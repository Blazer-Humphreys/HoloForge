@tool
extends RefCounted
## Turns kernel tessellations (CadShape.tessellate) into Godot meshes.
## Godot front faces are clockwise; the kernel already emits them that way.
##
## A mesh body (a CadMesh, core/mesh/mesh_body.gd) tessellates into the same keys: its stored
## triangles in their stored order ("face_ids" holds each triangle's face group), with group
## borders (edge id -1) and open edges (-2) as "edge_points". Its tessellation also carries
## "cad_mesh": the CadMesh, so picking can ask the mesh itself.

const MESH_BODY := preload("res://addons/holo_forge/core/mesh/mesh_body.gd")

const ANGULAR_DEFLECTION := 0.3
## The key under which a mesh body's tessellation (and its pickable body) carries its CadMesh.
const MESH_KEY := "cad_mesh"
## edge_ids of a mesh body's lines: a border between two face groups, and an open edge.
const MESH_GROUP_BORDER := -1
const MESH_OPEN_EDGE := -2


## Tessellates with a deflection relative to the shape's size (finer for small parts).
static func tessellate(shape: RefCounted) -> Dictionary:
	if shape == null or shape.is_null():
		return {}
	var diagonal: float = (shape.bbox() as AABB).size.length()
	var linear := clampf(diagonal * 0.0015, 0.00001, 0.01)
	var tess: Dictionary = shape.tessellate(linear, ANGULAR_DEFLECTION)
	if MESH_BODY.is_mesh(shape):
		tess[MESH_KEY] = shape
	return tess


static func has_triangles(tess: Dictionary) -> bool:
	return not (tess.get("indices", PackedInt32Array()) as PackedInt32Array).is_empty()


## The shaded surface of every face.
static func surface_mesh(tess: Dictionary) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	if not has_triangles(tess):
		return mesh
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = tess.positions
	arrays[Mesh.ARRAY_NORMAL] = tess.normals
	arrays[Mesh.ARRAY_TEX_UV] = tess.uvs
	arrays[Mesh.ARRAY_INDEX] = tess.indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Only the triangles of the given faces (used for selection and hover highlights).
static func face_subset_mesh(tess: Dictionary, faces: PackedInt32Array) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	if not has_triangles(tess) or faces.is_empty():
		return mesh
	if MESH_BODY.is_mesh(tess.get(MESH_KEY)):
		# A mesh body knows each face group's triangles: no pass over every triangle here.
		var triangles := PackedInt32Array()
		for f in faces:
			if f >= 0 and f < int(tess[MESH_KEY].face_count()):
				triangles.append_array(tess[MESH_KEY].group_triangles(f))
		return triangle_subset_mesh(tess, triangles)
	var wanted := {}
	for f in faces:
		wanted[f] = true
	var face_ids: PackedInt32Array = tess.face_ids
	var indices: PackedInt32Array = tess.indices
	var subset := PackedInt32Array()
	for t in face_ids.size():
		if wanted.has(face_ids[t]):
			subset.append(indices[t * 3])
			subset.append(indices[t * 3 + 1])
			subset.append(indices[t * 3 + 2])
	if subset.is_empty():
		return mesh
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = tess.positions
	arrays[Mesh.ARRAY_NORMAL] = tess.normals
	arrays[Mesh.ARRAY_INDEX] = subset
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Only the given triangles (indices into tess.face_ids: a mesh body's stored triangles), for the
## selection and hover highlights of a mesh body's triangles.
static func triangle_subset_mesh(tess: Dictionary, triangles: PackedInt32Array) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	if not has_triangles(tess) or triangles.is_empty():
		return mesh
	var indices: PackedInt32Array = tess.indices
	var count := int(indices.size() / 3.0)
	var subset := PackedInt32Array()
	for t in triangles:
		if t < 0 or t >= count:
			continue
		subset.append(indices[t * 3])
		subset.append(indices[t * 3 + 1])
		subset.append(indices[t * 3 + 2])
	if subset.is_empty():
		return mesh
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = tess.positions
	arrays[Mesh.ARRAY_NORMAL] = tess.normals
	arrays[Mesh.ARRAY_INDEX] = subset
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Edge lines; all edges when ids is empty, otherwise only those edges.
static func edge_mesh(tess: Dictionary, ids := PackedInt32Array()) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var points: PackedVector3Array = tess.get("edge_points", PackedVector3Array())
	var edge_ids: PackedInt32Array = tess.get("edge_ids", PackedInt32Array())
	if points.is_empty():
		return mesh
	var lines := points
	if not ids.is_empty():
		var wanted := {}
		for id in ids:
			wanted[id] = true
		lines = PackedVector3Array()
		for s in edge_ids.size():
			if wanted.has(edge_ids[s]):
				lines.append(points[s * 2])
				lines.append(points[s * 2 + 1])
		if lines.is_empty():
			return mesh
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = lines
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	return mesh


## Trimesh collision faces for a baked body.
static func collision_faces(tess: Dictionary) -> PackedVector3Array:
	var faces := PackedVector3Array()
	if not has_triangles(tess):
		return faces
	var positions: PackedVector3Array = tess.positions
	for i in tess.indices:
		faces.append(positions[i])
	return faces
