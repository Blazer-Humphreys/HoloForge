extends SceneTree
## Holo Forge kernel solid operations against their exact volumes: extrude (plain, two sides,
## tapered), revolve, sweep (straight, scaled, twisted), loft (prism, pyramid), torus, coil,
## pipe, thread groove, fillet (constant, variable, chord), chamfer (equal, two-distance,
## distance-angle), shell (open and closed), draft, scale, offset face, split body and faces,
## thicken, boundary fill and rib; plus persistent names: extrude faces are named after their
## sketch entities, and a fillet's edge keeps its name when the profile is resized.
##
## godot --headless --path . --script res://tests/holo_forge_solid_ops_test.gd

var failures: Array[String] = []
var k


func _init() -> void:
	call_deferred("run")


func run() -> void:
	k = ClassDB.instantiate("CadKernel") if ClassDB.class_exists("CadKernel") else null
	_expect(k != null, "The native kernel should load.")
	if k != null:
		_check_create()
		_check_modify()
		_check_names()
		_check_fitted_curves()
		_check_fitted_sweeps()
		_check_blends()
		_check_round_loft_starts()
		_check_round8_measures()
		_check_round9_sweeps()
	print("PASS holo_forge_solid_ops: every solid operation matches its analytic volume, names survive a resize, helices and spirals keep to their surfaces, coils, pipes, threads, sweeps and twisted sweeps are exact to a millionth at any size, fillets and chamfers round a dome's rim exactly, and round loops loft without twisting wherever they start; booleans that come out wrong are refused, twisted sweeps, the inner coil triangle, polygon lofts from any corner or facing either way and small three-circle lofts are exact." if failures.is_empty() else "FAIL holo_forge_solid_ops")
	quit(0 if failures.is_empty() else 1)


func _rect_profile(w: float, h: float, entity_base := 10) -> RefCounted:
	var curves := [
		{"type": "line", "a": Vector2(0, 0), "b": Vector2(w, 0), "entity": entity_base},
		{"type": "line", "a": Vector2(w, 0), "b": Vector2(w, h), "entity": entity_base + 1},
		{"type": "line", "a": Vector2(w, h), "b": Vector2(0, h), "entity": entity_base + 2},
		{"type": "line", "a": Vector2(0, h), "b": Vector2(0, 0), "entity": entity_base + 3},
	]
	# On the XY plane (normal +Z).
	return k.sketch_regions(curves, Transform3D.IDENTITY)[0].face


func _close(shape, expected: float, label: String, tolerance := 1e-9) -> void:
	var v: float = shape.volume() if shape != null else -1.0
	_expect(shape != null and absf(v - expected) < tolerance, "%s: volume should be %.10f (got %s; %s)" % [label, expected, v if shape != null else "null", k.get_last_error()])


func _check_create() -> void:
	var rect := _rect_profile(0.04, 0.02)
	_close(k.extrude(rect, {"direction": Vector3.BACK, "distance": 0.01, "tag": "E1"}), 8e-6, "Extrude")
	_close(k.extrude(rect, {"direction": Vector3.BACK, "distance": 0.01, "distance2": 0.005, "tag": "E2"}), 1.2e-5, "Two-sided extrude")
	var taper := deg_to_rad(10.0)
	var h := 0.01
	var inset := h * tan(taper)
	# The far end is a narrower rectangle (not a scaled copy): prismatoid volume h/6 (A1 + 4 Am + A2).
	var frustum := h / 6.0 * (0.0008 + 4.0 * (0.04 - inset) * (0.02 - inset) + (0.04 - 2.0 * inset) * (0.02 - 2.0 * inset))
	_close(k.extrude(rect, {"direction": Vector3.BACK, "distance": h, "taper": taper, "tag": "E3"}), frustum, "Tapered extrude", 1e-10)
	# A 10 x 20 mm rectangle 30 mm from the Y axis, revolved fully: 2 pi r A.
	var off_axis: RefCounted = k.sketch_regions([
		{"type": "line", "a": Vector2(0.03, 0), "b": Vector2(0.04, 0)}, {"type": "line", "a": Vector2(0.04, 0), "b": Vector2(0.04, 0.02)},
		{"type": "line", "a": Vector2(0.04, 0.02), "b": Vector2(0.03, 0.02)}, {"type": "line", "a": Vector2(0.03, 0.02), "b": Vector2(0.03, 0)},
	], Transform3D.IDENTITY)[0].face
	_close(k.revolve(off_axis, {"axis_origin": Vector3.ZERO, "axis": Vector3.UP, "tag": "R1"}), TAU * 0.035 * 0.0002, "Revolve", 1e-10)
	_close(k.revolve(off_axis, {"axis_origin": Vector3.ZERO, "axis": Vector3.UP, "angle": PI * 0.5, "tag": "R2"}), TAU * 0.035 * 0.0002 * 0.25, "Quarter revolve", 1e-10)

	var disk: RefCounted = k.sketch_regions([{"type": "circle", "c": Vector2.ZERO, "r": 0.005}], Transform3D.IDENTITY)[0].face
	var straight: RefCounted = k.sketch_wire([{"type": "line", "a": Vector2.ZERO, "b": Vector2(0, 0.05)}], Transform3D(Basis(Vector3.RIGHT, Vector3.BACK, Vector3.DOWN), Vector3.ZERO))
	_close(k.sweep(disk, straight, {"tag": "S1"}), PI * 2.5e-5 * 0.05, "Straight sweep", 1e-10)
	_close(k.sweep(disk, straight, {"tag": "S2", "scale": 2.0}), PI * 0.05 / 3.0 * (2.5e-5 + 1e-4 + 5e-5), "Scaled sweep (cone frustum)", 1e-9)
	var square: RefCounted = _rect_profile(0.01, 0.01)
	var twisted = k.sweep(square, straight, {"tag": "S3", "twist": PI * 0.5})
	_close(twisted, 1e-4 * 0.05, "Twisted sweep keeps its cross-section", 2e-8)

	var top: RefCounted = k.sketch_regions([
		{"type": "line", "a": Vector2(0, 0), "b": Vector2(0.01, 0)}, {"type": "line", "a": Vector2(0.01, 0), "b": Vector2(0.01, 0.01)},
		{"type": "line", "a": Vector2(0.01, 0.01), "b": Vector2(0, 0.01)}, {"type": "line", "a": Vector2(0, 0.01), "b": Vector2(0, 0)},
	], Transform3D(Basis.IDENTITY, Vector3(0, 0, 0.02)))[0].face
	_close(k.loft([square, top], {"tag": "L1", "ruled": true}), 1e-4 * 0.02, "Loft between equal squares", 1e-10)
	_close(k.loft([square, k.make_vertex(Vector3(0.005, 0.005, 0.03))], {"tag": "L2"}), 1e-4 * 0.03 / 3.0, "Loft to a point (pyramid)", 1e-10)

	_close(k.torus({"major_radius": 0.02, "minor_radius": 0.005, "tag": "T1"}), 2.0 * PI * PI * 0.02 * 0.000025, "Torus", 1e-10)
	# The section lies in the plane through the axis and turns with it: 2 pi rbar A a turn (its area
	# times the helix's length is 0.2 % more, which a tolerance of 0.3 % used to hide).
	var coil = k.coil({"diameter": 0.02, "pitch": 0.004, "turns": 3.0, "section_size": 0.002, "tag": "C1"})
	var coil_volume := TAU * 0.01 * PI * 0.000001 * 3.0
	_close(coil, coil_volume, "Coil (2 pi rbar A turns)", coil_volume * 1e-6)
	var path: RefCounted = k.sketch_wire([{"type": "arc", "c": Vector2.ZERO, "r": 0.05, "a0": 0.0, "a1": PI * 0.5}], Transform3D.IDENTITY)
	var bend = k.pipe(path, {"size": 0.01, "tag": "P1"})
	_close(bend, PI * 2.5e-5 * 0.05 * PI * 0.5, "Pipe along a quarter circle", 1e-9)
	var hollow = k.pipe(path, {"size": 0.01, "hollow": true, "thickness": 0.001, "tag": "P2"})
	_close(hollow, PI * (2.5e-5 - 1.6e-5) * 0.05 * PI * 0.5, "Hollow pipe", 1e-9)
	var groove = k.thread({"radius": 0.005, "pitch": 0.001, "length": 0.01, "depth": 0.0006, "tag": "TH"})
	_expect(groove != null and groove.volume() > 0.0 and groove.bbox().size.y > 0.0095, "A thread groove should run the full length (%s)." % [k.get_last_error()])


func _check_modify() -> void:
	var box = k.make_box(Vector3(0.04, 0.02, 0.03), Vector3.ZERO, "B")
	var long_edge := _edge_along(box, Vector3.FORWARD, 0.03)
	_close(k.fillet(box, PackedInt32Array([long_edge]), {"radius": 0.005, "tag": "F1"}), 2.4e-5 - (1.0 - PI / 4.0) * 0.000025 * 0.03, "Fillet")
	var variable = k.fillet(box, PackedInt32Array([long_edge]), {"radius": 0.002, "radius2": 0.006, "type": "variable", "tag": "F2"})
	_expect(variable != null and variable.volume() < 2.4e-5 and variable.volume() > 2.4e-5 - (1.0 - PI / 4.0) * 0.000036 * 0.03, "A variable fillet removes between its end radii' amounts.")
	_close(k.fillet(box, PackedInt32Array([long_edge]), {"radius": 0.005 * sqrt(2.0), "type": "chord", "tag": "F3"}), 2.4e-5 - (1.0 - PI / 4.0) * 0.000025 * 0.03, "Chord-length fillet")
	_close(k.chamfer(box, PackedInt32Array([long_edge]), {"distance": 0.004, "tag": "C1"}), 2.4e-5 - 0.5 * 0.000016 * 0.03, "Equal chamfer")
	_close(k.chamfer(box, PackedInt32Array([long_edge]), {"distance": 0.004, "distance2": 0.002, "type": "two", "tag": "C2"}), 2.4e-5 - 0.5 * 0.000008 * 0.03, "Two-distance chamfer")
	_close(k.chamfer(box, PackedInt32Array([long_edge]), {"distance": 0.004, "angle": PI * 0.25, "type": "angle", "tag": "C3"}), 2.4e-5 - 0.5 * 0.000016 * 0.03, "Distance-angle chamfer")

	var top := _face_facing(box, Vector3.UP)
	_close(k.shell(box, PackedInt32Array([top]), {"thickness": 0.002, "tag": "SH"}), 2.4e-5 - 0.036 * 0.018 * 0.026, "Open shell", 1e-10)
	_close(k.shell(box, PackedInt32Array(), {"thickness": 0.002, "tag": "SH2"}), 2.4e-5 - 0.036 * 0.016 * 0.026, "Closed hollow shell", 1e-10)
	_close(k.shell(box, PackedInt32Array([top]), {"thickness": 0.002, "direction": "outside", "tag": "SH3"}), 0.044 * 0.022 * 0.034 - 2.4e-5, "Outside shell", 1e-10)

	var side := _face_facing(box, Vector3.RIGHT)
	var drafted = k.draft(box, PackedInt32Array([side]), {"angle": deg_to_rad(5.0), "pull": Vector3.UP, "neutral_origin": Vector3.ZERO, "neutral_normal": Vector3.UP, "tag": "D1"})
	_close(drafted, 2.4e-5 - 0.5 * 0.02 * (0.02 * tan(deg_to_rad(5.0))) * 0.03, "Draft (5 degrees, neutral plane at the bottom)", 1e-10)

	_close(k.transform_shape(box, Transform3D(Basis.from_scale(Vector3(2, 1, 0.5)), Vector3.ONE), "SC"), 2.4e-5, "Non-uniform scale (2 x 1 x 0.5)")
	_close(k.transform_shape(box, Transform3D(Basis.from_scale(Vector3.ONE * 2.0), Vector3.ZERO), "SC2"), 2.4e-5 * 8.0, "Uniform scale x2")
	_close(k.offset_faces(box, PackedInt32Array([top]), 0.005, "OF"), 2.4e-5 + 0.04 * 0.03 * 0.005, "Offset face outward")
	_close(k.offset_faces(box, PackedInt32Array([top]), -0.005, "OF2"), 2.4e-5 - 0.04 * 0.03 * 0.005, "Offset face inward")

	var halves = k.split_body(box, k.plane_face(Vector3(0.01, 0, 0), Vector3.RIGHT, 1.0, "cut"), {"tag": "SP"})
	var parts: Array = halves.solids() if halves != null else []
	_expect(parts.size() == 2 and absf(float(parts[0].volume()) + float(parts[1].volume()) - 2.4e-5) < 1e-11, "Split Body by a plane should give two solids that add up (%s, %s; %s)." % [parts.map(func(p) -> float: return p.volume()), halves.shape_type() if halves != null else "null", k.get_last_error()])
	var split = k.split_faces(box, PackedInt32Array([top]), k.plane_face(Vector3(0.02, 0, 0), Vector3.RIGHT, 1.0, "line"), "SF")
	_expect(split != null and split.face_count() == 7 and split.solid_count() == 1, "Split Face should divide the top face and keep one solid (%s faces)." % (split.face_count() if split != null else -1))
	_close(k.thicken(box, PackedInt32Array([top]), {"thickness": 0.003, "tag": "TK"}), 0.04 * 0.03 * 0.003, "Thicken a face")

	var slab_a = k.plane_face(Vector3(0, 0.01, 0), Vector3.UP, 1.0, "a")
	var fill = k.boundary_fill([box, slab_a], PackedVector3Array([Vector3(0.02, 0.015, 0.015)]), "BF")
	_close(fill, 0.04 * 0.01 * 0.03, "Boundary fill keeps the cell above the plane")

	var cup = k.shell(box, PackedInt32Array([top]), {"thickness": 0.002, "tag": "CUP"})
	# A rib drawn as a line 12 mm up, wall to wall, in the cup's middle (z = 15 mm) plane: it grows
	# down to the floor (2 mm) between the walls, 2 mm thick.
	var rib_wire: RefCounted = k.sketch_wire([{"type": "line", "a": Vector2(0.002, 0.012), "b": Vector2(0.038, 0.012)}],
		Transform3D(Basis(Vector3.RIGHT, Vector3.UP, Vector3.BACK), Vector3(0, 0, 0.015)))
	var ribbed = k.rib(cup, rib_wire, {"plane_origin": Vector3(0, 0, 0.015), "plane_normal": Vector3.BACK, "thickness_direction": Vector3.BACK, "thickness": 0.002, "tag": "RB"})
	_expect(ribbed != null and absf(ribbed.volume() - cup.volume() - 0.036 * 0.010 * 0.002) < 1e-9,
		"A rib inside the cup should add a 36 x 10 x 2 mm wall (added %s; %s)." % [(ribbed.volume() - cup.volume()) if ribbed != null else "null", k.get_last_error()])


func _check_names() -> void:
	# Extrude faces are named after the sketch lines that made them; a fillet's edge keeps its name
	# when the profile gets bigger.
	var small = k.extrude(_rect_profile(0.04, 0.02), {"direction": Vector3.BACK, "distance": 0.01, "tag": "E"})
	var names: PackedStringArray = small.get_face_names()
	_expect(names.has("E:start") and names.has("E:end") and names.has("E:g(s10)") and names.has("E:g(s13)"), "Extrude faces should be named start, end and after their lines (%s)." % [names])
	var edge_name := "E:end|E:g(s11)"
	var edge: int = small.find_edge(edge_name)
	_expect(edge >= 0, "The edge between the end cap and line s11's face should be findable by name (%s)." % [small.get_edge_names()])
	var big = k.extrude(_rect_profile(0.08, 0.05), {"direction": Vector3.BACK, "distance": 0.01, "tag": "E"})
	var same: int = big.find_edge(edge_name)
	var info: Dictionary = big.edge_info(same) if same >= 0 else {}
	_expect(same >= 0 and absf(float(info.get("length", 0.0)) - 0.05) < 1e-7 and absf((info.midpoint as Vector3).x - 0.08) < 1e-7,
		"After resizing, the same name should find the right-hand end edge (%s)." % info)
	var rounded = k.fillet(big, PackedInt32Array([same]), {"radius": 0.003, "tag": "F"})
	var fillet_faces: Array = Array(rounded.get_face_names()).filter(func(n: String) -> bool: return n.begins_with("F:g("))
	_expect(fillet_faces.size() == 1 and rounded.find_face("E:start") >= 0, "The fillet face is named after its edge, and the other faces keep their names (%s)." % [rounded.get_face_names()])
	var cut = k.boolean(big, k.make_box(Vector3(0.01, 0.01, 0.03), Vector3(0.02, 0.02, -0.01), "H"), 1, "CUT")
	_expect(cut != null and cut.find_face("E:end") >= 0 and Array(cut.get_face_names()).any(func(n: String) -> bool: return n.begins_with("H:")),
		"After a cut the body keeps its names and gains the tool's faces (%s)." % [cut.get_face_names() if cut != null else "null"])


# --- What OCCT approximates, fitted to the part's size ------------------------------------------

## The exact length of a helix of radius r (at its base, for a cone), pitch p, n turns.
func _helix_length(r: float, p: float, n: float, taper := 0.0) -> float:
	if taper == 0.0:
		return n * sqrt(pow(TAU * r, 2) + p * p)
	var rise := p / cos(taper)
	var total := 0.0
	var steps := 20000
	for i in steps:
		var t := n * (i + 0.5) / steps
		var radius := r + rise * t * sin(taper)
		total += sqrt(radius * radius * TAU * TAU + rise * rise) * n / steps
	return total


## The area a section in the plane through the axis sweeps in one turn of a screw rising h a radian
## (2 pi âˆ« sqrt(rho^2 + h^2 (d rho / dl)^2) dl): a square of side a centred rbar from the axis.
func _screw_square(rbar: float, a: float, h: float) -> float:
	var f := func(rho: float) -> float: return 0.5 * (rho * sqrt(rho * rho + h * h) + h * h * log(rho + sqrt(rho * rho + h * h)))
	return TAU * (2.0 * (f.call(rbar + a * 0.5) - f.call(rbar - a * 0.5)) + 2.0 * a * rbar)


## The same for a circle of radius s centred rbar from the axis (periodic: the trapezoid rule is
## exact to rounding).
func _screw_circle(rbar: float, s: float, h: float) -> float:
	var steps := 2000
	var total := 0.0
	for i in steps:
		var phi := TAU * i / steps
		var rho := rbar + s * cos(phi)
		total += sqrt(rho * rho + h * h * sin(phi) * sin(phi)) * s * TAU / steps
	return TAU * total


## Helices keep to their cylinder or cone, and a flat spiral to its curve, within 1e-8 m (or a
## ten-millionth of a big radius), with their lengths to 1e-7: OCCT's default fit put a 10 mm helix
## 7 um off its cylinder and a 200-turn one 30 mm off, the spiral (a curve through 64 points a
## turn) was 77 nm off, and a 0.5 mm helix's length never came back. (Points are single precision.)
func _check_fitted_curves() -> void:
	var mm := 0.001
	for spec in [[10.0, 4.0, 3.0, 0.0], [10.0, 4.0, 3.0, deg_to_rad(10.0)], [10.0, 0.5, 200.0, 0.0], [0.5, 0.2, 3.0, 0.0]]:
		var r: float = spec[0] * mm
		var p: float = spec[1] * mm
		var n: float = spec[2]
		var taper: float = spec[3]
		var helix = k.helix({"radius": r, "pitch": p, "turns": n, "axis": Vector3(0, 0, 1), "taper": taper})
		var worst := INF
		var length := -1.0
		if helix != null:
			worst = 0.0
			var samples := int(maxf(3000.0, n * 100.0))
			for i in samples + 1:
				var q: Vector3 = helix.edge_point_at(0, float(i) / samples).point
				worst = maxf(worst, absf((Vector2(q.x, q.y).length() - (r + q.z * tan(taper))) * cos(taper)))
			length = float(helix.edge_info(0).length)
		var want := _helix_length(r, p, n, taper)
		_expect(worst <= maxf(1e-8, 1e-7 * r) and absf(length - want) <= 1e-7 * want,
			"A helix r %s mm, %s turns, taper %.0f deg should keep within 1e-8 m of its %s and be %.6f mm long (%s m off, %.6f mm)." % [spec[0], n, rad_to_deg(taper), "cone" if taper != 0.0 else "cylinder", want / mm, worst, length / mm])
	# A flat spiral: radius 10 mm growing 5 mm a turn, 2 turns.
	var spiral = k.helix({"radius": 10 * mm, "pitch": 5 * mm, "turns": 2.0, "axis": Vector3(0, 0, 1), "spiral": true})
	var off := INF
	if spiral != null:
		off = 0.0
		var angle := 0.0
		var before := 0.0
		for i in 8001:
			var q: Vector3 = spiral.edge_point_at(0, i / 8000.0).point
			var a := atan2(q.y, q.x)
			if i > 0:
				angle += wrapf(a - before, -PI, PI)
			before = a
			off = maxf(off, absf(Vector2(q.x, q.y).length() - (10 * mm + 5 * mm * angle / TAU)))
	# Its length, (F(r1) - F(r0)) / a with a = pitch / 2 pi, F(r) = (r s + a^2 ln(r + s)) / 2, s = sqrt(r^2 + a^2).
	var rise := 5 * mm / TAU
	var big_f := func(r: float) -> float: return 0.5 * (r * sqrt(r * r + rise * rise) + rise * rise * log(r + sqrt(r * r + rise * rise)))
	var spiral_length: float = (big_f.call(20 * mm) - big_f.call(10 * mm)) / rise
	var spiral_got: float = spiral.edge_info(0).length if spiral != null else -1.0
	_expect(off <= 1e-8 and absf(spiral_got - spiral_length) <= 1e-7 * spiral_length,
		"A flat spiral should keep within 1e-8 m of its curve and be %.6f mm long (%s m off, %.6f mm)." % [spiral_length / mm, off, spiral_got / mm])


## Coils, pipes, threads and sweeps are fitted to a ten-millionth of their profile and exact to a
## millionth at any size: OCCT's default fit (0.1 mm) put a 10 mm coil 0.02 % short, a 0.5 mm one
## 0.35 %, a 100-turn one at half its volume, a thread groove 0.03 % over, a circle swept along a
## spline 0.1 % over and a twisted sweep 0.004 % over.
func _check_fitted_sweeps() -> void:
	var mm := 0.001
	for scale in [1.0, 0.05, 50.0]:
		var r: float = 10.0 * mm * scale
		var p: float = 4.0 * mm * scale
		var size: float = 2.0 * mm * scale
		for section in ["square", "circle"]:
			for surface in [false, true]:
				var coil = k.coil({"diameter": 2.0 * r, "pitch": p, "turns": 3.0, "section_size": size, "section": section, "axis": Vector3(0, 0, 1), "surface": surface})
				# The section turns with the plane through the axis: 2 pi rbar A a turn, or as a
				# surface, the area its outline sweeps.
				var want: float = TAU * r * (size * size if section == "square" else PI * size * size * 0.25) * 3.0
				if surface:
					want = 3.0 * (_screw_square(r, size, p / TAU) if section == "square" else _screw_circle(r, size * 0.5, p / TAU))
				var got: float = (coil.area() if surface else coil.volume()) if coil != null else -1.0
				_expect(absf(got - want) <= 1e-6 * want, "A %s-section coil %s mm across (%s) should be exact to a millionth (%s, want %s; %s)." % [section, 20.0 * scale, "area" if surface else "volume", got, want, k.get_last_error()])
	var many = k.coil({"diameter": 0.02, "pitch": 0.002, "turns": 100.0, "section_size": 0.001, "section": "square", "axis": Vector3(0, 0, 1)})
	var long_volume := TAU * 0.01 * 1e-6 * 100.0
	_close(many, long_volume, "A 100-turn coil (2 pi rbar A turns)", long_volume * 1e-6)
	var helix = k.helix({"radius": 0.01, "pitch": 0.004, "turns": 3.0, "axis": Vector3(0, 0, 1)})
	var length := _helix_length(0.01, 0.004, 3.0)
	var pipe = k.pipe(helix, {"size": 0.002})
	_close(pipe, PI * 1e-6 * length, "A 2 mm pipe along a helix (A L)", PI * 1e-6 * length * 1e-6)
	var skin := TAU * 1e-3 * length + TAU * 1e-6
	_expect(pipe != null and absf(pipe.area() - skin) <= 1e-6 * skin, "The pipe along the helix should have an area of 2 pi r L + 2 pi r^2 (%s, want %s)." % [pipe.area() if pipe != null else -1.0, skin])
	var depth := 0.0006
	var groove = k.thread({"radius": 0.005, "pitch": 0.001, "length": 0.01, "depth": depth, "axis": Vector3(0, 0, 1)})
	var half_base := minf(depth * tan(PI / 6.0), 0.00045)
	var outer := 0.005 + depth * 0.1
	var tip := 0.005 - depth
	var groove_volume := TAU * (2.0 * outer + tip) / 3.0 * half_base * (outer - tip) * 10.0
	_close(groove, groove_volume, "A thread groove (its V screwed round: 2 pi rbar A turns)", groove_volume * 1e-6)
	# A 2 mm circle swept along a planar spline, and a square swept straight with a twist (and a
	# scale): each section's area along the path.
	var xz := Transform3D(Basis(Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(0, -1, 0)), Vector3.ZERO)
	var disc: RefCounted = k.sketch_regions([{"type": "circle", "c": Vector2.ZERO, "r": 0.002}], Transform3D.IDENTITY)[0].face
	var path = k.sketch_edges([{"type": "interp", "points": PackedVector2Array([Vector2(0, 0), Vector2(5, 8) * mm, Vector2(0, 16) * mm, Vector2(-4, 24) * mm]), "periodic": false}], xz)
	var path_length := 0.0
	for e in path.edge_count():
		path_length += float(path.edge_info(e).length)
	_close(k.sweep(disc, path, {}), PI * 4e-6 * path_length, "A 2 mm circle swept along a planar spline (A L)", PI * 4e-6 * path_length * 1e-6)
	# Equal circles square to the spline at its ends, lofted along it as a centerline: a tube (to
	# 1e-5: the circles are placed by single-precision points and tangents; OCCT's default fit put
	# it 3e-4 over).
	var ends := []
	for end in [path.edge_point_at(0, 0.0), path.edge_point_at(path.edge_count() - 1, 1.0)]:
		var t: Vector3 = (end.tangent as Vector3).normalized()
		var x := t.cross(Vector3(0, 1, 0)).normalized()
		ends.append(k.sketch_regions([{"type": "circle", "c": Vector2.ZERO, "r": 0.001}], Transform3D(Basis(x, t.cross(x), t), end.point))[0].face)
	_close(k.loft(ends, {"centerline": path}), PI * 1e-6 * path_length, "Equal 1 mm circles lofted along a spline centerline (A L)", PI * 1e-6 * path_length * 1e-5)
	var straight: RefCounted = k.sketch_wire([{"type": "line", "a": Vector2.ZERO, "b": Vector2(0, 0.02)}], Transform3D(Basis(Vector3.RIGHT, Vector3.BACK, Vector3.DOWN), Vector3.ZERO))
	var square := _rect_profile(0.004, 0.004)
	for spec in [[PI / 2.0, 1.0], [PI, 1.0], [PI / 2.0, 2.0]]:
		var s: float = spec[1]
		var want := 16e-6 * 0.02 * (1.0 + s + s * s) / 3.0
		_close(k.sweep(square, straight, {"twist": spec[0], "scale": s}), want, "A 4 mm square swept 20 mm, twisted %.0f deg, scaled %s" % [rad_to_deg(spec[0]), s], want * 1e-6)


## A dome (a 10 mm ball cut by z = c mm, the part above): the ball, its rim edge.
func _dome(c: float) -> Array:
	var ball = k.make_sphere(0.01, Vector3.ZERO, "s")
	var dome = k.boolean(ball, k.make_box(Vector3(0.04, 0.04, 0.02), Vector3(-0.02, -0.02, c * 0.001), "a"), 2, "d")
	var rim := -1
	for e in dome.edge_count() if dome != null else 0:
		var info: Dictionary = dome.edge_info(e)
		if str(info.get("type", "")) == "circle" and absf((info.midpoint as Vector3).z - c * 0.001) < 1e-9:
			rim = e
	return [dome, rim]


## A meridian profile (curves in mm, in the XZ plane) turned round Z: an exact solid of revolution.
func _turned(curves: Array) -> RefCounted:
	var xz := Transform3D(Basis(Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(0, -1, 0)), Vector3.ZERO)
	var scaled := []
	for curve in curves:
		var c: Dictionary = curve.duplicate()
		for key in ["a", "b", "c"]:
			if c.has(key):
				c[key] = (c[key] as Vector2) * 0.001
		if c.has("r"):
			c.r = float(c.r) * 0.001
		scaled.append(c)
	var best = null
	for region in k.sketch_regions(scaled, xz):
		best = region.face if best == null or float(region.area) > best.area() else best
	return k.revolve(best, {"axis_origin": Vector3.ZERO, "axis": Vector3(0, 0, 1), "angle": TAU}) if best != null else null


## A fillet or a chamfer where a sphere meets a plane (none of OCCT's exact cases) is built and
## exact: OCCT's own tolerances (0.1 mm, a 1 mm marching step) refused both at any size. The
## fillet against the dome with a torus rounding its rim; the chamfer against a cone from 1 mm in
## on the plane to the sphere 1 mm (straight) from the rim.
func _check_blends() -> void:
	for spec in [[0.0, 2.0], [4.0, 1.5], [-3.0, 1.0]]:
		var c: float = spec[0]
		var r: float = spec[1]
		var dome: Array = _dome(c)
		var rounded = k.fillet(dome[0], PackedInt32Array([dome[1]]), {"radius": r * 0.001})
		var note: String = k.get_last_warning()
		# The rounding ball (radius r) inside: on z = c (centre at c + r) and inside the sphere
		# (centre 10 - r from the origin), touching it on the ray through its centre.
		var cz := c + r
		var rho := sqrt(pow(10.0 - r, 2) - cz * cz)
		var q := Vector2(rho, cz) * 10.0 / (10.0 - r)
		var exact := _turned([{"type": "line", "a": Vector2(0, c), "b": Vector2(rho, c)}, {"type": "arc", "c": Vector2(rho, cz), "r": r, "a0": -PI / 2, "a1": atan2(q.y - cz, q.x - rho)},
			{"type": "arc", "c": Vector2.ZERO, "r": 10.0, "a0": atan2(q.y, q.x), "a1": PI / 2}, {"type": "line", "a": Vector2(0, 10), "b": Vector2(0, c)}])
		var want: float = exact.volume() if exact != null else -1.0
		_close(rounded, want, "A dome cut at z = %s mm, its rim rounded %s mm (the exact dome turned)" % [c, r], want * 1e-6)
		_expect(note == "", "The rounded dome should be fitted closely (%s)." % note)
	for c in [0.0, 4.0]:
		var dome: Array = _dome(c)
		var cut = k.chamfer(dome[0], PackedInt32Array([dome[1]]), {"distance": 0.001})
		var rho := sqrt(100.0 - c * c)
		var a1 := atan2(c, rho) + 2.0 * asin(0.05)
		var q := Vector2(cos(a1), sin(a1)) * 10.0
		var exact := _turned([{"type": "line", "a": Vector2(0, c), "b": Vector2(rho - 1.0, c)}, {"type": "line", "a": Vector2(rho - 1.0, c), "b": q},
			{"type": "arc", "c": Vector2.ZERO, "r": 10.0, "a0": a1, "a1": PI / 2}, {"type": "line", "a": Vector2(0, 10), "b": Vector2(0, c)}])
		var want: float = exact.volume() if exact != null else -1.0
		_close(cut, want, "A dome cut at z = %s mm, its rim chamfered 1 mm (a cone between the exact dome's circles)" % c, want * 1e-6)


## Round loops (circles, ellipses, periodic splines) loft from where the loop before them starts,
## carried into their plane as OCCT carries corners, and run the same way round: a circle to a
## circle drawn from 70 deg twisted the loft (its volume 20 % short), a holed square's hole to a
## ring's (a hole wall of 125.58 mm2 for 141.55), and a circle drawn on a plane facing the other way
## pinched the loft to a third of its volume. Polygons of as many corners loft as they did, with
## the same names.
func _check_round_loft_starts() -> void:
	var up := Transform3D(Basis.IDENTITY, Vector3(0, 0, 0.01))
	var c5: RefCounted = k.sketch_regions([{"type": "circle", "c": Vector2.ZERO, "r": 0.005}], Transform3D.IDENTITY)[0].face
	var c3: RefCounted = k.sketch_regions([{"type": "circle", "c": Vector2.ZERO, "r": 0.003}], up)[0].face
	var frustum := PI * 0.01 / 3.0 * (25.0 + 15.0 + 9.0) * 1e-6
	var cone := PI * 0.008 * sqrt(1e-4 + 4e-6)
	for degrees in [0.0, 30.0, 90.0, 137.0, 200.0]:
		var turned = k.transform_shape(c3, Transform3D(Basis(Vector3(0, 0, 1), deg_to_rad(degrees)), Vector3.ZERO), "t")
		for ruled in [false, true]:
			var solid = k.loft([c5, turned], {"ruled": ruled})
			_close(solid, frustum, "An r 5 mm circle lofted to an r 3 mm one drawn from %s deg (ruled %s)" % [degrees, ruled], frustum * 1e-6)
			var skin = k.loft([c5, turned], {"ruled": ruled, "surface": true})
			_expect(skin != null and absf(skin.area() - cone) <= 1e-6 * cone, "Their surface loft (ruled %s, from %s deg) should be the frustum's wall, %.6f mm2 (%s)." % [ruled, degrees, cone * 1e6, skin.area() * 1e6 if skin != null else -1.0])
	var flipped := Transform3D(Basis(Vector3(1, 0, 0), PI), Vector3(0, 0, 0.01))
	_close(k.loft([c5, k.sketch_regions([{"type": "circle", "c": Vector2.ZERO, "r": 0.003}], flipped)[0].face], {}), frustum, "An r 5 mm circle lofted to an r 3 mm one on a plane facing down", frustum * 1e-6)
	# A 12 mm square with an r 2 mm hole lofted to an r 6 mm disc with an r 2.5 mm hole 10 mm up.
	var holed = null
	for region in k.sketch_regions([{"type": "line", "a": Vector2(-0.006, -0.006), "b": Vector2(0.006, -0.006)}, {"type": "line", "a": Vector2(0.006, -0.006), "b": Vector2(0.006, 0.006)},
			{"type": "line", "a": Vector2(0.006, 0.006), "b": Vector2(-0.006, 0.006)}, {"type": "line", "a": Vector2(-0.006, 0.006), "b": Vector2(-0.006, -0.006)}, {"type": "circle", "c": Vector2.ZERO, "r": 0.002}], Transform3D.IDENTITY):
		holed = region.face if float(region.area) > 1e-4 else holed
	var ring = null
	for region in k.sketch_regions([{"type": "circle", "c": Vector2.ZERO, "r": 0.006}, {"type": "circle", "c": Vector2.ZERO, "r": 0.0025}], up):
		ring = region.face if float(region.area) > 5e-5 else ring
	var hole_wall := PI * 0.0045 * sqrt(1e-4 + 0.25e-6)
	var volumes := []
	for degrees in [0.0, 70.0]:
		var made = k.loft([holed, k.transform_shape(ring, Transform3D(Basis(Vector3(0, 0, 1), deg_to_rad(degrees)), Vector3.ZERO), "t")], {})
		var wall := 0.0
		for f in made.face_count() if made != null else 0:
			var info: Dictionary = made.face_info(f)
			if str(info.type) != "plane" and Vector2((info.point as Vector3).x, (info.point as Vector3).y).length() < 0.001:
				wall += float(info.area)
		volumes.append(made.volume() if made != null else -1.0)
		_expect(absf(wall - hole_wall) <= 1e-6 * hole_wall, "The holed square lofted to the ring drawn from %s deg should have the frustum's hole wall, %.6f mm2 (%.6f)." % [degrees, hole_wall * 1e6, wall * 1e6])
	_expect(absf(float(volumes[0]) - float(volumes[1])) <= 1e-6 * absf(float(volumes[0])), "The holed square's loft should not depend on where the ring is drawn from (%s)." % [volumes])
	# A 10 mm square to an 8 mm one turned 30 deg: as before, four walls named L:f#0..3.
	var outlines := []
	for spec in [[45.0, 0.005], [75.0, 0.004]]:
		var curves := []
		for j in 4:
			var a: Vector2 = Vector2.from_angle(deg_to_rad(spec[0] + 90.0 * j)) * spec[1] * sqrt(2.0)
			var b: Vector2 = Vector2.from_angle(deg_to_rad(spec[0] + 90.0 * (j + 1))) * spec[1] * sqrt(2.0)
			curves.append({"type": "line", "a": a, "b": b})
		outlines.append(curves)
	var square: RefCounted = k.sketch_regions(outlines[0], Transform3D.IDENTITY)[0].face
	var turned_square: RefCounted = k.sketch_regions(outlines[1], up)[0].face
	var squares = k.loft([square, turned_square], {"tag": "L"})
	var names: Array = Array(squares.get_face_names()) if squares != null else []
	names.sort()
	_close(squares, 777.606903e-9, "A 10 mm square lofted to an 8 mm one turned 30 deg (as before)", 777.606903e-9 * 1e-6)
	_expect(names == ["L:end", "L:f#0", "L:f#1", "L:f#2", "L:f#3", "L:start"], "The squares' loft should keep its names (%s)." % [names])


func _edge_along(shape, direction: Vector3, length: float) -> int:
	for e in shape.edge_count():
		var info: Dictionary = shape.edge_info(e)
		if info.get("type", "") == "line" and absf(float(info.length) - length) < 1e-9 and absf(absf((info.tangent as Vector3).dot(direction)) - 1.0) < 1e-6:
			return e
	return -1


func _face_facing(shape, normal: Vector3) -> int:
	for f in shape.face_count():
		var info: Dictionary = shape.face_info(f)
		if info.get("planar", false) and (info.normal as Vector3).is_equal_approx(normal):
			return f
	return -1


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error(message)
		print("FAIL: ", message)


## Round 8: a boolean that comes out wrong is refused, not returned as if done (a thread groove cut
## from a rod ending inside its last turn left the rod uncut, with no error); twisted sweeps are
## exact at any twist and along a helix (a loft through 24 turned copies made a square turned 1080
## deg 38 % big and lost 0.4 % along a helix); the coil's inner triangle is the right way out (its
## volume was negative); polygon loops loft corner to corner whichever corner they start at and
## whichever way they face (they twisted or flattened); a small smooth loft through three circles is
## exact (OCCT turns circles into splines to an absolute 1e-7 m).
func _check_round8_measures() -> void:
	var groove = k.thread({"radius": 0.0015, "pitch": 0.0005, "length": 0.01, "axis": Vector3(0, 0, 1)})
	var rod = k.make_cylinder(0.0015, 0.0105, Vector3(0, 0, -0.001), Vector3(0, 0, 1), "rod")
	var cut = k.boolean(rod, groove, 1, "cut")
	_expect(cut == null and k.get_last_error().contains("came out wrong"), "A thread groove cut from a rod ending inside its last turn should be refused, not left uncut (%s, \"%s\")." % [String.num((rod.volume() - cut.volume()) * 1e9, 6) + " mm3 removed" if cut != null else "null", k.get_last_error()])
	var through = k.make_cylinder(0.0015, 0.012, Vector3(0, 0, -0.001), Vector3(0, 0, 1), "rod")
	var threaded = k.boolean(through, groove, 1, "cut")
	_expect(threaded != null and through.volume() - threaded.volume() > 0.8 * groove.volume(), "The same groove inside a longer rod should still cut it (%s)." % k.get_last_error())
	# Twisted sweeps: a 4 mm square 30 mm straight, and a 2 mm one along 1.5 turns of a helix: A L.
	var path: RefCounted = k.sketch_wire([{"type": "line", "a": Vector2.ZERO, "b": Vector2(0, 0.03)}], Transform3D(Basis(Vector3.RIGHT, Vector3.BACK, Vector3.DOWN), Vector3.ZERO))
	var square := _rect_profile(0.004, 0.004)
	for degrees in [540.0, 720.0, 1080.0]:
		_close(k.sweep(square, path, {"twist": deg_to_rad(degrees)}), 16e-6 * 0.03, "A 4 mm square swept 30 mm, twisted %.0f deg" % degrees, 16e-6 * 0.03 * 1e-6)
	var helix = k.helix({"radius": 0.01, "pitch": 0.004, "turns": 1.5, "axis": Vector3(0, 0, 1)})
	var start: Dictionary = helix.edge_point_at(0, 0.0)
	var frame := Transform3D(Basis.looking_at(-(start.tangent as Vector3), Vector3(0, 0, 1)), start.point)
	var small: RefCounted = k.sketch_regions([{"type": "line", "a": Vector2(-0.001, -0.001), "b": Vector2(0.001, -0.001)}, {"type": "line", "a": Vector2(0.001, -0.001), "b": Vector2(0.001, 0.001)},
		{"type": "line", "a": Vector2(0.001, 0.001), "b": Vector2(-0.001, 0.001)}, {"type": "line", "a": Vector2(-0.001, 0.001), "b": Vector2(-0.001, -0.001)}], frame)[0].face
	var along := 4e-6 * _helix_length(0.01, 0.004, 1.5)
	for degrees in [0.01, 30.0]:
		_close(k.sweep(small, helix, {"twist": deg_to_rad(degrees)}), along, "A 2 mm square swept along 1.5 turns of a helix, twisted %s deg" % degrees, along * 1e-6)
	# Coil sections: a triangle 2 mm across, pointing out or in, screwed round 2 turns of r 10 mm.
	for spec in [["triangle_out", -1.0], ["triangle_in", 1.0]]:
		var coil = k.coil({"diameter": 0.02, "pitch": 0.004, "turns": 2.0, "section_size": 0.002, "section": spec[0], "axis": Vector3(0, 0, 1)})
		var want: float = TAU * (0.01 + spec[1] * 0.001 / 3.0) * 2e-6 * 2.0
		_close(coil, want, "A %s coil (2 pi rbar A turns, the right way out)" % spec[0], want * 1e-6)
	# A 10 x 6 rectangle lofted 10 mm to the same one drawn from another corner, and to one on a plane
	# facing down: the prism.
	var up := Transform3D(Basis.IDENTITY, Vector3(0, 0, 0.01))
	var corners := [Vector2(0, 0), Vector2(0.01, 0), Vector2(0.01, 0.006), Vector2(0, 0.006)]
	var outlines := []
	for first in [0, 2]:
		var curves := []
		for j in 4:
			curves.append({"type": "line", "a": corners[(first + j) % 4], "b": corners[(first + j + 1) % 4]})
		outlines.append(curves)
	var bottom: RefCounted = k.sketch_regions(outlines[0], Transform3D.IDENTITY)[0].face
	_close(k.loft([bottom, k.sketch_regions(outlines[1], up)[0].face], {}), 6e-7, "A rectangle lofted to the same one drawn from another corner", 6e-7 * 1e-6)
	var mirrored := []
	for line in outlines[0]:
		mirrored.append({"type": "line", "a": Vector2(line.a.x, -line.a.y), "b": Vector2(line.b.x, -line.b.y)})
	var facing_down := Transform3D(Basis(Vector3(1, 0, 0), PI), Vector3(0, 0, 0.01))
	_close(k.loft([bottom, k.sketch_regions(mirrored, facing_down)[0].face], {}), 6e-7, "A rectangle lofted to the same one on a plane facing down", 6e-7 * 1e-6)
	# r 1 -> 0.8 -> 0.6 mm coaxial circles 1 mm apart, lofted smooth: an exact frustum.
	var rings := []
	for i in 3:
		rings.append(k.sketch_regions([{"type": "circle", "c": Vector2.ZERO, "r": 0.001 - 0.0002 * i}], Transform3D(Basis.IDENTITY, Vector3(0, 0, 0.001 * i)))[0].face)
	var frustum := PI * 0.002 / 3.0 * (1.0 + 0.6 + 0.36) * 1e-6
	_close(k.loft(rings, {}), frustum, "Three coaxial circles 2 mm long lofted smooth", frustum * 1e-6)
	# r 5, 3 and 4 circles offset sideways, lofted smooth at 1 and 50 times their size: one shape (they
	# were 3e-5 apart).
	var volumes := []
	for s in [1.0, 50.0]:
		var offsets := []
		for spec in [[0.005, Vector3.ZERO], [0.003, Vector3(0.002, 0, 0.007)], [0.004, Vector3(0, -0.001, 0.015)]]:
			offsets.append(k.sketch_regions([{"type": "circle", "c": Vector2.ZERO, "r": spec[0] * s}], Transform3D(Basis.IDENTITY, spec[1] * s))[0].face)
		var made = k.loft(offsets, {})
		volumes.append(made.volume() / pow(s, 3.0) if made != null else -1.0)
	_expect(volumes[0] > 0.0 and absf(volumes[1] - volumes[0]) <= 1e-6 * volumes[0], "Three offset circles lofted at 1 and 50 times their size should be one shape (volumes %s mm3 scaled back)." % [[volumes[0] * 1e9, volumes[1] * 1e9]])


## Round 9: coils and sweeps that would cross themselves are refused (a coil whose section reached
## past its axis, one tapering in past its cone's apex, and a 4 mm square swept round a 1 mm bend
## came out with negative volumes, a 3 mm pipe round it overlapping); a tapered coil says how far
## its section leans and how far off that puts its volume (60 deg was 1.4 % over, silently); a
## twist can't be had with a guide rail or a parallel profile (it dropped them); a square swept
## round a ring with a twist is exact and cut at its seam (it was fitted to 1 mm, its area 3 %
## big); two circles lofted along a rail that starts where they do make the frustum (4.6 % big).
func _check_round9_sweeps() -> void:
	var up := Vector3(0, 0, 1)
	var coil = k.coil({"diameter": 0.0008, "pitch": 0.002, "turns": 3.0, "section_size": 0.001, "axis": up})
	_expect(coil == null and k.get_last_error().contains("cross its axis"), "A coil 0.8 mm across with a 1 mm section should be refused (%s, \"%s\")." % [coil.volume() if coil != null else "null", k.get_last_error()])
	coil = k.coil({"diameter": 0.01, "pitch": 0.002, "turns": 3.5, "section_size": 0.001, "taper": deg_to_rad(-40.0), "axis": up})
	_expect(coil == null and k.get_last_error().contains("cross its axis"), "A coil tapering in 40 deg past its apex should be refused (\"%s\")." % k.get_last_error())
	coil = k.coil({"diameter": 0.0008, "pitch": 0.003, "turns": 2.0, "section_size": 0.001, "spiral": true, "axis": up})
	_expect(coil == null and k.get_last_error().contains("cross itself"), "A spiral starting inside its section's reach should be refused (\"%s\")." % k.get_last_error())
	# A 60 deg tapered coil: its warning against the volume of one whose section stays in the plane
	# through the axis (the section's area times the integral of its centre's radius round it).
	var tapered = k.coil({"diameter": 0.01, "pitch": 0.006, "turns": 1.0, "section_size": 0.001, "section": "square", "taper": deg_to_rad(60.0), "axis": up})
	var said := RegEx.create_from_string("leans up to ([0-9.]+) deg.*volume is ([0-9.e+-]+) % over").search(k.get_last_warning())
	var meridian := 1e-6 * TAU * (0.005 + 0.5 * 0.006 * tan(deg_to_rad(60.0)))
	var over: float = (tapered.volume() - meridian) / meridian * 100.0 if tapered != null else 0.0
	_expect(tapered != null and said != null and absf(float(said.get_string(2)) - over) <= 0.05 * over, "A 60 deg tapered coil should say how far its volume is over (%s %%; \"%s\")." % [over, k.get_last_warning()])
	# Square profiles centred on the start of a quarter arc of radius 1 mm (heading down, bending
	# toward +x).
	var xz := Transform3D(Basis(Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(0, -1, 0)), Vector3.ZERO)
	var bend: RefCounted = k.sketch_wire([{"type": "arc", "c": Vector2(0.001, 0), "r": 0.001, "a0": PI, "a1": 1.5 * PI}], xz)
	var square := func(side: float) -> RefCounted:
		return k.sketch_regions([{"type": "line", "a": Vector2(-side, -side) * 0.5, "b": Vector2(side, -side) * 0.5}, {"type": "line", "a": Vector2(side, -side) * 0.5, "b": Vector2(side, side) * 0.5},
			{"type": "line", "a": Vector2(side, side) * 0.5, "b": Vector2(-side, side) * 0.5}, {"type": "line", "a": Vector2(-side, side) * 0.5, "b": Vector2(-side, -side) * 0.5}], Transform3D.IDENTITY)[0].face
	var crossed = k.sweep(square.call(0.004), bend, {})
	var reach := RegEx.create_from_string("reaches ([0-9.]+) mm .* only ([0-9.]+) mm round").search(k.get_last_error())
	_expect(crossed == null and reach != null and absf(float(reach.get_string(1)) - 2.0) < 0.01 and absf(float(reach.get_string(2)) - 1.0) < 0.01, "A 4 mm square swept round a 1 mm bend should be refused, saying it reaches 2 mm toward a 1 mm bend (%s, \"%s\")." % [crossed.volume() if crossed != null else "null", k.get_last_error()])
	var fits := 2.56e-6 * PI / 2.0 * 0.001
	_close(k.sweep(square.call(0.0016), bend, {}), fits, "A 1.6 mm square swept round a 1 mm bend (A L)", fits * 1e-6)
	var pipe = k.pipe(bend, {"size": 0.003})
	_expect(pipe == null and k.get_last_error().contains("cross itself"), "A 3 mm pipe round a 1 mm bend should be refused (\"%s\")." % k.get_last_error())
	# Twist with a guide rail or a parallel profile.
	var straight: RefCounted = k.sketch_wire([{"type": "line", "a": Vector2.ZERO, "b": Vector2(0, 0.02)}], xz)
	var guide: RefCounted = k.sketch_wire([{"type": "line", "a": Vector2(0.002, 0), "b": Vector2(0.003, 0.02)}], xz)
	var with_guide = k.sweep(square.call(0.004), straight, {"guide": guide, "twist": PI / 2.0})
	_expect(with_guide == null and k.get_last_error().contains("guide rail"), "A twisted sweep with a guide rail should be refused, not drop the rail (\"%s\")." % k.get_last_error())
	var parallel = k.sweep(square.call(0.004), straight, {"orientation": "parallel", "twist": 0.01})
	_expect(parallel == null and k.get_last_error().contains("parallel"), "A twisted sweep kept parallel should be refused, not swept square (\"%s\")." % k.get_last_error())
	# A 2 mm square round a 20 mm ring twisted 90 deg (closing on itself) and 45 deg (it can't): A L.
	var ring: RefCounted = k.sketch_wire([{"type": "circle", "c": Vector2(0.02, 0), "r": 0.02}], xz)
	var start: Dictionary = ring.edge_point_at(0, 0.0)
	var frame := Transform3D(Basis.looking_at(-(start.tangent as Vector3).normalized(), Vector3(0, 1, 0)), start.point)
	var section: RefCounted = k.sketch_regions([{"type": "line", "a": Vector2(-0.001, -0.001), "b": Vector2(0.001, -0.001)}, {"type": "line", "a": Vector2(0.001, -0.001), "b": Vector2(0.001, 0.001)},
		{"type": "line", "a": Vector2(0.001, 0.001), "b": Vector2(-0.001, 0.001)}, {"type": "line", "a": Vector2(-0.001, 0.001), "b": Vector2(-0.001, -0.001)}], frame)[0].face
	var whole := 4e-6 * TAU * 0.02
	var cutter = k.make_box(Vector3(0.01, 0.01, 0.01), Vector3(0.035, -0.005, -0.005), "b")
	var plain_cut = k.boolean(k.sweep(section, ring, {}), cutter, 1, "c")
	for degrees in [90.0, 45.0]:
		var twisted = k.sweep(section, ring, {"twist": deg_to_rad(degrees)})
		_expect(twisted != null and k.get_last_warning() == "", "A square swept round a ring twisted %s deg should build closely, with nothing to say (\"%s\", %s)." % [degrees, k.get_last_warning(), k.get_last_error()])
		_close(twisted, whole, "A 2 mm square swept round a 20 mm ring twisted %s deg (A L)" % degrees, whole * 1e-6)
		var cut = k.boolean(twisted, cutter, 1, "c") if twisted != null else null
		_expect(cut != null and plain_cut != null and absf(cut.volume() - plain_cut.volume()) <= whole * 1e-6, "The ring twisted %s deg should cut at its seam as the plain one does (%s)." % [degrees, k.get_last_error()])
	# Circles r 5 and r 3 mm 10 mm apart lofted along a straight rail from where both start: the
	# frustum, at 10 and 0.5 mm.
	for s in [1.0, 0.05]:
		var u: float = 0.001 * s
		var rail: RefCounted = k.sketch_wire([{"type": "line", "a": Vector2(5, 0) * u, "b": Vector2(3, 10) * u}], xz)
		var bottom: RefCounted = k.sketch_regions([{"type": "circle", "c": Vector2.ZERO, "r": 5 * u}], Transform3D.IDENTITY)[0].face
		var top: RefCounted = k.sketch_regions([{"type": "circle", "c": Vector2.ZERO, "r": 3 * u}], Transform3D(Basis.IDENTITY, Vector3(0, 0, 10) * u))[0].face
		var want: float = PI * 10.0 / 3.0 * 49.0 * pow(u, 3.0)
		_close(k.loft([bottom, top], {"rail": rail}), want, "Circles lofted along a rail starting where they do, x%s (the frustum)" % s, want * 1e-6)
