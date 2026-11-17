extends SceneTree
## Holo Forge Phase 4 Inspect: Measure on an L-bracket (distances between parallel faces, the
## 90 degree angle, a face area, an edge length, a vertex position, origin planes and axes),
## planes and axes as unbounded geometry (far points, crossing planes, skew axes), sketch curve,
## point and profile measures, center of mass against the analytic centroid, mass with
## Aluminum's density and the combined inertia of two bodies against the box formula; interference
## volume of overlapping and nested boxes (touching boxes, and disjoint ones whose bounds overlap,
## report none) and overlaps added as bodies or as components of their own; the analyses
## (curvature map on a sphere and a concave hole, minimum radius on a filleted box and a hole,
## draft on a drafted box, isocurves trimmed to their faces (a box with a hole: every point on its
## face, lines stopping at the hole), isocurve combs (1/r on a cylinder's circles, none on its
## straight lines), curvature combs on a sketch arc and on edges, a section cap, a turned section
## (tilt and spin), zebra, environment map with its reflection probe bounds, component colors,
## accessibility, center of mass); and physical material resolution body > component > default.
## Regressions: open-mesh (surface) bodies have no volume or mass and don't interfere (a body
## mixing solids with open faces counts only its solids); analyses leave hidden bodies out; combs
## comb exactly the picked sketch curves and their scale multiplies the automatic size; section,
## draft and accessibility references are found again on every build (the section follows its
## plane); small masses and areas keep their digits; components get distinct colors whatever their
## ids; a component's material reaches bodies that had their own; curvature map and isocurves on a
## 3120-face faceted mesh stay fast and kept results are reused; a surface body's centre is its
## area's exact centroid (not its display mesh's), a faceted mesh body's its triangles'.
##
## godot --headless --path . --script res://tests/holo_forge_inspect_test.gd

const DOCUMENT := preload("res://addons/holo_forge/core/document.gd")
const REGEN := preload("res://addons/holo_forge/core/regen.gd")
const OPERATIONS := preload("res://addons/holo_forge/core/operations.gd")
const SKETCH_DATA := preload("res://addons/holo_forge/core/sketch/sketch_data.gd")
const TESSELLATE := preload("res://addons/holo_forge/core/tessellate.gd")
const INSPECT := preload("res://addons/holo_forge/core/inspect.gd")
const ANALYSIS := preload("res://addons/holo_forge/core/analysis.gd")
const PHYSICAL := preload("res://addons/holo_forge/core/physical_materials.gd")
const TIMING := preload("res://tests/holo_forge_timing.gd")

const MM := 0.001
const MM2 := 1e-6
const MM3 := 1e-9
## Points pass through Godot's single-precision vectors: 1 micrometer is the bar for positions.
const POSITION_TOLERANCE := 1e-6

var failures: Array[String] = []
var kernel
var doc
var result := {}


func _init() -> void:
	call_deferred("run")


func run() -> void:
	kernel = REGEN.make_kernel()
	_expect(kernel != null, "The native kernel should load.")
	if kernel != null:
		_check_measure_and_mass()
		_check_unbounded_measures()
		_check_sketch_measures()
		_check_inertia()
		_check_interference()
		_check_interference_components()
		_check_curvature_map()
		_check_concave_curvature()
		_check_minimum_radius()
		_check_draft()
		_check_isocurve()
		_check_trimmed_isocurves()
		_check_isocurve_combs()
		_check_combs()
		_check_section()
		_check_section_rotation()
		_check_display_analyses()
		_check_open_shells()
		_check_hidden_bodies()
		_check_comb_picks()
		_check_comb_scale()
		_check_followed_references()
		_check_readout_digits()
		_check_component_color_order()
		_check_faceted_mesh_cost()
		_check_surface_centres()
	_check_materials()
	_check_material_assign()
	print("PASS holo_forge_inspect: L-bracket measures (distance, 90 deg angle, area, length, position), center of mass and Aluminum mass match the analytic values, unbounded planes/axes, sketch curves and combined inertia measure exactly, interference volume is exact, touching or disjoint is none, and overlaps become bodies or components, sphere curvature is 1/r^2 and holes are concave, minimum radius/draft/isocurve (trimmed, with combs)/comb/section (turned too) analyses are right, materials resolve body > component > default, and the review regressions (surface bodies, hidden bodies, comb picks and scale, followed references, readout digits, component colors, component materials, faceted-mesh speed, exact surface centres) hold." \
		if failures.is_empty() else "FAIL holo_forge_inspect")
	quit(0 if failures.is_empty() else 1)


# --- Helpers ---------------------------------------------------------------------------------

func _new_doc() -> void:
	doc = DOCUMENT.new()
	result = {}


func _add(type: String, inputs: Dictionary, options: Dictionary) -> Resource:
	var made := {}
	for key in inputs:
		var spec = inputs[key]
		made[key] = doc.make_input(spec[0], spec[1]) if spec is Array else doc.make_input(str(spec), "length")
	var feature: Resource = doc.add_feature(type, type.capitalize(), made, options)
	if OPERATIONS.creates_body(str(options.get("operation", ""))):
		feature.options["body_id"] = doc.new_body(feature.id)
	return feature


## A box l x h x w mm with its base center at position_mm.
func _box(position_mm: Vector3, l: float, h: float, w: float, operation := OPERATIONS.NEW_BODY) -> Resource:
	return _add("box", {"length": "%s mm" % l, "height": "%s mm" % h, "width": "%s mm" % w}, {"position": position_mm * MM, "operation": operation})


func _rebuild() -> Dictionary:
	result = REGEN.rebuild(doc, kernel)
	return result


func _no_errors(label: String) -> void:
	_expect((result.errors as Dictionary).is_empty(), "%s: the timeline should rebuild cleanly (%s)." % [label, result.errors])


func _body(feature: Resource) -> String:
	return str(feature.options.get("body_id", ""))


func _shape(body_id: String) -> RefCounted:
	return result.bodies[body_id].shape if result.bodies.has(body_id) else null


## A reference to the flat face facing normal whose plane passes through point.
func _face_at(body_id: String, normal: Vector3, point: Vector3) -> Dictionary:
	var shape := _shape(body_id)
	var best := {}
	for f in shape.face_count():
		var info: Dictionary = shape.face_info(f)
		if info.get("planar", false) and (info.normal as Vector3).is_equal_approx(normal) and absf(((info.point as Vector3) - point).dot(normal)) < 1e-7 \
				and float(info.area) > float(best.get("sig", {}).get("area", -1.0)):
			best = {"kind": "face", "body": body_id, "name": shape.get_face_names()[f], "sig": {"type": info.type, "point": info.point, "normal": info.normal, "area": info.area}}
	_expect(not best.is_empty(), "A face facing %s through %s should exist." % [normal, point])
	return best


func _edge_ref(body_id: String, direction: Vector3, length: float) -> Dictionary:
	var shape := _shape(body_id)
	for e in shape.edge_count():
		var info: Dictionary = shape.edge_info(e)
		if info.get("type", "") == "line" and absf(float(info.length) - length) < 1e-7 and absf(absf((info.tangent as Vector3).dot(direction)) - 1.0) < 1e-6:
			return {"kind": "edge", "body": body_id, "name": shape.get_edge_names()[e], "sig": {"type": "line", "point": info.midpoint, "length": info.length}}
	_expect(false, "An edge along %s of length %s should exist." % [direction, length])
	return {}


func _near(value: float, expected: float, rel: float) -> bool:
	return absf(value - expected) <= maxf(absf(expected) * rel, 1e-15)


func _vec_near(value: Vector3, expected: Vector3, tolerance := POSITION_TOLERANCE) -> bool:
	return value.distance_to(expected) <= tolerance


## Mesh colors are stored as 8-bit, so they come back within 1/255.
func _color_near(value: Color, expected: Color) -> bool:
	return absf(value.r - expected.r) < 0.01 and absf(value.g - expected.g) < 0.01 and absf(value.b - expected.b) < 0.01


func _analysis(type: String, options: Dictionary, tessellations := {}) -> Dictionary:
	var out := ANALYSIS.build({"id": "a1", "type": type, "name": type, "visible": true, "options": options}, result, tessellations, kernel, doc)
	_expect(not out.has("error"), "%s analysis should build (%s)." % [type, out.get("error", "")])
	return out


func _mesh_colors(out: Dictionary, body_id: String) -> PackedColorArray:
	var mesh: ArrayMesh = out.body_meshes.get(body_id)
	if mesh == null or mesh.get_surface_count() == 0:
		_expect(false, "The analysis should give body %s a colored mesh." % body_id)
		return PackedColorArray()
	return mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR]


## The face each vertex belongs to.
func _vertex_faces(tess: Dictionary) -> PackedInt32Array:
	var faces := PackedInt32Array()
	faces.resize((tess.positions as PackedVector3Array).size())
	var lists := ANALYSIS.face_vertices(tess)
	for f in lists:
		for v in lists[f]:
			faces[v] = f
	return faces


func _mesh_area(mesh: ArrayMesh) -> float:
	var area := 0.0
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		for t in int(indices.size() / 3.0):
			var a := positions[indices[t * 3]]
			area += (positions[indices[t * 3 + 1]] - a).cross(positions[indices[t * 3 + 2]] - a).length() * 0.5
	return area


# --- Measure and mass ------------------------------------------------------------------------

func _check_measure_and_mass() -> void:
	# An L-bracket: a 60 x 10 x 40 mm foot and a 10 x 50 x 40 mm upright sharing the corner at
	# the origin, joined into one body.
	_new_doc()
	var foot := _box(Vector3(30, 0, 20), 60, 10, 40)
	_box(Vector3(5, 0, 20), 10, 50, 40, OPERATIONS.JOIN)
	_rebuild()
	_no_errors("L-bracket")
	var body := _body(foot)
	_expect(result.bodies.size() == 1 and _shape(body) != null, "The L-bracket should be one body.")
	if _shape(body) == null:
		return
	var ctx := INSPECT.context(result, doc, kernel)
	var outer := _face_at(body, Vector3.LEFT, Vector3.ZERO)
	var end := _face_at(body, Vector3.RIGHT, Vector3(0.06, 0, 0))
	var bottom := _face_at(body, Vector3.DOWN, Vector3.ZERO)
	var top := _face_at(body, Vector3.UP, Vector3(0, 0.05, 0))
	var foot_top := _face_at(body, Vector3.UP, Vector3(0, 0.01, 0))

	var m := INSPECT.measure(outer, end, ctx)
	_expect(not m.has("error") and _near(float(m.get("distance", -1.0)), 0.06, 1e-6) and _near(float(m.get("angle", -1.0)), 0.0, 1e-6),
		"Outer and end faces (parallel) should be 60 mm apart at 0 deg (%s)." % [m])
	_expect(not m.has("error") and _vec_near(m.delta, Vector3(0.06, 0, 0)) and is_equal_approx((m.point_a as Vector3).x, 0.0) and _near((m.point_b as Vector3).x, 0.06, 1e-6),
		"The delta between parallel faces should run along X (%s)." % [m])
	m = INSPECT.measure(top, foot_top, ctx)
	_expect(not m.has("error") and _near(float(m.get("distance", -1.0)), 0.04, 1e-6) and _near(float(m.get("angle", -1.0)), 0.0, 1e-6),
		"The upright's top and the foot's top should be 40 mm apart (%s)." % [m])
	m = INSPECT.measure(outer, bottom, ctx)
	_expect(not m.has("error") and _near(float(m.get("angle", -1.0)), PI / 2.0, 1e-9) and absf(float(m.get("distance", -1.0))) < POSITION_TOLERANCE,
		"Perpendicular faces should measure 90 deg and touch (%s)." % [m])

	m = INSPECT.measure(bottom, {}, ctx)
	_expect(m.get("kind", "") == "face" and _near(float(m.get("area", -1.0)), 60 * 40 * MM2, 1e-6) and (m.get("normal", Vector3.ZERO) as Vector3).is_equal_approx(Vector3.DOWN),
		"The bottom face should be 2400 mm^2 (%s)." % [m])
	m = INSPECT.measure(_edge_ref(body, Vector3.BACK, 0.04), {}, ctx)
	_expect(m.get("kind", "") == "edge" and _near(float(m.get("length", -1.0)), 0.04, 1e-6) and absf(absf((m.get("direction", Vector3.ZERO) as Vector3).z) - 1.0) < 1e-6,
		"A Z edge should be 40 mm long (%s)." % [m])
	var corner := {"kind": "vertex", "body": body, "point": Vector3(0.06, 0.01, 0.04)}
	m = INSPECT.measure(corner, {}, ctx)
	_expect(m.get("kind", "") == "point" and _vec_near(m.get("position", Vector3.ZERO), Vector3(0.06, 0.01, 0.04)), "A vertex should report its position (%s)." % [m])
	m = INSPECT.measure(corner, outer, ctx)
	_expect(not m.has("error") and _near(float(m.get("distance", -1.0)), 0.06, 1e-6) and _vec_near(m.delta, Vector3(-0.06, 0, 0)) and not m.has("angle"),
		"A vertex is 60 mm from the outer face, with no angle (%s)." % [m])
	m = INSPECT.measure({"kind": "body", "body": body}, {}, ctx)
	# Two 1000 mm^2 L sections plus the 220 mm perimeter (60 + 10 + 50 + 40 + 10 + 50) x 40 deep.
	_expect(_near(float(m.get("volume", -1.0)), 40000 * MM3, 1e-6) and _near(float(m.get("area", -1.0)), (2 * 1000 + 220 * 40) * MM2, 1e-6),
		"The body measure should give its volume and area (%s)." % [m])
	# Origin geometry: the ground plane to the top face; the Y axis against faces.
	m = INSPECT.measure({"kind": "origin", "name": "xz"}, top, ctx)
	_expect(not m.has("error") and _near(float(m.get("distance", -1.0)), 0.05, 1e-6) and _near(float(m.get("angle", -1.0)), 0.0, 1e-9),
		"The ground plane is 50 mm below the top face, parallel (%s)." % [m])
	m = INSPECT.measure({"kind": "origin", "name": "y"}, end, ctx)
	_expect(not m.has("error") and _near(float(m.get("distance", -1.0)), 0.06, 1e-6) and _near(float(m.get("angle", -1.0)), 0.0, 1e-9),
		"The Y axis runs parallel to the end face, 60 mm away (%s)." % [m])
	m = INSPECT.measure({"kind": "origin", "name": "y"}, bottom, ctx)
	_expect(not m.has("error") and _near(float(m.get("angle", -1.0)), PI / 2.0, 1e-9), "The Y axis is perpendicular to the bottom face (%s)." % [m])
	m = INSPECT.measure({"kind": "origin", "name": "y"}, _edge_ref(body, Vector3.RIGHT, 0.06), ctx)
	_expect(not m.has("error") and _near(float(m.get("angle", -1.0)), PI / 2.0, 1e-9), "The Y axis is perpendicular to an X edge (%s)." % [m])
	_expect(INSPECT.measure({"kind": "face", "body": "nope", "name": "x"}, {}, ctx).has("error"), "A missing body should be an error.")

	# Mass properties: the L's centroid is the area-weighted centroid of its section, (20, 15) mm,
	# at half the 40 mm depth; Aluminum's mass is volume * 2700.
	var props := INSPECT.mass_properties(doc, result, [])
	var center: Vector3 = props.center
	var expected := Vector3(20, 15, 20) * MM
	_expect(_near(center.x, expected.x, 1e-6) and _near(center.y, expected.y, 1e-6) and _near(center.z, expected.z, 1e-6),
		"The center of mass should be (20, 15, 20) mm (got %s)." % [center])
	_expect(props.bodies[body].material == "Steel" and _near(float(props.mass), 40000 * MM3 * 7850.0, 1e-6), "Without a material the body is Steel (%s)." % [props.bodies[body]])
	doc.physical_materials["body:" + body] = "Aluminum"
	props = INSPECT.mass_properties(doc, result, [body])
	_expect(props.bodies[body].material == "Aluminum" and _near(float(props.mass), 40000 * MM3 * 2700.0, 1e-6) and _near(float(props.volume), 40000 * MM3, 1e-6),
		"With Aluminum the mass should be volume * 2700 = 0.108 kg (got %s)." % [props.mass])
	var com := _analysis("center_of_mass", {})
	_expect(com.points.size() == 1 and _vec_near(com.points[0].position, expected), "The Center of Mass analysis should mark the centroid (%s)." % [com.points])


func _construct(id: String) -> Dictionary:
	return {"kind": "construct", "feature": id}


## Planes and axes are unbounded, even far outside the model (here there are no bodies at all,
## so the model is 1 m across and everything below lies beyond it).
func _check_unbounded_measures() -> void:
	_new_doc()
	var ctx := INSPECT.context({"bodies": {}, "sketches": {}, "construction": {
		"x0": {"type": "plane", "origin": Vector3.ZERO, "normal": Vector3.RIGHT, "x": Vector3.BACK},
		"z10": {"type": "plane", "origin": Vector3(0, 0, 10), "normal": Vector3.BACK, "x": Vector3.RIGHT},
		# Parallel to z10 up to single-precision noise, and one tilted a real 1 degree.
		"z10_noisy": {"type": "plane", "origin": Vector3(0, 0, 10), "normal": Vector3(1e-7, 0, 1), "x": Vector3.RIGHT},
		"z10_tilted": {"type": "plane", "origin": Vector3(0, 0, 10), "normal": Vector3(sin(deg_to_rad(1.0)), 0, cos(deg_to_rad(1.0))), "x": Vector3.RIGHT},
		"skew": {"type": "axis", "origin": Vector3(0, 2, 5), "direction": Vector3.RIGHT},
		"far": {"type": "point", "position": Vector3(3, 4, 0)},
	}}, doc, kernel)
	var m := INSPECT.measure(_construct("far"), {"kind": "origin", "name": "x"}, ctx)
	_expect(_near(float(m.get("distance", -1.0)), 4.0, 1e-6) and _vec_near(m.get("point_b", Vector3.ZERO), Vector3(3, 0, 0)),
		"A point 4 m off the X axis (beyond the model) should measure 4 m to its foot (%s)." % [m])
	m = INSPECT.measure({"kind": "origin", "name": "x"}, _construct("far"), ctx)
	_expect(_near(float(m.get("distance", -1.0)), 4.0, 1e-6) and _vec_near(m.get("point_a", Vector3.ZERO), Vector3(3, 0, 0)), "The same, axis first (%s)." % [m])
	m = INSPECT.measure(_construct("far"), {"kind": "origin", "name": "xz"}, ctx)
	_expect(_near(float(m.get("distance", -1.0)), 4.0, 1e-6), "A point 4 m above the ground plane should measure 4 m (%s)." % [m])
	m = INSPECT.measure(_construct("x0"), _construct("z10"), ctx)
	var crossing: Vector3 = m.get("point_a", Vector3.ONE)
	_expect(absf(float(m.get("distance", -1.0))) < POSITION_TOLERANCE and _near(float(m.get("angle", -1.0)), PI / 2.0, 1e-9)
		and absf(crossing.x) < POSITION_TOLERANCE and absf(crossing.z - 10.0) < 1e-5,
		"Crossing planes meet (distance 0 on both planes, 90 deg) (%s)." % [m])
	m = INSPECT.measure({"kind": "origin", "name": "xy"}, _construct("z10"), ctx)
	_expect(_near(float(m.get("distance", -1.0)), 10.0, 1e-6) and _near(float(m.get("angle", -1.0)), 0.0, 1e-9), "Parallel planes 10 m apart (%s)." % [m])
	m = INSPECT.measure({"kind": "origin", "name": "xy"}, _construct("z10_noisy"), ctx)
	_expect(_near(float(m.get("distance", -1.0)), 10.0, 1e-6), "Planes parallel up to float noise are still 10 m apart (%s)." % [m])
	m = INSPECT.measure({"kind": "origin", "name": "xy"}, _construct("z10_tilted"), ctx)
	_expect(absf(float(m.get("distance", -1.0))) < POSITION_TOLERANCE and _near(float(m.get("angle", -1.0)), deg_to_rad(1.0), 1e-6),
		"A plane tilted 1 degree meets the XY plane (%s)." % [m])
	m = INSPECT.measure({"kind": "origin", "name": "y"}, _construct("skew"), ctx)
	_expect(_near(float(m.get("distance", -1.0)), 5.0, 1e-6) and _vec_near(m.get("point_a", Vector3.ZERO), Vector3(0, 2, 0))
		and _vec_near(m.get("point_b", Vector3.ZERO), Vector3(0, 2, 5)) and _near(float(m.get("angle", -1.0)), PI / 2.0, 1e-9),
		"Skew axes are 5 m apart between (0, 2, 0) and (0, 2, 5) (%s)." % [m])
	m = INSPECT.measure(_construct("skew"), _construct("x0"), ctx)
	_expect(absf(float(m.get("distance", -1.0))) < POSITION_TOLERANCE and _vec_near(m.get("point_a", Vector3.ZERO), Vector3(0, 2, 5))
		and _near(float(m.get("angle", -1.0)), PI / 2.0, 1e-9), "An axis piercing a plane meets it (%s)." % [m])
	m = INSPECT.measure({"kind": "origin", "name": "y"}, _construct("z10"), ctx)
	_expect(_near(float(m.get("distance", -1.0)), 10.0, 1e-6) and _near(float(m.get("angle", -1.0)), 0.0, 1e-9), "An axis parallel to a plane, 10 m off (%s)." % [m])


## Sketch curves, points and profiles; a construction line far outside the model.
func _check_sketch_measures() -> void:
	_new_doc()
	var sketch: Resource = doc.add_feature("sketch", "Sketch", {}, SKETCH_DATA.new_options(SKETCH_DATA.ORIGIN_PLANES.xy, "xy"))
	var s = SKETCH_DATA.new(sketch, doc)
	var c := Vector2(0.05, 0.02)
	var r := 0.01
	var arc: int = s.add_arc(s.add_point(c), s.add_point(c + Vector2(r, 0)), s.add_point(c + Vector2(0, r)))
	var tip: int = s.add_point(Vector2(0.03, 0.04))
	var line: int = s.add_line(s.add_point(Vector2.ZERO), tip)
	s.add_circle(s.add_point(Vector2(-0.05, 0)), r)
	var far_line: int = s.add_line(s.add_point(Vector2(2, 3)), s.add_point(Vector2(4, 3)), true)
	_rebuild()
	_no_errors("Measure sketch")
	var ctx := INSPECT.context(result, doc, kernel)
	var curve := func(entity: int) -> Dictionary: return {"kind": "sketch_curve", "sketch": sketch.id, "entity": entity}
	var m := INSPECT.measure(curve.call(arc), {}, ctx)
	_expect(m.get("kind", "") == "curve" and _near(float(m.get("radius", -1.0)), r, 1e-6) and _near(float(m.get("length", -1.0)), r * PI / 2.0, 1e-6),
		"A quarter arc measures its radius and length (%s)." % [m])
	m = INSPECT.measure(curve.call(line), {}, ctx)
	_expect(_near(float(m.get("length", -1.0)), 0.05, 1e-6) and _vec_near(m.get("direction", Vector3.ZERO), Vector3(0.6, 0.8, 0)), "A sketch line's length and direction (%s)." % [m])
	m = INSPECT.measure({"kind": "sketch_point", "sketch": sketch.id, "entity": tip}, {}, ctx)
	_expect(_vec_near(m.get("position", Vector3.ZERO), Vector3(0.03, 0.04, 0)), "A sketch point's position (%s)." % [m])
	var profile := {"kind": "profile", "sketch": sketch.id, "point": Vector2(-0.05, 0)}
	m = INSPECT.measure(profile, {}, ctx)
	_expect(_near(float(m.get("area", -1.0)), PI * r * r, 1e-6), "A circle profile's area (%s)." % [m])
	m = INSPECT.measure(curve.call(line), profile, ctx)
	_expect(_near(float(m.get("angle", -1.0)), 0.0, 1e-9), "A sketch line lies in its profile's plane: 0 deg (%s)." % [m])
	m = INSPECT.measure(curve.call(line), {"kind": "origin", "name": "z"}, ctx)
	_expect(_near(float(m.get("angle", -1.0)), PI / 2.0, 1e-9) and absf(float(m.get("distance", -1.0))) < POSITION_TOLERANCE,
		"A sketch line from the origin is square to the Z axis and touches it (%s)." % [m])
	m = INSPECT.measure(curve.call(far_line), {"kind": "origin", "name": "xz"}, ctx)
	_expect(_near(float(m.get("distance", -1.0)), 3.0, 1e-6) and _near(float(m.get("angle", -1.0)), 0.0, 1e-9),
		"A construction line 3 m up and 2-4 m out runs parallel to the ground plane, 3 m above it (%s)." % [m])


## The combined inertia of two separate boxes (Aluminum and Steel) about their shared center:
## m (b^2 + c^2) / 12 per box, moved there with the parallel axis theorem (worked in doubles).
func _check_inertia() -> void:
	_new_doc()
	doc.physical_materials = {"body:a": "Aluminum", "body:b": "Steel"}
	# size x, y, z; min corner x, y, z; density.
	var boxes := [[0.02, 0.04, 0.06, 0.0, 0.0, 0.0, 2700.0], [0.03, 0.01, 0.02, 0.1, 0.05, 0.03, 7850.0]]
	var bodies := {}
	var masses: Array[float] = []
	var centers: Array[PackedFloat64Array] = []
	var total := 0.0
	var mc := PackedFloat64Array([0.0, 0.0, 0.0])
	for i in boxes.size():
		var spec: Array = boxes[i]
		bodies["a" if i == 0 else "b"] = {"shape": kernel.make_box(Vector3(spec[0], spec[1], spec[2]), Vector3(spec[3], spec[4], spec[5]), "inertia%d" % i)}
		var mass: float = spec[0] * spec[1] * spec[2] * spec[6]
		var center := PackedFloat64Array([spec[3] + spec[0] * 0.5, spec[4] + spec[1] * 0.5, spec[5] + spec[2] * 0.5])
		masses.append(mass)
		centers.append(center)
		total += mass
		for k in 3:
			mc[k] += mass * center[k]
	var shared := PackedFloat64Array([mc[0] / total, mc[1] / total, mc[2] / total])
	var expected := PackedFloat64Array()
	expected.resize(9)
	expected.fill(0.0)
	for i in boxes.size():
		var spec: Array = boxes[i]
		var d := PackedFloat64Array([centers[i][0] - shared[0], centers[i][1] - shared[1], centers[i][2] - shared[2]])
		var d2 := d[0] * d[0] + d[1] * d[1] + d[2] * d[2]
		for row in 3:
			for col in 3:
				var own := 0.0
				if row == col:
					var s2: float = spec[0] * spec[0] + spec[1] * spec[1] + spec[2] * spec[2] - spec[row] * spec[row]
					own = masses[i] * s2 / 12.0
				expected[row * 3 + col] += own + masses[i] * ((d2 if row == col else 0.0) - d[row] * d[col])
	var props := INSPECT.mass_properties(doc, {"bodies": bodies}, [])
	var inertia: PackedFloat64Array = props.get("inertia", PackedFloat64Array())
	var largest := 0.0
	for v in expected:
		largest = maxf(largest, absf(v))
	var off := 0
	for k in 9:
		off += 0 if inertia.size() == 9 and absf(inertia[k] - expected[k]) <= largest * 1e-6 else 1
	_expect(off == 0 and _near(float(props.mass), total, 1e-6) and props.bodies.a.material == "Aluminum" and props.bodies.b.material == "Steel",
		"Two boxes' combined inertia should match the box formula and parallel axis theorem (%d of 9 off: %s vs %s)." % [off, inertia, expected])


# --- Interference ----------------------------------------------------------------------------

func _check_interference() -> void:
	var a: RefCounted = kernel.make_box(Vector3(40, 20, 30) * MM, Vector3.ZERO, "ia")
	var b: RefCounted = kernel.make_box(Vector3(20, 20, 20) * MM, Vector3(30, 10, 20) * MM, "ib")
	var touching: RefCounted = kernel.make_box(Vector3(10, 10, 10) * MM, Vector3(40, 0, 0) * MM, "ic")
	var bodies := {"a": {"shape": a}, "b": {"shape": b}, "c": {"shape": touching}}
	var found := INSPECT.interference(kernel, bodies, [])
	_expect(found.size() == 1, "Only the overlapping pair should interfere (%s)." % [found])
	if found.size() == 1:
		var hit: Dictionary = found[0]
		_expect([hit.a, hit.b] == ["a", "b"] and _near(float(hit.volume), 1000 * MM3, 1e-6) and hit.shape != null,
			"The overlap of the boxes is 10 x 10 x 10 mm (got %s)." % [hit.volume])
	_expect(INSPECT.interference(kernel, bodies, ["a", "c"]).is_empty(), "Touching boxes don't interfere.")
	# A box nested inside another interferes by its whole volume; a box sitting in an L's notch
	# (bounds overlap, solids don't) doesn't.
	var nested: RefCounted = kernel.make_box(Vector3(10, 10, 10) * MM, Vector3(5, 5, 5) * MM, "id")
	found = INSPECT.interference(kernel, {"a": {"shape": a}, "d": {"shape": nested}}, [])
	_expect(found.size() == 1 and _near(float(found[0].volume), 1000 * MM3, 1e-6), "A nested box interferes by its own volume (%s)." % [found])
	var l: RefCounted = kernel.boolean(kernel.make_box(Vector3(60, 10, 40) * MM, Vector3.ZERO, "il1"), kernel.make_box(Vector3(10, 50, 40) * MM, Vector3.ZERO, "il2"), 0, "il")
	var notch: RefCounted = kernel.make_box(Vector3(20, 20, 20) * MM, Vector3(20, 20, 10) * MM, "in")
	_expect((l.bbox() as AABB).intersects(notch.bbox()) and INSPECT.interference(kernel, {"l": {"shape": l}, "n": {"shape": notch}}, []).is_empty(),
		"A box in an L's notch doesn't interfere, though their bounds overlap.")


## Overlaps added to the design: as components (each body in a new component of its own, named
## "Interference N" and numbered across the document), or as plain bodies in the active component.
func _check_interference_components() -> void:
	_new_doc()
	_box(Vector3(20, 0, 15), 40, 20, 30)
	_box(Vector3(40, 10, 30), 20, 20, 20)
	_rebuild()
	_no_errors("Interference components")
	var found := INSPECT.interference(kernel, result.bodies, [])
	_expect(found.size() == 1, "The two boxes should overlap once (%s)." % [found])
	if found.size() != 1:
		return
	var breps := [found[0].shape.to_brep_bytes()]
	var added := INSPECT.add_overlaps(doc, breps, true)
	var feature: Resource = added.feature
	var body: String = added.bodies[0] if added.bodies.size() == 1 else ""
	var component: String = added.components[0] if added.components.size() == 1 else ""
	_expect(feature.type == "base_feature" and body != "" and component != "" and doc.body_component(body) == component
		and doc.component_name(component) == "Interference 1" and str(doc.components[component].get("feature", "")) == feature.id
		and str(doc.components[component].get("parent", "-")) == "",
		"Create Components should put the overlap body in its own component 'Interference 1' (%s, %s)." % [added, doc.components])
	_rebuild()
	_no_errors("Interference component body")
	_expect(_shape(body) != null and _near(_shape(body).volume(), 1000 * MM3, 1e-6), "The overlap body should be the 10 x 10 x 10 mm common volume.")
	# A second time the numbering goes on; inside an active component the new ones nest in it.
	doc.active_component = component
	var nested := INSPECT.add_overlaps(doc, breps + breps, true)
	_expect(nested.components.size() == 2 and doc.component_name(nested.components[0]) == "Interference 2" and doc.component_name(nested.components[1]) == "Interference 3"
		and str(doc.components[nested.components[0]].parent) == component and doc.body_component(nested.bodies[1]) == nested.components[1],
		"More overlap components should be numbered on and nest in the active component (%s)." % [doc.components])
	doc.active_component = ""
	var plain := INSPECT.add_overlaps(doc, breps, false)
	_expect(plain.components.is_empty() and plain.bodies.size() == 1 and doc.body_component(plain.bodies[0]) == "" and doc.components.size() == 3,
		"Create Bodies adds no components (%s)." % [plain])
	_rebuild()
	_no_errors("Interference bodies")
	_expect(result.bodies.size() == 6, "Two boxes and four overlap bodies (%s)." % [result.bodies.keys()])
	doc.remove_feature(feature.id)
	_expect(not doc.components.has(component) and not doc.bodies.has(body), "Removing the feature should take its components and bodies away.")


# --- Analyses --------------------------------------------------------------------------------

func _check_curvature_map() -> void:
	_new_doc()
	var sphere := _add("sphere", {"diameter": "20 mm"}, {"position": Vector3(0.1, 0.02, 0), "operation": OPERATIONS.NEW_BODY})
	_rebuild()
	_no_errors("Sphere")
	var body := _body(sphere)
	var r := 0.01
	var out := _analysis("curvature_map", {"mode": "gaussian"})
	var values: PackedFloat64Array = out.values.get(body, PackedFloat64Array())
	var bad := 0
	for v in values:
		bad += 0 if _near(v, 1.0 / (r * r), 1e-6) else 1
	_expect(values.size() > 100 and bad == 0, "Every sphere vertex should have Gaussian curvature 1/r^2 (%d of %d off)." % [bad, values.size()])
	_expect(_mesh_colors(out, body).size() == values.size() and out.body_materials.has(body), "The curvature map should color every vertex.")
	out = _analysis("curvature_map", {"mode": "mean"})
	bad = 0
	for v in out.values.get(body, PackedFloat64Array()):
		bad += 0 if _near(v, 1.0 / r, 1e-6) else 1
	_expect(bad == 0, "Every sphere vertex should have mean curvature 1/r (%d off)." % bad)
	var unknown := ANALYSIS.build({"type": "curvature_map", "options": {"mode": "nope"}}, result, {}, kernel, doc)
	_expect(unknown.has("error") and unknown.body_meshes.is_empty(), "An unknown curvature mode should be an error.")


## A 5 mm hole is concave: mean curvature -1/(2r) (flat faces 0), and Minimum Radius at 6 mm flags
## exactly the hole's vertices.
func _check_concave_curvature() -> void:
	var r := 0.005
	var hole: RefCounted = kernel.make_cylinder(r, 0.03, Vector3(0, -0.005, 0), Vector3.UP, "hc")
	var shape: RefCounted = kernel.boolean(kernel.make_box(Vector3(30, 20, 30) * MM, Vector3(-15, 0, -15) * MM, "hb"), hole, 1, "hh")
	var tess := TESSELLATE.tessellate(shape)
	var faces := _vertex_faces(tess)
	var fake := {"bodies": {"h": {"shape": shape}}}
	var out := ANALYSIS.build({"type": "curvature_map", "options": {"mode": "mean"}}, fake, {"h": tess}, kernel, null)
	var values: PackedFloat64Array = out.values.get("h", PackedFloat64Array())
	var on_hole := 0
	var wrong := 0
	for i in values.size():
		if shape.face_info(faces[i]).type == "cylinder":
			on_hole += 1
			wrong += 0 if _near(values[i], -0.5 / r, 1e-6) else 1
		else:
			wrong += 0 if values[i] == 0.0 else 1
	_expect(on_hole > 0 and wrong == 0, "A hole's mean curvature is -1/(2r) and flat faces are 0 (%d hole vertices, %d wrong)." % [on_hole, wrong])
	out = ANALYSIS.build({"type": "minimum_radius", "options": {"radius": 0.006}}, fake, {"h": tess}, kernel, null)
	var colors := _mesh_colors(out, "h")
	wrong = 0
	for i in colors.size():
		var below := _color_near(colors[i], ANALYSIS.MIN_RADIUS_COLORS.below)
		wrong += 0 if below == (shape.face_info(faces[i]).type == "cylinder") else 1
	_expect(colors.size() == values.size() and wrong == 0, "Minimum Radius 6 mm flags exactly the 5 mm hole (%d wrong)." % wrong)


func _check_minimum_radius() -> void:
	_new_doc()
	var box := _box(Vector3.ZERO, 40, 20, 30)
	_rebuild()
	_add("fillet", {"radius": "2 mm"}, {"edges": [_edge_ref(_body(box), Vector3.BACK, 0.03)]})
	_rebuild()
	_no_errors("Filleted box")
	var body := _body(box)
	var shape := _shape(body)
	var tess := TESSELLATE.tessellate(shape)
	var faces := _vertex_faces(tess)
	var fillet_face := -1
	for f in shape.face_count():
		if shape.face_info(f).type == "cylinder":
			fillet_face = f
	_expect(fillet_face >= 0, "The fillet should make a cylindrical face.")
	var out := _analysis("minimum_radius", {"radius": 0.003}, {body: tess})
	var colors := _mesh_colors(out, body)
	var wrong := 0
	var flagged := 0
	for i in colors.size():
		var below := _color_near(colors[i], ANALYSIS.MIN_RADIUS_COLORS.below)
		flagged += 1 if below else 0
		wrong += 0 if below == (faces[i] == fillet_face) else 1
	_expect(colors.size() == faces.size() and flagged > 0 and wrong == 0, "With 3 mm, exactly the fillet's vertices are flagged (%d flagged, %d wrong)." % [flagged, wrong])
	var radii: PackedFloat64Array = out.values.get(body, PackedFloat64Array())
	for i in radii.size():
		if faces[i] == fillet_face and not _near(radii[i], 0.002, 1e-6):
			_expect(false, "The fillet's radius of curvature should be 2 mm (got %s)." % radii[i])
			break
	out = _analysis("minimum_radius", {"radius": 0.001}, {body: tess})
	flagged = 0
	for c in _mesh_colors(out, body):
		flagged += 1 if _color_near(c, ANALYSIS.MIN_RADIUS_COLORS.below) else 0
	_expect(flagged == 0, "With 1 mm, nothing is flagged (%d flagged)." % flagged)


func _check_draft() -> void:
	_new_doc()
	var box := _box(Vector3.ZERO, 40, 20, 30)
	_rebuild()
	_add("draft", {"angle": ["5 deg", "angle"]}, {"faces": [_face_at(_body(box), Vector3.RIGHT, Vector3(0.02, 0, 0))], "plane": [{"kind": "origin", "name": "xz"}]})
	_rebuild()
	_no_errors("Drafted box")
	var body := _body(box)
	var shape := _shape(body)
	var tess := TESSELLATE.tessellate(shape)
	var faces := _vertex_faces(tess)
	var drafted := -1
	var vertical := []
	var flat := []
	for f in shape.face_count():
		var n: Vector3 = shape.face_info(f).normal
		if absf(n.y) < 1e-6:
			vertical.append(f)
		elif absf(absf(n.y) - 1.0) < 1e-6:
			flat.append(f)
		else:
			drafted = f
	_expect(drafted >= 0 and vertical.size() == 3 and flat.size() == 2, "The drafted box should have 1 drafted, 3 vertical and 2 flat faces.")
	var out := _analysis("draft", {"pull": Vector3.UP, "angle": deg_to_rad(3.0)}, {body: tess})
	var colors := _mesh_colors(out, body)
	var counts := {"drafted": 0, "vertical": 0, "flat": 0, "wrong": 0}
	for i in colors.size():
		var expected: Color
		if faces[i] == drafted:
			expected = ANALYSIS.DRAFT_COLORS.positive
			counts.drafted += 1
		elif vertical.has(faces[i]):
			expected = ANALYSIS.DRAFT_COLORS.needs
			counts.vertical += 1
		else:
			expected = ANALYSIS.DRAFT_COLORS.square
			counts.flat += 1
		counts.wrong += 0 if _color_near(colors[i], expected) else 1
	_expect(counts.drafted > 0 and counts.vertical > 0 and counts.wrong == 0,
		"The drafted face should be 'drafted', the vertical faces 'needs draft' and top/bottom 'square' (%s)." % [counts])
	var angles: PackedFloat64Array = out.values.get(body, PackedFloat64Array())
	for i in angles.size():
		if faces[i] == drafted:
			_expect(_near(angles[i], deg_to_rad(5.0), 1e-5), "The drafted face's draft angle should be 5 deg (got %s)." % rad_to_deg(angles[i]))
			break
	# Pulling down turns the drafted face into an undercut.
	out = _analysis("draft", {"pull": Vector3.DOWN}, {body: tess})
	colors = _mesh_colors(out, body)
	for i in colors.size():
		if faces[i] == drafted:
			_expect(_color_near(colors[i], ANALYSIS.DRAFT_COLORS.negative), "Pulled the other way, the drafted face is an undercut.")
			break


func _check_isocurve() -> void:
	_new_doc()
	var cylinder := _add("cylinder", {"diameter": "20 mm", "height": "30 mm"}, {"position": Vector3.ZERO, "operation": OPERATIONS.NEW_BODY})
	_rebuild()
	_no_errors("Cylinder")
	var body := _body(cylinder)
	var out := _analysis("isocurve", {"u_count": 3, "v_count": 2})
	var off := 0
	for line in out.lines:
		for p in line.points:
			off += 0 if absf(Vector2(p.x, p.z).length() - 0.01) < POSITION_TOLERANCE else 1
	_expect(out.lines.size() == 5 and off == 0, "A cylinder should get 3 + 2 isocurves on its round face (%d lines, %d points off)." % [out.lines.size(), off])
	_expect(_analysis("isocurve", {"u_count": 1, "v_count": 1, "planar": true}).lines.size() == 6, "With planar faces too, each of the 3 faces gets 2 lines.")
	# Measure on a round face reports its radius.
	var shape := _shape(body)
	for f in shape.face_count():
		if shape.face_info(f).type == "cylinder":
			var ref := {"kind": "face", "body": body, "name": shape.get_face_names()[f], "sig": {}}
			var m := INSPECT.measure(ref, {}, INSPECT.context(result, doc, kernel))
			_expect(_near(float(m.get("radius", -1.0)), 0.01, 1e-6) and _near(float(m.get("diameter", -1.0)), 0.02, 1e-6), "A cylinder face measures its radius (%s)." % [m])


## Isocurves are trimmed to their face: on a 30 x 20 x 30 mm box with a 5 mm hole down Y, every
## point lies on its own face, and lines across the top face stop at the hole's rim.
func _check_trimmed_isocurves() -> void:
	var r := 0.005
	var hole: RefCounted = kernel.make_cylinder(r, 0.03, Vector3(0, -0.005, 0), Vector3.UP, "th")
	var shape: RefCounted = kernel.boolean(kernel.make_box(Vector3(30, 20, 30) * MM, Vector3(-15, 0, -15) * MM, "tb"), hole, 1, "tc")
	var off := 0
	var points := 0
	var runs_total := 0
	var top := -1
	var wall := -1
	for f in shape.face_count():
		var info: Dictionary = shape.face_info(f)
		if info.type == "cylinder":
			wall = f
		elif (info.normal as Vector3).is_equal_approx(Vector3.UP) and absf((info.point as Vector3).y - 0.02) < POSITION_TOLERANCE:
			top = f
		var face: RefCounted = shape.face_shape(f)
		var runs: Array = shape.face_isocurves(f, 4, 4, 24)
		runs_total += runs.size()
		for run in runs:
			for p in run.points:
				points += 1
				off += 0 if float(kernel.closest_points(face, kernel.make_vertex(p)).get("distance", 1.0)) < POSITION_TOLERANCE else 1
	_expect(top >= 0 and wall >= 0 and points > 500 and off == 0, "Every isocurve point should lie on its own face (%d of %d off)." % [off, points])
	# Top face lines at -9, -3, 3 and 9 mm each way: the two at +-3 mm cross the hole and split.
	var runs: Array = shape.face_isocurves(top, 4, 4, 24) if top >= 0 else []
	var inside := 0
	var on_rim := 0
	for run in runs:
		var pts: PackedVector3Array = run.points
		for p in pts:
			inside += 1 if Vector2(p.x, p.z).length() < r - POSITION_TOLERANCE else 0
		for end in [pts[0], pts[pts.size() - 1]]:
			on_rim += 1 if absf(Vector2(end.x, end.z).length() - r) < POSITION_TOLERANCE else 0
	_expect(runs.size() == 12 and inside == 0 and on_rim == 8,
		"The top face's lines should split at the hole and stop on its rim (%d runs, %d points in the hole, %d ends on the rim)." % [runs.size(), inside, on_rim])
	# The hole's circles curve by 1/r toward its axis; its straight lines don't curve.
	var bad := 0
	for run in shape.face_isocurves(wall, 2, 2, 24) if wall >= 0 else []:
		var pts: PackedVector3Array = run.points
		var ks: PackedFloat64Array = run.curvature
		var normals: PackedVector3Array = run.normals
		var is_circle := _circle_direction(run) == str(run.direction)
		for i in pts.size():
			var radial := Vector3(pts[i].x, 0.0, pts[i].z).normalized()
			var curved: bool = _near(ks[i], 1.0 / r, 1e-6) and normals[i].dot(-radial) > 0.999999
			var straight: bool = ks[i] == 0.0 and normals[i] == Vector3.ZERO
			bad += 0 if (curved if is_circle else straight) else 1
	_expect(bad == 0, "The hole's circles should curve by 1/r toward the axis and its rulings be straight (%d bad)." % bad)
	# The analysis shows the same trimmed lines (flat faces too).
	var out := ANALYSIS.build({"type": "isocurve", "options": {"u_count": 4, "v_count": 4, "planar": true}}, {"bodies": {"h": {"shape": shape}}}, {}, kernel, null)
	var in_hole := 0
	for line in out.lines:
		for p in line.points:
			in_hole += 1 if (absf(p.y) < 1e-9 or absf(p.y - 0.02) < 1e-9) and Vector2(p.x, p.z).length() < r - POSITION_TOLERANCE else 0
	_expect(not out.has("error") and out.lines.size() > 0 and in_hole == 0, "The isocurve analysis should keep its lines off the hole (%d lines, %d points in it)." % [out.lines.size(), in_hole])


## "u" or "v": which iso direction of a cylinder run is its circle (the one whose points all share
## a height).
func _circle_direction(run: Dictionary) -> String:
	var pts: PackedVector3Array = run.points
	var level := true
	for p in pts:
		level = level and absf(p.y - pts[0].y) < 1e-9
	return str(run.direction) if level else ("v" if str(run.direction) == "u" else "u")


## The teeth of a comb analysis: [[root, tip], ...].
func _teeth(out: Dictionary) -> Array:
	var found := []
	for line in out.lines:
		if line.color == ANALYSIS.COMB_COLORS.teeth:
			found.append([line.points[0], line.points[1]])
	return found


## The automatic tooth size of combs whose teeth stand on roots, all of curvature k: the longest
## tooth is 15% of the roots' bounds.
func _auto_tooth(teeth: Array) -> float:
	var box := AABB()
	for i in teeth.size():
		box = AABB(teeth[i][0], Vector3.ZERO) if i == 0 else box.expand(teeth[i][0])
	return 0.15 * box.size.length()


## Isocurve combs: a cylinder's circles get equal outward teeth of curvature 1/r; its straight
## lines get none. comb_scale multiplies the automatic size.
func _check_isocurve_combs() -> void:
	_new_doc()
	var cylinder := _add("cylinder", {"diameter": "20 mm", "height": "30 mm"}, {"position": Vector3.ZERO, "operation": OPERATIONS.NEW_BODY})
	_rebuild()
	_no_errors("Comb cylinder")
	var r := 0.01
	var scale := 0.5
	var out := _analysis("isocurve", {"u_count": 2, "v_count": 1, "comb": true, "comb_density": 16, "comb_scale": scale})
	var teeth := _teeth(out)
	var tooth := scale * _auto_tooth(teeth)
	var envelopes := 0
	var wrong := 0
	var circle_y: float = teeth[0][0].y if not teeth.is_empty() else -1.0
	for line in out.lines:
		envelopes += 1 if line.color == ANALYSIS.COMB_COLORS.envelope else 0
	for t in teeth:
		var root: Vector3 = t[0]
		var tip: Vector3 = t[1]
		# Every tooth stands on the one circle (none on the straight lines), half the auto size, outward.
		if absf(root.y - circle_y) > 1e-9 or not _near(Vector2(root.x, root.z).length(), r, 1e-5) or not _near(root.distance_to(tip), tooth, 1e-5) \
				or not _near(Vector2(tip.x, tip.z).length(), r + tooth, 1e-5):
			wrong += 1
	# 64 samples round the circle, every 4th one (16 teeth) and the closing one.
	_expect(teeth.size() == 17 and envelopes == 1 and wrong == 0,
		"Only the cylinder's circle should get a comb: 17 equal teeth of half the auto size standing outward and one envelope (%d teeth, %d envelopes, %d wrong)." % [teeth.size(), envelopes, wrong])
	_expect(str(out.info).contains("3 isocurves") and str(out.info).contains("largest curvature"), "The readout should count the isocurves and give the largest curvature (%s)." % out.info)
	# Raw curvature from the kernel: 1/r on the circle, 0 on the straight lines.
	var shape := _shape(_body(cylinder))
	var straight := 0
	var circles := 0
	var bad := 0
	for f in shape.face_count():
		if shape.face_info(f).type != "cylinder":
			continue
		for run in shape.face_isocurves(f, 2, 1, 32):
			var ks: PackedFloat64Array = run.curvature
			var is_circle := _circle_direction(run) == str(run.direction)
			circles += 1 if is_circle else 0
			straight += 0 if is_circle else 1
			for k in ks:
				bad += 0 if (_near(k, 1.0 / r, 1e-6) if is_circle else k == 0.0) else 1
	_expect(circles == 1 and straight == 2 and bad == 0, "A cylinder's circle should curve by exactly 1/r and its lines by 0 (%d circles, %d lines, %d bad)." % [circles, straight, bad])
	# Auto scale: the longest tooth is 15% of the combed points' size.
	out = _analysis("isocurve", {"u_count": 0, "v_count": 1, "comb": true})
	var longest := 0.0
	var roots := AABB()
	var first := true
	for line in out.lines:
		if line.color == ANALYSIS.COMB_COLORS.teeth:
			longest = maxf(longest, (line.points[0] as Vector3).distance_to(line.points[1]))
			roots = AABB(line.points[0], Vector3.ZERO) if first else roots.expand(line.points[0])
			first = false
	_expect(not first and _near(longest, 0.15 * roots.size.length(), 1e-5), "Auto comb scale should make the longest tooth 15%% of the curves' size (got %s)." % longest)
	# Without combs (and for flat faces' straight lines) there are no teeth.
	out = _analysis("isocurve", {"u_count": 1, "v_count": 1, "planar": true})
	_expect(out.lines.all(func(line: Dictionary) -> bool: return line.color != ANALYSIS.COMB_COLORS.teeth), "Isocurves without combs have no teeth.")


func _check_combs() -> void:
	_new_doc()
	# A quarter arc of radius 10 mm about (50, 20) mm on the XY plane.
	var sketch: Resource = doc.add_feature("sketch", "Sketch", {}, SKETCH_DATA.new_options(SKETCH_DATA.ORIGIN_PLANES.xy, "xy"))
	var s = SKETCH_DATA.new(sketch, doc)
	var c := Vector2(0.05, 0.02)
	var r := 0.01
	s.add_arc(s.add_point(c), s.add_point(c + Vector2(r, 0)), s.add_point(c + Vector2(0, r)))
	var cylinder := _add("cylinder", {"diameter": "20 mm", "height": "30 mm"}, {"position": Vector3(0, 0, 0.2), "operation": OPERATIONS.NEW_BODY})
	_rebuild()
	_no_errors("Comb sketch")
	var scale := 2.0
	var out := _analysis("curvature_comb", {"sketch": sketch.id, "density": 16, "scale": scale})
	var teeth := _teeth(out)
	var tooth := scale * _auto_tooth(teeth)
	var wrong := 0
	var center := Vector3(c.x, c.y, 0.0)
	for t in teeth:
		var root: Vector3 = t[0]
		var tip: Vector3 = t[1]
		# Equal teeth of twice the automatic size, standing outside the arc.
		if not _near(root.distance_to(tip), tooth, 1e-5) or not _near(tip.distance_to(center), r + tooth, 1e-5):
			wrong += 1
	_expect(teeth.size() == 16 and wrong == 0, "An arc's comb should have 16 equal teeth of twice the auto size, outward (%d teeth, %d wrong)." % [teeth.size(), wrong])
	_expect(out.lines.size() == 17, "The comb should include its envelope.")
	# Edge combs: a cylinder's two circular edges (its seam line is skipped).
	out = _analysis("curvature_comb", {"edges": [{"kind": "body", "body": _body(cylinder)}], "density": 8, "scale": scale})
	teeth = _teeth(out)
	tooth = scale * _auto_tooth(teeth)
	wrong = 0
	for t in teeth:
		# Edge teeth stand outside too: the tip is r + tooth from the cylinder's axis.
		var tip: Vector3 = t[1]
		wrong += 0 if _near((t[0] as Vector3).distance_to(tip), tooth, 1e-5) and _near(Vector2(tip.x, tip.z - 0.2).length(), r + tooth, 1e-5) else 1
	_expect(teeth.size() == 16 and wrong == 0, "A cylinder's edge combs should have equal outward teeth of twice the auto size (%d teeth, %d wrong)." % [teeth.size(), wrong])


func _check_section() -> void:
	_new_doc()
	var box := _box(Vector3.ZERO, 40, 20, 30)
	_rebuild()
	var body := _body(box)
	var out := _analysis("section", {"origin": Vector3(0, 0.01, 0), "normal": Vector3.RIGHT})
	_expect(out.meshes.size() == 1, "Sectioning a box should give one cap (%d)." % out.meshes.size())
	if out.meshes.size() == 1:
		_expect(_near(_mesh_area(out.meshes[0].mesh), 20 * 30 * MM2, 1e-6), "The cap of a 40 x 20 x 30 box cut across X is 20 x 30 mm (got %s mm^2)." % (_mesh_area(out.meshes[0].mesh) / MM2))
	var material: ShaderMaterial = out.body_materials.get(body)
	_expect(material != null and material.shader == ANALYSIS.SECTION_SHADER and (material.get_shader_parameter("plane_normal") as Vector3).is_equal_approx(Vector3.RIGHT),
		"Bodies should get the section clip material.")
	out = _analysis("section", {"normal": Vector3.UP, "flip": true})
	_expect(out.meshes.size() == 1 and _near(_mesh_area(out.meshes[0].mesh), 40 * 30 * MM2, 1e-6)
		and (out.body_materials[body].get_shader_parameter("plane_normal") as Vector3).is_equal_approx(Vector3.DOWN),
		"By default the section goes through the model's center (40 x 30 mm across Y), flipped.")


## A turned section on the 40 x 20 x 30 mm box: the YZ-like plane (normal +X, default x axis -Z,
## y axis +Y) tilted about its x axis and spun about its y axis; the cap and the clip shader follow.
func _check_section_rotation() -> void:
	_new_doc()
	var box := _box(Vector3.ZERO, 40, 20, 30)
	_rebuild()
	var body := _body(box)
	var center := Vector3(0, 0.01, 0)
	var unturned := ANALYSIS.section_basis(Vector3.RIGHT, Vector3.ZERO, 0.0, 0.0)
	_expect(unturned.x == Vector3.FORWARD and unturned.y == Vector3.UP and unturned.z == Vector3.RIGHT, "The unturned frame of a +X normal should be (-Z, +Y, +X) (%s)." % [unturned])
	# [tilt, spin, x axis, expected normal, expected cap area in mm^2]
	var cases := [
		[90.0, 0.0, Vector3.ZERO, Vector3.DOWN, 40 * 30],
		[90.0, 90.0, Vector3.ZERO, Vector3.FORWARD, 40 * 20],
		[0.0, 90.0, Vector3.ZERO, Vector3.FORWARD, 40 * 20],
		[90.0, 0.0, Vector3.UP, Vector3.FORWARD, 40 * 20],
		# Tilted 45 degrees the cut runs corner to corner of the 40 x 20 side: 20 sqrt(2) x 30 mm.
		[45.0, 0.0, Vector3.ZERO, Vector3(1, -1, 0).normalized(), 600 * sqrt(2.0)],
	]
	for c in cases:
		var out := _analysis("section", {"origin": center, "normal": Vector3.RIGHT, "x": c[2], "tilt": deg_to_rad(c[0]), "spin": deg_to_rad(c[1])})
		var material: ShaderMaterial = out.body_materials.get(body)
		var normal: Vector3 = material.get_shader_parameter("plane_normal") if material != null else Vector3.ZERO
		var area := _mesh_area(out.meshes[0].mesh) / MM2 if out.meshes.size() == 1 else -1.0
		_expect(normal.is_equal_approx(c[3]) and _near(area, float(c[4]), 1e-5) and str(out.info).contains("Section area"),
			"Tilt %s, spin %s (x %s) should cut with normal %s and a %s mm^2 cap (got %s, %s mm^2)." % [c[0], c[1], c[2], c[3], c[4], normal, area])
	var flipped := _analysis("section", {"origin": center, "normal": Vector3.RIGHT, "tilt": PI / 2.0, "flip": true})
	_expect((flipped.body_materials[body].get_shader_parameter("plane_normal") as Vector3).is_equal_approx(Vector3.UP), "Flip should turn the turned normal round.")


func _check_display_analyses() -> void:
	_new_doc()
	var loose := _box(Vector3.ZERO, 40, 20, 30)
	var part := _box(Vector3(100, 0, 0), 10, 10, 10, OPERATIONS.NEW_COMPONENT)
	part.options["component_id"] = doc.new_component(part.id)
	doc.bodies[_body(part)]["component"] = part.options.component_id
	_rebuild()
	_no_errors("Display analyses")
	var zebra := _analysis("zebra", {"stripes": 8, "direction": "vertical"})
	var zm: ShaderMaterial = zebra.body_materials.get(_body(loose))
	_expect(zebra.body_materials.size() == 2 and zm != null and zm.shader == ANALYSIS.ZEBRA_SHADER and zm.get_shader_parameter("vertical") == true,
		"Zebra should give every body the stripe shader.")
	var environment := _analysis("environment_map", {})
	var chrome: StandardMaterial3D = environment.body_materials.get(_body(loose))
	_expect(chrome != null and chrome.metallic == 1.0 and is_equal_approx(chrome.roughness, 0.05), "Environment Map should be chrome.")
	# The probe covers both bodies: the 40 x 20 x 30 mm box at the origin and the 10 mm cube at x = 100 mm.
	var probe: Variant = environment.get("reflection_probe")
	_expect(probe is AABB and _vec_near((probe as AABB).position, Vector3(-0.02, 0, -0.015)) and _vec_near((probe as AABB).end, Vector3(0.105, 0.02, 0.015)),
		"Environment Map should ask for a reflection probe over the model's bounds (%s)." % [probe])
	_expect(not _analysis("zebra", {}).has("reflection_probe"), "Only Environment Map asks for a reflection probe.")
	var colors := _analysis("component_colors", {})
	_expect((colors.body_materials[_body(loose)] as StandardMaterial3D).albedo_color == ANALYSIS.TOP_LEVEL_COLOR
		and (colors.body_materials[_body(part)] as StandardMaterial3D).albedo_color == ANALYSIS.component_color(part.options.component_id)
		and ANALYSIS.component_color("comp1") == ANALYSIS.COMPONENT_PALETTE[0], "Component colors: top level grey, components by id.")
	var shape := _shape(_body(loose))
	var tess := TESSELLATE.tessellate(shape)
	var access := _analysis("accessibility", {"direction": Vector3.DOWN}, {_body(loose): tess})
	var faces := _vertex_faces(tess)
	var access_colors := _mesh_colors(access, _body(loose))
	var wrong := 0
	for i in access_colors.size():
		var reachable := (shape.face_info(faces[i]).normal as Vector3).y > 0.5
		wrong += 0 if _color_near(access_colors[i], ANALYSIS.ACCESS_COLORS.reachable if reachable else ANALYSIS.ACCESS_COLORS.blocked) else 1
	_expect(wrong == 0, "From above only the top face is reachable (%d wrong)." % wrong)
	var com := _analysis("center_of_mass", {})
	_expect(com.points.size() == 3, "Center of Mass marks each body and the total (%d points)." % com.points.size())
	# Headless runs still put shaders through Godot's shader compiler: a shader that fails to
	# compile lists no uniforms.
	var shaders := {ANALYSIS.ZEBRA_SHADER: ["stripes", "vertical", "dark_color", "light_color"], ANALYSIS.SECTION_SHADER: ["plane_origin", "plane_normal", "base_color", "inside_color"]}
	for shader: Shader in shaders:
		var names := shader.get_shader_uniform_list().map(func(u: Dictionary) -> String: return str(u.name))
		for wanted in shaders[shader]:
			_expect(names.has(wanted), "%s should compile with uniform %s (got %s)." % [shader.resource_path, wanted, names])
	_expect(ANALYSIS.build({"type": "nope", "options": {}}, result, {}, kernel, doc).has("error"), "An unknown analysis should report an error.")
	var highlight: Shader = ANALYSIS.SECTION_HIGHLIGHT_SHADER
	var highlight_names := highlight.get_shader_uniform_list().map(func(u: Dictionary) -> String: return str(u.name))
	for wanted in ["plane_origin", "plane_normal", "color", "grow_amount"]:
		_expect(highlight_names.has(wanted), "The section highlight shader should compile with uniform %s (got %s)." % [wanted, highlight_names])


# --- Review regressions ----------------------------------------------------------------------

## A 0.1 m cube mesh with its min corner at offset (Godot's clockwise winding seen from outside,
## or the other way round with flip), leaving out the faces listed in skip (1 is the top, +Z):
## [positions, indices] for kernel.mesh_to_shape.
func _cube_mesh(offset: Vector3, skip: Array, flip := false) -> Array:
	var positions := PackedVector3Array()
	for z in 2:
		for y in 2:
			for x in 2:
				positions.append(offset + Vector3(x, y, z) * 0.1)
	# Quads counter-clockwise seen from outside, turned clockwise below.
	var quads := [[0, 2, 3, 1], [4, 5, 7, 6], [0, 1, 5, 4], [2, 6, 7, 3], [0, 4, 6, 2], [1, 3, 7, 5]]
	var indices := PackedInt32Array()
	for q in quads.size():
		if q in skip:
			continue
		var a: Array = quads[q]
		indices.append_array([a[0], a[1], a[2], a[0], a[2], a[3]] if flip else [a[0], a[2], a[1], a[0], a[3], a[2]])
	return [positions, indices]


## Open meshes come in as surfaces (Insert Mesh warns they have no volume): they get no volume or
## mass (either winding), leave a solid's center of mass alone and don't interfere; a body mixing
## a solid with open faces counts only the solid.
func _check_open_shells() -> void:
	_new_doc()
	var open_mesh := _cube_mesh(Vector3(1, 0, 0), [1])
	var open: RefCounted = kernel.mesh_to_shape(open_mesh[0], open_mesh[1], "os")
	var inward_mesh := _cube_mesh(Vector3(1, 0, 0), [1], true)
	var inward: RefCounted = kernel.mesh_to_shape(inward_mesh[0], inward_mesh[1], "oi")
	var solid: RefCounted = kernel.make_box(Vector3(0.1, 0.1, 0.1), Vector3.ZERO, "osolid")
	_expect(open != null and inward != null and open.solid_count() == 0 and INSPECT.shape_kind(open) == "surface" and INSPECT.shape_kind(solid) == "solid",
		"An open cube mesh should be a surface.")
	if open == null or inward == null:
		return
	# The kernel itself counts only closed shells, so raw volume() / mass_properties() callers
	# outside inspect see no pseudo-volume either.
	for surface in [open, inward]:
		_expect(float(surface.volume()) == 0.0 and float(surface.mass_properties(7850.0).mass) == 0.0,
			"The kernel should give an open shell no volume or mass (%s, %s)." % [surface.volume(), surface.mass_properties(7850.0).mass])
	var whole_mesh := _cube_mesh(Vector3(1, 0, 0), [])
	var whole: RefCounted = kernel.mesh_to_shape(whole_mesh[0], whole_mesh[1], "ow")
	# (Mesh positions pass through float32 Vector3s: 1e-6 relative.)
	_expect(whole != null and _near(float(whole.volume()), 0.001, 1e-6), "The closed cube mesh should still be 0.001 m^3 (%s)." % [whole.volume() if whole != null else null])
	var bodies := {"s": {"shape": solid}, "o": {"shape": open}}
	var m := INSPECT.measure({"kind": "body", "body": "o"}, {}, INSPECT.context({"bodies": bodies}, doc, kernel))
	_expect(float(m.get("volume", -1.0)) == 0.0 and bool(m.get("surface", false)) and _near(float(m.get("area", 0.0)), 0.05, 1e-6),
		"An open mesh body should measure no volume, as a surface, with its 0.05 m^2 area (%s)." % [m])
	var props := INSPECT.mass_properties(doc, {"bodies": {"o": {"shape": open}}}, [])
	# The surface's own center is its area's centroid: five 0.01 m^2 faces, the top one missing.
	_expect(float(props.mass) == 0.0 and float(props.volume) == 0.0 and _vec_near(props.center, Vector3(1.05, 0.05, 0.04)),
		"An open mesh should have no mass or volume, centered on its area (%s, %s, %s)." % [props.mass, props.volume, props.center])
	props = INSPECT.mass_properties(doc, {"bodies": {"o": {"shape": inward}}}, [])
	_expect(float(props.mass) == 0.0 and float(props.volume) == 0.0, "Wound the other way it still has no mass (got %s)." % props.mass)
	props = INSPECT.mass_properties(doc, {"bodies": bodies}, [])
	_expect(_near(float(props.mass), 7.85, 1e-6) and _vec_near(props.center, Vector3(0.05, 0.05, 0.05)),
		"Next to a 100 mm steel cube the open mesh shouldn't move its center or add mass (%s kg at %s)." % [props.mass, props.center])
	var com := ANALYSIS.build({"type": "center_of_mass", "options": {}}, {"bodies": bodies}, {}, kernel, doc)
	_expect(str(com.info).begins_with("Mass 7.85 kg, center (50 mm, 50 mm, 50 mm)"), "The Center of Mass readout should be the cube's alone (%s)." % com.info)
	var over_mesh := _cube_mesh(Vector3(0.05, 0.05, 0.05), [1])
	var over: RefCounted = kernel.mesh_to_shape(over_mesh[0], over_mesh[1], "oo")
	var closed_mesh := _cube_mesh(Vector3(0.05, 0.05, 0.05), [])
	var closed: RefCounted = kernel.mesh_to_shape(closed_mesh[0], closed_mesh[1], "oc")
	_expect(INSPECT.interference(kernel, {"s": {"shape": solid}, "ov": {"shape": over}}, []).is_empty(), "A solid and an open mesh through it don't interfere by a volume.")
	var hits := INSPECT.interference(kernel, {"s": {"shape": solid}, "c": {"shape": closed}}, [])
	_expect(hits.size() == 1 and _near(float(hits[0].volume), 0.000125, 1e-6), "The same mesh closed is a solid and overlaps by 50 mm cubed (%s)." % [hits])
	var section := ANALYSIS.build({"type": "section", "options": {"origin": Vector3(1.05, 0.05, 0.05), "normal": Vector3.RIGHT}}, {"bodies": {"o": {"shape": open}}}, {}, kernel, doc)
	_expect(not section.has("error") and section.meshes.is_empty(), "A surface has no inside to cap (%d caps)." % section.meshes.size())
	# A solid 20 x 40 x 60 mm box and the open mesh in one body: only the box has volume and mass.
	var box: RefCounted = kernel.make_box(Vector3(0.02, 0.04, 0.06), Vector3(2, 0, 0), "obox")
	var mixed: RefCounted = kernel.make_compound([box, open])
	var mass := 0.02 * 0.04 * 0.06 * 7850.0
	props = INSPECT.mass_properties(doc, {"bodies": {"x": {"shape": mixed}}}, [])
	var moments: Vector3 = props.bodies.x.principal_moments
	var expected := Vector3(mass * (0.04 * 0.04 + 0.06 * 0.06) / 12.0, mass * (0.02 * 0.02 + 0.06 * 0.06) / 12.0, mass * (0.02 * 0.02 + 0.04 * 0.04) / 12.0)
	_expect(INSPECT.shape_kind(mixed) == "mixed" and _near(INSPECT.solid_volume(mixed), 0.02 * 0.04 * 0.06, 1e-6) and _near(float(props.mass), mass, 1e-6)
		and _vec_near(props.center, Vector3(2.01, 0.02, 0.03)) and _near(moments.x, minf(expected.x, minf(expected.y, expected.z)), 1e-5)
		and _near(moments.z, maxf(expected.x, maxf(expected.y, expected.z)), 1e-5),
		"A solid with open faces counts only the solid (%s, %s kg at %s, moments %s vs %s)." % [INSPECT.shape_kind(mixed), props.mass, props.center, moments, expected])
	hits = INSPECT.interference(kernel, {"x": {"shape": mixed}, "c": {"shape": kernel.make_box(Vector3(0.02, 0.02, 0.02), Vector3(2.01, 0.0, 0.0), "obox2")}}, [])
	_expect(hits.size() == 1 and _near(float(hits[0].volume), 0.01 * 0.02 * 0.02, 1e-6), "The mixed body's solid still interferes (%s)." % [hits])
	# Principal moments of a symmetric matrix with off-diagonal terms: 2 - sqrt 2, 2, 2 + sqrt 2.
	var found := INSPECT.principal_moments(PackedFloat64Array([2.0, -1.0, 0.0, -1.0, 2.0, -1.0, 0.0, -1.0, 2.0]))
	_expect(_near(found.x, 2.0 - sqrt(2.0), 1e-6) and _near(found.y, 2.0, 1e-6) and _near(found.z, 2.0 + sqrt(2.0), 1e-6), "Principal moments should be the eigenvalues (%s)." % [found])


## Hidden bodies (and a hidden component's) get nothing from analyses and don't count in readouts.
func _check_hidden_bodies() -> void:
	_new_doc()
	var shown := _box(Vector3.ZERO, 40, 20, 30)
	var hidden := _box(Vector3(200, 0, 0), 40, 20, 30)
	var round := _add("cylinder", {"diameter": "20 mm", "height": "30 mm"}, {"position": Vector3(0, 0, 0.2), "operation": OPERATIONS.NEW_BODY})
	var part := _box(Vector3(-200, 0, 0), 10, 10, 10, OPERATIONS.NEW_COMPONENT)
	part.options["component_id"] = doc.new_component(part.id)
	doc.bodies[_body(part)]["component"] = part.options.component_id
	_rebuild()
	_no_errors("Hidden bodies")
	doc.bodies[_body(hidden)]["visible"] = false
	doc.bodies[_body(round)]["visible"] = false
	doc.components[part.options.component_id]["visible"] = false
	var only := [_body(shown)]
	var section := _analysis("section", {"origin": Vector3(0, 0.01, 0), "normal": Vector3.UP})
	_expect(section.meshes.size() == 1 and section.meshes[0].body == _body(shown) and section.body_materials.keys() == only and section.info == "Section area 1200 mm²",
		"Only the shown box should be sectioned and capped (%d caps, %s, %s)." % [section.meshes.size(), section.body_materials.keys(), section.info])
	var com := _analysis("center_of_mass", {})
	_expect(com.points.size() == 1 and _vec_near(com.points[0].position, Vector3(0, 0.01, 0)) and str(com.info).contains("center (0 mm, 10 mm, 0 mm)"),
		"Center of Mass over all bodies should take only the shown one (%s, %s)." % [com.points, com.info])
	com = _analysis("center_of_mass", {"body_ids": [_body(hidden)]})
	_expect(com.points.size() == 1 and _vec_near(com.points[0].position, Vector3(0.2, 0.01, 0)), "A listed body is measured even when hidden (%s)." % [com.points])
	var iso := _analysis("isocurve", {})
	_expect(iso.lines.is_empty() and iso.info == "0 isocurves", "The hidden cylinder should get no isocurves (%d lines, %s)." % [iso.lines.size(), iso.info])
	var comb := _analysis("curvature_comb", {"edges": [{"kind": "body", "body": _body(round)}]})
	_expect(comb.lines.is_empty() and comb.info == "No curves to comb", "A hidden body's comb shouldn't draw (%d lines, %s)." % [comb.lines.size(), comb.info])
	_expect(_analysis("zebra", {}).body_materials.keys() == only and _analysis("component_colors", {}).body_materials.keys() == only,
		"Material analyses should only dress the shown body.")
	var probe: Variant = _analysis("environment_map", {}).get("reflection_probe")
	_expect(probe is AABB and _vec_near((probe as AABB).position, Vector3(-0.02, 0, -0.015)) and _vec_near((probe as AABB).end, Vector3(0.02, 0.02, 0.015)),
		"The reflection probe should cover the shown body only (%s)." % [probe])
	var curvature := _analysis("curvature_map", {})
	_expect(curvature.body_meshes.keys() == only, "The curvature map should color only the shown body (%s)." % [curvature.body_meshes.keys()])


## A comb combs exactly the picked sketch curves, each found in its own sketch.
func _check_comb_picks() -> void:
	_new_doc()
	var sketch_a: Resource = doc.add_feature("sketch", "Sketch", {}, SKETCH_DATA.new_options(SKETCH_DATA.ORIGIN_PLANES.xy, "xy"))
	var a = SKETCH_DATA.new(sketch_a, doc)
	var a10: int = a.add_circle(a.add_point(Vector2.ZERO), 0.01)
	var a5: int = a.add_circle(a.add_point(Vector2(0.05, 0)), 0.005)
	var sketch_b: Resource = doc.add_feature("sketch", "Sketch", {}, SKETCH_DATA.new_options(SKETCH_DATA.ORIGIN_PLANES.xy, "xy"))
	var b = SKETCH_DATA.new(sketch_b, doc)
	var b20: int = b.add_circle(b.add_point(Vector2(0.2, 0)), 0.02)
	_rebuild()
	_no_errors("Comb picks")
	var pick := func(sketch: Resource, entity: int) -> Dictionary: return {"kind": "sketch_curve", "sketch": sketch.id, "entity": entity}
	# Teeth per circle: [center, radius] -> how many teeth stand on it.
	var circles := {"a10": [Vector3.ZERO, 0.01], "a5": [Vector3(0.05, 0, 0), 0.005], "b20": [Vector3(0.2, 0, 0), 0.02]}
	var count := func(out: Dictionary) -> Dictionary:
		var counts := {"a10": 0, "a5": 0, "b20": 0, "other": 0}
		for t in _teeth(out):
			var on := "other"
			for name in circles:
				if absf((t[0] as Vector3).distance_to(circles[name][0]) - float(circles[name][1])) < POSITION_TOLERANCE:
					on = name
			counts[on] += 1
		return counts
	var out := _analysis("curvature_comb", {"curves": [pick.call(sketch_a, a10), pick.call(sketch_b, b20)], "density": 16})
	var counts: Dictionary = count.call(out)
	_expect(counts == {"a10": 16, "a5": 0, "b20": 16, "other": 0} and str(out.info).contains("radius 10 mm"),
		"Picking a circle in each sketch should comb those two only (%s, %s)." % [counts, out.info])
	out = _analysis("curvature_comb", {"curves": [pick.call(sketch_a, a10)], "density": 16})
	counts = count.call(out)
	_expect(counts == {"a10": 16, "a5": 0, "b20": 0, "other": 0} and str(out.info).contains("radius 10 mm"),
		"Picking one circle shouldn't comb its sibling or report its curvature (%s, %s)." % [counts, out.info])
	out = _analysis("curvature_comb", {"sketch": sketch_a.id, "density": 16})
	counts = count.call(out)
	_expect(counts == {"a10": 16, "a5": 16, "b20": 0, "other": 0}, "An entry with only a sketch still combs all of it (%s)." % [counts])
	var gone := ANALYSIS.build({"type": "curvature_comb", "options": {"curves": [pick.call(sketch_a, 999)]}}, result, {}, kernel, doc)
	_expect(gone.has("error") and gone.lines.is_empty(), "A picked curve that is gone should be an error (%s)." % [gone.get("error", "")])


## The comb scale multiplies the automatic size: 1 is the automatic size, 2 twice it (it used to be
## m^2, so typing 1 on a 10 mm arc made 100 m teeth).
func _check_comb_scale() -> void:
	_new_doc()
	var sketch: Resource = doc.add_feature("sketch", "Sketch", {}, SKETCH_DATA.new_options(SKETCH_DATA.ORIGIN_PLANES.xy, "xy"))
	var s = SKETCH_DATA.new(sketch, doc)
	var r := 0.01
	s.add_arc(s.add_point(Vector2.ZERO), s.add_point(Vector2(r, 0)), s.add_point(Vector2(0, r)))
	_rebuild()
	var longest := func(scale: float) -> float:
		var most := 0.0
		for t in _teeth(_analysis("curvature_comb", {"sketch": sketch.id, "scale": scale})):
			most = maxf(most, (t[0] as Vector3).distance_to(t[1]))
		return most
	var auto: float = longest.call(0.0)
	var one: float = longest.call(1.0)
	var two: float = longest.call(2.0)
	_expect(auto > 0.0 and auto < 0.01 and _near(one, auto, 1e-6) and _near(two, 2.0 * auto, 1e-6),
		"Comb scale 1 should be the automatic size and 2 twice it (auto %s m, 1: %s m, 2: %s m)." % [auto, one, two])


## Section, Draft and Accessibility find their picked plane or direction again on every build: the
## section follows its plane when the plane moves, and a deleted reference is an error.
func _check_followed_references() -> void:
	_new_doc()
	var box := _box(Vector3.ZERO, 40, 20, 30)
	var plane := _add("plane", {"distance": "5 mm"}, {"method": "offset", "plane": [{"kind": "origin", "name": "yz"}]})
	_rebuild()
	_no_errors("Section plane")
	var body := _body(box)
	var ref := {"kind": "construct", "feature": plane.id}
	var plane_origin := func(out: Dictionary) -> Vector3:
		var material: ShaderMaterial = out.body_materials.get(body)
		return material.get_shader_parameter("plane_origin") if material != null else Vector3.INF
	var options := {"plane_ref": ref, "offset": 0.0, "origin": Vector3(0.005, 0, 0), "normal": Vector3.RIGHT}
	var out := _analysis("section", options)
	_expect(_vec_near(plane_origin.call(out), Vector3(0.005, 0, 0)) and out.meshes.size() == 1 and _near(_mesh_area(out.meshes[0].mesh), 20 * 30 * MM2, 1e-6),
		"The section should cut on the picked plane at x = 5 mm (%s)." % [plane_origin.call(out)])
	plane.inputs["distance"] = doc.make_input("-12 mm", "length")
	_rebuild()
	_no_errors("Moved section plane")
	out = _analysis("section", options)
	_expect(_vec_near(plane_origin.call(out), Vector3(-0.012, 0, 0)), "Moving the plane to -12 mm should move the section with it (%s)." % [plane_origin.call(out)])
	options["offset"] = 0.002
	_expect(_vec_near(plane_origin.call(_analysis("section", options)), Vector3(-0.010, 0, 0)), "Offset moves the section along the plane's normal.")
	# Draft pulls along the picked plane's normal (+X), Accessibility's tool comes from the picked side.
	var tess := TESSELLATE.tessellate(_shape(body))
	var faces := _vertex_faces(tess)
	var top := -1
	var bottom := -1
	var side := -1
	for i in faces.size():
		var n: Vector3 = _shape(body).face_info(faces[i]).normal
		if n.is_equal_approx(Vector3.UP):
			top = i
		elif n.is_equal_approx(Vector3.DOWN):
			bottom = i
		elif n.is_equal_approx(Vector3.RIGHT):
			side = i
	var draft := _analysis("draft", {"direction_ref": ref, "angle": deg_to_rad(3.0)}, {body: tess})
	var angles: PackedFloat64Array = draft.values.get(body, PackedFloat64Array())
	_expect(top >= 0 and side >= 0 and angles.size() == faces.size() and absf(angles[top]) < 1e-6 and _near(angles[side], PI / 2.0, 1e-6),
		"Draft along the picked plane's normal should see the +X face square and the top at 0 deg.")
	draft = _analysis("draft", {"direction_ref": ref, "flip": true}, {body: tess})
	angles = draft.values.get(body, PackedFloat64Array())
	_expect(angles.size() == faces.size() and _near(angles[side], -PI / 2.0, 1e-6), "Flip should pull the other way.")
	var ground := {"kind": "origin", "name": "xz"}
	for flip in [false, true]:
		var access := _analysis("accessibility", {"direction_ref": ground, "flip": flip}, {body: tess})
		var colors := _mesh_colors(access, body)
		var reach := ANALYSIS.ACCESS_COLORS.reachable
		var block := ANALYSIS.ACCESS_COLORS.blocked
		_expect(bottom >= 0 and colors.size() == faces.size() and _color_near(colors[top], block if flip else reach) and _color_near(colors[bottom], reach if flip else block),
			"A tool coming from the ground plane's %s side should reach the %s face." % ["lower" if flip else "upper", "bottom" if flip else "top"])
	doc.remove_feature(plane.id)
	_rebuild()
	for type in ["section", "draft"]:
		var stale := ANALYSIS.build({"type": type, "options": {"plane_ref": ref, "direction_ref": ref, "origin": Vector3(0.005, 0, 0)}}, result, {}, kernel, doc)
		_expect(stale.has("error") and stale.body_materials.is_empty(), "%s on a deleted plane should be an error, not a stale cut (%s)." % [type, stale.get("error", "")])


## Small masses and areas keep their significant digits.
func _check_readout_digits() -> void:
	_new_doc()
	var cube := _box(Vector3(1.5, 0, 1.5), 3, 3, 3)
	doc.physical_materials["body:" + _body(cube)] = "PLA"
	_rebuild()
	var com := _analysis("center_of_mass", {})
	_expect(str(com.info).begins_with("Mass 0.00003348 kg"), "A 3 mm PLA cube should read 0.00003348 kg (%s)." % com.info)
	doc.units = "m"
	var section := _analysis("section", {"origin": Vector3(0.0015, 0.0015, 0.0015), "normal": Vector3.RIGHT})
	_expect(section.info == "Section area 0.000009 m²", "Its 9 mm^2 section should read 0.000009 m² in meters (%s)." % section.info)
	_expect(ANALYSIS.significant(7.85) == "7.85" and ANALYSIS.significant(1200.0) == "1200" and ANALYSIS.significant(0.0) == "0", "Plain values read as before.")


## Components get distinct colors by their place in the document, whatever their ids.
func _check_component_color_order() -> void:
	_new_doc()
	doc.components = {"comp1": {"name": "A", "parent": ""}, "comp11": {"name": "B", "parent": ""}}
	var first := _box(Vector3.ZERO, 10, 10, 10)
	var second := _box(Vector3(50, 0, 0), 10, 10, 10)
	doc.bodies[_body(first)]["component"] = "comp1"
	doc.bodies[_body(second)]["component"] = "comp11"
	_rebuild()
	var out := _analysis("component_colors", {})
	var a: Color = (out.body_materials[_body(first)] as StandardMaterial3D).albedo_color
	var b: Color = (out.body_materials[_body(second)] as StandardMaterial3D).albedo_color
	_expect(a == ANALYSIS.COMPONENT_PALETTE[0] and b == ANALYSIS.COMPONENT_PALETTE[1], "comp1 and comp11 should get the first two palette colors (%s, %s)." % [a, b])
	_expect(ANALYSIS.component_color("comp11") != ANALYSIS.component_color("comp1"), "Without a document comp11 still differs from comp1.")
	var many := {}
	for i in 14:
		many["comp%d" % (i * 10 + 1)] = {"name": "C%d" % i, "parent": ""}
	doc.components = many
	var seen := []
	for id in many:
		var color := ANALYSIS.component_color(id, doc)
		_expect(not seen.has(color), "Component %s should have a color of its own." % id)
		seen.append(color)


## Curvature Map and Isocurve on a 3120-face faceted mesh (an Insert Mesh sphere: every face flat)
## found flat faces from the mesh instead of asking the kernel face by face (8-12 s before), and a
## redraw reuses what was worked out. Each is timed against the same on a 760-face sphere, in turns:
## a quarter of the faces takes about a quarter of the time (a limit in milliseconds failed
## whenever the machine was busy; a cost growing with the square of the faces is 16 times).
func _check_faceted_mesh_cost() -> void:
	var shape: RefCounted = _faceted_sphere(40)
	var small: RefCounted = _faceted_sphere(20)
	_expect(shape != null and shape.face_count() == 3120 and small != null and small.face_count() == 760, "The faceted spheres should have 3120 and 760 faces.")
	if shape == null or small == null:
		return
	var tess := TESSELLATE.tessellate(shape)
	var small_tess := TESSELLATE.tessellate(small)
	var fake := {"bodies": {"m": {"shape": shape}}}
	ANALYSIS.clear_cache()
	var out := ANALYSIS.build({"type": "curvature_map", "options": {"mode": "gaussian"}}, fake, {"m": tess}, kernel, null)
	var values: PackedFloat64Array = out.values.get("m", PackedFloat64Array())
	_expect(not out.has("error") and values.size() == (tess.positions as PackedVector3Array).size() and values.count(0.0) == values.size(),
		"A faceted mesh's curvature map should be all zeros (%s)." % out.get("info", ""))
	var iso := ANALYSIS.build({"type": "isocurve", "options": {}}, fake, {"m": tess}, kernel, null)
	_expect(iso.lines.is_empty(), "A faceted mesh has no isocurves (%d lines)." % iso.lines.size())
	ANALYSIS.clear_cache()
	var combed := ANALYSIS.build({"type": "curvature_comb", "options": {"edges": [{"kind": "body", "body": "m"}]}}, fake, {"m": tess}, kernel, null)
	_expect(str(combed.get("info", "")).contains("No curves to comb"), "Combing every edge of the faceted mesh should find only straight edges (%s)." % combed.get("info", combed.get("error", "")))
	ANALYSIS.clear_cache()
	var flat_iso := ANALYSIS.build({"type": "isocurve", "options": {"planar": true}}, fake, {"m": tess}, kernel, null)
	_expect(not flat_iso.has("error"), "Isocurves on all 3120 flat faces should build (%s)." % flat_iso.get("error", ""))
	# The kernel keeps its face / edge maps per shape, so per-face and per-edge calls (and the first
	# build of combs and planar isocurves, which ask for every face or edge) aren't quadratic.
	var analysed := func(mesh: RefCounted, mesh_tess: Dictionary, spec: Dictionary) -> void:
		ANALYSIS.clear_cache()
		ANALYSIS.build(spec, {"bodies": {"m": {"shape": mesh.copy()}}}, {"m": mesh_tess}, kernel, null)
	for spec in [{"type": "curvature_map", "options": {"mode": "gaussian"}}, {"type": "isocurve", "options": {}},
			{"type": "curvature_comb", "options": {"edges": [{"kind": "body", "body": "m"}]}}, {"type": "isocurve", "options": {"planar": true}}]:
		var label := "%s%s" % [spec.type, " (planar)" if spec.options.get("planar", false) else ""]
		var timing := TIMING.compare(analysed.bind(shape, tess, spec), analysed.bind(small, small_tess, spec), 3, label + " on 3120 / 760 flat faces")
		_expect(timing.ratio < 8.0, "%s on 3120 flat faces should take about four times as long as on 760 (%.1f ms against %.1f ms)." % [label.capitalize(), timing.op, timing.calibration])
	var asked := func(mesh: RefCounted) -> void:
		var copy: RefCounted = mesh.copy()
		for f in copy.face_count():
			copy.face_info(f)
	var infos := TIMING.compare(asked.bind(shape), asked.bind(small), 5, "face_info on 3120 / 760 faces")
	_expect(infos.ratio < 8.0, "3120 face_info calls should take about four times as long as 760 (%.1f ms against %.1f ms)." % [infos.op, infos.calibration])
	# A curved B-rep body: the redraw reuses the kept curvatures, which match a fresh build.
	_new_doc()
	var sphere := _add("sphere", {"diameter": "20 mm"}, {"position": Vector3.ZERO, "operation": OPERATIONS.NEW_BODY})
	_rebuild()
	var body := _body(sphere)
	var sphere_tess := TESSELLATE.tessellate(_shape(body))
	ANALYSIS.clear_cache()
	var fresh: PackedFloat64Array = _analysis("curvature_map", {"mode": "mean"}, {body: sphere_tess}).values.get(body, PackedFloat64Array())
	_expect(ANALYSIS._cached(_shape(body), "curvature:" + ANALYSIS._tess_key(sphere_tess)) != null, "The sphere's curvatures should be kept for the next redraw.")
	var again: PackedFloat64Array = _analysis("curvature_map", {"mode": "mean"}, {body: sphere_tess}).values.get(body, PackedFloat64Array())
	_expect(fresh.size() > 100 and fresh == again, "A redraw should give the same curvatures (%d, %d values)." % [fresh.size(), again.size()])


# --- Physical materials ----------------------------------------------------------------------

func _check_materials() -> void:
	var required := ["Steel", "Stainless Steel", "Aluminum", "Titanium", "Copper", "Brass", "ABS Plastic", "PLA", "Nylon",
		"Polycarbonate", "Carbon Fiber", "Oak", "Rubber", "Glass", "Concrete", "Foam"]
	var names := PHYSICAL.names()
	for name in required:
		_expect(names.has(name), "The material table should have %s." % name)
	_expect(PHYSICAL.density("Aluminum") == 2700.0 and PHYSICAL.density("Foam") == 30.0 and PHYSICAL.density("Unknown") == 7850.0, "Densities should come from the table.")
	_new_doc()
	doc.components = {"comp1": {"name": "Outer", "parent": ""}, "comp2": {"name": "Inner", "parent": "comp1"}}
	doc.bodies = {
		"body1": {"name": "Body1", "component": "comp2"}, "body2": {"name": "Body2", "component": "comp2"},
		"body3": {"name": "Body3", "component": ""},
	}
	doc.physical_materials = {"component:comp1": "Aluminum", "body:body2": "Titanium", "body:body3": "Unobtainium"}
	_expect(PHYSICAL.material_for(doc, "body1") == "Aluminum", "A body takes its parent component's material.")
	_expect(PHYSICAL.material_for(doc, "body2") == "Titanium", "A body's own material beats its component's.")
	_expect(PHYSICAL.material_for(doc, "body3") == PHYSICAL.DEFAULT, "Unknown names fall back to the default.")
	_expect(PHYSICAL.material_for(doc, "body1.f7.2") == "Aluminum" and PHYSICAL.material_for(doc, "body2.f7.2") == "Titanium", "Split bodies use their source body's settings.")
	doc.physical_materials["component:comp2"] = "Copper"
	_expect(PHYSICAL.material_for(doc, "body1") == "Copper" and PHYSICAL.density_for(doc, "body1") == 8960.0, "The nearest component wins over its parent.")
	_expect(PHYSICAL.material_for(null, "body1") == "Steel", "No document means the default.")


## Applying a material to a component reaches its bodies that had their own (and their split-off
## pieces'); a trial copy previews it without touching the document.
func _check_material_assign() -> void:
	_new_doc()
	doc.components = {"comp1": {"name": "C1", "parent": ""}, "comp2": {"name": "C2", "parent": ""}}
	doc.bodies = {"body1": {"name": "Body1", "component": "comp1"}, "body2": {"name": "Body2", "component": "comp1"}, "body3": {"name": "Body3", "component": "comp2"}}
	doc.physical_materials = {"body:body1": "Aluminum", "body:body1.f7.2": "Brass", "body:body3": "Titanium"}
	var trial: Dictionary = doc.physical_materials.duplicate()
	PHYSICAL.assign(trial, doc, ["component:comp1"], "Copper")
	_expect(PHYSICAL.material_for(doc, "body1", trial) == "Copper" and PHYSICAL.material_for(doc, "body1.f7.2", trial) == "Copper"
		and PHYSICAL.material_for(doc, "body2", trial) == "Copper" and PHYSICAL.material_for(doc, "body3", trial) == "Titanium",
		"Copper on comp1 should reach body1 (which had Aluminum) and its piece, and leave comp2's body alone (%s)." % [trial])
	_expect(PHYSICAL.material_for(doc, "body1") == "Aluminum" and doc.physical_materials.size() == 3, "The trial shouldn't change the document.")
	PHYSICAL.assign(doc.physical_materials, doc, ["body:body2"], "Foam")
	_expect(PHYSICAL.material_for(doc, "body2") == "Foam" and PHYSICAL.material_for(doc, "body1") == "Aluminum", "Body keys only touch their bodies.")


## An Insert Mesh sphere of n x n quads (radius 50 mm, the poles' quads one triangle each): every
## face flat, 2 n (n - 1) of them.
func _faceted_sphere(n: int) -> RefCounted:
	var positions := PackedVector3Array()
	var indices := PackedInt32Array()
	for i in range(n + 1):
		var theta := PI * float(i) / n
		for j in n:
			var phi := TAU * float(j) / n
			positions.append(Vector3(sin(theta) * cos(phi), cos(theta), sin(theta) * sin(phi)) * 0.05)
	for i in n:
		for j in n:
			var a := i * n + j
			var b := i * n + (j + 1) % n
			var c := (i + 1) * n + j
			var d := (i + 1) * n + (j + 1) % n
			if i > 0:
				indices.append_array([a, b, c])
			if i < n - 1:
				indices.append_array([b, d, c])
	return kernel.mesh_to_shape(positions, indices, "fm")


## A surface body's centre (Mass Properties, Center of Mass) is its area's exact centroid: it came
## from the display mesh, an r 10 mm hemisphere at z 4.9919 mm, an r 200 mm one at 99.84 mm and a
## 120 degree cylinder strip 0.13 % short of its axis distance. A faceted mesh body keeps its
## triangles' centroid.
func _check_surface_centres() -> void:
	_new_doc()
	var xz := Transform3D(Basis(Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(0, -1, 0)), Vector3.ZERO)
	var domes := {}
	for radius in [10.0, 200.0]:
		var dome = kernel.revolve(kernel.sketch_edges([{"type": "arc", "c": Vector2.ZERO, "r": radius * MM, "a0": 0.0, "a1": PI / 2}], xz), {"axis_origin": Vector3.ZERO, "axis": Vector3(0, 0, 1), "angle": TAU, "surface": true})
		domes[radius] = dome
		var c: Vector3 = INSPECT.shape_mass_properties(dome, 1000.0).center if dome != null else Vector3.ZERO
		_expect(_near(c.z, radius * 0.5 * MM, 1e-6) and Vector2(c.x, c.y).length() <= radius * MM * 1e-6,
			"An r %s mm hemisphere surface should be centred %s mm up its axis (%s mm)." % [radius, radius * 0.5, c / MM])
	var strip = kernel.extrude(kernel.sketch_edges([{"type": "arc", "c": Vector2.ZERO, "r": 5 * MM, "a0": 0.0, "a1": deg_to_rad(120.0)}], Transform3D.IDENTITY), {"direction": Vector3(0, 0, 1), "distance": 10 * MM, "surface": true})
	var reach := 5.0 * MM * sin(PI / 3.0) / (PI / 3.0)
	var centre: Vector3 = INSPECT.shape_mass_properties(strip, 1000.0).center if strip != null else Vector3.ZERO
	_expect(_near(Vector2(centre.x, centre.y).length(), reach, 1e-6) and _near(Vector2(centre.x, centre.y).angle(), PI / 3.0, 1e-6) and _near(centre.z, 5 * MM, 1e-6),
		"A 120 degree r 5 mm cylinder strip should be centred r sin(t/2)/(t/2) = %.6f mm from its axis, 5 mm up (%s mm)." % [reach / MM, centre / MM])
	var com := ANALYSIS.build({"type": "center_of_mass", "options": {}}, {"bodies": {"d": {"shape": domes[10.0]}}}, {}, kernel, doc)
	var point: Vector3 = com.points[0].position if not (com.get("points", []) as Array).is_empty() else Vector3.ZERO
	_expect(_near(point.z, 5 * MM, 1e-6), "The Center of Mass analysis should mark the r 10 mm hemisphere surface at z 5 mm (%s mm)." % (point / MM))
	# A faceted hemisphere (each triangle a flat face): the centroid of its triangles' areas.
	var positions := PackedVector3Array()
	var indices := PackedInt32Array()
	var rings := 6
	var around := 12
	positions.append(Vector3(0, 0, 0.02))
	for i in range(1, rings + 1):
		var polar := PI / 2.0 * i / rings
		for j in around:
			var azimuth := TAU * j / around
			positions.append(Vector3(sin(polar) * cos(azimuth), sin(polar) * sin(azimuth), cos(polar)) * 0.02)
	for j in around:
		indices.append_array([0, 1 + (j + 1) % around, 1 + j])
	for i in range(1, rings):
		for j in around:
			var a := 1 + (i - 1) * around + j
			var b := 1 + (i - 1) * around + (j + 1) % around
			var c := 1 + i * around + j
			var d := 1 + i * around + (j + 1) % around
			indices.append_array([a, b, d, a, d, c])
	var mesh: RefCounted = kernel.mesh_to_shape(positions, indices, "fh")
	var sums := PackedFloat64Array([0.0, 0.0, 0.0, 0.0])
	for t in int(indices.size() / 3.0):
		var p: Vector3 = positions[indices[t * 3]]
		var q: Vector3 = positions[indices[t * 3 + 1]]
		var s: Vector3 = positions[indices[t * 3 + 2]]
		var area := (q - p).cross(s - p).length() * 0.5
		sums[3] += area
		for k in 3:
			sums[k] += area * (p[k] + q[k] + s[k]) / 3.0
	var faceted := Vector3(sums[0] / sums[3], sums[1] / sums[3], sums[2] / sums[3])
	var found: Vector3 = INSPECT.shape_mass_properties(mesh, 1000.0).center if mesh != null else Vector3.ZERO
	_expect(mesh != null and INSPECT.shape_kind(mesh) == "surface" and found.distance_to(faceted) <= 1e-6 * 0.02,
		"A faceted hemisphere mesh body should keep its triangles' centroid %s mm (%s mm)." % [faceted / MM, found / MM])


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error(message)
		print("FAIL: ", message)
