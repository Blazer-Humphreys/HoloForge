@tool
extends RefCounted
## Picking against tessellated bodies: a ray finds faces; edges and vertices are found by their
## distance on screen. Pickable bodies are dictionaries {"id", "tess", "aabb"} made by prepare().
##
## A pick is {"kind": "body"|"face"|"edge"|"vertex", "body": id, "index": int, "point": Vector3}.
## project: Callable(Vector3) -> Vector2 screen position (Vector2(INF, INF) when behind the camera).
## visible: Callable(Vector3) -> bool, false when something hides the point.
## A pickable body may carry "clip": {"origin", "normal"} while a Section analysis shows it: the
## half on the normal's side is cut away (not drawn), so nothing there can be picked or hovered.
##
## Mesh bodies (core/mesh/mesh_body.gd; their tessellation carries "cad_mesh": the CadMesh) are picked
## through the mesh itself (CadMesh.ray_hit), not triangle by triangle here. Their picks are
##   {"kind": "mesh_group", "body", "index": group id, "group": its name, "triangle", "point", "normal"}
##   {"kind": "mesh_triangle", "body", "index": triangle, "triangle", "group", "point", "normal"}
## ("mesh_triangle" when filters.mesh_triangle is true), or a "body" pick. They take the "face"
## place in the priority order, and a filter set without "mesh_group" follows its "face" filter.
## Mesh bodies have no edges or vertices to pick, and a region selects them only as bodies (the
## Mesh workspace selects their triangles itself, with CadMesh.triangles_in_frustum).
##
## Posed bodies (an assembly moves them, spec C7.3): a pickable body may carry "pose", the rigid
## Transform3D it is shown at, and "pose_inverse" (set_pose()). Rays are taken into the body's
## modelled space by the inverse before testing, and points are projected and checked for
## visibility where they are shown. Picks keep modelled "point" (and "normal"), so stored refs stay
## valid; a pick on a posed body also carries "world_point" (and "world_normal" for faces and mesh
## picks). A body without "pose" is picked exactly as before (no world keys).

const MESH_BODY := preload("res://addons/holo_forge/core/mesh/mesh_body.gd")

## The key under which a mesh body's tessellation and pickable body carry the CadMesh.
const MESH_KEY := "cad_mesh"
const MESH_GROUP := "mesh_group"
const MESH_TRIANGLE := "mesh_triangle"
## A ray that hits a section's cut-away half goes on from the hit at most this many times.
const CLIP_STEPS := 64
## A region tests at most this many of a mesh body's vertices.
const REGION_SAMPLES := 4096
const KINDS := ["vertex", "edge", "face", "body"]
## Which kind wins when several are under the cursor, per selection priority.
const PRIORITY_ORDER := {
	"default": ["vertex", "edge", "face", "body"],
	"body": ["body", "face", "edge", "vertex"],
	"face": ["face", "edge", "vertex", "body"],
	"edge": ["edge", "vertex", "face", "body"],
}


## Builds the lookup tables picking needs from a tessellation. A mesh body (shape, or the mesh
## its tessellation carries) needs none: it keeps "cad_mesh", the CadMesh that answers rays.
static func prepare(body_id: String, tess: Dictionary, shape: RefCounted = null) -> Dictionary:
	var mesh: Variant = shape if MESH_BODY.is_mesh(shape) else tess.get(MESH_KEY)
	if MESH_BODY.is_mesh(mesh):
		return {"id": body_id, "tess": tess, "aabb": (mesh.bbox() as AABB).grow(0.0001), "face_vertices": {}, MESH_KEY: mesh}
	var positions: PackedVector3Array = tess.get("positions", PackedVector3Array())
	var aabb := AABB()
	if not positions.is_empty():
		aabb = AABB(positions[0], Vector3.ZERO)
		for p in positions:
			aabb = aabb.expand(p)
	var face_vertices := {}
	var face_ids: PackedInt32Array = tess.get("face_ids", PackedInt32Array())
	var indices: PackedInt32Array = tess.get("indices", PackedInt32Array())
	for t in face_ids.size():
		var vertex_set: Dictionary = face_vertices.get(face_ids[t], {})
		for k in 3:
			vertex_set[indices[t * 3 + k]] = true
		face_vertices[face_ids[t]] = vertex_set
	return {"id": body_id, "tess": tess, "aabb": aabb.grow(0.0001), "face_vertices": face_vertices}


## Gives a pickable body the pose it is shown at (a rigid Transform3D); identity takes it away,
## so the body is picked as modelled.
static func set_pose(body: Dictionary, pose: Transform3D) -> void:
	if pose == Transform3D.IDENTITY:
		body.erase("pose")
		body.erase("pose_inverse")
	else:
		body["pose"] = pose
		body["pose_inverse"] = pose.affine_inverse()


## project for one body: its modelled points are projected where the body is shown.
static func _body_project(body: Dictionary, project: Callable) -> Callable:
	if not body.has("pose"):
		return project
	var pose: Transform3D = body.pose
	return func(p: Vector3) -> Vector2: return project.call(pose * p)


## visible for one body, taking modelled points.
static func _body_visible(body: Dictionary, visible: Callable) -> Callable:
	if not body.has("pose"):
		return visible
	var pose: Transform3D = body.pose
	return func(p: Vector3) -> bool: return visible.call(pose * p)


## Adds "world_point" (and "world_normal" when normal is given) to a pick on a posed body.
static func _add_world(pick: Dictionary, body: Dictionary, normal: Variant = null) -> Dictionary:
	if body.has("pose") and pick.has("point"):
		var pose: Transform3D = body.pose
		pick["world_point"] = pose * (pick.point as Vector3)
		if normal is Vector3:
			pick["world_normal"] = (pose.basis * (normal as Vector3)).normalized()
	return pick


## True when point lies in the half a body's section clip cuts away (as section_clip.gdshader).
static func clipped(body: Dictionary, point: Vector3) -> bool:
	var clip: Dictionary = body.get("clip", {})
	return not clip.is_empty() and (point - (clip.origin as Vector3)).dot(clip.normal as Vector3) > 0.0


static func key(pick: Dictionary) -> String:
	return "%s:%s:%d" % [pick.kind, pick.body, int(pick.get("index", -1))]


static func from_key(text: String) -> Dictionary:
	var parts := text.split(":")
	if parts.size() != 3:
		return {}
	return {"kind": parts[0], "body": parts[1], "index": parts[2].to_int()}


## The nearest face under a ray: {"body", "face", "point", "distance"} or {}. "point" is in the
## body's modelled space; on a posed body the hit also has "world_point" and "world_normal" (the
## distance is the same in both: a pose is rigid).
static func ray_hit(bodies: Array, from: Vector3, dir: Vector3) -> Dictionary:
	var best := {}
	var best_distance := INF
	for body in bodies:
		# A posed body is tested in its modelled space.
		var posed: bool = body.has("pose")
		var local_from := from
		var local_dir := dir
		if posed:
			var inverse: Transform3D = body.pose_inverse
			local_from = inverse * from
			local_dir = inverse.basis * dir
		if (body.aabb as AABB).intersects_ray(local_from, local_dir) == null:
			continue
		if body.has(MESH_KEY):
			var found := _mesh_ray_hit(body, local_from, local_dir)
			if not found.is_empty() and float(found.distance) < best_distance:
				best_distance = found.distance
				best = _add_world(found, body, found.get("normal"))
			continue
		var tess: Dictionary = body.tess
		var positions: PackedVector3Array = tess.get("positions", PackedVector3Array())
		var indices: PackedInt32Array = tess.get("indices", PackedInt32Array())
		var face_ids: PackedInt32Array = tess.get("face_ids", PackedInt32Array())
		var best_triangle := -1
		for t in face_ids.size():
			var hit = Geometry3D.ray_intersects_triangle(local_from, local_dir, positions[indices[t * 3]], positions[indices[t * 3 + 1]], positions[indices[t * 3 + 2]])
			if hit == null:
				continue
			# A hit in the cut-away half isn't drawn: the next hit along the ray wins.
			if clipped(body, hit):
				continue
			var d := local_from.distance_to(hit)
			if d < best_distance:
				best_distance = d
				best = {"body": body.id, "face": face_ids[t], "point": hit, "distance": d}
				best_triangle = t if posed else -1
		if best_triangle >= 0:
			# (The triangle's own normal: as the view's face_normal() works it out.)
			var a := positions[indices[best_triangle * 3]]
			var normal := (positions[indices[best_triangle * 3 + 2]] - a).cross(positions[indices[best_triangle * 3 + 1]] - a).normalized()
			_add_world(best, body, normal)
	return best


## ray_hit() for a mesh body: {"body", "face" (the group id), "point", "distance", "triangle",
## "normal", "mesh": true} or {}. A hit in a section's cut-away half isn't drawn: the ray goes on
## from it.
static func _mesh_ray_hit(body: Dictionary, from: Vector3, dir: Vector3) -> Dictionary:
	var mesh: RefCounted = body[MESH_KEY]
	var direction := dir.normalized()
	var origin := from
	var travelled := 0.0
	var step := maxf((body.aabb as AABB).size.length() * 1e-6, 1e-9)
	for i in CLIP_STEPS:
		var hit: Dictionary = mesh.ray_hit(origin, direction)
		if not bool(hit.get("hit", false)):
			return {}
		var point: Vector3 = hit.point
		if not clipped(body, point):
			return {
				"body": body.id, "face": int(hit.group), "point": point, "distance": travelled + float(hit.distance),
				"triangle": int(hit.triangle), "normal": hit.normal, "mesh": true,
			}
		travelled += float(hit.distance) + step
		origin = point + direction * step
	return {}


## The edge nearest the mouse on screen within max_px: {"body", "edge", "point", "pixels"} or {}.
## Mesh bodies have no edges to pick (their lines are group borders and open edges).
static func nearest_edge(bodies: Array, project: Callable, mouse: Vector2, max_px: float, visible: Callable) -> Dictionary:
	var best := {}
	var best_px := max_px
	for body in bodies:
		if body.has(MESH_KEY):
			continue
		var shown_at := _body_project(body, project)
		var shown := _body_visible(body, visible)
		var points: PackedVector3Array = body.tess.get("edge_points", PackedVector3Array())
		var ids: PackedInt32Array = body.tess.get("edge_ids", PackedInt32Array())
		for s in ids.size():
			var a3 := points[s * 2]
			var b3 := points[s * 2 + 1]
			var a: Vector2 = shown_at.call(a3)
			var b: Vector2 = shown_at.call(b3)
			if not (a.is_finite() and b.is_finite()):
				continue
			var closest := Geometry2D.get_closest_point_to_segment(mouse, a, b)
			var px := closest.distance_to(mouse)
			if px >= best_px:
				continue
			var t := 0.0 if a.is_equal_approx(b) else clampf((closest - a).length() / (b - a).length(), 0.0, 1.0)
			var point := a3.lerp(b3, t)
			if clipped(body, point) or not shown.call(point):
				continue
			best_px = px
			best = _add_world({"body": body.id, "edge": ids[s], "point": point, "pixels": px}, body)
	return best


## The vertex nearest the mouse on screen within max_px: {"body", "vertex", "point", "pixels"} or {}.
static func nearest_vertex(bodies: Array, project: Callable, mouse: Vector2, max_px: float, visible: Callable) -> Dictionary:
	var best := {}
	var best_px := max_px
	for body in bodies:
		if body.has(MESH_KEY):
			continue
		var shown_at := _body_project(body, project)
		var shown := _body_visible(body, visible)
		var vertices: PackedVector3Array = body.tess.get("vertices", PackedVector3Array())
		for i in vertices.size():
			if clipped(body, vertices[i]):
				continue
			var p: Vector2 = shown_at.call(vertices[i])
			if not p.is_finite():
				continue
			var px := p.distance_to(mouse)
			if px < best_px and shown.call(vertices[i]):
				best_px = px
				best = _add_world({"body": body.id, "vertex": i, "point": vertices[i], "pixels": px}, body)
	return best


## The single item under the mouse, honoring the selection filters and priority.
## filters: {"body": bool, "face": bool, "edge": bool, "vertex": bool}.
static func pick(bodies: Array, from: Vector3, dir: Vector3, project: Callable, mouse: Vector2,
		filters: Dictionary, priority: String, radius_px: float, visible: Callable) -> Dictionary:
	var found := {}
	var face := ray_hit(bodies, from, dir)
	if not face.is_empty():
		found["face"] = _with_world({"kind": "face", "body": face.body, "index": face.face, "point": face.point}, face)
		found["body"] = _with_world({"kind": "body", "body": face.body, "index": -1, "point": face.point}, face)
		if face.get("mesh", false):
			found["face"] = _with_world(_mesh_pick(bodies, face, bool(filters.get(MESH_TRIANGLE, false))), face)
	if filters.get("edge", true):
		var edge := nearest_edge(bodies, project, mouse, radius_px, visible)
		if not edge.is_empty():
			found["edge"] = _with_world({"kind": "edge", "body": edge.body, "index": edge.edge, "point": edge.point}, edge)
	if filters.get("vertex", true):
		var vertex := nearest_vertex(bodies, project, mouse, radius_px, visible)
		if not vertex.is_empty():
			found["vertex"] = _with_world({"kind": "vertex", "body": vertex.body, "index": vertex.vertex, "point": vertex.point}, vertex)
	for kind in PRIORITY_ORDER.get(priority, PRIORITY_ORDER.default):
		if not found.has(kind):
			continue
		# A mesh pick sits in the face place; a filter set that doesn't name it follows "face".
		var actual := str(found[kind].kind)
		if filters.get(actual, filters.get(kind, true)):
			return found[kind]
	return {}


## pick with the world keys of the hit it came from (a posed body's), if it has them.
static func _with_world(pick: Dictionary, hit: Dictionary) -> Dictionary:
	for key in ["world_point", "world_normal"]:
		if hit.has(key):
			pick[key] = hit[key]
	return pick


## The pick for a ray hit on a mesh body: its face group, or (triangles) the triangle itself.
static func _mesh_pick(bodies: Array, hit: Dictionary, triangles: bool) -> Dictionary:
	var group := int(hit.face)
	var name := ""
	for body in bodies:
		if body.id == hit.body and body.has(MESH_KEY):
			var names: PackedStringArray = body[MESH_KEY].get_face_names()
			name = str(names[group]) if group >= 0 and group < names.size() else ""
			break
	return {
		"kind": MESH_TRIANGLE if triangles else MESH_GROUP, "body": hit.body, "index": int(hit.triangle) if triangles else group,
		"group": name, "triangle": int(hit.triangle), "point": hit.point, "normal": hit.normal,
	}


## Items inside a screen rectangle. A left-to-right drag (crossing = false) takes items wholly
## inside; right-to-left (crossing = true) takes anything that reaches into it.
static func window_select(bodies: Array, project: Callable, rect: Rect2, crossing: bool, kind: String, visible: Callable) -> Array[Dictionary]:
	return _region_select(bodies, project, func(p: Vector2) -> bool: return rect.has_point(p), crossing, kind, visible)


## Items inside a freeform (lasso) outline; like a window, crossing takes partial items.
static func lasso_select(bodies: Array, project: Callable, outline: PackedVector2Array, crossing: bool, kind: String, visible: Callable) -> Array[Dictionary]:
	if outline.size() < 3:
		return []
	return _region_select(bodies, project, func(p: Vector2) -> bool: return Geometry2D.is_point_in_polygon(p, outline), crossing, kind, visible)


static func _region_select(bodies: Array, all_project: Callable, inside: Callable, crossing: bool, kind: String, all_visible: Callable) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for body in bodies:
		var tess: Dictionary = body.tess
		var positions: PackedVector3Array = tess.get("positions", PackedVector3Array())
		# A posed body's modelled points are projected and checked where it is shown.
		var project := _body_project(body, all_project)
		var visible := _body_visible(body, all_visible)
		var first := result.size()
		# Points in a section's cut-away half count as not shown.
		var shown := func(p: Vector3) -> bool: return not clipped(body, p) and visible.call(p)
		if body.has(MESH_KEY):
			if kind == "body" and _mesh_in_region(body, positions, project, inside, crossing, shown):
				result.append(_add_world({"kind": "body", "body": body.id, "index": -1, "point": (body.aabb as AABB).get_center()}, body))
			continue
		match kind:
			"body", "face":
				var any_body := false
				var all_body := true
				for face_id in body.face_vertices:
					var verts: Array = (body.face_vertices[face_id] as Dictionary).keys()
					var counts := _count_inside(verts.map(func(i: int) -> Vector3: return positions[i]), project, inside, shown)
					var face_hit: bool = (counts.inside > 0 if crossing else counts.inside == counts.total) and counts.visible > 0
					any_body = any_body or counts.inside > 0
					all_body = all_body and counts.inside == counts.total
					if kind == "face" and face_hit:
						result.append({"kind": "face", "body": body.id, "index": face_id, "point": positions[verts[0]]})
				if kind == "body" and (any_body if crossing else all_body) and not body.face_vertices.is_empty():
					result.append({"kind": "body", "body": body.id, "index": -1, "point": (body.aabb as AABB).get_center()})
			"edge":
				var points: PackedVector3Array = tess.get("edge_points", PackedVector3Array())
				var ids: PackedInt32Array = tess.get("edge_ids", PackedInt32Array())
				var per_edge := {}
				for s in ids.size():
					var list: Array = per_edge.get(ids[s], [])
					list.append(points[s * 2])
					list.append(points[s * 2 + 1])
					per_edge[ids[s]] = list
				for edge_id in per_edge:
					var counts := _count_inside(per_edge[edge_id], project, inside, shown)
					if (counts.inside > 0 if crossing else counts.inside == counts.total) and counts.visible > 0:
						result.append({"kind": "edge", "body": body.id, "index": edge_id, "point": per_edge[edge_id][0]})
			"vertex":
				var vertices: PackedVector3Array = tess.get("vertices", PackedVector3Array())
				for i in vertices.size():
					var p: Vector2 = project.call(vertices[i])
					if p.is_finite() and inside.call(p) and shown.call(vertices[i]):
						result.append({"kind": "vertex", "body": body.id, "index": i, "point": vertices[i]})
		for i in range(first, result.size()):
			_add_world(result[i], body)
	return result


## True when a region takes a mesh body: wholly inside (every corner of its bounds is; crossing:
## any of its vertices is, at most REGION_SAMPLES of them, evenly spread), with something showing.
static func _mesh_in_region(body: Dictionary, positions: PackedVector3Array, project: Callable, inside: Callable, crossing: bool, shown: Callable) -> bool:
	if positions.is_empty():
		return false
	var stride := maxi(1, int(ceil(float(positions.size()) / REGION_SAMPLES)))
	var samples := []
	for i in range(0, positions.size(), stride):
		samples.append(positions[i])
	var counts := _count_inside(samples, project, inside, shown)
	if counts.visible == 0:
		return false
	if crossing:
		return counts.inside > 0
	var box: AABB = body.aabb
	for i in 8:
		var p: Vector2 = project.call(box.get_endpoint(i))
		if not (p.is_finite() and inside.call(p)):
			return false
	return true


static func _count_inside(points: Array, project: Callable, inside: Callable, visible: Callable) -> Dictionary:
	var counts := {"inside": 0, "total": points.size(), "visible": 0}
	for point in points:
		var p: Vector2 = project.call(point)
		if p.is_finite() and inside.call(p):
			counts.inside += 1
			if visible.call(point):
				counts.visible += 1
	return counts
