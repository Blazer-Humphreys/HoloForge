@tool
extends RefCounted
## Shared by the feature handlers: evaluated inputs, resolved references and kernel results.
## A Reader collects the first problem as the feature's error, so a handler can read everything
## it needs and check once.

const OPERATIONS := preload("res://addons/holo_forge/core/operations.gd")
const REFERENCES := preload("res://addons/holo_forge/core/references.gd")
const SKETCH_DATA := preload("res://addons/holo_forge/core/sketch/sketch_data.gd")
const MESH_BODY := preload("res://addons/holo_forge/core/mesh/mesh_body.gd")

## The gate: what a Solid or Surface tool says of a mesh body (%s: the body's name). The sentence
## itself lives in core/mesh/mesh_body.gd, which core/references.gd and core/operations.gd can
## preload too (they can't preload this file: it preloads them).
const MESH_GATE := MESH_BODY.GATE


class Reader:
	extends RefCounted
	var feature: Resource
	var ctx: Dictionary
	var kernel: RefCounted
	## The first problem found ("" while all is well).
	var error := ""
	## References found by shape because their names were lost (the feature gets a warning).
	var repaired := 0
	## What the kernel said of results it built less closely than asked (see noted; the feature
	## gets them as warnings).
	var notes := PackedStringArray()

	func _init(p_feature: Resource, p_ctx: Dictionary) -> void:
		feature = p_feature
		ctx = p_ctx
		kernel = p_ctx.kernel

	func ok() -> bool:
		return error == ""

	func fail(text: String) -> void:
		if error == "":
			error = text

	func has_input(key: String) -> bool:
		return feature.inputs.has(key)

	## An expression input in meters, radians or a plain number. rule: "" | "positive" |
	## "non_negative" | "count" (a whole number of at least 1).
	func num(key: String, fallback: Variant = null, rule := "") -> float:
		var input: Dictionary = feature.inputs.get(key, {})
		if input.is_empty():
			if fallback == null:
				fail("%s is missing" % key.capitalize())
				return 0.0
			return float(fallback)
		var r: Dictionary = ctx.values.get(str(input.get("name", "")), {"ok": false, "error": "missing"})
		if not r.ok:
			fail("%s: %s" % [key.capitalize(), r.error])
			return 0.0
		var v := float(r.value)
		match rule:
			"positive":
				if v <= 0.0:
					fail("%s must be greater than zero" % key.capitalize())
			"non_negative":
				if v < 0.0:
					fail("%s can't be negative" % key.capitalize())
			"count":
				if v < 1.0 or absf(v - roundf(v)) > 1e-6:
					fail("%s must be a whole number of at least 1" % key.capitalize())
				v = roundf(v)
		return v

	func opt(key: String, fallback: Variant = null) -> Variant:
		return feature.options.get(key, fallback)

	func refs(key: String) -> Array:
		return feature.options.get(key, [])

	func ref(key: String) -> Dictionary:
		var list := refs(key)
		return list[0] if not list.is_empty() and list[0] is Dictionary else {}

	## Picked profiles (sketch regions or flat body faces) as one shape: several become a
	## compound. {"shape", "plane": Transform3D of the first} or {} after fail().
	func profiles(key := "profiles") -> Dictionary:
		return profiles_of(refs(key))

	## profiles() for a list of picks.
	func profiles_of(picks: Array) -> Dictionary:
		var faces := []
		var first_plane := Transform3D()
		for r in picks:
			var face: RefCounted = null
			var frame := Transform3D()
			if r.get("kind", "") == "face":
				var found := REFERENCES.face(r, ctx)
				if found.has("error"):
					fail(found.error)
					return {}
				repaired += 1 if found.repaired else 0
				var info: Dictionary = found.shape.face_info(found.index)
				if not info.get("planar", false):
					fail("A picked face isn't flat")
					return {}
				face = found.shape.face_shape(found.index)
				var f := SKETCH_DATA.face_plane(info.point, info.normal)
				frame = Transform3D(Basis(f.x, f.y, info.normal), f.origin)
			else:
				var p := REFERENCES.profile(r, ctx)
				if p.has("error"):
					fail(p.error)
					return {}
				face = p.face
				frame = p.plane
			if faces.is_empty():
				first_plane = frame
			faces.append(face)
		if faces.is_empty():
			fail("Select a profile")
			return {}
		return {"shape": faces[0] if faces.size() == 1 else kernel.make_compound(faces), "plane": first_plane}

	## {"origin", "normal", "x"} or {} after fail().
	func plane(key: String) -> Dictionary:
		var r := ref(key)
		if r.is_empty():
			fail("Select a plane")
			return {}
		var p := REFERENCES.plane(r, ctx)
		return _checked(p)

	## {"origin", "direction"} or {} after fail().
	func axis(key: String) -> Dictionary:
		var r := ref(key)
		if r.is_empty():
			fail("Select an axis")
			return {}
		return _checked(REFERENCES.axis(r, ctx))

	## A point, or fallback (with no fail) when nothing is picked and fallback isn't null.
	func point(key: String, fallback: Variant = null) -> Vector3:
		var r := ref(key)
		if r.is_empty():
			if fallback == null:
				fail("Select a point")
			return fallback if fallback != null else Vector3.ZERO
		var p := _checked(REFERENCES.point(r, ctx))
		return p.get("point", Vector3.ZERO)

	## Every picked point (sketch points, vertices, construction points).
	func points(key: String) -> PackedVector3Array:
		var result := PackedVector3Array()
		for r in refs(key):
			var p := _checked(REFERENCES.point(r, ctx))
			if p.is_empty():
				return PackedVector3Array()
			result.append(p.point)
		return result

	## A wire through the picked sketch curves or edges, or null after fail().
	func path(key: String) -> RefCounted:
		if refs(key).is_empty():
			fail("Select a path")
			return null
		var p := _checked(REFERENCES.path(refs(key), ctx))
		return p.get("wire")

	## The picked bodies that still exist (ids). A component pick stands for its bodies. A mesh
	## body among them fails the reader with the gate sentence, unless allow_mesh (only the tools
	## that work on mesh bodies pass it: Move/Copy, Remove, the Mesh features).
	func bodies(key: String, required := true, allow_mesh := false) -> Array:
		return bodies_of(refs(key), required, allow_mesh)

	## bodies() for a list of picks.
	func bodies_of(picks: Array, required := true, allow_mesh := false) -> Array:
		var result := []
		for r in picks:
			match str(r.get("kind", "")):
				"body":
					if not ctx.bodies.has(r.body):
						fail("Body %s no longer exists" % ctx.doc.body_name(r.body))
						return []
					if not result.has(r.body):
						result.append(r.body)
				"component":
					for body_id in ctx.bodies:
						if ctx.doc.body_component(body_id) == str(r.component) and not result.has(body_id):
							result.append(body_id)
				"face", "edge":
					if ctx.bodies.has(r.get("body", "")) and not result.has(r.body):
						result.append(r.body)
		if not allow_mesh and gated(result):
			return []
		if result.is_empty() and required:
			fail("Select a body")
		return result

	## True (after fail() with the gate sentence) when one of the bodies (ids) is a mesh body.
	func gated(body_ids: Array) -> bool:
		var text := MESH_BODY.gate_ids(ctx, body_ids)
		if text == "":
			return false
		fail(text)
		return true

	## Picked faces (or edges) grouped by body: {body id: {"shape", "indices"}}.
	func sub_shapes(key: String, kind: String) -> Dictionary:
		return sub_shapes_from(refs(key), kind)

	func sub_shapes_from(picks: Array, kind: String) -> Dictionary:
		var found := REFERENCES.group_by_body(picks, ctx, kind)
		repaired += int(found.repaired)
		if not found.errors.is_empty():
			fail(found.errors[0])
			return {}
		if found.groups.is_empty():
			fail("Select %ss" % kind)
		return found.groups

	## Picked faces grouped by body, where a picked body stands for all its faces (its indices
	## are then empty, which the kernel reads as every face): {body id: {"shape", "indices"}}.
	func faces_or_bodies(key: String) -> Dictionary:
		var face_picks := []
		var whole := []
		for pick in refs(key):
			if pick is Dictionary and pick.get("kind", "") == "face":
				face_picks.append(pick)
			elif pick is Dictionary and pick.get("kind", "") in ["body", "component"]:
				whole.append(pick)
		var groups := sub_shapes_from(face_picks, "face") if not face_picks.is_empty() else {}
		for body_id in bodies_of(whole, false):
			groups[body_id] = {"shape": ctx.bodies[body_id].shape, "indices": PackedInt32Array()}
		if gated(groups.keys()):
			return {}
		if groups.is_empty():
			fail("Select faces or bodies")
		return groups

	## A shape that cuts or splits: a plane (as a big flat face), a face, or a body.
	func tool_shape(key: String, size: float) -> RefCounted:
		var r := ref(key)
		if r.is_empty():
			fail("Select a splitting tool")
			return null
		match str(r.get("kind", "")):
			"body":
				var s := REFERENCES.body_shape(r, ctx)
				if s == null:
					fail("The splitting body is gone")
				elif gated([r.get("body", "")]):
					return null
				return s
			"face":
				var found := REFERENCES.face(r, ctx)
				if found.has("error"):
					fail(found.error)
					return null
				repaired += 1 if found.repaired else 0
				var info: Dictionary = found.shape.face_info(found.index)
				if info.get("planar", false) and bool(opt("extend", true)):
					return kernel.plane_face(info.point, info.normal, size, feature.id)
				return found.shape.face_shape(found.index)
		var p := plane(key)
		return kernel.plane_face(p.origin, p.normal, size, feature.id) if not p.is_empty() else null

	## The shape, or null after fail() with the kernel's reason.
	func checked(shape: RefCounted, what: String) -> RefCounted:
		if shape == null or shape.is_null():
			var why: String = kernel.get_last_error()
			fail("%s failed%s" % [what, (": " + why) if why != "" else ""])
			return null
		return shape

	## checked() for a kernel result just made, keeping the kernel's warning about it (a sweep it
	## could only fit loosely) for the feature's warnings.
	func noted(shape: RefCounted, what: String) -> RefCounted:
		var note: String = kernel.get_last_warning()
		if note != "" and shape != null:
			notes.append(note)
		return checked(shape, what)

	func _checked(found: Dictionary) -> Dictionary:
		if found.has("error"):
			fail(found.error)
			return {}
		# A face group pick found again under another name (an earlier change renumbered them).
		if found.has("group_moved"):
			notes.append(MESH_BODY.moved_note(feature.label, str(found.group_moved[0]), str(found.group_moved[1])))
		# (References refuse mesh bodies themselves; this catches a result that still holds one.)
		if MESH_BODY.is_mesh(found.get("shape")):
			fail(MESH_GATE % MESH_BODY.body_name(ctx.get("doc"), str(found.get("body", ""))))
			return {}
		return found


## The gate: "" when none of the regen entries ({"id", "shape", ...}) is a mesh body, else the
## gate sentence for the first one that is. Solid and Surface tools refuse mesh bodies with it,
## before any call a mesh body can't answer.
static func mesh_gate(doc: Resource, entries: Array) -> String:
	return MESH_BODY.gate(doc, entries)


## The size of everything in the model (for "through all" extents and big splitting planes). Mesh
## bodies count too (they answer bbox()), so a hole "through all" clears a mesh beside it.
static func model_size(ctx: Dictionary) -> float:
	var box := AABB()
	var first := true
	for body_id in ctx.bodies:
		var b: AABB = ctx.bodies[body_id].shape.bbox()
		box = b if first else box.merge(b)
		first = false
	return maxf(box.size.length() * 2.0 + box.position.length() * 2.0, 1.0)


## The range [lo, hi] of every body's bounds projected on direction, measured from origin.
static func model_span(ctx: Dictionary, origin: Vector3, direction: Vector3) -> Vector2:
	var lo := INF
	var hi := -INF
	for body_id in ctx.bodies:
		var b: AABB = ctx.bodies[body_id].shape.bbox()
		for i in 8:
			var t := (b.get_endpoint(i) - origin).dot(direction)
			lo = minf(lo, t)
			hi = maxf(hi, t)
	return Vector2(lo, hi) if lo <= hi else Vector2.ZERO


## Several solids fused into one (multi-profile extrudes); a single solid is returned as is.
static func fuse_solids(kernel: RefCounted, shape: RefCounted, tag: String) -> RefCounted:
	if shape == null or shape.solid_count() < 2:
		return shape
	var parts: Array = shape.solids()
	var merged: RefCounted = parts[0]
	for i in range(1, parts.size()):
		var next: RefCounted = kernel.boolean(merged, parts[i], 0, tag)
		if next == null:
			return shape
		merged = next
	return merged


## Ends a Create feature: reports the first problem, or applies the operation.
static func finish(r: Reader, shape: RefCounted, what: String) -> String:
	if not r.ok():
		return r.error
	if r.checked(shape, what) == null:
		return r.error
	_warn(r)
	return OPERATIONS.apply(r.ctx, r.feature, shape)


## Ends a Modify feature that replaces one body's shape. A mesh body is refused with the gate
## sentence (the Mesh features replace theirs themselves).
static func replace(r: Reader, body_id: String, shape: RefCounted, what: String) -> String:
	if not r.ok():
		return r.error
	if r.gated([body_id]):
		return r.error
	if r.checked(shape, what) == null:
		return r.error
	r.ctx.bodies[body_id].shape = shape
	_warn(r)
	return ""


## An id for a body a feature splits off or copies: "body3.f7.2" (shown as "Body3 (2)"). sources:
## every body the feature splits or copies at once. When one of them came from another one's
## body ("body3.f5.2" beside "body3"), its pieces carry its whole id ("body3.f5.2.f7.2"), so the
## two never overwrite each other.
static func derived_body_id(source: String, feature_id: String, index: int, sources: Array = []) -> String:
	var root := source.split(".")[0]
	if source != root:
		for other in sources:
			if str(other) != source and str(other).split(".")[0] == root:
				return "%s.%s.%d" % [source, feature_id, index]
	return "%s.%s.%d" % [root, feature_id, index]


static func _warn(r: Reader) -> void:
	if r.repaired > 0 and r.ctx.has("warnings"):
		r.ctx.warnings[r.feature.id] = "%d reference(s) were found again by shape; check the result" % r.repaired
	for note in r.notes:
		add_warning(r, note)
	r.notes.clear()


## Adds note to the feature's warnings, after any it has.
static func add_warning(r: Reader, note: String) -> void:
	if note == "" or not r.ctx.has("warnings"):
		return
	var before := str(r.ctx.warnings.get(r.feature.id, ""))
	r.ctx.warnings[r.feature.id] = note if before == "" else before + "; " + note


## A rotation about an axis through origin, as a transform.
static func rotation_about(origin: Vector3, direction: Vector3, angle: float) -> Transform3D:
	var basis := Basis(direction.normalized(), angle)
	return Transform3D(basis, origin - basis * origin)


## The rotation turning direction a onto direction b.
static func rotation_between(a: Vector3, b: Vector3) -> Basis:
	var from := a.normalized()
	var to := b.normalized()
	var axis := from.cross(to)
	if axis.length() < 1e-9:
		if from.dot(to) > 0.0:
			return Basis.IDENTITY
		# Opposite: half a turn about any perpendicular axis.
		var perpendicular := from.cross(Vector3.UP if absf(from.y) < 0.9 else Vector3.RIGHT).normalized()
		return Basis(perpendicular, PI)
	return Basis(axis.normalized(), acos(clampf(from.dot(to), -1.0, 1.0)))


## A point and tangent at fraction t (0..1) along a wire, by arc length.
static func along_wire(wire: RefCounted, t: float) -> Dictionary:
	var lengths: Array[float] = []
	var total := 0.0
	for e in wire.edge_count():
		var length := float(wire.edge_info(e).get("length", 0.0))
		lengths.append(length)
		total += length
	var target := clampf(t, 0.0, 1.0) * total
	for e in lengths.size():
		if target <= lengths[e] + 1e-12 or e == lengths.size() - 1:
			var local: float = target / lengths[e] if lengths[e] > 0.0 else 0.0
			# (By length along the edge: its curve's parameter isn't, on an ellipse or a spline.)
			return wire.edge_point_at_length(e, clampf(local, 0.0, 1.0))
		target -= lengths[e]
	return {"point": Vector3.ZERO, "tangent": Vector3.RIGHT}


## The rotation carrying a copy at fraction from (0..1) along a wire to fraction to, turning with
## the path's direction step by step (so a tangent turned exactly round turns about the path's
## bend, not about an arbitrary axis).
static func turn_along_wire(wire: RefCounted, from: float, to: float, steps := 64) -> Basis:
	var lengths: Array[float] = []
	var total := 0.0
	for e in wire.edge_count():
		lengths.append(float(wire.edge_info(e).get("length", 0.0)))
		total += lengths[e]
	# The steps between the ends by each edge's curve parameter (near enough to step along).
	var tangent_at := func(t: float) -> Vector3:
		var target := clampf(t, 0.0, 1.0) * total
		for e in lengths.size():
			if target <= lengths[e] + 1e-12 or e == lengths.size() - 1:
				return (wire.edge_point_at(e, clampf(target / lengths[e] if lengths[e] > 0.0 else 0.0, 0.0, 1.0)).tangent as Vector3).normalized()
			target -= lengths[e]
		return Vector3.RIGHT
	var basis := Basis.IDENTITY
	var before: Vector3 = (along_wire(wire, from).tangent as Vector3).normalized()
	var axis := Vector3.ZERO
	for k in range(1, steps + 1):
		var now: Vector3 = (along_wire(wire, to).tangent as Vector3).normalized() if k == steps else tangent_at.call(lerpf(from, to, float(k) / steps))
		var cross := before.cross(now)
		var step := Basis.IDENTITY
		if cross.length() > 1e-9:
			axis = cross.normalized()
			step = Basis(axis, acos(clampf(before.dot(now), -1.0, 1.0)))
		elif before.dot(now) < 0.0:
			# A cusp turning straight back: about the bend so far, or any square axis.
			var square := axis - before * axis.dot(before)
			step = Basis(square.normalized() if square.length() > 1e-6 else rotation_between(before, now).get_rotation_quaternion().get_axis(), PI)
		basis = step * basis
		before = now
	return basis.orthonormalized()


static func wire_length(wire: RefCounted) -> float:
	var total := 0.0
	for e in wire.edge_count():
		total += float(wire.edge_info(e).get("length", 0.0))
	return total
