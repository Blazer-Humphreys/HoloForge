extends SceneTree
## Holo Forge Form cages (pure topology, no kernel): the primitives have the counts of the work
## order's table, are valid and face outward; Topo finds edges, valences, boundary loops, edge
## loops, rings, face loops, components and the canonical edge order; every topology op gives
## its V/E/F counts with a valid cage (Insert Edge, Subdivide, Catmull-Clark step, extrude,
## extend, Insert Point, Fill Hole, Bridge, Merge Edge, Weld, UnWeld, Bevel, Thicken, Mirror and
## Circular Duplicate, Delete, Erase and Fill); one Catmull-Clark step keeps the limit point of
## every original vertex (smooth and crease rules); compact remaps creases, frozen, symmetry and
## isolated vertices; topology() and validate() of a 5046-face cage stay within budget.
##
## godot --headless --path . --script res://tests/holo_forge_form_cage_test.gd

const CAGE := preload("res://addons/holo_forge/core/form/cage.gd")
const PRIM := preload("res://addons/holo_forge/core/form/primitives.gd")
const OPS := preload("res://addons/holo_forge/core/form/form_ops.gd")
const TIMING := preload("res://tests/holo_forge_timing.gd")

var failures: Array[String] = []
var _sink := 0.0
var _timings := PackedStringArray()


func _init() -> void:
	call_deferred("run")


func run() -> void:
	_check_primitives()
	_check_topo()
	_check_selection_helpers()
	_check_insert_edge()
	_check_subdivide()
	_check_catmull_clark()
	_check_extrude_extend()
	_check_insert_point()
	_check_fill_hole()
	_check_bridge_merge_weld()
	_check_unweld()
	_check_bevel()
	_check_thicken()
	_check_duplicates()
	_check_delete()
	_check_compact()
	_check_misc_ops()
	_check_timing()
	print(("PASS holo_forge_form_cage: primitive counts and outward orientation (box, plane, cylinder, sphere, torus, quadball), Topo edges/valence/boundary loop/edge loop/ring/face loop/components/canonical edge order, selection helpers, op counts with valid cages (insert edge single and both, subdivide, Catmull-Clark step keeping limit points, extrude, extend, insert point, fill hole in three modes for n = 6/7/8, bridge, merge edge, weld, unweld, bevel 1/2/3, thicken, mirror and circular duplicate, delete, erase and fill), compact remapping, timings (%s)." % ", ".join(_timings)) \
		if failures.is_empty() else "FAIL holo_forge_form_cage")
	quit(0 if failures.is_empty() else 1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error(message)
		print("FAIL: ", message)


## Vector3i(V, E, F).
func _vef(c: Dictionary) -> Vector3i:
	var t := CAGE.topology(c)
	return Vector3i(t.nV, t.nE, t.nF)


func _counts(c: Dictionary, want: Vector3i, label: String) -> void:
	var got := _vef(c)
	_expect(got == want, "%s should be V/E/F %d/%d/%d (got %d/%d/%d)." % [label, want.x, want.y, want.z, got.x, got.y, got.z])
	var problems := CAGE.validate(c)
	_expect(problems.is_empty(), "%s should be a valid cage (%s)." % [label, ", ".join(problems)])


func _ok(r: Dictionary, label: String) -> bool:
	var good: bool = r.get("ok", r.get("error", "") == "") and str(r.get("error", "")) == ""
	_expect(good, "%s should succeed (%s)." % [label, r.get("error", "")])
	return good


## The numbered cube of the canonical-order check: [-1, 1]^3.
func _cube() -> Dictionary:
	var pts := PackedVector3Array([Vector3(-1, -1, -1), Vector3(1, -1, -1), Vector3(1, 1, -1), Vector3(-1, 1, -1), Vector3(-1, -1, 1), Vector3(1, -1, 1), Vector3(1, 1, 1), Vector3(-1, 1, 1)])
	return CAGE.from_vectors(pts, [[0, 3, 2, 1], [4, 5, 6, 7], [0, 1, 5, 4], [1, 2, 6, 5], [2, 3, 7, 6], [3, 0, 4, 7]])


func _face_sizes(c: Dictionary, size: int) -> int:
	var n := 0
	for k in (c.face_counts as PackedInt32Array):
		if k == size:
			n += 1
	return n


## Vertex pairs of the edges whose ends both have coordinate axis == value.
func _edges_at(c: Dictionary, axis: int, value: float) -> PackedInt32Array:
	var t := CAGE.topology(c)
	var p: PackedFloat64Array = c.positions
	var out := PackedInt32Array()
	for e in t.nE:
		var a := t.edges[2 * e]
		var b := t.edges[2 * e + 1]
		if absf(p[3 * a + axis] - value) < 1e-12 and absf(p[3 * b + axis] - value) < 1e-12:
			out.append(a)
			out.append(b)
	return out


func _check_primitives() -> void:
	var closed := [
		["box 1,1,1", PRIM.box(Vector3(2, 2, 2), Vector3i(1, 1, 1)), Vector3i(8, 12, 6)],
		["box 2,2,2", PRIM.box(Vector3(2, 2, 2), Vector3i(2, 2, 2)), Vector3i(26, 48, 24)],
		["box 3,2,1", PRIM.box(Vector3(0.03, 0.02, 0.01), Vector3i(3, 2, 1)), Vector3i(24, 44, 22)],
		["cylinder 8,2", PRIM.cylinder(1.0, 1.0, 8, 2), Vector3i(26, 56, 32)],
		["sphere 8,4", PRIM.sphere(1.0, 8, 4), Vector3i(26, 56, 32)],
		["torus 8,6", PRIM.torus(1.0, 0.25, 8, 6), Vector3i(48, 96, 48)],
		["quadball 1", PRIM.quadball(1.0, 1), Vector3i(8, 12, 6)],
		["quadball 2", PRIM.quadball(1.0, 2), Vector3i(26, 48, 24)],
	]
	for entry in closed:
		var c: Dictionary = entry[1]
		_counts(c, entry[2], "Primitive " + entry[0])
		_expect(CAGE.signed_volume(c) > 0.0, "Primitive %s should face outward (signed volume %s)." % [entry[0], CAGE.signed_volume(c)])
		_expect(CAGE.topology(c).is_closed(), "Primitive %s should be closed." % entry[0])
	_counts(PRIM.plane(Vector2(1, 1), Vector2i(2, 2)), Vector3i(9, 12, 4), "Primitive plane 2x2")
	var plane := PRIM.plane(Vector2(1, 1), Vector2i(2, 2))
	var t := CAGE.topology(plane)
	_expect(t.face_normal(plane, 0).z > 0.99, "The plane's faces should face +Z.")
	_counts(PRIM.cylinder(1.0, 1.0, 8, 2, "ngon"), Vector3i(24, 40, 18), "Cylinder 8,2 with n-gon caps")
	_expect(CAGE.signed_volume(PRIM.cylinder(1.0, 1.0, 8, 2, "ngon")) > 0.0, "The n-gon capped cylinder should face outward.")
	_counts(PRIM.cylinder(1.0, 1.0, 8, 2, "open"), Vector3i(24, 40, 16), "Open cylinder 8,2")
	# Mirror coordinates negate exactly.
	var box := PRIM.box(Vector3(0.05, 0.04, 0.03), Vector3i(3, 3, 3))
	var p: PackedFloat64Array = box.positions
	var found := 0
	for v in CAGE.vertex_count(box):
		for w in CAGE.vertex_count(box):
			if p[3 * w] == -p[3 * v] and p[3 * w + 1] == p[3 * v + 1] and p[3 * w + 2] == p[3 * v + 2]:
				found += 1
				break
	_expect(found == CAGE.vertex_count(box), "Every box vertex should have an exact mirror image across x = 0 (%d of %d)." % [found, CAGE.vertex_count(box)])
	# Primitive symmetry: maps complete and partners exact.
	var cyl := PRIM.primitive_symmetry(PRIM.cylinder(1.0, 1.0, 8, 2), "circular", Transform3D.IDENTITY, Vector3i.ZERO, 8)
	var m: PackedInt32Array = cyl.symmetry[0].map
	_expect(not m.has(-1) and m.size() == 26, "A circular cylinder's map should cover every vertex.")
	_expect(m[24] == 24 and m[25] == 25, "The cylinder's poles should map to themselves.")


func _check_topo() -> void:
	var cube := _cube()
	var t := CAGE.topology(cube)
	_expect(t.nE == 12, "The cube should have 12 edges (%d)." % t.nE)
	for v in 8:
		_expect(t.valence(v) == 3, "Cube vertex %d should have valence 3 (%d)." % [v, t.valence(v)])
	_expect(t.is_closed(), "The cube should be closed.")
	var expected := PackedInt32Array([0, 3, 2, 3, 1, 2, 0, 1, 4, 5, 5, 6, 6, 7, 4, 7, 1, 5, 0, 4, 2, 6, 3, 7])
	_expect(t.edges == expected, "The cube's canonical edge order should be %s (got %s)." % [expected, t.edges])
	for e in t.nE:
		var h := t.edge_he[e]
		_expect(t.he_twin[h] >= 0 and t.he_twin[t.he_twin[h]] == h, "Cube edge %d should have twinned half-edges." % e)
	_expect(t.edge_index(3, 0) == 0 and t.edge_index(0, 6) == -1, "edge_index should find edges either way and -1 for none.")
	_expect(t.edge_lookup.has((3 << 32) | 7), "edge_lookup should key edges by (min << 32) | max.")
	var vf := t.vertex_faces(0)
	_expect(vf.size() == 3 and vf.has(0) and vf.has(2) and vf.has(5), "Cube vertex 0 should touch faces 0, 2 and 5 (%s)." % vf)
	_expect(t.face_by_vertices(PackedInt32Array([6, 5, 4, 7])) == 1, "face_by_vertices should find the top face in any order.")
	_expect(t.face_normal(cube, 1).is_equal_approx(Vector3(0, 0, 1)), "The top face normal should be +Z.")
	_expect(t.vertex_normal(cube, 6).is_equal_approx(Vector3(1, 1, 1).normalized()), "Corner 6's normal should point along (1, 1, 1).")
	# Rotational order: consecutive faces share an edge.
	var box := PRIM.box(Vector3(2, 2, 2), Vector3i(2, 2, 2))
	var tb := CAGE.topology(box)
	for v in tb.nV:
		var faces := tb.vertex_faces(v)
		for i in faces.size():
			var a := faces[i]
			var b := faces[(i + 1) % faces.size()]
			_expect(tb.face_neighbors(a).has(b), "Faces around vertex %d should be in rotational order." % v)
	var plane := PRIM.plane(Vector2(1, 1), Vector2i(2, 2))
	var tp := CAGE.topology(plane)
	var loops := tp.boundary_loops()
	_expect(loops.size() == 1 and (loops[0] as PackedInt32Array).size() == 8, "The 2x2 plane should have one boundary loop of 8 vertices (%s)." % [loops])
	if loops.size() == 1:
		var loop: PackedInt32Array = loops[0]
		for i in loop.size():
			_expect(tp.half_edge(loop[i], loop[(i + 1) % loop.size()]) >= 0, "The boundary loop should run in boundary half-edge order.")
	_expect(tp.is_boundary_vertex(0) and not tp.is_boundary_vertex(4), "Plane corners are on the boundary, the centre isn't.")
	_expect(tp.valence(0) == 2 and tp.valence(1) == 3 and tp.valence(4) == 4, "Plane valences should be 2 / 3 / 4 (%d %d %d)." % [tp.valence(0), tp.valence(1), tp.valence(4)])
	# Box 2,2,2: the equator loop, ring and face loop.
	var eq := _edges_at(box, 2, 0.0)
	_expect(eq.size() == 16, "Box 2,2,2 should have 8 equator edges (%d)." % (eq.size() / 2))
	var e0 := tb.edge_index(eq[0], eq[1])
	var loop := tb.edge_loop(e0)
	_expect(loop.size() == 8, "The equator edge loop should have 8 edges (%d)." % loop.size())
	var ends := tb.chain_vertices(loop)
	var first_e := tb.edge_vertices(loop[0])
	var last_e := tb.edge_vertices(loop[loop.size() - 1])
	var touching := first_e.x == last_e.x or first_e.x == last_e.y or first_e.y == last_e.x or first_e.y == last_e.y
	_expect(loop.size() > 2 and touching and ends.size() == loop.size(), "The equator loop should be closed.")
	var eqset := {}
	for i in eq.size() / 2:
		eqset[tb.edge_index(eq[2 * i], eq[2 * i + 1])] = true
	for e in loop:
		_expect(eqset.has(e), "The equator loop should only hold equator edges.")
	var vl := tb.chain_vertices(loop)
	_expect(vl.size() == 8, "The equator loop should visit 8 vertices (%d)." % vl.size())
	# Every face of box 2,2,2 is a quad, so the ring from an equator edge runs on over the top
	# and bottom and closes in 8 edges (the work order says 4, which its own rule can't give).
	var ring := tb.edge_ring(e0)
	_expect(ring.size() == 8, "An edge ring from an equator edge should close over the top and bottom in 8 edges (%d)." % ring.size())
	var bpos: PackedFloat64Array = box.positions
	var e0v := tb.edge_vertices(e0)
	var dir0 := CAGE.position(box, e0v.y) - CAGE.position(box, e0v.x)
	for e in ring:
		var ev := tb.edge_vertices(e)
		var dir := CAGE.position(box, ev.y) - CAGE.position(box, ev.x)
		_expect(absf(absf(dir.normalized().dot(dir0.normalized())) - 1.0) < 1e-6, "Ring edges should run parallel to the equator edge.")
	_expect(bpos.size() == 78, "Box 2,2,2 has 26 vertices.")
	var hf := tb.edge_he[e0]
	var fa := tb.he_face[hf]
	var fb := -1
	for g in tb.face_neighbors(fa):
		# The neighbour across the equator edge's neighbour around the box: same z band.
		var cen_a := CAGE._centroid(box.positions, tb.face_verts(fa))
		var cen_g := CAGE._centroid(box.positions, tb.face_verts(g))
		if absf(cen_a.z - cen_g.z) < 1e-9:
			fb = g
			break
	var fl := tb.face_loop(fa, fb)
	_expect(fl.size() == 8, "The face loop around the middle should have 8 faces (%d)." % fl.size())
	# Components.
	var two: Dictionary = CAGE.append(_cube(), _cube()).cage
	var t2 := CAGE.topology(two)
	_expect(t2.component_count() == 2, "Two appended cubes should be 2 components (%d)." % t2.component_count())
	_expect(t2.components()[5] == 0 and t2.components()[6] == 1, "Components should be numbered by lowest face.")
	_expect(t2.component_vertices(1).size() == 8 and t2.component_vertices(1)[0] == 8, "The second cube's vertices should be 8..15.")
	# Broken topology is recorded.
	var fan := CAGE.from_vectors(PackedVector3Array([Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(0, -1, 0), Vector3(0, 0, 1)]), [[0, 1, 2], [1, 0, 3], [0, 1, 4]])
	var tf := CAGE.topology(fan)
	_expect(tf.non_manifold_edges() == PackedInt32Array([0, 1]), "The fan's shared edge should be non-manifold (%s)." % tf.non_manifold_edges())
	_expect(not CAGE.validate(fan).is_empty(), "validate should reject a non-manifold fan.")
	var flipped := _cube()
	var fidx: PackedInt32Array = flipped.face_indices
	fidx[1] = 1
	fidx[3] = 3
	flipped.face_indices = fidx
	_expect(not CAGE.validate(flipped).is_empty(), "validate should reject a flipped face.")


func _check_selection_helpers() -> void:
	var box := PRIM.box(Vector3(2, 2, 2), Vector3i(2, 2, 2))
	var t := CAGE.topology(box)
	var grown := t.grow("face", PackedInt32Array([0]))
	_expect(grown.size() == 8, "Growing one face of box 2,2,2 by vertex adjacency should give 8 faces (%d)." % grown.size())
	_expect(t.shrink("face", grown) == PackedInt32Array([0]), "Shrinking it back should give the one face (%s)." % t.shrink("face", grown))
	_expect(t.invert("face", PackedInt32Array([0, 1])).size() == 22, "Inverting 2 faces should give 22.")
	var eq := _edges_at(box, 2, 0.0)
	var e0 := t.edge_index(eq[0], eq[1])
	var loop := t.edge_loop(e0)
	var lg := t.loop_grow(PackedInt32Array([e0]))
	_expect(lg.size() == 3, "Loop grow from one equator edge should add one at each end (%d)." % lg.size())
	var rg := t.ring_grow(PackedInt32Array([e0]))
	_expect(rg.size() == 3, "Ring grow from one equator edge should add its two ring neighbours (%d)." % rg.size())
	_expect(t.ring_shrink(rg) == PackedInt32Array([e0]), "Ring shrink should drop the ring ends.")
	var far := loop[4]
	var rs := t.range_select("edge", loop[0], far)
	_expect(rs.size() == 5, "Range along the closed equator loop to the opposite edge should hold 5 edges (%d)." % rs.size())
	var near := t.range_select("edge", loop[0], loop[6])
	_expect(near.size() == 3, "Range should go the short way round (%d)." % near.size())
	var vl := t.vertex_loop(eq[0], eq[1])
	_expect(vl.size() == 8 and vl[0] == eq[0] and vl[1] == eq[1], "vertex_loop should list the loop starting a, b (%s)." % vl)
	var vg := t.grow("vertex", PackedInt32Array([vl[0]]))
	_expect(vg.size() == 5, "Growing a valence-4 vertex should add its 4 neighbours (%d)." % vg.size())
	# Feature faces: the band round a cylinder.
	var cyl := PRIM.cylinder(1.0, 2.0, 8, 3, "pole")
	var tc := CAGE.topology(cyl)
	var band := tc.feature_faces(8)
	_expect(band.size() == 24, "Feature selection on a cylinder side should take its 3 rows of 8 faces (%d)." % band.size())
	for f in band:
		_expect(tc.face_size(f) == 4, "The feature band should only hold side quads.")


func _check_insert_edge() -> void:
	var cube := _cube()
	var r := OPS.insert_edge(cube, {"edges": PackedInt32Array([0, 1])}, {"location": 0.5})
	if _ok(r, "Insert Edge on one cube edge"):
		_counts(r.cage, Vector3i(10, 15, 7), "Insert Edge on one cube edge")
		_expect(_face_sizes(r.cage, 5) == 2, "Inserting on one cube edge should make two pentagons (%d)." % _face_sizes(r.cage, 5))
		_expect((r.selection.edges as PackedInt32Array).size() == 2, "Insert Edge should select the new edge.")
	var box := PRIM.box(Vector3(2, 2, 2), Vector3i(2, 2, 2))
	var eq := _edges_at(box, 2, 0.0)
	r = OPS.insert_edge(box, {"edges": eq}, {"location": 0.5, "side": "single"})
	if _ok(r, "Insert Edge on the equator (single)"):
		_counts(r.cage, Vector3i(34, 64, 32), "Insert Edge on the equator (single)")
		var nv: PackedInt32Array = r.info.new_vertices
		var p: PackedFloat64Array = r.cage.positions
		var side := signf(p[3 * nv[0] + 2])
		for v in nv:
			_expect(absf(absf(p[3 * v + 2]) - 0.5) < 1e-12 and signf(p[3 * v + 2]) == side, "Single-side inserts should all land on one side at half way (z = %s)." % p[3 * v + 2])
	r = OPS.insert_edge(box, {"edges": eq}, {"location": 0.5, "side": "both"})
	if _ok(r, "Insert Edge on the equator (both)"):
		_counts(r.cage, Vector3i(42, 80, 40), "Insert Edge on the equator (both)")
	var neg := OPS.insert_edge(box, {"edges": eq}, {"location": -0.25})
	if _ok(neg, "Insert Edge on the other side"):
		var p: PackedFloat64Array = neg.cage.positions
		var pos: PackedFloat64Array = OPS.insert_edge(box, {"edges": eq}, {"location": 0.25}).cage.positions
		var v0: int = (neg.info.new_vertices as PackedInt32Array)[0]
		_expect(signf(p[3 * v0 + 2]) != signf(pos[3 * v0 + 2]), "A negative location should insert on the other side.")
	# A creased rail stays creased on both halves.
	var creased := _cube()
	CAGE.set_crease(creased, 0, 3, CAGE.SHARP)
	CAGE.set_crease(creased, 1, 2, CAGE.SHARP)
	var rc := CAGE.insert_edge_loop(creased, [{"edge": Vector2i(0, 1), "side": 0}], 0.5, false)
	_expect(rc.error == "" and (rc.cage.crease_edges as PackedInt32Array).size() == 8, "Creased rails should stay creased on both halves (%s)." % [rc.cage.crease_edges if rc.error == "" else rc.error])


func _check_subdivide() -> void:
	var cube := _cube()
	var r := OPS.subdivide(cube, {"faces": PackedInt32Array([1])}, {})
	if _ok(r, "Subdivide one cube face 2x2"):
		_counts(r.cage, Vector3i(13, 20, 9), "Subdivide one cube face 2x2")
		_expect(_face_sizes(r.cage, 5) == 4, "Subdividing one cube face should make its 4 neighbours pentagons (%d)." % _face_sizes(r.cage, 5))
		var p: PackedFloat64Array = r.cage.positions
		_expect(p[3 * 12] == 0.0 and p[3 * 12 + 1] == 0.0 and p[3 * 12 + 2] == 1.0, "The top face's centre point should be (0, 0, 1) exactly.")
	var three := OPS.subdivide(cube, {"faces": PackedInt32Array([1])}, {"u_faces": 3, "v_faces": 2})
	if _ok(three, "Subdivide one cube face 3x2"):
		_counts(three.cage, Vector3i(8 + 6 + 2, 12 + 6 + 7, 11), "Subdivide one cube face 3x2")
	var prism := PRIM.cylinder(1.0, 1.0, 5, 1, "ngon")
	_counts(prism, Vector3i(10, 15, 7), "Pentagonal prism")
	var pent := -1
	for f in CAGE.face_count(prism):
		if (prism.face_counts as PackedInt32Array)[f] == 5:
			pent = f
			break
	var rp := OPS.subdivide(prism, {"faces": PackedInt32Array([pent])}, {})
	if _ok(rp, "Subdivide a pentagon"):
		var nf: PackedInt32Array = rp.selection.faces
		_expect(nf.size() == 5, "A pentagon should become 5 faces (%d)." % nf.size())
		var t := CAGE.topology(rp.cage)
		for f in nf:
			_expect(t.face_size(f) == 4, "A subdivided pentagon's faces should be quads.")
		_counts(rp.cage, Vector3i(16, 25, 11), "Pentagonal prism with a subdivided cap")


## The limit point of an interior smooth vertex whose faces are all quads:
## (n^2 P + 4 sum(edge neighbours) + sum(diagonal corners)) / (n (n + 5)).
func _limit_quad_vertex(c: Dictionary, t: CAGE.Topo, v: int) -> PackedFloat64Array:
	var p: PackedFloat64Array = c.positions
	var n := t.valence(v)
	var out := PackedFloat64Array([0.0, 0.0, 0.0])
	for d in 3:
		out[d] = n * n * p[3 * v + d]
	for w in t.vertex_neighbors(v):
		for d in 3:
			out[d] += 4.0 * p[3 * w + d]
	for h in t.vertex_out(v):
		var diag := t.face_indices[t.he_next(t.he_next(h))]
		for d in 3:
			out[d] += p[3 * diag + d]
	for d in 3:
		out[d] /= n * (n + 5)
	return out


func _check_catmull_clark() -> void:
	var cube := _cube()
	var r := CAGE.catmull_clark_step(cube)
	_expect(r.error == "", "The Catmull-Clark step should succeed (%s)." % r.error)
	_counts(r.cage, Vector3i(26, 48, 24), "Catmull-Clark step of the cube")
	var tc := CAGE.topology(cube)
	var lim := _limit_quad_vertex(cube, tc, 6)
	_expect(absf(lim[0] - 0.5) < 1e-15 and absf(lim[1] - 0.5) < 1e-15 and absf(lim[2] - 0.5) < 1e-15, "The cube corner's limit should be (0.5, 0.5, 0.5) (%s)." % lim)
	var p: PackedFloat64Array = r.cage.positions
	_expect(absf(p[18] - 5.0 / 9.0) < 1e-15, "The cube corner should move to 5/9 (%s)." % p[18])
	# Limits of the original vertices survive one and two steps, also on a noisy cage.
	var rng := RandomNumberGenerator.new()
	rng.seed = 6061
	var noisy := PRIM.box(Vector3(2, 2, 2), Vector3i(3, 3, 3))
	var np: PackedFloat64Array = noisy.positions
	for i in np.size():
		np[i] += rng.randf_range(-0.15, 0.15)
	noisy.positions = np
	for c0 in [cube, noisy]:
		var parent: Dictionary = c0
		var tp := CAGE.topology(parent)
		var child: Dictionary = CAGE.catmull_clark_step(parent).cage
		var grand: Dictionary = CAGE.catmull_clark_step(child).cage
		var t1 := CAGE.topology(child)
		var t2 := CAGE.topology(grand)
		var worst := 0.0
		for v in tp.nV:
			var a := _limit_quad_vertex(parent, tp, v)
			var b := _limit_quad_vertex(child, t1, v)
			var g := _limit_quad_vertex(grand, t2, v)
			for d in 3:
				worst = maxf(worst, maxf(absf(a[d] - b[d]), absf(a[d] - g[d])))
		_expect(worst < 1e-12, "One and two Catmull-Clark steps should keep every vertex's limit point (off by %s)." % worst)
		_expect(CAGE.validate(grand).is_empty(), "Two Catmull-Clark steps should give a valid cage.")
	# Crease rule: a creased equator keeps the cubic B-spline limit (e0 + 4P + e1) / 6.
	var box := PRIM.box(Vector3(2, 2, 2), Vector3i(2, 2, 2))
	var eq := _edges_at(box, 2, 0.0)
	for i in eq.size() / 2:
		CAGE.set_crease(box, eq[2 * i], eq[2 * i + 1], CAGE.SHARP)
	var bp: PackedFloat64Array = box.positions
	var rb := CAGE.catmull_clark_step(box)
	var cb: Dictionary = rb.cage
	_expect((cb.crease_edges as PackedInt32Array).size() == 32, "Each creased edge should crease both halves (%d pairs)." % ((cb.crease_edges as PackedInt32Array).size() / 2))
	var cbp: PackedFloat64Array = cb.positions
	var tb := CAGE.topology(box)
	var tcb := CAGE.topology(cb)
	var worst := 0.0
	for i in eq.size() / 2:
		var v := eq[2 * i]
		var nb := PackedInt32Array()
		for w in tb.vertex_neighbors(v):
			if CAGE.is_crease(box, v, w):
				nb.append(w)
		var nc := PackedInt32Array()
		for w in tcb.vertex_neighbors(v):
			if CAGE.is_crease(cb, v, w):
				nc.append(w)
		_expect(nb.size() == 2 and nc.size() == 2, "Equator vertices should have two crease edges before and after.")
		if nb.size() != 2 or nc.size() != 2:
			continue
		for d in 3:
			var before := (bp[3 * nb[0] + d] + 4.0 * bp[3 * v + d] + bp[3 * nb[1] + d]) / 6.0
			var after := (cbp[3 * nc[0] + d] + 4.0 * cbp[3 * v + d] + cbp[3 * nc[1] + d]) / 6.0
			worst = maxf(worst, absf(before - after))
	_expect(worst < 1e-12, "A crease vertex should keep its limit point through a step (off by %s)." % worst)
	# A corner stays put; boundary corners too.
	var cornered := _cube()
	CAGE.set_corner(cornered, 6, CAGE.SHARP)
	var rcorner := CAGE.catmull_clark_step(cornered)
	var rp: PackedFloat64Array = rcorner.cage.positions
	_expect(rp[18] == 1.0 and rp[19] == 1.0 and rp[20] == 1.0, "A sharp corner should not move.")
	_expect((rcorner.cage.corners as PackedInt32Array) == PackedInt32Array([6]), "The corner should stay a corner.")
	var plane := PRIM.plane(Vector2(2, 2), Vector2i(1, 1))
	var rpl: Dictionary = CAGE.catmull_clark_step(plane).cage
	_counts(rpl, Vector3i(9, 12, 4), "Catmull-Clark step of a 1x1 plane")
	var pp: PackedFloat64Array = rpl.positions
	_expect(pp[0] == -1.0 and pp[1] == -1.0, "Boundary corners (valence 2) should stay put.")
	# Only the listed component.
	var two: Dictionary = CAGE.append(_cube(), PRIM.box(Vector3(1, 1, 1), Vector3i(1, 1, 1))).cage
	var part := CAGE.catmull_clark_step(two, PackedInt32Array([0, 1, 2, 3, 4, 5]))
	_expect(part.error == "", "A step on one component should work (%s)." % part.error)
	if part.error == "":
		_counts(part.cage, Vector3i(26 + 8, 48 + 12, 24 + 6), "Catmull-Clark step of one of two cubes")
	_expect(CAGE.catmull_clark_step(two, PackedInt32Array([0, 1])).error != "", "A step on part of a component should be refused.")


func _check_extrude_extend() -> void:
	var cube := _cube()
	var r := OPS.extrude_region(cube, {"faces": PackedInt32Array([1])}, {})
	if _ok(r, "Extrude one cube face"):
		_counts(r.cage, Vector3i(12, 20, 10), "Extrude one cube face")
		_expect((r.selection.faces as PackedInt32Array) == PackedInt32Array([1]), "Extrude should select the moved face.")
		_expect((r.selection.edges as PackedInt32Array).size() == 8, "Extrude should report the region's 4 new boundary edges.")
	var moved := OPS.extrude_region(cube, {"faces": PackedInt32Array([1])}, {"distance": 0.5})
	if _ok(moved, "Extrude one cube face by 0.5"):
		var p: PackedFloat64Array = moved.cage.positions
		var top := CAGE.topology(moved.cage).face_verts(1)
		for v in top:
			_expect(absf(p[3 * v + 2] - 1.5) < 1e-12, "The extruded face should sit at z = 1.5 (%s)." % p[3 * v + 2])
		_expect(CAGE.signed_volume(moved.cage) > 8.0, "The extruded cube should face outward and grow (%s)." % CAGE.signed_volume(moved.cage))
	var plane := PRIM.plane(Vector2(1, 1), Vector2i(1, 1))
	var re := OPS.extend_edges(plane, {"edges": PackedInt32Array([1, 3])}, {"distance": 0.5})
	if _ok(re, "Extend one plane edge"):
		_counts(re.cage, Vector3i(6, 7, 2), "Extend one plane edge")
		var t := CAGE.topology(re.cage)
		_expect(t.face_normal(re.cage, 1).z > 0.99, "The extension should face the same way as the plane.")
	_expect(not OPS.extend_edges(_cube(), {"edges": PackedInt32Array([0, 1])}, {}).ok, "Extending an interior edge should be refused.")
	# Alt+Ctrl keeps the rim's creases on the moved copy.
	var creased := _cube()
	for pr in [[4, 5], [5, 6], [6, 7], [4, 7]]:
		CAGE.set_crease(creased, pr[0], pr[1], CAGE.SHARP)
	var keep := CAGE.extrude_faces(creased, PackedInt32Array([1]), true)
	var plain := CAGE.extrude_faces(creased, PackedInt32Array([1]), false)
	_expect((keep.cage.crease_edges as PackedInt32Array).size() == 16 and (plain.cage.crease_edges as PackedInt32Array).size() == 8, "Keep creases should crease the moved rim too (%d / %d pairs)." % [(keep.cage.crease_edges as PackedInt32Array).size() / 2, (plain.cage.crease_edges as PackedInt32Array).size() / 2])


func _check_insert_point() -> void:
	var cube := _cube()
	# Face 1 = (4, 5, 6, 7): edges 4-5 and 6-7 are opposite.
	var r := OPS.insert_point(cube, {}, {"points": [{"edge": Vector2i(4, 5), "t": 0.5}, {"edge": Vector2i(6, 7), "t": 0.5}]})
	if _ok(r, "Insert Point across a cube face"):
		_counts(r.cage, Vector3i(10, 15, 7), "Insert Point across a cube face")
	var apart := OPS.insert_point(cube, {}, {"points": [{"edge": Vector2i(0, 3), "t": 0.5}, {"edge": Vector2i(5, 6), "t": 0.5}]})
	if _ok(apart, "Insert Point on edges sharing no face"):
		_expect(Array(apart.warnings).has("Points must share a face"), "Points sharing no face should warn.")
		_counts(apart.cage, Vector3i(10, 14, 6), "Insert Point on edges sharing no face")


func _check_fill_hole() -> void:
	var open8 := PRIM.cylinder(1.0, 1.0, 8, 2, "open")
	_counts(open8, Vector3i(24, 40, 16), "Open cylinder 8,2")
	var edge := PackedInt32Array([0, 1])
	for spec in [["star", Vector3i(24, 40, 17)], ["collapse", Vector3i(25, 48, 24)], ["reduced", Vector3i(25, 44, 20)], ["Reduced Star", Vector3i(25, 44, 20)], ["Fill Star", Vector3i(24, 40, 17)]]:
		var r := OPS.fill_hole(open8, {"edges": edge}, {"mode": spec[0]})
		if _ok(r, "Fill Hole " + spec[0]):
			_counts(r.cage, spec[1], "Fill Hole %s (n = 8)" % spec[0])
			_expect(CAGE.topology(r.cage).boundary_loops().size() == 1, "Fill Hole %s should leave one open end." % spec[0])
	var open6 := PRIM.cylinder(1.0, 1.0, 6, 1, "open")
	var r6 := OPS.fill_hole(open6, {"edges": edge}, {"mode": "reduced"})
	if _ok(r6, "Fill Hole reduced (n = 6)"):
		_counts(r6.cage, Vector3i(12, 19, 8), "Fill Hole reduced (n = 6: +0 V, +1 E, +2 F)")
	for n in [5, 7, 10]:
		var openn := PRIM.cylinder(1.0, 1.0, n, 1, "open")
		var rn := OPS.fill_hole(openn, {"edges": edge}, {"mode": "reduced"})
		if _ok(rn, "Fill Hole reduced (n = %d)" % n):
			_expect(CAGE.validate(rn.cage).is_empty(), "Fill Hole reduced (n = %d) should be valid." % n)
			var new_faces: PackedInt32Array = rn.selection.faces
			var tris := 0
			var t := CAGE.topology(rn.cage)
			for f in new_faces:
				if t.face_size(f) == 3:
					tris += 1
				_expect(t.face_size(f) <= 4, "Reduced fill (n = %d) should only make quads and triangles." % n)
			_expect(tris == (n % 2), "Reduced fill (n = %d) should make %d triangles (%d)." % [n, n % 2, tris])
	var creased := CAGE.copy(open8)
	CAGE.set_crease(creased, 0, 1, CAGE.SHARP)
	var rk := OPS.fill_hole(creased, {"edges": edge}, {"mode": "star", "keep_creases": false})
	_expect(rk.ok and (rk.cage.crease_edges as PackedInt32Array).is_empty(), "Fill Hole without Keep Creases should clear the rim's creases.")
	_expect(not OPS.fill_hole(_cube(), {"edges": PackedInt32Array([0, 1])}, {}).ok, "Filling from an interior edge should be refused.")


func _check_bridge_merge_weld() -> void:
	var open := PRIM.cylinder(1.0, 1.0, 8, 1, "open")
	_counts(open, Vector3i(16, 24, 8), "Open cylinder 8,1")
	var bottom := PackedInt32Array()
	var top := PackedInt32Array()
	for k in 8:
		bottom.append_array(PackedInt32Array([k, (k + 1) % 8]))
		top.append_array(PackedInt32Array([8 + k, 8 + (k + 1) % 8]))
	var r := OPS.bridge(open, {"edges": bottom, "edges2": top}, {"segments": 2})
	if _ok(r, "Bridge the cylinder's ends"):
		_counts(r.cage, Vector3i(24, 48, 24), "Bridge the cylinder's ends with 2 faces")
		var v := _vef(r.cage)
		_expect(v.x - v.y + v.z == 0, "The bridged cylinder should be a torus (V - E + F = 0).")
		_expect(CAGE.topology(r.cage).is_closed(), "The bridged cylinder should be closed.")
	# Bridge face regions of two separate boxes.
	var a := PRIM.box(Vector3(1, 1, 1), Vector3i(1, 1, 1))
	var b := PRIM.box(Vector3(1, 1, 1), Vector3i(1, 1, 1))
	var bp: PackedFloat64Array = b.positions
	for i in bp.size() / 3:
		bp[3 * i] += 3.0
	b.positions = bp
	var ab: Dictionary = CAGE.append(a, b).cage
	var ta := CAGE.topology(ab)
	var fa := -1
	var fb := -1
	for f in ta.nF:
		var n := ta.face_normal(ab, f)
		var cen := CAGE._centroid(ab.positions, ta.face_verts(f))
		if n.x > 0.99 and cen.x < 1.0:
			fa = f
		if n.x < -0.99 and cen.x > 2.0:
			fb = f
	var rf := OPS.bridge(ab, {"faces": PackedInt32Array([fa]), "faces2": PackedInt32Array([fb])}, {"segments": 3})
	if _ok(rf, "Bridge two boxes' facing faces"):
		_counts(rf.cage, Vector3i(24, 44, 22), "Bridge two boxes with 3 segments")
		_expect(CAGE.topology(rf.cage).component_count() == 1 and CAGE.signed_volume(rf.cage) > 0.0, "The bridged boxes should be one outward body.")
	# Multiples: 8 edges against 4.
	var cyl8 := PRIM.cylinder(1.0, 1.0, 8, 1, "open")
	var cyl4 := PRIM.cylinder(0.5, 1.0, 4, 1, "open")
	var c4p: PackedFloat64Array = cyl4.positions
	for i in c4p.size() / 3:
		c4p[3 * i + 2] += 2.0
	cyl4.positions = c4p
	var both: Dictionary = CAGE.append(cyl8, cyl4).cage
	var e8 := PackedInt32Array()
	for k in 8:
		e8.append_array(PackedInt32Array([8 + k, 8 + (k + 1) % 8]))
	var e4 := PackedInt32Array()
	for k in 4:
		e4.append_array(PackedInt32Array([16 + k, 16 + (k + 1) % 4]))
	var rm := OPS.bridge(both, {"edges": e8, "edges2": e4}, {"segments": 1})
	if _ok(rm, "Bridge 8 edges to 4"):
		_expect(_face_sizes(rm.cage, 5) == 4, "Bridging 8 edges to 4 should make 4 pentagons ((k + 3)-gons) (%d)." % _face_sizes(rm.cage, 5))
	_expect(not OPS.bridge(both, {"edges": e8, "edges2": PackedInt32Array([16, 17, 17, 18, 18, 19])}, {}).ok, "Bridging 8 edges to 3 should be refused.")
	# Merge Edge: two 1x1 planes along an edge.
	var p1 := PRIM.plane(Vector2(1, 1), Vector2i(1, 1))
	var p2 := PRIM.plane(Vector2(1, 1), Vector2i(1, 1))
	var q1: PackedFloat64Array = p1.positions
	var q2: PackedFloat64Array = p2.positions
	for i in 4:
		q1[3 * i] -= 0.5
		q2[3 * i] += 0.6
	p1.positions = q1
	p2.positions = q2
	var pair: Dictionary = CAGE.append(p1, p2).cage
	# p1's right edge is 1-3, p2's left edge is 4-6.
	var rme := OPS.merge_edge(pair, {"edges": PackedInt32Array([1, 3]), "edges2": PackedInt32Array([4, 6])}, {})
	if _ok(rme, "Merge Edge of two planes"):
		_counts(rme.cage, Vector3i(6, 7, 2), "Merge Edge of two planes")
	_expect(not OPS.merge_edge(pair, {"edges": PackedInt32Array([0, 1, 1, 3]), "edges2": PackedInt32Array([4, 6])}, {}).ok, "Merging groups of different sizes should be refused.")
	# Weld to tolerance: two planes side by side.
	var w1 := PRIM.plane(Vector2(1, 1), Vector2i(1, 1))
	var w2 := PRIM.plane(Vector2(1, 1), Vector2i(1, 1))
	var a1: PackedFloat64Array = w1.positions
	var a2: PackedFloat64Array = w2.positions
	for i in 4:
		a1[3 * i] -= 0.5
		a2[3 * i] += 0.5
	w1.positions = a1
	w2.positions = a2
	var side: Dictionary = CAGE.append(w1, w2).cage
	var rw := OPS.weld_vertices(side, {}, {"mode": "tolerance", "tolerance": 1e-6})
	if _ok(rw, "Weld to tolerance"):
		_counts(rw.cage, Vector3i(6, 7, 2), "Weld to tolerance of two planes side by side")
	var rv := OPS.weld_vertices(side, {"vertices": PackedInt32Array([1, 4])}, {"mode": "vertex"})
	if _ok(rv, "Weld vertex to vertex"):
		_counts(rv.cage, Vector3i(7, 8, 2), "Weld one coincident vertex pair")
	# A weld that would make an edge with three faces.
	var fan := CAGE.from_vectors(PackedVector3Array([Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(0, -1, 0), Vector3(0, 0, 1), Vector3(1, 0, 0), Vector3(0, 0, 0)]), [[0, 1, 2], [1, 0, 3], [6, 5, 4]])
	var bad := CAGE.weld(fan, [Vector2i(0, 6), Vector2i(1, 5)])
	_expect(bad.error == "Welding these vertices would make an edge with three faces.", "A weld making a three-face edge should be refused (%s)." % bad.error)


func _check_unweld() -> void:
	var open := PRIM.cylinder(1.0, 1.0, 8, 2, "open")
	var middle := PackedInt32Array()
	for k in 8:
		middle.append_array(PackedInt32Array([8 + k, 8 + (k + 1) % 8]))
	var r := OPS.unweld(open, {"edges": middle}, {})
	if _ok(r, "UnWeld the middle loop"):
		_counts(r.cage, Vector3i(32, 48, 16), "UnWeld the middle loop of an open cylinder")
		_expect(CAGE.topology(r.cage).component_count() == 2, "UnWelding the middle loop should leave 2 components.")
	var plane := PRIM.plane(Vector2(1, 1), Vector2i(2, 2))
	var rs := OPS.unweld(plane, {"edges": PackedInt32Array([4, 1])}, {})
	if _ok(rs, "UnWeld one inner edge of a grid"):
		_counts(rs.cage, Vector3i(10, 13, 4), "UnWeld one inner edge of a 2x2 grid (E + 1)")
		_expect(CAGE.topology(rs.cage).boundary_loops().size() == 1, "The slit should open into the outer boundary.")


func _check_bevel() -> void:
	var box := PRIM.box(Vector3(2, 2, 2), Vector3i(2, 2, 2))
	var eq := _edges_at(box, 2, 0.0)
	for spec in [[1, Vector3i(34, 64, 32)], [2, Vector3i(42, 80, 40)], [3, Vector3i(50, 96, 48)]]:
		var r := OPS.bevel_edge(box, {"edges": eq}, {"segments": spec[0]})
		if _ok(r, "Bevel the equator, %d segments" % spec[0]):
			_counts(r.cage, spec[1], "Bevel the equator with %d segments" % spec[0])
			_expect(CAGE.signed_volume(r.cage) > 0.0, "The bevelled box should face outward.")
	var creased := CAGE.copy(box)
	for i in eq.size() / 2:
		CAGE.set_crease(creased, eq[2 * i], eq[2 * i + 1], CAGE.SHARP)
	var rc := OPS.bevel_edge(creased, {"edges": eq}, {"segments": 2})
	_expect(rc.ok and (rc.cage.crease_edges as PackedInt32Array).is_empty(), "Bevel should drop the picked edges' crease.")
	var cube := _cube()
	_expect(not OPS.bevel_edge(cube, {"edges": PackedInt32Array([0, 1, 1, 2])}, {}).ok, "Bevel through a three-edge corner should be refused.")


func _check_thicken() -> void:
	var p1 := PRIM.plane(Vector2(1, 1), Vector2i(1, 1))
	var r := OPS.thicken(p1, {}, {"thickness": 0.1, "type": "sharp"})
	if _ok(r, "Thicken a 1x1 plane"):
		_counts(r.cage, Vector3i(8, 12, 6), "Thicken a 1x1 plane (sharp)")
		_expect((r.cage.crease_weights as PackedFloat32Array).size() == 8, "A sharp thicken should crease 8 rim edges (%d)." % (r.cage.crease_weights as PackedFloat32Array).size())
		_expect(absf(CAGE.signed_volume(r.cage) - 0.1) < 1e-12, "The thickened 1x1 plane should face outward and hold 0.1 (%s)." % CAGE.signed_volume(r.cage))
	var flipped := OPS.thicken(p1, {}, {"thickness": 0.1, "flip": true})
	if _ok(flipped, "Thicken a 1x1 plane flipped"):
		_expect(absf(CAGE.signed_volume(flipped.cage) - 0.1) < 1e-12, "A flipped thicken should face outward too (%s)." % CAGE.signed_volume(flipped.cage))
		var fp: PackedFloat64Array = flipped.cage.positions
		_expect(absf(fp[3 * 4 + 2] - 0.1) < 1e-12, "A flipped thicken should put the copy in front (%s)." % fp[3 * 4 + 2])
	var p2 := PRIM.plane(Vector2(1, 1), Vector2i(2, 2))
	var r2 := OPS.thicken(p2, {}, {"thickness": 0.1})
	if _ok(r2, "Thicken a 2x2 plane"):
		_counts(r2.cage, Vector3i(18, 32, 16), "Thicken a 2x2 plane")
	var soft := OPS.thicken(p2, {}, {"thickness": 0.1, "type": "soft"})
	_expect(soft.ok and (soft.cage.crease_edges as PackedInt32Array).is_empty(), "A soft thicken should crease nothing.")
	var none := OPS.thicken(p2, {}, {"thickness": 0.1, "type": "none"})
	if _ok(none, "Thicken without an edge"):
		_counts(none.cage, Vector3i(18, 24, 8), "Thicken a 2x2 plane with no edge")
		_expect(CAGE.topology(none.cage).component_count() == 2, "No Edge should leave the copy as a second component.")
	var closed := OPS.thicken(_cube(), {}, {"thickness": 0.1})
	if _ok(closed, "Thicken a cube"):
		_counts(closed.cage, Vector3i(16, 24, 12), "Thicken a closed cube")
		var p: PackedFloat64Array = closed.cage.positions
		_expect(absf(p[3 * 8] + 1.0 - 0.1 / sqrt(3.0)) < 1e-12, "A closed cage's copy should move inward.")


func _check_duplicates() -> void:
	var piece := PRIM.plane(Vector2(1, 1), Vector2i(1, 1))
	var pp: PackedFloat64Array = piece.positions
	for i in 4:
		pp[3 * i] += 0.5
	piece.positions = pp
	var r := OPS.mirror_duplicate(piece, {}, {"origin": Vector3.ZERO, "normal": Vector3(1, 0, 0)})
	if _ok(r, "Mirror - Duplicate with weld"):
		_counts(r.cage, Vector3i(6, 7, 2), "Mirror - Duplicate of a plane touching the mirror")
		var m: PackedInt32Array = (r.cage.symmetry as Array)[0].map
		var p: PackedFloat64Array = r.cage.positions
		var seam := 0
		for v in m.size():
			if p[3 * v] == 0.0:
				_expect(m[v] == v, "Seam vertex %d should map to itself." % v)
				seam += 1
			else:
				_expect(m[v] >= 0 and p[3 * m[v]] == -p[3 * v], "Vertex %d should map to its exact mirror image." % v)
		_expect(seam == 2, "The mirror seam should have 2 vertices (%d)." % seam)
		_expect(CAGE.topology(r.cage).face_normal(r.cage, 1).z > 0.99, "The mirrored copy should face the same way.")
	var far := PRIM.plane(Vector2(1, 1), Vector2i(1, 1))
	var fp: PackedFloat64Array = far.positions
	for i in 4:
		fp[3 * i] += 3.0
	far.positions = fp
	var rc := OPS.circular_duplicate(far, {}, {"origin": Vector3.ZERO, "axis": Vector3(0, 0, 1), "count": 4, "weld": false})
	if _ok(rc, "Circular - Duplicate"):
		_counts(rc.cage, Vector3i(16, 16, 4), "Circular - Duplicate of a separate plane piece, 4 copies")
		_expect(CAGE.topology(rc.cage).component_count() == 4, "Four copies should be 4 components.")
		var entry: Dictionary = (rc.cage.symmetry as Array)[0]
		var m: PackedInt32Array = entry.map
		_expect(int(entry.count) == 4 and not bool(entry.open) and m[0] == 4 and m[12] == 0, "The circular map should take each vertex to the next copy (%s)." % m)
	var arc := OPS.circular_duplicate(far, {}, {"origin": Vector3.ZERO, "axis": Vector3(0, 0, 1), "count": 3, "spacing": "angle", "angle": PI, "weld": false})
	if _ok(arc, "Circular - Duplicate on an arc"):
		var entry: Dictionary = (arc.cage.symmetry as Array)[0]
		_expect(bool(entry.open) and (entry.map as PackedInt32Array)[8] == -1, "A partial arc should be an open orbit.")
		var p: PackedFloat64Array = arc.cage.positions
		_expect(absf(p[3 * 8] + 2.5) < 1e-12, "The last arc copy should sit at 180 degrees.")


func _check_delete() -> void:
	var r := OPS.delete_elements(_cube(), {"faces": PackedInt32Array([1])}, {})
	if _ok(r, "Delete one cube face"):
		_counts(r.cage, Vector3i(8, 12, 5), "Delete one cube face")
		_expect(not CAGE.topology(r.cage).is_closed(), "The cube should be open after deleting a face.")
	var plane := PRIM.plane(Vector2(1, 1), Vector2i(2, 2))
	var rd := OPS.delete_elements(plane, {"edges": PackedInt32Array([1, 4])}, {})
	if _ok(rd, "Dissolve an inner plane edge"):
		_counts(rd.cage, Vector3i(9, 11, 3), "Dissolve an inner edge of a 2x2 plane")
	var rb := OPS.delete_elements(plane, {"edges": PackedInt32Array([0, 1])}, {})
	if _ok(rb, "Delete a boundary edge"):
		_counts(rb.cage, Vector3i(8, 10, 3), "A boundary edge deletes its face")
	var rv := OPS.delete_elements(plane, {"vertices": PackedInt32Array([4])}, {})
	if _ok(rv, "Dissolve the plane's centre"):
		_counts(rv.cage, Vector3i(8, 8, 1), "Dissolve the 2x2 plane's centre vertex")
	var box := PRIM.box(Vector3(2, 2, 2), Vector3i(2, 2, 2))
	var eq := _edges_at(box, 2, 0.0)
	var rl := OPS.delete_elements(box, {"edges": eq}, {})
	if _ok(rl, "Dissolve the equator loop"):
		_counts(rl.cage, Vector3i(18, 32, 16), "Dissolve the equator loop of box 2,2,2")
	var re := OPS.erase_and_fill(box, {"faces": PackedInt32Array([0])}, {})
	if _ok(re, "Erase and Fill one face"):
		_counts(re.cage, Vector3i(26, 48, 24), "Erase and Fill one face of box 2,2,2")
	var open8 := PRIM.cylinder(1.0, 1.0, 8, 2, "open")
	var ro := OPS.erase_and_fill(open8, {"faces": PackedInt32Array([0])}, {"mode": "star"})
	if _ok(ro, "Erase and Fill next to an open end"):
		_expect(CAGE.topology(ro.cage).boundary_loops().size() == 2, "Erase and Fill should leave holes that were already open (%d loops)." % CAGE.topology(ro.cage).boundary_loops().size())


func _check_compact() -> void:
	# The cube with unused vertices at ids 0 and 5 (the cube's vertices are 1-4 and 6-9).
	var cube := _cube()
	var p: PackedFloat64Array = cube.positions
	var np := PackedFloat64Array([9.0, 9.0, 9.0])
	np.append_array(p.slice(0, 12))
	np.append_array(PackedFloat64Array([8.0, 8.0, 8.0]))
	np.append_array(p.slice(12))
	var old_of := PackedInt32Array([1, 2, 3, 4, 6, 7, 8, 9])
	var idx: PackedInt32Array = cube.face_indices
	var ni := PackedInt32Array()
	for v in idx:
		ni.append(old_of[v])
	var c := CAGE.make(np, cube.face_counts, ni)
	CAGE.set_crease(c, 1, 4, CAGE.SHARP)
	CAGE.set_crease(c, 8, 9, 5.0)
	CAGE.set_corner(c, 9, CAGE.SHARP)
	c.frozen = PackedInt32Array([0, 6, 7])
	c.sym_isolated = PackedInt32Array([5, 8])
	var m := PackedInt32Array()
	for v in 10:
		m.append(v)
	m[1] = 2
	m[2] = 1
	m[0] = 5
	c.symmetry = [{"type": "mirror", "origin": PackedFloat64Array([0, 0, 0]), "normal": PackedFloat64Array([1, 0, 0]), "map": m}]
	c.links = [{"edges": PackedInt32Array([1, 2, 0, 3, 6, 7]), "target": {}, "continuity": "g0", "spacing": "uniform"}]
	var r := CAGE.compact(c)
	var out: Dictionary = r.cage
	_expect(r.vertex_map == PackedInt32Array([-1, 0, 1, 2, 3, -1, 4, 5, 6, 7]), "compact's vertex map should drop ids 0 and 5 (%s)." % r.vertex_map)
	_expect(CAGE.validate(out).is_empty(), "The compacted cage should be valid (%s)." % ", ".join(CAGE.validate(out)))
	_expect((out.positions as PackedFloat64Array).slice(0, 3) == p.slice(0, 3), "Positions should shift down with their vertices.")
	_expect(out.crease_edges == PackedInt32Array([0, 3, 6, 7]) and out.crease_weights == PackedFloat32Array([10.0, 5.0]), "Creases should be remapped (%s %s)." % [out.crease_edges, out.crease_weights])
	_expect(out.corners == PackedInt32Array([7]), "Corners should be remapped.")
	_expect(out.frozen == PackedInt32Array([4, 5]) and out.sym_isolated == PackedInt32Array([6]), "frozen and sym_isolated should be remapped (%s %s)." % [out.frozen, out.sym_isolated])
	var om: PackedInt32Array = (out.symmetry as Array)[0].map
	_expect(om.size() == 8 and om[0] == 1 and om[1] == 0 and om[2] == 2, "The symmetry map should be remapped (%s)." % om)
	var le: PackedInt32Array = (out.links as Array)[0].edges
	_expect(le == PackedInt32Array([0, 1, 4, 5]), "Link edges should be remapped, pairs with a removed vertex dropped (%s)." % le)


func _check_misc_ops() -> void:
	var cube := _cube()
	var se := CAGE.split_edge(cube, 0, 1, 0.25)
	_counts(se.cage, Vector3i(9, 13, 6), "split_edge")
	var p: PackedFloat64Array = se.cage.positions
	_expect(p[24] == -0.5 and p[25] == -1.0, "split_edge should place the vertex at t in doubles.")
	var sf := CAGE.split_face(cube, 1, 4, 6)
	_counts(sf.cage, Vector3i(8, 13, 7), "split_face")
	_expect(CAGE.split_face(cube, 1, 4, 5).error != "", "split_face of adjacent corners should be refused.")
	var fl := CAGE.flip_faces(cube, PackedInt32Array([0, 1, 2, 3, 4, 5]))
	_expect(CAGE.signed_volume(fl.cage) < 0.0 and CAGE.validate(fl.cage).is_empty(), "Flipping every face should turn the cube inside out.")
	var mixed := CAGE.flip_faces(cube, PackedInt32Array([1, 3]))
	var fixed := CAGE.orient_consistently(mixed.cage)
	_expect(fixed.error == "" and CAGE.validate(fixed.cage).is_empty() and CAGE.signed_volume(fixed.cage) > 0.0, "orient_consistently should turn flipped faces back outward.")
	_expect((fixed.flipped as PackedInt32Array) == PackedInt32Array([1, 3]), "orient_consistently should report the faces it flipped (%s)." % fixed.flipped)
	var inside := CAGE.orient_consistently(fl.cage)
	_expect(CAGE.signed_volume(inside.cage) > 0.0, "orient_consistently should make a closed cage's volume positive.")
	var tris := CAGE.split_to_quads(PRIM.sphere(1.0, 8, 4), PackedInt32Array(range(32)))
	_expect(tris.error == "" and _face_sizes(tris.cage, 4) == CAGE.face_count(tris.cage) and CAGE.validate(tris.cage).is_empty(), "split_to_quads of a whole sphere should leave only quads.")
	# Triangle pairs back into quads.
	var plane := PRIM.plane(Vector2(1, 1), Vector2i(2, 2))
	var tri_faces := []
	var pidx: PackedInt32Array = plane.face_indices
	for f in 4:
		tri_faces.append([pidx[4 * f], pidx[4 * f + 1], pidx[4 * f + 2]])
		tri_faces.append([pidx[4 * f], pidx[4 * f + 2], pidx[4 * f + 3]])
	var tri := CAGE.from_vectors(CAGE.positions_v3(plane), tri_faces)
	var merged := CAGE.merge_triangle_pairs(tri)
	_expect(int(merged.merged) == 4 and _face_sizes(merged.cage, 4) == 4, "Merging a triangulated 2x2 plane should give 4 quads (%d)." % int(merged.merged))
	_expect(CAGE.validate(merged.cage).is_empty(), "The merged plane should be valid.")
	var dv := CAGE.dissolve_vertices(PRIM.box(Vector3(2, 2, 2), Vector3i(2, 2, 2)), PackedInt32Array([4]))
	_expect(dv.error == "" and CAGE.validate(dv.cage).is_empty(), "Dissolving a face-centre vertex of box 2,2,2 should work (%s)." % dv.error)
	var hashes := CAGE.content_hash(cube)
	CAGE.set_crease(cube, 0, 1, CAGE.SHARP)
	_expect(CAGE.content_hash(cube) != hashes and CAGE.is_crease(cube, 1, 0), "A crease should change the content hash.")
	var th := CAGE.topology_hash(cube)
	CAGE.set_position_d(cube, 0, -1.5, -1.0, -1.0)
	_expect(CAGE.topology_hash(cube) == th, "Moving a vertex should keep the topology hash.")
	cube.frozen = PackedInt32Array([6])
	var locked := CAGE.locked_vertices(cube)
	var count := 0
	for v in 8:
		count += locked[v]
	_expect(count == 7 and locked[0] == 0, "Freezing a cube corner should lock the 7 vertices of its faces (%d)." % count)


func _calibration() -> void:
	var x := 0.0
	for i in 200000:
		x += sqrt(float(i)) * 0.5
	_sink = x


func _check_timing() -> void:
	var big := PRIM.box(Vector3(2, 2, 2), Vector3i(29, 29, 29))
	_expect(CAGE.face_count(big) == 5046, "The timing cage should have 5046 faces.")
	# Measured 2026-10-29 on the dev machine against the 200k-iteration loop (7.2-7.5 ms):
	# topology() 8.9 ms (ratio 1.22), validate() 13.3 ms (ratio 1.85). Limits are twice the
	# measured ratios; topology() is also held to the 60 ms budget.
	var topo := TIMING.compare(func() -> void: CAGE.topology(big), _calibration, 5, "topology of 5046 faces / 200k-iteration loop")
	_timings.append("topology %.1f ms, ratio %.2f" % [topo.op, topo.ratio])
	_expect(topo.ratio < 2.5, "topology() of a 5046-face cage should take under 2.5 calibration loops (%.1f ms against %.1f ms, ratio %.2f)." % [topo.op, topo.calibration, topo.ratio])
	_expect(topo.op < 60.0 or OS.get_environment("HOLO_FORGE_TIMING_SLOWDOWN") != "", "topology() of 5046 faces should take under 60 ms (%.1f ms)." % topo.op)
	var val := TIMING.compare(func() -> void: CAGE.validate(big), _calibration, 5, "validate 5046 faces / 200k-iteration loop")
	_timings.append("validate %.1f ms, ratio %.2f" % [val.op, val.ratio])
	_expect(val.ratio < 3.7, "validate() of a 5046-face cage should take under 3.7 calibration loops (%.1f ms against %.1f ms, ratio %.2f)." % [val.op, val.calibration, val.ratio])
