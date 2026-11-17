@tool
extends RefCounted
## Appearances on bodies: which material each face shows, texture coordinates at real size, the
## baked mesh with one surface per appearance, and where decals go.
##
## doc.appearances targets: "face:<body id>:<face name>" beats "body:<body id>" beats
## "component:<id>" (the body's component, then the components it sits in). Bodies a feature
## splits off or copies ("body3.f7.2") fall back to the body they came from.
##
## Face appearances follow a face through later splits: the pieces ("<name>#k") show what the face
## showed until they get entries of their own (face_name_chain).
##
## Mapping dictionaries (missing keys take DEFAULT_MAPPING):
##   type "automatic"    flat faces: the face's own plane (on walls its y runs up the world, so
##                       they read upright as with box mapping; on tops x runs along world X);
##                       curved faces: the surface's u,v stretched to meters
##                       (CadShape.face_uv_metric)
##        "planar"       projected along axis (zero axis: the face's normal when it is flat, else +Y),
##                       upright like automatic
##        "box"          each flat face (each triangle of a curved one) projected onto the side of a
##                       box (its up direction is axis, default +Y) that its normal points to
##        "cylindrical"  around axis (default +Y) through origin: u = angle * distance from the
##                       axis, v = height; caps (facing more than 45 degrees along the axis) are
##                       projected flat along it
##        "spherical"    around origin, poles along axis (default +Y): u = longitude * radius,
##                       v = latitude * radius
##   scale     Vector2, meters per texture repeat (negative flips)
##   rotation  radians, turns the texture counter-clockwise on the surface
##   offset    Vector2, in repeats
##   origin, axis  Vector3, the projection's center and direction, in body coordinates
## uv = (surface meters).rotated(rotation) / scale + offset. Seen from the side a face faces
## (outside, or the axis side of a bore), textures are not mirrored: u runs right and v down, like
## the image. Round projections start (u = 0) where they wrap: in the widest empty stretch around
## the axis when the faces don't go all the way round (so they need no wrap at all), else at a seam
## of the body, else at the frame's x direction.
##
## Mesh bodies (core/mesh/mesh_body.gd): a face group stands for a face, so a body's appearance
## and a group's ("face:<body id>:<group name>") work as on any body. Group names such as g0..gN
## are given by order, so a group's entry may also hold "at" (the point it was picked at) and
## "normal" (how the surface faced there; face_anchor() makes both from a pick): build_mesh()
## then finds the group again where it was picked when an earlier change renumbers the groups
## (MESH_BODY.resolve_group), and says so in its result's "notes". An entry without them goes by
## name. A group that isn't flat has
## no surface parameters: automatic mapping gives it the mesh's own box projection (in meters).
## Decals need a B-rep face: placed_decal() refuses a mesh body (decal_gate()).

const MATERIAL_LIBRARY := preload("res://addons/holo_forge/core/material_library.gd")
const INSPECT := preload("res://addons/holo_forge/core/inspect.gd")
const SKETCH_DATA := preload("res://addons/holo_forge/core/sketch/sketch_data.gd")
const UTIL := preload("res://addons/holo_forge/core/features/util.gd")
const MESH_BODY := preload("res://addons/holo_forge/core/mesh/mesh_body.gd")

const TYPES := ["automatic", "planar", "box", "cylindrical", "spherical"]
const TYPE_LABELS := {"automatic": "Automatic", "planar": "Planar", "box": "Box", "cylindrical": "Cylindrical", "spherical": "Spherical"}
const DEFAULT_MAPPING := {
	"type": "automatic", "scale": Vector2(0.1, 0.1), "offset": Vector2.ZERO, "rotation": 0.0,
	"origin": Vector3.ZERO, "axis": Vector3.ZERO,
}
## Points closer than this to a round projection's axis have no angle of their own.
const AXIS_EPSILON := 1e-6
## Normals closer than this (squared) count as the same: the face is flat.
const FLAT_EPSILON := 1e-8
## cos(45 degrees): cylindrical mapping treats triangles facing further along the axis as caps.
const CAP_FACING := 0.7071067811865476
## A triangle wraps round a projection's cut when its corners spread more than half a turn (plus
## this, so a flat face lying through the axis, exactly half a turn wide, never counts).
const WRAP_SLACK := 1e-6
## Round projections run u the other way round on a triangle whose normal points toward the axis
## (or center) by more than this (cosine): a face lying along the axis keeps the usual way.
const FACING_EPSILON := 1e-4
## A triangle whose area in a round projection's plane is under this times its size squared is
## seen edge-on there.
const SLIVER := 1e-6
## The axis counts as on a triangle's edge within this fraction of the triangle's size.
const AROUND_REACH := 1e-3


# --- Targets and lookup ------------------------------------------------------------------------

static func face_target(body_id: String, face_name: String) -> String:
	return "face:%s:%s" % [body_id, face_name]


static func body_target(body_id: String) -> String:
	return "body:" + body_id


static func component_target(component_id: String) -> String:
	return "component:" + component_id


## A mapping with every key filled in.
static func mapping_with_defaults(mapping: Dictionary) -> Dictionary:
	var result := DEFAULT_MAPPING.duplicate()
	for key in mapping:
		var value: Variant = mapping[key]
		# A value of another kind than the default's would stop the bake half way: one number for
		# a two-way value counts both ways, a whole number for a decimal one is taken, anything
		# else leaves the default.
		if result.has(key) and typeof(value) != typeof(result[key]):
			if result[key] is Vector2 and (value is float or value is int):
				value = Vector2(float(value), float(value))
			elif result[key] is float and value is int:
				value = float(value)
			else:
				continue
		result[key] = value
	return result


## The body appearances are read from when a body has no settings of its own ("body3.f7.2" ->
## "body3").
static func source_body(doc: Resource, body_id: String) -> String:
	return body_id if doc.bodies.has(body_id) else body_id.split(".")[0]


## What a face shows: {"material": appearance id or "", "mapping": full mapping, "source":
## "face" | "body" | "component" | "", "target": the doc.appearances key it reads ("" for none)}.
## face_name "" asks for the body's own appearance. A face a later feature split ("f1:y+#1")
## keeps what the face it came from showed: the nearest name in face_name_chain with an entry
## wins, the body's own entry before its source body's for the same name.
static func resolve(doc: Resource, body_id: String, face_name: String) -> Dictionary:
	var appearances: Dictionary = doc.appearances
	var source := source_body(doc, body_id)
	if face_name != "":
		for candidate in face_name_chain(face_name):
			for id in [body_id, source]:
				var hit := _entry(appearances, face_target(id, candidate), "face")
				if not hit.is_empty():
					return hit
	return _body_level(doc, body_id)


## A face name and the names of the faces it was split from, nearest first: "f1:y+#0#1" ->
## ["f1:y+#0#1", "f1:y+#0", "f1:y+"]. A feature that splits a face (a groove across it, Split Body,
## Split Face) names the pieces "<name>#k" (see naming.h).
static func face_name_chain(face_name: String) -> PackedStringArray:
	var chain := PackedStringArray([face_name])
	var current := face_name
	while true:
		var mark := current.rfind("#")
		if mark <= 0:
			break
		var tail := current.substr(mark + 1)
		if tail == "" or tail.lstrip("0123456789") != "":
			break
		current = current.substr(0, mark)
		chain.append(current)
	return chain


## The look in face_entries (from _face_entries) for a face, through the faces it was split from;
## fallback when none has one.
static func _face_look(face_entries: Dictionary, face_name: String, fallback: Dictionary) -> Dictionary:
	if face_name == "" or face_entries.is_empty():
		return fallback
	for candidate in face_name_chain(face_name):
		if face_entries.has(candidate):
			return face_entries[candidate]
	return fallback


static func _body_level(doc: Resource, body_id: String) -> Dictionary:
	var appearances: Dictionary = doc.appearances
	for id in [body_id, source_body(doc, body_id)]:
		var hit := _entry(appearances, body_target(id), "body")
		if not hit.is_empty():
			return hit
	var component: String = doc.body_component(body_id)
	var guard := 0
	while component != "" and guard < 64:
		var hit := _entry(appearances, component_target(component), "component")
		if not hit.is_empty():
			return hit
		component = str((doc.components.get(component, {}) as Dictionary).get("parent", ""))
		guard += 1
	return {"material": "", "mapping": mapping_with_defaults({}), "source": "", "target": ""}


static func _entry(appearances: Dictionary, key: String, source: String) -> Dictionary:
	var entry: Variant = appearances.get(key)
	if not (entry is Dictionary) or str(entry.get("material", "")) == "":
		return {}
	var hit := {"material": str(entry.material), "mapping": mapping_with_defaults(entry.get("mapping", {})), "source": source, "target": key}
	# (Where a mesh body's face group was picked: see _anchored.)
	for anchor in ["at", "normal"]:
		if entry.get(anchor) is Vector3:
			hit[anchor] = entry[anchor]
	return hit


## What a face group's appearance entry keeps to be found again ({"at", "normal"} from a view pick
## on a mesh body, {} for any other pick): merge it into the doc.appearances entry.
static func face_anchor(pick: Dictionary) -> Dictionary:
	var anchor := {}
	if str(pick.get("kind", "")) in ["mesh_group", "mesh_triangle"] and pick.get("point") is Vector3:
		anchor["at"] = pick.point
		if pick.get("normal") is Vector3:
			anchor["normal"] = pick.normal
	return anchor


## A mesh body's face group entries (from _face_entries), each under the name its group has now:
## an entry that knows where it was picked follows its group when an earlier change gave the name
## to another face (a note says so), and is left out when its group is gone (a note says so too).
## A group with an entry of its own keeps it.
static func _anchored(face_entries: Dictionary, shape: RefCounted, body_label: String, notes: PackedStringArray) -> Dictionary:
	var result := {}
	var moved := {}
	for face_name in face_entries:
		var look: Dictionary = face_entries[face_name]
		if not look.has("at"):
			result[face_name] = look
			continue
		var found := MESH_BODY.resolve_group(shape, {"group": face_name, "at": look.at, "normal": look.get("normal")})
		if found.has("error"):
			notes.append("The appearance of face group %s of %s is not shown: %s" % [face_name, body_label, found.error])
		elif bool(found.get("moved", false)):
			moved[str(found.name)] = look
			notes.append("The appearance of %s's face group %s now lands on face group %s, the one where it was picked (an earlier change renumbered the face groups or moved the body). Set it again if %s is meant." % [body_label, face_name, found.name, face_name])
		else:
			result[face_name] = look
	for face_name in moved:
		if not result.has(face_name):
			result[face_name] = moved[face_name]
	return result


## True when a body can read the doc.appearances entry target: its own face or body entries (or
## its source body's), or a component it sits in. Which faces actually show it is resolve's call.
static func reaches(doc: Resource, body_id: String, target: String) -> bool:
	var ids := [body_id, source_body(doc, body_id)]
	if target.begins_with("face:"):
		var rest := target.trim_prefix("face:")
		return ids.has(rest.substr(0, rest.find(":")))
	if target.begins_with("body:"):
		return ids.has(target.trim_prefix("body:"))
	if target.begins_with("component:"):
		var wanted := target.trim_prefix("component:")
		var component: String = doc.body_component(body_id)
		var guard := 0
		while component != "" and guard < 64:
			if component == wanted:
				return true
			component = str((doc.components.get(component, {}) as Dictionary).get("parent", ""))
			guard += 1
	return false


## Face appearances of one body by face name (its own beat its source body's). Look faces up with
## _face_look, so split faces find their original's.
static func _face_entries(doc: Resource, body_id: String) -> Dictionary:
	var source := source_body(doc, body_id)
	var own := {}
	var inherited := {}
	for key in doc.appearances:
		var text := str(key)
		if not text.begins_with("face:"):
			continue
		# Body ids have no ":"; face names may ("f1:y+").
		var rest := text.trim_prefix("face:")
		var split := rest.find(":")
		if split < 0:
			continue
		var owner_id := rest.substr(0, split)
		if owner_id != body_id and owner_id != source:
			continue
		var hit := _entry(doc.appearances, text, "face")
		if hit.is_empty():
			continue
		if owner_id == body_id:
			own[rest.substr(split + 1)] = hit
		else:
			inherited[rest.substr(split + 1)] = hit
	for face_name in own:
		inherited[face_name] = own[face_name]
	return inherited


# --- Texture coordinates -----------------------------------------------------------------------

## Real-size UVs for some of a face's tessellation vertices (vertex_indices index tess.positions),
## one per vertex. A vertex where the texture wraps around (a round projection's seam) gets the
## value of the first triangle that uses it; build_mesh splits such vertices instead.
static func uvs_for_face(shape: RefCounted, face_index: int, tess: Dictionary, vertex_indices: PackedInt32Array, mapping: Dictionary) -> PackedVector2Array:
	var tris := PackedInt32Array()
	var face_ids: PackedInt32Array = tess.get("face_ids", PackedInt32Array())
	for t in face_ids.size():
		if face_ids[t] == face_index:
			tris.append(t)
	var corners := face_corner_uvs(shape, face_index, tess, tris, mapping)
	var indices: PackedInt32Array = tess.get("indices", PackedInt32Array())
	var first := {}
	for k in tris.size():
		for c in 3:
			var v := indices[tris[k] * 3 + c]
			if not first.has(v):
				first[v] = corners[k * 3 + c]
	var result := PackedVector2Array()
	result.resize(vertex_indices.size())
	for i in vertex_indices.size():
		result[i] = first.get(vertex_indices[i], Vector2.ZERO)
	return result


## Real-size UVs for every corner of the given triangles (indices into tess.face_ids) of one
## face: three per triangle, in order. cut is the angle (in the projection frame) where round
## projections wrap; NAN picks one for this face (free_cut, else its seam, else the frame's x).
static func face_corner_uvs(shape: RefCounted, face_index: int, tess: Dictionary, tris: PackedInt32Array, mapping: Dictionary, cut := NAN) -> PackedVector2Array:
	var m := mapping_with_defaults(mapping)
	var positions: PackedVector3Array = tess.get("positions", PackedVector3Array())
	var normals: PackedVector3Array = tess.get("normals", PackedVector3Array())
	var indices: PackedInt32Array = tess.get("indices", PackedInt32Array())
	var out := PackedVector2Array()
	out.resize(tris.size() * 3)
	if tris.is_empty():
		return out
	var origin: Vector3 = m.origin
	var axis: Vector3 = m.axis
	match str(m.type):
		"planar":
			var direction := axis
			if direction.is_zero_approx():
				var flat := _flat_normal(tris, indices, normals)
				direction = flat if not flat.is_zero_approx() else Vector3.UP
			var frame := _upright_plane(origin, direction.normalized())
			for k in tris.size():
				for j in 3:
					out[k * 3 + j] = _in_plane(positions[indices[tris[k] * 3 + j]] - origin, frame)
		"box":
			var inverse := _box_basis(axis).transposed()
			for k in tris.size():
				var a := indices[tris[k] * 3]
				var b := indices[tris[k] * 3 + 1]
				var c := indices[tris[k] * 3 + 2]
				# The triangle's normal picks the side; on a flat face every triangle agrees.
				var side := inverse * (normals[a] + normals[b] + normals[c])
				for j in 3:
					out[k * 3 + j] = _box_project(inverse * (positions[indices[tris[k] * 3 + j]] - origin), side)
		"cylindrical", "spherical":
			out = _round(tris, indices, positions, normals, m, cut)
		_:
			var flat := _flat_normal(tris, indices, normals)
			if not flat.is_zero_approx():
				var frame := _upright_plane(positions[indices[tris[0] * 3]], flat)
				for k in tris.size():
					for j in 3:
						out[k * 3 + j] = _in_plane(positions[indices[tris[k] * 3 + j]] - frame.origin, frame)
			else:
				var raw: PackedVector2Array = tess.get("uvs", PackedVector2Array())
				# (A mesh body's own uvs are a box projection in meters already.)
				var is_mesh := MESH_BODY.is_mesh(shape)
				var metric: Vector2 = shape.face_uv_metric(face_index) if shape != null and not is_mesh else Vector2.ONE
				for k in tris.size():
					for j in 3:
						var v := indices[tris[k] * 3 + j]
						out[k * 3 + j] = (raw[v] if v < raw.size() else Vector2.ZERO) * metric
				# The surface's u may run either way round; turn it so the texture isn't mirrored.
				if not is_mesh and _winding(out) < 0.0:
					for k in out.size():
						out[k] = Vector2(-out[k].x, out[k].y)
	return _finish(out, m)


## The normal of a face whose triangles all share one (a flat face), else Vector3.ZERO.
static func _flat_normal(tris: PackedInt32Array, indices: PackedInt32Array, normals: PackedVector3Array) -> Vector3:
	var first := normals[indices[tris[0] * 3]]
	for t in tris:
		for c in 3:
			if normals[indices[t * 3 + c]].distance_squared_to(first) > FLAT_EPSILON:
				return Vector3.ZERO
	return first.normalized()


## A plane frame for a flat face ({"origin", "x", "y"}, as SKETCH_DATA.face_plane), the same way
## round as box mapping and unmirrored. On walls (faces box mapping puts on an X or Z side) y runs
## up the face (world up laid onto it), so textures and decals stand upright on every wall. On
## tops and bottoms it is face_plane's frame (x along world X, y toward -Z on a top), which turns
## smoothly as the face tilts: a slight tilt never turns the texture round.
static func _upright_plane(point: Vector3, normal: Vector3) -> Dictionary:
	var frame := SKETCH_DATA.face_plane(point, normal)
	var n := normal.normalized()
	if _is_wall(n):
		# (|n.y| < 0.71 on a wall, so up never lies along the normal.)
		var y := (Vector3.UP - n * n.y).normalized()
		frame.y = y
		frame.x = y.cross(n)
	return frame


## True for a direction box mapping puts on an X or Z side (it wins ties with Y), false for one it
## puts on the top or bottom.
static func _is_wall(n: Vector3) -> bool:
	return absf(n.y) < maxf(absf(n.x), absf(n.z))


## Plane coordinates with v pointing down the image (the frame's y is up).
static func _in_plane(d: Vector3, frame: Dictionary) -> Vector2:
	return Vector2(d.dot(frame.x), -d.dot(frame.y))


static func _box_basis(axis: Vector3) -> Basis:
	return Basis.IDENTITY if axis.is_zero_approx() else UTIL.rotation_between(Vector3.UP, axis)


## A point (box coordinates) projected onto the box side that normal n points to, each side
## seen from outside unmirrored.
static func _box_project(d: Vector3, n: Vector3) -> Vector2:
	var ax := absf(n.x)
	var ay := absf(n.y)
	var az := absf(n.z)
	if ax >= ay and ax >= az:
		return Vector2(-signf(n.x) * d.z, -d.y)
	if ay >= az:
		return Vector2(d.x, signf(n.y) * d.z)
	return Vector2(signf(n.z) * d.x, -d.y)


## Signed area of the corner triangles in uv space: positive when the texture is not mirrored
## (front faces are clockwise and v points down).
static func _winding(corners: PackedVector2Array) -> float:
	var total := 0.0
	for k in range(0, corners.size(), 3):
		total += (corners[k + 1] - corners[k]).cross(corners[k + 2] - corners[k])
	return total


## Cylindrical and spherical projections. Angles run from the cut; a triangle that spans the cut
## takes its low corners a full turn on, so the texture never smears back across the face.
## Cylindrical caps (triangles facing more than 45 degrees along the axis) would smear into
## rays, so they are projected flat along the axis instead. Triangles facing the axis (a bore, the
## inside of a hollow ball) are seen from the axis side, so u runs the other way round there, which
## keeps them unmirrored too. A triangle round the axis (one whose corners have no angle range: a
## tessellation without a vertex on the axis, such as a sphere whose poles lie elsewhere) takes
## one angle, its middle's, instead of smearing half a turn of texture across itself.
static func _round(tris: PackedInt32Array, indices: PackedInt32Array, positions: PackedVector3Array, normals: PackedVector3Array, m: Dictionary, cut: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	out.resize(tris.size() * 3)
	var spherical := str(m.type) == "spherical"
	var origin: Vector3 = m.origin
	var axis := _round_axis(m)
	var frame := SKETCH_DATA.face_plane(origin, axis)
	if is_nan(cut):
		cut = free_cut(tris, indices, positions, normals, m)
		if is_nan(cut):
			cut = seam_angle(tris, indices, positions, origin, axis)
		cut = 0.0 if is_nan(cut) else cut
	var angles := PackedFloat64Array()
	angles.resize(3)
	var on_axis: Array[bool] = [false, false, false]
	var flat: Array[Vector2] = [Vector2.ZERO, Vector2.ZERO, Vector2.ZERO]
	for k in tris.size():
		var t := tris[k]
		if not spherical:
			var facing := _cap_facing(t, indices, normals, axis)
			if absf(facing) > CAP_FACING:
				# Seen from the side it faces, unmirrored: the bottom cap runs x the other way.
				for j in 3:
					var d := positions[indices[t * 3 + j]] - origin
					out[k * 3 + j] = Vector2(signf(facing) * d.dot(frame.x), -d.dot(frame.y))
				continue
		var lo := INF
		var hi := -INF
		var middle := Vector3.ZERO
		for j in 3:
			var d := positions[indices[t * 3 + j]] - origin
			middle += d / 3.0
			flat[j] = Vector2(d.dot(frame.x), d.dot(frame.y))
			on_axis[j] = flat[j].length() < AXIS_EPSILON
			var angle := fposmod(atan2(flat[j].y, flat[j].x) - cut, TAU)
			# The seam itself starts the turn (atan2 lands either side of it).
			angles[j] = 0.0 if angle > TAU - 1e-5 else angle
			if not on_axis[j]:
				lo = minf(lo, angles[j])
				hi = maxf(hi, angles[j])
		var wraps := hi - lo > PI + WRAP_SLACK
		var known := 0
		var sum := 0.0
		for j in 3:
			if wraps and not on_axis[j] and angles[j] < PI:
				angles[j] += TAU
			if not on_axis[j]:
				sum += angles[j]
				known += 1
		# (A corner on the axis is a real pole, which the mean angle handles below. Corners round
		# the axis always spread at least half a turn.)
		var single := NAN
		if known == 0 or (known == 3 and hi - lo > PI * 0.9 and _surrounds_axis(flat)):
			var across := Vector2(middle.dot(frame.x), middle.dot(frame.y))
			var angle := fposmod(atan2(across.y, across.x) - cut, TAU) if across.length() >= AXIS_EPSILON else 0.0
			single = 0.0 if angle > TAU - 1e-5 else angle
		# Which way round u runs: the other way on a triangle facing the axis (or the center).
		var radial := middle if spherical else middle - axis * middle.dot(axis)
		var normal := normals[indices[t * 3]] + normals[indices[t * 3 + 1]] + normals[indices[t * 3 + 2]]
		var turn := -1.0 if normal.dot(radial) < -FACING_EPSILON * normal.length() * radial.length() else 1.0
		for j in 3:
			var d := positions[indices[t * 3 + j]] - origin
			var height := d.dot(axis)
			var rho := flat[j].length()
			# A point on the axis (a pole) takes its triangle's angle, which keeps the texture
			# from pinching to one side.
			var angle := single if not is_nan(single) else (angles[j] if not on_axis[j] else sum / known)
			if spherical:
				var radius := d.length()
				out[k * 3 + j] = Vector2(turn * angle * radius, -atan2(height, rho) * radius)
			else:
				out[k * 3 + j] = Vector2(turn * angle * rho, -height)
	return out


## True when a triangle (its corners in a round projection's plane, the axis at the plane's
## origin) goes round the axis or has an edge through it, so no stretch of angles holds its
## corners. A triangle seen edge-on (a face lying along the axis) doesn't count.
static func _surrounds_axis(corners: Array[Vector2]) -> bool:
	var area := (corners[1] - corners[0]).cross(corners[2] - corners[0])
	var size := 0.0
	for j in 3:
		size = maxf(size, corners[j].distance_to(corners[(j + 1) % 3]))
	if absf(area) <= SLIVER * size * size:
		return false
	# Within this of an edge counts as on it (the edge's own rounding).
	var reach := maxf(AXIS_EPSILON, AROUND_REACH * size)
	for j in 3:
		var edge := corners[(j + 1) % 3] - corners[j]
		# The axis' signed distance inside this edge (positive on the triangle's side).
		if edge.cross(-corners[j]) * signf(area) / edge.length() < -reach:
			return false
	return true


## A round projection's axis: the mapping's, or +Y when it has none.
static func _round_axis(m: Dictionary) -> Vector3:
	var axis: Vector3 = m.get("axis", Vector3.ZERO)
	return axis.normalized() if not axis.is_zero_approx() else Vector3.UP


## How far a triangle faces along the axis (its mean normal's dot with it).
static func _cap_facing(t: int, indices: PackedInt32Array, normals: PackedVector3Array, axis: Vector3) -> float:
	var n := (normals[indices[t * 3]] + normals[indices[t * 3 + 1]] + normals[indices[t * 3 + 2]]).normalized()
	return n.dot(axis)


## The angle (in a round projection's frame) of a cut no triangle crosses: the middle of the
## widest empty stretch around the axis. NAN when the triangles go all the way round (or none
## is off the axis). Cylindrical caps are left out, as _round projects them flat.
static func free_cut(tris: PackedInt32Array, indices: PackedInt32Array, positions: PackedVector3Array, normals: PackedVector3Array, mapping: Dictionary) -> float:
	var m := mapping_with_defaults(mapping)
	var origin: Vector3 = m.origin
	var axis := _round_axis(m)
	var frame := SKETCH_DATA.face_plane(origin, axis)
	var spherical := str(m.type) == "spherical"
	var kept := PackedInt32Array()
	var angles := PackedFloat64Array()
	for t in tris:
		if not spherical and absf(_cap_facing(t, indices, normals, axis)) > CAP_FACING:
			continue
		kept.append(t)
		for c in 3:
			var d := positions[indices[t * 3 + c]] - origin
			var p := Vector2(d.dot(frame.x), d.dot(frame.y))
			if p.length() >= AXIS_EPSILON:
				angles.append(atan2(p.y, p.x))
	if angles.is_empty():
		return NAN
	angles.sort()
	# The gap across the +-pi line first, then the ones between neighbours.
	var widest := angles[0] + TAU - angles[angles.size() - 1]
	var cut := angles[angles.size() - 1] + widest * 0.5
	for i in range(1, angles.size()):
		var gap := angles[i] - angles[i - 1]
		if gap > widest:
			widest = gap
			cut = angles[i - 1] + gap * 0.5
	# Every gap can still be bridged by a triangle (a body that goes all the way round).
	for t in kept:
		var lo := INF
		var hi := -INF
		for c in 3:
			var d := positions[indices[t * 3 + c]] - origin
			var p := Vector2(d.dot(frame.x), d.dot(frame.y))
			if p.length() >= AXIS_EPSILON:
				var angle := fposmod(atan2(p.y, p.x) - cut, TAU)
				lo = minf(lo, angle)
				hi = maxf(hi, angle)
		if hi - lo > PI + WRAP_SLACK:
			return NAN
	return cut


## The angle (in a round projection's frame) of a seam in these triangles: two vertices at the
## same place away from the axis, as periodic faces have where their u wraps. NAN when none.
static func seam_angle(tris: PackedInt32Array, indices: PackedInt32Array, positions: PackedVector3Array, origin: Vector3, axis: Vector3) -> float:
	var frame := SKETCH_DATA.face_plane(origin, axis)
	var seen := {}
	for t in tris:
		for c in 3:
			var v := indices[t * 3 + c]
			var p := positions[v]
			var other: int = seen.get(p, -1)
			if other < 0:
				seen[p] = v
				continue
			if other == v:
				continue
			var d := p - origin
			var px := d.dot(frame.x)
			var py := d.dot(frame.y)
			if Vector2(px, py).length() >= AXIS_EPSILON:
				return atan2(py, px)
	return NAN


## Meters to texture repeats: rotate, scale, offset.
static func _finish(out: PackedVector2Array, m: Dictionary) -> PackedVector2Array:
	var scale: Vector2 = m.scale
	scale.x = scale.x if absf(scale.x) > 1e-9 else 1e-9
	scale.y = scale.y if absf(scale.y) > 1e-9 else 1e-9
	var rotation := float(m.rotation)
	var offset: Vector2 = m.offset
	for k in out.size():
		out[k] = out[k].rotated(rotation) / scale + offset
	return out


# --- Baking --------------------------------------------------------------------------------------

## A body's mesh with one surface per appearance: {"mesh": ArrayMesh, "materials": Array (one
## Material per surface, also set on the mesh), "ids": PackedStringArray (appearance id per
## surface, "" for the default), "face_surfaces": PackedInt32Array (surface per face, -1 for faces
## without triangles), "notes": PackedStringArray (a mesh body's face group appearances that moved
## to another name or are not shown)}. Faces with no appearance use default_material (the first
## surface).
## Vertices are shared within a surface and split only where faces in different surfaces meet or
## the texture wraps.
## A body seen from both sides (two_sided: a surface) gets surface_material where it has no
## appearance (a double-sided default_material when null); its appearances stay the very
## materials (a Material file keeps its link), with the back side added to their surfaces as
## reversed triangles where they don't draw it themselves.
static func build_mesh(doc: Resource, body_id: String, shape: RefCounted, tess: Dictionary, default_material: Material, surface_material: Material = null) -> Dictionary:
	var mesh := ArrayMesh.new()
	var result := {"mesh": mesh, "materials": [], "ids": PackedStringArray(), "face_surfaces": PackedInt32Array(), "notes": PackedStringArray()}
	var indices: PackedInt32Array = tess.get("indices", PackedInt32Array())
	var face_ids: PackedInt32Array = tess.get("face_ids", PackedInt32Array())
	if indices.is_empty():
		return result
	var positions: PackedVector3Array = tess.positions
	var normals: PackedVector3Array = tess.normals
	var face_count: int = shape.face_count() if shape != null else 0
	var is_surface: bool = shape != null and shape.has_method("is_surface") and two_sided(shape)
	if MESH_BODY.is_mesh(shape) and _plain(doc, body_id):
		return _plain_mesh(result, tess, face_count, default_material, surface_material, is_surface)
	for f in face_ids:
		face_count = maxi(face_count, f + 1)

	# Triangles grouped by face: face f owns order[start[f] .. start[f + 1]).
	var start := PackedInt32Array()
	start.resize(face_count + 1)
	for f in face_ids:
		start[f + 1] += 1
	for f in face_count:
		start[f + 1] += start[f]
	var fill := start.duplicate()
	var order := PackedInt32Array()
	order.resize(face_ids.size())
	for t in face_ids.size():
		order[fill[face_ids[t]]] = t
		fill[face_ids[t]] += 1

	# What each face shows.
	var names: PackedStringArray = shape.get_face_names() if shape != null else PackedStringArray()
	var face_entries := _face_entries(doc, body_id)
	if MESH_BODY.is_mesh(shape) and not face_entries.is_empty():
		var notes := PackedStringArray()
		face_entries = _anchored(face_entries, shape, MESH_BODY.body_name(doc, body_id), notes)
		result.notes = notes
	var body_level := _body_level(doc, body_id)
	var looks: Array[Dictionary] = []
	var needs_default := false
	for f in face_count:
		var face_name := str(names[f]) if f < names.size() else ""
		var look := _face_look(face_entries, face_name, body_level)
		looks.append(look)
		needs_default = needs_default or (look.material == "" and start[f + 1] > start[f])
	var ids := PackedStringArray()
	if needs_default:
		ids.append("")
	var face_surfaces := PackedInt32Array()
	face_surfaces.resize(face_count)
	for f in face_count:
		if start[f + 1] == start[f]:
			face_surfaces[f] = -1
			continue
		var id := str(looks[f].material)
		if not ids.has(id):
			ids.append(id)
		face_surfaces[f] = ids.find(id)

	# Round projections wrap at one place per mapping: nowhere on the body when its faces don't go
	# all the way round (a cut no triangle crosses), else a seam the body already has (found per
	# face: different faces meet at shared positions too).
	var groups := {}
	for f in face_count:
		var mapping: Dictionary = looks[f].mapping
		var type := str(mapping.type)
		if face_surfaces[f] < 0 or (type != "cylindrical" and type != "spherical"):
			continue
		var key := str(mapping)
		if not groups.has(key):
			groups[key] = {"mapping": mapping, "tris": PackedInt32Array(), "seam": NAN}
		var group: Dictionary = groups[key]
		var tris := order.slice(start[f], start[f + 1])
		var all: PackedInt32Array = group.tris
		all.append_array(tris)
		group.tris = all
		if is_nan(float(group.seam)):
			group.seam = seam_angle(tris, indices, positions, mapping.origin, _round_axis(mapping))
	var cuts := {}
	for key in groups:
		var group: Dictionary = groups[key]
		var cut := free_cut(group.tris, indices, positions, normals, group.mapping)
		cuts[key] = cut if not is_nan(cut) else float(group.seam)

	for s in ids.size():
		var material: Material = MATERIAL_LIBRARY.material(ids[s]) if ids[s] != "" else null
		var back := is_surface and material != null and not draws_both_sides(material)
		if is_surface and material == null:
			material = surface_material if surface_material != null else double_sided(default_material)
		if material == null:
			material = default_material
		var out_positions := PackedVector3Array()
		var out_normals := PackedVector3Array()
		var out_uvs := PackedVector2Array()
		var out_indices := PackedInt32Array()
		var remap := {}
		for f in face_count:
			if face_surfaces[f] != s:
				continue
			var tris := order.slice(start[f], start[f + 1])
			var mapping: Dictionary = looks[f].mapping
			var cut := float(cuts.get(str(mapping), NAN))
			var corners := face_corner_uvs(shape, f, tess, tris, mapping, 0.0 if is_nan(cut) else cut)
			for k in tris.size():
				for j in 3:
					var v := indices[tris[k] * 3 + j]
					var uv := corners[k * 3 + j]
					var key := Vector3(v, uv.x, uv.y)
					var index: int = remap.get(key, -1)
					if index < 0:
						index = out_positions.size()
						remap[key] = index
						out_positions.append(positions[v])
						out_normals.append(normals[v])
						out_uvs.append(uv)
					out_indices.append(index)
		if back:
			# The back side: the same triangles turned over (normals flipped, winding reversed).
			var count := out_positions.size()
			for i in count:
				out_positions.append(out_positions[i])
				out_normals.append(-out_normals[i])
				out_uvs.append(out_uvs[i])
			for t in range(0, out_indices.size(), 3):
				out_indices.append_array([out_indices[t] + count, out_indices[t + 2] + count, out_indices[t + 1] + count])
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = out_positions
		arrays[Mesh.ARRAY_NORMAL] = out_normals
		arrays[Mesh.ARRAY_TEX_UV] = out_uvs
		arrays[Mesh.ARRAY_INDEX] = out_indices
		# Tangents, so normal maps shade the right way.
		var tool := SurfaceTool.new()
		tool.create_from_arrays(arrays)
		tool.generate_tangents()
		tool.commit(mesh)
		if material != null:
			mesh.surface_set_material(s, material)
		(result.materials as Array).append(material)
	result.ids = ids
	result.face_surfaces = face_surfaces
	return result


## True when nothing gives a body an appearance: no face (or group) entry, no body entry, no
## component entry.
static func _plain(doc: Resource, body_id: String) -> bool:
	return _face_entries(doc, body_id).is_empty() and str(_body_level(doc, body_id).material) == ""


## build_mesh() for a mesh body without appearances: one surface straight from the display mesh
## (its own box-projection uvs at the default scale), with no pass over every corner here: a mesh
## body can hold millions of triangles.
static func _plain_mesh(result: Dictionary, tess: Dictionary, face_count: int, default_material: Material, surface_material: Material, is_surface: bool) -> Dictionary:
	var material: Material = default_material
	if is_surface:
		material = surface_material if surface_material != null else double_sided(default_material)
	var uvs: PackedVector2Array = tess.get("uvs", PackedVector2Array())
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = tess.positions
	arrays[Mesh.ARRAY_NORMAL] = tess.normals
	if uvs.size() == (tess.positions as PackedVector3Array).size():
		var scale: Vector2 = DEFAULT_MAPPING.scale
		arrays[Mesh.ARRAY_TEX_UV] = Transform2D(0.0, Vector2(1.0 / scale.x, 1.0 / scale.y), 0.0, Vector2.ZERO) * uvs
	arrays[Mesh.ARRAY_INDEX] = tess.indices
	# Tangents, so normal maps shade the right way.
	var tool := SurfaceTool.new()
	tool.create_from_arrays(arrays)
	if arrays[Mesh.ARRAY_TEX_UV] != null:
		tool.generate_tangents()
	tool.commit(result.mesh)
	if material != null:
		(result.mesh as ArrayMesh).surface_set_material(0, material)
	(result.materials as Array).append(material)
	result.ids = PackedStringArray([""])
	var face_surfaces := PackedInt32Array()
	face_surfaces.resize(face_count)
	face_surfaces.fill(-1)
	for f in tess.get("face_ids", PackedInt32Array()):
		if f >= 0 and f < face_count:
			face_surfaces[f] = 0
	result.face_surfaces = face_surfaces
	return result


## True for a body seen from both sides: a surface (open shells and loose faces), or a body with
## open faces beside its solids. It renders (and collides) two-sided. A mesh body: when it isn't
## closed.
static func two_sided(shape: RefCounted) -> bool:
	if MESH_BODY.is_mesh(shape):
		return not shape.is_null() and MESH_BODY.shape_kind(shape) != "solid"
	return shape != null and not shape.is_null() and shape.face_count() > 0 and INSPECT.shape_kind(shape) != "solid"


## True when material draws back faces itself (culling off).
static func draws_both_sides(material: Material) -> bool:
	if material is BaseMaterial3D:
		return (material as BaseMaterial3D).cull_mode == BaseMaterial3D.CULL_DISABLED
	var shader: Shader = (material as ShaderMaterial).shader if material is ShaderMaterial else null
	return shader != null and shader.code.contains("cull_disabled")


## A copy of material drawn from both sides (surfaces are seen from behind too). Shader materials
## can't be changed that way and come back as they are.
static func double_sided(material: Material) -> Material:
	var base := material as BaseMaterial3D
	if base == null or base.cull_mode == BaseMaterial3D.CULL_DISABLED:
		return material
	var copy: BaseMaterial3D = base.duplicate()
	copy.cull_mode = BaseMaterial3D.CULL_DISABLED
	return copy


# --- Decals --------------------------------------------------------------------------------------

## Where a decal (a doc.decals entry) sits in its body's coordinates. A Godot Decal projects
## along its -Y, with the image's top toward -Z: so Y is the face normal and -Z the decal's up,
## turned by its rotation about the normal. Without an "up" the image stands upright the way
## textures do (_upright_plane): its top up the world on walls, toward -Z on tops. A negative size
## (Flip) mirrors the image on that axis through this basis (its determinant goes negative): Godot
## clamps a negative Decal size to 0.001, so decal_size stays positive.
static func decal_transform(info: Dictionary) -> Transform3D:
	var normal: Vector3 = info.get("normal", Vector3.UP)
	normal = normal.normalized() if normal.length() > 1e-9 else Vector3.UP
	var up: Vector3 = info.get("up", Vector3.ZERO)
	up -= normal * up.dot(normal)
	if up.length() < 1e-6:
		up = _upright_plane(Vector3.ZERO, normal).y
	up = up.normalized()
	var z := -up
	var x := normal.cross(z)
	var size: Vector2 = info.get("size", Vector2.ONE)
	if size.x < 0.0:
		x = -x
	if size.y < 0.0:
		z = -z
	var basis := Basis(normal, float(info.get("rotation", 0.0))) * Basis(x, normal, z)
	var position: Vector3 = info.get("position", Vector3.ZERO)
	return Transform3D(basis, position)


## A decal entry as it sits on its body now: a copy of info moved onto the face it was put on
## ("face"), so the decal follows that face through parametric edits (a taller box keeps its logo
## on top) instead of staying where the face used to be. The face is found by its name, else as
## the nearest of the pieces a later feature split it into ("<name>#k"), else as the nearest face
## facing the same way (within half the body's size, as lost references are repaired). The
## position moves to the closest point on that face and the normal becomes the face's there.
## Adds "repaired": true when the name was lost, and "lost": true (keeping the stored place) when
## no face is found. Entries without a face, and calls without a shape or kernel (a game has no
## kernel), keep their stored place.
## A decal on a mesh body is refused: it stays at its stored place with "lost": true and "error":
## the sentence of decal_gate().
static func placed_decal(info: Dictionary, shape: RefCounted, kernel: RefCounted) -> Dictionary:
	var placed := info.duplicate()
	var face_name := str(info.get("face", ""))
	var gate := decal_gate(shape)
	if gate != "":
		placed["lost"] = true
		placed["error"] = gate
		return placed
	if face_name == "" or shape == null or kernel == null:
		return placed
	var position: Vector3 = info.get("position", Vector3.ZERO)
	var point: RefCounted = kernel.make_vertex(position)
	var index: int = shape.find_face(face_name)
	var near := {}
	if index >= 0:
		near = kernel.closest_points(shape.face_shape(index), point)
	else:
		var names: PackedStringArray = shape.get_face_names()
		var candidates := PackedInt32Array()
		for f in names.size():
			if face_name_chain(str(names[f])).has(face_name):
				candidates.append(f)
		var split := not candidates.is_empty()
		if not split:
			for f in names.size():
				candidates.append(f)
		var normal: Vector3 = info.get("normal", Vector3.UP)
		normal = normal.normalized()
		var size: float = (shape.bbox() as AABB).size.length()
		var best_score := INF
		for f in candidates:
			var hit: Dictionary = kernel.closest_points(shape.face_shape(f), point)
			if not hit.has("a"):
				continue
			var score := float(hit.distance)
			if not split:
				score += (1.0 - (shape.face_normal_at(f, hit.a) as Vector3).dot(normal)) * size
			if score < best_score:
				best_score = score
				index = f
				near = hit
		if index < 0 or (not split and best_score > size * 0.5):
			placed["lost"] = true
			return placed
		placed["repaired"] = true
	if not near.has("a"):
		placed["lost"] = true
		return placed
	placed["position"] = near.a
	placed["normal"] = shape.face_normal_at(index, near.a)
	return placed


## Why a body can't take a decal ("" when it can): a mesh body has no B-rep face to sit on.
static func decal_gate(shape: RefCounted) -> String:
	return MESH_BODY.DECAL_GATE if MESH_BODY.is_mesh(shape) else ""


## A Godot Decal's size for a decal: (width, projection depth, height). The depth is the
## entry's "depth" when it has one, else half the larger side (enough to wrap a curved face).
static func decal_size(info: Dictionary) -> Vector3:
	var size: Vector2 = info.get("size", Vector2(0.05, 0.05))
	var depth := float(info.get("depth", 0.0))
	if depth <= 0.0:
		depth = maxf(absf(size.x), absf(size.y)) * 0.5
	return Vector3(absf(size.x), maxf(depth, 1e-4), absf(size.y))
