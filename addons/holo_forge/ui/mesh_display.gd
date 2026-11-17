@tool
extends RefCounted
## Meshes and materials of mesh bodies in the Forge view (owned by ui/forge_workspace.gd, shown
## through the view's set_bodies and set_mesh_overlays): the face group colours (Display Mesh Face
## Groups), group borders and open boundaries, the selection and hover overlays of the Mesh
## workspace, and the tool previews (removed parts, fills). Every colour is a forge_theme.gd
## mesh_* token; apply_theme recolours the shared materials in place, so nothing is rebuilt.
##
##   materials.surface            a mesh body's plain surface (mesh_surface)
##   materials.group_<0..7>       one per face group colour (mesh_group_palette)
##   materials.border / boundary  group borders and open edges (depth tested lines)
##   materials.selected / hover   translucent overlays, a hair in front of the surface
##   materials.removed / fill / preview   what a tool takes away, adds, or will make
##
##   group_colors(shape)          each face group's colour index: neighbours differ (greedy, in
##                                group order, so the same mesh always gets the same colours)
##   group_mesh(tess, shape)      the body's surface split into up to 8 surfaces by colour, each
##                                with its material (for set_bodies' "mesh")
##   selection_mesh(tess, triangles)   only those triangles (TESSELLATE.triangle_subset_mesh)
##   border_mesh(tess) / boundary_mesh(tess)   the two kinds of lines of a mesh body
##   boundary_segments(tess)      the open edges as point pairs, for the wide overlay lines ([]
##                                when there are more than BOUNDARY_OVERLAY_SEGMENTS)

const TESSELLATE := preload("res://addons/holo_forge/core/tessellate.gd")
const MESH_BODY := preload("res://addons/holo_forge/core/mesh/mesh_body.gd")
const FORGE_THEME := preload("res://addons/holo_forge/ui/forge_theme.gd")

const PALETTE_SIZE := 8
## The wide open-edge lines are drawn on the overlay only up to this many segments per body; a
## mesh with more keeps its thin lines.
const BOUNDARY_OVERLAY_SEGMENTS := 1500
## Colourings and coloured meshes kept (by mesh digest), so a view refresh builds nothing again.
const KEPT := 6
## Up to this many picked triangles are drawn as a mesh of their own corners (selection_mesh()).
const SMALL_SELECTION := 4096

var colors := FORGE_THEME.palette("dark")
var materials := {}
## How often group_mesh() built a mesh (tests read it).
var builds := 0

var _colorings := {}
var _group_meshes := {}


func _init() -> void:
	_make_materials()
	apply_theme(colors)


## Recolours every material from a palette (forge_theme.gd).
func apply_theme(palette: Dictionary) -> void:
	colors = palette.duplicate(true)
	var c := colors
	(materials.surface as StandardMaterial3D).albedo_color = c.mesh_surface
	(materials.surface_open as StandardMaterial3D).albedo_color = c.mesh_surface
	(materials.wire as StandardMaterial3D).albedo_color = c.mesh_wire
	(materials.border as StandardMaterial3D).albedo_color = c.mesh_group_border
	(materials.boundary as StandardMaterial3D).albedo_color = c.mesh_boundary
	(materials.selected as StandardMaterial3D).albedo_color = c.mesh_selected
	(materials.hover as StandardMaterial3D).albedo_color = c.mesh_hover
	(materials.removed as StandardMaterial3D).albedo_color = c.mesh_removed
	(materials.fill as StandardMaterial3D).albedo_color = Color(c.mesh_fill, 0.6)
	(materials.preview as StandardMaterial3D).albedo_color = Color(c.mesh_preview, 0.45)
	var palette_colors: Array = c.mesh_group_palette
	for i in PALETTE_SIZE:
		(materials["group_%d" % i] as StandardMaterial3D).albedo_color = palette_colors[i % palette_colors.size()]


## The material of face group colour index (0..7).
func group_material(index: int) -> StandardMaterial3D:
	return materials["group_%d" % posmod(index, PALETTE_SIZE)]


func _make_materials() -> void:
	# The body material's own look (ui/forge_viewport.gd), in the mesh colour.
	var surface := StandardMaterial3D.new()
	surface.roughness = 0.45
	surface.metallic = 0.1
	materials.surface = surface
	var open: StandardMaterial3D = surface.duplicate()
	open.cull_mode = BaseMaterial3D.CULL_DISABLED
	materials.surface_open = open
	for i in PALETTE_SIZE:
		var group := StandardMaterial3D.new()
		group.roughness = 0.45
		group.metallic = 0.1
		# An open mesh shows its inside too.
		group.cull_mode = BaseMaterial3D.CULL_DISABLED
		materials["group_%d" % i] = group
	var wire := _unshaded(1)
	wire.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	materials.wire = wire
	materials.border = _unshaded(1)
	materials.boundary = _unshaded(1)
	for key in ["selected", "hover", "removed", "fill", "preview"]:
		var m := _unshaded(2)
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		# On the surface itself: pulled a hair toward the camera so it doesn't fight the surface.
		m.use_z_clip_scale = true
		m.z_clip_scale = 0.9998
		materials[key] = m


static func _unshaded(priority: int) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.render_priority = priority
	return m


# --- Face group colours ----------------------------------------------------------------------

## Which face groups touch which: [PackedInt32Array of neighbour group indices] per group. Two
## groups are neighbours when a triangle of one shares an edge with a triangle of the other.
static func group_neighbours(shape: RefCounted, group_of: PackedInt32Array) -> Array:
	var count := int(shape.face_count())
	var neighbours := []
	neighbours.resize(count)
	for g in count:
		var mine: PackedInt32Array = shape.group_triangles(g)
		var found := {}
		if not mine.is_empty() and count > 1:
			# One ring around the group: the triangles in it that belong to other groups.
			for t in (shape.grow(mine, 1) as PackedInt32Array):
				var other := group_of[t] if t < group_of.size() else g
				if other != g:
					found[other] = true
		var list := PackedInt32Array(found.keys())
		list.sort()
		neighbours[g] = list
	return neighbours


## Each face group's colour index (0..7): the lowest one none of its already coloured neighbours
## has (greedy, in group order). The same mesh always gets the same colours.
func group_colors(shape: RefCounted) -> PackedInt32Array:
	var key := str(shape.digest())
	if _colorings.has(key):
		return _colorings[key]
	var count := int(shape.face_count())
	var group_of: PackedInt32Array = (shape.get_arrays() as Dictionary).get("groups", PackedInt32Array())
	var neighbours := group_neighbours(shape, group_of)
	var chosen := PackedInt32Array()
	chosen.resize(count)
	chosen.fill(-1)
	for g in count:
		var taken := {}
		for other in (neighbours[g] as PackedInt32Array):
			if chosen[other] >= 0:
				taken[chosen[other]] = true
		var pick := -1
		# Start from the group's own place in the palette, so groups far apart vary too.
		for step in PALETTE_SIZE:
			var candidate := (g + step) % PALETTE_SIZE
			if not taken.has(candidate):
				pick = candidate
				break
		# (More than 8 neighbours all coloured differently: the least used of their colours.)
		chosen[g] = pick if pick >= 0 else g % PALETTE_SIZE
	_keep(_colorings, key, chosen)
	return chosen


## A mesh body's surface with its face groups coloured: one surface per colour in use (up to 8),
## each with its palette material. tess: the body's tessellation; shape: its CadMesh.
func group_mesh(tess: Dictionary, shape: RefCounted) -> ArrayMesh:
	var key := str(shape.digest())
	if _group_meshes.has(key):
		return _group_meshes[key]
	builds += 1
	var mesh := ArrayMesh.new()
	if not TESSELLATE.has_triangles(tess):
		return mesh
	var chosen := group_colors(shape)
	var indices: PackedInt32Array = tess.indices
	var per_color := []
	for i in PALETTE_SIZE:
		per_color.append(PackedInt32Array())
	for g in chosen.size():
		var triangles: PackedInt32Array = shape.group_triangles(g)
		if triangles.is_empty():
			continue
		var into: PackedInt32Array = per_color[chosen[g]]
		var first := triangles[0]
		var last := triangles[triangles.size() - 1]
		if last - first + 1 == triangles.size():
			# The group's triangles lie in one run (the usual case): one slice.
			into.append_array(indices.slice(first * 3, (last + 1) * 3))
		else:
			for t in triangles:
				into.append(indices[t * 3])
				into.append(indices[t * 3 + 1])
				into.append(indices[t * 3 + 2])
		per_color[chosen[g]] = into
	for i in PALETTE_SIZE:
		var subset: PackedInt32Array = per_color[i]
		if subset.is_empty():
			continue
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = tess.positions
		arrays[Mesh.ARRAY_NORMAL] = tess.normals
		arrays[Mesh.ARRAY_TEX_UV] = tess.uvs
		arrays[Mesh.ARRAY_INDEX] = subset
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_material(mesh.get_surface_count() - 1, group_material(i))
	_keep(_group_meshes, key, mesh)
	return mesh


## The colour indices in use on a coloured mesh, in surface order (for tests).
func group_mesh_colors(mesh: ArrayMesh) -> PackedInt32Array:
	var used := PackedInt32Array()
	for s in mesh.get_surface_count():
		var material := mesh.surface_get_material(s)
		for i in PALETTE_SIZE:
			if material == materials["group_%d" % i]:
				used.append(i)
	return used


# --- Lines and overlays ----------------------------------------------------------------------

## The borders between a mesh body's face groups, as lines.
static func border_mesh(tess: Dictionary) -> ArrayMesh:
	return TESSELLATE.edge_mesh(tess, PackedInt32Array([TESSELLATE.MESH_GROUP_BORDER]))


## A mesh body's open edges, as lines.
static func boundary_mesh(tess: Dictionary) -> ArrayMesh:
	return TESSELLATE.edge_mesh(tess, PackedInt32Array([TESSELLATE.MESH_OPEN_EDGE]))


## How many open edges a mesh body's tessellation holds.
static func boundary_count(tess: Dictionary) -> int:
	var total := 0
	for id in (tess.get("edge_ids", PackedInt32Array()) as PackedInt32Array):
		if id == TESSELLATE.MESH_OPEN_EDGE:
			total += 1
	return total


## The open edges as point pairs, for the wide lines the overlay draws over the thin ones; empty
## when there are more than BOUNDARY_OVERLAY_SEGMENTS (the thin lines then stand alone).
static func boundary_segments(tess: Dictionary) -> PackedVector3Array:
	var points: PackedVector3Array = tess.get("edge_points", PackedVector3Array())
	var ids: PackedInt32Array = tess.get("edge_ids", PackedInt32Array())
	var out := PackedVector3Array()
	for s in ids.size():
		if ids[s] != TESSELLATE.MESH_OPEN_EDGE:
			continue
		if out.size() >= BOUNDARY_OVERLAY_SEGMENTS * 2:
			return PackedVector3Array()
		out.append(points[s * 2])
		out.append(points[s * 2 + 1])
	return out


## Only the given triangles of a mesh body (the selection, a hover, a tool's preview). Triangles
## that lie in one run (sorted, no gaps: a whole face group, or the whole body) are cut out of the
## index list in one piece, so hovering a big face group builds its overlay at once. A few
## triangles (a hovered triangle, a small selection) get a mesh of their own corners only, so the
## cost does not grow with the body (a mesh that shares a million-triangle body's vertices took
## 35 ms to build for one hovered triangle).
static func selection_mesh(tess: Dictionary, triangles: PackedInt32Array) -> ArrayMesh:
	var indices: PackedInt32Array = tess.get("indices", PackedInt32Array())
	var count := triangles.size()
	if indices.is_empty():
		return TESSELLATE.triangle_subset_mesh(tess, triangles)
	if count <= SMALL_SELECTION:
		return _corner_mesh(tess, triangles)
	var first := triangles[0]
	var last := triangles[count - 1]
	if first < 0 or last - first + 1 != count or (last + 1) * 3 > indices.size():
		return TESSELLATE.triangle_subset_mesh(tess, triangles)
	# (Ascending with as many entries as the span is wide: a run, unless it repeats or jumps.)
	var step := maxi(1, int(count / 64.0))
	for i in range(0, count, step):
		if triangles[i] != first + i:
			return TESSELLATE.triangle_subset_mesh(tess, triangles)
	var mesh := ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = tess.positions
	arrays[Mesh.ARRAY_NORMAL] = tess.normals
	arrays[Mesh.ARRAY_INDEX] = indices if count * 3 == indices.size() else indices.slice(first * 3, (last + 1) * 3)
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## The given triangles as a mesh that holds only their own corners (three vertices a triangle).
static func _corner_mesh(tess: Dictionary, triangles: PackedInt32Array) -> ArrayMesh:
	var indices: PackedInt32Array = tess.indices
	var positions: PackedVector3Array = tess.positions
	var normals: PackedVector3Array = tess.get("normals", PackedVector3Array())
	var smooth := normals.size() == positions.size()
	var corners := PackedVector3Array()
	var corner_normals := PackedVector3Array()
	corners.resize(triangles.size() * 3)
	corner_normals.resize(triangles.size() * 3)
	var at := 0
	for t in triangles:
		if t < 0 or t * 3 + 2 >= indices.size():
			continue
		var a := indices[t * 3]
		var b := indices[t * 3 + 1]
		var c := indices[t * 3 + 2]
		corners[at] = positions[a]
		corners[at + 1] = positions[b]
		corners[at + 2] = positions[c]
		if smooth:
			corner_normals[at] = normals[a]
			corner_normals[at + 1] = normals[b]
			corner_normals[at + 2] = normals[c]
		else:
			# (Godot's front faces wind clockwise.)
			var flat := (positions[c] - positions[a]).cross(positions[b] - positions[a]).normalized()
			corner_normals[at] = flat
			corner_normals[at + 1] = flat
			corner_normals[at + 2] = flat
		at += 3
	corners.resize(at)
	corner_normals.resize(at)
	var mesh := ArrayMesh.new()
	if at == 0:
		return mesh
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = corners
	arrays[Mesh.ARRAY_NORMAL] = corner_normals
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## A mesh body's triangle edges as lines (the faint wire a tool preview shows), or an empty mesh
## above max_triangles.
static func wire_mesh(tess: Dictionary, max_triangles := 60000) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var indices: PackedInt32Array = tess.get("indices", PackedInt32Array())
	if indices.is_empty() or indices.size() > max_triangles * 3:
		return mesh
	var positions: PackedVector3Array = tess.positions
	var lines := PackedVector3Array()
	lines.resize(indices.size() * 2)
	var at := 0
	for t in range(0, indices.size(), 3):
		for k in 3:
			lines[at] = positions[indices[t + k]]
			lines[at + 1] = positions[indices[t + (k + 1) % 3]]
			at += 2
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = lines
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	return mesh


func _keep(store: Dictionary, key: String, value: Variant) -> void:
	while store.size() >= KEPT:
		store.erase(store.keys()[0])
	store[key] = value
