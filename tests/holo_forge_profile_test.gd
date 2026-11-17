extends SceneTree
## Holo Forge sketch geometry in the kernel: profiles (a rectangle with two circles inside gives
## the rectangle-with-two-holes plus each disk; two overlapping circles give 3 regions; a
## dangling line adds none), curve intersections and nearest points (for trim and extend),
## offsets (with arcs at convex corners), splines and conics, sampling, and projecting a body's
## edges and its section onto a sketch plane.
##
## godot --headless --path . --script res://tests/holo_forge_profile_test.gd

var failures: Array[String] = []
var kernel


func _init() -> void:
	call_deferred("run")


func run() -> void:
	kernel = ClassDB.instantiate("CadKernel") if ClassDB.class_exists("CadKernel") else null
	_expect(kernel != null, "The native kernel should load.")
	if kernel != null:
		_check_regions()
		_check_curves()
		_check_projection()
	print("PASS holo_forge_profile: profiles with holes, overlapping circles, dangling lines, intersections, closest points, offsets, splines and conics, projection and section." \
		if failures.is_empty() else "FAIL holo_forge_profile")
	quit(0 if failures.is_empty() else 1)


func _rect(x0: float, y0: float, x1: float, y1: float) -> Array:
	return [
		{"type": "line", "a": Vector2(x0, y0), "b": Vector2(x1, y0)}, {"type": "line", "a": Vector2(x1, y0), "b": Vector2(x1, y1)},
		{"type": "line", "a": Vector2(x1, y1), "b": Vector2(x0, y1)}, {"type": "line", "a": Vector2(x0, y1), "b": Vector2(x0, y0)},
	]


func _check_regions() -> void:
	var xz := Transform3D(Basis(Vector3.RIGHT, Vector3.BACK, Vector3.DOWN), Vector3.ZERO)
	var curves := _rect(0, 0, 0.1, 0.05)
	curves.append({"type": "circle", "c": Vector2(0.025, 0.025), "r": 0.01})
	curves.append({"type": "circle", "c": Vector2(0.075, 0.025), "r": 0.01})
	var regions: Array = kernel.sketch_regions(curves, Transform3D.IDENTITY)
	_expect(regions.size() == 3, "A rectangle with two circles inside should give 3 profiles (got %d, %s)." % [regions.size(), kernel.get_last_error()])
	var holed := regions.filter(func(r: Dictionary) -> bool: return (r.loops as Array).size() == 3)
	var disks := regions.filter(func(r: Dictionary) -> bool: return (r.loops as Array).size() == 1)
	_expect(holed.size() == 1 and absf(float(holed[0].area) - (0.005 - 2.0 * PI * 0.0001)) < 1e-9, "One profile should be the rectangle with 2 holes (area %s)." % [holed.map(func(r: Dictionary) -> float: return r.area)])
	_expect(disks.size() == 2 and absf(float(disks[0].area) - PI * 0.0001) < 1e-9, "The two disks should be profiles of their own.")
	_expect(holed.size() == 1 and (holed[0].face as RefCounted).shape_type() == "FACE", "A profile should carry its planar face.")

	var overlapping: Array = kernel.sketch_regions([{"type": "circle", "c": Vector2(0, 0), "r": 1.0}, {"type": "circle", "c": Vector2(1, 0), "r": 1.0}], Transform3D.IDENTITY)
	_expect(overlapping.size() == 3, "Two overlapping circles should give 3 regions (got %d)." % overlapping.size())
	var total := 0.0
	for r in overlapping:
		total += float(r.area)
	var lens := 2.0 * (PI / 3.0) - sqrt(3.0) / 2.0
	_expect(absf(total - (2.0 * PI - lens)) < 1e-7, "The regions should cover the union of the circles (%f vs %f)." % [total, 2.0 * PI - lens])

	var with_dangling := _rect(0, 0, 1, 1)
	with_dangling.append({"type": "line", "a": Vector2(0.5, 0.5), "b": Vector2(2, 2)})
	_expect((kernel.sketch_regions(with_dangling, Transform3D.IDENTITY) as Array).size() == 1, "A dangling line should not add a profile.")

	# The same rectangle on the XZ plane: the face lies in that plane.
	var on_xz: Array = kernel.sketch_regions(_rect(0, 0, 0.1, 0.05), xz)
	var bounds: AABB = on_xz[0].face.bbox() if not on_xz.is_empty() else AABB()
	_expect(on_xz.size() == 1 and absf(bounds.size.y) < 1e-6 and absf(bounds.size.x - 0.1) < 1e-6 and absf(bounds.size.z - 0.05) < 1e-6,
		"A profile on the XZ plane should lie flat in X and Z (%s)." % bounds)


func _check_curves() -> void:
	var line := {"type": "line", "a": Vector2(-2, 0), "b": Vector2(2, 0)}
	var circle := {"type": "circle", "c": Vector2(0, 0), "r": 1.0}
	var hits: Dictionary = kernel.curve_intersections(line, circle)
	var params: PackedFloat64Array = hits.params_a
	params.sort()
	_expect((hits.points as PackedVector2Array).size() == 2 and absf(params[0] - 0.25) < 1e-9 and absf(params[1] - 0.75) < 1e-9,
		"A line through a circle should cross it twice at line params 0.25 and 0.75 (%s)." % [hits])
	var arc := {"type": "arc", "c": Vector2(0, 0), "r": 1.0, "a0": 0.0, "a1": PI * 0.5}
	_expect((kernel.curve_intersections(line, arc).points as PackedVector2Array).size() == 1, "A quarter arc should cross the line once.")
	var near: Dictionary = kernel.curve_closest_point(circle, Vector2(3, 0))
	_expect((near.point as Vector2).distance_to(Vector2(1, 0)) < 1e-6 and absf(float(near.distance) - 2.0) < 1e-9, "The nearest circle point to (3,0) is (1,0).")
	var end_near: Dictionary = kernel.curve_closest_point(line, Vector2(5, 1))
	_expect(absf(float(end_near.param) - 1.0) < 1e-9, "Past a line's end, its end is nearest (param 1).")

	var square := _rect(0, 0, 1, 1)
	var out: Array = kernel.offset_curves(square, 0.1)
	var arcs := out.filter(func(c: Dictionary) -> bool: return c.type == "arc")
	var lines := out.filter(func(c: Dictionary) -> bool: return c.type == "line")
	_expect(lines.size() == 4 and arcs.size() == 4 and absf(float(arcs[0].r) - 0.1) < 1e-9, "Offsetting a square outward should give 4 lines and 4 corner arcs (%d, %d; %s)." % [lines.size(), arcs.size(), kernel.get_last_error()])
	var inward: Array = kernel.offset_curves(square, -0.1)
	_expect(inward.size() == 4 and inward.all(func(c: Dictionary) -> bool: return c.type == "line"), "Offsetting inward should give a smaller square of 4 lines.")

	var spline := {"type": "interp", "points": PackedVector2Array([Vector2(0, 0), Vector2(1, 1), Vector2(2, 0), Vector2(3, 1)])}
	var spline_points: PackedVector2Array = kernel.sample_curve(spline, 0.001)
	_expect(spline_points.size() > 10 and spline_points[0].distance_to(Vector2(0, 0)) < 1e-6 and spline_points[spline_points.size() - 1].distance_to(Vector2(3, 1)) < 1e-6,
		"A fit-point spline should pass through its first and last points.")
	var nearest := float(kernel.curve_closest_point(spline, Vector2(1, 1)).distance)
	_expect(nearest < 1e-7, "A fit-point spline should pass exactly through its middle points (off by %f)." % nearest)
	var control := {"type": "bspline", "poles": PackedVector2Array([Vector2(0, 0), Vector2(1, 2), Vector2(2, -2), Vector2(3, 0)]), "degree": 3}
	var control_points: PackedVector2Array = kernel.sample_curve(control, 0.001)
	_expect(control_points[0].distance_to(Vector2(0, 0)) < 1e-6 and control_points[control_points.size() - 1].distance_to(Vector2(3, 0)) < 1e-6, "A control-point spline should start and end on its end points.")
	var conic := {"type": "conic", "a": Vector2(0, 0), "b": Vector2(2, 0), "shoulder": Vector2(1, 1), "weight": 1.0 / sqrt(2.0)}
	var conic_regions: Array = kernel.sketch_regions([conic, {"type": "line", "a": Vector2(2, 0), "b": Vector2(0, 0)}], Transform3D.IDENTITY)
	_expect(conic_regions.size() == 1 and absf(float(conic_regions[0].area) - (PI * 0.5 - 1.0)) < 1e-6, "A conic with weight 0.707 through (1,1) is a 90-degree arc of radius sqrt(2): segment area PI/2 - 1 (%s)." % [conic_regions.map(func(r: Dictionary) -> float: return r.area)])


func _check_projection() -> void:
	# A 100 x 50 x 80 mm box seen from above: its top edges project to a 100 x 80 rectangle.
	var box = kernel.make_box(Vector3(0.1, 0.05, 0.08))
	var top_ids := PackedInt32Array()
	var tess: Dictionary = box.tessellate(0.001, 0.2)
	var points: PackedVector3Array = tess.edge_points
	var ids: PackedInt32Array = tess.edge_ids
	for s in ids.size():
		if absf(points[s * 2].y - 0.05) < 1e-6 and absf(points[s * 2 + 1].y - 0.05) < 1e-6 and not top_ids.has(ids[s]):
			top_ids.append(ids[s])
	var plane := Transform3D(Basis(Vector3.RIGHT, Vector3.FORWARD, Vector3.UP), Vector3(0, 0.2, 0))
	var projected: Array = kernel.project_edges(box, top_ids, plane)
	var total := 0.0
	for curve in projected:
		total += (curve.a as Vector2).distance_to(curve.b) if curve.type == "line" else 0.0
	_expect(projected.size() == 4 and absf(total - 0.36) < 1e-6, "Projecting the top edges should give a 100 x 80 mm rectangle (perimeter %f, %s)." % [total, kernel.get_last_error()])
	var section: Array = kernel.section_curves(box, Transform3D(Basis.IDENTITY, Vector3(0, 0.025, 0)).rotated_local(Vector3.RIGHT, -PI * 0.5))
	_expect(section.size() == 4, "Cutting the box half way up should give 4 section lines (got %d)." % section.size())
	var top_face := -1
	for f in box.face_count():
		var info: Dictionary = box.face_info(f)
		if info.get("planar", false) and (info.normal as Vector3).is_equal_approx(Vector3.UP):
			top_face = f
	_expect(top_face >= 0 and (box.face_info(top_face).edges as PackedInt32Array).size() == 4, "face_info should find the top face with its 4 edges.")


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error(message)
		print("FAIL: ", message)
