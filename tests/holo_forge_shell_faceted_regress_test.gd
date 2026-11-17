extends SceneTree
## Regression checks for Solid Shell and offset on bodies made of flat triangles (Convert Mesh:
## Faceted and the older Insert Mesh body), headless, each call bounded in time:
## - A ball of flat triangles (320 and 1280 of them), hollowed: the geometry kernel's offset kept
##   one corner where the five or six faces round it, moved in, no longer meet in one point, each
##   face's edges ending a few hundredths of a millimetre from it. Every check of the walls passed;
##   the body was handed back with no message, its wall 1 to 2 % too thick, and drawn (and exported
##   to STL) with 36 to 388 open edges, since faces whose mesh missed their own area were drawn from
##   pieces that end at their own edges and their neighbours were not. A convex body of flat faces
##   is hollowed exactly now (the solid behind its faces' planes moved in), so: built, drawn
##   closed, every inner corner a wall behind the nearest face, the wall's volume the exact one.
## - The same design rebuilt gave two bodies: 7 rebuilds in 9 the cracked one in 2.5 s, 2 in 9 the
##   exact one after 190 s (a boolean a face, each inside its own time bound). Twelve from-scratch
##   rebuilds must give one volume, each well inside the time limit.
## - Offsets in of the same balls (offset_shape), and the whole thing through features (Insert
##   Mesh, Convert Faceted, Shell, STL export read back with no open edge).
## - Flat-faced bodies that are not convex (a Faceted bracket, a block with crossing holes): built
##   with a closed drawn mesh, or refused with a sentence, inside the time limit (an offset of the
##   2900-facet block took 35 s: two tries with the whole limit each).
## - Walls and distances the ball has no room for are refused saying so.

const REGEN := preload("res://addons/holo_forge/core/regen.gd")
const FIXTURES := preload("res://tests/holo_forge_mesh_fixtures.gd")

## The kernel's time limit (20 s) and a second.
const CALL_MS := 21000
## What a ball's shell or offset may take here (it took 190 s; it takes 0.3 to 2 s).
const BALL_MS := 10000

## Wall volumes (mm3) of icosphere(0.02, level) hollowed by a wall (mm), worked out apart from the
## kernel (each plane's face a square cut by every other half-space, in double precision).
const EXACT_WALL := {
	"2/0.5": 32376.356464 - 29972.460363,
	"2/1": 32376.356464 - 27690.592477,
	"2/2": 32376.356464 - 23480.227824,
	"3/0.5": 33221.924544 - 30782.875173,
	"3/0.6928": 33221.924544 - 29875.247866,
}

var failures: Array[String] = []
var checked: Array[String] = []
var kernel: RefCounted


func _init() -> void:
	call_deferred("run")


func check(ok: bool, detail: String) -> void:
	if not ok:
		failures.append(detail)
		print("  fail: ", detail)


func run() -> void:
	kernel = REGEN.make_kernel()
	if kernel != null and ClassDB.class_exists("CadMesh"):
		_ball_shells()
		_ball_offsets()
		_same_every_time()
		_no_room()
		_not_convex()
		_through_features()
	else:
		print("note: CadKernel or CadMesh is not loaded; the native checks are skipped")
	if failures.is_empty():
		print("PASS holo_forge_shell_faceted_regress: ", ", ".join(checked))
		quit(0)
	else:
		print("FAIL holo_forge_shell_faceted_regress")
		for f in failures:
			print("  ", f)
		quit(1)


# --- Helpers -------------------------------------------------------------------------------------

## The body of a ball of flat triangles: "faceted" (Convert Mesh: Faceted) or "old" (Insert Mesh).
func ball(kind: String, level: int) -> RefCounted:
	var fx := FIXTURES.icosphere(0.02, level)
	if kind == "old":
		return kernel.mesh_to_shape(fx.positions, fx.indices, "ball")
	var mesh := FIXTURES.to_mesh(fx)
	return mesh.to_faceted({}) if mesh != null else null


## The viewport's mesh of a body.
func drawn(shape: RefCounted) -> Dictionary:
	return shape.tessellate(clampf((shape.bbox() as AABB).size.length() * 0.0015, 0.00001, 0.01), 0.3)


## The edges of a drawn mesh that an odd number of its triangles use (corners matched exactly, as
## an STL reader matches them): 0 on a closed mesh.
func open_edges(positions: PackedVector3Array, indices: PackedInt32Array) -> int:
	var ids := {}
	var corner := PackedInt32Array()
	corner.resize(positions.size())
	for i in positions.size():
		if not ids.has(positions[i]):
			ids[positions[i]] = ids.size()
		corner[i] = ids[positions[i]]
	var uses := {}
	for t in range(0, indices.size(), 3):
		for e in 3:
			var u := corner[indices[t + e]]
			var v := corner[indices[t + (e + 1) % 3]]
			if u == v:
				continue
			var key := (mini(u, v) << 32) | maxi(u, v)
			uses[key] = int(uses.get(key, 0)) + 1
	var open := 0
	for key in uses:
		if int(uses[key]) % 2 != 0:
			open += 1
	return open


## What is wrong with the drawn mesh of a body: open edges and tessellation warnings ("" when it
## is closed and drawn without a warning).
func drawn_problem(shape: RefCounted) -> String:
	var t := drawn(shape)
	if not t.has("positions"):
		return "no mesh"
	var open := open_edges(t.positions, t.indices)
	var warnings: PackedStringArray = t.get("warnings", PackedStringArray())
	var parts := PackedStringArray()
	if open > 0:
		parts.append("%d open edges in %d triangles" % [open, (t.indices as PackedInt32Array).size() / 3])
	if not warnings.is_empty():
		parts.append("warning '%s'" % warnings[0])
	return ", ".join(parts)


## The planes of a ball's triangles as [normal (outward), distance from the origin] in doubles.
func planes_of(level: int) -> Array:
	var fx := FIXTURES.icosphere(0.02, level)
	var p: PackedVector3Array = fx.positions
	var idx: PackedInt32Array = fx.indices
	var out := []
	for t in range(0, idx.size(), 3):
		var a := p[idx[t]]
		var b := p[idx[t + 1]]
		var c := p[idx[t + 2]]
		var ux := float(b.x) - float(a.x)
		var uy := float(b.y) - float(a.y)
		var uz := float(b.z) - float(a.z)
		var vx := float(c.x) - float(a.x)
		var vy := float(c.y) - float(a.y)
		var vz := float(c.z) - float(a.z)
		var nx := uy * vz - uz * vy
		var ny := uz * vx - ux * vz
		var nz := ux * vy - uy * vx
		var l := sqrt(nx * nx + ny * ny + nz * nz)
		nx /= l
		ny /= l
		nz /= l
		var h := nx * float(a.x) + ny * float(a.y) + nz * float(a.z)
		if h < 0.0:
			nx = -nx
			ny = -ny
			nz = -nz
			h = -h
		out.append([nx, ny, nz, h])
	return out


## How far the corners of a ball's wall in (those of the drawn mesh well inside the ball) lie from
## where they belong: each is exactly a wall behind the nearest face's plane, and no nearer any
## other. The largest miss (m), and how many corners were measured.
func inner_corner_miss(shape: RefCounted, level: int, t: float) -> Dictionary:
	var planes := planes_of(level)
	var mesh := drawn(shape)
	var seen := {}
	var worst := 0.0
	var n := 0
	for q: Vector3 in mesh.positions:
		if seen.has(q):
			continue
		seen[q] = true
		var nearest := -INF
		for pl in planes:
			nearest = maxf(nearest, float(pl[0]) * float(q.x) + float(pl[1]) * float(q.y) + float(pl[2]) * float(q.z) - float(pl[3]))
		if nearest > -0.5 * t:
			continue
		worst = maxf(worst, absf(nearest + t))
		n += 1
	return {"miss": worst, "corners": n}


# --- Balls of flat triangles ---------------------------------------------------------------------

func _ball_shells() -> void:
	var built := 0
	var tried := 0
	var slowest := 0
	for spec in [["faceted", 2, [0.5, 1.0, 2.0]], ["old", 2, [1.0]], ["faceted", 3, [0.5, 0.6928]], ["old", 3, [0.5]]]:
		var a := ball(spec[0], spec[1])
		check(a != null, "The %s ball of level %d should be made." % [spec[0], spec[1]])
		if a == null:
			continue
		for t_mm: float in spec[2]:
			var t := t_mm / 1000.0
			var label := "The %s ball of %d flat triangles hollowed with a %s mm wall" % [spec[0], a.face_count(), t_mm]
			tried += 1
			var t0 := Time.get_ticks_msec()
			var out: RefCounted = kernel.shell(a, PackedInt32Array(), {"thickness": t})
			var ms := Time.get_ticks_msec() - t0
			var why := str(kernel.get_last_error())
			slowest = maxi(slowest, ms)
			check(ms < BALL_MS, "%s took %d ms (the exact wall takes a second or two; it took 190 s)." % [label, ms])
			check(out != null, "%s should be built: it is convex and flat-faced, so its wall is exact (%s)." % [label, why])
			if out == null:
				continue
			built += 1
			check(out.solid_count() == 1, "%s came out as %d solids." % [label, out.solid_count()])
			var bad := drawn_problem(out)
			check(bad == "", "%s is drawn with cracks: %s." % [label, bad])
			var miss := inner_corner_miss(out, spec[1], t)
			check(int(miss.corners) >= a.face_count() / 2 and float(miss.miss) < 2e-7, "%s has inner corners up to %.5f mm from a wall behind the nearest face (%d corners)." % [label, float(miss.miss) * 1000.0, miss.corners])
			var exact: float = EXACT_WALL["%d/%s" % [spec[1], str(t_mm).trim_suffix(".0")]]
			var wall: float = out.volume() * 1e9
			check(absf(wall - exact) < 2e-4 * exact, "%s holds %.3f mm3; the exact wall holds %.3f mm3." % [label, wall, exact])
	checked.append("%d of %d hollowed balls of flat triangles are built exact and drawn closed (slowest %d ms)" % [built, tried, slowest])


func _ball_offsets() -> void:
	var built := 0
	var tried := 0
	for spec in [["faceted", 2, [0.5, 2.0]], ["faceted", 3, [0.5]], ["old", 2, [1.0]]]:
		var a := ball(spec[0], spec[1])
		if a == null:
			continue
		for t_mm: float in spec[2]:
			var label := "The %s ball of %d flat triangles offset in by %s mm" % [spec[0], a.face_count(), t_mm]
			tried += 1
			var t0 := Time.get_ticks_msec()
			var out: RefCounted = kernel.offset_shape(a, -t_mm / 1000.0)
			var ms := Time.get_ticks_msec() - t0
			var why := str(kernel.get_last_error())
			check(ms < BALL_MS, "%s took %d ms." % [label, ms])
			check(out != null, "%s should be built (%s)." % [label, why])
			if out == null:
				continue
			built += 1
			var bad := drawn_problem(out)
			check(bad == "", "%s is drawn with cracks: %s." % [label, bad])
			var exact: float = a.volume() * 1e9 - float(EXACT_WALL["%d/%s" % [spec[1], str(t_mm).trim_suffix(".0")]])
			check(absf(out.volume() * 1e9 - exact) < 2e-5 * exact, "%s holds %.3f mm3; the exact offset holds %.3f mm3." % [label, out.volume() * 1e9, exact])
	checked.append("%d of %d balls offset in are exact and drawn closed" % [built, tried])


func _same_every_time() -> void:
	# From scratch each time: the mesh, the conversion, the shell.
	var volumes := {}
	var slowest := 0
	var open := 0
	for k in 12:
		var a := ball("faceted", 3)
		if a == null:
			check(false, "The ball should convert (round %d)." % (k + 1))
			continue
		var t0 := Time.get_ticks_msec()
		var out: RefCounted = kernel.shell(a, PackedInt32Array(), {"thickness": 0.0005})
		var ms := Time.get_ticks_msec() - t0
		slowest = maxi(slowest, ms)
		if out == null:
			volumes["refused: " + str(kernel.get_last_error())] = true
			continue
		volumes[out.volume()] = true
		var t := drawn(out)
		open += open_edges(t.positions, t.indices)
	check(volumes.size() == 1, "Twelve rebuilds of the same hollowed ball gave %d different results: %s." % [volumes.size(), str(volumes.keys())])
	check(open == 0, "The twelve rebuilds' drawn meshes have %d open edges in all." % open)
	check(slowest < BALL_MS, "The slowest of twelve rebuilds took %d ms (two in nine took 190 s)." % slowest)
	checked.append("12 from-scratch rebuilds of the 1280-triangle ball's shell give one body (slowest %d ms)" % slowest)


func _no_room() -> void:
	var a := ball("faceted", 2)
	if a == null:
		return
	var out: RefCounted = kernel.offset_shape(a, -0.025)
	var why := str(kernel.get_last_error())
	check(out == null and why.contains("comes out empty"), "The ball of 20 mm radius offset in by 25 mm leaves nothing and should be refused saying so, not '%s'." % why)
	out = kernel.shell(a, PackedInt32Array(), {"thickness": 0.021})
	why = str(kernel.get_last_error())
	check(out == null and why.contains("thicker than the body allows"), "The ball of 20 mm radius can't hold a 21 mm wall and should be refused saying so, not '%s'." % why)
	checked.append("a wall and a distance the ball has no room for are refused saying so")


# --- Flat-faced bodies that are not convex -------------------------------------------------------

func _not_convex() -> void:
	var bracket := FIXTURES.l_bracket()
	var crossing := FIXTURES.crossing_holes()
	var list := []
	if not bracket.is_empty():
		list.append(["Faceted bracket", bracket.mesh.to_faceted({}), true])
		list.append(["Faceted bracket (triangles kept)", bracket.mesh.to_faceted({"merge_flat": false}), true])
	var hollow := FIXTURES.to_mesh(FIXTURES.hollow_cube(false))
	if hollow != null:
		list.append(["Faceted hollow cube", hollow.to_faceted({}), true])
	if not crossing.is_empty():
		# (Its shell takes the kernel 17 s to give up on: the offset alone is timed here.)
		list.append(["Faceted block with crossing holes", crossing.mesh.to_faceted({}), false])
	var built := 0
	var refused := 0
	var slowest := 0
	for item in list:
		var a: RefCounted = item[1]
		check(a != null, "The %s should convert." % item[0])
		if a == null:
			continue
		var t: float = (a.bbox() as AABB).size.length() * 0.01
		var calls := [["offset in by", func(): return kernel.offset_shape(a, -t)]]
		if item[2]:
			calls.append(["shell with a wall of", func(): return kernel.shell(a, PackedInt32Array(), {"thickness": t})])
		for c in calls:
			var label := "The %s (%d flat faces), %s %.3f mm" % [item[0], a.face_count(), c[0], t * 1000.0]
			var t0 := Time.get_ticks_msec()
			var out: RefCounted = (c[1] as Callable).call()
			var ms := Time.get_ticks_msec() - t0
			# (Read at once: the next call that works clears it.)
			var why := str(kernel.get_last_error())
			slowest = maxi(slowest, ms)
			check(ms < CALL_MS, "%s took %d ms, over the time limit." % [label, ms])
			if out == null:
				refused += 1
				check(why.length() > 20 and why.contains(" "), "%s was refused without a sentence ('%s')." % [label, why])
				continue
			built += 1
			var bad := drawn_problem(out)
			check(bad == "", "%s was built and is drawn with cracks: %s." % [label, bad])
			check(out.volume() > 0.0 and out.volume() < a.volume(), "%s holds %s m3 of the body's %s m3." % [label, out.volume(), a.volume()])
	checked.append("flat-faced bodies that are not convex: %d shells and offsets built with a closed drawn mesh, %d refused with a sentence, inside the time limit (slowest %d ms)" % [built, refused, slowest])


# --- Through features ----------------------------------------------------------------------------

func _through_features() -> void:
	var needed := ["res://addons/holo_forge/core/document.gd", "res://addons/holo_forge/core/operations.gd", "res://addons/holo_forge/core/features/insert.gd",
			"res://addons/holo_forge/core/features/mesh_convert.gd", "res://addons/holo_forge/core/mesh/mesh_blob.gd", "res://addons/holo_forge/core/export.gd"]
	for path in needed:
		if not ResourceLoader.exists(path):
			print("note: %s is missing; the feature checks are skipped" % path)
			return
	var document: GDScript = load(needed[0])
	var operations: GDScript = load(needed[1])
	var insert: GDScript = load(needed[2])
	var mesh_convert: GDScript = load(needed[3])
	var mesh_blob: GDScript = load(needed[4])
	var exporter: GDScript = load(needed[5])
	var doc: Resource = document.new()
	var feature: Resource = doc.add_feature("mesh_import", "Mesh", {}, {
		"path": "", "kind": insert.KIND_MESH, "units": "mm", "mesh_units": "mm", "linked": false, "split": false,
		"transform": Transform3D.IDENTITY, "operation": operations.NEW_BODY, "mesh": mesh_blob.from_mesh(FIXTURES.to_mesh(FIXTURES.icosphere(0.02, 2))),
	})
	var body_id: String = doc.new_body(feature.id)
	feature.options["body_id"] = body_id
	var convert: Resource = mesh_convert.add_convert(doc, "convert_faceted", [body_id]).feature
	check(convert != null, "Convert Faceted should be added.")
	if convert == null:
		return
	REGEN.rebuild(doc, kernel)
	var out_id := str(convert.options.outputs[0])
	var shell: Resource = doc.add_feature("shell", "Shell", {"thickness": doc.make_input("1 mm", "length")}, {"faces": [{"kind": "body", "body": out_id}]})
	var t0 := Time.get_ticks_msec()
	var result: Dictionary = REGEN.rebuild(doc, kernel)
	var ms := Time.get_ticks_msec() - t0
	var why := str(result.errors.get(shell.id, ""))
	check(ms < BALL_MS, "Insert Mesh, Convert Faceted, Shell 1 mm rebuilt in %d ms." % ms)
	check(why == "" and result.bodies.has(out_id), "Insert Mesh, Convert Faceted, Shell 1 mm should build ('%s')." % why)
	if why != "" or not result.bodies.has(out_id):
		return
	var shape: RefCounted = result.bodies[out_id].shape
	var bad := drawn_problem(shape)
	check(bad == "", "The Shell feature's body is drawn with cracks: %s." % bad)
	check(absf(shape.volume() * 1e9 - float(EXACT_WALL["2/1"])) < 2e-4 * float(EXACT_WALL["2/1"]), "The Shell feature's body holds %.3f mm3; the exact wall holds %.3f mm3." % [shape.volume() * 1e9, float(EXACT_WALL["2/1"])])
	var dir := "user://holo_forge_shell_faceted_regress"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var path := ProjectSettings.globalize_path(dir.path_join("shell.stl"))
	var report: Dictionary = exporter.export_cad_report(kernel, result, [out_id], path, doc)
	check(str(report.get("error", "")) == "", "The STL export of the Shell feature's body failed: %s." % str(report.get("error", "")))
	var back: RefCounted = ClassDB.instantiate("CadMesh")
	if FileAccess.file_exists(path) and back.read_stl(path, 1.0):
		var census: Dictionary = back.check(2.0)
		check(int(census.get("boundary_edges", -1)) == 0 and bool(census.get("closed", false)), "The exported STL of the Shell feature's body, read back, has %s open edges (%d triangles)." % [str(census.get("boundary_edges", "?")), int(back.triangle_count())])
		DirAccess.remove_absolute(path)
	else:
		check(false, "The exported STL should be read back (%s)." % str(back.get_last_error()))
	checked.append("Insert Mesh, Convert Faceted, Shell through features: built, drawn closed, the STL read back closed (%d ms)" % ms)
