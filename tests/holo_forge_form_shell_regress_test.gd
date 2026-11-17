extends SceneTree
## Regression checks for the second Phase 6 fix round on shells, headless, each bounded in time:
## - Hollow shells (no open faces) of millimetre converted bodies are right or refused: a 1 mm
##   sphere's inner wall came out 1.0 wall OUTSIDE the body in about 200 places with no warning
##   (OCCT's fixed tolerances at that size); every inner-wall point must lie inside the body, about
##   a wall in. A 0.5 mm sphere's possible walls took 6 to 14 s each to be refused; they must now be
##   answered within 5 s, and the same wall gets the same answer every time it is asked.
## - Kernel bodies with a wall a little over half their thickness are refused saying where and how
##   thick the body is (they said only "The offset could not be built" or "inside out").
## - A kernel box with rounded edges hollows with a wall thicker than its rounds (the inner wall is
##   a sharp box: exact volume), also turned, where a wrong "runs through itself" refused walls
##   that fit; its shell with the top face open builds too (it failed at every thickness).

const PRIMITIVES := preload("res://addons/holo_forge/core/form/primitives.gd")
const CAGE := preload("res://addons/holo_forge/core/form/cage.gd")
const REGEN := preload("res://addons/holo_forge/core/regen.gd")

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
	if ClassDB.class_exists("CadSubD") and kernel != null:
		_small_hollows()
		_kernel_half_walls()
		_rounded_box()
	else:
		print("note: CadSubD is not loaded; the native checks are skipped")
	if failures.is_empty():
		print("PASS holo_forge_form_shell_regress: ", ", ".join(checked))
		quit(0)
	else:
		print("FAIL holo_forge_form_shell_regress")
		for f in failures:
			print("  ", f)
		quit(1)


# --- Helpers -------------------------------------------------------------------------------------

## c scaled by s, turned 1.1 rad about (-3, 1, 0.5) and moved by (-0.7, 0.4, 0.2) s (the placement
## the verifier found the outside walls with).
func placed(c: Dictionary, s: float) -> Dictionary:
	var out := CAGE.copy(c)
	var basis := Basis(Vector3(-3, 1, 0.5).normalized(), 1.1)
	var origin := Vector3(-0.7, 0.4, 0.2) * s
	var p: PackedFloat64Array = out.positions
	for v in p.size() / 3:
		var x := p[3 * v] * s
		var y := p[3 * v + 1] * s
		var z := p[3 * v + 2] * s
		p[3 * v] = float(basis.x.x) * x + float(basis.y.x) * y + float(basis.z.x) * z + float(origin.x)
		p[3 * v + 1] = float(basis.x.y) * x + float(basis.y.y) * y + float(basis.z.y) * z + float(origin.y)
		p[3 * v + 2] = float(basis.x.z) * x + float(basis.y.z) * y + float(basis.z.z) * z + float(origin.z)
	out.positions = p
	return out


func to_body(c: Dictionary) -> RefCounted:
	var s: RefCounted = ClassDB.instantiate("CadSubD")
	if not s.set_cage(c):
		return null
	var shapes: Array = s.to_shapes({"isolation": 6, "name_prefix": "t/b"})
	return shapes[0] if not shapes.is_empty() else null


## Closest point on triangle (a, b, c) to p (Ericson).
static func closest_on_tri(p: Vector3, a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	var ab := b - a
	var ac := c - a
	var ap := p - a
	var d1 := ab.dot(ap)
	var d2 := ac.dot(ap)
	if d1 <= 0.0 and d2 <= 0.0:
		return a
	var bp := p - b
	var d3 := ab.dot(bp)
	var d4 := ac.dot(bp)
	if d3 >= 0.0 and d4 <= d3:
		return b
	var vc := d1 * d4 - d3 * d2
	if vc <= 0.0 and d1 >= 0.0 and d3 <= 0.0:
		return a + ab * (d1 / (d1 - d3))
	var cp := p - c
	var d5 := ab.dot(cp)
	var d6 := ac.dot(cp)
	if d6 >= 0.0 and d5 <= d6:
		return c
	var vb := d5 * d2 - d1 * d6
	if vb <= 0.0 and d2 >= 0.0 and d6 <= 0.0:
		return a + ac * (d2 / (d2 - d6))
	var va := d3 * d6 - d5 * d4
	if va <= 0.0 and (d4 - d3) >= 0.0 and (d5 - d6) >= 0.0:
		return b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6)))
	var denom := 1.0 / (va + vb + vc)
	return a + ab * (vb * denom) + ac * (vc * denom)


## The inner-wall points of hollow (the nodes of its faces that are not the body's own) measured
## against the body's tessellation: how many, how many lie under 0.9 or over 1.1 walls from it, and
## how many lie outside it (by the side of the nearest triangle, clear of it: the 1 mm sphere's
## wrong ones lay a whole wall out).
func inner_wall(body: RefCounted, hollow: RefCounted, t: float) -> Dictionary:
	var outer: Dictionary = body.tessellate(t / 50.0, 0.1)
	var cell := t
	var grid := {}
	var tris := PackedVector3Array()
	var normals := PackedVector3Array()
	var p: PackedVector3Array = outer.positions
	var nn: PackedVector3Array = outer.normals
	var idx: PackedInt32Array = outer.indices
	for k in range(0, idx.size(), 3):
		var a := p[idx[k]]
		var b := p[idx[k + 1]]
		var c := p[idx[k + 2]]
		var ti := tris.size() / 3
		tris.append(a)
		tris.append(b)
		tris.append(c)
		normals.append((nn[idx[k]] + nn[idx[k + 1]] + nn[idx[k + 2]]).normalized())
		var i0 := Vector3i((a.min(b).min(c) / cell).floor())
		var i1 := Vector3i((a.max(b).max(c) / cell).floor())
		for x in range(i0.x, i1.x + 1):
			for y in range(i0.y, i1.y + 1):
				for z in range(i0.z, i1.z + 1):
					var key := Vector3i(x, y, z)
					if not grid.has(key):
						grid[key] = PackedInt32Array()
					grid[key].append(ti)
	var h: Dictionary = hollow.tessellate(t / 20.0, 0.2)
	var hp: PackedVector3Array = h.positions
	var hidx: PackedInt32Array = h.indices
	var fid: PackedInt32Array = h.face_ids
	var seen := {}
	var pts := PackedVector3Array()
	for k in hidx.size():
		if fid[k / 3] >= body.face_count() and not seen.has(hidx[k]):
			seen[hidx[k]] = true
			pts.append(hp[hidx[k]])
	var step := maxi(1, pts.size() / 3000)
	var out := {"n": 0, "thin": 0, "far": 0, "outside": 0}
	for i in range(0, pts.size(), step):
		var q := pts[i]
		var c0 := Vector3i((q / cell).floor())
		var best := INF
		var side := 0.0
		for x in range(-2, 3):
			for y in range(-2, 3):
				for z in range(-2, 3):
					var key := c0 + Vector3i(x, y, z)
					if grid.has(key):
						for ti in grid[key]:
							var cp := closest_on_tri(q, tris[ti * 3], tris[ti * 3 + 1], tris[ti * 3 + 2])
							var d := q.distance_to(cp)
							if d < best:
								best = d
								side = (q - cp).dot(normals[ti]) / maxf(d, 1e-30)
		out.n += 1
		if best < 0.9 * t:
			out.thin += 1
		elif best > 1.1 * t:
			out.far += 1
		if side > 0.5:
			out.outside += 1
	return out


# --- Millimetre bodies ---------------------------------------------------------------------------

func _small_hollows() -> void:
	# [name, cage, size (m), thicknesses (m)]
	var specs := [
		["sphere 1 mm", PRIMITIVES.sphere(2.0, 8, 4), 0.0005, [0.00004, 0.0001]],
		["sphere 0.5 mm", PRIMITIVES.sphere(2.0, 8, 4), 0.00025, [0.00002, 0.0001]],
		["torus 0.5 mm", PRIMITIVES.torus(2.0, 0.8, 8, 6), 0.00025, [0.00005]],
	]
	var built := 0
	var slowest := 0
	for spec in specs:
		var a := to_body(placed(spec[1], spec[2]))
		if a == null:
			check(false, "The converted %s should build." % spec[0])
			continue
		for t in spec[3]:
			var t0 := Time.get_ticks_msec()
			var out: RefCounted = kernel.shell(a, PackedInt32Array(), {"thickness": t})
			var ms := Time.get_ticks_msec() - t0
			slowest = maxi(slowest, ms)
			var err := str(kernel.get_last_error())
			check(ms < 5000, "The %s hollow at %s mm took %d ms (a 0.5 mm sphere took 6 to 14 s)." % [spec[0], t * 1000.0, ms])
			if out == null:
				print("  note: the %s hollow at %s mm was refused: %s" % [spec[0], t * 1000.0, err])
				check(err.length() > 20, "A refused %s hollow at %s mm should say why (%s)." % [spec[0], t * 1000.0, err])
				continue
			built += 1
			var w := inner_wall(a, out, t)
			check(int(w.n) > 100, "The %s hollow at %s mm should have inner-wall points to measure (%d)." % [spec[0], t * 1000.0, w.n])
			check(int(w.outside) == 0, "The %s hollow at %s mm was built with %d of %d inner-wall points outside the body." % [spec[0], t * 1000.0, w.outside, w.n])
			check(int(w.thin) == 0 and int(w.far) == 0, "The %s hollow at %s mm has %d inner-wall points under 0.9 and %d over 1.1 walls from the outside (of %d)." % [spec[0], t * 1000.0, w.thin, w.far, w.n])
	check(built >= 4, "Walls that fit millimetre bodies should build (%d of 5 built)." % built)
	# The same wall asked again (a hair thicker each time, so no kept answer is used) gets the same
	# answer: a 0.5 mm sphere at 0.1 mm passed and failed "runs through itself" by turns, as OCCT's
	# offset came out with its faces in another order.
	var ball := to_body(placed(PRIMITIVES.sphere(2.0, 8, 4), 0.00025))
	if ball != null:
		var answers := {}
		for k in 4:
			var out: RefCounted = kernel.shell(ball, PackedInt32Array(), {"thickness": 0.0001 + k * 1e-12})
			answers[out != null] = true
		check(answers.size() == 1, "The 0.5 mm sphere's 0.1 mm hollow should get the same answer every time (got both).")
	checked.append("hollows of 0.5 and 1 mm converted bodies have every inner-wall point inside, about a wall in (%d built, slowest %d ms)" % [built, slowest])


# --- Kernel bodies at half their thickness -------------------------------------------------------

func _kernel_half_walls() -> void:
	var sphere: RefCounted = kernel.make_sphere(0.025, Vector3.ZERO)
	var torus: RefCounted = kernel.torus({"major_radius": 0.02, "minor_radius": 0.005, "center": Vector3.ZERO, "axis": Vector3(1, 2, 3).normalized()})
	var box: RefCounted = kernel.transform_shape(kernel.make_box(Vector3(0.02, 0.014, 0.01), Vector3.ZERO), Transform3D(Basis(Vector3(1, 2, 3).normalized(), 0.4), Vector3(0.001, 0.002, 0.003)))
	for c in [["sphere R25", sphere, 0.0252], ["sphere R25", sphere, 0.0255], ["torus minor 5", torus, 0.0051], ["box 10 mm thick", box, 0.0051]]:
		var t0 := Time.get_ticks_msec()
		var out: RefCounted = kernel.shell(c[1], PackedInt32Array(), {"thickness": c[2]})
		var ms := Time.get_ticks_msec() - t0
		var err := str(kernel.get_last_error())
		check(out == null, "A %s mm wall on the kernel %s can't fit and should be refused." % [c[2] * 1000.0, c[0]])
		check(ms < 4000, "Refusing a %s mm wall on the kernel %s took %d ms." % [c[2] * 1000.0, c[0], ms])
		check(err.contains("thick") and err.contains(") mm") and err.contains("try a wall under"), "The refusal of a %s mm wall on the kernel %s should say where and how thick the body is (%s)." % [c[2] * 1000.0, c[0], err])
	# Walls just under half still build.
	for c in [["sphere R25", sphere, 0.0245], ["torus minor 5", torus, 0.0049], ["box 10 mm thick", box, 0.0049]]:
		var out: RefCounted = kernel.shell(c[1], PackedInt32Array(), {"thickness": c[2]})
		check(out != null and out.volume() > 0.0, "A %s mm wall on the kernel %s fits and should build (%s)." % [c[2] * 1000.0, c[0], kernel.get_last_error()])
	checked.append("kernel bodies refuse walls over half their thickness saying where and how thick, and build walls just under it")


# --- A box with rounded edges ---------------------------------------------------------------------

## A 20 x 14 x 10 mm box with every edge rounded to r, turned like the verifier's (when turned).
func rounded_box(r: float, turned: bool) -> RefCounted:
	var b0: RefCounted = kernel.make_box(Vector3(0.02, 0.014, 0.01), Vector3.ZERO)
	var all := PackedInt32Array()
	for e in b0.edge_count():
		all.append(e)
	var f: RefCounted = kernel.fillet(b0, all, {"radius": r})
	if f == null or not turned:
		return f
	return kernel.transform_shape(f, Transform3D(Basis(Vector3(-3, 1, 0.5).normalized(), 1.1), Vector3(-0.007, 0.004, 0.002)))


func _rounded_box() -> void:
	var built := 0
	# [r, t, turned]: walls thicker than, equal to and under the rounds, both placements.
	for c in [[0.001, 0.0005, false], [0.001, 0.001, true], [0.001, 0.002, false], [0.001, 0.003, true], [0.003, 0.002, true], [0.003, 0.004, false], [0.003, 0.004, true]]:
		var a := rounded_box(c[0], c[2])
		if a == null:
			check(false, "The %s mm rounded box should build." % [c[0] * 1000.0])
			continue
		var t: float = c[1]
		var t0 := Time.get_ticks_msec()
		var out: RefCounted = kernel.shell(a, PackedInt32Array(), {"thickness": t})
		var ms := Time.get_ticks_msec() - t0
		check(ms < 4000, "Hollowing the %s mm rounded box at %s mm took %d ms." % [c[0] * 1000.0, t * 1000.0, ms])
		if out == null:
			check(false, "The %s mm rounded box (turned %s) hollows at %s mm and should build (%s)." % [c[0] * 1000.0, c[2], t * 1000.0, kernel.get_last_error()])
			continue
		built += 1
		if t >= c[0]:
			# A wall at least the round's radius: the inner wall is the sharp box a wall in.
			var inner := (0.02 - 2.0 * t) * (0.014 - 2.0 * t) * (0.01 - 2.0 * t)
			check(absf(out.volume() - (a.volume() - inner)) < 1e-6 * a.volume(), "The %s mm rounded box hollowed at %s mm holds %s m3, not the body less a sharp %s m3 box (%s)." % [c[0] * 1000.0, t * 1000.0, out.volume(), inner, a.volume() - inner])
		var w := inner_wall(a, out, t)
		check(int(w.n) > 0 and int(w.thin) == 0 and int(w.far) == 0 and int(w.outside) == 0, "The %s mm rounded box hollowed at %s mm has inner-wall points off the wall (%s)." % [c[0] * 1000.0, t * 1000.0, w])
	# The turned box with 12 mm rounds at 80 mm walls of 4 to 10 mm, several times (a wrong "runs
	# through itself" came and went from run to run).
	var big: RefCounted = kernel.transform_shape(rounded_box(0.003, false), Transform3D(Basis(Vector3(-3, 1, 0.5).normalized(), 1.1).scaled(Vector3(4, 4, 4)), Vector3(-0.028, 0.016, 0.008)))
	var refused := 0
	for k in 3:
		for t in [0.004, 0.008, 0.010]:
			# (A slightly different wall each time: no answer kept from the last.)
			var out: RefCounted = kernel.shell(big, PackedInt32Array(), {"thickness": t + k * 1e-6})
			if out == null:
				refused += 1
				print("  note: ", kernel.get_last_error())
	check(refused == 0, "%d of 9 hollows of the turned 80 mm rounded box were refused (they fit)." % refused)
	# The shell with its top face open.
	for c in [[0.001, 0.0005], [0.001, 0.002]]:
		var a := rounded_box(c[0], false)
		var top := -1
		for f in a.face_count():
			var info: Dictionary = a.face_info(f)
			if info.get("planar", false) and (info.normal as Vector3).is_equal_approx(Vector3.UP):
				top = f
		var t: float = c[1]
		var closed: RefCounted = kernel.shell(a, PackedInt32Array(), {"thickness": t})
		var t0 := Time.get_ticks_msec()
		var open: RefCounted = kernel.shell(a, PackedInt32Array([top]), {"thickness": t})
		var ms := Time.get_ticks_msec() - t0
		check(ms < 8000, "The open %s mm rounded box shell at %s mm took %d ms." % [c[0] * 1000.0, t * 1000.0, ms])
		if open == null or closed == null:
			check(false, "The %s mm rounded box with its top open should shell at %s mm (%s)." % [c[0] * 1000.0, t * 1000.0, kernel.get_last_error()])
			continue
		built += 1
		# The opening: the top's footprint (the round's tangent lines), or the sharp inner box's top.
		var w := maxf(t, c[0])
		var opening := (0.02 - 2.0 * w) * (0.01 - 2.0 * w) * t
		check(absf((closed.volume() - open.volume()) - opening) < 1e-6 * a.volume(), "The open %s mm rounded box at %s mm should hold the closed hollow less its %s m3 opening (%s, closed %s)." % [c[0] * 1000.0, t * 1000.0, opening, open.volume(), closed.volume()])
		check(open.solid_count() == 1, "The open rounded box shell should be one solid (%d)." % open.solid_count())
	checked.append("a rounded kernel box hollows with walls over its rounds (a sharp inner box), turned too, and shells with its top open (%d built)" % built)
