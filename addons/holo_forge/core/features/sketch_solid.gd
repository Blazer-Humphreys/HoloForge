@tool
extends RefCounted
## Create features driven by sketch profiles and curves: Extrude, Revolve, Sweep, Loft, Rib,
## Web and Emboss. Inputs are expressions (lengths in meters, angles in radians); picks are
## references (see references.gd) in feature.options.
##
## Extrude options: profiles, side (one | two | symmetric), extent (distance | to | all),
## to_object, start (profile | offset | object), start_object, flip, whole_length (symmetric
## distance is the total), thin, thin_side (inside | outside | center). Inputs: distance,
## distance2, taper, start_offset, thickness.

const UTIL := preload("res://addons/holo_forge/core/features/util.gd")
const REFERENCES := preload("res://addons/holo_forge/core/references.gd")


static func build(feature: Resource, ctx: Dictionary) -> String:
	match feature.type:
		"extrude":
			return extrude(feature, ctx)
		"revolve":
			return revolve(feature, ctx)
		"sweep":
			return sweep(feature, ctx)
		"loft":
			return loft(feature, ctx)
		"rib":
			return rib(feature, ctx)
		"web":
			return web(feature, ctx)
		"emboss":
			return emboss(feature, ctx)
	return "Unknown feature '%s'" % feature.type


## surface (the Surface workspace's versions): profiles and open curves sweep out walls with no
## caps (core/features/surface.gd).
static func extrude(feature: Resource, ctx: Dictionary, surface := false) -> String:
	var r := UTIL.Reader.new(feature, ctx)
	var profile: Dictionary
	if surface:
		profile = surface_profile(r, r.refs("profiles"))
	else:
		profile = _thin_profile(r) if bool(r.opt("thin", false)) else r.profiles()
	if not r.ok():
		return r.error
	var plane: Transform3D = profile.plane
	var direction := plane.basis.z.normalized()
	if surface and not r.refs("direction").is_empty():
		direction = _picked_direction(r, "direction")
	elif not bool(profile.get("planar", true)):
		r.fail("Select a direction (an axis or plane): straight or twisted edges don't set one")
	direction *= -1.0 if bool(r.opt("flip", false)) else 1.0
	var center := _on_plane((profile.shape.bbox() as AABB).get_center(), plane)
	if ctx.has("profile_frames"):
		# (The profile's middle and its plane's normal, before Flip: feature_command.gd's arrow.)
		ctx.profile_frames[feature.id] = {"origin": center, "normal": plane.basis.z.normalized()}
	var start := 0.0
	match str(r.opt("start", "profile")):
		"offset":
			start = r.num("start_offset", 0.0)
		"object":
			start = distance_to(r, "start_object", center, direction)
	var side := str(r.opt("side", "one"))
	var d1 := 0.0
	var d2 := 0.0
	match str(r.opt("extent", "distance")):
		"distance":
			d1 = r.num("distance")
			if side == "two":
				d2 = r.num("distance2")
		"to":
			d1 = distance_to(r, "to_object", center, direction) - start
			if side == "two":
				d2 = r.num("distance2", 0.0)
		"all":
			var span := UTIL.model_span(ctx, center + direction * start, direction)
			var margin := UTIL.model_size(ctx) * 0.01
			if span.y <= 1e-9 and side == "one":
				r.fail("There's nothing to extrude through in that direction (try Flip)")
			d1 = maxf(span.y, 0.0) + margin
			if side != "one":
				d2 = maxf(-span.x, 0.0) + margin
	if side == "symmetric":
		if bool(r.opt("whole_length", false)):
			d1 *= 0.5
		d2 = d1
	var taper := r.num("taper", 0.0)
	if not r.ok():
		return r.error
	if d1 < 0.0 and str(r.opt("extent", "distance")) == "distance" and side == "one":
		# Pulled back past zero: an automatic operation cuts what it goes into (core/operations.gd).
		ctx["auto_cut"] = str(feature.id)
	var shape: RefCounted = r.kernel.extrude(profile.shape, {
		"direction": direction, "distance": d1, "distance2": d2, "taper": taper, "start_offset": start, "tag": feature.id,
		"surface": surface,
	})
	return UTIL.finish(r, shape if surface else UTIL.fuse_solids(r.kernel, shape, feature.id), "Extrude")


## What a surface feature sweeps: picked profiles and flat faces, sketch curves (exact edges) and
## body edges, as one shape, with the plane of the first pick (of body edges alone, the plane
## through them): {"shape", "plane", "planar": false when body edges lie in no one plane} or {}
## after fail().
static func surface_profile(r: UTIL.Reader, picks: Array) -> Dictionary:
	var parts := []
	var plane := Transform3D()
	var have_plane := false
	var areas := picks.filter(func(p: Variant) -> bool: return p is Dictionary and str(p.get("kind", "")) in ["profile", "face"])
	if not areas.is_empty():
		var found := r.profiles_of(areas)
		if found.is_empty():
			return {}
		parts.append(found.shape)
		plane = found.plane
		have_plane = true
	for entry in REFERENCES.curve_edges(picks, r.ctx):
		if entry.has("error"):
			r.fail(entry.error)
			return {}
		parts.append(entry.edges)
		if not have_plane:
			plane = entry.plane
			have_plane = true
	var edge_picks := picks.filter(func(p: Variant) -> bool: return p is Dictionary and str(p.get("kind", "")) == "edge")
	var edges := []
	for pick in edge_picks:
		var found := REFERENCES.edge(pick, r.ctx)
		if found.has("error"):
			r.fail(found.error)
			return {}
		r.repaired += 1 if found.repaired else 0
		var edge: RefCounted = found.shape.edge_shape(found.index)
		parts.append(edge)
		edges.append(edge)
	# Body edges alone: the plane they lie in (none for straight or twisted edges).
	var planar := true
	if not have_plane and not edges.is_empty():
		var found := _edges_plane(edges)
		planar = not found.is_empty()
		plane = found.plane if planar else _curve_plane(r, edge_picks[0], edges[0])
	if parts.is_empty():
		r.fail("Select profiles or curves")
		return {}
	return {"shape": parts[0] if parts.size() == 1 else r.kernel.make_compound(parts), "plane": plane, "planar": planar}


## A direction from a picked axis (or a plane's normal).
static func _picked_direction(r: UTIL.Reader, key: String) -> Vector3:
	var found := REFERENCES.axis(r.ref(key), r.ctx)
	if not found.has("error"):
		return (found.direction as Vector3).normalized()
	var plane := r.plane(key)
	return (plane.get("normal", Vector3.UP) as Vector3).normalized()


## A thin band to extrude: around open curves, or inside/outside/centered on a profile's edges.
static func _thin_profile(r: UTIL.Reader) -> Dictionary:
	var t := r.num("thickness", null, "positive")
	var picks := r.refs("profiles")
	if not r.ok():
		return {}
	if not picks.is_empty() and str(picks[0].get("kind", "")) in ["sketch_curve", "edge"]:
		var wire := r.path("profiles")
		if wire == null:
			return {}
		var curve_plane := _curve_plane(r, picks[0], wire)
		var band := r.checked(r.kernel.wire_outline(wire, t * 0.5, curve_plane.basis.z), "Thin outline")
		return {"shape": band, "plane": curve_plane} if band != null else {}
	var profile := r.profiles()
	if profile.is_empty():
		return {}
	var face: RefCounted = profile.shape
	var outer: RefCounted = face
	var inner: RefCounted = face
	match str(r.opt("thin_side", "inside")):
		"inside":
			inner = r.kernel.offset_profile(face, -t)
		"outside":
			outer = r.kernel.offset_profile(face, t)
		_:
			outer = r.kernel.offset_profile(face, t * 0.5)
			inner = r.kernel.offset_profile(face, -t * 0.5)
	if r.checked(outer, "Thin wall") == null or r.checked(inner, "Thin wall") == null:
		return {}
	var ring := r.checked(r.kernel.boolean(outer, inner, 1, r.feature.id), "Thin wall")
	return {"shape": ring, "plane": profile.plane} if ring != null else {}


static func revolve(feature: Resource, ctx: Dictionary, surface := false) -> String:
	var r := UTIL.Reader.new(feature, ctx)
	var profile := surface_profile(r, r.refs("profiles")) if surface else r.profiles()
	var axis := r.axis("axis")
	if not r.ok():
		return r.error
	var direction: Vector3 = (axis.direction as Vector3).normalized() * (-1.0 if bool(r.opt("flip", false)) else 1.0)
	var a1 := 0.0
	var a2 := 0.0
	match str(r.opt("extent", "angle")):
		"full":
			a1 = TAU
		"angle":
			a1 = r.num("angle")
		"two_sides":
			a1 = r.num("angle")
			a2 = r.num("angle2")
		"symmetric":
			a1 = r.num("angle") * 0.5
			a2 = a1
		"to":
			a1 = _angle_to(r, profile, axis.origin, direction)
	if not r.ok():
		return r.error
	if absf(a1 + a2) < 1e-9:
		return "The revolve angle is zero"
	var shape: RefCounted = r.kernel.revolve(profile.shape, {
		"axis_origin": axis.origin, "axis": direction, "angle": minf(a1, TAU), "angle2": a2, "tag": feature.id,
		"surface": surface,
	})
	return UTIL.finish(r, shape if surface else UTIL.fuse_solids(r.kernel, shape, feature.id), "Revolve")


static func sweep(feature: Resource, ctx: Dictionary, surface := false) -> String:
	var r := UTIL.Reader.new(feature, ctx)
	var profile := surface_profile(r, r.refs("profiles")) if surface else r.profiles()
	var path := r.path("path")
	var params := {
		"tag": feature.id, "orientation": str(r.opt("orientation", "perpendicular")),
		"twist": r.num("twist", 0.0), "scale": r.num("scale", 1.0), "surface": surface,
	}
	if not r.refs("guide").is_empty():
		params["guide"] = r.path("guide")
	if not r.ok():
		return r.error
	return UTIL.finish(r, r.noted(r.kernel.sweep(profile.shape, path, params), "Sweep"), "Sweep")


## Loft sections: a profile, a face or a point each; curves (or edges) picked one after another
## that join end to end make one section, so an open chain lofts as one curve.
static func loft(feature: Resource, ctx: Dictionary, surface := false) -> String:
	var r := UTIL.Reader.new(feature, ctx)
	var sections := []
	var chain := []
	for pick in r.refs("sections"):
		var kind := str(pick.get("kind", ""))
		if kind == "sketch_curve" or kind == "edge":
			if chain.is_empty() or _one_chain(chain + [pick], ctx):
				chain.append(pick)
				continue
			_add_chain(r, chain, sections)
			chain = [pick]
			continue
		_add_chain(r, chain, sections)
		chain = []
		match kind:
			"profile":
				var p := REFERENCES.profile(pick, ctx)
				if p.has("error"):
					r.fail(p.error)
				else:
					sections.append(p.face)
			"face":
				var found := REFERENCES.face(pick, ctx)
				if found.has("error"):
					r.fail(found.error)
				else:
					r.repaired += 1 if found.repaired else 0
					sections.append(found.shape.face_shape(found.index))
			_:
				var p := REFERENCES.point(pick, ctx)
				if p.has("error"):
					r.fail(p.error)
				else:
					sections.append(r.kernel.make_vertex(p.point))
	_add_chain(r, chain, sections)
	if sections.size() < 2:
		r.fail("Select at least two profiles to loft between")
	var params := {"tag": feature.id, "closed": bool(r.opt("closed", false)), "ruled": bool(r.opt("ruled", false)), "surface": surface}
	if not r.refs("centerline").is_empty():
		params["centerline"] = r.path("centerline")
	# One rail (its picks join end to end) is followed exactly: each section starts where the rail
	# touches it. Several ride along as one centerline (approximation).
	var rails := r.refs("rails")
	if not rails.is_empty():
		params["rail" if _one_chain(rails, ctx) else "centerline"] = r.path("rails")
	if not r.ok():
		return r.error
	return UTIL.finish(r, r.noted(r.kernel.loft(sections, params), "Loft"), "Loft")


## Rib: an open curve grows in its sketch plane until the body closes it in; it joins the body.
static func rib(feature: Resource, ctx: Dictionary) -> String:
	var r := UTIL.Reader.new(feature, ctx)
	var wire := r.path("curves")
	var thickness := r.num("thickness", null, "positive")
	if not r.ok():
		return r.error
	var plane := _curve_plane(r, r.ref("curves"), wire)
	var targets := UTIL.OPERATIONS.participating(ctx, wire, r.bodies("targets", false), true)
	if targets.is_empty():
		return "The rib's curve doesn't reach a body"
	var normal := plane.basis.z * (-1.0 if bool(r.opt("flip", false)) else 1.0)
	var symmetric := str(r.opt("thickness_side", "symmetric")) == "symmetric"
	var body_id: String = targets[0]
	var shape: RefCounted = r.kernel.rib(ctx.bodies[body_id].shape, wire, {
		"plane_origin": plane.origin, "plane_normal": normal, "thickness": thickness, "symmetric": symmetric, "tag": feature.id,
	})
	return UTIL.replace(r, body_id, shape, "Rib")


## Web: a wall of the given thickness along the curves, depth out of their sketch plane.
static func web(feature: Resource, ctx: Dictionary) -> String:
	var r := UTIL.Reader.new(feature, ctx)
	var wire := r.path("curves")
	var thickness := r.num("thickness", null, "positive")
	var depth := r.num("depth", null, "positive")
	if not r.ok():
		return r.error
	var plane := _curve_plane(r, r.ref("curves"), wire)
	var band := r.checked(r.kernel.wire_outline(wire, thickness * 0.5, plane.basis.z), "Web outline")
	if band == null:
		return r.error
	var symmetric := str(r.opt("depth_side", "one")) == "symmetric"
	var normal := plane.basis.z * (-1.0 if bool(r.opt("flip", false)) else 1.0)
	var shape: RefCounted = r.kernel.extrude(band, {
		"direction": normal, "distance": depth * (0.5 if symmetric else 1.0),
		"distance2": depth * 0.5 if symmetric else 0.0, "tag": feature.id,
	})
	return UTIL.finish(r, shape, "Web")


## Emboss / Deboss: the profile, projected along its sketch normal onto a face, raised from it
## or sunk into it by depth (on curved faces too: the stamp follows the face's offset).
static func emboss(feature: Resource, ctx: Dictionary) -> String:
	var r := UTIL.Reader.new(feature, ctx)
	var profile := r.profiles()
	var depth := r.num("depth", null, "positive")
	var target := r.ref("face")
	if target.is_empty():
		r.fail("Select the face to emboss on")
	if not r.ok():
		return r.error
	var found := REFERENCES.face(target, ctx)
	if found.has("error"):
		return found.error
	r.repaired += 1 if found.repaired else 0
	var raise := str(r.opt("effect", "emboss")) == "emboss"
	var slab := r.checked(r.kernel.thicken(found.shape, PackedInt32Array([found.index]), {"thickness": depth if raise else -depth, "tag": feature.id}), "Emboss")
	var size := UTIL.model_size(ctx)
	var prism := r.checked(r.kernel.extrude(profile.shape, {"direction": (profile.plane as Transform3D).basis.z, "distance": size, "distance2": size, "tag": feature.id}), "Emboss")
	if not r.ok():
		return r.error
	var stamp := r.checked(r.kernel.boolean(slab, prism, 2, feature.id), "Emboss")
	if stamp == null:
		return r.error
	return UTIL.replace(r, found.body, r.kernel.boolean(found.shape, stamp, 0 if raise else 1, feature.id), "Emboss")


# --- Helpers ---------------------------------------------------------------------------------

## True when curve (or edge) picks join end to end into one wire holding every one of them.
static func _one_chain(picks: Array, ctx: Dictionary) -> bool:
	var p := REFERENCES.path(picks, ctx)
	return not p.has("error") and int(p.wire.edge_count()) >= picks.size()


## A loft section from a chain of curve (or edge) picks (none when the chain is empty).
static func _add_chain(r: UTIL.Reader, chain: Array, sections: Array) -> void:
	if chain.is_empty():
		return
	var p := REFERENCES.path(chain, r.ctx)
	if p.has("error"):
		r.fail(p.error)
	else:
		sections.append(p.wire)


## The plane through body edges (sampled along each), facing the side the first edge turns
## toward, as _curve_plane does for one curve: {"plane": Transform3D}, or {} when they lie on one
## line or not in one plane (a straight edge sets no direction).
static func _edges_plane(edges: Array) -> Dictionary:
	var points := PackedVector3Array()
	for edge in edges:
		for t in [0.0, 0.25, 0.5, 0.75, 1.0]:
			points.append(edge.edge_point_at(0, t).point)
	var p0 := points[0]
	var p1 := p0
	for p in points:
		if p.distance_to(p0) > p1.distance_to(p0):
			p1 = p
	var span := p0.distance_to(p1)
	if span < 1e-12:
		return {}
	var along := (p1 - p0) / span
	var p2 := p0
	var off := 0.0
	for p in points:
		var away := ((p - p0) - along * (p - p0).dot(along)).length()
		if away > off:
			off = away
			p2 = p
	if off < span * 1e-6:
		return {}
	var normal := along.cross(p2 - p0).normalized()
	var center := Vector3.ZERO
	for p in points:
		if absf((p - p0).dot(normal)) > span * 1e-6:
			return {}
		center += p
	center /= points.size()
	var first: Dictionary = edges[0].edge_point_at(0, 0.0)
	var turn := (first.tangent as Vector3).cross(center - (first.point as Vector3))
	if turn.dot(normal) < 0.0:
		normal = -normal
	return {"plane": Transform3D(Basis(along, normal.cross(along), normal), p0)}


static func _on_plane(point: Vector3, plane: Transform3D) -> Vector3:
	var n := plane.basis.z.normalized()
	return point - n * (point - plane.origin).dot(n)


## The sketch plane of a picked curve (or a plane through an edge chain).
static func _curve_plane(r: UTIL.Reader, pick: Dictionary, wire: RefCounted) -> Transform3D:
	var sketch_state: Dictionary = r.ctx.sketches.get(pick.get("sketch", ""), {})
	if not sketch_state.is_empty():
		return sketch_state.plane
	var box: AABB = wire.bbox()
	var info: Dictionary = wire.edge_info(0)
	var tangent: Vector3 = info.get("tangent", Vector3.RIGHT)
	var normal := tangent.cross(box.get_center() - (info.start as Vector3))
	if normal.length() < 1e-9:
		normal = tangent.cross(Vector3.UP if absf(tangent.y) < 0.9 else Vector3.RIGHT)
	var basis := Basis(tangent, normal.normalized().cross(tangent), normal.normalized())
	return Transform3D(basis, info.start)


## Signed distance along direction from a point to a picked plane, face or body ("To Object").
## Planes are exact; curved faces and bodies use their nearest side (approximation).
static func distance_to(r: UTIL.Reader, key: String, from: Vector3, direction: Vector3) -> float:
	var pick := r.ref(key)
	if pick.is_empty():
		r.fail("Select the object to extrude to")
		return 0.0
	var target: RefCounted = null
	match str(pick.get("kind", "")):
		"body":
			target = REFERENCES.body_shape(pick, r.ctx)
		"face":
			var found := REFERENCES.face(pick, r.ctx)
			if found.has("error"):
				r.fail(found.error)
				return 0.0
			var info: Dictionary = found.shape.face_info(found.index)
			if not info.get("planar", false):
				target = found.shape.face_shape(found.index)
		"vertex", "sketch_point":
			return (r.point(key) - from).dot(direction)
	if target == null:
		var plane := r.plane(key)
		if plane.is_empty():
			return 0.0
		var n: Vector3 = plane.normal
		var along := direction.dot(n)
		if absf(along) < 1e-9:
			r.fail("The extrude runs parallel to that plane")
			return 0.0
		return ((plane.origin as Vector3) - from).dot(n) / along
	var box: AABB = target.bbox()
	var lo := INF
	var hi := -INF
	for i in 8:
		var t := (box.get_endpoint(i) - from).dot(direction)
		lo = minf(lo, t)
		hi = maxf(hi, t)
	return lo if lo > 1e-9 else hi


## The revolve angle that brings the profile's center onto a picked plane ("To" extent).
static func _angle_to(r: UTIL.Reader, profile: Dictionary, axis_origin: Vector3, direction: Vector3) -> float:
	var plane := r.plane("to_object")
	if plane.is_empty():
		return 0.0
	var c: Vector3 = (profile.shape.bbox() as AABB).get_center()
	var a := direction.normalized()
	var rel := c - axis_origin
	var v := rel - a * rel.dot(a)
	var n: Vector3 = plane.normal
	# (axis point + v cos t + (a x v) sin t - plane origin) . n = 0  ->  A cos t + B sin t + C = 0
	var big_a := v.dot(n)
	var big_b := a.cross(v).dot(n)
	var big_c := (axis_origin + a * rel.dot(a) - (plane.origin as Vector3)).dot(n)
	var radius := sqrt(big_a * big_a + big_b * big_b)
	if radius < 1e-12 or absf(big_c / radius) > 1.0:
		r.fail("The revolve can't reach that plane")
		return 0.0
	var phi := atan2(big_b, big_a)
	var spread := acos(clampf(-big_c / radius, -1.0, 1.0))
	var best := INF
	for t in [phi + spread, phi - spread]:
		var angle := fposmod(t, TAU)
		if angle > 1e-6 and angle < best:
			best = angle
	if best == INF:
		r.fail("The profile already touches that plane")
		return 0.0
	return best
