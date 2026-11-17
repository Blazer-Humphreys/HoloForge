extends SceneTree
## Holo Forge Phase 6, Stage 3 (team M1): the Form create tools that start from curves and clicks.
## - Extrude, Revolve, Sweep, Loft and Pipe cages from a scripted sketch (a circle profile, a
##   rectangle profile, an arc, a line path, three loft sections, an arc path) have the counts of
##   the work order's section 3.2 tables, valid cages and outward faces;
## - Revolve with Weld makes poles of valence n; Keep Creases creases the edges from sharp corners;
## - Fit to Curves puts the limit surface through the sample vertices within 1e-6 m;
## - a branching pipe path is refused with its message;
## - Face makes, extends and joins faces (Simple, Edge, Chain);
## - in a headless workspace, Extrude through the tool engine is one undo step.
##
## godot --headless --path . --script res://tests/holo_forge_form_create_test.gd

const DOCUMENT := preload("res://addons/holo_forge/core/document.gd")
const REGEN := preload("res://addons/holo_forge/core/regen.gd")
const CAGE := preload("res://addons/holo_forge/core/form/cage.gd")
const FORM_CREATE := preload("res://addons/holo_forge/core/form/form_create.gd")
const FORM_TOOLS := preload("res://addons/holo_forge/ui/form_tools.gd")
const SKETCH_DATA := preload("res://addons/holo_forge/core/sketch/sketch_data.gd")
const WORKSPACE := preload("res://addons/holo_forge/ui/forge_workspace.gd")
const CAD_PART := preload("res://addons/holo_forge/nodes/cad_part.gd")

const MM := 0.001
## Fit to Curves: the limit at the sample vertices lies on the curve within this (meters).
const FIT_TOLERANCE := 1e-6

var failures: Array[String] = []
var checked: Array[String] = []
var kernel: RefCounted
var doc: Resource
var result: Dictionary
var native := false
## Sketch features of the scripted model and the entities the checks pick.
var circle_sketch: Resource
var circle_id := -1
var rect_sketch: Resource
var arc_sketch: Resource
var arc_id := -1
var path_sketch: Resource
var path_line := -1
var loft_sketches: Array[Resource] = []
var loft_circles: Array[int] = []
var pipe_sketch: Resource
var pipe_arc := -1
var branch_sketch: Resource
var branch_lines: Array[int] = []
var tip_sketch: Resource
var tip_point := -1
## Extra paths: a rectangle against the Y axis, an L-shaped path with a small circle at its start, a
## circle path with a small circle across its start, a centerline and a rail for the loft.
var rect_axis_sketch: Resource
var l_sketch: Resource
var l_lines: Array[int] = []
var l_profile_sketch: Resource
var ring_sketch: Resource
var ring_id := -1
var ring_profile_sketch: Resource
var guide_sketch: Resource
var centerline_id := -1
var rail_id := -1


func _init() -> void:
	call_deferred("run")


func run() -> void:
	create_timer(240.0).timeout.connect(func() -> void:
		print("FAIL holo_forge_form_create: timed out ", failures)
		quit(1))
	kernel = REGEN.make_kernel()
	native = kernel != null and ClassDB.class_exists("CadSubD")
	if not native:
		print("NOTE: CadKernel / CadSubD are not registered (the holo_forge native DLL is missing): sketch-based creates skipped.")
	else:
		_build_model()
		_check_extrude()
		_check_revolve()
		_check_sweep()
		_check_loft()
		_check_pipe()
		_check_fit()
		_check_more()
		await _check_workspace()
	_check_face()
	if failures.is_empty():
		print("PASS holo_forge_form_create: " + ", ".join(checked) + ".")
	else:
		print("FAIL holo_forge_form_create")
		for f in failures:
			print("  - ", f)
	quit(0 if failures.is_empty() else 1)


func _expect(ok: bool, message: String) -> void:
	if not ok:
		failures.append(message)
		push_error(message)


# --- Model -------------------------------------------------------------------------------------

func _sketch(frame: Dictionary, ref := "frame") -> Resource:
	return doc.add_feature("sketch", "Sketch", {}, SKETCH_DATA.new_options(frame, ref))


func _build_model() -> void:
	doc = DOCUMENT.new()
	# A circle (r 10 mm) on XY; a 20 x 10 mm rectangle on XY beside it.
	circle_sketch = _sketch(SKETCH_DATA.ORIGIN_PLANES.xy, "xy")
	var s = SKETCH_DATA.new(circle_sketch, doc)
	circle_id = s.add_circle(s.add_point(Vector2.ZERO), 10 * MM)
	rect_sketch = _sketch({"origin": Vector3(0, 0, 0), "x": Vector3.RIGHT, "y": Vector3.UP})
	s = SKETCH_DATA.new(rect_sketch, doc)
	var c := Vector2(40, 0) * MM
	var p := [s.add_point(c), s.add_point(c + Vector2(20, 0) * MM), s.add_point(c + Vector2(20, 10) * MM), s.add_point(c + Vector2(0, 10) * MM)]
	for i in 4:
		s.add_line(p[i], p[(i + 1) % 4])
	# A half circle (r 10 mm) on XZ from (0, 0, 10) to (0, 0, -10) mm through (10, 0, 0): both ends
	# on the Z axis.
	arc_sketch = _sketch(SKETCH_DATA.ORIGIN_PLANES.xz, "xz")
	s = SKETCH_DATA.new(arc_sketch, doc)
	arc_id = s.add_arc(s.add_point(Vector2.ZERO), s.add_point(Vector2(0, -10) * MM), s.add_point(Vector2(0, 10) * MM))
	# A 40 mm line along +Z (on YZ: sketch x is world -Z).
	path_sketch = _sketch(SKETCH_DATA.ORIGIN_PLANES.yz, "yz")
	s = SKETCH_DATA.new(path_sketch, doc)
	path_line = s.add_line(s.add_point(Vector2.ZERO), s.add_point(Vector2(-40, 0) * MM))
	# Three loft sections: circles r 10 / 15 / 8 mm at z = 60 / 80 / 100 mm.
	for spec in [[60.0, 10.0], [80.0, 15.0], [100.0, 8.0]]:
		var sk := _sketch({"origin": Vector3(0, 0, spec[0] * MM), "x": Vector3.RIGHT, "y": Vector3.UP})
		var ls = SKETCH_DATA.new(sk, doc)
		loft_sketches.append(sk)
		loft_circles.append(ls.add_circle(ls.add_point(Vector2.ZERO), spec[1] * MM))
	# A tip point for a loft at z = 45 mm.
	tip_sketch = _sketch({"origin": Vector3(0, 0, 45 * MM), "x": Vector3.RIGHT, "y": Vector3.UP})
	s = SKETCH_DATA.new(tip_sketch, doc)
	tip_point = s.add_point(Vector2(0.0, 0.0))
	# A quarter circle path (r 25 mm) on XY, away from the rest.
	pipe_sketch = _sketch({"origin": Vector3(0, 100 * MM, 0), "x": Vector3.RIGHT, "y": Vector3.UP})
	s = SKETCH_DATA.new(pipe_sketch, doc)
	pipe_arc = s.add_arc(s.add_point(Vector2.ZERO), s.add_point(Vector2(25, 0) * MM), s.add_point(Vector2(0, 25) * MM))
	# Three lines meeting at one point (a branching path).
	branch_sketch = _sketch({"origin": Vector3(0, -100 * MM, 0), "x": Vector3.RIGHT, "y": Vector3.UP})
	s = SKETCH_DATA.new(branch_sketch, doc)
	var hub: int = s.add_point(Vector2.ZERO)
	for dir in [Vector2(20, 0), Vector2(-10, 17), Vector2(-10, -17)]:
		branch_lines.append(s.add_line(hub, s.add_point(dir * MM)))
	# A 10 x 20 mm rectangle with its 20 mm side on the Y axis (y 0.3 .. 0.32 m).
	rect_axis_sketch = _sketch({"origin": Vector3(0, 0.3, 0), "x": Vector3.RIGHT, "y": Vector3.UP})
	s = SKETCH_DATA.new(rect_axis_sketch, doc)
	var q := [s.add_point(Vector2.ZERO), s.add_point(Vector2(10, 0) * MM), s.add_point(Vector2(10, 20) * MM), s.add_point(Vector2(0, 20) * MM)]
	for i in 4:
		s.add_line(q[i], q[(i + 1) % 4])
	# An L: 20 mm along +X from (0.2, 0, 0), then 20 mm along +Y; a 3 mm circle square to its start.
	l_sketch = _sketch({"origin": Vector3(0.2, 0, 0), "x": Vector3.RIGHT, "y": Vector3.UP})
	s = SKETCH_DATA.new(l_sketch, doc)
	var l0: int = s.add_point(Vector2.ZERO)
	var l1: int = s.add_point(Vector2(20, 0) * MM)
	var l2: int = s.add_point(Vector2(20, 20) * MM)
	l_lines.append(s.add_line(l0, l1))
	l_lines.append(s.add_line(l1, l2))
	l_profile_sketch = _sketch({"origin": Vector3(0.2, 0, 0), "x": Vector3.FORWARD, "y": Vector3.UP})
	s = SKETCH_DATA.new(l_profile_sketch, doc)
	s.add_circle(s.add_point(Vector2.ZERO), 3 * MM)
	# A 20 mm circle path round (0.3, 0, 0) and a 3 mm circle across it at its start (0.32, 0, 0).
	ring_sketch = _sketch({"origin": Vector3(0.3, 0, 0), "x": Vector3.RIGHT, "y": Vector3.UP})
	s = SKETCH_DATA.new(ring_sketch, doc)
	ring_id = s.add_circle(s.add_point(Vector2.ZERO), 20 * MM)
	ring_profile_sketch = _sketch({"origin": Vector3(0.32, 0, 0), "x": Vector3.RIGHT, "y": Vector3.FORWARD})
	s = SKETCH_DATA.new(ring_profile_sketch, doc)
	s.add_circle(s.add_point(Vector2.ZERO), 3 * MM)
	# The loft guides: a centerline along Z through the loft circles, and a rail beside them.
	guide_sketch = _sketch({"origin": Vector3(0, 0, 0.05), "x": Vector3.FORWARD, "y": Vector3.RIGHT})
	s = SKETCH_DATA.new(guide_sketch, doc)
	centerline_id = s.add_line(s.add_point(Vector2.ZERO), s.add_point(Vector2(-60, 0) * MM))
	rail_id = s.add_line(s.add_point(Vector2(-10, 12) * MM), s.add_point(Vector2(-50, 12) * MM))
	result = REGEN.rebuild(doc, kernel)
	_expect((result.errors as Dictionary).is_empty(), "The scripted sketches should rebuild without errors (%s)." % [result.errors])


func _ctx(cages := {}) -> Dictionary:
	return {"feature": null, "doc": doc, "cages": cages, "subd": Callable(), "kernel": kernel, "result": result, "values": {}}


func _curve(sketch: Resource, entity: int) -> Dictionary:
	return {"kind": "sketch_curve", "sketch": sketch.id, "entity": entity}


func _profile(sketch: Resource, point: Vector2) -> Dictionary:
	return {"kind": "profile", "sketch": sketch.id, "point": point}


## Runs a tool through the registry; returns its single new cage ({} on failure, reported).
func _run(id: String, values: Dictionary, label: String, cages := {}) -> Dictionary:
	var r := FORM_TOOLS.run(id, _ctx(cages), {}, values)
	_expect(bool(r.ok), "%s should build (%s)." % [label, r.error])
	if not bool(r.ok):
		return {}
	var made: Array = r.new_bodies
	_expect(made.size() == 1, "%s should make one new body (%d)." % [label, made.size()])
	return made[0] if not made.is_empty() else {}


func _counts(cage: Dictionary) -> Vector3i:
	if cage.is_empty():
		return Vector3i.ZERO
	return Vector3i(CAGE.vertex_count(cage), CAGE.topology(cage).nE, CAGE.face_count(cage))


func _expect_counts(cage: Dictionary, want: Vector3i, label: String) -> void:
	var got := _counts(cage)
	_expect(got == want, "%s should be V/E/F %d/%d/%d (got %d/%d/%d)." % [label, want.x, want.y, want.z, got.x, got.y, got.z])
	if not cage.is_empty():
		var problems := CAGE.validate(cage)
		_expect(problems.is_empty(), "%s should be a valid cage (%s)." % [label, problems])


## Every face points away from the axis line (origin, dir): area vector . radial > 0.
func _outward_from_axis(cage: Dictionary, origin: Vector3, dir: Vector3, label: String) -> void:
	var topo := CAGE.topology(cage)
	var bad := 0
	for f in topo.nF:
		var centre := Vector3.ZERO
		var verts := CAGE.face_vertices(cage, f)
		for v in verts:
			centre += CAGE.position(cage, v)
		centre /= verts.size()
		var rel := centre - origin
		var radial := rel - dir * rel.dot(dir)
		if topo.face_area_vector(cage, f).dot(radial) <= 0.0:
			bad += 1
	_expect(bad == 0, "%s: every face should point outward (%d of %d don't)." % [label, bad, topo.nF])


## A short scientific form of x ("7.8e-10").
func _sci(x: float) -> String:
	if x == 0.0 or not is_finite(x):
		return str(x)
	var e := floori(log(absf(x)) / log(10.0))
	return "%.1fe%d" % [x / pow(10.0, e), e]


func _crease_count(cage: Dictionary) -> int:
	return (cage.get("crease_weights", PackedFloat32Array()) as PackedFloat32Array).size()


# --- Extrude -------------------------------------------------------------------------------------

func _base_extrude(extra: Dictionary) -> Dictionary:
	var values := {"distance": 20 * MM, "direction": "one_side", "distance2": 10 * MM, "taper": 0.0, "spacing": "uniform", "profile_faces": 8,
		"front_faces": 1, "keep_creases": true, "fit": false, "body": "new"}
	values.merge(extra, true)
	return values


func _check_extrude() -> void:
	# Closed k, m: k(m+1) / k(2m+1) / k m.
	var circle := _run("extrude", _base_extrude({"profile": [_profile(circle_sketch, Vector2.ZERO)]}), "Extrude of the circle profile")
	_expect_counts(circle, Vector3i(16, 24, 8), "The circle extruded with 8 faces round and 1 along")
	if not circle.is_empty():
		_outward_from_axis(circle, Vector3.ZERO, Vector3.BACK, "The extruded circle")
		var box := CAGE.bounds(circle)
		_expect(absf(box.position.z) < 1e-9 and absf(box.end.z - 0.02) < 1e-9, "One Side should run from the profile 20 mm along +Z (%s)." % box)
	var rect := _run("extrude", _base_extrude({"profile": [_profile(rect_sketch, Vector2(50, 5) * MM)], "front_faces": 2}), "Extrude of the rectangle profile")
	_expect_counts(rect, Vector3i(24, 40, 16), "The rectangle extruded with 8 faces round and 2 along")
	if not rect.is_empty():
		_expect(_crease_count(rect) == 8, "Keep Creases should crease the 4 corner lines (2 edges each) of the rectangle (%d)." % _crease_count(rect))
		var points := CAGE.positions_v3(rect)
		var on_corner := 0
		for q in points:
			for corner in [Vector2(40, 0), Vector2(60, 0), Vector2(60, 10), Vector2(40, 10)]:
				if Vector2(q.x, q.y).distance_to(corner * MM) < 1e-9:
					on_corner += 1
		_expect(on_corner == 12, "Every sharp corner of the rectangle should get a vertex in each ring (%d of 12)." % on_corner)
	var plain := _run("extrude", _base_extrude({"profile": [_profile(rect_sketch, Vector2(50, 5) * MM)], "keep_creases": false}), "Extrude without creases")
	_expect(not plain.is_empty() and _crease_count(plain) == 0, "Without Keep Creases nothing is creased.")
	# An open profile (the arc): (k+1)(m+1) / k(m+1) + (k+1)m / k m with its default 4 faces.
	var arc := _run("extrude", _base_extrude({"profile": [_curve(arc_sketch, arc_id)], "profile_faces": 4}), "Extrude of the open arc")
	_expect_counts(arc, Vector3i(10, 13, 4), "The open arc extruded with 4 faces")
	var sym := _run("extrude", _base_extrude({"profile": [_profile(circle_sketch, Vector2.ZERO)], "direction": "symmetric"}), "Symmetric extrude")
	_expect_counts(sym, Vector3i(24, 40, 16), "The symmetric extrude (one ring each side of the profile)")
	if not sym.is_empty():
		var box := CAGE.bounds(sym)
		_expect(absf(box.position.z + 0.01) < 1e-9 and absf(box.end.z - 0.01) < 1e-9, "Symmetric should centre the 20 mm on the profile (%s)." % box)
	var two := _run("extrude", _base_extrude({"profile": [_profile(circle_sketch, Vector2.ZERO)], "direction": "two_sides"}), "Two-sided extrude")
	if not two.is_empty():
		var box := CAGE.bounds(two)
		_expect(absf(box.position.z + 0.01) < 1e-9 and absf(box.end.z - 0.02) < 1e-9, "Two Sides should run 10 mm back and 20 mm forward (%s)." % box)
	var tapered := _run("extrude", _base_extrude({"profile": [_profile(circle_sketch, Vector2.ZERO)], "taper": deg_to_rad(10.0)}), "Tapered extrude")
	if not tapered.is_empty():
		var top := 0.0
		for q in CAGE.positions_v3(tapered):
			if q.z > 0.019:
				top = maxf(top, Vector2(q.x, q.y).length())
		_expect(absf(top - (0.01 - 0.02 * tan(deg_to_rad(10.0)))) < 1e-7, "A positive taper should narrow the far ring (%s m)." % top)
	var curvature := _run("extrude", _base_extrude({"profile": [_profile(rect_sketch, Vector2(50, 5) * MM)], "spacing": "curvature"}), "Curvature-spaced extrude")
	_expect_counts(curvature, Vector3i(16, 24, 8), "The curvature-spaced rectangle")
	checked.append("Extrude circle 16/24/8, rectangle 24/40/16 with 8 creased corner edges and a vertex on every corner, open arc 10/13/4, symmetric 24/40/16, two sides and taper extents, outward faces")


# --- Revolve -------------------------------------------------------------------------------------

func _check_revolve() -> void:
	var base := {"profile": [_curve(arc_sketch, arc_id)], "axis": [{"kind": "origin", "name": "z"}], "type": "full", "angle": PI * 0.5,
		"direction": "one_side", "angle2": PI * 0.5, "spacing": "uniform", "profile_faces": 4, "around_faces": 8, "weld": true, "symmetry": "none",
		"keep_creases": true, "fit": false, "body": "new"}
	var ball := _run("revolve", base, "Revolve of the half circle")
	# Open profile, k segments, both ends on the axis, full, weld: (k-1)n+2 / (2k-1)n / k n.
	_expect_counts(ball, Vector3i(26, 56, 32), "The welded full revolve (k 4, n 8)")
	if not ball.is_empty():
		var topo := CAGE.topology(ball)
		var poles := 0
		for v in topo.nV:
			var q := CAGE.position(ball, v)
			if Vector2(q.x, q.y).length() < 1e-9:
				poles += 1
				_expect(topo.valence(v) == 8, "A revolve pole should have valence 8 (%d)." % topo.valence(v))
		_expect(poles == 2, "Weld should make one pole at each end of the profile (%d)." % poles)
		_expect(topo.is_closed() and CAGE.signed_volume(ball) > 0.0, "The welded revolve should be closed and face outward.")
	var circular := base.duplicate()
	circular["symmetry"] = "circular"
	var sym := _run("revolve", circular, "Revolve with circular symmetry")
	if not sym.is_empty():
		var entries: Array = sym.symmetry
		_expect(entries.size() == 1 and str(entries[0].type) == "circular" and int(entries[0].count) == 8 and not (entries[0].map as PackedInt32Array).has(-1),
			"Circular symmetry should add a complete 8-fold entry about the axis (%s)." % [entries])
	var part := base.duplicate()
	part["type"] = "angle"
	var quarter := _run("revolve", part, "Revolve by 90 degrees")
	# n segments over the angle: n + 1 copies; the poles stay single.
	_expect_counts(quarter, Vector3i(29, 60, 32), "The welded 90-degree revolve")
	var unwelded := base.duplicate()
	unwelded["weld"] = false
	var r := FORM_TOOLS.run("revolve", _ctx(), {}, unwelded)
	_expect(bool(r.ok) and str(r.warnings).contains("Weld is off"), "Without Weld the profile ends stay apart, with a warning (%s)." % [r.warnings])
	checked.append("Revolve weld 26/56/32 with 2 poles of valence 8 (closed, outward), 90 degrees 29/60/32, circular symmetry entry")


# --- Sweep ---------------------------------------------------------------------------------------

func _check_sweep() -> void:
	var values := {"profile": [_profile(circle_sketch, Vector2.ZERO)], "path": [_curve(path_sketch, path_line)], "profile_faces": 8, "profile_spacing": "uniform",
		"path_faces": 8, "path_spacing": "uniform", "orientation": "perpendicular", "extent": 1.0, "keep_creases": true, "fit": false, "body": "new"}
	var tube := _run("sweep", values, "Sweep of the circle along the line")
	_expect_counts(tube, Vector3i(72, 136, 64), "The circle swept along the line (k 8, m 8)")
	if not tube.is_empty():
		_outward_from_axis(tube, Vector3.ZERO, Vector3.BACK, "The swept tube")
		var box := CAGE.bounds(tube)
		_expect(absf(box.end.z - 0.04) < 1e-6 and absf(box.size.x - 0.02) < 1e-6, "The sweep should follow the 40 mm path with the 20 mm circle (%s)." % box)
	var half := values.duplicate()
	half["extent"] = 0.5
	var short := _run("sweep", half, "Sweep along half the path")
	if not short.is_empty():
		_expect(absf(CAGE.bounds(short).end.z - 0.02) < 1e-6, "Distance 0.5 should follow half the path (%s)." % CAGE.bounds(short))
	checked.append("Sweep circle along line 72/136/64 (outward), Distance 0.5 follows half the path")


# --- Loft ----------------------------------------------------------------------------------------

func _check_loft() -> void:
	var sections := []
	for i in 3:
		sections.append(_profile(loft_sketches[i], Vector2.ZERO))
	var values := {"profiles": sections, "guide": "none", "rails": [], "centerline": [], "closed": false, "length_faces": 2, "width_faces": 8,
		"spacing": "uniform", "start": "free", "start_angle": 0.0, "start_weight": 1.0, "end": "free", "end_angle": 0.0, "end_weight": 1.0,
		"fit": false, "body": "new"}
	var loft := _run("loft", values, "Loft through 3 sections")
	# rings = (3 - 1) * 2 + 1 = 5: V = 8 * 5, E = 8 * (5 + 4), F = 8 * 4.
	_expect_counts(loft, Vector3i(40, 72, 32), "The 3-section loft (8 wide, 2 per span)")
	if not loft.is_empty():
		_outward_from_axis(loft, Vector3.ZERO, Vector3.BACK, "The loft")
		var radii := {}
		for q in CAGE.positions_v3(loft):
			var key := roundi(q.z / MM)
			radii[key] = maxf(float(radii.get(key, 0.0)), Vector2(q.x, q.y).length())
		_expect(radii.has(60) and radii.has(80) and radii.has(100) and absf(float(radii[80]) - 0.015) < 1e-6, "The loft's section rings should sit on the sections (%s)." % [radii])
	var tipped := values.duplicate()
	tipped["profiles"] = [{"kind": "sketch_point", "sketch": tip_sketch.id, "entity": tip_point}, sections[0], sections[1]]
	tipped["start"] = "tip"
	var tip := _run("loft", tipped, "Loft from a point tip")
	# A pole and 4 more rings of 8: V 33, F 8 triangles + 24 quads, E 8 + 8 * 4 + 8 * 3.
	_expect_counts(tip, Vector3i(33, 64, 32), "The loft from a point tip")
	if not tip.is_empty():
		var topo := CAGE.topology(tip)
		var pole := -1
		for v in topo.nV:
			if CAGE.position(tip, v).distance_to(Vector3(0, 0, 0.045)) < 1e-9:
				pole = v
		_expect(pole >= 0 and topo.valence(pole) == 8, "The tip should be a pole of valence 8 at the point.")
	var looped := values.duplicate()
	looped["closed"] = true
	var ring := _run("loft", looped, "Closed loft")
	_expect_counts(ring, Vector3i(48, 96, 48), "The closed 3-section loft (6 rings round)")
	checked.append("Loft 3 sections 40/72/32 (outward, rings on the sections), point tip 33/64/32 with a valence-8 pole, closed loft 48/96/48")


# --- Pipe ----------------------------------------------------------------------------------------

func _pipe_values(extra: Dictionary) -> Dictionary:
	var values := {"path": [_curve(pipe_sketch, pipe_arc)], "diameter": 10 * MM, "around_faces": 8, "density": 0, "start_end": "open", "end_end": "open",
		"tolerance": 0.01 * MM, "sections": "0", "fit": false, "body": "new"}
	values.merge(extra, true)
	return values


func _check_pipe() -> void:
	# The quarter circle is 39.27 mm long: auto density round(39.27 / 10) = 4 segments.
	var tube := _run("pipe", _pipe_values({}), "Pipe along the arc")
	_expect_counts(tube, Vector3i(40, 72, 32), "The pipe (n 8, m 4: n(m+1) / n(2m+1) / n m)")
	if not tube.is_empty():
		# Outward from the path: away from the nearest point of the quarter circle.
		var topo := CAGE.topology(tube)
		var inward := 0
		for f in topo.nF:
			var centre := Vector3.ZERO
			for v in CAGE.face_vertices(tube, f):
				centre += CAGE.position(tube, v)
			centre /= CAGE.face_vertices(tube, f).size()
			var flat := Vector3(centre.x, centre.y - 0.1, 0.0)
			var on_path := Vector3(0, 0.1, 0) + flat.normalized() * 0.025
			if topo.face_area_vector(tube, f).dot(centre - on_path) <= 0.0:
				inward += 1
		_expect(inward == 0, "The pipe: every face should point away from the path (%d of %d don't)." % [inward, topo.nF])
		var worst := 0.0
		for q in CAGE.positions_v3(tube):
			var radial := Vector2(q.x, q.y - 0.1).length()
			worst = maxf(worst, absf(Vector2(radial - 0.025, q.z).length() - 0.005))
		_expect(worst < 1e-6, "The pipe's rings should sit 5 mm from the path (worst %s m)." % worst)
	var dense := _run("pipe", _pipe_values({"density": 6}), "Pipe with density 6")
	_expect_counts(dense, Vector3i(56, 104, 48), "The pipe with 6 segments")
	var square := _run("pipe", _pipe_values({"start_end": "square", "end_end": "square"}), "Pipe with square ends")
	_expect_counts(square, Vector3i(40, 72, 34), "The pipe with two square ends (+1 F each)")
	if not square.is_empty():
		_expect(_crease_count(square) == 16 and CAGE.topology(square).is_closed() and CAGE.signed_volume(square) > 0.0,
			"Square ends should close the pipe with creased rims (%d creases)." % _crease_count(square))
	var spike := _run("pipe", _pipe_values({"start_end": "spike", "end_end": "spike"}), "Pipe with spike ends")
	_expect_counts(spike, Vector3i(42, 88, 48), "The pipe with two spike ends (+1 V and +n F each)")
	var swell := _run("pipe", _pipe_values({"sections": "1", "s1_pos": 0.5, "s1_dia": 16 * MM, "s1_angle": 0.0}), "Pipe with a section")
	if not swell.is_empty():
		var widest := 0.0
		for q in CAGE.positions_v3(swell):
			widest = maxf(widest, Vector2(Vector2(q.x, q.y - 0.1).length() - 0.025, q.z).length())
		_expect(absf(widest - 0.008) < 1e-6, "A 16 mm section at the middle should widen the pipe there (%s m)." % widest)
	var branching: Array = []
	for line in branch_lines:
		branching.append(_curve(branch_sketch, line))
	var r := FORM_TOOLS.run("pipe", _ctx(), {}, _pipe_values({"path": branching}))
	_expect(not bool(r.ok) and str(r.error) == FORM_CREATE.BRANCHING, "A branching path should be refused with its message (%s)." % r.error)
	checked.append("Pipe 40/72/32 (rings 5 mm off the path), density 6 56/104/48, square ends +2 F closed with 16 creased rim edges, spike ends 42/88/48, a section widens it, branching refused")


# --- Fit to curves -------------------------------------------------------------------------------

## The limit points of a cage (doubles).
func _limits(cage: Dictionary) -> PackedFloat64Array:
	var subd: RefCounted = ClassDB.instantiate("CadSubD")
	if not subd.set_cage(cage):
		return PackedFloat64Array()
	return subd.limit_points().positions


func _check_fit() -> void:
	var circle := _run("extrude", _base_extrude({"profile": [_profile(circle_sketch, Vector2.ZERO)], "fit": true}), "Extrude fitted to the circle")
	var worst := 0.0
	var count := 0
	if not circle.is_empty():
		var lp := _limits(circle)
		_expect(lp.size() == 3 * CAGE.vertex_count(circle), "The fitted cage should evaluate.")
		for v in lp.size() / 3:
			var x := lp[3 * v]
			var y := lp[3 * v + 1]
			var z := lp[3 * v + 2]
			# Each ring is the circle (r 10 mm) at z 0 or 20 mm.
			var off := absf(sqrt(x * x + y * y) - 0.01) + minf(absf(z), absf(z - 0.02))
			worst = maxf(worst, off)
			count += 1
	_expect(count == 16 and worst <= FIT_TOLERANCE, "Fit to Curves: the extrude's limit at its %d sample vertices should lie on the circle within 1e-6 m (worst %s m)." % [count, String.num_scientific(worst)])
	var worst_revolve := 0.0
	var ball := _run("revolve", {"profile": [_curve(arc_sketch, arc_id)], "axis": [{"kind": "origin", "name": "z"}], "type": "full", "spacing": "uniform",
		"profile_faces": 4, "around_faces": 8, "weld": true, "symmetry": "none", "keep_creases": true, "fit": true, "body": "new"}, "Revolve fitted to the arc")
	if not ball.is_empty():
		var lp := _limits(ball)
		for v in lp.size() / 3:
			worst_revolve = maxf(worst_revolve, absf(Vector3(lp[3 * v], lp[3 * v + 1], lp[3 * v + 2]).length() - 0.01))
	_expect(not ball.is_empty() and worst_revolve <= FIT_TOLERANCE, "Fit to Curves: the revolve's limit at its sample vertices should lie on the revolved arc within 1e-6 m (worst %s m)." % String.num_scientific(worst_revolve))
	# Without the fit the limit shrinks inside the curve.
	var loose := _run("extrude", _base_extrude({"profile": [_profile(circle_sketch, Vector2.ZERO)], "fit": false}), "Extrude not fitted")
	var inside := 0.0
	if not loose.is_empty():
		var lp := _limits(loose)
		inside = 0.01 - sqrt(lp[0] * lp[0] + lp[1] * lp[1])
	_expect(inside > 1e-4, "Without the fit the limit should lie inside the circle (%s m)." % inside)
	var worst_loft := 0.0
	var sections := []
	for i in 3:
		sections.append(_profile(loft_sketches[i], Vector2.ZERO))
	var loft := _run("loft", {"profiles": sections, "guide": "none", "closed": false, "length_faces": 2, "width_faces": 8, "spacing": "uniform",
		"start": "free", "end": "free", "fit": true, "body": "new"}, "Loft fitted to its sections")
	if not loft.is_empty():
		var lp := _limits(loft)
		var radius := {60: 0.01, 80: 0.015, 100: 0.008}
		for v in lp.size() / 3:
			var z := roundi(lp[3 * v + 2] / MM)
			if radius.has(z) and absf(lp[3 * v + 2] - z * MM) < 1e-7:
				worst_loft = maxf(worst_loft, absf(Vector2(lp[3 * v], lp[3 * v + 1]).length() - float(radius[z])))
	_expect(not loft.is_empty() and worst_loft <= FIT_TOLERANCE, "Fit to Curves: the loft's limit at its section vertices should lie on the sections within 1e-6 m (worst %s m)." % String.num_scientific(worst_loft))
	checked.append("Fit to Curves puts the limit on the curves (extrude %s m, revolve %s m, loft %s m; unfitted %.2f mm inside)" % [_sci(worst), _sci(worst_revolve), _sci(worst_loft), inside * 1000.0])
	# What one live preview costs (a tool run with Fit to Curves; reported, not a limit).
	var costs := PackedStringArray()
	for spec in [["extrude", _base_extrude({"profile": [_profile(circle_sketch, Vector2.ZERO)], "fit": true})],
			["loft", {"profiles": sections, "guide": "none", "closed": false, "length_faces": 2, "width_faces": 8, "spacing": "uniform", "start": "free", "end": "free", "fit": true, "body": "new"}],
			["pipe", _pipe_values({"fit": true})]]:
		var started := Time.get_ticks_usec()
		for i in 5:
			FORM_TOOLS.run(spec[0], _ctx(), {}, spec[1])
		costs.append("%s %.1f ms" % [spec[0], (Time.get_ticks_usec() - started) / 5000.0])
	checked.append("one preview with the fit: " + ", ".join(costs))


# --- Less common paths ---------------------------------------------------------------------------

func _check_more() -> void:
	# A closed profile with a side on the axis opens there: poles at both ends of that side.
	var cyl := _run("revolve", {"profile": [_profile(rect_axis_sketch, Vector2(5, 10) * MM)], "axis": [{"kind": "origin", "name": "y"}], "type": "full",
		"spacing": "uniform", "profile_faces": 8, "around_faces": 8, "weld": true, "symmetry": "none", "keep_creases": true, "fit": false, "body": "new"}, "Revolve of a rectangle on the axis")
	# 8 faces over 10/20/10/20 mm: 1/3/1/3, the axis side dropped: 5 segments, 6 points, 2 poles.
	_expect_counts(cyl, Vector3i(34, 72, 40), "The rectangle revolved round its side")
	if not cyl.is_empty():
		_expect(CAGE.topology(cyl).is_closed() and CAGE.signed_volume(cyl) > 0.0 and _crease_count(cyl) == 16,
			"It should be closed, outward, with the 2 rings through the outer corners creased (%d)." % _crease_count(cyl))
	# A sweep round the corner of an L path: the ring on the corner mitred and creased.
	var sweep_values := {"profile": [_profile(l_profile_sketch, Vector2.ZERO)], "path": [_curve(l_sketch, l_lines[0]), _curve(l_sketch, l_lines[1])],
		"profile_faces": 8, "profile_spacing": "uniform", "path_faces": 4, "path_spacing": "uniform", "orientation": "perpendicular", "extent": 1.0,
		"keep_creases": true, "fit": false, "body": "new"}
	var bend := _run("sweep", sweep_values, "Sweep round the L")
	_expect_counts(bend, Vector3i(40, 72, 32), "The sweep round the L (8 round, 2 + 2 along)")
	if not bend.is_empty():
		var corner := Vector3(0.22, 0, 0)
		var mitre := Vector3(1, 1, 0).normalized()
		var on_plane := 0
		var reach := 0.0
		for p in CAGE.positions_v3(bend):
			if absf((p - corner).dot(mitre)) < 1e-7 and p.distance_to(corner) < 0.005:
				on_plane += 1
				reach = maxf(reach, p.distance_to(corner))
		_expect(on_plane == 8 and absf(reach - 0.003 / cos(PI / 4.0)) < 1e-6, "The corner ring should lie on the mitre plane, stretched 1/cos 45 (%d points, reach %s m)." % [on_plane, reach])
		_expect(_crease_count(bend) == 8, "Keep Creases should crease the corner ring (%d)." % _crease_count(bend))
	# A sweep along a closed circle closes into a ring.
	var ring := _run("sweep", {"profile": [_profile(ring_profile_sketch, Vector2.ZERO)], "path": [_curve(ring_sketch, ring_id)], "profile_faces": 8,
		"profile_spacing": "uniform", "path_faces": 8, "path_spacing": "uniform", "orientation": "perpendicular", "extent": 1.0, "keep_creases": true,
		"fit": false, "body": "new"}, "Sweep along a circle")
	_expect_counts(ring, Vector3i(64, 128, 64), "The sweep along the closed circle")
	if not ring.is_empty():
		_expect(CAGE.topology(ring).is_closed() and CAGE.signed_volume(ring) > 0.0, "The closed sweep should be a closed outward ring.")
	var torus := _run("pipe", _pipe_values({"path": [_curve(ring_sketch, ring_id)]}), "Pipe along a circle")
	# 125.7 mm / 10 mm: 13 segments round, closed.
	_expect_counts(torus, Vector3i(104, 208, 104), "The pipe along the closed circle")
	if not torus.is_empty():
		_expect(CAGE.topology(torus).is_closed() and CAGE.signed_volume(torus) > 0.0, "The closed pipe should be a closed outward ring.")
	# Loft guides: a centerline and a rail keep the counts and the sections.
	var sections := []
	for i in 3:
		sections.append(_profile(loft_sketches[i], Vector2.ZERO))
	for guide in [["centerline", {"centerline": [_curve(guide_sketch, centerline_id)]}], ["rails", {"rails": [_curve(guide_sketch, rail_id)]}]]:
		var values := {"profiles": sections, "guide": guide[0], "closed": false, "length_faces": 2, "width_faces": 8, "spacing": "uniform",
			"start": "free", "end": "free", "fit": false, "body": "new"}
		values.merge(guide[1], true)
		var guided := _run("loft", values, "Loft with a %s" % guide[0])
		_expect_counts(guided, Vector3i(40, 72, 32), "The loft with a %s" % guide[0])
		if not guided.is_empty():
			var on := 0
			for p in CAGE.positions_v3(guided):
				if absf(p.z - 0.08) < 1e-7 and absf(Vector2(p.x, p.y).length() - 0.015) < 1e-6:
					on += 1
			_expect(on == 8, "The loft with a %s should keep its middle section (%d of 8)." % [guide[0], on])
	checked.append("revolve of a rectangle on the axis 34/72/40 (closed, 2 creased rings), sweep round an L 40/72/32 with the corner ring on the mitre plane and creased, closed sweep 64/128/64 and closed pipe 104/208/104, loft with a centerline or a rail keeps 40/72/32 and its sections")


# --- Face ----------------------------------------------------------------------------------------

func _check_face() -> void:
	var square := [{"point": Vector3(0, 0, 0), "body": "", "vertex": -1}, {"point": Vector3(0.01, 0, 0), "body": "", "vertex": -1},
		{"point": Vector3(0.01, 0.01, 0), "body": "", "vertex": -1}, {"point": Vector3(0, 0.01, 0), "body": "", "vertex": -1}]
	var r := FORM_TOOLS.run("face", _ctx(), {"corners": square}, {"mode": "simple", "sides": "four"})
	_expect(bool(r.ok) and (r.new_bodies as Array).size() == 1, "Four free corners should make a new body (%s)." % r.error)
	if not bool(r.ok):
		return
	var first: Dictionary = r.new_bodies[0]
	_expect_counts(first, Vector3i(4, 4, 1), "One face from four clicks")
	var topo := CAGE.topology(first)
	_expect(topo.face_normal(first, 0).z > 0.9, "A standalone face should face the camera (+Z here).")
	var cages := {"Body1": first}
	# Edge mode: the edge (1, 2) plus two clicks beyond it.
	var edge_corners := [{"point": Vector3(0.02, 0.01, 0), "body": "", "vertex": -1}, {"point": Vector3(0.02, 0, 0), "body": "", "vertex": -1}]
	r = FORM_TOOLS.run("face", _ctx(cages), {"edge": {"body": "Body1", "pair": Vector2i(1, 2)}, "corners": edge_corners}, {"mode": "edge"})
	_expect(bool(r.ok) and (r.cages as Dictionary).has("Body1"), "Edge mode should add a face to the body (%s)." % r.error)
	if bool(r.ok):
		var two: Dictionary = r.cages.Body1
		_expect_counts(two, Vector3i(6, 7, 2), "Edge mode: the second face shares the edge")
		var t2 := CAGE.topology(two)
		_expect(t2.face_normal(two, 1).z > 0.9, "The new face should agree with its neighbour's orientation.")
		cages["Body1"] = two
	# Simple mode with snapped corners joining two bodies.
	var other := CAGE.from_vectors(PackedVector3Array([Vector3(0, 0.02, 0), Vector3(0.01, 0.02, 0), Vector3(0.01, 0.03, 0), Vector3(0, 0.03, 0)]), [[0, 1, 2, 3]])
	cages["Body2"] = other
	var join := [{"point": Vector3(0, 0.01, 0), "body": "Body1", "vertex": 3}, {"point": Vector3(0.01, 0.01, 0), "body": "Body1", "vertex": 2},
		{"point": Vector3(0.01, 0.02, 0), "body": "Body2", "vertex": 1}, {"point": Vector3(0, 0.02, 0), "body": "Body2", "vertex": 0}]
	r = FORM_TOOLS.run("face", _ctx(cages), {"corners": join}, {"mode": "simple", "sides": "four"})
	_expect(bool(r.ok) and (r.cages as Dictionary).has("Body1") and (r.removed_bodies as Array) == ["Body2"], "A face on two bodies should join them (%s, %s)." % [r.error, r.get("removed_bodies")])
	if bool(r.ok):
		var joined: Dictionary = r.cages.Body1
		_expect_counts(joined, Vector3i(10, 13, 4), "The joined body")
		_expect(CAGE.topology(joined).components().size() == 4 and CAGE.topology(joined).component_count() == 1, "The joined body should be one piece.")
	# Chain mode: the open edges along x = 0.02 extended 10 mm further.
	var chain := {"body": "Body1", "pairs": PackedInt32Array([4, 5]), "start": 4}
	r = FORM_TOOLS.run("face", _ctx(cages), {"chain": chain, "offset": Vector3(0.03, 0, 0)}, {"mode": "chain"})
	_expect(bool(r.ok), "Chain mode should extend the open edge (%s)." % r.error)
	if bool(r.ok):
		var ext: Dictionary = r.cages.Body1
		_expect_counts(ext, Vector3i(8, 10, 3), "Chain mode: one more face beyond the edge")
		var moved := 0
		for q in CAGE.positions_v3(ext):
			if absf(q.x - 0.03) < 1e-9:
				moved += 1
		_expect(moved == 2, "The new row should sit at the offset point (%d)." % moved)
	var bad := [{"point": Vector3(0, 0, 0), "body": "", "vertex": -1}, {"point": Vector3(0.01, 0, 0), "body": "", "vertex": -1}, {"point": Vector3(0.02, 0, 0), "body": "", "vertex": -1}]
	r = FORM_TOOLS.run("face", _ctx(), {"corners": bad}, {"mode": "simple", "sides": "multiple"})
	_expect(not bool(r.ok), "Three corners on a line should be refused.")
	checked.append("Face: four clicks make a new 4/4/1 body facing the camera, Edge mode 6/7/2 agreeing with its neighbour, snapped corners join two bodies (10/13/4, one piece), Chain mode 8/10/3 at the offset")


# --- Headless workspace --------------------------------------------------------------------------

func _check_workspace() -> void:
	var ws: Control = WORKSPACE.new()
	root.add_child(ws)
	ws.size = Vector2(1400, 900)
	for i in 3:
		await process_frame
	var part: Node3D = CAD_PART.new()
	part.document = doc
	root.add_child(part)
	ws.set_part(part)
	await process_frame
	var f: Resource = ws.create_form()
	_expect(f != null and ws.form_editor.active, "Create Form should open a form.")
	if f == null:
		ws.queue_free()
		part.queue_free()
		return
	var editor: RefCounted = ws.form_editor
	editor.start_tool("extrude")
	_expect(editor.tool == "extrude" and ws.panel.visible and ws.panel.active_selection_key == "profile", "Extrude should open its panel with the Profile slot active (%s)." % ws.panel.active_selection_key)
	_expect(ws._active_kinds().has("profile"), "The picker should take profiles while the slot is active (%s)." % [ws._active_kinds()])
	# A pick through the workspace's picker path lands in the slot and previews.
	ws._on_reference_picked(_profile(circle_sketch, Vector2.ZERO))
	_expect((editor.tool_values.get("profile", []) as Array).size() == 1, "The picked profile should land in the Profile slot.")
	_expect(not (editor._preview as Dictionary).is_empty(), "The pick should preview the extrude (%s)." % ws.last_message)
	var steps_before: String = str(ws.last_step.get("name", ""))
	var model_before: Dictionary = ws._model_of(doc.snapshot())
	editor.tool_ok()
	await process_frame
	f = doc.find_feature(f.id)
	var bodies: Dictionary = f.options.bodies
	_expect(str(ws.last_step.get("name", "")) == "Form: Extrude" and steps_before == "Create Form", "OK should record one step named Form: Extrude (%s)." % ws.last_step.get("name", ""))
	_expect(ws._model_of(ws.last_step.get("before", {})) == model_before, "Form: Extrude should be exactly one step.")
	_expect(bodies.size() == 1 and _counts(bodies.values()[0]) == Vector3i(16, 24, 8), "The extrude should add one 16/24/8 body (%s)." % [bodies.keys()])
	_expect(editor.tool == "" and ws._active_kinds().is_empty(), "After OK the tool and its pick slot should close.")
	checked.append("workspace: Extrude's Profile slot takes a picked profile, previews, and OK is one step Form: Extrude")
	ws.run_action("finish_form")
	await process_frame
	ws.set_part(null)
	ws.queue_free()
	part.queue_free()
	await process_frame
