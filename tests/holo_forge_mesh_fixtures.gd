@tool
extends RefCounted
## Fixtures for the Holo Forge Mesh workspace tests (a helper, not a test). Pure GDScript and
## deterministic: no random numbers without a fixed seed. Every function gives
## {"positions": PackedVector3Array, "indices": PackedInt32Array (Godot winding: clockwise seen
## from outside), "groups": PackedInt32Array, "names": PackedStringArray}, in meters. Some add keys
## of their own (said at each). Files are written under user://holo_forge_mesh_fixtures/, never
## into the project.
##
## const FIXTURES := preload("res://tests/holo_forge_mesh_fixtures.gd")

const MM := 0.001
const DIR := "user://holo_forge_mesh_fixtures"


## A CadMesh of a fixture (null without the native library, or when the arrays are refused).
static func to_mesh(fixture: Dictionary) -> RefCounted:
	if not ClassDB.class_exists("CadMesh") or fixture.is_empty():
		return null
	var mesh: RefCounted = ClassDB.instantiate("CadMesh")
	if not mesh.set_arrays(fixture.positions, fixture.indices, fixture.groups, fixture.names, "godot"):
		push_warning("mesh fixture refused: " + mesh.get_last_error())
		return null
	return mesh


## A sphere of radius r from an icosahedron split s times: 20 * 4^s triangles (s = 5: 20,480;
## s = 4: 5,120) and 10 * 4^s + 2 welded vertices, every one on the sphere.
static func icosphere(r: float, s: int, center := Vector3.ZERO) -> Dictionary:
	var t := (1.0 + sqrt(5.0)) / 2.0
	var dirs: Array[Vector3] = []
	for p: Vector3 in [Vector3(-1, t, 0), Vector3(1, t, 0), Vector3(-1, -t, 0), Vector3(1, -t, 0), Vector3(0, -1, t), Vector3(0, 1, t),
			Vector3(0, -1, -t), Vector3(0, 1, -t), Vector3(t, 0, -1), Vector3(t, 0, 1), Vector3(-t, 0, -1), Vector3(-t, 0, 1)]:
		dirs.append(p.normalized())
	# Counter-clockwise seen from outside.
	var tris := PackedInt32Array([0, 11, 5, 0, 5, 1, 0, 1, 7, 0, 7, 10, 0, 10, 11, 1, 5, 9, 5, 11, 4, 11, 10, 2, 10, 7, 6, 7, 1, 8,
		3, 9, 4, 3, 4, 2, 3, 2, 6, 3, 6, 8, 3, 8, 9, 4, 9, 5, 2, 4, 11, 6, 2, 10, 8, 6, 7, 9, 8, 1])
	for level in s:
		var mids := {}
		var next := PackedInt32Array()
		next.resize(tris.size() * 4)
		var w := 0
		for i in range(0, tris.size(), 3):
			var a := tris[i]
			var b := tris[i + 1]
			var c := tris[i + 2]
			var corners := [a, b, c]
			var m := [0, 0, 0]
			for k in 3:
				var u: int = corners[k]
				var v: int = corners[(k + 1) % 3]
				var key := (mini(u, v) << 32) | maxi(u, v)
				if not mids.has(key):
					mids[key] = dirs.size()
					dirs.append((dirs[u] + dirs[v]).normalized())
				m[k] = mids[key]
			for id: int in [a, m[0], m[2], b, m[1], m[0], c, m[2], m[1], m[0], m[1], m[2]]:
				next[w] = id
				w += 1
		tris = next
	var positions := PackedVector3Array()
	positions.resize(dirs.size())
	for i in dirs.size():
		positions[i] = center + dirs[i] * r
	return _pack(positions, tris)


## A bumpy ball with five holes: icosphere s = 4, r = 50 mm, each vertex moved along its radius by
## 0.004 sin(3 theta) cos(2 phi) + 0.002 sin(5 phi) m (theta from +Y, phi around it), then the
## triangles within 3, 5, 8, 12 and 20 mm (along the sphere) of five fixed points taken out.
## "reference" is the same ball before the holes; "holes" is 5.
static func holed_blob() -> Dictionary:
	var ball := icosphere(0.05, 4)
	var positions: PackedVector3Array = ball.positions
	for i in positions.size():
		var dir := positions[i].normalized()
		var theta := acos(clampf(dir.y, -1.0, 1.0))
		var phi := atan2(dir.z, dir.x)
		positions[i] = dir * (0.05 + 0.004 * sin(3.0 * theta) * cos(2.0 * phi) + 0.002 * sin(5.0 * phi))
	var reference := {"positions": positions, "indices": ball.indices, "groups": ball.groups, "names": ball.names}
	var centres: Array[Vector3] = [Vector3(1, 0.2, 0.1).normalized(), Vector3(-0.3, 1, 0.2).normalized(), Vector3(0.1, -0.4, 1).normalized(),
		Vector3(-1, -0.3, 0.4).normalized(), Vector3(0.3, -1, -0.5).normalized()]
	var radii := [3 * MM, 5 * MM, 8 * MM, 12 * MM, 20 * MM]
	var indices: PackedInt32Array = ball.indices
	var kept := PackedInt32Array()
	for i in range(0, indices.size(), 3):
		var dir := (positions[indices[i]] + positions[indices[i + 1]] + positions[indices[i + 2]]).normalized()
		var out := false
		for h in centres.size():
			if acos(clampf(dir.dot(centres[h]), -1.0, 1.0)) * 0.05 <= radii[h]:
				out = true
		if not out:
			kept.append_array([indices[i], indices[i + 1], indices[i + 2]])
	var blob := _compacted(positions, kept)
	blob["reference"] = reference
	blob["holes"] = 5
	return blob


## An L profile of 60 x 40 x 10 mm extruded 30 mm with a 10 mm through hole in its long leg, built
## in the kernel and tessellated (CadMesh.from_shape, "high": deviation D / 5000, 8 degrees). One
## group per B-rep face. Adds "shape" (the CadShape), "mesh" (the CadMesh), "hole_axis_point",
## "hole_axis" and "hole_radius". Empty without the native library.
static func l_bracket() -> Dictionary:
	if not ClassDB.class_exists("CadKernel") or not ClassDB.class_exists("CadMesh"):
		return {}
	var kernel: RefCounted = ClassDB.instantiate("CadKernel")
	var outline: Array[Vector2] = [Vector2(0, 0), Vector2(60, 0), Vector2(60, 10), Vector2(10, 10), Vector2(10, 40), Vector2(0, 40)]
	var curves := []
	for i in outline.size():
		curves.append({"type": "line", "a": outline[i] * MM, "b": outline[(i + 1) % outline.size()] * MM, "entity": 10 + i})
	var regions: Array = kernel.sketch_regions(curves, Transform3D.IDENTITY)
	if regions.is_empty():
		return {}
	var solid: RefCounted = kernel.extrude(regions[0].face, {"direction": Vector3(0, 0, 1), "distance": 30 * MM, "tag": "L"})
	var drill: RefCounted = kernel.make_cylinder(5 * MM, 30 * MM, Vector3(35, -10, 15) * MM, Vector3.UP)
	var holed: RefCounted = kernel.boolean(solid, drill, 1) if solid != null and drill != null else null
	var fixture := _from_shape(holed, 5000.0, 8.0)
	if not fixture.is_empty():
		fixture["hole_axis_point"] = Vector3(35, 0, 15) * MM
		fixture["hole_axis"] = Vector3.UP
		fixture["hole_radius"] = 5 * MM
	return fixture


## A 60 x 60 x 30 mm block with two through holes along Z (r 4 mm) and two along X (r 3 mm), each
## X hole crossing both Z holes: 4 crossing cylinder pairs. Built in the kernel and tessellated
## like l_bracket(). Adds "shape" and "mesh". Empty without the native library.
static func crossing_holes() -> Dictionary:
	if not ClassDB.class_exists("CadKernel") or not ClassDB.class_exists("CadMesh"):
		return {}
	var kernel: RefCounted = ClassDB.instantiate("CadKernel")
	var block: RefCounted = kernel.make_box(Vector3(60, 60, 30) * MM)
	for x: float in [20.0, 40.0]:
		var drill: RefCounted = kernel.make_cylinder(4 * MM, 50 * MM, Vector3(x, 30, -10) * MM, Vector3(0, 0, 1))
		block = kernel.boolean(block, drill, 1) if block != null and drill != null else null
	for z: float in [9.0, 21.0]:
		var drill: RefCounted = kernel.make_cylinder(3 * MM, 80 * MM, Vector3(-10, 30, z) * MM, Vector3(1, 0, 0))
		block = kernel.boolean(block, drill, 1) if block != null and drill != null else null
	return _from_shape(block, 5000.0, 8.0)


## A 20 mm cube (12 triangles, welded) with rubbish on it: 30 tiny triangles 0.01 mm above its top,
## 5 of its triangles twice, one fin triangle on an edge, and 3 corners split by 1e-7 m (one
## triangle at each takes a copy of the corner). 48 triangles. "expected" holds the counts as
## built: {"triangles", "duplicate", "degenerate", "tiny", "fin", "split", "boundary_edges",
## "non_manifold_edges"} (the edge counts by a plain count of the uses of every edge).
static func cube_debris() -> Dictionary:
	var cube := _cube_ccw(20 * MM, Vector3.ZERO)
	var positions: PackedVector3Array = cube.positions
	var tris: PackedInt32Array = cube.indices
	# Three corners split: the first triangle at each corner moves to a copy 1e-7 m away.
	for corner: int in [0, 3, 5]:
		var copy := positions.size()
		positions.append(positions[corner] + Vector3(1e-7, 0, 0))
		for i in tris.size():
			if tris[i] == corner:
				tris[i] = copy
				break
	# Five triangles twice (the last five of the cube: untouched by the splits or not, as they are).
	for t in range(7, 12):
		tris.append_array([tris[t * 3], tris[t * 3 + 1], tris[t * 3 + 2]])
	# A fin on the cube's edge between corners 6 and 7 (an edge of two triangles that are neither
	# split nor doubled): a third triangle on it.
	var tip := positions.size()
	positions.append((positions[6] + positions[7]) * 0.5 + Vector3(0, 4 * MM, 4 * MM))
	tris.append_array([6, 7, tip])
	# 30 tiny triangles (0.05 mm) floating 0.01 mm above the top face.
	for i in 30:
		var at := Vector3(-8 * MM + (i % 6) * 3 * MM, 10 * MM + 0.01 * MM, -6 * MM + int(i / 6.0) * 3 * MM)
		var base := positions.size()
		positions.append_array([at, at + Vector3(0, 0, 0.05 * MM), at + Vector3(0.05 * MM, 0, 0)])
		tris.append_array([base, base + 1, base + 2])
	var fixture := _pack(positions, tris)
	var census := edge_census(fixture.indices)
	fixture["expected"] = {"triangles": 48, "duplicate": 5, "degenerate": 0, "tiny": 30, "fin": 1, "split": 3,
		"boundary_edges": census.boundary, "non_manifold_edges": census.non_manifold}
	return fixture


## Two 20 mm cubes in one mesh (groups g0 and g1), the second moved by offset from the first.
## "first" and "second" are the two cubes as fixtures of their own (group names "a" and "b").
static func two_cubes(offset: Vector3) -> Dictionary:
	var a := _cube_ccw(20 * MM, Vector3.ZERO)
	var b := _cube_ccw(20 * MM, offset)
	var positions: PackedVector3Array = a.positions.duplicate()
	positions.append_array(b.positions)
	var tris: PackedInt32Array = a.indices.duplicate()
	for id in b.indices:
		tris.append(id + 8)
	var groups := PackedInt32Array()
	groups.resize(24)
	for t in range(12, 24):
		groups[t] = 1
	var fixture := _pack(positions, tris, groups, PackedStringArray(["g0", "g1"]))
	fixture["first"] = _pack(a.positions, a.indices, PackedInt32Array(), PackedStringArray(["a"]))
	fixture["second"] = _pack(b.positions, b.indices, PackedInt32Array(), PackedStringArray(["b"]))
	return fixture


## A flat 40 x 40 mm plate of 32 x 32 squares in the XZ plane, facing +Y, open (128 open edges).
static func open_plate() -> Dictionary:
	var n := 32
	var positions := PackedVector3Array()
	for j in n + 1:
		for i in n + 1:
			positions.append(Vector3(-20 * MM + 40 * MM * i / n, 0, -20 * MM + 40 * MM * j / n))
	var tris := PackedInt32Array()
	for j in n:
		for i in n:
			var a := j * (n + 1) + i
			var b := a + 1
			var c := a + n + 1
			var d := c + 1
			tris.append_array([a, c, b, b, c, d])
	return _pack(positions, tris)


## Icosphere s = 3, r = 50 mm, with every triangle whose middle has z < 0 turned inside-out.
static func flipped_half() -> Dictionary:
	var ball := icosphere(0.05, 3)
	var indices: PackedInt32Array = ball.indices
	var positions: PackedVector3Array = ball.positions
	for i in range(0, indices.size(), 3):
		if (positions[indices[i]] + positions[indices[i + 1]] + positions[indices[i + 2]]).z < 0.0:
			var keep := indices[i + 1]
			indices[i + 1] = indices[i + 2]
			indices[i + 2] = keep
	ball.indices = indices
	return ball


## Two icospheres (s = 3, r = 20 mm) with centres 20 mm apart, in one mesh with no boolean: they
## cross each other. "first" and "second" are the two spheres as fixtures of their own.
static func self_crossing() -> Dictionary:
	var a := icosphere(0.02, 3, Vector3.ZERO)
	var b := icosphere(0.02, 3, Vector3(0.02, 0, 0))
	var positions: PackedVector3Array = a.positions.duplicate()
	positions.append_array(b.positions)
	var indices: PackedInt32Array = a.indices.duplicate()
	var base: int = a.positions.size()
	for id in b.indices:
		indices.append(id + base)
	var fixture := {"positions": positions, "indices": indices, "groups": _zeros(indices.size() / 3), "names": PackedStringArray(["g0"])}
	fixture["first"] = a
	fixture["second"] = b
	return fixture


## A closed cube of `size` with n x n squares on each face, welded: 12 n^2 triangles (n = 290:
## 1,009,200) and 6 n^2 + 2 vertices. For timing.
static func large_grid(n: int, size := 0.1) -> Dictionary:
	var positions := PackedVector3Array()
	positions.resize(6 * n * n + 2)
	var step := size / n
	for k: int in [0, n]:
		for j in n + 1:
			for i in n + 1:
				positions[_grid_index(n, i, j, k)] = Vector3(i * step, j * step, k * step)
	for k in range(1, n):
		for i in n + 1:
			positions[_grid_index(n, i, 0, k)] = Vector3(i * step, 0.0, k * step)
			positions[_grid_index(n, i, n, k)] = Vector3(i * step, n * step, k * step)
		for j in range(1, n):
			positions[_grid_index(n, 0, j, k)] = Vector3(0.0, j * step, k * step)
			positions[_grid_index(n, n, j, k)] = Vector3(n * step, j * step, k * step)
	var tris := PackedInt32Array()
	tris.resize(36 * n * n)
	var w := 0
	# Each face: two in-face axes (u, v) with u x v along the fixed axis, so (0,0) (1,0) (1,1) (0,1)
	# runs counter-clockwise seen from the high side.
	for face in 6:
		var axis := face >> 1
		var high := (face & 1) == 1
		var f := n if high else 0
		for b in n:
			for a in n:
				var q0 := 0
				var q1 := 0
				var q2 := 0
				var q3 := 0
				if axis == 0:  # x fixed: (u, v) = (y, z)
					q0 = _grid_index(n, f, a, b)
					q1 = _grid_index(n, f, a + 1, b)
					q2 = _grid_index(n, f, a + 1, b + 1)
					q3 = _grid_index(n, f, a, b + 1)
				elif axis == 1:  # y fixed: (u, v) = (z, x)
					q0 = _grid_index(n, b, f, a)
					q1 = _grid_index(n, b, f, a + 1)
					q2 = _grid_index(n, b + 1, f, a + 1)
					q3 = _grid_index(n, b + 1, f, a)
				else:  # z fixed: (u, v) = (x, y)
					q0 = _grid_index(n, a, b, f)
					q1 = _grid_index(n, a + 1, b, f)
					q2 = _grid_index(n, a + 1, b + 1, f)
					q3 = _grid_index(n, a, b + 1, f)
				# Counter-clockwise seen from outside: as it is on the high side, turned on the low side.
				tris[w] = q0
				tris[w + 1] = q1 if high else q2
				tris[w + 2] = q2 if high else q1
				tris[w + 3] = q0
				tris[w + 4] = q2 if high else q3
				tris[w + 5] = q3 if high else q2
				w += 6
	return _pack(positions, tris)


## A 20 mm cube with a 10 mm cube-shaped void at its centre: the void's 12 triangles face into the
## void, so the volume is 7,000 mm3 (24 triangles, 2 closed components). With island, a 4 mm cube
## sits inside the void too (36 triangles, 3 components, 7,064 mm3). "void_triangles" lists the
## void's triangles.
static func hollow_cube(island: bool) -> Dictionary:
	var outer := _cube_ccw(20 * MM, Vector3.ZERO)
	var inner := _cube_ccw(10 * MM, Vector3.ZERO)
	var positions: PackedVector3Array = outer.positions.duplicate()
	positions.append_array(inner.positions)
	var tris: PackedInt32Array = outer.indices.duplicate()
	var void_triangles := PackedInt32Array()
	for i in range(0, 36, 3):
		void_triangles.append(tris.size() / 3)
		tris.append_array([inner.indices[i] + 8, inner.indices[i + 2] + 8, inner.indices[i + 1] + 8])
	if island:
		var core := _cube_ccw(4 * MM, Vector3.ZERO)
		positions.append_array(core.positions)
		for id in core.indices:
			tris.append(id + 16)
	var fixture := _pack(positions, tris)
	fixture["void_triangles"] = void_triangles
	return fixture


## The fixture with every vertex moved along its normal by Gaussian noise of sigma x its mean edge
## length (seed 20261111).
static func with_noise(fixture: Dictionary, sigma: float) -> Dictionary:
	var positions: PackedVector3Array = fixture.positions.duplicate()
	var indices: PackedInt32Array = fixture.indices
	var normals := PackedVector3Array()
	normals.resize(positions.size())
	var edge_sum := 0.0
	for i in range(0, indices.size(), 3):
		var a := positions[indices[i]]
		var b := positions[indices[i + 1]]
		var c := positions[indices[i + 2]]
		var n := (c - a).cross(b - a)  # Godot winding: clockwise, so this points out
		for k in 3:
			normals[indices[i + k]] += n
		edge_sum += a.distance_to(b) + b.distance_to(c) + c.distance_to(a)
	var mean_edge := edge_sum / maxf(1.0, float(indices.size()))
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261111
	for i in positions.size():
		if normals[i].length_squared() > 0.0:
			positions[i] += normals[i].normalized() * rng.randfn(0.0, 1.0) * sigma * mean_edge
	var noisy := fixture.duplicate()
	noisy["positions"] = positions
	noisy["mean_edge"] = mean_edge
	return noisy


## {"boundary", "non_manifold"}: edges used by one triangle, and by more than two (a plain count,
## the tests' own measure next to CadMesh.check()).
static func edge_census(indices: PackedInt32Array) -> Dictionary:
	var uses := {}
	for i in range(0, indices.size(), 3):
		for k in 3:
			var u := indices[i + k]
			var v := indices[i + (k + 1) % 3]
			if u == v:
				continue
			var key := (mini(u, v) << 32) | maxi(u, v)
			uses[key] = int(uses.get(key, 0)) + 1
	var boundary := 0
	var non_manifold := 0
	for key in uses:
		if uses[key] == 1:
			boundary += 1
		elif uses[key] > 2:
			non_manifold += 1
	return {"boundary": boundary, "non_manifold": non_manifold}


## The fixture's volume (signed, positive when it faces out) and area, in doubles.
static func volume_and_area(fixture: Dictionary) -> Dictionary:
	var positions: PackedVector3Array = fixture.positions
	var indices: PackedInt32Array = fixture.indices
	var volume := 0.0
	var area := 0.0
	for i in range(0, indices.size(), 3):
		# Godot winding (a, c, b) is clockwise: (a, b, c) below is counter-clockwise.
		var a := positions[indices[i]]
		var b := positions[indices[i + 2]]
		var c := positions[indices[i + 1]]
		var ax := float(a.x); var ay := float(a.y); var az := float(a.z)
		var bx := float(b.x); var by := float(b.y); var bz := float(b.z)
		var cx := float(c.x); var cy := float(c.y); var cz := float(c.z)
		volume += (ax * (by * cz - bz * cy) + ay * (bz * cx - bx * cz) + az * (bx * cy - by * cx)) / 6.0
		var ux := bx - ax; var uy := by - ay; var uz := bz - az
		var vx := cx - ax; var vy := cy - ay; var vz := cz - az
		var nx := uy * vz - uz * vy; var ny := uz * vx - ux * vz; var nz := ux * vy - uy * vx
		area += 0.5 * sqrt(nx * nx + ny * ny + nz * nz)
	return {"volume": volume, "area": area}


## Writes the fixture as an STL file (binary, or text with ascii) and returns its path. `path` is a
## file name under user://holo_forge_mesh_fixtures/ (or a full user:// path). Coordinates are
## written times unit_scale (1000: millimeters). header is the binary file's 80-byte header text.
## With normals off the facet normals are written as zero (faster for a million triangles).
static func write_stl(fixture: Dictionary, path: String, unit_scale := 1.0, ascii := false, header := "Holo Forge mesh fixture", normals := true) -> String:
	var full := _path(path)
	var positions: PackedVector3Array = fixture.positions
	var indices: PackedInt32Array = fixture.indices
	var count := indices.size() / 3
	var file := FileAccess.open(full, FileAccess.WRITE)
	if file == null:
		return ""
	if ascii:
		var lines := PackedStringArray(["solid fixture"])
		for i in range(0, indices.size(), 3):
			# Stored clockwise (Godot); STL facets are counter-clockwise.
			var a := positions[indices[i]] * unit_scale
			var b := positions[indices[i + 2]] * unit_scale
			var c := positions[indices[i + 1]] * unit_scale
			var n := (b - a).cross(c - a).normalized()
			lines.append("facet normal %s %s %s" % [_num(n.x), _num(n.y), _num(n.z)])
			lines.append("outer loop")
			for p: Vector3 in [a, b, c]:
				lines.append("vertex %s %s %s" % [_num(p.x), _num(p.y), _num(p.z)])
			lines.append("endloop")
			lines.append("endfacet")
		lines.append("endsolid fixture")
		file.store_string("\n".join(lines) + "\n")
		file.close()
		return full
	var bytes := PackedByteArray()
	bytes.resize(84 + 50 * count)
	var title := header.to_ascii_buffer()
	for i in mini(title.size(), 80):
		bytes[i] = title[i]
	bytes.encode_u32(80, count)
	var at := 84
	for i in range(0, indices.size(), 3):
		var a := positions[indices[i]] * unit_scale
		var b := positions[indices[i + 2]] * unit_scale
		var c := positions[indices[i + 1]] * unit_scale
		if normals:
			var n := (b - a).cross(c - a).normalized()
			bytes.encode_float(at, n.x)
			bytes.encode_float(at + 4, n.y)
			bytes.encode_float(at + 8, n.z)
		bytes.encode_float(at + 12, a.x)
		bytes.encode_float(at + 16, a.y)
		bytes.encode_float(at + 20, a.z)
		bytes.encode_float(at + 24, b.x)
		bytes.encode_float(at + 28, b.y)
		bytes.encode_float(at + 32, b.z)
		bytes.encode_float(at + 36, c.x)
		bytes.encode_float(at + 40, c.y)
		bytes.encode_float(at + 44, c.z)
		at += 50
	file.store_buffer(bytes)
	file.close()
	return full


## Writes the fixture as an OBJ file (one "g" statement per group, in group order) and returns its
## path. Coordinates are written times unit_scale.
static func write_obj(fixture: Dictionary, path: String, unit_scale := 1.0) -> String:
	var full := _path(path)
	var positions: PackedVector3Array = fixture.positions
	var indices: PackedInt32Array = fixture.indices
	var groups: PackedInt32Array = fixture.groups
	var names: PackedStringArray = fixture.names
	var lines := PackedStringArray(["# Holo Forge mesh fixture"])
	for p in positions:
		lines.append("v %s %s %s" % [_num(p.x * unit_scale), _num(p.y * unit_scale), _num(p.z * unit_scale)])
	for g in names.size():
		lines.append("g %s" % names[g])
		for t in groups.size():
			if groups[t] == g:
				# Clockwise (Godot) to counter-clockwise, 1-based.
				lines.append("f %d %d %d" % [indices[t * 3] + 1, indices[t * 3 + 2] + 1, indices[t * 3 + 1] + 1])
	var file := FileAccess.open(full, FileAccess.WRITE)
	if file == null:
		return ""
	file.store_string("\n".join(lines) + "\n")
	file.close()
	return full


## Writes an 8 x 8 black and white checker of size x size pixels as a PNG and returns its path.
static func write_png_checker(path: String, size := 64) -> String:
	var full := _path(path)
	var image := Image.create(size, size, false, Image.FORMAT_RGB8)
	var cell := maxi(1, size / 8)
	for y in size:
		for x in size:
			image.set_pixel(x, y, Color.WHITE if (int(x / cell) + int(y / cell)) % 2 == 0 else Color.BLACK)
	image.save_png(full)
	return full


## Removes a file written by this helper (a name under the fixtures folder, or a full path).
static func remove_file(path: String) -> void:
	var full := _path(path)
	if FileAccess.file_exists(full):
		DirAccess.remove_absolute(full)


# ---------------------------------------------------------------- helpers


static func _path(path: String) -> String:
	var full := path if path.begins_with("user://") else DIR.path_join(path)
	DirAccess.make_dir_recursive_absolute(full.get_base_dir())
	return full


## A float32 as text that reads back to the same float32.
static func _num(value: float) -> String:
	if value == 0.0 or not is_finite(value):
		return "0"
	# Scientific, 10 significant digits (GDScript's format has no %e or %g).
	var exponent := int(floor(log(absf(value)) / log(10.0)))
	return "%.9fe%d" % [value / pow(10.0, exponent), exponent]


static func _zeros(count: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(count)
	return out


## A fixture from counter-clockwise triangles (the usual way to write them down): the indices are
## turned to Godot's clockwise order.
static func _pack(positions: PackedVector3Array, ccw: PackedInt32Array, groups := PackedInt32Array(), names := PackedStringArray()) -> Dictionary:
	var indices := ccw.duplicate()
	for i in range(0, indices.size(), 3):
		var keep := indices[i + 1]
		indices[i + 1] = indices[i + 2]
		indices[i + 2] = keep
	return {"positions": positions, "indices": indices, "groups": groups if not groups.is_empty() else _zeros(indices.size() / 3),
		"names": names if not names.is_empty() else PackedStringArray(["g0"])}


## _pack() without the vertices no triangle uses.
static func _compacted(positions: PackedVector3Array, godot_indices: PackedInt32Array) -> Dictionary:
	var remap := {}
	var kept := PackedVector3Array()
	var indices := PackedInt32Array()
	indices.resize(godot_indices.size())
	for i in godot_indices.size():
		var id := godot_indices[i]
		if not remap.has(id):
			remap[id] = kept.size()
			kept.append(positions[id])
		indices[i] = remap[id]
	return {"positions": kept, "indices": indices, "groups": _zeros(indices.size() / 3), "names": PackedStringArray(["g0"])}


## A cube as {"positions", "indices" (counter-clockwise seen from outside)}: 8 corners, 12 triangles.
static func _cube_ccw(size: float, center: Vector3) -> Dictionary:
	var h := size * 0.5
	var positions := PackedVector3Array()
	for k in 2:
		for j in 2:
			for i in 2:
				positions.append(center + Vector3(-h + size * i, -h + size * j, -h + size * k))
	# Corner id = i + 2 j + 4 k.
	var indices := PackedInt32Array([
		0, 2, 3, 0, 3, 1,  # z-
		4, 5, 7, 4, 7, 6,  # z+
		0, 1, 5, 0, 5, 4,  # y-
		2, 6, 7, 2, 7, 3,  # y+
		0, 4, 6, 0, 6, 2,  # x-
		1, 3, 7, 1, 7, 5,  # x+
	])
	return {"positions": positions, "indices": indices}


## The vertex number of surface point (i, j, k) of an n-cube grid (each 0..n, one of them 0 or n):
## the k = 0 sheet, then one ring of 4 n per middle layer, then the k = n sheet.
static func _grid_index(n: int, i: int, j: int, k: int) -> int:
	var sheet := (n + 1) * (n + 1)
	if k == 0:
		return j * (n + 1) + i
	if k == n:
		return sheet + (n - 1) * 4 * n + j * (n + 1) + i
	var base := sheet + (k - 1) * 4 * n
	if j == 0:
		return base + i
	if i == n:
		return base + n + j
	if j == n:
		return base + 2 * n + (n - i)
	return base + 3 * n + (n - j)


## A kernel shape tessellated into a fixture ("high": deviation = diagonal / detail, angle degrees).
static func _from_shape(shape: RefCounted, detail: float, degrees: float) -> Dictionary:
	if shape == null:
		return {}
	var mesh: RefCounted = ClassDB.instantiate("CadMesh")
	var diagonal: float = shape.bbox().size.length()
	if not mesh.from_shape(shape, diagonal / detail, deg_to_rad(degrees), false, 20.0):
		push_warning("mesh fixture could not be tessellated: " + mesh.get_last_error())
		return {}
	var arrays: Dictionary = mesh.get_arrays()
	return {"positions": arrays.positions, "indices": arrays.indices, "groups": arrays.groups, "names": arrays.group_names, "shape": shape, "mesh": mesh}


# ---------------------------------------------------------------- added for the verifier's findings (2026-11-12)


## A fixture from Godot-order triangles as they are (one group "g0" unless groups are given).
static func raw(positions: PackedVector3Array, godot_indices: PackedInt32Array, groups := PackedInt32Array(), names := PackedStringArray()) -> Dictionary:
	return {"positions": positions, "indices": godot_indices, "groups": groups if not groups.is_empty() else _zeros(godot_indices.size() / 3),
		"names": names if not names.is_empty() else PackedStringArray(["g0"])}


## A closed cube of `size` around `center` (12 triangles, 8 welded corners).
static func cube(size := 0.02, center := Vector3.ZERO) -> Dictionary:
	var c := _cube_ccw(size, center)
	return _pack(c.positions, c.indices)


## The fixture moved by `shift` (a copy).
static func shifted(fixture: Dictionary, shift: Vector3) -> Dictionary:
	var positions: PackedVector3Array = (fixture.positions as PackedVector3Array).duplicate()
	for i in positions.size():
		positions[i] += shift
	var out := fixture.duplicate()
	out["positions"] = positions
	return out


## Several fixtures in one mesh, nothing welded: each keeps its own vertices, also where two of
## them touch. Groups follow one another; names get the number of their first group ("g0_0", "g0_1").
static func joined(list: Array) -> Dictionary:
	var positions := PackedVector3Array()
	var indices := PackedInt32Array()
	var groups := PackedInt32Array()
	var names := PackedStringArray()
	for fixture: Dictionary in list:
		var base := positions.size()
		var group_base := names.size()
		positions.append_array(fixture.positions)
		for i in (fixture.indices as PackedInt32Array):
			indices.append(i + base)
		for g in (fixture.groups as PackedInt32Array):
			groups.append(g + group_base)
		for n in (fixture.names as PackedStringArray):
			names.append("%s_%d" % [n, group_base])
	return {"positions": positions, "indices": indices, "groups": groups, "names": names}


## The fixture with its triangles grouped by the octant their middle lies in (up to 8 groups,
## "o0".."o7"): on a ball the borders between the groups are zigzag lines along the triangles.
static func octant_groups(fixture: Dictionary) -> Dictionary:
	var positions: PackedVector3Array = fixture.positions
	var indices: PackedInt32Array = fixture.indices
	var groups := PackedInt32Array()
	groups.resize(indices.size() / 3)
	var remap := {}
	var names := PackedStringArray()
	for t in groups.size():
		var c := positions[indices[3 * t]] + positions[indices[3 * t + 1]] + positions[indices[3 * t + 2]]
		var octant := (1 if c.x > 0 else 0) | (2 if c.y > 0 else 0) | (4 if c.z > 0 else 0)
		if not remap.has(octant):
			remap[octant] = names.size()
			names.append("o%d" % octant)
		groups[t] = remap[octant]
	var out := fixture.duplicate()
	out["groups"] = groups
	out["names"] = names
	return out


## The side of a cone (radius 5 to 15 mm over 20 mm, 24 x 6 squares, open): no plane, cylinder or sphere.
static func cone_patch() -> Dictionary:
	var positions := PackedVector3Array()
	var n := 24
	var m := 6
	for j in m + 1:
		for i in n + 1:
			var a := TAU * i / n
			var r := 0.005 + 0.01 * j / m
			positions.append(Vector3(cos(a) * r, 0.02 * j / m, sin(a) * r))
	var indices := PackedInt32Array()
	for j in m:
		for i in n:
			var a := j * (n + 1) + i
			indices.append_array([a, a + n + 1, a + 1, a + 1, a + n + 1, a + n + 2])
	return raw(positions, indices)


## A quarter of a torus (30 mm and 10 mm radii, 24 x 12 squares, open): no plane, cylinder or sphere.
static func torus_patch() -> Dictionary:
	var positions := PackedVector3Array()
	var n := 24
	var m := 12
	for j in m + 1:
		for i in n + 1:
			var a := PI * i / n
			var b := PI * j / m
			positions.append(Vector3(cos(a) * (0.03 + 0.01 * cos(b)), 0.01 * sin(b), sin(a) * (0.03 + 0.01 * cos(b))))
	var indices := PackedInt32Array()
	for j in m:
		for i in n:
			var a := j * (n + 1) + i
			indices.append_array([a, a + n + 1, a + 1, a + 1, a + n + 1, a + n + 2])
	return raw(positions, indices)


# --- Fix round 2 (2026-11-13, re-verifier R1): open sheets and bodies that touch themselves ---


## The same triangles facing the other way.
static func flipped(fixture: Dictionary) -> Dictionary:
	var indices: PackedInt32Array = (fixture.indices as PackedInt32Array).duplicate()
	for i in range(0, indices.size(), 3):
		var t := indices[i + 1]
		indices[i + 1] = indices[i + 2]
		indices[i + 2] = t
	var out := fixture.duplicate()
	out["indices"] = indices
	return out


## The fixture with every position passed through `move`.
static func deformed(fixture: Dictionary, move: Callable) -> Dictionary:
	var positions: PackedVector3Array = (fixture.positions as PackedVector3Array).duplicate()
	for i in positions.size():
		positions[i] = move.call(positions[i])
	var out := fixture.duplicate()
	out["positions"] = positions
	return out


## A flat square sheet in the plane y = 0, n x n squares, centred on the origin.
static func grid_plate(size := 0.04, n := 8) -> Dictionary:
	var positions := PackedVector3Array()
	for j in n + 1:
		for i in n + 1:
			positions.append(Vector3(size * (float(i) / n - 0.5), 0, size * (float(j) / n - 0.5)))
	var ccw := PackedInt32Array()
	for j in n:
		for i in n:
			var a := j * (n + 1) + i
			ccw.append_array([a, a + n + 2, a + 1, a, a + n + 1, a + n + 2])
	return _pack(positions, ccw)


## An open tray: a bottom of n x n squares, b wide, at y = 0, and walls up to a rim at y = h
## that is the bottom's outline scaled by k about one bottom corner (so two walls are upright
## and two lean out). Outward facing.
static func tray(b: float, k: float, h: float, n: int) -> Dictionary:
	var positions := PackedVector3Array()
	var ccw := PackedInt32Array()
	for j in n + 1:
		for i in n + 1:
			positions.append(Vector3(b * i / n, 0, b * j / n))
	for j in n:
		for i in n:
			var a := j * (n + 1) + i
			ccw.append_array([a, a + 1, a + n + 2, a, a + n + 2, a + n + 1])
	var ring := []
	for i in n:
		ring.append(i)
	for j in n:
		ring.append(j * (n + 1) + n)
	for i in n:
		ring.append(n * (n + 1) + n - i)
	for j in n:
		ring.append((n - j) * (n + 1))
	var rim := []
	for id: int in ring:
		rim.append(positions.size())
		positions.append(Vector3(positions[id].x * k, h, positions[id].z * k))
	for i in ring.size():
		var next := (i + 1) % ring.size()
		ccw.append_array([ring[i], rim[i], rim[next], ring[i], rim[next], ring[next]])
	var fixture := _pack(positions, ccw)
	if float(volume_and_area(fixture).volume) < 0.0:
		fixture = flipped(fixture)
	return fixture


## An open cone: apex at height h over a base circle of radius r with m corners, open at its base.
static func cone_sheet(r: float, h: float, m := 24) -> Dictionary:
	var positions := PackedVector3Array([Vector3(0, h, 0)])
	for i in m:
		var angle := TAU * i / m
		positions.append(Vector3(r * cos(angle), 0, r * sin(angle)))
	var ccw := PackedInt32Array()
	for i in m:
		ccw.append_array([0, 1 + (i + 1) % m, 1 + i])
	return _pack(positions, ccw)


## The closed surface of a set of unit cells (Vector3i), `size` a cell, welded, outward facing.
static func voxels(cells: Array, size := 0.01) -> Dictionary:
	var have := {}
	for c: Vector3i in cells:
		have[c] = true
	var ids := {}
	var positions := PackedVector3Array()
	var ccw := PackedInt32Array()
	for c: Vector3i in cells:
		for dir: Vector3i in [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0), Vector3i(0, -1, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
			if have.has(c + dir):
				continue
			var u := Vector3i(0, 1, 0) if dir.x != 0 else (Vector3i(0, 0, 1) if dir.y != 0 else Vector3i(1, 0, 0))
			var v := Vector3i(0, 0, 1) if dir.x != 0 else (Vector3i(1, 0, 0) if dir.y != 0 else Vector3i(0, 1, 0))
			var o := c + Vector3i(maxi(dir.x, 0), maxi(dir.y, 0), maxi(dir.z, 0))
			var quad := [o, o + u, o + u + v, o + v]
			if dir.x + dir.y + dir.z < 0:
				quad.reverse()
			var corner := []
			for q: Vector3i in quad:
				if not ids.has(q):
					ids[q] = positions.size()
					positions.append(Vector3(q) * size)
				corner.append(ids[q])
			ccw.append_array([corner[0], corner[1], corner[2], corner[0], corner[2], corner[3]])
	return _pack(positions, ccw)
