extends SceneTree
## Regression checks for shells, hollows and offsets that came back wrong with no warning, or were
## refused for a false reason, headless, each call bounded in time:
## - A chamfered box's open shell, closed hollow and inward offset: OCCT's offset kept the box's
##   corners where a chamfer's corner face shrinks away in the wall and joined them to edges a
##   sixth of the wall off, so the body's faces held 4 to 120 % more than an exact wall (slivers of
##   material in the hollow) while its mesh, which every wall check measured, looked right. They
##   must match the exact walls (the body less the solid behind every kept face's plane a wall in),
##   with the faces' and the mesh's volumes agreeing.
## - A box open at the top and a side left a bar the wall's section along the edge where the two
##   openings meet; an L-shaped bracket open at two faces that meet inward left a round post in the
##   opening (the closed hollow's wall along that edge, under no kept face).
## - An L-shaped bracket open at both top faces had a rim whose mesh covered the opening, so the
##   mesh shown and exported held twice the body's volume.
## - A box shelled outward at under 1 mm was refused for "an outer wall within 0 mm of the outside"
##   at the opening's corner (OCCT's thick solid there has no rim, its walls running up to the
##   opening's corners): outward and both-way shells of flat-faced boxes are built exactly, and a
##   refusal elsewhere says what went wrong.
## - The refusal of a hollow OCCT's offset can't make doesn't promise another thickness works.

const REGEN := preload("res://addons/holo_forge/core/regen.gd")

## Each call must return within this (they return in well under a second).
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
		_chamfered_open()
		_chamfered_closed()
		_side_by_side_openings()
		_rim_mesh()
		_outward()
		_refusal_wording()
	else:
		print("note: CadKernel is not loaded; the native checks are skipped")
	if failures.is_empty():
		print("PASS holo_forge_shell_exact_regress: ", ", ".join(checked))
		quit(0)
	else:
		print("FAIL holo_forge_shell_exact_regress")
		for f in failures:
			print("  ", f)
		quit(1)


# --- Bodies --------------------------------------------------------------------------------------

func _placement(size_mm: float, rot: int) -> Transform3D:
	var s := size_mm / 2000.0
	if rot == 1:
		return Transform3D(Basis(Vector3(1, 2, 3).normalized(), 0.4), Vector3(0.1, 0.2, 0.3) * s)
	if rot == 2:
		return Transform3D(Basis(Vector3(-3, 1, 0.5).normalized(), 1.1), Vector3(-0.7, 0.4, 0.2) * s)
	return Transform3D.IDENTITY


## A box size x 0.7 size x 0.5 size mm, every edge chamfered by chamfer mm (none when 0), turned
## by rot (0 none; 1 and 2 placements where no face lines up with an axis).
func box(size_mm: float, rot: int, chamfer := 0.0) -> RefCounted:
	var S := size_mm / 1000.0
	var b: RefCounted = kernel.make_box(Vector3(S, S * 0.7, S * 0.5), Vector3.ZERO)
	if chamfer > 0.0:
		var all := PackedInt32Array()
		for e in b.edge_count():
			all.append(e)
		b = kernel.chamfer(b, all, {"distance": chamfer / 1000.0})
	return b if rot == 0 or b == null else kernel.transform_shape(b, _placement(size_mm, rot))


## The verifiers' L-shaped bracket: the box less a block 0.6 x 0.5 of it out of a corner.
func bracket(size_mm: float, rot: int) -> RefCounted:
	var S := size_mm / 1000.0
	var b: RefCounted = kernel.make_box(Vector3(S, S * 0.7, S * 0.5), Vector3.ZERO)
	b = kernel.boolean(b, kernel.make_box(Vector3(S * 0.6, S * 0.5, S), Vector3(S * 0.4, S * 0.2, -S * 0.2)), 1)
	return b if rot == 0 or b == null else kernel.transform_shape(b, _placement(size_mm, rot))


## The flat faces of a whose outward normal is within a hair of one of dirs.
func faces_facing(a: RefCounted, dirs: Array) -> PackedInt32Array:
	var out := PackedInt32Array()
	for f in a.face_count():
		var info: Dictionary = a.face_info(f)
		if not info.get("planar", false):
			continue
		for d in dirs:
			if (info.normal as Vector3).dot(d) > 0.9999:
				out.append(f)
				break
	return out


# --- Measures ------------------------------------------------------------------------------------

## The solid behind every flat face of a convex body a (but those in skip) with its plane moved out
## by offset (in when negative): the exact wall reference, from boxes far larger than the body.
func behind_planes(a: RefCounted, offset: float, skip := PackedInt32Array()) -> RefCounted:
	var centre: Vector3 = a.bbox().get_center()
	var L: float = 8.0 * a.bbox().size.length() + 8.0 * absf(offset)
	var region: RefCounted = null
	for f in a.face_count():
		if skip.has(f):
			continue
		var info: Dictionary = a.face_info(f)
		var n: Vector3 = (info.normal as Vector3).normalized()
		if n.dot((info.point as Vector3) - centre) < 0.0:
			n = -n
		var z := -n
		var x := z.cross(Vector3(0.3, 0.5, 0.7).normalized()).normalized()
		var y := z.cross(x)
		var on: Vector3 = (info.point as Vector3) + n * offset
		var over := centre + n * n.dot(on - centre)
		var half: RefCounted = kernel.transform_shape(kernel.make_box(Vector3(L, L, L), Vector3(-L / 2, -L / 2, 0)), Transform3D(Basis(x, y, z), over))
		region = half if region == null else kernel.boolean(region, half, 2)
		if region == null:
			return null
	return region


## The volume a's tessellation encloses (within deflection d), as the mesh shown and exported has it.
func mesh_volume(a: RefCounted, d: float) -> float:
	var t: Dictionary = a.tessellate(d, 0.1)
	if not t.has("positions"):
		return NAN
	var p: PackedVector3Array = t.positions
	var idx: PackedInt32Array = t.indices
	var c: Vector3 = a.bbox().get_center()
	var v := 0.0
	for k in range(0, idx.size(), 3):
		var u := p[idx[k]] - c
		var w := p[idx[k + 1]] - c
		var q := p[idx[k + 2]] - c
		v += u.dot(w.cross(q))
	# (Godot's triangles wind clockwise seen from outside.)
	return -v / 6.0


## The farthest an edge of a ends from its nearest corner.
func edge_gap(a: RefCounted) -> float:
	var corners := PackedVector3Array()
	for v in a.vertex_count():
		corners.append(a.vertex_position(v))
	var worst := 0.0
	for e in a.edge_count():
		var info: Dictionary = a.edge_info(e)
		for key in ["start", "end"]:
			if not info.has(key):
				continue
			var best := INF
			for q in corners:
				best = minf(best, (info[key] as Vector3).distance_to(q))
			worst = maxf(worst, best)
	return worst


## How much of a ball of radius r about q lies in a.
func ball_in(a: RefCounted, q: Vector3, r: float) -> float:
	var ball: RefCounted = kernel.make_sphere(r, q)
	var c = kernel.boolean(ball, a, 2)
	return (c.volume() if c != null else 0.0) / ball.volume()


## Checks out (made with a wall t from a, label naming it) is one solid whose faces and mesh hold
## the same volume (within a 200th of its area times the wall) and whose edges end at its corners;
## and, when exact isn't NAN, that it holds exact (within a 1000th).
func check_sound(out: RefCounted, t: float, exact: float, label: String) -> void:
	var vb: float = out.volume()
	var vm := mesh_volume(out, maxf(t / 50.0, 5e-7))
	check(out.solid_count() == 1, "%s came out as %d solids." % [label, out.solid_count()])
	check(absf(vb - vm) <= 0.005 * out.area() * t, "%s: its faces hold %s m3 but its mesh %s m3 (%.1f%% of its area times the wall)." % [label, vb, vm, 100.0 * absf(vb - vm) / (out.area() * t)])
	check(edge_gap(out) <= 0.02 * t, "%s has edges ending %.3f walls from their corners." % [label, edge_gap(out) / t])
	if not is_nan(exact):
		check(absf(vb - exact) <= 1e-3 * exact, "%s holds %s m3, the exact wall %s m3 (%+.2f%%)." % [label, vb, exact, 100.0 * (vb - exact) / exact])


func timed_shell(a: RefCounted, open: PackedInt32Array, t: float, direction: String, label: String) -> RefCounted:
	var t0 := Time.get_ticks_msec()
	var out = kernel.shell(a, open, {"thickness": t, "direction": direction})
	var ms := Time.get_ticks_msec() - t0
	check(ms < CALL_MS, "%s took %d ms." % [label, ms])
	return out


# --- Chamfered boxes -----------------------------------------------------------------------------

func _chamfered_open() -> void:
	var n := 0
	# [size mm, rot, chamfer mm, walls mm]
	for c in [[20.0, 0, 1.0, [0.5, 1.0, 2.0]], [20.0, 1, 1.0, [0.5, 1.0, 2.0]], [100.0, 2, 2.5, [1.0, 4.0]]]:
		var a := box(c[0], c[1], c[2])
		var top := faces_facing(a, [_placement(c[0], c[1]).basis * Vector3.UP])
		check(top.size() == 1, "The chamfered box's top face should be found.")
		for t_mm in c[3]:
			var t: float = t_mm / 1000.0
			var label := "The %s mm box chamfered %s mm (rot %d) open at the top, %s mm" % [c[0], c[2], c[1], t_mm]
			var out := timed_shell(a, top, t, "inside", label)
			check(out != null, "%s should be built (%s)." % [label, kernel.get_last_error()])
			if out == null:
				continue
			var ideal: RefCounted = kernel.boolean(a, behind_planes(a, -t, top), 1)
			check_sound(out, t, ideal.volume() if ideal != null else NAN, label)
			n += 1
	checked.append("%d chamfered boxes open at the top match the exact walls" % n)


func _chamfered_closed() -> void:
	var n := 0
	# [size mm, rot, chamfer mm, wall mm]: closed hollows and inward offsets.
	for c in [[4.0, 1, 0.1, 0.04], [4.0, 0, 0.4, 0.1], [20.0, 1, 1.0, 1.0], [100.0, 1, 2.5, 1.0], [300.0, 2, 5.0, 4.0]]:
		var a := box(c[0], c[1], c[2])
		var t: float = c[3] / 1000.0
		var inner := behind_planes(a, -t)
		var label := "The %s mm box chamfered %s mm (rot %d) hollowed %s mm" % [c[0], c[2], c[1], c[3]]
		var out := timed_shell(a, PackedInt32Array(), t, "inside", label)
		check(out != null, "%s should be built (%s)." % [label, kernel.get_last_error()])
		if out != null and inner != null:
			check_sound(out, t, a.volume() - inner.volume(), label)
		label = "The %s mm box chamfered %s mm (rot %d) offset in by %s mm" % [c[0], c[2], c[1], c[3]]
		var t0 := Time.get_ticks_msec()
		var off = kernel.offset_shape(a, -t)
		check(Time.get_ticks_msec() - t0 < CALL_MS, "%s took %d ms." % [label, Time.get_ticks_msec() - t0])
		check(off != null, "%s should be built (%s)." % [label, kernel.get_last_error()])
		if off != null and inner != null:
			check_sound(off, t, inner.volume(), label)
		n += 1
	checked.append("%d chamfered boxes' closed hollows and inward offsets are the exact walls" % n)


# --- Openings side by side ------------------------------------------------------------------------

func _side_by_side_openings() -> void:
	var n := 0
	# A box open at the top and at +x: the walls left are the bottom, -x, front and back.
	for c in [[20.0, 0, 1.0], [20.0, 1, 0.5], [100.0, 2, 1.0], [4.0, 1, 0.1]]:
		var S: float = c[0] / 1000.0
		var t: float = c[2] / 1000.0
		var xf := _placement(c[0], c[1])
		var a := box(c[0], c[1])
		var open := faces_facing(a, [xf.basis * Vector3.UP, xf.basis * Vector3.RIGHT])
		var label := "The %s mm box (rot %d) open at the top and a side, %s mm" % [c[0], c[1], c[2]]
		var out := timed_shell(a, open, t, "inside", label)
		check(out != null, "%s should be built (%s)." % [label, kernel.get_last_error()])
		if out == null:
			continue
		var exact: float = a.volume() - (S - t) * (0.7 * S - t) * (0.5 * S - 2.0 * t)
		check_sound(out, t, exact, label)
		# Nothing along the edge where the openings meet, half a wall in from both.
		var edge_mid: Vector3 = xf * Vector3(S - 0.5 * t, 0.7 * S - 0.5 * t, 0.25 * S)
		check(ball_in(out, edge_mid, 0.3 * t) < 0.01, "%s has a bar along the edge where its openings meet." % label)
		n += 1
	# The bracket open at its lower top face and the +x face beside it (they meet outward); and at
	# all four faces facing up or +x, two of which meet inward (built without the post along that
	# edge, or refused).
	for t_mm in [0.5, 1.0]:
		var t: float = t_mm / 1000.0
		var a := bracket(20.0, 0)
		var low := PackedInt32Array()
		for f in faces_facing(a, [Vector3.UP, Vector3.RIGHT]):
			var p: Vector3 = a.face_info(f).point
			if p.y < 0.005 or p.x > 0.019:
				low.append(f)
		var label := "The 20 mm bracket open at its lower top and end faces, %s mm" % t_mm
		var out := timed_shell(a, low, t, "inside", label)
		check(out != null, "%s should be built (%s)." % [label, kernel.get_last_error()])
		if out != null:
			check_sound(out, t, NAN, label)
			check(ball_in(out, Vector3(0.020 - 0.5 * t, 0.004 - 0.5 * t, 0.005), 0.3 * t) < 0.01, "%s has a bar along the edge where its openings meet." % label)
			n += 1
		var all := faces_facing(a, [Vector3.UP, Vector3.RIGHT])
		label = "The 20 mm bracket open at all four faces facing up or along x, %s mm" % t_mm
		out = timed_shell(a, all, t, "inside", label)
		if out != null:
			check_sound(out, t, NAN, label)
			check(ball_in(out, Vector3(0.008 - 0.5 * t, 0.004 - 0.5 * t, 0.005), 0.3 * t) < 0.01, "%s has a post standing in its opening along the inward edge." % label)
		else:
			check(kernel.get_last_error() != "", "%s was refused without a reason." % label)
	checked.append("%d shells open at faces side by side have no bar or post left between the openings" % n)


# --- A rim's mesh --------------------------------------------------------------------------------

func _rim_mesh() -> void:
	var n := 0
	for c in [[100.0, 1, 1.0], [100.0, 0, 2.5], [20.0, 2, 0.5]]:
		var a := bracket(c[0], c[1])
		var t: float = c[2] / 1000.0
		var top := faces_facing(a, [_placement(c[0], c[1]).basis * Vector3.UP])
		check(top.size() == 2, "The bracket's two top faces should be found.")
		var label := "The %s mm bracket (rot %d) open at both top faces, %s mm" % [c[0], c[1], c[2]]
		var out := timed_shell(a, top, t, "inside", label)
		check(out != null, "%s should be built (%s)." % [label, kernel.get_last_error()])
		if out == null:
			continue
		check_sound(out, t, NAN, label)
		n += 1
	checked.append("%d brackets open at both top faces mesh as they are (no rim over an opening)" % n)


# --- Outward and both ways -----------------------------------------------------------------------

func _outward() -> void:
	var n := 0
	# A plain box outward: (L + 2t)(H + t)(W + 2t) less the box, the rim on the open face's plane.
	for c in [[20.0, 0], [20.0, 1], [100.0, 2]]:
		var S: float = c[0] / 1000.0
		var a := box(c[0], c[1])
		var top := faces_facing(a, [_placement(c[0], c[1]).basis * Vector3.UP])
		for t_mm in [0.1, 0.3, 0.5, 0.7, 1.0]:
			var t: float = t_mm / 1000.0
			var label := "The %s mm box (rot %d) shelled %s mm outward, open at the top" % [c[0], c[1], t_mm]
			var out := timed_shell(a, top, t, "outside", label)
			check(out != null, "%s should be built (%s)." % [label, kernel.get_last_error()])
			if out != null:
				check_sound(out, t, (S + 2.0 * t) * (0.7 * S + t) * (0.5 * S + 2.0 * t) - a.volume(), label)
				n += 1
	# A chamfered box outward and both ways: the exact walls (out: behind the kept faces' planes a
	# wall out and the open face's own, less the body; both: the body grown half a wall less the
	# solid behind the kept faces' planes half a wall in).
	var a := box(20.0, 1, 1.0)
	var top := faces_facing(a, [_placement(20.0, 1).basis * Vector3.UP])
	var kept := PackedInt32Array()
	for f in a.face_count():
		if not top.has(f):
			kept.append(f)
	for t_mm in [0.5, 1.0, 2.0]:
		var t: float = t_mm / 1000.0
		var label := "The 20 mm box chamfered 1 mm (rot 1) shelled %s mm outward" % t_mm
		var out := timed_shell(a, top, t, "outside", label)
		check(out != null, "%s should be built (%s)." % [label, kernel.get_last_error()])
		if out != null:
			var grown: RefCounted = kernel.boolean(behind_planes(a, t, top), behind_planes(a, 0.0, kept), 2)
			check_sound(out, t, grown.volume() - a.volume() if grown != null else NAN, label)
			n += 1
		label = "The 20 mm box chamfered 1 mm (rot 1) shelled %s mm both ways" % t_mm
		out = timed_shell(a, top, t, "both", label)
		check(out != null, "%s should be built (%s)." % [label, kernel.get_last_error()])
		if out != null:
			var outer := behind_planes(a, 0.5 * t)
			var hollow := behind_planes(a, -0.5 * t, top)
			var cut: RefCounted = kernel.boolean(outer, hollow, 1) if outer != null and hollow != null else null
			check_sound(out, t, cut.volume() if cut != null else NAN, label)
			n += 1
	# A box with rounded upright edges outward at under 1 mm: built right, or refused for what
	# went wrong (not for a wall too close to the outside at the opening's corner).
	var S := 0.02
	var b: RefCounted = kernel.make_box(Vector3(S, S * 0.7, S * 0.5), Vector3.ZERO)
	var upright := PackedInt32Array()
	for e in b.edge_count():
		var info: Dictionary = b.edge_info(e)
		if absf(((info.end as Vector3) - (info.start as Vector3)).normalized().y) > 0.9:
			upright.append(e)
	var rounded: RefCounted = kernel.fillet(b, upright, {"radius": 0.003})
	var rtop := faces_facing(rounded, [Vector3.UP])
	for t_mm in [0.5, 1.0]:
		var t: float = t_mm / 1000.0
		for direction in ["outside", "both"]:
			var label := "The 20 mm box with 3 mm upright rounds shelled %s mm %s" % [t_mm, direction]
			var out := timed_shell(rounded, rtop, t, direction, label)
			if out != null:
				check_sound(out, t, NAN, label)
			else:
				var why: String = kernel.get_last_error()
				check(why != "" and not why.contains("bends too tightly"), "%s was refused for a false reason ('%s')." % [label, why])
	checked.append("%d outward and both-way shells of flat-faced boxes are exact (under 1 mm too)" % n)


# --- Refusal wording -----------------------------------------------------------------------------

func _refusal_wording() -> void:
	# A sphere cut by a cube: OCCT's offset makes no inner wall at any wall; the refusal mustn't say
	# another thickness may work.
	var S := 0.02
	var a: RefCounted = kernel.boolean(kernel.make_sphere(S / 2.0, Vector3.ZERO), kernel.make_box(Vector3(S, S, S) * 0.75, Vector3(-0.375, -0.375, -0.375) * S), 2)
	for t_mm in [1.0, 2.5]:
		var label := "The sphere cut by a cube hollowed %s mm" % t_mm
		var out := timed_shell(a, PackedInt32Array(), t_mm / 1000.0, "inside", label)
		if out != null:
			check_sound(out, t_mm / 1000.0, NAN, label)
		else:
			var why: String = kernel.get_last_error()
			check(why != "" and not why.ends_with("another thickness may work"), "%s was refused promising another thickness works ('%s')." % [label, why])
	checked.append("a hollow the kernel can't make is refused without promising another thickness works")
