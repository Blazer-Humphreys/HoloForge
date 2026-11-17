extends SceneTree
## Holo Forge Form tools (pure functions, no kernel): symmetry mirrors moves exactly (partner =
## reflection to 1e-12, every other vertex bit-for-bit unchanged) and carries Insert Edge and
## Extrude to the other side with complete maps; circular symmetry rotates partners exactly and
## isolated vertices neither drive nor follow; mirror and circular detection; the frozen locked
## set (frozen vertices plus their 1-ring) blocks moves and topology edits; Flatten, Straighten,
## Smooth, Cylindrify, Slide Edge, Crease / UnCrease and soft-modification weights give their
## exact numbers; no tool changes its input; the 5046-face timings stay within budget.
##
## godot --headless --path . --script res://tests/holo_forge_form_ops_test.gd

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
	_check_transforms()
	_check_mirror()
	_check_symmetric_topology()
	_check_circular()
	_check_detection()
	_check_locked()
	_check_geometry()
	_check_soft_weights()
	_check_purity()
	_check_timing()
	print(("PASS holo_forge_form_ops: mirror edits exact to 1e-12 with untouched vertices bit-identical, insert edge and extrude carried to the partner side with complete maps, 13 more topology tools (insert point, subdivide simple and exact, delete, fill hole, erase and fill, extend, thicken, bevel, weld, dissolve vertex and edge, bridge) keep mirror partners exact with complete maps, circular partners exact to 1e-12, isolated vertices, mirror/circular detection, frozen locked set and frozen refusals, flatten/straighten to 1e-12, smooth lowers energy and keeps the region border bit-exact, cylindrify radii and angles to 1e-12, slide 0.5, crease round trip, soft weights (smooth/linear/bulge), every tool leaves its input unchanged, timings (%s)." % ", ".join(_timings)) \
		if failures.is_empty() else "FAIL holo_forge_form_ops")
	quit(0 if failures.is_empty() else 1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error(message)
		print("FAIL: ", message)


func _ok(r: Dictionary, label: String) -> bool:
	_expect(bool(r.ok) and str(r.error) == "", "%s should succeed (%s)." % [label, r.error])
	return bool(r.ok)


func _vef(c: Dictionary) -> Vector3i:
	var t := CAGE.topology(c)
	return Vector3i(t.nV, t.nE, t.nF)


func _pd(c: Dictionary, v: int) -> PackedFloat64Array:
	return CAGE.position_d(c, v)


func _box_mirror() -> Dictionary:
	return PRIM.primitive_symmetry(PRIM.box(Vector3(2, 2, 2), Vector3i(2, 2, 2)), "mirror", Transform3D.IDENTITY, Vector3i(1, 0, 0), 0)


## The vertex at p (exact), or -1.
func _vertex_at(c: Dictionary, x: float, y: float, z: float) -> int:
	var p: PackedFloat64Array = c.positions
	for v in p.size() / 3:
		if p[3 * v] == x and p[3 * v + 1] == y and p[3 * v + 2] == z:
			return v
	return -1


## The largest |reflect(p_v) - p_map(v)| over every mapped vertex.
func _mirror_error(c: Dictionary, entry: int) -> float:
	var e: Dictionary = (c.symmetry as Array)[entry]
	var m: PackedInt32Array = e.map
	var worst := 0.0
	for v in m.size():
		if m[v] < 0:
			continue
		var q := OPS.reflect_d(_pd(c, v), e.origin, e.normal)
		var w := _pd(c, m[v])
		for d in 3:
			worst = maxf(worst, absf(q[d] - w[d]))
	return worst


func _check_transforms() -> void:
	var a := OPS.xf_from(Basis(Vector3(0.3, 1, 0.2).normalized(), 0.7), Vector3(0.1, -2, 3))
	var id := OPS.xf_compose(a, OPS.xf_inverse_rigid(a))
	var worst := 0.0
	var ident := OPS.xf_identity()
	for i in 12:
		worst = maxf(worst, absf(id[i] - ident[i]))
	_expect(worst < 1e-6, "A rigid transform after its inverse should be the identity (off by %s)." % worst)
	var o := PackedFloat64Array([0.1, 0.2, 0.3])
	var ax := OPS.unit_d(PackedFloat64Array([1.0, 2.0, 2.0]))
	var p := PackedFloat64Array([1.5, -0.25, 0.75])
	var r1 := OPS.rotate_d(p, o, ax, 0.9)
	var r2 := OPS.xf_apply(OPS.rotation_xf(o, ax, 0.9), p[0], p[1], p[2])
	var back := OPS.rotate_d(r1, o, ax, -0.9)
	var n := OPS.unit_d(PackedFloat64Array([0.3, -0.4, 1.2]))
	var m1 := OPS.reflect_d(p, o, n)
	var m2 := OPS.xf_apply(OPS.mirror_xf(o, n), p[0], p[1], p[2])
	var twice := OPS.reflect_d(m1, o, n)
	for d in 3:
		_expect(absf(r1[d] - r2[d]) < 1e-15 and absf(back[d] - p[d]) < 1e-15, "rotate_d and rotation_xf should agree and undo (axis %d)." % d)
		_expect(absf(m1[d] - m2[d]) < 1e-15 and absf(twice[d] - p[d]) < 1e-15, "reflect_d and mirror_xf should agree and undo (axis %d)." % d)
	var pts := PackedFloat64Array()
	for i in 10:
		pts.append_array(PackedFloat64Array([i, 2.0 * i, -i]))
	var line := OPS.best_fit_line(pts)
	var dir: PackedFloat64Array = line.direction
	_expect(absf(absf(dir[0] * 1 + dir[1] * 2 - dir[2]) / sqrt(6.0) - 1.0) < 1e-12, "best_fit_line should find the points' direction.")
	var eig := OPS.eigen_sym3([[2.0, 1.0, 0.0], [1.0, 2.0, 0.0], [0.0, 0.0, 5.0]])
	_expect(absf(eig.values[0] - 1.0) < 1e-12 and absf(eig.values[1] - 3.0) < 1e-12 and absf(eig.values[2] - 5.0) < 1e-12, "eigen_sym3 should give 1, 3, 5 (%s)." % [eig.values])


func _check_mirror() -> void:
	var box := _box_mirror()
	var m: PackedInt32Array = (box.symmetry as Array)[0].map
	_expect(not m.has(-1), "Box 2,2,2 with an X mirror should map every vertex.")
	var v := _vertex_at(box, 1.0, 1.0, 1.0)
	var u := m[v]
	_expect(u == _vertex_at(box, -1.0, 1.0, 1.0), "The +X corner's partner should be the -X corner.")
	var on_plane := _vertex_at(box, 0.0, 1.0, 1.0)
	_expect(m[on_plane] == on_plane, "A vertex on the mirror plane should map to itself.")
	var before: PackedFloat64Array = box.positions
	var r := OPS.edit_transform(box, {"vertices": PackedInt32Array([v])}, {"translate": PackedFloat64Array([0.013, 0.021, -0.007])})
	if _ok(r, "Edit Form move under a mirror"):
		var after: PackedFloat64Array = r.cage.positions
		var pv := _pd(r.cage, v)
		_expect(pv[0] == 1.0 + 0.013 and pv[1] == 1.0 + 0.021 and pv[2] == 1.0 - 0.007, "The moved vertex should move by exactly the translation (%s)." % pv)
		var q := OPS.reflect_d(pv, (box.symmetry as Array)[0].origin, (box.symmetry as Array)[0].normal)
		var pu := _pd(r.cage, u)
		for d in 3:
			_expect(absf(q[d] - pu[d]) <= 1e-12, "The partner should be the exact mirror image (axis %d: %s vs %s)." % [d, q[d], pu[d]])
		var changed := 0
		for w in before.size() / 3:
			if w == v or w == u:
				continue
			for d in 3:
				if after[3 * w + d] != before[3 * w + d]:
					changed += 1
		_expect(changed == 0, "Every other vertex should be unchanged bit for bit (%d coordinates changed)." % changed)
		_expect((r.info.moved as PackedInt32Array).size() == 2, "Two vertices should have moved (%s)." % r.info.moved)
	# Insert Edge on a +X edge: the partner side gets the mirrored insert.
	var a := _vertex_at(box, 1.0, 0.0, 0.0)
	var b := _vertex_at(box, 1.0, 0.0, 1.0)
	var ri := OPS.insert_edge(box, {"edges": PackedInt32Array([a, b])}, {"location": 0.5})
	if _ok(ri, "Insert Edge under a mirror"):
		_expect(_vef(ri.cage) == Vector3i(30, 54, 26), "A mirrored insert should add two inserts' worth (30/54/26, got %s)." % _vef(ri.cage))
		var mm: PackedInt32Array = (ri.cage.symmetry as Array)[0].map
		_expect(mm.size() == 30 and not mm.has(-1), "rebuild_symmetry should leave no -1 after the insert (%s)." % mm)
		_expect(_mirror_error(ri.cage, 0) <= 1e-12, "Inserted partners should be exact mirror images (%s)." % _mirror_error(ri.cage, 0))
		var nv: PackedInt32Array = ri.info.new_vertices
		var px := 0
		var nx := 0
		for w in nv:
			if _pd(ri.cage, w)[0] > 0.0:
				px += 1
			else:
				nx += 1
		_expect(px == 2 and nx == 2, "The insert should land on both sides (%d / %d)." % [px, nx])
		_expect(CAGE.validate(ri.cage).is_empty(), "The mirrored insert should be valid.")
	# Extrude a +X face: the partner face is extruded too and the map is complete.
	var t := CAGE.topology(box)
	var fx := -1
	for f in t.nF:
		var cen := CAGE._centroid(box.positions, t.face_verts(f))
		if cen.x == 1.0 and cen.y > 0.0 and cen.z > 0.0:
			fx = f
	for dist in [0.25, 0.0]:
		var re := OPS.extrude_region(box, {"faces": PackedInt32Array([fx])}, {"distance": dist})
		if not _ok(re, "Extrude under a mirror (distance %s)" % dist):
			continue
		_expect(_vef(re.cage) == Vector3i(34, 64, 32), "A mirrored extrude should extrude both faces (34/64/32, got %s)." % _vef(re.cage))
		var me: PackedInt32Array = (re.cage.symmetry as Array)[0].map
		_expect(me.size() == 34 and not me.has(-1), "The map should be complete after the extrude (distance %s)." % dist)
		_expect(_mirror_error(re.cage, 0) <= 1e-12, "Extruded partners should be exact mirror images (%s)." % _mirror_error(re.cage, 0))
		var nv: PackedInt32Array = re.info.new_vertices
		var fresh := {}
		for w in nv:
			fresh[w] = true
		for w in nv:
			_expect(fresh.has(me[w]), "A new vertex should map to the partner's new vertex, not the old rim (distance %s)." % dist)
		_expect((re.selection.faces as PackedInt32Array).size() == 2, "The extrude should select both moved faces.")
		if dist > 0.0:
			for f in re.selection.faces:
				var cen := CAGE._centroid(re.cage.positions, CAGE.topology(re.cage).face_verts(f))
				_expect(absf(absf(cen.x) - 1.25) < 1e-12, "The extruded faces should move out to |x| = 1.25 (%s)." % cen.x)
	# partner_selection and orbit.
	var ps := OPS.partner_selection(box, {"vertices": PackedInt32Array([v]), "edges": PackedInt32Array([a, b]), "faces": PackedInt32Array([fx])})
	_expect((ps.vertices as PackedInt32Array).size() == 2 and (ps.edges as PackedInt32Array).size() == 4 and (ps.faces as PackedInt32Array).size() == 2, "partner_selection should add each element's partner (%s)." % ps)
	var orb := OPS.orbit(box, v)
	_expect(orb.size() == 2 and orb.has(u), "The +X corner's orbit should be itself and its partner.")
	# A tilted mirror plane: partners exact to 1e-12 of the size.
	var tilted := PRIM.box(Vector3(2, 2, 2), Vector3i(2, 2, 2))
	var frame := Transform3D(Basis(Vector3(0.2, 0.9, 0.4).normalized(), 0.6), Vector3(0.3, -0.2, 0.1))
	var tp: PackedFloat64Array = tilted.positions
	for w in tp.size() / 3:
		var q := frame * Vector3(tp[3 * w], tp[3 * w + 1], tp[3 * w + 2])
		tp[3 * w] = q.x
		tp[3 * w + 1] = q.y
		tp[3 * w + 2] = q.z
	tilted.positions = tp
	tilted = PRIM.primitive_symmetry(tilted, "mirror", frame, Vector3i(1, 1, 0), 0)
	var tm0: PackedInt32Array = (tilted.symmetry as Array)[0].map
	var tm1: PackedInt32Array = (tilted.symmetry as Array)[1].map
	_expect(not tm0.has(-1) and not tm1.has(-1), "A tilted box should map fully on both mirrors.")
	var tv := 0
	for w in tm0.size():
		if tm0[w] != w and tm1[w] != w:
			tv = w
			break
	var rt := OPS.edit_transform(tilted, {"vertices": PackedInt32Array([tv])}, {"translate": PackedFloat64Array([0.011, -0.017, 0.023])})
	if _ok(rt, "Edit Form move under two tilted mirrors"):
		_expect(_mirror_error(rt.cage, 0) <= 2e-12 and _mirror_error(rt.cage, 1) <= 2e-12, "Tilted mirror partners should be exact to 1e-12 of the size (%s, %s)." % [_mirror_error(rt.cage, 0), _mirror_error(rt.cage, 1)])
		_expect((rt.info.moved as PackedInt32Array).size() == 4, "Two mirrors should move a vertex and its 3 partners (%s)." % rt.info.moved)


## Every topology tool keeps an X-mirrored cage exactly symmetric with a complete map.
func _check_symmetric_topology() -> void:
	var box := _box_mirror()
	var t := CAGE.topology(box)
	var fx := -1
	for f in t.nF:
		var cen := CAGE._centroid(box.positions, t.face_verts(f))
		if cen.x == 1.0 and cen.y > 0.0 and cen.z > 0.0:
			fx = f
	var a := _vertex_at(box, 1.0, 0.0, 0.0)
	var b := _vertex_at(box, 1.0, 0.0, 1.0)
	var opened: Dictionary = OPS.delete_elements(box, {"faces": PackedInt32Array([fx])}, {}).cage
	var loop: PackedInt32Array = CAGE.topology(opened).boundary_loops()[0]
	var big := PRIM.primitive_symmetry(PRIM.box(Vector3(4, 4, 4), Vector3i(4, 4, 4)), "mirror", Transform3D.IDENTITY, Vector3i(1, 0, 0), 0)
	var tb := CAGE.topology(big)
	var b1 := -1
	var b2 := -1
	for f in tb.nF:
		var cen := CAGE._centroid(big.positions, tb.face_verts(f))
		if cen.x == 2.0 and cen.y == -1.5 and cen.z == -1.5:
			b1 = f
		if cen.x == 2.0 and cen.y == 1.5 and cen.z == 1.5:
			b2 = f
	var cases := [
		["Insert Point", OPS.insert_point(box, {}, {"points": [{"edge": Vector2i(a, b), "t": 0.5}, {"edge": Vector2i(_vertex_at(box, 1.0, 1.0, 0.0), _vertex_at(box, 1.0, 1.0, 1.0)), "t": 0.5}]}), 30],
		["Subdivide", OPS.subdivide(box, {"faces": PackedInt32Array([fx])}, {}), 36],
		["Delete a face", OPS.delete_elements(box, {"faces": PackedInt32Array([fx])}, {}), 26],
		["Fill Hole", OPS.fill_hole(opened, {"edges": PackedInt32Array([loop[0], loop[1]])}, {}), 26],
		["Erase and Fill", OPS.erase_and_fill(box, {"faces": PackedInt32Array([fx])}, {}), 26],
		["Extend Edges", OPS.extend_edges(opened, {"edges": PackedInt32Array([loop[0], loop[1]])}, {"distance": 0.2}), 30],
		["Thicken", OPS.thicken(opened, {}, {"thickness": 0.1}), 52],
		["Bevel Edge", OPS.bevel_edge(box, {"edges": PackedInt32Array([a, b])}, {"segments": 2}), 34],
		["Weld (midpoint)", OPS.weld_vertices(box, {"vertices": PackedInt32Array([b, a])}, {"mode": "midpoint"}), 24],
		["Dissolve a vertex", OPS.delete_elements(box, {"vertices": PackedInt32Array([a])}, {}), 24],
		["Dissolve an edge", OPS.delete_elements(box, {"edges": PackedInt32Array([a, b])}, {}), 26],
		["Subdivide (exact, whole body)", OPS.subdivide(box, {"faces": PackedInt32Array(range(24))}, {"mode": "exact"}), 98],
		["Bridge", OPS.bridge(big, {"faces": PackedInt32Array([b1]), "faces2": PackedInt32Array([b2])}, {"segments": 4}), 122],
	]
	for case in cases:
		var r: Dictionary = case[1]
		if not _ok(r, case[0] + " under a mirror"):
			continue
		var c2: Dictionary = r.cage
		var m: PackedInt32Array = (c2.symmetry as Array)[0].map
		_expect(CAGE.vertex_count(c2) == int(case[2]), "%s under a mirror should give %d vertices (%d)." % [case[0], case[2], CAGE.vertex_count(c2)])
		_expect(m.size() == CAGE.vertex_count(c2) and not m.has(-1), "%s should leave a complete mirror map." % case[0])
		_expect(_mirror_error(c2, 0) <= 1e-12, "%s should keep partners exact (off by %s)." % [case[0], _mirror_error(c2, 0)])
		_expect(CAGE.validate(c2).is_empty() and r.warnings.is_empty(), "%s should be valid with no warnings (%s)." % [case[0], r.warnings])
	var touching := OPS.bridge(box, {"faces": PackedInt32Array([fx]), "faces2": PackedInt32Array([_face_at(box, 1.0, 0.5, -0.5)])}, {})
	_expect(not touching.ok and touching.error == "The two sides touch; pick sides apart from each other.", "Bridging two touching sides should be refused (%s)." % touching.error)


func _face_at(c: Dictionary, x: float, y: float, z: float) -> int:
	var t := CAGE.topology(c)
	for f in t.nF:
		var cen := CAGE._centroid(c.positions, t.face_verts(f))
		if cen.x == x and cen.y == y and cen.z == z:
			return f
	return -1


func _check_circular() -> void:
	var cyl := PRIM.primitive_symmetry(PRIM.cylinder(1.0, 1.0, 8, 2), "circular", Transform3D.IDENTITY, Vector3i.ZERO, 8)
	var entry: Dictionary = (cyl.symmetry as Array)[0]
	var m: PackedInt32Array = entry.map
	_expect(m[8] == 9 and m[15] == 8, "The circular map should step each ring vertex to the next.")
	var before: PackedFloat64Array = cyl.positions
	var r := OPS.edit_transform(cyl, {"vertices": PackedInt32Array([8])}, {"translate": PackedFloat64Array([0.031, -0.012, 0.05])})
	if _ok(r, "Edit Form move under circular symmetry"):
		var p0 := _pd(r.cage, 8)
		var worst := 0.0
		for k in range(1, 8):
			var q := OPS.rotate_d(p0, entry.origin, entry.axis, k * float(entry.step))
			var w := _pd(r.cage, 8 + k)
			for d in 3:
				worst = maxf(worst, absf(q[d] - w[d]))
		_expect(worst <= 1e-12, "The other 7 ring vertices should rotate exactly with it (off by %s)." % worst)
		var after: PackedFloat64Array = r.cage.positions
		var changed := 0
		for w in 26:
			if w >= 8 and w < 16:
				continue
			for d in 3:
				if after[3 * w + d] != before[3 * w + d]:
					changed += 1
		_expect(changed == 0, "Vertices off the moved ring should not change (%d coordinates)." % changed)
	var iso := OPS.isolate_symmetry(cyl, {"vertices": PackedInt32Array([9])}, {})
	if _ok(iso, "Isolate Symmetry"):
		var c2: Dictionary = iso.cage
		var b2: PackedFloat64Array = c2.positions
		var ri := OPS.edit_transform(c2, {"vertices": PackedInt32Array([9])}, {"translate": PackedFloat64Array([0.0, 0.0, 0.1])})
		if _ok(ri, "Move an isolated vertex"):
			var a2: PackedFloat64Array = ri.cage.positions
			var changed := 0
			for w in 26:
				if w == 9:
					continue
				for d in 3:
					if a2[3 * w + d] != b2[3 * w + d]:
						changed += 1
			_expect(changed == 0, "Moving an isolated vertex should change no other vertex (%d coordinates)." % changed)
		var rp := OPS.edit_transform(c2, {"vertices": PackedInt32Array([8])}, {"translate": PackedFloat64Array([0.0, 0.0, 0.1])})
		if _ok(rp, "Move an isolated vertex's partner"):
			var a3: PackedFloat64Array = rp.cage.positions
			_expect(a3[27] == b2[27] and a3[28] == b2[28] and a3[29] == b2[29], "Moving its partner should leave the isolated vertex where it was.")
			_expect(a3[3 * 10 + 2] == b2[3 * 10 + 2] + 0.1 or absf(a3[3 * 10 + 2] - b2[3 * 10 + 2] - 0.1) < 1e-12, "The rest of the ring should still follow.")
		var restore := OPS.isolate_symmetry(c2, {"vertices": PackedInt32Array([9])}, {"mode": "restore"})
		_expect(restore.ok and (restore.cage.sym_isolated as PackedInt32Array).is_empty(), "Restore should give the vertex its symmetry back.")


func _check_detection() -> void:
	var box := PRIM.box(Vector3(2, 2, 2), Vector3i(2, 2, 2))
	var planes := OPS.detect_mirror(box, PackedInt32Array(), 0.0)
	_expect(planes.size() == 3, "detect_mirror on box 2,2,2 should find 3 planes (%d)." % planes.size())
	var axes := {}
	for pl in planes:
		var n: PackedFloat64Array = pl.normal
		var o: PackedFloat64Array = pl.origin
		for k in 3:
			if absf(absf(n[k]) - 1.0) < 1e-9:
				axes[k] = true
		_expect(absf(o[0]) < 1e-12 and absf(o[1]) < 1e-12 and absf(o[2]) < 1e-12, "Each plane should pass through the centre (%s)." % o)
	_expect(axes.size() == 3, "The planes should be the x, y and z planes (%s)." % [planes])
	var oblong := PRIM.box(Vector3(2, 1.6, 1.2), Vector3i(2, 2, 2))
	var t := CAGE.topology(oblong)
	var hint := PackedInt32Array()
	for f in t.nF:
		var cen := CAGE._centroid(oblong.positions, t.face_verts(f))
		if absf(absf(cen.x) - 1.0) < 1e-12 and cen.y > 0.0 and cen.z > 0.0:
			hint.append(f)
	var hinted := OPS.detect_mirror(oblong, hint, 0.0)
	_expect(hinted.size() == 3 and absf(absf((hinted[0].normal as PackedFloat64Array)[0]) - 1.0) < 1e-9, "Two hint faces on either side should put the YZ plane first (%s)." % [hinted])
	var cyl := PRIM.cylinder(1.0, 1.0, 8, 2)
	var circ := OPS.detect_circular(cyl, PackedInt32Array(), 0.0)
	var counts := {}
	for cand in circ:
		var ax: PackedFloat64Array = cand.axis
		if absf(absf(ax[2]) - 1.0) < 1e-9:
			counts[int(cand.count)] = true
	_expect(counts.has(2) and counts.has(4) and counts.has(8), "detect_circular on cylinder 8,2 should include 2, 4 and 8 about Z (%s)." % [counts.keys()])
	_expect(not counts.has(3) and not counts.has(16), "detect_circular shouldn't claim 3 or 16 copies.")
	# Snap Exactly makes a nearly symmetric cage exact.
	var rng := RandomNumberGenerator.new()
	rng.seed = 77
	var rough := PRIM.box(Vector3(2, 2, 2), Vector3i(2, 2, 2))
	var rp: PackedFloat64Array = rough.positions
	for i in rp.size():
		rp[i] += rng.randf_range(-1e-6, 1e-6)
	rough.positions = rp
	var added := OPS.add_mirror(rough, {}, {"origin": Vector3.ZERO, "normal": Vector3(1, 0, 0), "tolerance": 1e-4, "snap": true})
	if _ok(added, "Mirror - Internal with Snap Exactly"):
		_expect(_mirror_error(added.cage, 0) <= 1e-12, "Snap Exactly should make the cage exactly symmetric (%s)." % _mirror_error(added.cage, 0))
		var m: PackedInt32Array = (added.cage.symmetry as Array)[0].map
		var p: PackedFloat64Array = added.cage.positions
		for v in m.size():
			if m[v] == v:
				_expect(p[3 * v] == 0.0, "Vertices on the plane should be put onto it (%s)." % p[3 * v])
	_expect(not OPS.add_mirror(PRIM.cylinder(1.0, 1.0, 7, 1), {}, {"origin": Vector3.ZERO, "normal": Vector3(1, 0, 0), "snap": false}).ok, "A mirror that doesn't fit should be refused.")
	var circ_added := OPS.add_circular(cyl, {}, {"origin": Vector3.ZERO, "axis": Vector3(0, 0, 1), "count": 4})
	_expect(circ_added.ok and not ((circ_added.cage.symmetry as Array)[0].map as PackedInt32Array).has(-1), "Circular - Internal with 4 copies should fit the 8-sided cylinder.")
	var cleared := OPS.clear_symmetry(circ_added.cage, {}, {})
	_expect(cleared.ok and (cleared.cage.symmetry as Array).is_empty(), "Clear Symmetry should remove every entry.")


func _check_locked() -> void:
	var box := PRIM.box(Vector3(2, 2, 2), Vector3i(2, 2, 2))
	var t := CAGE.topology(box)
	var top := -1
	for f in t.nF:
		var cen := CAGE._centroid(box.positions, t.face_verts(f))
		if cen.z == 1.0 and cen.x > 0.0 and cen.y > 0.0:
			top = f
	var fr := OPS.freeze(box, {"faces": PackedInt32Array([top])}, {})
	if not _ok(fr, "Freeze a top face"):
		return
	var frozen_cage: Dictionary = fr.cage
	_expect((frozen_cage.frozen as PackedInt32Array).size() == 4, "Freezing a face should freeze its 4 vertices.")
	var locked := CAGE.locked_vertices(frozen_cage)
	var want := {}
	for v in t.face_verts(top):
		for f in t.vertex_all_faces(v):
			for w in t.face_verts(f):
				want[w] = true
	var got := 0
	for v in locked.size():
		if locked[v]:
			got += 1
			_expect(want.has(v), "Vertex %d shouldn't be locked." % v)
	_expect(got == want.size(), "The locked set should be the frozen vertices and their 1-ring (%d of %d)." % [got, want.size()])
	var corner := t.face_verts(top)[0]
	var rm := OPS.edit_transform(frozen_cage, {"vertices": PackedInt32Array([corner])}, {"translate": PackedFloat64Array([0.1, 0.0, 0.0])})
	_expect(not rm.ok and rm.error == "Those vertices are frozen." and (rm.cage.positions as PackedFloat64Array) == (frozen_cage.positions as PackedFloat64Array), "Moving a locked vertex should leave it unchanged (%s)." % rm.error)
	var buffer := -1
	for v in want:
		if not (frozen_cage.frozen as PackedInt32Array).has(v):
			buffer = v
			break
	var rb := OPS.edit_transform(frozen_cage, {"vertices": PackedInt32Array([buffer])}, {"translate": PackedFloat64Array([0.1, 0.0, 0.0])})
	_expect(not rb.ok, "Moving a buffer vertex (1-ring of the frozen face) should be refused too.")
	var fv := t.face_verts(top)
	var ri := OPS.insert_edge(frozen_cage, {"edges": PackedInt32Array([fv[0], fv[1]])}, {})
	_expect(not ri.ok and ri.error == CAGE.FROZEN_ERROR, "Insert Edge through a face with a locked vertex should be refused with the frozen message (%s)." % ri.error)
	# The bottom face's centre line toward -X touches no face with a locked vertex.
	var far_a := _vertex_at(box, 0.0, 0.0, -1.0)
	var far_b := _vertex_at(box, -1.0, 0.0, -1.0)
	var rfar := OPS.insert_edge(frozen_cage, {"edges": PackedInt32Array([far_a, far_b])}, {})
	_expect(rfar.ok, "Insert Edge away from the frozen face should work (%s)." % rfar.error)
	# The bottom rim under the +X side reaches faces that hold buffer vertices: refused.
	var rim_a := _vertex_at(box, 1.0, 0.0, -1.0)
	var rim_b := _vertex_at(box, 1.0, 1.0, -1.0)
	var rrim := OPS.insert_edge(frozen_cage, {"edges": PackedInt32Array([rim_a, rim_b])}, {"side": "both"})
	_expect(not rrim.ok and rrim.error == CAGE.FROZEN_ERROR, "Insert Edge into faces with buffer vertices should be refused.")
	_expect(OPS.subdivide(frozen_cage, {"faces": PackedInt32Array([top])}, {}).error == CAGE.FROZEN_ERROR, "Subdividing a frozen face should be refused.")
	_expect(OPS.delete_elements(frozen_cage, {"faces": PackedInt32Array([top])}, {}).error == CAGE.FROZEN_ERROR, "Deleting a frozen face should be refused.")
	var soft := OPS.soft_weights(frozen_cage, null, PackedInt32Array([_vertex_at(box, -1.0, -1.0, -1.0)]), {"distance": 100.0})
	_expect(soft[corner] == 0.0, "Soft weights should be 0 on locked vertices.")
	var un := OPS.unfreeze(frozen_cage, {}, {"all": true})
	_expect(un.ok and (un.cage.frozen as PackedInt32Array).is_empty(), "Unfreeze All should clear the frozen list.")
	_expect(OPS.freeze(frozen_cage, {"faces": PackedInt32Array([top])}, {}).error == OPS.NOTHING, "Freezing frozen vertices again should be nothing to change.")


func _check_geometry() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 2026
	var noisy := PRIM.box(Vector3(2, 2, 2), Vector3i(4, 4, 4))
	var np: PackedFloat64Array = noisy.positions
	for i in np.size():
		np[i] += rng.randf_range(-0.05, 0.05)
	noisy.positions = np
	var size := CAGE.diagonal(noisy)
	var t := CAGE.topology(noisy)
	var side := PackedInt32Array()
	for f in t.nF:
		if CAGE._centroid(noisy.positions, t.face_verts(f)).x > 0.9:
			side.append(f)
	var rf := OPS.flatten(noisy, {"faces": side}, {"direction": "fit"})
	if _ok(rf, "Flatten (fit)"):
		var o: PackedFloat64Array = rf.info.origin
		var n: PackedFloat64Array = rf.info.normal
		var worst := 0.0
		for v in rf.info.moved:
			var p := _pd(rf.cage, v)
			worst = maxf(worst, absf((p[0] - o[0]) * n[0] + (p[1] - o[1]) * n[1] + (p[2] - o[2]) * n[2]))
		_expect(worst <= 1e-12 * size, "Flattened points should lie on the plane to 1e-12 of the size (%s)." % worst)
		_expect(absf(n[0]) > 0.99, "The fitted plane should face along x (%s)." % n)
	var rpl := OPS.flatten(noisy, {"faces": side}, {"direction": "plane", "plane": {"origin": Vector3(1, 0, 0), "normal": Vector3(1, 0.1, 0)}})
	if _ok(rpl, "Flatten onto a picked plane"):
		var o: PackedFloat64Array = rpl.info.origin
		var n: PackedFloat64Array = rpl.info.normal
		_expect(absf(n[1] / n[0] - 0.1) < 1e-7 and o[0] == 1.0, "Flatten should use the picked plane (%s, %s)." % [o, n])
		var worst := 0.0
		for v in rpl.info.moved:
			var p := _pd(rpl.cage, v)
			worst = maxf(worst, absf((p[0] - o[0]) * n[0] + (p[1] - o[1]) * n[1] + (p[2] - o[2]) * n[2]))
		_expect(worst <= 1e-12 * size, "Points flattened onto a picked plane should lie on it (%s)." % worst)
	var chain := PackedInt32Array()
	for v in t.nV:
		var p := _pd(noisy, v)
		if absf(p[1] + 1.0) < 0.06 and absf(p[2] + 1.0) < 0.06:
			chain.append(v)
	var rs := OPS.straighten(noisy, {"vertices": chain}, {})
	if _ok(rs, "Straighten (fit)"):
		var o: PackedFloat64Array = rs.info.origin
		var a: PackedFloat64Array = rs.info.direction
		var worst := 0.0
		for v in rs.info.moved:
			var p := _pd(rs.cage, v)
			var d := PackedFloat64Array([p[0] - o[0], p[1] - o[1], p[2] - o[2]])
			var along := d[0] * a[0] + d[1] * a[1] + d[2] * a[2]
			for k in 3:
				worst = maxf(worst, absf(d[k] - along * a[k]))
		_expect(chain.size() == 5 and worst <= 1e-12 * size, "Straightened points should lie on the line to 1e-12 (%d points, off by %s)." % [chain.size(), worst])
	# Smooth: a noisy 6x6 grid, the middle 4x4 faces.
	var grid := PRIM.plane(Vector2(6, 6), Vector2i(6, 6))
	var gp: PackedFloat64Array = grid.positions
	for v in gp.size() / 3:
		gp[3 * v + 2] = rng.randf_range(-0.3, 0.3)
	grid.positions = gp
	var region := PackedInt32Array()
	for j in range(1, 5):
		for i in range(1, 5):
			region.append(j * 6 + i)
	var rsm := OPS.smooth(grid, {"faces": region}, {"amount": 0.5})
	if _ok(rsm, "Smooth"):
		var tg := CAGE.topology(grid)
		var moved: PackedInt32Array = rsm.info.moved
		_expect(moved.size() == 9, "Smoothing the middle 4x4 faces should move the 9 inner vertices (%d)." % moved.size())
		var e0 := _umbrella(grid, tg, moved)
		var e1 := _umbrella(rsm.cage, tg, moved)
		_expect(e1 < e0, "Smooth should lower the umbrella energy (%s -> %s)." % [e0, e1])
		var mset := {}
		for v in moved:
			mset[v] = true
		var a1: PackedFloat64Array = rsm.cage.positions
		var changed := 0
		for v in gp.size() / 3:
			if mset.has(v):
				continue
			for d in 3:
				if a1[3 * v + d] != gp[3 * v + d]:
					changed += 1
		_expect(changed == 0, "Region-border and outside vertices should stay bit-exact (%d coordinates changed)." % changed)
	# Cylindrify a noisy open cylinder.
	var cyl := PRIM.cylinder(1.0, 1.5, 8, 3, "open")
	var cp: PackedFloat64Array = cyl.positions
	for i in cp.size():
		cp[i] += rng.randf_range(-0.04, 0.04)
	cyl.positions = cp
	var rc := OPS.cylindrify(cyl, {"faces": PackedInt32Array([9])}, {})
	if _ok(rc, "Cylindrify"):
		var bands: Array = rc.info.bands
		_expect(bands.size() == 1, "One band should be made round (%d)." % bands.size())
		if bands.size() == 1:
			var band: Dictionary = bands[0]
			var o: PackedFloat64Array = band.origin
			var a: PackedFloat64Array = band.axis
			var u: PackedFloat64Array = band.u
			var w: PackedFloat64Array = band.v
			var rings: Array = band.rings
			_expect(rings.size() == 4, "The band should have 4 rings (%d)." % rings.size())
			var worst_r := 0.0
			var worst_a := 0.0
			for ring in rings:
				var n: int = (ring as PackedInt32Array).size()
				var angles := PackedFloat64Array()
				for v in ring:
					var p := _pd(rc.cage, v)
					var d := PackedFloat64Array([p[0] - o[0], p[1] - o[1], p[2] - o[2]])
					var x := d[0] * u[0] + d[1] * u[1] + d[2] * u[2]
					var y := d[0] * w[0] + d[1] * w[1] + d[2] * w[2]
					worst_r = maxf(worst_r, absf(sqrt(x * x + y * y) - float(band.radius)))
					angles.append(atan2(y, x))
				for k in n:
					var gap := wrapf(angles[(k + 1) % n] - angles[k], 0.0, TAU)
					worst_a = maxf(worst_a, absf(gap - TAU / n))
			_expect(worst_r <= 1e-12, "Ring radii should be equal to 1e-12 (off by %s)." % worst_r)
			_expect(worst_a <= 1e-12, "Ring angles should be evenly spaced to 1e-12 (off by %s)." % worst_a)
	# Slide Edge 0.5 along the equator of box 2,2,2.
	var box := PRIM.box(Vector3(2, 2, 2), Vector3i(2, 2, 2))
	var eq := PackedInt32Array()
	var tb := CAGE.topology(box)
	var bp: PackedFloat64Array = box.positions
	for e in tb.nE:
		var va := tb.edges[2 * e]
		var vb := tb.edges[2 * e + 1]
		if bp[3 * va + 2] == 0.0 and bp[3 * vb + 2] == 0.0:
			eq.append_array(PackedInt32Array([va, vb]))
	var rsl := OPS.slide_edge(box, {"edges": eq}, {"slide": 0.5})
	if _ok(rsl, "Slide Edge 0.5"):
		var moved: PackedInt32Array = rsl.info.moved
		_expect(moved.size() == 8, "Sliding the equator should move its 8 vertices (%d)." % moved.size())
		var zs := {}
		for v in moved:
			var p := _pd(rsl.cage, v)
			_expect(p[0] == bp[3 * v] and p[1] == bp[3 * v + 1], "Slide should keep each vertex on its rail (x, y).")
			zs[p[2]] = true
		_expect(zs.size() == 1 and (zs.has(0.5) or zs.has(-0.5)), "Each vertex should move half way along its rail to z = +-0.5 on one side (%s)." % [zs.keys()])
		_expect(_vef(rsl.cage) == _vef(box), "Slide should keep the topology.")
	var rneg := OPS.slide_edge(box, {"edges": eq}, {"slide": -0.5})
	if _ok(rneg, "Slide Edge -0.5") and rsl.ok:
		var v0: int = (rsl.info.moved as PackedInt32Array)[0]
		_expect(_pd(rneg.cage, v0)[2] == -_pd(rsl.cage, v0)[2], "A negative slide should go the other way.")
	# Crease and UnCrease round trip.
	var rcr := OPS.crease(box, {"edges": eq, "vertices": PackedInt32Array([0])}, {})
	if _ok(rcr, "Crease"):
		_expect((rcr.cage.crease_weights as PackedFloat32Array).size() == 8 and (rcr.cage.crease_weights as PackedFloat32Array)[0] == 10.0, "Crease should give 8 edges weight 10.")
		_expect((rcr.cage.corners as PackedInt32Array) == PackedInt32Array([0]), "Crease should make the vertex a corner.")
		_expect(OPS.crease(rcr.cage, {"edges": eq}, {}).error == OPS.NOTHING, "Creasing creased edges again should be nothing to change.")
		var ru := OPS.uncrease(rcr.cage, {"edges": eq, "vertices": PackedInt32Array([0])}, {})
		_expect(ru.ok and (ru.cage.crease_edges as PackedInt32Array).is_empty() and (ru.cage.corners as PackedInt32Array).is_empty(), "UnCrease should leave crease_edges and corners empty.")
	# Under a mirror, creasing one side creases the partner too.
	var mb := _box_mirror()
	var a := _vertex_at(mb, 1.0, 0.0, 0.0)
	var b := _vertex_at(mb, 1.0, 0.0, 1.0)
	var rmc := OPS.crease(mb, {"edges": PackedInt32Array([a, b])}, {})
	_expect(rmc.ok and (rmc.cage.crease_weights as PackedFloat32Array).size() == 2, "Crease under a mirror should crease the partner edge.")


## Sum over verts of |mean(neighbours) - p|^2.
func _umbrella(c: Dictionary, t: CAGE.Topo, verts: PackedInt32Array) -> float:
	var p: PackedFloat64Array = c.positions
	var total := 0.0
	for v in verts:
		var nb := t.vertex_neighbors(v)
		for d in 3:
			var m := 0.0
			for w in nb:
				m += p[3 * w + d]
			m /= nb.size()
			total += pow(m - p[3 * v + d], 2)
	return total


func _check_soft_weights() -> void:
	# A strip whose first row sits at distances 0, 0.25, 0.5 and 1 from vertex 0.
	var xs := [0.0, 0.25, 0.5, 1.0]
	var pts := PackedVector3Array()
	for x in xs:
		pts.append(Vector3(x, 0, 0))
	for x in xs:
		pts.append(Vector3(x, 10, 0))
	var strip := CAGE.from_vectors(pts, [[0, 1, 5, 4], [1, 2, 6, 5], [2, 3, 7, 6]])
	var want := {"smooth": [1.0, 0.84375, 0.5, 0.0], "linear": [1.0, 0.75, 0.5, 0.0], "bulge": [1.0, 0.9375, 0.75, 0.0]}
	for transition in want:
		var w := OPS.soft_weights(strip, null, PackedInt32Array([0]), {"extent": "distance", "distance": 1.0, "transition": transition})
		for i in 4:
			_expect(w[i] == want[transition][i], "%s weight at distance %s should be %s (got %s)." % [transition.capitalize(), xs[i], want[transition][i], w[i]])
		for i in range(4, 8):
			_expect(w[i] == 0.0, "Vertices beyond the distance should get 0.")
	var half := OPS.soft_weights(strip, null, PackedInt32Array([0]), {"distance": 1.0, "weight": 0.5})
	_expect(half[1] == 0.421875, "The weight scales the falloff (%s)." % half[1])
	var grid := PRIM.plane(Vector2(4, 4), Vector2i(4, 4))
	var fc := OPS.soft_weights(grid, null, PackedInt32Array([12]), {"extent": "faces", "faces": 1, "transition": "linear"})
	_expect(fc[12] == 1.0 and fc[13] == 0.5 and fc[18] == 0.5 and fc[14] == 0.0, "Face Count extent 1 should give 1 / 0.5 / 0 by face rings (%s %s %s %s)." % [fc[12], fc[13], fc[18], fc[14]])
	var rect := OPS.soft_weights(grid, null, PackedInt32Array([12]), {"extent": "rectangular", "u_faces": 2, "v_faces": 1, "transition": "linear", "frame": Basis.IDENTITY})
	_expect(rect[13] == 0.5 and rect[17] == 0.0 and rect[7] == 0.0, "Rectangular extent should measure each frame axis on its own (%s %s %s)." % [rect[13], rect[17], rect[7]])
	# Soft modification through edit_transform: a vertex at R/2 moves half (smooth).
	var r := OPS.edit_transform(strip, {"vertices": PackedInt32Array([0])}, {"translate": PackedFloat64Array([0.0, 0.0, 1.0]), "soft": {"extent": "distance", "distance": 1.0}})
	if _ok(r, "Edit Form with soft modification"):
		var p: PackedFloat64Array = r.cage.positions
		_expect(p[2] == 1.0 and p[8] == 0.5 and p[5] == 0.84375 and p[11] == 0.0, "Soft modification should move each vertex by its weight (%s %s %s %s)." % [p[2], p[5], p[8], p[11]])


## Every tool is called on an input that must come back untouched.
func _check_purity() -> void:
	var box := _box_mirror()
	var t := CAGE.topology(box)
	var fx := -1
	for f in t.nF:
		var cen := CAGE._centroid(box.positions, t.face_verts(f))
		if cen.x == 1.0 and cen.y > 0.0 and cen.z > 0.0:
			fx = f
	var a := _vertex_at(box, 1.0, 0.0, 0.0)
	var b := _vertex_at(box, 1.0, 0.0, 1.0)
	CAGE.set_crease(box, a, b, CAGE.SHARP)
	box.frozen = PackedInt32Array([_vertex_at(box, -1.0, -1.0, -1.0)])
	var open := PRIM.cylinder(1.0, 1.0, 8, 2, "open")
	var plane := PRIM.plane(Vector2(1, 1), Vector2i(2, 2))
	var calls := [
		["edit_transform", box, {"vertices": PackedInt32Array([a])}, {"translate": Vector3(0.1, 0, 0)}],
		["extrude_region", box, {"faces": PackedInt32Array([fx])}, {"distance": 0.1}],
		["extend_edges", plane, {"edges": PackedInt32Array([0, 1])}, {"distance": 0.1}],
		["insert_edge", box, {"edges": PackedInt32Array([a, b])}, {"side": "both"}],
		["subdivide", box, {"faces": PackedInt32Array([fx])}, {}],
		["insert_point", box, {}, {"points": [{"edge": Vector2i(a, b), "t": 0.5}]}],
		["fill_hole", open, {"edges": PackedInt32Array([0, 1])}, {}],
		["unweld", open, {"edges": PackedInt32Array([8, 9, 9, 10])}, {}],
		["crease", box, {"edges": PackedInt32Array([a, _vertex_at(box, 1.0, 1.0, 0.0)])}, {}],
		["uncrease", box, {"edges": PackedInt32Array([a, b])}, {}],
		["slide_edge", box, {"edges": PackedInt32Array([a, b])}, {"slide": 0.3}],
		["smooth", box, {"faces": PackedInt32Array([fx])}, {}],
		["cylindrify", open, {"faces": PackedInt32Array([3])}, {}],
		["flatten", box, {"faces": PackedInt32Array([fx])}, {}],
		["straighten", box, {"vertices": PackedInt32Array([a, b])}, {}],
		["thicken", plane, {}, {}],
		["freeze", box, {"faces": PackedInt32Array([fx])}, {}],
		["unfreeze", box, {}, {"all": true}],
		["delete_elements", box, {"faces": PackedInt32Array([fx])}, {}],
		["clear_symmetry", box, {}, {}],
		["isolate_symmetry", box, {"vertices": PackedInt32Array([a])}, {}],
		["mirror_duplicate", plane, {}, {"origin": Vector3(0.5, 0, 0), "normal": Vector3(1, 0, 0)}],
		["circular_duplicate", plane, {}, {"origin": Vector3(2, 0, 0), "axis": Vector3(0, 0, 1), "count": 3}],
		["add_mirror", box, {}, {"origin": Vector3.ZERO, "normal": Vector3(0, 1, 0)}],
		["add_circular", open, {}, {"origin": Vector3.ZERO, "axis": Vector3(0, 0, 1), "count": 8}],
		["repair", box, {}, {"merge_triangles": true}],
		["bridge", open, {"edges": PackedInt32Array([0, 1, 1, 2]), "edges2": PackedInt32Array([16, 17, 17, 18])}, {"segments": 2}],
		["merge_edge", plane, {"edges": PackedInt32Array([0, 1]), "edges2": PackedInt32Array([6, 7])}, {}],
		["weld_vertices", plane, {"vertices": PackedInt32Array([0, 1])}, {}],
		["erase_and_fill", box, {"faces": PackedInt32Array([fx])}, {}],
		["bevel_edge", box, {"edges": PackedInt32Array([a, b])}, {"segments": 2}],
	]
	var names := {}
	var script: Object = OPS
	for call in calls:
		var c: Dictionary = call[1]
		var before := c.duplicate(true)
		var h := CAGE.content_hash(c)
		var r: Dictionary = script.call(call[0], c, call[2], call[3])
		names[call[0]] = true
		_expect(c == before and CAGE.content_hash(c) == h, "%s should not change its input." % call[0])
		_expect(r.has("ok") and r.has("cage") and r.has("selection") and r.has("warnings") and r.has("error") and r.has("info"), "%s should return the tool result shape." % call[0])
		if bool(r.ok):
			_expect(CAGE.validate(r.cage).is_empty(), "%s should return a valid cage (%s)." % [call[0], ", ".join(CAGE.validate(r.cage))])
		else:
			_expect(str(r.error) != "", "%s should explain a refusal." % call[0])
	for name in ["edit_transform", "extrude_region", "extend_edges", "insert_edge", "subdivide", "insert_point", "fill_hole", "unweld", "crease", "uncrease", "slide_edge", "smooth", "cylindrify", "flatten", "straighten", "thicken", "freeze", "unfreeze", "delete_elements", "clear_symmetry", "isolate_symmetry", "mirror_duplicate", "circular_duplicate", "add_mirror", "add_circular", "repair", "bridge", "merge_edge", "weld_vertices", "erase_and_fill", "bevel_edge"]:
		_expect(names.has(name), "The purity check should cover %s." % name)
	# Repair: a broken cage comes back valid with counted fixes.
	var cube := PRIM.box(Vector3(2, 2, 2), Vector3i(1, 1, 1))
	var p: PackedFloat64Array = cube.positions
	p.append_array(PackedFloat64Array([5.0, 5.0, 5.0]))
	var counts: PackedInt32Array = cube.face_counts
	var idx: PackedInt32Array = cube.face_indices
	var f0 := idx.slice(0, 4)
	counts.append(4)
	idx.append_array(f0)
	var flipped := idx.slice(4, 8)
	flipped.reverse()
	for k in 4:
		idx[4 + k] = flipped[k]
	counts.append(3)
	idx.append_array(PackedInt32Array([0, 0, 1]))
	var broken := CAGE.make(p, counts, idx)
	_expect(not CAGE.validate(broken).is_empty(), "The crafted cage should be broken.")
	var rep := OPS.repair(broken, {}, {})
	if _ok(rep, "Repair a broken cage"):
		_expect(CAGE.validate(rep.cage).is_empty(), "Repair should give a valid cage (%s)." % ", ".join(CAGE.validate(rep.cage)))
		_expect(int(rep.info.duplicate) == 1 and int(rep.info.degenerate) == 1 and int(rep.info.flipped) == 1 and int(rep.info.unused) == 1, "Repair should count 1 duplicate, 1 degenerate, 1 flipped face and 1 unused vertex (%s)." % rep.info)
		_expect(_vef(rep.cage) == Vector3i(8, 12, 6) and CAGE.signed_volume(rep.cage) > 0.0, "The repaired cage should be the outward cube.")
	var report := OPS.repair(broken, {}, {"mode": "report"})
	_expect(report.ok and report.cage == broken and (report.info.markers as Array).size() > 0, "Report mode should change nothing and list markers.")
	# A T-junction: two planes, one split along the shared edge.
	var left := PRIM.plane(Vector2(1, 1), Vector2i(1, 1))
	var right := PRIM.plane(Vector2(1, 1), Vector2i(1, 2))
	var lp: PackedFloat64Array = left.positions
	var rp: PackedFloat64Array = right.positions
	for v in lp.size() / 3:
		lp[3 * v] -= 0.5
	for v in rp.size() / 3:
		rp[3 * v] += 0.5
	left.positions = lp
	right.positions = rp
	var tj: Dictionary = CAGE.append(left, right).cage
	var rt := OPS.repair(tj, {}, {"tolerance": 1e-9})
	if _ok(rt, "Repair a T-junction"):
		_expect(int(rt.info.t_junctions) == 1 and int(rt.info.welded) >= 2, "Repair should zip the T-junction (%s)." % rt.info)
		var tr := CAGE.topology(rt.cage)
		_expect(tr.boundary_loops().size() == 1 and _vef(rt.cage) == Vector3i(8, 10, 3), "The zipped planes should be one sheet (%s)." % _vef(rt.cage))


func _calibration() -> void:
	var x := 0.0
	for i in 200000:
		x += sqrt(float(i)) * 0.5
	_sink = x


func _check_timing() -> void:
	var big := PRIM.box(Vector3(2, 2, 2), Vector3i(29, 29, 29))
	var mirrored := PRIM.primitive_symmetry(big, "mirror", Transform3D.IDENTITY, Vector3i(1, 0, 0), 0)
	var t := CAGE.topology(big)
	# An edge loop around the box through regular vertices, and a face in the middle of a side.
	var p: PackedFloat64Array = big.positions
	var e_mid := -1
	for e in t.nE:
		var a := t.edges[2 * e]
		var b := t.edges[2 * e + 1]
		if p[3 * a] == 1.0 and p[3 * b] == 1.0 and absf(p[3 * a + 2] - p[3 * b + 2]) < 1e-12 and absf(p[3 * a + 1]) < 0.05 and absf(p[3 * a + 2]) < 0.05:
			e_mid = e
			break
	var loop := t.edge_loop(e_mid)
	var loop_pairs := PackedInt32Array()
	for e in loop:
		loop_pairs.append_array(PackedInt32Array([t.edges[2 * e], t.edges[2 * e + 1]]))
	var face := t.he_face[t.edge_he[e_mid]]
	var vert := t.edges[2 * e_mid]
	# Measured 2026-10-29 on the dev machine (debug build, so every tool also validates its
	# result), against the 200k-iteration loop (7.0-7.5 ms): insert_edge on a 116-edge loop
	# 30 ms (ratio 4.13), the same with an X mirror 42 ms (5.73), subdivide one face 26 ms
	# (3.62), extrude one face with an X mirror 53 ms (7.35), move one vertex with an X mirror
	# 14 ms (1.87), delete one face 24 ms (3.35), rebuild_symmetry 2.8 ms (0.39), one full
	# Catmull-Clark step 59 ms (8.10). Each limit is twice the measured ratio; every op is also
	# held to the 120 ms budget.
	var specs := [
		["insert_edge loop", func() -> void: OPS.insert_edge(big, {"edges": loop_pairs}, {}), 8.3],
		["insert_edge loop, mirrored", func() -> void: OPS.insert_edge(mirrored, {"edges": loop_pairs}, {}), 11.5],
		["subdivide 1 face", func() -> void: OPS.subdivide(big, {"faces": PackedInt32Array([face])}, {}), 7.3],
		["extrude 1 face, mirrored", func() -> void: OPS.extrude_region(mirrored, {"faces": PackedInt32Array([face])}, {}), 14.7],
		["move 1 vertex, mirrored", func() -> void: OPS.edit_transform(mirrored, {"vertices": PackedInt32Array([vert])}, {"translate": Vector3(0.01, 0, 0)}), 3.8],
		["delete 1 face", func() -> void: OPS.delete_elements(big, {"faces": PackedInt32Array([face])}, {}), 6.7],
		["rebuild_symmetry", func() -> void: OPS.rebuild_symmetry(mirrored, 0.0), 0.8],
		["Catmull-Clark step", func() -> void: CAGE.catmull_clark_step(big), 16.2],
	]
	for spec in specs:
		var r := TIMING.compare(spec[1], _calibration, 3, spec[0] + " (5046 faces) / 200k-iteration loop")
		_timings.append("%s %.1f ms, ratio %.2f" % [spec[0], r.op, r.ratio])
		_expect(r.ratio < float(spec[2]), "%s on 5046 faces should take under %.2f calibration loops (%.1f ms against %.1f ms, ratio %.2f)." % [spec[0], spec[2], r.op, r.calibration, r.ratio])
		_expect(r.op < 120.0 or OS.get_environment("HOLO_FORGE_TIMING_SLOWDOWN") != "", "%s on 5046 faces should take under 120 ms (%.1f ms)." % [spec[0], r.op])
