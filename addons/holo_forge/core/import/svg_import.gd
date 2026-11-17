@tool
extends RefCounted
## Insert SVG: an SVG drawing as a new sketch of fixed curves.
##
## Reads path (M/L/H/V/C/S/Q/T/A/Z, absolute and relative), rect (rounded corners too), circle,
## ellipse, line, polyline and polygon, through nested group transforms (matrix, translate,
## scale, rotate, skewX, skewY) and the viewBox (fitted to the page as preserveAspectRatio says:
## meet, slice or none, with its alignment). Lengths may carry px/mm/cm/in/pt/pc units;
## a plain number is a CSS pixel (0.264583 mm). Every Bezier becomes a degree-3 control-point
## spline (quadratics are raised to cubics); elliptical arcs become exact conic pieces and
## circles a transform stretches become ellipses. Text, images and <use> are skipped with a
## warning.
##
## The Writer class below is shared with dxf_import.gd.

const FEATURE := preload("res://addons/holo_forge/core/feature.gd")
const SKETCH_DATA := preload("res://addons/holo_forge/core/sketch/sketch_data.gd")

## CSS pixels per unit (a pixel is 1/96 inch).
const PX_PER := {"px": 1.0, "mm": 96.0 / 25.4, "cm": 96.0 / 2.54, "in": 96.0, "pt": 96.0 / 72.0, "pc": 16.0, "q": 96.0 / 101.6}
const METERS_PER_PX := 0.0254 / 96.0
## Meters per plain user unit for options.units.
const UNIT_METERS := {"px": 0.0254 / 96.0, "mm": 0.001, "cm": 0.01, "m": 1.0, "in": 0.0254, "pt": 0.0254 / 72.0}
## Elements whose content is never drawn where it stands.
const HIDDEN := ["defs", "clippath", "mask", "symbol", "marker", "pattern", "metadata", "title", "desc", "style", "script",
	"lineargradient", "radialgradient", "filter", "foreignobject"]
const SKIPPED := {"text": "text (convert it to paths first)", "image": "images", "use": "<use> copies"}


## Writes importer curves into a sketch. End points that meet (within MERGE) share one point,
## each imported shape gets one "fix" constraint so the solver leaves it where it is, and
## elliptical arcs become conics of at most 90 degrees each (sketches have no elliptical arc;
## a conic is a rational quadratic, so the pieces are exact).
## All positions are sketch-plane coordinates in meters.
class Writer:
	extends RefCounted
	## Meters: curve ends closer than this become one point.
	const MERGE := 1e-7

	var sketch: RefCounted
	## Curve entities made (lines, arcs, circles, ellipses, splines, conics, text).
	var curves := 0
	## Lone points made on purpose (point()); curve ends don't count.
	var points := 0
	var warnings: Array[String] = []
	## "qx,qy" grid cell -> [[position, point id], ...]
	var _ends := {}

	func _init(p_sketch: RefCounted) -> void:
		sketch = p_sketch

	func warn(text: String) -> void:
		if not warnings.has(text):
			warnings.append(text)

	## The point for a curve end: one already at that spot, or a new one.
	func end_point(p: Vector2) -> int:
		var qx := roundi(p.x / MERGE)
		var qy := roundi(p.y / MERGE)
		for dx in [-1, 0, 1]:
			for dy in [-1, 0, 1]:
				for entry in _ends.get("%d,%d" % [qx + dx, qy + dy], []):
					if (entry[0] as Vector2).distance_to(p) <= MERGE:
						return int(entry[1])
		var id: int = sketch.add_point(p)
		var key := "%d,%d" % [qx, qy]
		if not _ends.has(key):
			_ends[key] = []
		_ends[key].append([p, id])
		return id

	## One connected run of segments (one fix constraint). Segments: {"type": "line", "a", "b"},
	## {"type": "cubic", "a", "c1", "c2", "b"}, {"type": "arc", "c", "u", "v", "t0", "t1", "a", "b"}
	## (p(t) = c + u cos t + v sin t from t0 to t1; a and b are its exact ends).
	## Returns the number of curves made.
	func chain(segments: Array) -> int:
		var refs := []
		var before := curves
		for seg in segments:
			match str(seg.type):
				"line":
					# A line shorter than MERGE draws nothing (and leaves no stray point behind).
					if (seg.a as Vector2).distance_to(seg.b) > MERGE:
						var a := end_point(seg.a)
						var b := end_point(seg.b)
						if a != b:
							refs.append(sketch.add_line(a, b))
							curves += 1
				"cubic":
					refs.append_array(_cubic(seg.a, seg.c1, seg.c2, seg.b))
				"arc":
					refs.append_array(_arc(seg.c, seg.u, seg.v, float(seg.t0), float(seg.t1), seg.a, seg.b))
		_fix(refs)
		return curves - before

	## A whole circle or ellipse from its center and two conjugate semi-axes.
	func ellipse(c: Vector2, u: Vector2, v: Vector2) -> int:
		var axes := principal(u, v)
		if axes.b <= MERGE:
			warn("A circle or ellipse flattened to nothing was skipped")
			return -1
		var center: int = sketch.add_point(c)
		var id: int
		if axes.circular:
			id = sketch.add_circle(center, (axes.a + axes.b) * 0.5)
		else:
			var focus: int = sketch.add_point(c + (axes.dir as Vector2) * sqrt(axes.a * axes.a - axes.b * axes.b))
			id = sketch.add_ellipse(center, focus, axes.b)
		curves += 1
		_fix([id])
		return id

	## A control-point spline (DXF). knots/mults/weights may be empty (uniform, clamped, not rational).
	func spline(poles: PackedVector2Array, degree: int, knots: PackedFloat64Array, mults: PackedInt32Array, weights: PackedFloat64Array) -> int:
		if poles.size() < 2:
			return -1
		var ids := []
		for i in poles.size():
			ids.append(end_point(poles[i]) if i == 0 or i == poles.size() - 1 else sketch.add_point(poles[i]))
		var id: int = sketch.add_spline(ids, "control")
		var e: Dictionary = sketch.entities().back()
		e["degree"] = clampi(degree, 1, poles.size() - 1)
		if not knots.is_empty():
			e["knots"] = knots
			e["mults"] = mults
		if not weights.is_empty():
			e["weights"] = weights
		curves += 1
		_fix(ids)
		return id

	## A spline through fit points.
	func fit_spline(points: PackedVector2Array, closed: bool) -> int:
		if points.size() < 2:
			return -1
		var ids := []
		for i in points.size():
			var end := not closed and (i == 0 or i == points.size() - 1)
			ids.append(end_point(points[i]) if end else sketch.add_point(points[i]))
		var id: int = sketch.add_spline(ids, "fit", closed)
		curves += 1
		_fix(ids)
		return id

	func point(p: Vector2) -> int:
		var id: int = sketch.add_point(p)
		points += 1
		_fix([id])
		return id

	func text(value: String, at: Vector2, height: float, angle: float) -> int:
		if value.strip_edges() == "" or height <= 0.0:
			return -1
		curves += 1
		return sketch.add_text(value, at, height, {"angle": angle})

	## Semi-axes of the ellipse c + u cos t + v sin t: {"a" (major), "b" (minor), "dir" (major
	## direction), "circular": true for a circle}.
	static func principal(u: Vector2, v: Vector2) -> Dictionary:
		var xx := float(u.x) * u.x + float(v.x) * v.x
		var xy := float(u.x) * u.y + float(v.x) * v.y
		var yy := float(u.y) * u.y + float(v.y) * v.y
		var mean := (xx + yy) * 0.5
		var spread := sqrt(((xx - yy) * 0.5) ** 2 + xy * xy)
		var a := sqrt(mean + spread)
		var b := sqrt(maxf(mean - spread, 0.0))
		var angle := 0.5 * atan2(2.0 * xy, xx - yy)
		return {"a": a, "b": b, "dir": Vector2(cos(angle), sin(angle)), "circular": a - b <= a * 1e-6}

	func _cubic(a: Vector2, c1: Vector2, c2: Vector2, b: Vector2) -> Array:
		if a.distance_to(b) <= MERGE and a.distance_to(c1) <= MERGE and a.distance_to(c2) <= MERGE:
			return []
		var ids := [end_point(a), sketch.add_point(c1), sketch.add_point(c2), end_point(b)]
		sketch.add_spline(ids, "control")
		sketch.entities().back()["degree"] = 3
		curves += 1
		return ids

	func _arc(c: Vector2, u: Vector2, v: Vector2, t0: float, t1: float, a: Vector2, b: Vector2) -> Array:
		var sweep := t1 - t0
		if absf(sweep) < 1e-12:
			return []
		if absf(sweep) >= TAU - 1e-9:
			# A whole turn: ellipse() makes and fixes it.
			ellipse(c, u, v)
			return []
		if a.distance_to(b) <= MERGE:
			# Ends that meet, decided before any end point is made: nearly a whole turn (a
			# rounded 2 pi, as "6.283185") is the whole curve; a sliver is nothing to draw.
			if absf(sweep) > PI:
				ellipse(c, u, v)
			else:
				warn("A curve too short to draw was skipped")
			return []
		var axes := principal(u, v)
		var start := end_point(a)
		var finish := end_point(b)
		if start == finish:
			return []
		if axes.circular:
			# Arcs run counter-clockwise; a clockwise sweep (or a mirrored one) swaps the ends.
			var ccw := (u.cross(v) > 0.0) == (sweep > 0.0)
			var center: int = sketch.add_point(c)
			var id: int = sketch.add_arc(center, start, finish) if ccw else sketch.add_arc(center, finish, start)
			curves += 1
			return [id]
		# Conic pieces (rational quadratics) of at most 90 degrees: exact for any ellipse. Separate
		# pieces rather than one multi-span spline, whose kinks the kernel integrates poorly.
		var pieces := maxi(1, ceili(absf(sweep) / (PI * 0.5) - 1e-9))
		var dt := sweep / pieces
		var w := cos(dt * 0.5)
		var ids := [start]
		for i in pieces:
			var tm := t0 + dt * (i + 0.5)
			var shoulder: int = sketch.add_point(c + (u * cos(tm) + v * sin(tm)) / w)
			var t := t0 + dt * (i + 1)
			var next: int = finish if i == pieces - 1 else sketch.add_point(c + u * cos(t) + v * sin(t))
			# The conic's shoulder weight is rho / (1 - rho).
			sketch.add_conic(ids.back(), next, shoulder, w / (1.0 + w))
			ids.append(shoulder)
			ids.append(next)
			curves += 1
		return ids

	## One fix constraint for a shape: curves by id, spline/conic points by their point ids
	## (the solver has no spline or conic entity to fix).
	func _fix(refs: Array) -> void:
		var seen := {}
		var unique := []
		for id in refs:
			if not seen.has(int(id)):
				seen[int(id)] = true
				unique.append(int(id))
		if not unique.is_empty():
			sketch.add_constraint("fix", unique)


## Reads SVG path data with a cursor, so packed arc flags ("a5 5 0 01 10 0") parse right.
class PathReader:
	extends RefCounted
	var text: String
	var i := 0

	func _init(p_text: String) -> void:
		text = p_text

	func skip() -> void:
		while i < text.length():
			var ch := text.unicode_at(i)
			if ch == 32 or ch == 9 or ch == 10 or ch == 13 or ch == 44:
				i += 1
			else:
				return

	func done() -> bool:
		skip()
		return i >= text.length()

	## The command letter at the cursor (consumed), or "" when a number (or nothing) is next.
	func letter() -> String:
		skip()
		if i >= text.length():
			return ""
		var ch := text[i]
		if "MmLlHhVvCcSsQqTtAaZz".contains(ch):
			i += 1
			return ch
		return ""

	func number() -> float:
		skip()
		var start := i
		var n := text.length()
		if i < n and (text.unicode_at(i) == 43 or text.unicode_at(i) == 45):
			i += 1
		var digits := false
		while i < n and _digit(text.unicode_at(i)):
			i += 1
			digits = true
		if i < n and text.unicode_at(i) == 46:
			i += 1
			while i < n and _digit(text.unicode_at(i)):
				i += 1
				digits = true
		if not digits:
			i = start
			return NAN
		if i < n and (text.unicode_at(i) == 101 or text.unicode_at(i) == 69):
			var save := i
			i += 1
			if i < n and (text.unicode_at(i) == 43 or text.unicode_at(i) == 45):
				i += 1
			var exponent := false
			while i < n and _digit(text.unicode_at(i)):
				i += 1
				exponent = true
			if not exponent:
				i = save
		return text.substr(start, i - start).to_float()

	func pair() -> Vector2:
		var x := number()
		var y := number()
		return Vector2(x, y) if not (is_nan(x) or is_nan(y)) else Vector2(NAN, NAN)

	## An arc flag: a single 0 or 1, even with no separator after it.
	func flag() -> int:
		skip()
		if i < text.length() and (text[i] == "0" or text[i] == "1"):
			i += 1
			return int(text[i - 1])
		return -1

	static func _digit(ch: int) -> bool:
		return ch >= 48 and ch <= 57


## Adds the drawing as a new sketch on frame ({"origin", "x", "y"}, see sketch_data.gd).
## options: "scale" (meters per SVG user unit; by default from the drawing's width/height and
## viewBox, else a CSS pixel), "units" (what a plain user unit is when you know better than
## the file: px, mm, cm, m, in, pt), "flip_y" (default true: SVG's y points down, so the
## drawing is turned upright with the bottom-left of its page at the sketch origin), "origin"
## (Vector2 offset in meters, in sketch coordinates).
## Returns {"feature": the sketch feature (null when nothing could be drawn), "curves": count,
## "warnings": Array[String]}.
static func to_sketch(svg_text: String, doc: Resource, frame: Dictionary, plane_ref: String, options := {}) -> Dictionary:
	var holder: Resource = FEATURE.new()
	holder.options = SKETCH_DATA.new_options(frame, plane_ref)
	var writer := Writer.new(SKETCH_DATA.new(holder, doc))
	_read(svg_text, writer, options)
	if writer.curves == 0:
		writer.warn("The SVG has no shapes to import")
		return {"feature": null, "curves": 0, "warnings": writer.warnings}
	var feature: Resource = doc.add_feature("sketch", "Sketch", {}, holder.options)
	return {"feature": feature, "curves": writer.curves, "warnings": writer.warnings}


static func _read(svg_text: String, writer: Writer, options: Dictionary) -> void:
	var parser := XMLParser.new()
	if svg_text.strip_edges() == "" or parser.open_buffer(svg_text.to_utf8_buffer()) != OK:
		writer.warn("The SVG couldn't be read")
		return
	# One entry per open element: {"xform": user units -> sketch meters, "hidden"}.
	var stack: Array[Dictionary] = []
	var seen_root := false
	while parser.read() == OK:
		var node_type := parser.get_node_type()
		if node_type == XMLParser.NODE_ELEMENT_END:
			if not stack.is_empty():
				stack.pop_back()
			continue
		if node_type != XMLParser.NODE_ELEMENT:
			continue
		var name := _local_name(parser.get_node_name())
		var attrs := {}
		for k in parser.get_attribute_count():
			attrs[_local_name(parser.get_attribute_name(k))] = parser.get_attribute_value(k)
		var parent: Dictionary = stack.back() if not stack.is_empty() else {}
		var xform := Transform2D.IDENTITY
		var hidden := bool(parent.get("hidden", false)) or name in HIDDEN or _display_none(attrs)
		if not seen_root:
			if name != "svg":
				writer.warn("This isn't an SVG drawing")
				return
			seen_root = true
			xform = _root_xform(attrs, options)
		elif name == "svg":
			xform = (parent.xform as Transform2D) * _nested_viewport(attrs)
		else:
			xform = (parent.xform as Transform2D) * _parse_transform(str(attrs.get("transform", "")))
		if not hidden:
			_shape(name, attrs, xform, writer)
		if not parser.is_empty():
			stack.append({"xform": xform, "hidden": hidden})
	if not seen_root:
		writer.warn("This isn't an SVG drawing")


static func _local_name(name: String) -> String:
	var parts := name.split(":")
	return parts[parts.size() - 1].to_lower()


static func _display_none(attrs: Dictionary) -> bool:
	if str(attrs.get("display", "")).strip_edges() == "none":
		return true
	return str(attrs.get("style", "")).replace(" ", "").contains("display:none")


# --- Coordinates -----------------------------------------------------------------------------

## User units -> sketch meters for the outer <svg> element. With a viewBox and a page size the
## viewBox is fitted to the page as preserveAspectRatio says (by default "xMidYMid meet": one
## scale, centered; "none" stretches it to fill the page), and flip_y puts the page's own
## bottom-left corner at the sketch origin.
static func _root_xform(attrs: Dictionary, options: Dictionary) -> Transform2D:
	var box := _numbers(str(attrs.get("viewbox", attrs.get("viewBox", ""))))
	var has_box := box.size() == 4 and box[2] > 0.0 and box[3] > 0.0
	var width := _length(str(attrs.get("width", "")), NAN)
	var height := _length(str(attrs.get("height", "")), NAN)
	var offset: Vector2 = options.get("origin", Vector2.ZERO)
	var flip := bool(options.get("flip_y", true))
	var corner := Vector2(box[0], box[1]) if has_box else Vector2.ZERO
	# Meters per user unit along x and y, where the viewBox's corner lands (meters, page y down)
	# and the page's height in meters.
	var unit := Vector2.ONE * METERS_PER_PX
	var shift := Vector2.ZERO
	var page := 0.0
	var override := options.has("scale") or (options.has("units") and UNIT_METERS.has(str(options.units)))
	if override:
		unit = Vector2.ONE * (float(options.scale) if options.has("scale") else float(UNIT_METERS[str(options.units)]))
		page = (float(box[3]) if has_box else (height if is_finite(height) else 0.0)) * unit.y
	elif has_box and (is_finite(width) or is_finite(height)):
		# A missing page side follows the viewBox's proportions.
		var page_w := width if is_finite(width) else box[2] * height / box[3]
		var page_h := height if is_finite(height) else box[3] * width / box[2]
		var fit := _fit_viewbox(box, page_w, page_h, str(attrs.get("preserveaspectratio", attrs.get("preserveAspectRatio", ""))))
		unit = (fit.scale as Vector2) * METERS_PER_PX
		shift = (fit.shift as Vector2) * METERS_PER_PX
		page = page_h * METERS_PER_PX
	else:
		page = (float(box[3]) if has_box else (height if is_finite(height) else 0.0)) * METERS_PER_PX
	var origin := shift - corner * unit
	if flip:
		return Transform2D(Vector2(unit.x, 0.0), Vector2(0.0, -unit.y), Vector2(origin.x, page - origin.y) + offset)
	return Transform2D(Vector2(unit.x, 0.0), Vector2(0.0, unit.y), origin + offset)


## How a viewBox fits a viewport of page_w x page_h (CSS pixels) under preserveAspectRatio text:
## {"scale": Vector2 (viewport units per viewBox unit), "shift": Vector2 (where the viewBox's
## corner lands, after the scale)}. "none" scales x and y apart; otherwise one scale, the smaller
## ("meet", the default) or the larger ("slice"), aligned by xMin/xMid/xMax and yMin/yMid/yMax.
static func _fit_viewbox(box: PackedFloat64Array, page_w: float, page_h: float, aspect: String) -> Dictionary:
	var words := aspect.strip_edges().split(" ", false)
	if not words.is_empty() and words[0] == "defer":
		words.remove_at(0)
	var align := words[0] if not words.is_empty() else "xMidYMid"
	var sx := page_w / box[2]
	var sy := page_h / box[3]
	if align == "none":
		return {"scale": Vector2(sx, sy), "shift": Vector2.ZERO}
	var s := maxf(sx, sy) if words.size() > 1 and words[1] == "slice" else minf(sx, sy)
	var ax := 0.0 if align.contains("xMin") else (1.0 if align.contains("xMax") else 0.5)
	var ay := 0.0 if align.contains("YMin") else (1.0 if align.contains("YMax") else 0.5)
	return {"scale": Vector2(s, s), "shift": Vector2((page_w - box[2] * s) * ax, (page_h - box[3] * s) * ay)}


## A nested <svg>: its x/y placement and viewBox fitting (preserveAspectRatio) inside the parent's
## user units.
static func _nested_viewport(attrs: Dictionary) -> Transform2D:
	var at := Vector2(_length(str(attrs.get("x", "")), 0.0), _length(str(attrs.get("y", "")), 0.0))
	var result := Transform2D(0.0, at)
	var box := _numbers(str(attrs.get("viewbox", attrs.get("viewBox", ""))))
	if box.size() == 4 and box[2] > 0.0 and box[3] > 0.0:
		var width := _length(str(attrs.get("width", "")), box[2])
		var height := _length(str(attrs.get("height", "")), box[3])
		var fit := _fit_viewbox(box, width, height, str(attrs.get("preserveaspectratio", attrs.get("preserveAspectRatio", ""))))
		var s: Vector2 = fit.scale
		var shift: Vector2 = fit.shift
		result = result * Transform2D(Vector2(s.x, 0.0), Vector2(0.0, s.y), Vector2(shift.x - box[0] * s.x, shift.y - box[1] * s.y))
	return result * _parse_transform(str(attrs.get("transform", "")))


## A transform attribute ("translate(10 5) rotate(30)") as one Transform2D.
static func _parse_transform(text: String) -> Transform2D:
	var result := Transform2D.IDENTITY
	if text.strip_edges() == "":
		return result
	var re := RegEx.create_from_string("(matrix|translate|scale|rotate|skewX|skewY)\\s*\\(([^)]*)\\)")
	for m in re.search_all(text):
		var n := _numbers(m.get_string(2))
		var t := Transform2D.IDENTITY
		match m.get_string(1):
			"matrix":
				if n.size() == 6:
					t = Transform2D(Vector2(n[0], n[1]), Vector2(n[2], n[3]), Vector2(n[4], n[5]))
			"translate":
				if n.size() >= 1:
					t = Transform2D(0.0, Vector2(n[0], n[1] if n.size() > 1 else 0.0))
			"scale":
				if n.size() >= 1:
					t = Transform2D(Vector2(n[0], 0.0), Vector2(0.0, n[1] if n.size() > 1 else n[0]), Vector2.ZERO)
			"rotate":
				if n.size() >= 1:
					var a := deg_to_rad(n[0])
					t = Transform2D(Vector2(cos(a), sin(a)), Vector2(-sin(a), cos(a)), Vector2.ZERO)
					if n.size() >= 3:
						var pivot := Vector2(n[1], n[2])
						t = Transform2D(0.0, pivot) * t * Transform2D(0.0, -pivot)
			"skewX":
				if n.size() >= 1:
					t = Transform2D(Vector2(1.0, 0.0), Vector2(tan(deg_to_rad(n[0])), 1.0), Vector2.ZERO)
			"skewY":
				if n.size() >= 1:
					t = Transform2D(Vector2(1.0, tan(deg_to_rad(n[0]))), Vector2(0.0, 1.0), Vector2.ZERO)
		result = result * t
	return result


static func _numbers(text: String) -> PackedFloat64Array:
	var reader := PathReader.new(text)
	var result := PackedFloat64Array()
	while not reader.done():
		var v := reader.number()
		if is_nan(v):
			break
		result.append(v)
	return result


## A length in user units (CSS pixels for absolute units); fallback when empty or a percentage.
static func _length(text: String, fallback: float) -> float:
	var s := text.strip_edges().to_lower()
	if s == "" or s.ends_with("%"):
		return fallback
	for unit in PX_PER:
		if s.ends_with(unit) and s.length() > unit.length():
			var number := s.substr(0, s.length() - unit.length()).strip_edges()
			return number.to_float() * float(PX_PER[unit]) if number.is_valid_float() else fallback
	return s.to_float() if s.is_valid_float() else fallback


static func _attr(attrs: Dictionary, key: String, fallback := 0.0) -> float:
	return _length(str(attrs.get(key, "")), fallback)


# --- Shapes ----------------------------------------------------------------------------------

static func _line(m: Transform2D, a: Vector2, b: Vector2) -> Dictionary:
	return {"type": "line", "a": m * a, "b": m * b}


static func _cubic(m: Transform2D, a: Vector2, c1: Vector2, c2: Vector2, b: Vector2) -> Dictionary:
	return {"type": "cubic", "a": m * a, "c1": m * c1, "c2": m * c2, "b": m * b}


## An elliptical arc in user space (center c, semi-axes u and v, angles t0 -> t1), in sketch space.
static func _arc(m: Transform2D, c: Vector2, u: Vector2, v: Vector2, t0: float, t1: float, a: Vector2, b: Vector2) -> Dictionary:
	return {"type": "arc", "c": m * c, "u": m.basis_xform(u), "v": m.basis_xform(v), "t0": t0, "t1": t1, "a": m * a, "b": m * b}


static func _shape(name: String, attrs: Dictionary, m: Transform2D, writer: Writer) -> void:
	match name:
		"path":
			_path(str(attrs.get("d", "")), m, writer)
		"rect":
			_rect(attrs, m, writer)
		"circle":
			var r := _attr(attrs, "r")
			if r > 0.0:
				writer.ellipse(m * Vector2(_attr(attrs, "cx"), _attr(attrs, "cy")), m.basis_xform(Vector2(r, 0.0)), m.basis_xform(Vector2(0.0, r)))
		"ellipse":
			var rx := _attr(attrs, "rx", -1.0)
			var ry := _attr(attrs, "ry", -1.0)
			rx = ry if rx < 0.0 else rx
			ry = rx if ry < 0.0 else ry
			if rx > 0.0 and ry > 0.0:
				writer.ellipse(m * Vector2(_attr(attrs, "cx"), _attr(attrs, "cy")), m.basis_xform(Vector2(rx, 0.0)), m.basis_xform(Vector2(0.0, ry)))
		"line":
			writer.chain([_line(m, Vector2(_attr(attrs, "x1"), _attr(attrs, "y1")), Vector2(_attr(attrs, "x2"), _attr(attrs, "y2")))])
		"polyline", "polygon":
			var n := _numbers(str(attrs.get("points", "")))
			var segments := []
			var count := n.size() >> 1
			for k in range(0, count - 1):
				segments.append(_line(m, Vector2(n[k * 2], n[k * 2 + 1]), Vector2(n[k * 2 + 2], n[k * 2 + 3])))
			if name == "polygon" and count >= 3:
				var last := count - 1
				segments.append(_line(m, Vector2(n[last * 2], n[last * 2 + 1]), Vector2(n[0], n[1])))
			writer.chain(segments)
		_:
			if SKIPPED.has(name):
				writer.warn("SVG %s aren't imported" % SKIPPED[name])


static func _rect(attrs: Dictionary, m: Transform2D, writer: Writer) -> void:
	var x := _attr(attrs, "x")
	var y := _attr(attrs, "y")
	var w := _attr(attrs, "width")
	var h := _attr(attrs, "height")
	if w <= 0.0 or h <= 0.0:
		return
	var rx := _attr(attrs, "rx", -1.0)
	var ry := _attr(attrs, "ry", -1.0)
	rx = ry if rx < 0.0 else rx
	ry = rx if ry < 0.0 else ry
	rx = clampf(rx, 0.0, w * 0.5)
	ry = clampf(ry, 0.0, h * 0.5)
	if rx <= 0.0 or ry <= 0.0:
		var corners := [Vector2(x, y), Vector2(x + w, y), Vector2(x + w, y + h), Vector2(x, y + h)]
		writer.chain(range(4).map(func(k: int) -> Dictionary: return _line(m, corners[k], corners[(k + 1) % 4])))
		return
	var u := Vector2(rx, 0.0)
	var v := Vector2(0.0, ry)
	# Clockwise on the page (SVG y down): top, top-right corner, right, ... back to the start.
	var segments := [
		_line(m, Vector2(x + rx, y), Vector2(x + w - rx, y)),
		_arc(m, Vector2(x + w - rx, y + ry), u, v, -PI * 0.5, 0.0, Vector2(x + w - rx, y), Vector2(x + w, y + ry)),
		_line(m, Vector2(x + w, y + ry), Vector2(x + w, y + h - ry)),
		_arc(m, Vector2(x + w - rx, y + h - ry), u, v, 0.0, PI * 0.5, Vector2(x + w, y + h - ry), Vector2(x + w - rx, y + h)),
		_line(m, Vector2(x + w - rx, y + h), Vector2(x + rx, y + h)),
		_arc(m, Vector2(x + rx, y + h - ry), u, v, PI * 0.5, PI, Vector2(x + rx, y + h), Vector2(x, y + h - ry)),
		_line(m, Vector2(x, y + h - ry), Vector2(x, y + ry)),
		_arc(m, Vector2(x + rx, y + ry), u, v, PI, PI * 1.5, Vector2(x, y + ry), Vector2(x + rx, y)),
	]
	writer.chain(segments)


## Path data: every subpath becomes one chain of segments (ending where it started closes it).
static func _path(d: String, m: Transform2D, writer: Writer) -> void:
	var reader := PathReader.new(d)
	var segments := []
	var cur := Vector2.ZERO
	var start := Vector2.ZERO
	var last_c2 := Vector2.ZERO  # previous cubic's second control point (for S)
	var last_q := Vector2.ZERO  # previous quadratic's control point (for T)
	var command := ""
	var previous := ""
	while not reader.done():
		var letter := reader.letter()
		if letter == "":
			if command == "" or command in ["Z", "z"]:
				writer.warn("Some SVG path data couldn't be read")
				break
			# Numbers after a command repeat it (after a moveto they are line segments).
			letter = "L" if command == "M" else ("l" if command == "m" else command)
		command = letter
		var rel := letter == letter.to_lower()
		var base := cur if rel else Vector2.ZERO
		var upper := letter.to_upper()
		var ok := true
		match upper:
			"M":
				var p := reader.pair() + base
				ok = p.is_finite()
				if ok:
					writer.chain(segments)
					segments = []
					cur = p
					start = p
			"L":
				var p := reader.pair() + base
				ok = p.is_finite()
				if ok:
					segments.append(_line(m, cur, p))
					cur = p
			"H":
				var x := reader.number()
				ok = not is_nan(x)
				if ok:
					var p := Vector2(x + (cur.x if rel else 0.0), cur.y)
					segments.append(_line(m, cur, p))
					cur = p
			"V":
				var y := reader.number()
				ok = not is_nan(y)
				if ok:
					var p := Vector2(cur.x, y + (cur.y if rel else 0.0))
					segments.append(_line(m, cur, p))
					cur = p
			"C", "S":
				var c1 := cur * 2.0 - last_c2 if previous in ["C", "S"] else cur
				if upper == "C":
					c1 = reader.pair() + base
				var c2 := reader.pair() + base
				var p := reader.pair() + base
				ok = c1.is_finite() and c2.is_finite() and p.is_finite()
				if ok:
					segments.append(_cubic(m, cur, c1, c2, p))
					last_c2 = c2
					cur = p
			"Q", "T":
				var q := cur * 2.0 - last_q if previous in ["Q", "T"] else cur
				if upper == "Q":
					q = reader.pair() + base
				var p := reader.pair() + base
				ok = q.is_finite() and p.is_finite()
				if ok:
					# A quadratic raised to a cubic: the same curve.
					segments.append(_cubic(m, cur, cur + (q - cur) * (2.0 / 3.0), p + (q - p) * (2.0 / 3.0), p))
					last_q = q
					cur = p
			"A":
				var rx := reader.number()
				var ry := reader.number()
				var phi := reader.number()
				var large := reader.flag()
				var sweep := reader.flag()
				var p := reader.pair() + base
				ok = not (is_nan(rx) or is_nan(ry) or is_nan(phi)) and large >= 0 and sweep >= 0 and p.is_finite()
				if ok:
					var seg := _svg_arc(m, cur, p, absf(rx), absf(ry), deg_to_rad(phi), large == 1, sweep == 1)
					if not seg.is_empty():
						segments.append(seg)
					cur = p
			"Z":
				# Exact test: is_equal_approx is relative (1e-5 of the coordinate), so it would
				# drop a real closing gap on big coordinates. The writer merges ends within MERGE.
				if cur != start:
					segments.append(_line(m, cur, start))
				writer.chain(segments)
				segments = []
				cur = start
		if not ok:
			writer.warn("Some SVG path data couldn't be read")
			break
		previous = upper
	writer.chain(segments)


## An SVG arc from a to b (endpoint form) as a center-form segment (SVG 1.1 implementation notes, F.6.5).
static func _svg_arc(m: Transform2D, a: Vector2, b: Vector2, rx: float, ry: float, phi: float, large: bool, sweep: bool) -> Dictionary:
	# Only identical ends omit the arc (F.6.2); nearly equal ones still draw it.
	if a == b:
		return {}
	if rx <= 0.0 or ry <= 0.0:
		return _line(m, a, b)
	var cos_phi := cos(phi)
	var sin_phi := sin(phi)
	var hx := (float(a.x) - b.x) * 0.5
	var hy := (float(a.y) - b.y) * 0.5
	var x1 := cos_phi * hx + sin_phi * hy
	var y1 := -sin_phi * hx + cos_phi * hy
	var lam := (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
	if lam > 1.0:
		rx *= sqrt(lam)
		ry *= sqrt(lam)
	var num := rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
	var den := rx * rx * y1 * y1 + ry * ry * x1 * x1
	var coef := sqrt(maxf(num / den, 0.0)) * (1.0 if large != sweep else -1.0)
	var cx1 := coef * rx * y1 / ry
	var cy1 := -coef * ry * x1 / rx
	var c := Vector2(cos_phi * cx1 - sin_phi * cy1 + (float(a.x) + b.x) * 0.5, sin_phi * cx1 + cos_phi * cy1 + (float(a.y) + b.y) * 0.5)
	var t0 := atan2((y1 - cy1) / ry, (x1 - cx1) / rx)
	var t1 := atan2((-y1 - cy1) / ry, (-x1 - cx1) / rx)
	var delta := fposmod(t1 - t0, TAU)
	if not sweep and delta > 0.0:
		delta -= TAU
	var u := Vector2(cos_phi, sin_phi) * rx
	var v := Vector2(-sin_phi, cos_phi) * ry
	return _arc(m, c, u, v, t0, t0 + delta, a, b)
