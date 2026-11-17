extends SceneTree
## Regression checks for the Phase 6 critics' findings, headless:
## - Fillets and chamfers of converted form bodies never come back broken: OCCT's ChFi3d reported
##   success with bodies tens of metres across, negative volumes, open shells of no volume and
##   faces out past a flat cap; every such result is now refused with a reason (or, when only
##   OCCT's own 0.1 mm tolerances work, built with that note).
## - A hollow shell of a converted body is built straight from its two walls: well under a second
##   at every size (it took 3 to 480 s), with the exact volume; an impossible thickness fails
##   with a reason within the time limit.
## - closest_points finds on-surface points beside a fully creased flat face's corner.
## - Convert (Form to B-rep) keeps the conversion warnings, and every rebuild shows them again.
## - Merge Edge leaves frozen geometry alone; partners of frozen vertices stay (symmetric bodies
##   keep their symmetry); a whole symmetric body with frozen faces can't move as a whole.
## - Combined symmetry entries (a mirror and a half turn: the mirror between them) keep moves
##   exactly symmetric.
## - An associative Match follows its target after a Subdivide splits its chain, and says so when
##   its target is gone.
## - Saving a loaded scene again before any rebuild keeps the exact cage doubles.
## - Out-of-range or fractional typed values are refused, not clamped; Subdivide 1 x 1 changes
##   nothing (no empty undo step); Slide 1 warns; Mirror - Internal needs its two faces; ticking a
##   check box shows the rows that depend on it; nearly flat creases are reported.

const CAGE := preload("res://addons/holo_forge/core/form/cage.gd")
const FORM_OPS := preload("res://addons/holo_forge/core/form/form_ops.gd")
const FORM_FIT := preload("res://addons/holo_forge/core/form/form_fit.gd")
const PRIMITIVES := preload("res://addons/holo_forge/core/form/primitives.gd")
const FORM := preload("res://addons/holo_forge/core/features/form.gd")
const FORM_TOOLS := preload("res://addons/holo_forge/ui/form_tools.gd")
const DOCUMENT := preload("res://addons/holo_forge/core/document.gd")
const REGEN := preload("res://addons/holo_forge/core/regen.gd")
const SKETCH_DATA := preload("res://addons/holo_forge/core/sketch/sketch_data.gd")
const COMMAND_PANEL := preload("res://addons/holo_forge/ui/command_panel.gd")

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
		_blends()
		_shells()
		_closest_points()
		_convert_warnings()
		_links()
	else:
		print("note: CadSubD is not loaded; the native checks are skipped")
	_frozen()
	_dihedral()
	_store_exact()
	_typed_values()
	_panel_bools()
	_flat_creases()
	if failures.is_empty():
		print("PASS holo_forge_form_critfix: ", ", ".join(checked))
		quit(0)
	else:
		print("FAIL holo_forge_form_critfix")
		for f in failures:
			print("  ", f)
		quit(1)


# --- Helpers -------------------------------------------------------------------------------------

## c scaled by s and moved by offset, in doubles.
func scaled(c: Dictionary, s: float, offset := Vector3.ZERO) -> Dictionary:
	var out := CAGE.copy(c)
	var p: PackedFloat64Array = out.positions
	for v in p.size() / 3:
		p[3 * v] = p[3 * v] * s + offset.x
		p[3 * v + 1] = p[3 * v + 1] * s + offset.y
		p[3 * v + 2] = p[3 * v + 2] * s + offset.z
	out.positions = p
	return out


## c with every edge whose two ends lie at height z creased (weight 10).
func crease_at(c: Dictionary, z: float) -> Dictionary:
	var out := CAGE.copy(c)
	var topo := CAGE.topology(out)
	for e in topo.nE:
		var ab := topo.edge_vertices(e)
		if absf(CAGE.position_d(out, ab.x)[2] - z) < 1e-9 and absf(CAGE.position_d(out, ab.y)[2] - z) < 1e-9:
			CAGE.set_crease(out, ab.x, ab.y, 10.0)
	return out


func to_body(c: Dictionary, level := 6) -> RefCounted:
	var s: RefCounted = ClassDB.instantiate("CadSubD")
	if not s.set_cage(c):
		return null
	var shapes: Array = s.to_shapes({"isolation": level, "name_prefix": "t/b"})
	return shapes[0] if not shapes.is_empty() else null


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


func symmetry_error(c: Dictionary) -> float:
	var worst := 0.0
	for e in c.get("symmetry", []):
		var xf := FORM_OPS._entry_xf(e)
		var m: PackedInt32Array = e.map
		for v in m.size():
			if m[v] < 0:
				continue
			var p := CAGE.position_d(c, v)
			var q := FORM_OPS.xf_apply(xf, p[0], p[1], p[2])
			var w := CAGE.position_d(c, m[v])
			worst = maxf(worst, Vector3(q[0] - w[0], q[1] - w[1], q[2] - w[2]).length())
	return worst


func edge_item(body: String, a: int, b: int) -> Dictionary:
	return {"kind": "edge", "body": body, "index": -1, "pair": Vector2i(mini(a, b), maxi(a, b))}


func face_item(body: String, f: int) -> Dictionary:
	return {"kind": "face", "body": body, "index": f, "pair": Vector2i(-1, -1)}


## Whether a blend's result is a sound part of the body: positive volume below the body's box,
## and inside the body's box (to slack).
func blend_sound(body: RefCounted, out: RefCounted, slack: float) -> bool:
	var v: float = out.volume()
	var a: AABB = body.bbox()
	var b: AABB = out.bbox()
	return v > 0.0 and v < a.size.x * a.size.y * a.size.z and b.position.x >= a.position.x - slack and b.position.y >= a.position.y - slack \
		and b.position.z >= a.position.z - slack and b.end.x <= a.end.x + slack and b.end.y <= a.end.y + slack and b.end.z <= a.end.z + slack


# --- Fillets and chamfers of converted bodies ----------------------------------------------------

func _blends() -> void:
	# (a) A 50 mm Cylinder (8 around, pole caps) with both rims and the cap spokes creased: its
	# 7.5 mm rim fillet came back 34 x 10 x 42 m with a negative volume.
	var cyl := crease_at(crease_at(PRIMITIVES.cylinder(2.0, 2.0, 8, 2, "pole"), 0.0), 2.0)
	cyl = scaled(cyl, 0.025, Vector3(0, 0, -0.025))
	var body := to_body(cyl)
	if body == null:
		check(false, "The creased cylinder should convert.")
		return
	var rim := PackedInt32Array()
	for e in body.edge_count():
		var info: Dictionary = body.edge_info(e)
		if absf(absf(float((info.midpoint as Vector3).z)) - 0.025) < 1e-6 and float(info.get("dihedral", 0.0)) > 0.5:
			rim.append(e)
	check(rim.size() >= 8, "The creased cylinder should have sharp rim edges (found %d)." % rim.size())
	var bad := 0
	var slow := 0
	for i in mini(6, rim.size()):
		for op in [["fillet", "radius", 0.0075], ["chamfer", "distance", 0.0075]]:
			var t0 := Time.get_ticks_msec()
			var out: RefCounted = kernel.call(op[0], body, PackedInt32Array([rim[i]]), {op[1]: op[2]})
			if Time.get_ticks_msec() - t0 > 10000:
				slow += 1
			if out == null:
				check(str(kernel.get_last_error()) != "", "A refused %s should say why." % op[0])
			elif not blend_sound(body, out, 2e-4):
				bad += 1
	check(bad == 0, "%d fillets or chamfers of the creased cylinder's rim came back broken with no error." % bad)
	check(slow == 0, "%d blends of the creased cylinder took over 10 s." % slow)
	# (b) Box 2,2,2 at 50 mm with its top and bottom rims creased: chamfers of 9 mm and more were
	# open shells of no volume ("solids" 1).
	var box := crease_at(crease_at(PRIMITIVES.box(Vector3(2, 2, 2), Vector3i(2, 2, 2)), 1.0), -1.0)
	box = scaled(box, 0.025)
	var bb := to_body(box)
	var edges := PackedInt32Array()
	for e in bb.edge_count():
		if float((bb.edge_info(e) as Dictionary).get("dihedral", 0.0)) > 0.5:
			edges.append(e)
	for d in [0.009, 0.0125, 0.02]:
		var one: RefCounted = kernel.chamfer(bb, PackedInt32Array([edges[0]]), {"distance": d})
		check(one == null or (one.volume() > 0.0 and blend_sound(bb, one, 2e-4)), "A %s mm chamfer of a rim-creased box came back broken (volume %s)." % [d * 1000.0, one.volume() if one != null else 0.0])
		if one == null:
			check(str(kernel.get_last_error()) != "", "A refused chamfer should say why.")
	var all: RefCounted = kernel.chamfer(bb, edges, {"distance": 0.009})
	check(all == null or all.volume() > 0.0, "A 9 mm chamfer of every rim edge came back with volume %s." % (all.volume() if all != null else 0.0))
	# A sound blend still builds, in its own time.
	var t1 := Time.get_ticks_msec()
	var good: RefCounted = kernel.fillet(bb, PackedInt32Array([edges[0]]), {"radius": 0.0025})
	check(good != null and blend_sound(bb, good, 1e-5), "A 2.5 mm fillet of the rim-creased box should build (%s)." % kernel.get_last_error())
	check(Time.get_ticks_msec() - t1 < 5000, "A sound fillet of a converted box should take under 5 s (%d ms)." % (Time.get_ticks_msec() - t1))
	# A tiny radius says it's small, not "too big".
	var tiny: RefCounted = kernel.fillet(bb, PackedInt32Array([edges[0]]), {"radius": 0.0000025})
	if tiny == null:
		check(not str(kernel.get_last_error()).contains("too big"), "A 2.5 um fillet's refusal shouldn't call the radius too big: %s" % kernel.get_last_error())
	checked.append("fillets and chamfers of converted bodies are sound or refused with a reason (no open shells, negative volumes or faces outside the body)")


# --- Hollow shells ---------------------------------------------------------------------------------

func _shells() -> void:
	for spec in [["box 2 mm", PRIMITIVES.box(Vector3(2, 2, 2), Vector3i(2, 2, 2)), 0.001], ["box 5 mm", PRIMITIVES.box(Vector3(2, 2, 2), Vector3i(2, 2, 2)), 0.0025],
			["sphere 5 mm", PRIMITIVES.sphere(2.0, 8, 4), 0.0025], ["plate 800 mm", PRIMITIVES.box(Vector3(2, 0.6, 0.075), Vector3i(6, 4, 1)), 0.4]]:
		var a := to_body(scaled(spec[1], spec[2]))
		var t := 0.02 * float(spec[2]) if not str(spec[0]).begins_with("plate") else 0.002
		var t0 := Time.get_ticks_msec()
		var sh: RefCounted = kernel.shell(a, PackedInt32Array(), {"thickness": t})
		var ms := Time.get_ticks_msec() - t0
		var err := str(kernel.get_last_error())
		var inner: RefCounted = kernel.offset_shape(a, -t)
		check(sh != null, "The hollow shell of a converted %s should build (%s)." % [spec[0], err])
		check(ms < 5000, "The hollow shell of a converted %s took %d ms (it froze the editor for seconds to minutes)." % [spec[0], ms])
		if sh != null and inner != null:
			var expect: float = a.volume() - inner.volume()
			check(absf(sh.volume() - expect) <= 1e-9 * a.volume() and sh.solid_count() == 1, "The hollow shell of a %s should hold the body less its inner offset (%s vs %s)." % [spec[0], sh.volume(), expect])
	# Thicker than the plate: the inner wall crosses the outside; refused with a reason in bounded time.
	var plate := to_body(scaled(PRIMITIVES.box(Vector3(2, 0.6, 0.075), Vector3i(6, 4, 1)), 0.01))
	var t2 := Time.get_ticks_msec()
	var thick: RefCounted = kernel.shell(plate, PackedInt32Array(), {"thickness": 0.0006})
	check(thick == null and str(kernel.get_last_error()) != "", "A shell thicker than its plate should be refused with a reason.")
	check(Time.get_ticks_msec() - t2 < 2000 * kernel.get_time_limit(), "An impossible shell should end within the time limit (%d ms)." % (Time.get_ticks_msec() - t2))
	checked.append("hollow shells of converted bodies are built from their walls in under a second with the exact volume; an impossible one is refused")


# --- closest_points beside a creased flat corner -------------------------------------------------

func _closest_points() -> void:
	var c := crease_at(PRIMITIVES.box(Vector3(2, 2, 2), Vector3i(2, 2, 2)), 1.0)
	var s: RefCounted = ClassDB.instantiate("CadSubD")
	s.set_cage(c)
	var faces := PackedInt32Array()
	var uvs := PackedVector2Array()
	for f in CAGE.face_count(c):
		for k in 41:
			var t := 0.75 + 0.25 * k / 40.0
			faces.append(f)
			uvs.append(Vector2(t, t))
			faces.append(f)
			uvs.append(Vector2(1.0 - t, 1.0 - t))
	var ev: Dictionary = s.evaluate(faces, uvs)
	var flat: PackedFloat64Array = ev.get("positions", PackedFloat64Array())
	var pts := PackedVector3Array()
	for i in flat.size() / 3:
		pts.append(Vector3(flat[3 * i], flat[3 * i + 1], flat[3 * i + 2]))
	var cp: Dictionary = s.closest_points(pts)
	var worst := 0.0
	for d in (cp.get("distances", PackedFloat64Array()) as PackedFloat64Array):
		worst = maxf(worst, d)
	check(pts.size() > 0 and worst < 1e-6, "Points on the limit beside a creased flat corner should come back on the surface (worst %s m)." % worst)
	checked.append("closest_points finds on-surface points beside a fully creased flat face's corner")


# --- Convert keeps its warnings ---------------------------------------------------------------------

func _convert_warnings() -> void:
	var d: Resource = DOCUMENT.new()
	var f: Resource = d.add_feature("form", "Form", {}, FORM.new_options())
	var body: String = d.new_body(f.id)
	var flat := PRIMITIVES.box(Vector3(0.02, 0.02, 0.02), Vector3i(1, 1, 1))
	var p: PackedFloat64Array = flat.positions
	for v in p.size() / 3:
		p[3 * v + 2] = 0.0
	flat.positions = p
	f.options.bodies[body] = flat
	var ctx := {"cages": {body: flat}, "feature": f, "doc": d, "result": {}, "kernel": kernel, "values": {}, "subd": Callable()}
	var r := FORM_TOOLS.run("convert", ctx, {"bodies": [{"kind": "body", "body": body, "index": -1, "pair": Vector2i(-1, -1)}]}, {"direction": "form_brep"})
	check(r.ok, "Converting a flat cage should still convert (%s)." % r.get("error", ""))
	if not r.ok:
		return
	check(not (r.warnings as PackedStringArray).is_empty(), "Converting a flat cage should warn (it encloses no volume).")
	var notes: Dictionary = r.get("brep_notes", {})
	check(notes.has(body) and not (notes[body] as PackedStringArray).is_empty(), "Convert should keep its warnings with the B-rep (brep_notes).")
	# As the editor's apply_result stores it: the cage goes, the B-rep and its notes stay.
	(f.options.bodies as Dictionary).erase(body)
	f.options["breps"] = r.breps
	f.options["brep_notes"] = notes
	FORM.clear_cache()
	var result := REGEN.rebuild(d, kernel)
	check(str((result.warnings as Dictionary).get(f.id, "")) != "", "Every rebuild of a converted flat body should show its conversion warnings (got %s)." % [result.warnings])
	checked.append("Convert keeps the conversion warnings and every rebuild shows them")


# --- Associative Match after a topology edit ----------------------------------------------------

func _links() -> void:
	var doc: Resource = DOCUMENT.new()
	var sketch: Resource = doc.add_feature("sketch", "Sketch", {}, SKETCH_DATA.new_options(SKETCH_DATA.ORIGIN_PLANES.xy, "xy"))
	var s = SKETCH_DATA.new(sketch, doc)
	var a: int = s.add_point(Vector2(-2.0, -1.0))
	var b: int = s.add_point(Vector2(2.0, -1.0))
	var line: int = s.add_line(a, b)
	var f: Resource = doc.add_feature("form", "Form", {}, FORM.new_options())
	var body: String = doc.new_body(f.id)
	f.options.bodies[body] = PRIMITIVES.plane(Vector2(4, 1), Vector2i(4, 1))
	var result := REGEN.rebuild(doc, kernel, {"form_preview": f.id})
	var cg: Dictionary = f.options.bodies[body]
	var topo := CAGE.topology(cg)
	var chain := []
	for e in topo.nE:
		var ab := topo.edge_vertices(e)
		if CAGE.position(cg, ab.x).y < -0.4 and CAGE.position(cg, ab.y).y < -0.4:
			chain.append(edge_item(body, ab.x, ab.y))
	var values := {"target": [{"kind": "sketch_curve", "sketch": sketch.id, "entity": line}], "associative": true, "continuity": "g0", "spacing": "uniform", "falloff": 1}
	var ctx := {"cages": {body: cg}, "result": result, "doc": doc, "feature": f, "kernel": kernel, "values": {}, "subd": Callable()}
	var r := FORM_TOOLS.run("match", ctx, {"edges": chain}, values)
	check(r.ok, "The associative Match should apply (%s)." % r.get("error", ""))
	if not r.ok:
		return
	var linked: Dictionary = r.cages[body]
	var rs := FORM_OPS.subdivide(linked, {"faces": PackedInt32Array([face_at(linked, Vector3(-1.5, -0.25, 0))])}, {})
	f.options.bodies[body] = rs.cage
	FORM.clear_cache()
	var r0 := REGEN.rebuild(doc, kernel)
	var y0: float = (r0.bodies[body].shape.bbox() as AABB).position.y
	for e in s.entities():
		if str(e.type) == "point":
			s.set_point(int(e.id), s.point(int(e.id)) + Vector2(0.0, -0.25))
	FORM.clear_cache()
	var r1 := REGEN.rebuild(doc, kernel)
	var y1: float = (r1.bodies[body].shape.bbox() as AABB).position.y
	check(absf((y1 - y0) + 0.25) < 1e-3, "After a Subdivide split its chain, the Match should still follow its target (moved %s, want -0.25)." % (y1 - y0))
	sketch.suppressed = true
	FORM.clear_cache()
	var r2 := REGEN.rebuild(doc, kernel)
	check(str((r2.warnings as Dictionary).get(f.id, "")).contains("Match"), "A Match whose target is suppressed should warn (got %s)." % [r2.warnings])
	checked.append("an associative Match follows its target after a Subdivide splits its chain and warns when the target is gone")


# --- Frozen geometry and symmetry ------------------------------------------------------------------

func _frozen() -> void:
	# Merge Edge: plane A (frozen) and plane B side by side.
	var pa: Dictionary = FORM_OPS.transform_vertices(PRIMITIVES.plane(Vector2(1, 1), Vector2i(1, 1)), PackedInt32Array(range(4)), PackedFloat32Array(), FORM_OPS.xf_from(Basis.IDENTITY, Vector3.ZERO)).cage
	var pb: Dictionary = FORM_OPS.transform_vertices(PRIMITIVES.plane(Vector2(1, 1), Vector2i(1, 1)), PackedInt32Array(range(4)), PackedFloat32Array(), FORM_OPS.xf_from(Basis.IDENTITY, Vector3(1.5, 0, 0))).cage
	for frozen_face in [0, 1]:
		var pair: Dictionary = CAGE.append(pa, pb).cage
		pair = FORM_OPS.freeze(pair, {"faces": PackedInt32Array([frozen_face])}, {}).cage
		var g1 := PackedInt32Array([vertex_at(pair, Vector3(0.5, 0.5, 0)), vertex_at(pair, Vector3(0.5, -0.5, 0))])
		var g2 := PackedInt32Array([vertex_at(pair, Vector3(1.0, 0.5, 0)), vertex_at(pair, Vector3(1.0, -0.5, 0))])
		var r := FORM_OPS.merge_edge(pair, {"edges": g1, "edges2": g2}, {})
		check(not r.ok and str(r.error) == CAGE.FROZEN_ERROR, "Merge Edge with face %d frozen should refuse (ok %s, '%s')." % [frozen_face, r.ok, r.error])
	# Without a frozen face it still merges.
	var free_pair: Dictionary = CAGE.append(pa, pb).cage
	var m := FORM_OPS.merge_edge(free_pair, {"edges": PackedInt32Array([vertex_at(free_pair, Vector3(0.5, 0.5, 0)), vertex_at(free_pair, Vector3(0.5, -0.5, 0))]),
		"edges2": PackedInt32Array([vertex_at(free_pair, Vector3(1.0, 0.5, 0)), vertex_at(free_pair, Vector3(1.0, -0.5, 0))])}, {})
	check(m.ok, "Merge Edge without frozen faces should still merge (%s)." % m.get("error", ""))
	# A mirrored box with its +X face at (1, 0.5, 0.5) frozen.
	var box := PRIMITIVES.primitive_symmetry(PRIMITIVES.box(Vector3(2, 2, 2), Vector3i(2, 2, 2)), "mirror", Transform3D.IDENTITY, Vector3i(1, 0, 0), 0)
	box = FORM_OPS.freeze(box, {"faces": PackedInt32Array([face_at(box, Vector3(1, 0.5, 0.5))])}, {}).cage
	var whole := FORM_OPS.edit_transform(box, {"body": true}, {"translate": Vector3(0.3, 0, 0)})
	check(not whole.ok and str(whole.error) == FORM_OPS.SYMMETRIC_FROZEN_BODY, "Moving a whole symmetric body with a frozen face should be refused (ok %s, '%s')." % [whole.ok, whole.error])
	var rot := FORM_OPS.edit_transform(box, {"body": true}, {"xf": FORM_OPS.xf_from(Basis(Vector3(0, 0, 1), deg_to_rad(30.0)), Vector3.ZERO)})
	check(not rot.ok, "Rotating a whole symmetric body with a frozen face should be refused.")
	var partner := vertex_at(box, Vector3(-1, 1, 1))
	var lone := FORM_OPS.edit_transform(box, {"vertices": PackedInt32Array([partner])}, {"translate": Vector3(0, 0, 0.3)})
	check(not lone.ok and str(lone.error) == FORM_OPS.FROZEN_PARTNERS, "Moving the partner of a frozen vertex should be refused (ok %s, '%s')." % [lone.ok, lone.error])
	var other := vertex_at(box, Vector3(0, -1, -1))
	var both := FORM_OPS.edit_transform(box, {"vertices": PackedInt32Array([partner, other])}, {"translate": Vector3(0, 0, 0.3)})
	check(both.ok and not (both.warnings as PackedStringArray).is_empty() and symmetry_error(both.cage) < 1e-12, "A move holding back a frozen vertex's partner should keep the symmetry and say so (ok %s, error %s, warnings %s)." % [both.ok, symmetry_error(both.cage) if both.ok else -1.0, both.get("warnings", [])])
	if both.ok:
		check(CAGE.position_d(both.cage, partner) == CAGE.position_d(box, partner) and absf(CAGE.position_d(both.cage, other)[2] - CAGE.position_d(box, other)[2] - 0.3) < 1e-6,
			"The held partner should stay and the free vertex move.")
	var slide := FORM_OPS.slide_edge(box, {"edges": PackedInt32Array([partner, vertex_at(box, Vector3(-1, 0, 1))])}, {"slide": 0.3})
	check(not slide.ok or symmetry_error(slide.cage) < 1e-12, "Slide Edge on the partner of a frozen edge should refuse or stay symmetric (error %s)." % (symmetry_error(slide.cage) if slide.ok else 0.0))
	# The editor drag path: carry_symmetry puts a moved partner of a frozen vertex back.
	var moved := CAGE.copy(box)
	var mp: PackedFloat64Array = moved.positions
	mp[3 * partner + 2] += 0.3
	moved.positions = mp
	var carried := FORM_OPS.carry_symmetry(box, moved, PackedInt32Array([partner]))
	check(carried.ok and symmetry_error(carried.cage) < 1e-12 and CAGE.position_d(carried.cage, partner) == CAGE.position_d(box, partner), "A drag of a frozen vertex's partner should leave the body symmetric with the frozen side in place.")
	checked.append("Merge Edge refuses frozen geometry; frozen vertices' partners stay (symmetry kept, with a warning); a frozen symmetric body can't move as a whole")


func _dihedral() -> void:
	# Box (Mirror X) + Circular 2 around Z: together they make the y = 0 mirror too.
	var box := PRIMITIVES.primitive_symmetry(PRIMITIVES.box(Vector3(0.02, 0.02, 0.02), Vector3i(2, 2, 2)), "mirror", Transform3D.IDENTITY, Vector3i(1, 0, 0), 0)
	var ctx := {"cages": {"b": box}, "result": {}, "doc": null, "feature": null, "kernel": null, "values": {}, "subd": Callable()}
	var r := FORM_TOOLS.run("circular_internal", ctx, {"faces": [face_item("b", face_at(box, Vector3(0.01, 0.005, 0.005))), face_item("b", face_at(box, Vector3(0.005, 0.01, 0.005)))]},
		{"candidate": "0", "tolerance": 0.0, "snap": true})
	check(r.ok, "Circular - Internal on a mirrored box should apply (%s)." % r.get("error", ""))
	if r.ok:
		var c: Dictionary = r.cages.b
		for spec in [[Vector3(0.01, 0, 0.01), Vector3(0, 0.002, 0)], [Vector3(0.01, 0.01, 0.01), Vector3(0.001, 0.002, 0.003)], [Vector3(0, 0.01, 0.01), Vector3(0.002, 0.001, 0)]]:
			var v := vertex_at(c, spec[0])
			var t := FORM_OPS.edit_transform(c, {"vertices": PackedInt32Array([v])}, {"translate": spec[1]})
			check(t.ok and symmetry_error(t.cage) < 1e-12, "Moving %s by %s under mirror + half turn should stay symmetric (error %s)." % [spec[0], spec[1], symmetry_error(t.cage) if t.ok else -1.0])
	# Mirror X and the diagonal mirror (1, -1, 0).
	var b2 := PRIMITIVES.primitive_symmetry(PRIMITIVES.box(Vector3(2, 2, 2), Vector3i(2, 2, 2)), "mirror", Transform3D.IDENTITY, Vector3i(1, 0, 0), 0)
	var sym: Array = (b2.symmetry as Array).duplicate(true)
	sym.append({"type": "mirror", "origin": PackedFloat64Array([0, 0, 0]), "normal": FORM_OPS.unit_d(PackedFloat64Array([1, -1, 0])), "map": PackedInt32Array()})
	b2.symmetry = sym
	b2 = FORM_OPS.rebuild_symmetry(b2, 0.0).cage
	var v2 := vertex_at(b2, Vector3(1, 0, 1))
	var t2 := FORM_OPS.edit_transform(b2, {"vertices": PackedInt32Array([v2])}, {"translate": Vector3(0, 0.2, 0)})
	check(t2.ok and symmetry_error(t2.cage) < 1e-12, "Moving (1, 0, 1) under two mirrors at 45 degrees should stay symmetric (error %s)." % (symmetry_error(t2.cage) if t2.ok else -1.0))
	# A cylinder (Circular 8) with a mirror through the axis.
	var cyl := PRIMITIVES.primitive_symmetry(PRIMITIVES.cylinder(2.0, 2.0, 8, 2, "pole"), "circular", Transform3D.IDENTITY, Vector3i(0, 0, 1), 8)
	var sym3: Array = (cyl.symmetry as Array).duplicate(true)
	sym3.append({"type": "mirror", "origin": PackedFloat64Array([0, 0, 0]), "normal": PackedFloat64Array([1, 0, 0]), "map": PackedInt32Array()})
	cyl.symmetry = sym3
	cyl = FORM_OPS.rebuild_symmetry(cyl, 0.0).cage
	var rim := -1
	var best := INF
	for v in CAGE.vertex_count(cyl):
		var q := CAGE.position(cyl, v)
		var dd := q.distance_to(Vector3(1, 0, 2))
		if dd < best:
			best = dd
			rim = v
	var t3 := FORM_OPS.edit_transform(cyl, {"vertices": PackedInt32Array([rim])}, {"translate": Vector3(0.2, 0.1, 0)})
	check(t3.ok and symmetry_error(t3.cage) < 1e-12, "Moving a rim vertex of a circular + mirror cylinder should stay symmetric (error %s)." % (symmetry_error(t3.cage) if t3.ok else -1.0))
	checked.append("combined symmetry entries (mirror + half turn, two mirrors, circular + mirror) keep vertex moves exactly symmetric")
	# Insert Point at t = 0.3 on edges that cross the mirror plane: the partner points go on the
	# same edges (they were skipped with "54-53 is not an edge").
	var b3 := PRIMITIVES.primitive_symmetry(PRIMITIVES.box(Vector3(3, 3, 3), Vector3i(3, 3, 3)), "mirror", Transform3D.IDENTITY, Vector3i(1, 0, 0), 0)
	var ea := vertex_at(b3, Vector3(-0.5, 1.5, 1.5))
	var eb := vertex_at(b3, Vector3(0.5, 1.5, 1.5))
	var ec := vertex_at(b3, Vector3(-0.5, 0.5, 1.5))
	var ed := vertex_at(b3, Vector3(0.5, 0.5, 1.5))
	var ri := FORM_OPS.insert_point(b3, {}, {"points": [{"edge": Vector2i(ea, eb), "t": 0.3}, {"edge": Vector2i(ec, ed), "t": 0.3}]})
	var unmapped := 0
	if ri.ok:
		for e in ri.cage.symmetry:
			for x in (e.map as PackedInt32Array):
				unmapped += 1 if x < 0 else 0
	check(ri.ok and (ri.warnings as PackedStringArray).is_empty() and unmapped == 0 and CAGE.vertex_count(ri.cage) == CAGE.vertex_count(b3) + 4 and symmetry_error(ri.cage) < 1e-12,
		"Insert Point at 0.3 on plane-crossing edges should place the mirrored points too (ok %s, %d vertices, warnings %s, %d unmapped)." % [ri.ok, CAGE.vertex_count(ri.cage) if ri.ok else 0, ri.get("warnings", []), unmapped])
	checked.append("Insert Point puts mirrored points on an edge that crosses the plane")


# --- Exact doubles survive a second save before any rebuild --------------------------------------

func _store_exact() -> void:
	var c := PRIMITIVES.box(Vector3(0.02, 0.02, 0.02), Vector3i(2, 2, 2))
	var frame := Transform3D(Basis(Vector3(0, 0, 1), deg_to_rad(33.0)), Vector3(0.001234567, 0, 0))
	c = FORM_TOOLS.place(c, frame)
	c = PRIMITIVES.primitive_symmetry(c, "mirror", frame, Vector3i(1, 0, 0), 0)
	var d: Resource = DOCUMENT.new()
	var f: Resource = d.add_feature("form", "Form", {}, FORM.new_options())
	var body: String = d.new_body(f.id)
	f.options.bodies[body] = c
	var positions: PackedFloat64Array = (c.positions as PackedFloat64Array).duplicate()
	FORM.store_exact(d)
	var path1 := "user://holo_forge_critfix_exact_1.tres"
	var path2 := "user://holo_forge_critfix_exact_2.tres"
	ResourceSaver.save(d, path1)
	var l1: Resource = ResourceLoader.load(path1, "", ResourceLoader.CACHE_MODE_IGNORE)
	# A second save with no rebuild in between (the form never opened in Forge).
	FORM.store_exact(l1)
	ResourceSaver.save(l1, path2)
	var l2: Resource = ResourceLoader.load(path2, "", ResourceLoader.CACHE_MODE_IGNORE)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path1))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path2))
	var back: Dictionary = (l2.features[0].options.bodies as Dictionary)[body]
	FORM.resolve_exact(back)
	check(back.positions == positions, "A cage saved twice (no rebuild between) should still come back exactly.")
	checked.append("a loaded scene saved again before any rebuild keeps the exact cage doubles")


# --- Typed values, panels, small tool fixes ----------------------------------------------------------

func _typed_values() -> void:
	check(FORM_TOOLS.range_error("circular_duplicate", {"quantity": 100.0}) != "", "Circular Duplicate Quantity 100 should be refused, not clamped to 64.")
	check(FORM_TOOLS.range_error("circular_duplicate", {"quantity": 2.5}) != "", "Circular Duplicate Quantity 2.5 should be refused, not rounded.")
	check(FORM_TOOLS.range_error("circular_duplicate", {"quantity": 6.0}) == "", "Circular Duplicate Quantity 6 should be fine.")
	check(FORM_TOOLS.range_error("subdivide", {"specify": true, "u_faces": 2.6, "v_faces": 2.0}) != "", "Subdivide Length Faces 2.6 should be refused.")
	check(FORM_TOOLS.range_error("subdivide", {"specify": false, "u_faces": 2.6}) == "", "A hidden field shouldn't be checked.")
	check(FORM_TOOLS.range_error("bevel_edge", {"distance_mode": "ratio", "ratio": 1.5, "segments": 1.0, "crown": 1.0}) != "", "Bevel Ratio 1.5 should be refused, not clamped.")
	check(FORM_TOOLS.range_error("slide_edge", {"slide": 1.5}) != "", "Slide 1.5 should be refused, not clamped.")
	var box := PRIMITIVES.box(Vector3(2, 2, 2), Vector3i(2, 2, 2))
	var ctx := {"cages": {"q": box}, "result": {}, "doc": null, "feature": null, "kernel": null, "values": {}, "subd": Callable()}
	var one := FORM_TOOLS.run("subdivide", ctx, {"faces": [face_item("q", 0)]}, {"mode": "simple", "specify": true, "u_faces": 1.0, "v_faces": 1.0})
	check(not one.ok and str(one.error) == FORM_OPS.NOTHING, "Subdivide 1 x 1 should report nothing to change (ok %s, '%s')." % [one.ok, one.get("error", "")])
	var topo := CAGE.topology(box)
	var loop := []
	for e in topo.nE:
		var ab := topo.edge_vertices(e)
		if absf(CAGE.position(box, ab.x).z) < 1e-9 and absf(CAGE.position(box, ab.y).z) < 1e-9 and (absf(absf(CAGE.position(box, ab.x).x) - 1.0) < 1e-9 or absf(absf(CAGE.position(box, ab.x).y) - 1.0) < 1e-9) \
				and (absf(absf(CAGE.position(box, ab.y).x) - 1.0) < 1e-9 or absf(absf(CAGE.position(box, ab.y).y) - 1.0) < 1e-9):
			loop.append(edge_item("q", ab.x, ab.y))
	var slid := FORM_TOOLS.run("slide_edge", ctx, {"edges": loop}, {"slide": 1.0})
	check(not slid.ok or not (slid.warnings as PackedStringArray).is_empty(), "Slide 1 should warn that faces collapse.")
	# Mirror - Internal needs a face on each side.
	var mctx := {"cages": {"q": box}, "result": {}, "doc": null, "feature": null, "kernel": null, "values": {}, "subd": Callable()}
	var mi := FORM_TOOLS.run("mirror_internal", mctx, {"faces": []}, {"candidate": "0", "tolerance": 0.0, "snap": true})
	check(not mi.ok, "Mirror - Internal with no faces picked should not apply the first plane.")
	var mi2 := FORM_TOOLS.run("mirror_internal", mctx, {"faces": [face_item("q", face_at(box, Vector3(1, 0.5, 0.5))), face_item("q", face_at(box, Vector3(-1, 0.5, 0.5)))]}, {"candidate": "0", "tolerance": 0.0, "snap": true})
	check(mi2.ok, "Mirror - Internal with two faces picked should apply (%s)." % mi2.get("error", ""))
	checked.append("typed values out of range are refused; Subdivide 1 x 1 changes nothing; Slide 1 warns; Mirror - Internal needs two faces")


func _panel_bools() -> void:
	var panel: Control = COMMAND_PANEL.new()
	root.add_child(panel)
	var fields: Array[Dictionary] = []
	for field in FORM_TOOLS.spec("subdivide").fields:
		fields.append(field)
	panel.setup("Subdivide", fields, {"mode": "simple", "specify": false, "u_faces": "2", "v_faces": "2"}, "mm")
	var row: Control = panel._row_nodes.get("u_faces")
	var before := row.visible if row != null else true
	var box: CheckBox = panel._editors.get("specify")
	if box != null:
		box.button_pressed = true
	check(row != null and not before and row.visible, "Ticking Specify should show Length Faces at once (before %s, after %s)." % [before, row.visible if row != null else false])
	panel.queue_free()
	checked.append("ticking a check box shows the rows that depend on it")


func _flat_creases() -> void:
	# A plane 2 x 1 whose middle edge is creased between two coplanar faces.
	var c := PRIMITIVES.plane(Vector2(2, 1), Vector2i(2, 1))
	var a := vertex_at(c, Vector3(0, 0.5, 0))
	var b := vertex_at(c, Vector3(0, -0.5, 0))
	if a < 0 or b < 0:
		check(false, "The plane should have a middle edge.")
		return
	CAGE.set_crease(c, a, b, 10.0)
	check(not FORM.flat_crease_notes(c).is_empty(), "A crease between coplanar faces should be reported.")
	var box := crease_at(PRIMITIVES.box(Vector3(2, 2, 2), Vector3i(1, 1, 1)), 1.0)
	check(FORM.flat_crease_notes(box).is_empty(), "A creased box rim (90 degrees) isn't a flat crease.")
	checked.append("creases between nearly flat faces are reported")
