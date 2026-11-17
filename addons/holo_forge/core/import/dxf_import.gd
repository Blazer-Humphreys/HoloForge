@tool
extends RefCounted
## Insert DXF: an ASCII DXF drawing as sketches of fixed curves.
##
## Entities: LINE, ARC, CIRCLE, LWPOLYLINE (bulges become arcs), POLYLINE/VERTEX, SPLINE
## (control points with their knots and weights, or fit points), ELLIPSE (whole or partial),
## POINT, TEXT and MTEXT (sketch text), and INSERT (block references, nested, scaled and turned,
## and arrays of them: columns and rows). Drawing units come from $INSUNITS (unitless drawings are
## read as millimeters). Entities whose extrusion points down (-Z, mirrored arcs) are handled;
## paper-space entities, 3D meshes, hatches and dimensions are skipped with a warning. A drawing
## far from its own origin (site plans, sheet layouts) is moved to the sketch origin first and the
## sketch's plane origin moved there instead, so its curves keep their precision (sketch points
## are single-precision) and still land where the drawing puts them. Block contents aren't
## measured for this: only the drawing's own entities and insertion points.

const FEATURE := preload("res://addons/holo_forge/core/feature.gd")
const SKETCH_DATA := preload("res://addons/holo_forge/core/sketch/sketch_data.gd")
const SVG_IMPORT := preload("res://addons/holo_forge/core/import/svg_import.gd")

## $INSUNITS code -> meters per drawing unit (0, unitless, reads as millimeters). 21-24 are the
## US survey foot, inch, yard and mile (a survey foot is 1200/3937 m).
const INSUNITS := {0: 0.001, 1: 0.0254, 2: 0.3048, 3: 1609.344, 4: 0.001, 5: 0.01, 6: 1.0, 7: 1000.0, 8: 2.54e-8,
	9: 2.54e-5, 10: 0.9144, 11: 1e-10, 12: 1e-9, 13: 1e-6, 14: 0.1, 15: 10.0, 16: 100.0, 17: 1e9, 18: 1.495978707e11,
	19: 9.4607304725808e15, 20: 3.0856775814914e16, 21: 1200.0 / 3937.0, 22: 100.0 / 3937.0, 23: 3600.0 / 3937.0,
	24: 6336000.0 / 3937.0}
const UNIT_METERS := {"mm": 0.001, "cm": 0.01, "m": 1.0, "in": 0.0254, "ft": 0.3048}
const MAX_DEPTH := 16
## Copies one arrayed INSERT may make (columns x rows); more are cut, with a warning.
const MAX_ARRAY_COPIES := 10000
## Radians: an ELLIPSE whose parameters span a whole turn within this is a whole ellipse (writers
## print 2 pi with 5 to 7 decimals: 6.283185 misses it by 3e-7).
const WHOLE_TURN := 1e-5
## Meters: a drawing reaching farther than this from its origin is moved to the sketch origin
## (single-precision sketch points step about 1e-7 m at 1 m, the size of the end-merge distance).
const FAR := 1.0
## Entity types that carry nothing to draw on their own (or are read with their owner).
const QUIET := ["VERTEX", "SEQEND", "ATTRIB", "ATTDEF", "VIEWPORT", "BLOCK", "ENDBLK"]
## The point groups (x codes; y is code + 10) of each entity type that draws, in model space.
## Vectors (an ELLIPSE's axis, an MTEXT's direction, SPLINE tangents) aren't points.
const POINT_CODES := {"LINE": [10, 11], "CIRCLE": [10], "ARC": [10], "LWPOLYLINE": [10], "VERTEX": [10],
	"SPLINE": [10, 11], "ELLIPSE": [10], "POINT": [10], "TEXT": [10, 11], "MTEXT": [10], "INSERT": [10]}
## Types whose points are object coordinates: an extrusion pointing down mirrors their x.
const OCS_TYPES := ["CIRCLE", "ARC", "LWPOLYLINE", "TEXT", "INSERT"]


## Reads the drawing: {"units": meters per drawing unit, "entities": [entity], "blocks": {name:
## {"base": Vector2, "entities": [...]}}, "layers": PackedStringArray, "error": "", "unit_note":
## "" or why the units were guessed}.
## An entity is {"type", "layer", "codes": [[group code, value String (or a float once moved)], ...]}.
static func parse(dxf_text: String) -> Dictionary:
	var result := {"units": 0.001, "entities": [], "blocks": {}, "layers": PackedStringArray(), "error": "", "unit_note": ""}
	if dxf_text.begins_with("AutoCAD Binary DXF"):
		result.error = "Binary DXF isn't supported; save the drawing as ASCII DXF"
		return result
	var lines := dxf_text.split("\n")
	var section := ""
	var variable := ""
	var current := {}
	var block := {}
	var layers := {}
	var i := 0
	while i + 1 < lines.size():
		var code_text := lines[i].strip_edges()
		var value := lines[i + 1].strip_edges()
		i += 2
		if not code_text.is_valid_int():
			result.error = "This isn't an ASCII DXF file (line %d)" % (i - 1)
			return result
		var code := code_text.to_int()
		if code == 0:
			# A new entity (or section marker) closes the one being read.
			if not current.is_empty():
				if current.type == "BLOCK":
					block = {"name": _text(current.codes, 2, ""), "base": _point(current.codes, 10), "entities": []}
				elif not block.is_empty():
					(block.entities as Array).append(current)
				else:
					(result.entities as Array).append(current)
				current = {}
			match value:
				"SECTION":
					section = "?"
				"ENDSEC":
					section = ""
				"EOF":
					break
				"ENDBLK":
					if not block.is_empty():
						result.blocks[block.name] = block
					block = {}
				_:
					if section in ["ENTITIES", "BLOCKS"]:
						current = {"type": value, "layer": "0", "codes": []}
			continue
		if section == "?":
			section = value if code == 2 else ""
			continue
		if section == "HEADER":
			if code == 9:
				variable = value
			elif variable == "$INSUNITS" and code == 70:
				if value.is_valid_int() and INSUNITS.has(value.to_int()):
					result.units = float(INSUNITS[value.to_int()])
					result.unit_note = ""
				else:
					result.units = 0.001
					result.unit_note = "The drawing's unit code %s isn't known, so it was read in millimeters" % value
			continue
		if current.is_empty():
			continue
		if code == 8:
			current.layer = value
			if current.type != "BLOCK":
				layers[value] = true
		(current.codes as Array).append([code, value])
	if not current.is_empty() and block.is_empty():
		(result.entities as Array).append(current)
	var names := PackedStringArray(layers.keys())
	names.sort()
	result.layers = names
	return result


## The layers that hold entities (for a layer picker).
static func layers(dxf_text: String) -> PackedStringArray:
	return parse(dxf_text).layers


## Adds the drawing as sketches on frame ({"origin", "x", "y"}). options: "layers" (Array of layer
## names to import; empty = all), "one_sketch_per_layer" (bool), "scale" (meters per drawing
## unit) or "units" (mm, cm, m, in, ft) to override $INSUNITS, "origin" (Vector2 offset in
## meters, sketch coordinates). Returns {"feature": the first sketch (null when nothing was
## drawn), "features": every sketch made, "curves": count, "warnings": Array[String],
## "layers": PackedStringArray of every layer in the drawing}. A drawing reaching more than FAR
## from its origin, and lying well away from it (its middle farther out than its size), is drawn
## about its middle, on a frame whose origin moved to that middle (the curves land in the same
## place; a warning says so).
static func to_sketch(dxf_text: String, doc: Resource, frame: Dictionary, plane_ref: String, options := {}) -> Dictionary:
	var drawing := parse(dxf_text)
	var warnings: Array[String] = []
	if drawing.error != "":
		warnings.append(drawing.error)
		return {"feature": null, "features": [], "curves": 0, "warnings": warnings, "layers": drawing.layers}
	var unit := float(drawing.units)
	if options.has("scale"):
		unit = float(options.scale)
	elif UNIT_METERS.has(str(options.get("units", ""))):
		unit = float(UNIT_METERS[str(options.units)])
	elif str(drawing.unit_note) != "":
		warnings.append(str(drawing.unit_note))
	var offset: Vector2 = options.get("origin", Vector2.ZERO)
	# Far from its origin: move the drawing to the sketch origin (in double precision, before any
	# single-precision point is made) and the frame's origin to where the drawing's middle was.
	var bounds := _model_points(drawing.entities)
	if bounds.size() == 4:
		var farthest := maxf(maxf(absf(bounds[0]), absf(bounds[2])), maxf(absf(bounds[1]), absf(bounds[3])))
		var half_size := maxf(bounds[2] - bounds[0], bounds[3] - bounds[1]) * 0.5
		var reach := farthest * absf(unit)
		# Only when the move pays: a big drawing that starts at its origin stays as it is.
		if reach > FAR and half_size * 2.0 < farthest:
			var middle := PackedFloat64Array([(bounds[0] + bounds[2]) * 0.5, (bounds[1] + bounds[3]) * 0.5])
			_model_points(drawing.entities, middle)
			frame = frame.duplicate(true)
			frame["origin"] = (frame.origin as Vector3) + (frame.x as Vector3) * (middle[0] * unit) + (frame.y as Vector3) * (middle[1] * unit)
			warnings.append("The drawing lies %.1f m from its origin, so its sketch's origin was moved to the drawing's middle to keep the curves precise" % reach)
	var state := {
		"frame": frame, "plane_ref": plane_ref, "doc": doc, "writers": {}, "order": [], "blocks": drawing.blocks,
		"filter": options.get("layers", []), "per_layer": bool(options.get("one_sketch_per_layer", false)), "skipped": {},
		"notes": [],
	}
	_emit(drawing.entities, Transform2D(Vector2(unit, 0.0), Vector2(0.0, unit), offset), unit, "", 0, state)
	for note in state.notes:
		if not warnings.has(note):
			warnings.append(note)
	var features := []
	var curves := 0
	for key in state.order:
		var entry: Dictionary = state.writers[key]
		var writer: SVG_IMPORT.Writer = entry.writer
		for w in writer.warnings:
			if not warnings.has(w):
				warnings.append(w)
		# Only what was drawn on purpose counts (a curve dropped as degenerate leaves nothing).
		if writer.curves == 0 and writer.points == 0:
			continue
		var feature: Resource = doc.add_feature("sketch", "Sketch", {}, (entry.holder as Resource).options)
		if state.per_layer:
			feature.options["layer"] = key
		features.append(feature)
		curves += writer.curves
	var skipped: Dictionary = state.skipped
	if not skipped.is_empty():
		var parts := PackedStringArray()
		for type in skipped:
			parts.append("%d %s" % [skipped[type], type])
		warnings.append("Skipped entities: %s" % ", ".join(parts))
	if features.is_empty():
		warnings.append("The DXF has nothing to import%s" % (" on the chosen layers" if not (state.filter as Array).is_empty() else ""))
	return {"feature": features[0] if not features.is_empty() else null, "features": features, "curves": curves, "warnings": warnings, "layers": drawing.layers}


## The writer (and its sketch) an entity on layer goes to.
static func _writer(state: Dictionary, layer: String) -> SVG_IMPORT.Writer:
	var key := layer if state.per_layer else ""
	if not state.writers.has(key):
		var holder: Resource = FEATURE.new()
		holder.options = SKETCH_DATA.new_options(state.frame, state.plane_ref)
		state.writers[key] = {"holder": holder, "writer": SVG_IMPORT.Writer.new(SKETCH_DATA.new(holder, state.doc))}
		(state.order as Array).append(key)
	return state.writers[key].writer


## Draws a list of entities through m (drawing units -> sketch meters); unit is m's length scale.
## Entities on layer "0" inside a block take the inserting entity's layer.
static func _emit(entities: Array, m: Transform2D, unit: float, inherit: String, depth: int, state: Dictionary) -> void:
	var i := 0
	while i < entities.size():
		var e: Dictionary = entities[i]
		i += 1
		var type := str(e.type)
		var codes: Array = e.codes
		var layer := inherit if inherit != "" and e.layer == "0" else str(e.layer)
		var vertices := []
		if type == "POLYLINE":
			# Its VERTEX entities follow it, up to SEQEND.
			while i < entities.size() and str(entities[i].type) == "VERTEX":
				vertices.append(entities[i])
				i += 1
		if type in QUIET:
			continue
		if _number(codes, 67, 0.0) == 1.0:
			continue
		if not (state.filter as Array).is_empty() and not (state.filter as Array).has(layer) and type != "INSERT":
			continue
		# Object coordinates: an extrusion pointing down mirrors x.
		var normal := Vector3(_number(codes, 210, 0.0), _number(codes, 220, 0.0), _number(codes, 230, 1.0))
		var ocs := m * Transform2D(Vector2(-1.0, 0.0), Vector2(0.0, 1.0), Vector2.ZERO) if normal.z < 0.0 else m
		match type:
			"LINE":
				_writer(state, layer).chain([_line(m, _point(codes, 10), _point(codes, 11))])
			"CIRCLE":
				var r := _number(codes, 40, 0.0)
				if r > 0.0:
					_writer(state, layer).ellipse(ocs * _point(codes, 10), ocs.basis_xform(Vector2(r, 0.0)), ocs.basis_xform(Vector2(0.0, r)))
			"ARC":
				var c := _point(codes, 10)
				var r := _number(codes, 40, 0.0)
				var a0 := deg_to_rad(_number(codes, 50, 0.0))
				var a1 := deg_to_rad(_number(codes, 51, 360.0))
				while a1 <= a0:
					a1 += TAU
				if r > 0.0:
					_writer(state, layer).chain([_arc(ocs, c, Vector2(r, 0.0), Vector2(0.0, r), a0, a1)])
			"LWPOLYLINE":
				# Each vertex is 10 (x), 20 (y) and an optional 42 (bulge), in order.
				var points := []
				for pair in codes:
					var code := int(pair[0])
					if code == 10:
						points.append({"p": Vector2(float(pair[1]), 0.0), "bulge": 0.0})
					elif (code == 20 or code == 42) and not points.is_empty():
						var last: Dictionary = points[points.size() - 1]
						if code == 20:
							last.p = Vector2((last.p as Vector2).x, float(pair[1]))
						else:
							last.bulge = float(pair[1])
				_polyline(_writer(state, layer), ocs, points, int(_number(codes, 70, 0.0)) & 1 == 1)
			"POLYLINE":
				var flags := int(_number(codes, 70, 0.0))
				if flags & (16 | 64) != 0:
					_skip(state, "3D mesh")
					continue
				var points := []
				for v in vertices:
					var vflags := int(_number(v.codes, 70, 0.0))
					if vflags & 16 != 0:
						continue  # a spline frame's control point, not on the curve
					points.append({"p": _point(v.codes, 10), "bulge": _number(v.codes, 42, 0.0)})
				_polyline(_writer(state, layer), m if flags & 8 != 0 else ocs, points, flags & 1 == 1)
			"SPLINE":
				_spline(_writer(state, layer), m, codes)
			"ELLIPSE":
				var c := _point(codes, 10)
				var u := _point(codes, 11)
				var ratio := _number(codes, 40, 1.0)
				var v := Vector2(-u.y, u.x) * ratio if normal.z >= 0.0 else Vector2(u.y, -u.x) * ratio
				var t0 := _number(codes, 41, 0.0)
				var t1 := _number(codes, 42, TAU)
				var writer := _writer(state, layer)
				if absf(t1 - t0) < 1e-12 or absf(absf(t1 - t0) - TAU) < WHOLE_TURN:
					writer.ellipse(m * c, m.basis_xform(u), m.basis_xform(v))
				else:
					while t1 <= t0:
						t1 += TAU
					writer.chain([_arc(m, c, u, v, t0, t1)])
			"POINT":
				_writer(state, layer).point(m * _point(codes, 10))
			"TEXT", "MTEXT":
				_text_entity(_writer(state, layer), ocs if type == "TEXT" else m, unit, type, codes)
			"INSERT":
				var block: Dictionary = state.blocks.get(_text(codes, 2, ""), {})
				if block.is_empty() or depth >= MAX_DEPTH:
					_skip(state, "INSERT of a missing block" if block.is_empty() else "INSERT nested too deep")
					continue
				var scale := Vector2(_number(codes, 41, 1.0), _number(codes, 42, 1.0))
				var turn := deg_to_rad(_number(codes, 50, 0.0))
				var factor := sqrt(absf(scale.x * scale.y))
				# An arrayed INSERT (MINSERT): columns along the insert's turned x, rows along its y,
				# spaced in drawing units (not scaled with the block).
				var columns := maxi(1, int(_number(codes, 70, 1.0)))
				var rows := maxi(1, int(_number(codes, 71, 1.0)))
				var spacing := Vector2(_number(codes, 44, 0.0), _number(codes, 45, 0.0))
				if columns * rows > MAX_ARRAY_COPIES:
					(state.notes as Array).append("A block array of %d x %d copies was cut to %d copies" % [columns, rows, MAX_ARRAY_COPIES])
					columns = mini(columns, MAX_ARRAY_COPIES)
					rows = maxi(1, floori(float(MAX_ARRAY_COPIES) / columns))
				for row in rows:
					for column in columns:
						var at := _point(codes, 10) + Vector2(spacing.x * column, spacing.y * row).rotated(turn)
						var place := Transform2D(turn, scale, 0.0, at) * Transform2D(0.0, -(block.base as Vector2))
						_emit(block.entities, ocs * place, unit * factor, layer, depth + 1, state)
			_:
				_skip(state, type)


static func _skip(state: Dictionary, what: String) -> void:
	state.skipped[what] = int(state.skipped.get(what, 0)) + 1


# --- Entities --------------------------------------------------------------------------------

static func _line(m: Transform2D, a: Vector2, b: Vector2) -> Dictionary:
	return {"type": "line", "a": m * a, "b": m * b}


## An arc (or elliptical arc) c + u cos t + v sin t from t0 to t1, mapped through m.
static func _arc(m: Transform2D, c: Vector2, u: Vector2, v: Vector2, t0: float, t1: float) -> Dictionary:
	var a := c + u * cos(t0) + v * sin(t0)
	var b := c + u * cos(t1) + v * sin(t1)
	return {"type": "arc", "c": m * c, "u": m.basis_xform(u), "v": m.basis_xform(v), "t0": t0, "t1": t1, "a": m * a, "b": m * b}


## Polyline vertices [{"p", "bulge"}]: a straight segment, or an arc when the bulge (the tangent
## of a quarter of the arc's angle, positive counter-clockwise) isn't zero.
static func _polyline(writer: SVG_IMPORT.Writer, m: Transform2D, points: Array, closed: bool) -> void:
	var segments := []
	var count := points.size()
	# A closed two-vertex polyline closes only with a bulge (two bulges of 1 draw a circle);
	# a straight closing segment would lie on its first one.
	var closing := closed and (count > 2 or (count == 2 and absf(float(points[1].bulge)) >= 1e-12))
	for k in range(count - 1 + (1 if closing else 0)):
		var p1: Vector2 = points[k].p
		var p2: Vector2 = points[(k + 1) % count].p
		var bulge := float(points[k].bulge)
		var chord := p2 - p1
		var d := chord.length()
		if d <= 0.0:
			continue
		if absf(bulge) < 1e-12:
			segments.append(_line(m, p1, p2))
			continue
		var theta := 4.0 * atan(bulge)
		var r := d / (2.0 * absf(sin(theta * 0.5)))
		var left := Vector2(-chord.y, chord.x) / d
		var c := (p1 + p2) * 0.5 + left * (d * 0.5) * (1.0 - bulge * bulge) / (2.0 * bulge)
		var t0 := (p1 - c).angle()
		var seg := _arc(m, c, Vector2(r, 0.0), Vector2(0.0, r), t0, t0 + theta)
		# The polyline's own vertices are the arc's ends.
		seg.a = m * p1
		seg.b = m * p2
		segments.append(seg)
	writer.chain(segments)


static func _spline(writer: SVG_IMPORT.Writer, m: Transform2D, codes: Array) -> void:
	var degree := int(_number(codes, 71, 3.0))
	var flags := int(_number(codes, 70, 0.0))
	var knots := PackedFloat64Array()
	var weights := PackedFloat64Array()
	# Control points (10/20) and fit points (11/21) come as x then y, one point after another.
	var pole_x := PackedFloat64Array()
	var pole_y := PackedFloat64Array()
	var fit_x := PackedFloat64Array()
	var fit_y := PackedFloat64Array()
	for pair in codes:
		match int(pair[0]):
			40:
				knots.append(float(pair[1]))
			41:
				weights.append(float(pair[1]))
			10:
				pole_x.append(float(pair[1]))
			20:
				pole_y.append(float(pair[1]))
			11:
				fit_x.append(float(pair[1]))
			21:
				fit_y.append(float(pair[1]))
	var poles := PackedVector2Array()
	for k in mini(pole_x.size(), pole_y.size()):
		poles.append(m * Vector2(pole_x[k], pole_y[k]))
	var fits := PackedVector2Array()
	for k in mini(fit_x.size(), fit_y.size()):
		fits.append(m * Vector2(fit_x[k], fit_y[k]))
	if poles.size() >= 2:
		var runs := knot_runs(knots, poles.size(), degree)
		if runs.is_empty() and not knots.is_empty():
			writer.warn("A spline's knots didn't fit its control points; it was read as a uniform spline")
		var rational := weights.size() == poles.size() and Array(weights).any(func(w: float) -> bool: return absf(w - 1.0) > 1e-12)
		writer.spline(poles, degree, runs.get("knots", PackedFloat64Array()), runs.get("mults", PackedInt32Array()), weights if rational else PackedFloat64Array())
	elif fits.size() >= 2:
		var closed := flags & 1 == 1
		if closed and fits[0].distance_to(fits[fits.size() - 1]) < 1e-12:
			fits.remove_at(fits.size() - 1)
		writer.fit_spline(fits, closed)


## A DXF knot vector (every knot repeated) as distinct knots and multiplicities, or {} when it
## doesn't match the control points (count + degree + 1 knots, end multiplicity <= degree + 1).
static func knot_runs(flat: PackedFloat64Array, pole_count: int, degree: int) -> Dictionary:
	if flat.size() != pole_count + degree + 1:
		return {}
	var span := maxf(absf(flat[flat.size() - 1] - flat[0]), 1e-12)
	var knots := PackedFloat64Array()
	var mults := PackedInt32Array()
	for k in flat:
		if not knots.is_empty() and absf(k - knots[knots.size() - 1]) <= span * 1e-10:
			mults[mults.size() - 1] += 1
		elif not knots.is_empty() and k < knots[knots.size() - 1]:
			return {}
		else:
			knots.append(k)
			mults.append(1)
	if knots.size() < 2 or mults[0] > degree + 1 or mults[mults.size() - 1] > degree + 1:
		return {}
	for k in range(1, mults.size() - 1):
		if mults[k] > degree:
			return {}
	return {"knots": knots, "mults": mults}


static func _text_entity(writer: SVG_IMPORT.Writer, m: Transform2D, unit: float, type: String, codes: Array) -> void:
	var value := ""
	var angle := deg_to_rad(_number(codes, 50, 0.0))
	if type == "MTEXT":
		for pair in codes:
			if int(pair[0]) == 3:
				value += str(pair[1])
		value += _text(codes, 1, "")
		value = _plain_mtext(value)
		var direction := _point(codes, 11)
		if direction.length() > 1e-12 and not _has(codes, 50):
			angle = direction.angle()
	else:
		value = _plain_text(_text(codes, 1, ""))
	var height := _number(codes, 40, 2.5)
	var at := _point(codes, 10)
	if type == "MTEXT" and int(_number(codes, 71, 1.0)) <= 3:
		# Attached at its top: drop to the first line's baseline.
		at += Vector2(sin(angle), -cos(angle)) * height
	writer.text(value, m * at, height * unit, angle + m.get_rotation())


## TEXT control codes: %%c, %%d and %%p symbols; underline/overline toggles dropped.
static func _plain_text(value: String) -> String:
	return value.replace("%%c", "Ø").replace("%%C", "Ø").replace("%%d", "°").replace("%%D", "°") \
		.replace("%%p", "±").replace("%%P", "±").replace("%%u", "").replace("%%U", "").replace("%%o", "").replace("%%O", "") \
		.replace("%%%", "%")


## MTEXT without its formatting codes; paragraphs become spaces (sketch text is one line).
static func _plain_mtext(value: String) -> String:
	var s := value.replace("\\P", " ").replace("\\~", " ")
	s = RegEx.create_from_string("\\\\[ACcFfHhQTWpL][^;\\\\]*;").sub(s, "", true)
	s = RegEx.create_from_string("\\\\[LlOoKk]").sub(s, "", true)
	s = s.replace("{", "").replace("}", "")
	return _plain_text(s).strip_edges()


# --- Group codes -----------------------------------------------------------------------------

static func _has(codes: Array, code: int) -> bool:
	for pair in codes:
		if int(pair[0]) == code:
			return true
	return false


static func _number(codes: Array, code: int, fallback: float) -> float:
	for pair in codes:
		if int(pair[0]) == code:
			return _value(pair[1])
	return fallback


## A group code's value as a number: the text read from the file, or a number written back.
static func _value(value: Variant) -> float:
	return float(value) if value is float else str(value).to_float()


## Walks the model-space points of entities (see POINT_CODES) and returns their bounds [min x,
## min y, max x, max y] in drawing units ([] when there are none). With shift ([x, y]) each point
## first moves by -shift, in double precision, written back into its codes as a number. Mirrored
## object coordinates (extrusion down) measure and move with their x turned round.
static func _model_points(entities: Array, shift := PackedFloat64Array()) -> PackedFloat64Array:
	var bounds := PackedFloat64Array()
	var mirror_vertices := false
	for e in entities:
		var type := str(e.type)
		var codes: Array = e.codes
		if type == "POLYLINE":
			# Its VERTEX entities follow it: object coordinates unless it is a 3D polyline.
			mirror_vertices = _number(codes, 230, 1.0) < 0.0 and int(_number(codes, 70, 0.0)) & 8 == 0
			continue
		if not POINT_CODES.has(type) or _number(codes, 67, 0.0) == 1.0:
			continue
		var mirrored := mirror_vertices if type == "VERTEX" else (type in OCS_TYPES and _number(codes, 230, 1.0) < 0.0)
		var flip := -1.0 if mirrored else 1.0
		var xs: Array = POINT_CODES[type]
		var x := NAN
		for pair in codes:
			var code := int(pair[0])
			if xs.has(code):
				x = _value(pair[1]) * flip
				if not shift.is_empty():
					pair[1] = (x - shift[0]) * flip
			elif xs.has(code - 10) and not is_nan(x):
				var y := _value(pair[1])
				if not shift.is_empty():
					pair[1] = y - shift[1]
				if bounds.is_empty():
					bounds = PackedFloat64Array([x, y, x, y])
				else:
					bounds[0] = minf(bounds[0], x)
					bounds[1] = minf(bounds[1], y)
					bounds[2] = maxf(bounds[2], x)
					bounds[3] = maxf(bounds[3], y)
				x = NAN
	return bounds


static func _text(codes: Array, code: int, fallback: String) -> String:
	for pair in codes:
		if int(pair[0]) == code:
			return str(pair[1])
	return fallback


## The point in group codes code (x) and code + 10 (y).
static func _point(codes: Array, code: int) -> Vector2:
	return Vector2(_number(codes, code, 0.0), _number(codes, code + 10, 0.0))
