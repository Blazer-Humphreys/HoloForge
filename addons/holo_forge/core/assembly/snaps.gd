@tool
extends RefCounted
## Joint snaps (Holo Forge Phase 8, contract C2.3): where on a body a joint side sits, as a frame in
## that body's modelled coordinates (C2.2).
##
## A stored snap (assembly_data SNAP_DEFAULT) is {"kind", "body", "ref" (REFERENCES.from_pick's
## output), "at", "normal", "frame"} plus, here:
##   "face": the face reference a pick on an edge or a vertex came through (edge_mid, vertex,
##           circle_center), so its Z can be worked out again;
##   "origin": a Joint Origin id (kind "origin").
## Kind "fixed" (added here) is a frame with no geometry behind it: an as-built joint's side keeps
## the picked world frame that way (C2.4), and it never goes lost.
##
## Geometry comes from the existing native queries (CadShape face_info / edge_info /
## vertex_position / face_normal_at; CadMesh face_info / group_triangles / fit_primitive /
## get_arrays). They answer in float32 (Vector3), so a snap point is as exact as float32 at the
## model's size (about 4e-9 m at 0.1 m); the frame itself and everything after it are doubles.
## Resolved frames are cached per result (by identity) and snap; a new result clears the cache.

const XFORM := preload("res://addons/holo_forge/core/assembly/xform64.gd")
const DATA := preload("res://addons/holo_forge/core/assembly/assembly_data.gd")
const JOINT_MATH := preload("res://addons/holo_forge/core/assembly/joint_math.gd")
const REFERENCES := preload("res://addons/holo_forge/core/references.gd")
const MESH_BODY := preload("res://addons/holo_forge/core/mesh/mesh_body.gd")

## A snap kind with no geometry: the stored frame is the snap (as-built joints).
const FIXED := "fixed"
## Fitted cylinders further than this (max distance / radius) from round are refused.
const ROUND_LIMIT := 0.01
## A vertex reference matches a vertex this close (relative to the body's size).
const VERTEX_MATCH := 1e-6
## How deep Joint Origins may refer to each other through their snaps.
const MAX_ORIGIN_DEPTH := 8

static var _cache_result: Variant = null
static var _cache := {}


## Forgets every cached frame and candidate list.
static func clear_cache() -> void:
	_cache_result = null
	_cache = {}


static func _cache_for(result: Dictionary) -> Dictionary:
	if _cache_result == null or not is_same(_cache_result, result):
		_cache_result = result
		_cache = {}
	return _cache


## A new snap of kind on the body ref refers to: {"snap": Dictionary} or {"error": sentence}.
## ref is REFERENCES.from_pick()'s output (face, edge, vertex or mesh_group reference). extra may
## hold "face" (the face reference the pick came through, for edge and vertex kinds), "at" (the
## picked point, Vector3, for sphere_center) and "origin" (an origin id, kind "origin"; then
## "assembly" too, to resolve it).
static func make_snap(kind: String, ref: Dictionary, result: Dictionary, doc: Resource, extra := {}) -> Dictionary:
	if not (kind in DATA.SNAP_KINDS) and kind != FIXED:
		return {"error": "Unknown snap kind \"%s\"." % kind}
	var snap := {"kind": kind, "body": str(ref.get("body", "")), "ref": ref.duplicate(true), "at": [0.0, 0.0, 0.0], "normal": [0.0, 0.0, 1.0], "frame": XFORM.identity()}
	if extra.get("face") is Dictionary and not (extra.face as Dictionary).is_empty():
		snap["face"] = (extra.face as Dictionary).duplicate(true)
	if extra.get("at") is Vector3:
		snap["at_pick"] = [float(extra.at.x), float(extra.at.y), float(extra.at.z)]
	if kind == "origin":
		snap["origin"] = str(extra.get("origin", ""))
		snap["body"] = ""
		snap["ref"] = {}
	var found := _compute(snap, result, doc, extra.get("assembly", {}) if extra.get("assembly") is Dictionary else {}, 0)
	if found.has("error"):
		return {"error": found.error}
	_store_frame(snap, found.frame)
	return {"snap": snap}


## A fixed snap (kind "fixed") holding frame, on body ("" for none).
static func fixed_snap(frame: PackedFloat64Array, body := "") -> Dictionary:
	var snap := {"kind": FIXED, "body": body, "ref": {}, "at": [0.0, 0.0, 0.0], "normal": [0.0, 0.0, 1.0], "frame": XFORM.identity()}
	_store_frame(snap, frame)
	return snap


## Where a stored snap is now: {"frame": xform64 (modelled coordinates of snap.body), "lost": bool,
## "error": why it is lost ("" when found)}. A lost snap (its reference no longer resolves, or
## resolves only by a repair) gives its stored frame.
static func resolve(snap: Dictionary, result: Dictionary, doc: Resource, assembly := {}) -> Dictionary:
	return _resolve(snap, result, doc, assembly, 0)


static func _resolve(snap: Dictionary, result: Dictionary, doc: Resource, assembly: Dictionary, depth: int) -> Dictionary:
	var kind := str(snap.get("kind", ""))
	if kind == FIXED:
		return {"frame": _stored_frame(snap), "lost": false, "error": ""}
	var cache := _cache_for(result)
	var key := 0
	var found := {}
	if kind != "origin":
		key = [kind, snap.get("ref", {}), snap.get("face", {}), snap.get("at_pick", [])].hash()
		found = cache.get(key, {})
	if found.is_empty():
		found = _compute(snap, result, doc, assembly, depth)
		if kind != "origin":
			cache[key] = found
	if found.has("error"):
		return {"frame": _stored_frame(snap), "lost": true, "error": str(found.error)}
	return {"frame": found.frame, "lost": false, "error": ""}


## The snap's frame from the geometry: {"frame"} or {"error"}.
static func _compute(snap: Dictionary, result: Dictionary, doc: Resource, assembly: Dictionary, depth: int) -> Dictionary:
	var kind := str(snap.get("kind", ""))
	if kind == "origin":
		return _origin_frame(str(snap.get("origin", "")), result, doc, assembly, depth)
	var ref: Dictionary = snap.get("ref", {}) if snap.get("ref") is Dictionary else {}
	var ctx := {"bodies": result.get("bodies", {}), "doc": doc}
	var shape := REFERENCES.body_shape(ref, ctx)
	if shape == null:
		return {"error": "The body for the pick is gone"}
	var is_mesh := MESH_BODY.is_mesh(shape)
	if kind in ["group_center", "group_axis_mid"]:
		if not is_mesh:
			return {"error": "Face groups are on mesh bodies only"}
		return _group_frame(kind, ref, shape, ctx)
	if is_mesh:
		return {"error": DATA.S_MESH_SNAP}
	match kind:
		"face_center", "axis_mid", "axis_start", "axis_end", "sphere_center":
			var found := _face_index(ref, ctx)
			if found.has("error"):
				return found
			return _face_frame(kind, shape, int(found.index), snap)
		"edge_mid", "circle_center":
			var found := _edge_index(ref, ctx)
			if found.has("error"):
				return found
			return _edge_frame(kind, shape, int(found.index), _through_face(snap, ctx))
		"vertex":
			return _vertex_frame(ref, shape, _through_face(snap, ctx))
	return {"error": "Unknown snap kind \"%s\"." % kind}


# --- B-rep kinds ---------------------------------------------------------------------------------

## A face reference's index now; a repaired reference counts as lost (the pick moved).
static func _face_index(ref: Dictionary, ctx: Dictionary) -> Dictionary:
	if str(ref.get("kind", "")) != "face":
		return {"error": "Pick a face"}
	var found := REFERENCES.face(ref, ctx)
	if found.has("error"):
		return {"error": str(found.error)}
	if bool(found.get("repaired", false)):
		return {"error": "The picked face can't be found any more"}
	return found


static func _edge_index(ref: Dictionary, ctx: Dictionary) -> Dictionary:
	if str(ref.get("kind", "")) != "edge":
		return {"error": "Pick an edge"}
	var found := REFERENCES.edge(ref, ctx)
	if found.has("error"):
		return {"error": str(found.error)}
	if bool(found.get("repaired", false)):
		return {"error": "The picked edge can't be found any more"}
	return found


## The face a pick on an edge or vertex came through: its index, or -1.
static func _through_face(snap: Dictionary, ctx: Dictionary) -> int:
	var face_ref: Variant = snap.get("face")
	if not (face_ref is Dictionary) or (face_ref as Dictionary).is_empty():
		return -1
	var found := _face_index(face_ref, ctx)
	return int(found.index) if not found.has("error") else -1


static func _face_frame(kind: String, shape: RefCounted, face: int, snap: Dictionary) -> Dictionary:
	var info: Dictionary = _face_info(shape, face)
	var face_type := str(info.get("type", ""))
	match kind:
		"face_center":
			if not bool(info.get("planar", face_type == "plane")) or not (info.get("normal") is Vector3):
				return {"error": "Face centre needs a flat face"}
			return _framed(_d(info.point), _d(info.normal))
		"sphere_center":
			if face_type != "sphere" or not (info.get("center") is Vector3):
				return {"error": "Sphere centre needs a spherical face"}
			var center := _d(info.center)
			var z := PackedFloat64Array([0.0, 0.0, 1.0])
			var at: Variant = snap.get("at_pick")
			if at is Array and (at as Array).size() == 3:
				var normal: Vector3 = shape.face_normal_at(face, Vector3(at[0], at[1], at[2]))
				if not normal.is_zero_approx():
					z = _d(normal)
			return _framed(center, z)
		"axis_mid", "axis_start", "axis_end":
			if not (info.get("axis") is Vector3) or not (info.get("axis_origin") is Vector3) or not (face_type in ["cylinder", "cone"]):
				return {"error": "Axis points need a cylindrical or conical face"}
			var axis := _unit(_d(info.axis))
			var base := _d(info.axis_origin)
			if axis.is_empty():
				return {"error": "The face has no axis"}
			var span := _extent(shape, info, base, axis)
			var t := (span[0] + span[1]) * 0.5
			var z := axis
			if kind == "axis_start":
				t = span[0]
				z = _scaled(axis, -1.0)
			elif kind == "axis_end":
				t = span[1]
			return _framed(_add(base, _scaled(axis, t)), z)
	return {"error": "Unknown face snap"}


## [min, max] of the face's extent along axis (from base), from its edges' points.
static func _extent(shape: RefCounted, info: Dictionary, base: PackedFloat64Array, axis: PackedFloat64Array) -> PackedFloat64Array:
	var low := INF
	var high := -INF
	for edge in info.get("edges", []):
		var e: Dictionary = _edge_info(shape, int(edge))
		for key in ["start", "end", "midpoint", "center"]:
			if e.get(key) is Vector3:
				var t := _dot(_sub(_d(e[key]), base), axis)
				low = minf(low, t)
				high = maxf(high, t)
	if low > high:
		return PackedFloat64Array([0.0, 0.0])
	return PackedFloat64Array([low, high])


static func _edge_frame(kind: String, shape: RefCounted, edge: int, through: int) -> Dictionary:
	var e: Dictionary = _edge_info(shape, edge)
	var faces: Array = Array(e.get("faces", []))
	var face := through if through >= 0 and faces.has(through) else _first_planar(shape, faces)
	if kind == "circle_center":
		if not (str(e.get("type", "")) in ["circle", "arc"]) or not (e.get("center") is Vector3) or not (e.get("axis") is Vector3):
			return {"error": "Circle centre needs a circular edge"}
		var z := _d(e.axis)
		if face >= 0:
			var info: Dictionary = _face_info(shape, face)
			var outward := _d(info.normal) if info.get("normal") is Vector3 else _d(shape.face_normal_at(face, e.center))
			if _dot(z, outward) < 0.0:
				z = _scaled(z, -1.0)
		return _framed(_d(e.center), z)
	if not (e.get("midpoint") is Vector3):
		return {"error": "The edge has no midpoint"}
	if face < 0 and not faces.is_empty():
		face = int(faces[0])
	if face < 0:
		return {"error": "The edge is on no face"}
	var normal := _face_normal(shape, face, e.midpoint)
	var hint := _d(e.tangent) if e.get("tangent") is Vector3 else PackedFloat64Array()
	return _framed(_d(e.midpoint), normal, hint)


static func _vertex_frame(ref: Dictionary, shape: RefCounted, through: int) -> Dictionary:
	if str(ref.get("kind", "")) != "vertex" or not (ref.get("point") is Vector3):
		return {"error": "Pick a vertex"}
	var point: Vector3 = ref.point
	var size := maxf((shape.bbox() as AABB).size.length(), 1e-9)
	var best := -1
	var best_d := INF
	for i in int(shape.vertex_count()):
		var d := (shape.vertex_position(i) as Vector3).distance_to(point)
		if d < best_d:
			best_d = d
			best = i
	if best < 0 or best_d > VERTEX_MATCH * size + 1e-9:
		return {"error": "The picked vertex can't be found any more"}
	var at: Vector3 = shape.vertex_position(best)
	# The faces at the vertex: those of the edges that start or end there.
	var faces := []
	for e in int(shape.edge_count()):
		var info: Dictionary = _edge_info(shape, e)
		for key in ["start", "end"]:
			if info.get(key) is Vector3 and (info[key] as Vector3).distance_to(at) <= VERTEX_MATCH * size + 1e-9:
				for f in info.get("faces", []):
					if not faces.has(int(f)):
						faces.append(int(f))
	faces.sort()
	var face := through if through >= 0 and faces.has(through) else (int(faces[0]) if not faces.is_empty() else -1)
	if face < 0:
		return {"error": "The vertex is on no face"}
	return _framed(_d(at), _face_normal(shape, face, at))


static func _first_planar(shape: RefCounted, faces: Array) -> int:
	for f in faces:
		if bool(_face_info(shape, int(f)).get("planar", false)):
			return int(f)
	return -1


## A face's outward normal at point (a plane's own normal; else face_normal_at).
static func _face_normal(shape: RefCounted, face: int, point: Vector3) -> PackedFloat64Array:
	var info: Dictionary = _face_info(shape, face)
	if bool(info.get("planar", false)) and info.get("normal") is Vector3:
		return _d(info.normal)
	return _d(shape.face_normal_at(face, point))


# --- Mesh kinds ----------------------------------------------------------------------------------

static func _group_frame(kind: String, ref: Dictionary, shape: RefCounted, ctx: Dictionary) -> Dictionary:
	if str(ref.get("kind", "")) != MESH_BODY.GROUP_REF:
		return {"error": DATA.S_MESH_SNAP}
	var found := REFERENCES.mesh_group(ref, ctx)
	if found.has("error"):
		return {"error": str(found.error)}
	if found.has("group_moved"):
		return {"error": "The picked face group moved"}
	var group := int(found.index)
	var info: Dictionary = shape.face_info(group)
	if kind == "group_center" and bool(info.get("planar", false)) and info.get("normal") is Vector3:
		return _framed(_d(info.point), _d(info.normal))
	# A round group (or a group_center pick on a group that is not flat): the fitted cylinder.
	var tris: PackedInt32Array = shape.group_triangles(group)
	var fit: Dictionary = shape.fit_primitive(tris)
	var cylinder: Dictionary = fit.get("cylinder", {}) if fit.get("cylinder") is Dictionary else {}
	var off := INF
	if bool(cylinder.get("valid", false)) and float(cylinder.get("radius", 0.0)) > 0.0:
		off = maxf(float(cylinder.get("max", INF)), float(cylinder.get("max_at_middles", 0.0))) / float(cylinder.radius)
	if off > ROUND_LIMIT:
		var shown := "over 100" if not is_finite(off) or off > 1.0 else String.num(off * 100.0, 1)
		return {"error": DATA.fill(DATA.S_GROUP_NOT_ROUND, {"n": shown})}
	var axis := _unit(_d(cylinder.axis))
	var base := _d(cylinder.point)
	var arrays: Dictionary = shape.get_arrays()
	var positions: PackedVector3Array = arrays.get("positions", PackedVector3Array())
	var indices: PackedInt32Array = arrays.get("indices", PackedInt32Array())
	var low := INF
	var high := -INF
	for t in tris:
		for k in 3:
			var at := int(t) * 3 + k
			if at < indices.size() and indices[at] < positions.size():
				var s := _dot(_sub(_d(positions[indices[at]]), base), axis)
				low = minf(low, s)
				high = maxf(high, s)
	if low > high:
		return {"error": "The face group has no triangles"}
	return _framed(_add(base, _scaled(axis, (low + high) * 0.5)), axis)


# --- Joint Origins -------------------------------------------------------------------------------

## An origin's frame (C2.6): its snap's frame times O_origin, in the modelled coordinates of its
## snap's body.
static func _origin_frame(origin_id: String, result: Dictionary, doc: Resource, assembly: Dictionary, depth: int) -> Dictionary:
	if depth >= MAX_ORIGIN_DEPTH:
		return {"error": "Joint Origins refer to each other in a circle"}
	for origin in assembly.get("origins", []):
		if origin is Dictionary and str(origin.get("id", "")) == origin_id:
			var snap: Dictionary = origin.get("snap", {}) if origin.get("snap") is Dictionary else {}
			var found := _resolve(snap, result, doc, assembly, depth + 1)
			if bool(found.lost):
				return {"error": str(found.error)}
			return {"frame": XFORM.compose(found.frame, JOINT_MATH.offset_xform(origin))}
	return {"error": "The Joint Origin is gone"}


## The origin's frame in the modelled coordinates of its snap's body, or {"error"}.
static func origin_frame(origin: Dictionary, result: Dictionary, doc: Resource, assembly: Dictionary) -> Dictionary:
	var snap: Dictionary = origin.get("snap", {}) if origin.get("snap") is Dictionary else {}
	var found := resolve(snap, result, doc, assembly)
	return {"frame": XFORM.compose(found.frame, JOINT_MATH.offset_xform(origin)), "lost": found.lost, "error": found.error}


# --- Candidates ----------------------------------------------------------------------------------

## The snaps a face offers while a snap slot is active (C2.3): [{"kind", "ref", "face" (or {}),
## "frame"}]. A B-rep face gives its centre (flat), its axis points (cylinder, cone), its sphere
## centre, its edges' midpoints and circle centres and its vertices; a mesh face group its centre
## (flat) or its axis middle (round). Cached per (result, body, face).
static func candidates(result: Dictionary, body_id: String, face_index: int, doc: Resource) -> Array:
	var cache := _cache_for(result)
	var key := "candidates:%s:%d" % [body_id, face_index]
	if cache.has(key):
		return cache[key]
	var out := []
	var body: Dictionary = result.get("bodies", {}).get(body_id, {})
	var shape: RefCounted = body.get("shape") if not body.is_empty() else null
	if shape != null:
		var face_ref := REFERENCES.from_pick({"kind": "face", "body": body_id, "index": face_index}, result)
		if MESH_BODY.is_mesh(shape):
			for kind in ["group_center", "group_axis_mid"]:
				_add_candidate(out, kind, face_ref, {}, result, doc)
				if not out.is_empty():
					break
		else:
			var info: Dictionary = _face_info(shape, face_index)
			match str(info.get("type", "")):
				"plane":
					_add_candidate(out, "face_center", face_ref, {}, result, doc)
				"cylinder", "cone":
					for kind in ["axis_mid", "axis_start", "axis_end"]:
						_add_candidate(out, kind, face_ref, {}, result, doc)
				"sphere":
					_add_candidate(out, "sphere_center", face_ref, {}, result, doc)
			var vertices := {}
			for edge in info.get("edges", []):
				var edge_ref := REFERENCES.from_pick({"kind": "edge", "body": body_id, "index": int(edge)}, result)
				var e: Dictionary = _edge_info(shape, int(edge))
				_add_candidate(out, "edge_mid", edge_ref, face_ref, result, doc)
				if str(e.get("type", "")) in ["circle", "arc"]:
					_add_candidate(out, "circle_center", edge_ref, face_ref, result, doc)
				for end in ["start", "end"]:
					if e.get(end) is Vector3 and not bool(e.get("closed", false)):
						var p: Vector3 = e[end]
						var vkey := "%.9f,%.9f,%.9f" % [p.x, p.y, p.z]
						if not vertices.has(vkey):
							vertices[vkey] = true
							_add_candidate(out, "vertex", {"kind": "vertex", "body": body_id, "point": p}, face_ref, result, doc)
	cache[key] = out
	return out


static func _add_candidate(out: Array, kind: String, ref: Dictionary, face_ref: Dictionary, result: Dictionary, doc: Resource) -> void:
	if ref.is_empty():
		return
	var made := make_snap(kind, ref, result, doc, {"face": face_ref})
	if made.has("snap"):
		out.append({"kind": kind, "ref": ref, "face": face_ref, "frame": made.snap.frame})


# --- Helpers -------------------------------------------------------------------------------------

## face_info / edge_info, cached per result (one native call per face or edge, C3.7).
static func _face_info(shape: RefCounted, face: int) -> Dictionary:
	var key := "f:%d:%d" % [shape.get_instance_id(), face]
	var cache: Dictionary = _cache if _cache_result != null else {}
	if cache.has(key):
		return cache[key]
	var info: Dictionary = shape.face_info(face)
	cache[key] = info
	return info


static func _edge_info(shape: RefCounted, edge: int) -> Dictionary:
	var key := "e:%d:%d" % [shape.get_instance_id(), edge]
	var cache: Dictionary = _cache if _cache_result != null else {}
	if cache.has(key):
		return cache[key]
	var info: Dictionary = shape.edge_info(edge)
	cache[key] = info
	return info


static func _framed(origin: PackedFloat64Array, z: PackedFloat64Array, hint := PackedFloat64Array()) -> Dictionary:
	var frame := XFORM.frame(origin, z, hint)
	if frame.is_empty():
		return {"error": "The pick gives no direction"}
	return {"frame": frame}


## Keeps a resolved frame in a snap ("frame", and "at" / "normal" for reading).
static func _store_frame(snap: Dictionary, frame: PackedFloat64Array) -> void:
	snap["frame"] = PackedFloat64Array(frame)
	snap["at"] = [frame[9], frame[10], frame[11]]
	snap["normal"] = [frame[6], frame[7], frame[8]]


static func _stored_frame(snap: Dictionary) -> PackedFloat64Array:
	var stored: Variant = snap.get("frame")
	if (stored is PackedFloat64Array or stored is Array) and XFORM.is_finite(PackedFloat64Array(stored)) and XFORM.orthonormal_error(PackedFloat64Array(stored)) <= 1e-9:
		return PackedFloat64Array(stored)
	return XFORM.identity()


static func _d(v: Vector3) -> PackedFloat64Array:
	return PackedFloat64Array([v.x, v.y, v.z])


static func _dot(a: PackedFloat64Array, b: PackedFloat64Array) -> float:
	return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


static func _add(a: PackedFloat64Array, b: PackedFloat64Array) -> PackedFloat64Array:
	return PackedFloat64Array([a[0] + b[0], a[1] + b[1], a[2] + b[2]])


static func _sub(a: PackedFloat64Array, b: PackedFloat64Array) -> PackedFloat64Array:
	return PackedFloat64Array([a[0] - b[0], a[1] - b[1], a[2] - b[2]])


static func _scaled(a: PackedFloat64Array, s: float) -> PackedFloat64Array:
	return PackedFloat64Array([a[0] * s, a[1] * s, a[2] * s])


static func _unit(a: PackedFloat64Array) -> PackedFloat64Array:
	var n := sqrt(_dot(a, a))
	if not (n > 0.0) or not is_finite(n):
		return PackedFloat64Array()
	return _scaled(a, 1.0 / n)
