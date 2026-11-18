@tool
extends RefCounted
## Holo Forge's install self-test: a short check that the addon works in this project, shipped with
## the addon (the full test suites stay in the repository).
##
## It loads the CAD kernel, draws a rectangle sketch on purpose at the wrong size and lets the
## constraint solver drive it to its 40 x 20 mm dimensions, extrudes it 10 mm, fillets one edge,
## and bakes the body into a MeshInstance3D. Every step is checked against exact numbers.
##
## Run it from Project > Tools > Holo Forge: Run Self-Test, or headless, as the Windows installer
## does:
##
##     godot --headless --path <project> --editor -- --holo-forge-self-test [--holo-forge-self-test-log=<file>]
##
## (exit code 0 when every check passes, 1 otherwise).

const DOCUMENT := preload("res://addons/holo_forge/core/document.gd")
const REGEN := preload("res://addons/holo_forge/core/regen.gd")
const SKETCH_DATA := preload("res://addons/holo_forge/core/sketch/sketch_data.gd")
const OPERATIONS := preload("res://addons/holo_forge/core/operations.gd")
const CAD_PART := preload("res://addons/holo_forge/nodes/cad_part.gd")

const MM := 0.001
const MM3 := 1e-9
## The fillet volume is exact; single-precision points allow about 1e-6 of it.
const VOLUME_TOLERANCE := 1e-5

## One line per check, starting with "PASS" or "FAIL".
var lines: PackedStringArray = []
var passed := true


## Runs every check. host is a node in the scene tree (the baked part goes under it for a moment).
func run(host: Node) -> bool:
	lines.clear()
	passed = true
	var started := Time.get_ticks_msec()
	var info := Engine.get_version_info()
	lines.append("Holo Forge %s self-test on Godot %s (%s)" % [_addon_version(), str(info.get("string", "?")), OS.get_name()])
	var kernel := _check_kernel()
	if kernel != null:
		var doc := _check_model(kernel)
		if doc != null:
			await _check_bake(doc, kernel, host)
	lines.append("%s: %d ms" % ["ALL CHECKS PASSED" if passed else "SELF-TEST FAILED", Time.get_ticks_msec() - started])
	return passed


func report() -> String:
	return "\n".join(lines)


func _check_kernel() -> RefCounted:
	var kernel: RefCounted = REGEN.make_kernel() if ClassDB.class_exists("CadShape") else null
	_expect(kernel != null, "The CAD kernel loads (holo_forge_native.dll and the libraries next to it).",
		"The CAD kernel didn't load. Check that addons/holo_forge/bin holds every DLL from the download, and that this is the 64-bit Windows editor, Godot 4.7 or newer.")
	return kernel


## Sketch (solved), extrude and fillet, by exact volumes. Returns the document, or null on a failure.
func _check_model(kernel: RefCounted) -> Resource:
	var doc: Resource = DOCUMENT.new()
	var frame: Dictionary = SKETCH_DATA.ORIGIN_PLANES["xz"]
	var sketch: Resource = doc.add_feature("sketch", "Sketch", {}, SKETCH_DATA.new_options(frame, "xz"))
	var s = SKETCH_DATA.new(sketch, doc)
	# Drawn 30 x 12 mm; the dimensions say 40 x 20 mm, so only a working solver gets it right.
	var p := [s.add_point(Vector2.ZERO), s.add_point(Vector2(30, 0) * MM), s.add_point(Vector2(30, 12) * MM), s.add_point(Vector2(0, 12) * MM)]
	var edges := []
	for i in 4:
		edges.append(s.add_line(p[i], p[(i + 1) % 4]))
	s.add_constraint("fix", [p[0]])
	s.add_constraint("horizontal", [edges[0]])
	s.add_constraint("horizontal", [edges[2]])
	s.add_constraint("vertical", [edges[1]])
	s.add_constraint("vertical", [edges[3]])
	s.add_constraint("distance_x", [p[0], p[1]], "40 mm")
	s.add_constraint("distance_y", [p[1], p[2]], "20 mm")
	var extrude: Resource = doc.add_feature("extrude", "Extrude", {"distance": doc.make_input("10 mm", "length")},
		{"profiles": [{"kind": "profile", "sketch": sketch.id, "point": Vector2(5, 5) * MM}], "operation": OPERATIONS.NEW_BODY})
	var body_id: String = doc.new_body(extrude.id)
	extrude.options["body_id"] = body_id

	var result: Dictionary = REGEN.rebuild(doc, kernel)
	var shape: RefCounted = result.bodies[body_id].shape if result.get("bodies", {}).has(body_id) else null
	var v: float = shape.volume() if shape != null else -1.0
	_expect(shape != null and absf(v - 8000 * MM3) <= 8000 * MM3 * VOLUME_TOLERANCE,
		"The sketch solver drives a 30 x 12 mm rectangle to its 40 x 20 mm dimensions, and Extrude makes the 8000 mm3 solid.",
		"Sketch + Extrude went wrong: expected 8000 mm3, got %s (errors: %s)." % [_mm3(v), result.get("errors", {})])
	if shape == null:
		return null

	# Fillet one 10 mm upright edge, r = 1 mm: it removes exactly (1 - pi/4) r^2 L.
	var edge := {}
	for e in shape.edge_count():
		var info: Dictionary = shape.edge_info(e)
		if info.get("type", "") == "line" and absf(float(info.length) - 10 * MM) < 1e-6 and absf(absf((info.tangent as Vector3).dot(Vector3.UP)) - 1.0) < 1e-6:
			edge = {"kind": "edge", "body": body_id, "name": shape.get_edge_names()[e], "sig": {"type": "line", "point": info.midpoint, "length": info.length}}
			break
	_expect(not edge.is_empty(), "The solid has its 10 mm upright edges, with names.", "No 10 mm upright edge was found on the extruded solid.")
	if edge.is_empty():
		return null
	doc.add_feature("fillet", "Fillet", {"radius": doc.make_input("1 mm", "length")}, {"edges": [edge]})
	result = REGEN.rebuild(doc, kernel)
	shape = result.bodies[body_id].shape if result.get("bodies", {}).has(body_id) else null
	v = shape.volume() if shape != null else -1.0
	var expected := (8000 - (1.0 - PI / 4.0) * 1 * 10) * MM3
	_expect(shape != null and (result.get("errors", {}) as Dictionary).is_empty() and absf(v - expected) <= expected * VOLUME_TOLERANCE,
		"Fillet rounds an edge with a 1 mm radius (exact volume %s mm3)." % _mm3(expected),
		"Fillet went wrong: expected %s mm3, got %s (errors: %s)." % [_mm3(expected), _mm3(v), result.get("errors", {})])
	return doc if shape != null else null


## The part bakes to one MeshInstance3D with the solid's size.
func _check_bake(doc: Resource, kernel: RefCounted, host: Node) -> void:
	var part: Node3D = CAD_PART.new()
	part.name = "HoloForgeSelfTest"
	host.add_child(part)
	part.document = doc
	part.apply_result(REGEN.rebuild(doc, kernel))
	await host.get_tree().process_frame
	var nodes: Dictionary = part.body_nodes()
	var node: MeshInstance3D = nodes.values()[0] if nodes.size() == 1 else null
	var size: Vector3 = node.get_aabb().size if node != null and node.mesh != null else Vector3.ZERO
	_expect(node != null and node.mesh != null and size.distance_to(Vector3(40, 10, 20) * MM) < 1e-5,
		"The body bakes into a MeshInstance3D of 40 x 10 x 20 mm.",
		"Baking went wrong: expected one 40 x 10 x 20 mm MeshInstance3D, got %d node(s), size %s m." % [nodes.size(), size])
	host.remove_child(part)
	part.free()


func _expect(condition: bool, pass_text: String, fail_text: String) -> void:
	lines.append(("PASS  " + pass_text) if condition else ("FAIL  " + fail_text))
	passed = passed and condition


static func _mm3(cubic_meters: float) -> String:
	return "%.3f" % (cubic_meters / MM3) if cubic_meters >= 0.0 else "nothing"


static func _addon_version() -> String:
	var cfg := ConfigFile.new()
	return str(cfg.get_value("plugin", "version", "?")) if cfg.load("res://addons/holo_forge/plugin.cfg") == OK else "?"
