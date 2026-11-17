extends SceneTree
## Regression checks for the Phase 6 verification round after the critical fixes, headless, each
## bounded in time:
## - A hollow shell (no open faces) of a converted body is right or refused: every inner-wall
##   point of a built one lies about the thickness from the outside (a converted torus' walls came
##   out at a quarter of it, a plate's at 0.6, with no warning), measured here independently on
##   the tessellations.
## - Impossible walls (thicker than half the body or than its curves) are refused within a couple
##   of seconds with a sentence saying where and how thick the body is (they blocked 10 to 20 s),
##   and asking again for the same body and thickness answers at once.
## - Single-edge fillets and chamfers of the O1 test body return within seconds (2.8 to 3 mm on
##   two edges never returned), built results sound, refusals with a reason.
## - Fillets of the O1 test body whose corners came out millimetres off the edges that meet there
##   (the mesh around them 0.3 to 0.7 mm off its faces at every deflection) are built with their
##   mesh on their faces or refused.
## - Create and Edit Form fields refuse typed values out of range with a sentence instead of
##   clamping them silently.

const CAGE := preload("res://addons/holo_forge/core/form/cage.gd")
const PRIMITIVES := preload("res://addons/holo_forge/core/form/primitives.gd")
const FORM_TOOLS := preload("res://addons/holo_forge/ui/form_tools.gd")
const REGEN := preload("res://addons/holo_forge/core/regen.gd")
const WS_CAGE := "res://tests/holo_forge/fixtures/form_ws_o1_cage.txt"

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
		_shell_walls()
		_shell_impossible()
		_blend_bounds()
		_blend_faces()
	else:
		print("note: CadSubD is not loaded; the native checks are skipped")
	_field_ranges()
	if failures.is_empty():
		print("PASS holo_forge_form_regress: ", ", ".join(checked))
		quit(0)
	else:
		print("FAIL holo_forge_form_regress")
		for f in failures:
			print("  ", f)
		quit(1)


# --- Helpers -------------------------------------------------------------------------------------

## c scaled by s, turned 0.4 rad about (1, 2, 3) and moved by (0.1, 0.2, 0.3) s, in doubles (the
## verifiers' placement: no face lines up with an axis).
func placed(c: Dictionary, s: float) -> Dictionary:
	var out := CAGE.copy(c)
	var basis := Basis(Vector3(1, 2, 3).normalized(), 0.4)
	var origin := Vector3(0.1, 0.2, 0.3) * s
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


func to_body(c: Dictionary, level := 6) -> RefCounted:
	var s: RefCounted = ClassDB.instantiate("CadSubD")
	if not s.set_cage(c):
		return null
	var shapes: Array = s.to_shapes({"isolation": level, "name_prefix": "t/b"})
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


## The fractions of a hollow body's inner-wall points (the points of its tessellation more than a
## twentieth of the wall from the outside) lying under 0.9 and over 1.1 walls from the body's own
## tessellation, the smallest distance (in walls), and how many points were measured.
func wall_spread(body: RefCounted, hollow: RefCounted, t: float) -> Dictionary:
	var outer: Dictionary = body.tessellate(t / 50.0, 0.1)
	var cell := t
	var grid := {}
	var tris := PackedVector3Array()
	var p: PackedVector3Array = outer.positions
	var idx: PackedInt32Array = outer.indices
	for k in range(0, idx.size(), 3):
		var a := p[idx[k]]
		var b := p[idx[k + 1]]
		var c := p[idx[k + 2]]
		var ti := tris.size() / 3
		tris.append(a)
		tris.append(b)
		tris.append(c)
		var i0 := Vector3i((a.min(b).min(c) / cell).floor())
		var i1 := Vector3i((a.max(b).max(c) / cell).floor())
		for x in range(i0.x, i1.x + 1):
			for y in range(i0.y, i1.y + 1):
				for z in range(i0.z, i1.z + 1):
					var key := Vector3i(x, y, z)
					if not grid.has(key):
						grid[key] = PackedInt32Array()
					grid[key].append(ti)
	var pts: PackedVector3Array = (hollow.tessellate(t / 20.0, 0.2) as Dictionary).positions
	var step := maxi(1, pts.size() / 1500)
	var n := 0
	var thin := 0
	var far := 0
	var lowest := INF
	for i in range(0, pts.size(), step):
		var q := pts[i]
		var c0 := Vector3i((q / cell).floor())
		var best := INF
		for x in range(-2, 3):
			for y in range(-2, 3):
				for z in range(-2, 3):
					var key := c0 + Vector3i(x, y, z)
					if grid.has(key):
						for ti in grid[key]:
							best = minf(best, q.distance_to(closest_on_tri(q, tris[ti * 3], tris[ti * 3 + 1], tris[ti * 3 + 2])))
		if best < 0.05 * t:
			continue
		n += 1
		lowest = minf(lowest, best / t)
		if best < 0.9 * t:
			thin += 1
		elif best > 1.1 * t:
			far += 1
	return {"n": n, "thin": thin, "far": far, "lowest": lowest}


# --- Hollow shells: right or refused -------------------------------------------------------------

func _shell_walls() -> void:
	# [name, cage, size (m), thicknesses (m)]: walls OCCT's offset gets wrong (torus at 10 to 15 mm,
	# plate at 7.67 mm), and walls that must still build.
	var specs := [
		["torus 50 mm", PRIMITIVES.torus(2.0, 0.8, 8, 6), 0.025, [0.010, 0.01064, 0.012, 0.015, 0.002]],
		["plate 800 mm", PRIMITIVES.box(Vector3(2.0, 0.6, 0.075), Vector3i(6, 4, 1)), 0.4, [0.00767, 0.002]],
		["box 50 mm", PRIMITIVES.box(Vector3(2, 2, 2), Vector3i(2, 2, 2)), 0.025, [0.00137, 0.00825]],
		["sphere 5 mm", PRIMITIVES.sphere(2.0, 8, 4), 0.0025, [0.000105, 0.00063]],
	]
	var built := 0
	for spec in specs:
		var a := to_body(placed(spec[1], spec[2]))
		if a == null:
			check(false, "The converted %s should build." % spec[0])
			continue
		for t in spec[3]:
			var t0 := Time.get_ticks_msec()
			var out: RefCounted = kernel.shell(a, PackedInt32Array(), {"thickness": t})
			var ms := Time.get_ticks_msec() - t0
			var err := str(kernel.get_last_error())
			check(ms < 15000, "The %s hollow at %s mm took %d ms." % [spec[0], t * 1000.0, ms])
			if out == null:
				check(err.length() > 20, "A refused %s hollow at %s mm should say why (%s)." % [spec[0], t * 1000.0, err])
				continue
			built += 1
			var w := wall_spread(a, out, t)
			check(int(w.n) > 100, "The %s hollow at %s mm should have inner-wall points to measure (%d)." % [spec[0], t * 1000.0, w.n])
			check(int(w.thin) == 0 and float(w.lowest) > 0.93, "The %s hollow at %s mm was built with %d of %d inner-wall points closer than 0.9 walls to the outside (lowest %.2f walls)." % [spec[0], t * 1000.0, w.thin, w.n, w.lowest])
			check(int(w.far) == 0, "The %s hollow at %s mm has %d inner-wall points farther than 1.1 walls from the outside." % [spec[0], t * 1000.0, w.far])
	check(built >= 4, "The walls that fit (torus 2 mm, plate 2 mm, box 1.37 and 8.25 mm, sphere 0.1 and 0.63 mm) should mostly build (%d built)." % built)
	checked.append("hollow shells of converted bodies are built with every inner-wall point about a wall from the outside, or refused (torus 10-15 mm, plate 7.67 mm)")


func _shell_impossible() -> void:
	# Walls thicker than the body or its curves: refused fast, saying where and how thick.
	var specs := [
		["box 50 mm", PRIMITIVES.box(Vector3(2, 2, 2), Vector3i(2, 2, 2)), 0.025, [0.0165, 0.0247, 0.033]],
		["sphere 50 mm", PRIMITIVES.sphere(2.0, 8, 4), 0.025, [0.022, 0.030]],
		["sphere 5 mm", PRIMITIVES.sphere(2.0, 8, 4), 0.0025, [0.00189]],
	]
	for spec in specs:
		var a := to_body(placed(spec[1], spec[2]))
		if a == null:
			check(false, "The converted %s should build." % spec[0])
			continue
		for t in spec[3]:
			var t0 := Time.get_ticks_msec()
			var out: RefCounted = kernel.shell(a, PackedInt32Array(), {"thickness": t})
			var ms := Time.get_ticks_msec() - t0
			var err := str(kernel.get_last_error())
			check(out == null, "A %s mm wall on the %s can't be right and should be refused." % [t * 1000.0, spec[0]])
			check(ms < 4000, "Refusing a %s mm wall on the %s took %d ms (it blocked 10 to 20 s)." % [t * 1000.0, spec[0], ms])
			check(err.contains(" mm") and (err.contains("thicker than") or err.contains("within")), "The refusal of a %s mm wall on the %s should say where and how thick (%s)." % [t * 1000.0, spec[0], err])
			var t1 := Time.get_ticks_msec()
			var again: RefCounted = kernel.shell(a, PackedInt32Array(), {"thickness": t})
			var ms2 := Time.get_ticks_msec() - t1
			check(again == null and str(kernel.get_last_error()) == err, "Asking again for a %s mm wall on the %s should give the same refusal." % [t * 1000.0, spec[0]])
			check(ms2 < 100, "Asking again for a refused %s mm wall on the %s took %d ms (a rebuild repeated the whole try)." % [t * 1000.0, spec[0], ms2])
	checked.append("impossible hollow walls are refused in under 4 s with where and how thick, and at once when asked again")


# --- Fillets and chamfers that marched without end -----------------------------------------------

func _blend_bounds() -> void:
	var base: Variant = str_to_var(FileAccess.get_file_as_string(WS_CAGE))
	if not base is Dictionary:
		check(false, "The O1 test cage fixture should load.")
		return
	var a := to_body(base)
	if a == null:
		check(false, "The O1 test body should convert.")
		return
	var sharp := PackedInt32Array()
	for e in a.edge_count():
		if float((a.edge_info(e) as Dictionary).get("dihedral", 0.0)) > 0.5:
			sharp.append(e)
	check(sharp.size() >= 8, "The O1 test body should have its sharp edges (%d)." % sharp.size())
	var bb: AABB = a.bbox()
	var slack := 2e-4
	var cases := []
	# The ones that never returned, then every sharp edge at the radii around them.
	for c in [["fillet", 8, 0.0028], ["fillet", 8, 0.0029], ["fillet", 8, 0.0029475], ["fillet", 8, 0.003], ["fillet", 38, 0.0025], ["chamfer", 8, 0.0029475]]:
		if sharp.has(c[1]):
			cases.append(c)
	for e in sharp:
		for r in [0.0013, 0.0029]:
			cases.append(["fillet", e, r])
		cases.append(["chamfer", e, 0.0029])
	var slowest := 0
	var bad := 0
	var silent := 0
	for c in cases:
		var t0 := Time.get_ticks_msec()
		var p := {"radius": c[2]} if c[0] == "fillet" else {"distance": c[2]}
		var out: RefCounted = kernel.call(c[0], a, PackedInt32Array([c[1]]), p)
		var ms := Time.get_ticks_msec() - t0
		if ms > slowest:
			slowest = ms
		check(ms < 8000, "A %s mm %s of edge %d took %d ms (it never returned)." % [c[2] * 1000.0, c[0], c[1], ms])
		if out == null:
			if str(kernel.get_last_error()) == "":
				silent += 1
			continue
		var ob: AABB = out.bbox()
		if not (out.volume() > 0.0 and out.volume() < a.volume() * 1.5 and ob.position.x >= bb.position.x - slack and ob.end.x <= bb.end.x + slack \
				and ob.position.y >= bb.position.y - slack and ob.end.y <= bb.end.y + slack and ob.position.z >= bb.position.z - slack and ob.end.z <= bb.end.z + slack):
			bad += 1
	check(bad == 0, "%d fillets or chamfers of the O1 body came back broken." % bad)
	check(silent == 0, "%d refused fillets or chamfers of the O1 body gave no reason." % silent)
	checked.append("single-edge fillets and chamfers of the O1 body return within seconds (%d cases, slowest %d ms)" % [cases.size(), slowest])


# --- Fillets whose corners came out off their edges ----------------------------------------------

## What is wrong with the mesh of a (at linear deflection lin, 0.2 rad): the faces whose mesh is off
## the face's own area by more than a twentieth of it and 0.01 mm2 (the chords of a sliver's mesh
## alone come to less), as "f<i> <face> / <mesh> mm2"; the tessellation's warnings; and the mesh's
## volume when it is off the body's by more than a 500th.
func mesh_problems(a: RefCounted, lin: float) -> Array:
	var t: Dictionary = a.tessellate(lin, 0.2)
	if not t.has("positions"):
		return ["no mesh"]
	var bad: Array = []
	var p: PackedVector3Array = t.positions
	var idx: PackedInt32Array = t.indices
	var fid: PackedInt32Array = t.face_ids
	var covered := {}
	var six := 0.0
	var c: Vector3 = (a.bbox() as AABB).get_center()
	for k in range(0, idx.size(), 3):
		var f := fid[k / 3]
		var p0 := p[idx[k]] - c
		var p1 := p[idx[k + 1]] - c
		var p2 := p[idx[k + 2]] - c
		covered[f] = float(covered.get(f, 0.0)) + 0.5 * (p1 - p0).cross(p2 - p0).length()
		six += p0.dot(p1.cross(p2))
	for f in a.face_count():
		var own: float = (a.face_info(f) as Dictionary).get("area", 0.0)
		var mesh: float = covered.get(f, 0.0)
		if absf(own - mesh) > 0.05 * own and absf(own - mesh) > 1e-8:
			bad.append("f%d %.4f / %.4f mm2" % [f, own * 1e6, mesh * 1e6])
	for w in t.get("warnings", PackedStringArray()):
		bad.append("warning: " + w)
	var volume: float = a.volume()
	if absf(absf(six) / 6.0 - volume) > 0.002 * volume:
		bad.append("mesh volume %.2f of the body's %.2f mm3" % [absf(six) / 6.0 * 1e9, volume * 1e9])
	return bad


func _blend_faces() -> void:
	# Where the closer fits built nothing, the geometry kernel's fillets at its own loose fit left
	# corners 1.7 to 2.6 mm off the edges that meet there (their tolerances made to match, so its
	# own check passed them): the mesh of the faces around such a corner sat 0.3 to 0.7 mm off them
	# at every deflection (faces of 0.25 mm2 drawn as 1.75 mm2, the mesh 0.5 % under the body's
	# volume), behind a "fitted only to within 0.1 mm" warning. And a 2 mm fillet left a 0.26 mm2
	# sliver with a corner 6 um off its edges, drawn 7 % over its area with no warning at all.
	# (At a tenth of that fit most of them build sound; a 3.8 mm one came out with its fillet's
	# surface folded over itself, a 48.6 mm2 face drawn as 53.9 mm2.)
	# Every one is built with its mesh on its faces, or refused with a reason.
	var base: Variant = str_to_var(FileAccess.get_file_as_string(WS_CAGE))
	var a := to_body(base) if base is Dictionary else null
	if a == null:
		check(false, "The O1 test body should convert.")
		return
	var lin: float = 2e-4 * (a.bbox() as AABB).size.length()
	var built := 0
	var tried := 0
	var slowest := 0
	for c in [[52, 0.0026], [61, 0.0026], [52, 0.003], [52, 0.0035], [61, 0.0039], [70, 0.0039], [33, 0.002], [52, 0.002], [8, 0.0005], [38, 0.001], [91, 0.003], [33, 0.0038]]:
		if a.edge_count() <= c[0] or float((a.edge_info(c[0]) as Dictionary).get("dihedral", 0.0)) <= 0.5:
			check(false, "Edge %d of the O1 test body should be one of its sharp edges." % c[0])
			continue
		tried += 1
		var label := "A %s mm fillet of edge %d of the O1 body" % [c[1] * 1000.0, c[0]]
		var t0 := Time.get_ticks_msec()
		var out: RefCounted = kernel.fillet(a, PackedInt32Array([c[0]]), {"radius": c[1]})
		var ms := Time.get_ticks_msec() - t0
		slowest = maxi(slowest, ms)
		check(ms < 8000, "%s took %d ms." % [label, ms])
		if out == null:
			check(str(kernel.get_last_error()) != "", "%s was refused without a reason." % label)
			continue
		built += 1
		var bad := mesh_problems(out, lin)
		check(bad.is_empty(), "%s was built with a mesh that isn't on its faces: %s (warning '%s')." % [label, ", ".join(bad.slice(0, 4)), kernel.get_last_warning()])
	# (The sound ones were always built, and the ones with corners off their edges build at a
	# tenth of the kernel's own fit: a fix that only refused them would pass the checks above.)
	# (Six are refused: 2 mm on edges 33 and 52 for the sliver, 3.5 mm on 52 and 3.9 mm on 61 and
	# 70 for corners off their edges, 3.8 mm on 33 for the fold.)
	check(built >= tried - 6, "Only %d of the %d fillets were built." % [built, tried])
	checked.append("%d of %d fillets of the O1 body that came out with corners off their edges (or sound) are built with their mesh on their faces, the rest refused (slowest %d ms)" % [built, tried, slowest])


# --- Typed values out of a field's range ---------------------------------------------------------

func _field_ranges() -> void:
	var refused := [
		["sweep", {"profile_faces": 0.0}], ["sweep", {"profile_faces": 65.0}], ["sweep", {"path_faces": 2.5}], ["sweep", {"extent": 1.5}],
		["sweep", {"extent": -0.1}], ["extrude", {"profile_faces": 100.0}], ["extrude", {"front_faces": 0.0}], ["revolve", {"around_faces": 70.0}],
		["loft", {"width_faces": 1.0}], ["loft", {"length_faces": 0.0}], ["pipe", {"around_faces": 2.0}], ["pipe", {"density": 300.0}],
		["pipe", {"sections": "1", "s1_pos": 1.5}], ["box", {"length_faces": 0.0}], ["cylinder", {"around_faces": 2.0}], ["sphere", {"rows": 1.0}],
		["torus", {"tube_faces": 100.0}], ["quadball", {"span_faces": 1.5}],
		["edit_form", {"soft": true, "extent": "faces", "faces": 65.0}], ["edit_form", {"soft": true, "weight": 2.0}],
		["edit_form", {"soft": true, "extent": "rectangular", "u_faces": 0.0}],
		# Loft weights, Pipe's curve tolerance and the scale factors clamped silently before.
		["loft", {"start": "direction", "start_weight": -1.0}], ["loft", {"start": "tip", "start_weight": 11.0}],
		["loft", {"end": "direction", "end_weight": 20.0}], ["loft", {"end": "tip", "end_weight": -0.5}],
		["pipe", {"tolerance": 0.0}], ["pipe", {"tolerance": 1e-9}], ["pipe", {"tolerance": 0.5}],
		["edit_form", {"x_scale": 0.0}], ["edit_form", {"y_scale": -2.0}], ["edit_form", {"zx_scale": 0.001}],
		["edit_form", {"uniform_scale": 5000.0}], ["edit_by_curve", {"x_scale": 0.0}], ["edit_by_curve", {"yz_scale": -1.0}],
	]
	for r in refused:
		var err := FORM_TOOLS.range_error(r[0], r[1])
		check(err != "" and err.ends_with("."), "%s %s should be refused with a sentence (got '%s')." % [r[0], r[1], err])
	var fine := [
		["sweep", {"profile_faces": 8.0, "path_faces": 64.0, "extent": 0.5}], ["extrude", {"profile_faces": 1.0, "front_faces": 64.0}],
		["loft", {"width_faces": 2.0, "length_faces": 3.0}], ["pipe", {"around_faces": 3.0, "density": 0.0, "sections": "1", "s1_pos": 1.0}],
		["edit_form", {"soft": true, "extent": "faces", "faces": 0.0, "weight": 0.5}],
		# (Hidden fields aren't checked: the weight of a hard edit isn't used.)
		["edit_form", {"soft": false, "weight": 5.0}],
		["loft", {"start": "direction", "start_weight": 0.0, "end": "tip", "end_weight": 10.0}],
		["loft", {"start": "free", "start_weight": -1.0, "end": "free", "end_weight": 50.0}],
		["pipe", {"tolerance": 1e-5}], ["pipe", {"tolerance": 1e-7}], ["pipe", {"tolerance": 0.1}],
		["edit_form", {"x_scale": 1.0, "y_scale": 0.01, "z_scale": 1000.0, "xy_scale": 2.0, "yz_scale": 0.5, "zx_scale": 1.0, "uniform_scale": 3.0}],
		["edit_by_curve", {"x_scale": 1.5, "xy_scale": 0.25}],
	]
	for f in fine:
		var err := FORM_TOOLS.range_error(f[0], f[1])
		check(err == "", "%s %s should be accepted (got '%s')." % [f[0], f[1], err])
	# The sentences: plain numbers as typed, lengths in the document's unit.
	var weight := FORM_TOOLS.range_error("loft", {"start": "direction", "start_weight": -1.0})
	check(weight == "Start Weight must be from 0 to 10.", "Loft Start Weight -1 should say its range (got '%s')." % weight)
	var tol_mm := FORM_TOOLS.range_error("pipe", {"tolerance": 0.0}, "mm")
	check(tol_mm == "Curve Tolerance must be from 0.0001 mm to 100 mm.", "Pipe tolerance 0 should say its range in mm (got '%s')." % tol_mm)
	var tol_cm := FORM_TOOLS.range_error("pipe", {"tolerance": 1.0}, "cm")
	check(tol_cm == "Curve Tolerance must be from 0.00001 cm to 10 cm.", "Pipe tolerance 1 m should say its range in cm (got '%s')." % tol_cm)
	var scale := FORM_TOOLS.range_error("edit_form", {"x_scale": 0.0})
	check(scale == "X Scale must be from 0.01 to 1000.", "Edit Form X Scale 0 should say its range (got '%s')." % scale)
	# Run refuses them too, instead of building with a clamped value.
	var ctx := {"cages": {}, "result": {}, "doc": null, "feature": null, "kernel": null, "values": {}, "subd": Callable()}
	var piped := FORM_TOOLS.run("pipe", ctx, {}, {"path": [], "tolerance": 0.0})
	check(not piped.ok and str(piped.error) == tol_mm, "Pipe with tolerance 0 should be refused with its range (got '%s')." % piped.error)
	var lofted := FORM_TOOLS.run("loft", ctx, {}, {"profiles": [], "start": "direction", "start_weight": -1.0})
	check(not lofted.ok and str(lofted.error) == weight, "Loft with Start Weight -1 should be refused with its range (got '%s')." % lofted.error)
	var curved := FORM_TOOLS.run("edit_by_curve", ctx, {}, {"x_scale": 0.0})
	check(not curved.ok and str(curved.error).begins_with("X Scale must be from"), "Edit By Curve X Scale 0 should be refused (got '%s')." % curved.error)
	checked.append("create and Edit Form fields refuse out-of-range typed values with a sentence (Loft weights, Pipe tolerance and scale factors too)")
