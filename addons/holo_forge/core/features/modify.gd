@tool
extends RefCounted
## Modify features: Fillet, Chamfer, Shell, Draft, Scale, Combine, Offset Face, Replace Face,
## Split Face, Split Body, Silhouette Split, Move/Copy, Align, Remove; and the Create features
## that start from existing geometry: Thicken, Boundary Fill and Base Feature.
##
## Surface bodies (open shells) take these too: Split Body cuts them into regions, Thicken turns
## them solid, Fillet and Chamfer round edges two faces share.
##
## Fillet: edges (edges; a face stands for its edges; a body for every sharp edge matching
## options.rule: all | rounds | fillets), radius_type (constant | variable | chord); inputs
## radius, radius2. Chamfer: edges, chamfer_type (equal | two | angle); inputs distance,
## distance2, angle. Shell: faces (removed; a body alone is hollowed), direction (inside |
## outside | both); input thickness. Draft: faces, plane (fixed plane; its normal pulls), flip,
## side (one | symmetric); input angle. Move/Copy: objects, move_type (free | translate | rotate |
## point_to_point), axis, from_point, to_point, copy; inputs x, y, z, rx, ry, rz, distance, angle.
## Remove: bodies, faces (the Delete action makes it for faces and for split-off bodies).
##
## Mesh bodies (core/mesh/mesh_body.gd): Move/Copy moves and copies them (CadMesh.transformed) and
## Remove removes them. Every other feature here refuses one with the gate sentence
## (UTIL.MESH_GATE), through UTIL.Reader or, where a pick is read directly, Reader.gated().

const UTIL := preload("res://addons/holo_forge/core/features/util.gd")
const OPERATIONS := preload("res://addons/holo_forge/core/operations.gd")
const REFERENCES := preload("res://addons/holo_forge/core/references.gd")
const MESH_BODY := preload("res://addons/holo_forge/core/mesh/mesh_body.gd")
const MESH := preload("res://addons/holo_forge/core/features/mesh.gd")

const KERNEL_OPS := {"join": 0, "cut": 1, "intersect": 2}


static func build(feature: Resource, ctx: Dictionary) -> String:
	var r := UTIL.Reader.new(feature, ctx)
	match feature.type:
		"fillet", "chamfer":
			return _round(r)
		"shell":
			return _shell(r)
		"draft":
			return _draft(r)
		"scale":
			return _scale(r)
		"combine":
			return _combine(r)
		"offset_face":
			return _offset_face(r)
		"replace_face":
			return _replace_face(r)
		"split_face":
			return _split_face(r)
		"split_body", "silhouette_split":
			return _split_body(r)
		"move":
			return _move(r)
		"align":
			return _align(r)
		"remove":
			return _remove(r)
		"thicken":
			return _thicken(r)
		"boundary_fill":
			return _boundary_fill(r)
		"base_feature":
			return _base_feature(r)
	return "Unknown feature '%s'" % feature.type


# --- Edges -----------------------------------------------------------------------------------

## Picked edges grouped by body; faces stand for their edges and bodies for their sharp edges.
static func edge_groups(r: UTIL.Reader, key: String) -> Dictionary:
	var groups := {}
	var edge_picks := []
	var rule := str(r.opt("rule", "all"))
	for pick in r.refs(key):
		var indices := PackedInt32Array()
		var shape: RefCounted = null
		var body_id := str(pick.get("body", ""))
		match str(pick.get("kind", "")):
			"edge":
				edge_picks.append(pick)
				continue
			"face":
				var found := REFERENCES.face(pick, r.ctx)
				if found.has("error"):
					r.fail(found.error)
					return {}
				r.repaired += 1 if found.repaired else 0
				shape = found.shape
				for e in found.shape.face_info(found.index).get("edges", []):
					indices.append(int(e))
			"body":
				shape = REFERENCES.body_shape(pick, r.ctx)
				if shape == null:
					r.fail("Body %s no longer exists" % r.ctx.doc.body_name(body_id))
					return {}
				if r.gated([body_id]):
					return {}
				for e in shape.edge_count():
					var info: Dictionary = shape.edge_info(e)
					if float(info.get("dihedral", 0.0)) < 1e-3:
						continue
					var convex := bool(info.get("convex", false))
					if rule == "all" or (rule == "rounds" and convex) or (rule == "fillets" and not convex):
						indices.append(e)
		if shape == null:
			continue
		_merge(groups, body_id, shape, indices)
	if not edge_picks.is_empty():
		var found := r.sub_shapes_from(edge_picks, "edge")
		for body_id in found:
			_merge(groups, body_id, found[body_id].shape, found[body_id].indices)
	if groups.is_empty():
		r.fail("Select edges")
	return groups


## Adds indices to a body's group (packed arrays are copied, so the group is rebuilt).
static func _merge(groups: Dictionary, body_id: String, shape: RefCounted, more: PackedInt32Array) -> void:
	var indices: PackedInt32Array = groups.get(body_id, {}).get("indices", PackedInt32Array())
	for e in more:
		if not indices.has(e):
			indices.append(e)
	groups[body_id] = {"shape": groups.get(body_id, {}).get("shape", shape), "indices": indices}


static func _round(r: UTIL.Reader) -> String:
	var params := {"tag": r.feature.id}
	if r.feature.type == "fillet":
		params.type = str(r.opt("radius_type", "constant"))
		params.radius = r.num("radius", null, "positive")
		if params.type == "variable":
			params.radius2 = r.num("radius2", null, "positive")
	else:
		params.type = str(r.opt("chamfer_type", "equal"))
		params.distance = r.num("distance", null, "positive")
		if params.type == "two":
			params.distance2 = r.num("distance2", null, "positive")
		elif params.type == "angle":
			params.angle = r.num("angle", null, "positive")
	var groups := edge_groups(r, "edges")
	if not r.ok():
		return r.error
	for body_id in groups:
		var group: Dictionary = groups[body_id]
		if (group.indices as PackedInt32Array).is_empty():
			continue
		var shape: RefCounted = r.kernel.fillet(group.shape, group.indices, params) if r.feature.type == "fillet" else r.kernel.chamfer(group.shape, group.indices, params)
		var error := UTIL.replace(r, body_id, r.noted(shape, r.feature.type.capitalize()), r.feature.type.capitalize())
		if error != "":
			return error
	return ""


# --- Bodies ----------------------------------------------------------------------------------

static func _shell(r: UTIL.Reader) -> String:
	var thickness := r.num("thickness", null, "positive")
	var params := {"thickness": thickness, "direction": str(r.opt("direction", "inside")), "tag": r.feature.id}
	var groups := {}
	var face_picks := r.refs("faces").filter(func(p: Dictionary) -> bool: return p.get("kind", "") == "face")
	if not face_picks.is_empty():
		groups = r.sub_shapes_from(face_picks, "face")
	for body_id in r.bodies("faces", false):
		if not groups.has(body_id):
			groups[body_id] = {"shape": r.ctx.bodies[body_id].shape, "indices": PackedInt32Array()}
	if groups.is_empty():
		r.fail("Select faces to remove, or a body to hollow")
	if not r.ok():
		return r.error
	for body_id in groups:
		var error := UTIL.replace(r, body_id, r.kernel.shell(groups[body_id].shape, groups[body_id].indices, params), "Shell")
		if error != "":
			return error
	return ""


static func _draft(r: UTIL.Reader) -> String:
	var angle := r.num("angle", null)
	var groups := r.sub_shapes("faces", "face")
	var neutral := r.plane("plane")
	if not r.ok():
		return r.error
	var pull: Vector3 = (neutral.normal as Vector3) * (-1.0 if bool(r.opt("flip", false)) else 1.0)
	for body_id in groups:
		var shape: RefCounted = groups[body_id].shape
		var indices: PackedInt32Array = groups[body_id].indices
		if str(r.opt("side", "one")) != "symmetric":
			var error := UTIL.replace(r, body_id, r.kernel.draft(shape, indices, {"angle": angle, "pull": pull, "neutral_origin": neutral.origin, "neutral_normal": neutral.normal, "tag": r.feature.id}), "Draft")
			if error != "":
				return error
			continue
		# Symmetric: split the faces at the plane, then draft each side away from it.
		var names := []
		for i in indices:
			names.append(shape.get_face_names()[i])
		var split := r.checked(r.kernel.split_faces(shape, indices, r.kernel.plane_face(neutral.origin, neutral.normal, UTIL.model_size(r.ctx), r.feature.id), r.feature.id), "Draft split")
		if split == null:
			return r.error
		var above := PackedInt32Array()
		var below := PackedInt32Array()
		var split_names: PackedStringArray = split.get_face_names()
		for f in split.face_count():
			var base := split_names[f].get_slice("#", 0)
			if not names.has(base) and not names.has(split_names[f]):
				continue
			var center: Vector3 = split.face_info(f).point
			if (center - (neutral.origin as Vector3)).dot(neutral.normal) >= 0.0:
				above.append(f)
			else:
				below.append(f)
		var result: RefCounted = split
		if not above.is_empty():
			result = r.checked(r.kernel.draft(result, above, {"angle": angle, "pull": pull, "neutral_origin": neutral.origin, "neutral_normal": neutral.normal, "tag": r.feature.id}), "Draft")
		if result != null and not below.is_empty():
			# Faces keep their names through the first draft; find the lower ones again.
			var lower := PackedInt32Array()
			var result_names: PackedStringArray = result.get_face_names()
			for f in below:
				var at := result_names.find(split_names[f])
				if at >= 0:
					lower.append(at)
			result = r.checked(r.kernel.draft(result, lower, {"angle": angle, "pull": -pull, "neutral_origin": neutral.origin, "neutral_normal": neutral.normal, "tag": r.feature.id}), "Draft")
		var error := UTIL.replace(r, body_id, result, "Draft")
		if error != "":
			return error
	return ""


static func _scale(r: UTIL.Reader) -> String:
	var ids := r.bodies("bodies")
	var pivot := r.point("point", Vector3.ZERO)
	var factors := Vector3.ONE * r.num("scale", 1.0, "positive")
	if str(r.opt("scale_type", "uniform")) == "non_uniform":
		factors = Vector3(r.num("scale_x", 1.0, "positive"), r.num("scale_y", 1.0, "positive"), r.num("scale_z", 1.0, "positive"))
	if not r.ok():
		return r.error
	var basis := Basis.from_scale(factors)
	var xform := Transform3D(basis, pivot - basis * pivot)
	for body_id in ids:
		var error := UTIL.replace(r, body_id, r.kernel.transform_shape(r.ctx.bodies[body_id].shape, xform, r.feature.id), "Scale")
		if error != "":
			return error
	return ""


static func _combine(r: UTIL.Reader) -> String:
	var targets := r.bodies("target")
	var tools := r.bodies("tools")
	var op := str(r.opt("operation", "join"))
	if not KERNEL_OPS.has(op):
		r.fail("Combine joins, cuts or intersects")
	if not r.ok():
		return r.error
	var target: String = targets[0]
	var shape: RefCounted = r.ctx.bodies[target].shape
	for tool_id in tools:
		if tool_id == target:
			continue
		shape = r.checked(r.kernel.boolean(shape, r.ctx.bodies[tool_id].shape, KERNEL_OPS[op], r.feature.id), "Combine")
		if shape == null:
			return r.error
		if not bool(r.opt("keep_tools", false)):
			r.ctx.bodies.erase(tool_id)
	r.ctx.bodies[target].shape = shape
	UTIL._warn(r)
	return ""


## Remove: the picked bodies go; picked faces leave their bodies (a solid opens into a surface,
## and a body left with no faces goes).
static func _remove(r: UTIL.Reader) -> String:
	# Mesh bodies are removed like any body (their faces can't be picked: sub_shapes refuses them).
	var ids := r.bodies("bodies", false, true)
	var groups := r.sub_shapes("faces", "face") if not r.refs("faces").is_empty() else {}
	if r.ok() and ids.is_empty() and groups.is_empty():
		r.fail("Select bodies or faces to remove")
	if not r.ok():
		return r.error
	for body_id in groups:
		if ids.has(body_id):
			continue
		var shape: RefCounted = groups[body_id].shape
		var rest := PackedInt32Array()
		for f in shape.face_count():
			if not (groups[body_id].indices as PackedInt32Array).has(f):
				rest.append(f)
		if rest.is_empty():
			r.ctx.bodies.erase(body_id)
			continue
		var error := UTIL.replace(r, body_id, r.kernel.keep_faces(shape, rest), "Remove")
		if error != "":
			return error
	for body_id in ids:
		r.ctx.bodies.erase(body_id)
	UTIL._warn(r)
	return ""


# --- Faces -----------------------------------------------------------------------------------

static func _offset_face(r: UTIL.Reader) -> String:
	var distance := r.num("distance")
	var groups := r.sub_shapes("faces", "face")
	if not r.ok():
		return r.error
	for body_id in groups:
		var error := UTIL.replace(r, body_id, r.kernel.offset_faces(groups[body_id].shape, groups[body_id].indices, distance, r.feature.id), "Offset Face")
		if error != "":
			return error
	return ""


## Replace Face moves the source faces onto the target. Flat faces onto a parallel plane or flat
## face move straight there (as Offset Face); otherwise (a surface body, a curved face, a plane at
## an angle) the solid grows out to the target or is cut back to it, the faces round the source
## faces carried on along their normal (the kernel refuses, naming it, one that doesn't run so).
static func _replace_face(r: UTIL.Reader) -> String:
	var groups := r.sub_shapes("faces", "face")
	var target := _replace_target(r)
	if not r.ok():
		return r.error
	for body_id in groups:
		var shape: RefCounted = groups[body_id].shape
		var indices: PackedInt32Array = groups[body_id].indices
		if not _onto_parallel_plane(shape, indices, target):
			var error := UTIL.replace(r, body_id, r.kernel.replace_faces(shape, indices, target.shape, {"tag": r.feature.id}), "Replace Face")
			if error != "":
				return error
			continue
		var names := []
		for i in indices:
			names.append(shape.get_face_names()[i])
		for name in names:
			var index: int = shape.find_face(name)
			var info: Dictionary = shape.face_info(index)
			var n: Vector3 = info.get("normal", Vector3.ZERO)
			var distance := ((target.plane.origin as Vector3) - (info.point as Vector3)).dot(n)
			if absf(distance) < 1e-12:
				continue
			shape = r.checked(r.kernel.offset_faces(shape, PackedInt32Array([index]), distance, r.feature.id), "Replace Face")
			if shape == null:
				return r.error
		r.ctx.bodies[body_id].shape = shape
	UTIL._warn(r)
	return ""


## The Replace Face target: {"shape": a surface body, a face, or a plane as a big face; "plane":
## {"origin", "normal"} too when it is flat}, or {} after fail().
static func _replace_target(r: UTIL.Reader) -> Dictionary:
	var pick := r.ref("target")
	if pick.is_empty():
		r.fail("Select the target (a plane, face or surface body)")
		return {}
	match str(pick.get("kind", "")):
		"body":
			var shape := REFERENCES.body_shape(pick, r.ctx)
			if shape == null:
				r.fail("The target body is gone")
				return {}
			if r.gated([pick.get("body", "")]):
				return {}
			if not shape.is_surface():
				r.fail("Pick a surface body, a face or a plane as the target")
				return {}
			return {"shape": shape}
		"face":
			var found := REFERENCES.face(pick, r.ctx)
			if found.has("error"):
				r.fail(found.error)
				return {}
			r.repaired += 1 if found.repaired else 0
			var info: Dictionary = found.shape.face_info(found.index)
			if not info.get("planar", false):
				return {"shape": found.shape.face_shape(found.index)}
	var plane := r.plane("target")
	if plane.is_empty():
		return {}
	return {"shape": r.kernel.plane_face(plane.origin, plane.normal, UTIL.model_size(r.ctx), r.feature.id), "plane": plane}


## True when every picked face is flat and parallel to a flat target: it moves straight onto it.
static func _onto_parallel_plane(shape: RefCounted, indices: PackedInt32Array, target: Dictionary) -> bool:
	if not target.has("plane"):
		return false
	for i in indices:
		var info: Dictionary = shape.face_info(i)
		var n: Vector3 = info.get("normal", Vector3.ZERO)
		if not info.get("planar", false) or absf(absf(n.dot(target.plane.normal)) - 1.0) > 1e-6:
			return false
	return true


static func _split_face(r: UTIL.Reader) -> String:
	var groups := r.sub_shapes("faces", "face")
	var tool := r.tool_shape("tool", UTIL.model_size(r.ctx))
	if not r.ok():
		return r.error
	for body_id in groups:
		var error := UTIL.replace(r, body_id, r.kernel.split_faces(groups[body_id].shape, groups[body_id].indices, tool, r.feature.id), "Split Face")
		if error != "":
			return error
	return ""


## Split Body by a plane, face or body; Silhouette Split by the plane through the body's middle
## facing the picked direction (approximation of the outline as seen from that direction).
static func _split_body(r: UTIL.Reader) -> String:
	var ids := r.bodies("body")
	if not r.ok():
		return r.error
	var body_id: String = ids[0]
	var shape: RefCounted = r.ctx.bodies[body_id].shape
	var tool: RefCounted
	if r.feature.type == "silhouette_split":
		var pick := r.ref("direction")
		var direction := Vector3.UP
		if not pick.is_empty():
			var axis := REFERENCES.axis(pick, r.ctx)
			if axis.has("error"):
				var plane := r.plane("direction")
				direction = plane.get("normal", Vector3.UP)
			else:
				direction = axis.direction
		tool = r.kernel.plane_face((shape.bbox() as AABB).get_center(), direction, UTIL.model_size(r.ctx), r.feature.id)
	else:
		tool = r.tool_shape("tool", UTIL.model_size(r.ctx))
	if not r.ok():
		return r.error
	var pieces := r.checked(r.kernel.split_body(shape, tool, {"tag": r.feature.id}), "Split Body")
	if pieces == null:
		return r.error
	# Every piece is a body: each solid, and a surface's regions along the cut (each a shell of its
	# own); open sheets beside a solid stay pieces too.
	var parts: Array = r.kernel.pieces(pieces)
	if parts.size() <= r.kernel.pieces(shape).size():
		return "The splitting tool doesn't cut through the body"
	r.ctx.bodies[body_id].shape = parts[0]
	for k in range(1, parts.size()):
		var id := UTIL.derived_body_id(body_id, r.feature.id, k + 1)
		r.ctx.bodies[id] = {"id": id, "shape": parts[k], "feature": r.feature.id}
	UTIL._warn(r)
	return ""


# --- Placement -------------------------------------------------------------------------------

static func _move(r: UTIL.Reader) -> String:
	# Move/Copy takes mesh bodies too (_place moves them with CadMesh.transformed).
	var ids := r.bodies("objects", true, true)
	if not r.ok():
		return r.error
	var xform := Transform3D.IDENTITY
	match str(r.opt("move_type", "free")):
		"free":
			var box := AABB()
			for i in ids.size():
				var b: AABB = r.ctx.bodies[ids[i]].shape.bbox()
				box = b if i == 0 else box.merge(b)
			var pivot := box.get_center()
			var basis := Basis.from_euler(Vector3(r.num("rx", 0.0), r.num("ry", 0.0), r.num("rz", 0.0)))
			xform = Transform3D(basis, pivot - basis * pivot + Vector3(r.num("x", 0.0), r.num("y", 0.0), r.num("z", 0.0)))
		"translate":
			var axis := r.axis("axis")
			if r.ok():
				xform = Transform3D(Basis.IDENTITY, (axis.direction as Vector3).normalized() * r.num("distance"))
		"rotate":
			var axis := r.axis("axis")
			if r.ok():
				xform = UTIL.rotation_about(axis.origin, axis.direction, r.num("angle"))
		"point_to_point":
			xform = Transform3D(Basis.IDENTITY, r.point("to_point") - r.point("from_point"))
	if not r.ok():
		return r.error
	return _place(r, ids, xform, "Move", true)


## Align: moves the body of the "from" pick so it meets the "to" pick: points meet; flat faces
## and planes also turn to face each other (or the same way with flip).
static func _align(r: UTIL.Reader) -> String:
	var from := r.ref("from")
	if from.is_empty() or r.ref("to").is_empty():
		return "Select what to align, then where it goes"
	var source := _frame(r, from)
	var target := _frame(r, r.ref("to"))
	if not r.ok():
		return r.error
	var basis := Basis.IDENTITY
	if source.has("normal") and target.has("normal"):
		var wanted: Vector3 = target.normal if bool(r.opt("flip", false)) else -(target.normal as Vector3)
		basis = UTIL.rotation_between(source.normal, wanted)
	var goal: Vector3 = target.point
	if target.get("plane", false):
		# Onto a plane: move straight across to it, not to the plane's origin.
		var n: Vector3 = target.normal
		goal = (source.point as Vector3) - n * ((source.point as Vector3) - (target.point as Vector3)).dot(n)
	var xform := Transform3D(basis, goal - basis * (source.point as Vector3))
	var ids := r.bodies("objects", false)
	if not r.ok():
		return r.error
	if ids.is_empty():
		if not r.ctx.bodies.has(from.get("body", "")):
			return "Pick something on a body to align"
		ids = [from.body]
	return _place(r, ids, xform, "Align")


## A point (and normal, for flat faces and planes) for an align pick.
static func _frame(r: UTIL.Reader, pick: Dictionary) -> Dictionary:
	match str(pick.get("kind", "")):
		"face":
			var found := REFERENCES.face(pick, r.ctx)
			if found.has("error"):
				r.fail(found.error)
				return {}
			var info: Dictionary = found.shape.face_info(found.index)
			if info.get("planar", false):
				return {"point": info.point, "normal": info.normal}
			return {"point": info.point}
		"origin", "construct":
			var plane := REFERENCES.plane(pick, r.ctx)
			if not plane.has("error"):
				return {"point": plane.origin, "normal": plane.normal, "plane": true}
	var p := REFERENCES.point(pick, r.ctx)
	if p.has("error"):
		r.fail(p.error)
		return {}
	return {"point": p.point}


## Moves (or copies) bodies by xform. allow_mesh: mesh bodies are moved too (Move/Copy); without it
## one is refused with the gate sentence (Align).
static func _place(r: UTIL.Reader, ids: Array, xform: Transform3D, what: String, allow_mesh := false) -> String:
	if not allow_mesh and r.gated(ids):
		return r.error
	var copy := bool(r.opt("copy", false))
	for body_id in ids:
		var is_mesh := MESH_BODY.is_mesh(r.ctx.bodies[body_id])
		var moved: RefCounted = null
		if is_mesh:
			var mesh: RefCounted = r.ctx.bodies[body_id].shape
			# (Kept by content: a rebuild that moves nothing gives the same mesh back.)
			moved = MESH.transformed(mesh, xform)
			if moved == null or moved.is_null():
				var why := str(mesh.get_last_error())
				r.fail("%s failed%s" % [what, (": " + why) if why != "" else ""])
				return r.error
		else:
			moved = r.checked(r.kernel.transform_shape(r.ctx.bodies[body_id].shape, xform, r.feature.id), what)
			if moved == null:
				return r.error
		if copy:
			var id := UTIL.derived_body_id(body_id, r.feature.id, 1, ids)
			r.ctx.bodies[id] = MESH_BODY.entry(id, moved, r.feature.id) if is_mesh else {"id": id, "shape": moved, "feature": r.feature.id}
		else:
			r.ctx.bodies[body_id].shape = moved
	UTIL._warn(r)
	return ""


# --- Solids from faces -----------------------------------------------------------------------

## Thicken: picked faces (a body: all its faces; faces that meet thicken as one sheet).
## thicken_type: sharp (seams mitred) | rounded (convex seams rounded over).
static func _thicken(r: UTIL.Reader) -> String:
	var thickness := r.num("thickness", null, "positive") * (-1.0 if bool(r.opt("flip", false)) else 1.0)
	var groups := r.faces_or_bodies("faces")
	if not r.ok():
		return r.error
	var params := {"thickness": thickness, "symmetric": str(r.opt("direction", "one")) == "symmetric",
		"type": str(r.opt("thicken_type", "sharp")), "tag": r.feature.id}
	var parts := []
	for body_id in groups:
		var part := r.checked(r.kernel.thicken(groups[body_id].shape, groups[body_id].indices, params), "Thicken")
		if part == null:
			return r.error
		parts.append(part)
	return UTIL.finish(r, parts[0] if parts.size() == 1 else r.kernel.make_compound(parts), "Thicken")


## Boundary Fill: the closed cells the picked tools (bodies, faces, planes) make; options.cells
## holds points inside the cells to keep (all cells when empty).
static func _boundary_fill(r: UTIL.Reader) -> String:
	var shapes := []
	var size := UTIL.model_size(r.ctx)
	for pick in r.refs("tools"):
		match str(pick.get("kind", "")):
			"body":
				var s := REFERENCES.body_shape(pick, r.ctx)
				if s == null:
					r.fail("A boundary body is gone")
				elif r.gated([pick.get("body", "")]):
					return r.error
				shapes.append(s)
			"face":
				var found := REFERENCES.face(pick, r.ctx)
				if found.has("error"):
					r.fail(found.error)
				else:
					shapes.append(found.shape.face_shape(found.index))
			_:
				var plane := REFERENCES.plane(pick, r.ctx)
				if plane.has("error"):
					r.fail(plane.error)
				else:
					shapes.append(r.kernel.plane_face(plane.origin, plane.normal, size, r.feature.id))
	if shapes.is_empty():
		r.fail("Select the bodies, faces or planes that bound the cells")
	if not r.ok():
		return r.error
	# Cells to keep: points inside them (picked points, or plain positions).
	var cells := PackedVector3Array()
	for cell in r.opt("cells", []):
		if cell is Vector3:
			cells.append(cell)
		elif cell is Dictionary:
			var p := REFERENCES.point(cell, r.ctx)
			if p.has("error"):
				r.fail(p.error)
			else:
				cells.append(p.point)
	return UTIL.finish(r, r.kernel.boundary_fill(shapes, cells, r.feature.id), "Boundary Fill")


## A base feature holds bodies as fixed shapes (BRep bytes in options.breps: body id -> bytes),
## for geometry that has no history (imports, direct edits).
static func _base_feature(r: UTIL.Reader) -> String:
	var breps: Dictionary = r.opt("breps", {})
	if breps.is_empty():
		return "The base feature holds no bodies"
	for body_id in breps:
		var shape: RefCounted = ClassDB.instantiate("CadShape")
		if not shape.load_brep_bytes(breps[body_id]):
			return "A base feature body could not be read"
		r.ctx.bodies[body_id] = {"id": body_id, "shape": shape, "feature": r.feature.id}
	return ""
