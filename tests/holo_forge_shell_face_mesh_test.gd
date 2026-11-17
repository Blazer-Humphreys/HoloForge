extends SceneTree
## Regression checks that every face of a shell is drawn as it is, and that shell and offset
## refusals say what really went wrong, headless, each call bounded in time:
## - Non-convex bodies (an L-shaped bracket, a U-shaped channel, a stepped block) open at their top
##   faces, at two heights: the shell's B-rep was right, but the rim round the lower opening
##   was made with the inner wall's outline as a hole touching the rim's outer wire where the
##   opening runs up to the step's wall, which the mesher misread: a lid over the opening (113 to
##   3000 mm2 of mesh on a 7 to 648 mm2 rim) or a piece of the rim left out, in the viewport and the
##   export, with no warning, at every deflection. Every face's mesh must cover the face's own area.
## - Bodies saved with such rims (made by the build before the fix) must still be drawn right:
##   CadShape.tessellate meshes a flat face whose mesh doesn't cover it again from pieces the
##   mesher reads right, and warns of any it can't.
## - A spline-walled horseshoe prism open at the top: OCCT's thick solid hung the rim's inner loop
##   on the outer loop's corner (one wire, a figure of eight), and the rim's mesh closed over the
##   whole opening (92 mm2 of mesh on a 1.3 mm2 rim at a fine deflection). It must be built and
##   drawn as it is.
## - Refusals that told an untrue reason: a chamfered hexagonal prism's walls "would fill the whole
##   body" at 0.4 mm on a 20 mm body; shells refused with a boolean's advice ("try moving or
##   resizing one of them slightly"); a filleted L refused as "the inner wall runs through itself"
##   where the rounds' meshes only graze; offsets of 4 mm thick bodies by 0.1 mm "come out empty".
## - An offset in or a hollow at half a body's thinnest section was refused as failing "although
##   the body is more than twice the distance thick everywhere": it must name the thin spot.
## - A saved fillet whose corners lie off the edges that meet there (spline faces, which the mesh
##   guard never checked): tessellate must warn of every face drawn off itself.

const REGEN := preload("res://addons/holo_forge/core/regen.gd")
const FIXTURES := "res://tests/holo_forge/fixtures/"

## Each call must return within this (the slowest, the horseshoe prism shelled 0.02 mm, takes
## about 13 s, as long as it took before its rim was checked).
const CALL_MS := 30000

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
		_open_shells()
		_saved_rims()
		_horseshoe()
		_refusal_reasons()
		_thin_boundary()
		_saved_blend()
	else:
		print("note: CadKernel is not loaded; the native checks are skipped")
	if failures.is_empty():
		print("PASS holo_forge_shell_face_mesh: ", ", ".join(checked))
		quit(0)
	else:
		print("FAIL holo_forge_shell_face_mesh")
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


func _edges_where(b: RefCounted, pred: Callable) -> PackedInt32Array:
	var out := PackedInt32Array()
	for e in b.edge_count():
		if pred.call(b.edge_info(e)):
			out.append(e)
	return out


func _all_edges(b: RefCounted) -> PackedInt32Array:
	return _edges_where(b, func(_i): return true)


## The solid behind the plane n.x <= d (n made unit), from a box of side L near c.
func _half_box(n: Vector3, d: float, c: Vector3, L: float) -> RefCounted:
	n = n.normalized()
	var z := -n
	var x := z.cross(Vector3(0.3, 0.5, 0.7).normalized()).normalized()
	var y := z.cross(x)
	var on := c + n * (d - n.dot(c))
	return kernel.transform_shape(kernel.make_box(Vector3(L, L, L), Vector3(-L / 2, -L / 2, 0)), Transform3D(Basis(x, y, z), on))


func _planes_body(planes: Array, c: Vector3, L: float) -> RefCounted:
	var r: RefCounted = null
	for pl in planes:
		var h := _half_box(pl[0], pl[1], c, L)
		r = h if r == null else kernel.boolean(r, h, 2)
		if r == null:
			return null
	return r


## A body size mm across, turned by rot: "box" (size x 0.7 x 0.5), "bracket" (an L: the box less
## its upper right), "channel" (a U: the box less a slot down its middle), "step" (the box with a
## block on its left half), "cham" (the box with every edge chamfered by param mm), "fillet_l" (the
## bracket with every edge rounded by param mm), "hexcham" (a hexagonal prism, every edge chamfered
## by param mm), "tet" (a corner tetrahedron), "union" (the box with a ball on its top).
func body(kind: String, size_mm: float, rot: int, param := 0.0) -> RefCounted:
	var S := size_mm / 1000.0
	var p := param / 1000.0
	var b: RefCounted = null
	match kind:
		"box":
			b = kernel.make_box(Vector3(S, S * 0.7, S * 0.5), Vector3.ZERO)
		"bracket":
			b = kernel.boolean(body("box", size_mm, 0), kernel.make_box(Vector3(S * 0.6, S * 0.5, S), Vector3(S * 0.4, S * 0.2, -S * 0.2)), 1)
		"channel":
			b = kernel.boolean(body("box", size_mm, 0), kernel.make_box(Vector3(0.6 * S, 0.5 * S, S), Vector3(0.2 * S, 0.2 * S, -0.2 * S)), 1)
		"step":
			b = kernel.boolean(body("box", size_mm, 0), kernel.make_box(Vector3(0.5 * S, 0.3 * S, 0.5 * S), Vector3(0.0, 0.7 * S - 1e-12, 0.0)), 0)
		"cham":
			var b0 := body("box", size_mm, 0)
			b = kernel.chamfer(b0, _all_edges(b0), {"distance": p})
		"fillet_l":
			var b0 := body("bracket", size_mm, 0)
			b = kernel.fillet(b0, _all_edges(b0), {"radius": p})
		"hexcham":
			var pl := [[Vector3.UP, 0.6 * S], [Vector3.DOWN, 0.0]]
			for i in 6:
				var a := TAU * i / 6.0
				pl.append([Vector3(cos(a), 0, sin(a)), S * 0.5 * cos(PI / 6.0)])
			var b0 := _planes_body(pl, Vector3(0, 0.3 * S, 0), 6.0 * S)
			b = kernel.chamfer(b0, _all_edges(b0), {"distance": p}) if b0 != null else null
		"tet":
			b = _planes_body([[Vector3.LEFT, 0.0], [Vector3.DOWN, 0.0], [Vector3.FORWARD, 0.0], [Vector3(1, 1, 1).normalized(), S / sqrt(3.0)]], Vector3(0.25, 0.25, 0.25) * S, 6.0 * S)
		"union":
			b = kernel.boolean(body("box", size_mm, 0), kernel.make_sphere(S * 0.2, Vector3(S * 0.5, S * 0.7, S * 0.25)), 0)
	check(b != null, "The %s mm %s should be made (%s)." % [size_mm, kind, kernel.get_last_error()])
	if b == null or rot == 0:
		return b
	return kernel.transform_shape(b, _placement(size_mm, rot))


## The flat faces of a whose outward normal, in the body's own frame (rot), is within a hair of one
## of dirs.
func faces_facing(a: RefCounted, rot: int, dirs: Array) -> PackedInt32Array:
	var basis := _placement(1.0, rot).basis
	var out := PackedInt32Array()
	for f in a.face_count():
		var info: Dictionary = a.face_info(f)
		if not info.get("planar", false):
			continue
		for d in dirs:
			if (info.normal as Vector3).dot(basis * (d as Vector3)) > 0.9999:
				out.append(f)
				break
	return out


# --- Measures ------------------------------------------------------------------------------------

## The faces of a whose mesh (at linear deflection lin, 0.3 rad) doesn't cover the face's own area
## (within a 10000th on a flat face, which these bodies' straight edges bound and a mesh covers
## exactly; a 50th on a round, whose facets cut across its bend: a lid or a missing piece is far
## more), as "f<i> <face> / <mesh> mm2"; and the tessellation's warnings.
func face_mesh_problems(a: RefCounted, lin: float, flat_tol := 1e-4) -> Array:
	var t: Dictionary = a.tessellate(lin, 0.3)
	var bad: Array = []
	if not t.has("positions"):
		return ["no mesh"]
	var p: PackedVector3Array = t.positions
	var idx: PackedInt32Array = t.indices
	var fid: PackedInt32Array = t.face_ids
	var covered := {}
	for k in range(0, idx.size(), 3):
		var f := fid[k / 3]
		covered[f] = float(covered.get(f, 0.0)) + 0.5 * (p[idx[k + 1]] - p[idx[k]]).cross(p[idx[k + 2]] - p[idx[k]]).length()
	for f in a.face_count():
		var info: Dictionary = a.face_info(f)
		var own: float = info.get("area", 0.0)
		var mesh: float = covered.get(f, 0.0)
		if absf(own - mesh) > (flat_tol if info.get("planar", false) else 0.02) * own + 1e-12:
			bad.append("f%d %.5f / %.5f mm2" % [f, own * 1e6, mesh * 1e6])
	for w in t.get("warnings", PackedStringArray()):
		bad.append("warning: " + w)
	return bad


## The display deflection (as the viewport meshes a body) and a fine one.
func deflections(a: RefCounted, t: float) -> Array:
	return [clampf((a.bbox() as AABB).size.length() * 0.0015, 1e-5, 0.01), t / 50.0]


func timed(label: String, call: Callable) -> Variant:
	var t0 := Time.get_ticks_msec()
	var out = call.call()
	var ms := Time.get_ticks_msec() - t0
	check(ms < CALL_MS, "%s took %d ms." % [label, ms])
	return out


# --- Open shells ---------------------------------------------------------------------------------

func _open_shells() -> void:
	var built := 0
	var tried := 0
	var cases := []
	for kind in ["bracket", "channel", "step"]:
		for rot in [0, 1, 2]:
			cases.append([kind, 20.0, rot, [0.2, 1.0]])
		cases.append([kind, 100.0, 1 if kind != "step" else 2, [4.0]])
	cases.append(["channel", 100.0, 0, [5.0]])
	for c in cases:
		var a := body(c[0], c[1], c[2])
		if a == null:
			continue
		var top := faces_facing(a, c[2], [Vector3.UP])
		check(top.size() >= 2, "The %s mm %s (rot %d) should have two or more top faces, not %d." % [c[1], c[0], c[2], top.size()])
		for t_mm in c[3]:
			var t: float = t_mm / 1000.0
			var label := "The %s mm %s (rot %d) open at its %d top faces, %s mm" % [c[1], c[0], c[2], top.size(), t_mm]
			var out = timed(label, func(): return kernel.shell(a, top, {"thickness": t, "direction": "inside"}))
			tried += 1
			if out == null:
				var why: String = kernel.get_last_error()
				check(why != "" and not why.contains("try moving or resizing"), "%s was refused with '%s'." % [label, why])
				continue
			built += 1
			check(out.solid_count() == 1, "%s came out as %d solids." % [label, out.solid_count()])
			for lin in deflections(out, t):
				var bad := face_mesh_problems(out, lin)
				check(bad.is_empty(), "%s meshed at %.5f mm doesn't cover its faces: %s." % [label, lin * 1000.0, ", ".join(bad.slice(0, 4))])
	# (All of these were built before, with lids; a fix that only refused them would pass the mesh
	# checks above.)
	check(built >= tried - 2, "Only %d of the %d open shells were built." % [built, tried])
	checked.append("%d of %d brackets, channels and steps open at top faces of two heights mesh every face as it is" % [built, tried])


# --- Saved bodies with misread rims --------------------------------------------------------------

func _saved_rims() -> void:
	var n := 0
	for name in ["shell_rim_hole_touching_rot0.brep", "shell_rim_hole_touching_rot1.brep", "shell_rim_hole_touching_channel.brep"]:
		var bytes := FileAccess.get_file_as_bytes(FIXTURES + name)
		check(not bytes.is_empty(), "The fixture %s should be read." % name)
		if bytes.is_empty():
			continue
		var s: RefCounted = ClassDB.instantiate("CadShape")
		check(s.load_brep_bytes(bytes), "The fixture %s should load." % name)
		for lin in [4e-5, 1e-5, 4e-6]:
			var bad: Array = timed(name, func(): return face_mesh_problems(s, lin))
			check(bad.is_empty(), "The saved shell %s meshed at %.5f mm doesn't cover its faces: %s." % [name, lin * 1000.0, ", ".join(bad.slice(0, 4))])
		n += 1
	checked.append("%d saved shells whose rims' holes touch their outer wires are meshed right" % n)


func _horseshoe() -> void:
	var shoe := PackedVector2Array()
	for p in [Vector2(0, 0), Vector2(5, -6), Vector2(10, 0), Vector2(10, 8), Vector2(8, 8.5), Vector2(7.5, 1), Vector2(5, -2.5), Vector2(2.5, 1), Vector2(2, 8.5), Vector2(0, 8)]:
		shoe.append(p / 1000.0)
	var face: RefCounted = null
	for region in kernel.sketch_regions([{"type": "interp", "points": shoe, "periodic": true}], Transform3D.IDENTITY, 0.0):
		face = region.face if face == null or float(region.area) > float(face.area()) else face
	var prism: RefCounted = kernel.extrude(face, {"direction": Vector3(0, 0, 1), "distance": 0.01}) if face != null else null
	check(prism != null, "The horseshoe prism should build (%s)." % kernel.get_last_error())
	if prism == null:
		return
	var top := faces_facing(prism, 0, [Vector3.BACK])
	var n := 0
	for t_mm in [0.02, 0.05]:
		var t: float = t_mm / 1000.0
		var label := "The horseshoe prism open at the top, %s mm" % t_mm
		var out = timed(label, func(): return kernel.shell(prism, top, {"thickness": t}))
		check(out != null, "%s should be built (%s)." % [label, kernel.get_last_error()])
		if out == null:
			continue
		# (Finer than the rim is wide: at the viewport's deflection, coarser than the 0.02 mm rim,
		# the spline loops' chords make it a tenth narrower, as any mesh of it would be.)
		var bad := face_mesh_problems(out, t / 50.0, 1e-3)
		check(bad.is_empty(), "%s meshed at %.6f mm doesn't cover its faces: %s." % [label, t / 50.0 * 1000.0, ", ".join(bad.slice(0, 4))])
		n += 1
	checked.append("%d horseshoe prisms open at the top mesh their rims as they are" % n)


# --- Refusal reasons -----------------------------------------------------------------------------

## A shell of kind (size mm, rot, param) open at the faces facing open_dirs (in its own frame),
## t mm thick in direction: built (and its faces meshed as they are) or refused for none of the
## untrue reasons.
func shell_case(kind: String, size_mm: float, rot: int, param: float, open_dirs: Array, t_mm: float, direction: String, untrue: Array) -> bool:
	var a := body(kind, size_mm, rot, param)
	if a == null:
		return false
	var open := faces_facing(a, rot, open_dirs)
	var label := "The %s mm %s (rot %d, %s) shelled %s mm %s, open at %d faces" % [size_mm, kind, rot, param, t_mm, direction, open.size()]
	var out = timed(label, func(): return kernel.shell(a, open, {"thickness": t_mm / 1000.0, "direction": direction}))
	if out != null:
		# (Flat faces with straight edges only, which a mesh covers exactly.)
		var bad := face_mesh_problems(out, deflections(out, t_mm / 1000.0)[0]) if kind in ["hexcham", "tet"] else []
		check(bad.is_empty(), "%s doesn't mesh its faces as they are: %s." % [label, ", ".join(bad.slice(0, 4))])
		return true
	var why: String = kernel.get_last_error()
	check(why != "", "%s was refused without a reason." % label)
	for u in untrue:
		check(not why.contains(u), "%s was refused for an untrue reason: '%s'." % [label, why])
	return false


func offset_case(kind: String, size_mm: float, rot: int, param: float, d_mm: float) -> bool:
	var a := body(kind, size_mm, rot, param)
	if a == null:
		return false
	var label := "The %s mm %s (rot %d, %s) offset in by %s mm" % [size_mm, kind, rot, param, d_mm]
	var out = timed(label, func(): return kernel.offset_shape(a, -d_mm / 1000.0))
	if out != null:
		check(out.volume() < a.volume() and out.volume() > 0.0, "%s holds %s m3 of the body's %s m3." % [label, out.volume(), a.volume()])
		return true
	var why: String = kernel.get_last_error()
	# (These bodies are far more than twice the distance thick everywhere: an empty offset is the
	# geometry kernel's failure, and the refusal must say so.)
	check(why != "" and not why.contains("thinner than twice") and (not why.contains("empty") or why.contains("geometry kernel")), "%s was refused for an untrue reason: '%s'." % [label, why])
	return false


func _refusal_reasons() -> void:
	var boolean_advice := "try moving or resizing"
	var built := 0
	var n := 0
	for c in [
		["hexcham", 20.0, 1, 0.8, [Vector3.UP], 0.4, "inside", ["fill the whole body"]],
		["tet", 800.0, 0, 0.0, [Vector3(1, 1, 1).normalized()], 1.6, "both", [boolean_advice]],
		["union", 20.0, 1, 0.0, [Vector3.UP, Vector3.RIGHT, Vector3.BACK], 0.1, "inside", [boolean_advice]],
		["fillet_l", 20.0, 1, 1.0, [], 0.4, "inside", ["the inner wall runs through itself", boolean_advice]],
	]:
		built += int(shell_case(c[0], c[1], c[2], c[3], c[4], c[5], c[6], c[7]))
		n += 1
	for c in [["cham", 0.5, 0, 0.05, 0.005], ["bracket", 20.0, 1, 0.0, 0.1], ["channel", 20.0, 1, 0.0, 0.1], ["step", 20.0, 1, 0.0, 0.1]]:
		built += int(offset_case(c[0], c[1], c[2], c[3], c[4]))
		n += 1
	checked.append("%d shells and offsets once refused for untrue reasons are built (%d) or refused for a true one" % [n, built])


## The 20 mm bracket's thin arm is 4 mm thick. Offset in by 2, 2.01 or 2.015 mm (twice that is the
## arm's thickness or a hair more), and hollowed with a 2 mm wall, it was refused with "although
## the body is more than twice the distance thick everywhere" (the slack for the mesh's deflection
## was put on the wrong side, and the search for the far side stopped at just twice the distance);
## only from 2.03 mm did the refusal name the thin spot. At and around the boundary the refusal
## must name the thin spot, and never say the body is thicker than it is.
func _thin_boundary() -> void:
	var a := body("bracket", 20.0, 1)
	if a == null:
		return
	var n := 0
	for d_mm in [1.99, 2.0, 2.01, 2.015, 2.03, 2.06]:
		var label := "The 20 mm bracket (4 mm thick at its thin arm) offset in by %s mm" % d_mm
		var out = timed(label, func(): return kernel.offset_shape(a, -d_mm / 1000.0))
		if out != null:
			check(d_mm < 2.0 and out.volume() < a.volume() and out.volume() > 0.0, "%s was built holding %s m3 of the body's %s m3." % [label, out.volume(), a.volume()])
			continue
		var why: String = kernel.get_last_error()
		check(why != "" and not why.contains("more than twice"), "%s was refused for an untrue reason: '%s'." % [label, why])
		if d_mm >= 2.0:
			check(why.contains("4 mm thick"), "%s should be refused naming the 4 mm thin spot, not with '%s'." % [label, why])
		n += 1
	for t_mm in [2.0, 2.01, 2.03]:
		var label := "The 20 mm bracket (4 mm thick at its thin arm) hollowed with a %s mm wall" % t_mm
		var out = timed(label, func(): return kernel.shell(a, PackedInt32Array(), {"thickness": t_mm / 1000.0}))
		check(out == null, "%s leaves no room in its thin arm and should be refused." % label)
		if out != null:
			continue
		var why: String = kernel.get_last_error()
		check(not why.contains("more than twice") and why.contains("4 mm thick"), "%s should be refused naming the 4 mm thin spot, not with '%s'." % [label, why])
		n += 1
	# (Where the body is clearly thicker, an empty offset is still the geometry kernel's failure:
	# the bracket offset in by 0.1 mm, in _refusal_reasons.)
	checked.append("%d offsets and hollows at about half the bracket's 4 mm arm are refused naming the thin spot" % n)


## Spline faces were never checked by the per-face mesh guard. The fixture holds the eight faces
## around two corners of a fillet the build before the fix handed back (2.6 mm on an edge of the
## converted O1 body, at the geometry kernel's own loose fit): each corner lies 1.7 mm off the
## edges that meet there, so the mesh of every face around it is pulled off the face (63.5 mm2 of
## mesh on a 59.5 mm2 face, 8.1 on 5.25) at every deflection. Such a fillet is refused now, but a
## body saved with one must not be drawn without a word: tessellate warns of each such face, in a
## sentence (the warning itself came out as "unsupported format character").
func _saved_blend() -> void:
	var name := "form_fillet_corner_off_edges.brep"
	var bytes := FileAccess.get_file_as_bytes(FIXTURES + name)
	check(not bytes.is_empty(), "The fixture %s should be read." % name)
	if bytes.is_empty():
		return
	var s: RefCounted = ClassDB.instantiate("CadShape")
	check(s.load_brep_bytes(bytes), "The fixture %s should load." % name)
	check(s.face_count() == 8, "The fixture %s should hold its 8 faces, not %d." % [name, s.face_count()])
	for lin in [5e-5, 7e-6]:
		var t: Dictionary = timed(name, func(): return s.tessellate(lin, 0.3))
		var warnings: PackedStringArray = t.get("warnings", PackedStringArray())
		check(warnings.size() == s.face_count(), "Each of the saved fillet's %d faces, meshed at %.4f mm, lies off itself and should be warned of (%d warnings)." % [s.face_count(), lin * 1000.0, warnings.size()])
		for w in warnings:
			check(w.begins_with("face ") and w.contains(" mm off the face") and w.contains("drawn and exported wrong"), "The warning should say which face lies how far off itself, not '%s'." % w)
	checked.append("a saved fillet whose corners lie off their edges is drawn with a warning for each of its %d spline faces" % s.face_count())
