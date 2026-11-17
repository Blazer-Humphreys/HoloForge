extends SceneTree
## Holo Forge Mesh workspace, native ops of Stage N2: the cases an adversarial sweep (verifier V1,
## 2026-11-12) found broken, each on its smallest input.
##
## B1 Reduce (Fast) by Maximum Deviation against the time limit (a sweep over flat grid bodies);
## B2 Stitch and Remove on closed bodies that touch face to face; B3 Reduce (Fast) on pieces
## that touch at a corner; B4 Reduce (Adaptive) with Keep Face Group Borders; P1 Remesh's border
## check both ways; P2 Reduce (Adaptive) by Maximum Deviation on bodies of flat faces; P4 Smooth:
## how far it moved the surface, Keep Volume shell by shell, the sign of volume_change; P5 Close
## Holes on the outline of an open sheet; P6 the counts of Generate Face Groups; P7 the numbers
## in the time sentences; on/off options given numbers; fit_primitive on shapes that are none of
## its three; Reverse Normal on a selection.
##
## godot --headless --path . --script res://tests/holo_forge_mesh_regress_pmp_test.gd

const FIXTURES := preload("res://tests/holo_forge_mesh_fixtures.gd")

const MM := 0.001

var failures: Array[String] = []
var checked: Array[String] = []
var _started := false
var _finished := false


func _init() -> void:
	call_deferred("run")


## A script error stops run() in the middle: the test then fails here and does not hang.
func _process(_delta: float) -> bool:
	if _started and not _finished:
		print("FAIL holo_forge_mesh_regress_pmp: the test stopped on a script error.")
		_finished = true
		quit(1)
	return false


func run() -> void:
	_started = true
	if not ClassDB.class_exists("CadMesh") or not ClassDB.class_exists("CadKernel"):
		print("NOTE: CadMesh is not registered (the holo_forge native DLL is missing): native mesh checks skipped.")
		print("PASS holo_forge_mesh_regress_pmp: skipped, the native library is not loaded.")
		_finished = true
		quit(0)
		return
	var only := OS.get_environment("N2_ONLY")
	for item: Array in [["b1", _check_fast_tolerance_time], ["b2", _check_stitch_touching], ["b3", _check_fast_touching], ["b4", _check_adaptive_borders], ["p1", _check_remesh_borders],
			["p2", _check_adaptive_tolerance], ["p4", _check_smooth_says], ["p5", _check_sheet_outline], ["p6", _check_group_counts], ["p7", _check_time_sentences], ["notes", _check_notes],
			["n1", _check_fill_balloon], ["n3", _check_tolerance_dense], ["n6", _check_outline_rule], ["n7", _check_stitch_self_touch], ["n9", _check_singular], ["more", _check_more_notes], ["flat", _check_flat_holes], ["area", _check_stitch_without_area],
			["r3far", _check_far_from_origin], ["r3fill", _check_smooth_fill_kept], ["r3thin", _check_reduce_thin_plate], ["r3count", _check_reduce_count_deviation], ["r3outline", _check_picked_outline_sentence]]:
		if only == "" or only.contains(item[0]):
			(item[1] as Callable).call()
	print(("PASS holo_forge_mesh_regress_pmp: " + "; ".join(checked) + ".") if failures.is_empty() else "FAIL holo_forge_mesh_regress_pmp")
	_finished = true
	quit(0 if failures.is_empty() else 1)


func _mesh(fixture: Dictionary) -> RefCounted:
	var mesh: RefCounted = ClassDB.instantiate("CadMesh")
	_expect(mesh.set_arrays(fixture.positions, fixture.indices, fixture.groups, fixture.names, "godot"), "A fixture should load (%s)." % mesh.get_last_error())
	return mesh


func _diagonal(mesh: RefCounted) -> float:
	return mesh.bbox().size.length()


func _two_sided(a: RefCounted, b: RefCounted) -> float:
	var ab: Dictionary = a.distance_to(b, 20000, 20.0)
	var ba: Dictionary = b.distance_to(a, 20000, 20.0)
	return maxf(ab.get("max", INF), ba.get("max", INF))


## The edges between triangles of different groups, as [a, b] point pairs.
func _border_segments(mesh: RefCounted) -> Array:
	var arrays: Dictionary = mesh.get_arrays()
	var positions: PackedVector3Array = arrays.positions
	var indices: PackedInt32Array = arrays.indices
	var groups: PackedInt32Array = arrays.groups
	var first := {}
	var out := []
	var done := {}
	for i in range(0, indices.size(), 3):
		for k in 3:
			var u := indices[i + k]
			var v := indices[i + (k + 1) % 3]
			var key := (mini(u, v) << 32) | maxi(u, v)
			if not first.has(key):
				first[key] = groups[i / 3]
			elif first[key] != groups[i / 3] and not done.has(key):
				done[key] = true
				out.append([positions[u], positions[v]])
	return out


## The largest distance from the ends and middles of (at most `most`, evenly picked) segments of
## `from` to the segments `to`.
func _segments_to_segments(from: Array, to: Array, most := 100000) -> float:
	var worst := 0.0
	var step := maxi(1, from.size() / most)
	for i in range(0, from.size(), step):
		var s: Array = from[i]
		for q: Vector3 in [s[0], s[1], (s[0] + s[1]) * 0.5]:
			var best := INF
			for t: Array in to:
				var d: Vector3 = t[1] - t[0]
				var l2 := d.length_squared()
				var along := clampf((q - t[0]).dot(d) / l2, 0.0, 1.0) if l2 > 0.0 else 0.0
				best = minf(best, q.distance_to(t[0] + d * along))
			worst = maxf(worst, best)
	return worst


func _number_after(text: String, before: String) -> float:
	var at := text.find(before)
	if at < 0:
		return NAN
	var rest := text.substr(at + before.length()).strip_edges()
	var end := 0
	while end < rest.length() and (rest[end].is_valid_int() or rest[end] in [".", "-", "e", "+", ","]):
		end += 1
	return rest.substr(0, end).replace(",", "").trim_suffix(".").to_float()


# ---------------------------------------------------------------- B1


func _check_fast_tolerance_time() -> void:
	# Reduce (Fast) by a small Maximum Deviation on flat grid bodies: one library call ran 13 s on
	# 99,372 triangles at a 0.5 s limit, 409 s on 499,392 and over 509 s on 1,009,200 at 20 s. No
	# call may come back later than its limit + 1 s. (Every row is printed: "B1 row".)
	var worst_over := -INF
	var rows := 0
	var late := []
	var outcomes := {}
	var cases := []
	for n: int in [10, 20, 40, 60, 91]:
		for tolerance: float in [1.1e-6, 1e-5, 1e-4, 1e-3]:
			for limit: float in [0.5, 2.0, 20.0]:
				cases.append([n, tolerance, limit])
	for n: int in [204, 290]:
		for tolerance: float in [1.1e-6, 1e-3]:
			cases.append([n, tolerance, 20.0])
	var fixture := {}
	var fixture_n := -1
	for case: Array in cases:
		var n: int = case[0]
		var tolerance: float = case[1]
		var limit: float = case[2]
		if n != fixture_n:
			fixture = FIXTURES.large_grid(n)
			fixture_n = n
		var mesh := _mesh(fixture)
		var d := _diagonal(mesh)
		var started := Time.get_ticks_usec()
		var result: RefCounted = mesh.reduce({"target": "tolerance", "method": "fast", "tolerance": d * tolerance, "time_limit": limit})
		var seconds := (Time.get_ticks_usec() - started) / 1e6
		var error: String = mesh.get_last_error()
		var warning: String = mesh.get_last_warning()
		var calls := int(mesh.get_last_report().get("calls", 0))
		rows += 1
		worst_over = maxf(worst_over, seconds - limit)
		if seconds > limit + 1.0:
			late.append("grid %d (%d triangles), D x %s, limit %s s: %.2f s" % [n, 12 * n * n, tolerance, limit, seconds])
		_expect((result == null) == (error != ""), "Reduce (fast, tolerance D x %s) on grid %d should give a result or an error, not both or neither ('%s')." % [tolerance, n, error])
		if result == null:
			_expect(error.contains("would take about") and error.contains("(limit"), "A refusal of Reduce (fast, tolerance D x %s) on grid %d should be about the time ('%s')." % [tolerance, n, error])
		elif is_same(result, mesh):
			_expect(warning.contains("Nothing could be taken out"), "Grid %d given back by Reduce (fast, tolerance D x %s) should come with the reason ('%s')." % [n, tolerance, warning])
		elif n <= 91:
			var off := _two_sided(result, mesh)
			_expect(off <= d * tolerance, "A result of Reduce (fast, tolerance D x %s) on grid %d should be within the tolerance (%.6f mm against %.6f mm)." % [tolerance, n, off / MM, d * tolerance / MM])
		var kind := "refused" if result == null else ("unchanged" if is_same(result, mesh) else "reduced")
		outcomes[kind] = int(outcomes.get(kind, 0)) + 1
		print("B1 row: grid %d, %d triangles, tolerance D x %s, limit %s s: %.3f s, %s%s" % [n, 12 * n * n, tolerance, limit, seconds, kind,
			(" to %d triangles in %d library calls" % [result.triangle_count(), calls]) if kind == "reduced" else ((" ('%s')" % error.substr(0, 70)) if kind == "refused" else "")])
	_expect(late.is_empty(), "Reduce (fast) by tolerance should come back within its limit + 1 s; late: %s." % [late])
	checked.append("B1 Reduce (fast) by Maximum Deviation: %d calls on grid bodies of 1,200 to 1,009,200 triangles, tolerances D x 1.1e-6 to 1e-3, limits 0.5, 2 and 20 s; the slowest came back %.2f s %s its limit (%s)" 		% [rows, absf(worst_over), "over" if worst_over > 0.0 else "under", outcomes])


# ---------------------------------------------------------------- B2


func _check_stitch_touching() -> void:
	var cases := {
		"two cubes face to face": [FIXTURES.joined([FIXTURES.cube(0.02, Vector3.ZERO), FIXTURES.cube(0.02, Vector3(0.02, 0, 0))]), 16e-6],
		"three cubes in a row": [FIXTURES.joined([FIXTURES.cube(0.02, Vector3.ZERO), FIXTURES.cube(0.02, Vector3(0.02, 0, 0)), FIXTURES.cube(0.02, Vector3(0.04, 0, 0))]), 24e-6],
		"two 4 x 4 grid cubes face to face": [FIXTURES.joined([FIXTURES.large_grid(4, 0.02), FIXTURES.shifted(FIXTURES.large_grid(4, 0.02), Vector3(0.02, 0, 0))]), 16e-6],
		"two cubes edge to edge": [FIXTURES.joined([FIXTURES.cube(0.02, Vector3.ZERO), FIXTURES.cube(0.02, Vector3(0.02, 0.02, 0))]), 16e-6],
		"two cubes corner to corner": [FIXTURES.joined([FIXTURES.cube(0.02, Vector3.ZERO), FIXTURES.cube(0.02, Vector3(0.02, 0.02, 0.02))]), 16e-6],
		"a cube inside a cube, touching one face": [FIXTURES.joined([FIXTURES.cube(0.02, Vector3.ZERO), FIXTURES.cube(0.01, Vector3(0.005, 0, 0))]), 9e-6],
		"a hollow cube with an island": [FIXTURES.hollow_cube(true), 7.064e-6],
	}
	for name: String in cases:
		var mesh := _mesh(cases[name][0])
		var volume: float = cases[name][1]
		_expect(mesh.check(5.0).closed and absf(mesh.volume() - volume) <= 1e-6 * volume, "%s should start closed with %.0f mm3." % [name, volume * 1e9])
		for options: Dictionary in [{}, {"tolerance": 0.0}, {"fix_non_manifold": false}]:
			var result: RefCounted = mesh.stitch_and_remove(options)
			var error: String = mesh.get_last_error()
			if result == null:
				_expect(error != "" and options.has("fix_non_manifold"), "Stitch and Remove %s on %s should give a result (only with Fix Non-Manifold Edges off may it refuse): '%s'." % [options, name, error])
				continue
			var c: Dictionary = result.check(5.0)
			_expect(c.boundary_edges == 0 and c.closed and absf(result.volume() - volume) <= 1e-6 * volume,
				"Stitch and Remove %s on %s (closed, %.0f mm3) should leave it closed with its volume (%d open edges, closed %s, %.1f mm3; warning '%s')." \
				% [options, name, volume * 1e9, int(c.boundary_edges), c.closed, result.volume() * 1e9, mesh.get_last_warning()])
	# Two boxes 0.05 mm apart, stitched with a tolerance that joins their walls.
	var apart := _mesh(FIXTURES.joined([FIXTURES.cube(0.02, Vector3.ZERO), FIXTURES.cube(0.02, Vector3(0.02005, 0, 0))]))
	var joined: RefCounted = apart.stitch_and_remove({"tolerance": 0.0001})
	_expect(joined != null, "Stitch and Remove with a 0.1 mm tolerance on two boxes 0.05 mm apart should give a result (%s)." % apart.get_last_error())
	if joined != null:
		var jc: Dictionary = joined.check(5.0)
		_expect(jc.boundary_edges == 0 and jc.closed and absf(joined.volume() - 16e-6) <= 0.01 * 16e-6,
			"Stitch and Remove with a tolerance that joins two boxes 0.05 mm apart should leave them closed (%d open edges, %.1f mm3; '%s')." % [int(jc.boundary_edges), joined.volume() * 1e9, apart.get_last_warning()])
	else:
		_expect(apart.get_last_error() != "", "Stitch and Remove on two boxes 0.05 mm apart gave nothing and no error.")
	# The debris cube still comes out as before (true doubles go).
	var debris := _mesh(FIXTURES.cube_debris())
	var clean: RefCounted = debris.stitch_and_remove({})
	_expect(clean != null and clean.triangle_count() == 12 and clean.check(5.0).closed and debris.get_last_report().removed_duplicates == 5, "The debris cube should still come out as 12 closed triangles with 5 doubles gone.")
	checked.append("B2 Stitch and Remove on closed bodies that touch (%d bodies, 3 option sets each: closed, with their volume)" % cases.size())


# ---------------------------------------------------------------- B3


func _check_fast_touching() -> void:
	var cases := {
		"two cubes corner to corner": FIXTURES.joined([FIXTURES.cube(0.02, Vector3.ZERO), FIXTURES.cube(0.02, Vector3(0.02, 0.02, 0.02))]),
		"two 8 x 8 grid cubes corner to corner": FIXTURES.joined([FIXTURES.large_grid(8, 0.02), FIXTURES.shifted(FIXTURES.large_grid(8, 0.02), Vector3(0.02, 0.02, 0.02))]),
		"two cubes edge to edge": FIXTURES.joined([FIXTURES.cube(0.02, Vector3.ZERO), FIXTURES.cube(0.02, Vector3(0.02, 0.02, 0))]),
		"two cubes face to face": FIXTURES.joined([FIXTURES.cube(0.02, Vector3.ZERO), FIXTURES.cube(0.02, Vector3(0.02, 0, 0))]),
		"two crossing balls": FIXTURES.self_crossing(),
	}
	var calls := 0
	for name: String in cases:
		var mesh := _mesh(cases[name])
		var before: Dictionary = mesh.check(5.0)
		_expect(before.manifold and before.closed, "%s should start closed and manifold." % name)
		for options: Dictionary in [{"method": "fast"}, {"method": "fast", "proportion": 90.0}, {"method": "fast", "target": "tolerance"}]:
			var result: RefCounted = mesh.reduce(options)
			var warning: String = mesh.get_last_warning()
			calls += 1
			if result == null:
				_expect(mesh.get_last_error() != "", "Reduce %s on %s gave nothing and no error." % [options, name])
				continue
			var after: Dictionary = result.check(5.0)
			var said := warning.contains("only touch") or warning.contains("more than two triangles")
			_expect((after.manifold and after.non_manifold_vertices == 0) or said,
				"Reduce %s on %s made the body non-manifold (%d corners, %d edges) and said nothing ('%s')." % [options, name, int(after.non_manifold_vertices), int(after.non_manifold_edges), warning])
			if warning.contains("Nothing could be taken out") or warning.contains("Nothing can be taken out"):
				_expect(is_same(result, mesh), "Reduce %s on %s says nothing could be taken out, but gave a different mesh (%d vertices against %d)." % [options, name, result.vertex_count(), mesh.vertex_count()])
			if is_same(result, mesh):
				_expect(warning != "", "Reduce %s on %s gave the mesh back without a word." % [options, name])
	checked.append("B3 Reduce (fast) on pieces that touch (%d calls: manifold, or the corners and edges counted in the warning; 'nothing could be taken out' only with the mesh itself)" % calls)


# ---------------------------------------------------------------- B4


func _check_adaptive_borders() -> void:
	var notes := []
	for name: String in ["ball s3 by octants", "ball s4 by octants", "L-bracket"]:
		var mesh: RefCounted = FIXTURES.l_bracket().mesh if name == "L-bracket" else _mesh(FIXTURES.octant_groups(FIXTURES.icosphere(0.05, 3 if name.contains("s3") else 4)))
		var borders := _border_segments(mesh)
		for proportion: float in [90.0, 50.0, 20.0]:
			var result: RefCounted = mesh.reduce({"method": "adaptive", "proportion": proportion, "keep_groups": true})
			var warning: String = mesh.get_last_warning()
			var report: Dictionary = mesh.get_last_report()
			_expect(result != null, "Reduce (adaptive, keep groups) to %s %% of %s should give a result (%s)." % [proportion, name, mesh.get_last_error()])
			if result == null:
				continue
			var after := _border_segments(result)
			var moved := maxf(_segments_to_segments(after, borders), _segments_to_segments(borders, after))
			var said := warning.contains("Face group borders moved by up to")
			_expect(moved <= 1e-6 or said, "Reduce (adaptive) with Keep Face Group Borders moved the borders of %s by %.4f mm at %s %% and said nothing ('%s')." % [name, moved / MM, proportion, warning])
			if said:
				_expect(absf(_number_after(warning, "moved by up to ") - moved / MM) <= 0.05 * moved / MM + 1e-3, "The border warning should carry the measured move (%.4f mm; '%s')." % [moved / MM, warning])
			_expect(report.has("border_deviation") or is_same(result, mesh), "The Reduce report should hold border_deviation with Keep Face Group Borders.")
			_expect(result.get_face_names() == mesh.get_face_names(), "Reduce with Keep Face Group Borders should keep the groups of %s." % name)
			var target := int(round(mesh.triangle_count() * proportion / 100.0))
			if absi(result.triangle_count() - target) > int(0.02 * target):
				_expect(warning.contains("Reduce kept %s triangles" % _commas(result.triangle_count())) and warning.contains("instead of %s" % _commas(target)),
					"Off its target, Reduce should say so with the numbers (%d of %d on %s; '%s')." % [result.triangle_count(), target, name, warning])
			notes.append("%s %d %%: %d triangles, borders moved %.4f mm" % [name, int(proportion), result.triangle_count(), moved / MM])
	checked.append("B4 Reduce (adaptive) with Keep Face Group Borders (%s)" % "; ".join(notes))


func _commas(value: int) -> String:
	var text := str(value)
	var out := ""
	while text.length() > 3:
		out = "," + text.substr(text.length() - 3) + out
		text = text.substr(0, text.length() - 3)
	return text + out


# ---------------------------------------------------------------- P1


func _check_remesh_borders() -> void:
	var fixture := FIXTURES.crossing_holes()
	_expect(not fixture.is_empty(), "The crossing holes fixture should build.")
	if fixture.is_empty():
		return
	var mesh: RefCounted = fixture.mesh
	var borders := _border_segments(mesh)
	var notes := []
	for density: float in [0.25, 0.5]:
		var result: RefCounted = mesh.remesh({"density": density})
		var warning: String = mesh.get_last_warning()
		var report: Dictionary = mesh.get_last_report()
		_expect(result != null, "Remesh (density %s) of the crossing holes should give a result (%s)." % [density, mesh.get_last_error()])
		if result == null:
			continue
		var after := _border_segments(result)
		# (Every 6th input border edge against all of the result's, and the other way round.)
		var lost := _segments_to_segments(borders, after, 300)
		var stray := _segments_to_segments(after, borders, 300)
		var moved := maxf(lost, stray)
		var said := warning.contains("Face group borders moved by up to")
		_expect(moved <= 1e-6 or said, "Remesh (density %s) moved the group borders of the crossing holes by %.4f mm (input border not in the result: %.4f mm) and said nothing ('%s')." % [density, moved / MM, lost / MM, warning])
		_expect(float(report.get("border_deviation", -1.0)) >= 0.9 * moved - 1e-9, "The report's border_deviation (%.4f mm) should cover both ways (measured %.4f mm)." % [float(report.get("border_deviation", -1.0)) / MM, moved / MM])
		_expect(result.get_face_names() == mesh.get_face_names(), "Remesh should keep the groups of the crossing holes.")
		notes.append("density %s: borders moved %.6f mm, report %.6f mm" % [density, moved / MM, float(report.get("border_deviation", -1.0)) / MM])
	checked.append("P1 Remesh border check both ways (crossing holes, %s)" % "; ".join(notes))


# ---------------------------------------------------------------- P2


func _check_adaptive_tolerance() -> void:
	var notes := []
	var bodies := {"L-bracket": FIXTURES.l_bracket().mesh, "crossing holes": FIXTURES.crossing_holes().mesh, "holed blob": _mesh(FIXTURES.holed_blob())}
	for name: String in bodies:
		var mesh: RefCounted = bodies[name]
		var d := _diagonal(mesh)
		for case: Array in [[d * 1e-6, true], [d / 2000.0, true], [d / 200.0, true], [d / 20.0, true], [d / 2000.0, false], [d / 20.0, false]]:
			var options := {"method": "adaptive", "target": "tolerance", "tolerance": case[0], "keep_groups": case[1]}
			var result: RefCounted = mesh.reduce(options)
			var warning: String = mesh.get_last_warning()
			_expect(result != null, "Reduce (adaptive) by a %.4f mm deviation (keep groups %s) on the %s should give a result or the mesh itself, not '%s'." % [float(case[0]) / MM, case[1], name, mesh.get_last_error()])
			if result == null:
				continue
			if is_same(result, mesh) or result.triangle_count() == mesh.triangle_count():
				_expect(warning.contains("Nothing could be taken out") or warning.contains("Nothing can be taken out"), "An unchanged %s should come with the 'nothing' warning ('%s')." % [name, warning])
			else:
				var off := _two_sided(result, mesh)
				_expect(off <= float(case[0]), "Reduce (adaptive) by a %.4f mm deviation on the %s gave a result %.4f mm off." % [float(case[0]) / MM, name, off / MM])
			notes.append("%s %.4f mm%s: %d of %d" % [name, float(case[0]) / MM, "" if case[1] else " (groups free)", result.triangle_count(), mesh.triangle_count()])
	checked.append("P2 Reduce (adaptive) by Maximum Deviation on bodies of flat faces and round holes (%s)" % "; ".join(notes))


# ---------------------------------------------------------------- P4


func _check_smooth_says() -> void:
	var bracket: RefCounted = FIXTURES.l_bracket().mesh
	var d := _diagonal(bracket)
	var notes := []
	for options: Dictionary in [{}, {"strength": 0.1}, {"strength": 0.1, "iterations": 1}, {"keep_volume": false}, {"strength": 0.1, "iterations": 50}]:
		var result: RefCounted = bracket.smooth(options)
		var warning: String = bracket.get_last_warning()
		var report: Dictionary = bracket.get_last_report()
		if result == null:
			_expect(bracket.get_last_error() != "", "Smooth %s on the L-bracket gave nothing and no error." % [options])
			continue
		var moved := _two_sided(result, bracket)
		var said := warning.contains("Smooth moved the surface by up to")
		_expect(moved <= 0.02 * d or said, "Smooth %s moved the L-bracket's surface by %.2f mm (%.0f %% of its size) and said nothing ('%s')." % [options, moved / MM, 100.0 * moved / d, warning])
		_expect(float(report.max_move) >= 0.5 * moved, "The Smooth report's max_move (%.2f mm) should not be far under the measured move (%.2f mm)." % [float(report.max_move) / MM, moved / MM])
		_expect(result.area() <= 1.02 * bracket.area() or said, "Smooth %s grew the L-bracket's area by %.0f %% and said nothing." % [options, 100.0 * (result.area() / bracket.area() - 1.0)])
		notes.append("L-bracket %s: %.2f mm%s" % [options, moved / MM, " (said)" if said else ""])
	# volume_change is signed.
	var ball := _mesh(FIXTURES.icosphere(0.05, 4))
	var shrunk: RefCounted = ball.smooth({"keep_volume": false})
	var change: float = ball.get_last_report().get("volume_change", 0.0)
	_expect(shrunk != null and shrunk.volume() < ball.volume() and change < 0.0 and absf(change - (shrunk.volume() / ball.volume() - 1.0)) < 1e-9,
		"A shrinking ball should report a negative volume_change (%.6f; measured %.6f)." % [change, (shrunk.volume() / ball.volume() - 1.0) if shrunk != null else 0.0])
	# Keep Volume shell by shell: the void of a hollow cube keeps its own volume.
	var hollow := _mesh(FIXTURES.hollow_cube(false))
	var smoothed: RefCounted = hollow.smooth({})
	if smoothed != null:
		var arrays: Dictionary = smoothed.get_arrays()
		var void_volume := 0.0
		for t in range(12, 24):
			var a: Vector3 = arrays.positions[arrays.indices[t * 3]]
			var b: Vector3 = arrays.positions[arrays.indices[t * 3 + 2]]
			var c: Vector3 = arrays.positions[arrays.indices[t * 3 + 1]]
			void_volume += a.dot(b.cross(c)) / 6.0
		_expect(absf(void_volume + 1e-6) <= 0.005e-6 and absf(smoothed.volume() - 7e-6) <= 0.005 * 7e-6,
			"Smooth with Keep Volume should keep each closed shell's volume: the void of the hollow cube is %.1f mm3 (was -1000), the body %.1f mm3 (was 7000); warning '%s'." \
			% [void_volume * 1e9, smoothed.volume() * 1e9, hollow.get_last_warning()])
		notes.append("hollow cube: void %.1f mm3" % (void_volume * 1e9))
	else:
		_expect(hollow.get_last_error() != "", "Smooth on the hollow cube gave nothing and no error.")
	checked.append("P4 Smooth says how far it moved the surface, volume_change is signed, Keep Volume holds shell by shell (%s)" % "; ".join(notes))


# ---------------------------------------------------------------- P5


func _check_sheet_outline() -> void:
	var one := FIXTURES.raw(PackedVector3Array([Vector3(0, 0, 0), Vector3(0.01, 0, 0), Vector3(0, 0.01, 0)]), PackedInt32Array([0, 1, 2]))
	var two := FIXTURES.raw(PackedVector3Array([Vector3(0, 0, 0), Vector3(0.01, 0, 0), Vector3(0, 0.01, 0), Vector3(0.01, 0.01, 0)]), PackedInt32Array([0, 1, 2, 1, 3, 2]))
	var sheets := {"one triangle": one, "two triangles": two, "the open plate": FIXTURES.open_plate()}
	for name: String in sheets:
		for fill: String in ["minimal", "smooth", "flat"]:
			var mesh := _mesh(sheets[name])
			var result: RefCounted = mesh.close_holes({"fill": fill})
			var warning: String = mesh.get_last_warning()
			_expect(result == null or (is_same(result, mesh) and warning.contains("outline of an open sheet")),
				"Close Holes (%s) on %s should not lay a second surface on the sheet: the mesh itself, with the reason (%s triangles; '%s')." \
				% [fill, name, result.triangle_count() if result != null else -1, warning])
	# A plate with a real hole in it: the hole closes, the outline stays.
	var plate := FIXTURES.open_plate()
	var kept := PackedInt32Array()
	for i in range(0, plate.indices.size(), 3):
		var middle: Vector3 = (plate.positions[plate.indices[i]] + plate.positions[plate.indices[i + 1]] + plate.positions[plate.indices[i + 2]]) / 3.0
		if middle.length() > 0.006:
			kept.append_array([plate.indices[i], plate.indices[i + 1], plate.indices[i + 2]])
	var holed := _mesh(FIXTURES.raw(plate.positions, kept))
	_expect(holed.boundary_loops().size() == 2, "The plate with a hole should have two open loops (%d)." % holed.boundary_loops().size())
	var filled: RefCounted = holed.close_holes({})
	var filled_warning: String = holed.get_last_warning()
	_expect(filled != null and not is_same(filled, holed) and filled.boundary_loops().size() == 1 and filled.check(5.0).boundary_edges == 128 and filled_warning.contains("outline of an open sheet") \
		and absf(filled.area() - 0.0016) <= 1e-9,
		"Close Holes on a plate with a hole should close the hole and leave the outline (%s; '%s')." % [holed.get_last_error(), filled_warning])
	# A real hole stays a hole: an open tube end and the holed blob close as before.
	var blob := _mesh(FIXTURES.holed_blob())
	var closed: RefCounted = blob.close_holes({})
	_expect(closed != null and closed.check(5.0).closed and blob.get_last_warning() == "", "The holed blob should still close without a warning ('%s')." % blob.get_last_warning())
	var half := FIXTURES.icosphere(0.05, 3)
	var half_kept := PackedInt32Array()
	for i in range(0, half.indices.size(), 3):
		if (half.positions[half.indices[i]] + half.positions[half.indices[i + 1]] + half.positions[half.indices[i + 2]]).y > 0.0:
			half_kept.append_array([half.indices[i], half.indices[i + 1], half.indices[i + 2]])
	var bowl := _mesh(FIXTURES.raw(half.positions, half_kept))
	var capped: RefCounted = bowl.close_holes({"fill": "minimal"})
	_expect(capped != null and capped.check(5.0).closed and capped.volume() > 0.2e-3, "Half a ball should still close into a solid (%s; '%s')." % [bowl.get_last_error(), bowl.get_last_warning()])
	checked.append("P5 Close Holes leaves the outline of an open sheet open and says why (one and two triangles, the plate, a plate with a hole: the hole closes; half a ball and the blob close as before)")


# ---------------------------------------------------------------- P6


func _check_group_counts() -> void:
	var notes := []
	for name: String in ["holed blob", "noisy ball", "L-bracket"]:
		var mesh: RefCounted = FIXTURES.l_bracket().mesh if name == "L-bracket" else _mesh(FIXTURES.holed_blob() if name == "holed blob" else FIXTURES.with_noise(FIXTURES.icosphere(0.05, 4), 0.2))
		for options: Dictionary in [{}, {"min_size": 100000}, {"min_size": 1}]:
			var result: RefCounted = mesh.generate_groups(options)
			var report: Dictionary = mesh.get_last_report()
			_expect(result != null, "Generate Face Groups %s on the %s should work (%s)." % [options, name, mesh.get_last_error()])
			if result == null:
				continue
			var sum := int(report.planes) + int(report.cylinders) + int(report.spheres) + int(report.freeform)
			_expect(sum == result.group_count() and int(report.groups) == result.group_count(),
				"Generate Face Groups %s on the %s: planes + cylinders + spheres + freeform should be the group count (%d against %d)." % [options, name, sum, result.group_count()])
		notes.append(name)
	checked.append("P6 Generate Face Groups (accurate) counts describe the result (%s)" % ", ".join(notes))


# ---------------------------------------------------------------- P7


func _check_time_sentences() -> void:
	# One call, one estimate: the number does not depend on the limit it is refused at.
	var ball := FIXTURES.with_noise(FIXTURES.icosphere(0.05, 6), 0.1)
	var said := []
	var slowest := 0.0
	for limit: float in [0.1, 0.3, 1.0, 2.0]:
		var mesh := _mesh(ball)
		mesh.check(5.0)
		var started := Time.get_ticks_usec()
		var result: RefCounted = mesh.remesh({"mode": "adaptive", "time_limit": limit})
		var ms := (Time.get_ticks_usec() - started) / 1000.0
		var error: String = mesh.get_last_error()
		if result == null and error.contains("would take about"):
			said.append(_number_after(error, "would take about "))
			slowest = maxf(slowest, ms)
			_expect(_number_after(error, "would take about ") > limit, "A refusal should name an estimate over its limit ('%s')." % error)
	var same := true
	for value: float in said:
		same = same and absf(value - said[0]) <= 0.02 * said[0]
	_expect(said.size() >= 2 and same, "Remesh (adaptive) should give one estimate for one call, whatever the limit (it said %s s)." % [said])
	_expect(slowest <= 200.0, "Refusing Remesh (adaptive) up front should take at most 0.2 s (%.0f ms)." % slowest)
	# An estimate just over the limit must read as over the limit.
	var grid := _mesh(FIXTURES.large_grid(60))
	grid.check(5.0)
	var shown := []
	for case: Array in [["smooth", {}], ["remesh", {}], ["reduce", {"method": "adaptive"}], ["stitch_and_remove", {}]]:
		var probe: Dictionary = (case[1] as Dictionary).duplicate()
		probe["time_limit"] = 0.05
		grid.call(case[0], probe)
		var first: String = grid.get_last_error()
		if not first.contains("would take about"):
			continue
		var estimate := _number_after(first, "would take about ")
		for factor: float in [0.999, 0.99, 0.97]:
			var options: Dictionary = (case[1] as Dictionary).duplicate()
			options["time_limit"] = maxf(0.05, estimate * factor)
			var result: RefCounted = grid.call(case[0], options)
			var error: String = grid.get_last_error()
			if result == null and error.contains("would take about"):
				var about := _number_after(error, "would take about ")
				var limit_said := _number_after(error, "(limit ")
				_expect(about > limit_said, "%s refused with an estimate that does not read as over its limit: '%s'." % [case[0], error])
				shown.append("%s: about %s s (limit %s s)" % [case[0], about, limit_said])
	_expect(shown.size() >= 2, "At least two ops should have been refused close to their limit (%d)." % shown.size())
	checked.append("P7 time sentences (Remesh (adaptive) says one estimate at every limit: %s s, refused in at most %.0f ms; estimates just over the limit read as over it: %s)" % [said[0] if not said.is_empty() else "?", slowest, "; ".join(shown)])


# ---------------------------------------------------------------- notes


func _check_notes() -> void:
	var ball := _mesh(FIXTURES.icosphere(0.05, 3))
	# On/off options take true and false (and 1 and 0), nothing else.
	for value: Variant in [2, -1, 0.5, "yes"]:
		for case: Array in [["smooth", "keep_volume", "Keep Volume"], ["reduce", "keep_groups", "Keep Face Group Borders"], ["remesh", "keep_sharp", "Keep Sharp Edges"], ["close_holes", "refine", "Match Edge Size"],
				["stitch_and_remove", "remove_small", "Remove Small Pieces"]]:
			var result: RefCounted = ball.call(case[0], {case[1]: value})
			_expect(result == null and ball.get_last_error().contains("%s must be on or off" % case[2]), "%s with %s = %s should be refused ('%s')." % [case[0], case[1], value, ball.get_last_error()])
	for value: Variant in [true, false, 1, 0]:
		_expect(ball.smooth({"keep_volume": value}) != null, "Smooth with keep_volume = %s should work (%s)." % [value, ball.get_last_error()])
	# fit_primitive: no winner for shapes that are none of the three.
	var none := {
		"a cube": [_mesh(FIXTURES.cube()), PackedInt32Array(range(12))],
		"two faces of a cube": [_mesh(FIXTURES.cube()), PackedInt32Array([0, 1, 4, 5])],
		"a cone": [_mesh(FIXTURES.cone_patch()), PackedInt32Array()],
		"a torus patch": [_mesh(FIXTURES.torus_patch()), PackedInt32Array()],
		"a triangle without area": [_mesh(FIXTURES.raw(PackedVector3Array([Vector3(0, 0, 0), Vector3(0.01, 0, 0), Vector3(0.02, 0, 0), Vector3(0, 0.01, 0)]), PackedInt32Array([0, 1, 2, 0, 1, 3]))), PackedInt32Array([0])],
	}
	for name: String in none:
		var mesh: RefCounted = none[name][0]
		var tris: PackedInt32Array = none[name][1]
		if tris.is_empty():
			tris = PackedInt32Array(range(mesh.triangle_count()))
		var fit: Dictionary = mesh.fit_primitive(tris)
		_expect(fit.get("winner", "?") == "", "fit_primitive on %s should name no winner (it says '%s')." % [name, fit.get("winner", "?")])
	var bracket: RefCounted = FIXTURES.l_bracket().mesh
	var winners := {}
	for g in bracket.group_count():
		var fit: Dictionary = bracket.fit_primitive(bracket.group_triangles(g))
		winners[fit.winner] = int(winners.get(fit.winner, 0)) + 1
	_expect(winners.get("plane", 0) == 8 and winners.get("cylinder", 0) == 1, "The L-bracket's groups should still fit 8 planes and 1 cylinder (%s)." % [winners])
	var cap: RefCounted = _mesh(FIXTURES.icosphere(0.05, 4))
	var patch: PackedInt32Array = cap.triangles_near(Vector3(0.05, 0, 0), 0.02, true)
	_expect(cap.fit_primitive(patch).winner == "sphere" and cap.fit_primitive(PackedInt32Array([0])).winner == "plane", "A patch of a ball should still fit a sphere, one triangle a plane.")
	var coarse: RefCounted = ClassDB.instantiate("CadKernel").make_cylinder(0.01, 0.03, Vector3.ZERO, Vector3.UP)
	var coarse_mesh: RefCounted = ClassDB.instantiate("CadMesh")
	if coarse != null and coarse_mesh.from_shape(coarse, 0.0005, deg_to_rad(20.0), false, 20.0):
		var side := -1
		for g in coarse_mesh.group_count():
			if coarse_mesh.fit_primitive(coarse_mesh.group_triangles(g)).winner == "cylinder":
				side = g
		_expect(side >= 0, "The side of a coarsely tessellated cylinder (20 degrees) should still fit a cylinder.")
	# Reverse Normal on a selection says that the picked triangles now face the other way.
	var some: RefCounted = ball.reverse({"mode": "selection", "triangles": PackedInt32Array([0, 1, 2])})
	_expect(some != null and ball.get_last_warning().contains("face the other way"), "Reverse Normal (selection) should say that its triangles now face the other way than their neighbours ('%s')." % ball.get_last_warning())
	checked.append("notes (on/off options refuse 2, -1, 0.5 and text; fit_primitive names no winner for a cube, two cube faces, a cone, a torus patch and a triangle without area, and still the right one for planes, cylinders and a ball patch; Reverse Normal (selection) says what it leaves)")


# ---------------------------------------------------------------- second fix round (re-verifier R1, 2026-11-13)


## True when the result's box lies inside the input's box grown by `grow` x the input's diagonal.
func _box_within(result: RefCounted, input: RefCounted, grow: float) -> bool:
	return (input.bbox() as AABB).grow(grow * _diagonal(input)).encloses(result.bbox())


func _check_fill_balloon() -> void:
	# N1: the smooth fill ran far outside the body (a 10-triangle tray: box 287 x 17.5 x 136 mm,
	# 38,172 mm3 against 1,867 with the flat fill) and nothing was said.
	var notes := []
	var bent := FIXTURES.deformed(FIXTURES.grid_plate(0.04, 8), func(v: Vector3) -> Vector3: return Vector3(v.x, maxf(v.x, 0.0) * tan(deg_to_rad(30.0)), v.z))
	var cases := {"tray 40 to 80 mm, 0.5 mm high": [FIXTURES.tray(0.04, 2.0, 0.0005, 1), {}], "tray 40 to 120 mm, 4 squares a side": [FIXTURES.tray(0.04, 3.0, 0.0005, 4), {}],
		"upright tray": [FIXTURES.tray(0.04, 1.0, 0.0005, 4), {}], "plate bent 30 degrees, its outline picked": [bent, {"loops": PackedInt32Array([0])}]}
	for name: String in cases:
		var mesh := _mesh(cases[name][0])
		var flat_options: Dictionary = (cases[name][1] as Dictionary).duplicate()
		flat_options["fill"] = "flat"
		var flat: RefCounted = mesh.close_holes(flat_options)
		var result: RefCounted = mesh.close_holes(cases[name][1])
		var warning: String = mesh.get_last_warning()
		var report: Dictionary = mesh.get_last_report()
		_expect(result != null and not is_same(result, mesh), "Close Holes (smooth) on the %s should give a result (%s; '%s')." % [name, mesh.get_last_error(), warning])
		if result == null or is_same(result, mesh):
			continue
		var size: Vector3 = result.bbox().size
		_expect(_box_within(result, mesh, 0.75), "The smooth fill of the %s runs far outside the body (box %.1f x %.1f x %.1f mm against a body of %.1f mm; '%s')." % [name, size.x / MM, size.y / MM, size.z / MM, _diagonal(mesh) / MM, warning])
		var replaced: PackedInt32Array = report.get("replaced_loops", PackedInt32Array())
		if not replaced.is_empty():
			_expect(warning.contains("flat fill") and warning.contains(" mm"), "A smooth fill that was replaced should be named, with distances ('%s')." % warning)
			if flat != null and not is_same(flat, mesh):
				_expect(absf(result.volume() - flat.volume()) <= 1e-6 * maxf(absf(flat.volume()), 1e-12), "The replaced fill of the %s should be the flat fill (%.1f against %.1f mm3)." % [name, result.volume() * 1e9, flat.volume() * 1e9])
		notes.append("%s: box %.1f x %.1f x %.1f mm, %.0f mm3%s" % [name, size.x / MM, size.y / MM, size.z / MM, result.volume() * 1e9, " (flat fill instead, said)" if not replaced.is_empty() else ""])
	checked.append("N1 the smooth fill stays near its hole (%s)" % "; ".join(notes))


func _check_tolerance_dense() -> void:
	# N3: Reduce by Maximum Deviation gave results 14 to 16 % over (found with every vertex, edge
	# middle and triangle middle; the op's 20,000 samples each way missed the maximum).
	var blob := _mesh(FIXTURES.holed_blob())
	var d := _diagonal(blob)
	var notes := []
	for case: Array in [["adaptive", d / 2000.0], ["adaptive", d / 200.0], ["adaptive", d / 20.0], ["fast", d / 200.0], ["fast", d / 20.0]]:
		var result: RefCounted = blob.reduce({"target": "tolerance", "tolerance": case[1], "method": case[0]})
		var report: Dictionary = blob.get_last_report()
		_expect(result != null, "Reduce (%s) by %.4f mm on the holed blob should give a result or the mesh itself (%s)." % [case[0], float(case[1]) / MM, blob.get_last_error()])
		if result == null or is_same(result, blob):
			notes.append("%s %.4f mm: unchanged" % [case[0], float(case[1]) / MM])
			continue
		var ab: Dictionary = result.distance_to(blob, 400000, 60.0)
		var ba: Dictionary = blob.distance_to(result, 400000, 60.0)
		var dense := maxf(ab.get("max", INF), ba.get("max", INF))
		_expect(dense <= float(case[1]), "Reduce (%s) by a %.5f mm deviation gave a result %.5f mm off (400,000 samples each way)." % [case[0], float(case[1]) / MM, dense / MM])
		_expect(float(report.deviation.max) >= 0.95 * dense, "The report's deviation (%.5f mm) should not be far under the densely measured one (%.5f mm)." % [float(report.deviation.max) / MM, dense / MM])
		notes.append("%s %.4f mm: %d triangles, %.4f mm (report %.4f)" % [case[0], float(case[1]) / MM, result.triangle_count(), dense / MM, float(report.deviation.max) / MM])
	checked.append("N3 Reduce by Maximum Deviation holds against 400,000 samples each way (holed blob: %s)" % "; ".join(notes))


func _check_outline_rule() -> void:
	# N6: shallow open shells were taken for outlines; wavy, saddle and bent sheets were closed.
	var notes := []
	var shells := {"a cone r 20 mm, 1 mm high": FIXTURES.cone_sheet(0.02, 0.001), "a tray 0.5 mm deep": FIXTURES.tray(0.04, 1.0, 0.0005, 4), "a steep cone": FIXTURES.cone_sheet(0.02, 0.02, 6)}
	for name: String in shells:
		for options: Dictionary in [{"fill": "minimal"}, {"fill": "minimal", "loops": PackedInt32Array([0])}, {}]:
			var mesh := _mesh(shells[name])
			var result: RefCounted = mesh.close_holes(options)
			_expect(result != null and not is_same(result, mesh) and result.check(5.0).closed and result.volume() > 0.0,
				"Close Holes %s on %s should close it into a solid ('%s'; '%s')." % [options, name, mesh.get_last_warning(), mesh.get_last_error()])
		notes.append(name)
	var plate := FIXTURES.grid_plate(0.05, 20)
	var sheets := {
		"a wavy plate (4 mm waves)": FIXTURES.deformed(plate, func(v: Vector3) -> Vector3: return Vector3(v.x, 0.004 * sin(v.x / 0.05 * 9.0) * cos(v.z / 0.05 * 7.0), v.z)),
		"a wavy plate (0.2 mm waves)": FIXTURES.deformed(plate, func(v: Vector3) -> Vector3: return Vector3(v.x, 0.0002 * sin(v.x / 0.05 * 9.0) * cos(v.z / 0.05 * 7.0), v.z)),
		"a saddle": FIXTURES.deformed(FIXTURES.grid_plate(0.04, 12), func(v: Vector3) -> Vector3: return Vector3(v.x, (v.x * v.x - v.z * v.z) * 12.0, v.z)),
		"a strip bent 30 degrees": FIXTURES.deformed(FIXTURES.grid_plate(0.04, 8), func(v: Vector3) -> Vector3: return Vector3(v.x, maxf(v.x, 0.0) * tan(deg_to_rad(30.0)), v.z)),
		"a flat plate": plate,
	}
	for name: String in sheets:
		for fill: String in ["minimal", "smooth"]:
			var mesh := _mesh(sheets[name])
			var result: RefCounted = mesh.close_holes({"fill": fill})
			_expect(is_same(result, mesh) and mesh.get_last_warning().contains("outline of an open sheet"),
				"Close Holes (%s) on %s should leave its outline open and say so (%s triangles; '%s'; '%s')." % [fill, name, result.triangle_count() if result != null else -1, mesh.get_last_warning(), mesh.get_last_error()])
		notes.append(name)
	# A loop that was picked is closed, with a word when it looks like an outline.
	var picked := _mesh(plate)
	var closed: RefCounted = picked.close_holes({"fill": "minimal", "loops": PackedInt32Array([0])})
	_expect(closed != null and not is_same(closed, picked) and closed.check(5.0).boundary_edges == 0 and picked.get_last_warning().contains("looks like the outline of an open sheet"),
		"A picked outline should be closed, with a warning that it looks like one ('%s'; '%s')." % [picked.get_last_warning(), picked.get_last_error()])
	checked.append("N6 the outline rule (closed: %s, picked or not; left open: the sheets; a picked outline is closed with a warning)" % ", ".join(notes))


func _check_stitch_self_touch() -> void:
	# N7: a closed body that touches itself was refused with "Lower the Stitch Tolerance", also at 0.
	var ring := FIXTURES.voxels([Vector3i(0, 0, 0), Vector3i(1, 0, 0), Vector3i(2, 0, 0), Vector3i(2, 1, 0), Vector3i(2, 2, 0), Vector3i(1, 2, 0), Vector3i(0, 2, 0), Vector3i(0, 1, 0)])
	var squeezed := FIXTURES.deformed(ring, func(v: Vector3) -> Vector3: return Vector3(0.015, v.y, v.z) if (absf(v.x - 0.01) < 1e-6 or absf(v.x - 0.02) < 1e-6) and v.y > 0.005 and v.y < 0.025 else v)
	var said := []
	for options: Dictionary in [{}, {"tolerance": 0.0}]:
		var mesh := _mesh(squeezed)
		var result: RefCounted = mesh.stitch_and_remove(options)
		var error: String = mesh.get_last_error()
		if result == null:
			_expect(error.contains("Rebuild") and not (options.has("tolerance") and error.contains("ower the Stitch Tolerance")),
				"Stitch and Remove %s on a body that touches itself should say what helps (Rebuild), not a hint that cannot work ('%s')." % [options, error])
			said.append(error)
		else:
			_expect(result.check(5.0).closed, "A result of Stitch and Remove %s on a body that touches itself should be closed ('%s')." % [options, mesh.get_last_warning()])
			said.append("a closed result")
	checked.append("N7 Stitch and Remove on a body that touches itself (%s)" % "; ".join(said))


func _one_right(text: String) -> bool:
	var wrong := RegEx.new()
	wrong.compile("(^|[^0-9,.])1 (holes|edges|open loops|open edges|triangles|pieces|vertices|corners|parts|places|non-manifold edges|more open edges|face groups)\\b")
	return wrong.search(text) == null


func _check_singular() -> void:
	# N9: "1 open loops are", "fixed 1 non-manifold edges", "made 1 edges", ...
	var seen := []
	var one := _mesh(FIXTURES.raw(PackedVector3Array([Vector3(0, 0, 0), Vector3(0.01, 0, 0), Vector3(0, 0.01, 0)]), PackedInt32Array([0, 1, 2])))
	one.close_holes({})
	seen.append(one.get_last_warning())
	_expect(one.get_last_warning().contains("1 open loop is the outline of an open sheet"), "One outline should read '1 open loop is ...' ('%s')." % one.get_last_warning())
	var edge := FIXTURES.joined([FIXTURES.cube(0.02, Vector3.ZERO), FIXTURES.cube(0.02, Vector3(0.02, 0.02, 0))])
	var touching := _mesh(edge)
	touching.stitch_and_remove({})
	seen.append(str(touching.get_last_report().get("summary", "")))
	_expect(str(touching.get_last_report().get("summary", "")).contains("fixed 1 non-manifold edge."), "One fixed edge should read 'fixed 1 non-manifold edge.' ('%s')." % touching.get_last_report().get("summary", ""))
	touching.stitch_and_remove({"fix_non_manifold": false})
	seen.append(touching.get_last_error())
	_expect(touching.get_last_error().contains("made 1 edge that more than two triangles share"), "One new edge should read 'made 1 edge that ...' ('%s')." % touching.get_last_error())
	# One hole that cannot be closed, one too large, one reversed triangle.
	var ball := _mesh(FIXTURES.icosphere(0.05, 3))
	var holed: RefCounted = ball.delete_triangles(PackedInt32Array([0]))
	holed.close_holes({"max_edges": 2})
	seen.append(holed.get_last_warning())
	_expect(holed.get_last_warning().contains("1 hole was larger than Largest Hole and stays open"), "One hole over Largest Hole should read '1 hole was larger ... and stays open' ('%s')." % holed.get_last_warning())
	ball.reverse({"mode": "selection", "triangles": PackedInt32Array([0])})
	seen.append(ball.get_last_warning())
	for text: String in seen:
		_expect(_one_right(text), "A count of one should read as one: '%s'." % text)
	checked.append("N9 counts of one read as one (%d sentences)" % seen.size())


func _check_more_notes() -> void:
	# Remesh says when a closed body's volume changed by more than 2 %.
	var ball := _mesh(FIXTURES.icosphere(0.05, 4))
	var coarse: RefCounted = ball.remesh({"edge_length": _diagonal(ball) / 5.0})
	var coarse_warning: String = ball.get_last_warning()
	var coarse_report: Dictionary = ball.get_last_report()
	if coarse != null:
		var change: float = coarse.volume() / ball.volume() - 1.0
		_expect(absf(change) <= 0.02 or coarse_warning.contains("Remesh changed the volume by"), "Remesh changed the ball's volume by %.1f %% and said nothing ('%s')." % [100.0 * change, coarse_warning])
		_expect(absf(float(coarse_report.get("volume_change", 0.0)) - change) <= 1e-6, "The Remesh report should hold the signed volume_change (%.4f against %.4f)." % [float(coarse_report.get("volume_change", 0.0)), change])
	else:
		_expect(ball.get_last_error() != "", "Remesh at D/5 gave nothing and no error.")
	# Smooth names the right reason on two well-shaped balls of different size.
	var pair := _mesh(FIXTURES.joined([FIXTURES.icosphere(0.05, 3), FIXTURES.icosphere(0.005, 3, Vector3(0.1, 0, 0))]))
	var smoothed: RefCounted = pair.smooth({})
	var smooth_warning: String = pair.get_last_warning()
	_expect(smoothed != null or pair.get_last_error() != "", "Smooth on two balls gave nothing and no error.")
	_expect(not smooth_warning.contains("very thin") and not smooth_warning.contains("lopsided"), "Smooth should not blame thin or lopsided triangles on two well-shaped balls ('%s')." % smooth_warning)
	# Stitch says when pieces lie on each other.
	var twice := _mesh(FIXTURES.joined([FIXTURES.cube(0.02, Vector3.ZERO), FIXTURES.flipped(FIXTURES.cube(0.02, Vector3.ZERO))]))
	var stitched: RefCounted = twice.stitch_and_remove({})
	var stitch_warning: String = twice.get_last_warning()
	if stitched != null:
		_expect(absf(stitched.volume() - 8e-6) <= 1e-9 or stitch_warning.contains("lie exactly on"), "Stitch and Remove on a cube and its inside-out copy gave %.0f mm3 (the cube has 8,000) and said nothing ('%s')." % [stitched.volume() * 1e9, stitch_warning])
	else:
		_expect(twice.get_last_error() != "", "Stitch and Remove on a cube and its inside-out copy gave nothing and no error.")
	checked.append("more notes (Remesh says a volume change above 2 %%; Smooth's reason on two balls: '%s'; Stitch says when pieces lie on each other)" % smooth_warning.substr(0, 90))


# ---------------------------------------------------------------- flat holes with straight sides (2026-11-13)


## A flat grid plate (n x n squares, `size` wide, in the plane y = 0) without the squares whose
## middle `inside` holds.
func _plate_with_hole(size: float, n: int, inside: Callable) -> Dictionary:
	var plate := FIXTURES.grid_plate(size, n)
	var kept := PackedInt32Array()
	for i in range(0, plate.indices.size(), 6):
		var middle := Vector3.ZERO
		for k in 6:
			middle += plate.positions[plate.indices[i + k]] / 6.0
		if not inside.call(middle):
			for k in 6:
				kept.append(plate.indices[i + k])
	return FIXTURES.raw(plate.positions, kept)


func _check_flat_holes() -> void:
	# A hole with straight sides in a flat plate: the fill used triangles of three corners on one
	# side ("made 4 triangles without area", "made 7 places where the mesh crosses itself").
	var holes := {
		"a square hole, 4 squares a side": _plate_with_hole(0.04, 8, func(m: Vector3) -> bool: return absf(m.x) < 0.01 and absf(m.z) < 0.01),
		"a square hole, 1 square": _plate_with_hole(0.04, 8, func(m: Vector3) -> bool: return m.x > 0.0 and m.x < 0.005 and m.z > 0.0 and m.z < 0.005),
		"a long hole, 32 by 4 squares": _plate_with_hole(0.05, 40, func(m: Vector3) -> bool: return absf(m.x) < 0.02 and absf(m.z) < 0.0025),
		"an L-shaped hole": _plate_with_hole(0.04, 16, func(m: Vector3) -> bool: return (absf(m.x) < 0.01 and m.z > -0.01 and m.z < 0.0) or (m.x > -0.01 and m.x < -0.005 and m.z >= 0.0 and m.z < 0.01)),
		"a hole one square wide across 12": _plate_with_hole(0.04, 16, func(m: Vector3) -> bool: return absf(m.x) < 0.015 and m.z > 0.0 and m.z < 0.0025),
	}
	var tilt := Basis(Vector3(1, 2, 3).normalized(), 0.7)
	var places := {"": func(v: Vector3) -> Vector3: return v, " (tilted)": func(v: Vector3) -> Vector3: return tilt * v, " (tilted, 100 m from the origin)": func(v: Vector3) -> Vector3: return tilt * v + Vector3(60, -70, 40)}
	var calls := 0
	var worst := ""
	for name: String in holes:
		for place: String in places:
			var fixture := FIXTURES.deformed(holes[name], places[place])
			for options: Dictionary in [{"fill": "minimal"}, {"fill": "flat"}, {"fill": "smooth"}, {"fill": "minimal", "refine": false}, {"fill": "minimal", "loops": PackedInt32Array([0, 1])}]:
				var mesh := _mesh(fixture)
				var open_before: int = mesh.check(5.0).boundary_edges
				var area_before: float = mesh.area()
				var size: float = (holes[name].positions[0] as Vector3).x * -2.0
				var result: RefCounted = mesh.close_holes(options)
				var warning: String = mesh.get_last_warning()
				calls += 1
				_expect(result != null and not is_same(result, mesh), "Close Holes %s on %s%s should fill the hole (%s; '%s')." % [options, name, place, mesh.get_last_error(), warning])
				if result == null or is_same(result, mesh):
					continue
				var c: Dictionary = result.check(5.0)
				var picked: bool = options.has("loops")
				var clean: bool = c.degenerate_triangles == 0 and not warning.contains("without area")
				# (With both loops picked the outline is closed too: that double surface crosses itself by design.)
				if not picked:
					clean = clean and int(c.self_intersections) <= 0 and not warning.contains("crosses itself") and int(c.boundary_edges) < open_before \
						and absf(result.area() - size * size) <= 2e-3 * size * size
				if not clean and worst == "":
					worst = "%s%s %s: %d triangles without area, %d crossings, area %.3f of %.3f mm2 (was %.3f); '%s'" % [name, place, options, int(c.degenerate_triangles), int(c.self_intersections), result.area() * 1e6, size * size * 1e6, area_before * 1e6, warning]
				_expect(clean, "Close Holes %s on %s%s should fill the flat hole with real triangles only (%d without area, %d crossings, area %.3f of %.3f mm2; '%s')." \
					% [options, name, place, int(c.degenerate_triangles), int(c.self_intersections), result.area() * 1e6, size * size * 1e6, warning])
	checked.append("flat holes with straight sides (%d calls: 5 holes x 3 places x 5 option sets, no triangle without area and no crossing)" % calls)


func _check_stitch_without_area() -> void:
	# Stitch and Remove judged "without area" by the body's size: on a 100 m body every triangle
	# under 10,000 mm2 went. Now by the shared rule (the triangle's own shape and place).
	var positions := PackedVector3Array([Vector3(0, 0, 0), Vector3(100, 0, 0), Vector3(0, 100, 0)])
	var indices := PackedInt32Array([0, 1, 2])
	for i in 4:
		var base := Vector3(0.001 * (i + 1), 0.001, 0.01)
		indices.append_array([positions.size(), positions.size() + 1, positions.size() + 2])
		positions.append_array(PackedVector3Array([base, base + Vector3(0.0001, 0, 0), base + Vector3(0, 0.0001, 0)]))
	for needle: Array in [[Vector3(0.02, 0.02, 0.01), Vector3(0.03, 0.02, 0.01), Vector3(0.025, 0.02, 0.01)], [Vector3(50, 50, 1), Vector3(50.01, 50, 1), Vector3(50.005, 50, 1)]]:
		indices.append_array([positions.size(), positions.size() + 1, positions.size() + 2])
		positions.append_array(PackedVector3Array(needle))
	var mesh := _mesh(FIXTURES.raw(positions, indices))
	var before: Dictionary = mesh.check(5.0)
	var result: RefCounted = mesh.stitch_and_remove({"tolerance": 0.0, "remove_small": false})
	var report: Dictionary = mesh.get_last_report()
	_expect(result != null, "Stitch and Remove on the 100 m body should work (%s)." % mesh.get_last_error())
	if result != null:
		_expect(int(before.degenerate_triangles) == 2 and result.triangle_count() == 5 and int(report.removed_degenerate) == 2 and int(result.check(5.0).degenerate_triangles) == 0,
			"Stitch and Remove should take out the 2 needles check() counts (%d) and keep the four 0.1 mm triangles of a 100 m body (%d triangles left of 7, %d removed as without area)." 			% [int(before.degenerate_triangles), result.triangle_count(), int(report.removed_degenerate)])
	checked.append("Stitch and Remove judges 'without area' as check() does (a 100 m body: 2 needles out, four 0.1 mm triangles kept)")


# ---------------------------------------------------------------- third fix round (re-verifier R3, 2026-11-13)


func _check_far_from_origin() -> void:
	# B1: Remesh on a 10 mm ball 30 km from the origin took 21 s against a 2 s limit (100 km: 9.7
	# s; once 36 min at a 20 s limit); at 10 km on the diagonal "made a broken mesh (internal
	# error)". Smooth, Reduce and Close Holes there came back with triangles without area.
	# Each op must keep to its limit, and either refuse with the distance and the step, or give
	# a clean result. At 1 km every op still works.
	var notes := []
	var limit := 2.0
	for place: Array in [[30.0, false], [100.0, false], [10.0, true], [10.0, false], [3.0, false], [3.0, true], [1.0, false], [1.0, true]]:
		var km: float = place[0]
		var centre := Vector3(1, 1, 1) * (km * 1000.0 / sqrt(3.0)) if place[1] else Vector3(km * 1000.0, 0, 0)
		var ball := FIXTURES.icosphere(0.005, 3, centre)
		var holed := _mesh(ball)
		var cap := PackedInt32Array()
		for i in range(0, ball.indices.size(), 3):
			var middle: Vector3 = (ball.positions[ball.indices[i]] + ball.positions[ball.indices[i + 1]] + ball.positions[ball.indices[i + 2]]) / 3.0 - centre
			if middle.y > 0.0035:
				cap.append(i / 3)
		holed = holed.delete_triangles(cap)
		var refused := 0
		for call: Array in [["remesh", {}], ["smooth", {}], ["reduce", {}], ["reduce", {"method": "fast"}], ["close_holes", {}]]:
			var mesh: RefCounted = holed if call[0] == "close_holes" else _mesh(ball)
			var options: Dictionary = (call[1] as Dictionary).duplicate()
			options["name"] = "Ball"
			options["time_limit"] = limit
			var started := Time.get_ticks_msec()
			var result: Variant = mesh.call(call[0], options)
			var ms := Time.get_ticks_msec() - started
			var error: String = mesh.get_last_error()
			var warning: String = mesh.get_last_warning()
			var where := "%s %s at %.0f km%s" % [call[0], call[1], km, " (diagonal)" if place[1] else ""]
			_expect(ms <= limit * 1000.0 + 500.0, "%s took %d ms against a %d ms limit ('%s')." % [where, ms, int(limit * 1000.0), error])
			if result == null:
				refused += 1
				_expect(error.contains("Ball is") and error.contains("from the origin") and error.contains("stored only to about") and km > 1.5,
					"%s should refuse only far from the origin, naming the distance and the step ('%s')." % [where, error])
			else:
				var made: int = int((result as RefCounted).check(5.0).degenerate_triangles)
				_expect(made == 0 and not warning.contains("without area") and not warning.contains("internal error"),
					"%s should give a clean result or refuse (%d triangles without area; '%s')." % [where, made, warning])
		notes.append("%.0f km%s: %d of 5 refused" % [km, " diag" if place[1] else "", refused])
	checked.append("B1 N2 ops on a 10 mm ball far from the origin keep a 2 s limit and refuse with the distance and step, or give a clean result (%s)" % "; ".join(notes))


## A rectangular open tray: a bottom of na x nb squares (a x b) at y = 0, upright or leaning
## walls up to a rim at y = h pushed out by e on every side. Outward facing.
func _rect_tray(a: float, b: float, na: int, nb: int, h: float, e: float) -> Dictionary:
	var positions := PackedVector3Array()
	var ccw := PackedInt32Array()
	for j in nb + 1:
		for i in na + 1:
			positions.append(Vector3(a * (float(i) / na - 0.5), 0, b * (float(j) / nb - 0.5)))
	for j in nb:
		for i in na:
			var q := j * (na + 1) + i
			ccw.append_array([q, q + 1, q + na + 2, q, q + na + 2, q + na + 1])
	var ring := []
	for i in na:
		ring.append(i)
	for j in nb:
		ring.append(j * (na + 1) + na)
	for i in na:
		ring.append(nb * (na + 1) + na - i)
	for j in nb:
		ring.append((nb - j) * (na + 1))
	var rim := []
	for id: int in ring:
		rim.append(positions.size())
		var v := positions[id]
		positions.append(Vector3(v.x * (a + 2.0 * e) / a, h, v.z * (b + 2.0 * e) / b))
	for i in ring.size():
		var next := (i + 1) % ring.size()
		ccw.append_array([ring[i], rim[i], rim[next], ring[i], rim[next], ring[next]])
	var fixture := FIXTURES._pack(positions, ccw)
	if float(FIXTURES.volume_and_area(fixture).volume) < 0.0:
		fixture = FIXTURES.flipped(fixture)
	return fixture


func _check_smooth_fill_kept() -> void:
	# A1: smooth fills that ran out sideways by up to 0.84 x the loop's width were kept with no
	# word (a 48 mm tray filled out to 67 mm, 9,920 mm3 against 971 with the flat fill; a 100 x 2
	# mm slot filled 44 mm past its end), and a dome over an upright tray (9,812 against 800 mm3).
	# Now: a smooth fill that leaves the loop's outline is replaced by the flat fill, with a word;
	# one that changes the body's volume against the flat fill by more than half is said.
	var notes := []
	var cases := {
		"tray 40 to 48 mm, 0.5 mm high": FIXTURES.tray(0.04, 1.2, 0.0005, 1),
		"tray 40 to 200 mm, 5 mm high": FIXTURES.tray(0.04, 5.0, 0.005, 1),
		"tray 40 to 120 mm, 2 squares a side": FIXTURES.tray(0.04, 3.0, 0.005, 2),
		"slot 100 x 2 mm, upright walls": _rect_tray(0.1, 0.002, 50, 1, 0.0005, 0.0),
		"slot 100 x 2 mm, rim out by 30 mm": _rect_tray(0.1, 0.002, 50, 1, 0.0005, 0.03),
		"upright tray 40 mm, 0.5 mm high": FIXTURES.tray(0.04, 1.0, 0.0005, 4),
	}
	for name: String in cases:
		var mesh := _mesh(cases[name])
		var flat: RefCounted = mesh.close_holes({"fill": "flat"})
		var result: RefCounted = mesh.close_holes({})
		var warning: String = mesh.get_last_warning()
		_expect(result != null and not is_same(result, mesh) and flat != null, "Close Holes on the %s should fill it (%s; '%s')." % [name, mesh.get_last_error(), warning])
		if result == null or is_same(result, mesh) or flat == null:
			continue
		# In the plane of the rim (x and z here): within the input's box, give or take a quarter
		# of its narrower side.
		var box: AABB = mesh.bbox()
		var out: AABB = result.bbox()
		var grow := 0.25 * minf(box.size.x, box.size.z)
		var sideways := maxf(maxf(box.position.x - out.position.x, out.end.x - box.end.x), maxf(box.position.z - out.position.z, out.end.z - box.end.z))
		var replaced: PackedInt32Array = mesh.get_last_report().get("replaced_loops", PackedInt32Array())
		replaced.append_array(mesh.get_last_report().get("outline_replaced_loops", PackedInt32Array()))
		_expect(sideways <= grow or (not replaced.is_empty() and warning.contains("flat fill")),
			"The smooth fill of the %s ran %.1f mm out of the body sideways (allowed %.1f mm) and was kept ('%s')." % [name, sideways / MM, grow / MM, warning])
		var ratio: float = result.volume() / flat.volume() if flat.volume() != 0.0 else INF
		_expect(absf(ratio - 1.0) <= 0.5 or (warning.contains("flat fill") and warning.contains("mm3")),
			"The smooth fill of the %s gives %.0f mm3 against %.0f with the flat fill, and that is not said ('%s')." % [name, result.volume() * 1e9, flat.volume() * 1e9, warning])
		notes.append("%s: %s" % [name, ("flat fill instead, said ('%s')" % warning.substr(0, 110)) if not replaced.is_empty() else ("%.0f against %.0f mm3, said" % [result.volume() * 1e9, flat.volume() * 1e9] if absf(ratio - 1.0) > 0.5 else "kept")])
	# Holes that the smooth fill closes as it should stay smooth and unsaid: a cap off a ball, the
	# end of a tube.
	var ball := FIXTURES.icosphere(0.02, 3)
	var cap := PackedInt32Array()
	for i in range(0, ball.indices.size(), 3):
		if (ball.positions[ball.indices[i]] + ball.positions[ball.indices[i + 1]] + ball.positions[ball.indices[i + 2]]).y / 3.0 > 0.012:
			cap.append(i / 3)
	var capped: RefCounted = _mesh(ball).delete_triangles(cap)
	var tube := _rect_tray(0.02, 0.02, 4, 4, 0.06, 0.0)
	for item: Array in [["a ball without its cap", capped], ["a 20 mm square tube 60 mm long", _mesh(tube)]]:
		var mesh: RefCounted = item[1]
		var result: RefCounted = mesh.close_holes({})
		var warning: String = mesh.get_last_warning()
		var replaced: PackedInt32Array = mesh.get_last_report().get("replaced_loops", PackedInt32Array())
		_expect(result != null and not is_same(result, mesh) and replaced.is_empty() and not warning.contains("flat fill"),
			"Close Holes on %s should keep its smooth fill, with no word on it (%s; '%s')." % [item[0], mesh.get_last_error(), warning])
		notes.append("%s: smooth, unsaid" % item[0])
	checked.append("A1 smooth fills stay in their hole's outline or are replaced and said; a volume more than half off the flat fill's is said (%s)" % "; ".join(notes))


## A closed plate size x thick x size: n x n squares on top and below, one ring of side walls.
func _closed_plate(n: int, size: float, thick: float) -> Dictionary:
	var positions := PackedVector3Array()
	var ccw := PackedInt32Array()
	for side in 2:
		for j in n + 1:
			for i in n + 1:
				positions.append(Vector3(size * (float(i) / n - 0.5), thick * 0.5 if side == 1 else -thick * 0.5, size * (float(j) / n - 0.5)))
	var m := (n + 1) * (n + 1)
	for j in n:
		for i in n:
			var a := j * (n + 1) + i
			ccw.append_array([a, a + 1, a + n + 2, a, a + n + 2, a + n + 1])
			ccw.append_array([m + a, m + a + n + 2, m + a + 1, m + a, m + a + n + 1, m + a + n + 2])
	var ring := []
	for i in n:
		ring.append(i)
	for j in n:
		ring.append(j * (n + 1) + n)
	for i in n:
		ring.append(n * (n + 1) + n - i)
	for j in n:
		ring.append((n - j) * (n + 1))
	for k in ring.size():
		var a: int = ring[k]
		var b: int = ring[(k + 1) % ring.size()]
		ccw.append_array([a, m + a, m + b, a, m + b, b])
	var fixture := FIXTURES._pack(positions, ccw)
	if float(FIXTURES.volume_and_area(fixture).volume) < 0.0:
		fixture = FIXTURES.flipped(fixture)
	return fixture


func _check_reduce_thin_plate() -> void:
	# A2: Reduce (Fast) by a Maximum Deviation of 1 mm on a closed plate 0.2 mm thick lost two
	# thirds of its volume (or all of it) and said nothing about it.
	var notes := []
	for n: int in [2, 4, 30]:
		for options: Dictionary in [{"target": "tolerance", "tolerance": 0.001, "method": "fast"}, {"target": "face_count", "face_count": 4, "method": "fast"}]:
			var mesh := _mesh(_closed_plate(n, 0.04, 0.0002))
			var result: RefCounted = mesh.reduce(options)
			var warning: String = mesh.get_last_warning()
			if result == null or is_same(result, mesh):
				notes.append("%d a side %s: %s" % [n, options.target, "refused" if result == null else "unchanged"])
				continue
			var change: float = float(mesh.get_last_report().get("volume_change", NAN))
			var measured: float = result.volume() / mesh.volume() - 1.0
			_expect(absf(measured) <= 0.02 or warning.contains("changed the volume by"), "Reduce %s on a 0.2 mm plate (%d squares a side) changed its volume by %.1f %% and said nothing ('%s')." % [options, n, 100.0 * measured, warning])
			notes.append("%d a side %s: %.0f %%%s" % [n, options.target, 100.0 * (change if not is_nan(change) else measured), ", said" if warning.contains("changed the volume by") else ""])
	checked.append("A2 Reduce says a volume change of a closed body (a 0.2 mm plate: %s)" % "; ".join(notes))


func _check_reduce_count_deviation() -> void:
	# A6: by proportion or face count the report's deviation came from 20,000 samples each way and
	# read low (crossing_holes to 3,635 faces: 0.000873 against 0.001746 mm; l_bracket to 383:
	# 0.00691 against 0.0101 mm). Now measured as by Maximum Deviation.
	var notes := []
	for case: Array in [["crossing holes", FIXTURES.crossing_holes(), {"method": "adaptive", "target": "face_count", "face_count": 3635, "keep_boundary": false, "keep_groups": false, "keep_sharp": false}],
			["crossing holes", FIXTURES.crossing_holes(), {"method": "adaptive", "target": "proportion", "proportion": 30.0, "keep_groups": false}],
			["l bracket", FIXTURES.l_bracket(), {"method": "adaptive", "target": "face_count", "face_count": 383, "keep_boundary": false, "keep_groups": false, "keep_sharp": false}],
			["holed blob", FIXTURES.holed_blob(), {"method": "fast", "target": "proportion", "proportion": 10.0}]]:
		var mesh := _mesh(case[1])
		var result: RefCounted = mesh.reduce(case[2])
		var report: Dictionary = mesh.get_last_report()
		_expect(result != null and not is_same(result, mesh), "Reduce %s on the %s should reduce it (%s)." % [case[2], case[0], mesh.get_last_error()])
		if result == null or is_same(result, mesh):
			continue
		var ab: Dictionary = result.distance_to(mesh, 400000, 60.0)
		var ba: Dictionary = mesh.distance_to(result, 400000, 60.0)
		var dense := maxf(ab.get("max", INF), ba.get("max", INF))
		var said := float((report.get("deviation", {}) as Dictionary).get("max", -1.0))
		_expect(said >= 0.98 * dense, "Reduce %s on the %s reports a deviation of %.6f mm, under the %.6f mm measured with 400,000 samples each way." % [case[2], case[0], said / MM, dense / MM])
		notes.append("%s to %d: report %.5f, measured %.5f mm" % [case[0], result.triangle_count(), said / MM, dense / MM])
	checked.append("A6 Reduce by proportion or face count reports a deviation no lower than measured (%s)" % "; ".join(notes))


func _check_picked_outline_sentence() -> void:
	# A7: "the fill lies back on the sheet and encloses next to nothing" was said of bent sheets
	# whose closed result encloses 2,000 to 8,000 mm3.
	var notes := []
	for degrees: float in [0.0, 30.0, 60.0]:
		var bent := FIXTURES.deformed(FIXTURES.grid_plate(0.04, 8), func(v: Vector3) -> Vector3: return Vector3(v.x, maxf(v.x, 0.0) * tan(deg_to_rad(degrees)), v.z))
		var mesh := _mesh(bent)
		var result: RefCounted = mesh.close_holes({"loops": PackedInt32Array([0])})
		var warning: String = mesh.get_last_warning()
		_expect(result != null and warning.contains("looks like the outline of an open sheet") and not warning.contains("next to nothing"),
			"A picked outline of a plate bent %.0f degrees should be closed with a true sentence (it encloses %.0f mm3; '%s')." % [degrees, absf(result.volume()) * 1e9 if result != null else -1.0, warning])
		notes.append("%.0f deg: %.0f mm3" % [degrees, absf(result.volume()) * 1e9 if result != null else -1.0])
	checked.append("A7 a picked outline is closed with a true sentence (%s)" % "; ".join(notes))


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error(message)
		print("FAIL: ", message)
