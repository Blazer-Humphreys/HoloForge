extends SceneTree
## Regression checks for the Phase 6 review findings (geometry, tools, storage), headless:
## - Converted bodies with extraordinary vertices are C1 inside every face, so they offset, shell
##   hollow and fillet a creased loop; no seam stays C0 (triangle caps included).
## - A small converted body's fillets and chamfers end, built or refused with a reason, within
##   seconds (their tolerances never go below OCCT's Precision::Confusion).
## - G1 across the faces' seams at isolation 6, per valence (the limits are twice the jumps
##   measured 2026-10-30: valence 3 0.016, valence 5 0.049, valence 8 0.19 degrees).
## - Non-finite positions, flat cages, pinched vertices and touching self-intersections are
##   refused or reported; face coordinates outside a face are refused; face_grid of a trapezoid
##   stays on the face; warnings carry their numbers; a coarse ray hit is refined to the surface.
## - Symmetry: soft modification moves the selection by the full drag, whole-body moves carry the
##   planes and axes (a skewing scale is refused), both sides picked follow the first, zero-
##   distance extends and unwelds keep partners in their own piece, Subdivide Specify, Insert
##   Edge at 0.5 beside a self-symmetric face, symmetric Reduced Star fallback.
## - Primitive counts and symmetry fit are checked; Smooth with nothing to move reports it;
##   Thicken along an axis goes along it; cages round-trip a text resource exactly.

const CAGE := preload("res://addons/holo_forge/core/form/cage.gd")
const FORM_OPS := preload("res://addons/holo_forge/core/form/form_ops.gd")
const PRIMITIVES := preload("res://addons/holo_forge/core/form/primitives.gd")
const FORM := preload("res://addons/holo_forge/core/features/form.gd")
const FORM_TOOLS := preload("res://addons/holo_forge/ui/form_tools.gd")
const DOCUMENT := preload("res://addons/holo_forge/core/document.gd")
const REGEN := preload("res://addons/holo_forge/core/regen.gd")

## Largest normal jump across B-rep seams at isolation 6 per vertex valence (degrees).
## A 20 mm form body (a reviewer's edited box: extruded faces, a creased rim, n-gons and a
## triangle) whose converted B-rep is 35 mm across. Before the fix its single-edge fillets at 1 mm
## never finished: the fillet's tolerances, a fraction of the body's size, fell below OCCT's
## Precision::Confusion and ChFi3d's marching never met them.
const SMALL_CAGE := """{ "corner_weights": PackedFloat32Array(), "corners": PackedInt32Array(), "crease_edges": PackedInt32Array(17, 18, 17, 20, 18, 19, 19, 22, 20, 23, 22, 25, 23, 24, 24, 25), "crease_weights": PackedFloat32Array(10, 10, 10, 10, 10, 10, 10, 10), "face_counts": PackedInt32Array(4, 4, 4, 4, 4, 4, 4, 5, 5, 4, 4, 5, 4, 4, 5, 4, 4, 4, 4, 4, 4, 4, 5, 4, 4, 4, 4, 3, 4, 4), "face_indices": PackedInt32Array(2, 5, 13, 11, 5, 8, 16, 13, 11, 13, 22, 19, 0, 28, 32, 31, 28, 9, 29, 32, 31, 32, 30, 3, 32, 29, 12, 30, 9, 17, 20, 12, 29, 3, 30, 12, 14, 6, 12, 20, 23, 14, 6, 14, 15, 7, 14, 23, 24, 26, 15, 26, 24, 25, 27, 27, 16, 15, 26, 0, 1, 10, 9, 28, 1, 2, 11, 10, 9, 10, 18, 17, 10, 11, 19, 18, 17, 18, 21, 20, 18, 19, 22, 21, 20, 21, 24, 23, 21, 22, 25, 24, 0, 31, 3, 4, 1, 3, 6, 7, 4, 1, 4, 5, 2, 4, 7, 8, 5, 7, 15, 16, 8, 27, 25, 33, 13, 16, 27, 22, 22, 27, 33, 25), "frozen": PackedInt32Array(), "links": [], "positions": PackedFloat64Array(-0.01, -0.01, -0.01, 0, -0.01, -0.01, 0.01, -0.01, -0.01, -0.01, 0, -0.01, 0, 0, -0.01, 0.01, 0, -0.01, -0.01, 0.01, -0.01, 0, 0.01, -0.01, 0.01, 0.01, -0.01, -0.01, -0.01, 0, 0, -0.01, 0, 0.01, -0.01, 0, -0.01, 0, 0, 0.01, 0, 0, -0.01, 0.01, 0, 0, 0.01, 0, 0.01, 0.01, 0, -0.01, -0.01, 0.01, 0, -0.01, 0.01, 0.01, -0.01, 0.01, -0.01, 0, 0.01, 0, 0, 0.011999999776482582, 0.01, 0, 0.01, -0.01, 0.01, 0.01, 0, 0.01, 0.009249999793246389, 0.01, 0.01, 0.009249999793246389, 0, 0.01, 0.006999999843537807, 0.01, 0.01, 0.006999999843537807, -0.01, -0.01, -0.005, -0.01, -0.005, 0, -0.01, 0, -0.005, -0.01, -0.005, -0.01, -0.01, -0.005, -0.005, 0.01, 0.008999999798834323, 0.007406249834457412), "sym_isolated": PackedInt32Array(), "symmetry": [], "version": 1 }"""
## The longest a single fillet or chamfer of that body may take (they take about 0.2 s).
const SMALL_BLEND_MS := 5000
const G1_LIMITS := {"cube (valence 3)": 0.03, "prism 5 (valence 5)": 0.10, "sphere 8x4 (valence 8)": 0.38}

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
		_native()
		_small_body_blends()
	else:
		print("note: CadSubD is not loaded; the native checks are skipped")
	_symmetry_tools()
	_other_tools()
	_text_round_trip()
	if failures.is_empty():
		print("PASS holo_forge_form_fix: ", ", ".join(checked))
		quit(0)
	else:
		print("FAIL holo_forge_form_fix")
		for f in failures:
			print("  ", f)
		quit(1)


# --- Small converted body: fillets and chamfers end -----------------------------------------------

## Every sharp edge of the small converted body fillets and chamfers at 0.5, 1 and 2 mm (a few
## chamfers at 2 mm are refused), all of them at once at 1 mm, and 4 mm is refused with a reason:
## each within SMALL_BLEND_MS, so none can freeze the editor.
func _small_body_blends() -> void:
	var sc := subd(str_to_var(SMALL_CAGE))
	var shapes: Array = sc.to_shapes({"isolation": 6})
	if shapes.size() != 1:
		check(false, "The small form body should convert to one body (%d)." % shapes.size())
		return
	var shape: RefCounted = shapes[0]
	var sharp := PackedInt32Array()
	for e in shape.edge_count():
		if float((shape.edge_info(e) as Dictionary).get("dihedral", 0.0)) > 0.5:
			sharp.append(e)
	check(sharp.size() >= 8, "The small converted body should have its creased edges (%d)." % sharp.size())
	var worst := 0
	var built := {"fillet": 0, "chamfer": 0}
	for op in ["fillet", "chamfer"]:
		for r in [0.0005, 0.001, 0.002, 0.004]:
			for e in sharp:
				var t0 := Time.get_ticks_msec()
				var out: RefCounted = kernel.call(op, shape, PackedInt32Array([e]), {"radius": r} if op == "fillet" else {"distance": r})
				var ms := Time.get_ticks_msec() - t0
				worst = maxi(worst, ms)
				check(ms < SMALL_BLEND_MS, "A %s of edge %d at %.1f mm should end in time (%d ms)." % [op, e, r * 1000.0, ms])
				if out != null:
					built[op] += 1
					# Built means sound: one closed solid with a volume above 0 inside the body's
					# box (a 4 mm chamfer of edge 91 once 'built' an open shell of volume 0).
					var a: AABB = shape.bbox().grow(0.0002)
					var b: AABB = out.bbox()
					check(out.solid_count() == 1 and out.volume() > 0.0 and a.encloses(b), "A %s of edge %d at %.1f mm built a broken body (volume %s, box %s in %s)." % [op, e, r * 1000.0, out.volume(), b, a])
				elif r < 0.0015:
					check(false, "A %s of edge %d at %.1f mm should build (%s)." % [op, e, r * 1000.0, kernel.get_last_error()])
				else:
					check(str(kernel.get_last_error()) != "", "A refused %s of edge %d at %.1f mm should say why." % [op, e, r * 1000.0])
	var t1 := Time.get_ticks_msec()
	var together: RefCounted = kernel.fillet(shape, sharp, {"radius": 0.001})
	check(together != null and Time.get_ticks_msec() - t1 < SMALL_BLEND_MS, "All the small body's sharp edges should fillet at 1 mm together in time (%s, %d ms)." % [kernel.get_last_error(), Time.get_ticks_msec() - t1])
	checked.append("small converted body: %d single-edge fillets and %d chamfers at 0.5 to 4 mm built or refused, the slowest %d ms" % [built.fillet, built.chamfer, worst])


# --- Cages ---------------------------------------------------------------------------------------

func cage_from(points: Array, faces: Array) -> Dictionary:
	var pts := PackedVector3Array()
	for p in points:
		pts.append(Vector3(p[0], p[1], p[2]))
	return CAGE.from_vectors(pts, faces)


func cube() -> Dictionary:
	return cage_from([[-1, -1, -1], [1, -1, -1], [1, 1, -1], [-1, 1, -1], [-1, -1, 1], [1, -1, 1], [1, 1, 1], [-1, 1, 1]],
		[[0, 3, 2, 1], [4, 5, 6, 7], [0, 1, 5, 4], [1, 2, 6, 5], [2, 3, 7, 6], [3, 0, 4, 7]])


func prism(n: int) -> Dictionary:
	var pts := []
	for z in 2:
		for i in n:
			var a := TAU * i / float(n)
			pts.append([cos(a), sin(a), -1.0 if z == 0 else 1.0])
	var bottom := []
	var top := []
	for i in n:
		bottom.append(n - 1 - i)
		top.append(n + i)
	var faces := [bottom, top]
	for i in n:
		var j := (i + 1) % n
		faces.append([i, j, n + j, n + i])
	return cage_from(pts, faces)


func subd(c: Dictionary) -> RefCounted:
	var s: RefCounted = ClassDB.instantiate("CadSubD")
	s.set_cage(c)
	return s


func vertex_at(c: Dictionary, p: Vector3) -> int:
	for v in CAGE.vertex_count(c):
		if CAGE.position(c, v).distance_to(p) < 1e-6:
			return v
	return -1


func face_at(c: Dictionary, centre: Vector3) -> int:
	var best := -1
	var best_d := INF
	for f in CAGE.face_count(c):
		var s := Vector3.ZERO
		var fv := CAGE.face_vertices(c, f)
		for v in fv:
			s += CAGE.position(c, v)
		var d := (s / fv.size()).distance_to(centre)
		if d < best_d:
			best_d = d
			best = f
	return best


func mirror_x(c: Dictionary) -> Dictionary:
	return PRIMITIVES.primitive_symmetry(c, "mirror", Transform3D.IDENTITY, Vector3i(1, 0, 0), 0)


## Largest |T(p_v) - p_map[v]| over every entry, and how many vertices have no partner.
func symmetry_error(c: Dictionary) -> Array:
	var worst := 0.0
	var broken := 0
	for e in c.get("symmetry", []):
		var xf := FORM_OPS._entry_xf(e)
		var m: PackedInt32Array = e.map
		for v in m.size():
			if m[v] < 0:
				broken += 1
				continue
			var q := FORM_OPS.xf_apply(xf, CAGE.position_d(c, v)[0], CAGE.position_d(c, v)[1], CAGE.position_d(c, v)[2])
			var w := CAGE.position_d(c, m[v])
			worst = maxf(worst, Vector3(q[0] - w[0], q[1] - w[1], q[2] - w[2]).length())
	return [worst, broken]


# --- Native: conversion, checks, picking ------------------------------------------------------------

func _native() -> void:
	# C1 faces: offsets, a hollow shell and a creased-loop fillet of bodies with extraordinary vertices.
	var box := PRIMITIVES.box(Vector3.ONE * 0.02, Vector3i(2, 2, 2))
	var s := subd(box)
	var shape: RefCounted = s.to_shapes({"isolation": 6, "name_prefix": "b"})[0]
	var rep: Dictionary = s.get_last_report()
	check(int(rep.get("c0_knots", -1)) == 0, "A converted box 2,2,2 should have no C0 seam inside its faces (%s)." % rep.get("c0_knots"))
	var off_out = kernel.offset_shape(shape, 0.001)
	var off_in = kernel.offset_shape(shape, -0.001)
	check(off_out != null and off_in != null, "A converted box 2,2,2 should offset by +-1 mm (%s)." % kernel.get_last_error())
	var hollow = kernel.shell(shape, PackedInt32Array(), {"thickness": 0.001})
	check(hollow != null and hollow.volume() < shape.volume(), "A converted box 2,2,2 should shell hollow at 1 mm (%s)." % kernel.get_last_error())
	for cs in [["sphere 8x4", PRIMITIVES.sphere(0.02, 8, 4)], ["prism 3", prism(3)], ["cube", cube()]]:
		var sc := subd(cs[1])
		var shapes: Array = sc.to_shapes({"isolation": 6})
		check(shapes.size() == 1 and int(sc.get_last_report().get("c0_knots", -1)) == 0, "%s should convert with no C0 seam (%s)." % [cs[0], sc.get_last_report().get("c0_knots")])
		if cs[0] == "sphere 8x4" and shapes.size() == 1:
			check(kernel.offset_shape(shapes[0], 0.0005) != null, "A converted sphere 8x4 should offset (%s)." % kernel.get_last_error())
	# A fillet of a creased rim loop finishes quickly.
	var topo := CAGE.topology(box)
	var rim := PackedInt32Array()
	for e in topo.nE:
		var ab := topo.edge_vertices(e)
		var pa := CAGE.position(box, ab.x)
		var pb := CAGE.position(box, ab.y)
		if absf(pa.z - 0.01) < 1e-9 and absf(pb.z - 0.01) < 1e-9 and ((absf(absf(pa.x) - 0.01) < 1e-9 and absf(absf(pb.x) - 0.01) < 1e-9) or (absf(absf(pa.y) - 0.01) < 1e-9 and absf(absf(pb.y) - 0.01) < 1e-9)):
			rim.append(ab.x)
			rim.append(ab.y)
	var creased: Dictionary = FORM_OPS.crease(box, {"edges": rim}, {}).cage
	var cs2 := subd(creased)
	var cshape: RefCounted = cs2.to_shapes({"isolation": 6})[0]
	var sharp := PackedInt32Array()
	for e in cshape.edge_count():
		if float((cshape.edge_info(e) as Dictionary).get("dihedral", 0.0)) > 0.5:
			sharp.append(e)
	var t0 := Time.get_ticks_msec()
	var filleted = kernel.fillet_edges(cshape, sharp, 0.001)
	check(filleted != null and Time.get_ticks_msec() - t0 < 10000, "A creased rim loop of a converted box should fillet at 1 mm in bounded time (%s, %d ms)." % [kernel.get_last_error(), Time.get_ticks_msec() - t0])
	checked.append("converted bodies with extraordinary vertices C1 (offset +-1 mm, hollow shell, creased-loop fillet; no C0 seams in box, sphere, triangle caps)")
	# G1 per valence at isolation 6.
	var g1_cases := {"cube (valence 3)": cube(), "prism 5 (valence 5)": prism(5), "sphere 8x4 (valence 8)": PRIMITIVES.sphere(2.0, 8, 4)}
	var g1_text := PackedStringArray()
	for name in g1_cases:
		var gs := subd(g1_cases[name])
		var gshape: RefCounted = gs.to_shapes({"isolation": 6})[0]
		var jump := _max_seam_jump(gshape)
		g1_text.append("%s %.3f" % [name, jump])
		check(jump <= float(G1_LIMITS[name]), "The normal jump across seams of %s at isolation 6 should be at most %s degrees (%.4f)." % [name, G1_LIMITS[name], jump])
	checked.append("G1 at isolation 6 per valence (%s deg)" % ", ".join(g1_text))
	# Non-finite positions.
	var bad := cube()
	var p: PackedFloat64Array = bad.positions
	p[0] = NAN
	bad.positions = p
	var sn: RefCounted = ClassDB.instantiate("CadSubD")
	check(not sn.set_cage(bad) and str(sn.get_last_error()).contains("non-finite"), "set_cage should refuse a NaN coordinate (%s)." % sn.get_last_error())
	var chk: Dictionary = sn.check_cage(bad)
	check(not chk.ok and (chk.get("non_finite_vertices", PackedInt32Array()) as PackedInt32Array).has(0), "check_cage should list the non-finite vertex.")
	var sp := subd(cube())
	var pos: PackedFloat64Array = (cube().positions as PackedFloat64Array).duplicate()
	pos[4] = INF
	check(not sp.set_positions(pos) and str(sp.get_last_error()).contains("non-finite"), "set_positions should refuse an INF coordinate.")
	# A flat cage converts with a warning naming the problem.
	var flat := cube()
	var fp: PackedFloat64Array = flat.positions
	for v in 8:
		fp[3 * v + 2] = 0.0
	flat.positions = fp
	var sf := subd(flat)
	sf.to_shapes({})
	var frep: Dictionary = sf.get_last_report()
	var fw := ", ".join(frep.get("warnings", PackedStringArray()))
	check(fw.contains("no area") and fw.contains("no volume") and not (frep.get("problem_faces", PackedInt32Array()) as PackedInt32Array).is_empty(), "A flat cage should convert with warnings (%s)." % fw)
	# Touching self-intersection (a symmetric push-through) and an unwelded seam (not one).
	var g2 := PRIMITIVES.box(Vector3.ONE * 2.0, Vector3i(2, 2, 2))
	var g2p: PackedFloat64Array = g2.positions
	var top := vertex_at(g2, Vector3(0, 0, 1))
	g2p[3 * top + 2] = -1.8
	g2.positions = g2p
	var through: Dictionary = sn.check_cage(g2)
	check(not through.ok and not (through.self_intersecting_faces as PackedInt32Array).is_empty(), "check_cage should find a symmetric push-through whose crossings land on edges.")
	var split: Dictionary = FORM_OPS.unweld(PRIMITIVES.plane(Vector2(2, 2), Vector2i(2, 2)), {"edges": PackedInt32Array([1, 4, 4, 7])}, {}).cage
	var seam: Dictionary = sn.check_cage(split)
	check((seam.self_intersecting_faces as PackedInt32Array).is_empty(), "An unwelded seam (coincident vertices) is not a self-intersection (%s)." % [seam.self_intersecting_faces])
	# Crease, corner and topology reports.
	var odd := cube()
	odd.crease_edges = PackedInt32Array([0, 6])
	odd.crease_weights = PackedFloat32Array([10.0])
	odd.corners = PackedInt32Array([42])
	odd.corner_weights = PackedFloat32Array([10.0])
	var ochk: Dictionary = sn.check_cage(odd)
	var oerr := ", ".join(ochk.errors)
	check(not ochk.ok and oerr.contains("not a cage edge") and oerr.contains("out of range"), "check_cage should report a non-edge crease and a corner out of range (%s)." % oerr)
	var so: RefCounted = ClassDB.instantiate("CadSubD")
	check(so.set_cage(odd) and str(so.get_last_warning()).contains("Ignored"), "set_cage should say it dropped them (%s)." % so.get_last_warning())
	var empty_chk: Dictionary = sn.check_cage(CAGE.empty())
	check(not empty_chk.ok and str(empty_chk.errors).contains("empty"), "check_cage should report an empty cage.")
	checked.append("non-finite positions refused, flat cage warned, touching self-intersections found, seams not, crease/corner/empty reports")
	# Domain, warnings, face grid, coarse rays.
	var sd := subd(prism(5))
	check(sd.evaluate(PackedInt32Array([2]), PackedVector2Array([Vector2(1.5, 0.5)])).is_empty() and str(sd.get_last_error()).contains("outside face"), "evaluate should refuse a coordinate outside the face (%s)." % sd.get_last_error())
	check(sd.evaluate(PackedInt32Array([0]), PackedVector2Array([Vector2(2.75, 0.75)])).is_empty(), "evaluate should refuse a coordinate between an n-gon's sub-face tiles.")
	var sc := subd(cube())
	var targets := PackedFloat64Array()
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in 24:
		targets.append(rng.randf_range(-1.0, 1.0))
	sc.interpolate(targets)
	var warn := str(sc.get_last_warning())
	var number := RegEx.create_from_string("[0-9]\\.?[0-9]*(e-?[0-9]+)?")
	check(warn.contains("misses its targets") and number.search(warn) != null and not warn.contains("unsupported"), "The interpolate warning should carry its residual (%s)." % warn)
	var kbox = kernel.make_box(Vector3(2, 2, 2), Vector3(-1, -1, -1))
	var tool = kernel.make_box(Vector3(4, 4, 4), Vector3(0, -2, -2))
	tool = kernel.transform_shape(tool, Transform3D(Basis(Vector3(0, 0, 1), deg_to_rad(15.0)), Vector3(0.2, 0, 0)))
	var trap = kernel.boolean(kbox, tool, 1)
	var on_face := false
	if trap != null:
		for f in trap.face_count():
			var n: Vector3 = (trap.face_info(f) as Dictionary).get("normal", Vector3())
			if n.z > 0.99:
				var g: Dictionary = sd.face_grid(trap, f, 4, 4)
				var pts: PackedFloat64Array = g.get("positions", PackedFloat64Array())
				var q := PackedVector3Array()
				for i in pts.size() / 3:
					q.append(Vector3(pts[3 * i], pts[3 * i + 1], pts[3 * i + 2]))
				var pr: Dictionary = sd.project_to_shape(trap.face_shape(f), q)
				var worst := 0.0
				for d in pr.distances:
					worst = maxf(worst, d)
				on_face = g.ok and q.size() == 25 and worst <= 1e-9
				check(on_face, "face_grid samples of a trapezoid face should lie on the face (worst %s)." % worst)
	check(trap != null and on_face, "The trapezoid face should be found and sampled.")
	var rays_ok := true
	var creased_cube := cube()
	creased_cube.crease_edges = PackedInt32Array([5, 6])
	creased_cube.crease_weights = PackedFloat32Array([10.0])
	var fine := subd(creased_cube)
	fine.tessellate({"rate": 48})
	var coarse := subd(creased_cube)
	coarse.tessellate({"rate": 2})
	rng.seed = 3
	for i in 40:
		var dir := Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1)).normalized()
		var from := -dir * 5.0 + Vector3(rng.randf_range(-0.3, 0.3), rng.randf_range(-0.3, 0.3), rng.randf_range(-0.3, 0.3))
		var a: Dictionary = fine.ray_hit(from, dir)
		var b: Dictionary = coarse.ray_hit(from, dir)
		if bool(a.hit) and bool(b.hit) and absf(float(a.distance) - float(b.distance)) > 1e-6:
			rays_ok = false
	check(rays_ok, "A ray hit on a rate-2 (drag) tessellation should be refined onto the surface (within 1e-6 of a rate-48 hit).")
	checked.append("face coordinates outside a face refused, warnings with numbers, trapezoid face_grid on the face, coarse ray hits refined")


## Largest normal jump (degrees) across the faces' shared edges, sampled densely near the ends.
func _max_seam_jump(shape: RefCounted) -> float:
	var ts := [0.0005, 0.002, 0.005, 0.008, 0.012, 0.02, 0.05, 0.1, 0.3, 0.5, 0.7, 0.9, 0.95, 0.98, 0.988, 0.992, 0.995, 0.998, 0.9995]
	var worst := 0.0
	for e in shape.edge_count():
		var faces: PackedInt32Array = (shape.edge_info(e) as Dictionary).get("faces", PackedInt32Array())
		if faces.size() != 2:
			continue
		for t in ts:
			var p: Vector3 = (shape.edge_point_at(e, t) as Dictionary).get("point", Vector3())
			var n0: Vector3 = shape.face_normal_at(faces[0], p)
			var n1: Vector3 = shape.face_normal_at(faces[1], p)
			if n0.length() > 0.5 and n1.length() > 0.5:
				worst = maxf(worst, rad_to_deg(n0.angle_to(n1)))
	return worst


# --- Symmetry tools ------------------------------------------------------------------------------------

func _symmetry_tools() -> void:
	# Soft modification under a mirror: the selected corner moves by the full drag.
	var box := mirror_x(PRIMITIVES.box(Vector3.ONE * 2.0, Vector3i(2, 2, 2)))
	var corner := vertex_at(box, Vector3(1, 1, 1))
	var r := FORM_OPS.edit_transform(box, {"vertices": PackedInt32Array([corner])}, {"translate": Vector3(0, 0, 0.5), "soft": {"extent": "distance", "distance": 2.5, "transition": "smooth"}})
	var moved := CAGE.position_d(r.cage, corner)
	check(r.ok and absf(moved[2] - 1.5) < 1e-12, "Soft modification under a mirror should move the selected corner by the whole 0.5 (moved %s)." % (moved[2] - 1.0))
	var r2 := FORM_OPS.edit_transform(box, {"vertices": PackedInt32Array([corner])}, {"translate": Vector3(0.5, 0, 0), "soft": {"extent": "distance", "distance": 2.5, "transition": "smooth"}})
	check(absf(CAGE.position_d(r2.cage, corner)[0] - 1.5) < 1e-12 and symmetry_error(r2.cage)[0] <= 1e-12, "A soft move across the plane should move the corner 0.5 and keep the partners mirrored.")
	# Whole body: rotate 90 deg about Z and translate; the plane moves with the body.
	var all := FORM_OPS._range(CAGE.vertex_count(box))
	var rot := FORM_OPS.edit_transform(box, {"body": true}, {"xf": FORM_OPS.xf_from(Basis(Vector3(0, 0, 1), PI * 0.5), Vector3.ZERO), "pivot": Vector3.ZERO})
	var size := CAGE.bounds(rot.cage).size
	var serr: Array = symmetry_error(rot.cage)
	var nrm: PackedFloat64Array = rot.cage.symmetry[0].normal
	check(rot.ok and size.distance_to(Vector3(2, 2, 2)) < 1e-6 and serr[0] <= 1e-12 and absf(absf(nrm[1]) - 1.0) < 1e-12, "Rotating a mirrored body 90 deg should rotate it and its plane (size %s, symmetry error %s, normal %s)." % [size, serr[0], nrm])
	var mv := FORM_OPS.edit_transform(box, {"body": true}, {"translate": Vector3(0.5, 0, 0)})
	check(mv.ok and absf(CAGE.bounds(mv.cage).position.x - (-0.5)) < 1e-12 and absf(float(mv.cage.symmetry[0].origin[0]) - 0.5) < 1e-12, "Moving a mirrored body +0.5 X should move it and its plane.")
	# Both sides picked: the first picked drives, the other mirrors.
	var a := vertex_at(box, Vector3(1, 0, 1))
	var b := vertex_at(box, Vector3(-1, 0, 1))
	var both := FORM_OPS.edit_transform(box, {"vertices": PackedInt32Array([a, b])}, {"translate": Vector3(0.3, 0, 0)})
	check(absf(CAGE.position_d(both.cage, a)[0] - 1.3) < 1e-6 and absf(CAGE.position_d(both.cage, b)[0] + CAGE.position_d(both.cage, a)[0]) < 1e-12, "With a vertex and its partner picked, the first moves +0.3 and the partner mirrors it.")
	# A skewing scale of the whole body would break the mirror: refused.
	var d := Vector3(1, 1, 0).normalized()
	# Doubles the size along (1, 1, 0): I + d d^T.
	var skew_basis := Basis(Vector3(1, 0, 0) + d * d.x, Vector3(0, 1, 0) + d * d.y, Vector3(0, 0, 1) + d * d.z)
	var skew := FORM_OPS.edit_transform(box, {"body": true}, {"xf": FORM_OPS.xf_from(skew_basis, Vector3.ZERO), "pivot": Vector3.ZERO})
	check(not skew.ok and str(skew.error) == FORM_OPS.BREAKS_SYMMETRY, "A skewing scale of a mirrored body should be refused (%s)." % skew.error)
	# Circular: a 90 deg rotation about X keeps the cylinder's shape and turns its axis.
	var cyl := PRIMITIVES.primitive_symmetry(PRIMITIVES.cylinder(2.0, 2.0, 8, 2, "pole"), "circular", Transform3D.IDENTITY, Vector3i.ZERO, 8)
	var crot := FORM_OPS.edit_transform(cyl, {"body": true}, {"xf": FORM_OPS.xf_from(Basis(Vector3(1, 0, 0), PI * 0.5), Vector3.ZERO), "pivot": Vector3.ZERO})
	var csize := CAGE.bounds(crot.cage).size
	check(crot.ok and csize.y > 1.9 and csize.z > 1.9 and symmetry_error(crot.cage)[0] <= 1e-12, "Rotating a circular body should keep its shape (size %s)." % csize)
	checked.append("soft and whole-body moves under symmetry (full drag, planes and axes carried, both sides follow the first, skew refused)")
	# Zero-distance extend: the new chain's partners are the partner's new chain.
	var plane := PRIMITIVES.primitive_symmetry(PRIMITIVES.plane(Vector2(4, 4), Vector2i(4, 4)), "mirror", Transform3D.IDENTITY, Vector3i(1, 0, 0), 0)
	var e0 := vertex_at(plane, Vector3(1, 2, 0))
	var e1 := vertex_at(plane, Vector3(2, 2, 0))
	var nv0 := CAGE.vertex_count(plane)
	var ext := FORM_OPS.extend_edges(plane, {"edges": PackedInt32Array([mini(e0, e1), maxi(e0, e1)])}, {})
	var m: PackedInt32Array = ext.cage.symmetry[0].map
	var fresh: PackedInt32Array = ext.info.new_vertices
	var maps_new := not fresh.is_empty()
	for v in fresh:
		maps_new = maps_new and m[v] >= nv0
	check(ext.ok and maps_new, "Vertices of a zero-distance extend should map to the partner's new vertices (%s)." % [Array(fresh).map(func(v): return m[v])])
	var moved_chain := FORM_OPS.edit_transform(ext.cage, {"vertices": fresh}, {"translate": Vector3(0, 0.5, 0)})
	var old_moved := 0
	for v in nv0:
		if CAGE.position_d(moved_chain.cage, v) != CAGE.position_d(ext.cage, v):
			old_moved += 1
	check(old_moved == 0, "Moving the new chain should move no original vertex (%d moved)." % old_moved)
	# UnWeld on a self-symmetric loop: every partner in its own piece.
	var b2 := mirror_x(PRIMITIVES.box(Vector3.ONE * 2.0, Vector3i(2, 2, 2)))
	var t2 := CAGE.topology(b2)
	var start := t2.edge_index(vertex_at(b2, Vector3(1, 1, 0)), vertex_at(b2, Vector3(1, 0, 0)))
	var loop := t2.edge_loop(start)
	var cut := FORM_OPS.unweld(b2, {"edges": FORM_OPS._edges_to_pairs(t2, loop)}, {})
	var ct := CAGE.topology(cut.cage)
	var comps := ct.components()
	var piece := PackedInt32Array()
	piece.resize(ct.nV)
	for f in ct.nF:
		for v in ct.face_verts(f):
			piece[v] = comps[f]
	var crossing := 0
	var um: PackedInt32Array = cut.cage.symmetry[0].map
	for v in um.size():
		if um[v] >= 0 and piece[um[v]] != piece[v]:
			crossing += 1
	check(cut.ok and ct.component_count() == 2 and crossing == 0 and symmetry_error(cut.cage)[1] == 0, "UnWeld on a self-symmetric loop should keep every partner in its own piece (%d cross)." % crossing)
	# Subdivide Specify 3 x 1 under the mirror: the partner face splits the same way.
	var sub := FORM_OPS.subdivide(b2, {"faces": PackedInt32Array([face_at(b2, Vector3(1, 0.5, 0.5))])}, {"u_faces": 3, "v_faces": 1})
	check(sub.ok and symmetry_error(sub.cage)[1] == 0 and FORM_OPS._faces_lacking_partners(sub.cage, FORM_OPS._range(CAGE.face_count(sub.cage))) == 0, "Subdivide 3 x 1 under a mirror should split the partner face alike (broken %d)." % symmetry_error(sub.cage)[1])
	# Insert Edge at 0.5 next to a self-symmetric face.
	var b3 := mirror_x(PRIMITIVES.box(Vector3.ONE * 3.0, Vector3i(3, 3, 3)))
	var ia := vertex_at(b3, Vector3(0.5, 0.5, 1.5))
	var ib := vertex_at(b3, Vector3(0.5, -0.5, 1.5))
	var ins := FORM_OPS.insert_edge(b3, {"edges": PackedInt32Array([mini(ia, ib), maxi(ia, ib)])}, {"location": 0.5})
	check(ins.ok and symmetry_error(ins.cage)[1] == 0 and symmetry_error(ins.cage)[0] <= 1e-12, "Insert Edge at 0.5 beside a self-symmetric face should give one loop on the plane (%s)." % ins.error)
	# Reduced Star on an n-fold symmetric hole falls back to a symmetric fill, with a warning.
	var tube := PRIMITIVES.primitive_symmetry(PRIMITIVES.cylinder(2.0, 2.0, 8, 2, "open"), "circular", Transform3D.IDENTITY, Vector3i.ZERO, 8)
	var tt := CAGE.topology(tube)
	var rim_edge := -1
	for e in tt.nE:
		if tt.is_boundary_edge(e):
			rim_edge = e
			break
	var fill := FORM_OPS.fill_hole(tube, {"edges": PackedInt32Array([tt.edges[2 * rim_edge], tt.edges[2 * rim_edge + 1]])}, {"mode": "reduced"})
	check(fill.ok and FORM_OPS._faces_lacking_partners(fill.cage, FORM_OPS._range(CAGE.face_count(fill.cage))) == 0 and ", ".join(fill.warnings).contains("symmetry"), "Reduced Star on an 8-fold hole should fill it symmetrically and say so (%s)." % [fill.warnings])
	checked.append("topology under symmetry (zero-distance extend, unweld, subdivide 3 x 1, insert edge at 0.5 on the plane, symmetric Reduced Star fallback)")


# --- Other tools ------------------------------------------------------------------------------------

func _other_tools() -> void:
	var ctx := {"cages": {}, "feature": null}
	var r: Dictionary = FORM_TOOLS.run("cylinder", ctx, {}, {"diameter": 0.02, "height": 0.02, "around_faces": 7.0, "height_faces": 2.0, "symmetry": "mirror", "sym_x": true})
	check(not r.ok and str(r.error).contains("does not fit"), "A mirror that doesn't fit 7 diameter faces should be refused (%s)." % r.error)
	r = FORM_TOOLS.run("cylinder", ctx, {}, {"diameter": 0.02, "height": 0.02, "around_faces": 2.0, "height_faces": 2.0})
	check(not r.ok and str(r.error).contains("whole number from 3"), "Diameter Faces 2 should be refused with its range (%s)." % r.error)
	r = FORM_TOOLS.run("box", ctx, {}, {"length": 0.02, "width": 0.02, "height": 0.02, "length_faces": 2.6, "width_faces": 2.0, "height_faces": 2.0})
	check(not r.ok and str(r.error).contains("whole number"), "A fractional face count should be refused (%s)." % r.error)
	# Smooth on a single face moves nothing: reported, no change.
	var box := PRIMITIVES.box(Vector3.ONE * 2.0, Vector3i(2, 2, 2))
	var sm := FORM_OPS.smooth(box, {"faces": PackedInt32Array([0])}, {"amount": 0.5})
	check(not sm.ok and str(sm.error) == FORM_OPS.NOTHING, "Smooth on one face should report there is nothing to change (%s)." % sm.error)
	# Thicken along +Z goes along +Z.
	var plane := PRIMITIVES.plane(Vector2(1, 1), Vector2i(1, 1))
	var th := FORM_OPS.thicken(plane, {}, {"thickness": 0.1, "direction": "axis", "axis": Vector3(0, 0, 1)})
	var zmax := -INF
	for v in CAGE.vertex_count(th.cage):
		zmax = maxf(zmax, CAGE.position(th.cage, v).z)
	check(th.ok and absf(zmax - 0.1) < 1e-6 and CAGE.validate(th.cage).is_empty(), "Thicken along +Z should put the copy at +Z (top %s)." % zmax)
	var thf := FORM_OPS.thicken(plane, {}, {"thickness": 0.1, "direction": "axis", "axis": Vector3(0, 0, 1), "flip": true})
	var zmin := INF
	for v in CAGE.vertex_count(thf.cage):
		zmin = minf(zmin, CAGE.position(thf.cage, v).z)
	check(thf.ok and absf(zmin + 0.1) < 1e-6, "Thicken along +Z with Flip should put the copy at -Z.")
	checked.append("primitive counts and symmetry fit refused with reasons, Smooth nothing to change, Thicken along the axis")


# --- Text resources ------------------------------------------------------------------------------------

func _text_round_trip() -> void:
	var c := PRIMITIVES.box(Vector3(0.1, 0.0123, 0.03), Vector3i(2, 2, 2))
	# Vector3-made positions are float32-exact doubles (which text prints shortest as float32).
	var frame := Transform3D(Basis(Vector3(0, 0, 1), 0.3), Vector3(0.1, 0.00123, -0.0))
	c = FORM_TOOLS.place(c, frame)
	c = PRIMITIVES.primitive_symmetry(c, "mirror", frame, Vector3i(1, 0, 0), 0)
	var d: Resource = DOCUMENT.new()
	var f: Resource = d.add_feature("form", "Form", {}, FORM.new_options())
	var body: String = d.new_body(f.id)
	f.options.bodies[body] = c
	var before := CAGE.content_hash(c)
	var positions: PackedFloat64Array = (c.positions as PackedFloat64Array).duplicate()
	var origin: PackedFloat64Array = (c.symmetry[0].origin as PackedFloat64Array).duplicate()
	FORM.store_exact(d)
	var path := "user://holo_forge_form_fix_round_trip.tres"
	check(ResourceSaver.save(d, path) == OK, "The test document should save as text.")
	var loaded: Resource = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	if loaded == null:
		check(false, "The saved text document should load.")
		return
	FORM.clear_cache()
	if kernel != null:
		REGEN.rebuild(loaded, kernel)
	else:
		FORM.resolve_exact((loaded.features[0].options.bodies as Dictionary)[body])
	var back: Dictionary = (loaded.features[0].options.bodies as Dictionary)[body]
	check(back.positions == positions and back.symmetry[0].origin == origin and CAGE.content_hash(back) == before and not back.has(FORM.EXACT_KEY),
		"A form cage should come back from a text resource exactly (hash %s vs %s, origin %s vs %s)." % [CAGE.content_hash(back), before, back.symmetry[0].origin, origin])
	checked.append("form cages round-trip a text resource bit-exactly (positions, symmetry plane, content hash)")
