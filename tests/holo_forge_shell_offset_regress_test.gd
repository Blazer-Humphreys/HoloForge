extends SceneTree
## Regression checks for shells and offsets of kernel bodies, headless, each bounded in time:
## - Offsets that collapse a body (a 2 mm box in by 0.6 mm, a 37 mm box in by 11.1 mm, a 2 mm
##   cylinder in by 1.2 mm) and hollows of small bodies that OCCT's offset can't make (a 20 mm
##   sphere cut by a 15 mm cube, an L-shaped 4 mm box) killed the editor inside OCCT's shape
##   healing (signal 11): they must come back, refused with a reason or right.
## - kernel.offset_shape never hands back an empty, flat or inside-out shape as done (a box with
##   1 mm rounds offset in by 1 or 2 mm came back with no volume; a 1 mm sphere in by 0.6 mm
##   inside out), and what it does hand back lies the distance from the body.
## - Shells with an open face are right or refused: one solid, inside the body, the opening open,
##   every point of the inner wall at least about a wall in from the faces kept (a chamfered box
##   open at the top came back at 0.42 mm3, or closed over; a rounded box and a box with a hole
##   came back with walls at a third and two thirds of the thickness).
## - A prism with a spline wall (a horseshoe, its top open) shells right: OCCT's mesh of its
##   wall, which the walls are checked against, cut across its bends 0.7 mm off asked for
##   0.002 mm and refused it.
## - Hollows of an L-shaped bracket and a box with a sphere on it, which OCCT's offset gets wrong
##   at some walls only, are built right (they were refused), and a refusal that remains says why
##   honestly.

const REGEN := preload("res://addons/holo_forge/core/regen.gd")

## Each call must return within this (they returned in well under a second, or never).
const CALL_MS := 8000

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
	if kernel != null:
		_crashes()
		_offsets()
		_open_shells()
		_spline_shells()
		_closed_shells()
	else:
		print("note: CadKernel is not loaded; the native checks are skipped")
	if failures.is_empty():
		print("PASS holo_forge_shell_offset_regress: ", ", ".join(checked))
		quit(0)
	else:
		print("FAIL holo_forge_shell_offset_regress")
		for f in failures:
			print("  ", f)
		quit(1)


# --- Bodies (the verifiers' kernel bodies) -------------------------------------------------------

func _edges_where(b: RefCounted, pred: Callable) -> PackedInt32Array:
	var out := PackedInt32Array()
	for e in b.edge_count():
		if pred.call(b.edge_info(e)):
			out.append(e)
	return out


## A kernel body size_mm across (a box size x 0.7 size x 0.5 size unless said), turned by rot (0
## none, 1 and 2 two placements where no face lines up with an axis); param in mm.
func body(kind: String, size_mm: float, rot: int, param := 0.0) -> RefCounted:
	var S := size_mm / 1000.0
	var p := param / 1000.0
	var box: RefCounted = kernel.make_box(Vector3(S, S * 0.7, S * 0.5), Vector3.ZERO)
	var b: RefCounted = null
	match kind:
		"box":
			b = box
		"cyl":
			b = kernel.make_cylinder(S / 2.0, S * 0.6, Vector3.ZERO, Vector3.UP)
		"cham":
			var all := PackedInt32Array()
			for e in box.edge_count():
				all.append(e)
			b = kernel.chamfer(box, all, {"distance": p})
		"fillet":
			var all := PackedInt32Array()
			for e in box.edge_count():
				all.append(e)
			b = kernel.fillet(box, all, {"radius": p})
		"vround":
			b = kernel.fillet(box, _edges_where(box, func(i): return absf(((i.end as Vector3) - (i.start as Vector3)).normalized().y) > 0.9), {"radius": p})
		"hole":
			var bb: AABB = box.bbox()
			b = kernel.boolean(box, kernel.make_cylinder(p, S, Vector3(bb.get_center().x, bb.position.y - S * 0.1, bb.get_center().z), Vector3.UP), 1)
		"L":
			var bb: AABB = box.bbox()
			b = kernel.boolean(box, kernel.make_box(Vector3(S * 0.6, S * 0.5, S), bb.position + Vector3(S * 0.4, S * 0.2, -S * 0.2)), 1)
		"spherebox":
			b = kernel.boolean(kernel.make_sphere(S / 2.0, Vector3.ZERO), kernel.make_box(Vector3(S, S, S) * 0.75, Vector3(-0.375, -0.375, -0.375) * S), 2)
		"union":
			b = kernel.boolean(box, kernel.make_sphere(S * 0.2, Vector3(S * 0.5, S * 0.7, S * 0.25)), 0)
	if b == null:
		return null
	if rot == 0:
		return b
	var s := size_mm / 2000.0
	var xf := Transform3D(Basis(Vector3(1, 2, 3).normalized(), 0.4), Vector3(0.1, 0.2, 0.3) * s)
	if rot == 2:
		xf = Transform3D(Basis(Vector3(-3, 1, 0.5).normalized(), 1.1), Vector3(-0.7, 0.4, 0.2) * s)
	return kernel.transform_shape(b, xf)


func up_of(rot: int) -> Vector3:
	if rot == 1:
		return Basis(Vector3(1, 2, 3).normalized(), 0.4) * Vector3.UP
	if rot == 2:
		return Basis(Vector3(-3, 1, 0.5).normalized(), 1.1) * Vector3.UP
	return Vector3.UP


func name_of(kind: String, size_mm: float, rot: int) -> String:
	return "%s %s mm (rot %d)" % [kind, size_mm, rot]


# --- Measures ------------------------------------------------------------------------------------

## How many of the points lie outside a: a ball a hundredth of t round each, less than 99 % in a.
## (By balls, not by cutting a from out: OCCT's cut of a shell from its own body, every outer face
## shared, can come back wrong itself.)
func outside_count(points: PackedVector3Array, a: RefCounted, t: float) -> int:
	var n := 0
	for q in points:
		var ball: RefCounted = kernel.make_sphere(0.01 * t, q)
		var c = kernel.boolean(ball, a, 2)
		if c == null or c.volume() < 0.99 * ball.volume():
			n += 1
	return n


## The least distance from those of out's tessellation vertices not on keep (the kept faces'
## compound, within 0.02 t) and not within skip_open of open (an opening's faces: rims lie
## between the kept faces and a wall in), to keep, in walls (INF when none), and how many there
## were; and the farthest, in walls; and up to 40 of those points ("wall").
func wall_distances(out: RefCounted, keep: RefCounted, open: RefCounted, t: float, skip_open: float) -> Dictionary:
	var tess: Dictionary = out.tessellate(t / 20.0, 0.2)
	var p: PackedVector3Array = tess.positions
	var lowest := INF
	var highest := 0.0
	var n := 0
	var wall := PackedVector3Array()
	var step := maxi(1, p.size() / 400)
	for i in range(0, p.size(), step):
		var v = kernel.make_vertex(p[i])
		if open != null:
			var ro: Dictionary = kernel.closest_points(v, open)
			if ro.has("distance") and float(ro.distance) < skip_open:
				continue
		var r: Dictionary = kernel.closest_points(v, keep)
		if not r.has("distance"):
			continue
		var d := float(r.distance) / t
		if d < 0.02:
			continue
		n += 1
		lowest = minf(lowest, d)
		highest = maxf(highest, d)
		if n % 8 == 1 and wall.size() < 40:
			wall.append(p[i])
	return {"lowest": lowest, "highest": highest, "n": n, "wall": wall}


# --- Crashes -------------------------------------------------------------------------------------

func _crashes() -> void:
	# Offsets that collapse the body, and hollows OCCT's offset can't make: each comes back.
	for c in [["box", 2.0, 0, -0.6], ["box", 37.0, 0, -11.1], ["cham", 20.0, 0, -3.0, 1.0], ["cyl", 2.0, 0, -1.2], ["L", 4.0, 1, -0.5], ["spherebox", 20.0, 1, -1.5], ["spherebox", 20.0, 1, -2.0]]:
		var a := body(c[0], c[1], c[2], c[4] if c.size() > 4 else 0.0)
		var t0 := Time.get_ticks_msec()
		var out = kernel.offset_shape(a, float(c[3]) / 1000.0)
		var ms := Time.get_ticks_msec() - t0
		check(ms < CALL_MS, "Offsetting the %s by %s mm took %d ms." % [name_of(c[0], c[1], c[2]), c[3], ms])
		check(out != null or str(kernel.get_last_error()).length() > 20, "A refused offset of the %s by %s mm should say why." % [name_of(c[0], c[1], c[2]), c[3]])
		if out != null:
			check(out.volume() > 0.0 and out.volume() < a.volume(), "The offset of the %s by %s mm came back with volume %s (body %s)." % [name_of(c[0], c[1], c[2]), c[3], out.volume(), a.volume()])
	for c in [["spherebox", 20.0, 1, [1.5, 2.0, 3.0]], ["spherebox", 10.0, 1, [1.0]], ["L", 4.0, 1, [0.05, 0.08]]]:
		var a := body(c[0], c[1], c[2])
		for t in c[3]:
			var t0 := Time.get_ticks_msec()
			var out = kernel.shell(a, PackedInt32Array(), {"thickness": float(t) / 1000.0})
			var ms := Time.get_ticks_msec() - t0
			check(ms < CALL_MS, "Hollowing the %s at %s mm took %d ms." % [name_of(c[0], c[1], c[2]), t, ms])
			check(out != null or str(kernel.get_last_error()).length() > 20, "A refused hollow of the %s at %s mm should say why." % [name_of(c[0], c[1], c[2]), t])
	checked.append("collapsing offsets and hollows OCCT can't make come back (they died in OCCT's shape healing)")


# --- offset_shape --------------------------------------------------------------------------------

func _offsets() -> void:
	# Never empty, flat or inside out as done.
	for c in [["fillet", 20.0, 0, -1.0, 1.0], ["fillet", 20.0, 0, -2.0, 1.0], ["box", 39.0, 0, -11.7], ["box", 40.0, 0, -12.0]]:
		var a := body(c[0], c[1], c[2], c[4] if c.size() > 4 else 0.0)
		var t0 := Time.get_ticks_msec()
		var out = kernel.offset_shape(a, float(c[3]) / 1000.0)
		check(Time.get_ticks_msec() - t0 < CALL_MS, "Offsetting the %s by %s mm took too long." % [name_of(c[0], c[1], c[2]), c[3]])
		check(out == null and str(kernel.get_last_error()).length() > 20, "The offset of the %s by %s mm can't be made and should be refused with a reason (got %s)." % [name_of(c[0], c[1], c[2]), c[3], "volume %s, %d faces" % [out.volume(), out.face_count()] if out != null else kernel.get_last_error()])
	var sphere: RefCounted = kernel.make_sphere(0.0005, Vector3.ZERO)
	var inside_out = kernel.offset_shape(sphere, -0.0006)
	check(inside_out == null and str(kernel.get_last_error()) != "", "A 1 mm sphere offset in by 0.6 mm should be refused (got volume %s)." % (inside_out.volume() if inside_out != null else 0.0))
	# Offsets that can be made still are, and lie the distance off.
	var box := body("box", 20.0, 0)
	var shrunk = kernel.offset_shape(box, -0.001)
	check(shrunk != null and absf(shrunk.volume() - 0.018 * 0.012 * 0.008) < 1e-12, "A 20 mm box offset in by 1 mm should be the 18 x 12 x 8 mm box (%s)." % (shrunk.volume() if shrunk != null else kernel.get_last_error()))
	for c in [["box", 20.0, 1, 1.0], ["L", 40.0, 0, -0.8], ["L", 40.0, 0, 2.0], ["cham", 20.0, 1, -0.5, 1.0], ["fillet", 20.0, 1, 1.0, 1.0]]:
		var a := body(c[0], c[1], c[2], c[4] if c.size() > 4 else 0.0)
		var d := float(c[3]) / 1000.0
		var out = kernel.offset_shape(a, d)
		check(out != null, "The %s should offset by %s mm (%s)." % [name_of(c[0], c[1], c[2]), c[3], kernel.get_last_error()])
		if out == null:
			continue
		check(out.volume() > 0.0 and (out.volume() < a.volume()) == (d < 0.0), "The offset of the %s by %s mm has volume %s (body %s)." % [name_of(c[0], c[1], c[2]), c[3], out.volume(), a.volume()])
		var w := wall_distances(out, a, null, absf(d), 0.0)
		check(int(w.n) > 20 and float(w.lowest) > 0.97 and float(w.highest) < 1.03, "The offset of the %s by %s mm should lie the distance off (%d points, %.3f to %.3f of it)." % [name_of(c[0], c[1], c[2]), c[3], w.n, w.lowest, w.highest])
		if d < 0.0:
			check(outside_count(w.wall, a, absf(d)) == 0, "The offset of the %s in by %s mm lies partly outside the body." % [name_of(c[0], c[1], c[2]), -d * 1000.0])
	checked.append("offset_shape refuses collapsed offsets with a reason and builds the rest the distance off")


# --- Shells with an open face --------------------------------------------------------------------

func _open_shells() -> void:
	# [kind, size mm, rot, param mm, t mm]: every one of these can be made, and now is.
	var cases := [["cham", 20.0, 0, 1.0, 0.5], ["cham", 20.0, 1, 1.0, 0.5], ["cham", 20.0, 1, 1.0, 2.0], ["vround", 20.0, 1, 3.0, 1.0], ["hole", 20.0, 1, 1.0, 1.0], ["L", 40.0, 1, 0.0, 1.0], ["box", 20.0, 1, 0.0, 1.0]]
	var built := 0
	for c in cases:
		var a := body(c[0], c[1], c[2], c[3])
		var label := name_of(c[0], c[1], c[2])
		var t := float(c[4]) / 1000.0
		var up := up_of(c[2])
		var open := PackedInt32Array()
		var keep := []
		var open_faces := []
		for f in a.face_count():
			var info: Dictionary = a.face_info(f)
			if info.get("planar", false) and (info.normal as Vector3).dot(up) > 0.9999:
				open.append(f)
				open_faces.append(a.face_shape(f))
			else:
				keep.append(a.face_shape(f))
		var t0 := Time.get_ticks_msec()
		var out = kernel.shell(a, open, {"thickness": t})
		var ms := Time.get_ticks_msec() - t0
		check(ms < CALL_MS, "The %s shell open at the top at %s mm took %d ms." % [label, c[4], ms])
		check(out != null, "The %s shell open at the top at %s mm can be made and should be (%s)." % [label, c[4], kernel.get_last_error()])
		if out == null:
			continue
		built += 1
		check(out.solid_count() == 1 and out.volume() > 0.02 * a.volume() and out.volume() < a.volume(), "The %s shell open at the top at %s mm has %d solids and volume %s (body %s)." % [label, c[4], out.solid_count(), out.volume(), a.volume()])
		# The opening is open: a ball a half wall under each open face's middle isn't in it.
		for f in open:
			var info: Dictionary = a.face_info(f)
			var ball: RefCounted = kernel.make_sphere(0.2 * t, (info.point as Vector3) - (info.normal as Vector3) * (0.5 * t))
			var inside = kernel.boolean(ball, out, 2)
			check(inside == null or inside.volume() < 0.01 * ball.volume(), "The %s shell open at the top at %s mm has its opening closed over." % [label, c[4]])
		var w := wall_distances(out, kernel.make_compound(keep), kernel.make_compound(open_faces), t, 1.02 * t)
		check(int(w.n) > 0 and float(w.lowest) > 0.97, "The %s shell open at the top at %s mm has its inner wall %.3f walls from the outside (%d points)." % [label, c[4], w.lowest, w.n])
		check(outside_count(w.wall, a, t) == 0, "The %s shell open at the top at %s mm has its inner wall outside the body." % [label, c[4]])
	checked.append("%d shells open at the top (chamfered, rounded, holed, L) are one solid inside the body, open, with walls a wall in" % built)


# --- A spline-walled prism open at the top --------------------------------------------------------

func _spline_shells() -> void:
	var shoe := PackedVector2Array()
	for q in [Vector2(0, 0), Vector2(5, -6), Vector2(10, 0), Vector2(10, 8), Vector2(8, 8.5), Vector2(7.5, 1), Vector2(5, -2.5), Vector2(2.5, 1), Vector2(2, 8.5), Vector2(0, 8)]:
		shoe.append(q / 1000.0)
	var face: RefCounted = null
	for region in kernel.sketch_regions([{"type": "interp", "points": shoe, "periodic": true}], Transform3D.IDENTITY, 0.0):
		if absf(float(region.area) * 1e6 - 92.39) < 0.2:
			face = region.face
	check(face != null, "The horseshoe region should be found.")
	if face == null:
		return
	var prism: RefCounted = kernel.extrude(face, {"direction": Vector3(0, 0, 1), "distance": 0.01})
	var top := -1
	var keep := []
	for f in prism.face_count():
		var info: Dictionary = prism.face_info(f)
		if str(info.type) == "plane" and (info.normal as Vector3).z > 0.99:
			top = f
		else:
			keep.append(prism.face_shape(f))
	for t_mm in [0.2, 0.5]:
		var t: float = t_mm / 1000.0
		var t0 := Time.get_ticks_msec()
		var out = kernel.shell(prism, PackedInt32Array([top]), {"thickness": t})
		var ms := Time.get_ticks_msec() - t0
		check(ms < CALL_MS, "The horseshoe shell at %s mm took %d ms." % [t_mm, ms])
		check(out != null, "The horseshoe prism open at the top can be shelled %s mm and should be (%s)." % [t_mm, kernel.get_last_error()])
		if out == null:
			continue
		# A wall thick round its 636 mm2 side and over its 92 mm2 floor (less inside the bends).
		var about := 728e-6 * t
		check(out.solid_count() == 1 and out.face_count() == 5 and out.volume() > 0.85 * about and out.volume() < 1.02 * about, "The horseshoe shell at %s mm has %d solids, %d faces, volume %s." % [t_mm, out.solid_count(), out.face_count(), out.volume()])
		var w := wall_distances(out, kernel.make_compound(keep), prism.face_shape(top), t, 1.02 * t)
		check(int(w.n) > 20 and float(w.lowest) > 0.97, "The horseshoe shell at %s mm has its inner wall %.3f walls from the outside (%d points)." % [t_mm, w.lowest, w.n])
		check(outside_count(w.wall, prism, t) == 0, "The horseshoe shell at %s mm has its inner wall outside the body." % t_mm)
	checked.append("a horseshoe prism open at the top shells with its walls a wall in")


# --- Closed hollows ------------------------------------------------------------------------------

func _closed_shells() -> void:
	# [kind, size mm, rot, t mm]: OCCT's offset gets these wrong at the first try (or made none).
	var cases := [["L", 40.0, 0, 0.5], ["L", 40.0, 0, 0.8], ["L", 40.0, 1, 0.5], ["L", 30.0, 2, 0.5], ["L", 30.0, 2, 1.0], ["L", 30.0, 2, 2.5], ["L", 4.0, 1, 0.05], ["L", 4.0, 1, 0.08], ["union", 20.0, 0, 1.0]]
	var built := 0
	for c in cases:
		var a := body(c[0], c[1], c[2])
		var label := name_of(c[0], c[1], c[2])
		var t := float(c[3]) / 1000.0
		var t0 := Time.get_ticks_msec()
		var out = kernel.shell(a, PackedInt32Array(), {"thickness": t})
		var ms := Time.get_ticks_msec() - t0
		check(ms < CALL_MS, "Hollowing the %s at %s mm took %d ms." % [label, c[3], ms])
		check(out != null, "The %s hollow at %s mm can be made and should be (%s)." % [label, c[3], kernel.get_last_error()])
		if out == null:
			continue
		built += 1
		check(out.solid_count() == 1 and out.volume() > 0.0 and out.volume() < a.volume(), "The %s hollow at %s mm has %d solids and volume %s." % [label, c[3], out.solid_count(), out.volume()])
		var w := wall_distances(out, a, null, t, 0.0)
		check(int(w.n) > 20 and float(w.lowest) > 0.97 and float(w.highest) < 1.03, "The %s hollow at %s mm has its inner wall %.3f to %.3f walls from the outside (%d points)." % [label, c[3], w.lowest, w.highest, w.n])
		check(outside_count(w.wall, a, t) == 0, "The %s hollow at %s mm has its inner wall outside the body." % [label, c[3]])
	# A sphere cut by a cube: OCCT's offset makes nothing at any wall. Refused, saying so.
	var sb := body("spherebox", 20.0, 0)
	var t1 := Time.get_ticks_msec()
	var refused = kernel.shell(sb, PackedInt32Array(), {"thickness": 0.001})
	check(Time.get_ticks_msec() - t1 < CALL_MS, "Hollowing the sphere cut by a cube took too long.")
	if refused == null:
		var err := str(kernel.get_last_error())
		check(err.contains("geometry kernel") and not err.contains("thinner"), "The refusal of the sphere cut by a cube should say the kernel couldn't make it, not ask for a thinner wall (%s)." % err)
	else:
		var w := wall_distances(refused, sb, null, 0.001, 0.0)
		check(float(w.lowest) > 0.97 and float(w.highest) < 1.03, "The sphere cut by a cube hollow at 1 mm has its inner wall %.3f to %.3f walls from the outside." % [w.lowest, w.highest])
	checked.append("%d hollows of L brackets and a box with a sphere OCCT's offset first got wrong are built a wall in; the sphere cut by a cube is refused honestly" % built)
