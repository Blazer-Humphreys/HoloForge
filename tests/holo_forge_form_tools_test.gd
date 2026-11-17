extends SceneTree
## Holo Forge Phase 6, Stage 3 (team M2): the Form modify, symmetry and utility tools through the
## tool registry (ui/form_tools.gd -> ui/form_tools_modify.gd -> core/form/form_ops.gd and
## core/form/form_fit.gd), without an editor:
## - every tool of 3.3 to 3.5 is registered and gives the counts of the spec (Insert Edge, Subdivide,
##   Insert Point, Merge Edge across bodies, Bridge (the torus), Fill Hole in three modes, Erase and
##   Fill, Weld (tolerance and across bodies), UnWeld, Bevel, Slide, Smooth, Cylindrify, Thicken,
##   Mirror / Circular - Internal and - Duplicate, Isolate Symmetry, Make Uniform);
## - the Exact modes: Insert Edge Exact on box 4,4,4 deviates at most 1% of the mean edge, Subdivide
##   Exact of a whole body is the Catmull-Clark step (same cage, limit within 1e-9);
## - the surface modes: Pull (control points on the face within 1e-9, limit points within 1e-6),
##   Flatten / Straighten surface points, Edit By Curve in both modes, Interpolate through the cage
##   points (sphere cage, residual 1e-9) and onto the surface;
## - Match: G0 puts the boundary's limit points on a sketch arc within 1e-6; an associative link
##   follows the sketch when it moves; a target after the form is refused;
## - Repair Body fixes a crafted broken cage (duplicate, flipped, unused, T-junction, degenerate)
##   into a valid cage with the right counts;
## - Convert: Form to BRep keeps the volume through a rebuild, Face to Form fits a box face within
##   1e-9, Mesh to Form makes an OBJ of 6 quads into 8/12/6.
##
## godot --headless --path . --script res://tests/holo_forge_form_tools_test.gd

const DOCUMENT := preload("res://addons/holo_forge/core/document.gd")
const REGEN := preload("res://addons/holo_forge/core/regen.gd")
const FORM := preload("res://addons/holo_forge/core/features/form.gd")
const CAGE := preload("res://addons/holo_forge/core/form/cage.gd")
const FORM_OPS := preload("res://addons/holo_forge/core/form/form_ops.gd")
const FORM_FIT := preload("res://addons/holo_forge/core/form/form_fit.gd")
const PRIMITIVES := preload("res://addons/holo_forge/core/form/primitives.gd")
const FORM_TOOLS := preload("res://addons/holo_forge/ui/form_tools.gd")
const MODIFY := preload("res://addons/holo_forge/ui/form_tools_modify.gd")
const SKETCH_DATA := preload("res://addons/holo_forge/core/sketch/sketch_data.gd")
const INSERT := preload("res://addons/holo_forge/core/features/insert.gd")
const MESH_IMPORT := preload("res://addons/holo_forge/core/import/mesh_import.gd")
const REFERENCES_FOR_TEST := preload("res://addons/holo_forge/core/references.gd")

const M2_TOOLS := ["edit_by_curve", "insert_edge", "subdivide", "insert_point", "merge_edge", "bridge", "fill_hole", "erase_and_fill",
	"weld_vertices", "unweld_edges", "bevel_edge", "slide_edge", "smooth", "cylindrify", "pull", "flatten", "straighten", "match",
	"interpolate", "thicken", "mirror_internal", "circular_internal", "mirror_duplicate", "circular_duplicate", "isolate_symmetry",
	"repair_body", "make_uniform", "convert"]

var failures: Array[String] = []
var checked: Array[String] = []
var kernel: RefCounted
var native := false


func _init() -> void:
	call_deferred("run")


func run() -> void:
	create_timer(400.0).timeout.connect(func() -> void:
		print("FAIL holo_forge_form_tools: timed out ", failures)
		quit(1))
	kernel = REGEN.make_kernel()
	native = kernel != null and ClassDB.class_exists("CadSubD")
	if not native:
		print("NOTE: CadKernel / CadSubD are not registered (the holo_forge native DLL is missing): kernel checks skipped.")
	_check_registry()
	_check_counts()
	_check_symmetry_tools()
	_check_repair()
	_check_make_uniform()
	_check_edit_by_curve()
	if native:
		_check_exact()
		_check_surface_points()
		_check_pull()
		_check_interpolate()
		_check_cylindrify_limit()
		_check_match()
		_check_match_associative()
		_check_convert_brep()
		_check_convert_face()
		_check_convert_mesh()
		_check_follow_curve()
	if failures.is_empty():
		print("PASS holo_forge_form_tools: " + ", ".join(checked) + ("" if native else " (kernel checks skipped)") + ".")
	else:
		print("FAIL holo_forge_form_tools")
		for f in failures:
			print("  - ", f)
	quit(0 if failures.is_empty() else 1)


func _expect(ok: bool, message: String) -> void:
	if not ok:
		failures.append(message)
		push_error(message)


# --- Helpers -----------------------------------------------------------------------------------

func _ctx(cages: Dictionary, result := {}, doc: Resource = null, feature: Resource = null) -> Dictionary:
	return {"cages": cages, "result": result, "doc": doc, "feature": feature, "kernel": kernel, "values": {}, "subd": Callable()}


## Runs a tool through the registry with the tool's defaults (as numbers) overridden by values.
func _run(id: String, ctx: Dictionary, picks: Dictionary, values := {}) -> Dictionary:
	var v := _defaults(id)
	v.merge(values, true)
	return FORM_TOOLS.run(id, ctx, picks, v)


## A tool's defaults as evaluated values (numbers for number fields, meters for lengths, radians).
func _defaults(id: String) -> Dictionary:
	var spec := FORM_TOOLS.spec(id)
	var kinds := {}
	for f in spec.get("fields", []):
		if str(f.get("type", "")) == "expression":
			kinds[f.key] = str(f.get("kind", "length"))
	var out := {}
	var defaults: Dictionary = spec.get("defaults", {})
	for key in defaults:
		if kinds.has(key):
			var text := str(defaults[key])
			match str(kinds[key]):
				"angle":
					out[key] = deg_to_rad(text.replace("deg", "").strip_edges().to_float())
				"length":
					out[key] = text.to_float()
				_:
					out[key] = text.to_float()
		else:
			out[key] = defaults[key]
	return out


func _counts(c: Dictionary) -> Vector3i:
	return Vector3i(CAGE.vertex_count(c), CAGE.topology(c).nE, CAGE.face_count(c))


func _vef(c: Dictionary) -> String:
	var k := _counts(c)
	return "%d/%d/%d" % [k.x, k.y, k.z]


func _edge_item(body: String, a: int, b: int) -> Dictionary:
	return {"kind": "edge", "body": body, "index": -1, "pair": Vector2i(mini(a, b), maxi(a, b))}


func _face_item(body: String, f: int) -> Dictionary:
	return {"kind": "face", "body": body, "index": f, "pair": Vector2i(-1, -1)}


func _vertex_item(body: String, v: int) -> Dictionary:
	return {"kind": "vertex", "body": body, "index": v, "pair": Vector2i(-1, -1)}


func _body_item(body: String) -> Dictionary:
	return {"kind": "body", "body": body, "index": -1, "pair": Vector2i(-1, -1)}


func _edge_items(body: String, topo: CAGE.Topo, edges: PackedInt32Array) -> Array:
	var out := []
	for e in edges:
		var ab := topo.edge_vertices(e)
		out.append(_edge_item(body, ab.x, ab.y))
	return out


## The cage's result: the run's cage for body (or {} with a failure noted).
func _cage_of(r: Dictionary, body: String, what: String) -> Dictionary:
	_expect(bool(r.get("ok", false)), "%s should work (%s)." % [what, r.get("error", "")])
	var c: Dictionary = (r.get("cages", {}) as Dictionary).get(body, {})
	if not c.is_empty():
		_expect(CAGE.validate(c).is_empty(), "%s should give a valid cage (%s)." % [what, CAGE.validate(c)])
	return c


func _expect_counts(c: Dictionary, want: String, what: String) -> void:
	_expect(not c.is_empty() and _vef(c) == want, "%s should give %s (%s)." % [what, want, _vef(c) if not c.is_empty() else "nothing"])


## An edge of the cage whose two ends satisfy pred (the first found, as vertex pairs).
func _find_edge(c: Dictionary, pred: Callable) -> Vector2i:
	var topo := CAGE.topology(c)
	for e in topo.nE:
		var ab := topo.edge_vertices(e)
		if pred.call(CAGE.position(c, ab.x), CAGE.position(c, ab.y)):
			return ab
	return Vector2i(-1, -1)


func _boundary_loop_items(body: String, c: Dictionary, pred: Callable) -> Array:
	var topo := CAGE.topology(c)
	for loop in topo.boundary_loops():
		var lp: PackedInt32Array = loop
		if pred.call(CAGE.position(c, lp[0])):
			var items := []
			for k in lp.size():
				items.append(_edge_item(body, lp[k], lp[(k + 1) % lp.size()]))
			return items
	return []


func _limit(c: Dictionary) -> PackedFloat64Array:
	var s := FORM_FIT.subd_of(c)
	if s.has("error"):
		return PackedFloat64Array()
	return (s.subd.limit_points() as Dictionary).get("positions", PackedFloat64Array())


func _lv(p: PackedFloat64Array, v: int) -> Vector3:
	return Vector3(p[3 * v], p[3 * v + 1], p[3 * v + 2])


# --- Registry ------------------------------------------------------------------------------------

func _check_registry() -> void:
	var missing := []
	for id in M2_TOOLS:
		if not FORM_TOOLS.has_tool(id) or FORM_TOOLS.owner(id) != MODIFY or not (FORM_TOOLS.owner(id) as Script).has_method("run_" + id):
			missing.append(id)
	_expect(missing.is_empty(), "Every M2 tool should be registered in form_tools_modify.gd with a run function (missing %s)." % [missing])
	checked.append("%d tools registered" % (M2_TOOLS.size() - missing.size()))


# --- Counts (3.3 to 3.5) -------------------------------------------------------------------------

func _check_counts() -> void:
	# Insert Edge (Simple): one cube edge, and the 2x2x2 equator loop single / both.
	var cube := PRIMITIVES.box(Vector3.ONE, Vector3i.ONE)
	var e0 := CAGE.topology(cube).edge_vertices(0)
	var r := _run("insert_edge", _ctx({"b": cube}), {"edges": [_edge_item("b", e0.x, e0.y)]})
	var c := _cage_of(r, "b", "Insert Edge on a cube edge")
	_expect_counts(c, "10/15/7", "Insert Edge on a cube edge")
	var box := PRIMITIVES.box(Vector3.ONE * 2.0, Vector3i(2, 2, 2))
	var eq := _find_edge(box, func(a: Vector3, b: Vector3) -> bool: return absf(a.z) < 1e-9 and absf(b.z) < 1e-9)
	var btopo := CAGE.topology(box)
	var loop := _edge_items("b", btopo, btopo.edge_loop(btopo.edge_index(eq.x, eq.y)))
	_expect(loop.size() == 8, "The 2x2x2 equator loop should have 8 edges (%d)." % loop.size())
	_expect_counts(_cage_of(_run("insert_edge", _ctx({"b": box}), {"edges": loop}), "b", "Insert Edge single"), "34/64/32", "Insert Edge on the equator (Single)")
	_expect_counts(_cage_of(_run("insert_edge", _ctx({"b": box}), {"edges": loop}, {"side": "both"}), "b", "Insert Edge both"), "42/80/40", "Insert Edge on the equator (Both)")
	r = _run("insert_edge", _ctx({"b": box}), {"edges": loop})
	_expect((r.selection as Array).size() == 8, "Insert Edge should select the 8 new edges (%d)." % (r.selection as Array).size())
	# Subdivide (Simple) one cube face, Exact whole cube.
	_expect_counts(_cage_of(_run("subdivide", _ctx({"b": cube}), {"faces": [_face_item("b", 0)]}), "b", "Subdivide one face"), "13/20/9", "Subdivide one cube face")
	# Insert Point: the midpoints of two opposite edges of one face.
	var f0 := CAGE.face_vertices(cube, 0)
	var pts := [{"edge": Vector2i(f0[0], f0[1]), "t": 0.5}, {"edge": Vector2i(f0[2], f0[3]), "t": 0.5}]
	_expect_counts(_cage_of(_run("insert_point", _ctx({"b": cube}), {}, {"points": pts, "points_body": "b"}), "b", "Insert Point"), "10/15/7", "Insert Point across a face")
	# Merge Edge: two 1x1 planes as separate bodies (group one moves onto group two; one body left).
	var p1 := PRIMITIVES.plane(Vector2.ONE, Vector2i.ONE)
	var p2: Dictionary = FORM_OPS.transform_vertices(p1, PackedInt32Array([0, 1, 2, 3]), PackedFloat32Array(), FORM_OPS.xf_translation(1.2, 0.0, 0.0)).cage
	var right := _find_edge(p1, func(a: Vector3, b: Vector3) -> bool: return a.x > 0.4 and b.x > 0.4)
	var left := _find_edge(p2, func(a: Vector3, b: Vector3) -> bool: return a.x < 0.8 and b.x < 0.8)
	r = _run("merge_edge", _ctx({"b1": p1, "b2": p2}), {"edges": [_edge_item("b1", right.x, right.y)]}, {"edges2": [_edge_item("b2", left.x, left.y)]})
	_expect_counts(_cage_of(r, "b2", "Merge Edge"), "6/7/2", "Merge Edge of two planes")
	_expect((r.get("removed_bodies", []) as Array) == ["b1"], "Merge Edge should remove group one's body (%s)." % [r.get("removed_bodies", [])])
	# Bridge: the two loops of an open cylinder with 2 faces make a torus.
	var tube := PRIMITIVES.cylinder(1.0, 1.0, 8, 1, "open")
	_expect(_vef(tube) == "16/24/8", "The open cylinder 8,1 should be 16/24/8 (%s)." % _vef(tube))
	var bottom := _boundary_loop_items("t", tube, func(p: Vector3) -> bool: return p.z < 0.5)
	var top := _boundary_loop_items("t", tube, func(p: Vector3) -> bool: return p.z > 0.5)
	r = _run("bridge", _ctx({"t": tube}), {"side1": bottom}, {"side2": top, "segments": 2.0})
	c = _cage_of(r, "t", "Bridge")
	_expect_counts(c, "24/48/24", "Bridge of the cylinder's loops (Faces 2)")
	# Bridge across two bodies: two boxes' facing faces.
	var cube2: Dictionary = FORM_OPS.transform_vertices(cube, PackedInt32Array(range(8)), PackedFloat32Array(), FORM_OPS.xf_translation(3.0, 0.0, 0.0)).cage
	var fx := _facing(cube, Vector3.RIGHT)
	var fmx := _facing(cube2, Vector3.LEFT)
	r = _run("bridge", _ctx({"a": cube, "z": cube2}), {"side1": [_face_item("a", fx)]}, {"side2": [_face_item("z", fmx)], "segments": 3.0})
	c = _cage_of(r, "a", "Bridge of two bodies")
	_expect_counts(c, "24/44/22", "Bridge of two cubes (Faces 3)")
	_expect((r.get("removed_bodies", []) as Array) == ["z"], "Bridging two bodies should join the second into the first (%s)." % [r.get("removed_bodies", [])])
	# Fill Hole on an open cylinder 8,2: Fill Star / Collapse / Reduced Star; n = 6 Reduced.
	var tube2 := PRIMITIVES.cylinder(1.0, 1.0, 8, 2, "open")
	var hole := _boundary_loop_items("t", tube2, func(p: Vector3) -> bool: return p.z < 0.5)
	var hole_edge := [hole[0]]
	_expect_counts(_cage_of(_run("fill_hole", _ctx({"t": tube2}), {"edge": hole_edge}, {"mode": "star"}), "t", "Fill Star"), "24/40/17", "Fill Hole, Fill Star (n = 8)")
	_expect_counts(_cage_of(_run("fill_hole", _ctx({"t": tube2}), {"edge": hole_edge}, {"mode": "collapse"}), "t", "Collapse"), "25/48/24", "Fill Hole, Collapse (n = 8)")
	_expect_counts(_cage_of(_run("fill_hole", _ctx({"t": tube2}), {"edge": hole_edge}, {"mode": "reduced"}), "t", "Reduced Star"), "25/44/20", "Fill Hole, Reduced Star (n = 8)")
	var tube6 := PRIMITIVES.cylinder(1.0, 1.0, 6, 1, "open")
	var hole6 := _boundary_loop_items("t", tube6, func(p: Vector3) -> bool: return p.z < 0.5)
	c = _cage_of(_run("fill_hole", _ctx({"t": tube6}), {"edge": [hole6[0]]}), "t", "Reduced Star n = 6")
	var k6 := _counts(tube6)
	_expect(not c.is_empty() and _counts(c) - k6 == Vector3i(0, 1, 2), "Fill Hole Reduced Star on n = 6 should add 0 V, 1 E, 2 F (%s -> %s)." % [_vef(tube6), _vef(c) if not c.is_empty() else "-"])
	# Erase and Fill: one face of the 2x2x2 box comes back as 26/48/24.
	_expect_counts(_cage_of(_run("erase_and_fill", _ctx({"b": box}), {"faces": [_face_item("b", 0)]}), "b", "Erase and Fill"), "26/48/24", "Erase and Fill of one box face")
	# Weld to Tolerance: two planes side by side, coincident vertices.
	var p3: Dictionary = FORM_OPS.transform_vertices(p1, PackedInt32Array([0, 1, 2, 3]), PackedFloat32Array(), FORM_OPS.xf_translation(1.0, 0.0, 0.0)).cage
	var pair: Dictionary = CAGE.append(p1, p3).cage
	_expect_counts(_cage_of(_run("weld_vertices", _ctx({"p": pair}), {"vertices": []}, {"mode": "tolerance", "tolerance": 1e-6}), "p", "Weld to Tolerance"), "6/7/2", "Weld to Tolerance of two planes")
	# Vertex to Vertex across two bodies: the bodies join.
	var a_corner := _nearest(p1, Vector3(0.5, 0.5, 0))
	var b_corner := _nearest(p2, Vector3(0.7, 0.5, 0))
	r = _run("weld_vertices", _ctx({"b1": p1, "b2": p2}), {"vertices": [_vertex_item("b1", a_corner), _vertex_item("b2", b_corner)]})
	c = _cage_of(r, "b2", "Weld across bodies")
	_expect_counts(c, "7/8/2", "Vertex to Vertex across two bodies")
	_expect((r.get("removed_bodies", []) as Array) == ["b1"], "Welding across bodies should join them (%s)." % [r.get("removed_bodies", [])])
	# UnWeld the middle loop of an open cylinder 8,2.
	var mid := _find_edge(tube2, func(a: Vector3, b: Vector3) -> bool: return absf(a.z - 0.5) < 1e-9 and absf(b.z - 0.5) < 1e-9)
	var t2 := CAGE.topology(tube2)
	c = _cage_of(_run("unweld_edges", _ctx({"t": tube2}), {"edges": _edge_items("t", t2, t2.edge_loop(t2.edge_index(mid.x, mid.y)))}), "t", "UnWeld")
	_expect_counts(c, "32/48/16", "UnWeld of the middle loop")
	_expect(not c.is_empty() and CAGE.topology(c).component_count() == 2, "UnWeld should leave 2 pieces.")
	# Bevel the equator loop: 1 / 2 / 3 segments.
	for s in [[1, "34/64/32"], [2, "42/80/40"], [3, "50/96/48"]]:
		_expect_counts(_cage_of(_run("bevel_edge", _ctx({"b": box}), {"edges": loop}, {"segments": float(s[0])}), "b", "Bevel %d" % s[0]), str(s[1]), "Bevel Edge with %d segments" % s[0])
	# Slide 0.5: same counts, every chain vertex moved.
	c = _cage_of(_run("slide_edge", _ctx({"b": box}), {"edges": loop}, {"slide": 0.5}), "b", "Slide Edge")
	_expect_counts(c, "26/48/24", "Slide Edge")
	if not c.is_empty():
		var moved := 0
		for v in CAGE.vertex_count(box):
			if CAGE.position(box, v) != CAGE.position(c, v):
				moved += 1
		_expect(moved == 8, "Slide Edge should move the 8 loop vertices (%d)." % moved)
	# Smooth: same counts, interior moved.
	var bumpy := CAGE.copy(PRIMITIVES.plane(Vector2(3, 3), Vector2i(3, 3)))
	var centre_v := _nearest(bumpy, Vector3(0.5, 0.5, 0))
	CAGE.set_position_d(bumpy, centre_v, 0.5, 0.5, 0.6)
	var all_faces := []
	for f in CAGE.face_count(bumpy):
		all_faces.append(_face_item("p", f))
	c = _cage_of(_run("smooth", _ctx({"p": bumpy}), {"faces": all_faces}), "p", "Smooth")
	_expect(not c.is_empty() and CAGE.position(c, centre_v).z < 0.6 * 0.6, "Smooth should pull the raised vertex down (%s)." % [CAGE.position(c, centre_v) if not c.is_empty() else null])
	# Thicken: 1x1 plane Sharp 8/12/6 with 8 creases; 2x2 plane 18/32/16.
	c = _cage_of(_run("thicken", _ctx({"p": p1}), {"elements": [_body_item("p")]}, {"thickness": 0.1}), "p", "Thicken")
	_expect_counts(c, "8/12/6", "Thicken of a 1x1 plane")
	_expect(not c.is_empty() and (c.crease_weights as PackedFloat32Array).size() == 8, "Sharp Thicken should crease both rims (8 pairs).")
	_expect_counts(_cage_of(_run("thicken", _ctx({"p": PRIMITIVES.plane(Vector2.ONE, Vector2i(2, 2))}), {"elements": [_body_item("p")]}, {"thickness": 0.1}), "p", "Thicken 2x2"), "18/32/16", "Thicken of a 2x2 plane")
	checked.append("counts (insert edge 10/15/7, 34/64/32, 42/80/40; subdivide 13/20/9; insert point; merge edge across bodies 6/7/2; bridge torus 24/48/24 and two bodies; fill hole star/collapse/reduced n=8 and n=6; erase and fill; weld to tolerance and across bodies; unweld 32/48/16; bevel 1/2/3; slide; smooth; thicken 8/12/6 and 18/32/16)")


## The face of c whose cage normal points along dir.
func _facing(c: Dictionary, dir: Vector3) -> int:
	var topo := CAGE.topology(c)
	for f in topo.nF:
		if topo.face_normal(c, f).dot(dir) > 0.99:
			return f
	return -1


func _nearest(c: Dictionary, p: Vector3) -> int:
	var best := -1
	var d := INF
	for v in CAGE.vertex_count(c):
		var dd := CAGE.position(c, v).distance_to(p)
		if dd < d:
			d = dd
			best = v
	return best


# --- Symmetry tools ------------------------------------------------------------------------------

func _check_symmetry_tools() -> void:
	# Mirror - Internal: a face on each side of the box finds the X plane; the map is complete.
	var box := PRIMITIVES.box(Vector3.ONE * 2.0, Vector3i(2, 2, 2))
	var px := _facing(box, Vector3.RIGHT)
	var mx := _facing(box, Vector3.LEFT)
	var r := _run("mirror_internal", _ctx({"b": box}), {"faces": [_face_item("b", px), _face_item("b", mx)]})
	var c := _cage_of(r, "b", "Mirror - Internal")
	var sym: Array = c.get("symmetry", [])
	_expect(sym.size() == 1 and str(sym[0].type) == "mirror" and absf(float(sym[0].normal[0])) > 0.999 and not (sym[0].map as PackedInt32Array).has(-1),
		"Mirror - Internal should add the X mirror with a complete map (%s)." % [sym])
	# Twice the same plane is refused; the next candidate (another plane) is taken instead.
	var r2 := _run("mirror_internal", _ctx({"b": c}), {"faces": [_face_item("b", px), _face_item("b", mx)]})
	var c2: Dictionary = (r2.get("cages", {}) as Dictionary).get("b", {})
	_expect(r2.ok and (c2.get("symmetry", []) as Array).size() == 2 and absf(float((c2.symmetry as Array)[1].normal[0])) < 0.5,
		"A second Mirror - Internal should add a different plane (%s)." % [r2.get("error", "")])
	# Circular - Internal: the cylinder's 8-fold symmetry.
	var cyl := PRIMITIVES.cylinder(1.0, 1.0, 8, 2, "pole")
	var found8 := false
	for k in 6:
		var rc := _run("circular_internal", _ctx({"c": cyl}), {"faces": []}, {"candidate": str(k)})
		if rc.ok and int((rc.info as Dictionary).get("count", 0)) == 8:
			var cc: Dictionary = rc.cages.c
			var entry: Dictionary = (cc.symmetry as Array)[0]
			found8 = int(entry.count) == 8 and not (entry.map as PackedInt32Array).has(-1)
			break
	_expect(found8, "Circular - Internal should offer the cylinder's 8-fold symmetry with a complete map.")
	# Mirror - Duplicate: a 1x1 plane with one edge on the YZ plane, welded: 6/7/2, seam on itself.
	var plane := PRIMITIVES.plane(Vector2.ONE, Vector2i.ONE)
	plane = FORM_OPS.transform_vertices(plane, PackedInt32Array([0, 1, 2, 3]), PackedFloat32Array(), FORM_OPS.xf_translation(0.5, 0.0, 0.0)).cage
	r = _run("mirror_duplicate", _ctx({"p": plane}), {"bodies": [_body_item("p")]}, {"plane": [{"kind": "origin", "name": "yz"}]})
	c = _cage_of(r, "p", "Mirror - Duplicate")
	_expect_counts(c, "6/7/2", "Mirror - Duplicate with weld")
	if not c.is_empty():
		var entry: Dictionary = (c.symmetry as Array).back()
		var m: PackedInt32Array = entry.map
		var on_seam := 0
		for v in m.size():
			if m[v] == v:
				on_seam += 1
				_expect(absf(CAGE.position(c, v).x) < 1e-12, "Seam vertices should lie on the plane.")
		_expect(on_seam == 2 and not m.has(-1), "The two seam vertices should map to themselves (%d, map %s)." % [on_seam, m])
	# Circular - Duplicate: a separate plane piece, 4 copies, no welds: 16/16/4 in 4 pieces.
	var piece: Dictionary = FORM_OPS.transform_vertices(PRIMITIVES.plane(Vector2.ONE, Vector2i.ONE), PackedInt32Array([0, 1, 2, 3]), PackedFloat32Array(), FORM_OPS.xf_translation(3.0, 0.0, 0.0)).cage
	r = _run("circular_duplicate", _ctx({"p": piece}), {"bodies": [_body_item("p")]}, {"axis": [{"kind": "origin", "name": "z"}], "weld": false})
	c = _cage_of(r, "p", "Circular - Duplicate")
	_expect_counts(c, "16/16/4", "Circular - Duplicate, 4 copies")
	_expect(not c.is_empty() and CAGE.topology(c).component_count() == 4, "Circular - Duplicate should make 4 pieces.")
	# Isolate Symmetry: isolate, then restore.
	var mirrored := PRIMITIVES.primitive_symmetry(box, "mirror", Transform3D.IDENTITY, Vector3i(1, 0, 0), 0)
	r = _run("isolate_symmetry", _ctx({"b": mirrored}), {"elements": [_vertex_item("b", 0)]})
	c = _cage_of(r, "b", "Isolate Symmetry")
	_expect(not c.is_empty() and (c.sym_isolated as PackedInt32Array) == PackedInt32Array([0]), "Isolate should add the vertex to sym_isolated.")
	if not c.is_empty():
		var back := _cage_of(_run("isolate_symmetry", _ctx({"b": c}), {"elements": [_vertex_item("b", 0)]}, {"mode": "restore"}), "b", "Restore Symmetry")
		_expect(not back.is_empty() and (back.sym_isolated as PackedInt32Array).is_empty(), "Restore should take it out again.")
	checked.append("symmetry tools (mirror internal finds the X plane, a second one another plane, circular internal 8-fold, mirror duplicate 6/7/2 with the seam on itself, circular duplicate 16/16/4 in 4 pieces, isolate and restore)")


# --- Repair --------------------------------------------------------------------------------------

func _check_repair() -> void:
	var pts := PackedVector3Array([Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(2, 0, 0), Vector3(0, 1, 0), Vector3(1, 1, 0), Vector3(2, 1, 0),
		Vector3(2, 2, 0), Vector3(0, 2, 0), Vector3(3, 0, 0), Vector3(3, 1, 0), Vector3(5, 5, 0)])
	var faces := [
		PackedInt32Array([0, 1, 4, 3]), PackedInt32Array([1, 2, 5, 4]),
		PackedInt32Array([3, 5, 6, 7]),        # T-junction: vertex 4 lies inside its edge 3-5
		PackedInt32Array([1, 2, 5, 4]),        # duplicate
		PackedInt32Array([5, 9, 8, 2]),        # flipped
		PackedInt32Array([0, 1, 0]),           # degenerate
	]
	# Vertex 10 is used by nothing.
	var broken := CAGE.make(PackedFloat64Array(), PackedInt32Array(), PackedInt32Array())
	var pos := PackedFloat64Array()
	for q in pts:
		pos.append_array(PackedFloat64Array([q.x, q.y, q.z]))
	var counts := PackedInt32Array()
	var idx := PackedInt32Array()
	for f in faces:
		counts.append((f as PackedInt32Array).size())
		idx.append_array(f)
	broken.positions = pos
	broken.face_counts = counts
	broken.face_indices = idx
	var r := _run("repair_body", _ctx({"b": broken}), {"bodies": []}, {"tolerance": 1e-6})
	var c := _cage_of(r, "b", "Repair Body")
	var info: Dictionary = r.get("info", {})
	_expect(not c.is_empty() and CAGE.validate(c).is_empty(), "Repair should leave a valid cage (%s)." % [CAGE.validate(c) if not c.is_empty() else "none"])
	for key in ["duplicate", "flipped", "unused", "t_junctions", "degenerate"]:
		_expect(int(info.get(key, -1)) == 1, "Repair should count one %s (%s)." % [key, info.get(key, null)])
	_expect(not c.is_empty() and _vef(c) == "10/13/4", "The repaired cage should be 10/13/4 (%s)." % [_vef(c) if not c.is_empty() else "-"])
	var report := _run("repair_body", _ctx({"b": broken}), {"bodies": []}, {"mode": "report", "tolerance": 1e-6})
	_expect(not report.ok and str(report.error) == FORM_OPS.NOTHING and int((report.info as Dictionary).get("duplicate", 0)) == 0,
		"Report mode should change nothing (%s)." % [report.get("error", "")])
	checked.append("repair (duplicate, flipped, unused, T-junction and degenerate each counted once, valid 10/13/4, report changes nothing)")


# --- Make Uniform --------------------------------------------------------------------------------

func _check_make_uniform() -> void:
	var cyl := PRIMITIVES.cylinder(1.0, 1.0, 8, 2, "pole")
	var r := _run("make_uniform", _ctx({"c": cyl}), {"bodies": []})
	var c := _cage_of(r, "c", "Make Uniform")
	var only_quads := not c.is_empty()
	for n in (c.get("face_counts", PackedInt32Array()) as PackedInt32Array):
		if n != 4:
			only_quads = false
	_expect(only_quads, "Make Uniform (Quads Only) should leave only quads (%s)." % [c.get("face_counts", null)])
	var note := "make uniform: only quads (%s)" % _vef(c)
	if native and only_quads:
		var even := _run("make_uniform", _ctx({"c": c}), {"bodies": []}, {"even": true, "iterations": 3.0})
		var ce := _cage_of(even, "c", "Make Uniform even spacing")
		var dev := float((even.info as Dictionary).get("max_deviation", INF))
		_expect(not ce.is_empty() and dev < 0.05 * CAGE.mean_edge_length(c), "Even Spacing should keep the surface (max deviation %s)." % dev)
		note += ", even spacing deviates %s m" % String.num_scientific(dev)
	checked.append(note)


# --- Edit By Curve -------------------------------------------------------------------------------

func _check_edit_by_curve() -> void:
	var strip := PRIMITIVES.plane(Vector2(4, 1), Vector2i(4, 1))
	var chain := []
	var topo := CAGE.topology(strip)
	for e in topo.nE:
		var ab := topo.edge_vertices(e)
		if CAGE.position(strip, ab.x).y < -0.4 and CAGE.position(strip, ab.y).y < -0.4:
			chain.append(_edge_item("s", ab.x, ab.y))
	_expect(chain.size() == 4, "The strip's lower side should be 4 edges (%d)." % chain.size())
	var pairs := PackedInt32Array()
	for item in chain:
		pairs.append(item.pair.x)
		pairs.append(item.pair.y)
	var curve := FORM_FIT.chain_curve(strip, pairs, {"degree": 3})
	var lift := Vector3(0, 0, 0.3)
	var r := _run("edit_by_curve", _ctx({"s": strip}), {"edges": chain}, {"curve_offsets": [Vector3.ZERO, lift, Vector3.ZERO, Vector3.ZERO]})
	var c := _cage_of(r, "s", "Edit By Curve")
	if not c.is_empty() and not curve.has("error"):
		var worst := 0.0
		var verts: PackedInt32Array = curve.verts
		var params: PackedFloat64Array = curve.params
		for i in verts.size():
			var t := params[i]
			var want := CAGE.position(strip, verts[i]) + lift * 3.0 * t * (1.0 - t) * (1.0 - t)
			worst = maxf(worst, CAGE.position(c, verts[i]).distance_to(want))
		_expect(worst < 1e-6, "Edit By Curve (control points) should move each chain vertex by the curve's change (%s off)." % worst)
	_expect(not _run("edit_by_curve", _ctx({"s": strip}), {"edges": chain}).ok, "An unchanged curve should change nothing.")
	var closed := _boundary_loop_items("s", strip, func(_p: Vector3) -> bool: return true)
	var rc := _run("edit_by_curve", _ctx({"s": strip}), {"edges": closed}, {"curve_offsets": [lift]})
	_expect(not rc.ok and str(rc.error) == "Pick an open chain of edges", "A closed loop should be refused with its message (%s)." % rc.get("error", ""))
	var note := "edit by curve (control points follow the curve's change, closed loops refused"
	if native:
		var rs := _run("edit_by_curve", _ctx({"s": strip}), {"edges": chain}, {"curve_offsets": [Vector3.ZERO, lift, Vector3.ZERO, Vector3.ZERO], "fit": "surface"})
		var cs := _cage_of(rs, "s", "Edit By Curve (surface points)")
		if not cs.is_empty():
			var before := _limit(strip)
			var after := _limit(cs)
			var worst := 0.0
			var verts: PackedInt32Array = curve.verts
			var params: PackedFloat64Array = curve.params
			for i in verts.size():
				var t := params[i]
				var want := _lv(before, verts[i]) + lift * 3.0 * t * (1.0 - t) * (1.0 - t)
				worst = maxf(worst, _lv(after, verts[i]).distance_to(want))
			_expect(worst < 1e-9, "Edit By Curve (surface points) should move the limit points by the curve's change (%s off)." % worst)
			note += ", surface points to %s" % String.num_scientific(worst)
	checked.append(note + ")")


# --- Exact modes (kernel) ------------------------------------------------------------------------

func _check_exact() -> void:
	var box := PRIMITIVES.box(Vector3.ONE * 4.0, Vector3i(4, 4, 4))
	var eq := _find_edge(box, func(a: Vector3, b: Vector3) -> bool: return absf(a.z) < 1e-9 and absf(b.z) < 1e-9)
	var topo := CAGE.topology(box)
	var loop := _edge_items("b", topo, topo.edge_loop(topo.edge_index(eq.x, eq.y)))
	var started := Time.get_ticks_usec()
	var r := _run("insert_edge", _ctx({"b": box}), {"edges": loop}, {"mode": "exact"})
	var ms := (Time.get_ticks_usec() - started) / 1000.0
	var c := _cage_of(r, "b", "Insert Edge Exact")
	var dev := float((r.info as Dictionary).get("max_deviation", INF))
	var mean := CAGE.mean_edge_length(box)
	_expect(not c.is_empty() and dev <= 0.01 * mean, "Insert Edge Exact on box 4,4,4 should deviate at most 1%% of the mean edge (%s of %s)." % [dev, mean])
	# Subdivide Exact on a whole body = the Catmull-Clark step.
	var cube := PRIMITIVES.box(Vector3.ONE * 2.0, Vector3i.ONE)
	var all := []
	for f in 6:
		all.append(_face_item("c", f))
	var rs := _run("subdivide", _ctx({"c": cube}), {"faces": all}, {"mode": "exact"})
	var cs := _cage_of(rs, "c", "Subdivide Exact")
	var cc: Dictionary = CAGE.catmull_clark_step(cube).cage
	_expect(not cs.is_empty() and _vef(cs) == "26/48/24" and cs.positions == cc.positions and cs.face_indices == cc.face_indices,
		"Subdivide Exact of the whole cube should be the Catmull-Clark step (%s)." % [_vef(cs) if not cs.is_empty() else "-"])
	var worst := INF
	if not cs.is_empty():
		var parent: RefCounted = FORM_FIT.subd_of(cube).subd
		var child: RefCounted = FORM_FIT.subd_of(cs).subd
		var faces := PackedInt32Array()
		var uvs := PackedVector2Array()
		var rng := RandomNumberGenerator.new()
		rng.seed = 6
		for i in 60:
			faces.append(rng.randi_range(0, 5))
			uvs.append(Vector2(rng.randf(), rng.randf()))
		var ev: Dictionary = parent.evaluate(faces, uvs)
		var pts := PackedVector3Array()
		var ep: PackedFloat64Array = ev.positions
		for i in faces.size():
			pts.append(_lv(ep, i))
		var cp: Dictionary = child.closest_points(pts)
		var near := 0.0
		for d in (cp.distances as PackedFloat64Array):
			near = maxf(near, d)
		# The query points are float32, so that check is to 1e-6; in doubles: the corners' limit
		# points (vertex v is v in the child) and the face centres (the child's face points).
		_expect(near <= 1e-6, "The exact subdivision's limit should stay on the cube's (%s)." % near)
		var lp_parent: PackedFloat64Array = (parent.limit_points() as Dictionary).positions
		var lp_child: PackedFloat64Array = (child.limit_points() as Dictionary).positions
		worst = 0.0
		for v in 8:
			worst = maxf(worst, _lv(lp_parent, v).distance_to(_lv(lp_child, v)))
		var centres: Dictionary = parent.evaluate(PackedInt32Array([0, 1, 2, 3, 4, 5]), PackedVector2Array([Vector2(0.5, 0.5), Vector2(0.5, 0.5), Vector2(0.5, 0.5), Vector2(0.5, 0.5), Vector2(0.5, 0.5), Vector2(0.5, 0.5)]))
		var cpos: PackedFloat64Array = centres.positions
		for f in 6:
			var centroid := CAGE._centroid(cube.positions, CAGE.face_vertices(cube, f))
			var w := _nearest(cs, centroid)
			var dd := 0.0
			for k in 3:
				dd += pow(lp_child[3 * w + k] - cpos[3 * f + k], 2)
			worst = maxf(worst, sqrt(dd))
		_expect(worst <= 1e-9, "The exact subdivision's limit at the corners and face centres should match the cube's within 1e-9 (%s)." % worst)
	# Subdivide Exact on one face refits (13/20/9, small deviation).
	var one := _run("subdivide", _ctx({"c": cube}), {"faces": [_face_item("c", 0)]}, {"mode": "exact"})
	var co := _cage_of(one, "c", "Subdivide Exact of one face")
	_expect_counts(co, "13/20/9", "Subdivide Exact of one face")
	# Insert Point Exact.
	var f0 := CAGE.face_vertices(cube, 0)
	var ip := _run("insert_point", _ctx({"c": cube}), {}, {"points": [{"edge": Vector2i(f0[0], f0[1]), "t": 0.5}, {"edge": Vector2i(f0[2], f0[3]), "t": 0.5}], "points_body": "c", "mode": "exact"})
	_expect_counts(_cage_of(ip, "c", "Insert Point Exact"), "10/15/7", "Insert Point Exact")
	checked.append("exact modes (insert edge loop on box 4,4,4 deviates %.3f%% of the mean edge in %.0f ms, whole-body subdivide = Catmull-Clark step with the limit kept to %s, one-face subdivide and insert point refitted)" % [100.0 * dev / mean, ms, String.num_scientific(worst)])


# --- Surface points ------------------------------------------------------------------------------

func _check_surface_points() -> void:
	var bumpy := CAGE.copy(PRIMITIVES.plane(Vector2(3, 3), Vector2i(3, 3)))
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	for v in CAGE.vertex_count(bumpy):
		var q := CAGE.position_d(bumpy, v)
		CAGE.set_position_d(bumpy, v, q[0], q[1], rng.randf_range(-0.2, 0.2))
	var sel := []
	for v in CAGE.vertex_count(bumpy):
		var q := CAGE.position(bumpy, v)
		if q.y > 0.4:
			sel.append(_vertex_item("p", v))
	# Flatten (surface points) onto the XY plane.
	var r := _run("flatten", _ctx({"p": bumpy}), {"vertices": sel}, {"direction": "plane", "plane": [{"origin": PackedFloat64Array([0.0, 0.0, 0.05]), "normal": Vector3(0, 0, 1)}], "type": "surface"})
	var c := _cage_of(r, "p", "Flatten (surface points)")
	var worst := 0.0
	if not c.is_empty():
		var lp := _limit(c)
		for item in sel:
			worst = maxf(worst, absf(lp[3 * int(item.index) + 2] - 0.05))
		_expect(worst <= 1e-9, "Flatten (surface points) should put the limit points on the plane (%s)." % worst)
	# Flatten control onto an origin plane reference.
	var rc := _run("flatten", _ctx({"p": bumpy}), {"vertices": sel}, {"direction": "plane", "plane": [{"kind": "origin", "name": "xy"}]})
	var cc := _cage_of(rc, "p", "Flatten onto the XY origin plane")
	var off := 0.0
	if not cc.is_empty():
		for item in sel:
			off = maxf(off, absf(CAGE.position_d(cc, int(item.index))[2]))
	_expect(off <= 1e-12, "Flatten (control points) onto the XY plane should leave z = 0 (%s)." % off)
	# Straighten (surface points) along two points.
	var row := []
	for v in CAGE.vertex_count(bumpy):
		if CAGE.position(bumpy, v).y < -1.4:
			row.append(_vertex_item("p", v))
	var a := Vector3(-1.5, -1.5, 0.1)
	var b := Vector3(1.5, -1.5, 0.1)
	var rs := _run("straighten", _ctx({"p": bumpy}), {"vertices": row}, {"direction": "two_points", "points": [a, b], "type": "surface"})
	var cs := _cage_of(rs, "p", "Straighten (surface points)")
	var line_off := 0.0
	if not cs.is_empty():
		var lp := _limit(cs)
		for item in row:
			var q := _lv(lp, int(item.index))
			var t := (q - a).dot((b - a).normalized())
			line_off = maxf(line_off, q.distance_to(a + (b - a).normalized() * t))
		_expect(line_off <= 1e-6, "Straighten (surface points) should put the limit points on the line (%s)." % line_off)
	checked.append("surface points (flatten %s, flatten onto an origin plane exact, straighten %s)" % [String.num_scientific(worst), String.num_scientific(line_off)])


# --- Pull -----------------------------------------------------------------------------------------

func _check_pull() -> void:
	var target: RefCounted = kernel.make_box(Vector3(4, 4, 1), Vector3(-2, -2, -1))
	var plane: Dictionary = FORM_OPS.transform_vertices(PRIMITIVES.plane(Vector2(2, 2), Vector2i(2, 2)), PackedInt32Array(range(9)), PackedFloat32Array(), FORM_OPS.xf_translation(0.0, 0.0, 0.3)).cage
	var all := [_body_item("p")]
	var result := {"bodies": {"box": {"id": "box", "shape": target, "feature": "f0"}}}
	var r := _run("pull", _ctx({"p": plane}, result), {"vertices": all})
	var c := _cage_of(r, "p", "Pull (control points)")
	var worst := 0.0
	if not c.is_empty():
		for v in CAGE.vertex_count(c):
			worst = maxf(worst, absf(CAGE.position_d(c, v)[2]))
		_expect(worst <= 1e-9, "Pull (control points) should put the vertices on the box's top face (%s)." % worst)
	var rs := _run("pull", _ctx({"p": plane}, result), {"vertices": all}, {"type": "surface"})
	var cs := _cage_of(rs, "p", "Pull (surface points)")
	var lim := 0.0
	if not cs.is_empty():
		var lp := _limit(cs)
		for v in CAGE.vertex_count(cs):
			lim = maxf(lim, absf(lp[3 * v + 2]))
		_expect(lim <= 1e-6, "Pull (surface points) should put the limit points on the top face (%s)." % lim)
	var none := _run("pull", _ctx({"p": plane}, {"bodies": {}}), {"vertices": all})
	_expect(not none.ok and str(none.error) == "There is no body to pull to", "Pull with no body should say so (%s)." % none.get("error", ""))
	checked.append("pull (control points on the face to %s, limit points to %s, no target refused)" % [String.num_scientific(worst), String.num_scientific(lim)])


# --- Interpolate ---------------------------------------------------------------------------------

func _check_interpolate() -> void:
	var sphere := PRIMITIVES.sphere(2.0, 8, 4)
	var r := _run("interpolate", _ctx({"s": sphere}), {"elements": [_body_item("s")]})
	var c := _cage_of(r, "s", "Interpolate (through)")
	var worst := INF
	if not c.is_empty():
		var lp := _limit(c)
		worst = 0.0
		for v in CAGE.vertex_count(sphere):
			worst = maxf(worst, _lv(lp, v).distance_to(CAGE.position(sphere, v)))
		_expect(worst <= 1e-9 * 2.0 and float((r.info as Dictionary).get("residual", INF)) <= 1e-9, "Interpolate Through should pass the limit through the cage points (%s)." % worst)
	var ro := _run("interpolate", _ctx({"s": sphere}), {"elements": []}, {"mode": "onto"})
	var co := _cage_of(ro, "s", "Interpolate (onto)")
	var onto := INF
	if not co.is_empty():
		var lp := _limit(sphere)
		onto = 0.0
		for v in CAGE.vertex_count(sphere):
			onto = maxf(onto, _lv(lp, v).distance_to(CAGE.position(co, v)))
		_expect(onto <= 1e-12, "Cage Onto Surface should move the cage points onto the limit points (%s)." % onto)
	checked.append("interpolate (through: residual %s on the sphere cage; onto: exact)" % String.num_scientific(worst))


# --- Cylindrify limit ---------------------------------------------------------------------------

func _check_cylindrify_limit() -> void:
	# Rings of different radii (each still a regular octagon, so the band's axis is exactly Z).
	var tube := CAGE.copy(PRIMITIVES.cylinder(2.0, 2.0, 8, 2, "open"))
	for v in CAGE.vertex_count(tube):
		var q := CAGE.position_d(tube, v)
		var k := 1.0 if q[2] < 0.5 else (1.25 if q[2] < 1.5 else 0.9)
		CAGE.set_position_d(tube, v, q[0] * k, q[1] * k, q[2])
	var faces := []
	for f in CAGE.face_count(tube):
		faces.append(_face_item("t", f))
	var r := _run("cylindrify", _ctx({"t": tube}), {"faces": faces}, {"auto_feature": false})
	var c := _cage_of(r, "t", "Cylindrify")
	if c.is_empty():
		return
	# The middle ring (its interior vertices), measured in doubles about its own centre: the cage
	# ring's radius R and the limit ring's radius.
	var lp := _limit(c)
	var topo := CAGE.topology(c)
	var ring := PackedInt32Array()
	for v in CAGE.vertex_count(c):
		if not topo.is_boundary_vertex(v):
			ring.append(v)
	var cp: PackedFloat64Array = c.positions
	var centre := PackedFloat64Array([0.0, 0.0, 0.0])
	var lcentre := PackedFloat64Array([0.0, 0.0, 0.0])
	for v in ring:
		for k in 3:
			centre[k] += cp[3 * v + k] / ring.size()
			lcentre[k] += lp[3 * v + k] / ring.size()
	var radius := 0.0
	for v in ring:
		radius += sqrt(pow(cp[3 * v] - centre[0], 2) + pow(cp[3 * v + 1] - centre[1], 2) + pow(cp[3 * v + 2] - centre[2], 2)) / ring.size()
	var want := radius * (4.0 + 2.0 * cos(TAU / 8.0)) / 6.0
	var worst := 0.0
	for v in ring:
		var rad := sqrt(pow(lp[3 * v] - lcentre[0], 2) + pow(lp[3 * v + 1] - lcentre[1], 2) + pow(lp[3 * v + 2] - lcentre[2], 2))
		worst = maxf(worst, absf(rad - want))
	_expect(ring.size() == 8 and radius > 0.0 and worst <= 1e-9 * radius, "Cylindrify: the middle ring's limit radius should be R(4 + 2cos(2pi/n))/6 (off %s over %d vertices)." % [worst, ring.size()])
	checked.append("cylindrify limit ring radius R(4+2cos(2pi/8))/6 to %s" % String.num_scientific(worst))


# --- Match ---------------------------------------------------------------------------------------

## A document with an XY sketch holding an arc (or a line), then a form with the strip cage:
## [doc, sketch feature, curve entity id, form feature, body id].
func _match_doc(arc: bool) -> Array:
	var doc: Resource = DOCUMENT.new()
	var sketch: Resource = doc.add_feature("sketch", "Sketch", {}, SKETCH_DATA.new_options(SKETCH_DATA.ORIGIN_PLANES.xy, "xy"))
	var s = SKETCH_DATA.new(sketch, doc)
	var curve := -1
	if arc:
		# A circle of radius 8 about (0, 7.5): the arc's lowest point is (0, -0.5).
		var y := 7.5 - sqrt(60.0)
		var c: int = s.add_point(Vector2(0.0, 7.5))
		var a: int = s.add_point(Vector2(-2.0, y))
		var b: int = s.add_point(Vector2(2.0, y))
		curve = s.add_arc(c, a, b)
	else:
		var a: int = s.add_point(Vector2(-2.0, -1.0))
		var b: int = s.add_point(Vector2(2.0, -1.0))
		curve = s.add_line(a, b)
	var f: Resource = doc.add_feature("form", "Form", {}, FORM.new_options())
	var body: String = doc.new_body(f.id)
	f.options.bodies[body] = PRIMITIVES.plane(Vector2(4, 1), Vector2i(4, 1))
	return [doc, sketch, curve, f, body]


func _lower_chain(body: String, c: Dictionary) -> Array:
	var topo := CAGE.topology(c)
	var chain := []
	for e in topo.nE:
		var ab := topo.edge_vertices(e)
		if CAGE.position(c, ab.x).y < -0.4 and CAGE.position(c, ab.y).y < -0.4:
			chain.append(_edge_item(body, ab.x, ab.y))
	return chain


func _check_match() -> void:
	var made := _match_doc(true)
	var doc: Resource = made[0]
	var f: Resource = made[3]
	var body: String = made[4]
	var result := REGEN.rebuild(doc, kernel, {"form_preview": f.id})
	var cage: Dictionary = f.options.bodies[body]
	var chain := _lower_chain(body, cage)
	var ref := {"kind": "sketch_curve", "sketch": made[1].id, "entity": made[2]}
	var r := _run("match", _ctx({body: cage}, result, doc, f), {"edges": chain}, {"target": [ref]})
	var c := _cage_of(r, body, "Match G0")
	if c.is_empty():
		return
	var samples: PackedFloat64Array = (r.info as Dictionary).get("samples", PackedFloat64Array())
	var order: PackedInt32Array = (r.info as Dictionary).get("order", PackedInt32Array())
	var pairs := PackedInt32Array()
	for item in chain:
		pairs.append(item.pair.x)
		pairs.append(item.pair.y)
	var verts: PackedInt32Array = FORM_FIT.edge_chain(c, pairs).verts
	var lp := _limit(c)
	var worst := 0.0
	var on_arc := 0.0
	for i in verts.size():
		var q := _lv(lp, verts[i])
		worst = maxf(worst, q.distance_to(_lv(samples, order[i])))
		on_arc = maxf(on_arc, absf(q.distance_to(Vector3(0.0, 7.5, 0.0)) - 8.0))
	_expect(worst <= 1e-6 and on_arc <= 1e-5, "Match G0: the boundary's limit points should sit on the arc samples (%s; %s off the circle)." % [worst, on_arc])
	_expect(not _run("match", _ctx({body: cage}, result, doc, f), {"edges": chain}, {"target": [ref], "continuity": "g1"}).ok,
		"G1 to a sketch curve should be refused (no face beside it).")
	# G1 to a model edge: a strip beside a box's top edge takes the top face's tangent plane.
	var box: RefCounted = kernel.make_box(Vector3(6, 2, 1), Vector3(-3, -1, -1))
	var edge_index := -1
	for e in box.edge_count():
		var info: Dictionary = box.edge_info(e)
		var m: Vector3 = info.midpoint
		if absf(m.y - 1.0) < 1e-9 and absf(m.z) < 1e-9:
			edge_index = e
	var model := {"bodies": {"bx": {"id": "bx", "shape": box, "feature": "f0"}}}
	var edge_ref := REFERENCES_FOR_TEST.from_pick({"kind": "edge", "body": "bx", "index": edge_index, "point": Vector3.ZERO}, model)
	var strip: Dictionary = FORM_OPS.transform_vertices(PRIMITIVES.plane(Vector2(4, 1), Vector2i(4, 1)), PackedInt32Array(range(10)), PackedFloat32Array(),
		FORM_OPS.xf_from(Basis.IDENTITY, Vector3(0.0, 1.7, 0.1))).cage
	var g1_chain := []
	var stopo := CAGE.topology(strip)
	for e in stopo.nE:
		var ab := stopo.edge_vertices(e)
		if CAGE.position(strip, ab.x).y < 1.3 and CAGE.position(strip, ab.y).y < 1.3:
			g1_chain.append(_edge_item("g", ab.x, ab.y))
	var rg := _run("match", _ctx({"g": strip}, model), {"edges": g1_chain}, {"target": [edge_ref], "continuity": "g1"})
	var cg := _cage_of(rg, "g", "Match G1")
	var flat := 0.0
	var away := true
	var inner := 0
	if not cg.is_empty():
		for v in CAGE.vertex_count(cg):
			var q := CAGE.position_d(cg, v)
			if CAGE.position(strip, v).y > 2.0 and not stopo.is_boundary_edge(_cross_edge(stopo, strip, v)):
				inner += 1
				flat = maxf(flat, absf(q[2]))
				away = away and q[1] > 1.0
		var glp := _limit(cg)
		for item in g1_chain:
			for v in [item.pair.x, item.pair.y]:
				flat = maxf(flat, absf(glp[3 * v + 2]) + absf(glp[3 * v + 1] - 1.0))
	_expect(edge_index >= 0 and inner == 3 and flat <= 1e-9 and away, "Match G1: the boundary should lie on the edge and the inner row in the top face's plane, away from the box (%s, %d inner, away %s)." % [flat, inner, away])
	checked.append("match G0 onto a sketch arc (limit at the samples to %s), G1 to a model edge (tangent plane to %s), G1 to a sketch curve refused" % [String.num_scientific(worst), String.num_scientific(flat)])


## The edge from v across the strip (to the vertex on the other side), -1 when none.
func _cross_edge(topo: CAGE.Topo, c: Dictionary, v: int) -> int:
	for e in topo.vertex_edges(v):
		var ab := topo.edge_vertices(e)
		var w := ab.y if ab.x == v else ab.x
		if absf(CAGE.position(c, w).x - CAGE.position(c, v).x) < 1e-9:
			return e
	return -1


func _check_match_associative() -> void:
	FORM.clear_cache()
	var made := _match_doc(false)
	var doc: Resource = made[0]
	var sketch: Resource = made[1]
	var f: Resource = made[3]
	var body: String = made[4]
	var result := REGEN.rebuild(doc, kernel, {"form_preview": f.id})
	var cage: Dictionary = f.options.bodies[body]
	var chain := _lower_chain(body, cage)
	var ref := {"kind": "sketch_curve", "sketch": sketch.id, "entity": made[2]}
	var r := _run("match", _ctx({body: cage}, result, doc, f), {"edges": chain}, {"target": [ref], "associative": true})
	var c := _cage_of(r, body, "Match (associative)")
	if c.is_empty():
		return
	_expect((c.get("links", []) as Array).size() == 1, "Associative Match should store one link (%s)." % [c.get("links", [])])
	f.options.bodies[body] = c
	var before := REGEN.rebuild(doc, kernel)
	var shape: RefCounted = (before.bodies.get(body, {}) as Dictionary).get("shape")
	_expect(shape != null, "The matched form should convert (%s)." % [before.errors])
	var min_y_before := (shape.bbox() as AABB).position.y if shape != null else 0.0
	# Move the sketch line 0.25 down and rebuild: the form's boundary follows.
	var s = SKETCH_DATA.new(sketch, doc)
	for e in s.entities():
		if str(e.type) == "point":
			var q: Vector2 = s.point(int(e.id))
			s.set_point(int(e.id), q + Vector2(0.0, -0.25))
	FORM.clear_cache()
	var after := REGEN.rebuild(doc, kernel)
	var shape2: RefCounted = (after.bodies.get(body, {}) as Dictionary).get("shape")
	var min_y_after := (shape2.bbox() as AABB).position.y if shape2 != null else 0.0
	_expect(shape2 != null and absf((min_y_after - min_y_before) + 0.25) <= 1e-4, "Moving the sketch should move the form's boundary by 0.25 (%s -> %s)." % [min_y_before, min_y_after])
	_expect(CAGE.content_hash(f.options.bodies[body]) == CAGE.content_hash(c), "The stored cage should not change on a rebuild.")
	# A target after the form is refused.
	var late: Resource = doc.add_feature("sketch", "Sketch", {}, SKETCH_DATA.new_options(SKETCH_DATA.ORIGIN_PLANES.xy, "xy"))
	var s2 = SKETCH_DATA.new(late, doc)
	var la: int = s2.add_point(Vector2(-2, -1.2))
	var lb: int = s2.add_point(Vector2(2, -1.2))
	var line2: int = s2.add_line(la, lb)
	var full := REGEN.rebuild(doc, kernel)
	var refused := _run("match", _ctx({body: cage}, full, doc, f), {"edges": chain}, {"target": [{"kind": "sketch_curve", "sketch": late.id, "entity": line2}], "associative": true})
	_expect(not refused.ok and str(refused.error) == "Associative targets must come before the form in the timeline", "A later target should be refused (%s)." % refused.get("error", ""))
	checked.append("associative match (link stored, moving the sketch moves the converted boundary by %.4f, stored cage untouched, later targets refused)" % (min_y_after - min_y_before))


# --- Convert -------------------------------------------------------------------------------------

func _check_convert_brep() -> void:
	FORM.clear_cache()
	var doc: Resource = DOCUMENT.new()
	var f: Resource = doc.add_feature("form", "Form", {}, FORM.new_options())
	var body: String = doc.new_body(f.id)
	f.options.bodies[body] = PRIMITIVES.box(Vector3.ONE * 0.02, Vector3i(2, 2, 2))
	var normal := REGEN.rebuild(doc, kernel)
	var volume := float(normal.bodies[body].shape.volume()) if normal.bodies.has(body) else 0.0
	var r := _run("convert", _ctx(f.options.bodies.duplicate(), {}, doc, f), {"bodies": [_body_item(body)]})
	_expect(r.ok and (r.breps as Dictionary).has(body), "Convert (Form to BRep) should give the body's B-rep (%s)." % r.get("error", ""))
	if not r.ok:
		return
	# What the editor's apply_result does with it.
	f.options.bodies.erase(body)
	f.options.breps[body] = r.breps[body]
	var after := REGEN.rebuild(doc, kernel)
	var v2 := float(after.bodies[body].shape.volume()) if after.bodies.has(body) else -1.0
	_expect(volume > 0.0 and absf(v2 - volume) <= volume * 1e-9, "The converted body should rebuild with the same volume (%s / %s)." % [volume, v2])
	_expect(not (f.options.bodies as Dictionary).has(body) and (f.options.breps as Dictionary).has(body), "The body should live in breps now.")
	checked.append("convert form to B-rep (volume kept through a rebuild: %s m3)" % String.num_scientific(v2))


func _check_convert_face() -> void:
	var box: RefCounted = kernel.make_box(Vector3(0.04, 0.03, 0.02), Vector3.ZERO)
	var top := -1
	for i in box.face_count():
		var info: Dictionary = box.face_info(i)
		if (info.normal as Vector3).z > 0.9:
			top = i
	var r := _run("convert", _ctx({}), {}, {"direction": "face_form", "faces": [{"shape": box, "index": top}]})
	_expect(r.ok and (r.new_bodies as Array).size() == 1, "Face to Form on a box face should make one body (%s)." % r.get("error", ""))
	if not r.ok:
		return
	var c: Dictionary = r.new_bodies[0]
	var residual := float((r.info as Dictionary).get("residual", INF))
	_expect(CAGE.validate(c).is_empty() and residual <= 1e-9, "The face's cage should be valid and its limit within 1e-9 of the samples (%s)." % residual)
	var lp := _limit(c)
	var flat := 0.0
	var up := true
	for v in CAGE.vertex_count(c):
		flat = maxf(flat, absf(lp[3 * v + 2] - 0.02))
	var topo := CAGE.topology(c)
	up = topo.face_normal(c, 0).z > 0.9
	_expect(flat <= 1e-9 and up, "The face's cage should lie on the face, facing out (%s, up %s)." % [flat, up])
	var round: RefCounted = kernel.make_sphere(0.01)
	var bad := _run("convert", _ctx({}), {}, {"direction": "face_form", "faces": [{"shape": round, "index": 0}]})
	_expect(not bad.ok and str(bad.error).contains("four-sided"), "A face that isn't four-sided should be refused (%s)." % bad.get("error", ""))
	checked.append("convert face to form (%s, limit within %s of the samples, non-four-sided refused)" % [_vef(c), String.num_scientific(residual)])


func _check_convert_mesh() -> void:
	var path := OS.get_user_data_dir().path_join("holo_forge_form_tools_cube_%d.obj" % OS.get_process_id())
	var text := "v 0 0 0\nv 1 0 0\nv 1 1 0\nv 0 1 0\nv 0 0 1\nv 1 0 1\nv 1 1 1\nv 0 1 1\n"
	text += "f 1 4 3 2\nf 5 6 7 8\nf 1 2 6 5\nf 2 3 7 6\nf 3 4 8 7\nf 4 1 5 8\n"
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()
	var polys := MESH_IMPORT.read_polygons(path, "m")
	_expect(str(polys.error) == "" and (polys.faces as Array).size() == 6 and (polys.faces[0] as PackedInt32Array).size() == 4, "read_polygons should keep the OBJ's 6 quads (%s)." % polys.get("error", ""))
	var doc: Resource = DOCUMENT.new()
	var made := INSERT.add_mesh_import(doc, path, "mm")
	var feature: Resource = made.feature
	var f: Resource = doc.add_feature("form", "Form", {}, FORM.new_options())
	var result := REGEN.rebuild(doc, kernel, {"form_preview": f.id})
	var mesh_body := str(feature.options.body_id) if feature != null else ""
	var r := _run("convert", _ctx({}, result, doc, f), {}, {"direction": "mesh_form", "mesh_body": [mesh_body]})
	_expect(r.ok and (r.new_bodies as Array).size() == 1, "Mesh to Form should make one cage body (%s)." % r.get("error", ""))
	if r.ok:
		var c: Dictionary = r.new_bodies[0]
		_expect(_vef(c) == "8/12/6" and CAGE.validate(c).is_empty() and CAGE.signed_volume(c) > 0.0, "The OBJ cube should become a valid outward 8/12/6 cage (%s)." % _vef(c))
		var b := CAGE.bounds(c)
		_expect(b.size.is_equal_approx(Vector3.ONE * 0.001), "The mesh's millimetre units should carry over (%s)." % b)
	DirAccess.remove_absolute(path)
	checked.append("convert mesh to form (OBJ of 6 quads -> 8/12/6)")


# --- Bridge Follow Curve --------------------------------------------------------------------------

func _check_follow_curve() -> void:
	var cube := PRIMITIVES.box(Vector3.ONE, Vector3i.ONE)
	var cube2: Dictionary = FORM_OPS.transform_vertices(cube, PackedInt32Array(range(8)), PackedFloat32Array(), FORM_OPS.xf_translation(4.0, 0.0, 0.0)).cage
	var joined: Dictionary = CAGE.append(cube, cube2).cage
	var fx := _facing(cube, Vector3.RIGHT)
	var fmx := _facing(cube2, Vector3.LEFT) + 6
	var r := FORM_OPS.bridge(joined, {"faces": PackedInt32Array([fx]), "faces2": PackedInt32Array([fmx])}, {"segments": 4})
	_expect(r.ok, "The bridge for Follow Curve should work (%s)." % r.get("error", ""))
	if not r.ok:
		return
	# An arc bulging up between the two faces' centres.
	var curve := PackedFloat64Array()
	for i in 33:
		var t := float(i) / 32.0
		curve.append_array(PackedFloat64Array([0.5 + 3.0 * t, 0.0, 1.2 * sin(PI * t)]))
	var fr := MODIFY.follow_curve(r.cage, r.info.new_vertices, 4, 4, Vector3(0.5, 0, 0), Vector3(3.5, 0, 0), curve)
	_expect(not fr.has("error"), "Follow Curve should work (%s)." % fr.get("error", ""))
	if fr.has("error"):
		return
	var c: Dictionary = fr.cage
	var nv: PackedInt32Array = r.info.new_vertices
	var worst := 0.0
	for k in 3:
		var centre := CAGE._centroid(c.positions, nv.slice(4 * k, 4 * k + 4))
		var best := INF
		for i in 33:
			best = minf(best, centre.distance_to(Vector3(curve[3 * i], curve[3 * i + 1], curve[3 * i + 2])))
		worst = maxf(worst, best)
	_expect(worst < 0.05 and CAGE.validate(c).is_empty(), "The rings' centres should sit on the curve (%s)." % worst)
	checked.append("bridge follow curve (ring centres within %.3f of the curve)" % worst)
