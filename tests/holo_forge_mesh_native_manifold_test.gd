extends SceneTree
## Holo Forge Mesh workspace, native class CadMesh, part 3 (Stage N3: the ops on Manifold and on our
## own voxel code). Phase 7 work order 5.1, checks 27 to 36, plus Merge and Texture Extrude:
##   27, 28  boolean (join, cut, intersect: volumes, closed, face groups kept, refusals)
##           merge_with (triangles put together, names kept apart, caps)
##   29-31   plane_cut (closed: trim with an even fill, the cut's triangles found by run id,
##           split volumes; open: our own clipper; Split Faces; an open tube's cut filled)
##   32      wrap (gaps closed up to twice the gap; wider ones refused by name)
##   33      rebuild (two crossing spheres become one clean solid)
##   34      shell (accurate: the wall, measured here too; fast; a wall that does not fit)
##   35      a boolean that cannot fit its time (refused before work; and, with the estimate
##           skipped, stopped by the watchdog)
##   36      separate (voids stay with their shells; islands and groups come apart)
##           displace (Texture Extrude: depth reached, the border untouched, closed stays closed)
## and timing ratios for a boolean of 2 x 200k triangles, a plane cut of 1M and a wrap of 2M cells.
## (HOLO_FORGE_TIMING_SLOWDOWN=3 fails the three timing checks: checked on 2026-11-11.)
##
## godot --headless --path . --script res://tests/holo_forge_mesh_native_manifold_test.gd

const FIXTURES := preload("res://tests/holo_forge_mesh_fixtures.gd")
const TIMING := preload("res://tests/holo_forge_timing.gd")

const MM := 0.001

## Timing ratio limits (work order 5.7): 2 x the ratio measured on the dev machine (Ryzen 9 5900HX)
## on 2026-11-11 against a sphere make + tessellate calibration of about 3.4 ms. Each op runs
## whole: the ingest, the library call, the way back and the checks on the result.
const LIMITS := {
	"boolean_2x200k": 470.0,   # measured 971-995 ms, ratio 225-233 (limit of the work order: 3 s): about 0.20 s of
	                           # ingest for each box, 0.20 s boolean, 0.02 s back, 0.3 s of checks on the result
	"plane_cut_1m": 980.0,     # measured 2174-2525 ms, ratio 478-488 (limit 5 s): ingest 1.0 s, the trim 0.9 s,
	                           # back and checks 0.2 s
	"wrap_2m_cells": 1310.0,   # measured 2763-2784 ms at 1,906,624 cells, ratio 656 (limit 15 s): our own field
	                           # 0.9 s, LevelSet 1.6 s, checks 0.25 s
}

var failures: Array[String] = []
var checked: Array[String] = []
var kernel: RefCounted


func _init() -> void:
	call_deferred("run")


func run() -> void:
	if not ClassDB.class_exists("CadMesh") or not ClassDB.class_exists("CadKernel"):
		print("NOTE: CadMesh is not registered (the holo_forge native DLL is missing): native mesh checks skipped.")
		print("PASS holo_forge_mesh_native_manifold: skipped, the native library is not loaded.")
		quit(0)
		return
	kernel = ClassDB.instantiate("CadKernel")
	_check_boolean()
	_check_merge()
	_check_plane_cut_closed()
	_check_plane_cut_open()
	_check_wrap()
	_check_rebuild()
	_check_shell()
	_check_separate()
	_check_displace()
	_check_defaults_and_ranges()
	_check_cancel()
	_check_timing()
	print(("PASS holo_forge_mesh_native_manifold: " + "; ".join(checked) + ".") if failures.is_empty() else "FAIL holo_forge_mesh_native_manifold")
	quit(0 if failures.is_empty() else 1)


func _new() -> RefCounted:
	return ClassDB.instantiate("CadMesh")


func _mesh(fixture: Dictionary) -> RefCounted:
	var mesh := _new()
	_expect(mesh.set_arrays(fixture.positions, fixture.indices, fixture.groups, fixture.names, "godot"), "A fixture should load (%s)." % mesh.get_last_error())
	return mesh


func _closed(mesh: RefCounted) -> bool:
	if mesh == null or mesh.is_null():
		return false
	var c: Dictionary = mesh.check(10.0)
	return c.get("closed", false) and c.get("manifold", false)


func _near(value: float, wanted: float, relative: float) -> bool:
	return absf(value - wanted) <= relative * absf(wanted)


## The box of check 12 as a mesh body: 6 groups named after the box's faces.
func _box_mesh(size: Vector3) -> RefCounted:
	var mesh := _new()
	_expect(mesh.from_shape(kernel.make_box(size), 0.002, 0.3, false, 20.0), "A box should tessellate (%s)." % mesh.get_last_error())
	return mesh


## The triangle areas of a mesh, added up in doubles.
func _area(mesh: RefCounted) -> float:
	var arrays: Dictionary = mesh.get_arrays()
	return FIXTURES.volume_and_area({"positions": arrays.positions, "indices": arrays.indices}).area


# ---------------------------------------------------------------- 27, 28


func _check_boolean() -> void:
	var two := FIXTURES.two_cubes(Vector3(10 * MM, 0, 0))
	var a := _mesh(two.first)
	var b := _mesh(two.second)
	var wanted := {"join": 12000.0, "cut": 4000.0, "intersect": 4000.0}
	var volumes := {}
	for op: String in wanted:
		var out: RefCounted = a.boolean([b], {"operation": op})
		_expect(out != null and a.get_last_error() == "" and a.get_last_warning() == "", "Combine %s of two cubes should work with no warning ('%s', '%s')." % [op, a.get_last_error(), a.get_last_warning()])
		if out == null:
			continue
		volumes[op] = out.volume() * 1e9
		_expect(_near(out.volume() * 1e9, wanted[op], 1e-6) and _closed(out),
			"Combine %s of two 20 mm cubes 10 mm apart should be closed with %s mm3 (got %s)." % [op, wanted[op], out.volume() * 1e9])
		var report: Dictionary = a.get_last_report()
		_expect(report.get("op", "") == "boolean" and report.checks.get("closed", "") == "ok" and report.checks.get("volume", "") == "ok" and report.checks.get("export", "") == "ok",
			"Combine's report should hold its checks (%s)." % [report.get("checks", {})])
	# 28: the face groups of both inputs come through under their names.
	var joined: RefCounted = a.boolean([b], {"operation": "join"})
	_expect(joined != null and joined.get_face_names() == PackedStringArray(["a", "b"]) and a.get_last_report().groups_lost == 0,
		"A join should keep both inputs' face group names (%s)." % [joined.get_face_names() if joined != null else "null"])
	# A name both have is told apart; the box's six groups stay on its six faces.
	var box := _box_mesh(Vector3(20, 20, 20) * MM)
	var other: RefCounted = _mesh(two.first).transformed(Transform3D(Basis.IDENTITY, Vector3(25, 10, 10) * MM))
	var mixed: RefCounted = box.boolean([other], {"operation": "join", "name": "Box", "tool_names": ["Cube"]})
	_expect(mixed != null and mixed.group_count() == 7 and _closed(mixed), "A box joined with a cube should have 7 groups and be closed (%s)." % box.get_last_error())
	if mixed != null:
		var names: PackedStringArray = mixed.get_face_names()
		_expect(names.slice(0, 6) == box.get_face_names() and names[6] == "a", "The box's group names should lead, then the tool's (%s)." % [names])
		var arrays: Dictionary = mixed.get_arrays()
		var on_face := true
		var low: int = mixed.find_face("box:x-")
		for t in arrays.groups.size():
			if arrays.groups[t] == low:
				for k in 3:
					on_face = on_face and absf(arrays.positions[arrays.indices[t * 3 + k]].x) < 1e-9
		_expect(low >= 0 and mixed.group_triangles(low).size() > 0 and on_face, "Every triangle of group box:x- should still lie on the box's x = 0 face.")
		_expect(_near(mixed.volume() * 1e9, 8000.0 + 8000.0 - 5.0 * 20.0 * 20.0, 1e-6), "Box and cube overlap by 5 mm: 14,000 mm3 (got %s)." % (mixed.volume() * 1e9))
	var same := _mesh(FIXTURES.icosphere(0.02, 2))
	var same_moved: RefCounted = same.transformed(Transform3D(Basis.IDENTITY, Vector3(0.01, 0, 0)))
	var clash: RefCounted = same.boolean([same_moved], {"operation": "join"})
	_expect(clash != null and clash.get_face_names() == PackedStringArray(["g0", "g0 (2)"]), "Two inputs with a group g0 should give g0 and g0 (2) (%s)." % [clash.get_face_names() if clash != null else same.get_last_error()])
	# Three bodies at once, and a cut by two tools.
	var c: RefCounted = _mesh(two.first).transformed(Transform3D(Basis.IDENTITY, Vector3(0, 10, 0) * MM))
	var three: RefCounted = a.boolean([b, c], {"operation": "join"})
	# (3 x 8,000, less the three overlaps of 4,000, 4,000 and 2,000, plus the 2,000 all three share.)
	_expect(three != null and _near(three.volume() * 1e9, 16000.0, 1e-6) and _closed(three),
		"Three cubes joined should have 16,000 mm3 (got %s; %s)." % [three.volume() * 1e9 if three != null else 0.0, a.get_last_error()])
	var cut_twice: RefCounted = a.boolean([b, c], {"operation": "cut"})
	_expect(cut_twice != null and _near(cut_twice.volume() * 1e9, 2000.0, 1e-6), "A cube cut by two cubes should keep 2,000 mm3 (got %s)." % (cut_twice.volume() * 1e9 if cut_twice != null else 0.0))
	# Refusals: before any work, each saying what to do.
	var apart: RefCounted = _mesh(two.first).transformed(Transform3D(Basis.IDENTITY, Vector3(0.1, 0, 0)))
	_expect(a.boolean([apart], {"operation": "intersect"}) == null and a.get_last_error() == "The result is empty (the bodies do not overlap).", "An empty intersection should be an error ('%s')." % a.get_last_error())
	# The report's "empty" flag is what callers read to tell "no overlap" from any other failure.
	_expect(a.get_last_report().get("empty", false) == true and a.get_last_report().get("op", "") == "boolean", "An empty intersection should set \"empty\": true in the report (%s)." % [a.get_last_report()])
	var gone: RefCounted = a.boolean([_mesh(FIXTURES.icosphere(0.05, 2))], {"operation": "cut"})
	_expect(gone != null and gone.is_null() and a.get_last_warning().contains("is empty") and a.get_last_report().get("empty", false) == true,
		"A cut that removes everything should give an empty mesh with a warning and the flag ('%s', '%s')." % [a.get_last_warning(), a.get_last_error()])
	_expect(a.boolean([b], {"operation": "intersect"}) != null and a.get_last_report().get("empty", true) == false, "A result with triangles should say \"empty\": false.")
	_expect(plate_open_refusal_has_no_flag(a), "A refusal for another reason must not set the flag.")
	var plate := _mesh(FIXTURES.open_plate())
	_expect(plate.boolean([a], {"name": "Plate"}) == null and plate.get_last_error().begins_with("Plate is not closed (128 open edges)") and plate.get_last_error().contains("Close Holes"),
		"An open target should be refused by name ('%s')." % plate.get_last_error())
	_expect(a.boolean([plate], {"tool_names": ["Sheet"]}) == null and a.get_last_error().begins_with("Sheet is not closed"), "An open tool should be refused by name ('%s')." % a.get_last_error())
	var flipped := _mesh(FIXTURES.flipped_half())
	_expect(flipped.boolean([a], {}) == null and flipped.get_last_error().contains("face the wrong way") and flipped.get_last_error().contains("Reverse Normal"),
		"A half-flipped target should be refused with Reverse Normal ('%s')." % flipped.get_last_error())
	_expect(a.boolean([], {}) == null and a.get_last_error().contains("tool body"), "No tools should be refused ('%s')." % a.get_last_error())
	_expect(a.boolean([b], {"operation": "glue"}) == null and a.get_last_error().contains("Operation must be one of"), "An unknown operation should be refused ('%s')." % a.get_last_error())
	_expect(a.boolean([kernel], {}) == null and a.get_last_error().contains("item 1"), "A tool that is no mesh should be refused ('%s')." % a.get_last_error())
	checked.append("boolean (two cubes: join %.3f, cut %.3f, intersect %.3f mm3, closed; group names kept, a clash told apart, the box's groups on its faces; 3 bodies; 8 refusals by name; an empty result sets \"empty\" in the report)" % [volumes.get("join", 0.0), volumes.get("cut", 0.0), volumes.get("intersect", 0.0)])


## An open tool is refused before any work: the report has no "empty" flag then.
func plate_open_refusal_has_no_flag(target: RefCounted) -> bool:
	var out: RefCounted = target.boolean([_mesh(FIXTURES.open_plate())], {"operation": "intersect"})
	return out == null and target.get_last_error().contains("is not closed") and not target.get_last_report().has("empty")


## A small number for a message ("3.2e-08"): GDScript's % has no %e.
func _sci(value: float) -> String:
	if value == 0.0:
		return "0"
	var exponent := floori(log(absf(value)) / log(10.0))
	return "%.1fe%d" % [value / pow(10.0, exponent), exponent]


func _check_merge() -> void:
	var two := FIXTURES.two_cubes(Vector3(30 * MM, 0, 0))
	var a := _mesh(two.first)
	var b := _mesh(two.second)
	var merged: RefCounted = a.merge_with([b])
	_expect(merged != null and merged.triangle_count() == 24 and merged.vertex_count() == 16 and merged.get_face_names() == PackedStringArray(["a", "b"]) and a.get_last_error() == "",
		"Merge of two cubes should have 24 triangles, 16 vertices and groups a, b (%s)." % a.get_last_error())
	if merged != null:
		var whole: Dictionary = _mesh(two).get_arrays()
		var got: Dictionary = merged.get_arrays()
		_expect(got.positions == whole.positions and got.indices == whole.indices and got.groups == whole.groups, "Merge should put the arrays one after the other, unchanged.")
		_expect(merged.check(5.0).closed_components == 2 and _near(merged.volume() * 1e9, 16000.0, 1e-6), "Two cubes merged are two closed parts of 16,000 mm3.")
	# Crossing bodies merge too (no boolean), an open one as well; a name both have is told apart.
	var crossing: RefCounted = a.merge_with([_mesh(FIXTURES.two_cubes(Vector3(10 * MM, 0, 0)).second), _mesh(FIXTURES.open_plate())])
	_expect(crossing != null and crossing.triangle_count() == 12 + 12 + 2048 and crossing.get_face_names() == PackedStringArray(["a", "b", "g0"]), "Merge takes crossing and open bodies (%s)." % a.get_last_error())
	var twins: RefCounted = a.merge_with([a, a])
	_expect(twins != null and twins.get_face_names() == PackedStringArray(["a", "a (2)", "a (3)"]) and twins.triangle_count() == 36, "Merge of a body with itself twice should name the groups a, a (2), a (3).")
	_expect(a.merge_with([]) == null and a.get_last_error().contains("at least one"), "Merge with nothing should be refused ('%s')." % a.get_last_error())
	_expect(a.merge_with([_new()]) == null and a.get_last_error().contains("item 1"), "Merge with an empty mesh should be refused ('%s')." % a.get_last_error())
	_expect(a.merge_with([kernel]) == null and a.get_last_error().contains("item 1"), "Merge with something that is no mesh should be refused ('%s')." % a.get_last_error())
	var big := _mesh(FIXTURES.large_grid(290))
	var started := Time.get_ticks_msec()
	_expect(big.merge_with([big]) == null and big.get_last_error().contains("2,018,400") and big.get_last_error().contains("2,000,000"), "Merge over the cap should be refused with the numbers ('%s')." % big.get_last_error())
	_expect(Time.get_ticks_msec() - started < 200, "The cap refusal should come before any copy.")
	checked.append("merge_with (24 triangles, arrays unchanged, names a, b; crossing and open bodies; a, a (2), a (3); 4 refusals, the cap in under 0.2 s)")


# ---------------------------------------------------------------- 29, 30


func _check_plane_cut_closed() -> void:
	var r := 0.05
	var ball := _mesh(FIXTURES.icosphere(r, 5))
	var plane := {"origin": Vector3(0, 0, 0.01), "normal": Vector3(0, 0, 1)}
	# 29: trim with the even fill.
	var parts: Array = ball.plane_cut(plane.merged({"type": "trim", "fill": "uniform"}))
	_expect(parts.size() == 2 and parts[0] != null and parts[1] == null and ball.get_last_error() == "", "Trim should give the upper part alone (%s)." % ball.get_last_error())
	var h := 0.04
	var cap_volume := PI * h * h * (3.0 * r - h) / 3.0
	var top_volume := 0.0
	if parts.size() == 2 and parts[0] != null:
		var top: RefCounted = parts[0]
		top_volume = top.volume()
		_expect(_closed(top) and _near(top.volume(), cap_volume, 0.005), "The trimmed ball should be closed with the cap's volume within 0.5 %% (got %s of %s)." % [top.volume(), cap_volume])
		_expect(top.get_face_names() == PackedStringArray(["g0", "cut0"]) and ball.get_last_warning() == "", "The cut face should be the new group cut0, with no warning ('%s')." % ball.get_last_warning())
		var report: Dictionary = ball.get_last_report()
		_expect(report.get("through_manifold", false) and report.get("cut_group", "") == "cut0" and report.checks.get("closed", "") == "ok" and report.get("cap_triangles", 0) > 2000,
			"The report should say the cut went through Manifold, and how many triangles the cut face has (%s)." % [report.get("checks", {})])
		# The even fill: every cut triangle on the plane, facing down, with edges about as long as the ball's.
		var arrays: Dictionary = top.get_arrays()
		var cut: int = top.find_face("cut0")
		var on_plane := true
		var facing := true
		var longest := 0.0
		var count := 0
		for t in arrays.groups.size():
			if arrays.groups[t] != cut:
				continue
			count += 1
			var p0: Vector3 = arrays.positions[arrays.indices[t * 3]]
			var p1: Vector3 = arrays.positions[arrays.indices[t * 3 + 2]]
			var p2: Vector3 = arrays.positions[arrays.indices[t * 3 + 1]]
			for p: Vector3 in [p0, p1, p2]:
				on_plane = on_plane and absf(p.z - 0.01) < 1e-7
			facing = facing and (p1 - p0).cross(p2 - p0).z <= 0.0
			longest = maxf(longest, maxf(p0.distance_to(p1), maxf(p1.distance_to(p2), p2.distance_to(p0))))
		var edge := 2.0 * PI * r / (5.0 * 32.0)  # about the ball's edge length
		_expect(on_plane and facing and count > 2000 and longest < 3.0 * edge, "The even fill should lie on the plane, face down and have ball-sized triangles (%d triangles, longest edge %s, ball edge about %s)." % [count, longest, edge])
		# The same cut filled plainly has far fewer cut triangles and the same volume.
		var plain: Array = ball.plane_cut(plane.merged({"type": "trim", "fill": "minimal"}))
		_expect(plain.size() == 2 and plain[0] != null and _closed(plain[0]) and _near(plain[0].volume(), top.volume(), 1e-9) and plain[0].group_triangles(plain[0].find_face("cut0")).size() < count / 4,
			"The plain fill should close the cut with fewer triangles and the same volume.")
		# No fill: the cut stays open, with as many open edges as the cut loop has.
		var open_cut: Array = ball.plane_cut(plane.merged({"type": "trim", "fill": "none"}))
		_expect(open_cut.size() == 2 and open_cut[0] != null and open_cut[0].get_face_names() == PackedStringArray(["g0"]) and open_cut[0].check(5.0).boundary_loops == 1 \
			and open_cut[0].check(5.0).boundary_edges == plain[0].group_triangles(plain[0].find_face("cut0")).size() + 2,
			"Fill None should leave one open loop (a loop of n edges is filled by n - 2 triangles).")
		# Keep Other Side.
		var other: Array = ball.plane_cut(plane.merged({"type": "trim", "fill": "minimal", "flip": true}))
		_expect(other.size() == 2 and other[0] == null and other[1] != null and _near(other[1].volume() + top.volume(), ball.volume(), 1e-6), "Keep Other Side should give the lower part.")
	# 29: the cut's triangles are found by run id. The 6-group box cut at half height.
	var box := _box_mesh(Vector3(20, 20, 20) * MM)
	var half: Array = box.plane_cut({"origin": Vector3(10, 10, 10) * MM, "normal": Vector3(0, 1, 0), "type": "trim", "fill": "minimal"})
	_expect(half.size() == 2 and half[0] != null and box.get_last_error() == "", "The box should cut at half height (%s)." % box.get_last_error())
	if half.size() == 2 and half[0] != null:
		var kept: RefCounted = half[0]
		var names: PackedStringArray = kept.get_face_names()
		_expect(names == PackedStringArray(["box:x-", "box:x+", "box:y+", "box:z-", "box:z+", "cut0"]), "The upper half should keep 5 face groups by name and gain cut0 (%s)." % [names])
		var arrays: Dictionary = kept.get_arrays()
		var cut: int = kept.find_face("cut0")
		var cut_on_plane := true
		var others_off := true
		for t in arrays.groups.size():
			var all_on := true
			for k in 3:
				all_on = all_on and absf(arrays.positions[arrays.indices[t * 3 + k]].y - 10 * MM) < 1e-9
			if arrays.groups[t] == cut:
				cut_on_plane = cut_on_plane and all_on
			else:
				others_off = others_off and not all_on
		_expect(cut_on_plane and others_off and kept.group_triangles(cut).size() == 2 and _near(kept.volume() * 1e9, 4000.0, 1e-6) and _closed(kept),
			"cut0 should be exactly the triangles on the plane, and the half 4,000 mm3 (got %s)." % (kept.volume() * 1e9))
	# The same box cut exactly on its bottom face: Manifold would give an empty side with no error.
	for flip in [false, true]:
		var nothing: Array = box.plane_cut({"origin": Vector3.ZERO, "normal": Vector3(0, 1, 0), "type": "trim", "fill": "minimal", "flip": flip, "name": "Box"})
		_expect(nothing.is_empty() and box.get_last_error() == "The plane does not cut Box.", "A plane on the bottom face should be refused ('%s')." % box.get_last_error())
	_expect(box.plane_cut({"origin": Vector3(0, 0.03, 0), "normal": Vector3(0, 1, 0)}).is_empty() and box.get_last_error().contains("does not cut"), "A plane that misses should be refused.")
	# A cut along a face the body already has: the cut triangles are not mistaken for the body's.
	var lifted := _box_mesh(Vector3(20, 20, 20) * MM)
	var slab: Array = lifted.plane_cut({"origin": Vector3(0, 5, 0) * MM, "normal": Vector3(0, 1, 0), "type": "split_body", "fill": "minimal"})
	_expect(slab.size() == 2 and slab[0] != null and slab[1] != null and slab[1].find_face("box:y-") >= 0 and slab[1].group_triangles(slab[1].find_face("box:y-")).size() == 2 \
		and slab[1].group_triangles(slab[1].find_face("cut0")).size() == 2 and slab[0].find_face("box:y-") == -1,
		"The lower slab should keep its bottom face group and gain cut0; the upper part should have no bottom group.")
	# 30: split body, the volumes add up.
	var both: Array = ball.plane_cut(plane.merged({"type": "split_body", "fill": "uniform"}))
	_expect(both.size() == 2 and both[0] != null and both[1] != null, "Split Body should give two parts (%s)." % ball.get_last_error())
	var sum_error := 1.0
	if both.size() == 2 and both[0] != null and both[1] != null:
		sum_error = absf(both[0].volume() + both[1].volume() - ball.volume()) / ball.volume()
		_expect(sum_error <= 1e-6 and _closed(both[0]) and _closed(both[1]), "The two parts' volumes should add up to the ball's within 1e-6 (off by %s)." % sum_error)
		_expect(both[0].find_face("cut0") >= 0 and both[1].find_face("cut0") >= 0 and ball.get_last_report().parts.size() == 2, "Both parts should have a cut0 group and a report.")
	# An oblique cut of a hollow body: the void is cut too, and both parts stay closed.
	var hollow := _mesh(FIXTURES.hollow_cube(false))
	var halves: Array = hollow.plane_cut({"origin": Vector3(1, 2, 0.5) * MM, "normal": Vector3(1, 0.3, 0.2), "type": "split_body", "fill": "uniform"})
	_expect(halves.size() == 2 and halves[0] != null and halves[1] != null and _closed(halves[0]) and _closed(halves[1]) \
		and absf(halves[0].volume() + halves[1].volume() - 7000e-9) <= 7000e-9 * 1e-6 and halves[0].check(5.0).components == 1,
		"A hollow cube cut obliquely should give two closed parts of 7,000 mm3 together (%s)." % hollow.get_last_error())
	# A body with no open edge that is still no solid (half its triangles face the wrong way): it is
	# cut by our own clipper, and the cut that cannot be filled is said, with the reason.
	var flipped := _mesh(FIXTURES.flipped_half())
	var odd: Array = flipped.plane_cut({"origin": Vector3(0, 0.01, 0), "normal": Vector3(0, 1, 0), "name": "Ball"})
	_expect(odd.size() == 2 and odd[0] != null and flipped.get_last_warning().begins_with("The cut could not be filled (") and flipped.get_last_warning().contains("Ball has triangles that face the wrong way") \
		and not flipped.get_last_report().get("through_manifold", true), "A half-flipped ball should be cut with a warning that says why the cut stays open ('%s', '%s')." % [flipped.get_last_warning(), flipped.get_last_error()])
	# Bad input is refused by field name.
	_expect(ball.plane_cut({"origin": Vector3.ZERO}).is_empty() and ball.get_last_error().contains("normal"), "A cut with no normal should be refused ('%s')." % ball.get_last_error())
	_expect(ball.plane_cut(plane.merged({"offset": 1.0})).is_empty() and ball.get_last_error().begins_with("Offset must be between"), "An offset out of range should be refused ('%s')." % ball.get_last_error())
	_expect(ball.plane_cut(plane.merged({"fill": "foam"})).is_empty() and ball.get_last_error().begins_with("Fill must be one of"), "An unknown fill should be refused ('%s')." % ball.get_last_error())
	checked.append("plane_cut closed (ball trimmed at z = 10 mm: closed, %.4f of the cap's volume, even fill on the plane; plain fill; Fill None; cut0 found by id on the box, 5 groups kept; a plane on the bottom face refused; split volumes off by %s; a hollow cube cut obliquely)" % [top_volume / cap_volume, _sci(sum_error)])


# ---------------------------------------------------------------- 31


## An open tube along Y: `rings` rings of `around` vertices, radius 10 mm, height 30 mm.
func _tube(around: int, rings: int) -> Dictionary:
	var positions := PackedVector3Array()
	for j in rings:
		for i in around:
			var angle := TAU * i / around
			positions.append(Vector3(0.01 * cos(angle), 0.03 * j / (rings - 1), 0.01 * sin(angle)))
	var godot := PackedInt32Array()
	for j in rings - 1:
		for i in around:
			var a := j * around + i
			var b := j * around + (i + 1) % around
			var c := a + around
			var d := b + around
			# Counter-clockwise seen from outside is (a, c, b), (b, c, d); Godot's order is turned.
			godot.append_array([a, b, c, b, d, c])
	var groups := PackedInt32Array()
	groups.resize(godot.size() / 3)
	return {"positions": positions, "indices": godot, "groups": groups, "names": PackedStringArray(["wall"])}


func _check_plane_cut_open() -> void:
	var plate := _mesh(FIXTURES.open_plate())
	var parts: Array = plate.plane_cut({"origin": Vector3.ZERO, "normal": Vector3(1, 0, 0), "type": "split_body"})
	_expect(parts.size() == 2 and parts[0] != null and parts[1] != null and plate.get_last_error() == "", "The open plate should split in two (%s)." % plate.get_last_error())
	var area_error := 1.0
	if parts.size() == 2 and parts[0] != null and parts[1] != null:
		area_error = absf(_area(parts[0]) + _area(parts[1]) - _area(plate)) / _area(plate)
		_expect(area_error <= 1e-9 and parts[0].is_surface() and parts[1].is_surface(), "The two open parts' areas should add up to the plate's within 1e-9 (off by %s)." % area_error)
		_expect(parts[0].bbox().position.x >= -1e-9 and parts[1].bbox().end.x <= 1e-9, "The first part should lie on the normal's side.")
		_expect(plate.get_last_warning() == "32 cut edges stay open (the body was open there).", "An open cut should be said ('%s')." % plate.get_last_warning())
		_expect(not plate.get_last_report().get("through_manifold", true), "An open body should go through our own clipper.")
	# A plane that crosses triangles: every crossed triangle is split, the areas still add up.
	var slanted: Array = plate.plane_cut({"origin": Vector3(0.0031, 0, 0), "normal": Vector3(1, 0, 0.37), "type": "split_body", "fill": "none"})
	_expect(slanted.size() == 2 and slanted[0] != null and slanted[1] != null and absf(_area(slanted[0]) + _area(slanted[1]) - _area(plate)) <= 1e-6 * _area(plate) \
		and slanted[0].triangle_count() + slanted[1].triangle_count() > 2048 and plate.get_last_warning() == "",
		"A slanted cut should split the crossed triangles and keep the area ('%s')." % plate.get_last_warning())
	# An open tube: the cut is a closed loop, so it is filled; the far end stays open.
	var tube := _mesh(_tube(48, 7))
	var cut: Array = tube.plane_cut({"origin": Vector3(0, 0.0125, 0), "normal": Vector3(0, 1, 0), "type": "trim", "fill": "uniform", "flip": true})
	_expect(cut.size() == 2 and cut[1] != null and tube.get_last_warning() == "", "The tube should cut with its loop filled ('%s', '%s')." % [tube.get_last_error(), tube.get_last_warning()])
	if cut.size() == 2 and cut[1] != null:
		var lower: RefCounted = cut[1]
		var c: Dictionary = lower.check(5.0)
		_expect(c.boundary_loops == 1 and c.boundary_edges == 48 and lower.find_face("cut0") >= 0 and c.non_manifold_edges == 0, "The lower tube should be open only at its far end (%s)." % [c])
		var lid_area := 0.0
		var arrays: Dictionary = lower.get_arrays()
		var lid: int = lower.find_face("cut0")
		var up := true
		for t in arrays.groups.size():
			if arrays.groups[t] == lid:
				var p0: Vector3 = arrays.positions[arrays.indices[t * 3]]
				var p1: Vector3 = arrays.positions[arrays.indices[t * 3 + 2]]
				var p2: Vector3 = arrays.positions[arrays.indices[t * 3 + 1]]
				var n := (p1 - p0).cross(p2 - p0)
				up = up and n.y > 0.0
				lid_area += 0.5 * n.length()
		var polygon_area := 0.5 * 48 * 0.01 * 0.01 * sin(TAU / 48)
		_expect(up and _near(lid_area, polygon_area, 1e-6), "The lid should face up and have the 48-gon's area (%s of %s)." % [lid_area, polygon_area])
	# Split Faces: nothing is removed; the upper side of the crossed group becomes a group of its own.
	var ball := _mesh(FIXTURES.icosphere(0.05, 4))
	var split: Array = ball.plane_cut({"origin": Vector3(0, 0, 0.0123), "normal": Vector3(0, 0, 1), "type": "split_faces"})
	_expect(split.size() == 2 and split[0] != null and split[1] == null, "Split Faces should give one body (%s)." % ball.get_last_error())
	if split.size() == 2 and split[0] != null:
		var whole: RefCounted = split[0]
		_expect(_closed(whole) and whole.get_face_names() == PackedStringArray(["g0", "g0_cut"]) and whole.triangle_count() > 5120 and _near(whole.volume(), ball.volume(), 1e-9),
			"Split Faces should keep the ball closed and whole, with a new group g0_cut (%s; %s)." % [whole.get_face_names(), whole.volume() / ball.volume()])
		var arrays: Dictionary = whole.get_arrays()
		var upper: int = whole.find_face("g0_cut")
		var sorted := true
		for t in arrays.groups.size():
			var z: float = (arrays.positions[arrays.indices[t * 3]].z + arrays.positions[arrays.indices[t * 3 + 1]].z + arrays.positions[arrays.indices[t * 3 + 2]].z) / 3.0
			sorted = sorted and ((z > 0.0123) == (arrays.groups[t] == upper))
		_expect(sorted, "Every triangle above the plane, and no other, should be in g0_cut.")
	checked.append("plane_cut open (plate split at x = 0: two open parts, areas off by %s, open cut said; a slanted cut; a tube's cut loop filled, facing up; Split Faces keeps the ball closed with g0_cut)" % _sci(area_error))


# ---------------------------------------------------------------- 32


## The bumpy ball of holed_blob() with only one small hole: the triangles within `radius` (along
## the sphere) of a fixed point taken out.
func _one_hole_blob(radius: float) -> Dictionary:
	var reference: Dictionary = FIXTURES.holed_blob().reference
	var centre := Vector3(1, 0.2, 0.1).normalized()
	var positions: PackedVector3Array = reference.positions
	var indices: PackedInt32Array = reference.indices
	var kept := PackedInt32Array()
	for i in range(0, indices.size(), 3):
		var dir := (positions[indices[i]] + positions[indices[i + 1]] + positions[indices[i + 2]]).normalized()
		if acos(clampf(dir.dot(centre), -1.0, 1.0)) * 0.05 > radius:
			kept.append_array([indices[i], indices[i + 1], indices[i + 2]])
	var groups := PackedInt32Array()
	groups.resize(kept.size() / 3)
	return {"positions": positions, "indices": kept, "groups": groups, "names": PackedStringArray(["g0"])}


func _check_wrap() -> void:
	var fixture := FIXTURES.holed_blob()
	var blob := _mesh(fixture)
	var reference := _mesh(fixture.reference)
	# The gap closes openings up to about twice its size. The blob's holes are 6 to 40 mm across:
	# a 26 mm gap closes them all.
	var wrapped: RefCounted = blob.wrap({"detail": 1.5 * MM, "gap": 26 * MM})
	_expect(wrapped != null and blob.get_last_error() == "", "Wrap should close the holed blob (%s)." % blob.get_last_error())
	var ratio := 0.0
	if wrapped != null:
		ratio = wrapped.volume() / reference.volume()
		var c: Dictionary = wrapped.check(10.0)
		_expect(c.closed and c.manifold and c.oriented and c.components == 1 and c.self_intersections == 0, "The wrap should be one clean closed solid (%s)." % [c])
		_expect(absf(ratio - 1.0) <= 0.03, "The wrap's volume should be within 3 %% of the blob without holes (ratio %s)." % ratio)
		_expect(wrapped.get_face_names() == PackedStringArray(["wrap0"]), "The wrap should be one group wrap0 (%s)." % [wrapped.get_face_names()])
		_expect(blob.get_last_warning() == "Edges are rounded to about 1.5 mm.", "Wrap should always add its note about rounded edges, and nothing else here ('%s')." % blob.get_last_warning())
		var report: Dictionary = blob.get_last_report()
		_expect(report.checks.get("closed", "") == "ok" and report.checks.get("covered", "") == "ok" and report.deviation.samples > 1000 and report.deviation.max < 6 * MM and report.deviation.mean < 0.5 * MM,
			"The report should say every part of the input is in the wrap, and how far the input is from it (%s; %s)." % [report.get("checks", {}), report.get("deviation", {})])
	# Small holes with a small gap: the 3 mm hole (6 mm across) closes with a 4 mm gap.
	var small := _mesh(_one_hole_blob(3 * MM))
	_expect(small.check(5.0).boundary_loops == 1, "The one-hole blob should have one open loop.")
	var closed_small: RefCounted = small.wrap({"detail": 1.25 * MM, "gap": 4 * MM})
	var small_ratio := 0.0
	if closed_small != null:
		small_ratio = closed_small.volume() / reference.volume()
	_expect(closed_small != null and _closed(closed_small) and absf(small_ratio - 1.0) <= 0.01, "A 4 mm gap should close a hole 6 mm across; volume within 1 %% (ratio %s; %s)." % [small_ratio, small.get_last_error()])
	# The work order's numbers (detail 1 mm, gap 3 mm) cannot close holes up to 40 mm across:
	# the outside reaches in, nothing is enclosed, and Wrap says so (with the size of the opening).
	var started := Time.get_ticks_msec()
	var open_wrap: RefCounted = blob.wrap({"detail": 1 * MM, "gap": 3 * MM, "name": "Blob"})
	_expect(open_wrap == null and blob.get_last_error().begins_with("Wrap would leave about 9") and blob.get_last_error().contains(" % of Blob out: ") and blob.get_last_error().contains("wider than 6 mm") \
		and blob.get_last_error().contains("largest opening is about 3"), "A gap too small for the holes should be an error that says so ('%s')." % blob.get_last_error())
	# A flat open sheet has nothing behind it at all.
	var sheet := _mesh(FIXTURES.open_plate())
	_expect(sheet.wrap({}) == null and sheet.get_last_error().begins_with("Wrap would leave all of the body out"), "An open sheet should be refused ('%s')." % sheet.get_last_error())
	var around: RefCounted = sheet.wrap({"offset": 1 * MM, "detail": 0.5 * MM})
	_expect(around != null and _closed(around) and _near(around.volume() * 1e9, 3200.0 + 160.0 * PI / 2.0 + 4.0 / 3.0 * PI, 0.05), "With an offset the sheet's wrap is a 2 mm slab around it (%s mm3; %s)." % [around.volume() * 1e9 if around != null else 0.0, sheet.get_last_error()])
	var refused_ms := Time.get_ticks_msec() - started
	# An offset: the wrap of the closed ball grown by 2 mm.
	var ball := _mesh(FIXTURES.icosphere(0.05, 4))
	var grown: RefCounted = ball.wrap({"detail": 1.5 * MM, "offset": 2 * MM})
	_expect(grown != null and _near(grown.volume(), 4.0 / 3.0 * PI * pow(0.052, 3), 0.01), "A ball wrapped with a 2 mm offset should have the volume of a 52 mm ball within 1 %% (%s)." % ball.get_last_error())
	var shrunk: RefCounted = ball.wrap({"detail": 1.5 * MM, "gap": 4 * MM, "offset": -3 * MM})
	_expect(shrunk != null and _near(shrunk.volume(), 4.0 / 3.0 * PI * pow(0.047, 3), 0.01), "A ball wrapped with a -3 mm offset should have the volume of a 47 mm ball within 1 %% (%s)." % ball.get_last_error())
	# Over budget: refused at once, with the cell size that fits.
	started = Time.get_ticks_msec()
	var d: float = ball.op_defaults("wrap", {}).detail_min
	_expect(ball.wrap({"detail": d}) == null and ball.get_last_error().begins_with("Wrap needs ") and ball.get_last_error().contains("million cells; raise Detail to"),
		"A grid over the cap should be refused with the cell size that fits ('%s')." % ball.get_last_error())
	_expect(Time.get_ticks_msec() - started < 200, "The grid refusal should come before any work.")
	_expect(ball.wrap({"detail": d * 0.5}) == null and ball.get_last_error().begins_with("Detail must be between"), "A detail below its range should be refused by name ('%s')." % ball.get_last_error())
	_expect(ball.wrap({"detail": 2 * MM, "gap": 1 * MM}) == null and ball.get_last_error().begins_with("Close Gaps Up To must be between"), "A gap below the detail should be refused ('%s')." % ball.get_last_error())
	_expect(ball.wrap({"detail": 2 * MM, "gap": 4 * MM, "offset": -5 * MM}) == null and ball.get_last_error().begins_with("Offset must be between"), "An offset below -gap should be refused ('%s')." % ball.get_last_error())
	checked.append("wrap (holed blob, gap 26 mm: one closed solid, volume ratio %.4f; a 6 mm hole closed by a 4 mm gap, ratio %.4f; the gap of 3 mm refused in %d ms saying the openings are wider; offsets +2 and -3 mm; the grid cap and 3 ranges refused)" % [ratio, small_ratio, refused_ms])


# ---------------------------------------------------------------- 33


func _check_rebuild() -> void:
	var fixture := FIXTURES.self_crossing()
	var crossing := _mesh(fixture)
	_expect(crossing.check(5.0).self_intersections > 0, "The fixture should cross itself.")
	var union: RefCounted = _mesh(fixture.first).boolean([_mesh(fixture.second)], {"operation": "join"})
	_expect(union != null, "The two spheres should join (the reference volume).")
	if union == null:
		return
	var ratios := {}
	for method: String in ["union", "exact_surface"]:
		var rebuilt: RefCounted = crossing.rebuild({"method": method})
		_expect(rebuilt != null and crossing.get_last_error() == "", "Rebuild (%s) should work (%s)." % [method, crossing.get_last_error()])
		if rebuilt == null:
			continue
		var c: Dictionary = rebuilt.check(20.0)
		ratios[method] = rebuilt.volume() / union.volume()
		_expect(c.closed and c.manifold and c.self_intersections == 0 and c.components == 1 and c.inverted_components == 0, "The rebuilt mesh should be one clean closed solid (%s)." % [c])
		_expect(absf(ratios[method] - 1.0) <= 0.02, "Rebuild's volume should be within 2 %% of the union's (ratio %s)." % ratios[method])
		var warning: String = crossing.get_last_warning()
		_expect(warning.contains("Rebuild changed the volume by -15") and warning.contains("Edges are rounded to about") and warning.split("\n").size() == 2,
			"Rebuild should report the volume change (overlaps count once) and the rounded edges ('%s')." % warning)
		if method == "exact_surface":
			_expect(crossing.get_last_report().snapped_vertices > rebuilt.vertex_count() / 2, "Exact Surface should move most vertices onto the input.")
			# On the input: every vertex of the result within a hair of one of the two spheres' facets.
			var far: Dictionary = rebuilt.distance_to(crossing, 5000, 10.0)
			_expect(far.max < 0.2 * MM, "With Exact Surface the result should lie on the input (max %s)." % far.max)
	# The default cell size is raised to fit the grid cap, and says so in the defaults.
	var defaults: Dictionary = crossing.op_defaults("rebuild", {})
	var d: float = crossing.bbox().size.length()
	_expect(defaults.detail > d / 250.0 and defaults.cells <= 2000000 and defaults.cells > 1500000, "Rebuild's default detail should be raised to fit 2,000,000 cells (%s)." % [defaults])
	# An open input: still a result, with the warning that says what was assumed.
	var open_ball := _mesh(_one_hole_blob(8 * MM))
	var patched: RefCounted = open_ball.rebuild({"detail": 1 * MM, "name": "Blob"})
	_expect(patched != null and _closed(patched) and open_ball.get_last_warning().begins_with("Blob has open edges; Rebuild treats them as closed"), "An open input should rebuild with a warning ('%s', '%s')." % [open_ball.get_last_warning(), open_ball.get_last_error()])
	# A hollow body keeps its void.
	var hollow := _mesh(FIXTURES.hollow_cube(false))
	var remade: RefCounted = hollow.rebuild({"detail": 0.25 * MM})
	_expect(remade != null and remade.check(10.0).components == 2 and remade.check(10.0).inverted_components == 0 and _near(remade.volume() * 1e9, 7000.0, 0.02),
		"A hollow cube should rebuild as a shell and a void, 7,000 mm3 within 2 %% (%s; %s)." % [remade.volume() * 1e9 if remade != null else 0.0, hollow.get_last_error()])
	# Flipped bits: a ball with its lower half turned inside-out comes back as the ball (the winding
	# number is useless there, so Rebuild counts crossings, and says so).
	var flipped := _mesh(FIXTURES.flipped_half())
	var whole_ball := _mesh(FIXTURES.icosphere(0.05, 3))
	var righted: RefCounted = flipped.rebuild({"detail": 1 * MM, "name": "Ball"})
	_expect(righted != null and _closed(righted) and righted.check(10.0).components == 1 and _near(righted.volume(), whole_ball.volume(), 0.02) \
		and flipped.get_last_warning().contains("Ball has triangles that face the wrong way") and flipped.get_last_warning().contains("Reverse Normal"),
		"A half-flipped ball should rebuild as the ball within 2 %%, with a warning (%s of %s; '%s')." % [righted.volume() if righted != null else 0.0, whole_ball.volume(), flipped.get_last_warning()])
	_expect(crossing.rebuild({"method": "magic"}) == null and crossing.get_last_error().begins_with("Method must be one of"), "An unknown method should be refused.")
	checked.append("rebuild (two crossing spheres: closed, manifold, 0 self-intersections, volume ratio to the union %.4f, exact surface %.4f; the default detail raised to the grid cap; an open input warned; a hollow cube keeps its void)" % [ratios.get("union", 0.0), ratios.get("exact_surface", 0.0)])


# ---------------------------------------------------------------- 34


## The share of 400 triangles of `group` (evenly spaced) whose middle lies within low .. high x
## thickness of the sphere of radius r: the test's own wall measure, by the sphere's formula.
func _wall_share(mesh: RefCounted, group: int, r: float, thickness: float) -> float:
	var arrays: Dictionary = mesh.get_arrays()
	var tris: PackedInt32Array = mesh.group_triangles(group)
	var within := 0
	var samples := 0
	var step := maxi(1, tris.size() / 400)
	for i in range(0, tris.size(), step):
		var t := tris[i]
		var middle: Vector3 = (arrays.positions[arrays.indices[t * 3]] + arrays.positions[arrays.indices[t * 3 + 1]] + arrays.positions[arrays.indices[t * 3 + 2]]) / 3.0
		var wall := absf(r - middle.length())
		samples += 1
		if wall >= 0.8 * thickness and wall <= 1.2 * thickness:
			within += 1
	return float(within) / maxf(1.0, samples)


func _check_shell() -> void:
	var r := 0.05
	var t := 2 * MM
	var ball := _mesh(FIXTURES.icosphere(r, 5))
	var shares := {}
	for direction: String in ["inside", "outside", "both"]:
		var shell: RefCounted = ball.shell({"thickness": t, "direction": direction, "method": "accurate"})
		_expect(shell != null and ball.get_last_error() == "" and ball.get_last_warning() == "", "Shell accurate %s should work with no warning ('%s', '%s')." % [direction, ball.get_last_error(), ball.get_last_warning()])
		if shell == null:
			continue
		var c: Dictionary = shell.check(20.0)
		_expect(c.closed and c.manifold and c.components == 2 and c.inverted_components == 0 and c.self_intersections == 0, "The %s shell should be a closed shell around a void (%s)." % [direction, c])
		var wall: Dictionary = ball.get_last_report().wall
		_expect(wall.samples == 400 and wall.within >= 0.95 and ball.get_last_report().checks.get("wall", "") == "ok", "The wall check should pass at 95 %% of 400 samples (%s)." % [wall])
		var inner_r := r - t if direction == "inside" else (r if direction == "outside" else r - t / 2)
		var outer_r := r if direction == "inside" else (r + t if direction == "outside" else r + t / 2)
		var exact := 4.0 / 3.0 * PI * (pow(outer_r, 3) - pow(inner_r, 3))
		_expect(_near(shell.volume(), exact, 0.03), "The %s shell's volume should be the spherical shell's within 3 %% (%s of %s)." % [direction, shell.volume(), exact])
		if direction == "inside":
			_expect(shell.get_face_names() == PackedStringArray(["g0", "shell0"]), "The ball's group should stay on the outside and the new wall be shell0 (%s)." % [shell.get_face_names()])
			# The outer surface is the input's, to the bit.
			var got: Dictionary = shell.get_arrays()
			var had: Dictionary = ball.get_arrays()
			var outer: PackedInt32Array = shell.group_triangles(0)
			var same := outer.size() == 20480
			var seen := {}
			for v: Vector3 in had.positions:
				seen[v] = true
			for i in range(0, outer.size(), 97):
				for k in 3:
					same = same and seen.has(got.positions[got.indices[outer[i] * 3 + k]])
			_expect(same, "Inside: the outer surface should be the ball's own triangles (%d of 20,480)." % outer.size())
			# The test's own measure: the new wall's triangles against the sphere's formula.
			shares[direction] = _wall_share(shell, shell.find_face("shell0"), r, t)
			_expect(shares[direction] >= 0.95, "Measured here, 95 %% of the inner wall should be 0.8 to 1.2 x 2 mm from the ball (%s)." % shares[direction])
		elif direction == "outside":
			shares[direction] = _wall_share(shell, shell.find_face("shell0"), r, t)
			_expect(shares[direction] >= 0.95, "Measured here, 95 %% of the outer wall should be 0.8 to 1.2 x 2 mm from the ball (%s)." % shares[direction])
	# Fast: a closed ball inwards, an open plate both ways (with a rim), a cube.
	var fast: RefCounted = ball.shell({"thickness": t, "method": "fast"})
	_expect(fast != null and _closed(fast) and fast.triangle_count() == 40960 and ball.get_last_warning() == "" and ball.get_last_report().wall.within >= 0.95 \
		and _wall_share(fast, fast.find_face("shell0"), r, t) >= 0.95, "The fast shell of a ball should be closed, 2 x the triangles, with the wall right ('%s')." % ball.get_last_warning())
	var plate := _mesh(FIXTURES.open_plate())
	var sheet: RefCounted = plate.shell({"thickness": 1 * MM, "direction": "both", "method": "fast"})
	_expect(sheet != null and _closed(sheet) and sheet.get_face_names() == PackedStringArray(["g0", "shell0", "shell1"]) and _near(sheet.volume() * 1e9, 1600.0, 1e-5) \
		and sheet.triangle_count() == 2048 * 2 + 128 * 2, "The fast shell of the open plate should be a closed 40 x 40 x 1 mm sheet with a rim (%s)." % plate.get_last_error())
	var cube := _mesh(FIXTURES.two_cubes(Vector3.ZERO).first)
	var box: RefCounted = cube.shell({"thickness": 2 * MM, "direction": "inside", "method": "fast"})
	_expect(box != null and _near(box.volume() * 1e9, 8000.0 - 16.0 * 16.0 * 16.0, 1e-5) and cube.get_last_warning() == "", "A cube's fast shell should leave a 16 mm void: sharp corners keep the wall (%s mm3; '%s')." % [box.volume() * 1e9 if box != null else 0.0, cube.get_last_warning()])
	var outward: RefCounted = cube.shell({"thickness": 2 * MM, "direction": "outside", "method": "fast"})
	_expect(outward != null and _near(outward.volume() * 1e9, 24.0 * 24.0 * 24.0 - 8000.0, 1e-5) and outward.get_face_names() == PackedStringArray(["a", "shell0"]),
		"A cube's outward fast shell should be a 24 mm cube around the old one, which keeps its group (%s)." % [outward.get_face_names() if outward != null else cube.get_last_error()])
	# A concave body: the fast shell either passes its wall check or says what is off, in numbers.
	var crossing := _mesh(FIXTURES.self_crossing().first)
	var dented: RefCounted = _mesh(FIXTURES.l_bracket()).shell({"thickness": 3 * MM, "direction": "outside", "method": "fast"}) if not FIXTURES.l_bracket().is_empty() else null
	_expect(dented != null and _closed(dented), "The L-bracket should get a closed fast shell.")
	# (Never neither: the wall check passed, or the warning says what is off, with numbers.)
	var bracket_mesh: RefCounted = FIXTURES.l_bracket().mesh
	var dented_again: RefCounted = bracket_mesh.shell({"thickness": 3 * MM, "direction": "outside", "method": "fast"})
	_expect(dented_again != null and (bracket_mesh.get_last_report().checks.get("wall", "") == "ok" \
		or (bracket_mesh.get_last_warning().contains("The wall is off:") and bracket_mesh.get_last_warning().contains("% of 400 samples")) or bracket_mesh.get_last_warning().contains("crosses itself in")),
		"A fast shell that fails its wall check must say so with numbers ('%s')." % bracket_mesh.get_last_warning())
	# A body that crosses itself: the accurate shell refuses by name, it does not blame itself.
	var tangled := _mesh(FIXTURES.self_crossing())
	_expect(tangled.shell({"thickness": 1 * MM, "name": "Pair"}) == null and tangled.get_last_error().begins_with("Pair crosses itself in") and tangled.get_last_error().ends_with("Rebuild it first."),
		"The accurate shell of a self-crossing body should be refused with Rebuild ('%s')." % tangled.get_last_error())
	# A wall that does not fit: refused before work, with the thinnest size.
	var flat: RefCounted = cube.transformed(Transform3D(Basis.from_scale(Vector3(1, 0.1, 1)), Vector3.ZERO))
	var started := Time.get_ticks_msec()
	for method: String in ["fast", "accurate"]:
		_expect(flat.shell({"thickness": 1.5 * MM, "method": method, "name": "Slab"}) == null and flat.get_last_error() == "A 1.5 mm wall does not fit in Slab (thinnest part about 2 mm).",
			"A 1.5 mm wall in a 2 mm slab should be refused (%s: '%s')." % [method, flat.get_last_error()])
	_expect(Time.get_ticks_msec() - started < 200, "The refusal should come before any work.")
	_expect(flat.shell({"thickness": 0.9 * MM, "method": "fast"}) != null, "A 0.9 mm wall fits in a 2 mm slab.")
	# Open bodies have no inside for the accurate method; Both works.
	_expect(plate.shell({"thickness": 1 * MM, "direction": "inside"}) == null and plate.get_last_error() == "An open body has no inside; use Both, or Close Holes first.", "Accurate inside on an open body should be refused ('%s')." % plate.get_last_error())
	var band: RefCounted = plate.shell({"thickness": 2 * MM, "direction": "both", "method": "accurate"})
	_expect(band != null and _closed(band) and _near(band.volume() * 1e9, 3200.0 + 160.0 * PI / 2.0 + 4.0 / 3.0 * PI, 0.02) and plate.get_last_report().wall.within >= 0.95,
		"Accurate Both on the open plate should be a 2 mm band around it (%s mm3; %s)." % [band.volume() * 1e9 if band != null else 0.0, plate.get_last_error()])
	_expect(ball.shell({"thickness": 1.0}) == null and ball.get_last_error().begins_with("Thickness must be between"), "A thickness out of range should be refused by name.")
	_expect(ball.shell({"thickness": t, "detail": t}) == null and ball.get_last_error().begins_with("Detail must be between"), "A detail out of range should be refused by name ('%s')." % ball.get_last_error())
	_expect(ball.shell({"thickness": 0.2 * MM}) == null and ball.get_last_error().contains("million cells") and ball.get_last_error().contains("Fast method"),
		"A wall too thin for the grid should be refused with a way out ('%s')." % ball.get_last_error())
	crossing = null
	checked.append("shell (accurate inside, outside, both on a ball: closed, a shell around a void, wall within 0.8 to 1.2 x 2 mm at 100 %% of the op's samples and %.0f %% / %.0f %% of the test's own; fast: ball, open plate with rim, cube; a wall that does not fit refused with the size; open bodies)" % [shares.get("inside", 0.0) * 100.0, shares.get("outside", 0.0) * 100.0])


# ---------------------------------------------------------------- 36


func _check_separate() -> void:
	var two := _mesh(FIXTURES.two_cubes(Vector3(30 * MM, 0, 0)))
	var pieces: Array = two.separate({})
	_expect(pieces.size() == 2 and pieces[0].triangle_count() == 12 and pieces[1].triangle_count() == 12 and two.get_last_warning() == "" and two.get_last_error() == "",
		"Two cubes in one mesh should separate into 2 meshes of 12 triangles ('%s')." % two.get_last_error())
	if pieces.size() == 2:
		var whole: Dictionary = two.get_arrays()
		var first: Dictionary = pieces[0].get_arrays()
		var second: Dictionary = pieces[1].get_arrays()
		var moved_down := PackedInt32Array()
		for id: int in whole.indices.slice(36, 72):
			moved_down.append(id - 8)
		_expect(first.positions == whole.positions.slice(0, 8) and second.positions == whole.positions.slice(8, 16) and first.indices == whole.indices.slice(0, 36) and second.indices == moved_down,
			"The pieces should hold the input's own vertices and triangles, in order, to the bit.")
		_expect(pieces[0].get_face_names() == PackedStringArray(["g0"]) and pieces[1].get_face_names() == PackedStringArray(["g1"]), "Each piece keeps its own group name.")
		_expect(two.get_last_report().get("through_manifold", false) and two.get_last_report().output.pieces == 2, "A closed body should go through Manifold's Decompose (%s)." % [two.get_last_report()])
	# A hollow cube is one piece: the void stays with its shell.
	var hollow := _mesh(FIXTURES.hollow_cube(false))
	var one: Array = hollow.separate({"name": "Shell"})
	_expect(one.size() == 1 and one[0].triangle_count() == 24 and _near(one[0].volume() * 1e9, 7000.0, 1e-6) and hollow.get_last_warning() == "Shell is one piece; nothing to separate.",
		"A hollow cube should stay one piece of 24 triangles and 7,000 mm3, with the warning ('%s')." % hollow.get_last_warning())
	_expect(hollow.get_last_report().get("voids_attached", 0) == 1, "The report should say one void was put back with its shell.")
	# With an island in the void: the shell with its void, and the island.
	var island := _mesh(FIXTURES.hollow_cube(true))
	var parts: Array = island.separate({})
	_expect(parts.size() == 2 and parts[0].triangle_count() == 24 and _near(parts[0].volume() * 1e9, 7000.0, 1e-6) and parts[1].triangle_count() == 12 and _near(parts[1].volume() * 1e9, 64.0, 1e-6) \
		and island.get_last_warning() == "", "A hollow cube with an island should give 24 triangles at 7,000 mm3 and 12 at 64 mm3 ('%s')." % island.get_last_warning())
	# A void with no shell around it is an inside-out piece, and is said.
	var fixture := FIXTURES.hollow_cube(false)
	var loose: PackedVector3Array = fixture.positions.duplicate()
	for v in range(8, 16):
		loose[v] += Vector3(0.05, 0, 0)
	var stray := _mesh({"positions": loose, "indices": fixture.indices, "groups": fixture.groups, "names": fixture.names})
	var strays: Array = stray.separate({})
	_expect(strays.size() == 2 and stray.get_last_warning() == "1 piece is inside-out. Reverse Normal can fix it.", "A void outside any shell should be its own piece, with a warning ('%s')." % stray.get_last_warning())
	# By groups, and open bodies by their connected parts.
	var by_groups: Array = two.separate({"by": "groups"})
	_expect(by_groups.size() == 2 and by_groups[1].get_face_names() == PackedStringArray(["g1"]) and not two.get_last_report().get("through_manifold", true), "Separate by groups should give one body per group.")
	var plate := FIXTURES.open_plate()
	var twice: PackedVector3Array = plate.positions.duplicate()
	for p: Vector3 in plate.positions:
		twice.append(p + Vector3(0, 0.01, 0))
	var twice_indices: PackedInt32Array = plate.indices.duplicate()
	for id: int in plate.indices:
		twice_indices.append(id + plate.positions.size())
	var sheets := _new()
	sheets.set_arrays(twice, twice_indices)
	var open_parts: Array = sheets.separate({})
	_expect(open_parts.size() == 2 and open_parts[0].triangle_count() == 2048 and open_parts[1].triangle_count() == 2048 and open_parts[1].is_surface(), "Two open plates in one mesh should separate (%s)." % sheets.get_last_error())
	_expect(two.separate({"by": "colour"}).is_empty() and two.get_last_error().begins_with("Separate By must be one of"), "An unknown mode should be refused.")
	checked.append("separate (two cubes: 2 x 12 triangles, the input's arrays to the bit; a hollow cube stays one piece of 7,000 mm3; with an island: 24 + 12 triangles; a stray void said; by groups; open parts)")


# ---------------------------------------------------------------- displace (Texture Extrude)


func _checker(size: int) -> PackedByteArray:
	var image := PackedByteArray()
	image.resize(size * size)
	for y in size:
		for x in size:
			image[y * size + x] = 255 if ((x / (size / 8)) + (y / (size / 8))) % 2 == 0 else 0
	return image


func _check_displace() -> void:
	var plate := _mesh(FIXTURES.open_plate())
	var image := _checker(64)
	var depth := 0.5 * MM
	var bumped: RefCounted = plate.displace({"image": image, "width": 64, "height": 64, "depth": depth})
	_expect(bumped != null and plate.get_last_error() == "" and plate.get_last_warning() == "", "Texture Extrude on the plate should work ('%s', '%s')." % [plate.get_last_error(), plate.get_last_warning()])
	var triangles := 0
	if bumped != null:
		triangles = bumped.triangle_count()
		var box: AABB = bumped.bbox()
		_expect(_near(box.end.y, depth, 0.01) and absf(box.position.y) < 1e-9, "The highest point should be the depth within 1 %% (%s of %s)." % [box.end.y, depth])
		_expect(_near(plate.get_last_report().max_displacement, depth, 1e-6), "The report should hold the largest displacement.")
		# The border: the plate's own rim vertices are where they were, to the bit, and no vertex on the rim moved.
		var before: Dictionary = plate.get_arrays()
		var after: Dictionary = bumped.get_arrays()
		var rim_same := true
		var rim_flat := true
		for v in before.positions.size():
			var p: Vector3 = before.positions[v]
			if absf(absf(p.x) - 0.02) < 1e-9 or absf(absf(p.z) - 0.02) < 1e-9:
				rim_same = rim_same and after.positions[v] == p
		for p: Vector3 in after.positions:
			if absf(absf(p.x) - 0.02) < 1e-9 or absf(absf(p.z) - 0.02) < 1e-9:
				rim_flat = rim_flat and p.y == 0.0
		_expect(rim_same and rim_flat, "The plate's border should be unchanged to the bit, and stay flat.")
		# The detail: tile / 128 by default (the plate's diagonal / 5 / 128), edges at most 4/3 of it.
		var detail: float = plate.get_last_report().detail
		_expect(_near(detail, plate.bbox().size.length() / 5.0 / 128.0, 1e-5) and bumped.triangle_count() > 300000, "The default detail should be tile / 128 (%s) and refine the plate (%d triangles)." % [detail, bumped.triangle_count()])
		# Black squares stay down, white ones go up by the depth.
		var levels := {}
		for p: Vector3 in after.positions:
			levels[snappedf(p.y / depth, 0.01)] = int(levels.get(snappedf(p.y / depth, 0.01), 0)) + 1
		_expect(int(levels.get(0.0, 0)) > 50000 and int(levels.get(1.0, 0)) > 50000, "About half the plate should stay down and half go up (%d down, %d up)." % [int(levels.get(0.0, 0)), int(levels.get(1.0, 0))])
	# A selection on a closed body: only the selection changes, and the body stays closed.
	var ball := _mesh(FIXTURES.icosphere(0.05, 4))
	var top := PackedInt32Array()
	var arrays: Dictionary = ball.get_arrays()
	for t in ball.triangle_count():
		if (arrays.positions[arrays.indices[t * 3]] + arrays.positions[arrays.indices[t * 3 + 1]] + arrays.positions[arrays.indices[t * 3 + 2]]).y > 0.12:
			top.append(t)
	var white := PackedByteArray()
	white.resize(16)
	white.fill(255)
	var raised: RefCounted = ball.displace({"image": white, "width": 4, "height": 4, "depth": 1 * MM, "tile": 0.02, "detail": 0.002, "triangles": top, "mapping": "planar"})
	_expect(raised != null and _closed(raised) and ball.get_last_error() == "", "A texture on part of a ball should keep it closed (%s)." % ball.get_last_error())
	if raised != null:
		var got: Dictionary = raised.get_arrays()
		var selected := {}
		for t in top:
			selected[t] = true
		# Outside the selection nothing moves: every vertex a triangle outside it uses is where it was, to
		# the bit, and every triangle that does not touch the selection is in the result as it was. (The
		# triangles right at the border are split along the border's edges, in their own plane.)
		var made := {}
		for i in range(0, got.indices.size(), 3):
			made[[got.positions[got.indices[i]], got.positions[got.indices[i + 1]], got.positions[got.indices[i + 2]]]] = true
		var in_selection := {}
		for t: int in top:
			for k in 3:
				in_selection[arrays.indices[t * 3 + k]] = true
		var untouched := true
		var vertices_same := true
		var outside := 0
		for t in ball.triangle_count():
			if selected.has(t):
				continue
			var apart := true
			for k in 3:
				var v: int = arrays.indices[t * 3 + k]
				vertices_same = vertices_same and got.positions[v] == arrays.positions[v]
				apart = apart and not in_selection.has(v)
			if apart:
				outside += 1
				untouched = untouched and made.has([arrays.positions[arrays.indices[t * 3]], arrays.positions[arrays.indices[t * 3 + 1]], arrays.positions[arrays.indices[t * 3 + 2]]])
		_expect(untouched and vertices_same and outside > 4000, "Outside the selection every vertex and every triangle that does not touch it should be unchanged to the bit (%d triangles looked at)." % outside)
		# Refining alone keeps the shape: with a black image nothing moves, so the volume and the area
		# are the ball's (the new vertices lie on the old edges, the border's triangles are split in place).
		var black := PackedByteArray()
		black.resize(16)
		var refined: RefCounted = ball.displace({"image": black, "width": 4, "height": 4, "depth": 1 * MM, "tile": 0.02, "detail": 0.002, "triangles": top, "mapping": "planar"})
		_expect(refined != null and refined.triangle_count() == raised.triangle_count() and _closed(refined) and _near(refined.volume(), ball.volume(), 1e-6) and _near(_area(refined), _area(ball), 1e-6) \
			and ball.get_last_report().moved_vertices == 0, "With a black image the refined ball should keep its volume and area (%s)." % ball.get_last_error())
		_expect(raised.bbox().end.y > 0.0505 and raised.bbox().end.y < 0.0512 and raised.volume() > ball.volume(), "The selection should be raised by about 1 mm (top at %s)." % raised.bbox().end.y)
	# Too deep on a tight curve: the crossings are counted and said.
	var small := _mesh(FIXTURES.icosphere(0.004, 3))
	var spiky: RefCounted = small.displace({"image": _checker(8), "width": 8, "height": 8, "depth": -0.0008, "tile": 0.002, "detail": 0.00025, "mapping": "cylindrical"})
	_expect(spiky != null and (small.get_last_warning() == "" or small.get_last_warning().contains("lower the Depth")), "A deep texture either works or says where it crosses itself ('%s', '%s')." % [small.get_last_warning(), small.get_last_error()])
	# Refusals.
	_expect(plate.displace({"depth": depth}) == null and plate.get_last_error().contains("needs an image"), "No image should be refused ('%s')." % plate.get_last_error())
	_expect(plate.displace({"image": image, "width": 64, "height": 63, "depth": depth}) == null and plate.get_last_error().contains("64 x 63"), "A wrong image size should be refused ('%s')." % plate.get_last_error())
	_expect(plate.displace({"image": image, "width": 64, "height": 64, "depth": 0.0}) == null and plate.get_last_error() == "Depth must not be 0.", "Depth 0 should be refused.")
	_expect(plate.displace({"image": image, "width": 64, "height": 64, "depth": 1.0}) == null and plate.get_last_error().begins_with("Depth must be between"), "A depth out of range should be refused.")
	var started := Time.get_ticks_msec()
	_expect(plate.displace({"image": image, "width": 64, "height": 64, "depth": depth, "tile": 0.004, "detail": 0.004 / 512.0}) == null \
		and plate.get_last_error().begins_with("Texture Extrude would make about") and plate.get_last_error().ends_with("raise Detail or Tile Size."), "Too many triangles should be refused before work ('%s')." % plate.get_last_error())
	_expect(Time.get_ticks_msec() - started < 200, "The triangle refusal should come before any work.")
	_expect(plate.displace({"image": image, "width": 64, "height": 64, "depth": depth, "triangles": PackedInt32Array([99999])}) == null and plate.get_last_error().contains("triangle 99999"), "A selection past the end should be refused.")
	checked.append("displace (checker on the open plate: %d triangles, highest point = the depth, border unchanged to the bit; a selection on a ball: the rest unchanged, still closed; 6 refusals)" % triangles)


# ---------------------------------------------------------------- defaults and ranges


func _check_defaults_and_ranges() -> void:
	var ball := _mesh(FIXTURES.icosphere(0.05, 4))
	var d: float = ball.bbox().size.length()
	var wrap: Dictionary = ball.op_defaults("wrap", {})
	_expect(_near(wrap.detail, d / 150.0, 1e-5) and _near(wrap.gap, 2.0 * wrap.detail, 1e-9) and _near(wrap.detail_min, d / 400.0, 1e-5) and _near(wrap.detail_max, d / 10.0, 1e-5) \
		and _near(wrap.gap_max, d / 4.0, 1e-5) and _near(wrap.offset_max, d / 10.0, 1e-5) and wrap.seconds > 0.0 and wrap.cells < 2000000,
		"Wrap's defaults should be the work order's (D / 150, gap 2 x detail; %s)." % [wrap])
	var shell: Dictionary = ball.op_defaults("shell", {})
	_expect(_near(shell.thickness, d / 50.0, 1e-5) and _near(shell.detail, shell.thickness / 4.0, 1e-5) and _near(shell.detail_max, shell.thickness / 2.0, 1e-5), "Shell's defaults should be D / 50 and thickness / 4 (%s)." % [shell])
	var thin: Dictionary = ball.op_defaults("shell", {"thickness": 2 * MM})
	_expect(thin.detail > 0.5 * MM and thin.detail <= 1 * MM and thin.cells <= 2000000 and thin.cells > 1500000 and not thin.has("problem"), "A 2 mm wall's default detail should be raised to fit the grid, within its range (%s)." % [thin])
	var too_thin: Dictionary = ball.op_defaults("shell", {"thickness": 1 * MM})
	_expect(String(too_thin.get("problem", "")).contains("million cells for a 1 mm wall"), "A 1 mm wall cannot be resolved on a 100 mm ball: the defaults should say so (%s)." % [too_thin])
	var displace: Dictionary = ball.op_defaults("displace", {})
	_expect(_near(displace.depth, d / 200.0, 1e-5) and _near(displace.tile, d / 5.0, 1e-5) and _near(displace.detail, displace.tile / 128.0, 1e-5), "Texture Extrude's defaults should be D / 200, D / 5, tile / 128 (%s)." % [displace])
	var cut: Dictionary = ball.op_defaults("plane_cut", {"normal": Vector3.UP})
	_expect(_near(cut.offset_max, d, 1e-5) and cut.through_manifold and cut.cuts and cut.seconds > 0.0, "Plane Cut's defaults should hold the offset range and the estimate (%s)." % [cut])
	var combine: Dictionary = ball.op_defaults("boolean", {"tools": [ball]})
	_expect(combine.seconds > 0.0, "Combine's defaults should hold its estimate (%s)." % [combine])
	_expect(ball.op_defaults("nothing", {}).is_empty() and _new().op_defaults("wrap", {}).is_empty(), "Unknown ops and empty meshes have no defaults.")
	# Every range, just outside each end, is refused with the field's name.
	var count := 0
	var cases := [
		["wrap", "detail", wrap.detail_min, wrap.detail_max, "Detail", {}],
		["wrap", "gap", wrap.gap_min, wrap.gap_max, "Close Gaps Up To", {"detail": wrap.detail}],
		["wrap", "offset", wrap.offset_min, wrap.offset_max, "Offset", {"detail": wrap.detail}],
		["shell", "thickness", shell.thickness_min, shell.thickness_max, "Thickness", {"method": "fast"}],
		["shell", "detail", shell.detail_min, shell.detail_max, "Detail", {}],
		["displace", "depth", displace.depth_min, displace.depth_max, "Depth", {}],
		["displace", "tile", displace.tile_min, displace.tile_max, "Tile Size", {}],
		["displace", "detail", displace.detail_min, displace.detail_max, "Detail", {}],
		["displace", "angle", -360.0, 360.0, "Rotation", {}],
		["rebuild", "detail", ball.op_defaults("rebuild", {}).detail_min, ball.op_defaults("rebuild", {}).detail_max, "Detail", {}],
	]
	var white := PackedByteArray([255])
	for c: Array in cases:
		for end in 2:
			var value: float = c[2 + end] + (absf(c[2 + end]) * 0.001 + 1e-9) * (-1.0 if end == 0 else 1.0)
			var options: Dictionary = c[5].merged({c[1]: value, "image": white, "width": 1, "height": 1})
			var out: Variant = ball.call(c[0], options)
			_expect(out == null and ball.get_last_error().begins_with(c[4] + " must be between"), "%s %s = %s should be refused by name ('%s')." % [c[0], c[1], value, ball.get_last_error()])
			count += 1
	# A value of the wrong kind is refused too, never read as 0.
	_expect(ball.wrap({"detail": "fine"}) == null and ball.get_last_error() == "Detail must be a number.", "A text for a number should be refused ('%s')." % ball.get_last_error())
	_expect(ball.shell({"thickness": NAN}) == null and ball.get_last_error() == "Thickness must be a number.", "NaN should be refused ('%s')." % ball.get_last_error())
	checked.append("op_defaults (wrap, rebuild, shell, plane_cut, displace, boolean) and %d range refusals by field name" % count)


# ---------------------------------------------------------------- 35


func _check_cancel() -> void:
	var grid := FIXTURES.large_grid(200)
	var a := _mesh(grid)
	var b: RefCounted = a.transformed(Transform3D(Basis.IDENTITY, Vector3(0.05, 0.05, 0.05)))
	_expect(a.triangle_count() == 480000, "large_grid(200) should have 480,000 triangles.")
	# Not enough time: refused before any work, from the estimate (the ingest alone takes longer).
	var started := Time.get_ticks_usec()
	var out: RefCounted = a.boolean([b], {"operation": "join", "time_limit": 0.05})
	var refused_ms := (Time.get_ticks_usec() - started) / 1000.0
	_expect(out == null and a.get_last_error().begins_with("Combine would take about") and a.get_last_error().contains("(limit 0.05 s)") and refused_ms < 1050.0,
		"A boolean with 0.05 s should be refused from its estimate ('%s', %.0f ms)." % [a.get_last_error(), refused_ms])
	# With the estimate skipped (a test switch) the watchdog is what stops it: it must not run to
	# the end of the boolean (about 2 s here).
	var stopped_ms := []
	for limit: float in [0.05, 0.6, 1.2]:
		started = Time.get_ticks_usec()
		out = a.boolean([b], {"operation": "join", "time_limit": limit, "skip_estimate": true})
		var ms := (Time.get_ticks_usec() - started) / 1000.0
		stopped_ms.append(ms)
		_expect(out == null and a.get_last_error().begins_with("Combine took longer than") and a.get_last_error().contains("was stopped"), "The watchdog should stop the boolean ('%s')." % a.get_last_error())
		_expect(ms < limit * 1000.0 + 1000.0, "The boolean should stop within its time + 1 s (limit %s s, took %.0f ms)." % [limit, ms])
	# With time, the same boolean works.
	started = Time.get_ticks_usec()
	out = a.boolean([b], {"operation": "join"})
	var whole_ms := (Time.get_ticks_usec() - started) / 1000.0
	_expect(out != null and _near(out.volume(), 0.002 - 0.000125, 1e-6), "With time the two boxes should join: 1,875,000 mm3 (%s)." % a.get_last_error())
	_expect(stopped_ms[0] < whole_ms, "A stopped boolean should come back sooner than a whole one (%.0f against %.0f ms)." % [stopped_ms[0], whole_ms])
	# The other Manifold ops stop too.
	started = Time.get_ticks_usec()
	var cut: Array = a.plane_cut({"origin": Vector3(0.031, 0.031, 0.031), "normal": Vector3(0.3, 1, 0.2), "type": "split_body", "time_limit": 0.05, "skip_estimate": true})
	var cut_ms := (Time.get_ticks_usec() - started) / 1000.0
	_expect(cut.is_empty() and a.get_last_error().begins_with("Plane Cut took longer than") and cut_ms < 1050.0, "The watchdog should stop a plane cut ('%s', %.0f ms)." % [a.get_last_error(), cut_ms])
	var ball := _mesh(FIXTURES.icosphere(0.05, 4))
	started = Time.get_ticks_usec()
	var wrap: RefCounted = ball.wrap({"time_limit": 0.3, "skip_estimate": true})
	var wrap_ms := (Time.get_ticks_usec() - started) / 1000.0
	_expect(wrap == null and ball.get_last_error().begins_with("Wrap took longer than 0.3 s") and ball.get_last_error().ends_with("Raise Detail.") and wrap_ms < 1300.0,
		"A wrap should stop at its time ('%s', %.0f ms)." % [ball.get_last_error(), wrap_ms])
	started = Time.get_ticks_usec()
	_expect(ball.wrap({"time_limit": 0.3}) == null and ball.get_last_error().begins_with("Wrap would take about") and Time.get_ticks_usec() - started < 200000, "A wrap that cannot fit should be refused at once ('%s')." % ball.get_last_error())
	checked.append("time limits (a 2 x 480k boolean with 0.05 s: refused in %.0f ms from its estimate; with the estimate skipped the watchdog stops it after %.0f / %.0f / %.0f ms at 0.05 / 0.6 / 1.2 s, the whole boolean takes %.0f ms; plane cut stopped after %.0f ms, wrap after %.0f ms)" % [refused_ms, stopped_ms[0], stopped_ms[1], stopped_ms[2], whole_ms, cut_ms, wrap_ms])


# ---------------------------------------------------------------- timing (5.7)


func _check_timing() -> void:
	var calibration := func() -> void:
		var sphere: RefCounted = kernel.make_sphere(0.02, Vector3.ZERO, "cal")
		sphere.tessellate(0.0002, 0.3)
	var results := {}
	# Boolean join of 2 x 200k triangles (limit of the work order: 3 s).
	var grid := FIXTURES.large_grid(129)
	var a := _mesh(grid)
	var b: RefCounted = a.transformed(Transform3D(Basis.IDENTITY, Vector3(0.0503, 0.0502, 0.0501)))
	_expect(a.triangle_count() == 199692, "large_grid(129) should have 199,692 triangles.")
	var join := func() -> void:
		var x := _mesh(grid)
		var y: RefCounted = x.transformed(Transform3D(Basis.IDENTITY, Vector3(0.0503, 0.0502, 0.0501)))
		x.boolean([y], {"operation": "join"})
	results["boolean_2x200k"] = TIMING.compare(join, calibration, 3, "boolean join, 2 x 200k triangles")
	var joined: RefCounted = a.boolean([b], {"operation": "join"})
	_expect(joined != null and _closed(joined), "The timed boolean should give a closed mesh (%s)." % a.get_last_error())
	# Plane Cut of 1M triangles (limit: 5 s), trim with the plain fill, off the grid's lines.
	var big := FIXTURES.large_grid(290)
	var cut_options := {"origin": Vector3(0, 0, 0.05013), "normal": Vector3(0, 0, 1), "type": "trim", "fill": "minimal"}
	var cut := func() -> void:
		var x := _mesh(big)
		x.plane_cut(cut_options)
	results["plane_cut_1m"] = TIMING.compare(cut, calibration, 2, "plane cut, 1M triangles")
	var million := _mesh(big)
	var kept: Array = million.plane_cut(cut_options)
	_expect(kept.size() == 2 and kept[0] != null and _near(kept[0].volume(), 0.001 * (1.0 - 0.5013), 1e-6), "The timed plane cut should keep 49.87 %% of the box (%s)." % million.get_last_error())
	# Wrap at 2M cells (limit: 15 s): the default detail raised to the grid cap.
	var ball := _mesh(FIXTURES.icosphere(0.05, 5))
	var fit := 0.87 * MM  # with the default gap of 2 cells: 124 samples a side
	var cells := 0.0
	var wrap := func() -> void:
		var x := _mesh(FIXTURES.icosphere(0.05, 5))
		x.wrap({"detail": fit})
	results["wrap_2m_cells"] = TIMING.compare(wrap, calibration, 2, "wrap, 2M cells")
	var wrapped: RefCounted = ball.wrap({"detail": fit})
	if wrapped != null:
		cells = ball.get_last_report().cells
	_expect(wrapped != null and cells > 1900000 and cells <= 2000000, "The timed wrap should use just under 2,000,000 cells (%s; %s)." % [cells, ball.get_last_error()])
	var parts: Array[String] = []
	for key: String in LIMITS:
		var r: Dictionary = results[key]
		parts.append("%s %.0f ms, ratio %.1f" % [key, r.op, r.ratio])
		if LIMITS[key] > 0.0:
			_expect(r.ratio <= LIMITS[key], "%s is too slow: %.0f ms, ratio %.1f against a limit of %.1f (calibration %.2f ms)." % [key, r.op, r.ratio, LIMITS[key], r.calibration])
	checked.append("timing (%s)" % ", ".join(parts))


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error(message)
		print("FAIL: ", message)
