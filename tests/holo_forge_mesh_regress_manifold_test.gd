extends SceneTree
## Holo Forge Mesh workspace, regressions of the Manifold and voxel ops (the fix round after the
## Phase 7 verifiers; team N3). Every case is the verifier's smallest input.
##
## B1  Accurate Shell on box-like bodies away from the origin crashed inside the mesh library's
##     level set. Each crash case runs in a child process of its own (this file, with
##     HOLO_FORGE_MESH_CHILD set), so a crash fails the case and not the test.
## B2  Separate on a body of thousands of closed pieces is refused within its time limit.
## B3  Accurate Shell on a body that crosses itself is refused by name; a shell volume that is
##     not positive never passes.
## B4  Texture Extrude says when its result crosses itself, also on large results.
## B5  Combine names every input that crosses itself, at any size.
## B6  Rebuild says when parts thinner than its cell were lost, with how far and how much.
## P1  Plane Cut between the pieces of one body gives the pieces on each side.
## P2  Plane Cut that leaves a thin sliver works (its checks are relative to the body).
## P3  Plane Cut on a void's wall gives the same part on every axis, with no false warning.
## P4  Wrap measures what it left out by surface area, and lists the parts that are out.
## P8  Rebuild on pieces smaller than its cell says that, not something about overlaps.
## P9  One of a thing is said in the singular.
## Second round (re-verifier R1):
## N4  Plane Cut through vertices of the body, or within 1e-7 D of them, gives closed parts.
## N8  A body too far from the origin for its size is refused with that reason, not as an
##     "internal error"; so is a result that would pass the 1,000 km limit.
## N10 Separate leaves the library's split out when it would not fit the time, and goes on.
## Combine and Plane Cut say what rounding costs far from the origin; lengths have no exponents.
## And: a join of bodies that only touch says so; an estimate does not depend on what was
## cached; accurate Shell Both says the face groups became one; Wrap says when it filled inner
## voids; a move that makes the mesh's points fall together is refused.
## Third round (re-verifier R3):
## B2  Plane Cut on the face a small cube (a piece of its own) stands on keeps the small cube
##     whole, also turned, with no flake; Split Body is not refused.
## B3  Plane Cut on the inner wall of a U channel keeps no wall without thickness (fin).
## Plane Cut says a sentence once (both parts' counts in one) and volumes in mm3.
## And: op_defaults gives Remesh, Smooth, Reduce and Close Holes' far refusal before the op runs.
##
## godot --headless --path . --script res://tests/holo_forge_mesh_regress_manifold_test.gd

const FIXTURES := preload("res://tests/holo_forge_mesh_fixtures.gd")

const MM := 0.001
const CHILD := "HOLO_FORGE_MESH_CHILD"

var failures: Array[String] = []
var checked: Array[String] = []


func _init() -> void:
	call_deferred("run")


func run() -> void:
	if not ClassDB.class_exists("CadMesh") or not ClassDB.class_exists("CadKernel"):
		print("NOTE: CadMesh is not registered (the holo_forge native DLL is missing): native mesh checks skipped.")
		print("PASS holo_forge_mesh_regress_manifold: skipped, the native library is not loaded.")
		quit(0)
		return
	var child := OS.get_environment(CHILD)
	if child != "":
		_run_child(child)
		quit(0)
		return
	_check_far_from_origin()
	_check_separate_many()
	_check_crossing_shell()
	_check_displace_crossing()
	_check_combine_crossing()
	_check_rebuild_thin()
	_check_plane_cut_pieces()
	_check_plane_cut_sliver()
	_check_plane_cut_void_wall()
	_check_wrap_left_out()
	_check_singular()
	_check_notes()
	_check_plane_cut_through_vertices()
	_check_far_from_origin_reasons()
	_check_separate_preview()
	_check_plain_numbers()
	_check_plane_cut_on_shared_face()
	_check_plane_cut_inner_wall()
	_check_plane_cut_sentences()
	_check_far_defaults()
	print(("PASS holo_forge_mesh_regress_manifold: " + "; ".join(checked) + ".") if failures.is_empty() else "FAIL holo_forge_mesh_regress_manifold")
	quit(0 if failures.is_empty() else 1)


func _new() -> RefCounted:
	return ClassDB.instantiate("CadMesh")


func _mesh(fixture: Dictionary) -> RefCounted:
	var mesh := _new()
	_expect(mesh.set_arrays(fixture.positions, fixture.indices, fixture.groups, fixture.names, "godot"), "A fixture should load (%s)." % mesh.get_last_error())
	return mesh


## A box of `size` around `center` (12 triangles, 8 vertices, one group).
func _box(size: Vector3, center := Vector3.ZERO, group := "g0") -> RefCounted:
	var cube: Dictionary = FIXTURES.two_cubes(Vector3.ZERO).first
	var positions: PackedVector3Array = cube.positions.duplicate()
	for i in positions.size():
		positions[i] = positions[i] / (20 * MM) * size + center
	var mesh := _new()
	mesh.set_arrays(positions, cube.indices, PackedInt32Array(), PackedStringArray([group]), "godot")
	return mesh


func _closed(mesh: RefCounted) -> bool:
	if mesh == null or mesh.is_null():
		return false
	var c: Dictionary = mesh.check(10.0)
	return c.get("closed", false) and c.get("manifold", false)


func _near(value: float, wanted: float, relative: float) -> bool:
	return absf(value - wanted) <= relative * absf(wanted)


## `count` small tetrahedra (0.5 mm) on a 1 mm grid, 100 a row: one mesh of closed pieces.
func _tetrahedra(count: int) -> RefCounted:
	var positions := PackedVector3Array()
	var ccw := PackedInt32Array()
	positions.resize(count * 4)
	ccw.resize(count * 12)
	var pattern := [0, 2, 1, 0, 1, 3, 0, 3, 2, 1, 2, 3]
	for k in count:
		var o := Vector3((k % 100) * 0.001, (int(k / 100.0) % 100) * 0.001, int(k / 10000.0) * 0.001)
		positions[k * 4] = o
		positions[k * 4 + 1] = o + Vector3(0.0005, 0, 0)
		positions[k * 4 + 2] = o + Vector3(0, 0.0005, 0)
		positions[k * 4 + 3] = o + Vector3(0, 0, 0.0005)
		for j in 12:
			ccw[k * 12 + j] = k * 4 + pattern[j]
	var mesh := _new()
	mesh.set_arrays(positions, ccw, PackedInt32Array(), PackedStringArray(), "ccw")
	return mesh


func _checker() -> PackedByteArray:
	var image := PackedByteArray()
	image.resize(64 * 64)
	for y in 64:
		for x in 64:
			image[y * 64 + x] = 255 if (x / 8 + y / 8) % 2 == 0 else 0
	return image


# ---------------------------------------------------------------- B1: one case per process


## A child's case: "<op>|<body>|<x>|<y>|<z>" (meters). Prints "CHILD OK <volume mm3> <error or warning>".
func _run_child(what: String) -> void:
	var parts := what.split("|")
	var at := Vector3(float(parts[2]), float(parts[3]), float(parts[4]))
	var body: RefCounted
	match parts[1]:
		"grid":
			body = _mesh(FIXTURES.large_grid(6, 0.02))
		"hollow":
			body = _mesh(FIXTURES.hollow_cube(false))
		"bracket":
			body = FIXTURES.l_bracket().mesh
		"ball":
			body = _mesh(FIXTURES.icosphere(0.01, 3))
		_:
			body = _box(Vector3.ONE * 20 * MM)
	body = body.transformed(Transform3D(Basis.IDENTITY, at))
	var out: RefCounted
	match parts[0]:
		"wrap":
			out = body.wrap({})
		"rebuild":
			out = body.rebuild({})
		"rebuild_exact":
			out = body.rebuild({"method": "exact_surface"})
		"shell_inside":
			out = body.shell({"direction": "inside"})
		"shell_outside":
			out = body.shell({"direction": "outside"})
		"shell_both":
			out = body.shell({"direction": "both"})
		"shell_fast":
			out = body.shell({"method": "fast"})
		"displace":
			out = body.displace({"image": _checker(), "width": 64, "height": 64, "tile": 4 * MM, "detail": 0.5 * MM})
	var said: String = body.get_last_error() if out == null else body.get_last_warning().replace("\n", " / ")
	print("CHILD OK %s %s | %s" % ["null" if out == null else "%.3f" % (out.volume() * 1e9), "closed" if out != null and _closed(out) else "-", said])


## Runs one case in a process of its own: {"ok": it came back, "volume": mm3 (NAN when null), "said"}.
func _child(what: String) -> Dictionary:
	OS.set_environment(CHILD, what)
	var output := []
	var code := OS.execute(OS.get_executable_path(), PackedStringArray(["--headless", "--path", ProjectSettings.globalize_path("res://"), "--script", "res://tests/holo_forge_mesh_regress_manifold_test.gd"]), output, true)
	OS.set_environment(CHILD, "")
	var text := "\n".join(output)
	var at := text.find("CHILD OK ")
	if code != 0 or at < 0:
		return {"ok": false, "volume": NAN, "said": "exit code %d%s" % [code, ", crashed with signal 11" if text.contains("signal 11") else ""]}
	var line := text.substr(at + 9).split("\n")[0]
	var first := line.split(" ")[0]
	return {"ok": true, "volume": NAN if first == "null" else float(first), "said": line}


func _check_far_from_origin() -> void:
	# The verifier's first case, and one per body and direction that crashed in its scan. The wall
	# of a 20 mm cube at the default thickness (D / 50) is 0.693 mm.
	var t := 20.0 * sqrt(3.0) / 50.0
	var inside := pow(20.0, 3) - pow(20.0 - 2.0 * t, 3)
	var outside := pow(20.0 + 2.0 * t, 3) - pow(20.0, 3)  # (less its rounded edges)
	var cases := [
		["shell_inside|cube|0.5|0.5|0.5", inside, 0.03],
		["shell_inside|cube|10|10|10", inside, 0.03],
		["shell_outside|cube|1.7|1.19|0.51", outside, 0.08],
		["shell_both|grid|0.3|0.21|0.09", 0.0, 0.0],
		["shell_inside|hollow|13|9.1|3.9", 0.0, 0.0],
		["shell_both|cube|211|147.7|63.3", 0.0, 0.0],
	]
	var crashed := 0
	for c: Array in cases:
		var r := _child(c[0])
		if not r.ok:
			crashed += 1
		_expect(r.ok, "Accurate Shell far from the origin must come back (%s: %s)." % [c[0], r.said])
		if r.ok and c[1] > 0.0:
			_expect(not is_nan(r.volume) and _near(r.volume, c[1], c[2]), "%s should give a wall of about %.0f mm3 (%s)." % [c[0], c[1], r.said])
		elif r.ok:
			# Far out, float32 leaves too few digits for some of these: a result or a refusal, never a crash.
			_expect(is_nan(r.volume) or r.volume > 0.0, "%s should give a shell or a refusal (%s)." % [c[0], r.said])
	checked.append("accurate Shell away from the origin (%d cases, one process each, %d crashed)" % [cases.size(), crashed])


# ---------------------------------------------------------------- B2


func _check_separate_many() -> void:
	var rows: Array[String] = []
	# (HOLO_FORGE_MESH_REGRESS_SHORT=1 leaves the two largest out: before the fix they took minutes.)
	for count: int in ([2000, 5000] if OS.get_environment("HOLO_FORGE_MESH_REGRESS_SHORT") != "" else [2000, 5000, 10000, 20000]):
		var body := _tetrahedra(count)
		for limit: float in [0.5, 2.0, 20.0]:
			var started := Time.get_ticks_usec()
			var pieces: Array = body.separate({"time_limit": limit, "name": "Debris"})
			var seconds := (Time.get_ticks_usec() - started) / 1e6
			rows.append("%d/%s s: %.2f s" % [count, limit, seconds])
			_expect(pieces.is_empty() and seconds <= limit + 1.0, "Separate on %d tetrahedra must stop within its %s s (+1 s): took %.2f s ('%s')." % [count, limit, seconds, body.get_last_error()])
			_expect(seconds <= 1.5, "Counting %d pieces should take well under a second (%.2f s)." % [count, seconds])
			_expect(body.get_last_error() == "Debris has %s separate pieces; Separate makes up to 1,000 bodies. Run Stitch and Remove first to drop the small ones." % _commas(count),
				"More than 1,000 pieces should be refused by their count ('%s')." % body.get_last_error())
	# 1,000 pieces are still made, and hollow pieces keep their voids.
	var thousand := _tetrahedra(1000)
	var started := Time.get_ticks_usec()
	var made: Array = thousand.separate({})
	_expect(made.size() == 1000 and made[999].triangle_count() == 4, "1,000 tetrahedra should separate into 1,000 bodies (%d; '%s')." % [made.size(), thousand.get_last_error()])
	rows.append("1000 pieces made in %.2f s" % ((Time.get_ticks_usec() - started) / 1e6))
	var hollow := _mesh(FIXTURES.hollow_cube(true))
	var two: Array = hollow.separate({})
	_expect(two.size() == 2 and two[0].triangle_count() == 24, "A hollow cube with an island is still two pieces.")
	checked.append("separate on many pieces (%s)" % ", ".join(rows))


func _commas(value: int) -> String:
	var digits := str(value)
	var out := ""
	for i in digits.length():
		out += digits[i]
		if i + 1 < digits.length() and (digits.length() - 1 - i) % 3 == 0:
			out += ","
	return out


# ---------------------------------------------------------------- B3


func _check_crossing_shell() -> void:
	var crossing := _mesh(FIXTURES.two_cubes(Vector3(10 * MM, 0, 0)))
	_expect(crossing.check(5.0).self_intersections > 0, "The two cubes should cross.")
	for direction: String in ["outside", "inside"]:
		var out: RefCounted = crossing.shell({"thickness": 1 * MM, "direction": direction, "method": "accurate", "name": "Pair"})
		_expect(out == null and crossing.get_last_error().begins_with("Pair crosses itself in ") and crossing.get_last_error().ends_with("Rebuild it first."),
			"The accurate shell (%s) of two crossing cubes must be refused by name (%s; '%s')." % [direction, "null" if out == null else "%s mm3" % (out.volume() * 1e9), crossing.get_last_error()])
	# The same refusal when the crossing count does not rise (the pair of the verifier's probe 13).
	var a := _mesh(FIXTURES.large_grid(20, 0.02))
	var pair: RefCounted = a.merge_with([a.transformed(Transform3D(Basis.from_euler(Vector3(0.3, 0.2, 0.1)), Vector3(0.011, 0.004, 0.003)))])
	var shell: RefCounted = pair.shell({"thickness": 1 * MM, "direction": "outside", "method": "accurate", "name": "Pair"})
	_expect(shell == null and pair.get_last_error().contains("crosses itself"), "A crossing pair must be refused whatever its crossing count does ('%s')." % pair.get_last_error())
	# Both needs no inside: it still works on a crossing body (the band around its surface).
	var band: RefCounted = crossing.shell({"thickness": 1 * MM, "direction": "both", "method": "accurate"})
	_expect(band != null and band.volume() > 0.0, "Both on a crossing body gives the band around its surface ('%s')." % crossing.get_last_error())
	checked.append("accurate Shell on a body that crosses itself (refused by name, inside and outside; Both still works)")


# ---------------------------------------------------------------- B4


func _check_displace_crossing() -> void:
	var said := []
	for n: int in [20, 110]:
		var grid := _mesh(FIXTURES.large_grid(n, 0.02))
		var out: RefCounted = grid.displace({"image": _checker(), "width": 64, "height": 64, "depth": -3.4 * MM, "tile": 2 * MM, "detail": 0.25 * MM, "refine": false, "name": "Cube"})
		var warning: String = grid.get_last_warning()
		var count := int(grid.get_last_report().get("self_intersections", -9))
		_expect(out != null and count != 0, "The deep texture on grid %d should cross itself (%s)." % [n, grid.get_last_error()])
		_expect((count > 0 and warning.contains("The extrusion crosses itself in %s places" % _commas(count))) or (count < 0 and warning.contains("was not tested")),
			"Texture Extrude must say its result crosses itself whenever it knows (grid %d: %d crossings, '%s')." % [n, count, warning])
		_expect(String(grid.get_last_report().checks.get("self_intersections", "")).begins_with("warn"), "The report's checks should hold the warning too (%s)." % [grid.get_last_report().get("checks", {})])
		said.append("%d triangles: %s crossings said" % [grid.triangle_count(), _commas(count)])
	checked.append("displace crossing itself (%s)" % ", ".join(said))


# ---------------------------------------------------------------- B5


func _check_combine_crossing() -> void:
	var said := []
	for n: int in [20, 220]:
		var a := _mesh(FIXTURES.large_grid(n, 0.02))
		var pair: RefCounted = a.merge_with([a.transformed(Transform3D(Basis.from_euler(Vector3(0.3, 0.2, 0.1)), Vector3(0.011, 0.004, 0.003)))])
		var ball := _mesh(FIXTURES.icosphere(0.01, 3, Vector3(0.03, 0.01, 0.01)))
		for op: String in (["join", "cut", "intersect"] if n == 20 else ["join"]):
			var out: RefCounted = pair.boolean([ball], {"operation": op, "name": "Pair"})
			var warning: String = pair.get_last_warning()
			_expect(out != null, "Combine %s should still give a result (%s)." % [op, pair.get_last_error()])
			_expect(warning.contains("Pair crosses itself") and warning.contains("Rebuild it first.") or warning.contains("Pair could not be tested"),
				"Combine %s on a target of %d triangles that crosses itself must say so by name ('%s')." % [op, pair.triangle_count(), warning])
			_expect(not warning.contains("made 1 places") and not warning.contains("where the mesh crosses itself"),
				"The body's own crossings must not be said as a few new ones ('%s')." % warning)
			if op == "join":
				said.append("%d triangles: '%s'" % [pair.triangle_count(), warning.get_slice("\n", warning.get_slice_count("\n") - 1).left(60)])
		if n == 20:
			# A tool that crosses itself is named as well.
			var out: RefCounted = ball.boolean([pair], {"operation": "join", "name": "Ball", "tool_names": ["Pair"]})
			_expect(out != null and ball.get_last_warning().contains("Pair crosses itself"), "A tool that crosses itself must be named ('%s')." % ball.get_last_warning())
			_expect(int(ball.get_last_report().get("input_self_intersections", [0, 0])[1]) > 0, "The report should hold each input's crossing count (%s)." % [ball.get_last_report().get("input_self_intersections")])
	# Clean inputs: no such sentence.
	var two := FIXTURES.two_cubes(Vector3(10 * MM, 0, 0))
	var clean := _mesh(two.first)
	_expect(clean.boolean([_mesh(two.second)], {}) != null and clean.get_last_warning() == "", "Clean cubes should join with no warning ('%s')." % clean.get_last_warning())
	checked.append("combine on inputs that cross themselves (%s; a tool named too)" % "; ".join(said))


# ---------------------------------------------------------------- B6, P8


func _check_rebuild_thin() -> void:
	var cube := _box(Vector3.ONE * 100 * MM)
	var pins := []
	for i in 5:
		pins.append(_box(Vector3(0.3, 20, 0.3) * MM, Vector3(-40 + i * 20, 59.9, 0) * MM, "pin%d" % i))
	var pinned: RefCounted = cube.boolean(pins, {"operation": "join"})
	_expect(pinned != null, "The pinned cube should build (%s)." % cube.get_last_error())
	var far := 0.0
	if pinned != null:
		for method: String in ["union", "exact_surface"]:
			var out: RefCounted = pinned.rebuild({"method": method, "name": "Pinned"})
			var warning: String = pinned.get_last_warning()
			var report: Dictionary = pinned.get_last_report()
			_expect(out != null and warning.contains("thinner than") and warning.contains("Lower Detail") and warning.contains("Pinned"),
				"Rebuild must say that parts thinner than its cell were lost (%s: '%s')." % [method, warning])
			_expect(report.get("left_out", 0.0) > 0.0 and report.get("deviation", {}).get("max", 0.0) > 15 * MM and String(report.checks.get("covered", "")).begins_with("warn"),
				"Rebuild's report should hold what was lost and how far it is (%s: left_out %s, deviation %s)." % [method, report.get("left_out"), report.get("deviation")])
			far = report.get("deviation", {}).get("max", 0.0)
	# A small cube beside a big one vanishes too.
	var beside: RefCounted = _box(Vector3.ONE * 20 * MM).merge_with([_box(Vector3.ONE * 0.1 * MM, Vector3(30, 0, 0) * MM, "speck")])
	var out2: RefCounted = beside.rebuild({})
	_expect(out2 != null and beside.get_last_warning().contains("thinner than") and beside.get_last_report().get("left_out_parts", []).size() == 1,
		"A speck that vanishes must be said, and listed ('%s'; %s)." % [beside.get_last_warning(), beside.get_last_report().get("left_out_parts")])
	# P8: pieces all smaller than the cell. Nothing true can be made of them: refused, saying why.
	var debris := _tetrahedra(2000)
	var out3: RefCounted = debris.rebuild({"name": "Debris"})
	var said: String = debris.get_last_error() if out3 == null else debris.get_last_warning()
	_expect(out3 == null and said.contains("thinner than") and said.contains("Lower Detail") and not said.contains("overlapped") and not said.contains("enclose nothing"),
		"Rebuild on pieces smaller than its cell must be refused for that reason ('%s')." % said)
	# A clean body: no such sentence.
	var ball := _mesh(FIXTURES.icosphere(0.02, 3))
	_expect(ball.rebuild({}) != null and not ball.get_last_warning().contains("thinner") and ball.get_last_report().get("left_out", 1.0) == 0.0, "A ball rebuilds with nothing lost ('%s')." % ball.get_last_warning())
	checked.append("rebuild losing thin parts (pins 0.3 mm on a 100 mm cube: said, %.1f mm away; a speck listed; debris smaller than the cell refused)" % (far * 1000.0))


# ---------------------------------------------------------------- P1


func _check_plane_cut_pieces() -> void:
	var apart := _mesh(FIXTURES.two_cubes(Vector3(30 * MM, 0, 0)))
	var plane := {"origin": Vector3(15 * MM, 0, 0), "normal": Vector3(1, 0, 0), "name": "Body"}
	for fill: String in ["uniform", "minimal", "none"]:
		var both: Array = apart.plane_cut(plane.merged({"type": "split_body", "fill": fill}))
		_expect(both.size() == 2 and both[0] != null and both[1] != null and both[0].triangle_count() == 12 and both[1].triangle_count() == 12 and _closed(both[0]) and _closed(both[1]),
			"A plane between two cubes should give one cube on each side (fill %s: '%s')." % [fill, apart.get_last_error()])
		if both.size() == 2 and both[0] != null:
			_expect(both[0].bbox().position.x > 0.015 and both[0].get_face_names() == PackedStringArray(["g1"]) and both[1].get_face_names() == PackedStringArray(["g0"]),
				"The first part is the cube on the normal's side, with its own group and no cut group.")
			_expect(apart.get_last_warning().contains("between") and apart.get_last_warning().contains("nothing was cut"), "The warning should say nothing was cut ('%s')." % apart.get_last_warning())
		var kept: Array = apart.plane_cut(plane.merged({"type": "trim", "fill": fill, "flip": true}))
		_expect(kept.size() == 2 and kept[0] == null and kept[1] != null and kept[1].triangle_count() == 12, "Trim keeps the cube on its side (fill %s: '%s')." % [fill, apart.get_last_error()])
	# On a face two pieces share.
	var touching := _mesh(FIXTURES.two_cubes(Vector3(20 * MM, 0, 0)))
	var parts: Array = touching.plane_cut({"origin": Vector3(10 * MM, 0, 0), "normal": Vector3(1, 0, 0), "type": "split_body"})
	_expect(parts.size() == 2 and parts[0] != null and parts[1] != null and _near(parts[0].volume() * 1e9, 8000.0, 1e-6) and _near(parts[1].volume() * 1e9, 8000.0, 1e-6) and _closed(parts[0]) and _closed(parts[1]),
		"A plane on the face two cubes share should give the two cubes ('%s')." % touching.get_last_error())
	checked.append("plane_cut between pieces (two cubes apart: one each side, all fills, trim and split; on a shared face)")


# ---------------------------------------------------------------- P2


func _check_plane_cut_sliver() -> void:
	var ball := _mesh(FIXTURES.icosphere(0.02, 4))
	var d: float = ball.bbox().size.length()
	var made := 0
	for depth: float in [1e-5, 1e-4, 1e-3]:
		for type: String in ["trim", "split_body"]:
			var parts: Array = ball.plane_cut({"origin": Vector3(0, 0.02 - depth * d, 0), "normal": Vector3(0, 1, 0), "type": type, "fill": "minimal", "name": "Ball"})
			var error: String = ball.get_last_error()
			_expect(not error.contains("on the way back") and not error.contains("report it"), "A thin sliver must not be called an internal error (%s at %s D: '%s')." % [type, depth, error])
			_expect(not parts.is_empty() or error == "The plane does not cut Ball.", "A sliver cut gives its parts, or the true refusal ('%s')." % error)
			if not parts.is_empty():
				made += 1
				_expect(parts[0] != null and _closed(parts[0]) and parts[0].volume() > 0.0 and parts[0].volume() < 1e-3 * ball.volume(), "The sliver should be a small closed cap (%s m3)." % parts[0].volume())
	# The verifier's case: the top 1e-5 D of a torus, a ring of 1.9e-12 m3.
	var ring := _torus(0.03, 0.01, 48, 24)
	var ring_d: float = ring.bbox().size.length()
	for type: String in ["trim", "split_body"]:
		for fill: String in ["uniform", "minimal"]:
			var parts: Array = ring.plane_cut({"origin": Vector3(0, 0.01 - 1e-5 * ring_d, 0), "normal": Vector3(0, 1, 0), "type": type, "fill": fill, "name": "Torus"})
			_expect(not parts.is_empty() and parts[0] != null and _closed(parts[0]) and _near(parts[0].volume(), 1.8857e-12, 0.01),
				"The top 1e-5 D of the torus should come back as a closed ring of 1.886e-12 m3 (%s, %s: %s; '%s')." % [type, fill, ("%.4f e-12 m3" % (parts[0].volume() * 1e12)) if not parts.is_empty() and parts[0] != null else "none", ring.get_last_error()])
	# Combine has the same check: a thin leftover is no internal error either.
	var a := _mesh(FIXTURES.icosphere(0.02, 2))
	var b: RefCounted = a.transformed(Transform3D(Basis.IDENTITY, Vector3(1e-6, 0, 0)))
	var cut: RefCounted = a.boolean([b], {"operation": "cut"})
	_expect(not a.get_last_error().contains("on the way back"), "A thin leftover of a cut must not be called an internal error ('%s')." % a.get_last_error())
	checked.append("thin slivers (plane cut 1e-5 to 1e-3 D below the top: %d of 6 made, none an internal error; a thin leftover of Combine %s)" % [made, "made" if cut != null else "refused: " + a.get_last_error().left(40)])


# ---------------------------------------------------------------- P3


func _check_plane_cut_void_wall() -> void:
	var hollow := _mesh(FIXTURES.hollow_cube(false))
	var areas := []
	for normal: Vector3 in [Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1)]:
		var plane := {"origin": Vector3(5, 5, 5) * MM, "normal": normal, "name": "Hollow"}
		for fill: String in ["uniform", "minimal"]:
			var lower: Array = hollow.plane_cut(plane.merged({"type": "trim", "fill": fill, "flip": true}))
			_expect(lower.size() == 2 and lower[1] != null and hollow.get_last_warning() == "", "A cut on the void's wall should work with no warning (%s, %s: '%s' '%s')." % [normal, fill, hollow.get_last_warning(), hollow.get_last_error()])
			if lower.size() == 2 and lower[1] != null:
				var c: Dictionary = lower[1].check(5.0)
				_expect(c.closed and c.manifold and c.components == 1 and c.inverted_components == 0 and c.self_intersections == 0 and _near(lower[1].volume() * 1e9, 5000.0, 1e-6),
					"The lower part should be one closed cup of 5,000 mm3 on every axis (%s, %s: %s, %s mm3)." % [normal, fill, c, lower[1].volume() * 1e9])
				if fill == "minimal":
					areas.append(lower[1].area())
		var upper: Array = hollow.plane_cut(plane.merged({"type": "trim", "fill": "minimal"}))
		_expect(upper.size() == 2 and upper[0] != null and upper[0].check(5.0).components == 1 and _near(upper[0].volume() * 1e9, 2000.0, 1e-6), "The upper part is a plain slab of 2,000 mm3 (%s)." % normal)
		var open_cut: Array = hollow.plane_cut(plane.merged({"type": "split_body", "fill": "none"}))
		_expect(open_cut.size() == 2 and open_cut[1] != null and open_cut[1].check(5.0).boundary_edges == 8 and hollow.get_last_warning() == "",
			"Fill None leaves the cup's two rims open on every axis (%s: %s edges, '%s')." % [normal, open_cut[1].check(5.0).boundary_edges if open_cut.size() == 2 and open_cut[1] != null else -1, hollow.get_last_warning()])
	_expect(areas.size() == 3 and _near(areas[1], areas[0], 1e-6) and _near(areas[2], areas[0], 1e-6) and _near(areas[0] * 1e6, 2400.0, 1e-5), "The cup should have the same area (2,400 mm2) on every axis (%s)." % [areas])
	checked.append("plane_cut on a void's wall (x, y, z: one closed cup of 5,000 mm3 and 2,400 mm2, no warning; Fill None 8 open edges)")


# ---------------------------------------------------------------- P4


func _check_wrap_left_out() -> void:
	# A cube and two specks: by vertices two thirds of the body, by area 0.005 %.
	var cube := _box(Vector3.ONE * 20 * MM)
	var specks := []
	for k in 2:
		specks.append(_box(Vector3.ONE * 0.1 * MM, Vector3(15 + k * 2, 0, 0) * MM, "s%d" % k))
	var dusty: RefCounted = cube.merge_with(specks)
	var out: RefCounted = dusty.wrap({"name": "Cube"})
	_expect(out != null and _near(out.volume() * 1e9, 8000.0, 0.01), "A cube with two specks should wrap as the cube (%s)." % dusty.get_last_error())
	var report: Dictionary = dusty.get_last_report()
	_expect(report.get("left_out", 1.0) < 0.001 and report.get("left_out_parts", []).size() == 2, "What is left out is measured by area, and the parts are listed (%s; %s)." % [report.get("left_out"), report.get("left_out_parts")])
	_expect(dusty.get_last_warning().contains("2 of its 3 separate parts are not in the wrap") and dusty.get_last_warning().contains("of Cube's surface"), "The warning should count the parts left out ('%s')." % dusty.get_last_warning())
	if report.get("left_out_parts", []).size() == 2:
		_expect(report.left_out_parts[0].first_triangle == 12 and report.left_out_parts[1].first_triangle == 24 and report.left_out_parts[0].triangles == 12, "Each part left out is given by its first triangle (%s)." % [report.left_out_parts])
	# A ball and a thin plate that is a quarter of the area: said as about that share.
	var ball := _mesh(FIXTURES.icosphere(0.02, 3))
	var plated: RefCounted = ball.merge_with([_box(Vector3(30, 0.2, 30) * MM, Vector3(0, 40, 0) * MM, "plate")])
	var share: float = 2.0 * 900e-6 / plated.area()
	var wrapped: RefCounted = plated.wrap({"name": "Pair"})
	_expect(wrapped != null and absf(plated.get_last_report().get("left_out", 0.0) - share) < 0.05, "A thin plate of %.0f %% of the area should be said as about that (%s; '%s')." % [share * 100.0, plated.get_last_report().get("left_out"), plated.get_last_warning()])
	checked.append("wrap left out by area (cube and two specks: %.4f %%, 2 parts listed; ball and thin plate: %.0f %% of %.0f %%)" % [report.get("left_out", 1.0) * 100.0, plated.get_last_report().get("left_out", 0.0) * 100.0, share * 100.0])


# ---------------------------------------------------------------- P9


func _check_singular() -> void:
	var said := []
	# One inside-out part.
	var fixture := FIXTURES.hollow_cube(false)
	var indices: PackedInt32Array = fixture.indices.duplicate()
	for t: int in fixture.void_triangles:
		var keep := indices[t * 3 + 1]
		indices[t * 3 + 1] = indices[t * 3 + 2]
		indices[t * 3 + 2] = keep
	var turned := _mesh({"positions": fixture.positions, "indices": indices, "groups": fixture.groups, "names": fixture.names})
	_expect(turned.boolean([_box(Vector3.ONE * 5 * MM, Vector3(0.05, 0, 0))], {"name": "Hollow"}) == null and turned.get_last_error() == "Hollow has 1 part that is inside-out. Reverse Normal can fix it.",
		"One inside-out part is said in the singular ('%s')." % turned.get_last_error())
	said.append(turned.get_last_error())
	# One cut edge left open: a single triangle cut in two.
	var triangle := _new()
	triangle.set_arrays(PackedVector3Array([Vector3(0, 0, 0), Vector3(0.01, 0, 0), Vector3(0, 0, 0.01)]), PackedInt32Array([0, 1, 2]))
	var parts: Array = triangle.plane_cut({"origin": Vector3(0.004, 0, 0), "normal": Vector3(1, 0, 0), "type": "trim"})
	_expect(not parts.is_empty() and triangle.get_last_warning() == "1 cut edge stays open (the body was open there).", "One open cut edge is said in the singular ('%s')." % triangle.get_last_warning())
	said.append(triangle.get_last_warning())
	# One open edge... a cube with one triangle less has three; the sentence for one is shared code.
	var open_cube: Dictionary = FIXTURES.two_cubes(Vector3.ZERO).first
	var fewer := _mesh({"positions": open_cube.positions, "indices": open_cube.indices.slice(3), "groups": PackedInt32Array(), "names": PackedStringArray(["a"])})
	_expect(fewer.boolean([_box(Vector3.ONE * 5 * MM)], {"name": "Cube"}) == null and fewer.get_last_error().begins_with("Cube is not closed (3 open edges)"), "Three open edges stay plural ('%s')." % fewer.get_last_error())
	# One new triangle without area, one place: the shared end of every op.
	var a := _mesh(FIXTURES.large_grid(20, 0.02))
	var pair: RefCounted = a.merge_with([a.transformed(Transform3D(Basis.from_euler(Vector3(0.3, 0.2, 0.1)), Vector3(0.011, 0.004, 0.003)))])
	pair.boolean([_mesh(FIXTURES.icosphere(0.01, 3, Vector3(0.03, 0.01, 0.01)))], {"operation": "join"})
	# (How many it makes depends on what counts as "without area", which is not this file's
	# business: whatever the count, one is said in the singular and more in the plural.)
	var made := RegEx.new()
	made.compile("made ([0-9,]+) (triangles?) without area")
	var found := made.search(pair.get_last_warning())
	_expect(found != null and (found.get_string(2) == "triangle") == (found.get_string(1) == "1") and not pair.get_last_warning().contains(" 1 triangles") and not pair.get_last_warning().contains(" 1 places"),
		"New triangles without area are counted in the singular or the plural as their number asks ('%s')." % pair.get_last_warning())
	# One piece inside-out (Separate).
	var loose: PackedVector3Array = fixture.positions.duplicate()
	for v in range(8, 16):
		loose[v] += Vector3(0.05, 0, 0)
	var stray := _mesh({"positions": loose, "indices": fixture.indices, "groups": fixture.groups, "names": fixture.names})
	stray.separate({})
	_expect(stray.get_last_warning() == "1 piece is inside-out. Reverse Normal can fix it.", "One inside-out piece is said in the singular ('%s')." % stray.get_last_warning())
	checked.append("singular forms (%s)" % "; ".join(said))


# ---------------------------------------------------------------- notes


func _check_notes() -> void:
	# A join of bodies that only touch is still two pieces, and says so.
	# (The verifier's cubes: corners at centre +- half the size. The mesh library leaves these as
	# two shells; cubes whose shared face differs in the last bit it fuses.)
	var a := _mesh(_corner_cube(20 * MM, Vector3.ZERO, "a"))
	var b := _mesh(_corner_cube(20 * MM, Vector3(20, 0, 0) * MM, "b"))
	var joined: RefCounted = a.boolean([b], {"operation": "join", "name": "Left"})
	_expect(joined != null and a.get_last_warning().contains("still 2 separate pieces") and a.get_last_report().get("pieces", 0) == 2, "A join of cubes that touch on a face should say it is still two pieces ('%s')." % a.get_last_warning())
	# (Corners exactly at centre +- half the size: a box scaled from the fixture lands a float32
	# step inside, and the join then keeps needles 0.0007 micrometres high, which the shared rule
	# counts as triangles without area since 2026-11-13.)
	var c := _mesh(_corner_cube(20 * MM, Vector3(10, 0, 0) * MM, "c"))
	_expect(a.boolean([c], {}) != null and a.get_last_warning() == "" and a.get_last_report().get("pieces", 0) == 1, "A join of cubes that overlap is one piece, with no warning ('%s')." % a.get_last_warning())
	# A target that was two pieces already: a tool that fuses with one of them leaves two, and
	# that is nothing new; a tool that meets neither is said.
	var apart := _mesh(FIXTURES.two_cubes(Vector3(60 * MM, 0, 0)))
	_expect(apart.boolean([_mesh(_corner_cube(20 * MM, Vector3(10, 0, 0) * MM, "t"))], {}) != null and apart.get_last_warning() == "" and apart.get_last_report().get("pieces", 0) == 2,
		"A tool that fuses with one of a body's two pieces leaves two, with no warning ('%s')." % apart.get_last_warning())
	_expect(apart.boolean([_box(Vector3.ONE * 20 * MM, Vector3(30, 0, 0) * MM, "t")], {}) != null and apart.get_last_warning().contains("still 3 separate pieces"),
		"A tool that meets neither piece is said ('%s')." % apart.get_last_warning())
	# The estimate is the same whatever is cached.
	var estimates := []
	for method: String in ["wrap", "rebuild", "shell"]:
		var ball := _mesh(FIXTURES.icosphere(0.02, 4))
		var before: float = ball.op_defaults(method, {}).seconds
		ball.ray_hit(Vector3(1, 0, 0), Vector3(-1, 0, 0))
		ball.check(5.0)
		var after: float = ball.op_defaults(method, {}).seconds
		_expect(before == after, "%s's estimate must not depend on what the mesh has cached (%s before, %s after)." % [method, before, after])
		estimates.append("%s %.2f s" % [method, before])
	var fast_ball := _mesh(FIXTURES.icosphere(0.02, 4))
	var fast_before: float = fast_ball.op_defaults("shell", {"method": "fast"}).seconds
	fast_ball.ray_hit(Vector3(1, 0, 0), Vector3(-1, 0, 0))
	_expect(fast_before == fast_ball.op_defaults("shell", {"method": "fast"}).seconds, "The fast shell's estimate must not depend on the cache either.")
	# Accurate Shell, Both: the face groups become one, and that is said.
	var box := _mesh(FIXTURES.two_cubes(Vector3(10 * MM, 0, 0)))
	var six := _new()
	six.from_shape(ClassDB.instantiate("CadKernel").make_box(Vector3(0.02, 0.02, 0.02)), 0.002, 0.3, false, 20.0)
	var band: RefCounted = six.shell({"thickness": 2 * MM, "direction": "both", "name": "Box"})
	_expect(band != null and band.group_count() == 1 and six.get_last_warning() == "Box's 6 face groups became one (shell0): Both makes a new surface on each side.", "Both should say the groups became one ('%s')." % six.get_last_warning())
	var plain := _box(Vector3.ONE * 20 * MM)
	_expect(plain.shell({"thickness": 2 * MM, "direction": "both"}) != null and plain.get_last_warning() == "", "With one group there is nothing to say ('%s')." % plain.get_last_warning())
	# Wrap fills inner voids, and says so.
	var hollow := _mesh(FIXTURES.hollow_cube(false))
	var wrapped: RefCounted = hollow.wrap({"name": "Hollow"})
	_expect(wrapped != null and _near(wrapped.volume() * 1e9, 8000.0, 0.01) and hollow.get_last_warning().contains("Wrap filled 1 inner void of Hollow"), "Wrap should say it filled the void ('%s')." % hollow.get_last_warning())
	# A move that makes the points fall together is refused (float32 keeps about 7 digits).
	var small := _box(Vector3.ONE * 2 * MM)
	_expect(small.transformed(Transform3D(Basis.IDENTITY, Vector3(90000, 0, 0))) == null and small.get_last_error().contains("fall together"), "A shift of 90 km must refuse a 2 mm cube ('%s')." % small.get_last_error())
	_expect(small.transformed(Transform3D(Basis.from_scale(Vector3.ONE * 1e-30), Vector3.ZERO)) == null and small.get_last_error().contains("smaller than a mesh body can be"), "A scale that shrinks the cube to nothing must be refused ('%s')." % small.get_last_error())
	_expect(small.transformed(Transform3D(Basis.IDENTITY, Vector3(3, 2, 1))) != null and small.transformed(Transform3D(Basis.from_scale(Vector3.ONE * 0.001), Vector3.ZERO)) != null, "Ordinary moves and scales still work ('%s')." % small.get_last_error())
	box = null
	checked.append("notes (a touching join said; estimates free of the cache: %s; Both names the groups it replaced; Wrap says it filled a void; a collapsing move refused)" % ", ".join(estimates))


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error(message)
		print("FAIL: ", message)


## A torus about the y axis (the verifier's: ring radius R, tube radius r, nu x nv quads).
func _torus(R: float, r: float, nu: int, nv: int) -> RefCounted:
	var positions := PackedVector3Array()
	for i in nu:
		var u := TAU * i / nu
		for j in nv:
			var v := TAU * j / nv
			positions.append(Vector3((R + r * cos(v)) * cos(u), r * sin(v), (R + r * cos(v)) * sin(u)))
	var indices := PackedInt32Array()
	for i in nu:
		for j in nv:
			var a := i * nv + j
			var b := ((i + 1) % nu) * nv + j
			var c := ((i + 1) % nu) * nv + (j + 1) % nv
			var d := i * nv + (j + 1) % nv
			indices.append_array([a, b, c, a, c, d])
	var mesh := _new()
	mesh.set_arrays(positions, indices, PackedInt32Array(), PackedStringArray(), "ccw")
	if mesh.volume() < 0.0:
		mesh = _new()
		mesh.set_arrays(positions, indices, PackedInt32Array(), PackedStringArray(), "godot")
	return mesh


## A cube of `size` around `center`, corners at centre +- half the size (8 vertices, 12 triangles).
func _corner_cube(size: float, center: Vector3, group: String) -> Dictionary:
	var h := size * 0.5
	var positions := PackedVector3Array()
	for k in 2:
		for j in 2:
			for i in 2:
				positions.append(center + Vector3(-h + size * i, -h + size * j, -h + size * k))
	# Corner id = i + 2 j + 4 k; triangles clockwise seen from outside (Godot's order).
	var indices := PackedInt32Array([
		0, 3, 2, 0, 1, 3,  4, 7, 5, 4, 6, 7,  0, 5, 1, 0, 4, 5,
		2, 7, 6, 2, 3, 7,  0, 6, 4, 0, 2, 6,  1, 7, 3, 1, 5, 7,
	])
	return {"positions": positions, "indices": indices, "groups": PackedInt32Array(), "names": PackedStringArray([group])}


# ---------------------------------------------------------------- second round: N4


## Planes through vertices and along edges of the body, and a hair beside them: the commonest
## cut there is (the mid-plane of a symmetric part). Each must give closed parts whose volumes
## add up.
func _check_plane_cut_through_vertices() -> void:
	var cases := []  # [what, mesh, origin, normal]
	var cube := _mesh(_corner_cube(20 * MM, Vector3.ZERO, "g0"))
	var d := 0.02 * sqrt(3.0)
	for k: float in [0.0, 1e-9, 1e-7]:
		for n: Vector3 in [Vector3(1, 0, 0), Vector3(1, 1, 0), Vector3(1, 1, 1), Vector3(1, 2, 3)]:
			cases.append(["cube, centre plane moved %s D, normal %s" % [k, n], cube, n.normalized() * (k * d), n])
			cases.append(["icosphere of 80, centre plane moved %s D, normal %s" % [k, n], _mesh(FIXTURES.icosphere(0.02, 1)), n.normalized() * (k * 0.04 * sqrt(3.0)), n])
	var bracket: RefCounted = FIXTURES.l_bracket().mesh
	cases.append(["L bracket, plane through its box centre, normal (1, 1, 0)", bracket, bracket.bbox().get_center(), Vector3(1, 1, 0)])
	cases.append(["torus, centre plane moved 1e-10 m, normal (1, 0, 0)", _torus(0.03, 0.01, 48, 24), Vector3(1e-10, 0, 0), Vector3(1, 0, 0)])
	# Every centre plane with a normal of small whole numbers, on balls of 320 and 1,280 triangles
	# and on the torus.
	for level: int in [2, 3]:
		var ball := _mesh(FIXTURES.icosphere(0.02, level))
		for a: int in [-1, 0, 1]:
			for b: int in [-1, 0, 1]:
				for c: int in [0, 1]:
					if (c == 0 and (b < 0 or (b == 0 and a <= 0))):
						continue
					cases.append(["icosphere level %d, centre plane, normal (%d, %d, %d)" % [level, a, b, c], ball, Vector3.ZERO, Vector3(a, b, c)])
	var ring := _torus(0.03, 0.01, 48, 24)
	for n: Vector3 in [Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(1, 0, 1), Vector3(1, 1, 0), Vector3(1, 1, 1), Vector3(0, 1, 0)]:
		cases.append(["torus, centre plane, normal %s" % n, ring, Vector3.ZERO, n])
	var refused := 0
	var wrong := 0
	var cuts := 0
	for case: Array in cases:
		var mesh: RefCounted = case[1]
		var whole: float = mesh.volume()
		for type: String in ["split_body", "trim"]:
			for fill: String in ["uniform", "minimal"]:
				cuts += 1
				var parts: Array = mesh.plane_cut({"origin": case[2], "normal": case[3], "type": type, "fill": fill})
				if parts.is_empty():
					refused += 1
					if refused <= 3:
						_expect(false, "%s, %s / %s: refused ('%s')." % [case[0], type, fill, mesh.get_last_error()])
					continue
				var sum := 0.0
				var closed := true
				for part: RefCounted in parts:
					if part != null:
						sum += part.volume()
						closed = closed and _closed(part)
				var right: bool = closed and (absf(sum - whole) <= 1e-6 * whole if type == "split_body" else (sum > 0.0 and sum < whole))
				if not right:
					wrong += 1
					if wrong <= 3:
						_expect(false, "%s, %s / %s: parts closed %s, volume %s of %s." % [case[0], type, fill, closed, sum, whole])
	_expect(refused == 0 and wrong == 0, "Plane Cut through vertices: %d of %d cuts refused, %d wrong." % [refused, cuts, wrong])
	checked.append("plane_cut through vertices (%d cuts on a cube, balls, the bracket and a torus: %d refused, %d wrong)" % [cuts, refused, wrong])


# ---------------------------------------------------------------- second round: N8


func _far(mesh: RefCounted, at: Vector3) -> RefCounted:
	return mesh.transformed(Transform3D(Basis.IDENTITY, at))


## True when `said` gives the distance from the origin as the reason and the way out, and does
## not call it an internal error.
func _true_reason(said: String) -> bool:
	return said.contains("from the origin") and said.contains("nearer the origin") and not said.contains("internal error") and not said.contains("report it")


func _check_far_from_origin_reasons() -> void:
	# The re-verifier's case: a 1.27 mm grid cube 170 m out. Positions step by 0.015 mm there;
	# the default wall is 0.044 mm in cells of 0.011 mm.
	var small := _far(_mesh(FIXTURES.large_grid(6, 0.0012656)), Vector3(-67.0, -86.5, -130.0))
	_expect(small != null, "A 1.27 mm cube 170 m out should load.")
	var said := []
	if small != null:
		for call: Array in [["shell", {"direction": "outside"}], ["shell", {"direction": "inside"}], ["shell", {"direction": "both"}], ["shell", {"method": "fast"}], ["wrap", {}], ["rebuild", {}],
				["displace", {"image": PackedByteArray([255, 0, 0, 255]), "width": 2, "height": 2}]]:
			var options: Dictionary = call[1].merged({"name": "Speck"})
			var out: Variant = small.call(call[0], options)
			_expect(out == null and _true_reason(small.get_last_error()) and small.get_last_error().begins_with("Speck is 1"),
				"%s %s on a 1.27 mm cube 170 m from the origin must be refused for that reason ('%s')." % [call[0], call[1], small.get_last_error() if out == null else "made: " + small.get_last_warning()])
		said.append(small.get_last_error().left(90))
	# The same cube near the origin works, and a 20 mm cube 260 m out still does (the first scan).
	var near := _mesh(FIXTURES.large_grid(6, 0.0012656))
	_expect(near.shell({"direction": "outside"}) != null, "The same cube at the origin shells (%s)." % near.get_last_error())
	var bigger := _far(_box(Vector3.ONE * 20 * MM), Vector3(211, 148, 63))
	var shelled: RefCounted = bigger.shell({"direction": "outside"})
	_expect(shelled != null and _closed(shelled), "A 20 mm cube 260 m out still shells (%s)." % bigger.get_last_error())
	# Plane Cut: a 20 mm cube at (1000, 1000, 1000) m has positions on a 0.06 mm lattice.
	var cube_km := _far(_box(Vector3.ONE * 20 * MM), Vector3(1000, 1000, 1000))
	var parts: Array = cube_km.plane_cut({"origin": Vector3(1000, 1000, 1000), "normal": Vector3(0.2, 1.0, 0.3), "name": "Cube"})
	_expect(parts.is_empty() and _true_reason(cube_km.get_last_error()), "Plane Cut 1.7 km out must be refused for that reason ('%s')." % cube_km.get_last_error())
	said.append(cube_km.get_last_error().left(90))
	# Nearer, where the cut is still good, it works and says what the rounding costs.
	var both: Array = bigger.plane_cut({"origin": Vector3(211, 148, 63), "normal": Vector3(0.2, 1.0, 0.3), "type": "split_body", "name": "Cube"})
	_expect(both.size() == 2 and both[0] != null and both[1] != null and _closed(both[0]) and _closed(both[1]) and absf(both[0].volume() + both[1].volume() - bigger.volume()) < 0.01 * bigger.volume(),
		"Plane Cut 260 m out should still work ('%s')." % bigger.get_last_error())
	_expect(bigger.get_last_warning().contains("from the origin") and bigger.get_last_warning().contains("stored only to about"), "Plane Cut 260 m out should say what the rounding costs ('%s')." % bigger.get_last_warning())
	# A result that would pass the 1,000 km limit: the true reason, before the work.
	var edge := _mesh(_corner_cube(100.0, Vector3(999990.0 - 50.0, 0, 0), "g0"))
	for call: Array in [["shell", {"direction": "outside", "thickness": 20.0}], ["shell", {"method": "fast", "direction": "outside", "thickness": 20.0}], ["wrap", {"offset": 15.0}],
			["displace", {"image": PackedByteArray([255, 255, 255, 255]), "width": 2, "height": 2, "depth": 15.0}]]:
		var out: Variant = edge.call(call[0], call[1].merged({"name": "Block"}))
		var error: String = edge.get_last_error()
		_expect(out == null and error.contains("1,000 km") and error.contains("nearer the origin") and not error.contains("internal error"),
			"%s %s past the 1,000 km limit must say so ('%s')." % [call[0], call[1], error if out == null else "made"])
	said.append(edge.get_last_error().left(90))
	# Combine: 20 mm cubes 1.7 km out join, with the cost of the rounding said; at the origin no word.
	var a := _far(_box(Vector3.ONE * 20 * MM), Vector3(1000, 1000, 1000))
	var b := _far(_box(Vector3.ONE * 20 * MM, Vector3(10, 0, 0) * MM, "b"), Vector3(1000, 1000, 1000))
	var joined: RefCounted = a.boolean([b], {"name": "Left", "tool_names": ["Right"]})
	_expect(joined != null and a.get_last_warning().contains("from the origin") and a.get_last_warning().contains("stored only to about") and a.get_last_warning().contains("% of its size"),
		"Combine 1.7 km out should say what the rounding costs ('%s' '%s')." % [a.get_last_warning(), a.get_last_error()])
	said.append(a.get_last_warning().left(120))
	checked.append("far from the origin (%s)" % "; ".join(said))


# ---------------------------------------------------------------- second round: N10


## `count` copies of a fixture on a cubic lattice, one mesh.
func _lattice(unit: Dictionary, count: int, pitch: float) -> RefCounted:
	var positions := PackedVector3Array()
	var indices := PackedInt32Array()
	var side := int(ceil(pow(count, 1.0 / 3.0)))
	for k in count:
		var o := Vector3(k % side, int(k / float(side)) % side, int(k / float(side * side))) * pitch
		var base := positions.size()
		for v: Vector3 in unit.positions:
			positions.append(v + o)
		for i: int in unit.indices:
			indices.append(i + base)
	var mesh := _new()
	mesh.set_arrays(positions, indices, PackedInt32Array(), PackedStringArray(["g0"]), "godot")
	return mesh


func _check_separate_preview() -> void:
	var said := []
	for count: int in [250, 251]:
		for limit: float in [0.5, 2.0, 20.0]:
			var balls := _lattice(FIXTURES.icosphere(0.002, 2), count, 0.005)
			var started := Time.get_ticks_usec()
			var pieces: Array = balls.separate({"time_limit": limit})
			var seconds := (Time.get_ticks_usec() - started) / 1e6
			_expect(pieces.size() == count and seconds < limit + 1.0, "Separate on %d balls of 320 triangles with %s s should give the %d pieces in time (%d pieces in %.2f s: '%s')." % [count, limit, count, pieces.size(), seconds, balls.get_last_error()])
			if count == 250:
				said.append("%s s: %d pieces in %.2f s" % [limit, pieces.size(), seconds])
	checked.append("separate on 250 balls of 320 triangles (%s)" % ", ".join(said))


# ---------------------------------------------------------------- second round: numbers in sentences


func _no_exponent(said: String) -> bool:
	var regex := RegEx.new()
	regex.compile("[0-9]e[-+]?[0-9]")
	return regex.search(said) == null


func _check_plain_numbers() -> void:
	var said := []
	var tiny := _box(Vector3.ONE * 0.1 * MM)
	_expect(tiny.shell({"thickness": 0.00004338787163}) == null and tiny.get_last_error().begins_with("Thickness must be between ") and _no_exponent(tiny.get_last_error()), "A range is said in plain numbers ('%s')." % tiny.get_last_error())
	said.append(tiny.get_last_error())
	_expect(tiny.shell({"thickness": 0.00000008661986}) == null and tiny.get_last_error().contains("million cells") and _no_exponent(tiny.get_last_error()), "A cell count and a thin wall are said in plain numbers ('%s')." % tiny.get_last_error())
	said.append(tiny.get_last_error())
	# The fast shell of two crossing cubes measures a wall of almost nothing somewhere.
	var pair := _mesh(FIXTURES.two_cubes(Vector3(10 * MM, 0, 0)))
	var out: RefCounted = pair.shell({"method": "fast", "thickness": 1 * MM})
	_expect(out != null and pair.get_last_warning().contains("measured ") and _no_exponent(pair.get_last_warning()), "The fast shell's measured wall is said in plain numbers ('%s')." % pair.get_last_warning())
	# Large lengths get a larger unit.
	var block := _mesh(_corner_cube(100.0, Vector3.ZERO, "g0"))
	_expect(block.shell({"thickness": 60.0}) == null and block.get_last_error() == "Thickness must be between 86.6 mm and 43.3 m.", "A range on a 100 m block is said in mm and m ('%s')." % block.get_last_error())
	said.append(block.get_last_error())
	checked.append("plain numbers (%s)" % "; ".join(said))


# ---------------------------------------------------------------- third round: helpers


## Bodies given as {positions, indices} (Godot's order), joined unwelded and moved by `xf`: one mesh.
func _joined(list: Array, xf := Transform3D.IDENTITY, winding := "godot") -> RefCounted:
	var positions := PackedVector3Array()
	var indices := PackedInt32Array()
	for part: Dictionary in list:
		var base := positions.size()
		for v: Vector3 in part.positions:
			positions.append(xf * v)
		for i: int in part.indices:
			indices.append(i + base)
	var mesh := _new()
	mesh.set_arrays(positions, indices, PackedInt32Array(), PackedStringArray(["g0"]), winding)
	return mesh


## A box of `size` around `center` triangulated as the re-verifier's (counter-clockwise from outside).
func _box_ccw(size: Vector3, center: Vector3) -> Dictionary:
	var positions := PackedVector3Array()
	for k in 2:
		for j in 2:
			for i in 2:
				positions.append(center + Vector3((i - 0.5) * size.x, (j - 0.5) * size.y, (k - 0.5) * size.z))
	return {"positions": positions, "indices": PackedInt32Array([0, 2, 3, 0, 3, 1, 4, 5, 7, 4, 7, 6, 0, 1, 5, 0, 5, 4, 2, 6, 7, 2, 7, 3, 0, 4, 6, 0, 6, 2, 1, 3, 7, 1, 7, 5])}


## Area of a part's triangles that lie on the plane (within `tolerance`) facing along `facing`
## (+1 along the normal, -1 against it).
func _on_plane_area(mesh: RefCounted, origin: Vector3, normal: Vector3, tolerance: float, facing: float) -> float:
	var arrays: Dictionary = mesh.get_arrays()
	var p: PackedVector3Array = arrays.positions
	var ids: PackedInt32Array = arrays.indices
	var total := 0.0
	for t in range(0, ids.size(), 3):
		var a := p[ids[t]]
		var b := p[ids[t + 1]]
		var c := p[ids[t + 2]]
		if absf((a - origin).dot(normal)) > tolerance or absf((b - origin).dot(normal)) > tolerance or absf((c - origin).dot(normal)) > tolerance:
			continue
		# (Godot's order is clockwise seen from outside.)
		var n := (c - a).cross(b - a)
		if n.dot(normal) * facing > 0.0:
			total += n.length() * 0.5
	return total


## The U channel: outline (0,0) (3,0) (3,2) (2,2) (2,1) (1,1) (1,2) (0,2) times 10 mm, 10 mm deep
## (28 triangles), moved by `xf`.
func _u_channel(xf: Transform3D) -> RefCounted:
	var outline := [Vector2(0, 0), Vector2(3, 0), Vector2(3, 2), Vector2(2, 2), Vector2(2, 1), Vector2(1, 1), Vector2(1, 2), Vector2(0, 2)]
	var positions := PackedVector3Array()
	for z in 2:
		for v: Vector2 in outline:
			positions.append(xf * (Vector3(v.x, v.y, z) * 10 * MM))
	var indices := PackedInt32Array()
	for t: Array in [[0, 1, 5], [1, 4, 5], [1, 2, 4], [2, 3, 4], [0, 5, 7], [5, 6, 7]]:
		indices.append_array([8 + t[0], 8 + t[1], 8 + t[2]])
		indices.append_array([t[0], t[2], t[1]])
	for k in 8:
		var a := k
		var b := (k + 1) % 8
		indices.append_array([a, b, 8 + b, a, 8 + b, 8 + a])
	var mesh := _new()
	mesh.set_arrays(positions, indices, PackedInt32Array(), PackedStringArray(["g0"]), "ccw")
	return mesh


# ---------------------------------------------------------------- third round: B2


## A small cube standing on a big one (two pieces, not welded), cut on the face it stands on:
## the small cube is what lies above, whole; on a turned copy too, with no flake.
func _check_plane_cut_on_shared_face() -> void:
	var wrong := 0
	var refused := 0
	var n := 0
	var first := ""
	for xi in range(-7, 8):
		for zi in range(-7, 8):
			var body := _joined([_box_ccw(Vector3.ONE * 20 * MM, Vector3.ZERO), _box_ccw(Vector3.ONE * 6 * MM, Vector3(xi, 13, zi) * MM)], Transform3D.IDENTITY, "ccw")
			for type: String in ["trim", "split_body"]:
				n += 1
				var parts: Array = body.plane_cut({"origin": Vector3(0, 10, 0) * MM, "normal": Vector3(0, 1, 0), "type": type, "fill": "uniform" if (xi + zi) % 2 == 0 else "minimal", "name": "Body"})
				if parts.is_empty():
					refused += 1
					if first == "":
						first = "(%d, %d) %s refused: %s" % [xi, zi, type, body.get_last_error()]
					continue
				var ok: bool = parts[0] != null and _closed(parts[0]) and _near(parts[0].volume() * 1e9, 216.0, 1e-6) and parts[0].check(5.0).components == 1
				if type == "split_body":
					ok = ok and parts[1] != null and _closed(parts[1]) and _near(parts[1].volume() * 1e9, 8000.0, 1e-6)
				if not ok:
					wrong += 1
					if first == "":
						first = "(%d, %d) %s: %s mm3 '%s'" % [xi, zi, type, parts[0].volume() * 1e9 if parts[0] != null else -1.0, body.get_last_warning()]
	_expect(wrong == 0 and refused == 0, "A cut on the face a small cube stands on keeps the small cube whole: %d of %d wrong, %d refused (%s)." % [wrong, n, refused, first])
	# Turned and moved: the same, with no flake or inside-out part.
	var xf := Transform3D(Basis(Vector3(0.3, 0.8, 0.5).normalized(), 0.7), Vector3(1, 2, 0) * MM)
	var said := ""
	for centre: Vector3 in [Vector3(2, 13, -1), Vector3(0, 13, 0)]:
		var body := _joined([_box_ccw(Vector3.ONE * 20 * MM, Vector3.ZERO), _box_ccw(Vector3.ONE * 6 * MM, centre * MM)], xf, "ccw")
		for type: Array in [["trim", false], ["trim", true], ["split_body", false]]:
			for fill: String in ["uniform", "minimal"]:
				var parts: Array = body.plane_cut({"origin": xf * (Vector3(0, 10, 0) * MM), "normal": xf.basis * Vector3(0, 1, 0), "type": type[0], "flip": type[1], "fill": fill, "name": "Body"})
				var warning: String = body.get_last_warning()
				var wanted := [216.0, 8000.0]
				var ok := not parts.is_empty() and not warning.contains("inside-out")
				for k in parts.size():
					if parts[k] == null:
						continue
					var c: Dictionary = parts[k].check(5.0)
					ok = ok and c.closed and c.manifold and c.components == 1 and c.inverted_components == 0 and _near(parts[k].volume() * 1e9, wanted[k], 1e-5)
				_expect(ok, "Turned, small cube at %s, %s%s / %s: the parts are the two cubes, no flake ('%s' '%s')." % [centre, type[0], " flip" if type[1] else "", fill, warning, body.get_last_error()])
				said = warning
	checked.append("plane_cut on the face a small cube stands on (%d cuts at 225 places: %d wrong, %d refused; turned: the two cubes%s)" % [n, wrong, refused, (", '" + said + "'") if said != "" else ", no warning"])


# ---------------------------------------------------------------- third round: B3


## The plane on the inner wall of a U channel, keeping the side without the wall: an L of
## 3,000 mm3 and 1,400 mm2, with nothing left on the plane facing the wrong way (a fin).
func _check_plane_cut_inner_wall() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var places := [Transform3D.IDENTITY]
	for k in 60:
		var axis := Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1)).normalized()
		places.append(Transform3D(Basis(axis, rng.randf_range(0.05, 3.1)), Vector3(rng.randf_range(-30, 30), rng.randf_range(-30, 30), rng.randf_range(-30, 30)) * MM))
	var fins := 0
	var wrong := 0
	var refused := 0
	var cuts := 0
	var first := ""
	for xf: Transform3D in places:
		var u := _u_channel(xf)
		var origin := xf * (Vector3(20, 0, 0) * MM)
		var normal := xf.basis * Vector3(1, 0, 0)
		for type: String in ["trim", "split_body"]:
			for fill: String in ["uniform", "minimal"]:
				cuts += 1
				var parts: Array = u.plane_cut({"origin": origin, "normal": normal, "type": type, "flip": true, "fill": fill, "name": "U"})
				if parts.size() != 2 or parts[1] == null:
					refused += 1
					if first == "":
						first = "%s %s refused: %s" % [xf.origin, type, u.get_last_error()]
					continue
				var kept: RefCounted = parts[1]
				var fin := _on_plane_area(kept, origin, normal, 1e-7, -1.0)
				if fin > 1e-9:
					fins += 1
				if fin > 1e-9 or not _closed(kept) or not _near(kept.volume() * 1e9, 3000.0, 1e-5) or not _near(kept.area() * 1e6, 1400.0, 1e-5):
					wrong += 1
					if first == "":
						first = "%s %s/%s: %.4f mm3, %.4f mm2, fin %.4f mm2 '%s'" % [xf.origin / MM, type, fill, kept.volume() * 1e9, kept.area() * 1e6, fin * 1e6, u.get_last_warning()]
	_expect(wrong == 0 and refused == 0, "A cut on the U channel's inner wall keeps an L of 3,000 mm3 and 1,400 mm2 with no fin: %d of %d wrong (%d with a fin), %d refused (%s)." % [wrong, cuts, fins, refused, first])
	checked.append("plane_cut on a U channel's inner wall (%d cuts at 61 places: %d wrong, %d refused)" % [cuts, wrong, refused])


# ---------------------------------------------------------------- third round: sentences


## A sentence is said once per warning, and a volume has no exponent.
func _check_plane_cut_sentences() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var repeated := 0
	var exponents := 0
	var first := ""
	var cuts := 0
	for k in 40:
		var axis := Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1)).normalized()
		var xf := Transform3D(Basis(axis, rng.randf_range(0.05, 3.1)), Vector3(rng.randf_range(-3, 3), rng.randf_range(-3, 3), rng.randf_range(-3, 3)) * MM)
		var cube := _joined([_corner_cube(20 * MM, Vector3.ZERO, "g0")], xf)
		for normal: Vector3 in [Vector3(1, -1, 0), Vector3(1, 1, 1), Vector3(1, 0, 0)]:
			cuts += 1
			var parts: Array = cube.plane_cut({"origin": xf.origin, "normal": xf.basis * normal, "type": "split_body", "fill": "uniform", "name": "Cube"})
			var warning: String = cube.get_last_warning()
			var lines := warning.split("\n", false)
			var seen := {}
			var twice := warning.count("without area") > 1
			for line in lines:
				twice = twice or seen.has(line)
				seen[line] = true
			if twice:
				repeated += 1
				if first == "":
					first = warning.replace("\n", " // ")
			if not _no_exponent(warning + cube.get_last_error()):
				exponents += 1
	_expect(repeated == 0 and exponents == 0, "Split Body says each thing once and with no exponent: %d of %d warnings repeat ('%s'), %d with an exponent." % [repeated, cuts, first, exponents])
	# Two cubes that cross each other (pieces that overlap, which the library takes for one
	# solid): each piece is cut on its own, the volumes add up, and the warning says so.
	var pair := _joined([_corner_cube(20 * MM, Vector3.ZERO, "g0"), _corner_cube(20 * MM, Vector3(10, 5, 5) * MM, "g0")])
	var whole: float = pair.volume()
	var told := ""
	for type: String in ["split_body", "trim"]:
		for fill: String in ["uniform", "minimal"]:
			var parts: Array = pair.plane_cut({"origin": Vector3(0, 3, 0) * MM, "normal": Vector3(0, 1, 0), "type": type, "fill": fill, "name": "Pair"})
			var warning: String = pair.get_last_warning()
			var ok := parts.size() == 2 and parts[0] != null and _closed(parts[0]) and _near(parts[0].volume() * 1e9, 7600.0, 1e-5)
			if type == "split_body":
				ok = ok and parts[1] != null and _closed(parts[1]) and _near(parts[0].volume() + parts[1].volume(), whole, 1e-6)
			_expect(ok and warning.contains("Each piece of Pair was cut on its own") and _no_exponent(warning + pair.get_last_error()),
				"Two cubes that overlap are cut piece by piece, and the warning says so (%s / %s: %d parts, '%s' '%s')." % [type, fill, parts.size(), warning, pair.get_last_error()])
			told = warning
	checked.append("plane_cut sentences (%d split cuts of a turned cube: %d repeat a sentence, %d with an exponent; overlapping cubes: '%s')" % [cuts, repeated, exponents, told])


# ---------------------------------------------------------------- third round: op_defaults far


## Remesh, Smooth, Reduce and Close Holes refuse a body too far from the origin before any work;
## op_defaults gives a panel the same sentence first (and nothing near the origin).
func _check_far_defaults() -> void:
	var near := _mesh(FIXTURES.icosphere(0.005, 2))
	var far: RefCounted = near.transformed(Transform3D(Basis.IDENTITY, Vector3(30000, 0, 0)))
	var said := []
	for call: Array in [["remesh", {}], ["remesh", {"mode": "adaptive"}], ["remesh", {"edge_length": 0.0005}], ["smooth", {}], ["reduce", {}], ["close_holes", {}]]:
		var options: Dictionary = call[1].merged({"name": "Ball"})
		var defaults: Dictionary = far.op_defaults(call[0], options)
		var out: Variant = far.call(call[0], options)
		var error: String = far.get_last_error()
		if not error.contains("from the origin"):
			_expect(not defaults.has("problem"), "%s %s: no far refusal from the op, so none from op_defaults ('%s' / %s)." % [call[0], call[1], error, defaults])
			said.append("%s: op says '%s'" % [call[0], error.left(40)])
			continue
		_expect(out == null and defaults.get("problem", "") == error, "%s %s: op_defaults should give the op's own far refusal ('%s' against '%s')." % [call[0], call[1], defaults.get("problem", ""), error])
		_expect(not near.op_defaults(call[0], call[1].merged({"name": "Ball"})).has("problem"), "%s near the origin: no problem." % call[0])
		said.append("%s %s" % [call[0], call[1]])
	checked.append("op_defaults says the far refusal of Remesh, Smooth, Reduce and Close Holes (%s; '%s')" % [", ".join(said), far.op_defaults("smooth", {"name": "Ball"}).get("problem", "")])
