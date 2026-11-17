extends SceneTree
## Holo Forge Mesh workspace, native class CadMesh, part 2 (Phase 7 work order, 5.1 #15 to 26,
## Stage N2: the pmp-library, meshoptimizer and own-code ops).
##
## Remesh (uniform on a clean and on a noisy ball: edge length, deviation, the "rougher" warning
## exactly when the two-sided deviation is over a quarter of the edge; face group borders kept
## where they were; a selection leaves the rest bit for bit; the time limit), Reduce (adaptive and
## fast to 50 %, face group borders with fast, by tolerance), Close Holes (the holed blob with
## every fill type, a 600-edge hole through ear clipping, Largest Hole, picked loops), Stitch and
## Remove (the debris cube, hollow cubes: a void is never turned), Generate Face Groups,
## fit_primitive, Smooth (volume kept, a selection's locked vertices), Reverse Normal, the two
## group edits (regroup), delete_triangles (with the loops it opens, for Erase and Fill) and
## welded. Then refusals (ranges by field name, meshes the libraries cannot hold, over-budget
## bodies refused before any work) and timing ratios.
## (HOLO_FORGE_TIMING_SLOWDOWN=3 fails all three timing checks: checked on 2026-11-11.)
##
## godot --headless --path . --script res://tests/holo_forge_mesh_native_pmp_test.gd

const FIXTURES := preload("res://tests/holo_forge_mesh_fixtures.gd")
const TIMING := preload("res://tests/holo_forge_timing.gd")

const MM := 0.001

## Timing ratio limits (work order 5.7): 2 x the ratio measured on the dev machine (Ryzen 9
## 5900HX) on 2026-11-11 against a sphere make + tessellate calibration of about 3.4 ms. Each op
## runs on a fresh CadMesh, so the time holds set_arrays and every structure the op builds, and
## the op's own checks at its end.
const LIMITS := {
	"reduce_fast_1m": 575.0,       # measured 1,391 ms against a calibration of 4.84 ms (other teams' tests were running), ratio 287 (limit of the work order: 2 s)
	"reduce_adaptive_82k": 765.0,  # measured 1,549 ms, ratio 381 (2026-11-13: with the deviation now measured at every changed triangle, 0.7 s of it): 81,920 triangles of a noisy ball, the 3-call staircase (limit of the work order: 6 s at 100k)
	"remesh_82k_10": 990.0,        # measured 2,371 ms, ratio 494: 81,920 triangles, 10 passes at the ball's own edge (limit of the work order: 12 s at 100k)
}

var failures: Array[String] = []
var checked: Array[String] = []
var kernel: RefCounted
var _started := false
var _finished := false


func _init() -> void:
	call_deferred("run")


## A script error stops run() in the middle: the test then fails here and does not hang.
func _process(_delta: float) -> bool:
	if _started and not _finished:
		print("FAIL holo_forge_mesh_native_pmp: the test stopped on a script error.")
		_finished = true
		quit(1)
	return false


func run() -> void:
	_started = true
	if not ClassDB.class_exists("CadMesh") or not ClassDB.class_exists("CadKernel"):
		print("NOTE: CadMesh is not registered (the holo_forge native DLL is missing): native mesh checks skipped.")
		print("PASS holo_forge_mesh_native_pmp: skipped, the native library is not loaded.")
		_finished = true
		quit(0)
		return
	kernel = ClassDB.instantiate("CadKernel")
	_check_remesh_uniform()
	_check_remesh_groups()
	_check_remesh_selection()
	_check_reduce_adaptive()
	_check_reduce_fast()
	_check_reduce_tolerance()
	_check_close_holes()
	_check_close_big_hole()
	_check_stitch()
	_check_groups()
	_check_smooth()
	_check_reverse()
	_check_delete_and_weld()
	_check_hard_cases()
	_check_refusals()
	_check_timing()
	print(("PASS holo_forge_mesh_native_pmp: " + "; ".join(checked) + ".") if failures.is_empty() else "FAIL holo_forge_mesh_native_pmp")
	_finished = true
	quit(0 if failures.is_empty() else 1)


func _new() -> RefCounted:
	return ClassDB.instantiate("CadMesh")


func _mesh(fixture: Dictionary) -> RefCounted:
	var mesh := _new()
	_expect(mesh.set_arrays(fixture.positions, fixture.indices, fixture.groups, fixture.names, "godot"), "A fixture should load (%s)." % mesh.get_last_error())
	return mesh


## The largest of the two one-sided distances between two meshes (20,000 samples each way).
func _two_sided(a: RefCounted, b: RefCounted) -> float:
	var ab: Dictionary = a.distance_to(b, 20000, 20.0)
	var ba: Dictionary = b.distance_to(a, 20000, 20.0)
	return maxf(ab.get("max", INF), ba.get("max", INF))


## Mean length of the edges of a mesh (each edge once).
func _mean_edge(mesh: RefCounted) -> float:
	var arrays: Dictionary = mesh.get_arrays()
	var positions: PackedVector3Array = arrays.positions
	var indices: PackedInt32Array = arrays.indices
	var seen := {}
	var sum := 0.0
	for i in range(0, indices.size(), 3):
		for k in 3:
			var u := indices[i + k]
			var v := indices[i + (k + 1) % 3]
			var key := (mini(u, v) << 32) | maxi(u, v)
			if not seen.has(key):
				seen[key] = true
				sum += positions[u].distance_to(positions[v])
	return sum / maxf(1.0, float(seen.size()))


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


func _distance_to_segment(p: Vector3, a: Vector3, b: Vector3) -> float:
	var d := b - a
	var l2 := d.length_squared()
	var t := clampf((p - a).dot(d) / l2, 0.0, 1.0) if l2 > 0.0 else 0.0
	return p.distance_to(a + d * t)


## The corner positions of the triangles `tris` (all when empty), in order: for bit-for-bit checks.
func _corners(mesh: RefCounted, count := -1) -> PackedVector3Array:
	var arrays: Dictionary = mesh.get_arrays()
	var positions: PackedVector3Array = arrays.positions
	var indices: PackedInt32Array = arrays.indices
	var out := PackedVector3Array()
	var n := indices.size() if count < 0 else mini(indices.size(), count * 3)
	out.resize(n)
	for i in n:
		out[i] = positions[indices[i]]
	return out


## The triangles of a mesh as a set of sorted corner-position triples (as strings of the bits).
func _triangle_set(mesh: RefCounted) -> Dictionary:
	var arrays: Dictionary = mesh.get_arrays()
	var positions: PackedVector3Array = arrays.positions
	var indices: PackedInt32Array = arrays.indices
	var out := {}
	for i in range(0, indices.size(), 3):
		var keys := [var_to_bytes(positions[indices[i]]).hex_encode(), var_to_bytes(positions[indices[i + 1]]).hex_encode(), var_to_bytes(positions[indices[i + 2]]).hex_encode()]
		keys.sort()
		out["".join(keys)] = true
	return out


func _number_in(text: String, before: String) -> float:
	var at := text.find(before)
	if at < 0:
		return NAN
	var rest := text.substr(at + before.length()).strip_edges()
	var end := 0
	while end < rest.length() and (rest[end].is_valid_int() or rest[end] in [".", "-", "e", "+"]):
		end += 1
	return rest.substr(0, end).trim_suffix(".").to_float()


# ---------------------------------------------------------------- 15


func _check_remesh_uniform() -> void:
	var ball := _mesh(FIXTURES.icosphere(0.05, 4))
	var result: RefCounted = ball.remesh({"edge_length": 2 * MM})
	_expect(result != null and ball.get_last_error() == "", "Remesh of a clean ball should work (%s)." % ball.get_last_error())
	if result == null:
		return
	var report: Dictionary = ball.get_last_report()
	var warning: String = ball.get_last_warning()
	var mean := _mean_edge(result)
	var deviation := _two_sided(result, ball)
	var c: Dictionary = result.check(5.0)
	_expect(absf(mean - 2 * MM) <= 0.2 * MM and absf(report.mean_edge - mean) < 1e-6,
		"Remesh at 2 mm should give edges within 10 %% of 2 mm (mean %.4f mm, report %.4f mm)." % [mean / MM, float(report.mean_edge) / MM])
	_expect(deviation <= 0.5 * MM and float(report.deviation.max) <= 0.5 * MM, "Remesh of a clean ball at 2 mm should stay within 0.5 mm of it both ways (%.4f mm)." % (deviation / MM))
	_expect(not warning.contains("rougher") and warning == "", "Remesh of a clean ball should not warn ('%s')." % warning)
	_expect(c.closed and c.manifold and c.oriented and c.self_intersections == 0, "The remeshed ball should be closed and clean (%s)." % [c])
	_expect(report.passes == 10 and report.op == "remesh" and report.checks.deviation == "ok", "The Remesh report should say 10 passes and a deviation that is ok (%s)." % [report.checks])
	# A noisy ball at its own mean edge: a result, not a failure; the result lies on the input
	# within half an edge; the warning is there exactly when both ways are over a quarter.
	var warned := 0
	for sigma: float in [0.2, 0.4]:
		var fixture := FIXTURES.with_noise(FIXTURES.icosphere(0.05, 4), sigma)
		var noisy := _mesh(fixture)
		var edge: float = fixture.mean_edge
		var smooth: RefCounted = noisy.remesh({"edge_length": edge})
		_expect(smooth != null, "Remesh of a noisy ball (sigma %.1f) should give a result (%s)." % [sigma, noisy.get_last_error()])
		if smooth == null:
			continue
		var text: String = noisy.get_last_warning()
		var noisy_report: Dictionary = noisy.get_last_report()
		var one_way: Dictionary = smooth.distance_to(noisy, 20000, 20.0)
		var both: float = noisy_report.deviation.max
		_expect(one_way.max <= 0.5 * edge, "The remeshed noisy ball (sigma %.1f) should lie within half an edge of the input (%.4f of an edge)." % [sigma, one_way.max / edge])
		_expect(text.contains("rougher") == (both > 0.25 * edge),
			"The 'rougher' warning should be there exactly when the two-sided deviation is over a quarter edge (sigma %.1f: %.4f of an edge, warning '%s')." % [sigma, both / edge, text])
		if text.contains("rougher"):
			warned += 1
			var said := _number_in(text, "deviation ")
			_expect(absf(said - both / MM) <= 0.001 * both / MM + 1e-4, "The warning should carry the measured deviation (%.4f mm; it says %s)." % [both / MM, said])
	_expect(warned >= 1, "At least the noisier ball should bring the 'rougher' warning.")
	checked.append("remesh uniform (clean ball at 2 mm: mean edge %.3f mm, deviation %.4f mm, closed, no warning; noisy balls: a result within half an edge, the 'rougher' warning exactly over a quarter edge, with the number)" % [mean / MM, deviation / MM])


# ---------------------------------------------------------------- 16


func _check_remesh_groups() -> void:
	var bracket := FIXTURES.l_bracket()
	_expect(not bracket.is_empty(), "The L-bracket fixture should build.")
	if bracket.is_empty():
		return
	var mesh: RefCounted = bracket.mesh
	var before := _border_segments(mesh)
	var worst := 0.0
	var restored := 0
	for edge: float in [1 * MM, 2 * MM, 4 * MM]:
		var result: RefCounted = mesh.remesh({"edge_length": edge})
		_expect(result != null, "Remesh of the L-bracket at %.0f mm should work (%s)." % [edge / MM, mesh.get_last_error()])
		if result == null:
			continue
		var report: Dictionary = mesh.get_last_report()
		restored += int(report.corners_restored)
		_expect(result.group_count() == mesh.group_count() and result.get_face_names() == mesh.get_face_names(),
			"Remesh should keep the face groups and their names (%s against %s)." % [result.get_face_names(), mesh.get_face_names()])
		# Every border edge of the result on an original border: its ends and its middle.
		var off := 0.0
		for segment: Array in _border_segments(result):
			for p: Vector3 in [segment[0], (segment[0] + segment[1]) * 0.5, segment[1]]:
				var nearest := INF
				for original: Array in before:
					nearest = minf(nearest, _distance_to_segment(p, original[0], original[1]))
				off = maxf(off, nearest)
		worst = maxf(worst, off)
		_expect(off <= 1e-6 and float(report.border_deviation) <= 1e-6,
			"At %.0f mm every group border edge should lie within 1e-6 m of an original border (off by %.10f m; the report says %.10f)." % [edge / MM, off, float(report.border_deviation)])
		var c: Dictionary = result.check(5.0)
		_expect(c.closed and c.manifold and c.oriented, "The remeshed L-bracket should be closed and manifold (%s)." % [c])
		_expect(absf(result.volume() - mesh.volume()) <= 0.005 * mesh.volume(), "The remeshed L-bracket should keep its volume within 0.5 %% (%.9f against %.9f)." % [result.volume(), mesh.volume()])
	checked.append("remesh keeps groups (L-bracket at 1, 2 and 4 mm: %d groups with their names, every border edge within %.10f m of an original border, %d border corners put back)" \
		% [mesh.group_count(), worst, restored])


func _check_remesh_selection() -> void:
	var ball := _mesh(FIXTURES.icosphere(0.05, 4))
	var arrays: Dictionary = ball.get_arrays()
	var selection := PackedInt32Array()
	for t in ball.triangle_count():
		if arrays.positions[arrays.indices[t * 3]].z > 0.01 and arrays.positions[arrays.indices[t * 3 + 1]].z > 0.01 and arrays.positions[arrays.indices[t * 3 + 2]].z > 0.01:
			selection.append(t)
	var picked := {}
	for t in selection:
		picked[t] = true
	var outside := _new()
	var kept := PackedInt32Array()
	for t in ball.triangle_count():
		if not picked.has(t):
			kept.append_array([arrays.indices[t * 3], arrays.indices[t * 3 + 1], arrays.indices[t * 3 + 2]])
	outside.set_arrays(arrays.positions, kept)
	var result: RefCounted = ball.remesh({"edge_length": 2 * MM, "triangles": selection})
	_expect(result != null, "Remesh of a selection should work (%s)." % ball.get_last_error())
	if result == null:
		return
	var after := _triangle_set(result)
	var missing := 0
	for key: String in _triangle_set(outside):
		if not after.has(key):
			missing += 1
	var c: Dictionary = result.check(5.0)
	_expect(missing == 0, "Remesh of a selection should leave every triangle outside it bit for bit (%d changed)." % missing)
	_expect(c.closed and c.manifold and result.triangle_count() > ball.triangle_count(), "The ball with a remeshed selection should stay closed, with more triangles (%d; %s)." % [result.triangle_count(), c])
	var tiny: RefCounted = ball.remesh({"edge_length": 2 * MM, "triangles": PackedInt32Array([5])})
	_expect(is_same(tiny, ball) and ball.get_last_warning().contains("too small to remesh"), "A selection without an inner vertex should give the mesh back with a warning ('%s')." % ball.get_last_warning())
	checked.append("remesh selection (%d of %d triangles remeshed, every triangle outside bit for bit, closed; one triangle: unchanged with the 'too small' warning)" % [selection.size(), ball.triangle_count()])


# ---------------------------------------------------------------- 17, 18, 19


func _check_reduce_adaptive() -> void:
	var ball := _mesh(FIXTURES.icosphere(0.05, 5))
	var result: RefCounted = ball.reduce({"method": "adaptive", "proportion": 50})
	_expect(result != null and ball.get_last_warning() == "", "Reduce (adaptive) to 50 %% should work without a warning (%s; '%s')." % [ball.get_last_error(), ball.get_last_warning()])
	if result == null:
		return
	var report: Dictionary = ball.get_last_report()
	var deviation := _two_sided(result, ball)
	var c: Dictionary = result.check(5.0)
	_expect(absi(result.triangle_count() - 10240) <= 204, "Reduce to 50 %% should land within 2 %% of 10,240 triangles (%d)." % result.triangle_count())
	_expect(deviation <= 0.05 * MM and float(report.deviation.max) <= 0.05 * MM, "Reduce (adaptive) to 50 %% should stay within 0.05 mm both ways (%.4f mm; the report says %.4f mm)." % [deviation / MM, float(report.deviation.max) / MM])
	_expect(c.closed and c.manifold and c.oriented and c.self_intersections == 0, "The reduced ball should be closed and manifold (%s)." % [c])
	# Every vertex left is an input vertex, where it was.
	var input := {}
	for p: Vector3 in ball.get_arrays().positions:
		input[p] = true
	var moved := 0
	for p: Vector3 in result.get_arrays().positions:
		if not input.has(p):
			moved += 1
	_expect(moved == 0, "Reduce should move no vertex (%d are not input vertices)." % moved)
	checked.append("reduce adaptive 50 %% (20,480 -> %d triangles, deviation %.4f mm both ways, closed, no vertex moved, %d library calls)" % [result.triangle_count(), deviation / MM, int(report.calls)])


func _check_reduce_fast() -> void:
	var ball := _mesh(FIXTURES.icosphere(0.05, 5))
	var result: RefCounted = ball.reduce({"method": "fast", "proportion": 50})
	_expect(result != null, "Reduce (fast) to 50 %% should work (%s)." % ball.get_last_error())
	if result == null:
		return
	var warning: String = ball.get_last_warning()
	var deviation := _two_sided(result, ball)
	var c: Dictionary = result.check(5.0)
	var count: int = result.triangle_count()
	if absi(count - 10240) > 204:
		_expect(warning.contains("Reduce kept %s triangles" % _commas(count)) and warning.contains("instead of 10,240"), "Off the target, the warning should carry the numbers (%d; '%s')." % [count, warning])
	_expect(c.boundary_edges == 0, "Reduce (fast) of a closed ball should leave no open edge (%d)." % int(c.boundary_edges))
	if c.non_manifold_edges > 0:
		_expect(warning.contains("Fast left %d edges" % int(c.non_manifold_edges)), "Edges with more than two triangles should come with the warning that counts them (%d; '%s')." % [int(c.non_manifold_edges), warning])
	else:
		_expect(not warning.contains("Fast left"), "Without such edges there should be no warning about them ('%s')." % warning)
	# (Measured 0.085 mm on this ball: the fast method does not reach the 0.05 mm the adaptive one keeps.)
	_expect(deviation <= 0.12 * MM, "Reduce (fast) to 50 %% should stay within 0.12 mm both ways (%.4f mm)." % (deviation / MM))
	# Face group borders: two groups split at z = 0.
	var fixture := FIXTURES.icosphere(0.05, 5)
	var groups := PackedInt32Array()
	groups.resize(20480)
	for t in 20480:
		var z: float = fixture.positions[fixture.indices[t * 3]].z + fixture.positions[fixture.indices[t * 3 + 1]].z + fixture.positions[fixture.indices[t * 3 + 2]].z
		groups[t] = 1 if z > 0.0 else 0
	var two := _new()
	_expect(two.set_arrays(fixture.positions, fixture.indices, groups, PackedStringArray(["low", "high"])), "A two-group ball should load.")
	var border_before := _border_segments(two)
	var kept: RefCounted = two.reduce({"method": "fast", "proportion": 50, "keep_groups": true})
	_expect(kept != null, "Reduce (fast) with Keep Face Group Borders should work (%s)." % two.get_last_error())
	if kept == null:
		return
	var report: Dictionary = two.get_last_report()
	var border_after := _border_segments(kept)
	var points_before := {}
	var length_before := 0.0
	for segment: Array in border_before:
		points_before[segment[0]] = true
		points_before[segment[1]] = true
		length_before += segment[0].distance_to(segment[1])
	var points_after := {}
	var length_after := 0.0
	for segment: Array in border_after:
		points_after[segment[0]] = true
		points_after[segment[1]] = true
		length_after += segment[0].distance_to(segment[1])
	var same_points := points_before.size() == points_after.size()
	for p: Vector3 in points_before:
		same_points = same_points and points_after.has(p)
	_expect(absi(kept.triangle_count() - 10240) <= 204 and kept.group_count() == 2 and kept.get_face_names() == PackedStringArray(["low", "high"]),
		"Reduce (fast) with borders kept should land within 2 %% with both groups (%d triangles, %s)." % [kept.triangle_count(), kept.get_face_names()])
	_expect(same_points and points_before.size() > 100, "Every group-border vertex should be where it was, bit for bit (%d before, %d after)." % [points_before.size(), points_after.size()])
	_expect(absf(length_after - length_before) <= 1e-6 * length_before and absf(float(report.border_length_after) - float(report.border_length_before)) <= 1e-6 * length_before,
		"The border length should not change (%.9f against %.9f m)." % [length_after, length_before])
	checked.append("reduce fast 50 %% (20,480 -> %d triangles, deviation %.4f mm, no open edge, %d edges with more than two triangles; with two groups: %d triangles, %d border vertices bit for bit, border length kept)" \
		% [count, deviation / MM, int(c.non_manifold_edges), kept.triangle_count(), points_before.size()])


func _check_reduce_tolerance() -> void:
	var ball := _mesh(FIXTURES.icosphere(0.05, 5))
	# 0.01 mm: taking one vertex off this ball moves the surface by about 0.03 mm (its height
	# over its ring), so nothing can go; the honest result is the ball as it is, said in words.
	var tight: RefCounted = ball.reduce({"target": "tolerance", "tolerance": 0.01 * MM})
	_expect(tight != null, "Reduce by a 0.01 mm tolerance should give a result (%s)." % ball.get_last_error())
	var tight_count := 0
	if tight != null:
		var tight_warning: String = ball.get_last_warning()
		tight_count = tight.triangle_count()
		var off := _two_sided(tight, ball)
		_expect(off <= 0.01 * MM, "Reduce by a 0.01 mm tolerance should stay within it (%.5f mm)." % (off / MM))
		_expect(tight_count < 20480 or tight_warning.contains("Nothing could be taken out within the Maximum Deviation of 0.01 mm"),
			"When nothing fits the tolerance, the warning should say so (%d triangles; '%s')." % [tight_count, tight_warning])
	var counts := []
	for case: Array in [["adaptive", 0.1 * MM], ["adaptive", 0.3 * MM], ["fast", 0.3 * MM]]:
		var result: RefCounted = ball.reduce({"target": "tolerance", "tolerance": case[1], "method": case[0]})
		_expect(result != null, "Reduce (%s) by a %.2f mm tolerance should work (%s)." % [case[0], case[1] / MM, ball.get_last_error()])
		if result == null:
			continue
		var report: Dictionary = ball.get_last_report()
		var off := _two_sided(result, ball)
		_expect(off <= case[1] and float(report.deviation.max) <= case[1], "Reduce (%s) by a %.2f mm tolerance should stay within it (%.4f mm)." % [case[0], case[1] / MM, off / MM])
		_expect(result.triangle_count() < 20480 and result.check(5.0).closed, "Reduce (%s) by a %.2f mm tolerance should take triangles out and stay closed (%d)." % [case[0], case[1] / MM, result.triangle_count()])
		counts.append("%s %.1f mm: %d" % [case[0], case[1] / MM, result.triangle_count()])
	# The fast method cannot hold a deviation this small on this ball: the ball itself comes back
	# with the reason (fix round 2026-11-12: no longer an error), never a wrong result.
	var fast: RefCounted = ball.reduce({"target": "tolerance", "tolerance": 0.01 * MM, "method": "fast"})
	var fast_warning: String = ball.get_last_warning()
	_expect(fast != null and ((is_same(fast, ball) and fast_warning.contains("Nothing could be taken out within the Maximum Deviation of 0.01 mm") and fast_warning.contains("Adaptive")) \
		or (not is_same(fast, ball) and _two_sided(fast, ball) <= 0.01 * MM)),
		"Reduce (fast) by a 0.01 mm tolerance should give the ball back with the reason, or a result within it (%s; '%s'; '%s')." % [fast, fast_warning, ball.get_last_error()])
	checked.append("reduce by tolerance (0.01 mm: %d triangles within it, with the 'nothing could be taken out' warning; %s, each within its tolerance; fast at 0.01 mm gives the ball back and says why)" \
		% [tight_count, ", ".join(counts)])


func _commas(value: int) -> String:
	var text := str(value)
	var out := ""
	while text.length() > 3:
		out = "," + text.substr(text.length() - 3) + out
		text = text.substr(0, text.length() - 3)
	return text + out


# ---------------------------------------------------------------- 20, 21


func _check_close_holes() -> void:
	var fixture := FIXTURES.holed_blob()
	var blob := _mesh(fixture)
	var reference := _mesh(fixture.reference)
	var before := _corners(blob)
	var loops: Array = blob.boundary_loops()
	_expect(loops.size() == 5, "The holed blob should have 5 holes (%d)." % loops.size())
	var volumes := []
	for fill: String in ["smooth", "minimal", "flat"]:
		var result: RefCounted = blob.close_holes({"fill": fill})
		_expect(result != null and blob.get_last_warning() == "", "Close Holes (%s) should work without a warning (%s; '%s')." % [fill, blob.get_last_error(), blob.get_last_warning()])
		if result == null:
			continue
		var report: Dictionary = blob.get_last_report()
		var c: Dictionary = result.check(5.0)
		_expect(c.closed and c.manifold and c.oriented and c.boundary_edges == 0 and c.self_intersections == 0, "Close Holes (%s) should close the blob (%s)." % [fill, c])
		_expect(_corners(result, blob.triangle_count()) == before, "Close Holes (%s) should leave the original triangles bit for bit." % fill)
		_expect(absf(result.volume() - reference.volume()) <= 0.01 * reference.volume(), "The closed blob (%s) should have the reference's volume within 1 %% (%.9f against %.9f)." % [fill, result.volume(), reference.volume()])
		_expect(result.group_count() == 6 and result.get_face_names() == PackedStringArray(["g0", "fill0", "fill1", "fill2", "fill3", "fill4"]) and report.filled_loops == PackedInt32Array([0, 1, 2, 3, 4]),
			"Each hole's fill should be a group fill<k> (%s)." % [result.get_face_names()])
		_expect((int(report.new_vertices) > 0) == (fill != "minimal"), "Only the minimal fill adds no vertex (%s: %d)." % [fill, int(report.new_vertices)])
		volumes.append("%s %.2f %%" % [fill, 100.0 * (result.volume() / reference.volume() - 1.0)])
	# Largest Hole, and picked loops.
	var some: RefCounted = blob.close_holes({"max_edges": 20})
	_expect(some != null and some.boundary_loops().size() == 2 and blob.get_last_warning().contains("2 holes were larger than Largest Hole and stay open"),
		"Largest Hole 20 should leave the two big holes open and say so ('%s')." % blob.get_last_warning())
	var picked: RefCounted = blob.close_holes({"loops": PackedInt32Array([1, 3])})
	_expect(picked != null and picked.boundary_loops().size() == 3 and blob.get_last_report().fill_groups == PackedStringArray(["fill0", "fill1"]), "Two picked holes should close, three stay (%s)." % blob.get_last_error())
	_expect(blob.close_holes({"loops": PackedInt32Array([9])}) == null and blob.get_last_error().contains("Hole 9 is not in the mesh"), "A hole that is not there should be refused ('%s')." % blob.get_last_error())
	var whole: RefCounted = reference.close_holes({})
	_expect(is_same(whole, reference) and reference.get_last_warning().contains("no open edges"), "A closed mesh should come back as it is, with a note ('%s')." % reference.get_last_warning())
	checked.append("close_holes (holed blob, 5 holes, smooth, minimal and flat: closed, originals bit for bit, groups fill0..fill4, volume against the reference: %s; Largest Hole; picked loops)" % ", ".join(volumes))


## A tube of `sides` sides closed at one end by a fan: one open loop of `sides` edges.
func _open_tube(sides: int) -> Dictionary:
	var positions := PackedVector3Array()
	var rings := 6
	var radius := 20 * MM
	for r in rings:
		for i in sides:
			var angle := TAU * i / sides
			# (Not flat: the open end waves a little, so the fill is no plain disc.)
			var wave := 1.5 * MM * sin(3.0 * angle) if r == rings - 1 else 0.0
			positions.append(Vector3(radius * cos(angle), r * 4 * MM + wave, radius * sin(angle)))
	var bottom := positions.size()
	positions.append(Vector3(0, 0, 0))
	var ccw := PackedInt32Array()
	for r in rings - 1:
		for i in sides:
			var a := r * sides + i
			var b := r * sides + (i + 1) % sides
			var c := a + sides
			var d := b + sides
			ccw.append_array([a, c, b, b, c, d])
	for i in sides:
		ccw.append_array([bottom, i, (i + 1) % sides])
	return FIXTURES._pack(positions, ccw)


func _check_close_big_hole() -> void:
	var tube := _mesh(_open_tube(600))
	var loops: Array = tube.boundary_loops()
	_expect(loops.size() == 1 and loops[0].edges == 600, "The tube should have one hole of 600 edges (%s)." % [loops.size()])
	var before := _corners(tube)
	var notes := []
	for fill: String in ["minimal", "smooth"]:
		var result: RefCounted = tube.close_holes({"fill": fill})
		_expect(result != null, "Close Holes (%s) on a 600-edge hole should work (%s)." % [fill, tube.get_last_error()])
		if result == null:
			continue
		var c: Dictionary = result.check(5.0)
		_expect(c.closed and c.manifold and c.oriented and c.boundary_edges == 0, "The 600-edge hole (%s) should be closed (%s)." % [fill, c])
		_expect(_corners(result, tube.triangle_count()) == before, "Close Holes (%s) should leave the tube's triangles bit for bit." % fill)
		_expect(result.volume() > 0.0, "The closed tube (%s) should face out (volume %.9f)." % [fill, result.volume()])
		notes.append("%s: %d new triangles" % [fill, result.triangle_count() - tube.triangle_count()])
	checked.append("close_holes big hole (600 edges, the ear-clipping path: closed and manifold; %s)" % ", ".join(notes))


# ---------------------------------------------------------------- 22


func _check_stitch() -> void:
	var fixture := FIXTURES.cube_debris()
	var debris := _mesh(fixture)
	var clean: RefCounted = debris.stitch_and_remove({})
	_expect(clean != null, "Stitch and Remove on the debris cube should work (%s)." % debris.get_last_error())
	if clean == null:
		return
	var report: Dictionary = debris.get_last_report()
	var expected: Dictionary = fixture.expected
	var c: Dictionary = clean.check(5.0)
	_expect(clean.triangle_count() == 12 and c.closed and c.manifold and c.oriented and absf(clean.volume() - 8e-6) < 1e-11, "The debris cube should come out as a closed cube of 12 triangles (%d; %s)." % [clean.triangle_count(), c])
	_expect(report.welded_vertices == expected.split and report.removed_duplicates == expected.duplicate and report.removed_fins == expected.fin and report.removed_pieces == expected.tiny \
		and report.removed_triangles == expected.duplicate + expected.fin + expected.tiny and report.fixed_non_manifold_edges == 1,
		"The Stitch report should count what the fixture holds (welded %s, duplicates %s, fins %s, pieces %s, triangles %s, edges fixed %s; fixture %s)." \
		% [report.welded_vertices, report.removed_duplicates, report.removed_fins, report.removed_pieces, report.removed_triangles, report.fixed_non_manifold_edges, expected])
	_expect(report.summary == "Welded 3 vertices, removed 36 triangles and 30 pieces, fixed 1 non-manifold edge.", "The Stitch summary should read as the stat row needs it ('%s')." % report.summary)
	var kept: RefCounted = debris.stitch_and_remove({"remove_small": false})
	_expect(kept != null and kept.triangle_count() == 42 and debris.get_last_report().removed_pieces == 0, "With Remove Small Pieces off the 30 tiny triangles stay (%d)." % (kept.triangle_count() if kept != null else -1))
	# Hollow cubes: the void faces in and is not turned; turned on input, it is turned back.
	var hollow := _mesh(FIXTURES.hollow_cube(false))
	var same: RefCounted = hollow.stitch_and_remove({})
	_expect(same != null and same.triangle_count() == 24 and absf(same.volume() - 7e-6) < 1e-11 and hollow.get_last_report().flipped_triangles == 0,
		"A correct hollow cube should keep its void (24 triangles, 7,000 mm3; got %s, %.9f)." % [same.triangle_count() if same != null else -1, same.volume() if same != null else 0.0])
	var turned_fixture := FIXTURES.hollow_cube(false)
	var indices: PackedInt32Array = turned_fixture.indices.duplicate()
	for t: int in turned_fixture.void_triangles:
		var keep := indices[t * 3 + 1]
		indices[t * 3 + 1] = indices[t * 3 + 2]
		indices[t * 3 + 2] = keep
	turned_fixture.indices = indices
	var turned := _mesh(turned_fixture)
	var fixed: RefCounted = turned.stitch_and_remove({})
	_expect(fixed != null and absf(fixed.volume() - 7e-6) < 1e-11 and turned.get_last_report().flipped_triangles == 12 and turned.get_last_report().flipped_pieces == 1,
		"A void turned inside-out should be turned back (7,000 mm3; got %.9f, %s triangles turned)." % [fixed.volume() if fixed != null else 0.0, turned.get_last_report().get("flipped_triangles")])
	var solid: RefCounted = hollow.stitch_and_remove({"remove_inner": true})
	_expect(solid != null and solid.triangle_count() == 12 and absf(solid.volume() - 8e-6) < 1e-11, "Remove Pieces Inside Others should take the void out (12 triangles, 8,000 mm3).")
	# Two crossing balls in one mesh: neither is turned.
	var crossing := _mesh(FIXTURES.self_crossing())
	var crossed: RefCounted = crossing.stitch_and_remove({})
	_expect(crossed != null and crossing.get_last_report().flipped_triangles == 0 and crossed.triangle_count() == 2560, "Two crossing balls should not be turned by Stitch and Remove (%s)." % crossing.get_last_error())
	# Two cubes that share an edge: the edge of four triangles becomes two edges of two.
	var pair := _mesh(FIXTURES.two_cubes(Vector3(0.02, 0.02, 0)))
	var joined: RefCounted = pair.welded()
	var apart: RefCounted = joined.stitch_and_remove({}) if joined != null else null
	_expect(apart != null and joined.check(5.0).non_manifold_edges == 1 and apart.check(5.0).closed and apart.check(5.0).components == 2 and absf(apart.volume() - 16e-6) < 1e-11,
		"Two cubes on one edge should come apart into two closed cubes (%s)." % (joined.get_last_error() if joined != null else pair.get_last_error()))
	checked.append("stitch_and_remove (debris cube -> 12 triangles, closed, counts as built: 3 welded, 5 duplicates, 1 fin, 30 pieces; hollow cube kept at 7,000 mm3, a turned void turned back; crossing balls untouched; cubes on one edge split)")


# ---------------------------------------------------------------- 23, 24


func _check_groups() -> void:
	var bracket := FIXTURES.l_bracket()
	if bracket.is_empty():
		_expect(false, "The L-bracket fixture should build.")
		return
	var mesh: RefCounted = bracket.mesh
	var names: PackedStringArray = mesh.get_face_names()
	var one: RefCounted = mesh.regroup({"groups": names})
	_expect(one != null and one.group_count() == 1 and one.get_face_names() == PackedStringArray([names[0]]) and one.triangle_count() == mesh.triangle_count(),
		"Combining every group should leave one, named like the first (%s; %s)." % [mesh.get_last_error(), one.get_face_names() if one != null else []])
	if one == null:
		return
	var counts := []
	for method: String in ["accurate", "fast"]:
		var grouped: RefCounted = one.generate_groups({"method": method, "angle": 20.0})
		_expect(grouped != null and grouped.group_count() == mesh.group_count(), "Generate Face Groups (%s) should find the L-bracket's %d groups (%s; %s)." \
			% [method, mesh.group_count(), grouped.group_count() if grouped != null else -1, one.get_last_error()])
		if grouped == null:
			continue
		var report: Dictionary = one.get_last_report()
		var expected_names := PackedStringArray()
		for g in grouped.group_count():
			expected_names.append("g%d" % g)
		_expect(grouped.get_face_names() == expected_names and _corners(grouped) == _corners(one), "The groups should be named g0..gN and the triangles unchanged (%s)." % [grouped.get_face_names()])
		# Each group of the result is one group of the original (the same triangles).
		var split := true
		var original: PackedInt32Array = mesh.get_arrays().groups
		var found: PackedInt32Array = grouped.get_arrays().groups
		var pairs := {}
		for t in original.size():
			var key := found[t]
			if not pairs.has(key):
				pairs[key] = original[t]
			split = split and pairs[key] == original[t]
		_expect(split, "Generate Face Groups (%s) should give the original groups back, triangle for triangle." % method)
		if method == "accurate":
			_expect(report.planes == 8 and report.cylinders == 1, "Accurate should see 8 planes and 1 cylinder (%s planes, %s cylinders)." % [report.planes, report.cylinders])
		var again: RefCounted = one.generate_groups({"method": method, "angle": 20.0})
		_expect(again != null and again.get_arrays().groups == found and again.digest() == grouped.digest(), "Generate Face Groups (%s) should give the same groups every time." % method)
		counts.append("%s: %d" % [method, grouped.group_count()])
	# Create Face Group.
	var made: RefCounted = mesh.regroup({"triangles": PackedInt32Array([0, 1, 2])})
	_expect(made != null and made.get_face_names()[made.group_count() - 1] == "user0" and made.group_triangles(made.group_count() - 1).size() == 3 and mesh.get_last_report().group == "user0",
		"Create Face Group should put the picked triangles in a new group user0 (%s)." % mesh.get_last_error())
	_expect(mesh.regroup({"groups": PackedStringArray([names[0]])}) == null and mesh.get_last_error().contains("two or more"), "Combining one group should be refused ('%s')." % mesh.get_last_error())
	_expect(mesh.regroup({"groups": PackedStringArray([names[0], "nope"])}) == null and mesh.get_last_error().contains("'nope' is not in the mesh"), "A group that is not there should be refused ('%s')." % mesh.get_last_error())
	# fit_primitive on the hole's group.
	var hole := -1
	var plane_groups := 0
	for g in mesh.group_count():
		var fit: Dictionary = mesh.fit_primitive(mesh.group_triangles(g))
		if fit.get("winner", "") == "cylinder":
			hole = g
		elif fit.get("winner", "") == "plane":
			plane_groups += 1
	_expect(hole >= 0 and plane_groups == mesh.group_count() - 1, "One group of the L-bracket should fit a cylinder and the others planes (%d planes)." % plane_groups)
	var radius := 0.0
	var tilt := 0.0
	if hole >= 0:
		var fit: Dictionary = mesh.fit_primitive(mesh.group_triangles(hole))
		radius = fit.cylinder.radius
		tilt = rad_to_deg(acos(clampf(absf(Vector3(fit.cylinder.axis).dot(bracket.hole_axis)), 0.0, 1.0)))
		var off_axis: float = (Vector3(fit.cylinder.point) - bracket.hole_axis_point).cross(bracket.hole_axis).length()
		_expect(absf(radius - bracket.hole_radius) <= 0.005 * bracket.hole_radius and tilt <= 0.1 and off_axis <= 0.005 * bracket.hole_radius and float(fit.cylinder.max) <= 1e-6,
			"The hole should fit a cylinder of 5 mm along Y (radius %.6f mm, %.4f degrees off, axis %.10f m away, largest error %.10f m)." % [radius / MM, tilt, off_axis, float(fit.cylinder.max)])
	checked.append("generate_groups (L-bracket merged to one group; %s, the original groups triangle for triangle, same every run; Create Face Group user0); fit_primitive (the hole: cylinder, radius %.5f mm, %.4f degrees off its axis)" \
		% [", ".join(counts), radius / MM, tilt])


# ---------------------------------------------------------------- 25


func _check_smooth() -> void:
	var fixture := FIXTURES.with_noise(FIXTURES.icosphere(0.05, 4), 0.2)
	var noisy := _mesh(fixture)
	var clean := _mesh(FIXTURES.icosphere(0.05, 4))
	var result: RefCounted = noisy.smooth({})
	_expect(result != null and noisy.get_last_warning() == "", "Smooth should work without a warning (%s; '%s')." % [noisy.get_last_error(), noisy.get_last_warning()])
	if result == null:
		return
	var report: Dictionary = noisy.get_last_report()
	var change: float = absf(result.volume() - noisy.volume()) / noisy.volume()
	_expect(change <= 0.005 and result.triangle_count() == noisy.triangle_count() and result.get_arrays().indices == noisy.get_arrays().indices,
		"Smooth with Keep Volume should keep the volume within 0.5 %% and the triangles as they are (%.5f %%)." % (100.0 * change))
	var rough_before: float = noisy.distance_to(clean, 20000, 20.0).max
	var rough_after: float = result.distance_to(clean, 20000, 20.0).max
	_expect(rough_after < 0.7 * rough_before and report.method == "implicit" and report.passes == 5, "Smooth should bring the noisy ball closer to the clean one (%.4f mm -> %.4f mm)." % [rough_before / MM, rough_after / MM])
	var loose: RefCounted = noisy.smooth({"keep_volume": false})
	_expect(loose != null and loose.volume() < 0.99 * noisy.volume(), "Without Keep Volume the ball should shrink (%.9f against %.9f)." % [loose.volume() if loose != null else 0.0, noisy.volume()])
	# A selection: every vertex an unselected triangle uses stays bit for bit.
	var selection := PackedInt32Array(range(0, 2000))
	var part: RefCounted = noisy.smooth({"triangles": selection})
	_expect(part != null, "Smooth of a selection should work (%s)." % noisy.get_last_error())
	if part != null:
		var arrays: Dictionary = noisy.get_arrays()
		var after: Dictionary = part.get_arrays()
		var locked := {}
		for t in range(2000, noisy.triangle_count()):
			for k in 3:
				locked[arrays.indices[t * 3 + k]] = true
		var moved_locked := 0
		var moved_free := 0
		for v in arrays.positions.size():
			if arrays.positions[v] != after.positions[v]:
				if locked.has(v):
					moved_locked += 1
				else:
					moved_free += 1
		_expect(moved_locked == 0 and moved_free > 100 and after.indices == arrays.indices and noisy.get_last_report().method == "laplacian",
			"Smooth of a selection should leave the locked vertices bit for bit (%d moved; %d free ones moved)." % [moved_locked, moved_free])
		_expect(absf(part.volume() - noisy.volume()) <= 0.005 * noisy.volume(), "Smooth of a selection with Keep Volume should keep the volume (%.9f against %.9f)." % [part.volume(), noisy.volume()])
	var sharp: RefCounted = noisy.smooth({"keep_sharp": true})
	_expect(sharp != null and noisy.get_last_report().method == "laplacian" and int(noisy.get_last_report().locked_vertices) > 0, "Keep Sharp Edges should use the Laplacian with locks (%s)." % noisy.get_last_error())
	checked.append("smooth (noisy ball: volume change %.5f %% with Keep Volume, triangles unchanged, %.3f mm -> %.3f mm from the clean ball; a selection: locked vertices bit for bit; Keep Sharp Edges)" \
		% [100.0 * change, rough_before / MM, rough_after / MM])


# ---------------------------------------------------------------- reverse, delete, weld


func _check_reverse() -> void:
	var half := _mesh(FIXTURES.flipped_half())
	var fixed: RefCounted = half.reverse({})
	_expect(fixed != null and not half.check(5.0).oriented and fixed.check(5.0).oriented and fixed.volume() > 0.0 and fixed.get_arrays().positions == half.get_arrays().positions,
		"Reverse Normal (auto) should turn the flipped half of the ball out (%s)." % half.get_last_error())
	var hollow := _mesh(FIXTURES.hollow_cube(false))
	var same: RefCounted = hollow.reverse({"mode": "auto"})
	_expect(same != null and same.digest() == hollow.digest() and hollow.get_last_report().flipped_triangles == 0, "Reverse Normal (auto) on a correct hollow cube should change nothing.")
	var island := _mesh(FIXTURES.hollow_cube(true))
	var island_same: RefCounted = island.reverse({"mode": "auto"})
	_expect(island_same != null and island_same.digest() == island.digest(), "Reverse Normal (auto) on a hollow cube with an island should change nothing.")
	var crossing := _mesh(FIXTURES.self_crossing())
	var crossed: RefCounted = crossing.reverse({"mode": "auto"})
	_expect(crossed != null and crossed.digest() == crossing.digest(), "Reverse Normal (auto) should turn neither of two crossing balls.")
	var ball := _mesh(FIXTURES.icosphere(0.05, 2))
	var inside_out: RefCounted = ball.reverse({"mode": "whole"})
	_expect(inside_out != null and absf(inside_out.volume() + ball.volume()) < 1e-12 and inside_out.check(5.0).inverted_components == 1, "Reverse Normal (whole) should turn the ball inside-out.")
	var back: RefCounted = inside_out.reverse({"mode": "auto"}) if inside_out != null else null
	_expect(back != null and back.digest() == ball.digest(), "Reverse Normal (auto) should turn an inside-out ball back to what it was.")
	var some: RefCounted = ball.reverse({"mode": "selection", "triangles": PackedInt32Array([0, 1, 2])})
	_expect(some != null and ball.get_last_report().flipped_triangles == 3 and not some.check(5.0).oriented, "Reverse Normal (selection) should turn the picked triangles only.")
	_expect(ball.reverse({"mode": "selection"}) == null and ball.get_last_error().contains("Select the triangles"), "Reverse Normal (selection) without a selection should be refused ('%s')." % ball.get_last_error())
	checked.append("reverse (auto: the flipped half turned out, hollow cubes and crossing balls untouched, an inside-out ball turned back; whole; selection)")


func _check_delete_and_weld() -> void:
	var ball := _mesh(FIXTURES.icosphere(0.05, 4))
	var patch: PackedInt32Array = ball.triangles_near(Vector3(0.05, 0, 0), 0.01, true)
	var far: PackedInt32Array = ball.triangles_near(Vector3(-0.05, 0, 0), 0.004, true)
	var both := patch.duplicate()
	both.append_array(far)
	var holed: RefCounted = ball.delete_triangles(both)
	_expect(holed != null and holed.triangle_count() == ball.triangle_count() - both.size(), "delete_triangles should take the picked triangles out (%s)." % ball.get_last_error())
	if holed == null:
		return
	var report: Dictionary = ball.get_last_report()
	var picked := {}
	for t in both:
		picked[t] = true
	var arrays: Dictionary = ball.get_arrays()
	var expected := PackedVector3Array()
	for t in ball.triangle_count():
		if not picked.has(t):
			for k in 3:
				expected.append(arrays.positions[arrays.indices[t * 3 + k]])
	_expect(_corners(holed) == expected, "delete_triangles should keep the other triangles bit for bit, in their order.")
	_expect(report.new_loops == PackedInt32Array([0, 1]) and report.merged_loops == PackedInt32Array() and holed.boundary_loops().size() == 2 and report.deleted_triangles == both.size(),
		"Two patches taken out should open two new loops (%s, merged %s)." % [report.new_loops, report.merged_loops])
	# Erase and Fill: close only what the deletion opened.
	var again: RefCounted = holed.delete_triangles(holed.triangles_near(Vector3(0, 0.05, 0), 0.008, true))
	var second: Dictionary = holed.get_last_report()
	_expect(again != null and second.new_loops.size() == 1 and again.boundary_loops().size() == 3, "A third patch should open one new loop beside the two old ones (%s)." % [second.get("new_loops")])
	if again != null:
		var refilled: RefCounted = again.close_holes({"loops": second.new_loops, "fill": "smooth"})
		_expect(refilled != null and refilled.boundary_loops().size() == 2 and refilled.check(5.0).boundary_edges == holed.check(5.0).boundary_edges,
			"Closing the new loop should leave the two old holes as they were (%s)." % again.get_last_error())
	# A deletion that reaches an open edge: the loop is new and merged.
	var edge_triangle: int = -1
	var loop: Dictionary = holed.boundary_loops()[0]
	var holed_arrays: Dictionary = holed.get_arrays()
	for t in holed.triangle_count():
		for k in 3:
			if holed_arrays.indices[t * 3 + k] == loop.vertices[0]:
				edge_triangle = t
	var grown: RefCounted = holed.delete_triangles(PackedInt32Array([edge_triangle]))
	_expect(grown != null and holed.get_last_report().merged_loops.size() == 1 and holed.get_last_report().new_loops == holed.get_last_report().merged_loops,
		"Deleting a triangle at an open edge should report the loop as new and merged (%s)." % [holed.get_last_report().get("merged_loops")])
	_expect(ball.delete_triangles(PackedInt32Array([99999])) == null and ball.get_last_error().contains("Triangle 99999 is not in the mesh"), "A triangle that is not there should be refused ('%s')." % ball.get_last_error())
	_expect(ball.delete_triangles(PackedInt32Array()) == null and ball.delete_triangles(PackedInt32Array(range(0, ball.triangle_count()))) == null and ball.get_last_error().contains("nothing of the mesh"),
		"Deleting nothing or everything should be refused ('%s')." % ball.get_last_error())
	# welded: a cube given as 12 separate triangles (36 vertices), in two groups.
	var cube: Dictionary = FIXTURES.two_cubes(Vector3(0.05, 0, 0)).first
	var soup_positions := PackedVector3Array()
	var soup_indices := PackedInt32Array()
	var soup_groups := PackedInt32Array()
	for i in cube.indices.size():
		soup_positions.append(cube.positions[cube.indices[i]])
		soup_indices.append(i)
	for t in 12:
		soup_groups.append(0 if t < 6 else 1)
	var soup := _new()
	_expect(soup.set_arrays(soup_positions, soup_indices, soup_groups, PackedStringArray(["a", "b"])) and soup.check(5.0).boundary_edges == 36, "A cube of separate triangles should load with 36 open edges.")
	var welded: RefCounted = soup.welded()
	_expect(welded != null and welded.vertex_count() == 8 and welded.triangle_count() == 12 and welded.check(5.0).closed and soup.get_last_report().welded_vertices == 28 \
		and welded.get_face_names() == PackedStringArray(["a", "b"]) and welded.get_arrays().groups == soup_groups and absf(welded.volume() - 8e-6) < 1e-11,
		"welded() should join the 36 corners into 8 and keep the groups (%s; %d vertices)." % [soup.get_last_error(), welded.vertex_count() if welded != null else -1])
	checked.append("delete_triangles (others bit for bit, the loops it opens: new and merged; with close_holes on the new loop the old holes stay); welded (36 corners -> 8, closed, groups kept)")


# ---------------------------------------------------------------- hard cases: a warning or a refusal, never silence


func _check_hard_cases() -> void:
	# Remesh (adaptive) on a body of flat faces and sharp edges: the default Minimum Edge is raised
	# to what the body allows (the result stays within what the adaptive type works on); a
	# Minimum Edge that was given and is too small is refused with the value that would fit.
	var hollow := _mesh(FIXTURES.hollow_cube(true))
	var started := Time.get_ticks_msec()
	var adaptive: RefCounted = hollow.remesh({"mode": "adaptive"})
	var took := Time.get_ticks_msec() - started
	_expect(adaptive != null, "Remesh (adaptive) of the hollow cube should work (%s)." % hollow.get_last_error())
	var adaptive_count := 0
	if adaptive != null:
		var report: Dictionary = hollow.get_last_report()
		adaptive_count = adaptive.triangle_count()
		var diagonal: float = hollow.bbox().size.length()
		_expect(float(report.min_edge) > diagonal / 1000.0 and float(report.max_edge) > float(report.min_edge) and adaptive_count <= 150000,
			"The default Minimum Edge should be raised to fit the body (%.4f mm; %d triangles)." % [float(report.min_edge) / MM, adaptive_count])
		_expect(adaptive.check(5.0).closed and absf(adaptive.volume() - hollow.volume()) <= 0.005 * hollow.volume() and took < 21000,
			"The adaptively remeshed hollow cube should stay closed with its volume (%.9f against %.9f; %d ms)." % [adaptive.volume(), hollow.volume(), took])
	var refused: RefCounted = hollow.remesh({"mode": "adaptive", "min_edge": 0.00002, "max_edge": 0.001})
	_expect(refused == null and hollow.get_last_error().contains("With a Minimum Edge of 0.02 mm") and hollow.get_last_error().contains("Raise the Minimum Edge to"),
		"A Minimum Edge that could make millions of triangles should be refused with the value that fits ('%s')." % hollow.get_last_error())
	var ball := _mesh(FIXTURES.icosphere(0.05, 6))
	var too_big: RefCounted = ball.remesh({"mode": "adaptive", "min_edge": 0.0001, "max_edge": 0.0003})
	_expect(too_big == null and (ball.get_last_error().contains("Raise the Minimum Edge to") or ball.get_last_error().contains("works on up to 150,000 triangles")),
		"Remesh (adaptive) beyond its working size should be refused ('%s')." % ball.get_last_error())
	# Smooth on a mesh pmp's solve fails on: our own smoothing takes over, and says so.
	var smoothed: RefCounted = hollow.smooth({})
	var smooth_warning: String = hollow.get_last_warning()
	_expect(smoothed != null and smooth_warning.contains("the step-by-step smoothing was used instead") and hollow.get_last_report().method == "laplacian" and smoothed.triangle_count() == 36,
		"Smooth of the hollow cube should fall back to the step-by-step smoothing with a warning (%s; '%s')." % [hollow.get_last_error(), smooth_warning])
	if smoothed != null:
		_expect(absf(smoothed.volume() - hollow.volume()) <= 0.005 * hollow.volume(), "The fallback should keep the volume too (%.9f against %.9f)." % [smoothed.volume(), hollow.volume()])
	# Reduce where a few triangles cannot hold the shape: the move is said, with its size.
	var cube := _mesh(FIXTURES.two_cubes(Vector3(0.05, 0, 0)).first)
	var crushed: RefCounted = cube.reduce({"proportion": 50})
	var crush_warning: String = cube.get_last_warning()
	_expect(crushed != null and crush_warning.contains("Reduce moved the surface by up to") and crush_warning.contains("Reduce kept"),
		"Reduce of a 12-triangle cube should warn about the move and the count ('%s')." % crush_warning)
	# Reduce (fast) of a flat grid: the triangles without area and the crossings it leaves are counted.
	var grid := _mesh(FIXTURES.large_grid(40))
	var fast: RefCounted = grid.reduce({"method": "fast"})
	var fast_report: Dictionary = grid.get_last_report()
	var fast_warning: String = grid.get_last_warning()
	if fast != null:
		var c: Dictionary = fast.check(5.0)
		_expect((c.degenerate_triangles == 0 or fast_warning.contains("triangles without area")) and (c.self_intersections <= 0 or fast_warning.contains("crosses itself")),
			"Reduce (fast) of a flat grid should count what it leaves (%s triangles without area, %s crossings; '%s')." % [c.degenerate_triangles, c.self_intersections, fast_warning])
		_expect(absf(fast.volume() - grid.volume()) <= 1e-6 * grid.volume() and fast_report.checks.count == "ok", "Reduce (fast) of the flat grid should keep its volume and hit the count (%.12f)." % fast.volume())
	else:
		_expect(false, "Reduce (fast) of a flat grid should work (%s)." % grid.get_last_error())
	# Close Holes on a sheet's own outline: not a hole. The plate comes back as it is, with the
	# reason (fix round 2026-11-12: it used to lay a second surface on the plate and warn).
	var plate := _mesh(FIXTURES.open_plate())
	var capped: RefCounted = plate.close_holes({"fill": "minimal"})
	var cap_warning: String = plate.get_last_warning()
	var cap_report: Dictionary = plate.get_last_report()
	_expect(is_same(capped, plate) and cap_warning.contains("outline of an open sheet") and (cap_report.get("outline_loops", PackedInt32Array()) as PackedInt32Array).size() == 1,
		"Closing the outline of a flat plate should give the plate back and say that an outline is not a hole ('%s'; '%s')." % [cap_warning, plate.get_last_error()])
	checked.append("hard cases (adaptive remesh of a hollow cube: %d triangles with the default Minimum Edge raised to fit, a too small one refused with the value that fits; Smooth falls back with a warning where the library's solve fails; Reduce of a cube and of a flat grid say what they left; Close Holes leaves a plate's outline open and says why)" % adaptive_count)


# ---------------------------------------------------------------- refusals, 26


func _check_refusals() -> void:
	var ball := _mesh(FIXTURES.icosphere(0.05, 3))
	# Ranges: refused by field name, never clamped.
	var cases := [
		["remesh", {"density": 1.5}, "Density must be between"],
		["remesh", {"iterations": 0}, "Passes must be a whole number between 1 and 50"],
		["remesh", {"edge_length": 1.0}, "Edge Length must be 0"],
		["remesh", {"sharp_angle": 5.0}, "Sharp Edge Angle must be between"],
		["remesh", {"mode": "adaptive", "min_edge": 0.002, "max_edge": 0.001}, "Minimum Edge must be"],
		["remesh", {"mode": "wild"}, "Type must be one of: uniform, adaptive"],
		["reduce", {"proportion": 0.0}, "Keep must be between 1 % and 99 %"],
		["reduce", {"target": "face_count", "face_count": 3}, "Triangle Count must be a whole number between 4 and 1,279"],
		["reduce", {"target": "tolerance", "tolerance": 1.0}, "Maximum Deviation must be between"],
		["smooth", {"strength": 2.0}, "Smoothness must be between 0 and 1"],
		["smooth", {"iterations": 51}, "Passes must be a whole number between 1 and 50"],
		["close_holes", {"fill": "round"}, "Fill Type must be one of: minimal, smooth, flat"],
		["close_holes", {"max_edges": -1}, "Largest Hole must be a whole number between 0 and 100,000"],
		["stitch_and_remove", {"tolerance": 1.0}, "Stitch Tolerance must be between"],
		["stitch_and_remove", {"min_size": 60.0}, "Smallest Piece to Keep must be between 0 % and 50 %"],
		["generate_groups", {"angle": 0.5}, "Angle Threshold must be between"],
		["generate_groups", {"min_size": 0}, "Smallest Group must be a whole number between 1 and 100,000"],
		["reverse", {"mode": "sideways"}, "Mode must be one of: whole, selection, auto"],
		["smooth", {"triangles": PackedInt32Array([999999])}, "Triangle 999999 is not in the mesh"],
		["smooth", {"keep_volume": "yes"}, "Keep Volume must be on or off"],
	]
	for case: Array in cases:
		var result: RefCounted = ball.call(case[0], case[1])
		_expect(result == null and ball.get_last_error().contains(case[2]), "%s with %s should be refused naming the field ('%s'; got '%s')." % [case[0], case[1], case[2], ball.get_last_error()])
	# Meshes the libraries cannot hold: sent to Stitch and Remove, never a crash.
	var debris := _mesh(FIXTURES.cube_debris())
	for method: String in ["remesh", "smooth", "close_holes"]:
		var result: RefCounted = debris.call(method, {})
		_expect(result == null and debris.get_last_error().contains("Run Stitch and Remove first"), "%s on the debris cube should point to Stitch and Remove ('%s')." % [method, debris.get_last_error()])
	_expect(debris.reduce({"method": "adaptive"}) == null and debris.get_last_error().contains("Run Stitch and Remove first"), "Reduce (adaptive) on the debris cube should point to Stitch and Remove ('%s')." % debris.get_last_error())
	var empty := _new()
	for method: String in ["remesh", "reduce", "smooth", "close_holes", "stitch_and_remove", "generate_groups", "reverse"]:
		_expect(empty.call(method, {}) == null and empty.get_last_error() != "", "%s on an empty mesh should be refused." % method)
	_expect(empty.welded() == null and empty.delete_triangles(PackedInt32Array([0])) == null and empty.fit_primitive(PackedInt32Array([0])).is_empty(), "welded, delete_triangles and fit_primitive on an empty mesh should be refused.")
	# 26: bodies too big for the time limit are refused before any work.
	var grid := _mesh(FIXTURES.large_grid(290))
	var took := {}
	var texts := {}
	for case: Array in [["remesh", {"time_limit": 0.05}], ["remesh", {}], ["smooth", {}], ["reduce", {"method": "adaptive"}], ["remesh", {"density": 1.0}]]:
		var label: String = "%s %s" % [case[0], case[1]]
		var started := Time.get_ticks_usec()
		var result: RefCounted = grid.call(case[0], case[1])
		took[label] = (Time.get_ticks_usec() - started) / 1000.0
		texts[label] = grid.get_last_error()
		_expect(result == null and (grid.get_last_error().contains("would take about") or grid.get_last_error().contains("took longer than") or grid.get_last_error().contains("would make about")),
			"%s on 1,009,200 triangles should be refused with its estimate ('%s')." % [label, grid.get_last_error()])
		_expect(took[label] <= 1050.0, "%s on 1,009,200 triangles should come back within its limit + 1 s (%.0f ms)." % [label, took[label]])
	var first: String = "remesh %s" % [{"time_limit": 0.05}]
	_expect(texts[first].contains("limit 0.05 s") and texts[first].contains("Lower Passes or Density"), "The time-out should name the limit and the way out ('%s')." % texts[first])
	var slowest := 0.0
	for label: String in took:
		if label != first:
			slowest = maxf(slowest, took[label])
	_expect(slowest <= 200.0, "Once the mesh's edges are known, a refusal should take at most 0.2 s (%.0f ms)." % slowest)
	checked.append("refusals (%d ranges by field name; the debris cube sent to Stitch and Remove; empty meshes; on 1,009,200 triangles Remesh with time_limit 0.05 back in %.0f ms, Remesh, Smooth and Reduce (adaptive) refused before work in at most %.0f ms)" \
		% [cases.size(), took[first], slowest])


func _check_timing() -> void:
	var calibration := func() -> void:
		var sphere: RefCounted = kernel.make_sphere(0.02, Vector3.ZERO, "cal")
		sphere.tessellate(0.0002, 0.3)
	var grid := FIXTURES.large_grid(290)
	var ball := FIXTURES.with_noise(FIXTURES.icosphere(0.05, 6), 0.1)
	var results := {}
	var counts := {}
	var fast := func() -> void:
		var m := _new()
		m.set_arrays(grid.positions, grid.indices)
		var r: RefCounted = m.reduce({"method": "fast", "proportion": 50})
		counts["reduce_fast_1m"] = r.triangle_count() if r != null else -1
	results["reduce_fast_1m"] = TIMING.compare(fast, calibration, 3, "set_arrays + reduce fast to 50 %, 1,009,200 triangles")
	var adaptive := func() -> void:
		var m := _new()
		m.set_arrays(ball.positions, ball.indices)
		var r: RefCounted = m.reduce({"method": "adaptive", "proportion": 50})
		counts["reduce_adaptive_82k"] = r.triangle_count() if r != null else -1
	results["reduce_adaptive_82k"] = TIMING.compare(adaptive, calibration, 3, "set_arrays + reduce adaptive to 50 %, 81,920 triangles")
	var remesh := func() -> void:
		var m := _new()
		m.set_arrays(ball.positions, ball.indices)
		var r: RefCounted = m.remesh({"edge_length": ball.mean_edge, "iterations": 10})
		counts["remesh_82k_10"] = r.triangle_count() if r != null else -1
	results["remesh_82k_10"] = TIMING.compare(remesh, calibration, 3, "set_arrays + remesh uniform, 10 passes, 81,920 triangles")
	_expect(absi(counts.reduce_fast_1m - 504600) <= 10092, "Reduce (fast) of the 1M grid should land within 2 %% of 504,600 (%d)." % counts.reduce_fast_1m)
	_expect(absi(counts.reduce_adaptive_82k - 40960) <= 819, "Reduce (adaptive) of the 82k ball should land within 2 %% of 40,960 (%d)." % counts.reduce_adaptive_82k)
	_expect(counts.remesh_82k_10 > 60000 and counts.remesh_82k_10 < 110000, "Remesh of the 82k ball at its own edge should keep about its size (%d)." % counts.remesh_82k_10)
	var over := []
	for key: String in results:
		var t: Dictionary = results[key]
		print("mesh pmp timing %s: %.1f ms (calibration %.3f ms), ratio %.2f, limit %.2f" % [key, t.op, t.calibration, t.ratio, LIMITS[key]])
		if t.ratio > LIMITS[key]:
			over.append("%s ratio %.2f > %.2f" % [key, t.ratio, LIMITS[key]])
	_expect(over.is_empty(), "Timing ratios over their limits: %s." % [over])
	checked.append("timing ratios (reduce fast 1,009,200 -> 50 %% %.0f ms; reduce adaptive 81,920 -> 50 %% %.0f ms; remesh 81,920, 10 passes %.0f ms)" \
		% [results.reduce_fast_1m.op, results.reduce_adaptive_82k.op, results.remesh_82k_10.op])


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error(message)
		print("FAIL: ", message)
