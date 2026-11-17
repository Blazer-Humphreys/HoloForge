@tool
extends RefCounted
## Construction planes, axes and points. feature.type is "plane", "axis" or "point" and
## options.method says how it is made; the result goes to ctx.construction[feature id] as
## {"type": "plane", "origin", "normal", "x"} | {"type": "axis", "origin", "direction"} |
## {"type": "point", "position"} for later features to reference.
##
## Planes: offset (plane; distance), angle (axis; angle), tangent (face, optional plane; angle),
## midplane (plane, plane2), perpendicular (axis, optional point), two_edges (axis, axis2),
## three_points (points), tangent_at_point (face, point), along_path (path; distance 0..1).
## Axes: cylinder (face), perp_at_point (face, point), two_planes (plane, plane2), two_points
## (point, point2), edge (axis), perp_face_point (face, point).
## Points: vertex (point), two_edges (axis, axis2), three_planes (plane, plane2, plane3),
## center (center), edge_plane (axis, plane), along_path (path; distance 0..1).

const UTIL := preload("res://addons/holo_forge/core/features/util.gd")
const REFERENCES := preload("res://addons/holo_forge/core/references.gd")
const SKETCH_DATA := preload("res://addons/holo_forge/core/sketch/sketch_data.gd")

const METHODS := {
	"plane": ["offset", "angle", "tangent", "midplane", "perpendicular", "two_edges", "three_points", "tangent_at_point", "along_path"],
	"axis": ["cylinder", "perp_at_point", "two_planes", "two_points", "edge", "perp_face_point"],
	"point": ["vertex", "two_edges", "three_planes", "center", "edge_plane", "along_path"],
}


static func build(feature: Resource, ctx: Dictionary) -> String:
	var r := UTIL.Reader.new(feature, ctx)
	var result := {}
	match feature.type:
		"plane":
			result = _plane(r)
			if not result.is_empty():
				var n: Vector3 = (result.normal as Vector3).normalized()
				result = {"type": "plane", "origin": result.origin, "normal": n, "x": SKETCH_DATA.face_plane(result.origin, n).x}
		"axis":
			result = _axis(r)
			if not result.is_empty():
				result = {"type": "axis", "origin": result.origin, "direction": (result.direction as Vector3).normalized()}
		"point":
			result = _point(r)
			if not result.is_empty():
				result = {"type": "point", "position": result.position}
		_:
			return "Unknown construction '%s'" % feature.type
	if not r.ok():
		return r.error
	if result.is_empty():
		return "The construction could not be made"
	for key in result:
		if result[key] is Vector3 and not (result[key] as Vector3).is_finite():
			return "The picks don't define a %s" % feature.type
	if result.has("normal") and (result.normal as Vector3).is_zero_approx() or result.has("direction") and (result.direction as Vector3).is_zero_approx():
		return "The picks don't define a %s" % feature.type
	ctx.construction[feature.id] = result
	UTIL._warn(r)
	return ""


static func _plane(r: UTIL.Reader) -> Dictionary:
	match str(r.opt("method", "offset")):
		"offset":
			var base := r.plane("plane")
			var distance := r.num("distance", 0.0)
			if not r.ok():
				return {}
			return {"origin": (base.origin as Vector3) + (base.normal as Vector3) * distance, "normal": base.normal}
		"angle":
			var axis := r.axis("axis")
			var angle := r.num("angle", 0.0)
			if not r.ok():
				return {}
			var d: Vector3 = (axis.direction as Vector3).normalized()
			var base := _perpendicular(d, _plane_normal_near(r, r.ref("axis")))
			return {"origin": axis.origin, "normal": base.rotated(d, angle)}
		"tangent":
			var found := _round_face(r, "face")
			var angle := r.num("angle", 0.0)
			if found.is_empty() or not r.ok():
				return {}
			var reference := Vector3.ZERO
			if not r.ref("plane").is_empty():
				var p := r.plane("plane")
				reference = p.get("normal", Vector3.ZERO)
			var radial := _perpendicular(found.axis, reference).rotated(found.axis, angle)
			return {"origin": (found.center as Vector3) + radial * float(found.radius), "normal": radial}
		"midplane":
			var a := r.plane("plane")
			var b := r.plane("plane2")
			if not r.ok():
				return {}
			var n1: Vector3 = a.normal
			var n2: Vector3 = b.normal
			var o1: Vector3 = a.origin
			var o2: Vector3 = b.origin
			var n := n1 - n2
			if n.length() < 1e-6:
				return {"origin": (o1 + o2) * 0.5, "normal": n1}
			# Points as far inside one plane as the other: p . (n1 - n2) = o1 . n1 - o2 . n2.
			var c := o1.dot(n1) - o2.dot(n2)
			return {"origin": n * (c / n.length_squared()), "normal": n.normalized()}
		"perpendicular":
			var axis := r.axis("axis")
			var at := r.point("point", axis.get("origin", Vector3.ZERO))
			if not r.ok():
				return {}
			return {"origin": at, "normal": axis.direction}
		"two_edges":
			var a := r.axis("axis")
			var b := r.axis("axis2")
			if not r.ok():
				return {}
			var d1: Vector3 = a.direction
			var n := d1.cross((b.origin as Vector3) - (a.origin as Vector3))
			if n.length() < 1e-9:
				n = d1.cross(b.direction)
			if absf(n.normalized().dot((b.direction as Vector3).normalized())) > 1e-6:
				r.fail("The two edges don't lie in one plane")
				return {}
			return {"origin": a.origin, "normal": n}
		"three_points":
			var points := r.points("points")
			if r.ok() and points.size() < 3:
				r.fail("Select three points")
			if not r.ok():
				return {}
			var n := (points[1] - points[0]).cross(points[2] - points[0])
			if n.length() < 1e-12:
				r.fail("The three points are in a line")
				return {}
			return {"origin": points[0], "normal": n}
		"tangent_at_point", "along_path":
			var at := _point_on(r)
			if at.is_empty():
				return {}
			return {"origin": at.point, "normal": at.normal}
	r.fail("Unknown plane method")
	return {}


static func _axis(r: UTIL.Reader) -> Dictionary:
	match str(r.opt("method", "cylinder")):
		"cylinder":
			var found := _round_face(r, "face")
			if found.is_empty():
				return {}
			return {"origin": found.center, "direction": found.axis}
		"perp_at_point", "perp_face_point":
			var at := _point_on(r)
			if at.is_empty():
				return {}
			return {"origin": at.point, "direction": at.normal}
		"two_planes":
			var a := r.plane("plane")
			var b := r.plane("plane2")
			if not r.ok():
				return {}
			var n1: Vector3 = a.normal
			var n2: Vector3 = b.normal
			var d := n1.cross(n2)
			if d.length() < 1e-9:
				r.fail("The planes are parallel")
				return {}
			var c1 := n1.dot(a.origin)
			var c2 := n2.dot(b.origin)
			return {"origin": (n2.cross(d) * c1 + d.cross(n1) * c2) / d.length_squared(), "direction": d}
		"two_points":
			var a := r.point("point")
			var b := r.point("point2")
			if not r.ok():
				return {}
			if a.distance_to(b) < 1e-12:
				r.fail("The points are the same")
				return {}
			return {"origin": a, "direction": b - a}
		"edge":
			return r.axis("axis")
	r.fail("Unknown axis method")
	return {}


static func _point(r: UTIL.Reader) -> Dictionary:
	match str(r.opt("method", "vertex")):
		"vertex":
			var p := r.point("point")
			return {"position": p} if r.ok() else {}
		"two_edges":
			var a := r.axis("axis")
			var b := r.axis("axis2")
			if not r.ok():
				return {}
			var d1: Vector3 = a.direction
			var d2: Vector3 = b.direction
			var w: Vector3 = (a.origin as Vector3) - (b.origin as Vector3)
			var bb := d1.dot(d2)
			var den := d1.dot(d1) * d2.dot(d2) - bb * bb
			if absf(den) < 1e-12:
				r.fail("The edges are parallel")
				return {}
			var t := (bb * d2.dot(w) - d2.dot(d2) * d1.dot(w)) / den
			var s := (d1.dot(d1) * d2.dot(w) - bb * d1.dot(w)) / den
			return {"position": ((a.origin as Vector3) + d1 * t + (b.origin as Vector3) + d2 * s) * 0.5}
		"three_planes":
			var planes := [r.plane("plane"), r.plane("plane2"), r.plane("plane3")]
			if not r.ok():
				return {}
			var n1: Vector3 = planes[0].normal
			var n2: Vector3 = planes[1].normal
			var n3: Vector3 = planes[2].normal
			var den := n1.dot(n2.cross(n3))
			if absf(den) < 1e-12:
				r.fail("The three planes don't meet in one point")
				return {}
			var c := [n1.dot(planes[0].origin), n2.dot(planes[1].origin), n3.dot(planes[2].origin)]
			return {"position": (n2.cross(n3) * c[0] + n3.cross(n1) * c[1] + n1.cross(n2) * c[2]) / den}
		"center":
			var pick := r.ref("center")
			if pick.is_empty():
				r.fail("Select a circle, sphere or torus")
				return {}
			if pick.get("kind", "") == "face":
				var found := _round_face(r, "center")
				return {"position": found.center} if not found.is_empty() else {}
			var p := r.point("center")
			return {"position": p} if r.ok() else {}
		"edge_plane":
			var axis := r.axis("axis")
			var plane := r.plane("plane")
			if not r.ok():
				return {}
			var d: Vector3 = axis.direction
			var n: Vector3 = plane.normal
			if absf(d.dot(n)) < 1e-9:
				r.fail("The edge runs parallel to the plane")
				return {}
			var t := ((plane.origin as Vector3) - (axis.origin as Vector3)).dot(n) / d.dot(n)
			return {"position": (axis.origin as Vector3) + d * t}
		"along_path":
			var at := _point_on(r)
			return {"position": at.point} if not at.is_empty() else {}
	r.fail("Unknown point method")
	return {}


# --- Helpers ---------------------------------------------------------------------------------

## A point with a normal: on a face at a picked point (tangent_at_point, perp_*) or along a path
## at a fraction of its length (along_path; the normal is the path's direction).
static func _point_on(r: UTIL.Reader) -> Dictionary:
	if str(r.opt("method", "")) == "along_path":
		var wire := r.path("path")
		var t := r.num("distance", 0.5)
		if not r.ok():
			return {}
		var at := UTIL.along_wire(wire, t)
		return {"point": at.point, "normal": at.tangent}
	var at := r.point("point")
	var pick := r.ref("face")
	if pick.is_empty():
		r.fail("Select a face")
	if not r.ok():
		return {}
	var found := REFERENCES.face(pick, r.ctx)
	if found.has("error"):
		r.fail(found.error)
		return {}
	r.repaired += 1 if found.repaired else 0
	var info: Dictionary = found.shape.face_info(found.index)
	if info.get("planar", false):
		# Flat faces: the picked point dropped onto the face's plane.
		var n: Vector3 = info.normal
		return {"point": at - n * (at - (info.point as Vector3)).dot(n), "normal": n}
	return {"point": at, "normal": found.shape.face_normal_at(found.index, at)}


## {"center", "axis", "radius"} of a cylinder, cone, sphere or torus face, or {} after fail().
static func _round_face(r: UTIL.Reader, key: String) -> Dictionary:
	var pick := r.ref(key)
	if pick.is_empty() or pick.get("kind", "") != "face":
		r.fail("Select a round face")
		return {}
	var found := REFERENCES.face(pick, r.ctx)
	if found.has("error"):
		r.fail(found.error)
		return {}
	r.repaired += 1 if found.repaired else 0
	var info: Dictionary = found.shape.face_info(found.index)
	match str(info.get("type", "")):
		"cylinder", "cone":
			var axis: Vector3 = (info.axis as Vector3).normalized()
			# The axis point level with the face's middle.
			var origin: Vector3 = info.axis_origin
			var center := origin + axis * ((info.point as Vector3) - origin).dot(axis)
			return {"center": center, "axis": axis, "radius": float(info.radius)}
		"sphere", "torus":
			return {"center": info.center, "axis": (info.get("axis", Vector3.UP) as Vector3).normalized(), "radius": float(info.radius)}
	r.fail("Select a round face (cylinder, cone, sphere or torus)")
	return {}


## A unit vector perpendicular to direction, as close to hint as possible.
static func _perpendicular(direction: Vector3, hint: Vector3) -> Vector3:
	var d := direction.normalized()
	for candidate in [hint, Vector3.UP, Vector3.RIGHT, Vector3.BACK]:
		var p: Vector3 = candidate - d * candidate.dot(d)
		if p.length() > 1e-6:
			return p.normalized()
	return Vector3.RIGHT


## The normal of the plane a line pick lies in: its sketch's plane, or a flat face beside an edge.
static func _plane_normal_near(r: UTIL.Reader, pick: Dictionary) -> Vector3:
	var sketch_state: Dictionary = r.ctx.sketches.get(pick.get("sketch", ""), {})
	if not sketch_state.is_empty():
		return (sketch_state.plane as Transform3D).basis.z
	if pick.get("kind", "") == "edge":
		var found := REFERENCES.edge(pick, r.ctx)
		if not found.has("error"):
			for f in found.shape.edge_info(found.index).get("faces", []):
				var info: Dictionary = found.shape.face_info(int(f))
				if info.get("planar", false):
					return info.normal
	return Vector3.ZERO
