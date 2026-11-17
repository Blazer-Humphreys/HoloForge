@tool
extends RefCounted
## Meshes and materials of the Form environment (owned by ui/form_editor.gd, shown through the
## view's set_form_meshes). Box mode draws the cage polygons flat; Control Frame the smooth surface
## with the cage lines and points around it; Smooth the surface with its limit edge curves. Lines
## come in two passes: depth-tested and a faint one drawn through everything. Selected and hovered
## faces, frozen and isolated faces and symmetry planes are translucent overlays. Every colour is a
## forge_theme.gd form_* token; apply_theme recolours the shared materials in place.

const CAGE := preload("res://addons/holo_forge/core/form/cage.gd")
const SURFACE_BODY_SHADER := preload("res://addons/holo_forge/render/surface_body.gdshader")
const FORGE_THEME := preload("res://addons/holo_forge/ui/forge_theme.gd")

var colors := FORGE_THEME.palette("dark")
var materials := {}


func _init() -> void:
	_make_materials()
	apply_theme(colors)


## Recolours every material from a palette (forge_theme.gd).
func apply_theme(palette: Dictionary) -> void:
	colors = palette.duplicate(true)
	var c := colors
	(materials.surface as StandardMaterial3D).albedo_color = c.form_surface
	(materials.box as StandardMaterial3D).albedo_color = c.form_box_face
	(materials.box_open as StandardMaterial3D).albedo_color = c.form_box_face
	var open: ShaderMaterial = materials.surface_open
	open.set_shader_parameter("front_color", c.form_surface)
	open.set_shader_parameter("back_color", c.surface_back)
	(materials.line as StandardMaterial3D).albedo_color = c.form_cage_line
	(materials.limit_line as StandardMaterial3D).albedo_color = c.form_cage_line
	(materials.hidden_line as StandardMaterial3D).albedo_color = c.form_cage_hidden
	(materials.points as StandardMaterial3D).albedo_color = c.form_point
	(materials.select_face as StandardMaterial3D).albedo_color = c.form_select_face
	(materials.hover_face as StandardMaterial3D).albedo_color = c.form_hover_face
	(materials.symmetry_plane as StandardMaterial3D).albedo_color = c.form_symmetry_plane
	(materials.symmetry_axis as StandardMaterial3D).albedo_color = Color(c.form_symmetry_line, 0.75)
	(materials.isolated_face as StandardMaterial3D).albedo_color = c.form_isolated
	(materials.frozen_face as StandardMaterial3D).albedo_color = Color(c.form_frozen, 0.28)
	(materials.warning_face as StandardMaterial3D).albedo_color = Color(c.form_warning, 0.3)


## The colour of a soft-modification weight (0 = the surface, 1 = full influence).
func soft_color(weight: float, base: Color) -> Color:
	return base.lerp(colors.form_soft_high, clampf(weight, 0.0, 1.0))


func _make_materials() -> void:
	var surface := StandardMaterial3D.new()
	surface.roughness = 0.55
	surface.metallic = 0.05
	materials.surface = surface
	var soft := StandardMaterial3D.new()
	soft.roughness = 0.55
	soft.metallic = 0.05
	soft.vertex_color_use_as_albedo = true
	# The colours are sRGB theme tokens: a zero weight must look exactly like form_surface.
	soft.vertex_color_is_srgb = true
	materials.surface_soft = soft
	var soft_open: StandardMaterial3D = soft.duplicate()
	soft_open.cull_mode = BaseMaterial3D.CULL_DISABLED
	materials.surface_soft_open = soft_open
	var open := ShaderMaterial.new()
	open.shader = SURFACE_BODY_SHADER
	materials.surface_open = open
	var box := StandardMaterial3D.new()
	box.roughness = 0.55
	box.metallic = 0.05
	materials.box = box
	var box_open: StandardMaterial3D = box.duplicate()
	box_open.cull_mode = BaseMaterial3D.CULL_DISABLED
	materials.box_open = box_open
	materials.line = _unshaded(1)
	materials.line.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var limit_line := _unshaded(1)
	limit_line.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# On the surface itself: pulled a hair toward the camera so it doesn't fight the surface.
	limit_line.use_z_clip_scale = true
	limit_line.z_clip_scale = 0.99995
	materials.limit_line = limit_line
	var hidden := _unshaded(0)
	hidden.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	hidden.no_depth_test = true
	materials.hidden_line = hidden
	var points := _unshaded(1)
	points.use_point_size = true
	points.point_size = 5.0
	materials.points = points
	var soft_points := _unshaded(1)
	soft_points.use_point_size = true
	soft_points.point_size = 6.0
	soft_points.vertex_color_use_as_albedo = true
	soft_points.vertex_color_is_srgb = true
	materials.soft_points = soft_points
	for key in ["select_face", "hover_face", "isolated_face", "frozen_face", "warning_face"]:
		var m := _unshaded(2)
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		m.use_z_clip_scale = true
		m.z_clip_scale = 0.9998
		materials[key] = m
	var plane := _unshaded(0)
	plane.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	plane.cull_mode = BaseMaterial3D.CULL_DISABLED
	plane.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	materials.symmetry_plane = plane
	# A circular symmetry's axis: drawn through the body (it runs inside it).
	var axis_line := _unshaded(1)
	axis_line.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	axis_line.no_depth_test = true
	materials.symmetry_axis = axis_line


static func _unshaded(priority: int) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.render_priority = priority
	return m


# --- Mesh builders -----------------------------------------------------------------------------

## The smooth surface from a CadSubD tessellation (colors: one per tess vertex, or empty).
static func surface_mesh(tess: Dictionary, colors_per_vertex := PackedColorArray()) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var indices: PackedInt32Array = tess.get("indices", PackedInt32Array())
	if indices.is_empty():
		return mesh
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = tess.positions
	arrays[Mesh.ARRAY_NORMAL] = tess.normals
	if colors_per_vertex.size() == (tess.positions as PackedVector3Array).size():
		arrays[Mesh.ARRAY_COLOR] = colors_per_vertex
	arrays[Mesh.ARRAY_INDEX] = indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## The cage polygons, fan-triangulated with flat per-face normals, as a tessellation-like
## dictionary {"positions", "normals", "indices", "face_ids"} (face_ids per triangle).
static func cage_faces(cage: Dictionary) -> Dictionary:
	var p: PackedFloat64Array = cage.positions
	var counts: PackedInt32Array = cage.face_counts
	var idx: PackedInt32Array = cage.face_indices
	var positions := PackedVector3Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	var face_ids := PackedInt32Array()
	var o := 0
	for f in counts.size():
		var n := counts[f]
		# Newell normal (outward for a counter-clockwise face).
		var nx := 0.0
		var ny := 0.0
		var nz := 0.0
		for k in n:
			var a := idx[o + k]
			var b := idx[o + (k + 1) % n]
			nx += (p[3 * a + 1] - p[3 * b + 1]) * (p[3 * a + 2] + p[3 * b + 2])
			ny += (p[3 * a + 2] - p[3 * b + 2]) * (p[3 * a] + p[3 * b])
			nz += (p[3 * a] - p[3 * b]) * (p[3 * a + 1] + p[3 * b + 1])
		var normal := Vector3(nx, ny, nz).normalized()
		var base := positions.size()
		for k in n:
			var v := idx[o + k]
			positions.append(Vector3(p[3 * v], p[3 * v + 1], p[3 * v + 2]))
			normals.append(normal)
		# Godot's front faces wind clockwise: each fan triangle is turned over.
		for k in range(1, n - 1):
			indices.append(base)
			indices.append(base + k + 1)
			indices.append(base + k)
			face_ids.append(f)
		o += n
	return {"positions": positions, "normals": normals, "indices": indices, "face_ids": face_ids}


## The cage edges as a line mesh (pairs: Topo.edges, 2 vertex ids per edge).
static func cage_lines_mesh(cage: Dictionary, pairs: PackedInt32Array) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	if pairs.is_empty():
		return mesh
	var p: PackedFloat64Array = cage.positions
	var lines := PackedVector3Array()
	lines.resize(pairs.size())
	for i in pairs.size():
		var v := pairs[i]
		lines[i] = Vector3(p[3 * v], p[3 * v + 1], p[3 * v + 2])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = lines
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	return mesh


## Segment pairs as a line mesh.
static func lines_mesh(points: PackedVector3Array) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	if points.size() < 2:
		return mesh
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = points
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	return mesh


## Points (colors: one per point, or empty).
static func points_mesh(points: PackedVector3Array, colors_per_point := PackedColorArray()) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	if points.is_empty():
		return mesh
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = points
	if colors_per_point.size() == points.size():
		arrays[Mesh.ARRAY_COLOR] = colors_per_point
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_POINTS, arrays)
	return mesh


## The triangles of the given faces (faces: face id -> true) of a tessellation-like dictionary,
## pushed offset meters along their normals.
static func faces_mesh(tess: Dictionary, faces: Dictionary, offset: float, tris := {}) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	if faces.is_empty():
		return mesh
	var positions: PackedVector3Array = tess.get("positions", PackedVector3Array())
	var normals: PackedVector3Array = tess.get("normals", PackedVector3Array())
	var indices: PackedInt32Array = tess.get("indices", PackedInt32Array())
	var face_ids: PackedInt32Array = tess.get("face_ids", PackedInt32Array())
	var out_p := PackedVector3Array()
	var out_n := PackedVector3Array()
	var remap := {}
	var out_i := PackedInt32Array()
	var wanted := PackedInt32Array()
	if not tris.is_empty():
		for f in faces:
			wanted.append_array(tris.get(f, PackedInt32Array()))
	else:
		for t in face_ids.size():
			if faces.has(face_ids[t]):
				wanted.append(t)
	for t in wanted:
		for k in 3:
			var i := indices[3 * t + k]
			var j: int = remap.get(i, -1)
			if j < 0:
				j = out_p.size()
				remap[i] = j
				var n := normals[i] if i < normals.size() else Vector3.ZERO
				out_p.append(positions[i] + n * offset)
				out_n.append(n)
			out_i.append(j)
	if out_i.is_empty():
		return mesh
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = out_p
	arrays[Mesh.ARRAY_NORMAL] = out_n
	arrays[Mesh.ARRAY_INDEX] = out_i
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## The given faces of a tessellation-like dictionary as a mesh sharing its vertex arrays (no copy
## of the vertices, no offset: the highlight materials pull it toward the camera). first_tri:
## {face: [first triangle, count]} from face_runs(). Cheap enough to rebuild on every drag frame.
static func faces_index_mesh(tess: Dictionary, faces: Dictionary, runs: Dictionary, all := false) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var indices: PackedInt32Array = tess.get("indices", PackedInt32Array())
	if indices.is_empty() or (faces.is_empty() and not all):
		return mesh
	var out_i := PackedInt32Array()
	if all:
		out_i = indices
	else:
		for f in faces:
			var run: Vector2i = runs.get(f, Vector2i(-1, 0))
			if run.x >= 0 and run.y > 0:
				out_i.append_array(indices.slice(3 * run.x, 3 * (run.x + run.y)))
	if out_i.is_empty():
		return mesh
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = tess.positions
	arrays[Mesh.ARRAY_NORMAL] = tess.normals
	arrays[Mesh.ARRAY_INDEX] = out_i
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## face id -> Vector2i(first triangle, triangle count) for tessellations whose triangles come face
## by face (CadSubD.tessellate, cage_faces).
static func face_runs(tess: Dictionary) -> Dictionary:
	var out := {}
	var face_ids: PackedInt32Array = tess.get("face_ids", PackedInt32Array())
	var start := 0
	while start < face_ids.size():
		var f := face_ids[start]
		var end := start + 1
		while end < face_ids.size() and face_ids[end] == f:
			end += 1
		if not out.has(f):
			out[f] = Vector2i(start, end - start)
		start = end
	return out


## face id -> PackedInt32Array of its triangles in a tessellation-like dictionary.
static func face_triangles(tess: Dictionary) -> Dictionary:
	var out := {}
	var face_ids: PackedInt32Array = tess.get("face_ids", PackedInt32Array())
	var start := 0
	while start < face_ids.size():
		var f := face_ids[start]
		var end := start + 1
		while end < face_ids.size() and face_ids[end] == f:
			end += 1
		var list: PackedInt32Array = out.get(f, PackedInt32Array())
		for t in range(start, end):
			list.append(t)
		out[f] = list
		start = end
	return out


## A translucent square in a mirror plane, sized to the body's bounds x 1.2.
static func plane_mesh(origin: Vector3, normal: Vector3, bounds: AABB) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var n := normal.normalized()
	if n.length() < 0.5:
		return mesh
	var u := n.cross(Vector3.UP if absf(n.y) < 0.9 else Vector3.RIGHT).normalized()
	var v := n.cross(u)
	var center := bounds.get_center()
	center -= n * (center - origin).dot(n)
	var half_u := 0.0
	var half_v := 0.0
	for i in 8:
		var d := bounds.get_endpoint(i) - center
		half_u = maxf(half_u, absf(d.dot(u)))
		half_v = maxf(half_v, absf(d.dot(v)))
	half_u = maxf(half_u, 1e-6) * 1.2
	half_v = maxf(half_v, 1e-6) * 1.2
	var corners := PackedVector3Array([center - u * half_u - v * half_v, center + u * half_u - v * half_v,
		center + u * half_u + v * half_v, center - u * half_u + v * half_v])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = corners
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([n, n, n, n])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 2, 1, 0, 3, 2])
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## A circular symmetry's axis as a line through the body's bounds (x 1.2), with small ticks at its
## ends.
static func axis_mesh(origin: Vector3, axis: Vector3, bounds: AABB) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var a := axis.normalized()
	if a.length() < 0.5:
		return mesh
	var lo := INF
	var hi := -INF
	for i in 8:
		var t := (bounds.get_endpoint(i) - origin).dot(a)
		lo = minf(lo, t)
		hi = maxf(hi, t)
	var pad := maxf((hi - lo) * 0.1, bounds.size.length() * 0.05)
	var p0 := origin + a * (lo - pad)
	var p1 := origin + a * (hi + pad)
	var side := a.cross(Vector3.UP if absf(a.y) < 0.9 else Vector3.RIGHT).normalized() * bounds.size.length() * 0.02
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([p0, p1, p0 - side, p0 + side, p1 - side, p1 + side])
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	return mesh


## Cage positions as Vector3s (float32 views, for display only).
static func positions_v3(cage: Dictionary) -> PackedVector3Array:
	var p: PackedFloat64Array = cage.positions
	var out := PackedVector3Array()
	out.resize(p.size() / 3)
	for v in out.size():
		out[v] = Vector3(p[3 * v], p[3 * v + 1], p[3 * v + 2])
	return out
