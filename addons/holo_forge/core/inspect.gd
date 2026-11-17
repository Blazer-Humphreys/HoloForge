@tool
extends RefCounted
## Inspect: Measure, Interference (and adding its overlaps as bodies or components) and mass
## properties (Center of Mass).
##
## measure(a, b, ctx) takes references (core/references.gd formats; b may be {}) and a context
## made by context(). One reference returns its own values:
##   face     {"kind": "face", "face_type", "area", "point" (centroid), "normal" (flat faces),
##            "radius", "diameter" (cylinders, spheres; a torus' major radius), "minor_radius"
##            (torus), "center" (spheres, tori), "axis" (cylinders, cones)}
##   edge     {"kind": "edge", "edge_type", "length", "start", "end", "direction" (straight
##            edges), "radius", "diameter", "center" (circles)}
##   point    {"kind": "point", "position"} (vertices, sketch points, construction points, origin)
##   body     {"kind": "body", "volume", "area", "surface" (true for a body without solids: its
##            volume is 0)}
##   plane    {"kind": "plane", "origin", "normal"} (origin and construction planes)
##   axis     {"kind": "axis", "origin", "direction"} (origin and construction axes)
##   profile  {"kind": "profile", "area"}
##   curve    {"kind": "curve", "length", "radius", "diameter" (circles, arcs), "direction" (lines)}
## Two references return {"kind": "distance", "distance" (the minimum), "point_a", "point_b"
## (where it is found), "delta" (point_b - point_a), "first", "second" (each reference's own
## values), and "angle" (radians, 0..pi/2) when both have a direction: flat faces, planes and
## profiles by their normal; straight edges, sketch lines, axes and round faces' axes by their
## direction. Planes and axes are unbounded: against each other they are solved exactly, and
## against anything else they become flat faces and lines that reach past it.
## Problems come back as {"error": text}. Lengths are meters, areas m^2, volumes m^3.
##
## Only solids have volume and mass. A surface body (an open mesh Insert Mesh brought in, a shell,
## loose faces) has none, and a body that mixes solids with open faces counts only its solids
## (OCCT would otherwise give open faces a made-up volume whose sign follows their winding).
## shape_kind(), solid_volume(), solid_shape() and shape_mass_properties() apply this.
##
## Mesh bodies (core/mesh/mesh_body.gd: triangles and face groups, no B-rep faces or edges):
##   shape_kind: "solid" for a closed one, "surface" for an open one (never "mixed"); a closed
##   one has the mass of its volume, an open one none (its mass entry carries "warning").
##   measure: a mesh body gives {"kind": "body", "mesh": true, ...}; a face group reference
##   ({"kind": "mesh_group", "body", "group"}) gives {"kind": "face", "mesh": true, ...}
##   (MESH_BODY.measure lists the keys). A distance is measured from a point: where the pick hit
##   the mesh (the reference's "at"), else the middle of the face group. Against a B-rep face,
##   edge, plane, axis, point or body it is the least distance from that point to it; "note" says
##   what was measured from. A whole mesh body with no picked point is refused
##   (MESH_BODY.MEASURE_WHOLE): the nearest point of a mesh body is not found.
##   interference: two closed mesh bodies overlap by their mesh intersection ("shape" is then a
##   CadMesh). A mesh body against a B-rep body: the B-rep body is tessellated first, and the
##   entry's "note" says so and how approximate the volume then is. Every pair with a mesh body
##   shares one deadline (INTERFERENCE_SECONDS); see interference().
##
## Posed bodies (Phase 8, C7.4): measure (ctx "poses"), interference and mass_properties (a
## "poses" argument) take {body id: xform64} and work on the bodies where an assembly puts them.
## Posed B-rep shapes come from kernel.transform_shape, posed mesh bodies from MESH.transformed,
## kept by (body, shape, pose bytes) (posed_shape); a body without a pose, or with the identity,
## is its modelled shape, so with no poses every result is what it was before. References keep
## their modelled points (picks, C7.3): posed_ref moves them with their body, in doubles. Mass
## properties are the modelled body's moved by the pose (the center by it, the inertia turned by
## it).
##
## Far from the origin (fix round 2, SB3 / PT3): float32 positions step by about 6e-5 m 1 km out.
## A picked B-rep vertex and a body's center RECENTER_M or more out are worked out again in doubles
## on a copy moved next to the origin (_exact_vertex(), center64()); points measured between are
## vertex shapes placed in doubles, and mass results carry "center64" (PackedFloat64Array 3) per
## body and in total beside the float32 "center".

const REFERENCES := preload("res://addons/holo_forge/core/references.gd")
const UTIL := preload("res://addons/holo_forge/core/features/util.gd")
const SKETCH_DATA := preload("res://addons/holo_forge/core/sketch/sketch_data.gd")
const PHYSICAL := preload("res://addons/holo_forge/core/physical_materials.gd")
const MESH_BODY := preload("res://addons/holo_forge/core/mesh/mesh_body.gd")
const MESH := preload("res://addons/holo_forge/core/features/mesh.gd")
const XFORM := preload("res://addons/holo_forge/core/assembly/xform64.gd")

const TAG := "inspect"
## Posed shapes kept (posed_shape); the oldest go first.
const POSED_KEEP := 256
## A common volume at or below this fraction of the smaller body is touching, not interference.
const INTERFERENCE_TOLERANCE := 1e-9
## Planes and axes whose directions differ by less than this (sine of the angle) are parallel.
const PARALLEL_SINE := 1e-6
## Interference against a mesh body: the presets a B-rep body is tessellated at (the next one when
## the kernel refuses a result), and the seconds each try and the mesh intersection may take.
const MESH_PRESETS := ["medium", "high", "very_high"]
## Seconds for every pair with a mesh body in one interference() call together.
const INTERFERENCE_SECONDS := 20.0
## A pair is not started with less than this left (seconds).
const INTERFERENCE_LEAST := 0.05
## The overlap with a round B-rep body is worked out again with finer triangles while it may be
## off by more than this share (percent) of itself.
const APPROXIMATE_PERCENT := 2.0
## A mesh overlap may be off by float rounding (inspect _rounding); from this share (percent) of its
## volume on, the entry says so ("approximate" and a note).
const ROUNDING_PERCENT := 0.01
## A pair the deadline left out (%s: the seconds the call had).
const NOT_CHECKED := "It was not checked: Interference ran out of its %s s. Check fewer bodies at once."
## More face groups than this are not looked through for a round one (the body counts as round).
const FLAT_CHECK_GROUPS := 2000

## How far (m) a body's center or a picked vertex may sit from the origin before it is worked out
## again in doubles on a copy moved to it (center64(), _exact_vertex(); float32 positions step by
## 1.2e-7 m at 1 m).
const RECENTER_M := 1.0

## Posed shapes: {"<body>|<pose bytes>": {"source": the modelled shape, "posed": its posed copy}}.
static var _posed := {}
## The kernel center64() moves B-rep copies with (made on first use).
static var _center_kernel: RefCounted = null


## The context measure() needs, from a regen result. Set ctx["poses"] ({body id: xform64}) to
## measure posed bodies (C7.4).
static func context(result: Dictionary, doc: Resource, kernel: RefCounted) -> Dictionary:
	return {
		"kernel": kernel, "doc": doc, "bodies": result.get("bodies", {}), "sketches": result.get("sketches", {}),
		"construction": result.get("construction", {}), "values": result.get("values", {}),
	}


# --- Measure ---------------------------------------------------------------------------------

static func measure(a: Dictionary, b: Dictionary, ctx: Dictionary) -> Dictionary:
	if ctx.get("kernel") == null:
		return {"error": "The Holo Forge kernel is not loaded"}
	if a.is_empty():
		return {"error": "Select something to measure"}
	# (SB3: a picked B-rep vertex far out, recovered in doubles before anything moves it.)
	a = _exact_vertex(a, ctx)
	b = _exact_vertex(b, ctx)
	var poses: Dictionary = ctx.get("poses", {})
	if not poses.is_empty():
		# Posed bodies (C7.4): the referenced bodies' shapes and the references' modelled points
		# moved by the poses (the other bodies only size planes and axes).
		var used := {}
		for ref: Dictionary in [a, b]:
			var id: Variant = ref.get("body")
			if id != null and poses.has(id):
				used[id] = poses[id]
		ctx = ctx.duplicate()
		ctx["bodies"] = posed_bodies(ctx.kernel, ctx.get("bodies", {}), used)
		ctx.erase("poses")
		a = posed_ref(a, poses)
		b = posed_ref(b, poses)
	if _on_mesh(a, ctx) or _on_mesh(b, ctx):
		return _measure_mesh(a, b, ctx)
	var size := UTIL.model_size(ctx)
	var first := _geometry(a, ctx, size)
	if first.has("error"):
		return first
	if b.is_empty():
		return first.values
	var second := _geometry(b, ctx, size)
	if second.has("error"):
		return second
	var kernel: RefCounted = ctx.kernel
	var found: Dictionary
	if first.has("infinite") and second.has("infinite"):
		# Two planes or axes: their unbounded closest points, worked out exactly.
		found = _closest_infinite(first, second)
	else:
		# A plane or axis stands for an unbounded one: grow it past the other reference, which
		# can sit outside the model (sketch and construction points, profiles, curves).
		if first.has("infinite"):
			first = _geometry(a, ctx, size + _far(second))
		elif second.has("infinite"):
			second = _geometry(b, ctx, size + _far(first))
		if first.has("error") or second.has("error"):
			return first if first.has("error") else second
		found = kernel.closest_points(first.shape, second.shape)
	if not found.has("distance"):
		var why: String = kernel.get_last_error()
		return {"error": "The distance could not be measured%s" % ((": " + why) if why != "" else "")}
	var point_a: Vector3 = found.a
	var point_b: Vector3 = found.b
	var measured := {
		"kind": "distance", "distance": float(found.distance), "point_a": point_a, "point_b": point_b,
		"delta": point_b - point_a, "first": first.values, "second": second.values,
	}
	var angle := direction_angle(first, second)
	if angle >= 0.0:
		measured["angle"] = angle
	return measured


## True for a reference on a mesh body.
static func _on_mesh(ref: Dictionary, ctx: Dictionary) -> bool:
	return not ref.is_empty() and MESH_BODY.is_mesh((ctx.get("bodies", {}) as Dictionary).get(ref.get("body", ""), {}))


## measure() with a mesh body on either side. A mesh reference alone, or two of them, are
## MESH_BODY.measure's. A mesh reference against anything else: the least distance from the mesh
## reference's point (where the pick hit, else its face group's middle) to the other geometry, in
## the order asked, with "note" naming that point.
static func _measure_mesh(a: Dictionary, b: Dictionary, ctx: Dictionary) -> Dictionary:
	var first_on_mesh := _on_mesh(a, ctx)
	if b.is_empty() or (first_on_mesh and _on_mesh(b, ctx)):
		var between := MESH_BODY.measure(a, b, ctx)
		# (SB3: between two points held in doubles, the distance in doubles.)
		var pa := _used_point64(a)
		var pb := _used_point64(b)
		if str(between.get("kind", "")) == "distance" and not pa.is_empty() and not pb.is_empty():
			between["distance"] = _distance64(pa, pb)
		return between
	var mesh_ref := a if first_on_mesh else b
	var other_ref := b if first_on_mesh else a
	var from := MESH_BODY.geometry(mesh_ref, ctx)
	if from.has("error"):
		return from
	if bool(from.get("whole", false)):
		return {"error": MESH_BODY.MEASURE_WHOLE % MESH_BODY.body_name(ctx.get("doc"), str(mesh_ref.get("body", "")))}
	var kernel: RefCounted = ctx.kernel
	var point: Vector3 = from.point
	var size := UTIL.model_size(ctx)
	var other := _geometry(other_ref, ctx, size)
	if other.has("infinite"):
		# A plane or axis is unbounded: grown past the point it is measured from.
		other = _geometry(other_ref, ctx, size + point.length())
	if other.has("error"):
		return other
	var from_shape: RefCounted = kernel.make_vertex(point)
	var exact := _used_point64(mesh_ref)
	if not exact.is_empty() and kernel.has_method("transform_shape64"):
		# (SB3: the point in doubles: a float32 vertex steps by about 6e-5 m 1 km out.)
		var placed: RefCounted = kernel.call("transform_shape64", kernel.make_vertex(Vector3.ZERO), XFORM.translation(exact[0], exact[1], exact[2]), TAG)
		if placed != null and not placed.is_null():
			from_shape = placed
	var found: Dictionary = kernel.closest_points(from_shape, other.shape)
	if not found.has("distance"):
		var why: String = kernel.get_last_error()
		return {"error": "The distance could not be measured%s" % ((": " + why) if why != "" else "")}
	var near: Vector3 = found.b
	var point_a := point if first_on_mesh else near
	var point_b := near if first_on_mesh else point
	var measured := {
		"kind": "distance", "distance": float(found.distance), "point_a": point_a, "point_b": point_b,
		"delta": point_b - point_a, "first": from.values if first_on_mesh else other.values,
		"second": other.values if first_on_mesh else from.values, "note": "Measured from %s." % str(from.from),
	}
	if from.has("normal"):
		var angle := direction_angle({"direction": from.normal, "dir_kind": "plane"}, other)
		if angle >= 0.0:
			measured["angle"] = angle
	return measured


## ref with "point64" (PackedFloat64Array 3) for a vertex (fix round 2, SB3): a vertex picked on a
## B-rep body RECENTER_M or more from the origin is found again in doubles (its float32 "point"
## steps by about 6e-5 m 1 km out): the body's shape is moved by -point in doubles, where the same
## vertex lies within a float32 step of the origin and is read exactly, and point is added back.
## Other vertices take their point as it is; other references are returned as they are.
static func _exact_vertex(ref: Dictionary, ctx: Dictionary) -> Dictionary:
	if str(ref.get("kind", "")) != "vertex" or not (ref.get("point") is Vector3) or ref.get("point64") is PackedFloat64Array:
		return ref
	var p: Vector3 = ref.point
	var out := ref.duplicate()
	out["point64"] = _doubles3(p)
	var body: Dictionary = (ctx.get("bodies", {}) as Dictionary).get(ref.get("body", ""), {})
	var shape: Variant = body.get("shape")
	var kernel: RefCounted = ctx.get("kernel")
	if p.length() < RECENTER_M or not (shape is RefCounted) or (shape as RefCounted).is_null() or MESH_BODY.is_mesh(shape) or kernel == null \
			or not kernel.has_method("transform_shape64") or not (shape as Object).has_method("vertex_count"):
		return out
	var nearest := -1
	var nearest_d := INF
	for i in int(shape.vertex_count()):
		var d := (shape.vertex_position(i) as Vector3).distance_to(p)
		if d < nearest_d:
			nearest_d = d
			nearest = i
	# (The pick must be that vertex: its float32 position, give or take a step.)
	if nearest < 0 or nearest_d > p.length() * 1e-6:
		return out
	var moved: RefCounted = kernel.call("transform_shape64", shape, XFORM.translation(-float(p.x), -float(p.y), -float(p.z)), TAG)
	if moved == null or moved.is_null() or int(moved.vertex_count()) != int(shape.vertex_count()):
		return out
	var q: Vector3 = moved.vertex_position(nearest)
	if not q.is_finite() or q.length() > p.length() * 1e-6:
		return out
	out["point64"] = PackedFloat64Array([float(p.x) + q.x, float(p.y) + q.y, float(p.z) + q.z])
	return out


## The point a reference is measured from, in doubles, when it holds one: a vertex's "point64", a
## pick's "at64" (with its "at"), the origin; else [].
static func _used_point64(ref: Dictionary) -> PackedFloat64Array:
	var kind := str(ref.get("kind", ""))
	if kind == "origin" and str(ref.get("name", "")) == "o":
		return PackedFloat64Array([0.0, 0.0, 0.0])
	if kind == "vertex":
		return _ref_point64(ref)
	if ref.get("at") is Vector3 and ref.get("at64") is PackedFloat64Array and (ref.at64 as PackedFloat64Array).size() == 3:
		return PackedFloat64Array(ref.at64)
	return PackedFloat64Array()


## A vertex reference's "point64", or [].
static func _ref_point64(ref: Dictionary) -> PackedFloat64Array:
	var exact: Variant = ref.get("point64")
	if str(ref.get("kind", "")) == "vertex" and exact is PackedFloat64Array and (exact as PackedFloat64Array).size() == 3:
		return PackedFloat64Array(exact)
	return PackedFloat64Array()


## The distance between two points of 3 doubles.
static func _distance64(a: PackedFloat64Array, b: PackedFloat64Array) -> float:
	var dx := b[0] - a[0]
	var dy := b[1] - a[1]
	var dz := b[2] - a[2]
	return sqrt(dx * dx + dy * dy + dz * dz)


## The angle (0..pi/2) between two directions {"direction", "dir_kind": "plane" | "line"}:
## normals for planes, directions for lines; a line against a plane is 0 when it lies in it.
## -1 when either has no direction.
static func direction_angle(a: Dictionary, b: Dictionary) -> float:
	var kind_a := str(a.get("dir_kind", ""))
	var kind_b := str(b.get("dir_kind", ""))
	if kind_a == "" or kind_b == "":
		return -1.0
	var da: Vector3 = (a.direction as Vector3).normalized()
	var db: Vector3 = (b.direction as Vector3).normalized()
	# atan2 keeps precision near 0 and 90 degrees, where acos and asin don't.
	var along := absf(da.dot(db))
	var across := da.cross(db).length()
	return atan2(across, along) if kind_a == kind_b else atan2(along, across)


## How far a measured shape reaches from the world origin (its bounding box's farthest corner).
static func _far(geometry: Dictionary) -> float:
	var box: AABB = geometry.shape.bbox()
	var far := 0.0
	for i in 8:
		far = maxf(far, box.get_endpoint(i).length())
	return far


## {"distance", "a", "b"} between two unbounded planes or axes (geometry from _plane / _axis).
## Crossing planes and lines that meet are 0 apart at a shared point. Directions within
## PARALLEL_SINE of each other count as parallel: they are single-precision vectors, and
## near-parallel planes would otherwise "meet" kilometers away.
static func _closest_infinite(first: Dictionary, second: Dictionary) -> Dictionary:
	var o1: Vector3 = first.values.origin
	var o2: Vector3 = second.values.origin
	var d1: Vector3 = first.direction
	var d2: Vector3 = second.direction
	var a := o1
	var b := o2
	if first.dir_kind == "plane" and second.dir_kind == "plane":
		var line := d1.cross(d2)
		if line.length() < PARALLEL_SINE:
			a = o2 - d1 * (o2 - o1).dot(d1)
		else:
			# The crossing line's point nearest o1: along plane 1, perpendicular to the line.
			a = o1 + (d2 - d1 * d1.dot(d2)) * (d2.dot(o2 - o1) / line.length_squared())
			b = a
	elif first.dir_kind == "plane" or second.dir_kind == "plane":
		var flip: bool = first.dir_kind == "line"
		var plane_origin := o2 if flip else o1
		var n := d2 if flip else d1
		var axis_origin := o1 if flip else o2
		var d := d1 if flip else d2
		var on_axis := axis_origin
		var on_plane := axis_origin - n * (axis_origin - plane_origin).dot(n)
		if absf(d.dot(n)) >= PARALLEL_SINE:
			# The axis pierces the plane.
			on_axis = axis_origin + d * ((plane_origin - axis_origin).dot(n) / d.dot(n))
			on_plane = on_axis
		a = on_axis if flip else on_plane
		b = on_plane if flip else on_axis
	else:
		var w := o1 - o2
		var along := d1.dot(d2)
		var den := d1.cross(d2).length_squared()
		if den < PARALLEL_SINE * PARALLEL_SINE:
			b = o2 + d2 * d2.dot(w)
		else:
			a = o1 + d1 * ((along * d2.dot(w) - d1.dot(w)) / den)
			b = o2 + d2 * ((d2.dot(w) - along * d1.dot(w)) / den)
	return {"distance": a.distance_to(b), "a": a, "b": b}


## {"shape" (for distances), "values", "direction"?, "dir_kind"?} for a reference, or {"error"}.
static func _geometry(ref: Dictionary, ctx: Dictionary, size: float) -> Dictionary:
	var kernel: RefCounted = ctx.kernel
	match str(ref.get("kind", "")):
		"body":
			var shape := REFERENCES.body_shape(ref, ctx)
			if shape == null:
				return {"error": "That body no longer exists"}
			var values := {"kind": "body", "volume": solid_volume(shape), "area": shape.area()}
			if shape_kind(shape) == "surface":
				values["surface"] = true
			return {"shape": shape, "values": values}
		"face":
			return _face(ref, ctx)
		"edge":
			return _edge(ref, ctx)
		"vertex", "sketch_point":
			var exact := _ref_point64(ref)
			if not exact.is_empty() and kernel.has_method("transform_shape64"):
				var placed: RefCounted = kernel.call("transform_shape64", kernel.make_vertex(Vector3.ZERO), XFORM.translation(exact[0], exact[1], exact[2]), TAG)
				if placed != null and not placed.is_null():
					return {"shape": placed, "values": {"kind": "point", "position": Vector3(exact[0], exact[1], exact[2])}}
			return _point(REFERENCES.point(ref, ctx), kernel)
		"origin":
			var name := str(ref.get("name", ""))
			if name == "o":
				return _point({"point": Vector3.ZERO}, kernel)
			if REFERENCES.ORIGIN_AXES.has(name):
				return _axis(REFERENCES.axis(ref, ctx), kernel, size)
			return _plane(REFERENCES.plane(ref, ctx), kernel, size)
		"construct":
			var c: Dictionary = ctx.construction.get(ref.get("feature", ""), {})
			match str(c.get("type", "")):
				"plane":
					return _plane(REFERENCES.plane(ref, ctx), kernel, size)
				"axis":
					return _axis(REFERENCES.axis(ref, ctx), kernel, size)
				"point":
					return _point(REFERENCES.point(ref, ctx), kernel)
			return {"error": "That construction geometry is missing"}
		"profile":
			var p := REFERENCES.profile(ref, ctx)
			if p.has("error"):
				return p
			var frame: Transform3D = p.plane
			return {"shape": p.face, "direction": frame.basis.z, "dir_kind": "plane", "values": {"kind": "profile", "area": p.face.area()}}
		"sketch_curve":
			return _curve(ref, ctx)
	return {"error": "That can't be measured"}


static func _face(ref: Dictionary, ctx: Dictionary) -> Dictionary:
	var found := REFERENCES.face(ref, ctx)
	if found.has("error"):
		return found
	var shape: RefCounted = found.shape
	var info: Dictionary = shape.face_info(found.index)
	var face_type := str(info.get("type", ""))
	var values := {"kind": "face", "face_type": face_type, "area": float(info.get("area", 0.0)), "point": info.get("point", Vector3.ZERO)}
	var geometry := {"shape": shape.face_shape(found.index), "values": values}
	if info.get("planar", false):
		values["normal"] = info.normal
		geometry["direction"] = info.normal
		geometry["dir_kind"] = "plane"
	# A cone's radius changes along it, so only constant radii are reported.
	if info.has("radius") and face_type != "cone":
		values["radius"] = float(info.radius)
		values["diameter"] = float(info.radius) * 2.0
	if info.has("minor_radius"):
		values["minor_radius"] = float(info.minor_radius)
	if info.has("center"):
		values["center"] = info.center
	if info.has("axis"):
		values["axis"] = info.axis
		geometry["direction"] = info.axis
		geometry["dir_kind"] = "line"
	return geometry


static func _edge(ref: Dictionary, ctx: Dictionary) -> Dictionary:
	var found := REFERENCES.edge(ref, ctx)
	if found.has("error"):
		return found
	var shape: RefCounted = found.shape
	var info: Dictionary = shape.edge_info(found.index)
	var edge_type := str(info.get("type", ""))
	var values := {"kind": "edge", "edge_type": edge_type, "length": float(info.get("length", 0.0)), "start": info.get("start", Vector3.ZERO), "end": info.get("end", Vector3.ZERO)}
	var geometry := {"shape": shape.edge_shape(found.index), "values": values}
	if edge_type == "line":
		var direction := ((info.end as Vector3) - (info.start as Vector3)).normalized()
		values["direction"] = direction
		geometry["direction"] = direction
		geometry["dir_kind"] = "line"
	elif edge_type == "circle":
		values["radius"] = float(info.radius)
		values["diameter"] = float(info.radius) * 2.0
		values["center"] = info.center
	return geometry


static func _point(found: Dictionary, kernel: RefCounted) -> Dictionary:
	if found.has("error"):
		return found
	var p: Vector3 = found.point
	return {"shape": kernel.make_vertex(p), "values": {"kind": "point", "position": p}}


static func _plane(found: Dictionary, kernel: RefCounted, size: float) -> Dictionary:
	if found.has("error"):
		return found
	var origin: Vector3 = found.origin
	var normal: Vector3 = (found.normal as Vector3).normalized()
	var face: RefCounted = kernel.plane_face(origin, normal, size + origin.length(), TAG)
	if face == null:
		return {"error": "The plane could not be made: %s" % kernel.get_last_error()}
	return {"shape": face, "direction": normal, "dir_kind": "plane", "infinite": true, "values": {"kind": "plane", "origin": origin, "normal": normal}}


static func _axis(found: Dictionary, kernel: RefCounted, size: float) -> Dictionary:
	if found.has("error"):
		return found
	var origin: Vector3 = found.origin
	var direction: Vector3 = (found.direction as Vector3).normalized()
	var line := line_shape(kernel, origin, direction, size + origin.length())
	if line == null:
		return {"error": "The axis could not be made: %s" % kernel.get_last_error()}
	return {"shape": line, "direction": direction, "dir_kind": "line", "infinite": true, "values": {"kind": "axis", "origin": origin, "direction": direction}}


## A straight line edge (as a wire) through origin along direction, reach long each way.
static func line_shape(kernel: RefCounted, origin: Vector3, direction: Vector3, reach: float) -> RefCounted:
	var x := direction.normalized()
	var y := x.cross(Vector3.UP if absf(x.y) < 0.9 else Vector3.RIGHT).normalized()
	var frame := Transform3D(Basis(x, y, x.cross(y)), origin)
	return kernel.sketch_wire([{"type": "line", "a": Vector2(-reach, 0.0), "b": Vector2(reach, 0.0)}], frame)


## A sketch curve reference ({"sketch", "entity"}) found in the regen result: {"curve" (a kernel
## curve dictionary in sketch coordinates), "frame" (the sketch plane, Transform3D)} or {"error"}.
## ctx needs "sketches" (the result's) and "doc"; construction geometry, which the solved curves
## leave out, is read from the sketch feature.
static func sketch_curve(ref: Dictionary, ctx: Dictionary) -> Dictionary:
	var sketch_id := str(ref.get("sketch", ""))
	var entity := int(ref.get("entity", -1))
	var state: Dictionary = (ctx.get("sketches", {}) as Dictionary).get(sketch_id, {})
	var doc: Resource = ctx.get("doc")
	var feature: Resource = doc.find_feature(sketch_id) if doc != null else null
	var curve := {}
	for c in state.get("curves", []):
		if int(c.get("entity", -1)) == entity:
			curve = c
			break
	var sketch = SKETCH_DATA.new(feature, doc) if feature != null else null
	if curve.is_empty() and sketch != null:
		curve = sketch.curve_of(entity)
	if curve.is_empty() or (state.is_empty() and sketch == null):
		return {"error": "That sketch curve is gone"}
	return {"curve": curve, "frame": state.plane if state.has("plane") else sketch.transform()}


static func _curve(ref: Dictionary, ctx: Dictionary) -> Dictionary:
	var found := sketch_curve(ref, ctx)
	if found.has("error"):
		return found
	var curve: Dictionary = found.curve
	var frame: Transform3D = found.frame
	var kernel: RefCounted = ctx.kernel
	var wire: RefCounted = kernel.sketch_wire([curve], frame)
	if wire == null or wire.is_null():
		return {"error": "The sketch curve could not be measured: %s" % kernel.get_last_error()}
	var values := {"kind": "curve", "length": UTIL.wire_length(wire)}
	var geometry := {"shape": wire, "values": values}
	match str(curve.get("type", "")):
		"circle", "arc":
			values["radius"] = float(curve.r)
			values["diameter"] = float(curve.r) * 2.0
		"line":
			var d: Vector2 = (curve.b as Vector2) - (curve.a as Vector2)
			var direction := (frame.basis * Vector3(d.x, d.y, 0.0)).normalized()
			values["direction"] = direction
			geometry["direction"] = direction
			geometry["dir_kind"] = "line"
	return geometry


# --- Posed bodies (C7.4) ---------------------------------------------------------------------

## A body's shape where pose (xform64) puts it: kernel.transform_shape64 for a B-rep shape and
## CadMesh.transformed64 for a mesh body (the pose in doubles, fix round 1 B4: a float32
## Transform3D is off by about 6e-5 m at 1 km), or the float32 transform_shape / MESH.transformed
## with a native library that lacks them; kept by (body, shape, pose bytes). The shape itself for
## an empty or identity pose, and when the move fails (pushed as a warning).
static func posed_shape(kernel: RefCounted, body_id: String, shape: RefCounted, pose: PackedFloat64Array) -> RefCounted:
	if shape == null or shape.is_null() or pose.size() != 12 or pose == XFORM.identity():
		return shape
	var key := "%s|%s" % [body_id, Marshalls.raw_to_base64(pose.to_byte_array())]
	var kept: Dictionary = _posed.get(key, {})
	if not kept.is_empty() and kept.source == shape:
		return kept.posed
	var posed: RefCounted = null
	if MESH_BODY.is_mesh(shape):
		posed = shape.call("transformed64", pose) if shape.has_method("transformed64") else MESH.transformed(shape, XFORM.to_transform(pose))
	elif kernel != null:
		posed = kernel.call("transform_shape64", shape, pose, TAG) if kernel.has_method("transform_shape64") else kernel.transform_shape(shape, XFORM.to_transform(pose), TAG)
	if posed == null or posed.is_null():
		push_warning("Holo Forge Inspect: body %s could not be posed; it is measured where it is modelled." % body_id)
		return shape
	if _posed.has(key):
		_posed.erase(key)
	elif _posed.size() >= POSED_KEEP:
		_posed.erase(_posed.keys()[0])
	_posed[key] = {"source": shape, "posed": posed}
	return posed


## bodies (id -> {"shape", ...}) with every posed body's shape moved by its pose (posed_shape);
## the same dictionary when poses is empty.
static func posed_bodies(kernel: RefCounted, bodies: Dictionary, poses: Dictionary) -> Dictionary:
	if poses.is_empty():
		return bodies
	var out := {}
	for id in bodies:
		var entry: Dictionary = bodies[id]
		var pose: Variant = poses.get(id)
		if pose is PackedFloat64Array and entry.get("shape") != null:
			entry = entry.duplicate()
			entry["shape"] = posed_shape(kernel, str(id), entry.shape, pose)
		out[id] = entry
	return out


## A reference whose modelled points ("point" of a vertex, "at" of a pick on a mesh, the lost-name
## signature's "point" and "normal") are moved by its body's pose; the same reference when the
## body has none.
## The points are moved in doubles (fix round 2, SB3): "point64" / "at64" (PackedFloat64Array 3)
## hold them, from the modelled ones (_exact_vertex()'s, else the Vector3), and the Vector3 keys
## are those rounded.
static func posed_ref(ref: Dictionary, poses: Dictionary) -> Dictionary:
	var pose: Variant = poses.get(ref.get("body", ""))
	if ref.is_empty() or not (pose is PackedFloat64Array) or (pose as PackedFloat64Array).size() != 12:
		return ref
	var xform := XFORM.to_transform(pose)
	var out := ref.duplicate(true)
	for key in ["point", "at"]:
		if out.get(key) is Vector3:
			var exact: Variant = out.get(key + "64")
			var from := PackedFloat64Array(exact) if exact is PackedFloat64Array and (exact as PackedFloat64Array).size() == 3 else _doubles3(out[key])
			var moved := XFORM.apply(pose, from)
			out[key + "64"] = moved
			out[key] = Vector3(moved[0], moved[1], moved[2])
	var sig: Variant = out.get("sig")
	if sig is Dictionary:
		if sig.get("point") is Vector3:
			sig["point"] = xform * (sig.point as Vector3)
		if sig.get("normal") is Vector3:
			sig["normal"] = xform.basis * (sig.normal as Vector3)
	return out


## Forgets the posed shapes kept.
static func clear_posed() -> void:
	_posed.clear()


# --- Interference ----------------------------------------------------------------------------

## Overlaps between bodies (id -> {"shape"}), every pair of body_ids (all bodies when empty):
## [{"a", "b", "volume", "shape" (the common solid)}]. Touching is not interference. Only solids
## overlap by a volume: surface bodies are left out and a body's open faces don't count. A pair
## the kernel can't intersect is listed with volume 0, shape null and "error".
##
## Mesh bodies: two closed ones overlap by their mesh intersection (the entry's "shape" is a
## CadMesh). More keys an entry with a mesh body can have:
##   "warning"      what the kernel says of the result: a body that crosses itself makes the
##                  volume wrong there ("<Body> crosses itself, ... Rebuild it first.").
##   "note"         a B-rep body was tessellated for it ("<Body> was tessellated for
##                  Interference."), and, for a round body or a thin overlap, how approximate the
##                  volume then is.
##   "approximate"  {"within": m3, "percent"} with that note: the volume may be off by up to this
##                  (a bound: the round sides' deviation, plus float rounding of the corners;
##                  given with a round B-rep side, or when it is ROUNDING_PERCENT or more).
##                  The overlap is worked out again with finer triangles while it is above
##                  APPROXIMATE_PERCENT and time is left.
##   "error"        the pair could not be worked out: the kernel's sentence (it names the body),
##                  or with "timed_out": true the deadline, or with "open": true an open mesh body
##                  whose bounds reach into the other body (it has no volume to overlap with; it
##                  is listed so that it does not read as "no interference").
## doc gives the bodies' names for those sentences (their ids without it). time_limit: seconds
## for all the pairs with a mesh body together; pairs it leaves out are listed with "timed_out",
## never dropped. Pairs of B-rep bodies are the kernel's own, as ever, with its own limit.
## poses ({body id: xform64}, C7.4): the bodies where they are posed; the overlaps are then in
## world space.
static func interference(kernel: RefCounted, bodies: Dictionary, body_ids: Array, doc: Resource = null, time_limit := INTERFERENCE_SECONDS, poses := {}) -> Array:
	var ids: Array = body_ids if not body_ids.is_empty() else bodies.keys()
	var found := []
	if kernel == null:
		return found
	if not poses.is_empty():
		var listed := {}
		for id in ids:
			if bodies.has(id):
				listed[id] = bodies[id]
		bodies = posed_bodies(kernel, listed, poses)
	var started := Time.get_ticks_msec()
	var solids := {}
	# Open mesh bodies (no volume): one whose bounds reach into another body is listed.
	var open := {}
	for id in ids:
		var shape: Variant = (bodies.get(id, {}) as Dictionary).get("shape")
		var solid := solid_shape(kernel, shape)
		if solid != null and not solid.is_null():
			solids[id] = solid
		elif MESH_BODY.is_mesh(shape) and not shape.is_null():
			open[id] = shape
	for i in ids.size():
		for j in range(i + 1, ids.size()):
			var a: RefCounted = solids.get(ids[i])
			var b: RefCounted = solids.get(ids[j])
			if a == null or b == null:
				if open.has(ids[i]) or open.has(ids[j]):
					var unknown := _open_pair(ids[i], ids[j], solids, open, doc)
					if not unknown.is_empty():
						found.append(unknown)
				continue
			# Boxes that only touch don't intersect, and touching isn't interference.
			if not (a.bbox() as AABB).intersects(b.bbox()):
				continue
			if MESH_BODY.is_mesh(a) or MESH_BODY.is_mesh(b):
				var hit := {}
				if time_limit - (Time.get_ticks_msec() - started) / 1000.0 < INTERFERENCE_LEAST:
					hit = _not_checked(time_limit)
				else:
					hit = _mesh_interference(a, b, MESH_BODY.body_name(doc, str(ids[i])), MESH_BODY.body_name(doc, str(ids[j])), started, time_limit)
				if hit.has("error") or hit.shape != null or bool(hit.get("unseen", false)):
					hit.merge({"a": ids[i], "b": ids[j]})
					found.append(hit)
				continue
			var common: RefCounted = kernel.boolean(a, b, 2, TAG)
			if common == null or common.is_null():
				found.append({"a": ids[i], "b": ids[j], "volume": 0.0, "shape": null, "error": kernel.get_last_error()})
				continue
			var volume: float = common.volume()
			if volume > INTERFERENCE_TOLERANCE * minf(a.volume(), b.volume()) + 1e-18:
				found.append({"a": ids[i], "b": ids[j], "volume": volume, "shape": common})
	return found


static func _not_checked(time_limit: float) -> Dictionary:
	return {"volume": 0.0, "shape": null, "timed_out": true, "error": NOT_CHECKED % String.num(time_limit, 1)}


## The entry for a pair with an open mesh body in it, when their bounds reach into each other
## ({} otherwise, and for a pair with a B-rep surface or a missing body, which stay left out).
static func _open_pair(id_a: Variant, id_b: Variant, solids: Dictionary, open: Dictionary, doc: Resource) -> Dictionary:
	var a: Variant = solids.get(id_a, open.get(id_a))
	var b: Variant = solids.get(id_b, open.get(id_b))
	if a == null or b == null or not (a.bbox() as AABB).intersects(b.bbox() as AABB):
		return {}
	# Each such body with its own reason and remedy (open, wrong-way triangles, no volume).
	var reasons := PackedStringArray()
	for id in [id_a, id_b]:
		if open.has(id):
			reasons.append(MESH_BODY.no_volume_reason(open[id], MESH_BODY.body_name(doc, str(id))))
	return {"a": id_a, "b": id_b, "volume": 0.0, "shape": null, "open": true, "error": " ".join(reasons)}


## The overlap of two solid bodies of which at least one is a mesh body: {"volume", "shape" (a
## CadMesh, null when they don't overlap), and "warning", "note", "approximate", "error",
## "timed_out" as interference() lists them}. started (Time.get_ticks_msec) and time_limit are
## the whole call's: everything here runs in what is left of it.
static func _mesh_interference(a: RefCounted, b: RefCounted, name_a: String, name_b: String, started: int, time_limit: float) -> Dictionary:
	var left := func() -> float: return time_limit - (Time.get_ticks_msec() - started) / 1000.0
	var sides := [[a, name_a], [b, name_b]]
	var meshes := [null, null]
	# For a tessellated B-rep side: the preset it is at, and whether it has a round face (a
	# flat-sided body's triangles are exact).
	var preset := [-1, -1]
	var round := [false, false]
	var notes := PackedStringArray()
	for k in 2:
		var shape: RefCounted = sides[k][0]
		if MESH_BODY.is_mesh(shape):
			meshes[k] = shape
			continue
		# A coarse preset first; the kernel refuses a result that is off, and the next one is tried.
		var made := {}
		for index in MESH_PRESETS.size():
			if left.call() < INTERFERENCE_LEAST:
				return _not_checked(time_limit)
			made = MESH.tessellated(shape, MESH_PRESETS[index], left.call())
			if not made.has("error"):
				preset[k] = index
				break
		if made.has("error"):
			if left.call() < INTERFERENCE_LEAST:
				return _not_checked(time_limit)
			return {"volume": 0.0, "shape": null, "error": "%s could not be tessellated for Interference: %s" % [sides[k][1], made.error]}
		meshes[k] = made.mesh
		round[k] = _has_round_group(made.mesh)
		notes.append(MESH_BODY.TESSELLATED_FOR % [sides[k][1], "Interference"])
	var hit := {}
	# The presets the result in hit was worked out with (the bound is theirs, not a finer one's
	# that was tessellated but not used before the time ran out).
	var used := preset.duplicate()
	# True when no overlap was found although the bodies come within the tessellation's deviation.
	var near := false
	# Worked out again with finer triangles while a round B-rep side leaves the volume too loose
	# (or no overlap was found though the bodies nearly touch: a thin one slips between triangles).
	while true:
		if left.call() < INTERFERENCE_LEAST:
			if hit.is_empty():
				return _not_checked(time_limit)
			break
		var now := MESH_BODY.interference(meshes[0], meshes[1], left.call(), name_a, name_b)
		if now.has("error"):
			if hit.is_empty():
				hit = now
				# Out of time. The kernel's own sentence stands when the pair had most of the call's
				# time to itself (it is too big by itself: "... Reduce the bodies first."); otherwise
				# the earlier pairs used the time up.
				if left.call() < INTERFERENCE_LEAST or str(now.error).contains("took longer") or str(now.error).contains("would take"):
					hit["timed_out"] = true
					if left.call() < time_limit * 0.75:
						hit = _not_checked(time_limit)
			break
		hit = now
		used = preset.duplicate()
		var loose := false
		if hit.shape == null:
			near = (round[0] or round[1]) and _nearly_touch(sides, meshes, preset, round, left.call())
			loose = near
		else:
			near = false
			loose = _approximate(sides, preset, round, hit).percent > APPROXIMATE_PERCENT
		if not loose:
			break
		var finer := false
		for k in 2:
			if not round[k] or preset[k] < 0 or preset[k] + 1 >= MESH_PRESETS.size() or left.call() < 1.0:
				continue
			var made: Dictionary = MESH.tessellated(sides[k][0], MESH_PRESETS[preset[k] + 1], left.call())
			if made.has("error"):
				continue
			meshes[k] = made.mesh
			preset[k] += 1
			finer = true
		if not finer:
			break
	if hit.get("shape") == null and not hit.has("error") and near:
		# Nothing found, but the surfaces are nearer than the triangles are true to them.
		hit["unseen"] = true
		notes.append("No overlap was found, but the bodies come within about %s mm of each other: an overlap thinner than that is not seen." % String.num(_deviation(sides, used, round) * 1000.0, 4))
	if hit.get("shape") != null:
		# Round B-rep sides are only near their surfaces; and every mesh keeps its corners to float
		# precision, so a thin overlap can be off by a share of itself even between flat sides.
		var approximate := _approximate(sides, used, round, hit)
		approximate.within += _rounding(meshes, hit)
		approximate.percent = approximate.within / float(hit.volume) * 100.0 if float(hit.volume) > 0.0 else INF
		if round[0] or round[1] or approximate.percent >= ROUNDING_PERCENT:
			hit["approximate"] = approximate
			if approximate.percent >= 100.0:
				notes.append("The volume is approximate: the overlap is so thin that it may be off by more than itself.")
			elif round[0] or round[1]:
				notes.append("The volume is approximate: within about %s %%." % _percent_text(approximate.percent))
			else:
				notes.append("The volume is approximate: within about %s %% (the triangles' corners are kept to float precision, and the overlap is thin)." % _percent_text(approximate.percent))
	if not notes.is_empty():
		hit["note"] = " ".join(notes)
	return hit


## How far the overlap's volume may be off because round B-rep sides were tessellated:
## {"within": m3, "percent": of the volume}. A bound: each such side's surface deviation (its
## Tessellate preset's) times the overlap's area.
static func _approximate(sides: Array, preset: Array, round: Array, hit: Dictionary) -> Dictionary:
	var within := _deviation(sides, preset, round) * float(hit.shape.area())
	var volume := float(hit.volume)
	return {"within": within, "percent": within / volume * 100.0 if volume > 0.0 else INF}


## How far the overlap's volume may be off because the meshes keep their corners as floats (m3):
## each corner of the two bodies and of the overlap may be off by half a float step of the largest
## coordinate along each axis, so the overlap's surface may sit that far off (three times: the
## two bodies and the overlap itself), times its area.
static func _rounding(meshes: Array, hit: Dictionary) -> float:
	var reach := 0.0
	for mesh in meshes + [hit.shape]:
		var box: AABB = (mesh as RefCounted).bbox()
		for corner in [box.position, box.end]:
			reach = maxf(reach, maxf(absf(corner.x), maxf(absf(corner.y), absf(corner.z))))
	var step := sqrt(3.0) * reach * pow(2.0, -24.0)
	return 3.0 * step * float(hit.shape.area())


## A share in percent as an upper bound: whole percent from 1 % up, two decimals below it.
static func _percent_text(percent: float) -> String:
	if percent >= 1.0:
		return String.num(ceilf(percent), 0)
	return String.num(maxf(ceilf(percent * 100.0) / 100.0, 0.01), 2)


## How far the triangles of the tessellated round B-rep sides may be from their surfaces (m): each
## side's Tessellate preset's surface deviation, added up.
static func _deviation(sides: Array, preset: Array, round: Array) -> float:
	var deviation := 0.0
	for k in 2:
		if round[k] and preset[k] >= 0:
			var size: float = ((sides[k][0] as RefCounted).bbox() as AABB).size.length()
			deviation += size * float(MESH.TESSELLATE_PRESETS[MESH_PRESETS[preset[k]]][0])
	return deviation


## True when two bodies that show no overlap come within the tessellation's deviation of each
## other: the tessellated round sides, grown by twice that deviation about their middles, do
## overlap the other body. (Then a thin overlap may have slipped between the triangles.)
static func _nearly_touch(sides: Array, meshes: Array, preset: Array, round: Array, time_left: float) -> bool:
	var deviation := _deviation(sides, preset, round)
	if deviation <= 0.0 or time_left < INTERFERENCE_LEAST:
		return false
	var grown := [meshes[0], meshes[1]]
	for k in 2:
		if not round[k] or preset[k] < 0:
			continue
		var box: AABB = (meshes[k] as RefCounted).bbox()
		var least := maxf(minf(box.size.x, minf(box.size.y, box.size.z)), 1e-9)
		var factor := 1.0 + 4.0 * deviation / least
		var middle := box.get_center()
		grown[k] = (meshes[k] as RefCounted).transformed(Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * factor), middle - middle * factor))
	var probe := MESH_BODY.interference(grown[0], grown[1], time_left)
	return probe.get("shape") != null


## True when a tessellated body has a face group that is not flat (so its triangles only come
## near the B-rep body's surface).
static func _has_round_group(mesh: RefCounted) -> bool:
	var count := int(mesh.face_count())
	if count > FLAT_CHECK_GROUPS:
		return true
	for i in count:
		if not bool(mesh.face_info(i).get("planar", false)):
			return true
	return false


## Adds overlaps (BRep bytes, CadShape.to_brep_bytes, one per overlap) to doc as one base feature
## "Interference" with a body per overlap. With as_components each body goes into a new component
## of its own (inside the active one) named "Interference 1", "Interference 2", ... (numbered
## across the document). Call it inside one doc change for a single undo step. Returns
## {"feature", "bodies": [body ids], "components": [component ids, in the same order]}.
static func add_overlaps(doc: Resource, breps: Array, as_components: bool) -> Dictionary:
	var feature: Resource = doc.add_feature("base_feature", "Interference", {}, {})
	var by_body := {}
	var body_ids := []
	var component_ids := []
	for bytes in breps:
		var body_id: String = doc.new_body(feature.id)
		by_body[body_id] = bytes
		body_ids.append(body_id)
		if as_components:
			var component_id: String = doc.new_component(feature.id)
			doc.components[component_id]["name"] = "Interference %d" % doc.next_number("interference_component")
			doc.bodies[body_id]["component"] = component_id
			component_ids.append(component_id)
	feature.options["breps"] = by_body
	return {"feature": feature, "bodies": body_ids, "components": component_ids}


# --- Mass properties -------------------------------------------------------------------------

## What a body shape holds: "solid" (a solid, or only solids), "surface" (no solids: an open mesh,
## a shell or loose faces) or "mixed" (solids and open faces besides them).
static func shape_kind(shape: RefCounted) -> String:
	if MESH_BODY.is_mesh(shape):
		return MESH_BODY.shape_kind(shape)
	if shape == null or shape.is_null():
		return "surface"
	if str(shape.shape_type()) == "SOLID":
		return "solid"
	if int(shape.solid_count()) == 0:
		return "surface"
	var faces := 0
	for solid in shape.solids():
		faces += int(solid.face_count())
	# Solids sharing faces (a compsolid) count those twice; open faces add to the shape's own count.
	return "solid" if faces >= int(shape.face_count()) else "mixed"


## The volume of a shape's solids (m^3): 0 for a surface, the solids' sum for a mixed shape.
static func solid_volume(shape: RefCounted) -> float:
	if MESH_BODY.is_mesh(shape):
		return MESH_BODY.solid_volume(shape)
	match shape_kind(shape):
		"solid":
			return shape.volume()
		"mixed":
			var total := 0.0
			for solid in shape.solids():
				total += float(solid.volume())
			return total
	return 0.0


## A shape's solids as one shape: the shape itself when it holds only solids, a compound of its
## solids when it has open faces too, null for a surface.
static func solid_shape(kernel: RefCounted, shape: RefCounted) -> RefCounted:
	match shape_kind(shape):
		"solid":
			return shape
		"mixed":
			return kernel.make_compound(shape.solids()) if kernel != null else null
	return null


## CadShape.mass_properties() of a body shape's solids only, in the same form ({"mass", "volume",
## "area", "center", "inertia", "principal_moments"}). A surface has no mass or volume, and its
## center is its area's centroid; a mixed shape combines its solids (area stays the whole shape's).
static func shape_mass_properties(shape: RefCounted, density: float) -> Dictionary:
	if MESH_BODY.is_mesh(shape):
		# (A closed mesh has the mass of its volume; an open one none, and "warning" says so.)
		return MESH_BODY.mass_properties(shape, density)
	var kind := shape_kind(shape)
	if kind == "solid":
		return shape.mass_properties(density)
	var none := PackedFloat64Array()
	none.resize(9)
	none.fill(0.0)
	var area: float = shape.area() if shape != null and not shape.is_null() else 0.0
	if kind == "surface":
		return {"mass": 0.0, "volume": 0.0, "area": area, "center": area_center(shape), "inertia": none, "principal_moments": Vector3.ZERO}
	var parts := {}
	var mass := 0.0
	var volume := 0.0
	# Volume-weighted sums in doubles (Vector3 is single precision).
	var moment := PackedFloat64Array([0.0, 0.0, 0.0])
	for solid in shape.solids():
		var p: Dictionary = solid.mass_properties(density)
		var part := {"mass": float(p.get("mass", 0.0)), "center": p.get("center", Vector3.ZERO), "inertia": PackedFloat64Array(p.get("inertia", none))}
		parts[parts.size()] = part
		mass += part.mass
		var v := float(p.get("volume", 0.0))
		volume += v
		for k in 3:
			moment[k] += v * (part.center as Vector3)[k]
	var center := area_center(shape)
	if volume > 0.0:
		center = Vector3(moment[0] / volume, moment[1] / volume, moment[2] / volume)
	var inertia := _combined_inertia(parts, center)
	return {"mass": mass, "volume": volume, "area": area, "center": center, "inertia": inertia, "principal_moments": principal_moments(inertia)}


## The area-weighted centroid of a shape's surface, integrated exactly by the kernel (as its area);
## the middle of its box when it has no faces.
static func area_center(shape: RefCounted) -> Vector3:
	if MESH_BODY.is_mesh(shape):
		return MESH_BODY.area_center(shape)
	if shape == null or shape.is_null():
		return Vector3.ZERO
	if not float(shape.area()) > 0.0:
		return (shape.bbox() as AABB).get_center()
	return shape.area_center()


## The eigenvalues of a symmetric 3 x 3 inertia matrix (9 floats, row-major), smallest first.
static func principal_moments(inertia: PackedFloat64Array) -> Vector3:
	if inertia.size() != 9:
		return Vector3.ZERO
	var a := inertia
	var off := a[1] * a[1] + a[2] * a[2] + a[5] * a[5]
	var values := [a[0], a[4], a[8]]
	if off > 0.0:
		# The closed form for symmetric matrices: B = (A - qI) / p has eigenvalues 2 cos(phi + 2k pi / 3).
		var q := (a[0] + a[4] + a[8]) / 3.0
		var p := sqrt(((a[0] - q) * (a[0] - q) + (a[4] - q) * (a[4] - q) + (a[8] - q) * (a[8] - q) + 2.0 * off) / 6.0)
		var b := PackedFloat64Array()
		for i in 9:
			b.append((a[i] - (q if i % 4 == 0 else 0.0)) / p)
		var det := b[0] * (b[4] * b[8] - b[5] * b[7]) - b[1] * (b[3] * b[8] - b[5] * b[6]) + b[2] * (b[3] * b[7] - b[4] * b[6])
		var phi := acos(clampf(det * 0.5, -1.0, 1.0)) / 3.0
		var largest := q + 2.0 * p * cos(phi)
		var smallest := q + 2.0 * p * cos(phi + TAU / 3.0)
		values = [smallest, 3.0 * q - largest - smallest, largest]
	values.sort()
	return Vector3(values[0], values[1], values[2])


## Mass properties of body_ids (all bodies of the regen result when empty), with each body's
## physical material density (shape_mass_properties: only solids have mass):
## {"bodies": {id: {"mass" (kg), "volume", "area", "center", "density", "material", "inertia"
## (9 floats about the body's center, row-major, kg m^2), "principal_moments"; a mesh body with
## something wrong also has "flaws", "wrong_way_edges", "inside_out_parts", "self_intersections"
## and "warning" (MESH_BODY.mass_properties)}}, "warnings" (only when a body has one: "<Body>:
## <warning>" for each), "mass",
## "volume", "area", "center" (mass-weighted; area-weighted when nothing has mass), "center64"
## (the same in doubles; each body's entry has one too), "inertia" (9 floats about the total
## center)}.
## poses ({body id: xform64}, C7.4): each posed body's center is moved and its inertia turned by
## its pose (world space); mass, volume, area and principal moments don't change.
static func mass_properties(doc: Resource, result: Dictionary, body_ids: Array, poses := {}) -> Dictionary:
	var bodies: Dictionary = result.get("bodies", {})
	var ids: Array = body_ids if not body_ids.is_empty() else bodies.keys()
	var per_body := {}
	var mass := 0.0
	var volume := 0.0
	var area := 0.0
	# Weighted sums in doubles (Vector3 is single precision).
	var moment := PackedFloat64Array([0.0, 0.0, 0.0])
	var area_moment := PackedFloat64Array([0.0, 0.0, 0.0])
	var warnings := PackedStringArray()
	for id in ids:
		var body: Dictionary = bodies.get(id, {})
		if body.get("shape") == null:
			continue
		var material := PHYSICAL.material_for(doc, str(id))
		var density := PHYSICAL.density(material)
		var props: Dictionary = shape_mass_properties(body.shape, density)
		props["center64"] = center64(body.shape, props, density)
		var pose: Variant = poses.get(id)
		if pose is PackedFloat64Array and (pose as PackedFloat64Array).size() == 12 and pose != XFORM.identity():
			props = posed_mass(props, pose)
		var c64: PackedFloat64Array = props.center64
		var center := Vector3(c64[0], c64[1], c64[2])
		var entry := {
			"mass": float(props.get("mass", 0.0)), "volume": float(props.get("volume", 0.0)), "area": float(props.get("area", 0.0)),
			"center": center, "center64": c64, "density": density, "material": material,
			"inertia": PackedFloat64Array(props.get("inertia", [])), "principal_moments": props.get("principal_moments", Vector3.ZERO),
		}
		# What is wrong with a mesh body (open, inside-out, crossing itself, ...), and its warning.
		for key in MESH_BODY.FLAW_KEYS:
			if props.has(key):
				entry[key] = props[key]
		if entry.has("warning"):
			warnings.append("%s: %s" % [MESH_BODY.body_name(doc, str(id)), str(entry.warning)])
		per_body[id] = entry
		mass += entry.mass
		volume += entry.volume
		area += entry.area
		for k in 3:
			moment[k] += entry.mass * c64[k]
			area_moment[k] += entry.area * c64[k]
	var total64 := PackedFloat64Array([0.0, 0.0, 0.0])
	if mass > 0.0:
		total64 = PackedFloat64Array([moment[0] / mass, moment[1] / mass, moment[2] / mass])
	elif area > 0.0:
		total64 = PackedFloat64Array([area_moment[0] / area, area_moment[1] / area, area_moment[2] / area])
	var total_center := Vector3(total64[0], total64[1], total64[2])
	var totals := {
		"bodies": per_body, "mass": mass, "volume": volume, "area": area, "center": total_center, "center64": total64,
		"inertia": _combined_inertia(per_body, total64),
	}
	# ("<Body>: <what is wrong with it>" for each flawed mesh body; no key when all are sound.)
	if not warnings.is_empty():
		totals["warnings"] = warnings
	return totals


## Mass properties ({"center", "inertia", ...}) of a body moved by pose (xform64): the center moved
## (in doubles), the inertia turned (R I Rᵀ); the rest as it is.
static func posed_mass(props: Dictionary, pose: PackedFloat64Array) -> Dictionary:
	var out := props.duplicate()
	var c: Vector3 = props.get("center", Vector3.ZERO)
	var c64: Variant = props.get("center64")
	var from := PackedFloat64Array(c64) if c64 is PackedFloat64Array and (c64 as PackedFloat64Array).size() == 3 else PackedFloat64Array([c.x, c.y, c.z])
	var moved := XFORM.apply(pose, from)
	out["center"] = Vector3(moved[0], moved[1], moved[2])
	out["center64"] = moved
	var inertia := PackedFloat64Array(props.get("inertia", []))
	if inertia.size() == 9:
		# R's columns are the pose's basis columns: R[row][col] = pose[col * 3 + row].
		var turned := PackedFloat64Array()
		turned.resize(9)
		for row in 3:
			for col in 3:
				var sum := 0.0
				for i in 3:
					for j in 3:
						sum += pose[i * 3 + row] * inertia[i * 3 + j] * pose[j * 3 + col]
				turned[row * 3 + col] = sum
		out["inertia"] = turned
	return out


## Every body's inertia moved to the shared center (parallel axis theorem) and summed. center is a
## Vector3 or a PackedFloat64Array of 3; an entry's "center64" is used when it has one (doubles).
static func _combined_inertia(per_body: Dictionary, center: Variant) -> PackedFloat64Array:
	var total := PackedFloat64Array()
	total.resize(9)
	total.fill(0.0)
	var at := _doubles3(center)
	for id in per_body:
		var entry: Dictionary = per_body[id]
		var inertia: PackedFloat64Array = entry.inertia
		var own := _doubles3(entry.get("center64", entry.get("center", Vector3.ZERO)))
		var d := PackedFloat64Array([own[0] - at[0], own[1] - at[1], own[2] - at[2]])
		var d2 := d[0] * d[0] + d[1] * d[1] + d[2] * d[2]
		var m := float(entry.mass)
		for row in 3:
			for col in 3:
				var shift := m * ((d2 if row == col else 0.0) - d[row] * d[col])
				total[row * 3 + col] += (inertia[row * 3 + col] if inertia.size() == 9 else 0.0) + shift
	return total


## A point as 3 doubles: a Vector3, or a PackedFloat64Array of 3 (else the origin).
static func _doubles3(p: Variant) -> PackedFloat64Array:
	if p is Vector3:
		return PackedFloat64Array([(p as Vector3).x, (p as Vector3).y, (p as Vector3).z])
	if p is PackedFloat64Array and (p as PackedFloat64Array).size() == 3:
		return PackedFloat64Array(p)
	return PackedFloat64Array([0.0, 0.0, 0.0])


## A body's center (props from shape_mass_properties) in doubles (fix round 2, PT3): CadShape and
## CadMesh give it as a float32 Vector3, which steps by about 6e-5 m 1 km out; a center
## RECENTER_M or more from the origin is measured again on a copy of the shape moved by
## -center in doubles (transform_shape64 / transformed64) and added back. Without those (an older
## native library) it is props' center as it is.
static func center64(shape: RefCounted, props: Dictionary, density: float) -> PackedFloat64Array:
	var c: Vector3 = props.get("center", Vector3.ZERO)
	var out := PackedFloat64Array([c.x, c.y, c.z])
	if shape == null or shape.is_null() or not c.is_finite() or c.length() < RECENTER_M:
		return out
	var back := XFORM.translation(-out[0], -out[1], -out[2])
	var moved: RefCounted = null
	if MESH_BODY.is_mesh(shape):
		if shape.has_method("transformed64"):
			moved = shape.call("transformed64", back)
	else:
		if _center_kernel == null and ClassDB.class_exists("CadKernel"):
			_center_kernel = ClassDB.instantiate("CadKernel")
		if _center_kernel != null and _center_kernel.has_method("transform_shape64"):
			moved = _center_kernel.call("transform_shape64", shape, back, TAG)
	if moved == null or moved.is_null():
		return out
	var local: Variant = shape_mass_properties(moved, density).get("center")
	if not (local is Vector3) or not (local as Vector3).is_finite():
		return out
	return PackedFloat64Array([out[0] + (local as Vector3).x, out[1] + (local as Vector3).y, out[2] + (local as Vector3).z])
