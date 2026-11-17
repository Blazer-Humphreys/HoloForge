@tool
extends RefCounted
## Stable references from features to what you picked, and how a rebuild finds them again.
##
## Reference dictionaries (stored in feature options):
##   {"kind": "profile", "sketch": feature id, "point": Vector2}   a sketch region, by a point inside it
##   {"kind": "body", "body": id}
##   {"kind": "face" | "edge", "body": id, "name": persistent name, "sig": {...}}
##     (a face clicked for Trim also holds "at": where the click hit it)
##   {"kind": "vertex", "body": id, "point": Vector3}
##   {"kind": "sketch_curve" | "sketch_point", "sketch": feature id, "entity": id}
##   {"kind": "origin", "name": "xy" | "xz" | "yz" | "x" | "y" | "z" | "o"}
##   {"kind": "construct", "feature": feature id}
##   {"kind": "mesh_group", "body": id, "group": face group name, "at": the point picked,
##     "normal": how the surface faced there}                               on a mesh body
##     (group names such as g0..gN are given by order, so "at" and "normal" let a rebuild find the
##     group again when an earlier change renumbers them: MESH_BODY.resolve_group; a reference
##     without them goes by name)
##   {"kind": "mesh_triangles", "body": id, "triangles": PackedInt32Array, "digest": the CadMesh's
##     digest when they were picked}                                        on a mesh body
## Faces and edges resolve by name; when a name is gone they fall back to the closest match of the
## same type (and the feature shows a warning), like other CAD apps repair lost references.
##
## Mesh bodies (core/mesh/mesh_body.gd) have face groups, not B-rep faces and edges: a face or edge
## reference on one resolves to {"error": the gate sentence}, so Solid and Surface features refuse
## it in one sentence. A flat face group still gives a plane (plane()); mesh_group() finds a group.

const SKETCH := preload("res://addons/holo_forge/core/sketch/sketch_data.gd")
const MESH_BODY := preload("res://addons/holo_forge/core/mesh/mesh_body.gd")

const ORIGIN_AXES := {"x": Vector3.RIGHT, "y": Vector3.UP, "z": Vector3.BACK}


# --- Making references from picks ----------------------------------------------------------

## A reference for a viewport pick ({"kind", "body", "index", "point"}) on a regen result.
static func from_pick(pick: Dictionary, result: Dictionary) -> Dictionary:
	var body: Dictionary = result.get("bodies", {}).get(pick.get("body", ""), {})
	if MESH_BODY.is_mesh(body):
		return _from_mesh_pick(pick, body)
	match str(pick.get("kind", "")):
		"body":
			return {"kind": "body", "body": pick.body}
		"face":
			if body.is_empty():
				return {}
			return {"kind": "face", "body": pick.body, "name": str(body.shape.get_face_names()[int(pick.index)]), "sig": face_signature(body.shape, int(pick.index))}
		"edge":
			if body.is_empty():
				return {}
			return {"kind": "edge", "body": pick.body, "name": str(body.shape.get_edge_names()[int(pick.index)]), "sig": edge_signature(body.shape, int(pick.index))}
		"vertex":
			return {"kind": "vertex", "body": pick.body, "point": body.shape.vertex_position(int(pick.index)) if not body.is_empty() else pick.get("point", Vector3.ZERO)}
	return {}


## from_pick() on a mesh body: its face groups and triangles (core/picking.gd gives "mesh_group"
## and "mesh_triangle" picks; a "face" pick's index is the group's too). It has no edges or
## vertices to refer to.
static func _from_mesh_pick(pick: Dictionary, body: Dictionary) -> Dictionary:
	var shape: RefCounted = body.shape
	match str(pick.get("kind", "")):
		"body":
			return {"kind": "body", "body": pick.body}
		"mesh_group", "face":
			var names: PackedStringArray = shape.get_face_names()
			var index := int(pick.get("index", -1))
			if index < 0 or index >= names.size():
				return {}
			var ref := {"kind": MESH_BODY.GROUP_REF, "body": pick.body, "group": str(names[index])}
			if pick.get("point") is Vector3:
				ref["at"] = pick.point
				if pick.get("normal") is Vector3:
					ref["normal"] = pick.normal
			return ref
		"mesh_triangle":
			var triangle := int(pick.get("triangle", pick.get("index", -1)))
			if triangle < 0 or triangle >= int(shape.triangle_count()):
				return {}
			var ref := {"kind": MESH_BODY.TRIANGLES_REF, "body": pick.body, "triangles": PackedInt32Array([triangle]), "digest": str(shape.digest())}
			if pick.get("point") is Vector3:
				ref["at"] = pick.point
				if pick.get("normal") is Vector3:
					ref["normal"] = pick.normal
			return ref
	return {}


static func face_signature(shape: RefCounted, index: int) -> Dictionary:
	var info: Dictionary = shape.face_info(index)
	return {"type": info.get("type", ""), "point": info.get("point", Vector3.ZERO), "normal": info.get("normal", Vector3.ZERO), "area": info.get("area", 0.0)}


static func edge_signature(shape: RefCounted, index: int) -> Dictionary:
	var info: Dictionary = shape.edge_info(index)
	return {"type": info.get("type", ""), "point": info.get("midpoint", Vector3.ZERO), "length": info.get("length", 0.0)}


## A short readable label for a reference (for command panel slots and warnings).
static func describe(ref: Dictionary, doc: Resource) -> String:
	match str(ref.get("kind", "")):
		"profile":
			return "Profile"
		"body":
			return doc.body_name(ref.body) if doc != null else str(ref.body)
		"face":
			return "Face"
		"edge":
			return "Edge"
		"vertex":
			return "Point"
		"sketch_curve":
			return "Curve"
		"sketch_point":
			return "Sketch Point"
		"origin":
			return str(ref.name).to_upper()
		"construct", "feature":
			var feature: Resource = doc.find_feature(ref.feature) if doc != null else null
			return feature.label if feature != null else "Feature"
		"component":
			return doc.component_name(ref.component) if doc != null else str(ref.component)
		"mesh_group":
			return "Face Group"
		"mesh_triangles":
			var count := (ref.get("triangles", PackedInt32Array()) as PackedInt32Array).size()
			return "%d Triangle%s" % [count, "" if count == 1 else "s"]
	return "?"


# --- Resolving -----------------------------------------------------------------------------

## A body's current shape, or null.
static func body_shape(ref: Dictionary, ctx: Dictionary) -> RefCounted:
	var body: Dictionary = ctx.bodies.get(ref.get("body", ""), {})
	return body.get("shape") if not body.is_empty() else null


## {"face": CadShape, "plane": Transform3D, "sketch": id} for a profile, or {"error": text}.
static func profile(ref: Dictionary, ctx: Dictionary) -> Dictionary:
	var sketch_state: Dictionary = ctx.sketches.get(ref.get("sketch", ""), {})
	if sketch_state.is_empty():
		return {"error": "The profile's sketch is missing"}
	var point: Vector2 = ref.get("point", Vector2.ZERO)
	var best := {}
	var best_area := INF
	for region in sketch_state.get("regions", []):
		var loops: Array = region.loops
		if loops.is_empty() or not Geometry2D.is_point_in_polygon(point, loops[0]):
			continue
		var in_hole := false
		for k in range(1, loops.size()):
			in_hole = in_hole or Geometry2D.is_point_in_polygon(point, loops[k])
		if not in_hole and float(region.area) < best_area:
			best_area = float(region.area)
			best = region
	if best.is_empty():
		return {"error": "A profile is no longer closed (the sketch changed)"}
	return {"face": best.face, "plane": sketch_state.plane, "sketch": ref.sketch}


## The face index a reference points to now: {"body", "index", "shape", "repaired": bool} or {"error"}.
static func face(ref: Dictionary, ctx: Dictionary) -> Dictionary:
	return _sub(ref, ctx, "face")


static func edge(ref: Dictionary, ctx: Dictionary) -> Dictionary:
	return _sub(ref, ctx, "edge")


static func _sub(ref: Dictionary, ctx: Dictionary, kind: String) -> Dictionary:
	var shape := body_shape(ref, ctx)
	if shape == null:
		return {"error": "The body for a picked %s is gone" % kind}
	if MESH_BODY.is_mesh(shape):
		# A mesh body has no B-rep faces or edges (and can't answer the calls below).
		return {"error": MESH_BODY.gate_ref(ref, ctx)}
	var name := str(ref.get("name", ""))
	var index: int = shape.find_face(name) if kind == "face" else shape.find_edge(name)
	if index < 0 and name.contains(":patch"):
		# A plate patch (five sides, points, rails) was named "<id>:patch" before it became
		# "<id>:plate": a reference saved then still finds it by name.
		var renamed := name.replace(":patch", ":plate")
		index = shape.find_face(renamed) if kind == "face" else shape.find_edge(renamed)
	if index >= 0:
		return {"body": ref.body, "index": index, "shape": shape, "repaired": false}
	# Lost name: the nearest face/edge of the same type, if one is reasonably close.
	var sig: Dictionary = ref.get("sig", {})
	var target: Vector3 = sig.get("point", Vector3.ZERO)
	var size: float = (shape.bbox() as AABB).size.length()
	var best := -1
	var best_score := INF
	var count: int = shape.face_count() if kind == "face" else shape.edge_count()
	for i in count:
		var other: Dictionary = face_signature(shape, i) if kind == "face" else edge_signature(shape, i)
		if other.type != sig.get("type", other.type):
			continue
		var score: float = (other.point as Vector3).distance_to(target)
		if kind == "face" and not (sig.get("normal", Vector3.ZERO) as Vector3).is_zero_approx():
			score += (1.0 - (other.normal as Vector3).dot(sig.normal)) * size
		if score < best_score:
			best_score = score
			best = i
	if best < 0 or best_score > size * 0.5:
		return {"error": "A picked %s can't be found any more" % kind}
	return {"body": ref.body, "index": best, "shape": shape, "repaired": true}


## Faces or edges grouped by body: {body id: {"shape", "indices": PackedInt32Array}}, plus any
## problems in "errors" and repaired references in "repaired".
static func group_by_body(refs: Array, ctx: Dictionary, kind: String) -> Dictionary:
	var groups := {}
	var errors := []
	var repaired := 0
	for ref in refs:
		var found := _sub(ref, ctx, kind) if ref.get("kind", "") == kind else {}
		if ref.get("kind", "") == "body" and kind == "edge":
			# A body stands for all its edges (rule fillet / chamfer).
			var shape := body_shape(ref, ctx)
			if MESH_BODY.is_mesh(shape):
				errors.append(MESH_BODY.gate_ref(ref, ctx))
				continue
			if shape != null:
				var all := PackedInt32Array()
				for i in shape.edge_count():
					all.append(i)
				groups[ref.body] = {"shape": shape, "indices": all}
			continue
		if found.has("error"):
			errors.append(found.error)
			continue
		if found.is_empty():
			continue
		repaired += 1 if found.repaired else 0
		var indices: PackedInt32Array = groups.get(found.body, {}).get("indices", PackedInt32Array())
		if not indices.has(found.index):
			indices.append(found.index)
		groups[found.body] = {"shape": found.shape, "indices": indices}
	return {"groups": groups, "errors": errors, "repaired": repaired}


## The face group a mesh_group reference points to now: {"body", "index", "shape" (the CadMesh),
## "name"} or {"error"}. A reference with "at" is checked against where it was picked
## (MESH_BODY.resolve_group): when an earlier change gave its name to another face, the group
## found there is returned with "group_moved": [the old name, the new name], for a warning.
static func mesh_group(ref: Dictionary, ctx: Dictionary) -> Dictionary:
	var shape := body_shape(ref, ctx)
	if shape == null:
		return {"error": "The body for a picked face group is gone"}
	if not MESH_BODY.is_mesh(shape):
		return {"error": "%s is not a mesh body any more" % MESH_BODY.body_name(ctx.get("doc"), str(ref.get("body", "")))}
	var found := MESH_BODY.resolve_group(shape, ref)
	if found.has("error"):
		return found
	var result := {"body": ref.body, "index": int(found.index), "shape": shape, "name": str(found.name)}
	if bool(found.get("moved", false)):
		result["group_moved"] = [str(found.from), str(found.name)]
	return result


## {"origin", "normal", "x"} for a plane reference (origin plane, construction plane, planar face,
## a flat face group of a mesh body, a profile's sketch plane), or {"error"}.
static func plane(ref: Dictionary, ctx: Dictionary) -> Dictionary:
	match str(ref.get("kind", "")):
		"mesh_group":
			var found := mesh_group(ref, ctx)
			if found.has("error"):
				return found
			var info: Dictionary = found.shape.face_info(found.index)
			if not info.get("planar", false):
				return {"error": "That face group isn't flat"}
			var frame := SKETCH.face_plane(info.point, info.normal)
			var of_group := {"origin": info.point, "normal": info.normal, "x": frame.x}
			if found.has("group_moved"):
				of_group["group_moved"] = found.group_moved
			return of_group
		"origin":
			var frame: Dictionary = SKETCH.ORIGIN_PLANES.get(ref.name, {})
			if frame.is_empty():
				return {"error": "Not a plane"}
			return {"origin": frame.origin, "normal": (frame.x as Vector3).cross(frame.y), "x": frame.x}
		"construct":
			var c: Dictionary = ctx.construction.get(ref.feature, {})
			if c.get("type", "") != "plane":
				return {"error": "That construction is not a plane"}
			return {"origin": c.origin, "normal": c.normal, "x": c.x}
		"face":
			var found := face(ref, ctx)
			if found.has("error"):
				return found
			var info: Dictionary = found.shape.face_info(found.index)
			if not info.get("planar", false):
				return {"error": "That face isn't flat"}
			var frame := SKETCH.face_plane(info.point, info.normal)
			return {"origin": info.point, "normal": info.normal, "x": frame.x}
		"profile":
			var p := profile(ref, ctx)
			if p.has("error"):
				return p
			var t: Transform3D = p.plane
			return {"origin": t.origin, "normal": t.basis.z, "x": t.basis.x}
	return {"error": "Pick a plane or a flat face"}


## {"origin", "direction"} for an axis reference (origin axis, construction axis, sketch line,
## straight edge, round face's axis), or {"error"}.
static func axis(ref: Dictionary, ctx: Dictionary) -> Dictionary:
	match str(ref.get("kind", "")):
		"mesh_group":
			return {"error": MESH_BODY.AXIS_GATE}
		"origin":
			if ORIGIN_AXES.has(ref.name):
				return {"origin": Vector3.ZERO, "direction": ORIGIN_AXES[ref.name]}
		"construct":
			var c: Dictionary = ctx.construction.get(ref.feature, {})
			if c.get("type", "") == "axis":
				return {"origin": c.origin, "direction": c.direction}
		"sketch_curve":
			var s := _sketch(ref, ctx)
			if s != null:
				var e: Dictionary = s.entity(int(ref.entity))
				if e.get("type", "") == "line":
					var a: Vector3 = s.to_world(s.point(int(e.p1)))
					var b: Vector3 = s.to_world(s.point(int(e.p2)))
					return {"origin": a, "direction": (b - a).normalized()}
		"edge":
			var found := edge(ref, ctx)
			if found.has("error"):
				return found
			var info: Dictionary = found.shape.edge_info(found.index)
			if info.get("type", "") == "line":
				return {"origin": info.start, "direction": ((info.end as Vector3) - info.start).normalized()}
			if info.get("type", "") == "circle":
				return {"origin": info.center, "direction": info.axis}
		"face":
			var found := face(ref, ctx)
			if found.has("error"):
				return found
			var info: Dictionary = found.shape.face_info(found.index)
			if info.has("axis"):
				return {"origin": info.axis_origin, "direction": info.axis}
	return {"error": "Pick an axis, a straight line or edge, or a round face"}


## A point for a point reference (origin, construction point, sketch point, vertex, circle center).
static func point(ref: Dictionary, ctx: Dictionary) -> Dictionary:
	match str(ref.get("kind", "")):
		"origin":
			return {"point": Vector3.ZERO}
		"construct":
			var c: Dictionary = ctx.construction.get(ref.feature, {})
			if c.get("type", "") == "point":
				return {"point": c.position}
		"sketch_point":
			var s := _sketch(ref, ctx)
			if s != null and not s.entity(int(ref.entity)).is_empty():
				return {"point": s.to_world(s.point(int(ref.entity)))}
		"vertex":
			return {"point": ref.point}
		"edge":
			var found := edge(ref, ctx)
			if found.has("error"):
				return found
			var info: Dictionary = found.shape.edge_info(found.index)
			return {"point": info.get("center", info.midpoint)}
	return {"error": "Pick a point"}


## A wire for path references (sketch curves, edges), or {"error"}.
static func path(refs: Array, ctx: Dictionary) -> Dictionary:
	var kernel: RefCounted = ctx.kernel
	var sketch_curves := {}
	var edge_groups := {}
	for ref in refs:
		match str(ref.get("kind", "")):
			"sketch_curve":
				var list: Array = sketch_curves.get(ref.sketch, [])
				list.append(int(ref.entity))
				sketch_curves[ref.sketch] = list
			"edge":
				var found := edge(ref, ctx)
				if found.has("error"):
					return found
				var indices: PackedInt32Array = edge_groups.get(found.body, {}).get("indices", PackedInt32Array())
				indices.append(found.index)
				edge_groups[found.body] = {"shape": found.shape, "indices": indices}
	for sketch_id in sketch_curves:
		var s := _sketch({"sketch": sketch_id}, ctx)
		if s == null:
			return {"error": "The path's sketch is missing"}
		var curves := []
		for id in sketch_curves[sketch_id]:
			var curve: Dictionary = s.curve_of(id)
			if not curve.is_empty():
				curves.append(curve)
		var wire: RefCounted = kernel.sketch_wire(curves, s.transform())
		if wire == null:
			return {"error": "The path curves don't connect: %s" % kernel.get_last_error()}
		return {"wire": wire}
	for body_id in edge_groups:
		var wire: RefCounted = kernel.wire_from_edges(edge_groups[body_id].shape, edge_groups[body_id].indices)
		if wire == null:
			return {"error": "The path edges don't connect"}
		return {"wire": wire}
	return {"error": "Pick a path"}


## The picked sketch curves as exact edges, one compound per sketch: [{"edges", "plane"}], or
## [{"error"}] (picks of other kinds are skipped).
static func curve_edges(refs: Array, ctx: Dictionary) -> Array:
	var by_sketch := {}
	for ref in refs:
		if str(ref.get("kind", "")) == "sketch_curve":
			var list: Array = by_sketch.get(ref.sketch, [])
			list.append(int(ref.entity))
			by_sketch[ref.sketch] = list
	var result := []
	for sketch_id in by_sketch:
		var s := _sketch({"sketch": sketch_id}, ctx)
		if s == null:
			return [{"error": "A picked curve's sketch is missing"}]
		var curves := []
		for id in by_sketch[sketch_id]:
			var curve: Dictionary = s.curve_of(id)
			if not curve.is_empty():
				curves.append(curve)
		if curves.is_empty():
			return [{"error": "A picked sketch curve is gone"}]
		var edges: RefCounted = ctx.kernel.sketch_edges(curves, s.transform())
		if edges == null or edges.is_null():
			return [{"error": "The sketch curves could not be made: %s" % ctx.kernel.get_last_error()}]
		result.append({"edges": edges, "plane": s.transform()})
	return result


## A picked curve's or point's sketch, or null. In a rebuild only the sketches built so far count
## (ctx.sketches): a suppressed sketch, or one later in the timeline, drives nothing.
static func _sketch(ref: Dictionary, ctx: Dictionary) -> RefCounted:
	var sketch_id := str(ref.get("sketch", ""))
	if ctx.has("sketches") and not (ctx.sketches as Dictionary).has(sketch_id):
		return null
	var feature: Resource = ctx.doc.find_feature(sketch_id) if ctx.get("doc") != null else null
	return SKETCH.new(feature, ctx.doc) if feature != null else null
