@tool
extends RefCounted
## Solves a sketch with the native constraint solver and writes the solved geometry back.
##
## solve() returns {"ok", "status", "dof", "conflicting": [constraint ids], "redundant": [...],
## "free": {entity id: true}, "measured": {constraint id: value}, "warnings": [String]}. Measured
## values are the driven dimensions' (an angle with rays: its sector's sweep, in [0, TAU); an arc's
## sweep angle in [0, TAU); a linear diameter: twice the distance).
##
## Dimensions the solver has no constraint for go through ones it has: an angle at a vertex
## between two points, or an arc's sweep, is the angle between two solver-only lines from the
## vertex (the arc's centre) that add no geometry to the sketch (a driving sweep also starts the
## arc's end at that sweep: the solver can't turn it far itself); a linear diameter holds half its
## value as a distance; a distance measured to a circle's or arc's curve ("edge") skips the
## mapping to its centre.

const KIND := {"point": 0, "line": 1, "circle": 2, "arc": 3, "ellipse": 4}
const ROUND := ["circle", "arc"]


## values: parameter results (name -> {"ok", "value"}). drag: {"point": id, "target": Vector2}.
static func solve(sketch: RefCounted, values: Dictionary, drag := {}) -> Dictionary:
	var result := {"ok": false, "status": 2, "dof": -1, "conflicting": [], "redundant": [], "free": {}, "measured": {}, "warnings": []}
	if not ClassDB.class_exists("CadSketchSolver"):
		result.warnings.append("The sketch solver is not loaded")
		return result
	var solver = ClassDB.instantiate("CadSketchSolver")
	var refs := {}
	var by_ref := {}
	var seeds := _sweep_seeds(sketch, values)
	for e in sketch.entities():
		if e.type == "point":
			var xy: PackedFloat64Array = seeds.get(int(e.id), PackedFloat64Array([float(e.x), float(e.y)]))
			var index: int = solver.add_point_xy(xy[0], xy[1])
			refs[int(e.id)] = Vector2i(0, index)
			if e.get("fixed", false) or e.get("projected", false):
				solver.set_point_fixed(index, true)
	var start_of := func(id: int) -> Vector2: return Vector2(seeds[id][0], seeds[id][1]) if seeds.has(id) else sketch.point(id)
	for e in sketch.entities():
		var ref := Vector2i(-1, -1)
		match str(e.type):
			"line":
				ref = Vector2i(1, solver.add_line(refs[int(e.p1)].y, refs[int(e.p2)].y))
			"circle":
				ref = Vector2i(2, solver.add_circle(refs[int(e.c)].y, float(e.r)))
			"arc":
				var c: Vector2 = start_of.call(int(e.c))
				var a0: float = (start_of.call(int(e.s)) - c).angle()
				var a1: float = (start_of.call(int(e.e)) - c).angle()
				if a1 <= a0:
					a1 += TAU
				ref = Vector2i(3, solver.add_arc(refs[int(e.c)].y, float(e.r), a0, a1, refs[int(e.s)].y, refs[int(e.e)].y))
			"ellipse":
				ref = Vector2i(4, solver.add_ellipse(refs[int(e.c)].y, refs[int(e.f)].y, float(e.minor)))
		if ref.x >= 0:
			refs[int(e.id)] = ref
			if e.get("projected", false):
				solver.set_fixed(ref, true)
	for id in refs:
		by_ref[refs[id]] = id

	var tag_to_constraint := {}
	var driven_tags := {}
	for c in sketch.constraints():
		var tags := _add(sketch, solver, refs, c, values, result.warnings)
		for tag in tags:
			tag_to_constraint[tag] = int(c.id)
			if not c.get("driving", true):
				driven_tags[int(c.id)] = tag

	var status: int
	if not drag.is_empty() and refs.has(int(drag.point)):
		solver.solve()
		status = solver.drag_point(refs[int(drag.point)].y, drag.target)
	else:
		status = solver.solve()
	result.status = status
	result.ok = status == 0 or status == 1
	result.dof = solver.get_dof()
	for tag in solver.get_conflicting():
		if tag_to_constraint.has(tag) and not result.conflicting.has(tag_to_constraint[tag]):
			result.conflicting.append(tag_to_constraint[tag])
	for tag in solver.get_redundant():
		if tag_to_constraint.has(tag) and not result.redundant.has(tag_to_constraint[tag]):
			result.redundant.append(tag_to_constraint[tag])
	for ref in solver.get_free_geometry():
		if by_ref.has(ref):
			result.free[by_ref[ref]] = true
	if not result.ok:
		return result

	var coords: PackedFloat64Array = solver.get_point_coords()
	for e in sketch.entities():
		var ref: Vector2i = refs.get(int(e.id), Vector2i(-1, -1))
		match str(e.type):
			"point":
				e["x"] = coords[ref.y * 2]
				e["y"] = coords[ref.y * 2 + 1]
			"circle":
				e["r"] = solver.get_circle_radius(ref.y)
			"arc":
				e["r"] = solver.get_arc_radius(ref.y)
			"ellipse":
				e["minor"] = solver.get_ellipse_minor_radius(ref.y)
	# Splines, conics and text follow their points; curves whose points are free are free too.
	for e in sketch.entities():
		if e.type in ["spline", "conic"]:
			for p in sketch.points_of(int(e.id)):
				if result.free.has(p):
					result.free[int(e.id)] = true
	for id in driven_tags:
		var measured: float = solver.get_constraint_value(driven_tags[id])
		var c: Dictionary = sketch.constraint(id)
		# An angle with rays measures its sector's sweep (the solver may settle on an equal angle).
		if c.get("type", "") == "angle" and (c.has("rays") or (c.refs as Array).size() == 1):
			measured = fposmod(measured + (PI if _rays_mixed(c) else 0.0), TAU)
		elif c.get("linear_diameter", false):
			measured *= 2.0
		result.measured[id] = measured
	return result


## Adds one sketch constraint to the solver; returns its solver tags (several for compound ones).
static func _add(sketch: RefCounted, solver, refs: Dictionary, c: Dictionary, values: Dictionary, warnings: Array) -> Array[int]:
	var tags: Array[int] = []
	var ids: Array = c.refs
	for id in ids:
		if not refs.has(int(id)) and not str(sketch.entity(int(id)).get("type", "")) in ["spline", "conic", "text"]:
			warnings.append("Constraint %d refers to missing geometry" % c.id)
			return tags
	var type := str(c.type)
	var value := 0.0
	if c.has("key") and c.get("driving", true):
		var input: Dictionary = sketch.feature.inputs.get(c.key, {}) if sketch.feature != null else {}
		var evaluated: Dictionary = values.get(str(input.get("name", "")), {})
		if not evaluated.get("ok", false):
			warnings.append("Dimension %s: %s" % [input.get("name", c.key), evaluated.get("error", "not evaluated")])
			return tags
		value = float(evaluated.value)
	var types: Array = ids.map(func(id) -> String: return str(sketch.entity(int(id)).get("type", "")))
	var mapped: Array = ids.map(func(id) -> Vector2i: return refs.get(int(id), Vector2i(-1, -1)))
	match type:
		"fix":
			for ref in mapped:
				if (ref as Vector2i).x >= 0:
					solver.set_fixed(ref, true)
			return tags
		"curvature":
			type = "tangent"
		"coincident":
			if types.size() == 2 and (types[0] != "point" or types[1] != "point"):
				# A point on a curve.
				if types[0] != "point":
					mapped.reverse()
				type = "point_on"
		"symmetric":
			if types.size() == 3 and types[0] != "point":
				return _symmetric_curves(sketch, solver, refs, ids, types)
		"distance", "distance_x", "distance_y":
			# Circles and arcs are measured from their centers, unless flagged to their curves.
			var edge: Variant = c.get("edge", [])
			for i in mapped.size():
				var to_curve: bool = edge is Array and i < (edge as Array).size() and bool(edge[i])
				if types[i] in ROUND and not to_curve:
					mapped[i] = refs[int(sketch.entity(int(ids[i])).c)]
					types[i] = "point"
			if c.get("linear_diameter", false):
				value *= 0.5
		"angle":
			# A vertex between two points [vertex, a, b], or an arc's sweep: the angle between
			# solver-only lines from the vertex.
			var spokes := []
			if types == ["point", "point", "point"]:
				spokes = [[ids[0], ids[1]], [ids[0], ids[2]]]
			elif types == ["arc"]:
				var arc: Dictionary = sketch.entity(int(ids[0]))
				spokes = [[arc.c, arc.s], [arc.c, arc.e]]
			if not spokes.is_empty():
				mapped = spokes.map(func(pair: Array) -> Vector2i: return Vector2i(1, solver.add_line(refs[int(pair[0])].y, refs[int(pair[1])].y)))
			# The value is the sweep between the rays; with one ray against its line's direction the
			# lines' own directions are the sweep minus PI apart. Angles without rays (older
			# documents) go to the solver as they always did.
			if c.get("driving", true) and _rays_mixed(c):
				value -= PI
	if mapped.any(func(ref: Vector2i) -> bool: return ref.x < 0):
		warnings.append("Constraint %d (%s) is not supported on splines, conics or text yet" % [c.id, type])
		return tags
	var tag: int = solver.add_constraint(type, mapped, value, bool(c.get("driving", true)))
	if tag < 0:
		warnings.append("Constraint %d (%s) does not apply to its geometry" % [c.id, type])
	else:
		tags.append(tag)
	return tags


## Where the solver starts the ends of arcs whose sweep a driving angle sets: turned about the
## centre to that sweep (the solver can't turn an arc's end far by itself). point id -> [x, y].
static func _sweep_seeds(sketch: RefCounted, values: Dictionary) -> Dictionary:
	var seeds := {}
	for c in sketch.constraints():
		if c.get("type", "") != "angle" or (c.refs as Array).size() != 1 or not c.get("driving", true) or not c.has("key"):
			continue
		var arc: Dictionary = sketch.entity(int(c.refs[0]))
		var input: Dictionary = sketch.feature.inputs.get(c.key, {}) if sketch.feature != null else {}
		var evaluated: Dictionary = values.get(str(input.get("name", "")), {})
		var end_point: Dictionary = sketch.entity(int(arc.get("e", -1)))
		if arc.get("type", "") != "arc" or not evaluated.get("ok", false) or end_point.get("fixed", false) or end_point.get("projected", false):
			continue
		var center: PackedFloat64Array = sketch.point_xy(int(arc.c))
		var start: PackedFloat64Array = sketch.point_xy(int(arc.s))
		var end: PackedFloat64Array = sketch.point_xy(int(arc.e))
		var r := sqrt(pow(end[0] - center[0], 2) + pow(end[1] - center[1], 2))
		var angle := atan2(start[1] - center[1], start[0] - center[0]) + float(evaluated.value)
		seeds[int(arc.e)] = PackedFloat64Array([center[0] + r * cos(angle), center[1] + r * sin(angle)])
	return seeds


## True for an angle whose two rays don't both run along their lines' p1->p2 directions.
static func _rays_mixed(c: Dictionary) -> bool:
	var rays: Variant = c.get("rays", [])
	return rays is Array and (rays as Array).size() == 2 and (float(rays[0]) >= 0.0) != (float(rays[1]) >= 0.0)


## Symmetry of two lines or two circles/arcs about a line: their points mirror pairwise.
static func _symmetric_curves(sketch: RefCounted, solver, refs: Dictionary, ids: Array, types: Array) -> Array[int]:
	var tags: Array[int] = []
	var axis: Vector2i = refs[int(ids[2])]
	var a: Dictionary = sketch.entity(int(ids[0]))
	var b: Dictionary = sketch.entity(int(ids[1]))
	var pairs := []
	if types[0] == "line" and types[1] == "line":
		# Pair the ends that are closer after mirroring.
		var direct: float = sketch.point(int(a.p1)).distance_to(sketch.point(int(b.p1))) + sketch.point(int(a.p2)).distance_to(sketch.point(int(b.p2)))
		var crossed: float = sketch.point(int(a.p1)).distance_to(sketch.point(int(b.p2))) + sketch.point(int(a.p2)).distance_to(sketch.point(int(b.p1)))
		pairs = [[a.p1, b.p1], [a.p2, b.p2]] if direct <= crossed else [[a.p1, b.p2], [a.p2, b.p1]]
	elif types[0] in ROUND and types[1] in ROUND:
		pairs = [[a.c, b.c]]
		var equal: int = solver.add_constraint("equal", [refs[int(ids[0])], refs[int(ids[1])]], 0.0, true)
		if equal >= 0:
			tags.append(equal)
	for pair in pairs:
		var tag: int = solver.add_constraint("symmetric", [refs[int(pair[0])], refs[int(pair[1])], axis], 0.0, true)
		if tag >= 0:
			tags.append(tag)
	return tags
