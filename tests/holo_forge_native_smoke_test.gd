extends SceneTree
## Holo Forge native kernel smoke test: the editor-only GDExtension loads; OpenCASCADE builds a
## 1x2x3 box with volume 6, cuts a cylinder hole out of it (V = abc - pi r^2 h), fillets an edge,
## tessellates with face and edge ids (a sphere's normals point out at its poles too), and
## round-trips BRep bytes; the planegcs sketch solver turns a rough triangle into an exact 3-4-5
## right triangle with no degrees of freedom left, and reports an over-constrained sketch as
## conflicting. Body edge lines run through the mesh's own nodes (a filleted box and a converted
## cube: curved edges between curved faces), so they never dip behind the facets and draw dotted.
## Stale ~holo_forge_native.dll~RF*.TMP copies are cleared from a library folder, nothing else.
## CadMesh (the Mesh workspace kernel) is registered and reports the versions of pmp-library,
## Manifold, meshoptimizer and Clipper2, after one real call into each library's DLL.
##
## godot --headless --path . --script res://tests/holo_forge_native_smoke_test.gd

var failures: Array[String] = []


func _init() -> void:
	call_deferred("run")


func run() -> void:
	var loaded := ClassDB.class_exists("CadKernel") and ClassDB.class_exists("CadShape") and ClassDB.class_exists("CadSketchSolver") \
		and ClassDB.class_exists("CadSubD") and ClassDB.class_exists("CadMesh")
	_expect(loaded, "The holo_forge GDExtension should register CadKernel, CadShape, CadSketchSolver, CadSubD and CadMesh.")
	if loaded:
		_check_kernel()
		_check_solver()
		_check_subd()
		_check_mesh()
	print("PASS holo_forge_native_smoke: kernel loads, box volume, boolean cut, fillet, tessellation ids, outward normals at sphere poles, edge lines on the mesh nodes, stale library copies cleared, BRep round trip, 3-4-5 sketch solve, conflict report, CadSubD (OpenSubdiv) cube limit point, CadMesh with the pmp, Manifold, meshoptimizer and Clipper2 versions." \
		if failures.is_empty() else "FAIL holo_forge_native_smoke")
	quit(0 if failures.is_empty() else 1)


func _check_kernel() -> void:
	var kernel = ClassDB.instantiate("CadKernel")
	print("HOLO FORGE kernel: ", kernel.version())

	var box = kernel.make_box(Vector3(1, 2, 3))
	_expect(box != null and absf(box.volume() - 6.0) < 1e-9, "A 1x2x3 box should have volume 6 (got %s)." % (box.volume() if box else "null"))
	_expect(box != null and box.face_count() == 6 and box.edge_count() == 12 and box.vertex_count() == 8,
		"A box should have 6 faces, 12 edges and 8 vertices.")
	_expect(box != null and box.bbox().size.is_equal_approx(Vector3(1, 2, 3)), "The box bounds should be 1x2x3 (got %s)." % (box.bbox() if box else "null"))

	# Drill a through hole: radius 0.25 along Y through the 1x3 face.
	var drill = kernel.make_cylinder(0.25, 2.0, Vector3(0.5, 0.0, 1.5), Vector3.UP)
	var holed = kernel.boolean(box, drill, 1)
	var expected := 6.0 - PI * 0.25 * 0.25 * 2.0
	_expect(holed != null and absf(holed.volume() - expected) < 1e-6,
		"Box minus hole should have volume %f (got %s)." % [expected, (holed.volume() if holed else "null")])

	# A 0.1 fillet along one 3-long edge removes (1 - pi/4) r^2 L.
	var tess: Dictionary = box.tessellate(0.01, 0.2)
	var edge_id := _long_edge(tess)
	var rounded = kernel.fillet_edges(box, PackedInt32Array([edge_id]), 0.1) if edge_id >= 0 else null
	var fillet_expected := 6.0 - (1.0 - PI / 4.0) * 0.01 * 3.0
	_expect(rounded != null and absf(rounded.volume() - fillet_expected) < 1e-6,
		"Filleting a 3-long edge with r=0.1 should leave volume %f (got %s)." % [fillet_expected, (rounded.volume() if rounded else "null")])

	_expect(tess.has("positions") and (tess["indices"] as PackedInt32Array).size() == (tess["face_ids"] as PackedInt32Array).size() * 3,
		"Tessellation should give one face id per triangle.")
	var face_set := {}
	for id in tess.get("face_ids", PackedInt32Array()):
		face_set[id] = true
	_expect(face_set.size() == 6, "Every box face should appear in the tessellation (got %d)." % face_set.size())
	_expect(_winding_matches_normals(tess), "Triangles should wind clockwise (Godot front faces) around their normals.")

	# A sphere's poles have no surface normal of their own: every vertex normal still points out.
	var sphere = kernel.make_sphere(0.013, Vector3(0.045, 0.013, 0.0))
	var round_tess: Dictionary = sphere.tessellate(0.0002, 0.3) if sphere != null else {}
	var inward := 0
	var round_positions: PackedVector3Array = round_tess.get("positions", PackedVector3Array())
	var round_normals: PackedVector3Array = round_tess.get("normals", PackedVector3Array())
	for i in round_positions.size():
		if round_normals[i].normalized().dot((round_positions[i] - Vector3(0.045, 0.013, 0.0)).normalized()) < 0.99:
			inward += 1
	_expect(not round_positions.is_empty() and inward == 0, "Every sphere vertex normal (poles too) should point outward (%d of %d don't)." % [inward, round_positions.size()])

	# Edge lines lie on the drawn facets: every edge point is one of the mesh's own nodes.
	if rounded != null:
		var off := _edge_points_off_mesh(rounded.tessellate(0.002, 0.3))
		_expect(off == 0, "The filleted box's edge lines should run through its mesh nodes (%d points off)." % off)
	var cube_subd = ClassDB.instantiate("CadSubD")
	if cube_subd.set_cage({"positions": PackedFloat64Array([-1, -1, -1, 1, -1, -1, 1, 1, -1, -1, 1, -1, -1, -1, 1, 1, -1, 1, 1, 1, 1, -1, 1, 1]),
			"face_counts": PackedInt32Array([4, 4, 4, 4, 4, 4]),
			"face_indices": PackedInt32Array([0, 3, 2, 1, 4, 5, 6, 7, 0, 1, 5, 4, 1, 2, 6, 5, 2, 3, 7, 6, 3, 0, 4, 7])}):
		var converted: Array = cube_subd.to_shapes({"isolation": 4})
		var cube_tess: Dictionary = (converted[0] as RefCounted).tessellate(0.01, 0.3) if converted.size() == 1 else {}
		var cube_off := _edge_points_off_mesh(cube_tess)
		_expect(not cube_tess.is_empty() and (cube_tess.edge_points as PackedVector3Array).size() > 0 and cube_off == 0,
			"The converted cube's curved edge lines should run through its mesh nodes (%d points off)." % cube_off)
	_check_library_leftovers()

	var bytes: PackedByteArray = holed.to_brep_bytes() if holed else PackedByteArray()
	var copy = ClassDB.instantiate("CadShape")
	_expect(bytes.size() > 0 and copy.load_brep_bytes(bytes) and absf(copy.volume() - expected) < 1e-9,
		"BRep bytes should load back the same solid.")


func _check_solver() -> void:
	var solver = ClassDB.instantiate("CadSketchSolver")
	var a: int = solver.add_point(Vector2(0, 0))
	var b: int = solver.add_point(Vector2(3.4, 0.3))
	var c: int = solver.add_point(Vector2(0.2, 3.7))
	var ab: int = solver.add_line(a, b)
	var ac: int = solver.add_line(a, c)
	var bc: int = solver.add_line(b, c)
	solver.set_point_fixed(a, true)
	solver.add_constraint("horizontal", [Vector2i(1, ab)])
	solver.add_constraint("perpendicular", [Vector2i(1, ab), Vector2i(1, ac)])
	solver.add_constraint("distance", [Vector2i(0, a), Vector2i(0, b)], 4.0)
	var height: int = solver.add_constraint("distance", [Vector2i(0, a), Vector2i(0, c)], 3.0)
	var status: int = solver.solve()
	_expect(status == 0 or status == 1, "The triangle sketch should solve (status %d)." % status)
	var hyp: float = solver.get_point(b).distance_to(solver.get_point(c))
	_expect(absf(hyp - 5.0) < 1e-6, "The solved triangle should have a hypotenuse of 5 (got %f)." % hyp)
	_expect(solver.get_dof() == 0, "A fixed point, horizontal, perpendicular and two lengths should leave 0 DOF (got %d)." % solver.get_dof())

	# Changing a dimension re-solves to the new size.
	solver.set_constraint_value(height, 4.0)
	solver.solve()
	_expect(absf(solver.get_point(a).distance_to(solver.get_point(c)) - 4.0) < 1e-6, "Editing a dimension should resize the sketch.")

	# Over-constraining the hypotenuse to a different length is reported as a conflict.
	var bad: int = solver.add_constraint("distance", [Vector2i(0, b), Vector2i(0, c)], 7.0)
	solver.solve()
	var conflicts: PackedInt32Array = solver.get_conflicting()
	_expect(conflicts.has(bad), "An impossible hypotenuse should be reported as conflicting (got %s)." % conflicts)
	print("HOLO FORGE solver: 3-4-5 triangle solved, dof 0, conflict tags %s (bc line %d)" % [conflicts, bc])


## CadSubD (OpenSubdiv, linked statically): the cube cage's corner limit point is (0.5, 0.5, 0.5).
func _check_subd() -> void:
	var subd = ClassDB.instantiate("CadSubD")
	var cage := {"positions": PackedFloat64Array([-1, -1, -1, 1, -1, -1, 1, 1, -1, -1, 1, -1, -1, -1, 1, 1, -1, 1, 1, 1, 1, -1, 1, 1]),
		"face_counts": PackedInt32Array([4, 4, 4, 4, 4, 4]),
		"face_indices": PackedInt32Array([0, 3, 2, 1, 4, 5, 6, 7, 0, 1, 5, 4, 1, 2, 6, 5, 2, 3, 7, 6, 3, 0, 4, 7])}
	_expect(subd.set_cage(cage), "CadSubD should load the cube cage (%s)." % subd.get_last_error())
	var limit: PackedFloat64Array = subd.limit_points().get("positions", PackedFloat64Array())
	_expect(limit.size() == 24 and absf(limit[18] - 0.5) < 1e-9 and absf(limit[19] - 0.5) < 1e-9 and absf(limit[20] - 0.5) < 1e-9,
		"The cube cage's corner should have its limit at (0.5, 0.5, 0.5) (got %s)." % [limit])
	print("HOLO FORGE subd: OpenSubdiv ", subd.osd_version())


## CadMesh (pmp.dll, manifold.dll, meshoptimizer.dll; Clipper2 is inside manifold.dll): the four
## library versions, each library called once. (pmp.dll needs VCOMP140.DLL, the MSVC OpenMP
## runtime, which Windows keeps in System32.)
func _check_mesh() -> void:
	var mesh: RefCounted = ClassDB.instantiate("CadMesh")
	_expect(mesh != null and mesh.has_method("is_mesh") and mesh.is_mesh(), "CadMesh should answer is_mesh() with true.")
	if mesh == null:
		return
	# Phase 8 contact (work order C5.1): the library has CadMesh.overlap.
	_expect(ClassDB.class_has_method("CadMesh", "overlap"), "CadMesh should have overlap() (Phase 8 contact); the loaded native library is older.")
	# Phase 8 fix round 1: moves given in doubles (xform64).
	_expect(ClassDB.class_has_method("CadMesh", "transformed64") and ClassDB.class_has_method("CadKernel", "transform_shape64"),
		"CadMesh should have transformed64() and CadKernel transform_shape64() (Phase 8 fix round 1); the loaded native library is older.")
	var versions: Dictionary = mesh.library_versions()
	_expect(mesh.get_last_error() == "", "Every mesh library should answer its test call (%s)." % mesh.get_last_error())
	var expected := {"pmp": "3.0.0", "manifold": "3.5.4", "meshoptimizer": "1.3", "clipper2": "2.0.1"}
	_expect(versions.size() == expected.size(), "library_versions() should name the four mesh libraries (got %s)." % [versions])
	for library: String in expected:
		_expect(str(versions.get(library, "")) == expected[library],
			"%s should be version %s (got '%s')." % [library, expected[library], versions.get(library, "")])
	print("HOLO FORGE mesh: pmp-library %s (vcpkg port version), Manifold %s, meshoptimizer %s, Clipper2 %s (inside manifold.dll); pmp.dll uses VCOMP140.DLL"
		% [versions.get("pmp", "?"), versions.get("manifold", "?"), versions.get("meshoptimizer", "?"), versions.get("clipper2", "?")])


## Edge points that are not mesh nodes (exactly) of the tessellation.
func _edge_points_off_mesh(tess: Dictionary) -> int:
	var nodes := {}
	for p in tess.get("positions", PackedVector3Array()):
		nodes[p] = true
	var off := 0
	for p in tess.get("edge_points", PackedVector3Array()):
		if not nodes.has(p):
			off += 1
	return off


## The plugin clears stale library copies (left when another editor held the copy it replaced):
## only names like ~holo_forge_native.dll~RF<hex>.TMP go.
func _check_library_leftovers() -> void:
	var dir := OS.get_user_data_dir().path_join("holo_forge_library_leftovers_test")
	DirAccess.make_dir_recursive_absolute(dir)
	var names := ["~holo_forge_native.dll~RF1a2b3c.TMP", "~holo_forge_native.dll~RFff00.tmp", "holo_forge_native.dll", "~holo_forge_native.dll", "other~RF12.TMP"]
	for name in names:
		var file := FileAccess.open(dir.path_join(name), FileAccess.WRITE)
		file.store_string("x")
		file.close()
	FileAccess.set_hidden_attribute(dir.path_join(names[0]), true)
	var removed: int = load("res://addons/holo_forge/plugin.gd").clear_library_leftovers(dir)
	var access := DirAccess.open(dir)
	access.include_hidden = true
	var left := Array(access.get_files())
	left.sort()
	_expect(removed == 2 and left == ["holo_forge_native.dll", "other~RF12.TMP", "~holo_forge_native.dll"], "Only the stale ~RF copies should go (removed %d, left %s)." % [removed, left])
	for name in left:
		DirAccess.remove_absolute(dir.path_join(name))
	DirAccess.remove_absolute(dir)


## The edge id of one 3-long box edge, found from the edge segments in the tessellation.
func _long_edge(tess: Dictionary) -> int:
	var points: PackedVector3Array = tess.get("edge_points", PackedVector3Array())
	var ids: PackedInt32Array = tess.get("edge_ids", PackedInt32Array())
	var lengths := {}
	for i in ids.size():
		lengths[ids[i]] = float(lengths.get(ids[i], 0.0)) + points[i * 2].distance_to(points[i * 2 + 1])
	for id in lengths:
		if absf(float(lengths[id]) - 3.0) < 1e-6:
			return id
	return -1


func _winding_matches_normals(tess: Dictionary) -> bool:
	var positions: PackedVector3Array = tess.get("positions", PackedVector3Array())
	var normals: PackedVector3Array = tess.get("normals", PackedVector3Array())
	var indices: PackedInt32Array = tess.get("indices", PackedInt32Array())
	if indices.is_empty():
		return false
	for t in range(0, indices.size(), 3):
		var p0 := positions[indices[t]]
		var p1 := positions[indices[t + 1]]
		var p2 := positions[indices[t + 2]]
		# Godot's front faces are clockwise when seen from the front, so (p2-p0)x(p1-p0) points out.
		if (p2 - p0).cross(p1 - p0).dot(normals[indices[t]]) <= 0.0:
			return false
	return true


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error(message)
		print("FAIL: ", message)
