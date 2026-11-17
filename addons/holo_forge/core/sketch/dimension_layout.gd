@tool
extends RefCounted
## Pure geometry for sketch dimensions: what a dimension measures now, which linear orientation
## and which of the four angles the cursor asks for, where its lines, arrows and text go in the
## sketch plane, and the same on screen with fixed pixel sizes. No drawing, no solving.
##
## A dimension's text sits at T = anchor + offset (the anchor is the sketch editor's
## _dimension_anchor, the middle of what it measures). Plane layouts are in sketch-plane meters;
## screen layouts apply the pixel metrics along the projected directions, so a dimension stays a
## drafting dimension when the sketch is seen at an angle while its text keeps its pixel size and
## stays upright.

const UNITS := preload("res://addons/holo_forge/core/units.gd")
## Degrees of hysteresis between linear orientation sectors.
const ANGLE_SNAP := 4.0
## Pixel sizes at UI scale 1 (metrics() scales them): line widths; arrowheads (length, half of the
## base); extension lines' gap at the geometry, run past the dimension line, and the distance
## under which one isn't drawn; the half size of the marker a sketch point is drawn with (the gap
## is taken from its edge; 0 when points aren't shown); the text baseline above its line; the
## foot spacing under which arrows go outside and their tails; the dimension line's run past text
## placed beyond a foot; the clear space between text and the end of an extension line it sits
## over; the room kept between an angle's text and its rays; radius/diameter landings (shortest,
## text baseline above, text start); arc extensions' run past the arrow; the text hit area's
## padding and the lines' hit distance; the offset shown when the text sits on what it measures;
## the smallest angle arc; the value and tooltip font sizes.
const METRICS := {
	"line": 1.0, "line_selected": 1.5, "arrow_len": 9.0, "arrow_half": 1.8,
	"ext_gap": 3.0, "ext_over": 5.0, "ext_skip": 4.0, "mark": 0.0, "text_gap": 4.0, "short": 24.0, "tail": 15.0, "text_beyond": 2.0,
	"text_clear": 4.0, "text_room": 1.0, "landing": 12.0, "landing_gap": 3.0, "landing_start": 2.0, "arc_over": 4.0,
	"pad": 3.0, "hit": 4.0, "default_offset": 24.0, "angle_min": 30.0, "font": 13.0, "tip_font": 12.0,
}
## Digit height as a share of the font size (text hung below a line keeps the same gap).
const CAP_HEIGHT := 0.72

static var _literal := RegEx.create_from_string("^\\s*\\+?(\\d+\\.?\\d*|\\.\\d+)([eE][+-]?\\d+)?\\s*(mm|cm|m|in|ft|deg|rad|°)?\\s*$")
static var _signed_literal := RegEx.create_from_string("^\\s*[+-]?(\\d+\\.?\\d*|\\.\\d+)([eE][+-]?\\d+)?\\s*(mm|cm|m|in|ft|deg|rad|°)?\\s*$")


## The pixel metrics at a UI scale (the editor's display scale; 1 outside the editor).
static func metrics(scale := 1.0) -> Dictionary:
	var m := {}
	for key in METRICS:
		m[key] = float(METRICS[key]) * scale
	return m


# --- Text ------------------------------------------------------------------------------------

## A plain number with an optional unit (no names, operators or brackets).
static func is_literal(expression: String) -> bool:
	return _literal.search(expression) != null


## A plain number that may carry a sign ("-0.02 m", as older Fully Define wrote horizontal and
## vertical distances): shown without the expression marker.
static func is_number(expression: String) -> bool:
	return _signed_literal.search(expression) != null


## A plain number (with its unit, if any) times factor, to 6 decimals in the same unit ("10 mm" * 2
## -> "20 mm", "10" -> "20"); "" when expression isn't a plain number.
static func scale_literal(expression: String, factor: float) -> String:
	var found := _literal.search(expression)
	if found == null:
		return ""
	var number := (found.get_string(1) + found.get_string(2)).to_float() * factor
	var text := String.num(snappedf(number, 1e-6), 6)
	if text.contains("."):
		text = text.rstrip("0").rstrip(".")
	var unit := found.get_string(3)
	return text + (" " + unit if unit != "" else "")


## The number on the canvas: lengths in the document unit with 3 decimals, keeping at least 2
## ("40.00", "13.079"); angles in degrees with 1 decimal and "°".
static func canvas_number(value: float, kind: String, document_units: String) -> String:
	if kind == UNITS.KIND_ANGLE:
		return "%.1f°" % rad_to_deg(absf(value))
	var unit := UNITS.display_unit(UNITS.KIND_LENGTH, document_units)
	var text := "%.3f" % (absf(value) / float(UNITS.LENGTH_UNITS.get(unit, 1.0)))
	return text.substr(0, text.length() - 1) if text.ends_with("0") else text


## The full label: prefix (R, Ø), number, the expression marker ("ƒ " or "f ", for values set by
## an expression rather than a plain number, signed or not), driven parentheses.
static func canvas_text(c: Dictionary, value: float, document_units: String, expression: String, marker: String) -> String:
	var text := canvas_number(value, str(c.get("kind", "length")), document_units)
	if c.get("type", "") == "diameter" or c.get("linear_diameter", false):
		text = "Ø" + text
	elif c.get("type", "") == "radius":
		text = "R" + text
	if not c.get("driving", true):
		return "(" + text + ")"
	if expression != "" and not is_number(expression):
		text = marker + text
	return text


## Text angle that never reads upside down; vertical text reads top to bottom.
static func upright(v: Vector2) -> float:
	var angle := atan2(v.y, v.x)
	if angle > PI * 0.5 + 1e-6:
		angle -= PI
	elif angle <= -PI * 0.5 + 1e-6:
		angle += PI
	return angle


# --- Orientation and angle sectors -------------------------------------------------------------

static func _mod_pi_gap(a: float, b: float) -> float:
	var g := fposmod(a - b, PI)
	return minf(g, PI - g)


## "distance_x", "distance_y" or "aligned" for a pair of plane points and the cursor: the axis
## nearest the cursor's direction from the pair's middle (plane Y: horizontal, plane X: vertical,
## the pair's normal: aligned); the previous answer stays until the cursor is ANGLE_SNAP past the
## boundary between the two.
static func linear_orientation(pa: Vector2, pb: Vector2, place: Vector2, single_line: bool, lock := "", previous := "") -> String:
	if lock != "":
		return lock
	var d := pb - pa
	var length := d.length()
	var level := absf(d.y) <= length * 0.01
	var upright_pair := absf(d.x) <= length * 0.01
	if level or upright_pair:
		if single_line:
			return "aligned"
		return "distance_x" if level else "distance_y"
	var w := place - (pa + pb) * 0.5
	if w.length_squared() < 1e-24:
		return previous if previous != "" else "aligned"
	var axes := {"distance_x": PI * 0.5, "distance_y": 0.0, "aligned": fposmod(d.orthogonal().angle(), PI)}
	var theta := fposmod(w.angle(), PI)
	var best := ""
	var best_gap := INF
	for key in axes:
		var gap := _mod_pi_gap(theta, axes[key])
		if gap < best_gap:
			best_gap = gap
			best = key
	# delta past the boundary makes the two gaps differ by twice delta.
	if axes.has(previous) and _mod_pi_gap(theta, axes[previous]) - best_gap < 2.0 * deg_to_rad(ANGLE_SNAP):
		return previous
	return best


## The sector (of four) at two lines' crossing that holds the cursor:
## {"order": [i, j] into [line a, line b] (counter-clockwise), "rays": [s_i, s_j] (+1 = p1->p2),
##  "value": the sector's angle in (0, PI), "vertex": Vector2}; {} for parallel lines.
static func angle_sector(a1: Vector2, a2: Vector2, b1: Vector2, b2: Vector2, place: Vector2) -> Dictionary:
	var da := (a2 - a1).normalized()
	var db := (b2 - b1).normalized()
	var vertex: Variant = Geometry2D.line_intersects_line(a1, da, b1, db)
	if vertex == null or da == Vector2.ZERO or db == Vector2.ZERO:
		return {}
	var w: Vector2 = place - (vertex as Vector2)
	if w.length_squared() < 1e-24:
		w = da + db
	var rays := [[0, 1, da], [0, -1, -da], [1, 1, db], [1, -1, -db]]
	var start: Array = []
	var start_gap := INF
	var finish: Array = []
	var finish_gap := INF
	for r in rays:
		# w is this far counter-clockwise of the ray, and the ray this far counter-clockwise of w.
		var from_ray := fposmod((r[2] as Vector2).angle_to(w), TAU)
		if from_ray < start_gap:
			start_gap = from_ray
			start = r
		var to_ray := fposmod(w.angle_to(r[2]), TAU)
		if to_ray < finish_gap:
			finish_gap = to_ray
			finish = r
	return {"order": [start[0], finish[0]], "rays": [start[1], finish[1]], "value": start_gap + finish_gap, "vertex": vertex}


# --- Measuring ---------------------------------------------------------------------------------

## What the dimension measures in the geometry right now (meters or radians, positive): length
## |p2-p1|; distance between points or centres, from a point or centre to a line, or from the
## second line's first end to the first line (to a circle's or arc's curve instead of its centre
## for refs flagged in "edge"; twice that with "linear_diameter"); distance_x |xb-xa|; distance_y
## |yb-ya|; radius r; diameter 2r; arc_length r times the sweep; angle with rays the
## counter-clockwise sweep from rays[0]*dir(refs[0]) to rays[1]*dir(refs[1]) in [0, TAU) (for
## three points [vertex, a, b] the directions are vertex->a and vertex->b); an arc's sweep angle
## (refs [arc]); a legacy angle |da.angle_to(db)|.
static func measure(s: RefCounted, c: Dictionary) -> float:
	var refs: Array = c.get("refs", [])
	if refs.is_empty():
		return 0.0
	for r in refs:
		if s.entity(int(r)).is_empty():
			return 0.0
	var first: Dictionary = s.entity(int(refs[0]))
	var second: Dictionary = s.entity(int(refs[1])) if refs.size() > 1 else {}
	var twice := 2.0 if c.get("linear_diameter", false) else 1.0
	match str(c.get("type", "")):
		"length":
			return _line_dir(s, first).length() if first.type == "line" else 0.0
		"radius":
			return float(first.get("r", 0.0))
		"diameter":
			return 2.0 * float(first.get("r", 0.0))
		"arc_length":
			if first.type != "arc":
				return 0.0
			var span := _arc_span(s, first)
			return float(first.r) * (span[1] - span[0])
		"distance_x", "distance_y":
			if second.is_empty():
				return 0.0
			var d := _center(s, int(refs[1])) - _center(s, int(refs[0]))
			return absf(d.x if c.type == "distance_x" else d.y) * twice
		"distance":
			if second.is_empty():
				return 0.0
			if edges(c).has(true):
				return absf(edge_gap(s, refs, edges(c)))
			if first.type == "line" and second.type == "line":
				return _to_line(s, s.point(int(second.p1)), first) * twice
			if second.type == "line":
				return _to_line(s, _center(s, int(refs[0])), second) * twice
			if first.type == "line":
				return _to_line(s, _center(s, int(refs[1])), first) * twice
			return _center(s, int(refs[0])).distance_to(_center(s, int(refs[1])))
		"angle":
			if refs.size() == 1:
				if first.type != "arc":
					return 0.0
				var span := _arc_span(s, first)
				return span[1] - span[0]
			var dirs := _angle_dirs(s, refs)
			if dirs.is_empty():
				return 0.0
			var rays := _rays(c)
			if not rays.is_empty():
				return fposmod(((dirs[0] as Vector2) * rays[0]).angle_to((dirs[1] as Vector2) * rays[1]), TAU)
			return absf((dirs[0] as Vector2).angle_to(dirs[1]))
	return 0.0


## An angle's two directions: two lines' p1->p2, or for three points [vertex, a, b] vertex->a and
## vertex->b; [] when the refs aren't one of those.
static func _angle_dirs(s: RefCounted, refs: Array) -> Array:
	var types := refs.map(func(r) -> String: return str(s.entity(int(r)).get("type", "")))
	if types == ["line", "line"]:
		return [_line_dir(s, s.entity(int(refs[0]))), _line_dir(s, s.entity(int(refs[1])))]
	if types == ["point", "point", "point"]:
		var vertex: Vector2 = s.point(int(refs[0]))
		return [s.point(int(refs[1])) - vertex, s.point(int(refs[2])) - vertex]
	return []


## A distance's "edge" flags (per ref: measured to the curve of a circle or arc, not its centre).
static func edges(c: Dictionary) -> Array:
	var flags: Variant = c.get("edge", [])
	if not flags is Array or (flags as Array).size() != 2:
		return [false, false]
	return [bool(flags[0]), bool(flags[1])]


## The signed gap between two items measured to the curves of the round ones flagged in edge (the
## way the solver measures it): to a line, the centre's distance less the radius (negative when the
## line cuts the circle); between round items or a point, the centres' distance less both radii, or
## for one inside the other the bigger radius less the smaller and the centres' distance (negative
## when they overlap).
static func edge_gap(s: RefCounted, refs: Array, flags: Array) -> float:
	var a: Dictionary = s.entity(int(refs[0]))
	var b: Dictionary = s.entity(int(refs[1]))
	var radius := func(e: Dictionary, flagged: bool) -> float: return float(e.get("r", 0.0)) if flagged and e.get("type", "") in ["circle", "arc"] else 0.0
	if a.get("type", "") == "line" or b.get("type", "") == "line":
		var line_first: bool = a.get("type", "") == "line"
		var other := 1 if line_first else 0
		var h := _to_line(s, _center(s, int(refs[other])), a if line_first else b)
		return h - radius.call(b if line_first else a, flags[other])
	var d := _center(s, int(refs[0])).distance_to(_center(s, int(refs[1])))
	var r0: float = radius.call(a, flags[0])
	var r1: float = radius.call(b, flags[1])
	if d >= r0 and d >= r1:
		return d - r0 - r1
	return maxf(r0, r1) - minf(r0, r1) - d


## A point's position, a circle's or arc's centre, or a line's middle.
static func _center(s: RefCounted, id: int) -> Vector2:
	var e: Dictionary = s.entity(id)
	match str(e.get("type", "")):
		"point":
			return s.point(id)
		"circle", "arc":
			return s.point(int(e.c))
		"line":
			return (s.point(int(e.p1)) + s.point(int(e.p2))) * 0.5
	return Vector2.ZERO


static func _line_dir(s: RefCounted, line: Dictionary) -> Vector2:
	return s.point(int(line.p2)) - s.point(int(line.p1))


static func _to_line(s: RefCounted, p: Vector2, line: Dictionary) -> float:
	return Geometry2D.get_closest_point_to_segment_uncapped(p, s.point(int(line.p1)), s.point(int(line.p2))).distance_to(p)


## An arc's start and end angles about its centre, the end counter-clockwise after the start.
static func _arc_span(s: RefCounted, arc: Dictionary) -> Array:
	var center: Vector2 = s.point(int(arc.c))
	var a0: float = (s.point(int(arc.s)) - center).angle()
	var a1: float = (s.point(int(arc.e)) - center).angle()
	if a1 <= a0:
		a1 += TAU
	return [a0, a1]


## An angle's stored ray signs (+1/-1 per ref), or [] for a legacy angle.
static func _rays(c: Dictionary) -> Array:
	var rays: Variant = c.get("rays", [])
	if not rays is Array or (rays as Array).size() != 2:
		return []
	return [1.0 if float(rays[0]) >= 0.0 else -1.0, 1.0 if float(rays[1]) >= 0.0 else -1.0]


# --- Plane layout ------------------------------------------------------------------------------

## Plane-space layout (meters), one of:
## {"form": "linear", "a", "b" (feature points), "m" (measuring direction), "k" (offset direction),
##  "foot_a", "foot_b", "text", "line_ext": [[segment end, foot], ...], "nudge",
##  "marks": [bool, bool] (a and b are sketch points, drawn with a marker)}
## {"form": "angle", "vertex", "rays": [Vector2, Vector2], "start", "sweep", "radius", "text",
##  "ray_ranges": [[t0, t1], [t0, t1]] (where a curve lies along each ray; [0, 0] for none, as for
##  three points no line joins)}
## {"form": "radius" | "diameter", "center", "r", "u", "text", "inside": bool, "span": [a0, a1] or [], "nudge"}
## {"form": "note", "text"} (only the text: an angle between lines that no longer cross)
## "nudge" is a plane direction to show the dimension 24 px off along, when its text sits on what
## it measures (old documents); {} when the dimension can't be laid out.
static func plane_layout(s: RefCounted, c: Dictionary, anchor: Vector2) -> Dictionary:
	var refs: Array = c.get("refs", [])
	if refs.is_empty():
		return {}
	for r in refs:
		if s.entity(int(r)).is_empty():
			return {}
	var t: Vector2 = anchor + (c.get("offset", Vector2.ZERO) as Vector2)
	var first: Dictionary = s.entity(int(refs[0]))
	var second: Dictionary = s.entity(int(refs[1])) if refs.size() > 1 else {}
	match str(c.get("type", "")):
		"length":
			if first.type != "line":
				return {}
			var a: Vector2 = s.point(int(first.p1))
			var b: Vector2 = s.point(int(first.p2))
			return _linear(a, b, (b - a).normalized() if a != b else Vector2.RIGHT, t)
		"distance_x", "distance_y":
			if second.is_empty():
				return {}
			return _linear(_center(s, int(refs[0])), _center(s, int(refs[1])), Vector2.RIGHT if c.type == "distance_x" else Vector2.UP, t)
		"distance":
			if second.is_empty():
				return {}
			var flags := edges(c)
			if first.type == "line" or second.type == "line":
				return _to_line_layout(s, refs, t, flags, bool(c.get("linear_diameter", false)))
			var a := _center(s, int(refs[0]))
			var b := _center(s, int(refs[1]))
			if flags.has(true):
				var ends := _edge_points(s, refs, flags)
				a = ends[0]
				b = ends[1]
			return _linear(a, b, (b - a).normalized() if a.distance_to(b) > 1e-12 else Vector2.RIGHT, t, [not bool(flags[0]), not bool(flags[1])])
		"radius", "diameter":
			if not first.type in ["circle", "arc"]:
				return {}
			return _round(s, first, str(c.type), t)
		"angle":
			if refs.size() == 1:
				if first.type != "arc":
					return {}
				# An arc's sweep: an arc about its centre between the rays to its ends.
				var center: Vector2 = s.point(int(first.c))
				var r := float(first.r)
				var span := _arc_span(s, first)
				return {"form": "angle", "vertex": center, "rays": [Vector2.from_angle(span[0]), Vector2.from_angle(span[1])],
					"start": span[0], "sweep": span[1] - span[0], "radius": t.distance_to(center), "text": t, "ray_ranges": [[r, r], [r, r]]}
			if refs.size() == 3:
				if not [first.type, second.type, s.entity(int(refs[2])).get("type", "")] == ["point", "point", "point"]:
					return {}
				var vertex: Vector2 = s.point(int(refs[0]))
				var joined := [_joined(s, int(refs[0]), int(refs[1])), _joined(s, int(refs[0]), int(refs[2]))]
				return _angle_between([vertex, s.point(int(refs[1]))], [vertex, s.point(int(refs[2]))], _rays(c), t, joined)
			if second.is_empty() or first.type != "line" or second.type != "line":
				return {}
			return _angle(s, first, second, _rays(c), t)
		"arc_length":
			if first.type != "arc":
				return {}
			var center: Vector2 = s.point(int(first.c))
			var r := float(first.r)
			var span := _arc_span(s, first)
			return {"form": "angle", "vertex": center, "rays": [Vector2.from_angle(span[0]), Vector2.from_angle(span[1])],
				"start": span[0], "sweep": span[1] - span[0], "radius": t.distance_to(center), "text": t, "ray_ranges": [[r, r], [r, r]]}
	return {}


## Linear: feature points a and b measured along m, the dimension line through t; marks: which of
## them are sketch points (drawn with a marker).
static func _linear(a: Vector2, b: Vector2, m: Vector2, t: Vector2, marks := [true, true]) -> Dictionary:
	var k := m.orthogonal()
	var nudge := Vector2.ZERO
	# Text on the measured segment itself (zero offset): shown off to the plane-up (or left) side.
	if Geometry2D.get_closest_point_to_segment(t, a, b).distance_to(t) <= a.distance_to(b) * 1e-6 + 1e-12:
		nudge = k if k.y > 1e-9 or (absf(k.y) <= 1e-9 and k.x < 0.0) else -k
	return {"form": "linear", "a": a, "b": b, "m": m, "k": k, "foot_a": a + k * (t - a).dot(k), "foot_b": b + k * (t - b).dot(k),
		"text": t, "line_ext": [], "nudge": nudge, "marks": marks}


## True when a line of the sketch runs between two points.
static func _joined(s: RefCounted, a: int, b: int) -> bool:
	for e in s.entities():
		if e.type == "line" and ((int(e.p1) == a and int(e.p2) == b) or (int(e.p1) == b and int(e.p2) == a)):
			return true
	return false


## Distance to a line: from a point or a circle's centre (or its curve, when flagged in edge), or
## between two (parallel) lines. The dimension line runs across the line through t; feet off a
## line's segment get line extensions. A linear diameter (the line a centerline) runs on to the
## measured item's mirror image across the line.
static func _to_line_layout(s: RefCounted, refs: Array, t: Vector2, flags := [false, false], mirrored := false) -> Dictionary:
	var first: Dictionary = s.entity(int(refs[0]))
	var second: Dictionary = s.entity(int(refs[1]))
	var both: bool = first.type == "line" and second.type == "line"
	var line: Dictionary = first if both or first.type == "line" else second
	var other := 1 if both or first.type == "line" else 0
	var other_id := int(refs[other])
	var l1: Vector2 = s.point(int(line.p1))
	var l2: Vector2 = s.point(int(line.p2))
	var u := (l2 - l1).normalized() if l1 != l2 else Vector2.RIGHT
	var n := u.orthogonal()
	var foot_a := l1 + u * (t - l1).dot(u)
	var line_ext := []
	_line_extension(l1, l2, foot_a, line_ext)
	var b: Vector2
	var foot_b: Vector2
	var b_mark := false
	if both:
		var m1: Vector2 = s.point(int(second.p1))
		var m2: Vector2 = s.point(int(second.p2))
		var crossing: Variant = Geometry2D.line_intersects_line(m1, m2 - m1, t, n) if m1 != m2 else null
		foot_b = crossing if crossing != null else m1 + u * (t - m1).dot(u)
		b = foot_b
		_line_extension(m1, m2, foot_b, line_ext)
	else:
		b = _center(s, other_id)
		b_mark = true
		var round: Dictionary = s.entity(other_id)
		if bool(flags[other]) and round.get("type", "") in ["circle", "arc"]:
			# The curve's point nearest the line.
			b -= n * signf((b - l1).dot(n)) * float(round.r)
			b_mark = false
		foot_b = b + u * (t - b).dot(u)
	var a := foot_a
	if mirrored:
		a = b - n * 2.0 * (b - l1).dot(n)
		foot_a = a + u * (t - a).dot(u)
	return {"form": "linear", "a": a, "b": b, "m": n, "k": u, "foot_a": foot_a, "foot_b": foot_b, "text": t, "line_ext": line_ext, "nudge": Vector2.ZERO,
		"marks": [false, b_mark]}


## The two feature points of a distance between round items or a point measured to the curves
## flagged in edge: the curves' nearest points (along the centres' line).
static func _edge_points(s: RefCounted, refs: Array, flags: Array) -> Array:
	var c0 := _center(s, int(refs[0]))
	var c1 := _center(s, int(refs[1]))
	var radii := []
	for i in 2:
		var e: Dictionary = s.entity(int(refs[i]))
		radii.append(float(e.get("r", 0.0)) if bool(flags[i]) and e.get("type", "") in ["circle", "arc"] else 0.0)
	var d := c0.distance_to(c1)
	var u := (c1 - c0) / d if d > 1e-12 else Vector2.RIGHT
	if d >= float(radii[0]) and d >= float(radii[1]):
		return [c0 + u * float(radii[0]), c1 - u * float(radii[1])]
	# One inside the other: both curves' points on the side the inner one is pushed to.
	if float(radii[0]) >= float(radii[1]):
		return [c0 + u * float(radii[0]), c1 + u * float(radii[1])]
	return [c0 - u * float(radii[0]), c1 - u * float(radii[1])]


## A thin extension along a line from its nearer end to a foot that falls off its segment.
static func _line_extension(p1: Vector2, p2: Vector2, foot: Vector2, into: Array) -> void:
	var d := p2 - p1
	var length := d.length()
	if length <= 0.0:
		return
	var along := (foot - p1).dot(d / length)
	var eps := length * 1e-9
	if along > length + eps:
		into.append([p2, foot])
	elif along < -eps:
		into.append([p1, foot])


static func _round(s: RefCounted, e: Dictionary, type: String, t: Vector2) -> Dictionary:
	var center: Vector2 = s.point(int(e.c))
	var r := float(e.r)
	var w := t - center
	var u := w.normalized() if w.length() > r * 1e-9 + 1e-15 else Vector2(1, 1).normalized()
	var on_curve := absf(w.length() - r) <= r * 1e-6 + 1e-12
	return {"form": type, "center": center, "r": r, "u": u, "text": t, "inside": w.length() < r and not on_curve,
		"span": _arc_span(s, e) if e.type == "arc" else [], "nudge": u if on_curve else Vector2.ZERO}


static func _angle(s: RefCounted, a: Dictionary, b: Dictionary, rays: Array, t: Vector2) -> Dictionary:
	return _angle_between([s.point(int(a.p1)), s.point(int(a.p2))], [s.point(int(b.p1)), s.point(int(b.p2))], rays, t)


## An angle between two segments [from, to] (two lines, or a vertex to two points): the sector of
## rays (or, without, the one that holds t). covered: whether a curve lies along each segment (a
## vertex and a point no line joins have none: their ray gets an extension from the vertex).
static func _angle_between(a: Array, b: Array, rays: Array, t: Vector2, covered := [true, true]) -> Dictionary:
	var a1: Vector2 = a[0]
	var a2: Vector2 = a[1]
	var b1: Vector2 = b[0]
	var b2: Vector2 = b[1]
	var lines := [[a1, a2], [b1, b2]]
	var dirs := [(a2 - a1).normalized(), (b2 - b1).normalized()]
	var vertex: Variant = Geometry2D.line_intersects_line(a1, dirs[0], b1, dirs[1])
	if vertex == null or dirs[0] == Vector2.ZERO or dirs[1] == Vector2.ZERO:
		return {"form": "note", "text": t}
	var order := [0, 1]
	var signs := rays
	if rays.is_empty():
		var sector := angle_sector(a1, a2, b1, b2, t)
		order = sector.order
		signs = [float(sector.rays[0]), float(sector.rays[1])]
	var ray0: Vector2 = (dirs[order[0]] as Vector2) * float(signs[0])
	var ray1: Vector2 = (dirs[order[1]] as Vector2) * float(signs[1])
	var ranges := []
	for i in 2:
		if not bool(covered[order[i]]):
			ranges.append([0.0, 0.0])
			continue
		var ray: Vector2 = [ray0, ray1][i]
		var ends: Array = lines[order[i]]
		var t0: float = ((ends[0] as Vector2) - (vertex as Vector2)).dot(ray)
		var t1: float = ((ends[1] as Vector2) - (vertex as Vector2)).dot(ray)
		ranges.append([minf(t0, t1), maxf(t0, t1)])
	return {"form": "angle", "vertex": vertex, "rays": [ray0, ray1], "start": ray0.angle(), "sweep": fposmod(ray0.angle_to(ray1), TAU),
		"radius": t.distance_to(vertex), "text": t, "ray_ranges": ranges}


# --- Screen layout -----------------------------------------------------------------------------

## Screen-space primitives with the pixel metrics m (metrics() at the UI scale):
## {"dim_lines": [[a, b]] (dimension lines, tails, leaders, landings), "ext_lines": [[a, b]]
##  (extension lines, line and ray extensions), "polylines": [PackedVector2Array] (angle arcs, arc
##  extensions), "arrows": [{"tip", "dir"}] (dir points from the body to the tip),
##  "text": {"anchor", "angle", "align": "center"|"left"|"right", "baseline"} (the baseline's
##  offset in the text's rotated frame, negative = above), "text_center", "hit_poly" (the text box
##  grown by m.pad), "hit_segments": [[a, b]]}; {} when it isn't on screen.
## to_screen: Callable(Vector2 plane) -> Vector2 (non-finite when behind the camera).
## text_w, ascent and descent: the label's width and the font's ascent and descent in pixels.
static func screen_layout(plane: Dictionary, to_screen: Callable, m: Dictionary, text_w: float, ascent: float, descent: float) -> Dictionary:
	if plane.is_empty():
		return {}
	var p := _nudged(plane, to_screen, m)
	var out := {"dim_lines": [], "ext_lines": [], "polylines": [], "arrows": [], "text": {}}
	var ok := false
	match str(p.form):
		"linear":
			ok = _linear_screen(p, to_screen, m, text_w, out)
		"angle":
			ok = _angle_screen(p, to_screen, m, text_w, out)
		"radius", "diameter":
			ok = _round_screen(p, to_screen, m, text_w, out)
		"note":
			var at: Vector2 = to_screen.call(p.text)
			ok = at.is_finite()
			out.text = {"anchor": at, "angle": 0.0, "align": "center", "baseline": -float(m.text_gap)}
	if not ok:
		return {}
	var text: Dictionary = out.text
	var angle: float = text.angle
	var anchor: Vector2 = text.anchor
	var box := Rect2(text_x(str(text.align), text_w), float(text.baseline) - ascent, text_w, ascent + descent)
	var grown := box.grow(float(m.pad))
	var poly := PackedVector2Array()
	for corner in [grown.position, Vector2(grown.end.x, grown.position.y), grown.end, Vector2(grown.position.x, grown.end.y)]:
		poly.append(anchor + (corner as Vector2).rotated(angle))
	out["hit_poly"] = poly
	out["text_center"] = anchor + box.get_center().rotated(angle)
	var segments: Array = (out.dim_lines as Array) + (out.ext_lines as Array)
	for line: PackedVector2Array in out.polylines:
		for i in line.size() - 1:
			segments.append([line[i], line[i + 1]])
	out["hit_segments"] = segments
	return out


## Where text of width w starts, in its rotated frame, for an alignment.
static func text_x(align: String, w: float) -> float:
	match align:
		"left":
			return 0.0
		"right":
			return -w
	return -w * 0.5


## A plane length to measure the screen scale over, from the dimension's own size.
static func _step(p: Dictionary) -> float:
	var size := 0.0
	match str(p.form):
		"linear":
			size = (p.a as Vector2).distance_to(p.b)
		"radius", "diameter":
			size = float(p.r)
		"angle":
			size = float(p.radius)
			for range_pair: Array in p.ray_ranges:
				size = maxf(size, maxf(absf(float(range_pair[0])), absf(float(range_pair[1]))))
	return maxf(size, 1e-6) * 0.25


## Pixels per plane meter at a point along a plane direction.
static func _pixels_per_meter(at: Vector2, direction: Vector2, to_screen: Callable, h: float) -> float:
	var a: Vector2 = to_screen.call(at)
	var b: Vector2 = to_screen.call(at + direction * h)
	if not (a.is_finite() and b.is_finite()) or h <= 0.0:
		return 0.0
	return a.distance_to(b) / h


## Text that sits on what it measures moves default_offset pixels along the plane layout's nudge.
static func _nudged(plane: Dictionary, to_screen: Callable, m: Dictionary) -> Dictionary:
	var nudge: Vector2 = plane.get("nudge", Vector2.ZERO)
	if nudge == Vector2.ZERO:
		return plane
	var at: Vector2 = plane.text
	var ppm := _pixels_per_meter(at, nudge, to_screen, _step(plane))
	if ppm <= 1e-9:
		return plane
	var shift := nudge * (float(m.default_offset) / ppm)
	var p := plane.duplicate()
	p.text = at + shift
	if p.form == "linear":
		p.foot_a = (p.foot_a as Vector2) + shift
		p.foot_b = (p.foot_b as Vector2) + shift
	else:
		p.inside = false
	return p


## An extension line from a feature point toward its foot: a gap at the point (from the edge of its
## marker when marked), past the foot.
static func _extension(from: Vector2, foot: Vector2, m: Dictionary, into: Array, marked := false) -> void:
	var v := foot - from
	var d := v.length()
	if d <= float(m.ext_skip):
		return
	var e := v / d
	var gap := float(m.ext_gap) + (float(m.get("mark", 0.0)) if marked else 0.0)
	into.append([from + e * gap, foot + e * float(m.ext_over)])


static func _linear_screen(p: Dictionary, to_screen: Callable, m: Dictionary, text_w: float, out: Dictionary) -> bool:
	var a: Vector2 = to_screen.call(p.a)
	var b: Vector2 = to_screen.call(p.b)
	var foot_a: Vector2 = to_screen.call(p.foot_a)
	var foot_b: Vector2 = to_screen.call(p.foot_b)
	var at: Vector2 = to_screen.call(p.text)
	if not (a.is_finite() and b.is_finite() and foot_a.is_finite() and foot_b.is_finite() and at.is_finite()):
		return false
	var span := foot_b - foot_a
	var dir := span.normalized()
	if span.length() < 0.5:
		# A zero-length dimension: its line still runs along the projected measuring direction.
		var h := _step(p)
		var mm: Vector2 = p.m
		var ahead: Vector2 = to_screen.call((p.text as Vector2) + mm * h)
		var behind: Vector2 = to_screen.call((p.text as Vector2) - mm * h)
		dir = (ahead - behind).normalized()
		if not dir.is_finite() or dir == Vector2.ZERO:
			dir = Vector2.RIGHT
	var length := maxf(span.dot(dir), 0.0)
	var marks: Array = p.get("marks", [false, false])
	_extension(a, foot_a, m, out.ext_lines, bool(marks[0]))
	_extension(b, foot_b, m, out.ext_lines, bool(marks[1]))
	for pair: Array in p.get("line_ext", []):
		var from: Vector2 = to_screen.call(pair[0])
		var to: Vector2 = to_screen.call(pair[1])
		if from.is_finite() and to.is_finite():
			# From a line's end point (a sketch point).
			_extension(from, to, m, out.ext_lines, true)
	var short := length < float(m.short)
	var lo := 0.0
	var hi := length
	if short:
		# Too tight for arrows inside: they point in from outside, on tails.
		out.arrows.append({"tip": foot_a, "dir": dir})
		out.arrows.append({"tip": foot_b, "dir": -dir})
		lo = -float(m.tail)
		hi = length + float(m.tail)
	else:
		out.arrows.append({"tip": foot_a, "dir": -dir})
		out.arrows.append({"tip": foot_b, "dir": dir})
	# Text beyond a foot: the dimension line runs on under it.
	var along := (at - foot_a).dot(dir)
	var half := text_w * 0.5 + float(m.text_beyond)
	if along > length:
		hi = maxf(hi, along + half)
	elif along < 0.0:
		lo = minf(lo, along - half)
	if short:
		out.dim_lines.append([foot_a + dir * lo, foot_a])
		if length > 0.0:
			out.dim_lines.append([foot_a, foot_b])
		out.dim_lines.append([foot_b, foot_a + dir * hi])
	else:
		out.dim_lines.append([foot_a + dir * lo, foot_a + dir * hi])
	# Text over an extension line sits clear of the end that runs past the line, and hangs below
	# the line when the extension line comes down through where it would sit.
	var angle := upright(dir)
	var up := Vector2(0, -1).rotated(angle)
	var clear := float(m.ext_over) + float(m.text_clear)
	var runs_up := false
	var comes_down := false
	for pair: Array in [[a, foot_a, 0.0], [b, foot_b, length]]:
		var feature: Vector2 = pair[0]
		var foot: Vector2 = pair[1]
		if feature.distance_to(foot) <= float(m.ext_skip) or absf(along - float(pair[2])) >= text_w * 0.5 + float(m.text_beyond):
			continue
		if (foot - feature).dot(up) > 0.0:
			runs_up = true
		else:
			comes_down = true
	var baseline := -(clear if runs_up else float(m.text_gap))
	if comes_down and not runs_up:
		baseline = clear + float(m.font) * CAP_HEIGHT
	out.text = {"anchor": at, "angle": angle, "align": "center", "baseline": baseline}
	return true


static func _angle_screen(p: Dictionary, to_screen: Callable, m: Dictionary, text_w: float, out: Dictionary) -> bool:
	var vertex: Vector2 = p.vertex
	var center: Vector2 = to_screen.call(vertex)
	if not center.is_finite():
		return false
	var rays: Array = p.rays
	var h := _step(p)
	var ppm := (_pixels_per_meter(vertex, rays[0], to_screen, h) + _pixels_per_meter(vertex, rays[1], to_screen, h)) * 0.5
	if ppm <= 1e-9:
		return false
	var rho := maxf(float(p.radius), float(m.angle_min) / ppm)
	var start: float = p.start
	var sweep: float = p.sweep
	var count := maxi(8, ceili(rad_to_deg(sweep) / 3.0))
	var arc := PackedVector2Array()
	for i in count + 1:
		var q: Vector2 = to_screen.call(vertex + Vector2.from_angle(start + sweep * i / count) * rho)
		if not q.is_finite():
			return false
		arc.append(q)
	out.polylines.append(arc)
	var first := arc[0]
	var last := arc[count]
	var out_first := (first - arc[1]).normalized()
	var out_last := (last - arc[count - 1]).normalized()
	var tails := first.distance_to(last) < float(m.short)
	if not tails:
		out.arrows.append({"tip": first, "dir": out_first})
		out.arrows.append({"tip": last, "dir": out_last})
	else:
		out.arrows.append({"tip": first, "dir": -out_first})
		out.arrows.append({"tip": last, "dir": -out_last})
		out.dim_lines.append([first, first + out_first * float(m.tail)])
		out.dim_lines.append([last, last + out_last * float(m.tail)])
	# Rays whose segment doesn't reach the arc get an extension out (or in) to it, from the
	# segment's end point (or the vertex, when no curve lies along the ray).
	for i in 2:
		var ray: Vector2 = rays[i]
		var t0: float = p.ray_ranges[i][0]
		var t1: float = p.ray_ranges[i][1]
		var end_t := t1 if rho > t1 else (t0 if rho < t0 else NAN)
		if is_nan(end_t):
			continue
		var from: Vector2 = to_screen.call(vertex + ray * end_t)
		var to: Vector2 = to_screen.call(vertex + ray * rho)
		if from.is_finite() and to.is_finite():
			_extension(from, to, m, out.ext_lines, true)
	# The text: where T points from the vertex, outside the arc and never across a ray. It stays
	# inside the sector when it fits there between the rays, else it goes beyond the arrow (and its
	# tail) on T's side.
	var t: Vector2 = p.text
	var rel := fposmod((t - vertex).angle() - start, TAU) if t.distance_to(vertex) > 1e-15 else sweep * 0.5
	var at_end := rel > sweep * 0.5 if rel <= sweep else rel - sweep < TAU - rel
	var inner := maxf(center.distance_to(arc[int(count * 0.5)]), 1.0) + float(m.text_gap)
	var half := atan2(text_w * 0.5 + float(m.text_room), inner)
	if sweep >= 2.0 * half:
		if rel > sweep:
			rel = sweep if at_end else 0.0
		rel = clampf(rel, half, sweep - half)
	else:
		var beyond := ((float(m.tail) if tails else 0.0) + float(m.text_gap)) / inner + half
		rel = sweep + beyond if at_end else -beyond
	var phi := start + rel
	var q: Vector2 = to_screen.call(vertex + Vector2.from_angle(phi) * rho)
	var ahead: Vector2 = to_screen.call(vertex + Vector2.from_angle(phi + 0.01) * rho)
	var behind: Vector2 = to_screen.call(vertex + Vector2.from_angle(phi - 0.01) * rho)
	if not (q.is_finite() and ahead.is_finite() and behind.is_finite()):
		return false
	var angle := upright(ahead - behind)
	var above := Vector2(0, -1).rotated(angle)
	var baseline := -float(m.text_gap) if above.dot(q - center) >= 0.0 else float(m.text_gap) + float(m.font) * CAP_HEIGHT
	out.text = {"anchor": q, "angle": angle, "align": "center", "baseline": baseline}
	return true


static func _round_screen(p: Dictionary, to_screen: Callable, m: Dictionary, text_w: float, out: Dictionary) -> bool:
	var plane_center: Vector2 = p.center
	var r: float = p.r
	var u: Vector2 = p.u
	var center: Vector2 = to_screen.call(plane_center)
	var near: Vector2 = to_screen.call(plane_center + u * r)
	var far: Vector2 = to_screen.call(plane_center - u * r)
	var at: Vector2 = to_screen.call(p.text)
	if not (center.is_finite() and near.is_finite() and far.is_finite() and at.is_finite()):
		return false
	var diameter: bool = p.form == "diameter"
	if p.inside:
		# Inside: the line across (diameter) or out from the centre (radius), arrows on the curve.
		if diameter:
			out.dim_lines.append([far, near])
			out.arrows.append({"tip": far, "dir": (far - center).normalized()})
		else:
			out.dim_lines.append([center, near])
		out.arrows.append({"tip": near, "dir": (near - center).normalized()})
		# The text runs along the line (T is on it), above it, so the line never crosses it.
		out.text = {"anchor": at, "angle": upright(near - center), "align": "center", "baseline": -float(m.text_gap)}
	else:
		# Outside: a leader from the curve (through the centre for a diameter) to a landing.
		if diameter:
			out.dim_lines.append([far, at])
			out.arrows.append({"tip": far, "dir": (far - center).normalized()})
		else:
			out.dim_lines.append([near, at])
			var inward := near - at if near.distance_to(at) > 1.0 else center - near
			out.arrows.append({"tip": near, "dir": inward.normalized()})
		var side := 1.0 if at.x >= near.x else -1.0
		var landing := maxf(float(m.landing), text_w + 2.0 * float(m.landing_start))
		out.dim_lines.append([at, at + Vector2(side * landing, 0.0)])
		out.text = {"anchor": at + Vector2(side * float(m.landing_start), 0.0), "angle": 0.0, "align": "left" if side > 0.0 else "right",
			"baseline": -float(m.landing_gap)}
	# An arrow off a partial arc gets an arc extension along the circle.
	var span: Array = p.span
	if not span.is_empty():
		var radius_px := center.distance_to(near)
		var phis := [u.angle(), u.angle() + PI] if diameter else [u.angle()]
		for phi: float in phis:
			_arc_extension(plane_center, r, span, phi, radius_px, to_screen, m, out)
	return true


static func _arc_extension(center: Vector2, r: float, span: Array, phi: float, radius_px: float, to_screen: Callable, m: Dictionary, out: Dictionary) -> void:
	if radius_px <= 1.0:
		return
	var a0: float = span[0]
	var width: float = float(span[1]) - a0
	var rel := fposmod(phi - a0, TAU)
	if rel <= width + 1e-9:
		return
	var gap := float(m.ext_gap) / radius_px
	var over := float(m.arc_over) / radius_px
	var from: float
	var to: float
	if rel - width <= TAU - rel:
		from = a0 + width + gap
		to = a0 + rel + over
	else:
		from = a0 - gap
		to = a0 + rel - TAU - over
	if (to - from) * (1.0 if rel - width <= TAU - rel else -1.0) <= 0.0:
		return
	var count := maxi(4, ceili(rad_to_deg(absf(to - from)) / 3.0))
	var points := PackedVector2Array()
	for i in count + 1:
		var q: Vector2 = to_screen.call(center + Vector2.from_angle(from + (to - from) * i / count) * r)
		if not q.is_finite():
			return
		points.append(q)
	out.polylines.append(points)
