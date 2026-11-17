extends SceneTree
## Holo Forge Mesh workspace, data layer regressions (the fix round after the Phase 7 verifiers).
##
## Readers: a damaged STL or OBJ file is refused with the true reason or loaded with a warning
## that says what was left out (a text STL cut off inside a facet or without endsolid, a binary
## STL that is short or holds more facets than it says, an OBJ cut off in its last face, a face
## of one or two corners, a corner that is not a whole number); upper-case STL keywords read;
## one OBJ polygon of 100,000 corners reads in well under a second, and one that cannot be split
## in time is refused fast. Coordinates beyond 1,000 km and group names with a NUL character are
## refused everywhere (arrays, blob, files, a move).
## Tessellate: the smallest Surface Deviation follows the body's size, so every preset works on
## small bodies; a result 1 to 5 % off in volume is kept with a warning that gives the percent,
## one more than 5 % off is refused.
## Mass properties: a flawed closed mesh (inside-out parts, triangles facing the wrong way, a
## body that crosses itself) carries "warning" and "flaws" and never a negative mass.
##
## Second round (after the re-verifier): OBJ polygons with corners along their sides give no
## triangle without area and a closed cube stays closed and manifold; a face that meets others
## part-way along an edge takes their corners (or the reader warns with a count); Tessellate
## leaves no triangle that uses a corner twice (a ball's poles, a cone's tip); mass properties
## name non-manifold edges as such; lengths in sentences are plain numbers with a unit; a
## triangle counts as "without area" by its own shape, not by the size of the body.
##
## Third round: "without area" is judged by the triangle's own shape only (height at most 2^-24
## of its longest edge), not by its place, so a well-formed body far from the origin has none
## and Faceted takes it; Tessellate far from the origin joins nodes float32 stores at one place,
## and says so with the distance when triangles without area are left; OBJ faces that meet
## others part-way along an edge are joined wherever the corner lies on the side (also when the
## faces only overlap part of a side), corners near a side but off it are warned without
## promising a fix that does not work; a tilted staircase gives no needles; faces that name a
## corner twice in a row or have no area are mended or left out, and counted.
##
## godot --headless --path . --script res://tests/holo_forge_mesh_regress_data_test.gd

const FIXTURES := preload("res://tests/holo_forge_mesh_fixtures.gd")

const MM := 0.001
const DIR := "user://holo_forge_mesh_fixtures"

var failures: Array[String] = []
var checked: Array[String] = []
var kernel: RefCounted
var written: Array[String] = []


func _init() -> void:
	call_deferred("run")


func run() -> void:
	if not ClassDB.class_exists("CadMesh") or not ClassDB.class_exists("CadKernel"):
		print("NOTE: CadMesh is not registered (the holo_forge native DLL is missing): native mesh checks skipped.")
		print("PASS holo_forge_mesh_regress_data: skipped, the native library is not loaded.")
		quit(0)
		return
	kernel = ClassDB.instantiate("CadKernel")
	_check_stl_text()
	_check_stl_binary()
	_check_obj_damage()
	_check_obj_straight_sides()
	_check_obj_t_junctions()
	_check_bounds_and_names()
	_check_tessellate_small()
	_check_tessellate_volume()
	_check_tessellate_poles()
	_check_sentences()
	_check_without_area()
	_check_mass_flaws()
	_check_obj_polygons()
	_check_far_bodies()
	_check_obj_round3()
	for path in written:
		FIXTURES.remove_file(path)
	print(("PASS holo_forge_mesh_regress_data: " + "; ".join(checked) + ".") if failures.is_empty() else "FAIL holo_forge_mesh_regress_data")
	quit(0 if failures.is_empty() else 1)


func _new() -> RefCounted:
	return ClassDB.instantiate("CadMesh")


func _mesh(fixture: Dictionary) -> RefCounted:
	var mesh := _new()
	_expect(mesh.set_arrays(fixture.positions, fixture.indices, fixture.groups, fixture.names, "godot"), "A fixture should load (%s)." % mesh.get_last_error())
	return mesh


func _write(name: String, bytes: PackedByteArray) -> String:
	DirAccess.make_dir_recursive_absolute(DIR)
	var path := DIR.path_join(name)
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_buffer(bytes)
	file.close()
	written.append(path)
	return path


## {"ok", "error", "warning", "mesh", "seconds"} of reading bytes as a file of that name.
func _read(name: String, bytes: PackedByteArray, scale := 1.0) -> Dictionary:
	var path := _write(name, bytes)
	var mesh := _new()
	var started := Time.get_ticks_usec()
	var ok: bool = mesh.read_stl(path, scale) if name.get_extension() == "stl" else mesh.read_obj(path, scale)
	return {"ok": ok, "error": str(mesh.get_last_error()), "warning": str(mesh.get_last_warning()), "mesh": mesh, "seconds": (Time.get_ticks_usec() - started) / 1e6}


func _cube_fixture() -> Dictionary:
	return FIXTURES.two_cubes(Vector3(0.03, 0, 0)).first


func _is_cube(mesh: RefCounted) -> bool:
	return mesh.triangle_count() == 12 and mesh.vertex_count() == 8 and mesh.check().get("closed", false) and absf(mesh.volume() - 8e-6) < 1e-11


func _has_all(text: String, words: Array) -> bool:
	for word: String in words:
		if not text.contains(word):
			return false
	return true


# ---------------------------------------------------------------- readers


func _check_stl_text() -> void:
	var path := FIXTURES.write_stl(_cube_fixture(), "regress_text.stl", 1.0, true)
	written.append(path)
	var text := FileAccess.get_file_as_string(path)
	var lines := text.split("\n")
	# Whole: no warning.
	var whole := _read("regress_text_whole.stl", text.to_utf8_buffer())
	_expect(whole.ok and whole.warning == "" and _is_cube(whole.mesh), "A whole text STL should read without a warning ('%s', '%s')." % [whole.error, whole.warning])
	# Upper-case keywords.
	var upper := _read("regress_text_upper.stl", text.to_upper().to_utf8_buffer())
	_expect(upper.ok and upper.warning == "" and _is_cube(upper.mesh), "A text STL with upper-case keywords should read ('%s')." % upper.error)
	# Cut off after a whole facet (line 8 is the first endfacet): what is there loads, with a warning.
	var after_facet := _read("regress_text_cut8.stl", "\n".join(lines.slice(0, 8)).to_utf8_buffer())
	_expect(after_facet.ok and after_facet.mesh.triangle_count() == 1 and _has_all(after_facet.warning, ["regress_text_cut8.stl", "endsolid", "cut off", "1 triangle"]),
		"A text STL that stops after a facet should load with a warning that it has no endsolid and looks cut off (ok=%s, '%s', '%s')." % [after_facet.ok, after_facet.error, after_facet.warning])
	# Cut off inside a facet (after its third vertex, and after its endloop): refused with the reason.
	for cut: int in [6, 7]:
		var inside := _read("regress_text_cut%d.stl" % cut, "\n".join(lines.slice(0, cut)).to_utf8_buffer())
		_expect(not inside.ok and _has_all(inside.error, ["regress_text_cut%d.stl" % cut, "ends inside facet 1", "cut off"]),
			"A text STL that stops inside its first facet (after line %d) should be refused as cut off (ok=%s, '%s')." % [cut, inside.ok, inside.error])
	# Cut off in the middle of a later facet.
	var later := _read("regress_text_cut40.stl", "\n".join(lines.slice(0, 40)).to_utf8_buffer())
	_expect(not later.ok and _has_all(later.error, ["ends inside facet 6", "cut off"]), "A text STL that stops inside its sixth facet should say so (ok=%s, '%s')." % [later.ok, later.error])
	# A facet with four vertices, and one with two.
	var four := _read("regress_text_four.stl", text.replace(lines[4], lines[4] + "\n" + lines[4]).to_utf8_buffer())
	_expect(not four.ok and _has_all(four.error, ["facet 1", "4 vertices"]), "A facet of 4 vertices should be refused by number ('%s')." % four.error)
	var two := _read("regress_text_two.stl", text.replace(lines[4] + "\n", "").to_utf8_buffer())
	_expect(not two.ok and _has_all(two.error, ["facet 1", "2 vertices"]), "A facet of 2 vertices should be refused by number ('%s')." % two.error)
	# Two solids in one file are both read; an empty solid has no triangles.
	var both := _read("regress_text_twice.stl", (text + text).to_utf8_buffer())
	_expect(both.ok and both.mesh.triangle_count() == 24 and both.warning == "", "Two solids in one text STL should both be read ('%s', '%s')." % [both.error, both.warning])
	var none := _read("regress_text_none.stl", "solid nothing\nendsolid nothing\n".to_utf8_buffer())
	_expect(not none.ok and none.error.contains("no triangles"), "An empty solid should have no triangles ('%s')." % none.error)
	checked.append("text STL (upper-case keywords read; no endsolid after a facet: loaded with a warning; cut off inside a facet: refused as 'ends inside facet n'; facets of 4 and 2 vertices refused by number)")


func _stl_binary(count_field := -1, facets := 12) -> PackedByteArray:
	var path := FIXTURES.write_stl(_cube_fixture(), "regress_binary_source.stl", 1.0)
	if not written.has(path):
		written.append(path)
	var bytes := FileAccess.get_file_as_bytes(path).slice(0, 84 + 50 * facets)
	if count_field >= 0:
		bytes.encode_u32(80, count_field)
	return bytes


func _check_stl_binary() -> void:
	var whole := _read("regress_binary_whole.stl", _stl_binary())
	_expect(whole.ok and whole.warning == "" and _is_cube(whole.mesh), "A whole binary STL should read without a warning ('%s', '%s')." % [whole.error, whole.warning])
	# Zero padding after the last facet is padding: no warning.
	var padded := _stl_binary()
	padded.resize(padded.size() + 100)
	var with_padding := _read("regress_binary_padded.stl", padded)
	_expect(with_padding.ok and with_padding.warning == "" and _is_cube(with_padding.mesh), "Zero bytes after the last facet are padding, not a flaw ('%s', '%s')." % [with_padding.error, with_padding.warning])
	# A count smaller than the data: the facets it names are read, the rest is named in a warning.
	for count: int in [11, 1]:
		var less := _read("regress_binary_count%d.stl" % count, _stl_binary(count))
		_expect(less.ok and less.mesh.triangle_count() == count and _has_all(less.warning, ["regress_binary_count%d.stl" % count, "%d triangle" % count, "12"]),
			"A binary STL that says %d triangles and holds 12 should load %d with a warning naming both (ok=%s, %d, '%s')." % [count, count, less.ok, less.mesh.triangle_count(), less.warning])
	# Short files: the last byte missing, half a facet missing, a count one too high.
	var bytes := _stl_binary()
	for cut: int in [1, 25, 300]:
		var short := _read("regress_binary_cut%d.stl" % cut, bytes.slice(0, bytes.size() - cut))
		_expect(not short.ok and _has_all(short.error, ["regress_binary_cut%d.stl" % cut, "12 triangles", "cut off"]) and not short.error.contains("no triangles"),
			"A binary STL missing its last %d bytes should be refused as cut off, not as empty (ok=%s, '%s')." % [cut, short.ok, short.error])
	var over := _read("regress_binary_count13.stl", _stl_binary(13))
	_expect(not over.ok and _has_all(over.error, ["13 triangles", "cut off"]), "A binary STL that says 13 triangles and holds 12 should be refused as cut off ('%s')." % over.error)
	var header_only := _read("regress_binary_header.stl", bytes.slice(0, 84))
	_expect(not header_only.ok and header_only.error.contains("cut off"), "A binary STL header that says 12 triangles with none behind it should be refused as cut off ('%s')." % header_only.error)
	var empty := _read("regress_binary_zero.stl", _stl_binary(0, 0))
	_expect(not empty.ok and empty.error.contains("no triangles"), "A binary STL with a count of 0 has no triangles ('%s')." % empty.error)
	var junk := _read("regress_binary_junk.stl", PackedByteArray([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]))
	_expect(not junk.ok and junk.error.contains("not an STL file") and not junk.error.contains("no triangles"), "Ten stray bytes are not an STL file ('%s')." % junk.error)
	checked.append("binary STL (zero padding silent; a count below the data: loaded with a warning naming both numbers; a missing last byte, half a facet or a count too high: refused as cut off; stray bytes: not an STL file)")


func _check_obj_damage() -> void:
	var good := "v 0 0 0\nv 0.02 0 0\nv 0 0.02 0\nv 0 0 0.02\ng base\nf 1 3 2\nf 1 2 4\ng side\nf 1 4 3\nf 2 3 4\n"
	var whole := _read("regress_obj_whole.obj", good.to_utf8_buffer())
	_expect(whole.ok and whole.warning == "" and whole.mesh.triangle_count() == 4 and whole.mesh.check().closed, "A whole OBJ should read without a warning ('%s', '%s')." % [whole.error, whole.warning])
	# Cut off in the middle of its last face ("f 2 3", no line end).
	var cut := _read("regress_obj_cut.obj", good.left(good.length() - 3).to_utf8_buffer())
	_expect(not cut.ok and _has_all(cut.error, ["regress_obj_cut.obj", "line 10", "cut off"]), "An OBJ that stops inside its last face should be refused as cut off (ok=%s, '%s', '%s')." % [cut.ok, cut.error, cut.warning])
	# A face of two corners and one of one corner inside the file: left out, and said so.
	var two := _read("regress_obj_two.obj", good.replace("f 1 3 2", "f 1 3").to_utf8_buffer())
	_expect(two.ok and two.mesh.triangle_count() == 3 and _has_all(two.warning, ["regress_obj_two.obj", "1 face", "fewer than 3 corners", "line 6"]),
		"A face of 2 corners should be left out with a warning that counts it and names its line (ok=%s, '%s', '%s')." % [two.ok, two.error, two.warning])
	var ones := _read("regress_obj_ones.obj", good.replace("f 1 3 2", "f 1").replace("f 1 2 4", "f 2 4").to_utf8_buffer())
	_expect(ones.ok and ones.mesh.triangle_count() == 2 and _has_all(ones.warning, ["2 faces", "fewer than 3 corners", "line 6"]),
		"Two short faces should be counted in one warning (ok=%s, '%s', '%s')." % [ones.ok, ones.error, ones.warning])
	# A corner that is not a whole number.
	for bad: String in ["1.5", "1e0", "2x"]:
		var half := _read("regress_obj_fraction.obj", good.replace("f 1 3 2", "f %s 3 2" % bad).to_utf8_buffer())
		_expect(not half.ok and _has_all(half.error, ["line 6", "whole number"]), "A corner '%s' should be refused as not a whole number (ok=%s, '%s')." % [bad, half.ok, half.error])
	# A polygon that crosses itself is read, with a warning that its triangles may overlap.
	var bow := _read("regress_obj_bow.obj", "v 0 0 0\nv 1 1 0\nv 1 0 0\nv 0 1 0\nf 1 2 3 4\n".to_utf8_buffer())
	_expect(bow.ok and _has_all(bow.warning, ["1 face", "line 5"]) and (bow.warning.contains("cross") or bow.warning.contains("flat")),
		"A bow-tie polygon should be read with a warning (ok=%s, '%s', '%s')." % [bow.ok, bow.error, bow.warning])
	# The /vt/vn forms still read; a bad texture index is none of our business.
	var forms := _read("regress_obj_forms.obj", "v 0 0 0\nv 0.02 0 0\nv 0 0.02 0\nv 0 0 0.02\nvt 0 0\nvn 0 0 1\nf 1/1/1 3/1/1 2/1/1\nf 1//1 2//1 4//1\nf 1/1 4/1 3/1\nf 2 3 4\n".to_utf8_buffer())
	_expect(forms.ok and forms.warning == "" and forms.mesh.triangle_count() == 4, "The v/vt/vn forms should read without a warning ('%s', '%s')." % [forms.error, forms.warning])
	checked.append("OBJ damage (cut off inside the last face: refused; faces of 1 or 2 corners: left out with a counted warning; corners 1.5, 1e0, 2x: refused as not whole numbers; a self-crossing polygon: read with a warning)")


func _check_bounds_and_names() -> void:
	var cube := _mesh(_cube_fixture())
	var blob: PackedByteArray = cube.to_blob()
	# A finite coordinate of 3e38 in a blob (CRC made right).
	var far := blob.duplicate()
	far.encode_float(28, 3.0e38)
	far.encode_u32(far.size() - 4, _crc32(far.slice(0, far.size() - 4)))
	var mesh := _new()
	_expect(not mesh.from_blob(far) and _has_all(mesh.get_last_error(), ["vertex 0", "1,000 km"]), "A blob with a coordinate of 3e38 should be refused by name ('%s')." % mesh.get_last_error())
	# The same through set_arrays, a file's scale and a move.
	var positions: PackedVector3Array = _cube_fixture().positions.duplicate()
	positions[3] = Vector3(0, 2.0e6, 0)
	mesh = _new()
	_expect(not mesh.set_arrays(positions, _cube_fixture().indices) and _has_all(mesh.get_last_error(), ["vertex 3", "1,000 km"]), "set_arrays with a vertex 2,000 km out should be refused by name ('%s')." % mesh.get_last_error())
	positions[3] = Vector3(0, 9.0e5, 0)
	mesh = _new()
	_expect(mesh.set_arrays(positions, _cube_fixture().indices), "A vertex 900 km out is inside the bound (%s)." % mesh.get_last_error())
	var scaled := _read("regress_scale.stl", _stl_binary(), 1e30)
	_expect(not scaled.ok and scaled.error.contains("1,000 km"), "A file read with a scale of 1e30 should be refused by the size it gets ('%s')." % scaled.error)
	var moved: RefCounted = cube.transformed(Transform3D(Basis.IDENTITY, Vector3(1e30, 0, 0)))
	_expect(moved == null and _has_all(cube.get_last_error(), ["1,000 km"]) and not cube.get_last_error().contains("internal error"), "A move of 1e30 m should be refused by name, not as an internal error ('%s')." % cube.get_last_error())
	# (A body large enough to keep its shape there: at 500 km positions step by 3 cm.)
	var near: RefCounted = cube.transformed(Transform3D(Basis.from_scale(Vector3(1e5, 1e5, 1e5)), Vector3(5e5, 0, 0)))
	_expect(near != null, "A 2 km cube moved 500 km out is inside the bound (%s)." % cube.get_last_error())
	# A group name with a NUL character, in a blob and through set_arrays.
	var names_at := 24 + 96 + 144 + 48
	var nul := blob.duplicate()
	nul[names_at + 2] = 0
	nul.encode_u32(nul.size() - 4, _crc32(nul.slice(0, nul.size() - 4)))
	mesh = _new()
	_expect(not mesh.from_blob(nul) and _has_all(mesh.get_last_error(), ["face group 0", "NUL"]), "A blob whose group name holds a NUL character should be refused ('%s')." % mesh.get_last_error())
	checked.append("bounds and names (a coordinate beyond 1,000 km refused by vertex in a blob, in set_arrays, through a file's scale and through a move; 900 km accepted; a group name with a NUL character refused)")


func _crc32(bytes: PackedByteArray) -> int:
	var crc := 0xFFFFFFFF
	for byte in bytes:
		crc ^= byte
		for k in 8:
			crc = (crc >> 1) ^ 0xEDB88320 if crc & 1 else crc >> 1
	return crc ^ 0xFFFFFFFF


# ---------------------------------------------------------------- OBJ: corners along the sides


## Twice... no: the area of a 2D polygon (shoelace), positive.
func _shoelace(points: PackedVector2Array) -> float:
	var sum := 0.0
	for i in points.size():
		var a := points[i]
		var b := points[(i + 1) % points.size()]
		sum += float(a.x) * float(b.y) - float(b.x) * float(a.y)
	return absf(sum) * 0.5


## Triangles whose corners lie exactly on a line (in doubles from the stored floats).
func _exactly_flat(mesh: RefCounted) -> int:
	var arrays: Dictionary = mesh.get_arrays()
	var p: PackedVector3Array = arrays.positions
	var idx: PackedInt32Array = arrays.indices
	var count := 0
	for i in range(0, idx.size(), 3):
		var a := p[idx[i]]
		var b := p[idx[i + 1]]
		var c := p[idx[i + 2]]
		var ux := float(b.x) - float(a.x); var uy := float(b.y) - float(a.y); var uz := float(b.z) - float(a.z)
		var vx := float(c.x) - float(a.x); var vy := float(c.y) - float(a.y); var vz := float(c.z) - float(a.z)
		if uy * vz - uz * vy == 0.0 and uz * vx - ux * vz == 0.0 and ux * vy - uy * vx == 0.0:
			count += 1
	return count


## One polygon (2D points, turned by basis) as an OBJ face, read back.
func _read_polygon(name: String, points: PackedVector2Array, basis := Basis.IDENTITY) -> Dictionary:
	var lines := PackedStringArray()
	for point in points:
		var v := basis * Vector3(point.x, point.y, 0.0)
		lines.append("v %.9f %.9f %.9f" % [v.x, v.y, v.z])
	var face := PackedStringArray(["f"])
	for i in points.size():
		face.append(str(i + 1))
	lines.append(" ".join(face))
	return _read(name, ("\n".join(lines) + "\n").to_utf8_buffer())


## A rectangle of w x h with k points a side (corners counted once): 4 k corners.
func _dotted_rectangle(w: float, h: float, k: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in k:
		out.append(Vector2(w * i / k, 0))
	for i in k:
		out.append(Vector2(w, h * i / k))
	for i in k:
		out.append(Vector2(w - w * i / k, h))
	for i in k:
		out.append(Vector2(0, h - h * i / k))
	return out


func _comb(teeth: int, tooth := 0.004, depth := 0.05) -> PackedVector2Array:
	var out := PackedVector2Array([Vector2(0, 0)])
	for t in teeth:
		var x := t * 2.0 * tooth
		out.append_array([Vector2(x, depth), Vector2(x + tooth, depth), Vector2(x + tooth, 0.005), Vector2(x + 2.0 * tooth, 0.005)])
	out.append(Vector2(teeth * 2.0 * tooth, 0))
	return out


## A 20 mm cube as an OBJ of 6 polygons with k segments an edge (k - 1 extra corners on every
## side). plain: face numbers (0..5) written as plain quads instead, so their neighbours meet
## them part-way along their edges.
func _ngon_cube_obj(k: int, plain := []) -> PackedByteArray:
	var ids := {}
	var lines := PackedStringArray()
	var face_lines := PackedStringArray()
	var size := 0.02
	var faces := [
		[Vector3(0, 0, 0), Vector3(0, 1, 0), Vector3(1, 0, 0)], [Vector3(0, 0, 1), Vector3(1, 0, 0), Vector3(0, 1, 0)],
		[Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 0, 1)], [Vector3(0, 1, 0), Vector3(0, 0, 1), Vector3(1, 0, 0)],
		[Vector3(0, 0, 0), Vector3(0, 0, 1), Vector3(0, 1, 0)], [Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1)],
	]
	for f in faces.size():
		var o: Vector3 = faces[f][0]
		var u: Vector3 = faces[f][1]
		var v: Vector3 = faces[f][2]
		var steps := 1 if plain.has(f) else k
		var loop := []
		for i in steps:
			loop.append(o + u * (float(i) / steps))
		for i in steps:
			loop.append(o + u + v * (float(i) / steps))
		for i in steps:
			loop.append(o + u * (1.0 - float(i) / steps) + v)
		for i in steps:
			loop.append(o + v * (1.0 - float(i) / steps))
		var parts := PackedStringArray(["f"])
		for q: Vector3 in loop:
			var key := Vector3i((q * k).round())
			if not ids.has(key):
				ids[key] = ids.size() + 1
				lines.append("v %.9f %.9f %.9f" % [q.x * size, q.y * size, q.z * size])
			parts.append(str(ids[key]))
		face_lines.append(" ".join(parts))
	return ("\n".join(lines) + "\n" + "\n".join(face_lines) + "\n").to_utf8_buffer()


func _check_obj_straight_sides() -> void:
	# A closed cube whose faces have corners along their sides stays a closed, manifold cube.
	for k: int in [2, 3, 8]:
		var cube := _read("regress_ngon_cube_%d.obj" % k, _ngon_cube_obj(k))
		var r: Dictionary = cube.mesh.check() if cube.ok else {}
		var props: Dictionary = cube.mesh.mass_properties(1000.0) if cube.ok else {}
		_expect(cube.ok and cube.warning == "" and cube.mesh.triangle_count() == 6 * (4 * k - 2) and cube.mesh.vertex_count() == 8 + 12 * (k - 1) \
			and r.get("closed", false) and r.get("manifold", false) and r.get("degenerate_triangles", -1) == 0 and r.get("non_manifold_edges", -1) == 0 \
			and absf(cube.mesh.volume() - 8e-6) < 1e-11 and not props.has("flaws"),
			"A cube of 6 polygons with %d extra corners a side should read as a closed manifold cube without flat triangles (ok=%s, %d triangles, check %s, flaws %s, '%s')." \
			% [k - 1, cube.ok, cube.mesh.triangle_count() if cube.ok else 0, r, props.get("flaws"), cube.warning])
	# Lone polygons with corners on straight sides: no triangle without area, the right area.
	var cases := {
		"rectangle, 3 points a side": _dotted_rectangle(0.02, 0.01, 3), "rectangle, 50 points a side": _dotted_rectangle(0.02, 0.01, 50),
		"rectangle, 2000 points a side": _dotted_rectangle(0.02, 0.01, 2000),
		"L with points on its sides": PackedVector2Array([Vector2(0, 0), Vector2(0.01, 0), Vector2(0.02, 0), Vector2(0.02, 0.01), Vector2(0.01, 0.01), Vector2(0.01, 0.015), Vector2(0.01, 0.02), Vector2(0, 0.02), Vector2(0, 0.01), Vector2(0, 0.005)]),
		"triangle with points on every side": PackedVector2Array([Vector2(0, 0), Vector2(0.01, 0), Vector2(0.02, 0), Vector2(0.015, 0.01), Vector2(0.01, 0.02), Vector2(0.005, 0.01)]),
		"comb of 3 teeth": _comb(3), "comb of 300 teeth": _comb(300), "comb of 3000 teeth": _comb(3000),
		"two squares meeting at a corner": PackedVector2Array([Vector2(0, 0), Vector2(0.01, 0), Vector2(0.01, 0.01), Vector2(0.02, 0.01), Vector2(0.02, 0.02), Vector2(0.01, 0.02), Vector2(0.01, 0.01), Vector2(0, 0.01)]),
	}
	var tilt := Basis.from_euler(Vector3(0.7, 0.3, 1.1))
	var done := 0
	for label: String in cases:
		for turned: bool in [false, true]:
			var points: PackedVector2Array = cases[label]
			var read := _read_polygon("regress_straight_%d.obj" % done, points, tilt if turned else Basis.IDENTITY)
			var want := _shoelace(points)
			var flat: int = read.mesh.check(10.0).get("degenerate_triangles", -1) if read.ok else -1
			var area: float = read.mesh.area() if read.ok else 0.0
			# The 24 m comb is the one polygon here that cannot be split without needles: its 6,000
			# floor points can only be joined to the two ends of its 24 m base, and a 4 mm triangle
			# seen from 20 m away is thinner than float32 holds at 24 m. There, no triangle may be
			# exactly flat, and the area holds to what those numbers allow.
			var needles := label == "comb of 3000 teeth"
			if needles:
				flat = _exactly_flat(read.mesh) if read.ok and not turned else 0
			# Whole, or said: the triangles tile the polygon with none flat, or a warning says they may not.
			_expect(read.ok and read.mesh.triangle_count() == points.size() - 2 and read.seconds < 5.0 and (read.warning != "" or (flat == 0 and absf(area - want) < (1e-4 if needles else 1e-5) * want)),
				"The %s%s should split into %d triangles with area and the polygon's area (ok=%s, %d triangles, %d without area, area %s against %s, %.2f s, '%s', '%s')." \
				% [label, " (tilted)" if turned else "", points.size() - 2, read.ok, read.mesh.triangle_count() if read.ok else 0, flat, area, want, read.seconds, read.error, read.warning])
			if not turned:
				# Flat in its own plane: no excuse for a warning.
				_expect(read.warning == "" or label.begins_with("two squares"), "The %s lies in a plane and is simple: no warning ('%s')." % [label, read.warning])
			done += 1
	checked.append("OBJ corners on straight sides (cubes of 8-, 12- and 32-corner faces closed and manifold with no flat triangle; %d lone polygons, flat and tilted, split into triangles with area)" % done)


func _check_obj_t_junctions() -> void:
	# One face written as a plain quad where its four neighbours have corners along the shared
	# edges: it takes their corners, and the cube is closed.
	for k: int in [2, 3]:
		var cube := _read("regress_t_cube_%d.obj" % k, _ngon_cube_obj(k, [1]))
		var r: Dictionary = cube.mesh.check() if cube.ok else {}
		_expect(cube.ok and cube.warning == "" and r.get("closed", false) and r.get("manifold", false) and r.get("degenerate_triangles", -1) == 0 and cube.mesh.triangle_count() == 6 * (4 * k - 2) \
			and absf(cube.mesh.volume() - 8e-6) < 1e-11,
			"A cube with one plain face among faces with %d extra corners a side should come out closed (ok=%s, %d triangles, check %s, '%s')." % [k - 1, cube.ok, cube.mesh.triangle_count() if cube.ok else 0, r, cube.warning])
	# All but one face plain: the plain ones take the one face's corners.
	var mostly := _read("regress_t_cube_mostly.obj", _ngon_cube_obj(3, [0, 1, 2, 3, 4]))
	var rm: Dictionary = mostly.mesh.check() if mostly.ok else {}
	_expect(mostly.ok and mostly.warning == "" and rm.get("closed", false) and rm.get("manifold", false) and rm.get("degenerate_triangles", -1) == 0,
		"A cube with one face of 12 corners among plain faces should come out closed (check %s, '%s')." % [rm, mostly.warning])
	# The classic: one large square beside two small ones. The large one takes the corner between them.
	var classic := "v 0 0 0\nv 2 0 0\nv 2 2 0\nv 0 2 0\nv 3 0 0\nv 3 1 0\nv 2 1 0\nv 3 2 0\nf 1 2 3 4\nf 2 5 6 7\nf 7 6 8 3\n"
	var joined := _read("regress_t_classic.obj", classic.to_utf8_buffer())
	var rj: Dictionary = joined.mesh.check() if joined.ok else {}
	_expect(joined.ok and joined.warning == "" and joined.mesh.triangle_count() == 7 and rj.get("boundary_edges", -1) == 7 and rj.get("boundary_loops", -1) == 1 and rj.get("degenerate_triangles", -1) == 0 \
		and absf(joined.mesh.area() - 6.0) < 1e-9,
		"A square beside two smaller ones should be joined at the corner between them (7 triangles, 7 open edges in one loop; got %d triangles, check %s, '%s')." % [joined.mesh.triangle_count() if joined.ok else 0, rj, joined.warning])
	# Two faces that each have a corner on their shared edge, at different places: each takes the
	# other's (third round; before, this was only warned of, with a Stitch and Remove hint that
	# Stitch could not keep).
	var apart := "v 0 0 0\nv 1 0 0\nv 1 0.5 0\nv 1 1 0\nv 0 1 0\nv 2 0 0\nv 2 1 0\nv 1 0.25 0\nf 1 2 3 4 5\nf 2 6 7 4 8\n"
	var split := _read("regress_t_apart.obj", apart.to_utf8_buffer())
	var rs: Dictionary = split.mesh.check() if split.ok else {}
	_expect(split.ok and split.warning == "" and rs.get("boundary_edges", -1) == 6 and rs.get("boundary_loops", -1) == 1 and rs.get("degenerate_triangles", -1) == 0 and absf(split.mesh.area() - 2.0) < 1e-9,
		"Two faces with different corners on their shared edge should be joined (6 open edges in one loop; check %s, '%s', '%s')." % [rs, split.error, split.warning])
	# An open mesh without such places has no such warning.
	var open := _read("regress_t_none.obj", "v 0 0 0\nv 1 0 0\nv 1 1 0\nv 0 1 0\nv 2 0 0\nv 2 1 0\nf 1 2 3 4\nf 2 5 6 3\n".to_utf8_buffer())
	_expect(open.ok and open.warning == "", "Two squares that share a whole edge have nothing to warn of ('%s')." % open.warning)
	checked.append("OBJ faces that meet part-way along an edge (a plain face among dotted ones takes their corners: closed cube; the square beside two small ones is joined; corners at different places: joined)")


# ---------------------------------------------------------------- Tessellate


func _check_tessellate_small() -> void:
	var presets := {"low": [200.0, 30.0], "medium": [1000.0, 15.0], "high": [5000.0, 8.0], "very_high": [20000.0, 4.0]}
	var done := 0
	# Every preset on boxes from 10 mm down to 0.1 mm, and on small balls.
	for size: float in [10.0, 2.0, 0.5, 0.1]:
		for preset: String in presets:
			var box: RefCounted = kernel.make_box(Vector3(size, size, size) * MM)
			var diagonal: float = box.bbox().size.length()
			var mesh := _new()
			var ok: bool = mesh.from_shape(box, diagonal / presets[preset][0], deg_to_rad(presets[preset][1]), false, 20.0)
			_expect(ok and mesh.triangle_count() == 12 and mesh.check().closed and absf(mesh.volume() - box.volume()) < 1e-3 * box.volume(),
				"A %s mm box should tessellate at the %s preset ('%s')." % [size, preset, mesh.get_last_error()])
			done += 1
	for radius: float in [2.0, 0.25, 0.05]:
		for preset: String in presets:
			var ball: RefCounted = kernel.make_sphere(radius * MM, Vector3.ZERO)
			var diagonal: float = ball.bbox().size.length()
			var mesh := _new()
			var ok: bool = mesh.from_shape(ball, diagonal / presets[preset][0], deg_to_rad(presets[preset][1]), false, 20.0)
			var off: float = absf(mesh.volume() - ball.volume()) / ball.volume() if ok else 1.0
			_expect(ok and mesh.check().closed and off < 0.05, "A ball of radius %s mm should tessellate at the %s preset, within 5 %% (%s; '%s')." % [radius, preset, off, mesh.get_last_error()])
			done += 1
	# Under the mesher's own floor (0.0001 mm) the value is raised to it, and said.
	var half: RefCounted = kernel.make_box(Vector3(0.5, 0.5, 0.5) * MM)
	var raised := _new()
	_expect(raised.from_shape(half, half.bbox().size.length() / 20000.0, deg_to_rad(4.0), false, 20.0) and _has_all(raised.get_last_warning(), ["Surface Deviation was raised from 43.3 nm to 0.1 µm"]),
		"A deviation under 0.0001 mm should be raised to it with a warning in plain numbers ('%s', '%s')." % [raised.get_last_error(), raised.get_last_warning()])
	var not_raised := _new()
	_expect(not_raised.from_shape(kernel.make_box(Vector3(10, 10, 10) * MM), Vector3(10, 10, 10).length() * MM / 20000.0, deg_to_rad(4.0), false, 20.0) and not_raised.get_last_warning() == "",
		"A 10 mm box at the finest preset should tessellate without a warning ('%s', '%s')." % [not_raised.get_last_error(), not_raised.get_last_warning()])
	# A typed value below the body's smallest is still refused by name, and the sentence gives the range.
	var box: RefCounted = kernel.make_box(Vector3(10, 10, 10) * MM)
	var tiny := _new()
	_expect(not tiny.from_shape(box, 1e-10, 0.2, false, 20.0) and tiny.get_last_error().begins_with("Surface Deviation must be between "), "A deviation far below the body's smallest should be refused by name ('%s')." % tiny.get_last_error())
	var wide := _new()
	_expect(not wide.from_shape(box, 0.01, 0.2, false, 20.0) and wide.get_last_error().begins_with("Surface Deviation must be between "), "A deviation above a tenth of the size should be refused by name ('%s')." % wide.get_last_error())
	# On a body of ordinary size the smallest stays 0.001 mm.
	var big: RefCounted = kernel.make_box(Vector3(0.2, 0.2, 0.2))
	var under := _new()
	_expect(not under.from_shape(big, 0.9e-6, 0.2, false, 20.0) and under.get_last_error().contains("0.001 mm"), "On a 200 mm box the smallest deviation should stay 0.001 mm ('%s')." % under.get_last_error())
	checked.append("Tessellate on small bodies (%d preset runs on boxes of 10 to 0.1 mm and balls of radius 2 to 0.05 mm all tessellate; under 0.0001 mm the deviation is raised to it with a warning; a typed value out of range is still refused by name)" % done)


func _check_tessellate_volume() -> void:
	# Low preset (D / 200, 30 degrees) on a 100 mm ball: about 2.3 % off. Kept, with the percent.
	var ball: RefCounted = kernel.make_sphere(0.05, Vector3.ZERO)
	var diagonal: float = ball.bbox().size.length()
	var low := _new()
	var ok: bool = low.from_shape(ball, diagonal / 200.0, deg_to_rad(30.0), false, 20.0)
	var off: float = absf(low.volume() - ball.volume()) / ball.volume() * 100.0 if ok else 100.0
	var report: Dictionary = low.get_last_report()
	_expect(ok and off > 1.0 and off < 5.0 and _has_all(low.get_last_warning(), ["volume", "%", "Refinement"]) and low.get_last_warning().contains("%.1f" % off) \
		and str(report.get("checks", {}).get("volume", "")).begins_with("warn: "),
		"A ball at the Low preset (%.2f %% off) should be kept with a warning that gives the percent (ok=%s, '%s', '%s', %s)." % [off, ok, low.get_last_error(), low.get_last_warning(), report.get("checks", {})])
	var ball_off := off
	# The same on a cylinder (about 1.1 % off).
	var rod: RefCounted = kernel.make_cylinder(0.02, 0.06, Vector3.ZERO, Vector3.UP)
	var rod_low := _new()
	ok = rod_low.from_shape(rod, rod.bbox().size.length() / 200.0, deg_to_rad(30.0), false, 20.0)
	off = absf(rod_low.volume() - rod.volume()) / rod.volume() * 100.0 if ok else 100.0
	_expect(ok and off > 1.0 and off < 5.0 and rod_low.get_last_warning().contains("%.1f" % off), "A cylinder at the Low preset (%.2f %% off) should be kept with the percent in a warning ('%s', '%s')." % [off, rod_low.get_last_error(), rod_low.get_last_warning()])
	# Medium: under 1 %, no warning.
	var medium := _new()
	ok = medium.from_shape(ball, diagonal / 1000.0, deg_to_rad(15.0), false, 20.0)
	_expect(ok and medium.get_last_warning() == "" and str(medium.get_last_report().get("checks", {}).get("volume", "")) == "ok", "A ball at the Medium preset should have no warning ('%s', '%s')." % [medium.get_last_error(), medium.get_last_warning()])
	# The coarsest allowed setting (a tenth of the size, 45 degrees) is more than 5 % off: refused.
	var coarse := _new()
	ok = coarse.from_shape(ball, diagonal / 10.0, deg_to_rad(45.0), false, 20.0)
	_expect(not ok and _has_all(coarse.get_last_error(), ["volume", "more than 5 %", "Raise the Refinement"]) and coarse.is_null(),
		"A ball at the coarsest setting should be refused as more than 5 %% off (ok=%s, '%s')." % [ok, coarse.get_last_error()])
	checked.append("Tessellate volume rule (ball at Low %.2f %% off and cylinder %.2f %% off: kept with the percent in a warning; Medium: no warning; more than 5 %% off: refused)" % [ball_off, off])


func _twice_used(mesh: RefCounted) -> int:
	var indices: PackedInt32Array = mesh.get_arrays().indices
	var count := 0
	for i in range(0, indices.size(), 3):
		if indices[i] == indices[i + 1] or indices[i + 1] == indices[i + 2] or indices[i] == indices[i + 2]:
			count += 1
	return count


func _check_tessellate_poles() -> void:
	var presets := {"low": [200.0, 30.0], "medium": [1000.0, 15.0], "high": [5000.0, 8.0], "very_high": [20000.0, 4.0]}
	var shapes := {}
	shapes["ball"] = kernel.make_sphere(0.01, Vector3.ZERO)
	shapes["torus"] = kernel.torus({"major_radius": 0.02, "minor_radius": 0.005, "tag": "T"})
	# A cone with a sharp tip: a right triangle turned about the Y axis.
	var profile: Array = kernel.sketch_regions([{"type": "line", "a": Vector2(0, 0), "b": Vector2(0.01, 0)}, {"type": "line", "a": Vector2(0.01, 0), "b": Vector2(0, 0.02)},
		{"type": "line", "a": Vector2(0, 0.02), "b": Vector2(0, 0)}], Transform3D.IDENTITY)
	shapes["cone"] = kernel.revolve(profile[0].face, {"axis_origin": Vector3.ZERO, "axis": Vector3.UP, "tag": "C"}) if not profile.is_empty() else null
	# A box with every edge rounded (ball corners).
	var box: RefCounted = kernel.make_box(Vector3(0.02, 0.02, 0.02))
	var edges := PackedInt32Array()
	for e in box.edge_count():
		edges.append(e)
	shapes["rounded box"] = kernel.fillet(box, edges, {"radius": 0.004, "tag": "F"})
	var runs := 0
	var dropped := 0
	for label: String in shapes:
		var shape: RefCounted = shapes[label]
		_expect(shape != null and not shape.is_null(), "The %s should build in the kernel." % label)
		if shape == null or shape.is_null():
			continue
		var diagonal: float = shape.bbox().size.length()
		for preset: String in presets:
			var mesh := _new()
			var ok: bool = mesh.from_shape(shape, diagonal / presets[preset][0], deg_to_rad(presets[preset][1]), false, 20.0)
			var left_out := int(mesh.get_last_report().get("dropped_triangles", 0)) if ok else 0
			var r: Dictionary = mesh.check(10.0) if ok else {}
			var twice := _twice_used(mesh) if ok else -1
			_expect(ok and twice == 0 and r.get("closed", false) and r.get("manifold", false) and r.get("oriented", false) and r.get("degenerate_triangles", -1) == 0,
				"The %s at the %s preset should tessellate closed, with no triangle that uses a corner twice or has no area (ok=%s, %d use a corner twice, check %s, '%s')." \
				% [label, preset, ok, twice, r, mesh.get_last_error()])
			dropped += left_out
			runs += 1
	_expect(dropped > 0, "The report of a tessellated ball should count the triangles left out at its poles (dropped_triangles; got %d in all)." % dropped)
	checked.append("Tessellate at poles and tips (%d runs on a ball, a torus, a cone and a rounded box: closed, no triangle that uses a corner twice, none without area; %d such triangles left out in all)" % [runs, dropped])


func _check_sentences() -> void:
	# Non-manifold and not open: two tetrahedra that share one edge.
	var positions := PackedVector3Array([Vector3(0, 0, 0), Vector3(0, 0, 1), Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(-1, 0, 0), Vector3(0, -1, 0)])
	var ccw := PackedInt32Array([0, 1, 2, 1, 3, 2, 3, 0, 2, 0, 3, 1, 0, 4, 1, 1, 4, 5, 5, 4, 0, 0, 1, 5])
	var pair := _new()
	_expect(pair.set_arrays(positions, ccw, PackedInt32Array(), PackedStringArray(), "ccw"), "Two tetrahedra on one edge should load (%s)." % pair.get_last_error())
	var r: Dictionary = pair.check()
	var props: Dictionary = pair.mass_properties(1000.0)
	_expect(r.boundary_edges == 0 and r.non_manifold_edges == 1 and props.get("flaws", PackedStringArray()) == PackedStringArray(["non_manifold"]) and props.get("non_manifold_edges", 0) == 1 \
		and str(props.get("warning", "")).contains("shared by more than two triangles") and not str(props.get("warning", "")).contains("open") and props.mass == 0.0,
		"A mesh with a non-manifold edge and no open edge should say so, not that it is open (check %s, %s)." % [r, props])
	# Open and non-manifold at once: both named.
	var fin := _mesh(FIXTURES.cube_debris())
	props = fin.mass_properties(1000.0)
	_expect(props.flaws.has("open") and props.flaws.has("non_manifold") and str(props.warning).contains("open") and str(props.warning).contains("shared by more than two triangles"),
		"A mesh that is open and non-manifold should name both (%s)." % [props])
	# The size limit, in plain numbers, as what it is: a limit on each coordinate.
	var far := _new()
	var cube: Dictionary = _cube_fixture()
	var moved: PackedVector3Array = cube.positions.duplicate()
	moved[0] = Vector3(1000001.0, 0, 0)
	_expect(not far.set_arrays(moved, cube.indices) and _has_all(far.get_last_error(), ["vertex 0", "1,000.001 km", "1,000 km", "each axis"]) and not far.get_last_error().contains("e+"),
		"A vertex at 1,000.001 km should be refused in plain numbers, as a limit along each axis ('%s')." % far.get_last_error())
	var corner := _new()
	moved = cube.positions.duplicate()
	for i in moved.size():
		moved[i] += Vector3(7e5, 7e5, 7e5)
	_expect(corner.set_arrays(moved, cube.indices), "A cube at (700, 700, 700) km is inside the limit, which is along each axis (%s)." % corner.get_last_error())
	var huge := _new()
	moved = cube.positions.duplicate()
	moved[0] = Vector3(3e38, 0, 0)
	_expect(not huge.set_arrays(moved, cube.indices) and not huge.get_last_error().contains("e+") and huge.get_last_error().contains("km"), "A vertex at 3e38 m should be refused without an exponent ('%s')." % huge.get_last_error())
	var scaled := _read("regress_sentence_scale.stl", _stl_binary(), 1e9)
	_expect(not scaled.ok and not scaled.error.contains("e+") and _has_all(scaled.error, ["1,000 km", "each axis", "units"]), "A file far too large should be refused in plain numbers ('%s')." % scaled.error)
	# Tessellate's sentences: lengths with a unit, no exponents.
	var tiny: RefCounted = kernel.make_box(Vector3(0.1, 0.1, 0.1) * MM)
	var low := _new()
	_expect(not low.from_shape(tiny, 1e-12, 0.2, false, 20.0) and low.get_last_error().begins_with("Surface Deviation must be between ") and not low.get_last_error().contains("e-") \
		and low.get_last_error().contains("nm"),
		"The range of a tiny body should be given in plain numbers ('%s')." % low.get_last_error())
	var raised := _new()
	_expect(raised.from_shape(tiny, tiny.bbox().size.length() / 5000.0, deg_to_rad(8.0), false, 20.0) and not raised.get_last_warning().contains("e-") and raised.get_last_warning().contains("nm"),
		"The raised deviation should be given in plain numbers ('%s', '%s')." % [raised.get_last_error(), raised.get_last_warning()])
	var slow := _new()
	_expect(not slow.from_shape(kernel.make_sphere(0.5, Vector3.ZERO), 1e-6, deg_to_rad(1.0), false, 20.0) and slow.get_last_error().contains("Tessellate would take about") \
		and not slow.get_last_error().contains("e+"),
		"A time estimate should be a plain number ('%s')." % slow.get_last_error())
	checked.append("sentences (non-manifold edges named as such; the 1,000 km limit said per axis in plain numbers; Tessellate's lengths in nm or \u00b5m and its time estimate without exponents)")


func _check_without_area() -> void:
	# 0.1 mm triangles on a body 100 m across have area.
	var positions := PackedVector3Array()
	var indices := PackedInt32Array()
	for j in 11:
		for i in 11:
			positions.append(Vector3(i * 0.0001, 0, j * 0.0001))
	for j in 10:
		for i in 10:
			var a := j * 11 + i
			indices.append_array([a, a + 1, a + 11, a + 1, a + 12, a + 11])
	var base := positions.size()
	positions.append_array([Vector3(60, 0, 0), Vector3(100, 0, 0), Vector3(100, 0, 40)])
	indices.append_array([base, base + 1, base + 2])
	var wide := _new()
	wide.set_arrays(positions, indices)
	var r: Dictionary = wide.check()
	_expect(wide.bbox().size.length() > 100.0 and r.degenerate_triangles == 0, "0.1 mm triangles on a 100 m body have area (%d counted as without)." % r.degenerate_triangles)
	# A needle whose height is below the float32 step at its place has no area; a small but real one has.
	var shapes := _new()
	shapes.set_arrays(PackedVector3Array([
		Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0.5, 1e-9, 0),       # 1 m long, 1 nm high at 1 m: nothing
		Vector3(0, 1, 0), Vector3(1, 1, 0), Vector3(0.5, 1.001, 0),      # 1 m long, 1 mm high: thin but real
		Vector3(0, 2, 0), Vector3(1e-6, 2, 0), Vector3(0, 2, 1e-6),      # 1 um across, 2 m out: small but real
		Vector3(0, 0, 1), Vector3(5e-8, 0, 1), Vector3(0, 5e-8, 1),      # 50 nm across, 1 m out: stored exactly, real (third round: judged by itself)
		Vector3(0.001, 0, 0.5), Vector3(0.002, 0, 0.5), Vector3(0.003, 0, 0.5),  # on a line
	]), PackedInt32Array([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 0, 0, 1]))
	r = shapes.check()
	_expect(r.degenerate_triangles == 3, "A needle a billionth as high as it is long, three points on a line and a triangle that names a corner twice have no area; a 1 mm high needle, a 1 um triangle and a 50 nm one stored exactly have (%d counted)." % r.degenerate_triangles)
	# Near the origin tiny triangles are real.
	var small := _new()
	small.set_arrays(PackedVector3Array([Vector3(0, 0, 0), Vector3(1e-7, 0, 0), Vector3(0, 1e-7, 0), Vector3(0.05, 0, 0), Vector3(0.05, 0.05, 0), Vector3(0, 0.05, 0)]), PackedInt32Array([0, 1, 2, 3, 4, 5]))
	_expect(small.check().degenerate_triangles == 0, "A 0.1 um triangle at the origin has area.")
	checked.append("triangles without area judged by themselves (0.1 mm triangles on a 100 m body count as having area; needles under the float32 step, points on a line and corners used twice do not)")


# ---------------------------------------------------------------- mass properties


func _flipped(fixture: Dictionary, triangles := PackedInt32Array()) -> Dictionary:
	var out := fixture.duplicate()
	var indices: PackedInt32Array = fixture.indices.duplicate()
	var all := triangles.is_empty()
	for t in indices.size() / 3:
		if all or triangles.has(t):
			var keep := indices[t * 3 + 1]
			indices[t * 3 + 1] = indices[t * 3 + 2]
			indices[t * 3 + 2] = keep
	out["indices"] = indices
	return out


func _check_mass_flaws() -> void:
	# Clean bodies: no warning, no flaws.
	for clean: Dictionary in [_cube_fixture(), FIXTURES.hollow_cube(false), FIXTURES.hollow_cube(true)]:
		var props: Dictionary = _mesh(clean).mass_properties(1000.0)
		_expect(not props.has("warning") and not props.has("flaws") and props.mass > 0.0, "A clean closed mesh should have no warning (%s)." % [props])
	# An inside-out cube: its size as a positive mass, and a warning.
	var inside_out := _mesh(_flipped(_cube_fixture()))
	var props: Dictionary = inside_out.mass_properties(1000.0)
	_expect(absf(props.mass - 0.008) < 1e-8 and absf(props.volume - 8e-6) < 1e-11 and props.center.length() < 1e-9 and props.inertia[0] > 0.0 \
		and str(props.get("warning", "")).contains("inside-out") and props.get("flaws", PackedStringArray()) == PackedStringArray(["inside_out"]) and props.get("inside_out_parts", 0) == 1,
		"An inside-out cube should weigh +8 g with a warning that names the flaw (%s)." % [props])
	_expect(inside_out.volume() < 0.0, "volume() itself stays signed (%s)." % inside_out.volume())
	# A hollow cube whose void faces outward: 1 part inside-out, never a negative mass.
	var hollow := FIXTURES.hollow_cube(false)
	props = _mesh(_flipped(hollow, hollow.void_triangles)).mass_properties(1000.0)
	_expect(props.mass > 0.0 and str(props.get("warning", "")).contains("inside-out") and props.get("inside_out_parts", 0) == 1 and props.flaws.has("inside_out"),
		"A hollow cube whose void faces out should warn of 1 inside-out part (%s)." % [props])
	# Half the triangles flipped: no volume can be told; the centre is the surface's, inside the ball.
	props = _mesh(FIXTURES.flipped_half()).mass_properties(1000.0)
	_expect(props.mass == 0.0 and props.volume == 0.0 and props.center.length() < 0.05 and str(props.get("warning", "")).contains("face the wrong way") \
		and props.flaws.has("wrong_way") and props.get("wrong_way_edges", 0) > 0,
		"A half-flipped ball should have no mass, a centre inside the ball and a warning that counts the edges (%s)." % [props])
	# Two cubes that cross each other: the overlap is counted twice, and the warning says so.
	var crossing := _mesh(FIXTURES.two_cubes(Vector3(0.01, 0, 0)))
	props = crossing.mass_properties(1000.0)
	_expect(props.mass > 0.0 and str(props.get("warning", "")).contains("crosses itself") and props.flaws.has("self_crossing") and props.get("self_intersections", 0) > 0,
		"Two crossing cubes should carry a warning that the mesh crosses itself (%s)." % [props])
	# Open: as before, now with the flaw named too.
	props = _mesh(FIXTURES.open_plate()).mass_properties(1000.0)
	_expect(props.mass == 0.0 and props.volume == 0.0 and str(props.get("warning", "")).contains("open") and props.get("flaws", PackedStringArray()) == PackedStringArray(["open"]),
		"An open plate should keep its warning and name the flaw (%s)." % [props])
	# center_of_mass() follows the same rules.
	_expect(_mesh(FIXTURES.flipped_half()).center_of_mass().length() < 0.05, "center_of_mass() of a half-flipped ball should be inside the ball.")
	checked.append("mass properties of flawed bodies (inside-out cube: +8 g with 'inside-out'; void facing out: warned; half-flipped ball: no mass, centre inside, 'face the wrong way'; crossing cubes: 'crosses itself'; clean bodies: no warning; keys warning, flaws, inside_out_parts, wrong_way_edges, self_intersections)")


# ---------------------------------------------------------------- OBJ polygons


## An OBJ with one polygon: a circle, a star (r = 1 + 0.5 sin(40 a)) or random points.
func _polygon_obj(kind: String, corners: int) -> PackedByteArray:
	var lines := PackedStringArray()
	var rng := RandomNumberGenerator.new()
	rng.seed = 12
	for i in corners:
		var a := TAU * i / corners
		var r := 1.0
		if kind == "star":
			r = 1.0 + 0.5 * sin(40.0 * a)
		if kind == "gear":
			# Tips on the unit circle, valleys on a circle of 1 mm: every reflex corner sits in one spot.
			r = 1.0 if i % 2 == 0 else 0.001
		if kind == "random":
			lines.append("v %f %f 0" % [rng.randf(), rng.randf()])
		else:
			lines.append("v %f %f 0" % [r * cos(a), r * sin(a)])
	var face := PackedStringArray(["f"])
	for i in corners:
		face.append(str(i + 1))
	lines.append(" ".join(face))
	return ("\n".join(lines) + "\n").to_utf8_buffer()


func _check_obj_polygons() -> void:
	var notes := []
	for kind: String in ["circle", "star"]:
		var read := _read("regress_polygon_%s.obj" % kind, _polygon_obj(kind, 100000))
		var area: float = read.mesh.area() if read.ok else 0.0
		# Circle: pi. Star: the integral of r^2 / 2 = pi (1 + 0.125).
		var expected := PI if kind == "circle" else PI * 1.125
		_expect(read.ok and read.mesh.triangle_count() == 99998 and absf(area - expected) < 1e-3 * expected and read.seconds < 5.0,
			"One %s polygon of 100,000 corners should read as 99,998 triangles of its area in well under 5 s (ok=%s, %.2f s, area %s against %s, '%s')." % [kind, read.ok, read.seconds, area, expected, read.error])
		notes.append("%s %.2f s" % [kind, read.seconds])
	# A polygon that cannot be split (20,000 random corners): refused fast, or read with a warning.
	var tangle := _read("regress_polygon_random.obj", _polygon_obj("random", 20000))
	_expect(tangle.seconds < 5.0 and ((not tangle.ok and _has_all(tangle.error, ["line 20,001", "20,000 corners"])) or (tangle.ok and tangle.warning.contains("cross"))),
		"A polygon of 20,000 random corners should be refused (or warned of) within 5 s (ok=%s, %.2f s, '%s', '%s')." % [tangle.ok, tangle.seconds, tangle.error, tangle.warning])
	notes.append("random 20,000 corners %s in %.2f s" % ["read with a warning" if tangle.ok else "refused", tangle.seconds])
	# A gear with deep teeth: every tip's triangle reaches the spot where all the reflex corners are.
	# A small one is split right (its area is n / 2 sin(2 pi / n) r); a huge one is more work than
	# a second of corner tests and is refused fast, by name (the count of tests decides, not the
	# clock, so the outcome is the same on a busy machine).
	var small := _read("regress_polygon_gear_small.obj", _polygon_obj("gear", 2000))
	var gear_area := 2000 * 0.5 * 1.0 * 0.001 * sin(TAU / 2000)
	_expect(small.ok and small.warning == "" and small.mesh.triangle_count() == 1998 and absf(small.mesh.area() - gear_area) < 1e-3 * gear_area,
		"A gear polygon of 2,000 corners should split into 1,998 triangles of its area (ok=%s, area %s against %s, '%s', '%s')." % [small.ok, small.mesh.area() if small.ok else 0.0, gear_area, small.error, small.warning])
	var gear := _read("regress_polygon_gear.obj", _polygon_obj("gear", 250000))
	_expect(gear.seconds < 5.0 and not gear.ok and _has_all(gear.error, ["line 250,001", "250,000 corners", "could not be split into triangles in time"]),
		"A gear polygon of 250,000 corners should be refused by name within 5 s (ok=%s, %.2f s, '%s')." % [gear.ok, gear.seconds, gear.error])
	notes.append("deep gear of 2,000 corners split right, of 250,000 corners refused as not splittable in time in %.2f s" % gear.seconds)
	checked.append("OBJ polygons of 100,000 corners (%s)" % ", ".join(notes))


# ---------------------------------------------------------------- third round


## A mesh moved by a transform in float32 (as a probe or a feature would move it).
func _moved(mesh: RefCounted, xform: Transform3D) -> RefCounted:
	var arrays: Dictionary = mesh.get_arrays()
	var positions: PackedVector3Array = arrays.positions.duplicate()
	for i in positions.size():
		positions[i] = xform * positions[i]
	var out := _new()
	_expect(out.set_arrays(positions, arrays.indices, arrays.groups, arrays.group_names, "godot"), "A moved mesh should load (%s)." % out.get_last_error())
	return out


func _check_far_bodies() -> void:
	# The re-verifier's case: the drilled block turned 1.1 rad about (1, 0, 1) and moved out along
	# (100, 50, -80). Converted before the second round; refused for "triangles without area"
	# after it, and Stitch kept them, so the hint went round in a circle.
	var block: Dictionary = FIXTURES.crossing_holes()
	var notes := []
	if block.is_empty():
		_expect(false, "The crossing_holes fixture should build.")
		return
	var direction := Vector3(100, 50, -80).normalized()
	for distance: float in [1.0, 50.0, 141.8]:
		var far := _moved(block.mesh, Transform3D(Basis(Vector3(1, 0, 1).normalized(), 1.1), direction * distance))
		var r: Dictionary = far.check()
		var faceted: Variant = far.to_faceted({"merge_flat": true})
		var refusal := str(far.get_last_error()) if faceted == null else ""
		_expect(r.closed and r.degenerate_triangles == 0 and not refusal.contains("without area"),
			"The drilled block %s m out should have no triangle without area and Faceted should not refuse it for that (check %s, '%s')." % [distance, r, refusal])
		notes.append("%s m: %d without area%s" % [distance, r.degenerate_triangles, ", Faceted refused: " + refusal if faceted == null else ""])
	# Tessellate of a 20 mm ball out on the x axis at Very High: no triangle without area, or a
	# count with the distance; never a silent one. Closed either way.
	for distance: float in [100.0, 300.0, 10000.0]:
		var ball: RefCounted = kernel.make_sphere(0.01, Vector3(distance, 0, 0))
		var mesh := _new()
		var ok: bool = mesh.from_shape(ball, ball.bbox().size.length() / 20000.0, deg_to_rad(4.0), false, 20.0)
		var said: String = mesh.get_last_warning() if ok else mesh.get_last_error()  # (before check(), which clears it)
		var r: Dictionary = mesh.check(10.0) if ok else {}
		var flat: int = r.get("degenerate_triangles", -1)
		_expect((ok and r.closed and (flat == 0 or _has_all(said, ["%d triangle" % flat, "without area", "from the origin", "stored only to about"]))) \
			or (not ok and _has_all(said, ["from the origin", "stored only to about"])),
			"A 20 mm ball %s m out at Very High should tessellate closed with no triangle without area, or say how many and why (ok=%s, check %s, '%s')." % [distance, ok, r, said])
		notes.append("ball %s m out: %s" % [distance, ("%d without area%s" % [flat, " (said)" if said != "" else ""]) if ok else "refused, said why"])
	checked.append("far bodies (the drilled block 1 to 141.8 m out: %s)" % "; ".join(notes))


## A prism of a polygon (2D points), its faces as OBJ polygons, moved by xform in float32.
func _prism_obj(points: PackedVector2Array, height: float, xform: Transform3D) -> PackedByteArray:
	var lines := PackedStringArray()
	for z: float in [0.0, height]:
		for p in points:
			var v := xform * Vector3(p.x, p.y, z)
			lines.append("v %.10f %.10f %.10f" % [v.x, v.y, v.z])
	var n := points.size()
	var bottom := PackedStringArray(["f"])
	var top := PackedStringArray(["f"])
	for i in n:
		bottom.append(str(n - i))
		top.append(str(n + i + 1))
	lines.append(" ".join(bottom))
	lines.append(" ".join(top))
	for i in n:
		lines.append("f %d %d %d %d" % [i + 1, (i + 1) % n + 1, n + (i + 1) % n + 1, n + i + 1])
	return ("\n".join(lines) + "\n").to_utf8_buffer()


## Text of an OBJ from points and faces (0-based corners).
func _obj_text(points: Array, faces: Array) -> PackedByteArray:
	var lines := PackedStringArray()
	for v: Vector3 in points:
		lines.append("v %.10f %.10f %.10f" % [v.x, v.y, v.z])
	for face: Array in faces:
		var parts := PackedStringArray(["f"])
		for i: int in face:
			parts.append(str(i + 1))
		lines.append(" ".join(parts))
	return ("\n".join(lines) + "\n").to_utf8_buffer()


## A box 20 x 30 x 20 mm whose four side faces are each two quads split at heights[k] x 30 mm.
func _staggered_box(heights: Array, xform := Transform3D.IDENTITY) -> PackedByteArray:
	var points := []
	var ids := {}
	var id := func(v: Vector3) -> int:
		var key := Vector3i((v * 1e6).round())
		if not ids.has(key):
			ids[key] = points.size()
			points.append(xform * v)
		return ids[key]
	var a := 0.02
	var b := 0.03
	var c := 0.02
	var corners := [Vector3(0, 0, 0), Vector3(a, 0, 0), Vector3(a, 0, c), Vector3(0, 0, c)]
	var faces := [[id.call(corners[0]), id.call(corners[1]), id.call(corners[2]), id.call(corners[3])]]
	var top := []
	for k in 4:
		top.append(id.call(corners[3 - k] + Vector3(0, b, 0)))
	faces.append(top)
	for k in 4:
		var p: Vector3 = corners[k]
		var q: Vector3 = corners[(k + 1) % 4]
		var h: float = heights[k] * b
		faces.append([id.call(q), id.call(p), id.call(p + Vector3(0, h, 0)), id.call(q + Vector3(0, h, 0))])
		faces.append([id.call(q + Vector3(0, h, 0)), id.call(p + Vector3(0, h, 0)), id.call(p + Vector3(0, b, 0)), id.call(q + Vector3(0, b, 0))])
	return _obj_text(points, faces)


func _check_obj_round3() -> void:
	var tilt := Transform3D(Basis(Vector3(1, 2, 3).normalized(), 0.9), Vector3(0.01, -0.02, 0.03))
	# A4: a staircase prism whose inner corners lie on one line, tilted: no needles.
	var stairs := PackedVector2Array([Vector2(0, 0), Vector2(0.04, 0), Vector2(0.04, 0.01), Vector2(0.03, 0.01), Vector2(0.03, 0.02), Vector2(0.02, 0.02), Vector2(0.02, 0.03), Vector2(0.01, 0.03), Vector2(0.01, 0.04), Vector2(0, 0.04)])
	for item in [["", Transform3D.IDENTITY], [" tilted", tilt], [" turned 30 degrees", Transform3D(Basis(Vector3(0, 0, 1), PI / 6.0), Vector3.ZERO)]]:
		var read := _read("regress_r3_stairs.obj", _prism_obj(stairs, 0.01, item[1]))
		var r: Dictionary = read.mesh.check() if read.ok else {}
		_expect(read.ok and read.warning == "" and r.closed and r.degenerate_triangles == 0 and absf(read.mesh.volume() - 1e-5) < 1e-9,
			"A staircase prism%s should read closed with no triangle without area (ok=%s, check %s, volume %s, '%s')." % [item[0], read.ok, r, read.mesh.volume() if read.ok else 0.0, read.warning])
	# A3: faces that meet part-way along a side are joined wherever the corner lies on it.
	var sheets := {
		"two rectangles sharing 10 mm of a side": [[Vector3(0, 0, 0), Vector3(0.01, 0, 0), Vector3(0.01, 0.02, 0), Vector3(0, 0.02, 0), Vector3(0.01, 0.01, 0), Vector3(0.02, 0.01, 0), Vector3(0.02, 0.03, 0), Vector3(0.01, 0.03, 0)], [[0, 1, 2, 3], [4, 5, 6, 7]]],
		"a 10 x 10 square against the middle of a 30 mm side": [[Vector3(0, 0, 0), Vector3(0.01, 0, 0), Vector3(0.01, 0.03, 0), Vector3(0, 0.03, 0), Vector3(0.01, 0.01, 0), Vector3(0.02, 0.01, 0), Vector3(0.02, 0.02, 0), Vector3(0.01, 0.02, 0)], [[0, 1, 2, 3], [4, 5, 6, 7]]],
		"10 x 20 beside 10 x 30 sharing the bottom corner": [[Vector3(0, 0, 0), Vector3(0.01, 0, 0), Vector3(0.01, 0.02, 0), Vector3(0, 0.02, 0), Vector3(0.01, 0, 0), Vector3(0.02, 0, 0), Vector3(0.02, 0.03, 0), Vector3(0.01, 0.03, 0)], [[0, 1, 2, 3], [1, 5, 6, 7]]],
		"two faces with corners at different places on the shared side": [[Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 0.5, 0), Vector3(1, 1, 0), Vector3(0, 1, 0), Vector3(2, 0, 0), Vector3(2, 1, 0), Vector3(1, 0.25, 0)], [[0, 1, 2, 3, 4], [1, 5, 6, 3, 7]]],
	}
	for label: String in sheets:
		var read := _read("regress_r3_sheet.obj", _obj_text(sheets[label][0], sheets[label][1]))
		var r: Dictionary = read.mesh.check() if read.ok else {}
		_expect(read.ok and read.warning == "" and r.boundary_loops == 1 and r.manifold and r.degenerate_triangles == 0,
			"%s: the faces should be joined into one sheet with one outline and no warning (ok=%s, check %s, '%s')." % [label, read.ok, r, read.warning])
	for heights: Array in [[0.3333, 0.6667, 0.3333, 0.6667], [0.2, 0.4, 0.6, 0.8]]:
		for item in [["", Transform3D.IDENTITY], [" tilted", tilt]]:
			var read := _read("regress_r3_staggered.obj", _staggered_box(heights, item[1]))
			var r: Dictionary = read.mesh.check() if read.ok else {}
			_expect(read.ok and read.warning == "" and r.closed and r.manifold and r.degenerate_triangles == 0 and absf(read.mesh.volume() - 1.2e-5) < 1e-9,
				"A box whose side faces are split at heights %s%s should read closed, 12,000 mm3 (ok=%s, check %s, volume %s, '%s')." % [heights, item[0], read.ok, r, read.mesh.volume() if read.ok else 0.0, read.warning])
	# The same place written as two vertices: the warning names Stitch and Remove, and it works.
	var twice := _read("regress_r3_twice.obj", _obj_text([Vector3(0, 0, 0), Vector3(0.01, 0, 0), Vector3(0.01, 0.02, 0), Vector3(0, 0.02, 0), Vector3(0.01, 0, 0), Vector3(0.02, 0, 0), Vector3(0.02, 0.03, 0), Vector3(0.01, 0.03, 0)], [[0, 1, 2, 3], [4, 5, 6, 7]]))
	var stitched: RefCounted = twice.mesh.stitch_and_remove({}) if twice.ok else null
	var rs: Dictionary = stitched.check() if stitched != null else {}
	_expect(twice.ok and _has_all(twice.warning, ["on another whose corners are written twice","Stitch and Remove can join them"]) and rs.get("boundary_loops", -1) == 1 and rs.get("manifold", false),
		"Faces whose shared edge has its corners written twice should be read with a warning that sends to Stitch and Remove, and Stitch and Remove should join them (ok=%s, '%s'; after Stitch %s)." % [twice.ok, twice.warning, rs])
	# A corner near a side but off it: warned, without promising what Stitch cannot do.
	for off: float in [0.0002, 0.02]:
		var near := _read("regress_r3_near.obj", _obj_text([Vector3(0, 0, 0), Vector3(0.02, 0, 0), Vector3(0.02, 0.02, 0), Vector3(0, 0.02, 0), Vector3(0.03, 0, 0), Vector3(0.03, 0.01, 0), Vector3(0.02 + off * MM, 0.01, 0), Vector3(0.03, 0.02, 0)], [[0, 1, 2, 3], [1, 4, 5, 6], [6, 5, 7, 2]]))
		_expect(near.ok and _has_all(near.warning, ["near one of its sides", "off", "open there"]) and not near.warning.contains("Stitch"),
			"A corner %s mm off a neighbour's side should be warned of, without sending to Stitch and Remove (ok=%s, '%s')." % [off, near.ok, near.warning])
	# Broken faces: mended or left out, and counted.
	var square := [Vector3(0, 0, 0), Vector3(0.01, 0, 0), Vector3(0.01, 0.01, 0), Vector3(0, 0.01, 0)]
	for faces: Array in [[[0, 1, 1, 2, 3]], [[0, 1, 2, 3, 0]]]:
		var mended := _read("regress_r3_repeat.obj", _obj_text(square, faces))
		var r: Dictionary = mended.mesh.check() if mended.ok else {}
		_expect(mended.ok and mended.mesh.triangle_count() == 2 and r.degenerate_triangles == 0 and r.non_manifold_edges == 0 and _has_all(mended.warning, ["1 face names a corner twice in a row", "line 5"]),
			"A face that names a corner twice in a row (%s) should lose the repeat, with a counted warning (ok=%s, %d triangles, check %s, '%s')." % [faces, mended.ok, mended.mesh.triangle_count() if mended.ok else 0, r, mended.warning])
	var lined := _read("regress_r3_line.obj", _obj_text([Vector3(0, 0, 0), Vector3(0.01, 0, 0), Vector3(0.01, 0.01, 0), Vector3(0, 0.01, 0), Vector3(0.02, 0, 0)], [[0, 1, 2, 3], [0, 1, 4]]))
	_expect(lined.ok and lined.mesh.triangle_count() == 2 and lined.mesh.check().degenerate_triangles == 0 and _has_all(lined.warning, ["1 face has no area", "left out", "line 7"]),
		"A face whose corners lie on one line should be left out with a counted warning (ok=%s, '%s')." % [lined.ok, lined.warning])
	var only := _read("regress_r3_only_line.obj", _obj_text([Vector3(0, 0, 0), Vector3(0.01, 0, 0), Vector3(0.02, 0, 0)], [[0, 1, 2]]))
	_expect(not only.ok and only.error.contains("no faces with area"), "A file whose only face has no area should be refused as such (ok=%s, '%s', '%s')." % [only.ok, only.error, only.warning])
	checked.append("OBJ, third round (a staircase prism plain, tilted and turned: closed, no needles; sheets meeting part-way, also overlapping part of a side and with corners at different places: joined; boxes with side faces split at different heights, plain and tilted: closed; an edge written twice: sent to Stitch and Remove, which joins it; corners 0.0002 and 0.02 mm off a side: warned; faces that repeat a corner: mended and counted; faces without area: left out and counted)")


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error(message)
		print("FAIL: ", message)
