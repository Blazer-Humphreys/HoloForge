extends SceneTree
## Holo Forge Phase 3 features through the document timeline: every Create and Modify feature
## against its exact volume (1e-6 relative where the answer is exact), patterns and mirror,
## holes (simple, counterbore, countersink, drill point, tapped), construction geometry,
## components, topological naming (an upstream sketch dimension changes and the fillet still
## finds its edge, by name) and a 20-feature timeline rolled back, edited and recomputed in
## under three times a plain recompute (timed in turns, see holo_forge_timing.gd).
##
## godot --headless --path . --script res://tests/holo_forge_solid_features_test.gd

const DOCUMENT := preload("res://addons/holo_forge/core/document.gd")
const REGEN := preload("res://addons/holo_forge/core/regen.gd")
const SKETCH_DATA := preload("res://addons/holo_forge/core/sketch/sketch_data.gd")
const OPERATIONS := preload("res://addons/holo_forge/core/operations.gd")
const HOLE := preload("res://addons/holo_forge/core/features/hole.gd")
const TIMING := preload("res://tests/holo_forge_timing.gd")

const MM3 := 1e-9
## Points and lengths pass through Godot's single-precision vectors: 1 micrometer is the bar.

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
		_check_sketch_features()
		_check_holes()
		_check_primitives()
		_check_patterns()
		_check_path_spacing()
		_check_modify()
		_check_construct()
		_check_components()
		_check_naming()
		_check_timing()
	print("PASS holo_forge_solid_features: every feature matches its exact volume, patterns/mirror/holes/construct work, the fillet keeps its edge, and a 20-feature timeline recomputes in %d ms." % _timing_ms \
		if failures.is_empty() else "FAIL holo_forge_solid_features")
	quit(0 if failures.is_empty() else 1)


# --- Helpers ---------------------------------------------------------------------------------

var _timing_ms := 0


func _new_doc() -> void:
	doc = DOCUMENT.new()
	result = {}


## Adds a feature; inputs are "expr" (a length) or [expr, kind]. Create features get a body.
func _add(type: String, inputs: Dictionary, options: Dictionary) -> Resource:
	var made := {}
	for key in inputs:
		var spec = inputs[key]
		made[key] = doc.make_input(spec[0], spec[1]) if spec is Array else doc.make_input(str(spec), "length")
	var feature: Resource = doc.add_feature(type, type.capitalize(), made, options)
	if OPERATIONS.creates_body(str(options.get("operation", ""))):
		feature.options["body_id"] = doc.new_body(feature.id)
	return feature


func _rebuild() -> Dictionary:
	result = REGEN.rebuild(doc, kernel)
	return result


## A w x h mm rectangle on an origin plane (or a frame dictionary), lower-left corner at corner
## (mm), fully dimensioned. {"feature", "lines": [bottom, right, top, left], "dims": [w, h]}.
func _rect(plane: Variant, corner: Vector2, w: float, h: float) -> Dictionary:
	var frame: Dictionary = SKETCH_DATA.ORIGIN_PLANES[plane] if plane is String else plane
	var feature: Resource = doc.add_feature("sketch", "Sketch", {}, SKETCH_DATA.new_options(frame, plane if plane is String else "frame"))
	var s = SKETCH_DATA.new(feature, doc)
	var c := corner * 0.001
	var p := [s.add_point(c), s.add_point(c + Vector2(w, 0) * 0.001), s.add_point(c + Vector2(w, h) * 0.001), s.add_point(c + Vector2(0, h) * 0.001)]
	var lines := []
	for i in 4:
		lines.append(s.add_line(p[i], p[(i + 1) % 4]))
	s.add_constraint("fix", [p[0]])
	s.add_constraint("horizontal", [lines[0]])
	s.add_constraint("horizontal", [lines[2]])
	s.add_constraint("vertical", [lines[1]])
	s.add_constraint("vertical", [lines[3]])
	var dw: int = s.add_constraint("distance_x", [p[0], p[1]], "%s mm" % w)
	var dh: int = s.add_constraint("distance_y", [p[1], p[2]], "%s mm" % h)
	return {"feature": feature, "lines": lines, "dims": [dw, dh], "center": (c + Vector2(w, h) * 0.0005)}


func _profile(sketch: Dictionary, point: Variant = null) -> Dictionary:
	return {"kind": "profile", "sketch": sketch.feature.id, "point": point if point != null else sketch.center}


func _body(feature: Resource) -> String:
	return str(feature.options.get("body_id", ""))


func _shape(body_id: String) -> RefCounted:
	return result.bodies[body_id].shape if result.bodies.has(body_id) else null


func _volume(body_id: String, expected: float, label: String, rel := 1e-6) -> void:
	var shape := _shape(body_id)
	var v: float = shape.volume() if shape != null else -1.0
	_expect(shape != null and absf(v - expected) <= absf(expected) * rel, "%s: volume should be %s (got %s; errors %s)" % [label, String.num_scientific(expected), String.num_scientific(v) if shape != null else "no body", result.get("errors", {})])


func _no_errors(label: String) -> void:
	_expect((result.errors as Dictionary).is_empty(), "%s: the timeline should rebuild cleanly (%s)." % [label, result.errors])


## A reference to the biggest flat face facing normal, by its persistent name.
func _face_ref(body_id: String, normal: Vector3) -> Dictionary:
	var shape := _shape(body_id)
	var best := {}
	for f in shape.face_count():
		var info: Dictionary = shape.face_info(f)
		if info.get("planar", false) and (info.normal as Vector3).is_equal_approx(normal) and float(info.area) > float(best.get("sig", {}).get("area", -1.0)):
			best = {"kind": "face", "body": body_id, "name": shape.get_face_names()[f], "sig": {"type": info.type, "point": info.point, "normal": info.normal, "area": info.area}}
	return best


func _edge_ref(body_id: String, direction: Vector3, length: float) -> Dictionary:
	var shape := _shape(body_id)
	for e in shape.edge_count():
		var info: Dictionary = shape.edge_info(e)
		if info.get("type", "") == "line" and absf(float(info.length) - length) < 1e-6 and absf(absf((info.tangent as Vector3).dot(direction)) - 1.0) < 1e-6:
			return {"kind": "edge", "body": body_id, "name": shape.get_edge_names()[e], "sig": {"type": "line", "point": info.midpoint, "length": info.length}}
	return {}


func _box(position_mm: Vector3, l: float, h: float, w: float) -> Resource:
	return _add("box", {"length": "%s mm" % l, "height": "%s mm" % h, "width": "%s mm" % w}, {"position": position_mm * 0.001, "operation": OPERATIONS.NEW_BODY})


# --- Sketch-driven Create features -----------------------------------------------------------

func _check_sketch_features() -> void:
	_new_doc()
	# Extrude 40 x 20 by 10 mm, and two sides (10 + 5), symmetric (whole 12), tapered.
	var rect := _rect("xz", Vector2.ZERO, 40, 20)
	var plain := _add("extrude", {"distance": "10 mm"}, {"profiles": [_profile(rect)], "operation": OPERATIONS.NEW_BODY})
	var two := _add("extrude", {"distance": "10 mm", "distance2": "5 mm"}, {"profiles": [_profile(rect)], "side": "two", "operation": OPERATIONS.NEW_BODY})
	var sym := _add("extrude", {"distance": "12 mm"}, {"profiles": [_profile(rect)], "side": "symmetric", "whole_length": true, "operation": OPERATIONS.NEW_BODY})
	var thin_rect := _rect("xz", Vector2(100, 0), 40, 20)
	var thin_in := _add("extrude", {"distance": "10 mm", "thickness": "2 mm"}, {"profiles": [_profile(thin_rect)], "thin": true, "thin_side": "inside", "operation": OPERATIONS.NEW_BODY})
	var thin_out := _add("extrude", {"distance": "10 mm", "thickness": "2 mm"}, {"profiles": [_profile(thin_rect)], "thin": true, "thin_side": "outside", "operation": OPERATIONS.NEW_BODY})
	# Up to a construction plane 15 mm above, and starting 5 mm up.
	var plane := _add("plane", {"distance": "15 mm"}, {"method": "offset", "plane": [{"kind": "origin", "name": "xz"}]})
	var to_plane := _add("extrude", {}, {"profiles": [_profile(rect)], "extent": "to", "to_object": [{"kind": "construct", "feature": plane.id}], "operation": OPERATIONS.NEW_BODY})
	var offset_start := _add("extrude", {"distance": "10 mm", "start_offset": "5 mm"}, {"profiles": [_profile(rect)], "start": "offset", "operation": OPERATIONS.NEW_BODY})
	# Revolve: a 10 x 20 rectangle 30 mm from the Y axis, fully (2 pi r A) and a quarter.
	var ring := _rect("xy", Vector2(30, 0), 10, 20)
	var full := _add("revolve", {}, {"profiles": [_profile(ring)], "axis": [{"kind": "origin", "name": "y"}], "extent": "full", "operation": OPERATIONS.NEW_BODY})
	var quarter := _add("revolve", {"angle": ["90 deg", "angle"]}, {"profiles": [_profile(ring)], "axis": [{"kind": "origin", "name": "y"}], "extent": "angle", "operation": OPERATIONS.NEW_BODY})
	# Sweep a 5 mm circle (YZ plane, at y = 200 mm) along a 50 mm line in X.
	var disk_sketch: Resource = doc.add_feature("sketch", "Sketch", {}, SKETCH_DATA.new_options(SKETCH_DATA.ORIGIN_PLANES.yz, "yz"))
	var ds = SKETCH_DATA.new(disk_sketch, doc)
	ds.add_circle(ds.add_point(Vector2(0, 0.2)), 0.005)
	var path_sketch: Resource = doc.add_feature("sketch", "Sketch", {}, SKETCH_DATA.new_options(SKETCH_DATA.ORIGIN_PLANES.xy, "xy"))
	var ps = SKETCH_DATA.new(path_sketch, doc)
	var path_line: int = ps.add_line(ps.add_point(Vector2(0, 0.2)), ps.add_point(Vector2(0.05, 0.2)))
	var swept := _add("sweep", {}, {"profiles": [{"kind": "profile", "sketch": disk_sketch.id, "point": Vector2(0, 0.2)}],
		"path": [{"kind": "sketch_curve", "sketch": path_sketch.id, "entity": path_line}], "operation": OPERATIONS.NEW_BODY})
	# Loft (ruled) between equal 10 mm squares 20 mm apart.
	var low := _rect("xz", Vector2(500, 0), 10, 10)
	var high := _rect({"origin": Vector3(0, 0.02, 0), "x": Vector3.RIGHT, "y": Vector3.FORWARD}, Vector2(500, 0), 10, 10)
	var lofted := _add("loft", {}, {"sections": [_profile(low), _profile(high)], "ruled": true, "operation": OPERATIONS.NEW_BODY})
	# Offset Face on an extrude's side face (its face orientation is reversed in the kernel).
	var pulled := _add("extrude", {"distance": "10 mm"}, {"profiles": [_profile(rect)], "operation": OPERATIONS.NEW_BODY})
	_add("offset_face", {"distance": "5 mm"}, {"faces": [{"kind": "face", "body": _body(pulled), "name": "%s:g(s%d)" % [pulled.id, rect.lines[1]], "sig": {}}]})
	_rebuild()
	_no_errors("Sketch features")
	_volume(_body(plain), 8000 * MM3, "Extrude")
	_volume(_body(two), 12000 * MM3, "Two-sided extrude")
	_volume(_body(sym), 9600 * MM3, "Symmetric extrude (whole length)")
	_volume(_body(thin_in), (800 - 36 * 16) * 10 * MM3, "Thin extrude inside")
	_volume(_body(thin_out), (2.0 * 2.0 * (40 + 20) + PI * 4.0) * 10 * MM3, "Thin extrude outside (round corners)", 1e-5)
	_volume(_body(to_plane), 800 * 15 * MM3, "Extrude to a construction plane")
	var started := _shape(_body(offset_start))
	_expect(started != null and absf((started.bbox() as AABB).position.y - 0.005) < 1e-6, "An offset start should lift the extrude 5 mm.")
	_volume(_body(full), TAU * 35 * 200 * MM3, "Full revolve (2 pi r A)")
	_volume(_body(quarter), TAU * 35 * 200 * 0.25 * MM3, "Quarter revolve")
	_volume(_body(swept), PI * 25 * 50 * MM3, "Sweep along a line")
	_volume(_body(lofted), 100 * 20 * MM3, "Ruled loft")
	_volume(_body(pulled), (8000 + 20 * 10 * 5) * MM3, "Offset Face pushes an extrude's side face outward")
	var names: PackedStringArray = _shape(_body(plain)).get_face_names()
	_expect(names.has(plain.id + ":start") and names.has(plain.id + ":end") and names.has("%s:g(s%d)" % [plain.id, rect.lines[1]]),
		"Extrude faces should be named after the feature and its sketch lines (%s)." % [names])

	# Join and Cut with automatic participating bodies; Intersect; a cut with no body touched fails.
	_new_doc()
	var base := _box(Vector3.ZERO, 40, 20, 30)
	var slot := _rect("xz", Vector2(-5, -100), 10, 200)
	var cut := _add("extrude", {"distance": "5 mm"}, {"profiles": [_profile(slot, Vector2(0, 0))], "side": "two", "operation": OPERATIONS.CUT, "flip": false})
	cut.inputs["distance2"] = doc.make_input("5 mm", "length")
	var boss := _rect({"origin": Vector3(0, 0.02, 0), "x": Vector3.RIGHT, "y": Vector3.FORWARD}, Vector2(-5, -5), 10, 10)
	var joined := _add("extrude", {"distance": "8 mm"}, {"profiles": [_profile(boss)], "operation": OPERATIONS.JOIN})
	var far := _rect({"origin": Vector3(0, 0.5, 0), "x": Vector3.RIGHT, "y": Vector3.FORWARD}, Vector2.ZERO, 5, 5)
	var missed := _add("extrude", {"distance": "5 mm"}, {"profiles": [_profile(far)], "operation": OPERATIONS.CUT})
	_rebuild()
	_volume(_body(base), (24000 - 10 * 5 * 30 + 10 * 10 * 8) * MM3, "Cut (two sides) then Join on the touched body")
	_expect(not result.errors.has(cut.id) and not result.errors.has(joined.id), "Cut and Join should find their bodies (%s)." % [result.errors])
	_expect(result.errors.has(missed.id), "A cut that touches nothing should report it.")

	# Rib inside a shelled cup, Web on a plate, Emboss on a top face.
	_new_doc()
	var cup := _box(Vector3(0, 0, 0), 40, 20, 30)
	_rebuild()
	var shell := _add("shell", {"thickness": "2 mm"}, {"faces": [_face_ref(_body(cup), Vector3.UP)], "direction": "inside"})
	var rib_sketch: Resource = doc.add_feature("sketch", "Sketch", {}, SKETCH_DATA.new_options({"origin": Vector3.ZERO, "x": Vector3.RIGHT, "y": Vector3.UP}, "frame"))
	var rs = SKETCH_DATA.new(rib_sketch, doc)
	var rib_line: int = rs.add_line(rs.add_point(Vector2(-0.018, 0.012)), rs.add_point(Vector2(0.018, 0.012)))
	var rib := _add("rib", {"thickness": "2 mm"}, {"curves": [{"kind": "sketch_curve", "sketch": rib_sketch.id, "entity": rib_line}]})
	var plate := _box(Vector3(200, 0, 0), 60, 4, 60)
	var web_sketch: Resource = doc.add_feature("sketch", "Sketch", {}, SKETCH_DATA.new_options({"origin": Vector3(0, 0.004, 0), "x": Vector3.RIGHT, "y": Vector3.FORWARD}, "frame"))
	var ws = SKETCH_DATA.new(web_sketch, doc)
	var web_line: int = ws.add_line(ws.add_point(Vector2(0.18, 0.0)), ws.add_point(Vector2(0.22, 0.0)))
	var web := _add("web", {"thickness": "2 mm", "depth": "5 mm"}, {"curves": [{"kind": "sketch_curve", "sketch": web_sketch.id, "entity": web_line}], "operation": OPERATIONS.JOIN})
	_rebuild()
	var stamp := _rect({"origin": Vector3(0, 0.004, 0), "x": Vector3.RIGHT, "y": Vector3.FORWARD}, Vector2(210, 10), 10, 5)
	var emboss := _add("emboss", {"depth": "1 mm"}, {"profiles": [_profile(stamp)], "face": [_face_ref(_body(plate), Vector3.UP)], "effect": "emboss"})
	_rebuild()
	_no_errors("Rib, web and emboss")
	_volume(_body(cup), (24000 - 36 * 18 * 26 + 36 * 10 * 2) * MM3, "Rib fills down to the cup's floor")
	_volume(_body(plate), (60 * 4 * 60 + (2 * 40 + PI) * 5 + 10 * 5 * 1) * MM3, "Web (rounded ends) and emboss on the plate", 1e-5)
	_expect(not result.errors.has(shell.id) and not result.errors.has(rib.id) and not result.errors.has(web.id) and not result.errors.has(emboss.id), "Rib/web/emboss should succeed.")


# --- Holes -----------------------------------------------------------------------------------

func _check_holes() -> void:
	_new_doc()
	var block := _box(Vector3.ZERO, 100, 10, 40)
	_rebuild()
	var top := _face_ref(_body(block), Vector3.UP)
	var at := func(x: float, z: float) -> Array: return [{"kind": "vertex", "body": _body(block), "point": Vector3(x, 10, z) * 0.001}]
	var simple := _add("hole", {"diameter": "6 mm", "depth": "5 mm"}, {"points": at.call(-30, 0), "face": [top]})
	var counterbore := _add("hole", {"diameter": "6.6 mm", "depth": "8 mm", "cb_diameter": "11 mm", "cb_depth": "4 mm"}, {"points": at.call(30, 10), "face": [top], "hole_type": "counterbore"})
	var countersink := _add("hole", {"diameter": "6.6 mm", "depth": "8 mm", "cs_diameter": "13 mm", "cs_angle": ["90 deg", "angle"]}, {"points": at.call(30, -10), "face": [top], "hole_type": "countersink"})
	var pointed := _add("hole", {"diameter": "4 mm", "depth": "6 mm", "drill_angle": ["118 deg", "angle"]}, {"points": at.call(-40, -12), "face": [top], "drill_point": "angled"})
	var through := _add("hole", {"diameter": "4 mm"}, {"points": at.call(45, 15), "face": [top], "extent": "all"})
	var pattern := _add("rect_pattern", {"quantity1": ["3", "number"], "distance1": "20 mm"}, {"object_type": "features", "objects": [{"kind": "feature", "feature": simple.id}], "direction1": [{"kind": "origin", "name": "x"}], "distance_type": "spacing"})

	_rebuild()
	_no_errors("Holes")
	var r_cb := 3.3
	var sink := (6.5 - r_cb) / tan(PI * 0.25)
	var removed := 3.0 * PI * 9 * 5 \
		+ PI * (5.5 * 5.5 * 4 + r_cb * r_cb * 4) \
		+ PI * sink / 3.0 * (6.5 * 6.5 + 6.5 * r_cb + r_cb * r_cb) + PI * r_cb * r_cb * (8 - sink) \
		+ PI * 4 * 6 + PI * 4 * (2.0 / tan(deg_to_rad(59.0))) / 3.0 \
		+ PI * 4 * 10
	_volume(_body(block), (100 * 10 * 40 - removed) * MM3, "Simple, counterbore, countersink, drill-point and through holes, plus a pattern of the simple hole")

	# A tapped M6 hole: modeled threads remove a little more than the tap drill; cosmetic ones don't.
	_new_doc()
	var tapped_block := _box(Vector3.ZERO, 30, 12, 30)
	_rebuild()
	var face := _face_ref(_body(tapped_block), Vector3.UP)
	var m6 := HOLE.size_info("ISO Metric", "M6")
	_expect(absf(float(m6.pitch) - 0.001) < 1e-12 and absf(float(m6.tap_drill) - 0.005) < 1e-12, "M6 should be 1 mm pitch with a 5 mm tap drill (%s)." % [m6])
	_expect(absf(float(HOLE.size_info("UNC", "1/4-20").pitch) - 0.0254 / 20.0) < 1e-12, "1/4-20 should have a 1/20 inch pitch.")
	var cosmetic := _add("hole", {"depth": "8 mm"}, {"points": [{"kind": "vertex", "body": _body(tapped_block), "point": Vector3(-0.007, 0.012, 0)}], "face": [face], "tap_type": "tapped", "standard": "ISO Metric", "size": "M6"})
	var modeled := _add("hole", {"depth": "8 mm"}, {"points": [{"kind": "vertex", "body": _body(tapped_block), "point": Vector3(0.007, 0.012, 0)}], "face": [face], "tap_type": "tapped", "standard": "ISO Metric", "size": "M6", "modeled": true})
	var clearance := _add("hole", {"depth": "8 mm"}, {"points": [{"kind": "vertex", "body": _body(tapped_block), "point": Vector3(0, 0.012, 0.009)}], "face": [face], "tap_type": "clearance", "standard": "ISO Metric", "size": "M6", "fit": "normal"})
	_rebuild()
	_no_errors("Tapped holes")
	var v: float = _shape(_body(tapped_block)).volume()
	var plain := 30 * 12 * 30 - PI * 6.25 * 8 * 2 - PI * 3.3 * 3.3 * 8
	_expect(v < plain * MM3 - 1e-9 and v > (plain - PI * (9.0 - 6.25) * 8) * MM3, "A modeled M6 thread should cut between the tap drill and the major diameter (%s vs %s)." % [v, plain * MM3])
	_expect(result.threads.size() == 1, "The cosmetic thread should be noted (%s)." % [result.threads.keys()])
	_expect(not result.errors.has(cosmetic.id) and not result.errors.has(modeled.id) and not result.errors.has(clearance.id), "Tapped and clearance holes should build.")

	# A modeled full-length M3 thread 0.5 mm in from the end of a 3 x 10 mm rod runs to its far end
	# and cuts 9.5 mm of thread (the groove ran on past the end, and its cut through the end face
	# left the rod uncut with no error).
	_new_doc()
	var rod := _add("cylinder", {"diameter": "3 mm", "height": "10 mm"}, {"position": Vector3.ZERO, "operation": OPERATIONS.NEW_BODY})
	_rebuild()
	var round_face := {}
	var rod_shape := _shape(_body(rod))
	for f in rod_shape.face_count():
		var info: Dictionary = rod_shape.face_info(f)
		if str(info.type) == "cylinder":
			round_face = {"kind": "face", "body": _body(rod), "name": rod_shape.get_face_names()[f], "sig": {"type": "cylinder", "point": info.point, "area": info.area}}
	var before: float = rod_shape.volume()
	var thread := _add("thread", {"offset": "0.5 mm", "length": "0.5 mm"}, {"faces": [round_face], "modeled": true, "full_length": true})
	_rebuild()
	var m3 := HOLE.closest_size("ISO Metric", 0.003, false)
	var d := float(m3.pitch) * HOLE.EXTERNAL_DEPTH
	var half_base := minf(d * tan(PI / 6.0), float(m3.pitch) * 0.45)
	# The V's part inside the rod (its tip at r - d, 1.1 d deep to its base), screwed 9.5 mm.
	var want := TAU * (0.0015 - d / 3.0) * half_base * 1.1 * d / 1.21 * 0.0095 / float(m3.pitch)
	var threaded: float = before - (_shape(_body(rod)).volume() if _shape(_body(rod)) != null else before)
	_expect(not result.errors.has(thread.id) and absf(threaded - want) <= 0.01 * want, "A full-length M3 thread 0.5 mm in from a rod's end should cut %s mm3 (%s; %s %s)." % [String.num(want * 1e9, 4), String.num(threaded * 1e9, 4), result.errors, result.get("warnings", {})])


# --- Primitives ------------------------------------------------------------------------------

func _check_primitives() -> void:
	_new_doc()
	var torus := _add("torus", {"diameter": "40 mm", "section": "10 mm"}, {"position": Vector3.ZERO, "operation": OPERATIONS.NEW_BODY})
	var coil := _add("coil", {"diameter": "20 mm", "turns": ["3", "number"], "pitch": "4 mm", "section_size": "2 mm"}, {"position": Vector3(0.1, 0, 0), "coil_type": "revolution_pitch", "operation": OPERATIONS.NEW_BODY})
	var spiral := _add("coil", {"diameter": "20 mm", "turns": ["2", "number"], "pitch": "5 mm", "section_size": "2 mm"}, {"position": Vector3(0.3, 0, 0), "coil_type": "spiral", "operation": OPERATIONS.NEW_BODY})
	var arc_sketch: Resource = doc.add_feature("sketch", "Sketch", {}, SKETCH_DATA.new_options(SKETCH_DATA.ORIGIN_PLANES.xy, "xy"))
	var s = SKETCH_DATA.new(arc_sketch, doc)
	var arc: int = s.add_arc(s.add_point(Vector2(0, 0.3)), s.add_point(Vector2(0.05, 0.3)), s.add_point(Vector2(0, 0.35)))
	var pipe := _add("pipe", {"diameter": "10 mm"}, {"path": [{"kind": "sketch_curve", "sketch": arc_sketch.id, "entity": arc}], "operation": OPERATIONS.NEW_BODY})
	var hollow := _add("pipe", {"diameter": "10 mm", "thickness": "1 mm"}, {"path": [{"kind": "sketch_curve", "sketch": arc_sketch.id, "entity": arc}], "hollow": true, "operation": OPERATIONS.NEW_BODY})
	_rebuild()
	_no_errors("Primitives")
	_volume(_body(torus), 2.0 * PI * PI * 20 * 25 * MM3, "Torus")
	# The section lies in the plane through the axis and turns with it: 2 pi rbar A a turn (its
	# area times the helix's length is 0.2 % more, which a 5e-3 tolerance used to hide, with the
	# coil 0.02 % short).
	_volume(_body(coil), TAU * 10.0 * PI * 3.0 * MM3, "Coil (2 pi rbar A turns)")
	# A flat spiral (radius 10 mm growing 5 mm a turn, 2 turns): section area times its length.
	var spiral_length := 0.0
	var steps := 4000
	for i in steps:
		var theta := TAU * 2.0 * (i + 0.5) / steps
		var radius := 10.0 + 5.0 * theta / TAU
		spiral_length += sqrt(radius * radius + pow(5.0 / TAU, 2)) * TAU * 2.0 / steps
	_volume(_body(spiral), PI * spiral_length * MM3, "Spiral coil")
	_volume(_body(pipe), PI * 25 * (PI * 0.5 * 50) * MM3, "Pipe along a quarter circle")
	_volume(_body(hollow), PI * (25 - 16) * (PI * 0.5 * 50) * MM3, "Hollow pipe")


# --- Patterns and mirror ---------------------------------------------------------------------

func _check_patterns() -> void:
	_new_doc()
	var post := _add("cylinder", {"diameter": "10 mm", "height": "10 mm"}, {"position": Vector3(0.05, 0, 0), "operation": OPERATIONS.NEW_BODY})
	var circle := _add("circ_pattern", {"quantity": ["4", "number"]}, {"object_type": "bodies", "objects": [{"kind": "body", "body": _body(post)}], "axis": [{"kind": "origin", "name": "y"}]})
	var cube := _box(Vector3(60, 0, 0), 10, 10, 10)
	var mirror := _add("mirror", {}, {"object_type": "bodies", "objects": [{"kind": "body", "body": _body(cube)}], "plane": [{"kind": "origin", "name": "yz"}]})
	var row := _add("rect_pattern", {"quantity1": ["3", "number"], "distance1": "40 mm", "quantity2": ["2", "number"], "distance2": "15 mm"},
		{"object_type": "bodies", "objects": [{"kind": "body", "body": _body(cube)}], "direction1": [{"kind": "origin", "name": "x"}], "direction2": [{"kind": "origin", "name": "z"}], "suppressed": [2]})
	_rebuild()
	_no_errors("Patterns")
	var copies: Array = result.bodies.keys().filter(func(id: String) -> bool: return id.begins_with(_body(post) + "." + circle.id))
	_expect(copies.size() == 3, "A circular pattern of 4 should add 3 bodies (%s)." % [result.bodies.keys()])
	for id in copies:
		_volume(id, PI * 25 * 10 * MM3, "Patterned post")
	var quarter_turn: RefCounted = _shape(_body(post) + "." + circle.id + ".1")
	_expect(quarter_turn != null and (quarter_turn.bbox() as AABB).get_center().distance_to(Vector3(0, 0.005, -0.05)) < 1e-6, "The first copy should sit a quarter turn around Y.")
	var mirrored: String = _body(cube) + "." + mirror.id + ".1"
	_volume(mirrored, 1000 * MM3, "Mirrored body keeps a positive volume")
	_expect(_shape(mirrored) != null and absf((_shape(mirrored).bbox() as AABB).get_center().x + 0.06) < 1e-6, "The mirror copy should sit at x = -60 mm (%s)." % [_shape(mirrored).bbox() if _shape(mirrored) != null else "none"])
	_expect(doc.body_name(mirrored) == "Body2 (1)", "Copies are named after their source body (%s)." % doc.body_name(mirrored))
	var grid: Array = result.bodies.keys().filter(func(id: String) -> bool: return id.begins_with(_body(cube) + "." + row.id))
	_expect(grid.size() == 4, "A 3 x 2 pattern with one copy suppressed should add 4 bodies (%d)." % grid.size())

	# Mirror of a feature joins its copy to the same body; a path pattern follows a line.
	_new_doc()
	var slab := _box(Vector3.ZERO, 100, 5, 40)
	var lump_sketch := _rect({"origin": Vector3(0, 0.005, 0), "x": Vector3.RIGHT, "y": Vector3.FORWARD}, Vector2(20, -5), 10, 10)
	var lump := _add("extrude", {"distance": "5 mm"}, {"profiles": [_profile(lump_sketch)], "operation": OPERATIONS.JOIN})
	var feature_mirror := _add("mirror", {}, {"object_type": "features", "objects": [{"kind": "feature", "feature": lump.id}], "plane": [{"kind": "origin", "name": "yz"}]})
	var path_sketch: Resource = doc.add_feature("sketch", "Sketch", {}, SKETCH_DATA.new_options(SKETCH_DATA.ORIGIN_PLANES.xz, "xz"))
	var ps = SKETCH_DATA.new(path_sketch, doc)
	var line: int = ps.add_line(ps.add_point(Vector2(0.025, 0.0)), ps.add_point(Vector2(0.025, 0.015)))
	_rebuild()
	var hole := _add("hole", {"diameter": "3 mm"}, {"points": [{"kind": "vertex", "body": _body(slab), "point": Vector3(-0.04, 0.005, 0.0)}], "face": [_face_ref(_body(slab), Vector3.UP)], "extent": "all"})
	var along := _add("path_pattern", {"quantity": ["3", "number"], "distance": "15 mm"}, {"object_type": "features", "objects": [{"kind": "feature", "feature": hole.id}], "path": [{"kind": "sketch_curve", "sketch": path_sketch.id, "entity": line}]})
	_rebuild()
	_no_errors("Feature mirror and path pattern")
	_volume(_body(slab), (100 * 5 * 40 + 2 * 500 - 3 * PI * 2.25 * 5) * MM3, "Mirrored boss joins; three holes along the path")
	_expect(not result.errors.has(feature_mirror.id) and not result.errors.has(along.id), "Feature mirror and path pattern should build.")


## Pattern on Path spaces copies by length along the path (along an ellipse they landed at 0.18,
## 0.43 and 0.57 of it for 0.2, 0.4 and 0.6: the curve's parameter), and Path Direction turns a
## copy whose heading is exactly opposite the start's about the path's bend (it was mirrored across
## the path's plane).
func _check_path_spacing() -> void:
	_new_doc()
	var plane: Dictionary = SKETCH_DATA.ORIGIN_PLANES.xy
	var es: Resource = doc.add_feature("sketch", "Sketch", {}, SKETCH_DATA.new_options(plane, "xy"))
	var e = SKETCH_DATA.new(es, doc)
	var ellipse: int = e.add_ellipse(e.add_point(Vector2.ZERO), e.add_point(Vector2(0.01, 0)), 0.004)
	var xd: Vector3 = plane.get("x", Vector3.RIGHT)
	var yd: Vector3 = plane.get("y", Vector3.UP)
	# The ellipse's semi-axes are sqrt(116) and 4 mm (the second point is a focus); its length from
	# its start, by many short chords.
	var major := sqrt(116.0) * 0.001
	var minor := 0.004
	var n := 20000
	var lengths := PackedFloat64Array([0.0])
	for i in n:
		lengths.append(lengths[i] + (Vector2(major * cos(TAU * (i + 1) / n), minor * sin(TAU * (i + 1) / n)) - Vector2(major * cos(TAU * i / n), minor * sin(TAU * i / n))).length())
	var perimeter: float = lengths[n]
	var source := _box(Vector3.ZERO, 1, 1, 1)
	var along := _add("path_pattern", {"quantity": ["4", "number"], "distance": "%s mm" % (0.6 * perimeter * 1000.0)}, {"object_type": "bodies", "objects": [{"kind": "body", "body": _body(source)}], "path": [{"kind": "sketch_curve", "sketch": es.id, "entity": ellipse}], "distance_type": "extent"})
	_rebuild()
	_no_errors("Pattern on Path along an ellipse")
	var start := Vector2(major, 0)
	var from: Vector3 = (_shape(_body(source)).bbox() as AABB).get_center() if _shape(_body(source)) != null else Vector3.ZERO
	for k in range(1, 4):
		var id := "%s.%s.%d" % [_body(source), along.id, k]
		var target: float = 0.2 * k * perimeter
		var i := lengths.bsearch(target)
		var angle := TAU * (i - 1 + (target - lengths[i - 1]) / (lengths[i] - lengths[i - 1])) / n
		var want := Vector2(major * cos(angle), minor * sin(angle)) - start
		var moved: Vector3 = (_shape(id).bbox() as AABB).get_center() - from if _shape(id) != null else Vector3(1, 1, 1)
		_expect((Vector2(moved.dot(xd), moved.dot(yd)) - want).length() < 2e-6, "Copy %d along the ellipse should sit %.1f of its length along it (moved %s mm, want %s mm)." % [k, 0.2 * k, Vector2(moved.dot(xd), moved.dot(yd)) * 1000.0, want * 1000.0])
	# A semicircle on the XZ plane (normal +y) from the origin heading +x, round to 20 mm along the
	# sketch's y heading -x; a box above the plane (+y) copied to its end following the path stays
	# above it.
	_new_doc()
	var ss: Resource = doc.add_feature("sketch", "Sketch", {}, SKETCH_DATA.new_options(SKETCH_DATA.ORIGIN_PLANES.xz, "xz"))
	var s = SKETCH_DATA.new(ss, doc)
	var arc: int = s.add_arc(s.add_point(Vector2(0, 0.01)), s.add_point(Vector2.ZERO), s.add_point(Vector2(0, 0.02)))
	var block := _add("box", {"length": "1 mm", "height": "1 mm", "width": "1 mm"}, {"position": Vector3(0, 0.001, 0), "operation": OPERATIONS.NEW_BODY})
	var turned := _add("path_pattern", {"quantity": ["2", "number"], "distance": "%s mm" % (PI * 10.0)}, {"object_type": "bodies", "objects": [{"kind": "body", "body": _body(block)}], "path": [{"kind": "sketch_curve", "sketch": ss.id, "entity": arc}], "distance_type": "extent", "orientation": "path"})
	_rebuild()
	_no_errors("Pattern on Path round a semicircle, following it")
	var copy := _shape("%s.%s.1" % [_body(block), turned.id])
	var was: AABB = _shape(_body(block)).bbox() if _shape(_body(block)) != null else AABB()
	var now: AABB = copy.bbox() if copy != null else AABB()
	_expect(copy != null and signf(now.get_center().y) == signf(was.get_center().y) and absf(now.get_center().y - was.get_center().y) < 1e-6, "A copy at the end of a semicircle, turned exactly round, should stay on the same side of the path's plane (y %s mm, source %s mm)." % [now.get_center().y * 1000.0, was.get_center().y * 1000.0])


# --- Modify ----------------------------------------------------------------------------------

func _check_modify() -> void:
	_new_doc()
	var a := _box(Vector3.ZERO, 40, 20, 30)
	var b := _box(Vector3(300, 0, 0), 40, 20, 30)
	var c := _box(Vector3(600, 0, 0), 20, 20, 20)
	var d := _box(Vector3(610, 0, 0), 20, 20, 20)
	var e := _box(Vector3(900, 0, 0), 20, 20, 20)
	var ball := _add("sphere", {"diameter": "20 mm"}, {"position": Vector3(1.2, 0.01, 0), "operation": OPERATIONS.NEW_BODY})
	var f := _box(Vector3(1500, 0, 0), 40, 20, 30)
	var g := _box(Vector3(1800, 0, 0), 10, 10, 10)
	var h := _box(Vector3(2100, 0, 0), 40, 20, 30)
	_rebuild()
	var edge := _edge_ref(_body(a), Vector3.FORWARD, 0.03)
	var fillet := _add("fillet", {"radius": "1 mm"}, {"edges": [edge]})
	var chamfer := _add("chamfer", {"distance": "2 mm"}, {"edges": [_edge_ref(_body(b), Vector3.FORWARD, 0.03)]})
	var offset := _add("offset_face", {"distance": "2 mm"}, {"faces": [_face_ref(_body(h), Vector3.UP)]})
	var combine := _add("combine", {}, {"target": [{"kind": "body", "body": _body(c)}], "tools": [{"kind": "body", "body": _body(d)}], "operation": "cut"})
	var cut_plane := _add("plane", {"distance": "905 mm"}, {"method": "offset", "plane": [{"kind": "origin", "name": "yz"}]})
	var split := _add("split_body", {}, {"body": [{"kind": "body", "body": _body(e)}], "tool": [{"kind": "construct", "feature": cut_plane.id}]})
	var silhouette := _add("silhouette_split", {}, {"body": [{"kind": "body", "body": _body(ball)}], "direction": [{"kind": "origin", "name": "y"}]})
	var lift := _add("plane", {"distance": "25 mm"}, {"method": "offset", "plane": [{"kind": "origin", "name": "xz"}]})
	var replace := _add("replace_face", {}, {"faces": [_face_ref(_body(f), Vector3.UP)], "target": [{"kind": "construct", "feature": lift.id}]})
	var thicken := _add("thicken", {"thickness": "3 mm"}, {"faces": [_face_ref(_body(f), Vector3.DOWN)], "flip": true, "operation": OPERATIONS.NEW_BODY})
	var scaled := _add("scale", {"scale": ["2", "number"]}, {"bodies": [{"kind": "body", "body": _body(g)}], "point": [{"kind": "vertex", "body": _body(g), "point": Vector3(1.8, 0, 0)}]})
	var moved := _add("move", {"distance": "10 mm"}, {"objects": [{"kind": "body", "body": _body(g)}], "move_type": "translate", "axis": [{"kind": "origin", "name": "z"}]})
	var copied := _add("move", {"x": "50 mm"}, {"objects": [{"kind": "body", "body": _body(g)}], "move_type": "free", "copy": true})
	_rebuild()
	_no_errors("Modify")
	_volume(_body(a), (24000 - (1.0 - PI / 4.0) * 1 * 30) * MM3, "1 mm fillet removes (1 - pi/4) r^2 L")
	_volume(_body(b), (24000 - 0.5 * 4 * 30) * MM3, "Equal chamfer")
	_volume(_body(h), (24000 + 40 * 30 * 2) * MM3, "Offset the top face 2 mm")
	_volume(_body(c), 10 * 20 * 20 * MM3, "Combine cut")
	var pieces: Array = result.bodies.keys().filter(func(id: String) -> bool: return id == _body(e) or id.begins_with(_body(e) + "."))
	_expect(pieces.size() == 2, "Split Body should make two bodies (%s)." % [pieces])
	var total := 0.0
	for id in pieces:
		total += float(_shape(id).volume())
	_expect(absf(total - 8000 * MM3) < 8000 * MM3 * 1e-6, "The split pieces should add up to the body (%s)." % total)
	var halves: Array = result.bodies.keys().filter(func(id: String) -> bool: return id == _body(ball) or id.begins_with(_body(ball) + "."))
	_expect(halves.size() == 2 and absf(float(_shape(halves[0]).volume()) - PI * 1000 / 3.0 * 2.0 * MM3) < 1e-12, "Silhouette Split of a sphere seen from above should make two halves.")
	_volume(_body(f), 40 * 25 * 30 * MM3, "Replace Face moves the top to the plane 25 mm up")
	_volume(_body(thicken), 40 * 30 * 3 * MM3, "Thicken the bottom face 3 mm")
	_volume(_body(g), 8000 * MM3, "Scale x2 multiplies the volume by 8")
	var g_box: AABB = _shape(_body(g)).bbox()
	_expect(absf(g_box.get_center().z - 0.01) < 1e-6, "Move along Z should shift the body 10 mm (%s)." % g_box)
	var copy_id: String = _body(g) + "." + copied.id + ".1"
	_expect(result.bodies.has(copy_id) and absf((_shape(copy_id).bbox() as AABB).get_center().x - g_box.get_center().x - 0.05) < 1e-6, "Move with Copy should leave the body and add a moved copy (%s; %s vs %s)." % [result.bodies.keys(), _shape(copy_id).bbox() if result.bodies.has(copy_id) else "none", g_box])
	for feature in [fillet, chamfer, offset, combine, split, silhouette, replace, thicken, scaled, moved]:
		_expect(not result.errors.has(feature.id), "%s should succeed (%s)." % [feature.label, result.errors.get(feature.id, "")])

	# Shell (open, closed), draft, split face, boundary fill, align, remove, base feature.
	_new_doc()
	var cup := _box(Vector3.ZERO, 40, 20, 30)
	var hollow := _box(Vector3(200, 0, 0), 40, 20, 30)
	var drafted := _box(Vector3(400, 0, 0), 40, 20, 30)
	var parted := _box(Vector3(600, 0, 0), 40, 20, 30)
	var filled := _box(Vector3(800, 0, 0), 40, 20, 30)
	var aligned := _box(Vector3(1000, 0, 0), 10, 10, 10)
	var removed := _box(Vector3(1200, 0, 0), 10, 10, 10)
	_rebuild()
	_add("shell", {"thickness": "2 mm"}, {"faces": [_face_ref(_body(cup), Vector3.UP)]})
	_add("shell", {"thickness": "2 mm"}, {"faces": [{"kind": "body", "body": _body(hollow)}]})
	_add("draft", {"angle": ["5 deg", "angle"]}, {"faces": [_face_ref(_body(drafted), Vector3.RIGHT)], "plane": [{"kind": "origin", "name": "xz"}]})
	var splitter := _add("plane", {"distance": "600 mm"}, {"method": "offset", "plane": [{"kind": "origin", "name": "yz"}]})
	_add("split_face", {}, {"faces": [_face_ref(_body(parted), Vector3.UP)], "tool": [{"kind": "construct", "feature": splitter.id}]})
	var mid := _add("plane", {"distance": "10 mm"}, {"method": "offset", "plane": [{"kind": "origin", "name": "xz"}]})
	var fill := _add("boundary_fill", {}, {"tools": [{"kind": "body", "body": _body(filled)}, {"kind": "construct", "feature": mid.id}], "cells": [Vector3(0.8, 0.015, 0)], "operation": OPERATIONS.NEW_BODY})
	var high := _add("plane", {"distance": "50 mm"}, {"method": "offset", "plane": [{"kind": "origin", "name": "xz"}]})
	_add("align", {}, {"from": [_face_ref(_body(aligned), Vector3.DOWN)], "to": [{"kind": "construct", "feature": high.id}], "flip": false})
	var remove := _add("remove", {}, {"bodies": [{"kind": "body", "body": _body(removed)}]})
	var brep: PackedByteArray = kernel.make_box(Vector3(0.01, 0.02, 0.03), Vector3(1.5, 0, 0), "").to_brep_bytes()
	var base_body: String = doc.new_body("")
	var base := _add("base_feature", {}, {"breps": {base_body: brep}})
	doc.bodies[base_body]["feature"] = base.id
	_rebuild()
	_no_errors("Shell, draft, split face, fill, align, remove, base feature")
	_volume(_body(cup), (24000 - 36 * 18 * 26) * MM3, "Open shell")
	_volume(_body(hollow), (24000 - 36 * 16 * 26) * MM3, "Closed (hollow) shell")
	_volume(_body(drafted), (24000 - 0.5 * 20 * (20 * tan(deg_to_rad(5.0))) * 30) * MM3, "Draft from the ground plane")
	_expect(_shape(_body(parted)).face_count() == 7, "Split Face should divide the top face in two.")
	_volume(_body(fill), 40 * 10 * 30 * MM3, "Boundary Fill keeps the upper cell")
	var seated: AABB = _shape(_body(aligned)).bbox()
	_expect(absf(seated.position.y - 0.05) < 1e-6 and absf(seated.get_center().x - 1.0) < 1e-6, "Align should seat the bottom face on the plane 50 mm up, staying where it was across the plane (%s)." % seated)
	_expect(not result.bodies.has(_body(removed)) and not result.errors.has(remove.id), "Remove should drop the body from the result.")
	_volume(base_body, 6000 * MM3, "Base feature body")


# --- Construct -------------------------------------------------------------------------------

func _check_construct() -> void:
	_new_doc()
	var block := _box(Vector3.ZERO, 40, 20, 30)
	var tube := _add("cylinder", {"diameter": "10 mm", "height": "30 mm"}, {"position": Vector3(0.1, 0, 0), "operation": OPERATIONS.NEW_BODY})
	_rebuild()
	var top := _face_ref(_body(block), Vector3.UP)
	var side := _face_ref(_body(block), Vector3.RIGHT)
	var left := _face_ref(_body(block), Vector3.LEFT)
	var round_face := {}
	var tube_shape := _shape(_body(tube))
	for i in tube_shape.face_count():
		if tube_shape.face_info(i).type == "cylinder":
			round_face = {"kind": "face", "body": _body(tube), "name": tube_shape.get_face_names()[i], "sig": {}}
	var o := func(name: String) -> Array: return [{"kind": "origin", "name": name}]
	var specs := {
		"offset": _add("plane", {"distance": "5 mm"}, {"method": "offset", "plane": [top]}),
		"angle": _add("plane", {"angle": ["90 deg", "angle"]}, {"method": "angle", "axis": o.call("x")}),
		"tangent": _add("plane", {"angle": ["0 deg", "angle"]}, {"method": "tangent", "face": [round_face], "plane": o.call("yz")}),
		"midplane": _add("plane", {}, {"method": "midplane", "plane": [side], "plane2": [left]}),
		"perpendicular": _add("plane", {}, {"method": "perpendicular", "axis": o.call("z")}),
		"three_points": _add("plane", {}, {"method": "three_points", "points": [{"kind": "vertex", "point": Vector3.ZERO}, {"kind": "vertex", "point": Vector3.RIGHT}, {"kind": "vertex", "point": Vector3.BACK}]}),
		"tangent_at_point": _add("plane", {}, {"method": "tangent_at_point", "face": [top], "point": [{"kind": "vertex", "point": Vector3(0, 0.03, 0)}]}),
		"axis_cylinder": _add("axis", {}, {"method": "cylinder", "face": [round_face]}),
		"axis_planes": _add("axis", {}, {"method": "two_planes", "plane": o.call("xy"), "plane2": o.call("yz")}),
		"axis_points": _add("axis", {}, {"method": "two_points", "point": [{"kind": "vertex", "point": Vector3.ZERO}], "point2": [{"kind": "vertex", "point": Vector3(0, 0, 2)}]}),
		"axis_perp": _add("axis", {}, {"method": "perp_at_point", "face": [top], "point": [{"kind": "vertex", "point": Vector3(0.01, 0.5, 0)}]}),
		"point_planes": _add("point", {}, {"method": "three_planes", "plane": [top], "plane2": [side], "plane3": o.call("xy")}),
		"point_center": _add("point", {}, {"method": "center", "center": [round_face]}),
		"point_edges": _add("point", {}, {"method": "two_edges", "axis": o.call("x"), "axis2": o.call("y")}),
		"point_edge_plane": _add("point", {}, {"method": "edge_plane", "axis": o.call("y"), "plane": [top]}),
	}
	_rebuild()
	_no_errors("Construct")
	var c: Dictionary = result.construction
	var at := func(key: String) -> Dictionary: return c.get(specs[key].id, {})
	_expect(absf(float(at.call("offset").get("origin", Vector3.ZERO).y) - 0.025) < 1e-6 and (at.call("offset").normal as Vector3).is_equal_approx(Vector3.UP), "Offset plane 5 mm above the top face (%s)." % [at.call("offset")])
	_expect(absf(absf((at.call("angle").normal as Vector3).dot(Vector3.UP)) - 1.0) > 0.5, "A plane at 90 degrees about X turns away from its base plane.")
	_expect(absf((at.call("tangent").origin as Vector3).distance_to(Vector3(0.105, 0.015, 0.0))) < 1e-6 or absf(Vector2((at.call("tangent").origin as Vector3).x - 0.1, (at.call("tangent").origin as Vector3).z).length() - 0.005) < 1e-6, "A tangent plane touches the round face (%s)." % [at.call("tangent")])
	_expect(absf((at.call("midplane").origin as Vector3).x) < 1e-6 and absf(absf((at.call("midplane").normal as Vector3).x) - 1.0) < 1e-6, "The midplane of the two side faces is the YZ plane.")
	_expect((at.call("three_points").normal as Vector3).is_equal_approx(Vector3.DOWN), "A plane through (0,0,0), (1,0,0), (0,0,1) faces down.")
	_expect(absf((at.call("tangent_at_point").origin as Vector3).y - 0.02) < 1e-6, "A point dropped onto the top face sits at its height.")
	_expect(absf((at.call("axis_cylinder").origin as Vector3).x - 0.1) < 1e-6 and absf(absf((at.call("axis_cylinder").direction as Vector3).y) - 1.0) < 1e-6, "The cylinder's axis is vertical through its center (%s)." % [at.call("axis_cylinder")])
	_expect(absf(absf((at.call("axis_planes").direction as Vector3).y) - 1.0) < 1e-6, "XY and YZ meet along Y.")
	_expect((at.call("axis_points").direction as Vector3).is_equal_approx(Vector3.BACK), "Two points make an axis from one to the other.")
	_expect((at.call("axis_perp").direction as Vector3).is_equal_approx(Vector3.UP) and absf((at.call("axis_perp").origin as Vector3).y - 0.02) < 1e-6, "Axis perpendicular to the top face at a point (%s)." % [at.call("axis_perp")])
	_expect((at.call("point_planes").position as Vector3).distance_to(Vector3(0.02, 0.02, 0)) < 1e-6, "Three planes meet at the top-right edge's middle.")
	_expect(absf((at.call("point_center").position as Vector3).x - 0.1) < 1e-6, "The round face's center point is on its axis (%s)." % [at.call("point_center")])
	_expect((at.call("point_edges").position as Vector3).length() < 1e-6, "The X and Y axes meet at the origin.")
	_expect((at.call("point_edge_plane").position as Vector3).distance_to(Vector3(0, 0.02, 0)) < 1e-6, "The Y axis meets the top face's plane 20 mm up.")
	_expect(at.call("perpendicular").get("normal", Vector3.ZERO).is_equal_approx(Vector3.BACK), "A plane perpendicular to Z faces along Z.")


# --- Components ------------------------------------------------------------------------------

func _check_components() -> void:
	_new_doc()
	var loose := _box(Vector3.ZERO, 10, 10, 10)
	var part := _add("box", {"length": "10 mm", "height": "10 mm", "width": "10 mm"}, {"position": Vector3(0.1, 0, 0), "operation": OPERATIONS.NEW_COMPONENT})
	part.options["component_id"] = doc.new_component(part.id)
	doc.bodies[_body(part)]["component"] = part.options.component_id
	_rebuild()
	_no_errors("Components")
	_expect(result.bodies.has(_body(part)) and doc.body_component(_body(part)) == part.options.component_id and doc.body_component(_body(loose)) == "",
		"A New Component body should sit in its own component.")
	doc.components[part.options.component_id]["visible"] = false
	_expect(not doc.body_visible(_body(part)) and doc.body_visible(_body(loose)), "Hiding a component hides its bodies.")
	var state: Dictionary = doc.snapshot()
	doc.remove_feature(part.id)
	_expect(doc.components.is_empty(), "Removing the feature removes the component it made.")
	doc.restore(state)
	_expect(doc.components.size() == 1, "Undo (restore) brings the component back.")


# --- Topological naming ----------------------------------------------------------------------

func _check_naming() -> void:
	_new_doc()
	var rect := _rect("xz", Vector2.ZERO, 40, 20)
	var extrude := _add("extrude", {"distance": "10 mm"}, {"profiles": [_profile(rect)], "operation": OPERATIONS.NEW_BODY})
	_rebuild()
	var body := _body(extrude)
	var edge_name := "%s:end|%s:g(s%d)" % [extrude.id, extrude.id, rect.lines[1]]
	var index: int = _shape(body).find_edge(edge_name)
	_expect(index >= 0, "The right-hand top edge should be findable by name (%s)." % [_shape(body).get_edge_names()])
	var edge := {"kind": "edge", "body": body, "name": edge_name, "sig": {"type": "line", "point": _shape(body).edge_info(index).midpoint, "length": 0.02}}
	var fillet := _add("fillet", {"radius": "3 mm"}, {"edges": [edge]})
	_rebuild()
	_volume(body, (8000 - (1.0 - PI / 4.0) * 9 * 20) * MM3, "Fillet before the edit")
	# Widen the sketch: the edge moves to x = 60 mm, the fillet follows it by name.
	rect.feature.set_expression("dim%d" % rect.dims[0], "60 mm")
	_rebuild()
	_no_errors("After widening the sketch")
	_volume(body, (12000 - (1.0 - PI / 4.0) * 9 * 20) * MM3, "Fillet after the sketch got wider")
	_expect(not result.warnings.has(fillet.id), "The fillet should find its edge by name, not by repair (%s)." % [result.warnings])
	var rounded := _shape(body)
	var fillet_face := -1
	for f in rounded.face_count():
		if rounded.face_info(f).type == "cylinder":
			fillet_face = f
	_expect(fillet_face >= 0 and absf((rounded.face_info(fillet_face).point as Vector3).x - 0.06) < 0.003, "The rounded edge should be at the new right-hand side.")


# --- Timeline speed --------------------------------------------------------------------------

func _check_timing() -> void:
	_new_doc()
	var plate := _box(Vector3.ZERO, 120, 10, 80)
	_rebuild()
	var top := _face_ref(_body(plate), Vector3.UP)
	var boss_sketch := _rect({"origin": Vector3(0, 0.01, 0), "x": Vector3.RIGHT, "y": Vector3.FORWARD}, Vector2(-10, -10), 20, 20)
	var boss := _add("extrude", {"distance": "15 mm"}, {"profiles": [_profile(boss_sketch)], "operation": OPERATIONS.JOIN})
	var holes := []
	for i in 6:
		holes.append(_add("hole", {"diameter": "5 mm", "depth": "6 mm"}, {"points": [{"kind": "vertex", "body": _body(plate), "point": Vector3(-0.05 + i * 0.02, 0.01, 0.03)}], "face": [top]}))
	var pattern := _add("rect_pattern", {"quantity1": ["2", "number"], "distance1": "10 mm"}, {"object_type": "features", "objects": [{"kind": "feature", "feature": holes[0].id}], "direction1": [{"kind": "origin", "name": "z"}], "distance_type": "spacing", "flip1": true})
	_rebuild()
	_add("fillet", {"radius": "2 mm"}, {"edges": [_edge_ref(_body(plate), Vector3.UP, 0.01)]})
	var long_edge := _edge_ref(_body(plate), Vector3.RIGHT, 0.12)
	_expect(not long_edge.is_empty(), "The plate should have a 120 mm edge along X (%s)." % [range(_shape(_body(plate)).edge_count()).map(func(e: int) -> String: return "%s %s" % [_shape(_body(plate)).edge_info(e).type, _shape(_body(plate)).edge_info(e).length])])
	_add("chamfer", {"distance": "1 mm"}, {"edges": [long_edge]})
	var plane := _add("plane", {"distance": "40 mm"}, {"method": "offset", "plane": [{"kind": "origin", "name": "xz"}]})
	_add("cylinder", {"diameter": "8 mm", "height": "30 mm"}, {"position": Vector3(0.04, -0.01, -0.02), "operation": OPERATIONS.CUT})
	_add("cylinder", {"diameter": "8 mm", "height": "30 mm"}, {"position": Vector3(-0.04, -0.01, -0.02), "operation": OPERATIONS.CUT})
	var post := _add("cylinder", {"diameter": "6 mm", "height": "10 mm"}, {"position": Vector3(0.2, 0, 0), "operation": OPERATIONS.NEW_BODY})
	_add("mirror", {}, {"object_type": "bodies", "objects": [{"kind": "body", "body": _body(post)}], "plane": [{"kind": "origin", "name": "yz"}]})
	_add("move", {"distance": "5 mm"}, {"objects": [{"kind": "body", "body": _body(post)}], "move_type": "translate", "axis": [{"kind": "origin", "name": "y"}]})
	_add("axis", {}, {"method": "two_planes", "plane": [{"kind": "origin", "name": "xy"}], "plane2": [{"kind": "construct", "feature": plane.id}]})
	_add("torus", {"diameter": "30 mm", "section": "6 mm"}, {"position": Vector3(0, 0.1, 0), "operation": OPERATIONS.NEW_BODY})
	_expect(doc.features.size() == 20, "The timing timeline should have 20 features (%d)." % doc.features.size())
	_rebuild()
	_no_errors("20-feature timeline")
	var full_volume: float = _shape(_body(plate)).volume()
	var start := Time.get_ticks_usec()
	doc.rollback = 8
	_rebuild()
	var rolled: int = result.bodies.size()
	holes[0].set_expression("diameter", "4 mm")
	doc.rollback = -1
	_rebuild()
	_timing_ms = int((Time.get_ticks_usec() - start) / 1000)
	_no_errors("20-feature timeline after the edit")
	_expect(rolled == 1 and _shape(_body(plate)).volume() > full_volume, "The edit (a smaller patterned hole) should show after recompute.")
	# Rolling back, editing and recomputing against recomputing the whole timeline as it is, in
	# turns (a limit in milliseconds failed whenever the machine was busy).
	var diameters := ["4 mm", "5 mm"]
	var edit := func() -> void:
		doc.rollback = 8
		REGEN.rebuild(doc, kernel)
		diameters.reverse()
		holes[0].set_expression("diameter", diameters[0])
		doc.rollback = -1
		REGEN.rebuild(doc, kernel)
	var timing := TIMING.compare(edit, func() -> void: REGEN.rebuild(doc, kernel), 3, "roll back, edit and recompute 20 features / recompute them")
	_expect(timing.ratio < 3.0, "Rolling back, editing and recomputing 20 features should take under 3 times a plain recompute (%.1f ms against %.1f ms)." % [timing.op, timing.calibration])
	holes[0].set_expression("diameter", "4 mm")
	_rebuild()
	_expect(not result.errors.has(pattern.id), "The hole pattern should follow the edited hole.")


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error(message)
		print("FAIL: ", message)
