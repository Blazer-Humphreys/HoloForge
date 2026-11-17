@tool
extends RefCounted
## A view over a sketch feature's options: entities, constraints and the sketch plane.
##
## Coordinates are plane coordinates in meters (u along the plane's X, v along its Y), stored as
## separate floats so they keep double precision. Entity dictionaries:
##   point   {id, type, x, y, fixed, origin?}
##   line    {id, type, p1, p2, construction, centerline}
##   circle  {id, type, c, r, construction}
##   arc     {id, type, c, s, e, r, construction}            counter-clockwise from s to e
##   ellipse {id, type, c, f, minor, construction}             center, focus, minor radius
##   spline  {id, type, points, mode: "fit"|"control", closed, construction}
##   conic   {id, type, s, e, shoulder, rho, construction}
##   text    {id, type, text, height, x, y, angle, font, bold, italic, path, construction}
##   ref3d   {id, type, polylines (world PackedVector3Array list), source}
## Constraints: {id, type, refs: [entity ids], key: "dim<id>" (dimensions), driving, offset}.
## Dimension values are the feature's inputs (model parameters), keyed by the constraint's key.
## A dimension's text sits at offset from the middle of what it measures (plane meters). An angle
## may carry rays [s0, s1] (+1 along a ref's p1->p2, -1 against it; refs counter-clockwise): its
## value is then the positive sweep from the first ray to the second, and it is drawn as that
## sector; without rays (older documents) the solver gets the value between the refs' own
## directions as before, and it is drawn as the sector that holds its text. An angle's refs may
## also be three points [vertex, a, b] (the angle at the vertex, with rays) or one arc (its sweep).
## Other optional dimension fields: param_name (a driven dimension that was driving: the name it
## gets back when made driving again), edge ([bool per ref] on a distance: measured to a circle's
## or arc's curve, not its centre) and linear_diameter (a distance from a centerline shown and held
## as twice the distance). Every other field is optional too: absent means the behaviour from
## before the field existed.

const PARAMETERS := preload("res://addons/holo_forge/core/parameters.gd")
const DIMENSIONS := ["distance", "distance_x", "distance_y", "radius", "diameter", "angle", "arc_length", "length"]
const CURVES := ["line", "circle", "arc", "ellipse", "spline", "conic", "text"]

## Origin planes in Godot space (Y up): X along the plane's U axis, Y along its V axis.
const ORIGIN_PLANES := {
	"xy": {"origin": Vector3.ZERO, "x": Vector3.RIGHT, "y": Vector3.UP},
	"xz": {"origin": Vector3.ZERO, "x": Vector3.RIGHT, "y": Vector3.FORWARD},
	"yz": {"origin": Vector3.ZERO, "x": Vector3.FORWARD, "y": Vector3.UP},
}

var feature: Resource
var options: Dictionary
var doc: Resource
## id -> index in options.entities / options.constraints, checked on every use and rebuilt when it
## no longer matches (entities added or removed, or the array replaced), so lookups don't scan the
## whole sketch (a large imported drawing made solving quadratic).
var _entity_at := {}
var _constraint_at := {}


func _init(p_feature: Resource = null, p_doc: Resource = null) -> void:
	feature = p_feature
	doc = p_doc
	options = p_feature.options if p_feature != null else {}
	if not options.has("entities"):
		options["entities"] = []
	if not options.has("constraints"):
		options["constraints"] = []
	if not options.has("next_id"):
		options["next_id"] = 1


## New sketch options on a plane frame, with the fixed sketch origin point.
static func new_options(plane: Dictionary, plane_ref: String) -> Dictionary:
	var result := {"plane": plane.duplicate(true), "plane_ref": plane_ref, "entities": [], "constraints": [], "next_id": 2, "visible": true}
	result.entities.append({"id": 1, "type": "point", "x": 0.0, "y": 0.0, "fixed": true, "origin": true})
	return result


## The plane frame for a planar face: world origin projected onto it, axes kept close to world axes.
static func face_plane(point: Vector3, normal: Vector3) -> Dictionary:
	var n := normal.normalized()
	var origin := Vector3.ZERO - n * (Vector3.ZERO - point).dot(n)
	var candidates := [Vector3.RIGHT, Vector3.FORWARD, Vector3.UP]
	var x := Vector3.ZERO
	for axis in candidates:
		var projected: Vector3 = axis - n * axis.dot(n)
		if projected.length() > 0.5:
			x = projected.normalized()
			break
	return {"origin": origin, "x": x, "y": n.cross(x).normalized()}


func transform() -> Transform3D:
	var plane: Dictionary = options.get("plane", ORIGIN_PLANES.xz)
	var x: Vector3 = plane.x
	var y: Vector3 = plane.y
	return Transform3D(Basis(x, y, x.cross(y)), plane.origin)


func normal() -> Vector3:
	return transform().basis.z


func to_world(uv: Vector2) -> Vector3:
	var plane: Dictionary = options.plane
	return (plane.origin as Vector3) + (plane.x as Vector3) * uv.x + (plane.y as Vector3) * uv.y


func to_plane(world: Vector3) -> Vector2:
	var plane: Dictionary = options.plane
	var rel: Vector3 = world - (plane.origin as Vector3)
	return Vector2(rel.dot(plane.x), rel.dot(plane.y))


# --- Entities --------------------------------------------------------------------------------

func entities() -> Array:
	return options.entities


func constraints() -> Array:
	return options.constraints


func new_id() -> int:
	var id := int(options.next_id)
	options.next_id = id + 1
	return id


func entity(id: int) -> Dictionary:
	return _lookup(options.entities, _entity_at, id)


func constraint(id: int) -> Dictionary:
	return _lookup(options.constraints, _constraint_at, id)


## The item of list whose id is id ({} when none), through the index: an index entry is used only
## while it still points at an item with that id. The index is rebuilt when the list was replaced
## or grew or shrank since it was built (the first item with an id wins, as a scan would find
## it); otherwise a miss is settled by a plain scan (an item replaced in place), as before.
static func _lookup(list: Array, index: Dictionary, id: int) -> Dictionary:
	var at: int = index.get(id, -1)
	if at >= 0 and at < list.size() and int(list[at].id) == id:
		return list[at]
	var built: Variant = index.get("list")
	if built is Array and is_same(built, list) and int(index.get("size", -1)) == list.size():
		for k in list.size():
			if int(list[k].id) == id:
				index[id] = k
				return list[k]
		return {}
	index.clear()
	for k in list.size():
		var key := int(list[k].id)
		if not index.has(key):
			index[key] = k
	index["list"] = list
	index["size"] = list.size()
	at = index.get(id, -1)
	return list[at] if at >= 0 else {}


func origin_id() -> int:
	for e in options.entities:
		if e.get("origin", false):
			return int(e.id)
	return -1


func point(id: int) -> Vector2:
	var e := entity(id)
	return Vector2(float(e.get("x", 0.0)), float(e.get("y", 0.0)))


func point_xy(id: int) -> PackedFloat64Array:
	var e := entity(id)
	return PackedFloat64Array([float(e.get("x", 0.0)), float(e.get("y", 0.0))])


func set_point(id: int, p: Vector2) -> void:
	var e := entity(id)
	if not e.is_empty():
		e["x"] = float(p.x)
		e["y"] = float(p.y)


func add_point(p: Vector2, fixed := false) -> int:
	var id := new_id()
	options.entities.append({"id": id, "type": "point", "x": float(p.x), "y": float(p.y), "fixed": fixed})
	return id


## A point entity at p, or the given existing point id when snap_point >= 0.
func point_or(p: Vector2, snap_point: int) -> int:
	return snap_point if snap_point >= 0 and not entity(snap_point).is_empty() else add_point(p)


func add_line(p1: int, p2: int, construction := false, centerline := false) -> int:
	var id := new_id()
	options.entities.append({"id": id, "type": "line", "p1": p1, "p2": p2, "construction": construction, "centerline": centerline})
	return id


func add_circle(c: int, r: float, construction := false) -> int:
	var id := new_id()
	options.entities.append({"id": id, "type": "circle", "c": c, "r": float(r), "construction": construction})
	return id


## A counter-clockwise arc from point s to point e about point c (radius from c to s).
func add_arc(c: int, s: int, e: int, construction := false) -> int:
	var id := new_id()
	options.entities.append({"id": id, "type": "arc", "c": c, "s": s, "e": e, "r": point(c).distance_to(point(s)), "construction": construction})
	return id


func add_ellipse(c: int, f: int, minor: float, construction := false) -> int:
	var id := new_id()
	options.entities.append({"id": id, "type": "ellipse", "c": c, "f": f, "minor": float(minor), "construction": construction})
	return id


func add_spline(point_ids: Array, mode := "fit", closed := false, construction := false) -> int:
	var id := new_id()
	options.entities.append({"id": id, "type": "spline", "points": point_ids.duplicate(), "mode": mode, "closed": closed, "construction": construction})
	return id


func add_conic(s: int, e: int, shoulder: int, rho := 0.5, construction := false) -> int:
	var id := new_id()
	options.entities.append({"id": id, "type": "conic", "s": s, "e": e, "shoulder": shoulder, "rho": float(rho), "construction": construction})
	return id


func add_text(text: String, at: Vector2, height: float, extra := {}) -> int:
	var id := new_id()
	var entry := {"id": id, "type": "text", "text": text, "x": float(at.x), "y": float(at.y), "height": float(height), "angle": 0.0,
		"font": "", "bold": false, "italic": false, "path": -1, "construction": false}
	entry.merge(extra, true)
	options.entities.append(entry)
	return id


func add_ref3d(polylines: Array, source: String) -> int:
	var id := new_id()
	options.entities.append({"id": id, "type": "ref3d", "polylines": polylines.duplicate(), "source": source})
	return id


## The point ids an entity is built on (its end points, center, fit points, ...).
func points_of(id: int) -> Array[int]:
	var e := entity(id)
	var result: Array[int] = []
	match str(e.get("type", "")):
		"point":
			result.append(id)
		"line":
			result.append_array([int(e.p1), int(e.p2)])
		"circle":
			result.append(int(e.c))
		"arc":
			result.append_array([int(e.c), int(e.s), int(e.e)])
		"ellipse":
			result.append_array([int(e.c), int(e.f)])
		"spline":
			for p in e.points:
				result.append(int(p))
		"conic":
			result.append_array([int(e.s), int(e.e), int(e.shoulder)])
	return result


## Entities (other than id) that use point p.
func users_of_point(p: int) -> Array[int]:
	var result: Array[int] = []
	for e in options.entities:
		if int(e.id) != p and e.type != "point" and points_of(int(e.id)).has(p):
			result.append(int(e.id))
	return result


## Deletes entities and every constraint that refers to them; points only a deleted curve used
## go too (the sketch origin always stays).
func remove_entities(ids: Array) -> void:
	var doomed := {}
	for id in ids:
		doomed[int(id)] = true
	for id in ids:
		for p in points_of(int(id)):
			if entity(p).get("origin", false):
				continue
			var still_used := users_of_point(p).any(func(user: int) -> bool: return not doomed.has(user))
			if not still_used:
				doomed[p] = true
	for id in doomed.keys():
		if entity(id).get("origin", false):
			doomed.erase(id)
	options.entities = options.entities.filter(func(e: Dictionary) -> bool: return not doomed.has(int(e.id)))
	var dropped: Array = options.constraints.filter(func(c: Dictionary) -> bool: return (c.refs as Array).any(func(r) -> bool: return doomed.has(int(r))))
	for c in dropped:
		remove_constraint(int(c.id))


# --- Constraints and dimensions --------------------------------------------------------------

## Adds a constraint; a dimension (with expression) also becomes a model parameter dN.
func add_constraint(type: String, refs: Array, expression := "", kind := "length", driving := true) -> int:
	var id := new_id()
	var entry := {"id": id, "type": type, "refs": refs.map(func(r) -> int: return int(r)), "driving": driving}
	if type in DIMENSIONS:
		entry["key"] = "dim%d" % id
		entry["kind"] = "angle" if type == "angle" else kind
		entry["offset"] = Vector2.ZERO
		if driving and feature != null and doc != null:
			feature.inputs[entry.key] = doc.make_input(expression, entry.kind)
	options.constraints.append(entry)
	return id


func remove_constraint(id: int) -> void:
	var c := constraint(id)
	if c.is_empty():
		return
	if c.has("key") and feature != null:
		feature.inputs.erase(c.key)
	options.constraints = options.constraints.filter(func(other: Dictionary) -> bool: return int(other.id) != id)


## Turns a dimension between driving (it sets the size) and driven (it only measures). Made
## driving, it gets back the parameter name it had (param_name) while nothing else uses it.
func set_driving(id: int, driving: bool, expression := "") -> void:
	var c := constraint(id)
	if c.is_empty() or not c.has("key") or bool(c.driving) == driving:
		return
	c["driving"] = driving
	if driving and doc != null:
		var name := str(c.get("param_name", ""))
		if name != "" and PARAMETERS.is_valid_name(doc, name):
			feature.inputs[c.key] = {"name": name, "expression": expression, "kind": c.kind}
		else:
			feature.inputs[c.key] = doc.make_input(expression, c.kind)
		c.erase("param_name")
	elif not driving:
		feature.inputs.erase(c.key)


func dimension_expression(id: int) -> String:
	var c := constraint(id)
	return feature.expression(str(c.get("key", ""))) if feature != null else ""


# --- Curves for the kernel -------------------------------------------------------------------

## The curve dictionaries (see sketch_geometry.h) of the profile-forming geometry: everything
## except points, construction lines and centerlines. Each has "entity" set to its id.
func profile_curves(text_outlines := {}) -> Array:
	var result := []
	for e in options.entities:
		if e.type == "point" or e.type == "ref3d" or e.get("construction", false) or e.get("centerline", false):
			continue
		if e.type == "text":
			for outline in text_outlines.get(int(e.id), []):
				result.append({"type": "polyline", "points": outline, "closed": true, "entity": int(e.id)})
			continue
		var curve := curve_of(int(e.id))
		if not curve.is_empty():
			result.append(curve)
	return result


## One entity as a curve dictionary (empty for points, text and 3D references).
func curve_of(id: int) -> Dictionary:
	var e := entity(id)
	var curve := {}
	match str(e.get("type", "")):
		"line":
			curve = {"type": "line", "a": point(int(e.p1)), "b": point(int(e.p2))}
		"circle":
			curve = {"type": "circle", "c": point(int(e.c)), "r": float(e.r)}
		"arc":
			var c := point(int(e.c))
			curve = {"type": "arc", "c": c, "r": float(e.r), "a0": (point(int(e.s)) - c).angle(), "a1": (point(int(e.e)) - c).angle()}
		"ellipse":
			var c := point(int(e.c))
			var focus := point(int(e.f)) - c
			var minor := float(e.minor)
			var major := sqrt(focus.length_squared() + minor * minor)
			var direction := focus.normalized() if focus.length() > 1e-12 else Vector2.RIGHT
			curve = {"type": "ellipse", "c": c, "major": direction * major, "minor": minor}
		"spline":
			var pts := PackedVector2Array()
			for p in e.points:
				pts.append(point(int(p)))
			if e.get("mode", "fit") == "fit":
				curve = {"type": "interp", "points": pts, "periodic": bool(e.get("closed", false))}
			else:
				curve = {"type": "bspline", "poles": pts, "degree": mini(int(e.get("degree", 3)), pts.size() - 1), "periodic": bool(e.get("closed", false))}
				for key in ["weights", "knots", "mults"]:
					if e.has(key):
						curve[key] = e[key]
		"conic":
			var rho := clampf(float(e.get("rho", 0.5)), 0.01, 0.99)
			curve = {"type": "conic", "a": point(int(e.s)), "b": point(int(e.e)), "shoulder": point(int(e.shoulder)), "weight": rho / (1.0 - rho)}
	if not curve.is_empty():
		curve["entity"] = id
	return curve


## A curve's points in plane coordinates for drawing (lines and circles exactly, others via the kernel).
func sample(id: int, kernel: RefCounted, deflection: float) -> PackedVector2Array:
	var curve := curve_of(id)
	match str(curve.get("type", "")):
		"":
			return PackedVector2Array()
		"line":
			return PackedVector2Array([curve.a, curve.b])
		"circle", "arc":
			var c: Vector2 = curve.c
			var r: float = curve.r
			var a0 := 0.0 if curve.type == "circle" else float(curve.a0)
			var span := TAU if curve.type == "circle" else fposmod(float(curve.a1) - a0, TAU)
			if span < 1e-9:
				span = TAU
			var steps := clampi(int(ceil(span / acos(clampf(1.0 - deflection / maxf(r, 1e-9), -1.0, 1.0)))) , 8, 256) if r > deflection else 8
			var pts := PackedVector2Array()
			for i in steps + 1:
				var a := a0 + span * i / steps
				pts.append(c + Vector2(cos(a), sin(a)) * r)
			return pts
	return kernel.sample_curve(curve, deflection) if kernel != null else PackedVector2Array()


## Copies of the given entities (with their own points), moved by the transform; returns a map
## old id -> new id for every copied entity and point.
func copy_entities(ids: Array, xform: Transform2D) -> Dictionary:
	var mapping := {}
	var point_ids := {}
	for id in ids:
		for p in points_of(int(id)):
			point_ids[p] = true
	for p in point_ids:
		mapping[p] = add_point(xform * point(p))
	for id in ids:
		var e := entity(int(id))
		if e.type == "point":
			continue
		var copy := e.duplicate(true)
		copy.id = new_id()
		for key in ["p1", "p2", "c", "s", "e", "f", "shoulder"]:
			if copy.has(key):
				copy[key] = mapping[int(copy[key])]
		if copy.has("points") and copy.type == "spline":
			copy.points = (copy.points as Array).map(func(p) -> int: return int(mapping[int(p)]))
		if copy.type in ["circle", "arc"]:
			copy.r = float(copy.r) * absf(xform.get_scale().x)
		if copy.type == "ellipse":
			copy.minor = float(copy.minor) * absf(xform.get_scale().x)
		if xform.determinant() < 0.0 and copy.type == "arc":
			# A mirror reverses the arc's direction; swap its ends to keep it counter-clockwise.
			var s: int = copy.s
			copy.s = copy.e
			copy.e = s
		copy.erase("projected")
		options.entities.append(copy)
		mapping[int(id)] = int(copy.id)
	return mapping
