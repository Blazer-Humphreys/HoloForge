extends SceneTree
## Holo Forge Mesh workspace, native class CadMesh (Phase 7 work order, 5.1).
##
## Part 1 (Stage N1: data, IO, queries), checks 1 to 14: set_arrays and its validation, winding,
## the HFM1 blob (round trip, byte layout, CRC), STL (text, binary, a binary file whose header
## starts with "solid", a padded one) and OBJ (quads, a concave pentagon, groups), check() on
## clean, open, dirty, self-crossing and hollow meshes (the nesting rule: a void is not
## inside-out), volume and area, ray_hit, section, Tessellate (from_shape), distance_to and the
## triangle cap. Then the CadShape subset mesh bodies answer (bounds, groups as faces, mass
## properties), the display tessellation's contract, the selection queries, transformed(), and
## timing ratios for read_stl, tessellate(), ray_hit and check() on a million triangles.
## (HOLO_FORGE_TIMING_SLOWDOWN=3 fails all four timing checks: checked on 2026-11-11.)
##
## Part 2 (Stage N2: pmp and meshoptimizer ops) and part 3 (Stage N3: Manifold and voxel ops)
## are appended by those stages.
##
## godot --headless --path . --script res://tests/holo_forge_mesh_native_test.gd

const FIXTURES := preload("res://tests/holo_forge_mesh_fixtures.gd")
const TIMING := preload("res://tests/holo_forge_timing.gd")

const MM := 0.001

## Timing ratio limits (work order 5.7): 2 x the ratio measured on the dev machine (Ryzen 9
## 5900HX) on 2026-11-11 against a sphere make + tessellate calibration of about 3.4 ms, on
## large_grid(290) (1,009,200 triangles). Each op runs on a fresh CadMesh, so the time holds
## set_arrays (or the file read) and every structure the op builds.
const LIMITS := {
	"read_stl_1m": 78.0,       # measured 166-175 ms, ratio 36-40 (limit of the work order: 1.5 s)
	"tessellate_1m": 112.0,    # measured 236-251 ms with set_arrays (11 ms), ratio 54-58 (limit 0.8 s)
	"check_1m": 350.0,         # measured 772-805 ms with set_arrays, ratio 171-178 (limit 1.5 s): about 250 ms
	                           # of counts and components, 120 ms hierarchy, 420 ms self-intersection test
	"ray_hit_1m": 0.0011,      # measured 0.0019-0.0023 ms a ray, ratio 0.00043-0.00055 (limit 4 ms)
}

var failures: Array[String] = []
var checked: Array[String] = []
var kernel: RefCounted


func _init() -> void:
	call_deferred("run")


func run() -> void:
	if not ClassDB.class_exists("CadMesh") or not ClassDB.class_exists("CadKernel"):
		print("NOTE: CadMesh is not registered (the holo_forge native DLL is missing): native mesh checks skipped.")
		print("PASS holo_forge_mesh_native: skipped, the native library is not loaded.")
		quit(0)
		return
	kernel = ClassDB.instantiate("CadKernel")
	_check_set_arrays()
	_check_validation()
	_check_winding()
	_check_blob()
	_check_stl()
	_check_obj()
	_check_check()
	_check_volume_area()
	_check_ray()
	_check_section()
	_check_from_shape()
	_check_distance()
	_check_shape_subset()
	_check_tessellation()
	_check_selection()
	_check_transformed()
	_check_timing()
	print(("PASS holo_forge_mesh_native: " + "; ".join(checked) + ".") if failures.is_empty() else "FAIL holo_forge_mesh_native")
	quit(0 if failures.is_empty() else 1)


func _new() -> RefCounted:
	return ClassDB.instantiate("CadMesh")


func _mesh(fixture: Dictionary) -> RefCounted:
	var mesh := _new()
	_expect(mesh.set_arrays(fixture.positions, fixture.indices, fixture.groups, fixture.names, "godot"), "A fixture should load (%s)." % mesh.get_last_error())
	return mesh


# ---------------------------------------------------------------- 1, 2, 14


func _check_set_arrays() -> void:
	var ball := FIXTURES.icosphere(0.05, 4)
	var mesh := _new()
	_expect(mesh.is_null() and mesh.triangle_count() == 0, "A new CadMesh should be empty.")
	var ok: bool = mesh.set_arrays(ball.positions, ball.indices)
	_expect(ok and mesh.get_last_error() == "", "set_arrays should take an icosphere (%s)." % mesh.get_last_error())
	_expect(mesh.triangle_count() == 5120 and mesh.vertex_count() == 2562 and mesh.group_count() == 1,
		"Icosphere s4 should have 5,120 triangles, 2,562 vertices and 1 group (got %d, %d, %d)." % [mesh.triangle_count(), mesh.vertex_count(), mesh.group_count()])
	_expect(mesh.is_mesh() and not mesh.is_null() and mesh.shape_type() == "MESH" and mesh.get_face_names() == PackedStringArray(["g0"]),
		"A mesh body should say is_mesh, MESH and name its only group g0 (got %s)." % [mesh.get_face_names()])
	var back: Dictionary = mesh.get_arrays()
	_expect(back.positions == ball.positions and back.indices == ball.indices and back.groups == ball.groups and back.group_names == ball.names,
		"get_arrays should give back what set_arrays took (Godot order).")
	# Groups without names are named g0, g1, ...
	var grouped := _new()
	var groups := PackedInt32Array()
	groups.resize(5120)
	for t in range(2560, 5120):
		groups[t] = 1
	_expect(grouped.set_arrays(ball.positions, ball.indices, groups) and grouped.get_face_names() == PackedStringArray(["g0", "g1"]) \
		and grouped.group_triangles(1).size() == 2560 and grouped.find_face("g1") == 1 and grouped.find_face("nope") == -1,
		"Two unnamed groups should be g0 and g1 with 2,560 triangles each (%s)." % grouped.get_last_error())
	checked.append("set_arrays (icosphere s4: 5,120 triangles, 2,562 vertices, 1 group; arrays back unchanged; unnamed groups g0, g1)")


func _check_validation() -> void:
	var ball := FIXTURES.icosphere(0.05, 2)
	var cases := []
	var bad_index: PackedInt32Array = ball.indices.duplicate()
	bad_index[7] = 9999
	cases.append(["an index out of range", ball.positions, bad_index, ball.groups, ball.names, "vertex 9,999"])
	var negative: PackedInt32Array = ball.indices.duplicate()
	negative[7] = -1
	cases.append(["a negative index", ball.positions, negative, ball.groups, ball.names, "vertex -1"])
	var nan: PackedVector3Array = ball.positions.duplicate()
	nan[5] = Vector3(0, NAN, 0)
	cases.append(["a NaN position", nan, ball.indices, ball.groups, ball.names, "finite"])
	var inf: PackedVector3Array = ball.positions.duplicate()
	inf[5] = Vector3(INF, 0, 0)
	cases.append(["an infinite position", inf, ball.indices, ball.groups, ball.names, "finite"])
	cases.append(["a wrong groups length", ball.positions, ball.indices, PackedInt32Array([0, 0, 0]), ball.names, "group ids"])
	var out_group: PackedInt32Array = ball.groups.duplicate()
	out_group[3] = 4
	cases.append(["a group id out of range", ball.positions, ball.indices, out_group, ball.names, "face group 4"])
	cases.append(["an index count not divisible by 3", ball.positions, PackedInt32Array([0, 1, 2, 3]), PackedInt32Array(), PackedStringArray(), "multiple of 3"])
	cases.append(["an empty group name", ball.positions, ball.indices, ball.groups, PackedStringArray([""]), "1 to 64 bytes"])
	cases.append(["a 65-byte group name", ball.positions, ball.indices, ball.groups, PackedStringArray(["x".repeat(65)]), "1 to 64 bytes"])
	cases.append(["two groups of one name", ball.positions, ball.indices, ball.groups, PackedStringArray(["a", "a"]), "both named"])
	for c: Array in cases:
		var mesh := _new()
		var ok: bool = mesh.set_arrays(c[1], c[2], c[3], c[4], "godot")
		_expect(not ok and mesh.get_last_error().contains(c[5]) and mesh.is_null(),
			"set_arrays with %s should be refused with an error naming it ('%s'; got ok=%s, '%s')." % [c[0], c[5], ok, mesh.get_last_error()])
	var twice := _mesh(ball)
	_expect(not twice.set_arrays(ball.positions, ball.indices) and twice.get_last_error().contains("cannot change") and twice.triangle_count() == 320,
		"A second set_arrays should be refused and leave the mesh as it was ('%s')." % twice.get_last_error())
	_expect(not twice.from_blob(twice.to_blob()) and twice.get_last_error().contains("cannot change"), "from_blob on a made mesh should be refused.")
	# 14: one triangle over the cap is refused from the sizes alone (nothing is copied first).
	var many := PackedInt32Array()
	many.resize(2000001 * 3)
	var capped := _new()
	var started := Time.get_ticks_usec()
	var took_it: bool = capped.set_arrays(PackedVector3Array([Vector3.ZERO, Vector3.RIGHT, Vector3.UP]), many)
	var ms := (Time.get_ticks_usec() - started) / 1000.0
	_expect(not took_it and capped.get_last_error().contains("2,000,001") and capped.get_last_error().contains("2,000,000") and capped.is_null(),
		"2,000,001 triangles should be refused naming the 2,000,000 cap ('%s')." % capped.get_last_error())
	_expect(ms < 20.0, "The cap refusal should come from the array sizes, before any copy (took %.2f ms)." % ms)
	checked.append("validation (%d bad inputs and a second set_arrays refused by name; 2,000,001 triangles refused in %.2f ms naming 2,000,000)" % [cases.size(), ms])


# ---------------------------------------------------------------- 3


func _check_winding() -> void:
	# The same orientation test on CadShape.tessellate of a kernel box and on CadMesh.tessellate:
	# Godot's clockwise triangles give a negative a . (b x c) sum.
	var box: RefCounted = kernel.make_box(Vector3(0.02, 0.02, 0.02))
	var shape_sum := _signed_sum(box.tessellate(0.001, 0.3))
	var cube := _mesh(FIXTURES.two_cubes(Vector3(0.03, 0, 0)).first)
	var mesh_sum := _signed_sum(cube.tessellate())
	var from_box := _new()
	_expect(from_box.from_shape(box, 0.002, 0.3, false, 20.0), "A box should tessellate into a mesh (%s)." % from_box.get_last_error())
	var from_sum := _signed_sum(from_box.tessellate())
	_expect(shape_sum < 0.0 and mesh_sum < 0.0 and from_sum < 0.0 and absf(mesh_sum - shape_sum) < 1e-9 and absf(from_sum - shape_sum) < 1e-9,
		"CadMesh.tessellate should wind like CadShape.tessellate (signed sums %s, %s, %s)." % [shape_sum, mesh_sum, from_sum])
	# Stored counter-clockwise: the volume is positive either way in.
	var ccw := _new()
	var arrays: Dictionary = cube.get_arrays()
	var turned: PackedInt32Array = arrays.indices.duplicate()
	for i in range(0, turned.size(), 3):
		var keep := turned[i + 1]
		turned[i + 1] = turned[i + 2]
		turned[i + 2] = keep
	_expect(ccw.set_arrays(arrays.positions, turned, PackedInt32Array(), PackedStringArray(), "ccw") and absf(ccw.volume() - 8e-6) < 1e-12 \
		and absf(cube.volume() - 8e-6) < 1e-12 and ccw.digest() != "" and ccw.get_arrays().indices == arrays.indices,
		"The same cube given clockwise (godot) and counter-clockwise (ccw) should be one mesh of +8e-6 m3 (%s, %s)." % [cube.volume(), ccw.volume()])
	checked.append("winding (tessellate() is clockwise like CadShape.tessellate; godot and ccw input give the same mesh)")


func _signed_sum(tess: Dictionary) -> float:
	var positions: PackedVector3Array = tess.get("positions", PackedVector3Array())
	var indices: PackedInt32Array = tess.get("indices", PackedInt32Array())
	var sum := 0.0
	for i in range(0, indices.size(), 3):
		sum += positions[indices[i]].dot(positions[indices[i + 1]].cross(positions[indices[i + 2]])) / 6.0
	return sum


# ---------------------------------------------------------------- 4, 5


func _check_blob() -> void:
	var groups := FIXTURES.two_cubes(Vector3(0.03, 0, 0))
	var mesh := _mesh(groups)
	var blob: PackedByteArray = mesh.to_blob()
	var copy := _new()
	_expect(copy.from_blob(blob), "A blob should read back (%s)." % copy.get_last_error())
	var a: Dictionary = mesh.get_arrays()
	var b: Dictionary = copy.get_arrays()
	_expect(a.positions.to_byte_array() == b.positions.to_byte_array() and a.indices == b.indices and a.groups == b.groups and a.group_names == b.group_names,
		"A blob round trip should give the same arrays bit for bit.")
	_expect(mesh.digest() == copy.digest() and mesh.digest().length() == 16 and copy.to_blob() == blob, "A blob round trip should keep the digest (%s, %s)." % [mesh.digest(), copy.digest()])
	_expect(_mesh(FIXTURES.two_cubes(Vector3(0.031, 0, 0))).digest() != mesh.digest(), "Other content should give another digest.")
	# One flipped byte: refused by the CRC.
	var damaged := blob.duplicate()
	damaged[40] = damaged[40] ^ 0x10
	var refused := _new()
	_expect(not refused.from_blob(damaged) and refused.get_last_error().contains("CRC") and refused.is_null(),
		"A blob with one flipped byte should be refused by its CRC ('%s')." % refused.get_last_error())
	var magic := blob.duplicate()
	magic[0] = 0x58
	var short := blob.slice(0, blob.size() - 5)
	var flagged := blob.duplicate()
	flagged.encode_u32(8, 2)
	var versioned := blob.duplicate()
	versioned.encode_u32(4, 7)
	for c: Array in [[magic, "magic"], [short, "size"], [flagged, "flags"], [versioned, "version"], [PackedByteArray(), "magic"]]:
		var m := _new()
		_expect(not m.from_blob(c[0]) and m.get_last_error().contains(c[1]), "A blob with a wrong %s should be refused naming it ('%s')." % [c[1], m.get_last_error()])
	# 5: the layout of a one-triangle mesh, byte for byte.
	var one := _new()
	var p := PackedVector3Array([Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 2, 0)])
	one.set_arrays(p, PackedInt32Array([0, 1, 2]))
	var bytes: PackedByteArray = one.to_blob()
	var layout := bytes.size() == 24 + 36 + 12 + 4 + 2 + 2 + 4
	if layout:
		layout = bytes.slice(0, 4).get_string_from_ascii() == "HFM1" and bytes.decode_u32(4) == 1 and bytes.decode_u32(8) == 0 and bytes.decode_u32(12) == 3 \
			and bytes.decode_u32(16) == 1 and bytes.decode_u32(20) == 1
		for v in 3:
			layout = layout and bytes.decode_float(24 + v * 12) == p[v].x and bytes.decode_float(28 + v * 12) == p[v].y and bytes.decode_float(32 + v * 12) == p[v].z
		# Stored counter-clockwise: Godot's (0, 1, 2) is (0, 2, 1).
		layout = layout and bytes.decode_u32(60) == 0 and bytes.decode_u32(64) == 2 and bytes.decode_u32(68) == 1 and bytes.decode_u32(72) == 0
		layout = layout and bytes.decode_u16(76) == 2 and bytes.slice(78, 80).get_string_from_ascii() == "g0" and bytes.decode_u32(80) == _crc32(bytes.slice(0, 80))
	_expect(layout, "A one-triangle blob should be 84 bytes laid out as HFM1, 1, 0, V, T, G, positions, triangles, groups, names, CRC-32 (got %d bytes: %s)." % [bytes.size(), bytes.hex_encode()])
	checked.append("HFM1 blob (round trip bit for bit with the same digest, one flipped byte refused by the CRC, wrong magic/size/flags/version refused, 84-byte layout of one triangle with an IEEE CRC-32)")


## CRC-32 (IEEE 802.3), bit by bit: the test's own.
func _crc32(bytes: PackedByteArray) -> int:
	var crc := 0xFFFFFFFF
	for byte in bytes:
		crc ^= byte
		for k in 8:
			crc = (crc >> 1) ^ 0xEDB88320 if crc & 1 else crc >> 1
	return crc ^ 0xFFFFFFFF


# ---------------------------------------------------------------- 6, 7


func _check_stl() -> void:
	var text := _new()
	_expect(text.read_stl("res://tests/holo_forge/fixtures/cube_10mm.stl", 0.001), "The text STL cube should read (%s)." % text.get_last_error())
	_expect(_is_cube(text, 0.01), "The text STL cube should be closed with 12 triangles and 8 welded vertices, 10 mm wide (%d, %d, %s)." % [text.triangle_count(), text.vertex_count(), text.bbox()])
	var arrays: Dictionary = text.get_arrays()
	var fixture := {"positions": arrays.positions, "indices": arrays.indices, "groups": arrays.groups, "names": arrays.group_names}
	var results := []
	var files := {
		"binary": FIXTURES.write_stl(fixture, "native_cube_binary.stl", 1000.0),
		"binary with a header that starts with solid": FIXTURES.write_stl(fixture, "native_cube_solid_header.stl", 1000.0, false, "solid cube_10mm made by a binary writer"),
		"text": FIXTURES.write_stl(fixture, "native_cube_text.stl", 1000.0, true),
	}
	# A padded binary file: extra bytes after the last triangle.
	var padded := FileAccess.get_file_as_bytes(files["binary"])
	padded.append_array(PackedByteArray([0, 0, 0, 0, 0, 0, 0]))
	var padded_path := FIXTURES.DIR.path_join("native_cube_padded.stl")
	var out := FileAccess.open(padded_path, FileAccess.WRITE)
	out.store_buffer(padded)
	out.close()
	files["binary with padding"] = padded_path
	for label: String in files:
		var mesh := _new()
		var ok: bool = mesh.read_stl(files[label], 0.001)
		_expect(ok and _is_cube(mesh, 0.01) and mesh.get_arrays().positions == arrays.positions,
			"The %s STL cube should read as the same cube (%s; %d triangles, %d vertices)." % [label, mesh.get_last_error(), mesh.triangle_count(), mesh.vertex_count()])
		results.append(label)
	_expect(FileAccess.get_file_as_bytes(files["binary"]).size() == 84 + 50 * 12 and FileAccess.get_file_as_bytes(files["text"]).slice(0, 5).get_string_from_ascii() == "solid",
		"The written fixtures should be a 684-byte binary file and a text file.")
	var missing := _new()
	_expect(not missing.read_stl("user://holo_forge_mesh_fixtures/not_there.stl", 0.001) and missing.get_last_error().contains("could not be opened"),
		"A missing STL should be refused ('%s')." % missing.get_last_error())
	var empty_path := FIXTURES.DIR.path_join("native_empty.stl")
	out = FileAccess.open(empty_path, FileAccess.WRITE)
	out.store_string("solid nothing\nendsolid nothing\n")
	out.close()
	var empty := _new()
	_expect(not empty.read_stl(empty_path, 0.001) and empty.get_last_error().contains("no triangles"), "An STL without facets should be refused ('%s')." % empty.get_last_error())
	var scaled := _new()
	_expect(not scaled.read_stl(files["binary"], 0.0) and scaled.get_last_error().contains("scale"), "A zero scale should be refused ('%s')." % scaled.get_last_error())
	for path: String in files.values() + [empty_path]:
		FIXTURES.remove_file(path)
	checked.append("read_stl (text fixture, binary, binary with a 'solid' header, padded binary: each a closed 10 mm cube of 12 triangles and 8 welded vertices; missing, empty and zero-scale refused)")


func _is_cube(mesh: RefCounted, size: float) -> bool:
	if mesh.triangle_count() != 12 or mesh.vertex_count() != 8:
		return false
	var report: Dictionary = mesh.check()
	return report.get("closed", false) and report.get("manifold", false) and report.get("oriented", false) \
		and mesh.bbox().size.is_equal_approx(Vector3(size, size, size)) and absf(mesh.volume() - size * size * size) < 1e-6 * size * size * size


func _check_obj() -> void:
	var cube := _new()
	_expect(cube.read_obj("res://tests/holo_forge/fixtures/cube_2cm.obj", 0.01), "The OBJ cube should read (%s)." % cube.get_last_error())
	_expect(_is_cube(cube, 0.02) and cube.get_face_names() == PackedStringArray(["g0"]),
		"The OBJ cube (quads, / forms, negative indices) should be a closed 2 cm cube of 12 triangles in one group g0 (%d triangles, %s)." % [cube.triangle_count(), cube.get_face_names()])
	# A concave pentagon (an arrow tail), then a second group holding a quad given with negative indices.
	var path := FIXTURES.DIR.path_join("native_pentagon.obj")
	DirAccess.make_dir_recursive_absolute(FIXTURES.DIR)
	var out := FileAccess.open(path, FileAccess.WRITE)
	out.store_string("# concave pentagon\r\nv 0 0 0\r\nv 2 0 0\nv 2 2 0\nv 1 0.5 0\nv 0 2 0\nvn 0 0 1\ng unused\no first\nf 1//1 2//1 3//1 4//1 5//1\n" \
		+ "v 0 0 1\nv 1 0 1\nv 1 1 1\nv 0 1 1\ng second\nf -4 -3 -2 -1\n")
	out.close()
	var mesh := _new()
	_expect(mesh.read_obj(path, 1.0), "The pentagon OBJ should read (%s)." % mesh.get_last_error())
	var arrays: Dictionary = mesh.get_arrays()
	var first: PackedInt32Array = mesh.group_triangles(0)
	var area := 0.0
	var positive := first.size() == 3
	for t in first:
		# Godot order (a, c, b): counter-clockwise is (a, b, c) = (i, i + 2, i + 1).
		var a: Vector3 = arrays.positions[arrays.indices[t * 3]]
		var b: Vector3 = arrays.positions[arrays.indices[t * 3 + 2]]
		var c: Vector3 = arrays.positions[arrays.indices[t * 3 + 1]]
		var n := (b - a).cross(c - a)
		positive = positive and n.z > 1e-9 and absf(n.x) < 1e-9 and absf(n.y) < 1e-9
		area += 0.5 * n.z
	# Shoelace area of (0,0) (2,0) (2,2) (1,0.5) (0,2): 2.5.
	_expect(positive and absf(area - 2.5) < 1e-6, "A concave pentagon should become 3 triangles of positive area that add up to 2.5 (got %d, area %.6f)." % [first.size(), area])
	_expect(mesh.get_face_names() == PackedStringArray(["g0", "g1"]) and mesh.group_triangles(1).size() == 2 and mesh.triangle_count() == 5 and mesh.vertex_count() == 9,
		"Groups with faces should be g0, g1 in file order, a statement without faces none (%s; %d triangles, %d vertices)." % [mesh.get_face_names(), mesh.triangle_count(), mesh.vertex_count()])
	var bad_path := FIXTURES.DIR.path_join("native_bad.obj")
	out = FileAccess.open(bad_path, FileAccess.WRITE)
	out.store_string("v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 7\n")
	out.close()
	var bad := _new()
	_expect(not bad.read_obj(bad_path, 1.0) and bad.get_last_error().contains("line 4") and bad.get_last_error().contains("vertex 7"),
		"An OBJ face that points past the vertices should be refused naming the line ('%s')." % bad.get_last_error())
	FIXTURES.remove_file(path)
	FIXTURES.remove_file(bad_path)
	checked.append("read_obj (2 cm cube of quads with / forms and negative indices: 12 triangles; a concave pentagon as 3 positive triangles of the exact area; o/g groups in file order; a bad face refused by line)")


# ---------------------------------------------------------------- 8


func _check_check() -> void:
	var ball := _mesh(FIXTURES.icosphere(0.05, 4))
	var r: Dictionary = ball.check()
	_expect(r.closed and r.manifold and r.oriented and r.genus == 0 and r.boundary_edges == 0 and r.boundary_loops == 0 and r.non_manifold_edges == 0 \
		and r.non_manifold_vertices == 0 and r.degenerate_triangles == 0 and r.duplicate_triangles == 0 and r.unused_vertices == 0 and r.components == 1 \
		and r.closed_components == 1 and r.inverted_components == 0 and r.self_intersections == 0 and r.self_intersection_pairs.is_empty(),
		"An icosphere should be closed, manifold, oriented, genus 0, clean (%s)." % [r])
	_expect(ball.solid_count() == 1 and not ball.is_surface(), "An icosphere should be one solid, not a surface.")
	var keys := ["closed", "manifold", "oriented", "boundary_edges", "boundary_loops", "non_manifold_edges", "non_manifold_vertices", "degenerate_triangles", "duplicate_triangles",
		"unused_vertices", "components", "closed_components", "inverted_components", "genus", "self_intersections", "self_intersection_pairs"]
	var has_all := r.size() == keys.size()
	for key: String in keys:
		has_all = has_all and r.has(key)
	_expect(has_all, "check() should give the 16 keys of the contract (%s)." % [r.keys()])

	var plate := _mesh(FIXTURES.open_plate())
	r = plate.check()
	var loops: Array = plate.boundary_loops()
	_expect(not r.closed and r.manifold and r.oriented and r.boundary_loops == 1 and r.boundary_edges == 128 and r.genus == -1 and r.components == 1 and r.closed_components == 0,
		"The open plate should have 1 loop of 128 open edges (%s)." % [r])
	_expect(loops.size() == 1 and loops[0].id == 0 and loops[0].edges == 128 and loops[0].vertices.size() == 128 and loops[0].points.size() == 128 \
		and loops[0].vertices[0] == 0 and absf(loops[0].length - 0.16) < 1e-6 and loops[0].planar_error < 1e-9,
		"boundary_loops() of the plate should be one flat loop of 128 edges, 160 mm long, from vertex 0 (%s)." % [loops[0] if loops.size() == 1 else loops.size()])
	_expect(plate.is_surface() and plate.solid_count() == 0 and plate.volume() == 0.0, "An open plate should be a surface with no solids and no volume.")

	var debris_fixture := FIXTURES.cube_debris()
	var debris := _mesh(debris_fixture)
	var expected: Dictionary = debris_fixture.expected
	r = debris.check()
	_expect(debris.triangle_count() == expected.triangles and r.degenerate_triangles == expected.degenerate and r.duplicate_triangles == expected.duplicate \
		and r.non_manifold_edges == expected.non_manifold_edges and r.boundary_edges == expected.boundary_edges and not r.closed and not r.manifold \
		and r.components == 32 and r.unused_vertices == 0,
		"cube_debris should count as built: %s (got %s)." % [expected, r])
	# A triangle of no area and a vertex nothing uses are counted too.
	var sliver := _new()
	sliver.set_arrays(PackedVector3Array([Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(2, 0, 0), Vector3(5, 5, 5)]), PackedInt32Array([0, 1, 2, 0, 3, 1, 0, 2, 2]))
	r = sliver.check()
	_expect(r.degenerate_triangles == 2 and r.unused_vertices == 1 and r.components == 1, "A flat triangle, one that names a vertex twice and a spare vertex should be counted (%s)." % [r])

	var crossing := _mesh(FIXTURES.self_crossing())
	r = crossing.check()
	_expect(r.self_intersections > 0 and r.self_intersection_pairs.size() >= 2 and r.self_intersection_pairs.size() <= 128 and r.closed and r.components == 2 \
		and r.closed_components == 2 and r.inverted_components == 0 and r.oriented and crossing.solid_count() == 2,
		"Two crossing spheres should have self-intersections and stay two solid shells, neither inside-out (%s)." % [r])
	var pair_ok := true
	for i in range(0, r.self_intersection_pairs.size(), 2):
		# One triangle of each sphere (1,280 triangles each).
		pair_ok = pair_ok and r.self_intersection_pairs[i] < 1280 and r.self_intersection_pairs[i + 1] >= 1280
	_expect(pair_ok, "Every crossing pair should join one triangle of each sphere.")
	var crossings: int = r.self_intersections

	# The nesting rule: a void faces inward and is not inside-out.
	var hollow_fixture := FIXTURES.hollow_cube(false)
	var hollow := _mesh(hollow_fixture)
	r = hollow.check()
	_expect(r.closed and r.closed_components == 2 and r.components == 2 and r.inverted_components == 0 and r.oriented and r.self_intersections == 0 and hollow.solid_count() == 1,
		"A hollow cube should be closed with 2 closed components, none inside-out, one solid (%s, solids %d)." % [r, hollow.solid_count()])
	_expect(absf(hollow.volume() - 7000 * MM * MM * MM) < 1e-6 * 7000 * MM * MM * MM, "A hollow cube's volume should be 7,000 mm3 (got %s)." % (hollow.volume() / (MM * MM * MM)))
	var flipped: Dictionary = hollow_fixture.duplicate()
	var indices: PackedInt32Array = hollow_fixture.indices.duplicate()
	for t: int in hollow_fixture.void_triangles:
		var keep := indices[t * 3 + 1]
		indices[t * 3 + 1] = indices[t * 3 + 2]
		indices[t * 3 + 2] = keep
	flipped["indices"] = indices
	var wrong := _mesh(flipped)
	r = wrong.check()
	_expect(r.closed and r.closed_components == 2 and r.inverted_components == 1 and not r.oriented and wrong.solid_count() == 1,
		"The same cube with its void turned outward should have 1 inside-out component (%s)." % [r])
	var island := _mesh(FIXTURES.hollow_cube(true))
	r = island.check()
	_expect(r.closed and r.closed_components == 3 and r.inverted_components == 0 and r.oriented and island.solid_count() == 2 \
		and absf(island.volume() - 7064 * MM * MM * MM) < 1e-6 * 7064 * MM * MM * MM,
		"A hollow cube with an island should have 3 closed components, none inside-out, 2 solids, 7,064 mm3 (%s, solids %d, %s mm3)." % [r, island.solid_count(), island.volume() / (MM * MM * MM)])
	# A lone inside-out shell is inverted; half-flipped triangles are not oriented but have no depth.
	var cube: Dictionary = FIXTURES.two_cubes(Vector3(0.03, 0, 0)).first
	var inside_out := cube.duplicate()
	indices = cube.indices.duplicate()
	for i in range(0, indices.size(), 3):
		var keep := indices[i + 1]
		indices[i + 1] = indices[i + 2]
		indices[i + 2] = keep
	inside_out["indices"] = indices
	var turned := _mesh(inside_out)
	r = turned.check()
	_expect(r.closed and r.inverted_components == 1 and not r.oriented and turned.volume() < 0.0, "An inside-out cube should be 1 inverted component with a negative volume (%s)." % [r])
	r = _mesh(FIXTURES.flipped_half()).check()
	_expect(r.closed and r.manifold and not r.oriented and r.closed_components == 1 and r.inverted_components == 0, "A half-flipped sphere should be closed but not oriented (%s)." % [r])
	# Five holes: five loops, ordered by their smallest vertex, that hold every open edge.
	var blob := _mesh(FIXTURES.holed_blob())
	r = blob.check()
	loops = blob.boundary_loops()
	var loop_edges := 0
	var ordered := loops.size() == 5
	for i in loops.size():
		loop_edges += loops[i].edges
		ordered = ordered and loops[i].id == i and loops[i].vertices.size() == loops[i].edges and loops[i].length > 0.0 \
			and (i == 0 or loops[i - 1].vertices[0] < loops[i].vertices[0])
		for v: int in loops[i].vertices:
			ordered = ordered and v >= loops[i].vertices[0]
	_expect(not r.closed and r.boundary_loops == 5 and r.components == 1 and ordered and loop_edges == r.boundary_edges and r.self_intersections == 0,
		"The holed blob should have 5 loops in a stable order that hold all %d open edges (%d loops, %d edges)." % [r.boundary_edges, loops.size(), loop_edges])
	# An empty mesh answers everything with nothing.
	var nothing := _new()
	r = nothing.check()
	_expect(not r.closed and r.components == 0 and r.genus == -1 and r.self_intersections == 0 and nothing.volume() == 0.0 and nothing.area() == 0.0 and nothing.bbox() == AABB() \
		and nothing.boundary_loops().is_empty() and nothing.section(Vector3.ZERO, Vector3.UP).is_empty() and not nothing.ray_hit(Vector3.ZERO, Vector3.UP).hit \
		and nothing.mass_properties().is_empty() and nothing.solid_count() == 0 and not nothing.is_surface() and nothing.to_blob().size() == 28 and nothing.digest().length() == 16,
		"An empty mesh should answer every query with nothing (%s)." % [r])
	checked.append("check() (icosphere clean, genus 0; plate 1 loop of 128 open edges; cube_debris %d duplicate, %d non-manifold, %d open edges as built; crossing spheres %d crossings and still 2 solids; hollow cube 2 closed components, 0 inside-out, 1 solid, 7,000 mm3; void turned out: 1 inside-out; island: 2 solids, 7,064 mm3; holed blob 5 loops; empty mesh)" \
		% [expected.duplicate, expected.non_manifold_edges, expected.boundary_edges, crossings])


# ---------------------------------------------------------------- 9, 10, 11


func _check_volume_area() -> void:
	var fixture := FIXTURES.icosphere(0.05, 5)
	var mesh := _mesh(fixture)
	var exact := FIXTURES.volume_and_area(fixture)
	_expect(mesh.triangle_count() == 20480 and absf(mesh.volume() - exact.volume) < 1e-6 * exact.volume and absf(mesh.area() - exact.area) < 1e-6 * exact.area,
		"Icosphere s5 volume and area should match the polyhedron's to 1e-6 (%s against %s, %s against %s)." % [mesh.volume(), exact.volume, mesh.area(), exact.area])
	# And both are near the sphere's (inscribed polyhedron: a little under).
	var sphere := 4.0 / 3.0 * PI * pow(0.05, 3)
	_expect(mesh.volume() < sphere and mesh.volume() > 0.995 * sphere, "The icosphere's volume should be just under the sphere's.")
	checked.append("volume and area (icosphere s5 within 1e-6 of the polyhedron summed in GDScript: %s mm3, %s mm2)" % [mesh.volume() / pow(MM, 3), mesh.area() / pow(MM, 2)])


func _check_ray() -> void:
	var mesh := _mesh(FIXTURES.icosphere(0.05, 4))
	var hit: Dictionary = mesh.ray_hit(Vector3(1, 0, 0), Vector3(-1, 0, 0))
	_expect(hit.get("hit", false) and absf(hit.distance - (1.0 - hit.point.x)) < 1e-6 and hit.normal.dot(Vector3(1, 0, 0)) > 0.99 and absf(hit.point.x - 0.05) < 1e-4 \
		and hit.triangle >= 0 and hit.triangle < 5120 and hit.group == 0,
		"A ray from (1, 0, 0) toward -X should hit the sphere at x = 0.05 with an outward normal (%s)." % [hit])
	_expect(not mesh.ray_hit(Vector3(1, 0, 0), Vector3(1, 0, 0)).hit and not mesh.ray_hit(Vector3(1, 0, 0), Vector3(-1, 0, 0), 0.5).hit \
		and mesh.ray_hit(Vector3(1, 0, 0), Vector3(-1, 0, 0), 0.96).hit and not mesh.ray_hit(Vector3(1, 1, 0), Vector3(-1, 0, 0)).hit,
		"Rays that point away, stop short or pass by should miss; one that reaches should hit.")
	# From inside: the back face counts, with the triangle's own outward normal.
	var inside: Dictionary = mesh.ray_hit(Vector3.ZERO, Vector3(0, 3, 0))
	_expect(inside.hit and absf(inside.distance - inside.point.y) < 1e-6 and inside.normal.y > 0.99, "A ray from inside should hit the back of the surface (%s)." % [inside])
	checked.append("ray_hit (distance = 1 - x within 1e-6, outward normal, misses, back faces)")


func _check_section() -> void:
	var fixture := FIXTURES.icosphere(0.05, 4)
	var mesh := _mesh(fixture)
	var lines: Array = mesh.section(Vector3.ZERO, Vector3(0, 0, 1))
	var theta := _largest_edge_angle(fixture)
	var ok: bool = lines.size() == 1 and lines[0].closed and lines[0].points.size() >= 16
	var low := INF
	var high := 0.0
	var turn := 0.0
	if lines.size() == 1:
		var points: PackedVector3Array = lines[0].points
		for i in points.size():
			var p := points[i]
			var radius := Vector2(p.x, p.y).length()
			low = minf(low, radius)
			high = maxf(high, radius)
			ok = ok and absf(p.z) <= 1e-6
			var q := points[(i + 1) % points.size()]
			turn += Vector2(p.x, p.y).angle_to(Vector2(q.x, q.y))
	_expect(ok and low >= 0.05 * cos(theta / 2.0) - 1e-7 and high <= 0.05 + 1e-7,
		"The section of the icosphere at z = 0 should be one closed line on the plane with radii between r cos(theta / 2) and r (%d lines, radii %.6f..%.6f, limit %.6f)." \
		% [lines.size(), low, high, 0.05 * cos(theta / 2.0)])
	_expect(absf(turn - TAU) < 1e-3, "A solid's section should run counter-clockwise seen from the normal's tip (turned %.4f)." % turn)
	# Off-centre: a smaller circle; past the sphere: nothing; an open plate: an open line.
	var small: Array = mesh.section(Vector3(0, 0, 0.03), Vector3(0, 0, 2))
	_expect(small.size() == 1 and small[0].closed and absf(Vector2(small[0].points[0].x, small[0].points[0].y).length() - 0.04) < 5e-4, "A section at z = 30 mm should be a circle of about 40 mm radius.")
	_expect(mesh.section(Vector3(0, 0, 0.06), Vector3(0, 0, 1)).is_empty() and mesh.section(Vector3.ZERO, Vector3.ZERO).is_empty(), "A plane that misses the body, or has no normal, should cut nothing.")
	var plate: Array = _mesh(FIXTURES.open_plate()).section(Vector3(0.001, 0, 0), Vector3(1, 0, 0))
	_expect(plate.size() == 1 and not plate[0].closed and absf(plate[0].points[0].distance_to(plate[0].points[plate[0].points.size() - 1]) - 0.04) < 1e-6,
		"A cut across the open plate should be one open line 40 mm long (%s)." % [plate.size()])
	var two: Array = _mesh(FIXTURES.two_cubes(Vector3(0.03, 0, 0))).section(Vector3.ZERO, Vector3(0, 1, 0))
	_expect(two.size() == 2 and two[0].closed and two[1].closed, "A cut through two cubes should be two closed lines (%d)." % two.size())
	checked.append("section (icosphere at z = 0: one closed counter-clockwise line of %d points on the plane, radii within the chord bound; smaller circle off-centre; nothing past the body; open line on an open plate; two loops for two cubes)" % (lines[0].points.size() if lines.size() == 1 else 0))


## The largest angle (seen from the centre) between the ends of an edge of a centred sphere fixture.
func _largest_edge_angle(fixture: Dictionary) -> float:
	var positions: PackedVector3Array = fixture.positions
	var indices: PackedInt32Array = fixture.indices
	var largest := 0.0
	for i in range(0, indices.size(), 3):
		for k in 3:
			largest = maxf(largest, positions[indices[i + k]].angle_to(positions[indices[i + (k + 1) % 3]]))
	return largest


# ---------------------------------------------------------------- 12, 13


func _check_from_shape() -> void:
	var box: RefCounted = kernel.make_box(Vector3(0.02, 0.02, 0.02))
	var mesh := _new()
	var ok: bool = mesh.from_shape(box, 0.002, deg_to_rad(15.0), false, 20.0)
	_expect(ok and mesh.group_count() == 6 and mesh.get_face_names() == box.get_face_names() and mesh.triangle_count() == 12 and mesh.vertex_count() == 8,
		"A tessellated box should have 6 groups named like its faces, 12 triangles and 8 welded vertices (%s; %s against %s; %d, %d)." \
		% [mesh.get_last_error(), mesh.get_face_names(), box.get_face_names(), mesh.triangle_count(), mesh.vertex_count()])
	var report: Dictionary = mesh.get_last_report()
	var r: Dictionary = mesh.check()
	_expect(r.get("closed", false) and r.manifold and r.oriented and absf(mesh.volume() - 8e-6) < 1e-9, "The tessellated box should be closed with a volume of 8e-6 m3 (%s, %s)." % [r, mesh.volume()])
	_expect(report.get("op", "") == "tessellate" and report.get("checks", {}).get("boundary", "") == "ok" and report.get("checks", {}).get("volume", "") == "ok" and report.output.triangles == 12,
		"from_shape should leave a report with its checks (%s)." % [report])
	for g in 6:
		var info: Dictionary = mesh.face_info(g)
		_expect(info.type == "plane" and info.planar and absf(info.area - 4e-4) < 1e-9 and info.triangles == 2 and info.normal.is_equal_approx(box.face_info(g).normal),
			"Group %d of the box should be a flat face of 400 mm2 with the B-rep face's normal (%s)." % [g, info])
	# The body's own display mesh is not replaced by the mesh Tessellate makes.
	var before: int = box.tessellate(0.01, 0.5).indices.size()
	var fine := _new()
	var sphere: RefCounted = kernel.make_sphere(0.01, Vector3.ZERO)
	var coarse: int = sphere.tessellate(0.001, 0.5).indices.size()
	_expect(fine.from_shape(sphere, 0.00001, deg_to_rad(4.0), false, 20.0), "A sphere should tessellate (%s)." % fine.get_last_error())
	_expect(sphere.tessellate(0.001, 0.5).indices.size() == coarse and box.tessellate(0.01, 0.5).indices.size() == before and fine.triangle_count() * 3 > coarse * 4,
		"Tessellate should leave the body's display mesh alone (%d triangles before and %d after; the mesh body has %d)." % [coarse / 3, sphere.tessellate(0.001, 0.5).indices.size() / 3, fine.triangle_count()])
	r = fine.check()
	var exact := 4.0 / 3.0 * PI * 1e-6
	_expect(r.get("closed", false) and r.manifold and r.oriented and r.genus == 0 and absf(fine.volume() - exact) < 0.01 * exact and fine.group_count() == sphere.face_count(),
		"A tessellated sphere should be closed, genus 0, within 1 %% of its volume (%s, %s against %s)." % [r, fine.volume(), exact])
	# Ranges are refused by name, and a second call is refused.
	for c: Array in [[0.002, deg_to_rad(60.0), "Normal Deviation"], [0.002, deg_to_rad(0.5), "Normal Deviation"], [0.01, 0.2, "Surface Deviation"], [1e-9, 0.2, "Surface Deviation"]]:
		var m := _new()
		_expect(not m.from_shape(box, c[0], c[1], false, 20.0) and m.get_last_error().contains(c[2]) and m.get_last_error().contains("must be between") and m.is_null(),
			"from_shape with linear %s, angular %s should be refused naming %s ('%s')." % [c[0], c[1], c[2], m.get_last_error()])
	var none := _new()
	_expect(not none.from_shape(null, 0.002, 0.2, false, 20.0) and none.get_last_error() != "", "from_shape without a body should be refused.")
	_expect(not mesh.from_shape(box, 0.002, 0.2, false, 20.0) and mesh.get_last_error().contains("cannot change"), "from_shape on a made mesh should be refused.")
	# A setting that would make far more than 2,000,000 triangles is refused before meshing.
	var huge := _new()
	var started := Time.get_ticks_msec()
	var took: bool = huge.from_shape(kernel.make_sphere(10.0, Vector3.ZERO), 1e-6, deg_to_rad(1.0), false, 20.0)
	var refusal_ms := Time.get_ticks_msec() - started
	_expect(not took and huge.get_last_error().contains("Tessellate would make about") and huge.get_last_error().contains("lower the Refinement") and refusal_ms < 1000,
		"A 10 m sphere at 0.001 mm should be refused at once by its triangle count ('%s', %d ms)." % [huge.get_last_error(), refusal_ms])
	# A setting that would run for most of a minute inside one face is refused by its time, at once.
	var slow := _new()
	started = Time.get_ticks_msec()
	took = slow.from_shape(kernel.make_sphere(0.05, Vector3.ZERO), 1e-6, deg_to_rad(2.0), false, 20.0)
	var slow_ms := Time.get_ticks_msec() - started
	_expect(not took and slow.get_last_error().contains("Tessellate would take about") and slow.get_last_error().contains("limit 20 s") and slow_ms < 200,
		"A 50 mm sphere at 0.001 mm (about 500,000 triangles on one face, 27 s) should be refused at once by its time ('%s', %d ms)." % [slow.get_last_error(), slow_ms])
	# Relative deviation (a fraction of each edge's size).
	var by_size := _new()
	_expect(by_size.from_shape(kernel.make_sphere(0.05, Vector3.ZERO), 0.01, deg_to_rad(10.0), true, 20.0) and by_size.check().closed and by_size.triangle_count() > 500,
		"A sphere should tessellate with a relative deviation (%s)." % by_size.get_last_error())
	# Long face names are shortened the same way every time, to at most 64 bytes.
	var long_name := "extrude12:side(sketch4:line7)|fillet3:g(extrude12:side(sketch4:line8)|extrude12:cap_end)#2"
	var short_name: String = mesh.group_name_for(long_name)
	_expect(short_name.to_utf8_buffer().size() <= 64 and short_name == _new().group_name_for(long_name) and short_name != mesh.group_name_for(long_name + "x") \
		and mesh.group_name_for("x+") == "x+" and short_name.begins_with("extrude12:side(sketch4:line7)"),
		"group_name_for should keep short names and shorten long ones the same way every time ('%s')." % short_name)
	# The L-bracket fixture: one group per B-rep face, closed.
	var bracket := FIXTURES.l_bracket()
	_expect(not bracket.is_empty(), "The L-bracket fixture should build.")
	if not bracket.is_empty():
		var faces: int = bracket.shape.face_count()
		r = bracket.mesh.check()
		_expect((faces == 9 or faces == 10) and bracket.mesh.group_count() == faces and r.get("closed", false) and r.manifold and r.genus == 1 \
			and absf(bracket.mesh.volume() - bracket.shape.volume()) < 0.001 * bracket.shape.volume(),
			"The L-bracket should tessellate into one group per face (9 or 10), closed, genus 1, with its volume (%d faces, %d groups, %s)." % [faces, bracket.mesh.group_count(), r])
		checked.append("from_shape (box: 6 groups named like its faces, 12 triangles, closed, 8e-6 m3; sphere closed within 1 %%; the body's display mesh untouched; ranges refused by name, a huge count in %d ms and a slow setting in %d ms; relative deviation; long names shortened; L-bracket %d groups, %d triangles, genus 1)" \
			% [refusal_ms, slow_ms, faces, bracket.mesh.triangle_count()])


func _check_distance() -> void:
	var s4_fixture := FIXTURES.icosphere(0.05, 4)
	var s4 := _mesh(s4_fixture)
	var s5 := _mesh(FIXTURES.icosphere(0.05, 5))
	var same: Dictionary = s4.distance_to(s4, 20000, 20.0)
	_expect(same.get("max", 1.0) <= 1e-9 and same.samples == 20000 and not same.timed_out and same.mean <= 1e-9 and same.rms <= 1e-9,
		"A mesh should be at distance 0 from itself (%s; %s)." % [same, s4.get_last_error()])
	# From the finer sphere to the coarser one: the sagitta of the coarse sphere's longest edge.
	var theta := _largest_edge_angle(s4_fixture)
	var sagitta := 0.05 * (1.0 - cos(theta / 2.0))
	var d: Dictionary = s5.distance_to(s4, 20000, 20.0)
	_expect(absf(d.get("max", 0.0) - sagitta) < 0.1 * sagitta and d.samples == 20000 and d.mean > 0.0 and d.mean < d.rms and d.rms < d.max and not d.timed_out,
		"Icosphere s5 should be within 10 %% of the s4 sagitta %s from s4 (%s)." % [sagitta, d])
	_expect(absf(d.max_point.length() - 0.05) < 1e-4, "The farthest sample should be a point on the fine sphere (%s)." % [d.max_point])
	var again: Dictionary = s5.distance_to(s4, 20000, 20.0)
	_expect(again.max == d.max and again.mean == d.mean, "The sampled distance should be the same on every run (fixed seed).")
	var fewer: Dictionary = s5.distance_to(s4, 500, 20.0)
	_expect(fewer.samples == 500 and fewer.max <= d.max + 1e-12, "Fewer samples than vertices should take that many vertices.")
	var empty: Dictionary = s5.distance_to(_new(), 100, 1.0)
	_expect(empty.is_empty() and s5.get_last_error() != "", "The distance to an empty mesh should be refused.")
	checked.append("distance_to (a mesh to itself 0; icosphere s5 to s4 max %s mm against the sagitta %s mm; repeatable; refused on an empty mesh)" % [d.max / MM, sagitta / MM])


# ---------------------------------------------------------------- the CadShape subset, display, selection


func _check_shape_subset() -> void:
	var plate := _mesh(FIXTURES.open_plate())
	var info: Dictionary = plate.face_info(0)
	_expect(info.type == "plane" and info.planar and info.normal.is_equal_approx(Vector3.UP) and absf(info.area - 0.0016) < 1e-9 and info.triangles == 2048 \
		and info.point.length() < 1e-6 and info.edges == PackedInt32Array() and plate.face_info(5).is_empty() and plate.face_info(-1).is_empty(),
		"The plate's group should be a plane facing +Y of 1,600 mm2 around the origin (%s)." % [info])
	_expect(plate.face_count() == 1 and plate.edge_count() == 0 and plate.get_edge_names().is_empty() and plate.edge_info(0).is_empty() and plate.vertex_count() == 33 * 33 \
		and is_same(plate.copy(), plate) and plate.bbox().size.is_equal_approx(Vector3(0.04, 0, 0.04)) and plate.memory_bytes() > 2048 * 16,
		"The plate should answer the CadShape calls a body gets (faces, no edges, vertices, copy() itself, bounds).")
	var props: Dictionary = plate.mass_properties()
	_expect(props.volume == 0.0 and props.mass == 0.0 and props.has("warning") and absf(props.area - 0.0016) < 1e-9 and props.center.length() < 1e-6 \
		and plate.center_of_mass().length() < 1e-6,
		"An open plate should have no volume or mass, a warning, and its surface's centre (%s)." % [props])
	var ball := _mesh(FIXTURES.icosphere(0.05, 5))
	info = ball.face_info(0)
	_expect(info.type == "mesh_group" and not info.planar and absf(info.area - ball.area()) < 1e-12, "A sphere's group should be a curved mesh_group (%s)." % [info])
	_expect(ball.face_normal_at(0, Vector3(0, 0.2, 0)).dot(Vector3.UP) > 0.99 and ball.face_normal_at(0, Vector3(-0.2, 0, 0)).dot(Vector3.LEFT) > 0.99 \
		and ball.face_normal_at(3, Vector3.UP) == Vector3.ZERO,
		"face_normal_at should give the normal of the group's nearest triangle.")
	# A solid ball of radius r and density rho: m = rho V, I = 2/5 m r^2 about any axis.
	props = ball.mass_properties(2700.0)
	var mass: float = 2700.0 * ball.volume()
	var moment := 0.4 * mass * 0.05 * 0.05
	_expect(not props.has("warning") and absf(props.mass - mass) < 1e-9 * mass and props.center.length() < 1e-7 and props.inertia.size() == 9 \
		and absf(props.inertia[0] - moment) < 0.01 * moment and absf(props.inertia[4] - moment) < 0.01 * moment and absf(props.inertia[8] - moment) < 0.01 * moment \
		and absf(props.inertia[1]) < 1e-4 * moment and absf(props.principal_moments.x - moment) < 0.01 * moment and absf(props.principal_moments.z - moment) < 0.01 * moment,
		"A ball's mass properties should be rho V and 2/5 m r^2 (%s; expected mass %s, moment %s)." % [props, mass, moment])
	# A box off the origin: the exact centre and Ixx = m (b^2 + c^2) / 12.
	var cube := _mesh(FIXTURES.two_cubes(Vector3(0.03, 0, 0)).second)
	props = cube.mass_properties(1000.0)
	var m_cube := 1000.0 * 8e-6
	var i_cube := m_cube * (0.02 * 0.02 * 2.0) / 12.0
	_expect(props.center.is_equal_approx(Vector3(0.03, 0, 0)) and absf(props.mass - m_cube) < 1e-9 and absf(props.inertia[0] - i_cube) < 1e-6 * i_cube \
		and absf(props.inertia[8] - i_cube) < 1e-6 * i_cube and cube.center_of_mass().is_equal_approx(Vector3(0.03, 0, 0)),
		"A cube at x = 30 mm should have its centre there and m a^2 / 6 about it (%s; expected %s)." % [props, i_cube])
	var hollow := _mesh(FIXTURES.hollow_cube(false))
	_expect(hollow.winding_inside(PackedVector3Array([Vector3.ZERO, Vector3(0.0075, 0, 0), Vector3(0.02, 0, 0), Vector3(0.0075, 0.0075, 0.0075)])) == PackedByteArray([0, 1, 0, 1]),
		"winding_inside should be 0 in the void and outside, 1 in the wall.")
	checked.append("the CadShape subset (plane and mesh_group face_info, face_normal_at, no edges, copy() the same instance, ball mass and 2/5 m r2, cube centre and inertia, thin-shell warning on an open plate, winding_inside around a void)")


func _check_tessellation() -> void:
	var fixture := FIXTURES.icosphere(0.05, 3)
	var mesh := _mesh(fixture)
	var tess: Dictionary = mesh.tessellate()
	var positions: PackedVector3Array = tess.positions
	var normals: PackedVector3Array = tess.normals
	var indices: PackedInt32Array = tess.indices
	var ok: bool = tess.size() == 8 and indices.size() == 1280 * 3 and tess.face_ids.size() == 1280 and normals.size() == positions.size() and tess.uvs.size() == positions.size() \
		and tess.vertices.is_empty() and tess.edge_points.is_empty() and tess.edge_ids.is_empty() and not tess.has("warnings")
	# Triangle k of the display mesh is stored triangle k, corner for corner; normals are unit and outward.
	for i in indices.size():
		ok = ok and positions[indices[i]] == fixture.positions[fixture.indices[i]]
	for i in positions.size():
		ok = ok and absf(normals[i].length() - 1.0) < 1e-5 and normals[i].dot(positions[i].normalized()) > 0.97
	_expect(ok, "The display mesh of a sphere should keep the stored triangle order, with unit outward normals and uvs for every vertex (%d vertices for %d)." % [positions.size(), fixture.positions.size()])
	# A smooth sphere shares its vertices except where the box projection changes axis.
	_expect(positions.size() >= 642 and positions.size() < 642 * 2, "A smooth sphere should share most vertices (%d for 642)." % positions.size())
	# A cube: every corner split three ways (sharp edges), flat normals, uvs in meters.
	var cube := _mesh(FIXTURES.two_cubes(Vector3(0.03, 0, 0)).first)
	tess = cube.tessellate()
	positions = tess.positions
	normals = tess.normals
	ok = positions.size() == 24 and tess.edge_ids.is_empty()
	for i in range(0, tess.indices.size(), 3):
		var a := positions[tess.indices[i]]
		var b := positions[tess.indices[i + 1]]
		var c := positions[tess.indices[i + 2]]
		var face_normal := (c - a).cross(b - a).normalized()  # clockwise front faces
		for k in 3:
			ok = ok and normals[tess.indices[i + k]].is_equal_approx(face_normal)
		var uv_a: Vector2 = tess.uvs[tess.indices[i]]
		var uv_b: Vector2 = tess.uvs[tess.indices[i + 1]]
		ok = ok and absf(uv_a.distance_to(uv_b) - a.distance_to(b)) < 1e-7
	_expect(ok, "A cube's display mesh should have 24 vertices with flat normals and uvs that measure meters (%d vertices)." % positions.size())
	# Lines: group borders (-1) on a tessellated box, open boundaries (-2) on the plate.
	var box := _new()
	box.from_shape(kernel.make_box(Vector3(0.02, 0.02, 0.02)), 0.002, 0.3, false, 20.0)
	tess = box.tessellate()
	var borders := 0
	for id in tess.edge_ids:
		borders += 1 if id == -1 else 0
	_expect(borders == 12 and tess.edge_ids.size() == 12 and tess.edge_points.size() == 24 and tess.face_ids == box.get_arrays().groups,
		"A tessellated box should draw its 12 group borders and give one group id per triangle (%d lines)." % tess.edge_ids.size())
	tess = _mesh(FIXTURES.open_plate()).tessellate()
	var open := 0
	for id in tess.edge_ids:
		open += 1 if id == -2 else 0
	_expect(open == 128 and tess.edge_ids.size() == 128 and tess.positions.size() == 33 * 33, "The open plate should draw its 128 open edges and share every vertex (%d lines, %d vertices)." % [tess.edge_ids.size(), tess.positions.size()])
	_expect(_new().tessellate().is_empty(), "An empty mesh should give an empty display mesh.")
	checked.append("tessellate() contract (stored triangle order, clockwise, unit outward normals, shared smooth vertices, 24 split vertices on a cube, uvs in meters, 12 border lines on a box, 128 open-edge lines on a plate)")


func _check_selection() -> void:
	var plate := _mesh(FIXTURES.open_plate())
	var near: PackedInt32Array = plate.triangles_near(Vector3(0.0001, 0, 0.0001), 0.002, false)
	# Squares are 1.25 mm: a 2 mm disc at the middle touches the 4 x 4 squares around it, less the far corners.
	_expect(near.size() >= 12 and near.size() <= 40, "A 2 mm disc on the plate should touch a handful of triangles (%d)." % near.size())
	var seed_tri := PackedInt32Array([near[0]])
	var ring1: PackedInt32Array = plate.grow(seed_tri, 1)
	var ring2: PackedInt32Array = plate.grow(seed_tri, 2)
	_expect(ring1.size() == 4 and ring2.size() == 10 and plate.shrink(ring2, 1) == ring1 and plate.shrink(ring1, 1) == seed_tri and plate.shrink(seed_tri, 1).is_empty() \
		and plate.grow(seed_tri, 0) == seed_tri and plate.grow(PackedInt32Array([-5, 999999]), 1).is_empty(),
		"Grow should add one ring of edge neighbours a step (1, 4, 10) and shrink peel it off (%d, %d)." % [ring1.size(), ring2.size()])
	_expect(plate.connected(seed_tri, 30.0).size() == 2048 and plate.connected(seed_tri, 0.0).size() == 2048, "A flat plate should be one connected patch at any angle.")
	# Two cubes: by angle one face, by component one cube.
	var cubes := _mesh(FIXTURES.two_cubes(Vector3(0.03, 0, 0)))
	_expect(cubes.connected(PackedInt32Array([0]), 30.0) == PackedInt32Array([0, 1]) and cubes.connected(PackedInt32Array([0]), 180.0).size() == 12 \
		and cubes.connected(PackedInt32Array([0, 12]), 180.0).size() == 24 and cubes.group_triangles(1).size() == 12 and cubes.group_triangles(1)[0] == 12 \
		and cubes.group_triangles(7).is_empty(),
		"connected() should stop at sharp edges under 90 degrees and take the whole component at 180.")
	# Paint select that keeps to the patch under the brush: a disc that reaches both cubes.
	var both: PackedInt32Array = cubes.triangles_near(Vector3(0.015, 0, 0), 0.006, false)
	var patch: PackedInt32Array = cubes.triangles_near(Vector3(0.014, 0, 0), 0.006, true)
	var sides := [0, 0]
	for t in both:
		sides[0 if t < 12 else 1] += 1
	var patch_first := true
	for t in patch:
		patch_first = patch_first and t < 12
	_expect(sides[0] > 0 and sides[1] > 0 and patch_first and not patch.is_empty() and patch.size() < both.size(), "A connected paint select should keep to the cube nearest the brush (%s, %d)." % [sides, patch.size()])
	# Window select: the half of the sphere with x >= 0, as a box of 6 planes whose normals point out.
	var fixture := FIXTURES.icosphere(0.05, 3)
	var ball := _mesh(fixture)
	var planes := [Plane(Vector3.LEFT, 0.0), Plane(Vector3.RIGHT, 1.0), Plane(Vector3.UP, 1.0), Plane(Vector3.DOWN, 1.0), Plane(Vector3.BACK, 1.0), Plane(Vector3.FORWARD, 1.0)]
	var inside: PackedInt32Array = ball.triangles_in_frustum(planes, "inside")
	var crossing: PackedInt32Array = ball.triangles_in_frustum(planes, "crossing")
	var expect_inside := 0
	var expect_crossing := 0
	for i in range(0, fixture.indices.size(), 3):
		var count := 0
		for k in 3:
			count += 1 if fixture.positions[fixture.indices[i + k]].x >= 0.0 else 0
		expect_inside += 1 if count == 3 else 0
		expect_crossing += 1 if count > 0 else 0
	_expect(inside.size() == expect_inside and crossing.size() == expect_crossing and inside.size() < crossing.size() and inside.size() > 500,
		"A window over x >= 0 should take %d triangles inside and %d crossing (got %d, %d)." % [expect_inside, expect_crossing, inside.size(), crossing.size()])
	_expect(ball.triangles_in_frustum([Plane(Vector3.RIGHT, -1.0)], "crossing").is_empty() and ball.triangles_in_frustum([Plane(Vector3.RIGHT, 1.0)], "inside").size() == 1280,
		"A window that misses takes nothing; one that holds the body takes it all.")
	checked.append("selection queries (triangles_near, connected paint select, grow 1/4/10 and shrink back, connected by angle and by component, group_triangles, window select inside %d / crossing %d)" % [inside.size(), crossing.size()])


func _check_transformed() -> void:
	var fixture := FIXTURES.icosphere(0.05, 3)
	var mesh := _mesh(fixture)
	var moved: RefCounted = mesh.transformed(Transform3D(Basis.IDENTITY, Vector3(1, 2, 3)))
	_expect(moved != null and mesh.get_last_error() == "", "A move should give a new mesh (%s)." % mesh.get_last_error())
	if moved == null:
		return
	var out: PackedVector3Array = moved.get_arrays().positions
	var exact: bool = out.size() == fixture.positions.size()
	for i in out.size():
		exact = exact and out[i] == fixture.positions[i] + Vector3(1, 2, 3)
	_expect(exact and moved.get_arrays().indices == fixture.indices and moved.get_face_names() == mesh.get_face_names() and moved.digest() != mesh.digest() \
		and not is_same(moved, mesh) and mesh.get_arrays().positions == fixture.positions,
		"A move by (1, 2, 3) should add exactly that to every vertex (float32) and leave the first mesh alone.")
	var report: Dictionary = mesh.get_last_report()
	_expect(report.get("op", "") == "transformed" and report.has("ms") and report.input.triangles == 1280 and report.output.triangles == 1280 and report.output.closed \
		and report.checks.valid == "ok" and report.has("deviation") and report.has("self_intersections"),
		"A move should leave an op report (%s)." % [report])
	# A mirror keeps the body facing out; a scale scales the volume.
	var mirrored: RefCounted = mesh.transformed(Transform3D(Basis.from_scale(Vector3(-1, 1, 1)), Vector3.ZERO))
	var scaled: RefCounted = mesh.transformed(Transform3D(Basis.from_scale(Vector3(2, 3, 0.5)), Vector3.ZERO))
	_expect(mirrored != null and absf(mirrored.volume() - mesh.volume()) < 1e-6 * mesh.volume() and mirrored.check().oriented,
		"A mirrored mesh should still face out with the same volume.")
	_expect(scaled != null and absf(scaled.volume() - 3.0 * mesh.volume()) < 1e-6 * 3.0 * mesh.volume(), "A (2, 3, 0.5) scale should triple the volume.")
	_expect(mesh.transformed(Transform3D(Basis.from_scale(Vector3(1, 0, 1)), Vector3.ZERO)) == null and mesh.get_last_error().contains("flatten"),
		"A flattening transform should be refused ('%s')." % mesh.get_last_error())
	checked.append("transformed() (exact float32 translation, names kept, the input unchanged, an op report, mirror keeps facing out, scale scales the volume, flattening refused)")


# ---------------------------------------------------------------- timing (5.7)


func _check_timing() -> void:
	var started := Time.get_ticks_msec()
	var grid := FIXTURES.large_grid(290)
	var path := FIXTURES.write_stl(grid, "native_grid_1m.stl", 1000.0, false, "Holo Forge timing fixture", false)
	var fixture_ms := Time.get_ticks_msec() - started
	var triangles: int = grid.indices.size() / 3
	_expect(triangles == 1009200 and grid.positions.size() == 6 * 290 * 290 + 2, "large_grid(290) should have 1,009,200 triangles (got %d)." % triangles)
	var calibration := func() -> void:
		var sphere: RefCounted = kernel.make_sphere(0.02, Vector3.ZERO, "cal")
		sphere.tessellate(0.0002, 0.3)
	var results := {}
	var read := func() -> void:
		var m := _new()
		m.read_stl(path, 0.001)
	results["read_stl_1m"] = TIMING.compare(read, calibration, 3, "read_stl, 1M triangles (binary)")
	var tessellate := func() -> void:
		var m := _new()
		m.set_arrays(grid.positions, grid.indices)
		m.tessellate()
	results["tessellate_1m"] = TIMING.compare(tessellate, calibration, 3, "set_arrays + tessellate(), 1M triangles")
	var check := func() -> void:
		var m := _new()
		m.set_arrays(grid.positions, grid.indices)
		m.check(20.0)
	results["check_1m"] = TIMING.compare(check, calibration, 3, "set_arrays + check(), 1M triangles")
	var built := _mesh(grid)
	var first_ray_started := Time.get_ticks_usec()
	var first: Dictionary = built.ray_hit(Vector3(0.031, 0.047, 1.0), Vector3(0, 0, -1))
	var first_ray_ms := (Time.get_ticks_usec() - first_ray_started) / 1000.0
	_expect(first.get("hit", false) and absf(first.point.z - 0.1) < 1e-6 and first.normal.is_equal_approx(Vector3(0, 0, 1)), "A ray onto the big box should hit its top (%s)." % [first])
	var rays := func() -> void:
		built.ray_hit(Vector3(0.031, 0.047, 1.0), Vector3(0.01, 0.02, -1))
	results["ray_hit_1m"] = TIMING.compare(rays, calibration, 5, "ray_hit, 1M triangles (hierarchy built)")
	# The whole mesh is what the file holds, and the checks agree with the fixture.
	var from_file := _new()
	_expect(from_file.read_stl(path, 0.001) and from_file.triangle_count() == triangles and from_file.vertex_count() == grid.positions.size(),
		"The 1M-triangle STL should weld back to the fixture's vertices (%s; %d triangles, %d vertices)." % [from_file.get_last_error(), from_file.triangle_count(), from_file.vertex_count()])
	var r: Dictionary = built.check(20.0)
	print("mesh timing: check() of the built mesh %s" % [built.get_last_report()])
	_expect(r.get("closed", false) and r.manifold and r.oriented and r.genus == 0 and r.self_intersections == 0 and absf(built.volume() - 0.001) < 1e-9,
		"The big box should be closed, genus 0, without self-intersections, 0.001 m3 (%s; %s)." % [r, built.get_last_error()])
	# A check that cannot finish in its time says so.
	var hurried := _mesh(grid)
	var hurried_started := Time.get_ticks_msec()
	var nothing: Dictionary = hurried.check(0.05)
	var hurried_ms := Time.get_ticks_msec() - hurried_started
	_expect(nothing.is_empty() and hurried.get_last_error().contains("took longer than 0.05 s") and hurried_ms < 1050,
		"check(0.05) on 1M triangles should stop with an error within its limit + 1 s (%d ms, '%s')." % [hurried_ms, hurried.get_last_error()])
	FIXTURES.remove_file(path)
	var over := []
	for key: String in results:
		var t: Dictionary = results[key]
		print("mesh timing %s: %.4f ms (calibration %.3f ms), ratio %.5f, limit %.5f" % [key, t.op, t.calibration, t.ratio, LIMITS[key]])
		if t.ratio > LIMITS[key]:
			over.append("%s ratio %.5f > %.5f" % [key, t.ratio, LIMITS[key]])
	print("mesh timing: fixture (large_grid(290) + STL written in GDScript) %d ms; first ray with the hierarchy build %.1f ms; check(0.05) stopped after %d ms" % [fixture_ms, first_ray_ms, hurried_ms])
	_expect(over.is_empty(), "Timing ratios over their limits: %s." % [over])
	checked.append("timing ratios on 1,009,200 triangles (read_stl %.0f ms, set_arrays + tessellate() %.0f ms, set_arrays + check() %.0f ms, ray_hit %.4f ms; check(0.05) stopped in %d ms)" \
		% [results.read_stl_1m.op, results.tessellate_1m.op, results.check_1m.op, results.ray_hit_1m.op, hurried_ms])


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error(message)
		print("FAIL: ", message)
