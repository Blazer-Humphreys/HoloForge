@tool
extends RefCounted
## Sketch text as closed outlines (plane coordinates), from the font's glyph contours.
## Height is the em height in meters; bold thickens the outlines, italic slants them, and text
## on a path places each glyph along a sketch curve.

const SHAPE_SIZE := 64
const BEZIER_STEPS := 6


## Every text entity's outlines: entity id -> Array[PackedVector2Array].
static func outlines_for(sketch: RefCounted, kernel: RefCounted = null) -> Dictionary:
	var result := {}
	for e in sketch.entities():
		if e.type == "text":
			result[int(e.id)] = outlines(e, sketch, kernel)
	return result


static func outlines(e: Dictionary, sketch: RefCounted = null, kernel: RefCounted = null) -> Array[PackedVector2Array]:
	var result: Array[PackedVector2Array] = []
	var text := str(e.get("text", ""))
	if text.strip_edges() == "":
		return result
	var font: Font = null
	if str(e.get("font", "")) != "" and ResourceLoader.exists(str(e.font)):
		font = load(str(e.font)) as Font
	if font == null:
		font = ThemeDB.fallback_font
	var ts := TextServerManager.get_primary_interface()
	var line := TextLine.new()
	line.add_string(text, font, SHAPE_SIZE)
	var scale := float(e.get("height", 0.01)) / SHAPE_SIZE
	var glyphs: Array = ts.shaped_text_get_glyphs(line.get_rid())
	var path := _path_points(e, sketch, kernel)
	var pen := 0.0
	for glyph in glyphs:
		var font_rid: RID = glyph.get("font_rid", RID())
		var index: int = glyph.get("index", 0)
		var offset: Vector2 = glyph.get("offset", Vector2.ZERO)
		var advance: float = glyph.get("advance", 0.0)
		if font_rid.is_valid() and index > 0:
			var data: Dictionary = ts.font_get_glyph_contours(font_rid, SHAPE_SIZE, index)
			for contour in _contours(data):
				var placed := PackedVector2Array()
				for p in contour:
					# Font units: x right, y down from the baseline; the sketch's y points up.
					var local := Vector2(pen + offset.x + p.x, -(offset.y + p.y)) * scale
					if e.get("italic", false):
						local.x += local.y * 0.2
					placed.append(local)
				result.append(placed)
		pen += advance
	if e.get("bold", false):
		var thick: Array[PackedVector2Array] = []
		for outline in result:
			for grown in Geometry2D.offset_polygon(outline, float(e.get("height", 0.01)) * 0.03, Geometry2D.JOIN_MITER):
				thick.append(grown)
		result = thick
	var origin := Vector2(float(e.get("x", 0.0)), float(e.get("y", 0.0)))
	var angle := float(e.get("angle", 0.0))
	var placed_result: Array[PackedVector2Array] = []
	for outline in result:
		var moved := PackedVector2Array()
		for p in outline:
			moved.append(_along_path(p, path, scale) if not path.is_empty() else origin + p.rotated(angle))
		placed_result.append(moved)
	return placed_result


## Flattens TextServer glyph contours (on-curve points and quadratic / cubic control points).
static func _contours(data: Dictionary) -> Array[PackedVector2Array]:
	var result: Array[PackedVector2Array] = []
	var points: PackedVector3Array = data.get("points", PackedVector3Array())
	var ends: PackedInt32Array = data.get("contours", PackedInt32Array())
	var start := 0
	for end in ends:
		var raw: Array[Vector3] = []
		for i in range(start, end + 1):
			raw.append(points[i])
		start = end + 1
		if raw.size() < 2:
			continue
		var outline := PackedVector2Array()
		var n := raw.size()
		# Start from an on-curve point.
		var first := 0
		for i in n:
			if int(raw[i].z) == TextServer.CONTOUR_CURVE_TAG_ON:
				first = i
				break
		var i := 0
		var current := Vector2(raw[first].x, raw[first].y)
		outline.append(current)
		while i < n:
			var a: Vector3 = raw[(first + i + 1) % n]
			var tag := int(a.z)
			if tag == TextServer.CONTOUR_CURVE_TAG_ON:
				current = Vector2(a.x, a.y)
				outline.append(current)
				i += 1
			elif tag == TextServer.CONTOUR_CURVE_TAG_OFF_CONIC:
				var b: Vector3 = raw[(first + i + 2) % n]
				var control := Vector2(a.x, a.y)
				var to := Vector2(b.x, b.y)
				var consumed := 2
				if int(b.z) == TextServer.CONTOUR_CURVE_TAG_OFF_CONIC:
					# Two conic controls in a row imply an on-curve point half way.
					to = (control + to) * 0.5
					consumed = 1
				for s in range(1, BEZIER_STEPS + 1):
					var t := float(s) / BEZIER_STEPS
					outline.append(current.lerp(control, t).lerp(control.lerp(to, t), t))
				current = to
				i += consumed
			else:
				var c1 := Vector2(a.x, a.y)
				var b2: Vector3 = raw[(first + i + 2) % n]
				var b3: Vector3 = raw[(first + i + 3) % n]
				var c2 := Vector2(b2.x, b2.y)
				var to := Vector2(b3.x, b3.y)
				for s in range(1, BEZIER_STEPS + 1):
					var t := float(s) / BEZIER_STEPS
					var u := 1.0 - t
					outline.append(current * u * u * u + c1 * 3.0 * u * u * t + c2 * 3.0 * u * t * t + to * t * t * t)
				current = to
				i += 3
		if outline.size() > 2 and outline[0].distance_to(outline[outline.size() - 1]) < 1e-9:
			outline.remove_at(outline.size() - 1)
		if outline.size() > 2:
			result.append(outline)
	return result


## Sampled points of the path curve for text on a path (empty when the text has no path).
static func _path_points(e: Dictionary, sketch: RefCounted, kernel: RefCounted) -> PackedVector2Array:
	var path_id := int(e.get("path", -1))
	if path_id < 0 or sketch == null or sketch.entity(path_id).is_empty():
		return PackedVector2Array()
	return sketch.sample(path_id, kernel, float(e.get("height", 0.01)) * 0.01)


## Bends a glyph point onto the path: x runs along the path, y stands off it.
static func _along_path(p: Vector2, path: PackedVector2Array, _scale: float) -> Vector2:
	var remaining := p.x
	for i in path.size() - 1:
		var a := path[i]
		var b := path[i + 1]
		var length := a.distance_to(b)
		if remaining <= length or i == path.size() - 2:
			var tangent := (b - a).normalized() if length > 1e-12 else Vector2.RIGHT
			var normal := Vector2(-tangent.y, tangent.x)
			return a + tangent * remaining + normal * p.y
		remaining -= length
	return path[0] + Vector2(p.x, p.y) if not path.is_empty() else p
