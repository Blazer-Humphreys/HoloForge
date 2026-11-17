@tool
extends RefCounted
## Rectangular, Circular and Path patterns, and Mirror.
##
## options.object_type picks what is copied: "bodies" and "components" copy shapes as new bodies
## (Mirror can join them instead: options.operation "join"); "features" replays each picked
## Create feature's tool shape at every copy with that feature's own operation; "faces" patterns
## the Create features that made the picked faces. options.suppressed lists copy numbers (1 is
## the first copy) to leave out.
##
## Rectangular: direction1/direction2 (axis picks), distance_type (extent | spacing),
## symmetric1/2, flip1/2; inputs quantity1, distance1, quantity2, distance2.
## Circular: axis, symmetric; inputs quantity, angle (a full turn spaces copies evenly).
## Path: path, distance_type, orientation (identical | path), flip; inputs quantity, distance.
## Mirror: plane.

const UTIL := preload("res://addons/holo_forge/core/features/util.gd")
const OPERATIONS := preload("res://addons/holo_forge/core/operations.gd")
const REFERENCES := preload("res://addons/holo_forge/core/references.gd")


static func build(feature: Resource, ctx: Dictionary) -> String:
	var r := UTIL.Reader.new(feature, ctx)
	var transforms := []
	var mirror := {}
	match feature.type:
		"rect_pattern":
			transforms = _rect(r)
		"circ_pattern":
			transforms = _circular(r)
		"path_pattern":
			transforms = _path(r)
		"mirror":
			mirror = r.plane("plane")
			transforms = [Transform3D.IDENTITY]
		_:
			return "Unknown pattern '%s'" % feature.type
	if not r.ok():
		return r.error
	var kept := []
	var suppressed: Array = r.opt("suppressed", [])
	for k in transforms.size():
		if not suppressed.has(k + 1):
			kept.append(transforms[k])
	return _copy(r, kept, mirror)


static func _copy(r: UTIL.Reader, transforms: Array, mirror: Dictionary) -> String:
	var ctx := r.ctx
	var kernel := r.kernel
	var fid: String = r.feature.id
	var make_copy := func(shape: RefCounted, xform: Transform3D) -> RefCounted:
		if not mirror.is_empty():
			return kernel.mirror_shape(shape, mirror.origin, mirror.normal, fid)
		return kernel.transform_shape(shape, xform, fid)
	match str(r.opt("object_type", "bodies")):
		"bodies", "components":
			var ids := r.bodies("objects")
			if not r.ok():
				return r.error
			for body_id in ids:
				var source: RefCounted = ctx.bodies[body_id].shape
				for k in transforms.size():
					var copy := r.checked(make_copy.call(source, transforms[k]), "Copy")
					if copy == null:
						return r.error
					if not mirror.is_empty() and str(r.opt("operation", OPERATIONS.NEW_BODY)) == OPERATIONS.JOIN:
						var joined := r.checked(kernel.boolean(ctx.bodies[body_id].shape, copy, 0, fid), "Mirror join")
						if joined == null:
							return r.error
						ctx.bodies[body_id].shape = joined
					else:
						var id := UTIL.derived_body_id(body_id, fid, k + 1, ids)
						ctx.bodies[id] = {"id": id, "shape": copy, "feature": fid}
		"features", "faces":
			var sources := _source_features(r)
			if not r.ok():
				return r.error
			for source_id in sources:
				var tool: Dictionary = ctx.get("tools", {}).get(source_id, {})
				var source_feature: Resource = ctx.doc.find_feature(source_id)
				if tool.is_empty() or source_feature == null:
					return "%s can't be copied: only Create features (and holes) can be patterned" % (source_feature.label if source_feature != null else source_id)
				for k in transforms.size():
					var copy := r.checked(make_copy.call(tool.shape, transforms[k]), "Copy")
					if copy == null:
						return r.error
					var body_id := ""
					if OPERATIONS.creates_body(tool.operation):
						body_id = UTIL.derived_body_id(str(source_feature.options.get("body_id", source_id)), fid, k + 1)
					var error := OPERATIONS.apply_shape(ctx, r.feature, copy, tool.operation, source_feature.options.get("targets", []), body_id)
					if error != "":
						return error
		_:
			return "Unknown object type '%s'" % r.opt("object_type", "")
	UTIL._warn(r)
	return ""


## The Create features picked directly, or that made the picked faces (their names start with
## the feature id).
static func _source_features(r: UTIL.Reader) -> Array:
	var result := []
	for pick in r.refs("objects"):
		match str(pick.get("kind", "")):
			"feature":
				if not result.has(pick.feature):
					result.append(pick.feature)
			"face":
				var found := REFERENCES.face(pick, r.ctx)
				if found.has("error"):
					r.fail(found.error)
					return []
				var name: String = found.shape.get_face_names()[found.index]
				var source := name.get_slice(":", 0)
				if r.ctx.get("tools", {}).has(source) and not result.has(source):
					result.append(source)
				elif not r.ctx.get("tools", {}).has(source):
					r.fail("A picked face doesn't come from a feature that can be patterned")
					return []
	if result.is_empty():
		r.fail("Select features or faces to pattern")
	return result


static func _offsets(count: int, step: float, symmetric: bool) -> Array:
	var result := []
	for i in range(-(count - 1) if symmetric else 0, count):
		result.append(i * step)
	return result


static func _rect(r: UTIL.Reader) -> Array:
	var spacing := str(r.opt("distance_type", "extent")) == "spacing"
	var directions := []
	for n in [1, 2]:
		if n == 2 and r.refs("direction2").is_empty():
			directions.append({"direction": Vector3.ZERO, "offsets": [0.0]})
			continue
		var axis := r.axis("direction%d" % n)
		var count := int(r.num("quantity%d" % n, null, "count"))
		var distance := r.num("distance%d" % n)
		if not r.ok():
			return []
		var step := distance if spacing else (distance / (count - 1) if count > 1 else 0.0)
		var flip := -1.0 if bool(r.opt("flip%d" % n, false)) else 1.0
		directions.append({"direction": (axis.direction as Vector3).normalized() * flip, "offsets": _offsets(count, step, bool(r.opt("symmetric%d" % n, false)))})
	var result := []
	for a in directions[0].offsets:
		for b in directions[1].offsets:
			if absf(a) < 1e-12 and absf(b) < 1e-12:
				continue
			result.append(Transform3D(Basis.IDENTITY, directions[0].direction * a + directions[1].direction * b))
	return result


static func _circular(r: UTIL.Reader) -> Array:
	var axis := r.axis("axis")
	var count := int(r.num("quantity", null, "count"))
	var angle := r.num("angle", TAU)
	if not r.ok():
		return []
	var full := absf(absf(angle) - TAU) < 1e-6
	var step := angle / count if full else (angle / (count - 1) if count > 1 else 0.0)
	var angles := []
	if bool(r.opt("symmetric", false)) and not full:
		for i in count:
			angles.append((i - (count - 1) * 0.5) * step)
	else:
		for i in range(1, count):
			angles.append(i * step)
	var result := []
	for a in angles:
		if absf(a) > 1e-9:
			result.append(UTIL.rotation_about(axis.origin, axis.direction, a))
	return result


static func _path(r: UTIL.Reader) -> Array:
	var wire := r.path("path")
	var count := int(r.num("quantity", null, "count"))
	var distance := r.num("distance")
	if not r.ok():
		return []
	var length := UTIL.wire_length(wire)
	if length <= 0.0:
		r.fail("The path has no length")
		return []
	var step := distance if str(r.opt("distance_type", "extent")) == "spacing" else (distance / (count - 1) if count > 1 else 0.0)
	var flip := bool(r.opt("flip", false))
	var follow := str(r.opt("orientation", "identical")) == "path"
	var start := UTIL.along_wire(wire, 1.0 if flip else 0.0)
	var result := []
	for i in range(1, count):
		var s := i * step
		if s > length + 1e-9:
			break
		var fraction := (length - s) / length if flip else s / length
		var at := UTIL.along_wire(wire, fraction)
		var basis := Basis.IDENTITY
		if follow:
			basis = UTIL.turn_along_wire(wire, 1.0 if flip else 0.0, fraction)
		result.append(Transform3D(basis, (at.point as Vector3) - basis * (start.point as Vector3)))
	return result
