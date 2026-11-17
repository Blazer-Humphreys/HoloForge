extends SceneTree
## Holo Forge Phase 5, the Surface workspace, through the document timeline:
## - surface Extrude, Revolve, Sweep, Loft and Coil make open shells (walls, no caps);
## - Patch fills a 4-edge loop with one face (flat from a box's top edges, twisted between a lofted
##   sheet's edges, domed G1 off the box's vertical walls) and, stitched in, closes an open box
##   into a solid;
## - Unstitch then Stitch turns a box's 6 faces back into a closed solid of the box's volume;
## - Thicken by t gives area x t (an L-shaped sheet mitred at its seam, not overlapped);
## - Trim then Untrim gives the original area back (a hole in a flat strip, a cut-off end of a
##   lofted sheet), and Trim with nothing picked cuts the surface into clickable pieces;
## - Ruled, Offset, Extend (natural on a cylinder, tangent on a flat face), Merge, Reverse Normal,
##   Split Body into pieces, Fillet across a surface seam, Offset Face and patterns on surfaces;
## - surface-only tools refuse solids; every Surface tool is enabled with a spec; surface bodies
##   bake double-sided;
## - straight from the kernel: tapered holes and one-edge loops rise straight (names kept); G1/G2
##   patches carry on from the faces around the loop and are refused when they can't; offsets are
##   refused past a radius of curvature or at an apex, never broken; Offset Face moves whole
##   sheets; natural extends stay joined, grow past a spline's end and integrate in full; flat
##   sheets and tangent corners extend filled; ruled chains, trims along edges, merges across
##   cuts, stitch refusals, closed one-face sheets and whole-sheet reverses;
## - review fixes: Trim removes the piece where it was clicked (a holed strip's outer piece), takes
##   a profile or gathered curves as its tool and cuts a surface tool too; pieces of bodies sharing
##   a root keep ids of their own; solids' automatic Join/Cut leave surfaces alone; refused coils
##   say why; Stitch keeps what meets nothing as its own body; Split Body keeps a sheet beside a
##   solid; a stitched Patch owns no body, a flat face is a patch outline, edges take their own
##   continuity; straight edges need a Direction; joined curves loft as one section; suppressed
##   or later sketches drive nothing; Press Pull won't tear a sheet; the extrude arrow follows
##   curves and a Direction; two-sided bodies (and mixed ones) draw, analyse and collide from both
##   sides, keep Material files linked; Interference names unchecked surfaces; Remove takes faces;
## - round 2: three- and four-sided patches are Coons surfaces filling their own surface (G1 rises
##   square off an open box's walls and a tube's rim and closes the box; a twisted loop spans its
##   loft; Untrim keeps them); plates (five sides, points, rails) refuse Untrim's outer loop; G1
##   faces are the ones away from the loop's inside; rails are followed; G2 is no longer offered
##   and a stored one is refused; Untrim keeps sheets joined; Extend refuses to pass an apex or
##   pole (or where its strips' lines cross), says when natural falls back to tangent, and offers
##   Perpendicular and Chain Selection;
## - round 2, part B: Loft lofts every loop (holes, separate pieces; solid and surface) and follows
##   one rail exactly (loops it doesn't touch ride along, open curves are placed where it touches
##   them); tapered walls are true planes (turned off the axes too) and cones (and open curves
##   lean); Thicken refuses what it can't build and rounds convex seams when asked; Ruled fills or
##   cuts back its corners, turned strips alike; Trim is quicker on dense sheets; Replace Face
##   reaches a surface (Surface menu too); Press Pull in the Surface workspace extrudes a surface;
## - round 3: a loop with under three corners is a lens (a tube cap tangent all round, a sphere
##   hole's cap on the sphere), and G1 patches thicken and offset; old plate names still resolve;
##   rails a patch misses are refused; turned spline profiles extend along themselves; a trimmed
##   face's untouched edge extends naturally; perpendicular strips meet across faces, are planes
##   and thicken; the kernel's warning clears; arcs meeting lines taper as a draft; Replace Face
##   stops at the near side of a closed target; a rail loft keeps to its sections and points;
##   lofts of unlike loops are sound; thin skins thicken; old Ruled/Extend features edit back true;
## - round 4: G1 caps that would fold over (a dart, a five-lobed flower) and plates that would run
##   back down walls leaning out are refused, convex and smooth caps still build; a D-cut shaft's
##   cap has no point at its shallow corners and thickens; a lens cap's rim extends 2 mm wide all
##   round in every mode; a sharply bent rail builds with a warning; G1 over sketch curves warns it
##   built G0; a stored G2 patch edits as G1 and an unoffered choice shows as itself; spline
##   bodies' volumes, areas, centres and inertia are exact; boxes hold their shapes; Untrim goes by
##   a face's own edges and keeps it joined (or refuses); a loft to a round loop follows the other
##   loop's edges and is named by them.
## - round 5: only creases or caps leaving their walls fold (cylinder strips past a half turn and a
##   half-G1 box build); D-cut caps carry their walls on to their corners and thicken; small loops'
##   plates and rails build at any size, arch rails too, and a G1 rim with a point is refused for its
##   walls; a stored G2 over curves builds G0; Untrim Outer keeps a joined hole; spline walls and
##   tori measure quickly; Shell works on a copy and refuses an unchanged result; ellipse lengths,
##   small trims and untrims are exact; plate boxes hold their corners' overshoot.
## - round 6: G1 caps say how far they fall short of tangency toward their corners (and facing down
##   near one), in the document too; caps over walls leaning in stay above their rims and inside
##   the walls' planes; smooth caps with a concave stretch build again; Patch, Stitch, Extend and
##   Untrim leave their inputs as they were; lens caps' square bands keep their width; refusals name
##   rails and don't hang on the size; a choice not offered shows once.
## - round 7: Trim and measure speeds are timed against a calibration of the same kind, in turns,
##   so a busy machine doesn't fail them (holo_forge_timing.gd).
## - round 10: sections along a step's top or a hole's side are made, one refused body leaves the
##   others capped; rail lofts keep their sections where drawn; overlapping sweeps, pipes and coils
##   and guided sweeps round tight bends are refused; Thicken and Offset size by the picked faces;
##   twisted rings and small stitched G1 caps build quickly.
## - round 11: sections touching a turned body's hole along a line are made and exact; alike
##   sections loft along a curved rail quickly; sweeps whose helix turns overlap by thousandths of
##   a millimetre are refused; sweeps and pipes round sharp corners are mitred (twisted ones
##   refused); a closed path starts where its profile sits; narrow sheets thicken and offset
##   exactly; twisted rings on turned or small paths are quick.
##
## godot --headless --path . --script res://tests/holo_forge_surface_test.gd

const DOCUMENT := preload("res://addons/holo_forge/core/document.gd")
const REGEN := preload("res://addons/holo_forge/core/regen.gd")
const SKETCH_DATA := preload("res://addons/holo_forge/core/sketch/sketch_data.gd")
const OPERATIONS := preload("res://addons/holo_forge/core/operations.gd")
const REFERENCES := preload("res://addons/holo_forge/core/references.gd")
const SURFACE := preload("res://addons/holo_forge/core/features/surface.gd")
const CATALOG := preload("res://addons/holo_forge/tools/catalog.gd")
const SPECS := preload("res://addons/holo_forge/tools/feature_specs.gd")
const APPEARANCE := preload("res://addons/holo_forge/core/appearance.gd")
const TESSELLATE := preload("res://addons/holo_forge/core/tessellate.gd")
const CAD_PART := preload("res://addons/holo_forge/nodes/cad_part.gd")
const COMMAND := preload("res://addons/holo_forge/tools/command.gd")
const FEATURE_COMMAND := preload("res://addons/holo_forge/tools/feature_command.gd")
const INTERFERENCE := preload("res://addons/holo_forge/tools/interference_command.gd")
const COMMAND_PANEL := preload("res://addons/holo_forge/ui/command_panel.gd")
const ANALYSIS := preload("res://addons/holo_forge/core/analysis.gd")
const INSPECT := preload("res://addons/holo_forge/core/inspect.gd")
const TIMING := preload("res://tests/holo_forge_timing.gd")

const MM := 1e-3
const MM2 := 1e-6
const MM3 := 1e-9

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
		_check_create()
		_check_patch()
		_check_stitch()
		_check_thicken()
		_check_trim()
		_check_modify()
		_check_refusals()
		_check_catalog()
		_check_bake()
		_check_kernel_taper()
		_check_kernel_patch()
		_check_kernel_offset()
		_check_kernel_extend()
		_check_kernel_sheets()
		_check_trim_picks()
		_check_shared_roots()
		_check_solids_near_surfaces()
		_check_stitch_apart()
		_check_patch_command()
		_check_edges_and_chains()
		_check_sketch_order()
		_check_arrow()
		_check_two_sided()
		_check_remove()
		_check_round2_patch()
		_check_round2_plates()
		_check_round2_untrim()
		_check_round2_extend()
		_check_round2_commands()
		_check_round2_loft()
		_check_round2_taper()
		_check_round2_thicken()
		_check_round2_ruled()
		_check_round2_trim_speed()
		_check_round2_replace_face()
		_check_round2_press_pull()
		_check_round3_patch()
		_check_round3_plates()
		_check_round3_extend()
		_check_round3_taper_and_replace()
		_check_round3_loft_and_thicken()
		_check_round4_folds()
		_check_round4_sides()
		_check_round4_lenses()
		_check_round4_warnings_and_choices()
		_check_round4_volumes()
		_check_round4_boxes()
		_check_round4_untrim()
		_check_round4_loft_seams()
		_check_round5_folds()
		_check_round5_lenses()
		_check_round5_rails()
		_check_round5_g2_curves()
		_check_round5_untrim()
		_check_round5_measure_speed()
		_check_round5_shell()
		_check_round5_lengths()
		_check_round5_small_trim()
		_check_round5_boxes()
		_check_round6_shortfalls()
		_check_round6_leaning()
		_check_round6_concave()
		_check_round6_inputs()
		_check_round6_lens_bands()
		_check_round6_reasons()
		_check_round6_unoffered()
		_check_round8_caps()
		_check_round9_fixes()
		_check_round10_fixes()
		_check_round11_fixes()
	if failures.is_empty():
		print("PASS holo_forge_surface: surface extrude/revolve/sweep/loft/coil are open shells; a 4-edge patch is one face (flat, twisted, G1 domed off vertical walls) and stitched in closes a box; unstitch + stitch of a box's 6 faces is a solid of its volume; thicken gives area x t (L sheet mitred); trim + untrim give the area back; ruled, offset, extend (natural/tangent), merge, reverse normal, split into pieces, fillet, offset face and patterns on surfaces; solids refused; every Surface tool enabled; surfaces bake double-sided; kernel tapers, patch checks, offsets, extends, trims, merges, stitches and reverses hold; review fixes (trim by click, profile and surface tools; shared-root ids; solid ops skip surfaces; coil refusals; stitch apart; split mixed; patch command, faces and per-edge continuity; edge directions; loft chains; sketch order; press pull; arrows; two-sided draw, analysis, collision and Material files; interference note; remove faces) hold; round 2 (Coons patches: box dome, tube cap, twisted loop, untrim; plates refuse untrim; supports away from the loop; rails; no G2; untrim stays joined; extend stops short of apex and pole, notes tangent fallbacks, perpendicular and chains) holds; round 2 part B (loft holes, pieces and one rail; flat and conical taper walls, leaning open curves; thicken refusals, exact volumes and rounded seams; ruled corners; quick trim; replace face onto surfaces and the Surface menu; surface press pull) holds; round 3 (lens caps tangent all round, patches thicken and offset, old plate names, missed rails refused, spline profiles extend to their axis, trimmed faces extend naturally, perpendicular corners across faces and flat walls, warnings clear, drafted arc corners, replace to the near crossing, rail loft span and points, unlike loft loops, thin skins, old ruled and extend edits) holds; round 4 (folding caps and wrong-side plates refused, convex caps unchanged, D-cut cap point-free and thickening, lens rims extend full width, bent rails warn, G1 over curves warns, stored G2 edits as G1, unoffered choices shown; exact spline volumes, areas, centres and inertia; boxes that hold their shapes; untrim by its own edges, staying joined; loft walls along the square, named by it) holds; round 5 (creases and caps leaving their walls fold, nothing else; round-ended D-cut caps tangent and thickening; plates and rails at any size; G1 rim with a point refused for its walls; stored G2 over curves builds G0; untrim outer keeps a joined hole; quick spline and torus measures; shell on a copy, never unchanged; exact ellipse lengths, small trims and untrims; plate boxes hold their corners) holds; round 6 (G1 shortfalls told and matching their rims, in the document too; lean-in caps above their rims and inside their walls; concave smooth caps build; inputs kept byte for byte; lens bands full width; rails named and reasons alike at any size; one unoffered choice) holds; round 7 (trim and measure speeds held against calibrations, in turns) holds; round 8 (caps over split sides tangent and quiet, the seam's plate built, exact distances to caps, no false facing down, narrow corner turns told, one reason at any size, stitched names kept, caps past their walls' planes told) holds; round 10 (sections along steps and hole sides, uncapped bodies named; rail lofts keep their sections; overlapping sweeps, pipes, coils and tight guided bends refused; thicken and offset sized by picked faces; quick twisted rings and small G1 stitches) holds; round 11 (turned sections tangent to holes, quick alike rail lofts, near-touching helix turns refused, mitred corners, profiles away from a ring's start, narrow sheets, quick twisted rings) holds")
	else:
		for failure in failures:
			print("  - ", failure)
		print("FAIL holo_forge_surface")
	quit(0 if failures.is_empty() else 1)


# --- Helpers ---------------------------------------------------------------------------------

func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


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
	# As the commands do: New Body owns a body, New Component one in a component of its own.
	COMMAND.sync_body(doc, feature)
	return feature


## A Surface workspace feature; its Create tools make a new body unless options say otherwise.
func _surface(method: String, inputs: Dictionary, options: Dictionary) -> Resource:
	var o := options.duplicate(true)
	o["method"] = method
	if str(SPECS.get_spec("surface:" + method).get("op", "")) != "" and not o.has("operation"):
		o["operation"] = OPERATIONS.NEW_BODY
	return _add("surface", inputs, o)


func _box(position_mm: Vector3, l: float, h: float, w: float) -> Resource:
	return _add("box", {"length": "%s mm" % l, "height": "%s mm" % h, "width": "%s mm" % w}, {"position": position_mm * 0.001, "operation": OPERATIONS.NEW_BODY})


func _rebuild() -> Dictionary:
	result = REGEN.rebuild(doc, kernel)
	return result


## A sketch of lines (ends in mm; shared ends join) on an origin plane or a frame.
func _lines(plane: Variant, segments: Array) -> Dictionary:
	var frame: Dictionary = SKETCH_DATA.ORIGIN_PLANES[plane] if plane is String else plane
	var feature: Resource = doc.add_feature("sketch", "Sketch", {}, SKETCH_DATA.new_options(frame, plane if plane is String else "frame"))
	var s = SKETCH_DATA.new(feature, doc)
	var points := {}
	var ids := []
	for segment in segments:
		var ends := []
		for p in segment:
			if not points.has(p):
				points[p] = s.add_point(p * 0.001)
			ends.append(points[p])
		ids.append(s.add_line(ends[0], ends[1]))
	return {"feature": feature, "lines": ids, "data": s}


func _curve(sketch: Dictionary, k := 0) -> Dictionary:
	return {"kind": "sketch_curve", "sketch": sketch.feature.id, "entity": sketch.lines[k]}


func _curves(sketch: Dictionary) -> Array:
	var refs := []
	for k in sketch.lines.size():
		refs.append(_curve(sketch, k))
	return refs


func _body(feature: Resource) -> String:
	return str(feature.options.get("body_id", ""))


func _shape(body_id: String) -> RefCounted:
	return result.bodies[body_id].shape if result.get("bodies", {}).has(body_id) else null


func _area(body_id: String) -> float:
	var shape := _shape(body_id)
	return shape.area() / MM2 if shape != null else -1.0


func _close(value: float, expected: float, rel: float, label: String) -> void:
	_expect(absf(value - expected) <= absf(expected) * rel, "%s: should be %s (got %s; errors %s)" % [label, expected, value, result.get("errors", {})])


func _no_error(feature: Resource, label: String) -> void:
	_expect(not (result.get("errors", {}) as Dictionary).has(feature.id), "%s: %s" % [label, result.get("errors", {}).get(feature.id, "")])


func _is_surface(body_id: String, faces: int, label: String) -> void:
	var shape := _shape(body_id)
	_expect(shape != null and shape.is_surface() and shape.solid_count() == 0, "%s should be a surface body (errors %s)." % [label, result.get("errors", {})])
	if shape != null and faces > 0:
		_expect(shape.face_count() == faces, "%s should have %d face(s) (has %d)." % [label, faces, shape.face_count()])


## A reference to the body's face nearest point, made as a view pick makes it.
func _face_ref_at(body_id: String, point: Vector3) -> Dictionary:
	var shape := _shape(body_id)
	var best := -1
	var best_d := INF
	for f in shape.face_count():
		var hit: Dictionary = kernel.closest_points(shape.face_shape(f), kernel.make_vertex(point))
		if hit.has("distance") and float(hit.distance) < best_d:
			best_d = float(hit.distance)
			best = f
	return REFERENCES.from_pick({"kind": "face", "body": body_id, "index": best}, result)


## A reference to the body's edge whose middle is nearest point.
func _edge_ref_at(body_id: String, point: Vector3) -> Dictionary:
	var shape := _shape(body_id)
	var best := -1
	var best_d := INF
	for e in shape.edge_count():
		var d := (shape.edge_info(e).midpoint as Vector3).distance_to(point)
		if d < best_d:
			best_d = d
			best = e
	return REFERENCES.from_pick({"kind": "edge", "body": body_id, "index": best}, result)


## References to every edge of a body whose middle lies at height y (meters).
func _edges_at_height(body_id: String, y: float) -> Array:
	var shape := _shape(body_id)
	var refs := []
	for e in shape.edge_count():
		if absf((shape.edge_info(e).midpoint as Vector3).y - y) < 1e-7:
			refs.append(REFERENCES.from_pick({"kind": "edge", "body": body_id, "index": e}, result))
	return refs


func _all_edges(body_id: String) -> Array:
	var refs := []
	for e in _shape(body_id).edge_count():
		refs.append(REFERENCES.from_pick({"kind": "edge", "body": body_id, "index": e}, result))
	return refs


# --- Create ----------------------------------------------------------------------------------

func _check_create() -> void:
	_new_doc()
	# An open 20 mm line extruded 10 mm: one flat face of 200 mm2 (y = 0, x 0..20, z 0..10).
	var line := _lines("xy", [[Vector2(0, 0), Vector2(20, 0)]])
	var strip := _surface("extrude", {"distance": "10 mm"}, {"profiles": [_curve(line)]})
	# A closed 5 mm circle profile: only the tube's wall (2 pi r h), plain and tapered.
	var ring: Resource = doc.add_feature("sketch", "Sketch", {}, SKETCH_DATA.new_options(SKETCH_DATA.ORIGIN_PLANES.xz, "xz"))
	var rs = SKETCH_DATA.new(ring, doc)
	rs.add_circle(rs.add_point(Vector2(0.1, 0)), 0.005)
	var disc := {"kind": "profile", "sketch": ring.id, "point": Vector2(0.1, 0)}
	var tube := _surface("extrude", {"distance": "10 mm"}, {"profiles": [disc]})
	var cone := _surface("extrude", {"distance": "10 mm", "taper": ["5 deg", "angle"]}, {"profiles": [disc]})
	# A line 30 mm from Y turned fully about Y: a cylinder wall 2 pi r h.
	var post := _lines("xy", [[Vector2(30, 0), Vector2(30, 10)]])
	var spun := _surface("revolve", {}, {"profiles": [_curve(post)], "axis": [{"kind": "origin", "name": "y"}], "extent": "full"})
	# A 4 mm line across a 50 mm X path: a 200 mm2 ribbon.
	var cross := _lines("yz", [[Vector2(-2, 200), Vector2(2, 200)]])
	var path := _lines("xy", [[Vector2(0, 200), Vector2(50, 200)]])
	var ribbon := _surface("sweep", {}, {"profiles": [_curve(cross)], "path": [_curve(path)]})
	# Between two skew lines: one ruled sheet, four edges, no caps.
	var low := _lines("xy", [[Vector2(100, 0), Vector2(120, 0)]])
	var high := _lines({"origin": Vector3(0, 0, 0.01), "x": Vector3.RIGHT, "y": Vector3.UP}, [[Vector2(100, 5), Vector2(120, 10)]])
	var sheet := _surface("loft", {}, {"sections": [_curve(low), _curve(high)]})
	var coil := _surface("coil", {"diameter": "20 mm", "turns": ["3", "number"], "height": "15 mm", "section_size": "2 mm"},
		{"coil_type": "revolution_height", "section": "circle", "position": Vector3(0.3, 0, 0)})
	# New Component puts the surface in a component of its own; a pattern copies surfaces.
	var in_component := _surface("extrude", {"distance": "5 mm"}, {"profiles": [_curve(line)], "operation": OPERATIONS.NEW_COMPONENT})
	var pattern := _add("rect_pattern", {"quantity1": ["2", "number"], "distance1": "40 mm", "quantity2": ["1", "number"], "distance2": "1 mm"},
		{"object_type": "bodies", "objects": [{"kind": "body", "body": _body(strip)}], "direction1": [{"kind": "origin", "name": "z"}]})
	_rebuild()
	for feature in [strip, tube, cone, spun, ribbon, sheet, coil, in_component, pattern]:
		_no_error(feature, "Create %s" % feature.options.get("method", feature.type))
	_is_surface(_body(strip), 1, "A surface extrude of a line")
	_close(_area(_body(strip)), 200.0, 1e-6, "Surface Extrude of a 20 mm line by 10 mm (area)")
	_is_surface(_body(tube), 1, "A surface extrude of a circle (wall, no caps)")
	_close(_area(_body(tube)), TAU * 5.0 * 10.0, 1e-6, "Surface Extrude of a 5 mm circle (area)")
	_is_surface(_body(cone), 1, "A tapered surface extrude of a circle")
	_expect(_area(_body(cone)) < _area(_body(tube)), "A tapered (inward) wall should be smaller than the straight one.")
	_is_surface(_body(spun), 1, "A surface revolve of a line")
	_close(_area(_body(spun)), TAU * 30.0 * 10.0, 1e-6, "Surface Revolve of a 10 mm line at 30 mm (area)")
	_is_surface(_body(ribbon), 1, "A surface sweep of a line")
	_close(_area(_body(ribbon)), 200.0, 1e-6, "Surface Sweep of a 4 mm line along 50 mm (area)")
	_is_surface(_body(sheet), 1, "A surface loft between two lines")
	if _shape(_body(sheet)) != null:
		_expect(_shape(_body(sheet)).edge_count() == 4 and _shape(_body(sheet)).volume() == 0.0, "The lofted sheet should have 4 edges and no volume.")
	_is_surface(_body(coil), 0, "A surface coil")
	_expect(doc.body_component(_body(in_component)) != "", "A New Component surface should sit in its own component.")
	var copies := 0
	for body_id in result.bodies:
		if str(body_id).begins_with(_body(strip) + "."):
			copies += 1
			_is_surface(body_id, 1, "A patterned copy of a surface")
			_close(_area(body_id), 200.0, 1e-6, "A patterned surface copy (area)")
	_expect(copies == 1, "The pattern should add one surface copy (got %d)." % copies)


# --- Patch -----------------------------------------------------------------------------------

func _check_patch() -> void:
	_new_doc()
	var box := _box(Vector3.ZERO, 10, 10, 10)
	var square := _lines("xz", [[Vector2(20, 0), Vector2(30, 0)], [Vector2(30, 0), Vector2(30, 10)], [Vector2(30, 10), Vector2(20, 10)], [Vector2(20, 10), Vector2(20, 0)]])
	var low := _lines("xy", [[Vector2(100, 0), Vector2(120, 0)]])
	var high := _lines({"origin": Vector3(0, 0, 0.01), "x": Vector3.RIGHT, "y": Vector3.UP}, [[Vector2(100, 5), Vector2(120, 10)]])
	var sheet := _surface("loft", {}, {"sections": [_curve(low), _curve(high)]})
	_rebuild()
	var top_edges := _edges_at_height(_body(box), 0.01)
	_expect(top_edges.size() == 4, "The box should have 4 top edges (got %d)." % top_edges.size())
	var flat := _surface("patch", {}, {"boundary": top_edges, "continuity": "g0"})
	var domed := _surface("patch", {}, {"boundary": top_edges, "continuity": "g1"})
	var from_curves := _surface("patch", {}, {"boundary": _curves(square)})
	var twisted := _surface("patch", {}, {"boundary": _all_edges(_body(sheet))})
	var open_loop := _surface("patch", {}, {"boundary": _curves(square).slice(0, 3)})
	_rebuild()
	for feature in [flat, domed, from_curves, twisted]:
		_no_error(feature, "Patch")
	_is_surface(_body(flat), 1, "A G0 patch of a box's top edges")
	_close(_area(_body(flat)), 100.0, 1e-6, "A flat patch over a 10 mm square (area)")
	if _shape(_body(flat)) != null:
		_expect(str(_shape(_body(flat)).face_info(0).type) == "plane", "A flat G0 patch should be an exact plane.")
	# G1 carries on from the walls around the top (not the top itself): up off the vertical walls,
	# into a dome over the top (round 1 refused this: its plate couldn't rise off the walls).
	_is_surface(_body(domed), 1, "A G1 patch on a box's vertical walls")
	if _shape(_body(domed)) != null:
		_expect((_shape(_body(domed)).bbox() as AABB).end.y > 0.0105, "A G1 patch on vertical walls should dome above them (%s)." % _shape(_body(domed)).bbox())
	doc.remove_feature(domed.id)
	_is_surface(_body(from_curves), 1, "A patch of 4 sketch lines")
	_close(_area(_body(from_curves)), 100.0, 1e-6, "A patch of a 10 mm sketch square (area)")
	_is_surface(_body(twisted), 1, "A patch of a twisted 4-edge loop")
	if _shape(_body(twisted)) != null:
		_expect(_shape(_body(twisted)).edge_count() == 4, "The twisted patch should keep its 4 boundary edges (has %d)." % _shape(_body(twisted)).edge_count())
		_close(_area(_body(twisted)), _area(_body(sheet)), 1e-4, "A twisted patch spans the lofted sheet")
	_expect(str(result.errors.get(open_loop.id, "")).contains("closed loop"), "An open boundary should be refused (%s)." % result.errors.get(open_loop.id, ""))
	# Unstitch the box's top, then a stitched patch on the open edges closes it into a solid.
	doc.remove_feature(open_loop.id)
	var lid := _surface("unstitch", {}, {"objects": [_face_ref_at(_body(box), Vector3(0, 0.01, 0))]})
	_rebuild()
	_no_error(lid, "Unstitch the box's top")
	_is_surface(_body(box), 5, "The box without its top")
	var closing := _surface("patch", {}, {"boundary": _edges_at_height(_body(box), 0.01), "stitch": true})
	_rebuild()
	_no_error(closing, "Stitched patch")
	var closed := _shape(_body(box))
	_expect(closed != null and closed.solid_count() == 1, "The stitched patch should close the box into a solid.")
	if closed != null:
		_close(closed.volume() / MM3, 1000.0, 1e-6, "The closed box (volume)")


# --- Stitch ----------------------------------------------------------------------------------

func _check_stitch() -> void:
	_new_doc()
	var box := _box(Vector3(100, 0, 0), 10, 20, 30)
	var apart := _surface("unstitch", {}, {"objects": [{"kind": "body", "body": _body(box)}]})
	_rebuild()
	_no_error(apart, "Unstitch a box")
	var ids: Array = result.bodies.keys()
	_expect(ids.size() == 6, "Unstitching a box should give 6 bodies (got %d)." % ids.size())
	var total := 0.0
	for body_id in ids:
		_is_surface(body_id, 1, "An unstitched face")
		total += _area(body_id)
	_close(total, 2.0 * (10 * 20 + 20 * 30 + 10 * 30), 1e-6, "The unstitched faces (total area)")
	var picks := []
	for body_id in ids:
		picks.append({"kind": "body", "body": body_id})
	var open_stitch := _surface("stitch", {"tolerance": "0.001 mm"}, {"bodies": picks, "solid": false})
	_rebuild()
	_no_error(open_stitch, "Stitch without making a solid")
	_expect(result.bodies.size() == 1 and _shape(ids[0]) != null and _shape(ids[0]).is_surface(), "Without Make Solid the closed shell stays a surface body.")
	open_stitch.options["solid"] = true
	_rebuild()
	_no_error(open_stitch, "Stitch")
	var solid := _shape(ids[0])
	_expect(result.bodies.size() == 1 and solid != null and solid.solid_count() == 1, "Stitching the 6 faces should give one solid body.")
	if solid != null:
		_close(solid.volume() / MM3, 6000.0, 1e-6, "The stitched box (volume)")
		_expect(solid.face_count() == 6, "The stitched box keeps 6 faces.")
	# Strips 3 mm apart don't meet within 0.01 mm: Stitch is refused and both bodies stay.
	_new_doc()
	var near := _lines("xy", [[Vector2(0, 0), Vector2(10, 0)]])
	var far := _lines("xy", [[Vector2(13, 0), Vector2(20, 0)]])
	var left := _surface("extrude", {"distance": "10 mm"}, {"profiles": [_curve(near)]})
	var right := _surface("extrude", {"distance": "10 mm"}, {"profiles": [_curve(far)]})
	var gap := _surface("stitch", {"tolerance": "0.01 mm"}, {"bodies": [{"kind": "body", "body": _body(left)}, {"kind": "body", "body": _body(right)}]})
	_rebuild()
	_expect(str(result.errors.get(gap.id, "")).contains("Nothing was stitched") and result.bodies.has(_body(left)) and result.bodies.has(_body(right)),
		"Stitching strips that don't meet should be refused, keeping both bodies (%s, bodies %s)." % [result.errors.get(gap.id, ""), result.bodies.keys()])


# --- Thicken ---------------------------------------------------------------------------------

func _check_thicken() -> void:
	_new_doc()
	var line := _lines("xy", [[Vector2(0, 0), Vector2(20, 0)]])
	var strip := _surface("extrude", {"distance": "10 mm"}, {"profiles": [_curve(line)]})
	var bend := _lines("xy", [[Vector2(100, 0), Vector2(120, 0)], [Vector2(120, 0), Vector2(120, 10)]])
	var ell := _surface("extrude", {"distance": "10 mm"}, {"profiles": _curves(bend)})
	_rebuild()
	_is_surface(_body(ell), 2, "An L-shaped sheet")
	_close(_area(_body(ell)), 300.0, 1e-6, "The L sheet (area)")
	var slab := _add("thicken", {"thickness": "2 mm"}, {"faces": [{"kind": "body", "body": _body(strip)}], "operation": OPERATIONS.NEW_BODY})
	var middle := _add("thicken", {"thickness": "2 mm"}, {"faces": [_face_ref_at(_body(strip), Vector3(0.01, 0, 0.005))], "direction": "symmetric", "operation": OPERATIONS.NEW_BODY})
	var bent := _add("thicken", {"thickness": "1 mm"}, {"faces": [{"kind": "body", "body": _body(ell)}], "operation": OPERATIONS.NEW_BODY})
	_rebuild()
	for feature in [slab, middle, bent]:
		_no_error(feature, "Thicken")
	_close(_shape(_body(slab)).volume() / MM3 if _shape(_body(slab)) != null else -1.0, 400.0, 1e-6, "Thicken a 200 mm2 surface by 2 mm")
	_close(_shape(_body(middle)).volume() / MM3 if _shape(_body(middle)) != null else -1.0, 400.0, 1e-6, "Thicken it 2 mm symmetric")
	var v: float = _shape(_body(bent)).volume() / MM3 if _shape(_body(bent)) != null else -1.0
	# 300 mm2 x 1 mm, mitred: the bend's corner square goes (inside) or comes (outside).
	_expect(absf(v - 290.0) < 1e-3 or absf(v - 310.0) < 1e-3, "Thicken an L sheet 1 mm should mitre its seam: 290 or 310 mm3 (got %s)." % v)


# --- Trim and Untrim -------------------------------------------------------------------------

func _check_trim() -> void:
	_new_doc()
	var line := _lines("xy", [[Vector2(0, 0), Vector2(20, 0)]])
	var strip := _surface("extrude", {"distance": "10 mm"}, {"profiles": [_curve(line)]})
	var post := _add("cylinder", {"diameter": "4 mm", "height": "20 mm"}, {"position": Vector3(0.01, -0.01, 0.005), "operation": OPERATIONS.NEW_BODY})
	var trim := _surface("trim", {}, {"tool": [{"kind": "body", "body": _body(post)}], "remove": []})
	_rebuild()
	# Nothing picked: the strip is cut so its pieces can be clicked, and Trim asks for them.
	_expect(str(result.errors.get(trim.id, "")).contains("Click the pieces"), "Trim without pieces should ask for them (%s)." % result.errors.get(trim.id, ""))
	_expect(_shape(_body(strip)) != null and kernel.pieces(_shape(_body(strip))).size() == 2, "Before a pick the strip should show 2 pieces (the disc and the rest).")
	trim.options["remove"] = [_face_ref_at(_body(strip), Vector3(0.01, 0, 0.005))]
	_rebuild()
	_no_error(trim, "Trim a hole")
	_close(_area(_body(strip)), 200.0 - PI * 4.0, 1e-6, "The strip with a 4 mm hole trimmed (area)")
	_is_surface(_body(strip), 1, "The trimmed strip")
	var holed_face := _face_ref_at(_body(strip), Vector3(0.002, 0, 0.002))
	var hole_edge := _edge_ref_at(_body(strip), Vector3(0.012, 0, 0.005))
	for spec in [["inner", {"faces": [holed_face]}], ["all", {"faces": [holed_face]}], ["loops", {"loops": [hole_edge]}]]:
		var options: Dictionary = spec[1]
		options["untrim_type"] = spec[0]
		var untrim := _surface("untrim", {}, options)
		_rebuild()
		_no_error(untrim, "Untrim %s" % spec[0])
		_close(_area(_body(strip)), 200.0, 1e-6, "Untrim (%s) gives the strip's area back" % spec[0])
		doc.remove_feature(untrim.id)
	# A lofted (B-spline) sheet with one end cut off at x = 112 mm: Untrim All gives it back.
	var low := _lines("xy", [[Vector2(100, 0), Vector2(120, 0)]])
	var high := _lines({"origin": Vector3(0, 0, 0.01), "x": Vector3.RIGHT, "y": Vector3.UP}, [[Vector2(100, 5), Vector2(120, 10)]])
	var sheet := _surface("loft", {}, {"sections": [_curve(low), _curve(high)]})
	var cut := _add("plane", {"distance": "112 mm"}, {"method": "offset", "plane": [{"kind": "origin", "name": "yz"}]})
	_rebuild()
	var whole := _area(_body(sheet))
	var end_trim := _surface("trim", {}, {"tool": [{"kind": "construct", "feature": cut.id}], "remove": []})
	_rebuild()
	end_trim.options["remove"] = [_face_ref_at(_body(sheet), Vector3(0.118, 0.008, 0.008))]
	_rebuild()
	_no_error(end_trim, "Trim the sheet's end")
	_expect(_area(_body(sheet)) < whole * 0.8, "Trimming the sheet's end should take area away (%s of %s)." % [_area(_body(sheet)), whole])
	var restore := _surface("untrim", {}, {"untrim_type": "all", "faces": [_face_ref_at(_body(sheet), Vector3(0.105, 0.003, 0.005))]})
	_rebuild()
	_no_error(restore, "Untrim the sheet")
	_close(_area(_body(sheet)), whole, 1e-6, "Untrim All gives the lofted sheet its area back")
	# A tool around the surface that never crosses it: nothing to click, and Trim says so.
	_new_doc()
	var inside := _surface("extrude", {"distance": "10 mm"}, {"profiles": [_curve(_lines("xy", [[Vector2(0, 0), Vector2(20, 0)]]))]})
	var drum := _add("cylinder", {"diameter": "60 mm", "height": "40 mm"}, {"position": Vector3(0.01, -0.02, 0.005), "operation": OPERATIONS.NEW_BODY})
	var miss := _surface("trim", {}, {"tool": [{"kind": "body", "body": _body(drum)}], "remove": []})
	_rebuild()
	_expect(str(result.errors.get(miss.id, "")).contains("doesn't cut"), "Trim by a tool that misses the surface should say so (%s)." % result.errors.get(miss.id, ""))
	_close(_area(_body(inside)), 200.0, 1e-6, "A trim that cuts nothing leaves the strip whole")


# --- Modify ----------------------------------------------------------------------------------

func _check_modify() -> void:
	_new_doc()
	var box := _box(Vector3(200, 0, 0), 10, 10, 10)
	var line := _lines("xy", [[Vector2(0, 0), Vector2(20, 0)]])
	var strip := _surface("extrude", {"distance": "10 mm"}, {"profiles": [_curve(line)]})
	var arc_sketch: Resource = doc.add_feature("sketch", "Sketch", {}, SKETCH_DATA.new_options(SKETCH_DATA.ORIGIN_PLANES.xy, "xy"))
	var arcs = SKETCH_DATA.new(arc_sketch, doc)
	var arc: int = arcs.add_arc(arcs.add_point(Vector2(0, 0.1)), arcs.add_point(Vector2(0.01, 0.1)), arcs.add_point(Vector2(0, 0.11)))
	var curved := _surface("extrude", {"distance": "10 mm"}, {"profiles": [{"kind": "sketch_curve", "sketch": arc_sketch.id, "entity": arc}]})
	var halves := _lines("xy", [[Vector2(0, 50), Vector2(10, 50)], [Vector2(10, 50), Vector2(20, 50)]])
	var pair := _surface("extrude", {"distance": "10 mm"}, {"profiles": _curves(halves)})
	var bend := _lines("xy", [[Vector2(100, 0), Vector2(120, 0)], [Vector2(120, 0), Vector2(120, 10)]])
	var ell := _surface("extrude", {"distance": "10 mm"}, {"profiles": _curves(bend)})
	var mid_plane := _add("plane", {"distance": "5 mm"}, {"method": "offset", "plane": [{"kind": "origin", "name": "yz"}]})
	_rebuild()
	_is_surface(_body(pair), 2, "Two collinear walls")
	_close(_area(_body(curved)), 10.0 * PI / 2.0 * 10.0, 1e-6, "A quarter-cylinder surface (area)")

	var ruled := _surface("ruled", {"distance": "5 mm"}, {"edges": [_edge_ref_at(_body(box), Vector3(0.2, 0.01, 0.005))], "ruled_type": "normal"})
	var ruled_tangent := _surface("ruled", {"distance": "5 mm"}, {"edges": [_edge_ref_at(_body(box), Vector3(0.2, 0.01, 0.005))], "ruled_type": "tangent"})
	var offset := _surface("offset", {"distance": "5 mm"}, {"faces": [_face_ref_at(_body(box), Vector3(0.2, 0.01, 0))]})
	var extend := _surface("extend", {"distance": "5 mm"}, {"edges": [_edge_ref_at(_body(strip), Vector3(0.02, 0, 0.005))], "extend_type": "tangent"})
	var natural := _surface("extend", {"distance": "5 mm"}, {"edges": [_edge_ref_at(_body(curved), Vector3(0, 0.11, 0.005))], "extend_type": "natural"})
	var merge := _surface("merge", {}, {"edges": [_edge_ref_at(_body(pair), Vector3(0.01, 0.05, 0.005))]})
	var fillet := _add("fillet", {"radius": "2 mm"}, {"edges": [_edge_ref_at(_body(ell), Vector3(0.12, 0, 0.005))], "radius_type": "constant"})
	_rebuild()
	for feature in [ruled, ruled_tangent, offset, extend, natural, merge, fillet]:
		_no_error(feature, "Modify %s" % feature.options.get("method", feature.type))
	_is_surface(_body(ruled), 1, "A ruled surface")
	_close(_area(_body(ruled)), 50.0, 1e-6, "Ruled 5 mm from a 10 mm edge (area)")
	if _shape(_body(ruled)) != null:
		_expect((_shape(_body(ruled)).bbox() as AABB).end.y > 0.0149, "A normal ruled surface off the top edge should rise 5 mm.")
	if _shape(_body(ruled_tangent)) != null:
		var b: AABB = _shape(_body(ruled_tangent)).bbox()
		_expect(absf(b.size.y) < 1e-7 and b.end.z > 0.0099 and b.position.z < 0.0051, "A tangent ruled surface should lie in the top's plane, off the box (%s)." % b)
	_is_surface(_body(offset), 1, "An offset surface")
	_close(_area(_body(offset)), 100.0, 1e-6, "Offset of the box's top (area)")
	if _shape(_body(offset)) != null:
		_expect(absf((_shape(_body(offset)).bbox() as AABB).position.y - 0.015) < 1e-7, "The offset top should sit 5 mm above the box.")
	_is_surface(_body(strip), 1, "The extended strip (merged into one flat face)")
	_close(_area(_body(strip)), 250.0, 1e-6, "Extend (tangent) a 10 mm edge by 5 mm (area)")
	_is_surface(_body(curved), 1, "The naturally extended cylinder patch")
	_close(_area(_body(curved)), 10.0 * PI / 2.0 * 10.0 + 50.0, 1e-6, "Extend (natural) a quarter cylinder by 5 mm (area)")
	if _shape(_body(curved)) != null:
		_expect(str(_shape(_body(curved)).face_info(0).type) == "cylinder", "A natural extend keeps the cylinder a cylinder.")
	_is_surface(_body(pair), 1, "The merged walls")
	_close(_area(_body(pair)), 200.0, 1e-6, "Merged walls (area)")
	_is_surface(_body(ell), 3, "The filleted L sheet")

	# Reverse Normal: the strip's face turns over.
	var before: Vector3 = _shape(_body(strip)).face_normal_at(0, Vector3(0.01, 0, 0.005))
	var reverse := _surface("reverse_normal", {}, {"objects": [{"kind": "body", "body": _body(strip)}]})
	_rebuild()
	_no_error(reverse, "Reverse Normal")
	var after: Vector3 = _shape(_body(strip)).face_normal_at(0, Vector3(0.01, 0, 0.005))
	_expect(before.dot(after) < -0.99, "Reverse Normal should turn the face over (%s -> %s)." % [before, after])
	var face_reverse := _surface("reverse_normal", {}, {"objects": [_face_ref_at(_body(strip), Vector3(0.01, 0, 0.005))]})
	_rebuild()
	_expect(before.dot(_shape(_body(strip)).face_normal_at(0, Vector3(0.01, 0, 0.005))) > 0.99, "Reversing the picked face turns it back.")
	doc.remove_feature(face_reverse.id)

	# Split Body cuts the 25 mm strip at x = 5 mm into two surface bodies (50 + 200 mm2).
	var split := _add("split_body", {}, {"body": [{"kind": "body", "body": _body(strip)}], "tool": [{"kind": "construct", "feature": mid_plane.id}]})
	# Offset Face (Press Pull on a face) moves the ruled surface's face along its normal.
	var push := _add("offset_face", {"distance": "3 mm"}, {"faces": [_face_ref_at(_body(ruled), Vector3(0.2, 0.0125, 0.005))]})
	_rebuild()
	_no_error(split, "Split a surface body")
	_no_error(push, "Offset Face on a surface")
	var parts := []
	for body_id in result.bodies:
		if body_id == _body(strip) or str(body_id).begins_with(_body(strip) + "."):
			parts.append(_area(body_id))
	parts.sort()
	_expect(parts.size() == 2 and absf(parts[0] - 50.0) < 1e-4 and absf(parts[1] - 200.0) < 1e-4, "Split Body should cut the strip into 50 + 200 mm2 surfaces (got %s)." % [parts])
	_close(_area(_body(ruled)), 50.0, 1e-6, "The pushed ruled face keeps its area")


# --- Refusals --------------------------------------------------------------------------------

func _check_refusals() -> void:
	_new_doc()
	var box := _box(Vector3.ZERO, 10, 10, 10)
	_rebuild()
	var top := _face_ref_at(_body(box), Vector3(0, 0.01, 0))
	var edge := _edge_ref_at(_body(box), Vector3(0, 0.01, 0.005))
	var untrim := _surface("untrim", {}, {"untrim_type": "all", "faces": [top]})
	_rebuild()
	_expect(str(result.errors.get(untrim.id, "")).contains("surface bodies"), "Untrim should refuse a solid (%s)." % result.errors.get(untrim.id, ""))
	doc.remove_feature(untrim.id)
	var extend := _surface("extend", {"distance": "5 mm"}, {"edges": [edge]})
	_rebuild()
	_expect(str(result.errors.get(extend.id, "")).contains("surface bodies"), "Extend should refuse a solid (%s)." % result.errors.get(extend.id, ""))
	doc.remove_feature(extend.id)
	var reverse := _surface("reverse_normal", {}, {"objects": [{"kind": "body", "body": _body(box)}]})
	_rebuild()
	_expect(str(result.errors.get(reverse.id, "")).contains("surface bodies"), "Reverse Normal should refuse a solid (%s)." % result.errors.get(reverse.id, ""))
	doc.remove_feature(reverse.id)
	var plane := _add("plane", {"distance": "0 mm"}, {"method": "offset", "plane": [{"kind": "origin", "name": "yz"}]})
	var trim := _surface("trim", {}, {"tool": [{"kind": "construct", "feature": plane.id}], "remove": [top]})
	_rebuild()
	_expect(str(result.errors.get(trim.id, "")).contains("surface bodies"), "Trim should refuse a solid (%s)." % result.errors.get(trim.id, ""))
	_expect(_shape(_body(box)) != null and _shape(_body(box)).solid_count() == 1, "The refused tools should leave the box solid.")


# --- Catalog ---------------------------------------------------------------------------------

func _check_catalog() -> void:
	var off := []
	var no_spec := []
	for group in CATALOG.groups("Surface"):
		for tool in CATALOG.tools_in("Surface", group):
			if int(tool.phase) > 5:
				continue
			if not CATALOG.is_enabled(tool):
				off.append(tool.name)
			if tool.command == CATALOG.FEATURE and not str(tool.type).begins_with("press_pull") and SPECS.get_spec(tool.type).is_empty():
				no_spec.append(tool.name)
	_expect(off.is_empty(), "Every Surface workspace tool should be enabled (%s)." % [off])
	_expect(no_spec.is_empty(), "Every Surface feature tool should have a spec (%s)." % [no_spec])
	_expect(CATALOG.for_shortcut("Surface", "E").get("type", "") == "surface:extrude", "E in the Surface workspace should run the surface Extrude.")
	_expect(CATALOG.for_shortcut("Solid", "E").get("type", "") == "extrude", "E in the Solid workspace stays the solid Extrude.")
	for method in SURFACE.METHODS:
		var key: String = "surface:" + method
		var spec := SPECS.get_spec(key)
		_expect(not spec.is_empty() and spec.type == "surface" and spec.method == method, "%s should have a spec of type surface." % key)
		var tool_found := false
		for tool in CATALOG.all_tools():
			tool_found = tool_found or tool.type == key
		_expect(tool_found, "%s should have a tool, so the timeline can edit it." % key)
	var ops: Array = SPECS.get_spec("surface:extrude").get("ops", [])
	_expect(ops == [OPERATIONS.NEW_BODY, OPERATIONS.NEW_COMPONENT], "Surface Create tools should offer New Body and New Component only.")


# --- Bake ------------------------------------------------------------------------------------

func _check_bake() -> void:
	_new_doc()
	var line := _lines("xy", [[Vector2(0, 0), Vector2(20, 0)]])
	var strip := _surface("extrude", {"distance": "10 mm"}, {"profiles": [_curve(line)]})
	var box := _box(Vector3(100, 0, 0), 10, 10, 10)
	_rebuild()
	for spec in [[_body(strip), true], [_body(box), false]]:
		var shape := _shape(spec[0])
		var built: Dictionary = APPEARANCE.build_mesh(doc, spec[0], shape, TESSELLATE.tessellate(shape), CAD_PART.default_material(), CAD_PART.surface_material())
		var material := (built.mesh as ArrayMesh).surface_get_material(0) as BaseMaterial3D
		var two_sided := material != null and material.cull_mode == BaseMaterial3D.CULL_DISABLED
		_expect(two_sided == spec[1], "A %s should bake %s." % ["surface" if spec[1] else "solid", "double-sided" if spec[1] else "single-sided"])
	var plain := StandardMaterial3D.new()
	var copy := APPEARANCE.double_sided(plain) as BaseMaterial3D
	_expect(copy != plain and copy.cull_mode == BaseMaterial3D.CULL_DISABLED and plain.cull_mode == BaseMaterial3D.CULL_BACK, "double_sided should copy a material, leaving the original as it was.")


# --- Kernel: shapes straight from the kernel (sketch curves in mm, on the XY plane) ----------

func _k_line(a: Vector2, b: Vector2) -> Dictionary:
	return {"type": "line", "a": a * MM, "b": b * MM}


func _k_arc(c: Vector2, r: float, a0: float, a1: float) -> Dictionary:
	return {"type": "arc", "c": c * MM, "r": r * MM, "a0": a0, "a1": a1}


func _k_circle(c: Vector2, r: float) -> Dictionary:
	return {"type": "circle", "c": c * MM, "r": r * MM}


func _k_square(half: float) -> Array:
	return [_k_line(Vector2(-half, -half), Vector2(half, -half)), _k_line(Vector2(half, -half), Vector2(half, half)),
		_k_line(Vector2(half, half), Vector2(-half, half)), _k_line(Vector2(-half, half), Vector2(-half, -half))]


## The sketch region of the curves with this area (mm2).
func _k_region(curves: Array, area_mm2: float) -> RefCounted:
	for region in kernel.sketch_regions(curves, Transform3D.IDENTITY, 0.0):
		if absf(float(region.area) / MM2 - area_mm2) < maxf(area_mm2 * 2e-3, 1e-3):
			return region.face
	return null


## Curves extruded along +Z into a surface height_mm tall.
func _k_sheet(curves: Array, height_mm: float) -> RefCounted:
	return kernel.extrude(kernel.sketch_edges(curves, Transform3D.IDENTITY), {"direction": Vector3(0, 0, 1), "distance": height_mm * MM, "surface": true})


## Curves turned a full turn about Y into a surface.
func _k_spun(curves: Array) -> RefCounted:
	return kernel.revolve(kernel.sketch_edges(curves, Transform3D.IDENTITY), {"axis_origin": Vector3.ZERO, "axis": Vector3(0, 1, 0), "angle": TAU, "surface": true})


## The edges of shape that pass test (on edge_info).
func _k_edges(shape: RefCounted, test: Callable) -> PackedInt32Array:
	var ids := PackedInt32Array()
	for e in shape.edge_count():
		var info: Dictionary = shape.edge_info(e)
		if str(info.get("type", "")) != "degenerate" and test.call(info):
			ids.append(e)
	return ids


## How many edges bound one face (x) and how many join two (y).
func _k_open_shared(shape: RefCounted) -> Vector2i:
	var counts := Vector2i()
	for e in shape.edge_count():
		var info: Dictionary = shape.edge_info(e)
		if str(info.get("type", "")) == "degenerate":
			continue
		counts += Vector2i(1, 0) if (info.get("faces", PackedInt32Array()) as PackedInt32Array).size() == 1 else Vector2i(0, 1)
	return counts


func _k_mesh_volume(shape: RefCounted, deflection_mm: float) -> float:
	var mesh: Dictionary = shape.tessellate(deflection_mm * MM, 0.05)
	var points: PackedVector3Array = mesh.positions
	var indices: PackedInt32Array = mesh.indices
	var total := 0.0
	for t in range(0, indices.size(), 3):
		total += points[indices[t]].dot(points[indices[t + 1]].cross(points[indices[t + 2]])) / 6.0
	return absf(total) / MM3


func _k_mesh_area(shape: RefCounted, deflection_mm: float) -> float:
	var mesh: Dictionary = shape.tessellate(deflection_mm * MM, 0.05)
	var points: PackedVector3Array = mesh.positions
	var indices: PackedInt32Array = mesh.indices
	var total := 0.0
	for t in range(0, indices.size(), 3):
		total += 0.5 * (points[indices[t + 1]] - points[indices[t]]).cross(points[indices[t + 2]] - points[indices[t]]).length()
	return total / MM2


## Expects the kernel to have refused a shape, giving a reason with these words.
func _k_refused(shape: RefCounted, words: String, label: String) -> void:
	_expect(shape == null and kernel.get_last_error().contains(words), "%s should be refused (\"%s\"; got %s, \"%s\")." % [label, words, "null" if shape == null else shape.shape_type(), kernel.get_last_error()])


func _frustum_area(r1: float, r2: float, h: float) -> float:
	return PI * (r1 + r2) * sqrt(h * h + (r1 - r2) * (r1 - r2))


func _frustum_volume(r1: float, r2: float, h: float) -> float:
	return PI * h / 3.0 * (r1 * r1 + r1 * r2 + r2 * r2)


# Tapered extrudes: every loop's far end runs like the loop, so walls rise straight up.
func _check_kernel_taper() -> void:
	var taper := deg_to_rad(10.0)
	var inset := 10.0 * tan(taper)
	var annulus := _k_region([_k_circle(Vector2.ZERO, 10), _k_circle(Vector2.ZERO, 5)], PI * 75.0)
	var walls = kernel.extrude(annulus, {"direction": Vector3(0, 0, 1), "distance": 10 * MM, "taper": taper, "surface": true})
	var cones := 0
	for f in walls.face_count():
		cones += 1 if str(walls.face_info(f).type) == "cone" else 0
	_expect(cones == 2, "A tapered annulus's two walls should both be cones (the hole's isn't twisted through the axis).")
	_close(walls.area() / MM2, _frustum_area(10.0, 10.0 - inset, 10.0) + _frustum_area(5.0, 5.0 + inset, 10.0), 1e-6, "The tapered annulus's walls (area)")
	var ring = kernel.extrude(annulus, {"direction": Vector3(0, 0, 1), "distance": 10 * MM, "taper": taper})
	_close(ring.volume() / MM3 if ring != null else -1.0, _frustum_volume(10.0, 10.0 - inset, 10.0) - _frustum_volume(5.0, 5.0 + inset, 10.0), 1e-6, "A tapered annulus (volume)")
	# A one-edge loop other than a circle: a 10 x 5 mm ellipse (perimeter 48.44224) by 5 deg.
	var ellipse := _k_region([{"type": "ellipse", "c": Vector2.ZERO, "major": Vector2(10 * MM, 0), "minor": 5 * MM}], PI * 50.0)
	var lean := tan(deg_to_rad(5.0))
	var perimeter := 48.44224
	var wall = kernel.extrude(ellipse, {"direction": Vector3(0, 0, 1), "distance": 10 * MM, "taper": deg_to_rad(5.0), "surface": true})
	_expect(wall != null and wall.face_count() == 1, "A tapered ellipse's wall should be one face (%s)." % kernel.get_last_error())
	if wall != null:
		_close(wall.area() / MM2, (perimeter * 10.0 - PI * lean * 100.0) / cos(deg_to_rad(5.0)), 1e-4, "A tapered ellipse's wall (area)")
	var plug = kernel.extrude(ellipse, {"direction": Vector3(0, 0, 1), "distance": 10 * MM, "taper": deg_to_rad(5.0)})
	_expect(plug != null and plug.solid_count() == 1 and plug.face_count() == 3, "A tapered ellipse should be a closed solid of 3 faces (%s)." % kernel.get_last_error())
	if plug != null:
		# Its top is the ellipse moved in by 10 tan 5 deg everywhere (Steiner: A - P s + pi s^2).
		var top_area := 0.0
		for f in plug.face_count():
			if (plug.face_info(f).point as Vector3).z > 9.99 * MM:
				top_area = float(plug.face_info(f).area) / MM2
		_close(top_area, PI * 50.0 - perimeter * 10.0 * lean + PI * 100.0 * lean * lean, 1e-4, "A tapered ellipse's top (area)")
		# (Its mesh agrees; volume() itself is checked against the exact draft in _check_round4_volumes.)
		_close(_k_mesh_volume(plug, 0.002), PI * 50.0 * 10.0 - perimeter * lean * 50.0 + PI * lean * lean * 1000.0 / 3.0, 2e-3, "A tapered ellipse (mesh volume)")
	# A taper keeps the walls' names: each is named by the profile edge it rises from.
	var square := _k_region(_k_square(5.0), 100.0)
	var names := []
	for degrees in [0.0, 2.0]:
		var sides = kernel.extrude(square, {"direction": Vector3(0, 0, 1), "distance": 10 * MM, "taper": deg_to_rad(degrees), "surface": true, "tag": "e1"})
		var list := Array(sides.get_face_names())
		list.sort()
		names.append(list)
	_expect(names[0] == names[1] and not str(names[1]).contains("e1:f"), "A tapered surface extrude should name its walls as an untapered one does (%s vs %s)." % names)


# Patch: G1/G2 carry on from the faces around the loop and are checked; G2 no longer throws.
func _check_kernel_patch() -> void:
	# A solid frustum with 45 deg walls: G1 over its top is tangent to every wall alike.
	var base := _k_region(_k_square(8.0), 256.0)
	var frustum = kernel.extrude(base, {"direction": Vector3(0, 0, 1), "distance": 5 * MM, "taper": deg_to_rad(45.0)})
	var top := _k_edges(frustum, func(info: Dictionary) -> bool: return absf((info.midpoint as Vector3).z - 5 * MM) < 1e-7)
	_expect(top.size() == 4, "The frustum should have 4 top edges.")
	var dome = kernel.patch([{"shape": frustum, "edges": top, "continuity": 1}], PackedVector3Array(), {})
	_expect(dome != null, "A G1 patch over 45 deg walls should build (%s)." % kernel.get_last_error())
	if dome != null:
		for side in [Vector3(-1, 0, 0), Vector3(1, 0, 0), Vector3(0, -1, 0), Vector3(0, 1, 0)]:
			# At the middle of each top edge (3 mm out), the patch's normal is the wall's.
			var normal: Vector3 = dome.face_normal_at(0, side * 3.0 * MM + Vector3(0, 0, 5 * MM))
			var wall: Vector3 = (side + Vector3(0, 0, 1)).normalized()
			_expect(absf(normal.dot(wall)) > 0.998, "The G1 patch should be tangent to the wall on the %s side (normal %s, wall %s)." % [side, normal, wall])
	# Vertical walls (an open tube): the patch rises off them into a cap (round 1's plate couldn't,
	# and refused; see _check_round2_patch for its tangency).
	var tube := _k_sheet([_k_circle(Vector2.ZERO, 10)], 10.0)
	var rim := _k_edges(tube, func(info: Dictionary) -> bool: return absf((info.midpoint as Vector3).z - 10 * MM) < 1e-7)
	var tube_cap = kernel.patch([{"shape": tube, "edges": rim, "continuity": 1}], PackedVector3Array(), {})
	_expect(tube_cap != null and (tube_cap.bbox() as AABB).end.z > 10.5 * MM, "A G1 patch on a tube's rim should cap it (%s)." % kernel.get_last_error())
	# G2 no longer throws OCCT's "continuity is not G0 G1 or G2"; a cap that misses the sphere's
	# curvature is refused for it.
	var holed := _k_spun([_k_arc(Vector2.ZERO, 10, -PI / 2, PI / 4)])
	var hole := _k_edges(holed, func(info: Dictionary) -> bool: return str(info.type) == "circle" and (info.midpoint as Vector3).y > 7 * MM)
	var cap = kernel.patch([{"shape": holed, "edges": hole, "continuity": 2}], PackedVector3Array(), {})
	_expect(not kernel.get_last_error().contains("continuity is not"), "A G2 patch should build its constraints (%s)." % kernel.get_last_error())
	_expect(cap != null or kernel.get_last_error().contains("curvature"), "A G2 patch should match the curvature or say it can't (%s)." % kernel.get_last_error())
	_expect(kernel.patch([{"shape": holed, "edges": hole, "continuity": 1}], PackedVector3Array(), {}) != null, "A G1 cap on a sphere's hole should build (%s)." % kernel.get_last_error())
	# A point above the boundary would fling the plate wide: refused.
	var loop = kernel.sketch_edges(_k_square(5.0), Transform3D.IDENTITY)
	_k_refused(kernel.patch([{"shape": loop, "edges": PackedInt32Array(), "continuity": 0}], PackedVector3Array([Vector3(0, -5, 3) * MM]), {}), "smoothly", "A patch through a point above its boundary")
	# Its box is the patch's own, before and after it is drawn (not the spline's control points).
	var raised = kernel.patch([{"shape": loop, "edges": PackedInt32Array(), "continuity": 0}], PackedVector3Array([Vector3(0, 0, 3) * MM]), {})
	var before: AABB = raised.bbox()
	raised.tessellate(0.02 * MM, 0.1)
	var after: AABB = raised.copy().bbox()
	_expect(before.size.is_equal_approx(Vector3(10, 10, 3) * MM) and after.size.is_equal_approx(before.size), "A domed patch's box should be 10 x 10 x 3 mm before and after meshing (%s, %s)." % [before, after])


# Offsets: refused where the surface curves too tightly or comes to a point, never broken.
func _check_kernel_offset() -> void:
	var quarter := _k_sheet([_k_arc(Vector2.ZERO, 10, 0.0, PI / 2)], 10.0)
	var toward: Vector3 = quarter.face_normal_at(0, Vector3(7.07, 7.07, 5) * MM)
	var inward := 1.0 if toward.dot(Vector3(-1, -1, 0)) > 0.0 else -1.0
	_k_refused(kernel.offset_surface(quarter, PackedInt32Array(), inward * 15 * MM, "o"), "curves too tightly", "Offsetting a 10 mm quarter tube 15 mm toward its axis")
	var smaller = kernel.offset_surface(quarter, PackedInt32Array(), inward * 5 * MM, "o")
	_expect(smaller != null and absf(float(smaller.face_info(0).get("radius", 0.0)) - 5 * MM) < 1e-9, "Offsetting it 5 mm in should give a 5 mm cylinder.")
	var cone := _k_spun([_k_line(Vector2(0, 10), Vector2(10, 0))])
	for distance in [1.0, -1.0, 0.1]:
		var moved = kernel.offset_surface(cone, PackedInt32Array(), distance * MM, "o")
		_expect(moved == null or (moved.area() > 0.0 and moved.area() < 1.0 and _k_mesh_area(moved, 0.05) > 100.0), "Offsetting a cone with an apex by %s mm should be refused or sound (area %s)." % [distance, moved.area() if moved != null else "-"])
		_expect(moved != null or kernel.get_last_error().contains("point") or kernel.get_last_error().contains("tightly"), "A refused cone offset should say why (%s)." % kernel.get_last_error())
	# Offset Face on a surface moves whole sheets: a face joined to unpicked faces is refused.
	var ell := _k_sheet([_k_line(Vector2(0, 0), Vector2(10, 0)), _k_line(Vector2(10, 0), Vector2(10, 10))], 10.0)
	_k_refused(kernel.offset_faces(ell, PackedInt32Array([0]), 2 * MM, "of"), "every face", "Offset Face on one face of an L sheet")
	var both = kernel.offset_faces(ell, PackedInt32Array([0, 1]), 1 * MM, "of")
	_expect(both != null and _k_open_shared(both).y == 1, "Offset Face on the whole L sheet should keep it joined (%s)." % kernel.get_last_error())
	if both != null:
		var named_before := Array(ell.get_face_names())
		var named_after := Array(both.get_face_names())
		named_before.sort()
		named_after.sort()
		_expect(named_before == named_after, "Offset Face should keep the moved faces' names (%s -> %s)." % [named_before, named_after])


# Extend: natural extends stay joined and really grow; flat faces and corners carry on.
func _check_kernel_extend() -> void:
	var arcs := _k_sheet([_k_arc(Vector2.ZERO, 10, 0.0, PI / 2), _k_arc(Vector2(-10, 10), 10, 0.0, PI / 2)], 10.0)
	var tops := _k_edges(arcs, func(info: Dictionary) -> bool: return absf((info.midpoint as Vector3).z - 10 * MM) < 1e-7)
	for ids in [tops, PackedInt32Array([tops[0]])]:
		var grown = kernel.extend_surface(arcs, ids, {"distance": 5 * MM, "mode": "natural"})
		_expect(grown != null and _k_open_shared(grown).y == 1, "A natural extend should keep the seam between the two faces (%s)." % kernel.get_last_error())
	var both = kernel.extend_surface(arcs, tops, {"distance": 5 * MM, "mode": "natural"})
	var thick = kernel.thicken(both, PackedInt32Array(), {"thickness": 1 * MM})
	_expect(thick != null and thick.solid_count() == 1, "The extended two-face sheet should thicken into one solid.")
	# A spline's extrusion carries on past the spline's end (it used to stay as it was).
	var wave := _k_sheet([{"type": "interp", "points": PackedVector2Array([Vector2(0, 0) * MM, Vector2(10, 5) * MM, Vector2(20, 0) * MM])}], 10.0)
	var end := _k_edges(wave, func(info: Dictionary) -> bool: return str(info.type) == "line" and absf((info.start as Vector3).x - 20 * MM) < 1e-7)
	var longer = kernel.extend_surface(wave, end, {"distance": 5 * MM, "mode": "natural"})
	_expect(longer != null and absf((longer.area() - wave.area()) / MM2 - 50.0) < 0.5, "A natural extend of a spline wall's end should add about 5 x 10 mm2 (added %s)." % ((longer.area() - wave.area()) / MM2 if longer != null else -1.0))
	# An extended spline face's area is integrated in full (its added span is no longer squeezed).
	var low = kernel.sketch_wire([_k_line(Vector2(0, 0), Vector2(20, 0))], Transform3D.IDENTITY)
	var high = kernel.sketch_wire([_k_line(Vector2(0, 0), Vector2(20, 5))], Transform3D(Basis.IDENTITY, Vector3(0, 0, 10 * MM)))
	var sheet = kernel.loft([low, high], {"surface": true})
	var edge := _k_edges(sheet, func(info: Dictionary) -> bool: return (info.midpoint as Vector3).is_equal_approx(Vector3(10, 0, 0) * MM))
	var stretched = kernel.extend_surface(sheet, edge, {"distance": 5 * MM, "mode": "natural"})
	_expect(stretched != null, "A natural extend of a lofted sheet's straight edge should build (%s)." % kernel.get_last_error())
	if stretched != null:
		_close(stretched.area() / MM2, _k_mesh_area(stretched, 0.002), 2e-4, "A naturally extended lofted sheet's area (against its mesh)")
	# Two adjacent edges of a flat sheet: a bigger rectangle, corner filled, in either mode.
	var flat := _k_sheet([_k_line(Vector2(0, 0), Vector2(16, 0))], 12.0)
	var two := _k_edges(flat, func(info: Dictionary) -> bool: return absf((info.midpoint as Vector3).x - 16 * MM) < 1e-7 or absf((info.midpoint as Vector3).z - 12 * MM) < 1e-7)
	for mode in ["natural", "tangent"]:
		var wider = kernel.extend_surface(flat, two, {"distance": 4 * MM, "mode": mode})
		_close(wider.area() / MM2 if wider != null else -1.0, 320.0, 1e-6, "Extending two adjacent edges of a 16 x 12 mm sheet by 4 mm (%s)" % mode)
	# Tangent strips on a curved face's two adjacent edges meet at a filled corner: one piece, the
	# quarter cylinder (157.08 mm2) with its arc's 4 mm strip (round 3: an exact cylinder, which
	# joins it), the straight edge's 10 x 4 mm strip and their 4 x 4 mm corner.
	var quarter := _k_sheet([_k_arc(Vector2.ZERO, 10, 0.0, PI / 2)], 10.0)
	var corner := _k_edges(quarter, func(info: Dictionary) -> bool: return absf((info.midpoint as Vector3).z - 10 * MM) < 1e-7 or (str(info.type) == "line" and absf((info.start as Vector3).y) < 1e-7))
	var flanged = kernel.extend_surface(quarter, corner, {"distance": 4 * MM, "mode": "tangent"})
	_expect(flanged != null and kernel.pieces(flanged).size() == 1, "Tangent strips on two adjacent edges should meet at a corner face (%s)." % kernel.get_last_error())
	_close(flanged.area() / MM2 if flanged != null else -1.0, 50.0 * PI + 20.0 * PI + 40.0 + 16.0, 1e-6, "Tangent strips on a quarter cylinder's two adjacent edges, corner filled (area)")


# Sheets: ruled chains, trims along edges, merges across cuts, stitching, reversing, closing.
func _check_kernel_sheets() -> void:
	# Ruled tangent strips on two top edges of a box: off the top they share, the corner closed.
	var box = kernel.make_box(Vector3(10, 10, 10) * MM, Vector3.ZERO, "box")
	var chain := _k_edges(box, func(info: Dictionary) -> bool: return (info.midpoint as Vector3).is_equal_approx(Vector3(0, 10, 5) * MM) or (info.midpoint as Vector3).is_equal_approx(Vector3(5, 10, 0) * MM))
	var flange = kernel.ruled(box, chain, {"type": "tangent", "distance": 4 * MM})
	_expect(flange != null and kernel.pieces(flange).size() == 1, "Tangent ruled strips on a chain of edges should stay one piece.")
	if flange != null:
		_close(flange.area() / MM2, 96.0, 1e-6, "Two 10 x 4 mm strips and their 4 x 4 mm corner (area)")
		_expect(absf(flange.bbox().size.y) < 1e-9, "The strips should lie in the box's top plane (%s)." % flange.bbox())
	# A ruled direction along its own straight edge sweeps nothing: refused.
	var strip := _k_sheet([_k_line(Vector2(0, 0), Vector2(10, 0))], 10.0)
	var upright := _k_edges(strip, func(info: Dictionary) -> bool: return absf((info.start as Vector3).z - (info.end as Vector3).z) > 1e-6)
	_k_refused(kernel.ruled(strip, PackedInt32Array([upright[0]]), {"type": "direction", "direction": Vector3(0, 0, 1), "distance": 5 * MM}), "runs along the edge", "A ruled direction along its edge")
	# Trim along the joint of two faces parts them; a tool that misses is refused when a piece is picked.
	var halves := _k_sheet([_k_line(Vector2(0, 0), Vector2(10, 0)), _k_line(Vector2(10, 0), Vector2(20, 0))], 10.0)
	var joint = kernel.plane_face(Vector3(10 * MM, 0, 0), Vector3(1, 0, 0), 0.1, "tool")
	var trimmed = kernel.trim(halves, joint, PackedVector3Array([Vector3(15, 0, 5) * MM]), {})
	_close(trimmed.area() / MM2 if trimmed != null else -1.0, 100.0, 1e-6, "Trimming at the joint of two faces (area left)")
	_expect(kernel.pieces(kernel.trim(halves, joint, PackedVector3Array(), {})).size() == 2, "Trim at the joint with nothing picked should show 2 pieces.")
	_k_refused(kernel.trim(halves, kernel.plane_face(Vector3(50 * MM, 0, 0), Vector3(1, 0, 0), 0.1, "tool"), PackedVector3Array([Vector3(15, 0, 5) * MM]), {}), "doesn't cut", "Trim by a tool that misses")
	# Merge joins coplanar pieces a cut left in separate shells.
	var whole := _k_sheet([_k_line(Vector2(0, 0), Vector2(20, 0))], 10.0)
	var cut = kernel.trim(whole, joint, PackedVector3Array(), {})
	var seam := _k_edges(cut, func(info: Dictionary) -> bool: return (info.faces as PackedInt32Array).size() == 2)
	var merged = kernel.merge_faces(cut, seam, PackedInt32Array(), "m")
	_expect(merged != null and merged.face_count() == 1, "Merging the two pieces of a cut sheet should give one face (%s)." % kernel.get_last_error())
	# Stitch: strips that don't meet are refused; a cut's pieces sew back into one.
	_k_refused(kernel.stitch([strip, _k_sheet([_k_line(Vector2(13, 0), Vector2(20, 0))], 10.0)], {"tolerance": 0.01 * MM}), "Nothing was stitched", "Stitching strips 3 mm apart")
	var resewn = kernel.stitch([cut], {"tolerance": 0.01 * MM})
	_expect(resewn != null and kernel.pieces(resewn).size() == 1, "Stitching a cut's pieces should make one piece again.")
	# A lone closed face (a sphere's) stitches into a solid and thickens into a hollow ball.
	var ball := _k_spun([_k_arc(Vector2.ZERO, 10, -PI / 2, PI / 2)])
	var solid_ball = kernel.stitch([ball], {"solid": true})
	_expect(solid_ball != null and solid_ball.solid_count() == 1, "Stitching a one-face sphere should make a solid (%s)." % kernel.get_last_error())
	if solid_ball != null:
		_close(solid_ball.volume() / MM3, 4.0 / 3.0 * PI * 1000.0, 1e-6, "The stitched sphere (volume)")
	var shell_ball = kernel.thicken(ball, PackedInt32Array(), {"thickness": 1 * MM})
	_expect(shell_ball != null and shell_ball.solid_count() == 1, "Thickening a one-face sphere should work (%s)." % kernel.get_last_error())
	if shell_ball != null:
		_close(shell_ball.volume() / MM3, 4.0 / 3.0 * PI * (1331.0 - 1000.0), 1e-4, "A sphere thickened 1 mm outward (volume)")
	# Reverse Normal on one face turns its whole sheet, so the L still thickens as one, mitred.
	var ell := _k_sheet([_k_line(Vector2(0, 0), Vector2(10, 0)), _k_line(Vector2(10, 0), Vector2(10, 10))], 10.0)
	var turned = kernel.reverse_faces(ell, PackedInt32Array([0]))
	var flipped := true
	for f in 2:
		var at: Vector3 = ell.face_info(f).point
		flipped = flipped and turned.face_normal_at(f, at).dot(ell.face_normal_at(f, at)) < -0.99
	_expect(flipped, "Reversing one face of a sheet should turn the whole sheet.")
	var thick_ell = kernel.thicken(turned, PackedInt32Array(), {"thickness": 1 * MM})
	var v: float = thick_ell.volume() / MM3 if thick_ell != null else -1.0
	_expect(absf(v - 190.0) < 1e-3 or absf(v - 210.0) < 1e-3, "The turned L should thicken mitred: 190 or 210 mm3 (got %s)." % v)


# --- Review fixes ------------------------------------------------------------------------------

## Stands in for the Forge workspace where a command only reads the design.
class Workspace:
	extends RefCounted
	var doc: Resource
	var result: Dictionary
	var kernel: RefCounted


## Trim removes the clicked piece even where its middle lies on another piece (a holed strip's
## outer piece: its centroid is the hole's center, on the disc); a profile cuts as a tool, and a
## Trimming Tool slot gathers the curves of an outline; a surface body's face stands for its whole
## body, which is cut too, so its own pieces can be clicked away.
func _check_trim_picks() -> void:
	_new_doc()
	var strip := _surface("extrude", {"distance": "10 mm"}, {"profiles": [_curve(_lines("xy", [[Vector2(0, 0), Vector2(20, 0)]]))]})
	var post := _add("cylinder", {"diameter": "4 mm", "height": "20 mm"}, {"position": Vector3(0.01, -0.01, 0.005), "operation": OPERATIONS.NEW_BODY})
	var trim := _surface("trim", {}, {"tool": [{"kind": "body", "body": _body(post)}], "remove": []})
	_rebuild()
	var outer := _face_ref_at(_body(strip), Vector3(0.0015, 0, 0.0015))
	outer["at"] = Vector3(0.0015, 0, 0.0015)
	trim.options["remove"] = [outer]
	_rebuild()
	_no_error(trim, "Trim the outer piece of a holed strip")
	_close(_area(_body(strip)), PI * 4.0, 1e-6, "Clicking a holed strip's outer piece away leaves the disc (area)")
	# A pick with no click kept (made before they were): a point inside its face, not its centroid.
	outer.erase("at")
	_rebuild()
	_close(_area(_body(strip)), PI * 4.0, 1e-6, "An outer piece picked without its click is still the one removed (area)")

	# A sketch circle's profile as the tool, in the sheet's plane: the sheet is cut round it.
	_new_doc()
	var sheet := _surface("extrude", {"distance": "20 mm"}, {"profiles": [_curve(_lines("xy", [[Vector2(0, 0), Vector2(20, 0)]]))]})
	var round: Resource = doc.add_feature("sketch", "Sketch", {}, SKETCH_DATA.new_options(SKETCH_DATA.ORIGIN_PLANES.xz, "xz"))
	var rs = SKETCH_DATA.new(round, doc)
	rs.add_circle(rs.add_point(Vector2(0.01, -0.01)), 0.003)
	var by_profile := _surface("trim", {}, {"tool": [{"kind": "profile", "sketch": round.id, "point": Vector2(0.01, -0.01)}], "remove": []})
	_rebuild()
	_expect(str(result.errors.get(by_profile.id, "")).contains("Click the pieces") and kernel.pieces(_shape(_body(sheet))).size() == 2,
		"A profile as the trimming tool should cut the sheet round it (%s)." % result.errors.get(by_profile.id, ""))
	var disc := _face_ref_at(_body(sheet), Vector3(0.01, 0, 0.01))
	disc["at"] = Vector3(0.01, 0, 0.01)
	by_profile.options["remove"] = [disc]
	_rebuild()
	_close(_area(_body(sheet)), 400.0 - PI * 9.0, 1e-6, "Trimming a disc out by a profile (area)")

	# The Trimming Tool slot takes one tool, but gathers sketch curves (an outline of four lines).
	var panel = COMMAND_PANEL.new()
	var fields: Array[Dictionary] = []
	for field in SPECS.get_spec("surface:trim").fields:
		fields.append(field)
	panel.setup("Trim", fields, {"tool": [], "remove": [], "extend": false}, "mm")
	panel.activate_selection("tool")
	var square := _lines("xz", [[Vector2(2, -2), Vector2(6, -2)], [Vector2(6, -2), Vector2(6, -6)], [Vector2(6, -6), Vector2(2, -6)], [Vector2(2, -6), Vector2(2, -2)]])
	for ref in _curves(square):
		panel.add_selection(ref)
	_expect((panel.values.tool as Array).size() == 4 and panel.active_selection_key == "tool", "The trimming tool slot should gather the outline's 4 curves (%d)." % (panel.values.tool as Array).size())
	panel.add_selection({"kind": "body", "body": "body1"})
	_expect((panel.values.tool as Array).size() == 1 and panel.active_selection_key == "remove", "A body picked as the tool should replace the curves and move on (%s)." % [panel.values.tool])
	panel.free()

	# Crossing surfaces: a sheet A (y = 0) and a U-shaped wall B. B's face picked as the tool stands
	# for all of B, so A is cut by both of B's legs, and B is cut by A: both show pieces to click.
	_new_doc()
	var a := _surface("extrude", {"distance": "10 mm"}, {"profiles": [_curve(_lines("xy", [[Vector2(0, 0), Vector2(20, 0)]]))]})
	var legs := _lines("xy", [[Vector2(5, -5), Vector2(5, 5)], [Vector2(5, 5), Vector2(15, 5)], [Vector2(15, 5), Vector2(15, -5)]])
	var b := _surface("extrude", {"distance": "10 mm"}, {"profiles": _curves(legs)})
	_rebuild()
	var both := _surface("trim", {}, {"tool": [_face_ref_at(_body(b), Vector3(0.005, -0.003, 0.005))], "remove": []})
	_rebuild()
	var a_pieces: int = kernel.pieces(_shape(_body(a))).size() if _shape(_body(a)) != null else 0
	var b_pieces: int = kernel.pieces(_shape(_body(b))).size() if _shape(_body(b)) != null else 0
	_expect(str(result.errors.get(both.id, "")).contains("Click the pieces") and a_pieces == 3 and b_pieces == 3,
		"A surface tool's face should cut with all of its body, and be cut too (A %d, B %d pieces; %s)." % [a_pieces, b_pieces, result.errors.get(both.id, "")])
	var middle := _face_ref_at(_body(a), Vector3(0.01, 0, 0.005))
	middle["at"] = Vector3(0.01, 0, 0.005)
	var leg := _face_ref_at(_body(b), Vector3(0.005, -0.003, 0.005))
	leg["at"] = Vector3(0.005, -0.003, 0.005)
	both.options["remove"] = [middle, leg]
	_rebuild()
	_no_error(both, "Trim pieces of a surface and of its surface tool")
	_close(_area(_body(a)), 100.0, 1e-6, "The sheet without its middle piece (area)")
	_close(_area(_body(b)), 250.0, 1e-6, "The tool surface without one leg's end (area)")


## Bodies sharing a root (a body and a piece split off it) unstitched or copied together keep every
## piece: no derived id is given twice.
func _check_shared_roots() -> void:
	_new_doc()
	var box := _box(Vector3.ZERO, 10, 10, 10)
	_add("split_body", {}, {"body": [{"kind": "body", "body": _body(box)}], "tool": [{"kind": "origin", "name": "yz"}]})
	_rebuild()
	var halves: Array = result.bodies.keys()
	_expect(halves.size() == 2, "The split box should be two bodies (%s)." % [halves])
	var picks := halves.map(func(id: String) -> Dictionary: return {"kind": "body", "body": id})
	var apart := _surface("unstitch", {}, {"objects": picks})
	_rebuild()
	_no_error(apart, "Unstitch a body and its split-off piece")
	var faces := 0
	var area := 0.0
	for body_id in result.bodies:
		faces += _shape(body_id).face_count()
		area += _area(body_id)
	_expect(faces == 12 and absf(area - 800.0) < 1e-3, "Unstitching both halves should keep their 12 faces, 800 mm2 (got %d, %s)." % [faces, area])
	doc.remove_feature(apart.id)
	var copy := _add("move", {"x": "30 mm"}, {"objects": picks, "move_type": "free", "copy": true})
	_rebuild()
	_no_error(copy, "Copy a body and its split-off piece")
	_expect(result.bodies.size() == 4, "Copying both halves should add two bodies (%s)." % [result.bodies.keys()])
	var names := {}
	for body_id in result.bodies:
		names[doc.body_name(body_id)] = true
	_expect(names.size() == 4, "Each body should have a name of its own (%s)." % [names.keys()])


## A solid's Join or Cut with no bodies picked leaves a surface beside it alone (a Join next to a
## sheet failed and deleted it; a Cut trimmed it); a coil the kernel refuses says why.
func _check_solids_near_surfaces() -> void:
	_new_doc()
	var box := _box(Vector3.ZERO, 20, 10, 20)
	var sheet := _surface("extrude", {"distance": "30 mm"}, {"profiles": [_curve(_lines("xy", [[Vector2(0, -5), Vector2(0, 25)]]))]})
	var top := {"origin": Vector3(0, 0.01, 0), "x": Vector3.RIGHT, "y": Vector3.FORWARD}
	var square := _lines(top, [[Vector2(-3, -3), Vector2(3, -3)], [Vector2(3, -3), Vector2(3, 3)], [Vector2(3, 3), Vector2(-3, 3)], [Vector2(-3, 3), Vector2(-3, -3)]])
	var inside := {"kind": "profile", "sketch": square.feature.id, "point": Vector2.ZERO}
	var boss := _add("extrude", {"distance": "5 mm"}, {"profiles": [inside], "operation": OPERATIONS.JOIN, "targets": []})
	_rebuild()
	_no_error(boss, "Join beside a surface")
	_expect(_shape(_body(box)) != null and absf(_shape(_body(box)).volume() / MM3 - 4180.0) < 1e-3, "The join should grow the box only.")
	_close(_area(_body(sheet)), 900.0, 1e-6, "The sheet beside a join stays whole (area)")
	boss.options["operation"] = OPERATIONS.CUT
	boss.options["flip"] = true
	_rebuild()
	_no_error(boss, "Cut beside a surface")
	_close(_area(_body(sheet)), 900.0, 1e-6, "The sheet beside a cut stays whole (area)")
	_expect(_shape(_body(box)) != null and absf(_shape(_body(box)).volume() / MM3 - 3820.0) < 1e-3, "The cut should take from the box.")

	# Section wider than the coil: the kernel refuses, and the feature says so.
	var coil_inputs := {"diameter": "2 mm", "turns": ["3", "number"], "pitch": "5 mm", "section_size": "3 mm"}
	var coil_options := {"coil_type": "revolution_pitch", "section": "circle", "section_position": "inside", "position": Vector3(0.1, 0, 0)}
	var skin := _surface("coil", coil_inputs, coil_options)
	var spring := _add("coil", coil_inputs, coil_options.merged({"operation": OPERATIONS.NEW_BODY}))
	_rebuild()
	for feature in [skin, spring]:
		_expect(str(result.errors.get(feature.id, "")).contains("Coil failed"), "A coil the kernel refuses should say why (%s)." % result.errors.get(feature.id, ""))


## Stitch: surfaces that meet join into the first body; one that meets nothing stays a body of its
## own. Split Body of a solid with an open sheet beside it keeps the sheet.
func _check_stitch_apart() -> void:
	_new_doc()
	var near := _surface("extrude", {"distance": "10 mm"}, {"profiles": [_curve(_lines("xy", [[Vector2(0, 0), Vector2(10, 0)]]))]})
	var touching := _surface("extrude", {"distance": "10 mm"}, {"profiles": [_curve(_lines("xy", [[Vector2(10, 0), Vector2(20, 0)]]))]})
	var far := _surface("extrude", {"distance": "10 mm"}, {"profiles": [_curve(_lines("xy", [[Vector2(100, 0), Vector2(110, 0)]]))]})
	var picks := [{"kind": "body", "body": _body(near)}, {"kind": "body", "body": _body(far)}, {"kind": "body", "body": _body(touching)}]
	var sew := _surface("stitch", {"tolerance": "0.01 mm"}, {"bodies": picks})
	_rebuild()
	_no_error(sew, "Stitch strips, one of them apart")
	_expect(result.bodies.size() == 2 and result.bodies.has(_body(near)) and result.bodies.has(_body(far)),
		"The touching strips should join and the far one stay its own body (%s)." % [result.bodies.keys()])
	_close(_area(_body(near)), 200.0, 1e-6, "The stitched strips (area)")
	_close(_area(_body(far)), 100.0, 1e-6, "The strip apart (area)")
	_expect(_shape(_body(near)) != null and kernel.pieces(_shape(_body(near))).size() == 1, "The stitched strips should be one piece.")
	_expect(str(result.warnings.get(sew.id, "")).contains("separate bodies"), "Stitch should say what stayed apart (%s)." % result.warnings.get(sew.id, ""))

	_new_doc()
	var cube = kernel.make_box(Vector3(10, 10, 10) * MM, Vector3(-5, 0, -5) * MM, "cube")
	var mixed = kernel.make_compound([cube, _k_sheet([_k_line(Vector2(100, 0), Vector2(120, 0))], 10.0)])
	_add("base_feature", {}, {"breps": {"body1": mixed.to_brep_bytes()}})
	var split := _add("split_body", {}, {"body": [{"kind": "body", "body": "body1"}], "tool": [{"kind": "origin", "name": "yz"}]})
	_rebuild()
	_no_error(split, "Split a solid with a sheet beside it")
	var area := 0.0
	for body_id in result.bodies:
		area += _area(body_id)
	_expect(result.bodies.size() == 3 and absf(area - 1000.0) < 1e-3, "The split should keep the sheet beside the halves (%d bodies, %s mm2)." % [result.bodies.size(), area])


## Patch: a stitched patch makes no body (or component) of its own and hides its Operation; a flat
## face picked as the boundary (the view picks flat faces as profiles) fills its outline.
func _check_patch_command() -> void:
	_new_doc()
	var box := _box(Vector3.ZERO, 10, 10, 10)
	_rebuild()
	var lid := _surface("patch", {}, {"boundary": [_face_ref_at(_body(box), Vector3(0, 0.01, 0))]})
	_rebuild()
	_no_error(lid, "Patch a picked flat face's outline")
	_close(_area(_body(lid)), 100.0, 1e-6, "A patch over a box's top face (area)")
	doc.remove_feature(lid.id)
	_surface("unstitch", {}, {"objects": [_face_ref_at(_body(box), Vector3(0, 0.01, 0))]})
	_rebuild()
	var command = FEATURE_COMMAND.new("surface:patch")
	var values: Dictionary = command.defaults()
	values["boundary"] = _edges_at_height(_body(box), 0.01)
	values["stitch"] = true
	values["operation"] = OPERATIONS.NEW_COMPONENT
	var bodies_before: int = doc.bodies.size()
	var patch: Resource = command.create_feature(doc, values)
	_rebuild()
	_no_error(patch, "Stitched patch made by its command")
	_expect(doc.bodies.size() == bodies_before and doc.components.is_empty() and not patch.options.has("operation"),
		"A stitched patch should own no body or component (bodies %s, components %s)." % [doc.bodies.keys(), doc.components.keys()])
	_expect(_shape(_body(box)) != null and _shape(_body(box)).solid_count() == 1, "The stitched patch should close the box.")
	var operation_row: Dictionary = command.fields().filter(func(f: Dictionary) -> bool: return f.key == "operation")[0]
	_expect(not command._shown(operation_row, values), "The Operation row should hide while the patch is stitched.")
	values["stitch"] = false
	command.write_values(doc, values)
	_expect(doc.bodies.has(str(patch.options.get("body_id", ""))) and doc.components.size() == 1, "Not stitched, the patch owns a body in a component again.")

	# Continuity per edge: a G0 patch over a box's top with one edge G1 to its (vertical) wall rises
	# off that wall only (round 1 refused it); over a frustum's 45 deg walls, edges given G1 carry
	# on from their walls.
	_new_doc()
	var cube := _box(Vector3.ZERO, 10, 10, 10)
	_rebuild()
	var rim := _edges_at_height(_body(cube), 0.01)
	var one_g1 := _surface("patch", {}, {"boundary": rim, "continuity": "g0", "other_edges": [rim[0]], "other_continuity": "g1"})
	var all_g0 := _surface("patch", {}, {"boundary": rim, "continuity": "g0", "other_edges": [rim[0]], "other_continuity": "g0"})
	_rebuild()
	_no_error(one_g1, "A patch with one edge G1 to a vertical wall")
	_no_error(all_g0, "A patch with its other edges G0")
	var g1_edge: Dictionary = _shape(_body(cube)).edge_info(_shape(_body(cube)).find_edge(str(rim[0].name))) if _shape(_body(cube)) != null else {}
	if _shape(_body(one_g1)) != null and not g1_edge.is_empty():
		var wall_normal := Vector3.ZERO
		for f in g1_edge.faces:
			if absf((_shape(_body(cube)).face_info(f).normal as Vector3).y) < 0.5:
				wall_normal = _shape(_body(cube)).face_info(f).normal
		var normal: Vector3 = _shape(_body(one_g1)).face_normal_at(0, g1_edge.midpoint)
		_expect(absf(normal.dot(wall_normal)) > cos(deg_to_rad(1.0)), "The patch's G1 edge should carry on from its wall (normal %s, wall %s)." % [normal, wall_normal])
	if _shape(_body(all_g0)) != null:
		_expect(str(_shape(_body(all_g0)).face_info(0).type) == "plane", "With every edge G0 the patch stays flat.")
	_new_doc()
	var base := _lines("xy", [[Vector2(-8, -8), Vector2(8, -8)], [Vector2(8, -8), Vector2(8, 8)], [Vector2(8, 8), Vector2(-8, 8)], [Vector2(-8, 8), Vector2(-8, -8)]])
	var frustum := _add("extrude", {"distance": "5 mm", "taper": ["45 deg", "angle"]}, {"profiles": [{"kind": "profile", "sketch": base.feature.id, "point": Vector2.ZERO}], "operation": OPERATIONS.NEW_BODY})
	_rebuild()
	var top: Array = []
	var solid := _shape(_body(frustum))
	for e in solid.edge_count() if solid != null else 0:
		if absf((solid.edge_info(e).midpoint as Vector3).z - 5 * MM) < 1e-7:
			top.append(REFERENCES.from_pick({"kind": "edge", "body": _body(frustum), "index": e}, result))
	_expect(top.size() == 4, "The frustum should have 4 top edges (%d; %s)." % [top.size(), result.errors])
	var mixed := _surface("patch", {}, {"boundary": top, "continuity": "g0", "other_edges": top, "other_continuity": "g1"})
	_rebuild()
	_no_error(mixed, "A G0 patch with its edges given G1")
	if _shape(_body(mixed)) != null:
		for side in [Vector3(-1, 0, 0), Vector3(1, 0, 0), Vector3(0, -1, 0), Vector3(0, 1, 0)]:
			var normal: Vector3 = _shape(_body(mixed)).face_normal_at(0, side * 3.0 * MM + Vector3(0, 0, 5 * MM))
			var wall: Vector3 = (side + Vector3(0, 0, 1)).normalized()
			_expect(absf(normal.dot(wall)) > 0.998, "The patch's G1 side should be tangent to its wall (%s: normal %s)." % [side, normal])


## Surface Extrude of body edges: straight edges need a Direction; a flat loop of edges rises off
## its plane. Loft: curves picked one after another that join make one section.
func _check_edges_and_chains() -> void:
	_new_doc()
	var box := _box(Vector3.ZERO, 10, 10, 10)
	_rebuild()
	var edge := _edge_ref_at(_body(box), Vector3(0, 0.01, 0.005))
	var lone := _surface("extrude", {"distance": "5 mm"}, {"profiles": [edge]})
	var led := _surface("extrude", {"distance": "5 mm"}, {"profiles": [edge], "direction": [{"kind": "origin", "name": "y"}]})
	var rim := _surface("extrude", {"distance": "5 mm"}, {"profiles": _edges_at_height(_body(box), 0.01)})
	_rebuild()
	_expect(str(result.errors.get(lone.id, "")).contains("direction"), "A straight edge with no direction should ask for one (%s)." % result.errors.get(lone.id, ""))
	_no_error(led, "Surface Extrude of an edge along Y")
	if _shape(_body(led)) != null:
		var up: AABB = _shape(_body(led)).bbox()
		_expect(absf(up.position.y - 0.01) < 1e-7 and absf(up.size.y - 0.005) < 1e-7, "The edge's wall should rise 5 mm off the top (%s)." % up)
	_no_error(rim, "Surface Extrude of a box's top edges")
	if _shape(_body(rim)) != null:
		var walls: AABB = _shape(_body(rim)).bbox()
		_expect(absf(walls.size.y - 0.005) < 1e-7 and absf(walls.size.x - 0.01) < 1e-7 and absf(walls.size.z - 0.01) < 1e-7,
			"The top edges' walls should stand up off the top's plane (%s)." % walls)

	# Two L-shaped polylines (2 lines each) 20 mm apart: two sections, two flat 10 x 20 mm walls.
	var low := _lines("xy", [[Vector2(0, 50), Vector2(10, 50)], [Vector2(10, 50), Vector2(10, 60)]])
	var high := _lines({"origin": Vector3(0, 0, 0.02), "x": Vector3.RIGHT, "y": Vector3.UP}, [[Vector2(0, 50), Vector2(10, 50)], [Vector2(10, 50), Vector2(10, 60)]])
	var walls := _surface("loft", {}, {"sections": _curves(low) + _curves(high)})
	# Two 10 mm squares, each picked as its 4 curves: two closed sections, one solid.
	var base := _lines("xy", [[Vector2(100, 0), Vector2(110, 0)], [Vector2(110, 0), Vector2(110, 10)], [Vector2(110, 10), Vector2(100, 10)], [Vector2(100, 10), Vector2(100, 0)]])
	var lid := _lines({"origin": Vector3(0, 0, 0.02), "x": Vector3.RIGHT, "y": Vector3.UP}, [[Vector2(100, 0), Vector2(110, 0)], [Vector2(110, 0), Vector2(110, 10)], [Vector2(110, 10), Vector2(100, 10)], [Vector2(100, 10), Vector2(100, 0)]])
	var block := _add("loft", {}, {"sections": _curves(base) + _curves(lid), "operation": OPERATIONS.NEW_BODY})
	_rebuild()
	_no_error(walls, "Loft between two open chains")
	_close(_area(_body(walls)), 400.0, 1e-4, "A loft between two L-shaped chains (area)")
	_no_error(block, "Loft between two squares of curves")
	_close(_shape(_body(block)).volume() / MM3 if _shape(_body(block)) != null else -1.0, 2000.0, 1e-4, "A loft between two squares picked as curves (volume)")


## A sketch that is suppressed, or comes later in the timeline, drives nothing. Press Pull on one
## face of a two-face sheet would tear it: refused.
func _check_sketch_order() -> void:
	_new_doc()
	var line := _lines("xy", [[Vector2(0, 0), Vector2(20, 0)]])
	var wall := _surface("extrude", {"distance": "10 mm"}, {"profiles": [_curve(line)]})
	line.feature.suppressed = true
	_rebuild()
	_expect(str(result.errors.get(wall.id, "")).contains("sketch is missing") and not result.bodies.has(_body(wall)),
		"A suppressed sketch's curves should not build (%s)." % result.errors.get(wall.id, ""))
	line.feature.suppressed = false
	doc.features.erase(line.feature)
	doc.features.append(line.feature)
	_rebuild()
	_expect(str(result.errors.get(wall.id, "")).contains("sketch is missing"), "A sketch later in the timeline should not drive the extrude (%s)." % result.errors.get(wall.id, ""))

	_new_doc()
	var bend := _lines("xy", [[Vector2(0, 0), Vector2(20, 0)], [Vector2(20, 0), Vector2(20, 10)]])
	var ell := _surface("extrude", {"distance": "10 mm"}, {"profiles": _curves(bend)})
	_rebuild()
	var command = FEATURE_COMMAND.new("press_pull")
	var values: Dictionary = command.defaults()
	values["pick"] = [_face_ref_at(_body(ell), Vector3(0.01, 0, 0.005))]
	values["distance"] = "3"
	var pulled: Resource = command.create_feature(doc, values)
	_rebuild()
	_expect(pulled.type == "offset_face" and str(result.errors.get(pulled.id, "")).contains("every face") and kernel.pieces(_shape(_body(ell))).size() == 1,
		"Press Pull on one face of a sheet should be refused, leaving it whole (%s)." % result.errors.get(pulled.id, ""))


## The Surface Extrude arrow: on curves, from where the wall starts to its far edge; along a picked
## Direction when there is one.
func _check_arrow() -> void:
	_new_doc()
	var line := _lines("xy", [[Vector2(0, 0), Vector2(20, 0)]])
	var command = FEATURE_COMMAND.new("surface:extrude")
	var values: Dictionary = command.defaults()
	values["profiles"] = [_curve(line)]
	values["distance"] = "10"
	command.create_feature(doc, values)
	command.result = _rebuild()
	var handles: Array = command.manipulators(values, {"distance": 0.01})
	_expect(handles.size() == 1 and absf((handles[0].origin as Vector3).z - 0.01) < 1e-7 and (handles[0].direction as Vector3).is_equal_approx(Vector3.BACK),
		"A curve's extrude arrow should end on the wall's far edge (%s)." % [handles])
	var ring: Resource = doc.add_feature("sketch", "Sketch", {}, SKETCH_DATA.new_options(SKETCH_DATA.ORIGIN_PLANES.xz, "xz"))
	var rs = SKETCH_DATA.new(ring, doc)
	rs.add_circle(rs.add_point(Vector2(0.1, 0)), 0.005)
	var along_x = FEATURE_COMMAND.new("surface:extrude")
	var picked: Dictionary = along_x.defaults()
	picked["profiles"] = [{"kind": "profile", "sketch": ring.id, "point": Vector2(0.1, 0)}]
	picked["direction"] = [{"kind": "origin", "name": "x"}]
	along_x.create_feature(doc, picked)
	along_x.workspace = Workspace.new()
	along_x.workspace.doc = doc
	along_x.workspace.kernel = kernel
	along_x.result = _rebuild()
	handles = along_x.manipulators(picked, {"distance": 0.01})
	_expect(handles.size() == 1 and (handles[0].direction as Vector3).is_equal_approx(Vector3.RIGHT), "With a Direction picked the arrow should run along it (%s)." % [handles])


## Bodies seen from both sides: analyses draw both sides, baked collision works from both sides, a
## Material file on a surface stays that very file (its back drawn as triangles), a solid with an
## open sheet beside it counts as two-sided, and Interference says surfaces weren't checked.
func _check_two_sided() -> void:
	_new_doc()
	var strip := _surface("extrude", {"distance": "10 mm"}, {"profiles": [_curve(_lines("xy", [[Vector2(0, 0), Vector2(20, 0)]]))]})
	var box := _box(Vector3(100, 0, 0), 10, 10, 10)
	_rebuild()
	var tess := {}
	for body_id in result.bodies:
		tess[body_id] = TESSELLATE.tessellate(_shape(body_id))
	var analyses := {"zebra": {}, "draft": {"pull": Vector3.UP}, "curvature_map": {}, "minimum_radius": {"radius": 0.003},
		"accessibility": {"direction": Vector3.DOWN}, "environment_map": {}, "component_colors": {}}
	for type in analyses:
		var out := ANALYSIS.build({"type": type, "options": analyses[type]}, result, tess, kernel, doc)
		var material: Material = out.body_materials.get(_body(strip))
		var both := (material is BaseMaterial3D and (material as BaseMaterial3D).cull_mode == BaseMaterial3D.CULL_DISABLED) \
			or (material is ShaderMaterial and (material as ShaderMaterial).shader.code.contains("cull_disabled"))
		_expect(both, "The %s analysis should draw a surface from both sides (%s)." % [type, material])

	var part: Node3D = CAD_PART.new()
	part.document = doc
	part.generate_collision = true
	part.apply_result(result)
	for spec in [[_body(strip), true], [_body(box), false]]:
		var node: Node = part.body_nodes().get(spec[0])
		var collision := node.get_node_or_null("Collision/Shape") as CollisionShape3D if node != null else null
		var shape := collision.shape as ConcavePolygonShape3D if collision != null else null
		_expect(shape != null and shape.backface_collision == spec[1], "A baked %s should collide %s." % ["surface" if spec[1] else "solid", "from both sides" if spec[1] else "from its outside"])
	part.free()

	# Material files on a surface: the files themselves, their back drawn as triangles unless they
	# draw both sides already.
	var shader := Shader.new()
	shader.code = "shader_type spatial;\nrender_mode cull_back;\nvoid fragment() { ALBEDO = vec3(1.0); }\n"
	var shaded := ShaderMaterial.new()
	shaded.shader = shader
	var plain := StandardMaterial3D.new()
	var open := StandardMaterial3D.new()
	open.cull_mode = BaseMaterial3D.CULL_DISABLED
	var sheet := _shape(_body(strip))
	var front: int = (TESSELLATE.tessellate(sheet).indices as PackedInt32Array).size()
	for spec in [[shaded, 2, "a"], [plain, 2, "b"], [open, 1, "c"]]:
		var path := "user://holo_forge_surface_test_%d_%s.tres" % [OS.get_process_id(), spec[2]]
		ResourceSaver.save(spec[0], path)
		var file: Material = load(path)
		doc.appearances[APPEARANCE.body_target(_body(strip))] = {"material": path}
		var built: Dictionary = APPEARANCE.build_mesh(doc, _body(strip), sheet, TESSELLATE.tessellate(sheet), CAD_PART.default_material(), CAD_PART.surface_material())
		var mesh: ArrayMesh = built.mesh
		var count: int = (mesh.surface_get_arrays(0)[Mesh.ARRAY_INDEX] as PackedInt32Array).size()
		_expect(mesh.surface_get_material(0) == file and count == front * int(spec[1]),
			"A %s file on a surface should stay that file (%s) with %dx its triangles (%d of %d)." % [file.get_class(), mesh.surface_get_material(0) == file, spec[1], count, front])
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	doc.appearances.clear()

	# A solid with an open sheet beside it is two-sided too.
	var mixed = kernel.make_compound([kernel.make_box(Vector3(10, 10, 10) * MM, Vector3.ZERO, "cube"), _k_sheet([_k_line(Vector2(50, 0), Vector2(60, 0))], 10.0)])
	var mixed_mesh: Dictionary = APPEARANCE.build_mesh(doc, "mixed", mixed, TESSELLATE.tessellate(mixed), CAD_PART.default_material(), CAD_PART.surface_material())
	_expect(APPEARANCE.two_sided(mixed) and not APPEARANCE.two_sided(_shape(_body(box))) and (mixed_mesh.mesh as ArrayMesh).surface_get_material(0) == CAD_PART.surface_material(),
		"A solid with an open sheet beside it should draw two-sided.")

	var check = INTERFERENCE.new()
	check.workspace = Workspace.new()
	check.workspace.doc = doc
	check.workspace.result = result
	check.workspace.kernel = kernel
	var text: String = check.describe()
	_expect(text.contains("not checked: %s" % doc.body_name(_body(strip))) and text.contains("between the solids"), "Interference should say surfaces weren't checked (%s)." % text)


## Remove (the Delete action's feature): picked faces leave their body (a solid opens into a
## surface) and picked split-off bodies go.
func _check_remove() -> void:
	_new_doc()
	var box := _box(Vector3.ZERO, 10, 10, 10)
	_add("split_body", {}, {"body": [{"kind": "body", "body": _body(box)}], "tool": [{"kind": "origin", "name": "yz"}]})
	_rebuild()
	var piece := ""
	for body_id in result.bodies:
		if body_id != _body(box):
			piece = body_id
	var top := {}
	for f in _shape(_body(box)).face_count():
		if (_shape(_body(box)).face_info(f).normal as Vector3).y > 0.99:
			top = REFERENCES.from_pick({"kind": "face", "body": _body(box), "index": f}, result)
	var gone := _add("remove", {}, {"bodies": [{"kind": "body", "body": piece}], "faces": [top]})
	_rebuild()
	_no_error(gone, "Remove a face and a split-off body")
	_expect(not result.bodies.has(piece), "The removed piece should be gone.")
	_is_surface(_body(box), 5, "The half box without its top")


# --- Round 2: patches, plates, untrim, extend --------------------------------------------------

## True when a one-face sheet fills its surface's UV box: Untrim All gives it back as it is.
func _k_fills_box(sheet: RefCounted) -> bool:
	var whole = kernel.untrim(sheet, PackedInt32Array([0]), PackedInt32Array(), {"mode": "all", "extend": 0.0})
	return whole != null and absf(whole.area() - sheet.area()) <= 1e-9 * sheet.area()


## A closed loop of straight edges through 3D corners (in mm).
func _k_loop3(corners_mm: Array) -> RefCounted:
	var segments := []
	for k in corners_mm.size():
		var a: Vector3 = corners_mm[k] * MM
		var d: Vector3 = corners_mm[(k + 1) % corners_mm.size()] * MM - a
		var x := d.normalized()
		var y := x.cross(Vector3(0, 0, 1)).normalized()
		segments.append(kernel.sketch_wire([{"type": "line", "a": Vector2.ZERO, "b": Vector2(d.length(), 0)}], Transform3D(Basis(x, y, x.cross(y)), a)))
	return kernel.make_compound(segments)


## A1: three- and four-sided loops make Coons patches that fill their own surface: G1 rises square
## off an open box's walls (stitched in, it closes the box) and off a tube's rim; a twisted loop
## spans its loft (trimmed, Untrim All gives it back); a flat loop stays a plane.
func _check_round2_patch() -> void:
	var box = kernel.make_box(Vector3(10, 10, 10) * MM, Vector3.ZERO, "box")
	var walls := PackedInt32Array()
	for f in box.face_count():
		if (box.face_info(f).normal as Vector3).z < 0.99:
			walls.append(f)
	var open_box = kernel.keep_faces(box, walls)
	var rim := _k_edges(open_box, func(info: Dictionary) -> bool: return absf((info.midpoint as Vector3).z - 10 * MM) < 1e-7)
	var dome = kernel.patch([{"shape": open_box, "edges": rim, "continuity": 1}], PackedVector3Array(), {"tag": "p"})
	_expect(dome != null and dome.face_count() == 1, "A G1 patch over an open box should be one face (%s)." % kernel.get_last_error())
	if dome != null:
		_expect(_k_fills_box(dome), "The G1 dome should fill its UV box (Untrim All leaves it as it is).")
		_expect((dome.bbox() as AABB).end.z > 10.5 * MM, "The G1 dome should rise above the box (%s)." % dome.bbox())
		for k in 4:
			for t in [0.25, 0.5, 0.75]:
				var at: Vector3 = [Vector3(t * 10, 0, 10), Vector3(10, t * 10, 10), Vector3(t * 10, 10, 10), Vector3(0, t * 10, 10)][k] * MM
				var wall := Vector3(0, 1, 0) if k % 2 == 0 else Vector3(1, 0, 0)
				var normal: Vector3 = dome.face_normal_at(0, at)
				_expect(absf(normal.dot(wall)) > cos(deg_to_rad(1.0)), "The G1 dome should carry on from the wall at %s mm (normal %s)." % [at / MM, normal])
	# With Patch's Stitch option the dome closes the box: one solid, more than the box's volume.
	_new_doc()
	var cube := _box(Vector3.ZERO, 10, 10, 10)
	_rebuild()
	_surface("unstitch", {}, {"objects": [_face_ref_at(_body(cube), Vector3(0, 0.01, 0))]})
	_rebuild()
	var lid := _surface("patch", {}, {"boundary": _edges_at_height(_body(cube), 0.01), "continuity": "g1", "stitch": true})
	_rebuild()
	_no_error(lid, "A stitched G1 patch over an open box")
	var closed := _shape(_body(cube))
	_expect(closed != null and closed.solid_count() == 1 and closed.volume() / MM3 > 1000.0,
		"The stitched G1 dome should close the box into one solid over 1000 mm3 (%s)." % [closed.volume() / MM3 if closed != null else -1.0])
	# A G1 cap on an open r 5 mm tube: a dome, tangent to the tube all round (checked between the
	# points its circle is split at into four sides).
	var tube := _k_sheet([_k_circle(Vector2.ZERO, 5)], 10.0)
	var tube_rim := _k_edges(tube, func(info: Dictionary) -> bool: return absf((info.midpoint as Vector3).z - 10 * MM) < 1e-7)
	var cap = kernel.patch([{"shape": tube, "edges": tube_rim, "continuity": 1}], PackedVector3Array(), {"tag": "p"})
	_expect(cap != null and (cap.bbox() as AABB).end.z > 10.5 * MM, "A G1 cap on an open tube should be a dome (%s)." % kernel.get_last_error())
	if cap != null:
		for k in 8:
			var a := TAU * (k + 0.5) / 8.0
			var radial := Vector3(cos(a), sin(a), 0)
			var normal: Vector3 = cap.face_normal_at(0, radial * 5 * MM + Vector3(0, 0, 10 * MM))
			_expect(absf(normal.dot(radial)) > cos(deg_to_rad(1.0)), "The tube cap should carry on from the tube at %.1f deg (normal %s)." % [rad_to_deg(a), normal])
	# A twisted four-edge loop spans its lofted sheet (round 1's plate was 5 % off); trimmed, Untrim
	# All gives it its area back.
	var low = kernel.sketch_wire([_k_line(Vector2(0, 0), Vector2(20, 0))], Transform3D.IDENTITY)
	var high = kernel.sketch_wire([_k_line(Vector2(0, 5), Vector2(20, 10))], Transform3D(Basis.IDENTITY, Vector3(0, 0, 10 * MM)))
	var loft = kernel.loft([low, high], {"surface": true})
	var twisted = kernel.patch([{"shape": loft, "edges": PackedInt32Array(), "continuity": 0}], PackedVector3Array(), {"tag": "p"})
	_close(twisted.area() / MM2 if twisted != null else -1.0, loft.area() / MM2, 1e-4, "A patch of a twisted loop spans its lofted sheet (area)")
	if twisted != null:
		var tool = kernel.plane_face(Vector3(12 * MM, 0, 0), Vector3(1, 0, 0), 0.1, "tool")
		var cut = kernel.trim(twisted, tool, PackedVector3Array([Vector3(18, 4.75, 5) * MM]), {})
		_expect(cut != null and cut.area() < twisted.area() * 0.8, "Trimming the twisted patch's end should take area away (%s)." % kernel.get_last_error())
		if cut != null:
			var back = kernel.untrim(cut, PackedInt32Array([0]), PackedInt32Array(), {"mode": "all", "extend": 0.0})
			_close(back.area() / MM2 if back != null else -1.0, twisted.area() / MM2, 1e-6, "Untrim All gives the trimmed twisted patch its area back")
	# Three sides: flat, an exact plane; bent (one side a half circle standing up off the others'
	# plane), a Coons patch collapsed at one corner.
	var triangle = kernel.sketch_wire([_k_line(Vector2(0, 0), Vector2(10, 0)), _k_line(Vector2(10, 0), Vector2(0, 10)), _k_line(Vector2(0, 10), Vector2(0, 0))], Transform3D.IDENTITY)
	var flat = kernel.patch([{"shape": triangle, "edges": PackedInt32Array(), "continuity": 0}], PackedVector3Array(), {"tag": "p"})
	_expect(flat != null and str(flat.face_info(0).type) == "plane", "A flat three-sided loop should patch as a plane.")
	var standing = kernel.sketch_edges([_k_arc(Vector2(5, 0), 5, 0.0, PI)], Transform3D(Basis(Vector3(0, 1, 0), Vector3(0, 0, 1), Vector3(1, 0, 0)), Vector3.ZERO))
	var legs = kernel.sketch_edges([_k_line(Vector2(0, 0), Vector2(10, 0)), _k_line(Vector2(10, 0), Vector2(0, 10))], Transform3D.IDENTITY)
	var bent = kernel.patch([{"shape": kernel.make_compound([legs, standing]), "edges": PackedInt32Array(), "continuity": 0}], PackedVector3Array(), {"tag": "p"})
	_expect(bent != null and bent.face_count() == 1 and _k_fills_box(bent) and (bent.bbox() as AABB).size.z > 4.9 * MM,
		"A bent three-sided loop should patch as one face filling its surface (%s)." % kernel.get_last_error())


## A2, A5, A7, A9: a plate patch (five sides, points or rails) has no natural boundary past its
## edges: Untrim All and External refuse it (also once trimmed), a hole in it still untrims. G1
## over a hole through a plate carries on from the plate's top however the plate was made. A rail
## is followed. G2 is no longer offered, and a document that stored it is refused.
func _check_round2_plates() -> void:
	var plate = kernel.patch([{"shape": _k_loop3([Vector3(10, 0, 3), Vector3(3.09, 9.51, 0), Vector3(-8.09, 5.88, 0), Vector3(-8.09, -5.88, 0), Vector3(3.09, -9.51, 0)]),
		"edges": PackedInt32Array(), "continuity": 0}], PackedVector3Array(), {"tag": "p"})
	_expect(plate != null and plate.face_count() == 1, "A five-sided patch should build (%s)." % kernel.get_last_error())
	if plate != null:
		for mode in ["all", "outer"]:
			_k_refused(kernel.untrim(plate, PackedInt32Array([0]), PackedInt32Array(), {"mode": mode, "extend": 0.0}), "no natural boundary beyond its edges", "Untrim (%s) of a plate patch" % mode)
		var center: Vector3 = kernel.closest_points(plate, kernel.make_vertex(Vector3(0, 0, 10) * MM)).a
		var drill = kernel.make_cylinder(2 * MM, 20 * MM, Vector3(0, 0, -10) * MM, Vector3(0, 0, 1), "drill")
		var holed = kernel.trim(plate, drill, PackedVector3Array([center]), {})
		_expect(holed != null and holed.area() < plate.area() - 12.0 * MM2, "A hole should trim out of the plate patch (%s)." % kernel.get_last_error())
		if holed != null:
			_k_refused(kernel.untrim(holed, PackedInt32Array([0]), PackedInt32Array(), {"mode": "all", "extend": 0.0}), "no natural boundary", "Untrim All of the holed plate patch")
			var healed = kernel.untrim(holed, PackedInt32Array([0]), PackedInt32Array(), {"mode": "inner", "extend": 0.0})
			_close(healed.area() / MM2 if healed != null else -1.0, plate.area() / MM2, 1e-6, "Untrim Internal closes the plate patch's hole")
	# G1 over a hole through a plate: flush with its top, whichever face OCCT lists first.
	var block = kernel.make_box(Vector3(40, 40, 5) * MM, Vector3(-20, -20, 0) * MM, "plate")
	var drilled = kernel.boolean(block, kernel.make_cylinder(5 * MM, 20 * MM, Vector3(0, 0, -5) * MM, Vector3(0, 0, 1), "drill"), 1, "cut")
	var extruded = kernel.extrude(_k_region(_k_square(20.0) + [_k_circle(Vector2.ZERO, 5)], 1600.0 - PI * 25.0), {"direction": Vector3(0, 0, 1), "distance": 5 * MM})
	for spec in [[drilled, "a cylinder cut out of a box"], [extruded, "an extruded holed profile"]]:
		var body: RefCounted = spec[0]
		var hole_rim := _k_edges(body, func(info: Dictionary) -> bool: return str(info.type) == "circle" and absf((info.midpoint as Vector3).z - 5 * MM) < 1e-7)
		var hole_cap = kernel.patch([{"shape": body, "edges": hole_rim, "continuity": 1}], PackedVector3Array(), {"tag": "p"})
		_expect(hole_cap != null, "A G1 cap over the hole in %s should build (%s)." % [spec[1], kernel.get_last_error()])
		if hole_cap != null:
			for k in 4:
				for t in [0.25, 0.5, 0.75]:
					var a: float = TAU * (k + t) / 4.0
					var normal: Vector3 = hole_cap.face_normal_at(0, Vector3(cos(a), sin(a), 0) * 5 * MM + Vector3(0, 0, 5 * MM))
					_expect(absf(normal.z) > cos(deg_to_rad(1.0)), "The cap over the hole in %s should lie flush with the plate (normal %s at %.1f deg)." % [spec[1], normal, rad_to_deg(a)])
	# A rail arching over a 10 mm square to z = 3 mm: the patch runs along it.
	var c := -8.0 / 3.0
	var r := 3.0 - c
	var a0 := atan2(-c, 5.0)
	var rail = kernel.sketch_edges([_k_arc(Vector2(0, c), r, a0, PI - a0)], Transform3D(Basis(Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(0, -1, 0)), Vector3.ZERO))
	var railed = kernel.patch([{"shape": kernel.sketch_edges(_k_square(5.0), Transform3D.IDENTITY), "edges": PackedInt32Array(), "continuity": 0}], PackedVector3Array(),
		{"tag": "p", "rails": [{"shape": rail, "edges": PackedInt32Array()}]})
	_expect(railed != null, "A patch with a rail should build (%s)." % kernel.get_last_error())
	if railed != null:
		for t in [0.25, 0.5, 0.75]:
			var a: float = a0 + (PI - 2.0 * a0) * t
			var on_rail := Vector3(cos(a) * r, 0, c + sin(a) * r) * MM
			var gap: float = float(kernel.closest_points(railed, kernel.make_vertex(on_rail)).distance) / MM
			_expect(gap < 0.01, "The patch should pass within 0.01 mm of its rail at %s mm (%s mm)." % [on_rail / MM, gap])
	# G2 isn't offered; a stored G2 is refused for the curvature it can't reach.
	for field in SPECS.get_spec("surface:patch").fields:
		if field.key in ["continuity", "other_continuity"]:
			var offered: Array = (field.options as Array).map(func(option: Array) -> String: return option[0])
			_expect(offered == ["g0", "g1"], "Patch's %s should offer G0 and G1 only (%s)." % [field.key, offered])
	_new_doc()
	var cube := _box(Vector3.ZERO, 10, 10, 10)
	_rebuild()
	var stored := _surface("patch", {}, {"boundary": _edges_at_height(_body(cube), 0.01), "continuity": "g2"})
	_rebuild()
	_expect(str(result.errors.get(stored.id, "")).contains("curvature"), "A stored G2 patch should be refused for its curvature (%s)." % result.errors.get(stored.id, ""))


## A3: Untrim keeps a sheet joined: a face given its natural boundary is sewn back to its
## neighbours (an L sheet), and doesn't wrap round onto them (a two-arc sheet).
func _check_round2_untrim() -> void:
	var ell := _k_sheet([_k_line(Vector2(0, 0), Vector2(10, 0)), _k_line(Vector2(10, 0), Vector2(10, 10))], 10.0)
	var restored = kernel.untrim(ell, PackedInt32Array([0]), PackedInt32Array(), {"mode": "all", "extend": 0.0})
	_expect(restored != null and _k_open_shared(restored) == Vector2i(6, 1) and kernel.pieces(restored).size() == 1,
		"Untrim All on an L sheet's face should keep its seam (%s)." % [_k_open_shared(restored) if restored != null else kernel.get_last_error()])
	if restored != null:
		_close(restored.area() / MM2, 200.0, 1e-6, "The untrimmed L sheet (area)")
		var thick = kernel.thicken(restored, PackedInt32Array(), {"thickness": 1 * MM})
		_expect(thick != null and thick.solid_count() == 1, "The untrimmed L sheet should thicken into one solid (%s)." % kernel.get_last_error())
	var arcs := _k_sheet([_k_arc(Vector2.ZERO, 10, 0.0, PI / 2), _k_arc(Vector2(-10, 10), 10, 0.0, PI / 2)], 10.0)
	var kept = kernel.untrim(arcs, PackedInt32Array([0]), PackedInt32Array(), {"mode": "all", "extend": 0.0})
	_expect(kept != null and _k_open_shared(kept) == Vector2i(6, 1),
		"Untrim All on a two-arc sheet's face should keep its seam (%s)." % [_k_open_shared(kept) if kept != null else kernel.get_last_error()])


## A4, A6, A8: Extend stops short of a cone's apex or a sphere's pole (natural), and of where its
## strips' lines cross (tangent), saying how far it can go; Perpendicular adds a wall square to
## the face; Chain Selection takes a whole smooth rim from one pick; natural extension of an edge a
## trim made goes tangent and says so (a trimmed face's untouched edge carries its surface on).
func _check_round2_extend() -> void:
	var frustum := _k_spun([_k_line(Vector2(5, 10), Vector2(10, 0))])
	var small := _k_edges(frustum, func(info: Dictionary) -> bool: return absf((info.midpoint as Vector3).y - 10 * MM) < 1e-7)
	_k_refused(kernel.extend_surface(frustum, small, {"distance": 20 * MM, "mode": "natural"}), "apex (11.18 mm away)", "Extending a frustum's small rim 20 mm (its apex is 11.18 mm on)")
	_k_refused(kernel.extend_surface(frustum, small, {"distance": 20 * MM, "mode": "tangent"}), "(11.18 mm away)", "Extending it 20 mm tangent (its strip's lines cross at the apex)")
	var slant := sqrt(125.0)
	var shorter = kernel.extend_surface(frustum, small, {"distance": 5 * MM, "mode": "natural"})
	_close(shorter.area() / MM2 if shorter != null else -1.0, PI * (15.0 - 25.0 / slant) * (slant + 5.0), 1e-6, "A frustum's small rim extended 5 mm (area)")
	var zone := _k_spun([_k_arc(Vector2.ZERO, 10, 0.0, PI / 3)])
	var zone_top := _k_edges(zone, func(info: Dictionary) -> bool: return (info.midpoint as Vector3).y > 8 * MM)
	_k_refused(kernel.extend_surface(zone, zone_top, {"distance": 10 * MM, "mode": "natural"}), "pole (5.24 mm away)", "Extending a sphere zone's top rim 10 mm (its pole is 5.24 mm on)")
	var taller = kernel.extend_surface(zone, zone_top, {"distance": 3 * MM, "mode": "natural"})
	_close(taller.area() / MM2 if taller != null else -1.0, TAU * 100.0 * sin(PI / 3.0 + 0.3), 1e-6, "A sphere zone's top rim extended 3 mm (area)")
	# Perpendicular: a 5 mm wall square to a flat sheet along its 16 mm edge.
	var sheet := _k_sheet([_k_line(Vector2(0, 0), Vector2(16, 0))], 12.0)
	var top_edge := _k_edges(sheet, func(info: Dictionary) -> bool: return absf((info.midpoint as Vector3).z - 12 * MM) < 1e-7)
	var walled = kernel.extend_surface(sheet, top_edge, {"distance": 5 * MM, "mode": "perpendicular"})
	_close(walled.area() / MM2 if walled != null else -1.0, 192.0 + 80.0, 1e-6, "A perpendicular extension of a 16 mm edge by 5 mm (area)")
	if walled != null:
		_expect(walled.face_count() == 2 and absf((walled.bbox() as AABB).size.y - 5 * MM) < 1e-9, "The perpendicular extension should stand 5 mm square off the sheet (%s)." % walled.bbox())
	# Chain Selection: one pick on a rounded rectangle's top rim takes all 8 of its smooth edges.
	var band := _k_sheet(_k_rounded(), 10.0)
	var rim := _k_edges(band, func(info: Dictionary) -> bool: return absf((info.midpoint as Vector3).z - 10 * MM) < 1e-7)
	_expect(rim.size() == 8, "The rounded band should have 8 top edges (%d)." % rim.size())
	var one := _k_edges(band, func(info: Dictionary) -> bool: return (info.midpoint as Vector3).is_equal_approx(Vector3(0, -5, 10) * MM))
	var chained = kernel.extend_surface(band, one, {"distance": 3 * MM, "mode": "natural", "chain": true})
	_close((chained.area() - band.area()) / MM2 if chained != null else -1.0, _ROUNDED_PERIMETER * 3.0, 1e-6, "Chained, one pick extends the whole rim by 3 mm (area added)")
	if chained != null:
		_expect(kernel.pieces(chained).size() == 1 and (chained.bbox() as AABB).size.z > 12.99 * MM, "The chained extension should stay one piece, 3 mm taller all round.")
	var single = kernel.extend_surface(band, one, {"distance": 3 * MM, "mode": "natural", "chain": false})
	_close((single.area() - band.area()) / MM2 if single != null else -1.0, 16.0 * 3.0, 1e-6, "Unchained, only the picked 16 mm edge extends (area added)")
	# A face its surface fills but for a hole still carries on naturally, hole and all.
	var quarter := _k_sheet([_k_arc(Vector2.ZERO, 10, 0.0, PI / 2)], 10.0)
	var through := Vector3(cos(PI / 4), sin(PI / 4), 0)
	var drill = kernel.make_cylinder(2 * MM, 30 * MM, Vector3(0, 0, 5 * MM), through, "drill")
	var holed = kernel.trim(quarter, drill, PackedVector3Array([through * 10 * MM + Vector3(0, 0, 5 * MM)]), {})
	var side := _k_edges(holed, func(info: Dictionary) -> bool: return str(info.type) == "line" and absf((info.start as Vector3).x) < 1e-7) if holed != null else PackedInt32Array()
	var around = kernel.extend_surface(holed, side, {"distance": 5 * MM, "mode": "natural"}) if side.size() == 1 else null
	_expect(around != null and around.face_count() == 1 and str(around.face_info(0).type) == "cylinder" and kernel.get_last_warning() == "",
		"A holed face's straight edge should extend naturally round its cylinder, quietly (%s, %s)." % [kernel.get_last_error(), kernel.get_last_warning()])
	if around != null:
		_close((around.area() - holed.area()) / MM2, 50.0, 1e-6, "Extending a holed quarter cylinder 5 mm round (area added)")
	# On a face its surface doesn't fill (a quarter cylinder with a corner notch trimmed off) an edge
	# the trim made goes tangent, and the feature says so; its untouched bottom edge carries the
	# cylinder on (round 3: it used to go tangent too), and an untrimmed face says nothing.
	_new_doc()
	var arc_sketch: Resource = doc.add_feature("sketch", "Sketch", {}, SKETCH_DATA.new_options(SKETCH_DATA.ORIGIN_PLANES.xy, "xy"))
	var arcs = SKETCH_DATA.new(arc_sketch, doc)
	var notched_arc: int = arcs.add_arc(arcs.add_point(Vector2.ZERO), arcs.add_point(Vector2(0.01, 0)), arcs.add_point(Vector2(0, 0.01)))
	var plain_arc: int = arcs.add_arc(arcs.add_point(Vector2(0.1, 0)), arcs.add_point(Vector2(0.11, 0)), arcs.add_point(Vector2(0.1, 0.01)))
	var notched := _surface("extrude", {"distance": "10 mm"}, {"profiles": [{"kind": "sketch_curve", "sketch": arc_sketch.id, "entity": notched_arc}]})
	var whole := _surface("extrude", {"distance": "10 mm"}, {"profiles": [{"kind": "sketch_curve", "sketch": arc_sketch.id, "entity": plain_arc}]})
	# (A box stands on the middle of its base: x 4..14, y -5..5, z 6..16 mm, over the corner.)
	var notch := _box(Vector3(9, -5, 11), 10, 10, 10)
	var trim := _surface("trim", {}, {"tool": [{"kind": "body", "body": _body(notch)}], "remove": []})
	_rebuild()
	var corner := Vector3(cos(PI / 12), sin(PI / 12), 0.8) * 0.01
	var piece := _face_ref_at(_body(notched), corner)
	piece["at"] = corner
	trim.options["remove"] = [piece]
	_rebuild()
	_no_error(trim, "Trim a notch off a quarter cylinder")
	# (The notch's arc runs at z 6 mm from 0 to 30 deg round.)
	var fallback := _surface("extend", {"distance": "2 mm"}, {"edges": [_edge_ref_at(_body(notched), Vector3(cos(PI / 12) * 0.01, sin(PI / 12) * 0.01, 0.006))], "extend_type": "natural", "chain": false})
	var plain := _surface("extend", {"distance": "2 mm"}, {"edges": [_edge_ref_at(_body(whole), Vector3(0.1, 0, 0) + Vector3(cos(PI / 4), sin(PI / 4), 0) * 0.01)], "extend_type": "natural", "chain": false})
	_rebuild()
	_no_error(fallback, "A natural extend of a trimmed face's trimmed edge")
	_no_error(plain, "A natural extend of an untrimmed face")
	_expect(str(result.warnings.get(fallback.id, "")).contains("1 edge was extended tangentially (natural extension needs an untrimmed edge)"),
		"A natural extend that falls back should say so (%s)." % result.warnings.get(fallback.id, ""))
	_expect(not result.warnings.has(plain.id), "A natural extend of an untrimmed face should say nothing (%s)." % result.warnings.get(plain.id, ""))
	doc.remove_feature(fallback.id)
	_rebuild()
	var bottom := _surface("extend", {"distance": "2 mm"}, {"edges": [_edge_ref_at(_body(notched), Vector3(cos(PI / 4), sin(PI / 4), 0) * 0.01)], "extend_type": "natural", "chain": false})
	_rebuild()
	_no_error(bottom, "A natural extend of a trimmed face's untouched bottom edge")
	_expect(not result.warnings.has(bottom.id), "The untouched bottom edge should extend naturally, quietly (%s)." % result.warnings.get(bottom.id, ""))
	var notched_shape := _shape(_body(notched))
	_expect(notched_shape != null and notched_shape.face_count() == 1 and str(notched_shape.face_info(0).type) == "cylinder", "The bottom band should join the notched face on its cylinder (%s)." % [_k_kinds(notched_shape)])
	# The quarter cylinder (r 10, 10 tall) less its notch (30 deg by 4 mm), plus the 2 mm band.
	_close(_area(_body(notched)), 50.0 * PI - 40.0 * PI / 6.0 + 10.0 * PI, 1e-6, "A notched quarter cylinder with its bottom edge extended 2 mm naturally (area)")


const _ROUNDED_PERIMETER := 2.0 * 16.0 + 2.0 * 6.0 + TAU * 2.0


## A 20 x 10 mm rectangle with 2 mm round corners, as 8 sketch curves.
func _k_rounded() -> Array:
	return [_k_line(Vector2(-8, -5), Vector2(8, -5)), _k_arc(Vector2(8, -3), 2, -PI / 2, 0.0), _k_line(Vector2(10, -3), Vector2(10, 3)), _k_arc(Vector2(8, 3), 2, 0.0, PI / 2),
		_k_line(Vector2(8, 5), Vector2(-8, 5)), _k_arc(Vector2(-8, 3), 2, PI / 2, PI), _k_line(Vector2(-10, 3), Vector2(-10, -3)), _k_arc(Vector2(-8, -3), 2, PI, PI * 1.5)]


## New fields round-trip: a Patch with an Interior Rail and an Extend with Chain Selection (on by
## default) and each Extend Type, made by their commands, read back from the timeline, written and
## rebuilt, come out the same.
func _check_round2_commands() -> void:
	_new_doc()
	var square := _lines("xy", [[Vector2(-5, -5), Vector2(5, -5)], [Vector2(5, -5), Vector2(5, 5)], [Vector2(5, 5), Vector2(-5, 5)], [Vector2(-5, 5), Vector2(-5, -5)]])
	var arch: Resource = doc.add_feature("sketch", "Sketch", {}, SKETCH_DATA.new_options({"origin": Vector3.ZERO, "x": Vector3.RIGHT, "y": Vector3.BACK}, "frame"))
	var arch_data = SKETCH_DATA.new(arch, doc)
	var arc: int = arch_data.add_arc(arch_data.add_point(Vector2(0, -8.0 / 3.0) * MM), arch_data.add_point(Vector2(5, 0) * MM), arch_data.add_point(Vector2(-5, 0) * MM))
	var command = FEATURE_COMMAND.new("surface:patch")
	var values: Dictionary = command.defaults()
	values["boundary"] = _curves(square)
	values["rails"] = [{"kind": "sketch_curve", "sketch": arch.id, "entity": arc}]
	var patch: Resource = command.create_feature(doc, values)
	_rebuild()
	_no_error(patch, "A patch with a rail, made by its command")
	var area := _area(_body(patch))
	_expect(area > 101.0 and _shape(_body(patch)) != null and absf((_shape(_body(patch)).bbox() as AABB).size.z - 3 * MM) < 0.01 * MM,
		"The rail should lift the patch to 3 mm (area %s, box %s)." % [area, _shape(_body(patch)).bbox() if _shape(_body(patch)) != null else null])
	var edit = FEATURE_COMMAND.new("surface:patch")
	edit.feature = patch
	var read: Dictionary = edit.read_values()
	_expect((read.rails as Array).size() == 1 and int(read.rails[0].entity) == arc, "The rail should read back from the timeline (%s)." % [read.rails])
	edit.write_values(doc, read)
	_rebuild()
	_close(_area(_body(patch)), area, 1e-9, "The patch with its rail rebuilt after editing (area)")

	# The same rounded rectangle in a sketch (corners shared), extruded into a band.
	_new_doc()
	var band_sketch: Resource = doc.add_feature("sketch", "Sketch", {}, SKETCH_DATA.new_options(SKETCH_DATA.ORIGIN_PLANES.xy, "xy"))
	var band_data = SKETCH_DATA.new(band_sketch, doc)
	var points := {}
	var at := func(p: Vector2) -> int:
		if not points.has(p):
			points[p] = band_data.add_point(p * MM)
		return points[p]
	var ids := [
		band_data.add_line(at.call(Vector2(-8, -5)), at.call(Vector2(8, -5))), band_data.add_arc(at.call(Vector2(8, -3)), at.call(Vector2(8, -5)), at.call(Vector2(10, -3))),
		band_data.add_line(at.call(Vector2(10, -3)), at.call(Vector2(10, 3))), band_data.add_arc(at.call(Vector2(8, 3)), at.call(Vector2(10, 3)), at.call(Vector2(8, 5))),
		band_data.add_line(at.call(Vector2(8, 5)), at.call(Vector2(-8, 5))), band_data.add_arc(at.call(Vector2(-8, 3)), at.call(Vector2(-8, 5)), at.call(Vector2(-10, 3))),
		band_data.add_line(at.call(Vector2(-10, 3)), at.call(Vector2(-10, -3))), band_data.add_arc(at.call(Vector2(-8, -3)), at.call(Vector2(-10, -3)), at.call(Vector2(-8, -5))),
	]
	var band := _surface("extrude", {"distance": "10 mm"}, {"profiles": ids.map(func(id: int) -> Dictionary: return {"kind": "sketch_curve", "sketch": band_sketch.id, "entity": id})})
	_rebuild()
	var before := _area(_body(band))
	var extend_command = FEATURE_COMMAND.new("surface:extend")
	var extend_values: Dictionary = extend_command.defaults()
	_expect(bool(extend_values.get("chain", false)), "Chain Selection should be on by default.")
	extend_values["edges"] = [_edge_ref_at(_body(band), Vector3(0, -0.005, 0.01))]
	extend_values["distance"] = "1.5"
	for type in ["natural", "tangent", "perpendicular"]:
		extend_values["extend_type"] = type
		var extend: Resource = extend_command.create_feature(doc, extend_values)
		_rebuild()
		_no_error(extend, "A chained %s extend made by its command" % type)
		var grown := _area(_body(band))
		if type != "perpendicular":
			_close(grown - before, _ROUNDED_PERIMETER * 1.5, 1e-6, "A chained %s extend of the rounded rim by 1.5 mm (area added)" % type)
		else:
			_expect(grown - before > 16.0 * 1.5 * 2.0, "A chained perpendicular extend should flange the whole rim (added %s mm2)." % (grown - before))
		var reader = FEATURE_COMMAND.new("surface:extend")
		reader.feature = extend
		var back: Dictionary = reader.read_values()
		_expect(bool(back.chain) and str(back.extend_type) == type, "Chain and %s should read back from the timeline (%s, %s)." % [type, back.chain, back.extend_type])
		reader.write_values(doc, back)
		_rebuild()
		_close(_area(_body(band)), grown, 1e-9, "The chained %s extend rebuilt after editing (area)" % type)
		doc.remove_feature(extend.id)
		extend_command = FEATURE_COMMAND.new("surface:extend")


# --- Round 2, part B: loft, taper, thicken, ruled, trim, replace face, press pull ------------------

## The sketch region of the curves (mm, on the plane) with this area (mm2).
func _k_region_at(curves: Array, area_mm2: float, plane: Transform3D) -> RefCounted:
	for region in kernel.sketch_regions(curves, plane, 0.0):
		if absf(float(region.area) / MM2 - area_mm2) < maxf(area_mm2 * 2e-3, 1e-3):
			return region.face
	return null


## The faces' kinds (face_info types) of a shape, sorted, once each.
func _k_kinds(shape: RefCounted) -> Array:
	var kinds := []
	for f in shape.face_count() if shape != null else 0:
		if not kinds.has(str(shape.face_info(f).type)):
			kinds.append(str(shape.face_info(f).type))
	kinds.sort()
	return kinds


## The volume of a body (mm3), -1 when it is missing.
func _volume(body_id: String) -> float:
	return _shape(body_id).volume() / MM3 if _shape(body_id) != null else -1.0


## B1: Loft lofts every loop: two annuli give both walls (surface) or a tube (solid, its caps named),
## two discs a section give two solids, and profiles that don't match are refused; the Loft feature
## (solid and surface) keeps a profile's hole. B10: one rail is followed exactly: an S through a
## corner of each square that meets them off square (the old centerline loft turned the squares to
## it and missed it by 1.45 mm); loops the rail doesn't touch (a hole, another disc) ride along.
func _check_round2_loft() -> void:
	var up := Transform3D(Basis.IDENTITY, Vector3(0, 0, 10 * MM))
	var annulus := [_k_circle(Vector2.ZERO, 10), _k_circle(Vector2.ZERO, 5)]
	var low := _k_region_at(annulus, PI * 75.0, Transform3D.IDENTITY)
	var high := _k_region_at(annulus, PI * 75.0, up)
	var walls = kernel.loft([low, high], {"surface": true})
	_close(walls.area() / MM2 if walls != null else -1.0, TAU * 15.0 * 10.0, 1e-6, "A surface loft of two r 10 / 5 mm annuli makes both walls (area)")
	var tube = kernel.loft([low, high], {"tag": "L"})
	_close(tube.volume() / MM3 if tube != null else -1.0, PI * 75.0 * 10.0, 1e-6, "A solid loft of two annuli keeps the hole (volume)")
	if tube != null:
		_expect(tube.find_face("L:start") >= 0 and tube.find_face("L:end") >= 0, "The lofted tube's ends should keep their names (%s)." % [tube.get_face_names()])
	var pair_low = kernel.make_compound([_k_region_at([_k_circle(Vector2(-10, 0), 3)], PI * 9.0, Transform3D.IDENTITY), _k_region_at([_k_circle(Vector2(10, 0), 3)], PI * 9.0, Transform3D.IDENTITY)])
	var pair_high = kernel.make_compound([_k_region_at([_k_circle(Vector2(12, 0), 2)], PI * 4.0, up), _k_region_at([_k_circle(Vector2(-8, 0), 2)], PI * 4.0, up)])
	var two = kernel.loft([pair_low, pair_high], {})
	_expect(two != null and two.solid_count() == 2, "Two discs a section should loft into two solids (%s)." % kernel.get_last_error())
	_close(two.volume() / MM3 if two != null else -1.0, 2.0 * PI * 10.0 / 3.0 * (9.0 + 6.0 + 4.0), 1e-6, "Two r 3 mm discs lofted to the r 2 mm ones above them (volume)")
	var disc := _k_region_at([_k_circle(Vector2.ZERO, 10)], PI * 100.0, up)
	_k_refused(kernel.loft([low, disc], {}), "same holes", "A loft from an annulus to a disc")
	_k_refused(kernel.loft([pair_low, disc], {}), "separate pieces", "A loft from two discs to one")
	# One rail that touches only the outer circle (x 10 mm, z 0..10): the hole rides along with it;
	# of two discs a section it touches one, and the other rides along too.
	var xz := Transform3D(Basis(Vector3(0, 0, 1), Vector3(1, 0, 0), Vector3(0, 1, 0)), Vector3.ZERO)
	var outer_rail = kernel.sketch_wire([_k_line(Vector2(0, 10), Vector2(10, 10))], xz)
	var railed_tube = kernel.loft([low, high], {"rail": outer_rail, "tag": "R"})
	_close(railed_tube.volume() / MM3 if railed_tube != null else -1.0, PI * 75.0 * 10.0, 1e-6, "Two annuli lofted along a rail on the outer circle keep the hole (volume; %s)" % kernel.get_last_error())
	if railed_tube != null:
		_expect(railed_tube.find_face("R:start") >= 0 and railed_tube.find_face("R:end") >= 0, "The railed tube's ends should be named as a loft's are (%s)." % [railed_tube.get_face_names()])
	var railed_walls = kernel.loft([low, high], {"rail": outer_rail, "surface": true})
	_close(railed_walls.area() / MM2 if railed_walls != null else -1.0, TAU * 15.0 * 10.0, 1e-6, "A surface loft of two annuli along that rail makes both walls (area)")
	var pair_up = kernel.make_compound([_k_region_at([_k_circle(Vector2(-10, 0), 3)], PI * 9.0, up), _k_region_at([_k_circle(Vector2(10, 0), 3)], PI * 9.0, up)])
	var side_rail = kernel.sketch_wire([_k_line(Vector2(0, 13), Vector2(10, 13))], xz)
	var railed_pair = kernel.loft([pair_low, pair_up], {"rail": side_rail})
	_expect(railed_pair != null and railed_pair.solid_count() == 2, "Two discs a section along a rail touching one should loft into two solids (%s)." % kernel.get_last_error())
	_close(railed_pair.volume() / MM3 if railed_pair != null else -1.0, 2.0 * PI * 9.0 * 10.0, 1e-6, "Two r 3 mm discs lofted 10 mm along a rail touching one (volume)")
	# Open curves (half circles) along a rail through their far ends: placed where it touches them.
	var arc_low = kernel.sketch_wire([_k_arc(Vector2.ZERO, 10, 0.0, PI)], Transform3D.IDENTITY)
	var arc_high = kernel.sketch_wire([_k_arc(Vector2.ZERO, 10, 0.0, PI)], up)
	var end_rail = kernel.sketch_wire([_k_line(Vector2(0, -10), Vector2(10, -10))], xz)
	var half_tube = kernel.loft([arc_low, arc_high], {"rail": end_rail, "surface": true})
	_close(half_tube.area() / MM2 if half_tube != null else -1.0, PI * 10.0 * 10.0, 1e-6, "Two half circles lofted along a rail through their ends (area; %s)" % kernel.get_last_error())
	if half_tube != null:
		var gap := 0.0
		for i in 11:
			gap = maxf(gap, float(kernel.closest_points(half_tube, kernel.make_vertex(end_rail.edge_point_at(0, i / 10.0).point)).distance))
		_expect(gap < 1e-3 * MM, "The half-circle loft should run along its rail (gap %s mm)." % (gap / MM))
	_new_doc()
	var sections := []
	for z in [0.0, 0.01]:
		var holder: Resource = doc.add_feature("sketch", "Sketch", {}, SKETCH_DATA.new_options({"origin": Vector3(0, 0, z), "x": Vector3.RIGHT, "y": Vector3.UP}, "frame"))
		var data = SKETCH_DATA.new(holder, doc)
		var center: int = data.add_point(Vector2.ZERO)
		data.add_circle(center, 0.01)
		data.add_circle(center, 0.005)
		sections.append({"kind": "profile", "sketch": holder.id, "point": Vector2(0.0075, 0)})
	var solid_loft := _add("loft", {}, {"sections": sections, "operation": OPERATIONS.NEW_BODY})
	var surface_loft := _surface("loft", {}, {"sections": sections})
	_rebuild()
	_no_error(solid_loft, "Loft of two annulus profiles")
	_no_error(surface_loft, "Surface Loft of two annulus profiles")
	_close(_volume(_body(solid_loft)), PI * 75.0 * 10.0, 1e-6, "The Loft feature keeps the profiles' hole (volume)")
	_close(_area(_body(surface_loft)), TAU * 15.0 * 10.0, 1e-6, "The Surface Loft feature makes both walls (area)")

	# B10: squares at z = 0 and 40 mm (the far one 30 mm over in X), an S of two r 36.5 mm arcs
	# from the near one's corner to the far one's, 16.87 deg off square at both ends.
	_new_doc()
	var square := [[Vector2(0, 0), Vector2(10, 0)], [Vector2(10, 0), Vector2(10, 10)], [Vector2(10, 10), Vector2(0, 10)], [Vector2(0, 10), Vector2(0, 0)]]
	var near := _lines("xy", square)
	var far := _lines({"origin": Vector3(0.03, 0, 0.04), "x": Vector3.RIGHT, "y": Vector3.UP}, square)
	var rail_sketch: Resource = doc.add_feature("sketch", "Sketch", {}, SKETCH_DATA.new_options({"origin": Vector3.ZERO, "x": Vector3.BACK, "y": Vector3.RIGHT}, "frame"))
	var rs = SKETCH_DATA.new(rail_sketch, doc)
	var start_angle := atan2(15.0, 20.0) - deg_to_rad(20.0)
	var radius := 12.5 / sin(deg_to_rad(20.0))
	var c1 := Vector2(-sin(start_angle), cos(start_angle)) * radius
	var c2 := Vector2(40, 30) - c1
	var middle: int = rs.add_point(Vector2(20, 15) * MM)
	var first: int = rs.add_arc(rs.add_point(c1 * MM), rs.add_point(Vector2.ZERO), middle)
	var second: int = rs.add_arc(rs.add_point(c2 * MM), rs.add_point(Vector2(40, 30) * MM), middle)
	var rails := [{"kind": "sketch_curve", "sketch": rail_sketch.id, "entity": first}, {"kind": "sketch_curve", "sketch": rail_sketch.id, "entity": second}]
	var profiles := [{"kind": "profile", "sketch": near.feature.id, "point": Vector2(0.005, 0.005)}, {"kind": "profile", "sketch": far.feature.id, "point": Vector2(0.005, 0.005)}]
	var railed := _add("loft", {}, {"sections": profiles, "rails": rails, "operation": OPERATIONS.NEW_BODY})
	_rebuild()
	_no_error(railed, "Loft along one S rail")
	var lofted := _shape(_body(railed))
	if lofted != null:
		var worst := 0.0
		for arc in [[c1, Vector2.ZERO, Vector2(20, 15)], [c2, Vector2(40, 30), Vector2(20, 15)]]:
			var center: Vector2 = arc[0]
			var a0: float = (arc[1] - center).angle()
			var a1: float = (arc[2] - center).angle()
			for i in 21:
				var on: Vector2 = center + Vector2.from_angle(lerp_angle(a0, a1, i / 20.0)) * radius
				worst = maxf(worst, float(kernel.closest_points(lofted, kernel.make_vertex(Vector3(on.y, 0, on.x) * MM)).distance))
		_expect(worst < 1e-3 * MM, "A loft along one rail should pass within 0.001 mm of every rail sample (worst %s mm)." % (worst / MM))
		_expect(lofted.solid_count() == 1, "The railed loft should be one solid.")
	var rail_field: Dictionary = (SPECS.get_spec("loft").fields as Array).filter(func(f: Dictionary) -> bool: return f.key == "rails")[0]
	_expect(str(rail_field.label).contains("one exactly"), "Loft's rail field should say one rail is followed exactly (%s)." % rail_field.label)


## B2: tapered walls of straight edges are planes and of arcs cones, solid and surface, with exact
## volumes and the caps' names (holes too); a sketch goes on a tapered side face. B3: open curves
## taper too, leaning to their left seen from the far end (right for a negative angle), with planar
## walls sharing their corner edge.
func _check_round2_taper() -> void:
	var taper := deg_to_rad(5.0)
	var s := 10.0 * tan(taper)
	var rect := _k_region([_k_line(Vector2(0, 0), Vector2(20, 0)), _k_line(Vector2(20, 0), Vector2(20, 10)), _k_line(Vector2(20, 10), Vector2(0, 10)), _k_line(Vector2(0, 10), Vector2(0, 0))], 200.0)
	var block = kernel.extrude(rect, {"direction": Vector3(0, 0, 1), "distance": 10 * MM, "taper": taper, "tag": "t"})
	var sides = kernel.extrude(rect, {"direction": Vector3(0, 0, 1), "distance": 10 * MM, "taper": taper, "surface": true, "tag": "t"})
	_expect(_k_kinds(block) == ["plane"] and _k_kinds(sides) == ["plane"], "A tapered rectangle's faces should all be planes (solid %s, surface %s)." % [_k_kinds(block), _k_kinds(sides)])
	_close(block.volume() / MM3 if block != null else -1.0, 10.0 / 6.0 * (200.0 + 4.0 * (20.0 - s) * (10.0 - s) + (20.0 - 2.0 * s) * (10.0 - 2.0 * s)), 1e-6, "A tapered 20 x 10 mm rectangle (prismatoid volume)")
	_close(sides.area() / MM2 if sides != null else -1.0, (120.0 - 8.0 * s) / 2.0 * 10.0 / cos(taper), 1e-6, "A tapered rectangle's walls (area)")
	var holed := _k_region(_k_square(15.0) + _k_square(5.0), 800.0)
	var framed = kernel.extrude(holed, {"direction": Vector3(0, 0, 1), "distance": 10 * MM, "taper": taper, "tag": "h"})
	_expect(_k_kinds(framed) == ["plane"], "A tapered holed square's faces should all be planes (%s)." % [_k_kinds(framed)])
	_close(framed.volume() / MM3 if framed != null else -1.0, 10.0 / 6.0 * (900.0 + 4.0 * pow(30.0 - s, 2) + pow(30.0 - 2.0 * s, 2)) - 10.0 / 6.0 * (100.0 + 4.0 * pow(10.0 + s, 2) + pow(10.0 + 2.0 * s, 2)), 1e-6, "A tapered holed square (volume)")
	if framed != null:
		_expect(framed.find_face("h:start") >= 0 and framed.find_face("h:end") >= 0, "A tapered holed profile's caps should keep their names through the hole's cut (%s)." % [framed.get_face_names()])
	var round_wall = kernel.extrude(_k_region([_k_circle(Vector2.ZERO, 10)], PI * 100.0), {"direction": Vector3(0, 0, 1), "distance": 10 * MM, "taper": taper, "surface": true})
	_expect(_k_kinds(round_wall) == ["cone"], "A tapered circle's wall should be a cone (%s)." % [_k_kinds(round_wall)])
	# A hexagon turned off the axes (r 10 mm): every wall flat too, the frustum's volume exact.
	var corners := []
	for k in 6:
		corners.append(Vector2.from_angle(deg_to_rad(15.0 + 60.0 * k)) * 10.0)
	var sides6 := []
	for k in 6:
		sides6.append(_k_line(corners[k], corners[(k + 1) % 6]))
	var hexagon := _k_region(sides6, 150.0 * sqrt(3.0))
	var shrink := (5.0 * sqrt(3.0) - s) / (5.0 * sqrt(3.0))
	var hex_block = kernel.extrude(hexagon, {"direction": Vector3(0, 0, 1), "distance": 10 * MM, "taper": taper})
	var hex_walls = kernel.extrude(hexagon, {"direction": Vector3(0, 0, 1), "distance": 10 * MM, "taper": taper, "surface": true})
	_expect(_k_kinds(hex_block) == ["plane"] and _k_kinds(hex_walls) == ["plane"], "A tapered hexagon turned off the axes should have only flat faces (solid %s, surface %s)." % [_k_kinds(hex_block), _k_kinds(hex_walls)])
	var base_area := 150.0 * sqrt(3.0)
	_close(hex_block.volume() / MM3 if hex_block != null else -1.0, 10.0 / 3.0 * base_area * (1.0 + shrink + shrink * shrink), 1e-6, "A tapered hexagon (frustum volume)")
	_close(hex_walls.area() / MM2 if hex_walls != null else -1.0, 6.0 * (10.0 + 10.0 * shrink) / 2.0 * 10.0 / cos(taper), 1e-6, "A tapered hexagon's walls (area)")
	# A sketch on a tapered side face, and a 1 mm boss extruded from it.
	_new_doc()
	var base := _lines("xy", [[Vector2(0, 0), Vector2(20, 0)], [Vector2(20, 0), Vector2(20, 10)], [Vector2(20, 10), Vector2(0, 10)], [Vector2(0, 10), Vector2(0, 0)]])
	var tapered := _add("extrude", {"distance": "10 mm", "taper": ["5 deg", "angle"]}, {"profiles": [{"kind": "profile", "sketch": base.feature.id, "point": Vector2(0.01, 0.005)}], "operation": OPERATIONS.NEW_BODY})
	_rebuild()
	_no_error(tapered, "A tapered extrude")
	var solid := _shape(_body(tapered))
	var side := -1
	for f in solid.face_count() if solid != null else 0:
		var info: Dictionary = solid.face_info(f)
		if info.get("planar", false) and absf((info.normal as Vector3).z) < 0.99 and absf((info.normal as Vector3).y) > 0.5:
			side = f
	_expect(side >= 0, "A tapered extrude's side face should be flat.")
	if side >= 0:
		var info: Dictionary = solid.face_info(side)
		var on_side: Resource = doc.add_feature("sketch", "Sketch", {}, SKETCH_DATA.new_options(SKETCH_DATA.face_plane(info.point, info.normal), "face:%s:%d" % [_body(tapered), side]))
		var data = SKETCH_DATA.new(on_side, doc)
		data.add_circle(data.add_point(Vector2.ZERO), 0.001)
		var boss := _add("extrude", {"distance": "1 mm"}, {"profiles": [{"kind": "profile", "sketch": on_side.id, "point": Vector2.ZERO}], "operation": OPERATIONS.NEW_BODY})
		_rebuild()
		_no_error(boss, "An extrude from a sketch on a tapered side face")
		_close(_volume(_body(boss)), PI, 1e-6, "A 1 mm boss on a tapered side face (volume)")

	# B3: a 20 mm line extruded 10 mm at +-10 deg: one planar wall, its top edge 10 tan 10 deg to the
	# line's left (+Y, seen from +Z) or right.
	var lean := 10.0 * tan(deg_to_rad(10.0))
	var line = kernel.sketch_edges([_k_line(Vector2(0, 0), Vector2(20, 0))], Transform3D.IDENTITY)
	for degrees in [10.0, -10.0]:
		var wall = kernel.extrude(line, {"direction": Vector3(0, 0, 1), "distance": 10 * MM, "taper": deg_to_rad(degrees), "surface": true})
		_expect(wall != null and wall.face_count() == 1 and _k_kinds(wall) == ["plane"], "A line tapered %s deg should be one planar wall (%s)." % [degrees, kernel.get_last_error()])
		_close(wall.area() / MM2 if wall != null else -1.0, 200.0 / cos(deg_to_rad(10.0)), 1e-6, "A 20 mm line extruded 10 mm at %s deg (area)" % degrees)
		var top := _k_edges(wall, func(info: Dictionary) -> bool: return absf((info.midpoint as Vector3).z - 10 * MM) < 1e-7) if wall != null else PackedInt32Array()
		var y: float = (wall.edge_info(top[0]).midpoint as Vector3).y / MM if top.size() == 1 else INF
		_expect(absf(y - signf(degrees) * lean) < 1e-6, "The %s deg wall's top edge should sit %.4f mm to the %s (at y %s mm)." % [degrees, lean, "left" if degrees > 0.0 else "right", y])
	var ell = kernel.sketch_edges([_k_line(Vector2(0, 0), Vector2(20, 0)), _k_line(Vector2(20, 0), Vector2(20, 10))], Transform3D.IDENTITY)
	var bent = kernel.extrude(ell, {"direction": Vector3(0, 0, 1), "distance": 10 * MM, "taper": deg_to_rad(10.0), "surface": true})
	_expect(bent != null and bent.face_count() == 2 and _k_kinds(bent) == ["plane"] and _k_open_shared(bent).y == 1, "A tapered L polyline should be two planar walls sharing an edge (%s)." % kernel.get_last_error())
	# Its walls lean into the bend: cut back to where their tops meet.
	_close(bent.area() / MM2 if bent != null else -1.0, (30.0 - lean) * 10.0 / cos(deg_to_rad(10.0)), 1e-6, "A tapered L polyline (area)")
	_new_doc()
	var drawn := _lines("xy", [[Vector2(0, 0), Vector2(20, 0)]])
	var leaning := _surface("extrude", {"distance": "10 mm", "taper": ["10 deg", "angle"]}, {"profiles": [_curve(drawn)]})
	_rebuild()
	_no_error(leaning, "A tapered surface extrude of a sketch line")
	_close(_area(_body(leaning)), 200.0 / cos(deg_to_rad(10.0)), 1e-6, "The tapered surface extrude of a sketch line (area)")
	var taper_field: Dictionary = (SPECS.get_spec("surface:extrude").fields as Array).filter(func(f: Dictionary) -> bool: return f.key == "taper")[0]
	_expect(str(taper_field.label).contains("lean left"), "Surface Extrude's taper label should say how open curves lean (%s)." % taper_field.label)


## B4: Thicken refuses what it can't build (growing past a radius of curvature, a cone's apex) and
## gives exact volumes otherwise, on the side asked (a cone band too). B5: Rounded rounds a convex
## seam over; Sharp mitres it as before.
func _check_round2_thicken() -> void:
	var quarter := _k_sheet([_k_arc(Vector2.ZERO, 10, 0.0, PI / 2)], 10.0)
	var toward: Vector3 = quarter.face_normal_at(0, Vector3(7.07, 7.07, 5) * MM)
	var inward := 1.0 if toward.dot(Vector3(-1, -1, 0)) > 0.0 else -1.0
	_k_refused(kernel.thicken(quarter, PackedInt32Array(), {"thickness": inward * 15 * MM}), "curves too tightly", "Thickening an r 10 mm quarter tube 15 mm toward its axis")
	_k_refused(kernel.thicken(quarter, PackedInt32Array(), {"thickness": 24 * MM, "symmetric": true}), "curves too tightly", "Thickening it 24 mm symmetric")
	var hollow = kernel.thicken(quarter, PackedInt32Array(), {"thickness": inward * 5 * MM})
	_close(hollow.volume() / MM3 if hollow != null else -1.0, PI / 4.0 * (100.0 - 25.0) * 10.0, 1e-6, "The quarter tube thickened 5 mm toward its axis (volume)")
	var ball := _k_spun([_k_arc(Vector2.ZERO, 10, -PI / 2, PI / 2)])
	var into := -1.0 if (ball.face_normal_at(0, Vector3(10, 0, 0) * MM) as Vector3).x > 0.0 else 1.0
	_k_refused(kernel.thicken(ball, PackedInt32Array(), {"thickness": into * 12 * MM}), "curves too tightly", "Thickening an r 10 mm sphere 12 mm inward")
	var shell = kernel.thicken(ball, PackedInt32Array(), {"thickness": into * 3 * MM})
	_close(shell.volume() / MM3 if shell != null else -1.0, 4.0 / 3.0 * PI * (1000.0 - 343.0), 1e-6, "The sphere thickened 3 mm inward (volume)")
	var cone := _k_spun([_k_line(Vector2(0, 10), Vector2(10, 0))])
	_k_refused(kernel.thicken(cone, PackedInt32Array(), {"thickness": 1 * MM, "symmetric": true}), "sharp point", "Thickening a cone with an apex, symmetric")
	_k_refused(kernel.thicken(cone, PackedInt32Array(), {"thickness": 1 * MM}), "sharp point", "Thickening a cone with an apex")
	# A cone band (r 5..10 mm over 10 mm) grows 1 mm the side asked (OCCT's simple offset goes the
	# other way): A t -+ t^2/2 times its integral of curvature, 20 pi, toward / away from its axis.
	var band := _k_spun([_k_line(Vector2(5, 10), Vector2(10, 0))])
	var axis_way := 1.0 if (band.face_normal_at(0, Vector3(7.5, 5, 0) * MM) as Vector3).x < 0.0 else -1.0
	var lateral := PI * 15.0 * sqrt(125.0)
	for way in [1.0, -1.0]:
		var thick_band = kernel.thicken(band, PackedInt32Array(), {"thickness": way * axis_way * MM})
		_close(thick_band.volume() / MM3 if thick_band != null else -1.0, lateral - way * 10.0 * PI, 1e-6, "A cone band thickened 1 mm %s its axis (volume; %s)" % ["toward" if way > 0.0 else "away from", kernel.get_last_error()])
	# B5: an L sheet of two 10 x 10 mm faces, thickened 2 mm to the outside of its bend.
	var ell := _k_sheet([_k_line(Vector2(0, 0), Vector2(10, 0)), _k_line(Vector2(10, 0), Vector2(10, 10))], 10.0)
	var inner := 0
	for f in ell.face_count():
		if absf((ell.face_info(f).point as Vector3).y) < 1e-9:
			inner = f
	var outside := -1.0 if (ell.face_normal_at(inner, ell.face_info(inner).point) as Vector3).y > 0.0 else 1.0
	var sharp = kernel.thicken(ell, PackedInt32Array(), {"thickness": outside * 2 * MM, "type": "sharp"})
	var rounded = kernel.thicken(ell, PackedInt32Array(), {"thickness": outside * 2 * MM, "type": "rounded"})
	_close(sharp.volume() / MM3 if sharp != null else -1.0, 440.0, 1e-6, "An L sheet thickened 2 mm outside, Sharp (the 2 x 2 x 10 mm corner block mitred in)")
	_close(rounded.volume() / MM3 if rounded != null else -1.0, 400.0 + 10.0 * PI, 1e-6, "An L sheet thickened 2 mm outside, Rounded (a quarter cylinder for the corner block)")
	# Made by its command, Thicken Type reads back from the timeline and rebuilds the same.
	_new_doc()
	var bend := _lines("xy", [[Vector2(0, 0), Vector2(10, 0)], [Vector2(10, 0), Vector2(10, 10)]])
	var sheet := _surface("extrude", {"distance": "10 mm"}, {"profiles": _curves(bend)})
	_rebuild()
	var walls := _shape(_body(sheet))
	var low_face := 0
	for f in walls.face_count() if walls != null else 0:
		if absf((walls.face_info(f).point as Vector3).y) < 1e-9:
			low_face = f
	var command = FEATURE_COMMAND.new("thicken")
	var values: Dictionary = command.defaults()
	_expect(str(values.get("thicken_type", "")) == "sharp", "Thicken Type should default to Sharp (%s)." % values.get("thicken_type", ""))
	values["faces"] = [{"kind": "body", "body": _body(sheet)}]
	values["thickness"] = "2"
	values["thicken_type"] = "rounded"
	values["flip"] = walls != null and (walls.face_normal_at(low_face, walls.face_info(low_face).point) as Vector3).y > 0.0
	var thick: Resource = command.create_feature(doc, values)
	_rebuild()
	_no_error(thick, "A Rounded Thicken made by its command")
	var made := _volume(_body(thick))
	_close(made, 400.0 + 10.0 * PI, 1e-6, "The Rounded Thicken feature (volume)")
	var reader = FEATURE_COMMAND.new("thicken")
	reader.feature = thick
	var back: Dictionary = reader.read_values()
	_expect(str(back.get("thicken_type", "")) == "rounded", "Thicken Type should read back from the timeline (%s)." % back.get("thicken_type", ""))
	reader.write_values(doc, back)
	_rebuild()
	_close(_volume(_body(thick)), made, 1e-9, "The Rounded Thicken rebuilt after editing (volume)")


## B6: where picked edges meet, Ruled fills the gap (Rounded: a circular sector about the corner;
## Mitered: out to where the strips meet, turned strips too, which turn alike) and cuts the strips
## back where they would overlap (Extend's strips too); Corner Type defaults to Rounded for new
## features and round-trips.
func _check_round2_ruled() -> void:
	var box = kernel.make_box(Vector3(10, 10, 10) * MM, Vector3.ZERO, "box")
	var chain := _k_edges(box, func(info: Dictionary) -> bool: return (info.midpoint as Vector3).is_equal_approx(Vector3(0, 10, 5) * MM) or (info.midpoint as Vector3).is_equal_approx(Vector3(5, 10, 0) * MM))
	for spec in [["mitered", 44.0], ["rounded", 40.0 + PI]]:
		var flange = kernel.ruled(box, chain, {"type": "tangent", "distance": 2 * MM, "corner_type": spec[0]})
		_close(flange.area() / MM2 if flange != null else -1.0, spec[1], 1e-6, "Tangent ruled 2 mm on two top edges of a 10 mm box, %s corner (area)" % spec[0])
		_expect(flange != null and kernel.pieces(flange).size() == 1 and absf((flange.bbox() as AABB).size.y) < 1e-9, "The %s ruled strips should be one flat piece." % spec[0])
	# Turned by an angle, both strips turn alike (tangent ones up off the top, 30 deg: 1 mm high;
	# normal ones out, 20 deg) and their corner closes: mitred, each strip carried on in its own
	# plane (two triangles of d^2 cos 30 / 2, or d^2 sin 20 / 2); rounded, a sector between the
	# strips' end lines (cos of its angle sin^2 30).
	var tilted := [["tangent", 30.0, "mitered", 40.0 + 4.0 * cos(deg_to_rad(30.0))], ["tangent", 30.0, "rounded", 40.0 + 2.0 * acos(0.25)],
		["normal", 20.0, "mitered", 40.0 + 4.0 * sin(deg_to_rad(20.0))]]
	for spec in tilted:
		var turned = kernel.ruled(box, chain, {"type": spec[0], "distance": 2 * MM, "angle": deg_to_rad(spec[1]), "corner_type": spec[2]})
		_close(turned.area() / MM2 if turned != null else -1.0, spec[3], 1e-6, "%s ruled turned %s deg, %s corner (area)" % [spec[0], spec[1], spec[2]])
		_expect(turned != null and kernel.pieces(turned).size() == 1, "The turned %s strips with a %s corner should be one piece." % [spec[0], spec[2]])
		if turned != null and spec[0] == "tangent":
			var rise: AABB = turned.bbox()
			_expect(absf(rise.position.y - 10 * MM) < 1e-9 and rise.end.y > 11 * MM - 1e-9, "Tangent strips turned 30 deg should both rise off the top (y %s..%s mm)." % [rise.position.y / MM, rise.end.y / MM])
	# An L-shaped flat face: the strips off the two edges at its concave corner are cut back to meet.
	var ell := _k_region([_k_line(Vector2(0, 0), Vector2(20, 0)), _k_line(Vector2(20, 0), Vector2(20, 10)), _k_line(Vector2(20, 10), Vector2(10, 10)),
		_k_line(Vector2(10, 10), Vector2(10, 20)), _k_line(Vector2(10, 20), Vector2(0, 20)), _k_line(Vector2(0, 20), Vector2(0, 0))], 300.0)
	var inner := _k_edges(ell, func(info: Dictionary) -> bool: return (info.midpoint as Vector3).is_equal_approx(Vector3(15, 10, 0) * MM) or (info.midpoint as Vector3).is_equal_approx(Vector3(10, 15, 0) * MM))
	for corner in ["mitered", "rounded"]:
		var strips = kernel.ruled(ell, inner, {"type": "tangent", "distance": 2 * MM, "corner_type": corner})
		_close(strips.area() / MM2 if strips != null else -1.0, 36.0, 1e-6, "Ruled strips at an L face's concave corner (%s): two 10 x 2 mm strips less their 2 x 2 mm overlap (area)" % corner)
		_expect(strips != null and kernel.pieces(strips).size() == 1, "The strips at the concave corner should be one piece.")
	var grown = kernel.extend_surface(ell, inner, {"distance": 2 * MM, "mode": "tangent"})
	_close(grown.area() / MM2 if grown != null else -1.0, 336.0, 1e-6, "Extend (tangent) of an L face's concave corner edges by 2 mm, strips cut back (area)")
	_new_doc()
	var cube := _box(Vector3.ZERO, 10, 10, 10)
	_rebuild()
	var command = FEATURE_COMMAND.new("surface:ruled")
	var values: Dictionary = command.defaults()
	_expect(str(values.get("corner_type", "")) == "rounded", "Ruled's Corner Type should default to Rounded (%s)." % values.get("corner_type", ""))
	values["edges"] = [_edge_ref_at(_body(cube), Vector3(0, 0.01, 0.005)), _edge_ref_at(_body(cube), Vector3(0.005, 0.01, 0))]
	values["distance"] = "2"
	var made: Resource = command.create_feature(doc, values)
	_rebuild()
	_no_error(made, "A Ruled feature with rounded corners")
	_close(_area(_body(made)), 40.0 + PI, 1e-6, "The Ruled feature's rounded corner (area)")
	var reader = FEATURE_COMMAND.new("surface:ruled")
	reader.feature = made
	var back: Dictionary = reader.read_values()
	_expect(str(back.get("corner_type", "")) == "rounded", "Corner Type should read back from the timeline (%s)." % back.get("corner_type", ""))
	back["corner_type"] = "mitered"
	reader.write_values(doc, back)
	_rebuild()
	_close(_area(_body(made)), 44.0, 1e-6, "The Ruled feature edited to mitred corners (area)")


## B7: Trim of a 200-face zigzag wall by a plane is quick (the critic measured about 350 ms a call,
## three times what it takes now), with the same pieces and areas; a solid tool's inside is one
## region (an edge inside a solid tool isn't on it). Its two trims are timed against the same two
## trims of a 50-face stretch of the wall, in turns: a limit in milliseconds failed whenever the
## machine was busy, and so did a calibration that runs on one thread (the wall's common with a
## slab) when other programs took every core the trim's cut runs on.
func _check_round2_trim_speed() -> void:
	var zig := []
	for k in 200:
		zig.append(_k_line(Vector2(k, (k % 2) * 1.0), Vector2(k + 1, ((k + 1) % 2) * 1.0)))
	var wall := _k_sheet(zig, 10.0)
	var cutter = kernel.plane_face(Vector3(0, 0, 5) * MM, Vector3(0, 0, 1), 1.0, "tool")
	var made := {}
	var trims := func() -> void:
		made.shown = kernel.trim(wall, cutter, PackedVector3Array(), {})
		made.trimmed = kernel.trim(wall, cutter, PackedVector3Array([Vector3(0.5, 0.5, 8) * MM]), {})
	var short := []
	for k in 50:
		short.append(zig[k])
	var stretch := _k_sheet(short, 10.0)
	var stretch_trims := func() -> void:
		kernel.trim(stretch, cutter, PackedVector3Array(), {})
		kernel.trim(stretch, cutter, PackedVector3Array([Vector3(0.5, 0.5, 8) * MM]), {})
	var timing := TIMING.compare(trims, stretch_trims, 3, "trim 200-face wall twice / a 50-face stretch twice")
	var shown = made.get("shown")
	var trimmed = made.get("trimmed")
	# (Four times the faces take about four times as long.)
	_expect(timing.ratio < 6.0, "Trimming a 200-face wall twice should take under 6 times as long as a 50-face stretch of it (%.1f ms against %.1f ms)." % [timing.op, timing.calibration])
	_expect(shown != null and kernel.pieces(shown).size() == 2 and shown.face_count() == 400, "The cut 200-face wall should show 2 pieces of 400 faces.")
	_close(shown.area() if shown != null else -1.0, wall.area(), 1e-6, "The cut wall keeps its area")
	_close(trimmed.area() if trimmed != null else -1.0, wall.area() * 0.5, 1e-6, "The wall with its top half trimmed away (area)")
	var block = kernel.make_box(Vector3(50, 20, 4) * MM, Vector3(70, -10, 3) * MM, "block")
	var around = kernel.trim(wall, block, PackedVector3Array(), {})
	_expect(around != null and kernel.pieces(around).size() == 2, "A box through the wall should cut it into the part inside and the part outside (%d pieces)." % (kernel.pieces(around).size() if around != null else -1))


## B8: Replace Face takes a cube's top up to a cylindrical surface body over it (an arc through
## (-10, 10), (0, 13), (10, 10) mm over the cube's x -5..5, extruded across it: one curved top
## keeping the top's name, exact volume) and down to one that dips 3 mm below it; a drafted side
## face is refused by name. Replace Face, Align and Manage Materials are in the Surface workspace's
## Modify menu.
func _check_round2_replace_face() -> void:
	for spec in [["over", 13.0], ["under", 7.0]]:
		_new_doc()
		# (A box stands on the middle of its base: x and z -5..5, y 0..10 mm.)
		var cube := _box(Vector3.ZERO, 10, 10, 10)
		var apex: float = spec[1]
		# The circle through (-10, 10), (0, apex), (10, 10): center (0, k), radius |apex - k|.
		var k := (apex * apex - 200.0) / (2.0 * apex - 20.0)
		var radius := absf(apex - k)
		var arc_sketch: Resource = doc.add_feature("sketch", "Sketch", {}, SKETCH_DATA.new_options({"origin": Vector3(0, 0, -0.01), "x": Vector3.RIGHT, "y": Vector3.UP}, "frame"))
		var data = SKETCH_DATA.new(arc_sketch, doc)
		var left: int = data.add_point(Vector2(-10, 10) * MM)
		var right: int = data.add_point(Vector2(10, 10) * MM)
		var center: int = data.add_point(Vector2(0, k) * MM)
		var arc: int = data.add_arc(center, right, left) if apex > 10.0 else data.add_arc(center, left, right)
		var target := _surface("extrude", {"distance": "20 mm"}, {"profiles": [{"kind": "sketch_curve", "sketch": arc_sketch.id, "entity": arc}]})
		_rebuild()
		var top := _face_ref_at(_body(cube), Vector3(0, 0.01, 0))
		var replace := _add("replace_face", {}, {"faces": [top], "target": [{"kind": "body", "body": _body(target)}]})
		_rebuild()
		_no_error(replace, "Replace a cube's top by a surface %s it" % spec[0])
		# The region between y = 10 and the arc over x -5..5, times the 10 mm depth.
		var under_arc := radius * radius * asin(5.0 / radius) + 5.0 * sqrt(radius * radius - 25.0)
		var bulge := under_arc + 10.0 * (k - 10.0) if apex > 10.0 else -(10.0 * (10.0 - k) + under_arc)
		_close(_volume(_body(cube)), 1000.0 + 10.0 * bulge, 1e-6, "A cube's top replaced by a surface %s it (volume)" % spec[0])
		var shape := _shape(_body(cube))
		if shape != null:
			var curved: int = shape.find_face(str(top.name))
			_expect(shape.face_count() == 6 and _k_kinds(shape) == ["cylinder", "plane"] and curved >= 0 and str(shape.face_info(curved).type) == "cylinder",
				"The cube should keep 6 faces with one curved top, named as the top was (%s, %s)." % [_k_kinds(shape), shape.get_face_names()])
		if spec[0] == "over":
			var made := _volume(_body(cube))
			var reader = FEATURE_COMMAND.new("replace_face")
			reader.feature = replace
			reader.write_values(doc, reader.read_values())
			_rebuild()
			_close(_volume(_body(cube)), made, 1e-9, "Replace Face rebuilt after editing (volume)")
	# A drafted side face doesn't run along the top's normal: refused, by name.
	_new_doc()
	var drafted_box := _box(Vector3.ZERO, 10, 10, 10)
	_rebuild()
	var tilt := _add("draft", {"angle": ["5 deg", "angle"]}, {"faces": [_face_ref_at(_body(drafted_box), Vector3(0.005, 0.005, 0))], "plane": [{"kind": "origin", "name": "xz"}]})
	var flat := _lines("xy", [[Vector2(-10, 13), Vector2(10, 13)]])
	var lid := _surface("extrude", {"distance": "10 mm", "distance2": "10 mm"}, {"profiles": [_curve(flat)], "side": "two"})
	_rebuild()
	_no_error(tilt, "Draft a box's side")
	var leaning := _shape(_body(drafted_box))
	var leaning_name := ""
	for f in leaning.face_count() if leaning != null else 0:
		var n: Vector3 = leaning.face_info(f).get("normal", Vector3.ZERO)
		if absf(n.x) > 0.5 and absf(n.x) < 0.9999:
			leaning_name = str(leaning.get_face_names()[f])
	var refused := _add("replace_face", {}, {"faces": [_face_ref_at(_body(drafted_box), Vector3(0, 0.01, 0))], "target": [{"kind": "body", "body": _body(lid)}]})
	_rebuild()
	_expect(leaning_name != "" and str(result.errors.get(refused.id, "")).contains("can't carry %s" % leaning_name),
		"Replace Face next to a drafted side should be refused naming it (%s; %s)." % [leaning_name, result.errors.get(refused.id, "")])
	for name in ["Replace Face", "Align", "Manage Materials"]:
		var found := {}
		for tool in CATALOG.tools_in("Surface", "Modify"):
			found = tool if tool.name == name else found
		_expect(not found.is_empty() and CATALOG.is_enabled(found), "%s should be enabled in the Surface workspace's Modify menu." % name)


## B9: Press Pull on a sketch profile makes a surface Extrude (a new surface body) in the Surface
## workspace (and edits back), and still a Join extrude in the Solid workspace.
func _check_round2_press_pull() -> void:
	var tools := {}
	for workspace in ["Surface", "Solid"]:
		for tool in CATALOG.tools_in(workspace, "Modify"):
			if tool.name == "Press Pull":
				tools[workspace] = tool
	_new_doc()
	var cube := _box(Vector3.ZERO, 10, 10, 10)
	# A square over the box's top (x and z -5..5 mm, at y 10 mm), facing up.
	var square := _lines({"origin": Vector3(0, 0.01, 0), "x": Vector3.RIGHT, "y": Vector3.FORWARD},
		[[Vector2(-5, -5), Vector2(5, -5)], [Vector2(5, -5), Vector2(5, 5)], [Vector2(5, 5), Vector2(-5, 5)], [Vector2(-5, 5), Vector2(-5, -5)]])
	_rebuild()
	var inside := {"kind": "profile", "sketch": square.feature.id, "point": Vector2.ZERO}
	var command = FEATURE_COMMAND.new(str(tools.get("Surface", {}).get("type", "")))
	var values: Dictionary = command.defaults()
	values["pick"] = [inside]
	values["distance"] = "5"
	var pulled: Resource = command.create_feature(doc, values)
	_rebuild()
	_no_error(pulled, "Press Pull on a profile in the Surface workspace")
	_expect(pulled.type == "surface" and str(pulled.options.get("method", "")) == "extrude", "Press Pull in the Surface workspace should make a surface Extrude (%s %s)." % [pulled.type, pulled.options.get("method", "")])
	_is_surface(_body(pulled), 4, "A Surface Press Pull of a square")
	_close(_area(_body(pulled)), 200.0, 1e-6, "The surface Press Pull's walls (area)")
	_close(_volume(_body(cube)), 1000.0, 1e-6, "The box beside a surface Press Pull stays as it was (volume)")
	var edit = FEATURE_COMMAND.new(str(tools.get("Surface", {}).get("type", "")))
	edit.feature = pulled
	var back: Dictionary = edit.read_values()
	back["distance"] = "6"
	edit.write_values(doc, back)
	_rebuild()
	_close(_area(_body(pulled)), 240.0, 1e-6, "The surface Press Pull edited to 6 mm (area)")
	doc.remove_feature(pulled.id)
	var solid_command = FEATURE_COMMAND.new(str(tools.get("Solid", {}).get("type", "")))
	var solid_values: Dictionary = solid_command.defaults()
	solid_values["pick"] = [inside]
	solid_values["distance"] = "5"
	var joined: Resource = solid_command.create_feature(doc, solid_values)
	_rebuild()
	_no_error(joined, "Press Pull on a profile in the Solid workspace")
	_expect(joined.type == "extrude" and str(joined.options.get("operation", "")) == OPERATIONS.AUTO, "Press Pull in the Solid workspace should be a Join-or-New-Body extrude, joining what it touches (%s)." % joined.type)
	_close(_volume(_body(cube)), 1500.0, 1e-6, "The Solid Press Pull joins the box (volume)")


# --- Round 3: tangent all round, thickenable patches, extends, taper, replace, loft, thicken --------

## How many neighbours on a 24 x 24 grid of a one-face patch's normals (over [0, 1]^2) face apart.
func _k_flips(shape: RefCounted) -> int:
	var n := 24
	var uvs := PackedVector2Array()
	for i in n + 1:
		for j in n + 1:
			uvs.append(Vector2(float(i) / n, float(j) / n))
	var normals: PackedVector3Array = shape.surface_curvatures(0, uvs).get("normals", PackedVector3Array())
	var flips := 0
	for i in n + 1:
		for j in n + 1:
			var a := normals[i * (n + 1) + j]
			flips += 1 if i < n and a.dot(normals[(i + 1) * (n + 1) + j]) < 0.0 else 0
			flips += 1 if j < n and a.dot(normals[i * (n + 1) + j + 1]) < 0.0 else 0
	return flips


## A1, NEW-1, NEW-6: a loop with under three corners is a lens with two collapsed ends (no patch
## corner sits where the loop runs on smoothly): a G1 cap on a tube is tangent to it all round (the
## old split points too), thickens and offsets both ways, and stitched to the tube thickens too; a
## cap over a sphere's hole lies on the sphere. A four-cornered G1 dome thickens (its volume() is
## checked in _check_round4_volumes).
func _check_round3_patch() -> void:
	var tube := _k_sheet([_k_circle(Vector2.ZERO, 5)], 10.0)
	var rim := _k_edges(tube, func(info: Dictionary) -> bool: return absf((info.midpoint as Vector3).z - 10 * MM) < 1e-7)
	var cap = kernel.patch([{"shape": tube, "edges": rim, "continuity": 1}], PackedVector3Array(), {"tag": "p"})
	_expect(cap != null and cap.face_count() == 1 and _k_fills_box(cap), "A G1 tube cap should be one face filling its box (%s)." % kernel.get_last_error())
	if cap != null:
		var worst := 0.0
		for k in 72:
			var a := TAU * k / 72.0
			var radial := Vector3(cos(a), sin(a), 0)
			var normal: Vector3 = cap.face_normal_at(0, radial * 5 * MM + Vector3(0, 0, 10 * MM))
			worst = maxf(worst, rad_to_deg(acos(clampf(absf(normal.dot(radial)), 0.0, 1.0))) if normal.length() > 0.5 else 90.0)
		_expect(worst < 0.1, "The G1 tube cap should be tangent to the tube all round, every 5 deg from its seam (worst %.4f deg)." % worst)
		# Thickened 0.2 mm either way: a shell of about A t (1 +- t / 5 + t^2 / 75) (a dome of
		# r 5 mm, out from it or in).
		var up: Vector3 = cap.face_normal_at(0, Vector3(0, 0, 15) * MM)
		for t in [0.2, -0.2]:
			var thick = kernel.thicken(cap, PackedInt32Array(), {"thickness": t * MM})
			_expect(thick != null and thick.solid_count() == 1, "The G1 tube cap should thicken %s mm (%s)." % [t, kernel.get_last_error()])
			var out := 1.0 if (t > 0.0) == (up.z > 0.0) else -1.0
			var shell: float = cap.area() / MM2 * 0.2 * (1.0 + out * 0.2 / 5.0 + 0.04 / 75.0)
			_close(_k_mesh_volume(thick, 0.002) if thick != null else -1.0, shell, 5e-3, "The tube cap thickened %s mm (mesh volume)" % t)
			_expect(kernel.offset_surface(cap, PackedInt32Array(), t * MM, "o") != null, "The G1 tube cap should offset %s mm (%s)." % [t, kernel.get_last_error()])
		var closed = kernel.stitch([tube, cap], {})
		_expect(closed != null and kernel.thicken(closed, PackedInt32Array(), {"thickness": 0.2 * MM}) != null, "The tube and its cap stitched should thicken 0.2 mm (%s)." % kernel.get_last_error())
	# Neither it nor a lens between two half circles hinged 69 deg apart folds: on a grid of normals
	# (its collapsed ends' too, their limits from inside) no neighbours face apart.
	var hinged := [kernel.sketch_edges([_k_arc(Vector2.ZERO, 10, 0.0, PI)], Transform3D.IDENTITY), kernel.sketch_edges([_k_arc(Vector2.ZERO, 10, 0.0, PI)], Transform3D(Basis(Vector3(1, 0, 0), 1.2), Vector3.ZERO))]
	var hinge = kernel.patch([{"shape": kernel.make_compound(hinged), "edges": PackedInt32Array(), "continuity": 0}], PackedVector3Array(), {"tag": "p"})
	for spec in [[cap, "G1 tube cap"], [hinge, "hinged half circles' lens"]]:
		var flips := _k_flips(spec[0]) if spec[0] != null else -1
		_expect(flips == 0, "The %s should not fold (%d neighbouring normals face apart)." % [spec[1], flips])
	# A cap over a hole down to 45 deg from the top of an r 10 mm sphere carries the sphere on.
	var holed := _k_spun([_k_arc(Vector2.ZERO, 10, -PI / 2, PI / 4)])
	var hole := _k_edges(holed, func(info: Dictionary) -> bool: return str(info.type) == "circle" and (info.midpoint as Vector3).y > 7 * MM)
	var lid = kernel.patch([{"shape": holed, "edges": hole, "continuity": 1}], PackedVector3Array(), {"tag": "p"})
	_expect(lid != null, "A G1 cap over a sphere's hole should build (%s)." % kernel.get_last_error())
	if lid != null:
		var off := 0.0
		for i in 5:
			for j in 5:
				var p: Vector3 = kernel.closest_points(lid, kernel.make_vertex(Vector3((i - 2) * 3.0, 20, (j - 2) * 3.0) * MM)).a
				off = maxf(off, absf(p.length() - 10 * MM))
		_expect(absf((lid.bbox() as AABB).end.y - 10 * MM) < 0.01 * MM and off < 0.01 * MM, "The sphere hole's cap should lie on the sphere (top y %.4f mm, %.4f mm off it at most)." % [(lid.bbox() as AABB).end.y / MM, off / MM])
	# Four corners: the G1 dome over an open box thickens; at 0.05 mm its mesh volume is area x t.
	var box = kernel.make_box(Vector3(10, 10, 10) * MM, Vector3.ZERO, "box")
	var walls := PackedInt32Array()
	for f in box.face_count():
		if (box.face_info(f).normal as Vector3).z < 0.99:
			walls.append(f)
	var open_box = kernel.keep_faces(box, walls)
	var dome = kernel.patch([{"shape": open_box, "edges": _k_edges(open_box, func(info: Dictionary) -> bool: return absf((info.midpoint as Vector3).z - 10 * MM) < 1e-7), "continuity": 1}], PackedVector3Array(), {"tag": "p"})
	if dome != null:
		var thin = kernel.thicken(dome, PackedInt32Array(), {"thickness": 0.05 * MM})
		_close(_k_mesh_volume(thin, 0.002) if thin != null else -1.0, dome.area() / MM2 * 0.05, 0.02, "The G1 box dome thickened 0.05 mm (mesh volume against area x t; %s)" % kernel.get_last_error())
		_expect(kernel.thicken(dome, PackedInt32Array(), {"thickness": 0.2 * MM}) != null, "The G1 box dome should thicken 0.2 mm (%s)." % kernel.get_last_error())
		# Its corners turn from the walls' way to the top's within a fifth of a side (a 0.4 mm
		# bend): 1 mm folds there, and is refused for it.
		_k_refused(kernel.thicken(dome, PackedInt32Array(), {"thickness": 1 * MM}), "curves too tightly", "Thickening the G1 box dome 1 mm")


## NEW-2, NEW-3: a document saved when plate patches were named "<id>:patch" still finds such a face
## by name; a patch is refused when it misses one of its rails by more than a hundredth of its
## size (a rail beside the boundary); a sharply bent one it passes near builds with a warning.
func _check_round3_plates() -> void:
	_new_doc()
	var square := _lines("xy", [[Vector2(-5, -5), Vector2(5, -5)], [Vector2(5, -5), Vector2(5, 5)], [Vector2(5, 5), Vector2(-5, 5)], [Vector2(-5, 5), Vector2(-5, -5)]])
	var arch: Resource = doc.add_feature("sketch", "Sketch", {}, SKETCH_DATA.new_options({"origin": Vector3.ZERO, "x": Vector3.RIGHT, "y": Vector3.BACK}, "frame"))
	var arch_data = SKETCH_DATA.new(arch, doc)
	var arc: int = arch_data.add_arc(arch_data.add_point(Vector2(0, -8.0 / 3.0) * MM), arch_data.add_point(Vector2(5, 0) * MM), arch_data.add_point(Vector2(-5, 0) * MM))
	var plate := _surface("patch", {}, {"boundary": _curves(square), "rails": [{"kind": "sketch_curve", "sketch": arch.id, "entity": arc}]})
	_rebuild()
	var face := _face_ref_at(_body(plate), Vector3(0, 0, 3) * MM)
	_expect(str(face.get("name", "")) == plate.id + ":plate", "A railed patch should be a plate face (%s)." % face.get("name", ""))
	face["name"] = plate.id + ":patch"
	var moved := _surface("offset", {"distance": "1 mm"}, {"faces": [face]})
	_rebuild()
	_no_error(moved, "An Offset of a plate face saved under its old name")
	_expect(not result.warnings.has(moved.id), "A plate face's old name should still find it, with no repair (%s)." % result.warnings.get(moved.id, ""))
	# A tent of two lines rising to 3 mm over the square's middle, and the arch beside the square.
	# (Round 4: a smooth plate can't follow the tent's kink, so it passes 0.10 mm under the peak,
	# within a hundredth of its size, and says so; round 3 refused it.)
	var xz := Transform3D(Basis(Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(0, -1, 0)), Vector3.ZERO)
	var loop = kernel.sketch_edges(_k_square(5.0), Transform3D.IDENTITY)
	var tent = kernel.sketch_edges([_k_line(Vector2(-5, 0), Vector2(0, 3)), _k_line(Vector2(0, 3), Vector2(5, 0))], xz)
	var tented = kernel.patch([{"shape": loop, "edges": PackedInt32Array(), "continuity": 0}], PackedVector3Array(), {"rails": [{"shape": tent, "edges": PackedInt32Array()}]})
	_expect(tented != null and kernel.get_last_warning() == "The patch passes within 0.10 mm of its rails",
		"A patch along a sharply bent rail should build, saying how near it passes (%s, \"%s\")." % [kernel.get_last_error(), kernel.get_last_warning()])
	if tented != null:
		var peak: float = float(kernel.closest_points(tented, kernel.make_vertex(Vector3(0, 0, 3) * MM)).distance) / MM
		_expect(peak > 0.05 and peak < 0.141, "The tent rail's patch should pass under its peak by under a hundredth of its size (%.3f mm)." % peak)
	var c := -8.0 / 3.0
	var aside = kernel.sketch_edges([_k_arc(Vector2(0, c), 3.0 - c, atan2(-c, 5.0), PI - atan2(-c, 5.0))], Transform3D(xz.basis, Vector3(0, 8, 0) * MM))
	_k_refused(kernel.patch([{"shape": loop, "edges": PackedInt32Array(), "continuity": 0}], PackedVector3Array(), {"rails": [{"shape": aside, "edges": PackedInt32Array()}]}),
		"can't pass through its rails", "A patch with its rail beside the boundary")


## A4, A6, A8, NEW-4, NEW-5: a turned spline profile carries on along itself and stops short of the
## axis; a trimmed sphere zone's untouched rim carries the sphere on; Perpendicular fills or cuts
## back the corners between faces' strips; the kernel's warning is cleared by the next call;
## perpendicular walls off flat faces are planes and thicken.
func _check_round3_extend() -> void:
	# A straight interpolated profile from (6, 0) to (2, 6) mm about Y: its top rim reaches the
	# axis 3.61 mm on; 3 mm on it is a cone band of r 2 to 2 - 3 * 4 / sqrt(52) mm.
	var straight := _k_spun([{"type": "interp", "points": PackedVector2Array([Vector2(6, 0) * MM, Vector2(4, 3) * MM, Vector2(2, 6) * MM])}])
	var top := _k_edges(straight, func(info: Dictionary) -> bool: return str(info.type) == "circle" and absf((info.midpoint as Vector3).y - 6 * MM) < 1e-6)
	_k_refused(kernel.extend_surface(straight, top, {"distance": 5 * MM, "mode": "natural"}), "meets its axis (3.61 mm away)", "Extending a turned straight spline's top rim 5 mm (the axis is 3.61 mm on)")
	var longer = kernel.extend_surface(straight, top, {"distance": 3 * MM, "mode": "natural"})
	_close((longer.area() - straight.area()) / MM2 if longer != null else -1.0, PI * (4.0 - 12.0 / sqrt(52.0)) * 3.0, 1e-4, "A turned straight spline's top rim extended 3 mm (area added)")
	var bent := _k_spun([{"type": "bspline", "poles": PackedVector2Array([Vector2(6, 0) * MM, Vector2(6, 3) * MM, Vector2(4, 5) * MM, Vector2(2, 6) * MM]), "degree": 3}])
	var bent_top := _k_edges(bent, func(info: Dictionary) -> bool: return str(info.type) == "circle" and absf((info.midpoint as Vector3).y - 6 * MM) < 1e-6)
	_k_refused(kernel.extend_surface(bent, bent_top, {"distance": 5 * MM, "mode": "natural"}), "meets its axis", "Extending a turned spline that curls into its axis 5 mm")
	# Half an r 10 mm sphere zone (0 to 60 deg up) with a notch trimmed out of its top: its bottom
	# rim carries the sphere on 2 mm (a band of pi R^2 sin 0.2), quietly.
	var zone = kernel.revolve(kernel.sketch_edges([_k_arc(Vector2.ZERO, 10, 0.0, PI / 3)], Transform3D.IDENTITY), {"axis_origin": Vector3.ZERO, "axis": Vector3(0, 1, 0), "angle": PI, "surface": true})
	var notch = kernel.make_box(Vector3(20, 20, 40) * MM, Vector3(3, 6, -20) * MM, "notch")
	var notched = kernel.trim(zone, notch, PackedVector3Array([Vector3(6.43, 7.66, 0) * MM]), {})
	var bottom := _k_edges(notched, func(info: Dictionary) -> bool: return absf((info.midpoint as Vector3).y) < 1e-7 and str(info.type) == "circle") if notched != null else PackedInt32Array()
	var band = kernel.extend_surface(notched, bottom, {"distance": 2 * MM, "mode": "natural"}) if bottom.size() == 1 else null
	_close((band.area() - notched.area()) / MM2 if band != null else -1.0, PI * 100.0 * sin(0.2), 1e-6, "A notched sphere zone's bottom rim extended 2 mm naturally (area added; %s)" % kernel.get_last_error())
	_expect(band != null and kernel.get_last_warning() == "", "The notched zone's untouched rim should extend naturally, quietly (%s)." % kernel.get_last_warning())
	# NEW-4: a fallback's warning (a tilted cut through a quarter cylinder) is gone after any call.
	var quarter := _k_sheet([_k_arc(Vector2.ZERO, 10, 0.0, PI / 2)], 10.0)
	var cut = kernel.trim(quarter, kernel.plane_face(Vector3(0, 0, 5) * MM, Vector3(0, 0.3, 1).normalized(), 0.1, "tool"), PackedVector3Array([Vector3(7.07, 7.07, 9.5) * MM]), {})
	var slant := _k_edges(cut, func(info: Dictionary) -> bool: return str(info.type) != "line" and absf((info.midpoint as Vector3).z) > 1e-6) if cut != null else PackedInt32Array()
	var fell = kernel.extend_surface(cut, slant, {"distance": 1 * MM, "mode": "natural"}) if slant.size() == 1 else null
	_expect(fell != null and kernel.get_last_warning().contains("extended tangentially"), "A natural extend of a tilted cut should fall back and say so (%s, %s)." % [slant.size(), kernel.get_last_warning()])
	kernel.make_box(Vector3(1, 1, 1) * MM, Vector3.ZERO, "after")
	_expect(kernel.get_last_warning() == "", "make_box should clear the last warning (%s)." % kernel.get_last_warning())
	# A8: the top rim of a square tube (one edge per face) and of an L sheet, perpendicular 3 mm,
	# either way out: strips cut back where they cross (84, 51) or their corners filled (156, 69).
	var square_tube := _k_sheet(_k_square(5.0), 10.0)
	var ell := _k_sheet([_k_line(Vector2(0, 0), Vector2(10, 0)), _k_line(Vector2(10, 0), Vector2(10, 10))], 10.0)
	for spec in [[square_tube, [84.0, 156.0], "square tube"], [ell, [51.0, 69.0], "L sheet"]]:
		var added := []
		for sheet in [spec[0], kernel.reverse_faces(spec[0], PackedInt32Array())]:
			var rim := _k_edges(sheet, func(info: Dictionary) -> bool: return absf((info.midpoint as Vector3).z - 10 * MM) < 1e-7)
			var walled = kernel.extend_surface(sheet, rim, {"distance": 3 * MM, "mode": "perpendicular"})
			added.append(roundf((walled.area() - sheet.area()) / MM2 * 1e4) / 1e4 if walled != null else -1.0)
		added.sort()
		_expect(added == spec[1], "A %s's top rim extended perpendicular 3 mm either way should add %s mm2 (%s)." % [spec[2], spec[1], added])
	# NEW-5: a flat sheet with a 5 mm perpendicular wall is two planes and thickens as an extruded L
	# (16 x 12 and 16 x 5 mm, 0.5 mm: 136 less or plus the 16 x 0.5 x 0.5 mm corner).
	var flat := _k_sheet([_k_line(Vector2(0, 0), Vector2(16, 0))], 12.0)
	var walled_flat = kernel.extend_surface(flat, _k_edges(flat, func(info: Dictionary) -> bool: return absf((info.midpoint as Vector3).z - 12 * MM) < 1e-7), {"distance": 5 * MM, "mode": "perpendicular"})
	_expect(_k_kinds(walled_flat) == ["plane"], "A perpendicular wall off a flat sheet's straight edge should be a plane (%s)." % [_k_kinds(walled_flat)])
	var volumes := []
	for t in [0.5, -0.5]:
		var thick = kernel.thicken(walled_flat, PackedInt32Array(), {"thickness": t * MM}) if walled_flat != null else null
		volumes.append(roundf(thick.volume() / MM3 * 1e4) / 1e4 if thick != null else -1.0)
	volumes.sort()
	_expect(volumes == [132.0, 140.0], "The sheet with its perpendicular wall should thicken 0.5 mm either way (132, 140 mm3; %s)." % [volumes])
	# A disc's rim with a 3 mm perpendicular wall: a cylinder (its prism, not a ruled spline), so the
	# cup thickens.
	var disc := _k_region([_k_circle(Vector2.ZERO, 5)], 25.0 * PI)
	var cup = kernel.extend_surface(disc, _k_edges(disc, func(info: Dictionary) -> bool: return str(info.type) == "circle"), {"distance": 3 * MM, "mode": "perpendicular"})
	_close(cup.area() / MM2 if cup != null else -1.0, 25.0 * PI + 30.0 * PI, 1e-6, "A disc with a 3 mm perpendicular wall round its rim (area)")
	_expect(_k_kinds(cup) == ["cylinder", "plane"] and kernel.thicken(cup, PackedInt32Array(), {"thickness": 0.5 * MM}) != null,
		"The disc's perpendicular wall should be a cylinder and the cup thicken (%s, %s)." % [_k_kinds(cup), kernel.get_last_error()])


## B2, B8: a taper where an arc meets a line at a corner drafts the straight prism (a cone and
## planes, the exact volume, caps and walls named as before); Replace Face moves each point of a
## face to the target's crossing of its normal nearest it (a rod or a sphere the normal crosses
## twice: their near side).
func _check_round3_taper_and_replace() -> void:
	var dee := _k_region([_k_arc(Vector2.ZERO, 10, 0.0, PI), _k_line(Vector2(-10, 0), Vector2(10, 0))], 50.0 * PI)
	var taper := deg_to_rad(5.0)
	var drafted = kernel.extrude(dee, {"direction": Vector3(0, 0, 1), "distance": 10 * MM, "taper": taper, "tag": "t"})
	var drafted_walls = kernel.extrude(dee, {"direction": Vector3(0, 0, 1), "distance": 10 * MM, "taper": taper, "surface": true, "tag": "t"})
	_expect(_k_kinds(drafted) == ["cone", "plane"] and _k_kinds(drafted_walls) == ["cone", "plane"], "A tapered D shape's walls should be a cone and a plane (solid %s, surface %s)." % [_k_kinds(drafted), _k_kinds(drafted_walls)])
	# Its section at height z is the half disc r 10 - s cut at y = s (s = z tan 5 deg): Simpson's rule.
	var n := 1000
	var exact := 0.0
	for i in n + 1:
		var s := 10.0 * i / n * tan(taper)
		var rho := 10.0 - s
		var section := rho * rho * acos(s / rho) - s * sqrt(rho * rho - s * s)
		exact += section * (1.0 if i == 0 or i == n else (4.0 if i % 2 == 1 else 2.0))
	exact *= 10.0 / n / 3.0
	_close(drafted.volume() / MM3 if drafted != null else -1.0, exact, 1e-6, "A D shape tapered 5 deg over 10 mm (volume)")
	if drafted != null:
		_expect(drafted.find_face("t:start") >= 0 and drafted.find_face("t:end") >= 0 and str(drafted.get_face_names()).contains("t:g("), "The drafted D shape should name its caps and walls as a taper does (%s)." % [drafted.get_face_names()])
	# A 10 mm cube (x and z -5..5, y 0..10 mm) with its top replaced by an r 8 mm rod along Z whose
	# underside dips into it, one wholly above it, and an r 8 mm sphere at y 14 mm.
	var primitive := func(x: float) -> float: return x / 2.0 * sqrt(64.0 - x * x) + 32.0 * asin(x / 8.0)
	var under: float = 2.0 * primitive.call(5.0)
	var sphere_exact := 0.0
	for i in 200:
		for j in 200:
			var x := -5.0 + 10.0 * (i + 0.5) / 200.0
			var z := -5.0 + 10.0 * (j + 0.5) / 200.0
			sphere_exact += (14.0 - sqrt(64.0 - x * x - z * z)) * 0.0025
	var rod := func(y: float) -> RefCounted: return kernel.extrude(kernel.sketch_edges([_k_circle(Vector2(0, y), 8)], Transform3D(Basis.IDENTITY, Vector3(0, 0, -10) * MM)), {"direction": Vector3(0, 0, 1), "distance": 20 * MM, "surface": true})
	var ball = kernel.revolve(kernel.sketch_edges([_k_arc(Vector2(0, 14), 8, -PI / 2, PI / 2)], Transform3D.IDENTITY), {"axis_origin": Vector3.ZERO, "axis": Vector3(0, 1, 0), "angle": TAU, "surface": true})
	for spec in [[rod.call(16.0), 1000.0 - 10.0 * (under - 60.0), "a rod dipping into it"], [rod.call(20.0), 1000.0 + 10.0 * (100.0 - under), "a rod above it"], [ball, sphere_exact, "a sphere over it"]]:
		var cube = kernel.make_box(Vector3(10, 10, 10) * MM, Vector3(-5, 0, -5) * MM, "cube")
		var lid := -1
		for f in cube.face_count():
			lid = f if (cube.face_info(f).normal as Vector3).y > 0.99 else lid
		var replaced = kernel.replace_faces(cube, PackedInt32Array([lid]), spec[0], {})
		_close(replaced.volume() / MM3 if replaced != null else -1.0, spec[1], 1e-4, "A cube's top replaced by %s goes to its near side (volume; %s)" % [spec[2], kernel.get_last_error()])


## B10, NEW-loft-thicken 1-4: one rail running past the sections lofts only between them, and a
## point section along it is kept; lofts between loops of different edge counts are sound; thin
## skins on big parts and on small ones thicken; Ruled and Extend features saved before Corner Type
## and Chain Selection read back what they build and edit to the same.
func _check_round3_loft_and_thicken() -> void:
	var up := Transform3D(Basis.IDENTITY, Vector3(0, 0, 10 * MM))
	var corner_square := [_k_line(Vector2(0, 0), Vector2(10, 0)), _k_line(Vector2(10, 0), Vector2(10, 10)), _k_line(Vector2(10, 10), Vector2(0, 10)), _k_line(Vector2(0, 10), Vector2(0, 0))]
	var low := _k_region_at(corner_square, 100.0, Transform3D.IDENTITY)
	var high := _k_region_at(corner_square, 100.0, up)
	var xz := Transform3D(Basis(Vector3(0, 0, 1), Vector3(1, 0, 0), Vector3(0, 1, 0)), Vector3.ZERO)
	var railed = kernel.loft([low, high], {"rail": kernel.sketch_wire([_k_line(Vector2(-10, 0), Vector2(20, 0))], xz)})
	_close(railed.volume() / MM3 if railed != null else -1.0, 1000.0, 1e-6, "Two squares lofted along a rail running 10 mm past each (volume; %s)" % kernel.get_last_error())
	if railed != null:
		_expect(absf((railed.bbox() as AABB).position.z) < 1e-9 and absf((railed.bbox() as AABB).end.z - 10 * MM) < 1e-9, "The railed loft should stop at the squares (%s)." % railed.bbox())
	var pyramid = kernel.loft([low, kernel.make_vertex(Vector3(0, 0, 10) * MM)], {"rail": kernel.sketch_wire([_k_line(Vector2(0, 0), Vector2(10, 0))], xz)})
	_close(pyramid.volume() / MM3 if pyramid != null else -1.0, 1000.0 / 3.0, 1e-5, "A square lofted to a point along a rail (volume; %s)" % kernel.get_last_error())
	# A 10 mm square to an r 5 mm circle 10 mm above: sound (OCCT splits the loops to match).
	var square := _k_region_at(_k_square(5.0), 100.0, Transform3D.IDENTITY)
	var circle := _k_region_at([_k_circle(Vector2.ZERO, 5)], 25.0 * PI, up)
	for ruled in [false, true]:
		var lofted = kernel.loft([square, circle], {"ruled": ruled})
		_expect(lofted != null and lofted.solid_count() == 1 and lofted.volume() > 800.0 * MM3, "A square lofted to a circle (ruled %s) should be a solid (%s)." % [ruled, lofted.volume() / MM3 if lofted != null else kernel.get_last_error()])
		if lofted != null:
			_close(_k_mesh_volume(lofted, 0.002), lofted.volume() / MM3, 2e-3, "A square lofted to a circle, ruled %s (volume against its mesh)" % ruled)
			var walls = kernel.loft([square, circle], {"ruled": ruled, "surface": true})
			_close(walls.area() / MM2 if walls != null else -1.0, lofted.area() / MM2 - 100.0 - 25.0 * PI, 1e-6, "The square-to-circle surface loft, ruled %s (area)" % ruled)
	# Thin skins: 0.02 mm on an r 200 mm tube 100 mm tall, 0.01 mm on a 5 x 5 mm sheet.
	var skin = kernel.thicken(_k_sheet([_k_circle(Vector2.ZERO, 200)], 100.0), PackedInt32Array(), {"thickness": 0.02 * MM})
	var skin_volume: float = skin.volume() / MM3 if skin != null else -1.0
	# (Its volume is two 12.6e6 mm3 cylinders' difference: good to about 1e-5.)
	_expect(absf(skin_volume - PI * (pow(200.02, 2) - 40000.0) * 100.0) < 3e-5 * skin_volume or absf(skin_volume - PI * (40000.0 - pow(199.98, 2)) * 100.0) < 3e-5 * skin_volume,
		"An r 200 mm tube thickened 0.02 mm should be its thin shell (%s mm3; %s)." % [skin_volume, kernel.get_last_error()])
	var small = kernel.thicken(_k_sheet([_k_line(Vector2(0, 0), Vector2(5, 0))], 5.0), PackedInt32Array(), {"thickness": 0.01 * MM})
	_close(small.volume() / MM3 if small != null else -1.0, 0.25, 1e-6, "A 5 x 5 mm sheet thickened 0.01 mm (volume; %s)" % kernel.get_last_error())
	# A Ruled feature saved before Corner Type builds mitred, reads back so and edits to the same.
	_new_doc()
	var cube := _box(Vector3.ZERO, 10, 10, 10)
	_rebuild()
	var command = FEATURE_COMMAND.new("surface:ruled")
	var values: Dictionary = command.defaults()
	values["edges"] = [_edge_ref_at(_body(cube), Vector3(0, 0.01, 0.005)), _edge_ref_at(_body(cube), Vector3(0.005, 0.01, 0))]
	values["distance"] = "2"
	var old_ruled: Resource = command.create_feature(doc, values)
	old_ruled.options.erase("corner_type")
	_rebuild()
	_close(_area(_body(old_ruled)), 44.0, 1e-6, "A Ruled feature saved before Corner Type (mitred area)")
	var reader = FEATURE_COMMAND.new("surface:ruled")
	reader.feature = old_ruled
	var back: Dictionary = reader.read_values()
	_expect(str(back.get("corner_type", "")) == "mitered", "An old Ruled feature's Corner Type should read back Mitered (%s)." % back.get("corner_type", ""))
	reader.write_values(doc, back)
	_rebuild()
	_close(_area(_body(old_ruled)), 44.0, 1e-6, "An old Ruled feature edited with nothing changed (area)")
	# An Extend saved before Chain Selection extends only its pick (of two edges in line, which a
	# chain would take both of), and reads back so.
	var band := _surface("extrude", {"distance": "10 mm"}, {"profiles": _curves(_lines("xy", [[Vector2(20, -5), Vector2(28, -5)], [Vector2(28, -5), Vector2(36, -5)]]))})
	_rebuild()
	var before := _area(_body(band))
	var extend_command = FEATURE_COMMAND.new("surface:extend")
	var extend_values: Dictionary = extend_command.defaults()
	extend_values["edges"] = [_edge_ref_at(_body(band), Vector3(0.024, -0.005, 0.01))]
	extend_values["distance"] = "2"
	var old_extend: Resource = extend_command.create_feature(doc, extend_values)
	old_extend.options.erase("chain")
	_rebuild()
	_close(_area(_body(band)) - before, 16.0, 1e-6, "An Extend saved before Chain Selection extends only its 8 mm pick (area added)")
	var extend_reader = FEATURE_COMMAND.new("surface:extend")
	extend_reader.feature = old_extend
	var extend_back: Dictionary = extend_reader.read_values()
	_expect(not bool(extend_back.get("chain", true)), "An old Extend's Chain Selection should read back off (%s)." % extend_back.get("chain", ""))
	extend_reader.write_values(doc, extend_back)
	_rebuild()
	_close(_area(_body(band)) - before, 16.0, 1e-6, "An old Extend edited with nothing changed (area added)")


# --- Round 4: patch safety (folds, sides, lens corners and rims, rails, warnings, stored choices) --

## Walls h mm tall rising from curves on XY (leaning out by -slope deg), and their top edges.
func _k_walls(curves: Array, h: float, slope := 0.0) -> Array:
	var walls = kernel.extrude(kernel.sketch_edges(curves, Transform3D.IDENTITY), {"direction": Vector3(0, 0, 1), "distance": h * MM, "surface": true, "taper": deg_to_rad(slope)})
	return [walls, _k_edges(walls, func(info: Dictionary) -> bool: return absf((info.midpoint as Vector3).z - h * MM) < 1e-7)]


## Lines round the points (mm), closing the loop.
func _k_polygon(points: Array) -> Array:
	var curves := []
	for i in points.size():
		curves.append(_k_line(points[i], points[(i + 1) % points.size()]))
	return curves


## The lowest n.Z over a grid of a one-face Coons patch's normals (over [0, 1]^2), on a cap over a
## loop on XY facing up: below 0 it faces back down somewhere.
func _k_lowest_facing(shape: RefCounted) -> float:
	var n := 32
	var uvs := PackedVector2Array()
	for i in n + 1:
		for j in n + 1:
			uvs.append(Vector2(float(i) / n, float(j) / n))
	var normals: PackedVector3Array = shape.surface_curvatures(0, uvs).get("normals", PackedVector3Array())
	var up := 1.0 if normals[(n + 1) * (n + 1) / 2].z >= 0.0 else -1.0
	var lowest := 1.0
	for normal in normals:
		lowest = minf(lowest, normal.z * up)
	return lowest


## P1: a G1 cap over a concave outline folds over its walls (a dart's curls out over its notch and
## back, a five-lobed flower's reaches past its walls between the lobes), and used to be built and
## thicken to a wrong volume: both are refused for it. Convex and smooth outlines still cap, facing
## no way back down (a square, a kite, a slot, a half disc).
func _check_round4_folds() -> void:
	var dart := _k_walls(_k_polygon([Vector2(0, 0), Vector2(10, -6), Vector2(5, 0), Vector2(10, 6)]), 10.0)
	_k_refused(kernel.patch([{"shape": dart[0], "edges": dart[1], "continuity": 1}], PackedVector3Array(), {"tag": "p"}), "would fold over itself", "A G1 cap on a dart prism")
	var lobes := PackedVector2Array()
	for k in 15:
		lobes.append(Vector2(cos(TAU * k / 15.0), sin(TAU * k / 15.0)) * (6.0 + (2.0 if k % 3 == 0 else 0.0)) * MM)
	var flower := _k_walls([{"type": "interp", "points": lobes, "periodic": true}], 10.0)
	_k_refused(kernel.patch([{"shape": flower[0], "edges": flower[1], "continuity": 1}], PackedVector3Array(), {"tag": "p"}), "would fold over itself", "A G1 cap on a five-lobed flower")
	var slot := [_k_line(Vector2(-5, -2), Vector2(5, -2)), _k_arc(Vector2(5, 0), 2, -PI / 2, PI / 2), _k_line(Vector2(5, 2), Vector2(-5, 2)), _k_arc(Vector2(-5, 0), 2, PI / 2, PI * 1.5)]
	var half_disc := [_k_arc(Vector2.ZERO, 5, -PI / 2, PI / 2), _k_line(Vector2(0, 5), Vector2(0, -5))]
	for spec in [[_k_polygon([Vector2(0, 0), Vector2(10, 0), Vector2(10, 10), Vector2(0, 10)]), "square"], [_k_polygon([Vector2(0, 0), Vector2(10, -6), Vector2(14, 0), Vector2(10, 6)]), "kite"],
			[slot, "slot"], [half_disc, "half disc"]]:
		var walls := _k_walls(spec[0], 10.0)
		var cap = kernel.patch([{"shape": walls[0], "edges": walls[1], "continuity": 1}], PackedVector3Array(), {"tag": "p"})
		_expect(cap != null and str(cap.get_face_names()) == "[\"p:patch\"]", "A G1 cap on a %s prism should build as before (%s)." % [spec[1], kernel.get_last_error()])
		if cap != null:
			var lowest := _k_lowest_facing(cap)
			_expect(lowest > -0.01, "The %s prism's G1 cap should face no way down (lowest n.N %.3f)." % [spec[1], lowest])


## P2: a G1 plate over walls leaning out used to leave them the wrong way, back down along them
## into a bowl (a 3 mm pentagon prism leaning 30 deg out reached z = -15 mm, a hexagon at 60 deg
## -9.6 mm): refused for it. A square over walls leaning out is a Coons cap carrying them on up and
## out above its rim, as before.
func _check_round4_sides() -> void:
	for spec in [[5, -30.0], [6, -60.0]]:
		var corners := []
		for k in spec[0]:
			corners.append(Vector2.from_angle(TAU * k / spec[0]) * 6.0)
		var walls := _k_walls(_k_polygon(corners), 3.0, spec[1])
		_k_refused(kernel.patch([{"shape": walls[0], "edges": walls[1], "continuity": 1}], PackedVector3Array(), {"tag": "p"}), "run back down along those faces",
			"A G1 plate on a %d-sided prism leaning %d deg out" % [spec[0], -spec[1]])
	var square := _k_walls(_k_square(5.0), 3.0, -30.0)
	var cap = kernel.patch([{"shape": square[0], "edges": square[1], "continuity": 1}], PackedVector3Array(), {"tag": "p"})
	_expect(cap != null and absf((cap.bbox() as AABB).position.z - 3 * MM) < 1e-6 * MM and (cap.bbox() as AABB).end.z > 8 * MM,
		"A G1 cap on a square prism leaning 30 deg out should rise above its rim (%s, %s)." % [kernel.get_last_error(), cap.bbox() if cap != null else null])
	# Five or more corners on upright walls: no plate rises steeply enough, so G1 is refused for the
	# walls (a chamfered square's plate missed its boundary and was blamed on a point it hasn't).
	var hexagon := []
	for k in 6:
		hexagon.append(Vector2.from_angle(TAU * k / 6.0) * 6.0)
	for spec in [[hexagon, "hexagon"], [[Vector2(0, 0), Vector2(10, 0), Vector2(10, 4), Vector2(4, 4), Vector2(4, 10), Vector2(0, 10)], "L"],
			[[Vector2(0, 0), Vector2(10, 0), Vector2(10, 9.5), Vector2(9.5, 10), Vector2(0, 10)], "chamfered square"]]:
		var upright := _k_walls(_k_polygon(spec[0]), 10.0)
		_k_refused(kernel.patch([{"shape": upright[0], "edges": upright[1], "continuity": 1}], PackedVector3Array(), {"tag": "p"}), "too steep for it", "A G1 cap on an upright %s prism" % spec[1])


## P5, P6: a lens's end at a shallow corner (a D-cut shaft, whose flat meets its round at 37 deg)
## thickens (Thicken refused its point as a cone's apex; round 5 keeps the round end, whose point
## Thicken takes, see _check_round5_lenses); it carries the walls on in the middle of its sides. A
## tube cap's rim (two half circles
## meeting at the lens's collapsed ends) extended 2 mm naturally, tangentially or square to it is a
## band 2 mm wide all round (it pinched to nothing at the lens's ends, or 1.46 mm square to them).
func _check_round4_lenses() -> void:
	var a := acos(4.0 / 5.0)
	var shaft := _k_walls([_k_arc(Vector2.ZERO, 5, a, TAU - a), _k_line(Vector2(4, -3), Vector2(4, 3))], 10.0)
	var cap = kernel.patch([{"shape": shaft[0], "edges": shaft[1], "continuity": 1}], PackedVector3Array(), {"tag": "p"})
	_expect(cap != null, "A G1 cap on a D-cut shaft should build (%s)." % kernel.get_last_error())
	if cap != null:
		for spec in [[Vector3(-5, 0, 10), "round"], [Vector3(4, 0, 10), "flat"]]:
			var normal: Vector3 = cap.face_normal_at(0, spec[0] * MM)
			_expect(absf(normal.dot(Vector3(1, 0, 0))) > cos(deg_to_rad(1.0)), "The D-cut shaft's cap should carry its %s wall on mid-side (normal %s)." % [spec[1], normal])
		for t in [0.2, 0.05]:
			var thick = kernel.thicken(cap, PackedInt32Array(), {"thickness": t * MM})
			_expect(thick != null and thick.solid_count() == 1, "The D-cut shaft's cap should thicken %s mm (%s)." % [t, kernel.get_last_error()])
	var tube := _k_walls([_k_circle(Vector2.ZERO, 5)], 10.0)
	var lid = kernel.patch([{"shape": tube[0], "edges": tube[1], "continuity": 1}], PackedVector3Array(), {"tag": "p"})
	var rim := _k_edges(lid, func(_info: Dictionary) -> bool: return true) if lid != null else PackedInt32Array()
	for mode in ["natural", "tangent", "perpendicular"]:
		var grown = kernel.extend_surface(lid, PackedInt32Array([rim[0]]), {"distance": 2 * MM, "mode": mode, "chain": true}) if not rim.is_empty() else null
		_expect(grown != null, "Extending a tube cap's rim 2 mm (%s) should build (%s)." % [mode, kernel.get_last_error()])
		if grown == null:
			continue
		var open := []
		for e in grown.edge_count():
			var info: Dictionary = grown.edge_info(e)
			if str(info.type) != "degenerate" and (info.faces as PackedInt32Array).size() == 1:
				open.append(grown.edge_shape(e))
		var boundary = kernel.make_compound(open)
		var widths := []
		for k in 12:
			var at := Vector3(cos(TAU * k / 12.0), sin(TAU * k / 12.0), 0) * 5 * MM + Vector3(0, 0, 10 * MM)
			widths.append(snappedf(float(kernel.closest_points(boundary, kernel.make_vertex(at)).distance) / MM, 0.001))
		_expect(widths.all(func(w: float) -> bool: return absf(w - 2.0) <= 0.01), "A tube cap's rim extended 2 mm (%s) should be a band 2 mm wide all round (%s)." % [mode, widths])


## P7, P8, P9: a patch along a sharply bent rail (a tent of two lines) builds and warns how near it
## passes; G1 over sketch curves (no face beside them) builds G0 and says so, over a body's edges
## with how far its corners fall short of tangency (round 6). A Patch stored with G2 reads back as
## G1, so its panel shows G1 and OK builds a G1 dome; a choice field holding a value it doesn't
## offer shows that value, not its first choice.
func _check_round4_warnings_and_choices() -> void:
	_new_doc()
	var square := _lines("xy", [[Vector2(-5, -5), Vector2(5, -5)], [Vector2(5, -5), Vector2(5, 5)], [Vector2(5, 5), Vector2(-5, 5)], [Vector2(-5, 5), Vector2(-5, -5)]])
	var tent := _lines({"origin": Vector3.ZERO, "x": Vector3.RIGHT, "y": Vector3.BACK}, [[Vector2(-5, 0), Vector2(0, 3)], [Vector2(0, 3), Vector2(5, 0)]])
	var railed := _surface("patch", {}, {"boundary": _curves(square), "rails": _curves(tent)})
	var curved := _surface("patch", {}, {"boundary": _curves(square), "continuity": "g1"})
	var cube := _box(Vector3(30, 0, 0), 10, 10, 10)
	_rebuild()
	_surface("unstitch", {}, {"objects": [_face_ref_at(_body(cube), Vector3(0.03, 0.01, 0))]})
	_rebuild()
	var dome := _surface("patch", {}, {"boundary": _edges_at_height(_body(cube), 0.01), "continuity": "g1"})
	_rebuild()
	_no_error(railed, "A patch along a tent rail")
	_expect(str(result.warnings.get(railed.id, "")) == "The patch passes within 0.10 mm of its rails", "A patch along a tent rail should say how near it passes (%s)." % result.warnings.get(railed.id, ""))
	_no_error(curved, "A G1 patch over sketch curves")
	_expect(str(result.warnings.get(curved.id, "")) == "G1 needs body edges with a face beside them; 4 edges were built G0", "G1 over sketch curves should say it was built G0 (%s)." % result.warnings.get(curved.id, ""))
	_no_error(dome, "A G1 patch over a box's top edges")
	# (Round 6: its corners turn 90 deg off the walls, over 35 % of its rim, which it now says; it
	# said nothing before. See _check_round6_shortfalls.)
	_expect(str(result.warnings.get(dome.id, "")) == "G1 holds along 65% of the boundary; toward the corners the patch turns off the faces by up to 90 deg",
		"G1 over a body's edges should say how far its corners fall short of tangency (%s)." % result.warnings.get(dome.id, ""))
	# A Patch stored with G2: its edit reads G1, the panel shows G1, OK builds the G1 dome.
	var stored := _surface("patch", {}, {"boundary": _edges_at_height(_body(cube), 0.01), "continuity": "g2"})
	_rebuild()
	_expect(str(result.errors.get(stored.id, "")).contains("curvature"), "A stored G2 patch should still be refused as it stands (%s)." % result.errors.get(stored.id, ""))
	var edit = FEATURE_COMMAND.new("surface:patch")
	edit.feature = stored
	var read: Dictionary = edit.read_values()
	_expect(str(read.get("continuity", "")) == "g1", "A stored G2 patch's continuity should read back as G1 (%s)." % read.get("continuity", ""))
	var panel = COMMAND_PANEL.new()
	panel.setup("Patch", edit.fields(), read, "mm")
	var shown: OptionButton = panel._editors.get("continuity")
	_expect(shown != null and str(shown.get_item_metadata(shown.selected)) == "g1" and shown.get_item_text(shown.selected).begins_with("G1"),
		"The stored G2 patch's panel should show G1 (%s)." % [shown.get_item_text(shown.selected) if shown != null else "no field"])
	panel.free()
	edit.write_values(doc, read)
	_rebuild()
	_no_error(stored, "A stored G2 patch edited with nothing changed")
	var edited := _shape(_body(stored))
	_expect(str(stored.options.get("continuity", "")) == "g1" and edited != null and (edited.bbox() as AABB).end.y > 10.5 * MM,
		"The edited G2 patch should build a G1 dome over the box (%s, %s)." % [stored.options.get("continuity", ""), edited.bbox() if edited != null else null])
	# A choice the field doesn't offer (a Ruled corner type no build knows) shows as itself.
	var ruled = FEATURE_COMMAND.new("surface:ruled")
	var values: Dictionary = ruled.defaults()
	values["corner_type"] = "beveled"
	panel = COMMAND_PANEL.new()
	panel.setup("Ruled", ruled.fields(), values, "mm")
	var corner: OptionButton = panel._editors.get("corner_type")
	_expect(corner != null and str(corner.get_item_metadata(corner.selected)) == "beveled" and corner.get_item_text(corner.selected).contains("beveled"),
		"A choice field holding a value it doesn't offer should show it (%s)." % [corner.get_item_text(corner.selected) if corner != null else "no field"])
	values["corner_type"] = "rounded"
	panel.set_values(values)
	values["corner_type"] = "beveled"
	panel.set_values(values)
	_expect(corner != null and str(corner.get_item_metadata(corner.selected)) == "beveled", "Refreshed, the field should show the value it holds again (%s)." % [corner.get_item_metadata(corner.selected) if corner != null else "no field"])
	panel.free()


# --- Round 4: measuring spline bodies, their boxes, Untrim's joints, loft seams ----------------

## The area (mm2), centroid and second moments about the centroid (mm4) of a flat region on XY, from a
## polygon of samples points along each of its edges (one closed loop).
func _k_outline(face: RefCounted, samples: int) -> Dictionary:
	var points := []
	for e in face.edge_count():
		for i in samples:
			points.append(face.edge_point_at(e, float(i) / samples).point / MM)
	var a := 0.0
	var cx := 0.0
	var cy := 0.0
	var xx := 0.0
	var yy := 0.0
	for i in points.size():
		var p: Vector3 = points[i]
		var q: Vector3 = points[(i + 1) % points.size()]
		var c := p.x * q.y - q.x * p.y
		a += c
		cx += (p.x + q.x) * c
		cy += (p.y + q.y) * c
		yy += (p.y * p.y + p.y * q.y + q.y * q.y) * c
		xx += (p.x * p.x + p.x * q.x + q.x * q.x) * c
	a *= 0.5
	cx /= 6.0 * a
	cy /= 6.0 * a
	return {"area": absf(a), "cx": cx, "cy": cy, "yy": absf(yy / 12.0 - a * cy * cy), "xx": absf(xx / 12.0 - a * cx * cx)}


## A flat face (lines round points, mm) in the XY plane of frame.
func _k_flat(points: Array, frame := Transform3D.IDENTITY) -> RefCounted:
	return kernel.patch([{"shape": kernel.sketch_edges(_k_polygon(points), frame), "edges": PackedInt32Array(), "continuity": 0}], PackedVector3Array(), {"tag": "f"})


## K1: volume(), area(), the centre and the inertia are integrated a piece of each spline at a
## time (OCCT's fixed-order rule read spline-bounded solids off: a fit-point horseshoe extruded
## 10 mm by 1.9 %, its walls' area by 1.6 %, a 10 x 5 mm ellipse tapered 10 deg by 2.2 %, a G1 box
## dome thickened 0.05 mm by 19 %). The horseshoe's region is measured by a dense polygon of its
## outline, the taper by the exact draft (A h -+ P h^2 tan a / 2 + pi h^3 tan^2 a / 3), the skins
## by their mean (area x t, to t^2 of its curvature) and their mesh.
func _check_round4_volumes() -> void:
	var shoe := PackedVector2Array()
	for p in [Vector2(0, 0), Vector2(5, -6), Vector2(10, 0), Vector2(10, 8), Vector2(8, 8.5), Vector2(7.5, 1), Vector2(5, -2.5), Vector2(2.5, 1), Vector2(2, 8.5), Vector2(0, 8)]:
		shoe.append(p * MM)
	var outline := {"type": "interp", "points": shoe, "periodic": true}
	var face := _k_region([outline], 92.39)
	_expect(face != null, "The horseshoe's region should be found.")
	if face == null:
		return
	var coarse := _k_outline(face, 4000)
	var fine := _k_outline(face, 8000)
	var area: float = (4.0 * fine.area - coarse.area) / 3.0
	_close(face.area() / MM2, area, 1e-6, "A fit-point horseshoe's region (area against a polygon of its outline)")
	var prism = kernel.extrude(face, {"direction": Vector3(0, 0, 1), "distance": 10 * MM})
	_close(prism.volume() / MM3 if prism != null else -1.0, area * 10.0, 1e-6, "The horseshoe extruded 10 mm (volume)")
	if prism != null:
		var props: Dictionary = prism.mass_properties(1.0)
		var center: Vector3 = props.center / MM
		_expect(center.distance_to(Vector3(fine.cx, fine.cy, 5.0)) < 1e-5, "The horseshoe prism's centre should be its outline's centroid, 5 mm up (%s, %s)." % [center, Vector3(fine.cx, fine.cy, 5.0)])
		var inertia: PackedFloat64Array = props.inertia
		_close(inertia[0] * 1e15, 10.0 * fine.yy + area * 1000.0 / 12.0, 1e-5, "The horseshoe prism's inertia about X through its centre (mm^5)")
		_close(inertia[8] * 1e15, 10.0 * (fine.xx + fine.yy), 1e-5, "The horseshoe prism's inertia about Z through its centre (mm^5)")
	var walls = kernel.extrude(kernel.sketch_edges([outline], Transform3D.IDENTITY), {"direction": Vector3(0, 0, 1), "distance": 10 * MM, "surface": true})
	var perimeter := 0.0
	for e in walls.edge_count():
		var info: Dictionary = walls.edge_info(e)
		if str(info.type) != "degenerate" and absf((info.midpoint as Vector3).z) < 1e-9:
			perimeter += float(info.length) / MM
	_close(walls.area() / MM2, perimeter * 10.0, 1e-6, "The horseshoe's walls 10 mm tall (area)")
	var ellipse := _k_region([{"type": "ellipse", "c": Vector2.ZERO, "major": Vector2(10 * MM, 0), "minor": 5 * MM}], PI * 50.0)
	# (An ellipse's straight wall: OCCT's adaptive rule read it 402-508 mm2 for 484.4.)
	var straight = kernel.extrude(kernel.sketch_edges([{"type": "ellipse", "c": Vector2.ZERO, "major": Vector2(10 * MM, 0), "minor": 5 * MM}], Transform3D.IDENTITY), {"direction": Vector3(0, 0, 1), "distance": 10 * MM, "surface": true})
	_close(straight.area() / MM2 if straight != null else -1.0, 484.42241102738376, 1e-7, "A 10 x 5 mm ellipse's wall 10 mm tall (area)")
	for degrees in [10.0, -10.0]:
		var t := tan(deg_to_rad(absf(degrees)))
		var exact := PI * 500.0 - signf(degrees) * 48.442241102738376 * t * 50.0 + PI * t * t * 1000.0 / 3.0
		var drafted = kernel.extrude(ellipse, {"direction": Vector3(0, 0, 1), "distance": 10 * MM, "taper": deg_to_rad(degrees)})
		_close(drafted.volume() / MM3 if drafted != null else -1.0, exact, 1e-5, "A 10 x 5 mm ellipse tapered %d deg over 10 mm (volume, the exact draft)" % degrees)
	var box = kernel.make_box(Vector3(10, 10, 10) * MM, Vector3.ZERO, "box")
	var sides := PackedInt32Array()
	for f in box.face_count():
		if (box.face_info(f).normal as Vector3).z < 0.99:
			sides.append(f)
	var open_box = kernel.keep_faces(box, sides)
	var dome = kernel.patch([{"shape": open_box, "edges": _k_edges(open_box, func(info: Dictionary) -> bool: return absf((info.midpoint as Vector3).z - 10 * MM) < 1e-7), "continuity": 1}], PackedVector3Array(), {"tag": "p"})
	var skins := []
	for t in [0.05, -0.05]:
		var skin = kernel.thicken(dome, PackedInt32Array(), {"thickness": t * MM}) if dome != null else null
		_expect(skin != null, "The G1 box dome should thicken %s mm (%s)." % [t, kernel.get_last_error()])
		if skin != null:
			skins.append(skin.volume() / MM3)
			_close(skin.volume() / MM3, _k_mesh_volume(skin, 0.002), 1e-3, "The G1 box dome thickened %s mm (volume against its mesh)" % t)
	if skins.size() == 2:
		_close(0.5 * (skins[0] + skins[1]), dome.area() / MM2 * 0.05, 1e-4, "The G1 box dome thickened 0.05 mm either way (mean volume against area x t)")


## K2: bbox() holds the whole shape and stays tight: a hexagon plate through a point dips a micron
## below its rim near an edge, and one through two points too (the box stopped at the rim: OCCT
## trims a face's box to its edges where a search says nothing lies beyond them); flat faces stay
## exactly flat.
func _check_round4_boxes() -> void:
	var hexagon := []
	for k in 6:
		hexagon.append(Vector2.from_angle(TAU * k / 6.0) * 6.0)
	var loop = kernel.sketch_edges(_k_polygon(hexagon), Transform3D.IDENTITY)
	for spec in [[[Vector3(-3, 1.5, 5)], "a point"], [[Vector3(3, 2, 4), Vector3(-3, -2, 1)], "two points"]]:
		var points := PackedVector3Array()
		for p in spec[0]:
			points.append(p * MM)
		var plate = kernel.patch([{"shape": loop, "edges": PackedInt32Array(), "continuity": 0}], points, {"tag": "p"})
		_expect(plate != null, "A hexagon plate through %s should build (%s)." % [spec[1], kernel.get_last_error()])
		if plate == null:
			continue
		var box: AABB = plate.bbox()
		var mesh := AABB()
		var outside := 0.0
		var first := true
		for p in plate.tessellate(0.001 * MM, 0.05).positions:
			mesh = AABB(p, Vector3.ZERO) if first else mesh.expand(p)
			first = false
			for i in 3:
				outside = maxf(outside, maxf(box.position[i] - p[i], p[i] - box.end[i]))
		_expect(outside <= 1e-9 and mesh.position.z < -0.5e-6, "A hexagon plate through %s should lie within its box (%.6f mm out; it dips to z %.6f mm)." % [spec[1], outside / MM, mesh.position.z / MM])
		_expect(box.position.z > mesh.position.z - 0.001 * MM and box.end.z < mesh.end.z + 0.001 * MM, "The plate's box should stay within a micron of it (%s against its mesh %s)." % [box, mesh])
	var blob := PackedVector2Array()
	for p in [Vector2(0, 0), Vector2(5, -6), Vector2(10, 0), Vector2(5, 4)]:
		blob.append(p * MM)
	var blobs: Array = kernel.sketch_regions([{"type": "interp", "points": blob, "periodic": true}], Transform3D(Basis.IDENTITY, Vector3(0, 0, 3 * MM)), 0.0)
	for spec in [[_k_region(_k_square(5.0), 100.0), "square"], [blobs[0].face if not blobs.is_empty() else null, "spline"]]:
		_expect(spec[0] != null and (spec[0].bbox() as AABB).size.z == 0.0, "A flat %s region's box should be flat (%s)." % [spec[1], spec[0].bbox() if spec[0] != null else null])


## K3, K4: Untrim goes by a face's own edges (not their control points) and keeps every edge it
## shares. A tube cut by a tilted plane (its top at z 13.5 mm) untrims to 13.5 mm, not 17.3; with
## its elliptic cap stitched on, it grows only down and stays one sheet (it grew up through its cap
## and split off); a triangle beside a tilted roof and a wall under a slanted roof grow only past
## their free edges, still joined; an L whose shared edge's line runs through it is refused.
func _check_round4_untrim() -> void:
	var tube := _k_sheet([_k_circle(Vector2.ZERO, 5)], 20.0)
	var cutter = kernel.plane_face(Vector3(0, 0, 12) * MM, Vector3(0.3, 0, 1).normalized(), 0.1, "cut")
	var cut = kernel.trim(tube, cutter, PackedVector3Array([Vector3(0, 5, 19) * MM]), {})
	_expect(cut != null and cut.face_count() == 1, "The tube cut by a tilted plane should be one face (%s)." % kernel.get_last_error())
	if cut == null:
		return
	for grow in [0.0, 3.0]:
		var grown = kernel.untrim(cut, PackedInt32Array([0]), PackedInt32Array(), {"mode": "all", "extend": grow * MM})
		var box: AABB = grown.bbox() if grown != null else AABB()
		_expect(grown != null and absf(box.position.z + grow * MM) < 1e-6 * MM and box.end.z <= (13.5 + grow) * MM + 1e-9 and box.end.z > (13.4 + grow) * MM,
			"The cut tube untrimmed (extend %s mm) should run from z -%s to %s mm (%s, %s)." % [grow, grow, 13.5 + grow, box, kernel.get_last_error()])
	var rim := _k_edges(cut, func(info: Dictionary) -> bool: return (info.faces as PackedInt32Array).size() == 1 and (info.midpoint as Vector3).z > 8 * MM)
	var cap = kernel.patch([{"shape": cut, "edges": rim, "continuity": 0}], PackedVector3Array(), {"tag": "cap"})
	var capped = kernel.stitch([cut, cap], {"tolerance": 1e-8, "solid": false})
	var wall := -1
	for f in capped.face_count() if capped != null else 0:
		wall = f if str(capped.face_info(f).type) == "cylinder" else wall
	for grow in [0.0, 3.0]:
		var grown = kernel.untrim(capped, PackedInt32Array([wall]), PackedInt32Array(), {"mode": "all", "extend": grow * MM}) if wall >= 0 else null
		_expect(grown != null and kernel.pieces(grown).size() == 1 and _k_open_shared(grown).y == 1, "The capped cut tube untrimmed (extend %s mm) should stay one sheet joined at its cap (%s)." % [grow, kernel.get_last_error()])
		if grown != null:
			_close(grown.area() / MM2, capped.area() / MM2 + TAU * 5.0 * grow, 1e-6, "The capped cut tube untrimmed, extend %s mm (area: grown down only)" % grow)
	# A right triangle sewn along its hypotenuse to a roof tilted up 30 deg; a wall sewn along its
	# slanted top to a roof.
	var hypotenuse := Vector3(-1, 1, 0).normalized()
	var rise := (Vector3(1, 1, 0).normalized() * cos(deg_to_rad(30)) + Vector3(0, 0, sin(deg_to_rad(30)))).normalized()
	var triangle := _k_flat([Vector2(0, 0), Vector2(10, 0), Vector2(0, 10)])
	var roof := _k_flat([Vector2(0, 0), Vector2(sqrt(200.0), 0), Vector2(sqrt(200.0), 6), Vector2(0, 6)], Transform3D(Basis(hypotenuse, rise, hypotenuse.cross(rise)), Vector3(10, 0, 0) * MM))
	var gable := _k_flat([Vector2(0, 0), Vector2(10, 0), Vector2(10, 4), Vector2(0, 8)], Transform3D(Basis(Vector3(0, 1, 0), Vector3(0, 0, 1), Vector3(1, 0, 0)), Vector3.ZERO))
	var slope := Vector3(0, 1, -0.4).normalized()
	var top := _k_flat([Vector2(0, 0), Vector2(sqrt(116.0), 0), Vector2(sqrt(116.0), 6), Vector2(0, 6)], Transform3D(Basis(slope, Vector3(1, 0, 0), slope.cross(Vector3(1, 0, 0))), Vector3(0, 0, 8) * MM))
	for spec in [[triangle, roof, 50.0, [[0.0, 50.0], [2.0, 98.0]], "triangle beside a tilted roof"], [gable, top, 60.0, [[0.0, 60.0]], "wall under a slanted roof"]]:
		var pair = kernel.stitch([spec[0], spec[1]], {"tolerance": 1e-8, "solid": false})
		var face := -1
		for f in pair.face_count() if pair != null else 0:
			face = f if absf(float(pair.face_info(f).area) / MM2 - spec[2]) < 1e-3 else face
		_expect(face >= 0 and _k_open_shared(pair).y == 1, "The %s should be sewn into one sheet." % spec[4])
		for grown_area in spec[3]:
			var grown = kernel.untrim(pair, PackedInt32Array([face]), PackedInt32Array(), {"mode": "all", "extend": grown_area[0] * MM}) if face >= 0 else null
			_expect(grown != null and kernel.pieces(grown).size() == 1 and _k_open_shared(grown).y == 1, "Untrim All (extend %s mm) on the %s should keep it one sheet (%s)." % [grown_area[0], spec[4], kernel.get_last_error()])
			if grown != null:
				_close(grown.area() / MM2, pair.area() / MM2 - spec[2] + grown_area[1], 1e-6, "Untrim All (extend %s mm) on the %s (area: grown past its free edges only)" % [grown_area[0], spec[4]])
	# An L with a wall standing on its inner edge: that edge's line runs through the L, so it can't
	# grow and stay joined there.
	var ell := _k_flat([Vector2(0, 0), Vector2(10, 0), Vector2(10, 4), Vector2(4, 4), Vector2(4, 10), Vector2(0, 10)])
	var fence := _k_flat([Vector2(4, 0), Vector2(10, 0), Vector2(10, 5), Vector2(4, 5)], Transform3D(Basis(Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(0, -1, 0)), Vector3(0, 4, 0) * MM))
	var fenced = kernel.stitch([ell, fence], {"tolerance": 1e-8, "solid": false})
	var floor_face := -1
	for f in fenced.face_count() if fenced != null else 0:
		floor_face = f if absf(float(fenced.face_info(f).area) / MM2 - 64.0) < 1e-3 else floor_face
	_expect(floor_face >= 0 and _k_open_shared(fenced).y == 1, "The L and its wall should be sewn into one sheet.")
	_k_refused(kernel.untrim(fenced, PackedInt32Array([floor_face]), PackedInt32Array(), {"mode": "all", "extend": 0.0}), "Untrim can't grow this face past its joint with the flat face beside it; unstitch it first",
		"Untrim All on an L whose shared inner edge's line runs through it")


## K5: a loft between unlike loops follows the edges of the one with the most: a square to a circle
## has four walls wherever the circle starts (a circle starting at 0 deg split a side of the square
## in two: five walls), also to a periodic spline started at 30 or 200 deg and to an ellipse turned
## 30 deg. Its walls are named after the square's sides, so a fillet on an edge between two keeps
## its edge when the circle's diameter changes.
func _check_round4_loft_seams() -> void:
	var up := Transform3D(Basis.IDENTITY, Vector3(0, 0, 10 * MM))
	var square := _k_region_at(_k_square(5.0), 100.0, Transform3D.IDENTITY)
	var tops := [[_k_region_at([_k_circle(Vector2.ZERO, 5)], 25.0 * PI, up), "a circle"]]
	for start in [30.0, 200.0]:
		var ring := PackedVector2Array()
		for k in 12:
			ring.append(Vector2.from_angle(deg_to_rad(start) + TAU * k / 12.0) * 5.0 * MM)
		tops.append([_k_region_at([{"type": "interp", "points": ring, "periodic": true}], 25.0 * PI, up), "a spline circle started at %d deg" % start])
	tops.append([_k_region_at([{"type": "ellipse", "c": Vector2.ZERO, "major": Vector2.from_angle(deg_to_rad(30.0)) * 6.0 * MM, "minor": 4.0 * MM}], 24.0 * PI, up), "an ellipse turned 30 deg"])
	for spec in tops:
		var loft = kernel.loft([square, spec[0]], {"tag": "L"}) if spec[0] != null else null
		var walls := Array(loft.get_face_names()).filter(func(n: String) -> bool: return n.begins_with("L:g(")) if loft != null else []
		_expect(loft != null and loft.face_count() == 6 and walls.size() == 4, "A square lofted to %s should have 4 walls named by its sides (%s, %s)." % [spec[1], loft.get_face_names() if loft != null else null, kernel.get_last_error()])
	_new_doc()
	var low := _lines("xy", [[Vector2(-5, -5), Vector2(5, -5)], [Vector2(5, -5), Vector2(5, 5)], [Vector2(5, 5), Vector2(-5, 5)], [Vector2(-5, 5), Vector2(-5, -5)]])
	var high: Resource = doc.add_feature("sketch", "Sketch", {}, SKETCH_DATA.new_options({"origin": Vector3(0, 0, 0.01), "x": Vector3.RIGHT, "y": Vector3.UP}, "frame"))
	var hs = SKETCH_DATA.new(high, doc)
	var circle: int = hs.add_circle(hs.add_point(Vector2.ZERO), 0.005)
	var loft := _add("loft", {}, {"sections": [{"kind": "profile", "sketch": low.feature.id, "point": Vector2.ZERO}, {"kind": "profile", "sketch": high.id, "point": Vector2.ZERO}], "operation": OPERATIONS.NEW_BODY})
	_rebuild()
	_no_error(loft, "Loft from a square to a circle")
	var named := []
	for line in low.lines:
		named.append("%s:g(s%d)" % [loft.id, line])
	var walls := Array(_shape(_body(loft)).get_face_names()).filter(func(n: String) -> bool: return named.has(n)) if _shape(_body(loft)) != null else []
	_expect(walls.size() == 4, "The square-to-circle loft's 4 walls should be named after the square's sides (%s)." % [_shape(_body(loft)).get_face_names() if _shape(_body(loft)) != null else null])
	var fillet := _add("fillet", {"radius": "1 mm"}, {"edges": [_edge_ref_at(_body(loft), Vector3(5, -5, 5) * MM)]})
	_rebuild()
	_no_error(fillet, "A fillet on the edge between two of the loft's walls")
	var before := _volume(_body(loft))
	for radius in [0.004, 0.0065]:
		hs.entity(circle)["r"] = radius
		_rebuild()
		_no_error(fillet, "The fillet after the circle's radius became %s mm" % (radius / MM))
		_expect(not result.get("warnings", {}).has(fillet.id), "The fillet should keep its edge by name when the circle's radius becomes %s mm (%s)." % [radius / MM, result.get("warnings", {}).get(fillet.id, "")])
		_expect(_volume(_body(loft)) > 0.0 and absf(_volume(_body(loft)) - before) > 1.0, "The filleted loft should follow the circle's radius (%s mm3, was %s)." % [_volume(_body(loft)), before])


# --- Round 5: caps that build, rails at any size, stored choices, measures that hold ------------

## The worst angle (deg) between a cap and the walls whose top edges (rim) bound it, at samples
## points along each edge.
func _k_rim_angle(cap: RefCounted, walls: RefCounted, rim: PackedInt32Array, samples := 40) -> float:
	var worst := 0.0
	for e in rim:
		var wall: int = (walls.edge_info(e).faces as PackedInt32Array)[0]
		for k in samples:
			var p: Vector3 = walls.edge_point_at(e, (k + 0.5) / samples).point
			var a: Vector3 = walls.face_normal_at(wall, p)
			var b: Vector3 = cap.face_normal_at(0, p)
			worst = maxf(worst, rad_to_deg(acos(clampf(absf(a.dot(b)), 0.0, 1.0))) if a.length() > 0.5 and b.length() > 0.5 else 90.0)
	return worst


## How many of samples points along each rim edge a cap leaves its wall at by more than 1 deg.
func _k_rim_off(cap: RefCounted, walls: RefCounted, rim: PackedInt32Array, samples := 40) -> int:
	var off := 0
	for e in rim:
		var wall: int = (walls.edge_info(e).faces as PackedInt32Array)[0]
		for k in samples:
			var p: Vector3 = walls.edge_point_at(e, (k + 0.5) / samples).point
			var a: Vector3 = walls.face_normal_at(wall, p)
			var b: Vector3 = cap.face_normal_at(0, p)
			off += 1 if absf(a.dot(b)) < cos(deg_to_rad(1.0)) else 0
	return off


## NEW-patch-1, NEW-patch-2: only a crease, or a cap passing out beyond its walls, is a fold. A G0
## patch round a strip of a cylinder bent past a half turn (190, 240, 270 deg) is the strip itself
## (it faces back down, and was refused as folding); a box capped G1 on two neighbouring sides and
## G0 on the others, facing down a little near its corner but inside its walls, builds and thickens.
func _check_round5_folds() -> void:
	var frame := Transform3D(Basis(Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(0, -1, 0)), Vector3.ZERO)
	for span in [190.0, 240.0, 270.0]:
		var arc := _k_arc(Vector2.ZERO, 5, deg_to_rad(90.0 - span / 2.0), deg_to_rad(90.0 + span / 2.0))
		var strip = kernel.extrude(kernel.sketch_edges([arc], frame), {"direction": Vector3(0, 1, 0), "distance": 10 * MM, "surface": true})
		var rim := _k_edges(strip, func(info: Dictionary) -> bool: return (info.faces as PackedInt32Array).size() == 1)
		var cap = kernel.patch([{"shape": strip, "edges": rim, "continuity": 0}], PackedVector3Array(), {"tag": "p"})
		_expect(cap != null, "A G0 patch round a %d deg strip of a cylinder should build (%s)." % [span, kernel.get_last_error()])
		if cap != null:
			_close(cap.area() / MM2, strip.area() / MM2, 1e-6, "A G0 patch round a %d deg strip of a cylinder (area: the strip's)" % span)
	var box = kernel.make_box(Vector3(10, 10, 10) * MM, Vector3.ZERO, "box")
	var sides := PackedInt32Array()
	for f in box.face_count():
		if (box.face_info(f).normal as Vector3).z < 0.99:
			sides.append(f)
	var open_box = kernel.keep_faces(box, sides)
	var top := _k_edges(open_box, func(info: Dictionary) -> bool: return absf((info.midpoint as Vector3).z - 10 * MM) < 1e-7)
	var each := PackedInt32Array()
	for e in top:
		var m: Vector3 = open_box.edge_info(e).midpoint
		each.append(1 if m.x < 1e-7 or m.y < 1e-7 else 0)
	var mixed = kernel.patch([{"shape": open_box, "edges": top, "continuity": 0, "edge_continuity": each}], PackedVector3Array(), {"tag": "p"})
	_expect(mixed != null, "A box capped G1 on two neighbouring sides and G0 on the others should build (%s)." % kernel.get_last_error())
	if mixed != null:
		var held: AABB = mixed.bbox()
		_expect(held.position.x > -0.001 * MM and held.position.y > -0.001 * MM and held.end.x < 10.001 * MM and held.end.y < 10.001 * MM,
			"The mixed cap should stay inside its walls (%s)." % held)
		_expect(kernel.thicken(mixed, PackedInt32Array(), {"thickness": 0.2 * MM}) != null, "The mixed cap should thicken 0.2 mm (%s)." % kernel.get_last_error())


## P5, NEW-patch-3, P3 (in part): a lens's corner turning up to 45 deg ends round: a D-cut shaft's
## G1 cap carries its walls on all along its rim (round 3 fanned its corners out flat, off the walls
## over a fifth of each side, and refused flats at x = 4.95 to 4.99 mm as folding), comes to a point
## there whose normals turn by the corner's angle only, and thickens 0.2 and 0.05 mm. Where walls
## meet at a sharper corner no smooth cap carries both on: it turns over the shortest ramp its bends
## allow (a half disc's cap leaves its walls at 20 of 80 points along its rim: 28 before).
func _check_round5_lenses() -> void:
	for x in [4.0, 4.5, 4.95, 4.98]:
		var a := acos(x / 5.0)
		var y := sqrt(25.0 - x * x)
		var shaft := _k_walls([_k_arc(Vector2.ZERO, 5, a, TAU - a), _k_line(Vector2(x, -y), Vector2(x, y))], 10.0)
		var cap = kernel.patch([{"shape": shaft[0], "edges": shaft[1], "continuity": 1}], PackedVector3Array(), {"tag": "p"})
		_expect(cap != null, "A G1 cap on a D-cut shaft (flat at x = %s mm) should build (%s)." % [x, kernel.get_last_error()])
		if cap == null:
			continue
		var worst := _k_rim_angle(cap, shaft[0], shaft[1])
		_expect(worst < 1.0, "The D-cut shaft's cap (flat at x = %s mm) should carry its walls on all along its rim (worst %.2f deg)." % [x, worst])
		for t in [0.2, 0.05]:
			var thick = kernel.thicken(cap, PackedInt32Array(), {"thickness": t * MM})
			_expect(thick != null and thick.solid_count() == 1, "The D-cut shaft's cap (flat at x = %s mm) should thicken %s mm (%s)." % [x, t, kernel.get_last_error()])
	var half := _k_walls([_k_arc(Vector2.ZERO, 5, -PI / 2, PI / 2), _k_line(Vector2(0, 5), Vector2(0, -5))], 10.0)
	var lid = kernel.patch([{"shape": half[0], "edges": half[1], "continuity": 1}], PackedVector3Array(), {"tag": "p"})
	_expect(lid != null, "A G1 cap on a half disc should build (%s)." % kernel.get_last_error())
	if lid != null:
		var off := _k_rim_off(lid, half[0], half[1])
		_expect(off <= 20, "The half disc's cap should leave its walls at no more than 20 of 80 points along its rim (%d)." % off)
		_expect(kernel.thicken(lid, PackedInt32Array(), {"thickness": 0.2 * MM}) != null, "The half disc's cap should thicken 0.2 mm (%s)." % kernel.get_last_error())


## P7, NEW-patch-4, P4: a plate over a loop under 10 mm is made scaled up to it (OCCT's plate has
## tolerances of its own): the tent rail on a 3 mm square builds, passing within 0.03 mm (it was
## refused as missed), and a hexagon 1.2 mm across takes a point. Smooth arch rails build at 5 and
## 10 mm (5 of 50 were refused, their boundary misread). A G1 box rim with a point inside is
## refused for its walls, not the point.
func _check_round5_rails() -> void:
	var xz := Transform3D(Basis(Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(0, -1, 0)), Vector3.ZERO)
	var small = kernel.sketch_edges(_k_square(1.5), Transform3D.IDENTITY)
	var tent = kernel.sketch_edges([_k_line(Vector2(-1.5, 0), Vector2(0, 0.9)), _k_line(Vector2(0, 0.9), Vector2(1.5, 0))], xz)
	var tented = kernel.patch([{"shape": small, "edges": PackedInt32Array(), "continuity": 0}], PackedVector3Array(), {"rails": [{"shape": tent, "edges": PackedInt32Array()}]})
	_expect(tented != null and kernel.get_last_warning() == "The patch passes within 0.03 mm of its rails",
		"A tent rail on a 3 mm square should build, passing within 0.03 mm (%s, '%s')." % [kernel.get_last_error(), kernel.get_last_warning()])
	# (The plate rises past its point; scaled up tenfold it is the 12 mm hexagon's plate.)
	var plates := []
	for across in [0.6, 6.0]:
		var hexagon := []
		for k in 6:
			hexagon.append(Vector2.from_angle(TAU * k / 6.0) * across)
		plates.append(kernel.patch([{"shape": kernel.sketch_edges(_k_polygon(hexagon), Transform3D.IDENTITY), "edges": PackedInt32Array(), "continuity": 0}], PackedVector3Array([Vector3(-0.5, 0.25, 0.8333) * across * MM]), {"tag": "p"}))
	_expect(plates[0] != null and plates[1] != null, "Hexagon plates 1.2 and 12 mm across through a point should build (%s)." % kernel.get_last_error())
	if plates[0] != null and plates[1] != null:
		_close((plates[0].bbox() as AABB).end.z * 10.0 / MM, (plates[1].bbox() as AABB).end.z / MM, 1e-3, "The 1.2 mm hexagon plate's top, scaled tenfold (the 12 mm one's)")
	for spec in [[5.0, 4.0, 3.0], [5.0, 4.0, -3.0], [2.5, 1.5, 0.0], [2.5, 2.0, 1.5], [2.5, 2.0, -1.5]]:
		var half: float = spec[0]
		var rise: float = spec[1]
		var c: float = (rise * rise - half * half) / (2.0 * rise)
		var start := atan2(-c, half)
		var arch = kernel.sketch_edges([_k_arc(Vector2(0, c), rise - c, start, PI - start)], Transform3D(xz.basis, Vector3(0, spec[2], 0) * MM))
		var loop = kernel.sketch_edges(_k_square(half), Transform3D.IDENTITY)
		var plate = kernel.patch([{"shape": loop, "edges": PackedInt32Array(), "continuity": 0}], PackedVector3Array(), {"rails": [{"shape": arch, "edges": PackedInt32Array()}]})
		_expect(plate != null, "A %s mm square with an arch rising %s mm at y = %s mm should build (%s)." % [half * 2.0, rise, spec[2], kernel.get_last_error()])
		if plate != null:
			var peak: float = float(kernel.closest_points(plate, kernel.make_vertex(arch.edge_point_at(0, 0.5).point)).distance)
			_expect(peak < 0.002 * half * MM, "That plate should pass through the arch's top (%.5f mm off)." % (peak / MM))
	var box = kernel.make_box(Vector3(10, 10, 10) * MM, Vector3.ZERO, "box")
	var sides := PackedInt32Array()
	for f in box.face_count():
		if (box.face_info(f).normal as Vector3).z < 0.99:
			sides.append(f)
	var open_box = kernel.keep_faces(box, sides)
	var top := _k_edges(open_box, func(info: Dictionary) -> bool: return absf((info.midpoint as Vector3).z - 10 * MM) < 1e-7)
	_k_refused(kernel.patch([{"shape": open_box, "edges": top, "continuity": 1}], PackedVector3Array([Vector3(5, 5, 13) * MM]), {"tag": "p"}), "too steep for it", "A G1 box rim with a point in its middle")


## NEW-patch-5: a Patch over sketch curves stored with G2 builds G0 and says so (curves have no face
## to match; it was refused for curvature). (NEW-patch-6, a G1 dome with perpendicular bands
## thickened, takes OCCT over a minute: tests/holo_forge_surface_slow_test.gd.)
func _check_round5_g2_curves() -> void:
	_new_doc()
	var square := _lines("xy", [[Vector2(-5, -5), Vector2(5, -5)], [Vector2(5, -5), Vector2(5, 5)], [Vector2(5, 5), Vector2(-5, 5)], [Vector2(-5, 5), Vector2(-5, -5)]])
	var stored := _surface("patch", {}, {"boundary": _curves(square), "continuity": "g2"})
	_rebuild()
	_no_error(stored, "A Patch over sketch curves stored with G2")
	_expect(str(result.warnings.get(stored.id, "")) == "G1 needs body edges with a face beside them; 4 edges were built G0", "It should say it was built G0 (%s)." % result.warnings.get(stored.id, ""))


## NEW-measures-1: Untrim's outer loop leaves the holes it keeps as they are: a plate whose round
## hole is sewn to a tube grows past its outer edges and stays joined at the hole (it was refused,
## the hole taken for a slanted joint); taking the hole away too (All) parts it from the tube and is
## refused.
func _check_round5_untrim() -> void:
	var plate := _k_region(_k_square(10.0) + [_k_circle(Vector2.ZERO, 3)], 400.0 - 9.0 * PI)
	var tube = kernel.extrude(kernel.sketch_edges([_k_circle(Vector2.ZERO, 3)], Transform3D.IDENTITY), {"direction": Vector3(0, 0, -1), "distance": 5 * MM, "surface": true})
	var sheet = kernel.stitch([plate, tube], {"tolerance": 1e-8, "solid": false}) if plate != null else null
	var face := -1
	for f in sheet.face_count() if sheet != null else 0:
		face = f if absf(float(sheet.face_info(f).area) / MM2 - (400.0 - 9.0 * PI)) < 1e-3 else face
	_expect(face >= 0 and _k_open_shared(sheet).y == 1, "The holed plate and its tube should be sewn into one sheet.")
	if face < 0:
		return
	for grow in [0.0, 2.0]:
		var grown = kernel.untrim(sheet, PackedInt32Array([face]), PackedInt32Array(), {"mode": "outer", "extend": grow * MM})
		_expect(grown != null and kernel.pieces(grown).size() == 1 and _k_open_shared(grown).y == 1, "Untrim Outer (extend %s mm) on the plate should keep it joined to its tube (%s)." % [grow, kernel.get_last_error()])
		if grown != null:
			var side: float = 20.0 + 2.0 * grow
			_close(grown.area() / MM2, side * side - 9.0 * PI + TAU * 3.0 * 5.0, 1e-6, "Untrim Outer (extend %s mm) on the plate (area: grown past its outer edges)" % grow)
	_k_refused(kernel.untrim(sheet, PackedInt32Array([face]), PackedInt32Array(), {"mode": "all", "extend": 0.0}), "past its joint with the cylindrical face", "Untrim All on the plate whose hole is joined")


## NEW-measures-2, K1: a face is integrated across its fewer pieces (a wall of a 300-point spline
## cut by a tilted plane took 0.5 s for its volume and 1.2 s for its area, every piece of its
## boundary crossing every piece of the wall, a hundred times the uncut prism), and a quarter turn
## of a round surface takes 10 Gauss points (a torus measured 14 times slower than a box; OCCT's
## fixed rule, 4 times). The cut prism is timed against the uncut one, in turns (a limit in
## milliseconds failed whenever the machine was busy).
func _check_round5_measure_speed() -> void:
	var points := PackedVector2Array()
	for k in 300:
		var t: float = TAU * k / 300.0
		points.append(Vector2.from_angle(t) * (10.0 + 0.6 * sin(7.0 * t)) * MM)
	var outline := {"type": "interp", "points": points, "periodic": true}
	var region: Dictionary = {}
	for r in kernel.sketch_regions([outline], Transform3D.IDENTITY, 0.0):
		region = r if region.is_empty() or float(r.area) > float(region.area) else region
	var prism = kernel.extrude(region.face, {"direction": Vector3(0, 0, 1), "distance": 20 * MM})
	var half = kernel.transform_shape(kernel.make_box(Vector3(100, 100, 100) * MM, Vector3(-50, -50, 0) * MM, "h"), Transform3D(Basis(Vector3(0, 1, 0), -atan(0.4)), Vector3(0, 0, 10) * MM), "h")
	var cut = kernel.boolean(prism, half, 1, "c")
	_expect(cut != null, "The 300-point spline prism should be cut by the tilted box (%s)." % kernel.get_last_error())
	if cut != null:
		# Each run on a fresh copy (a shape keeps what it measured).
		var measure_all := func(shape: RefCounted) -> void:
			var copy: RefCounted = shape.copy()
			copy.volume()
			copy.area()
			for f in copy.face_count():
				copy.face_info(f)
		var timing := TIMING.compare(measure_all.bind(cut), measure_all.bind(prism), 5, "measure cut 300-point prism / uncut")
		_expect(timing.ratio < 2.0, "Measuring the cut 300-point spline prism should take about as long as the uncut prism (%.1f ms against %.1f ms)." % [timing.op, timing.calibration])
		var fresh = cut.copy()
		var volume: float = fresh.volume() / MM3
		var area: float = fresh.area() / MM2
		# Below z = 10 + 0.4 x over a region centred on the origin: 10 mm times its area.
		_close(volume, float(region.area) / MM2 * 10.0, 1e-6, "The cut 300-point spline prism (volume)")
		_expect(area > 0.0, "The cut prism should have an area.")
	var torus = kernel.torus({"major_radius": 6 * MM, "minor_radius": 1.5 * MM})
	var box = kernel.make_box(Vector3(10, 10, 10) * MM, Vector3.ZERO, "b")
	var measure_many := func(shape: RefCounted) -> void:
		for k in 50:
			var copy: RefCounted = shape.copy()
			copy.volume()
			copy.area()
	var costs := TIMING.compare(measure_many.bind(torus), measure_many.bind(box), 5, "measure a torus / a box, 50 each")
	_expect(costs.ratio < 8.0, "A torus should measure no more than 8 times slower than a box (%.2f ms, %.2f ms for 50)." % [costs.op, costs.calibration])
	_close(torus.volume() / MM3, 2.0 * PI * PI * 6.0 * 1.5 * 1.5, 1e-9, "A torus (volume)")
	_close(torus.area() / MM2, 4.0 * PI * PI * 6.0 * 1.5, 1e-9, "A torus (area)")


## NEW-measures-3: Shell works on a copy (OCCT's offset changed the body's own edges, failing or
## not: after shelling the horseshoe prism a boolean of it read 100.834 mm3 for 100.824) and refuses
## a shell OCCT hands back as the body was: the spline-walled prism shells at 0.05 and 0.2 mm (it
## came back unchanged), and a square-to-circle loft shelled 0.2 mm is a shell or refused.
func _check_round5_shell() -> void:
	var shoe := PackedVector2Array()
	for p in [Vector2(0, 0), Vector2(5, -6), Vector2(10, 0), Vector2(10, 8), Vector2(8, 8.5), Vector2(7.5, 1), Vector2(5, -2.5), Vector2(2.5, 1), Vector2(2, 8.5), Vector2(0, 8)]:
		shoe.append(p * MM)
	var face := _k_region([{"type": "interp", "points": shoe, "periodic": true}], 92.39)
	var prism = kernel.extrude(face, {"direction": Vector3(0, 0, 1), "distance": 10 * MM}) if face != null else null
	_expect(prism != null, "The horseshoe prism should build.")
	if prism == null:
		return
	var ball = kernel.make_sphere(4 * MM, Vector3(5, 4, 5) * MM, "s")
	var common = kernel.boolean(prism, ball, 2, "c")
	_expect(common != null and common.volume() > 0.0, "The horseshoe prism and a ball should overlap (%s)." % kernel.get_last_error())
	if common == null:
		return
	var before: float = common.volume()
	var top := -1
	for f in prism.face_count():
		var info: Dictionary = prism.face_info(f)
		top = f if str(info.type) == "plane" and (info.normal as Vector3).z > 0.99 else top
	for t in [0.02, 0.05, 0.2]:
		var shelled = kernel.shell(prism, PackedInt32Array([top]), {"thickness": t * MM})
		_expect(shelled != null and shelled.face_count() == 5 and shelled.volume() < 0.5 * prism.volume(), "The horseshoe prism should shell %s mm (%s, %s faces)." % [t, kernel.get_last_error(), shelled.face_count() if shelled != null else 0])
	_close(kernel.boolean(prism, ball, 2, "c").volume(), before, 1e-12, "The horseshoe prism and a ball after three shells (common volume: unchanged)")
	var square := _k_region(_k_square(5.0), 100.0)
	var circle: RefCounted = null
	for r in kernel.sketch_regions([_k_circle(Vector2.ZERO, 5)], Transform3D(Basis.IDENTITY, Vector3(0, 0, 10) * MM), 0.0):
		circle = r.face
	var loft = kernel.loft([square, circle], {"tag": "L"})
	var cap := -1
	for f in loft.face_count() if loft != null else 0:
		var info: Dictionary = loft.face_info(f)
		cap = f if str(info.type) == "plane" and (info.point as Vector3).z > 9 * MM else cap
	var hollow = kernel.shell(loft, PackedInt32Array([cap]), {"thickness": 0.2 * MM}) if cap >= 0 else null
	_expect((hollow != null and hollow.face_count() > loft.face_count() and hollow.volume() < loft.volume()) or (hollow == null and kernel.get_last_error().contains("at that thickness")),
		"A loft shelled 0.2 mm should be a shell or be refused, never come back unchanged (%s)." % kernel.get_last_error())


## NEW-measures-4: edge_info's length is integrated a piece at a time to rounding (OCCT's fixed rule
## read a 10 x 5 mm ellipse 0.13 % long, a 10 x 1 mm one 1.5 %): against a dense polygon of it.
func _check_round5_lengths() -> void:
	for minor in [5.0, 1.0]:
		var edges = kernel.sketch_edges([{"type": "ellipse", "c": Vector2.ZERO, "major": Vector2(10, 0) * MM, "minor": minor * MM}], Transform3D.IDENTITY)
		var polygon := []
		for count in [4000, 8000]:
			var total := 0.0
			var last: Vector3 = edges.edge_point_at(0, 0.0).point
			for i in range(1, count + 1):
				var p: Vector3 = edges.edge_point_at(0, float(i) / count).point
				total += p.distance_to(last)
				last = p
			polygon.append(total / MM)
		_close(float(edges.edge_info(0).length) / MM, (4.0 * polygon[1] - polygon[0]) / 3.0, 1e-7, "A 10 x %s mm ellipse's length" % minor)


## NEW-measures-5: a surface under 10 mm is trimmed scaled up to it (a 0.5 mm tube's cut face came
## out 0.24 % too big), and Untrim reaches the face's own edges (it fell short by the cut's
## tolerance: 2.5 % at 0.5 mm, 0.1 % at 10 mm): a tube r 0.25 mm cut by a plane tilted 0.7 has its
## exact area, and untrimmed runs from its base to the cut's top, 0.775 mm.
func _check_round5_small_trim() -> void:
	for scale in [0.05, 1.0]:
		var u: float = MM * scale
		var tube = kernel.extrude(kernel.sketch_edges([{"type": "circle", "c": Vector2.ZERO, "r": 5 * u}], Transform3D.IDENTITY), {"direction": Vector3(0, 0, 1), "distance": 20 * u, "surface": true})
		var cutter = kernel.plane_face(Vector3(0, 0, 12) * u, Vector3(0.7, 0, 1).normalized(), 100 * u, "cut")
		var cut = kernel.trim(tube, cutter, PackedVector3Array([Vector3(0, 5, 19) * u]), {})
		_expect(cut != null, "The tube x%s should be trimmed (%s)." % [scale, kernel.get_last_error()])
		if cut == null:
			continue
		_close(cut.area() / (u * u), TAU * 5.0 * 12.0, 1e-4, "The tube x%s below a plane tilted 0.7 (area)" % scale)
		var grown = kernel.untrim(cut, PackedInt32Array([0]), PackedInt32Array(), {"mode": "all", "extend": 0.0})
		_expect(grown != null, "The cut tube x%s should untrim (%s)." % [scale, kernel.get_last_error()])
		if grown != null:
			_close((grown.bbox() as AABB).end.z / u, 15.5, 1e-6, "The cut tube x%s untrimmed (its top)" % scale)
			_close(grown.area() / (u * u), TAU * 5.0 * 15.5, 1e-4, "The cut tube x%s untrimmed (area)" % scale)


## K2: a plate overshooting its rim a micron near a corner (a hexagon plate through one point below
## it, 12 mm and 600 mm across) lies inside its box: the climb to its top stays in the face (it ran
## out past the edge and was dropped, the box 1 um short at 12 mm, 67 um at 600 mm).
func _check_round5_boxes() -> void:
	var hexagon := []
	for k in 6:
		hexagon.append(Vector2.from_angle(TAU * k / 6.0) * 6.0)
	for scale in [1.0, 50.0]:
		var corners := []
		for p in hexagon:
			corners.append(p * scale)
		var plate = kernel.patch([{"shape": kernel.sketch_edges(_k_polygon(corners), Transform3D.IDENTITY), "edges": PackedInt32Array(), "continuity": 0}], PackedVector3Array([Vector3(4.5, 0, -2) * scale * MM]), {"tag": "p"})
		_expect(plate != null, "A hexagon plate x%s through a point below it should build (%s)." % [scale, kernel.get_last_error()])
		if plate == null:
			continue
		var box: AABB = plate.bbox()
		var outside := 0.0
		for p in plate.tessellate(0.0005 * scale * MM, 0.02).positions:
			for i in 3:
				outside = maxf(outside, maxf(box.position[i] - p[i], p[i] - box.end[i]))
		_expect(outside <= 1e-9 + 2e-7 * box.size.length(), "The hexagon plate x%s should lie within its box (%.6f mm out)." % [scale, outside / MM])


# --- Round 6: G1 shortfalls told, caps judged on their exact rim, inputs kept, lens bands ------

## The share (%) of the length of a cap's G1 rim along which it lies within a degree of its walls,
## and the most it turns off them (deg), at 40 points along each rim edge (each: the edges'
## continuity, 1 for G1; every edge when empty).
func _k_rim_share(cap: RefCounted, walls: RefCounted, rim: PackedInt32Array, each := PackedInt32Array()) -> Vector2:
	var tangent := 0.0
	var total := 0.0
	var worst := 0.0
	for i in rim.size():
		if not each.is_empty() and each[i] != 1:
			continue
		var wall: int = (walls.edge_info(rim[i]).faces as PackedInt32Array)[0]
		var length: float = float(walls.edge_info(rim[i]).length)
		for k in 40:
			var p: Vector3 = walls.edge_point_at(rim[i], (k + 0.5) / 40.0).point
			var a: Vector3 = walls.face_normal_at(wall, p)
			var b: Vector3 = cap.face_normal_at(0, p)
			var angle := rad_to_deg(acos(clampf(absf(a.dot(b)), 0.0, 1.0))) if a.length() > 0.5 and b.length() > 0.5 else 90.0
			worst = maxf(worst, angle)
			total += length
			tangent += length if angle <= 1.0 else 0.0
	return Vector2(100.0 * tangent / maxf(total, 1e-30), worst)


## The numbers a G1 shortfall warning gives: [share %, worst deg, facing down deg (-1: none)], or
## [] when it gives none.
func _k_shortfall(warning: String) -> Array:
	var found := RegEx.create_from_string("G1 holds along (\\d+)% of the (?:boundary|G1 edges); toward the corners the patch turns off the faces by up to (\\d+) deg(?:, and near a corner it faces down by up to (\\d+) deg past their lean)?$").search(warning)
	if found == null:
		return []
	return [float(found.get_string(1)), float(found.get_string(2)), float(found.get_string(3)) if found.get_string(3) != "" else -1.0]


## The largest of value(p) over a shape's mesh points that lie on it, p in mm (a mesh can hold a
## stray point off a face that comes to a point: such points are passed over).
func _k_worst_on(shape: RefCounted, value: Callable, deflection_mm := 0.005) -> float:
	var points: PackedVector3Array = shape.tessellate(deflection_mm * MM, 0.05).positions
	var values := PackedFloat64Array()
	for p in points:
		values.append(value.call(p / MM))
	var size: float = (shape.bbox() as AABB).size.length()
	var first := -INF
	for k in 60:
		var at := -1
		for i in values.size():
			at = i if values[i] > -INF and (at < 0 or values[i] > values[at]) else at
		if at < 0:
			break
		first = maxf(first, values[at]) if k == 0 else first
		if float(kernel.closest_points(shape, kernel.make_vertex(points[at])).distance) <= 1e-6 * size:
			return values[at]
		values[at] = -INF
	return first if first > -INF else 0.0


## True when outline winds round q (a winding number, not crossings: no ray to graze a corner).
func _k_winds(q: Vector2, outline: PackedVector2Array) -> bool:
	var total := 0.0
	for k in outline.size():
		total += (outline[k] - q).angle_to(outline[(k + 1) % outline.size()] - q)
	return absf(total) > PI


## A1: a G1 cap that can't stay tangent up to its corners (no smooth cap carries both faces on
## there) says along what share of its rim it is tangent and how far it turns off its walls, the
## numbers agreeing with a probe of its rim (it said nothing: a box dome's corners turn 90 deg off
## its walls over 35 % of its rim), and when it faces down past its walls near a corner, how far.
## Caps tangent all round say nothing; the warning stays through a rebuild after an upstream sketch
## edit, and after an undo.
func _check_round6_shortfalls() -> void:
	var a := acos(3.0 / 5.0)
	var tip := acos(3.0 / 9.0)
	var triangle := []
	for k in 3:
		triangle.append(Vector2.from_angle(TAU * k / 3.0) * 6.0)
	for spec in [[_k_square(5.0), "box"], [_k_polygon(triangle), "triangle"], [[_k_arc(Vector2.ZERO, 5, a, TAU - a), _k_line(Vector2(3, -4), Vector2(3, 4))], "D-cut (flat at x = 3 mm)"],
			[[_k_arc(Vector2.ZERO, 5, -PI / 2, PI / 2), _k_line(Vector2(0, 5), Vector2(0, -5))], "half disc"],
			[[_k_arc(Vector2.ZERO, 3, tip - PI, PI - tip), _k_line(Vector2.from_angle(PI - tip) * 3.0, Vector2(-9, 0)), _k_line(Vector2(-9, 0), Vector2.from_angle(PI + tip) * 3.0)], "teardrop"]]:
		var walls := _k_walls(spec[0], 10.0)
		var cap = kernel.patch([{"shape": walls[0], "edges": walls[1], "continuity": 1}], PackedVector3Array(), {"tag": "p"})
		var said := _k_shortfall(kernel.get_last_warning())
		_expect(cap != null and not said.is_empty(), "A G1 cap on a %s prism should build and say how far it falls short of tangency (\"%s\", %s)." % [spec[1], kernel.get_last_warning(), kernel.get_last_error()])
		if cap != null and not said.is_empty():
			var probe := _k_rim_share(cap, walls[0], walls[1])
			_expect(absf(said[0] - probe.x) <= 1.0 and absf(said[1] - probe.y) <= 1.0, "The %s cap's warning (%s %%, %s deg) should agree with its rim (%.1f %%, %.1f deg)." % [spec[1], said[0], said[1], probe.x, probe.y])
	# G1 on two neighbouring sides of an open box: it also faces down near their corner.
	var box = kernel.make_box(Vector3(10, 10, 10) * MM, Vector3.ZERO, "box")
	var sides := PackedInt32Array()
	for f in box.face_count():
		if (box.face_info(f).normal as Vector3).z < 0.99:
			sides.append(f)
	var open_box = kernel.keep_faces(box, sides)
	var top := _k_edges(open_box, func(info: Dictionary) -> bool: return absf((info.midpoint as Vector3).z - 10 * MM) < 1e-7)
	var each := PackedInt32Array()
	for e in top:
		var m: Vector3 = open_box.edge_info(e).midpoint
		each.append(1 if m.x < 1e-7 or m.y < 1e-7 else 0)
	var mixed = kernel.patch([{"shape": open_box, "edges": top, "continuity": 0, "edge_continuity": each}], PackedVector3Array(), {"tag": "p"})
	var told := _k_shortfall(kernel.get_last_warning())
	_expect(mixed != null and kernel.get_last_warning().contains("of the G1 edges") and told.size() == 3 and told[2] > 0.0,
		"A box capped G1 on two neighbouring sides should say how far its corner falls short and faces down (\"%s\")." % kernel.get_last_warning())
	if mixed != null and told.size() == 3 and told[2] > 0.0:
		var probe := _k_rim_share(mixed, open_box, top, each)
		var down := rad_to_deg(asin(clampf(-_k_lowest_facing(mixed), 0.0, 1.0)))
		_expect(absf(told[0] - probe.x) <= 1.0 and absf(told[1] - probe.y) <= 1.0 and absf(told[2] - down) <= 1.0,
			"The mixed box cap's warning (%s %%, %s deg, down %s deg) should agree with a probe of it (%.1f %%, %.1f deg, down %.1f deg)." % [told[0], told[1], told[2], probe.x, probe.y, down])
	# Tangent all round: a tube's cap, a D-cut cap with round ends, caps over round holes in a
	# sphere and a cylinder.
	var quiet := []
	quiet.append([_k_walls([_k_circle(Vector2.ZERO, 5)], 10.0), "tube"])
	var b := acos(4.0 / 5.0)
	quiet.append([_k_walls([_k_arc(Vector2.ZERO, 5, b, TAU - b), _k_line(Vector2(4, -3), Vector2(4, 3))], 10.0), "D-cut with round ends (flat at x = 4 mm)"])
	var sphere = kernel.keep_faces(kernel.make_sphere(10 * MM, Vector3.ZERO, "s"), PackedInt32Array([0]))
	var cylinder = kernel.extrude(kernel.sketch_edges([_k_circle(Vector2.ZERO, 10)], Transform3D(Basis(Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(0, -1, 0)), Vector3(0, -15, 0) * MM)),
		{"direction": Vector3(0, 1, 0), "distance": 30 * MM, "surface": true})
	for spec in [[sphere, "sphere"], [cylinder, "cylinder"]]:
		var tool = kernel.extrude(kernel.sketch_edges([_k_circle(Vector2.ZERO, 4)], Transform3D(Basis.IDENTITY, Vector3(0, 0, 2) * MM)), {"direction": Vector3(0, 0, 1), "distance": 20 * MM, "surface": true})
		var holed = kernel.trim(spec[0], tool, PackedVector3Array([Vector3(0, 0, 10) * MM]), {})
		var hole := _k_edges(holed, func(info: Dictionary) -> bool: return (info.faces as PackedInt32Array).size() == 1 and (info.midpoint as Vector3).z > 5 * MM and absf((info.midpoint as Vector3).y) < 8 * MM) if holed != null else PackedInt32Array()
		quiet.append([[holed, hole], "round hole in a %s" % spec[1]])
	for spec in quiet:
		var cap = kernel.patch([{"shape": spec[0][0], "edges": spec[0][1], "continuity": 1}], PackedVector3Array(), {"tag": "p"}) if spec[0][0] != null else null
		var warning: String = kernel.get_last_warning()
		_expect(cap != null and warning == "" and _k_rim_share(cap, spec[0][0], spec[0][1]).y < 1.0,
			"A G1 cap on a %s, tangent all round, should say nothing (\"%s\", %s)." % [spec[1], warning, kernel.get_last_error()])
	# In the document: the warning of a G1 cap on walls up from a sketch's square, through a rebuild
	# after the square becomes 10 x 12 mm and an undo; a G1 cap stitched onto a tube's end, none.
	_new_doc()
	var square := _lines("xz", [[Vector2(0, 0), Vector2(10, 0)], [Vector2(10, 0), Vector2(10, 10)], [Vector2(10, 10), Vector2(0, 10)], [Vector2(0, 10), Vector2(0, 0)]])
	var walls := _surface("extrude", {"distance": "10 mm"}, {"profiles": _curves(square)})
	var ring: Resource = doc.add_feature("sketch", "Sketch", {}, SKETCH_DATA.new_options(SKETCH_DATA.ORIGIN_PLANES.xz, "xz"))
	var rs = SKETCH_DATA.new(ring, doc)
	rs.add_circle(rs.add_point(Vector2(0.1, 0)), 0.005)
	var pipe := _surface("extrude", {"distance": "10 mm"}, {"profiles": [{"kind": "profile", "sketch": ring.id, "point": Vector2(0.1, 0)}]})
	_rebuild()
	var lid := _surface("patch", {}, {"boundary": _edges_at_height(_body(walls), 0.01), "continuity": "g1"})
	var end := _surface("patch", {}, {"boundary": _edges_at_height(_body(pipe), 0.01), "continuity": "g1", "stitch": true})
	_rebuild()
	_no_error(lid, "A G1 cap on walls up from a sketch")
	_no_error(end, "A G1 cap stitched onto a tube's end")
	var first := str(result.warnings.get(lid.id, ""))
	_expect(not _k_shortfall(first).is_empty(), "The document should show the cap's shortfall (%s)." % [result.warnings])
	_expect(not result.warnings.has(end.id) and _shape(_body(pipe)) != null and _shape(_body(pipe)).face_count() == 2,
		"A G1 cap stitched onto a tube's end, tangent all round, should say nothing (%s)." % result.warnings.get(end.id, ""))
	var before: Dictionary = doc.snapshot()
	var edge: Dictionary = square.data.entity(square.lines[2])
	square.data.set_point(int(edge.p1), Vector2(10, 12) * MM)
	square.data.set_point(int(edge.p2), Vector2(0, 12) * MM)
	_rebuild()
	_no_error(lid, "The G1 cap after its sketch's square became 10 x 12 mm")
	var deeper: RefCounted = _shape(_body(walls))
	_expect(not _k_shortfall(str(result.warnings.get(lid.id, ""))).is_empty() and deeper != null and absf((deeper.bbox() as AABB).size.z - 12 * MM) < 1e-9,
		"After the sketch's square becomes 10 x 12 mm the cap should still say how far it falls short (%s)." % [result.warnings])
	doc.restore(before)
	_rebuild()
	_expect(str(result.warnings.get(lid.id, "")) == first, "After an undo the cap should say what it said first (\"%s\", \"%s\")." % [result.warnings.get(lid.id, ""), first])


## A2, A4: a G1 cap on a boss whose walls lean in stays above its rim and inside the planes of its
## walls: a Coons cap, made flatter where the full one would bulge past them (round 3 gave the 15
## and 20 deg bosses plates dipping 0.24 and 0.10 mm below their rims, which nothing checked beside
## a corner, and refused 25 deg; round 2's 15 deg Coons cap passed 0.09 mm out beyond the walls).
## A square with one side bowed in 2 mm and an annular sector have no cap inside their walls (round
## 2's curled 0.9 mm out over them, facing down): refused as folding over.
func _check_round6_leaning() -> void:
	for lean in [15.0, 20.0, 25.0]:
		var boss := _k_walls(_k_square(5.0), 3.0, lean)
		var cap = kernel.patch([{"shape": boss[0], "edges": boss[1], "continuity": 1}], PackedVector3Array(), {"tag": "p"})
		_expect(cap != null, "A G1 cap on a square boss leaning in %s deg should build (%s)." % [lean, kernel.get_last_error()])
		if cap == null:
			continue
		var t := tan(deg_to_rad(lean))
		var below := _k_worst_on(cap, func(p: Vector3) -> float: return 3.0 - p.z)
		var past := _k_worst_on(cap, func(p: Vector3) -> float: return maxf(absf(p.x), absf(p.y)) - (5.0 - p.z * t))
		# (Within a 500th of its size of the planes, as the cap checks hold it.)
		_expect(below <= 1e-4 and past <= 0.02, "The %s deg boss's cap should stay above its rim and inside its walls' planes (%.4f mm below, %.4f mm past)." % [lean, below, past])
		_expect(kernel.thicken(cap, PackedInt32Array(), {"thickness": 0.2 * MM}) != null, "The %s deg boss's cap should thicken 0.2 mm (%s)." % [lean, kernel.get_last_error()])
	var r := 29.0 / 4.0
	var bowed := [_k_line(Vector2(0, 0), Vector2(10, 0)), _k_line(Vector2(10, 0), Vector2(10, 10)),
		{"type": "arc", "c": Vector2(5, 8.0 + r) * MM, "r": r * MM, "a0": atan2(2.0 - r, -5.0), "a1": atan2(2.0 - r, 5.0), "ccw": false}, _k_line(Vector2(0, 10), Vector2(0, 0))]
	var sector := [_k_arc(Vector2.ZERO, 10, 0.0, PI / 2), _k_line(Vector2(0, 10), Vector2(0, 4)), _k_arc(Vector2.ZERO, 4, 0.0, PI / 2), _k_line(Vector2(4, 0), Vector2(10, 0))]
	for spec in [[bowed, "square with a side bowed in 2 mm"], [sector, "annular sector"]]:
		var walls := _k_walls(spec[0], 10.0)
		_k_refused(kernel.patch([{"shape": walls[0], "edges": walls[1], "continuity": 1}], PackedVector3Array(), {"tag": "p"}), "would fold over itself", "A G1 cap on a %s prism" % spec[1])


## A3: smooth G1 caps over one curve with a concave stretch (kidney, horseshoe, peanut, bean) build
## again and stay inside their walls: a cap is held to the plane of the wall at its nearest point of
## the rim, found exactly (it was the nearest of 23 points an edge, and along a curve bowing between
## them that plane cut the cap, refused as bulging). Caps that fold over stay refused.
func _check_round6_concave() -> void:
	var shapes := {
		"kidney": [Vector2(0, 0), Vector2(4, -3), Vector2(9, -3), Vector2(12, 0), Vector2(9, 3), Vector2(6, 1.2), Vector2(3, 3)],
		"horseshoe": [Vector2(0, 0), Vector2(5, -6), Vector2(10, 0), Vector2(10, 8), Vector2(8, 8.5), Vector2(7.5, 1), Vector2(5, -2.5), Vector2(2.5, 1), Vector2(2, 8.5), Vector2(0, 8)],
		"peanut": [Vector2(-6, 0), Vector2(-4, -3), Vector2(0, -1.8), Vector2(4, -3), Vector2(6, 0), Vector2(4, 3), Vector2(0, 1.8), Vector2(-4, 3)],
		"bean": [Vector2(-6, 0), Vector2(-4, -3), Vector2(0, -3.5), Vector2(4, -3), Vector2(6, 0), Vector2(4, 2.5), Vector2(0, 1.5), Vector2(-4, 2.5)],
	}
	for name in shapes:
		var points := PackedVector2Array()
		for p in shapes[name]:
			points.append(p * MM)
		var curve := {"type": "interp", "points": points, "periodic": true}
		var walls := _k_walls([curve], 10.0)
		var cap = kernel.patch([{"shape": walls[0], "edges": walls[1], "continuity": 1}], PackedVector3Array(), {"tag": "p"})
		_expect(cap != null and kernel.get_last_warning() == "", "A G1 cap on a %s prism should build, tangent all round (%s, \"%s\")." % [name, kernel.get_last_error(), kernel.get_last_warning()])
		if cap == null:
			continue
		var outline := PackedVector2Array()
		var wire = kernel.sketch_edges([curve], Transform3D.IDENTITY)
		for k in 800:
			var q: Vector3 = wire.edge_point_at(0, k / 800.0).point / MM
			outline.append(Vector2(q.x, q.y))
		var outside := _k_worst_on(cap, func(p: Vector3) -> float:
			var q := Vector2(p.x, p.y)
			# (Godot's test reads some points inside a dense outline as outside: a winding number
			# settles those.)
			if Geometry2D.is_point_in_polygon(q, outline) or _k_winds(q, outline):
				return 0.0
			var d := INF
			for k in outline.size():
				d = minf(d, q.distance_to(Geometry2D.get_closest_point_to_segment(q, outline[k], outline[(k + 1) % outline.size()])))
			return d)
		_expect(outside < 0.002, "The %s cap should stay inside its walls (%.4f mm out)." % [name, outside])
		_expect(kernel.thicken(cap, PackedInt32Array(), {"thickness": 0.2 * MM}) != null, "The %s cap should thicken 0.2 mm (%s)." % [name, kernel.get_last_error()])
	for spec in [[[Vector2(0, 0), Vector2(10, -6), Vector2(8.5, 0), Vector2(10, 6)], "deep dart"], [[Vector2(0, 0), Vector2(12, -2), Vector2(10, 0), Vector2(12, 2)], "thin arrow"]]:
		var walls := _k_walls(_k_polygon(spec[0]), 10.0)
		_k_refused(kernel.patch([{"shape": walls[0], "edges": walls[1], "continuity": 1}], PackedVector3Array(), {"tag": "p"}), "would fold over itself", "A G1 cap on a %s prism" % spec[1])


## A7: Patch (built and refused: Coons, lens, plate), Stitch, Extend and Untrim leave the shapes they
## are given as they were, byte for byte (they worked on them: a refused G1 cap changed its walls'
## BREP, a stitch the cap it sewed; OCCT's changes made later shells hang).
func _check_round6_inputs() -> void:
	var shoe := PackedVector2Array()
	for p in [Vector2(0, 0), Vector2(5, -6), Vector2(10, 0), Vector2(10, 8), Vector2(8, 8.5), Vector2(7.5, 1), Vector2(5, -2.5), Vector2(2.5, 1), Vector2(2, 8.5), Vector2(0, 8)]:
		shoe.append(p * MM)
	var sheet := _k_walls([{"type": "interp", "points": shoe, "periodic": true}], 10.0)
	var dart := _k_walls(_k_polygon([Vector2(0, 0), Vector2(10, -6), Vector2(5, 0), Vector2(10, 6)]), 10.0)
	var hexagon := []
	for k in 6:
		hexagon.append(Vector2.from_angle(TAU * k / 6.0) * 6.0)
	var upright := _k_walls(_k_polygon(hexagon), 10.0)
	var box := _k_walls(_k_square(5.0), 10.0)
	var flat = kernel.patch([{"shape": sheet[0], "edges": sheet[1], "continuity": 0}], PackedVector3Array(), {"tag": "p"})
	var dome = kernel.patch([{"shape": box[0], "edges": box[1], "continuity": 1}], PackedVector3Array(), {"tag": "p"})
	var lid_rim := _k_edges(dome, func(_info: Dictionary) -> bool: return true) if dome != null else PackedInt32Array()
	var cases := [
		["a G1 lens cap", [sheet[0]], func() -> RefCounted: return kernel.patch([{"shape": sheet[0], "edges": sheet[1], "continuity": 1}], PackedVector3Array(), {"tag": "p"})],
		["a refused G1 cap on a dart", [dart[0]], func() -> RefCounted: return kernel.patch([{"shape": dart[0], "edges": dart[1], "continuity": 1}], PackedVector3Array(), {"tag": "p"})],
		["a refused G1 plate on a hexagon", [upright[0]], func() -> RefCounted: return kernel.patch([{"shape": upright[0], "edges": upright[1], "continuity": 1}], PackedVector3Array(), {"tag": "p"})],
		["a G1 box dome", [box[0]], func() -> RefCounted: return kernel.patch([{"shape": box[0], "edges": box[1], "continuity": 1}], PackedVector3Array(), {"tag": "p"})],
		["stitch of a sheet and its flat cap", [sheet[0], flat], func() -> RefCounted: return kernel.stitch([sheet[0], flat], {"tolerance": 1e-5, "solid": false})],
		["stitch of the walls and the dome", [box[0], dome], func() -> RefCounted: return kernel.stitch([box[0], dome], {"tolerance": 1e-7, "solid": true})],
		["extend of the dome's rim", [dome], func() -> RefCounted: return kernel.extend_surface(dome, lid_rim, {"distance": 1 * MM, "mode": "perpendicular"})],
		["untrim of the dome", [dome], func() -> RefCounted: return kernel.untrim(dome, PackedInt32Array([0]), PackedInt32Array(), {"mode": "all", "extend": 0.0})],
	]
	for spec in cases:
		var before := []
		for s in spec[1]:
			before.append(s.to_brep_bytes() if s != null else PackedByteArray())
		var made: RefCounted = spec[2].call()
		var changed := []
		for i in spec[1].size():
			if spec[1][i] != null and spec[1][i].to_brep_bytes() != before[i]:
				changed.append(i)
		_expect(changed.is_empty(), "The %s (%s) should leave the shapes it was given as they were (changed: %s)." % [spec[0], "made" if made != null else kernel.get_last_error(), changed])


## The narrowest and widest a band round rim (edges of cap) is, of distance: from points along the
## rim to the nearest of many points along the banded shape's open edges.
func _k_band_widths(cap: RefCounted, rim: PackedInt32Array, banded: RefCounted, distance: float) -> Vector2:
	var far := PackedVector3Array()
	for e in banded.edge_count():
		var info: Dictionary = banded.edge_info(e)
		if str(info.type) != "degenerate" and (info.faces as PackedInt32Array).size() == 1:
			for k in 601:
				far.append(banded.edge_point_at(e, k / 600.0).point)
	var lo := INF
	var hi := 0.0
	for e in rim:
		for k in 17:
			var p: Vector3 = cap.edge_point_at(e, k / 16.0).point
			var d := INF
			for q in far:
				d = minf(d, q.distance_to(p))
			lo = minf(lo, d / distance)
			hi = maxf(hi, d / distance)
	return Vector2(lo, hi)


## A6: a lens cap's rim extended square to it keeps its full width all round (an ellipse cap's band
## was 12 % narrow at the lens's ends: its far edge ran through 25 points, by its own length, so a
## rim turning fast there was cut across): ellipse, slot and egg caps 10 mm long, a 30th of that
## out. (Every mode at 0.5, 10 and 500 mm: tests/holo_forge_surface_slow_test.gd.)
func _check_round6_lens_bands() -> void:
	var ellipse := PackedVector2Array()
	for k in 24:
		ellipse.append(Vector2(cos(TAU * k / 24.0) * 15.0, sin(TAU * k / 24.0) * 3.0) * MM / 3.0)
	var egg := PackedVector2Array()
	for p in [Vector2(-6, 0), Vector2(-3, -3.5), Vector2(3, -3), Vector2(6, 0), Vector2(3, 3), Vector2(-3, 3.5)]:
		egg.append(p * MM * 10.0 / 12.0)
	var s := 10.0 / 14.0
	var slot := [_k_line(Vector2(-5, -2) * s, Vector2(5, -2) * s), _k_arc(Vector2(5, 0) * s, 2 * s, -PI / 2, PI / 2), _k_line(Vector2(5, 2) * s, Vector2(-5, 2) * s), _k_arc(Vector2(-5, 0) * s, 2 * s, PI / 2, PI * 1.5)]
	for spec in [[[{"type": "interp", "points": ellipse, "periodic": true}], "ellipse"], [slot, "slot"], [[{"type": "interp", "points": egg, "periodic": true}], "egg"]]:
		var walls := _k_walls(spec[0], 3.0)
		var cap = kernel.patch([{"shape": walls[0], "edges": walls[1], "continuity": 1}], PackedVector3Array(), {"tag": "p"})
		var rim := _k_edges(cap, func(_info: Dictionary) -> bool: return true) if cap != null else PackedInt32Array()
		var banded = kernel.extend_surface(cap, PackedInt32Array([rim[0]]), {"distance": MM / 3.0, "mode": "perpendicular", "chain": true}) if not rim.is_empty() else null
		_expect(banded != null, "A %s lens cap's rim should extend square to it (%s)." % [spec[1], kernel.get_last_error()])
		if banded != null:
			var widths := _k_band_widths(cap, rim, banded, MM / 3.0)
			_expect(widths.x > 0.99 and widths.y < 1.01, "The %s cap's band should be as wide as asked all round (%.4f..%.4f of it)." % [spec[1], widths.x, widths.y])


## A8: a patch refused for a rail beside its boundary names its rails (it asked whether a point was);
## a G1 plate over walls leaning out is refused for their lean at every size (a pentagon leaning
## 30 deg out was "too steep" at 0.05 and 50 times its size: which way OCCT's plate fails hangs on
## its size).
func _check_round6_reasons() -> void:
	var loop = kernel.sketch_edges(_k_square(5.0), Transform3D.IDENTITY)
	var xz := Transform3D(Basis(Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(0, -1, 0)), Vector3(0, 4.9, 0) * MM)
	var beside = kernel.sketch_edges([_k_line(Vector2(-4, 0), Vector2(0, 3)), _k_line(Vector2(0, 3), Vector2(4, 0))], xz)
	_k_refused(kernel.patch([{"shape": loop, "edges": PackedInt32Array(), "continuity": 0}], PackedVector3Array(), {"rails": [{"shape": beside, "edges": PackedInt32Array()}]}),
		"through its boundary and rails (is a rail beside the boundary?)", "A patch with a rail beside its boundary")
	for spec in [[5, -30.0], [6, -60.0]]:
		for scale in [0.05, 1.0, 50.0]:
			var corners := []
			for k in spec[0]:
				corners.append(Vector2.from_angle(TAU * k / spec[0]) * 6.0 * scale)
			var walls := _k_walls(_k_polygon(corners), 3.0 * scale, spec[1])
			_k_refused(kernel.patch([{"shape": walls[0], "edges": walls[1], "continuity": 1}], PackedVector3Array(), {"tag": "p"}), "run back down along those faces",
				"A G1 plate on a %d-sided prism leaning %d deg out, x%s" % [spec[0], -spec[1], scale])


## A9: a choice field keeps one choice at most for a value it doesn't offer, gone once the value is
## an offered one (refreshing the panel added another each time: 3, then 4).
func _check_round6_unoffered() -> void:
	var ruled = FEATURE_COMMAND.new("surface:ruled")
	var values: Dictionary = ruled.defaults()
	var panel = COMMAND_PANEL.new()
	panel.setup("Ruled", ruled.fields(), values, "mm")
	var corner: OptionButton = panel._editors.get("corner_type")
	var offered := corner.item_count
	var counts := []
	for value in ["beveled", "rounded", "beveled", "chamfered", "beveled", "mitered", null, "chamfered"]:
		values["corner_type"] = value
		panel.set_values(values)
		counts.append(corner.item_count - offered)
		var shown: Variant = corner.get_item_metadata(corner.selected)
		_expect(str(shown) == str(panel.values.corner_type) and (value == null or str(shown) == str(value)), "The corner type shown should be the value held (%s shown for %s)." % [shown, value])
	_expect(counts == [1, 0, 1, 1, 1, 0, 0, 1], "A value not offered should have one choice at most, gone once it is offered (extra choices %s)." % [counts])
	panel.free()


## Round 8 helpers: a 10 mm sphere's face (one, holed again each time, as a user would) holed by a
## tool extruded along axis from curves drawn square to it (2 mm out), and the hole's edges (on the
## face only, toward axis).
var _k_sphere: RefCounted = null


func _k_holed_sphere(curves: Array, axis := Vector3(0, 0, 1)) -> Array:
	if _k_sphere == null:
		_k_sphere = kernel.keep_faces(kernel.make_sphere(10 * MM, Vector3.ZERO, "s"), PackedInt32Array([0]))
	var sphere: RefCounted = _k_sphere
	var z := axis.normalized()
	var x := Vector3(1, 0, 0) if absf(z.z) > 0.99 else Vector3(0, 0, 1).cross(z).normalized()
	var y := z.cross(x)
	var tool = kernel.extrude(kernel.sketch_edges(curves, Transform3D(Basis(x, y, z), z * 2 * MM)), {"direction": z, "distance": 20 * MM, "surface": true})
	var holed = kernel.trim(sphere, tool, PackedVector3Array([z * 10 * MM]), {})
	if holed == null:
		return [null, PackedInt32Array()]
	return [holed, _k_edges(holed, func(info: Dictionary) -> bool:
		var m: Vector3 = info.midpoint
		return (info.faces as PackedInt32Array).size() == 1 and m.dot(z) > 5 * MM and (m - z * m.dot(z)).length() < 5 * MM)]


## The most a cap over a sphere's hole turns off the sphere (whose normal is radial) along the hole,
## deg.
func _k_sphere_rim(cap: RefCounted, holed: RefCounted, hole: PackedInt32Array) -> float:
	var worst := 0.0
	for e in hole:
		for k in 100:
			var p: Vector3 = holed.edge_point_at(e, (k + 0.5) / 100.0).point
			worst = maxf(worst, rad_to_deg(acos(clampf(absf((cap.face_normal_at(0, p) as Vector3).dot(p.normalized())), 0.0, 1.0))))
	return worst


## Round 8 (caps): G1 caps over holes whose sides are several edges (a side drawn as two lines, a
## sphere's seam splitting one) say nothing where they are tangent (each edge was matched to its
## neighbour on the same circle, and the faces' normals read off it: warnings of up to 27 deg), a
## G1 plate over a pentagon split by the seam builds (it crashed the editor), and a round hole
## drilled through the seam is capped (it was refused as too steep); distances to Coons and lens
## caps are exact (OCCT's search read points on them 4-7 mm away); a cap over walls leaning out 35
## deg says nothing of facing down (it said 25 deg); a corner's narrow turn off its walls is told (it
## said 4 deg where it turns 13); 6-gon prisms give one reason at any size; a bowed side's fold isn't
## blamed on its bend; stitching keeps the names of the faces it sews (they were renamed by place)
## and a shared face once; a lean-in cap passing out past its walls' planes says how far.
func _check_round8_caps() -> void:
	var a := Vector2(4, 0)
	var b := Vector2(0, 4)
	var c := Vector2(-4, 0)
	var d := Vector2(0, -4)
	var turned := []
	for k in 4:
		turned.append(Vector2.from_angle(PI / 2.0 * k + 0.7) * 4.0)
	var holes := [
		[[_k_line(a, b), _k_line(b, (b + c) / 2), _k_line((b + c) / 2, c), _k_line(c, d), _k_line(d, a)], Vector3(0, 0, 1), "square hole with a side in two"],
		[_k_polygon(turned), Vector3(0, 0, 1), "turned square hole split by the seam"],
		[[_k_circle(Vector2.ZERO, 4)], Vector3(1, 0, 0), "round hole through the seam"],
		[[_k_circle(Vector2.ZERO, 4)], Vector3(0.894427, 0, 0.447214), "round hole drilled up through the seam"],
	]
	for spec in holes:
		var made := _k_holed_sphere(spec[0], spec[1])
		var cap = kernel.patch([{"shape": made[0], "edges": made[1], "continuity": 1}], PackedVector3Array(), {"tag": "p"}) if made[0] != null else null
		var warning: String = kernel.get_last_warning()
		var worst := _k_sphere_rim(cap, made[0], made[1]) if cap != null else 90.0
		_expect(cap != null and worst < 1.0 and warning == "", "A G1 cap over a sphere's %s (%d edges) should build tangent and say nothing (%.2f deg off, \"%s\", %s)." % [spec[2], made[1].size(), worst, warning, kernel.get_last_error()])
	var pentagon := []
	for k in 5:
		pentagon.append(Vector2.from_angle(TAU * k / 5.0 + 0.3) * 4.0)
	var holed := _k_holed_sphere(_k_polygon(pentagon))
	var plate = kernel.patch([{"shape": holed[0], "edges": holed[1], "continuity": 1}], PackedVector3Array(), {"tag": "p"})
	_expect(plate != null and _k_sphere_rim(plate, holed[0], holed[1]) < rad_to_deg(0.05), "A G1 plate over a pentagon hole split by the sphere's seam should build tangent (%s, %s)." % [plate.get_face_names() if plate != null else "", kernel.get_last_error()])
	# Distances to caps: points 1 mm above their middles, and points of their meshes.
	for spec in [[[_k_circle(Vector2.ZERO, 5)], "tube"], [_k_square(5.0), "box"]]:
		var walls := _k_walls(spec[0], 10.0)
		var cap = kernel.patch([{"shape": walls[0], "edges": walls[1], "continuity": 1}], PackedVector3Array(), {"tag": "p"})
		var mesh: Dictionary = cap.tessellate(0.05 * MM, 0.2)
		var normals: PackedVector3Array = cap.surface_curvatures(0, mesh.uvs).normals
		var off := 0.0
		var on := 0.0
		var count := 0
		for k in range(0, mesh.positions.size(), maxi(1, mesh.positions.size() / 300)):
			var p: Vector3 = mesh.positions[k]
			if Vector2(p.x, p.y).length() > 3 * MM:
				continue
			count += 1
			var n: Vector3 = normals[k] * (1.0 if normals[k].z > 0.0 else -1.0)
			on = maxf(on, float(kernel.closest_points(cap, kernel.make_vertex(p)).distance))
			off = maxf(off, absf(float(kernel.closest_points(cap, kernel.make_vertex(p + n * MM)).distance) - MM))
		# (Within the single precision the points are given in.)
		_expect(count >= 5 and on < 1e-7 and off < 1e-7, "Distances to a G1 %s cap should be exact (points on it %s mm away, 1 mm above it off by %s mm, %d points)." % [spec[1], String.num_scientific(on / MM), String.num_scientific(off / MM), count])
	# Walls leaning out 35 deg: the cap leans out with them, never further.
	var k3 := acos(3.0 / 5.0)
	var dcut := [_k_arc(Vector2.ZERO, 5, k3, TAU - k3), _k_line(Vector2(3, -4), Vector2(3, 4))]
	var leaning := _k_walls(dcut, 10.0, -35.0)
	var mushroom = kernel.patch([{"shape": leaning[0], "edges": leaning[1], "continuity": 1}], PackedVector3Array(), {"tag": "p"})
	_expect(mushroom != null and not kernel.get_last_warning().contains("faces down"), "A G1 cap over a D-cut's walls leaning out 35 deg shouldn't say it faces down past them (\"%s\", %s)." % [kernel.get_last_warning(), kernel.get_last_error()])
	# Leaning out 30 deg: the turn off the walls toward the corners, against a probe close to them.
	leaning = _k_walls(dcut, 10.0, -30.0)
	var narrow = kernel.patch([{"shape": leaning[0], "edges": leaning[1], "continuity": 1}], PackedVector3Array(), {"tag": "p"})
	var told := RegEx.create_from_string("up to (\\d+) deg").search(kernel.get_last_warning())
	var probe := 0.0
	for e in leaning[1]:
		var wall: int = (leaning[0].edge_info(e).faces as PackedInt32Array)[0]
		for k in 25:
			var t := pow(10.0, -5.0 + 3.7 * k / 24.0)
			for at in [t, 1.0 - t]:
				var p: Vector3 = leaning[0].edge_point_at(e, at).point
				probe = maxf(probe, rad_to_deg(acos(clampf(absf((leaning[0].face_normal_at(wall, p) as Vector3).dot(narrow.face_normal_at(0, p))), 0.0, 1.0)))) if narrow != null else probe
	_expect(narrow != null and told != null and absf(float(told.get_string(1)) - probe) <= 3.0, "A D-cut cap over walls leaning out 30 deg should tell how far it turns off them near its corners (\"%s\", probe %.1f deg)." % [kernel.get_last_warning(), probe])
	# 6-gon prisms leaning out: the same reason at x0.02 and x0.05 as at full size.
	var hexagon := []
	for k in 6:
		hexagon.append(Vector2.from_angle(TAU * k / 6.0) * 6.0)
	for spec in [[25.0, 0.02, "run back down"], [10.0, 0.05, "too steep"]]:
		var reasons := []
		for s in [1.0, spec[1]]:
			var scaled := []
			for p in hexagon:
				scaled.append(p * s)
			var w := _k_walls(_k_polygon(scaled), 3.0 * s, -spec[0])
			kernel.patch([{"shape": w[0], "edges": w[1], "continuity": 1}], PackedVector3Array(), {"tag": "p"})
			reasons.append(kernel.get_last_error())
		_expect(str(reasons[0]).contains(spec[2]) and reasons[1] == reasons[0], "A G1 cap on a 6-gon prism leaning out %s deg should be refused alike at x1 and x%s (%s)." % [spec[0], spec[1], reasons])
	# A side bowed in 1 mm: refused as folding over, not blamed on a sharp bend.
	var r := 13.0
	var bowed := [_k_line(Vector2(0, 0), Vector2(10, 0)), _k_line(Vector2(10, 0), Vector2(10, 10)),
		{"type": "arc", "c": Vector2(5, 9.0 + r) * MM, "r": r * MM, "a0": atan2(1.0 - r, -5.0), "a1": atan2(1.0 - r, 5.0), "ccw": false}, _k_line(Vector2(0, 10), Vector2(0, 0))]
	var bow := _k_walls(bowed, 10.0)
	var folded = kernel.patch([{"shape": bow[0], "edges": bow[1], "continuity": 1}], PackedVector3Array(), {"tag": "p"})
	_expect(bow[1].size() == 4 and (folded != null or (kernel.get_last_error().contains("fold over itself") and not kernel.get_last_error().contains("too sharply"))),
		"A G1 cap on a square with a side bowed in 1 mm should build, or fold without blaming a sharp bend (%d rim edges, \"%s\")." % [bow[1].size(), kernel.get_last_error()])
	# Stitching keeps the names of the faces it sews, and a face the shapes share once.
	var box := _k_walls(_k_square(5.0), 10.0)
	var dome = kernel.patch([{"shape": box[0], "edges": box[1], "continuity": 1}], PackedVector3Array(), {"tag": "p"})
	var sewn = kernel.stitch([box[0], dome], {"tolerance": 1e-7, "solid": true})
	var names: Array = Array(box[0].get_face_names()) + ["p:patch"]
	var kept: Array = Array(sewn.get_face_names()) if sewn != null else []
	names.sort()
	kept.sort()
	_expect(kept == names, "Stitching walls and their dome should keep the faces' names (%s, not %s)." % [names, kept])
	var shared = kernel.stitch([box[0], kernel.keep_faces(box[0], PackedInt32Array([0]))], {"tolerance": 1e-5, "solid": false})
	_expect(shared != null and shared.face_count() == 4, "Stitching walls with one of their own faces should keep that face once (%d faces)." % [shared.face_count() if shared != null else -1])
	# A lean-in boss whose cap passes out past its walls' planes (within the 500th of its size held
	# to) says how far.
	var boss := _k_walls(_k_square(5.0), 3.0, 26.0)
	var lid = kernel.patch([{"shape": boss[0], "edges": boss[1], "continuity": 1}], PackedVector3Array(), {"tag": "p"})
	var lid_warning: String = kernel.get_last_warning()
	var lean := tan(deg_to_rad(26.0))
	var past := _k_worst_on(lid, func(p: Vector3) -> float: return maxf(absf(p.x), absf(p.y)) - (5.0 - p.z * lean)) if lid != null else 0.0
	var said := RegEx.create_from_string("passes out past the planes of its G1 faces by up to ([0-9.]+) mm").search(lid_warning)
	_expect(lid != null and (past <= 1e-3 or (said != null and absf(float(said.get_string(1)) - past) <= 0.25 * past + 1e-3)),
		"A G1 cap on a boss leaning in 26 deg passing %.4f mm out past its walls' planes should say so (\"%s\")." % [past, lid_warning])



## Round 9: normals read off caps 0.5 mm across, and off a seam-split plate's rim 500 mm across, are
## the surface's own (they were up to 85 and 90 deg off, and the plate's stitched seam read 16 deg);
## distances to a plate's points near its rim are exact (measured in millimetres, its tolerance had
## swollen to 1 % of its size there); a lid stitched in through its box's floor is refused (it made
## a solid crossing itself, with a volume); thickens and offsets of small L sheets and U channels are
## exact (they came out up to 14 % and 65 % off); sections of small stitched and thickened caps are
## the same sections at 10 mm, scaled (they read 0, or lost their hole).
func _check_round9_fixes() -> void:
	# Normals at the meshes' own points of G1 caps 0.5 mm across.
	for spec in [[_k_square(0.25), "box dome"], [[_k_circle(Vector2.ZERO, 0.25)], "tube cap"]]:
		var walls := _k_walls(spec[0], 0.5)
		var cap = kernel.patch([{"shape": walls[0], "edges": walls[1], "continuity": 1}], PackedVector3Array(), {"tag": "p"})
		var worst := 90.0
		if cap != null:
			worst = 0.0
			var mesh: Dictionary = cap.tessellate((cap.bbox() as AABB).size.length() * 5e-4, 0.2)
			var exact: PackedVector3Array = cap.surface_curvatures(0, mesh.uvs).normals
			for k in range(0, mesh.positions.size(), maxi(1, mesh.positions.size() / 300)):
				var got: Vector3 = cap.face_normal_at(0, mesh.positions[k])
				worst = maxf(worst, rad_to_deg(acos(clampf(absf(got.normalized().dot(exact[k].normalized())), 0.0, 1.0))) if got.length() > 0.5 else 90.0)
		_expect(worst < 1.0, "face_normal_at on a 0.5 mm G1 %s should match the surface's normal at its own points (worst %.2f deg)." % [spec[1], worst])
	# A G1 plate over a 7-gon hole in a sphere 1 m across, split by the sphere's seam: along the hole
	# its normal is the sphere's (radial), and stitched to the sphere it meets it at 0 deg.
	var r := 0.5
	var sphere = kernel.keep_faces(kernel.make_sphere(r, Vector3.ZERO, "s"), PackedInt32Array([0]))
	var heptagon := []
	for k in 7:
		heptagon.append(Vector2.from_angle(TAU * k / 7.0 + 0.7) * 0.4 * r / MM)
	var along := Basis(Vector3(0, 1, 0), Vector3(0, 0, 1), Vector3(1, 0, 0))
	var tool = kernel.extrude(kernel.sketch_edges(_k_polygon(heptagon), Transform3D(along, Vector3(0.2 * r, 0, 0))), {"direction": Vector3(1, 0, 0), "distance": 2.0 * r, "surface": true})
	var holed = kernel.trim(sphere, tool, PackedVector3Array([Vector3(r, 0, 0)]), {})
	var hole := _k_edges(holed, func(info: Dictionary) -> bool:
		var m: Vector3 = info.midpoint
		return (info.faces as PackedInt32Array).size() == 1 and m.x > 0.5 * r and Vector2(m.y, m.z).length() < 0.47 * r) if holed != null else PackedInt32Array()
	var plate = kernel.patch([{"shape": holed, "edges": hole, "continuity": 1}], PackedVector3Array(), {"tag": "p"}) if holed != null else null
	var rim_off := 90.0
	var seam := 90.0
	if plate != null:
		rim_off = 0.0
		for e in hole:
			for k in 40:
				var p: Vector3 = holed.edge_point_at(e, (k + 0.5) / 40.0).point
				rim_off = maxf(rim_off, rad_to_deg(acos(clampf(absf((plate.face_normal_at(0, p) as Vector3).dot(p.normalized())), 0.0, 1.0))))
		var sewn = kernel.stitch([holed, plate], {"tolerance": 1e-6 * r / 0.01, "solid": false})
		seam = 0.0 if sewn != null else 90.0
		for e in (sewn.edge_count() if sewn != null else 0):
			var info: Dictionary = sewn.edge_info(e)
			if info.has("dihedral"):
				seam = maxf(seam, rad_to_deg(float(info.dihedral)))
	_expect(hole.size() >= 8 and rim_off < 1.0 and seam < 1.0, "A G1 plate over a seam-split 7-gon hole in a 1 m sphere should read the sphere's normal along the hole and meet it at 0 deg (%d edges, %.2f deg off, seam %.2f deg; %s)." % [hole.size(), rim_off, seam, kernel.get_last_error()])
	# Distances to a G0 hexagon plate pulled up by a point, at its own points next to its rim (on
	# isocurves, beside their ends), at 10 and 0.5 mm.
	for s in [1.0, 0.05]:
		var hexagon := []
		for k in 6:
			hexagon.append(Vector2.from_angle(TAU * k / 6.0) * 5.0 * MM * s)
		var lines := []
		for k in 6:
			lines.append({"type": "line", "a": hexagon[k], "b": hexagon[(k + 1) % 6]})
		var hw = kernel.extrude(kernel.sketch_edges(lines, Transform3D.IDENTITY), {"direction": Vector3(0, 0, 1), "distance": 10 * MM * s, "surface": true})
		var top := _k_edges(hw, func(info: Dictionary) -> bool: return absf((info.midpoint as Vector3).z - 10 * MM * s) < 1e-7 * s)
		var pulled = kernel.patch([{"shape": hw, "edges": top, "continuity": 0}], PackedVector3Array([Vector3(0, 0, 13) * MM * s]), {"tag": "p"})
		var far := 1.0
		var count := 0
		if pulled != null:
			far = 0.0
			for run in pulled.face_isocurves(0, 10, 10, 400):
				var pts: PackedVector3Array = run.points
				for idx in [1, 2, 3, 4, pts.size() - 2, pts.size() - 3, pts.size() - 4, pts.size() - 5]:
					if idx > 0 and idx < pts.size() - 1:
						count += 1
						far = maxf(far, float(kernel.closest_points(pulled, kernel.make_vertex(pts[idx])).distance))
		_expect(count > 50 and far <= 1e-6 * 10.0 * MM * s, "Points of a G0 hexagon plate (x%s) next to its rim should read on it (%d points, worst %s mm)." % [s, count, String.num_scientific(far / MM)])
	# An open 10 mm box lidded by a G0 patch through a point below its floor, and one above it.
	var box = kernel.make_box(Vector3(10, 10, 10) * MM, Vector3(-5, -5, 0) * MM, "b")
	var sides := PackedInt32Array()
	for f in box.face_count():
		if (box.face_info(f).normal as Vector3).z < 0.99:
			sides.append(f)
	var open = kernel.keep_faces(box, sides)
	var rim := _k_edges(open, func(info: Dictionary) -> bool: return (info.faces as PackedInt32Array).size() == 1)
	for depth in [-2.0, 5.0]:
		var lid = kernel.patch([{"shape": open, "edges": rim, "continuity": 0}], PackedVector3Array([Vector3(0, 0, depth) * MM]), {"tag": "p"})
		var sewn = kernel.stitch([open, lid], {"tolerance": 1e-6, "solid": true}) if lid != null else null
		if depth < 0.0:
			_expect(lid != null and sewn == null and kernel.get_last_error().contains("cross each other"), "A lid through a point below its box's floor, stitched in, should be refused (%s, \"%s\")." % [sewn.volume() / MM3 if sewn != null else "null", kernel.get_last_error()])
		else:
			_expect(sewn != null and sewn.solid_count() == 1 and sewn.volume() > 0.0 and sewn.volume() < 1000 * MM3, "A lid dipping to 5 mm inside its box, stitched in, should close it (%s)." % kernel.get_last_error())
	# An L sheet with 1.2 mm legs, 0.8 mm long, thickened 0.1 mm either way and both ways: mitred.
	var a := 1.2 * MM
	var w := 0.8 * MM
	var t := 0.1 * MM
	var sheet = kernel.extrude(kernel.sketch_edges([_k_line(Vector2(1.2, 0), Vector2.ZERO), _k_line(Vector2.ZERO, Vector2(0, 1.2))], Transform3D.IDENTITY), {"direction": Vector3(0, 0, 1), "distance": w, "surface": true})
	for spec in [[t, false, (2 * a + t) * t * w], [-t, false, (2 * a - t) * t * w], [t, true, 2 * a * t * w]]:
		var thick = kernel.thicken(sheet, PackedInt32Array([0, 1]), {"thickness": spec[0], "symmetric": spec[1]})
		var v: float = thick.volume() if thick != null else -1.0
		_expect(absf(v - spec[2]) <= 1e-6 * spec[2], "An L sheet with 1.2 mm legs thickened %s mm%s should be mitred exactly (%s, want %s; %s)." % [spec[0] / MM, " both ways" if spec[1] else "", v / MM3, spec[2] / MM3, kernel.get_last_error()])
	# The same L at 0.6 mm and a U channel with 0.6 mm walls, offset 0.05 mm either way.
	var small = kernel.extrude(kernel.sketch_edges([_k_line(Vector2(0.6, 0), Vector2.ZERO), _k_line(Vector2.ZERO, Vector2(0, 0.6))], Transform3D.IDENTITY), {"direction": Vector3(0, 0, 1), "distance": 0.4 * MM, "surface": true})
	var channel = kernel.extrude(kernel.sketch_edges([_k_line(Vector2(0, 0.6), Vector2.ZERO), _k_line(Vector2.ZERO, Vector2(0.6, 0)), _k_line(Vector2(0.6, 0), Vector2(0.6, 0.6))], Transform3D.IDENTITY), {"direction": Vector3(0, 0, 1), "distance": 0.4 * MM, "surface": true})
	var d := 0.05 * MM
	for spec in [[small, d, 2 * (0.6 * MM + d) * 0.4 * MM, "L"], [small, -d, 2 * (0.6 * MM - d) * 0.4 * MM, "L"], [channel, d, (1.8 * MM - 4 * d) * 0.4 * MM, "U"], [channel, -d, (1.8 * MM + 4 * d) * 0.4 * MM, "U"]]:
		var moved = kernel.offset_surface(spec[0], PackedInt32Array(range(spec[0].face_count())), spec[1], "o")
		var area: float = moved.area() if moved != null else -1.0
		_expect(absf(area - spec[2]) <= 1e-6 * spec[2] and kernel.get_last_warning() == "", "A 0.6 mm %s sheet offset %s mm should be joined exactly (%s mm2, want %s; \"%s\" %s)." % [spec[3], spec[1] / MM, area / MM2, spec[2] / MM2, kernel.get_last_warning(), kernel.get_last_error()])
	# Sections through a G1 box dome stitched to its walls and floor, and the dome thickened 0.2 mm,
	# near their tops at 0.5 and 2 mm against the same at 10 mm.
	var areas := {}
	for s in [1.0, 0.2, 0.05]:
		var bw = kernel.extrude(kernel.sketch_edges(_k_square(5.0 * s), Transform3D.IDENTITY), {"direction": Vector3(0, 0, 1), "distance": 10 * MM * s, "surface": true})
		var top := _k_edges(bw, func(info: Dictionary) -> bool: return absf((info.midpoint as Vector3).z - 10 * MM * s) < 1e-7 * s)
		var bottom := _k_edges(bw, func(info: Dictionary) -> bool: return absf((info.midpoint as Vector3).z) < 1e-7 * s)
		var dome = kernel.patch([{"shape": bw, "edges": top, "continuity": 1}], PackedVector3Array(), {"tag": "p"})
		var floor_ = kernel.patch([{"shape": bw, "edges": bottom, "continuity": 0}], PackedVector3Array(), {"tag": "b"})
		var solid = kernel.stitch([bw, dome, floor_], {"tolerance": 1e-7 * s, "solid": true})
		var thick = kernel.thicken(dome, PackedInt32Array(), {"thickness": 0.2 * MM * s})
		var at: Vector3 = Vector3(0, 0, 14.5) * MM * s
		var cut = kernel.section_faces(solid, at, Vector3(0, 0, 1)) if solid != null else null
		var ring = kernel.section_faces(thick, at, Vector3(0, 0, 1)) if thick != null else null
		areas[s] = [cut.area() / (s * s) if cut != null else -1.0, ring.area() / (s * s) if ring != null else -1.0]
		if s == 0.05 and solid != null and thick != null:
			var shown: Dictionary = ANALYSIS.build({"type": "section", "options": {"origin": at, "normal": Vector3(0, 0, 1)}}, {"bodies": {"b": {"shape": solid}, "k": {"shape": thick}}}, {}, kernel, DOCUMENT.new())
			_expect(not shown.has("error") and shown.meshes.size() == 2, "Section Analysis of a 0.5 mm stitched dome and its thickened dome should cap both (%s, %d caps)." % [shown.get("error", shown.get("info", "")), shown.meshes.size()])
	for s in [0.2, 0.05]:
		for i in 2:
			var want: float = areas[1.0][i]
			_expect(want > 0.0 and absf(float(areas[s][i]) - want) <= 1e-4 * want, "The section near the top of a %s at x%s should be the one at 10 mm scaled (%s, want %s mm2)." % [["stitched G1 box dome", "thickened G1 box dome"][i], s, float(areas[s][i]) / MM2, want / MM2])


## Round 10: Section Analysis cuts a stepped block along its step's top and a holed box along its
## hole's side (both refused at every size: the plane there crosses no loop of its own, and one
## refused body dropped every body's caps; a refused body is now left uncapped and named); a loft
## along a rail bent at its middle section is its two frustums (7.2 % short: the sections turned
## with the rail) and an S rail keeps its squares flat; sweeps, pipes and coils whose turns overlap
## are refused saying by how much (a 4 mm circle along a helix of pitch 3 mm counted 1 mm of each
## turn twice), and a guided sweep round too tight a bend like a plain one (it built with no
## volume); Thicken and Offset of a small L picked in a body with a far face are exact (sized by the
## whole body, they came out broken and unjoined); a twisted ring sweep and a stitched 0.5 mm G1
## tube cap take about as long as their plain kin (they took 12-130 s and 13-15 s).
func _check_round10_fixes() -> void:
	# R1: at 0.05, 1 and 50 times 10 mm.
	for s in [0.05, 1.0, 50.0]:
		var u: float = MM * s
		var step = kernel.boolean(kernel.make_box(Vector3(10, 10, 5) * u, Vector3.ZERO, "b"), kernel.make_box(Vector3(5, 10, 5) * u, Vector3(0, 0, 5) * u, "u"), 0, "s")
		var holed = kernel.boolean(kernel.make_box(Vector3(10, 10, 10) * u, Vector3(-5, -5, 0) * u, "b"), kernel.make_cylinder(2.0 * u, 20 * u, Vector3(0, 0, -5) * u, Vector3(0, 0, 1), "c"), 1, "h")
		for spec in [[step, Vector3(0, 0, 5), Vector3(0, 0, 1), "a stepped block along its step's top"], [holed, Vector3(2, 0, 0), Vector3(1, 0, 0), "a holed box along its hole's side"]]:
			var cap = kernel.section_faces(spec[0], (spec[1] as Vector3) * u, spec[2]) if spec[0] != null else null
			var got: float = cap.area() / (u * u) if cap != null else -1.0
			_expect(absf(got - 100.0) <= 1e-5 * 100.0, "The section through %s (x%s) should be 100 mm2 (%s; \"%s\")." % [spec[3], s, got, kernel.get_last_error()])
	var block = kernel.make_box(Vector3(10, 10, 10) * MM, Vector3.ZERO, "b")
	var aside = kernel.make_box(Vector3(10, 10, 10) * MM, Vector3(20, 0, 0) * MM, "o")
	var shown: Dictionary = ANALYSIS.build({"type": "section", "options": {"origin": Vector3(0, 0, 5) * MM, "normal": Vector3(0, 0, 1)}}, {"bodies": {"good": {"shape": block}, "bad": {"shape": aside}}}, {}, RefusingKernel.new(kernel, aside), DOCUMENT.new())
	_expect(not shown.has("error") and shown.meshes.size() == 1 and str(shown.info).begins_with("Section area 100 mm²") and str(shown.info).contains("The section through bad could not be made"),
		"Section Analysis should cap the body it can and name the one it can't (%s, %d caps)." % [shown.get("error", shown.get("info", "")), shown.meshes.size()])
	# R2: circles r 5, 4 and 5 mm at z 0, 5 and 10 on a rail through their rims bent at the middle one.
	var xz := Transform3D(Basis(Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(0, -1, 0)), Vector3.ZERO)
	for s in [0.05, 1.0, 50.0]:
		var u: float = MM * s
		var discs := []
		for spec in [[5.0, 0.0], [4.0, 5.0], [5.0, 10.0]]:
			discs.append(kernel.sketch_regions([{"type": "circle", "c": Vector2.ZERO, "r": spec[0] * u}], Transform3D(Basis.IDENTITY, Vector3(0, 0, spec[1]) * u), 0.0)[0].face)
		var bent = kernel.sketch_edges([{"type": "line", "a": Vector2(5, 0) * u, "b": Vector2(4, 5) * u}, {"type": "line", "a": Vector2(4, 5) * u, "b": Vector2(5, 10) * u}], xz)
		var frustums = kernel.loft(discs, {"rail": bent})
		var want := 2.0 * PI * 5.0 / 3.0 * (25.0 + 20.0 + 16.0)
		var got: float = frustums.volume() / pow(u, 3) if frustums != null else -1.0
		_expect(absf(got - want) <= 1e-6 * want and kernel.get_last_warning() == "", "Circles r 5, 4, 5 mm lofted along a rail bent at the middle one (x%s) should be their two frustums (%s mm3, want %s; \"%s\" %s)." % [s, got, want, kernel.get_last_warning(), kernel.get_last_error()])
	# 10 mm squares at z 0 and 40 mm (the far one 30 mm over in x) on an S rail of two r 36.5 mm arcs
	# from corner to corner: each section along it is the square, carried flat (100 x 40 mm3).
	var start_angle := atan2(15.0, 20.0) - deg_to_rad(20.0)
	var radius := 12.5 / sin(deg_to_rad(20.0))
	var c1 := Vector2(-sin(start_angle), cos(start_angle)) * radius
	var c2 := Vector2(40, 30) - c1
	var s_rail = kernel.sketch_edges([_k_arc(c1, radius, (-c1).angle(), (Vector2(20, 15) - c1).angle()), _k_arc(c2, radius, (Vector2(40, 30) - c2).angle(), (Vector2(20, 15) - c2).angle())],
		Transform3D(Basis(Vector3(0, 0, 1), Vector3(1, 0, 0), Vector3(0, 1, 0)), Vector3.ZERO))
	var square_mm := [Vector2(0, 0), Vector2(10, 0), Vector2(10, 10), Vector2(0, 10)]
	var near := _k_region_at(_k_polygon(square_mm), 100.0, Transform3D.IDENTITY)
	var far := _k_region_at(_k_polygon(square_mm), 100.0, Transform3D(Basis.IDENTITY, Vector3(30, 0, 40) * MM))
	var sheared = kernel.loft([near, far], {"rail": s_rail})
	_close(sheared.volume() / MM3 if sheared != null else -1.0, 4000.0, 1e-6, "Two squares lofted along an S rail keep flat (volume; %s)" % kernel.get_last_error())
	# R3: a 4 mm circle swept along 3 turns of a helix r 10 mm with a 3 mm pitch, and a 4 mm pipe;
	# the coil of that section and pitch; on a 5 mm pitch the circle clears the next turn by 1 mm.
	var by := RegEx.create_from_string("overlap itself by ([0-9.]+) mm")
	for pitch in [3.0, 5.0]:
		var hx = kernel.helix({"radius": 10 * MM, "pitch": pitch * MM, "turns": 3.0, "axis": Vector3(0, 0, 1)})
		var st: Dictionary = hx.edge_point_at(0, 0.0)
		var round4 = kernel.sketch_regions([_k_circle(Vector2.ZERO, 2.0)], Transform3D(Basis.looking_at(-(st.tangent as Vector3).normalized(), Vector3(0, 0, 1)), st.point), 0.0)[0].face
		var swept = kernel.sweep(round4, hx, {})
		var said := by.search(kernel.get_last_error())
		if pitch == 3.0:
			_expect(swept == null and said != null and absf(float(said.get_string(1)) - 1.0) < 0.1, "A 4 mm circle swept along a helix of pitch 3 mm should be refused for overlapping itself by about 1 mm (%s, \"%s\")." % [swept.volume() / MM3 if swept != null else "null", kernel.get_last_error()])
			var piped = kernel.pipe(hx, {"size": 4 * MM})
			said = by.search(kernel.get_last_error())
			_expect(piped == null and said != null and absf(float(said.get_string(1)) - 1.0) < 0.1, "A 4 mm pipe along that helix should be refused for overlapping itself by about 1 mm (\"%s\")." % kernel.get_last_error())
			var coiled = kernel.coil({"diameter": 20 * MM, "section_size": 4 * MM, "pitch": 3 * MM, "turns": 3.0, "axis": Vector3(0, 0, 1)})
			_expect(coiled == null and kernel.get_last_error().contains("overlap each other by 1 mm") and kernel.get_last_error().contains("at least 4 mm"), "A coil with a 4 mm section at a 3 mm pitch should be refused, saying the pitch it needs (\"%s\")." % kernel.get_last_error())
		else:
			var along: float = PI * 4.0 * MM2 * float(hx.edge_info(0).length)
			_expect(swept != null and absf(swept.volume() - along) <= 1e-6 * along, "A 4 mm circle swept along a helix of pitch 5 mm should build (A L; %s, \"%s\")." % [swept.volume() / MM3 if swept != null else "null", kernel.get_last_error()])
	# A 0.2 mm square guided round a 0.05 mm bend by a concentric arc through its outer side.
	var r := 0.05 * MM
	var bend = kernel.sketch_edges([{"type": "arc", "c": Vector2(0, r), "r": r, "a0": -PI / 2, "a1": 0.0}], Transform3D.IDENTITY)
	var outer_guide = kernel.sketch_edges([{"type": "arc", "c": Vector2(0, r), "r": 3.0 * r, "a0": -PI / 2, "a1": 0.0}], Transform3D.IDENTITY)
	var yz := Transform3D(Basis(Vector3(0, 1, 0), Vector3(0, 0, 1), Vector3(1, 0, 0)), Vector3.ZERO)
	var small_square = kernel.sketch_regions(_k_square(0.1), yz, 0.0)[0].face
	_k_refused(kernel.sweep(small_square, bend, {"guide": outer_guide}), "toward the centre of a bend", "A 0.2 mm square guided round a 0.05 mm bend")
	# R4: an L sheet with 1.2 mm legs and a 1 mm plane 20 mm away in one body, only the L picked.
	var a := 1.2 * MM
	var w := 0.8 * MM
	var l_sheet = kernel.extrude(kernel.sketch_edges([_k_line(Vector2(1.2, 0), Vector2.ZERO), _k_line(Vector2.ZERO, Vector2(0, 1.2))], Transform3D.IDENTITY), {"direction": Vector3(0, 0, 1), "distance": w, "surface": true})
	var both = kernel.make_compound([l_sheet, kernel.plane_face(Vector3(20, 20, 0) * MM, Vector3(0, 0, 1), 1.0 * MM, "far")])
	var legs := PackedInt32Array()
	for f in both.face_count():
		if ((both.face_info(f).point as Vector3) - Vector3(20, 20, 0) * MM).length() > 5 * MM:
			legs.append(f)
	for t in [0.1 * MM, -0.1 * MM]:
		var thick = kernel.thicken(both, legs, {"thickness": t})
		var want: float = (2 * a + t) * absf(t) * w
		_expect(thick != null and absf(thick.volume() - want) <= 1e-6 * want, "A small L picked in a body with a far face, thickened %s mm, should be mitred exactly (%s, want %s; \"%s\")." % [t / MM, thick.volume() / MM3 if thick != null else "null", want / MM3, kernel.get_last_error()])
		var moved = kernel.offset_surface(both, legs, t, "o")
		var area: float = 2.0 * (a + t) * w
		_expect(moved != null and absf(moved.area() - area) <= 1e-6 * area and kernel.get_last_warning() == "", "That L offset %s mm should be joined exactly (%s, want %s; \"%s\" %s)." % [t / MM, moved.area() / MM2 if moved != null else "null", area / MM2, kernel.get_last_warning(), kernel.get_last_error()])
	# R5: a 2 mm square round a 20 mm ring twisted 7 deg, against the same square swept twisted along
	# the ring's first half (one pipe): exact, and a few times as long, not hundreds.
	var ring = kernel.sketch_wire([{"type": "circle", "c": Vector2(0.02, 0), "r": 0.02}], xz)
	var half_ring = kernel.sketch_wire([{"type": "arc", "c": Vector2(0.02, 0), "r": 0.02, "a0": 0.0, "a1": PI}], xz)
	var ring_start: Dictionary = ring.edge_point_at(0, 0.0)
	var section = kernel.sketch_regions(_k_square(1.0), Transform3D(Basis.looking_at(-(ring_start.tangent as Vector3).normalized(), Vector3(0, 1, 0)), ring_start.point), 0.0)[0].face
	var twisted = kernel.sweep(section, ring, {"twist": deg_to_rad(7.0)})
	var whole := 4e-6 * TAU * 0.02
	_expect(twisted != null and absf(twisted.volume() - whole) <= 1e-6 * whole, "A 2 mm square round a 20 mm ring twisted 7 deg should be A L (%s; %s)." % [twisted.volume() / MM3 if twisted != null else "null", kernel.get_last_error()])
	var ring_cost := TIMING.compare(func() -> void: kernel.sweep(section, ring, {"twist": deg_to_rad(7.0)}), func() -> void: kernel.sweep(section, half_ring, {"twist": deg_to_rad(7.0)}), 3, "twisted ring / twisted half ring")
	_expect(ring_cost.ratio < 25.0, "A twisted ring sweep should take a few times a twisted half ring's (%.0f ms against %.0f ms)." % [ring_cost.op, ring_cost.calibration])
	# R6: a G1 cap stitched to a 0.5 mm tube and its floor as a solid, against the same 25 mm across
	# (OCCT's crossing check of it took 15 s at 0.5 mm, a tenth of a second at 25 mm).
	var tube := _k_walls([_k_circle(Vector2.ZERO, 0.25)], 0.5)
	var tube_cap = kernel.patch([{"shape": tube[0], "edges": tube[1], "continuity": 1}], PackedVector3Array(), {"tag": "p"})
	var tube_floor = kernel.sketch_regions([_k_circle(Vector2.ZERO, 0.25)], Transform3D.IDENTITY, 0.0)[0].face
	var closed = kernel.stitch([tube[0], tube_cap, tube_floor], {"tolerance": 5e-8, "solid": true}) if tube_cap != null else null
	_expect(closed != null and closed.solid_count() == 1, "A G1 cap on a 0.5 mm tube stitched to it and its floor should close a solid (%s)." % kernel.get_last_error())
	var big_tube := _k_walls([_k_circle(Vector2.ZERO, 12.5)], 25.0)
	var big_cap = kernel.patch([{"shape": big_tube[0], "edges": big_tube[1], "continuity": 1}], PackedVector3Array(), {"tag": "p"})
	var big_floor = kernel.sketch_regions([_k_circle(Vector2.ZERO, 12.5)], Transform3D.IDENTITY, 0.0)[0].face
	if closed != null and big_cap != null:
		var stitch_cost := TIMING.compare(func() -> void: kernel.stitch([tube[0], tube_cap, tube_floor], {"tolerance": 5e-8, "solid": true}), func() -> void: kernel.stitch([big_tube[0], big_cap, big_floor], {"tolerance": 2.5e-6, "solid": true}), 3, "stitch G1 tube cap 0.5 mm / 25 mm")
		_expect(stitch_cost.ratio < 5.0, "Stitching a 0.5 mm G1 tube cap into a solid should take about as long as at 25 mm (%.0f ms against %.0f ms)." % [stitch_cost.op, stitch_cost.calibration])


## Round 11: a section through a turned body, where the plane only touches a hole along a line, is
## made (refused at some turns: the classifier's rays grazed the hole's top) and exact where it
## also lies along a step (the faces either side of the line overlapped, 5e-5 big); a loft of alike
## sections along a curved rail is the one section swept (0.8 s, up to 7 s); sweeps and pipes whose
## helix turns overlap by thousandths of a millimetre are refused; sweeps and pipes round a path's
## sharp corners are mitred (a closed square came out empty, an L its first leg) and twisted ones
## there refused; a sweep round a closed path starts where its profile sits; Thicken and Offset of
## narrow sheets are exact (a 0.6 mm wide L 30 mm long came out 74 % short); twisted rings on turned
## or small paths are quick (130 s).
func _check_round11_fixes() -> void:
	var u := MM
	# NEW-r5-1: a 10 mm box with a 2 mm hole along Y at z = 5 mm, turned about Z, at the origin and
	# moved, cut along the hole's top (z = 7 mm).
	var side_hole = kernel.boolean(kernel.make_box(Vector3(10, 10, 10) * u, Vector3(-5, -5, 0) * u, "b"), kernel.make_cylinder(2.0 * u, 20 * u, Vector3(0, -10, 5) * u, Vector3(0, 1, 0), "c"), 1, "h")
	for move in [Vector3.ZERO, Vector3(3, -7, 11)]:
		for deg in [1.0, 5.0, 90.0]:
			var xf := Transform3D(Basis(Vector3(0, 0, 1), deg_to_rad(deg)), move * u)
			var cap = kernel.section_faces(kernel.transform_shape(side_hole, xf, "t"), xf * (Vector3(0, 0, 7) * u), Vector3(0, 0, 1))
			_expect(cap != null and absf(cap.area() / MM2 - 100.0) <= 1e-6 * 100.0, "A box with a side hole turned %s deg (moved %s), cut along the hole's top, should section to 100 mm2 (%s; \"%s\")." % [deg, move, cap.area() / MM2 if cap != null else "refused", kernel.get_last_error()])
	var turned_box = kernel.transform_shape(side_hole, Transform3D(Basis(Vector3(0, 0, 1), deg_to_rad(5.0)), Vector3.ZERO), "t")
	var alone: Dictionary = ANALYSIS.build({"type": "section", "options": {"origin": Vector3(0, 0, 7) * u, "normal": Vector3(0, 0, 1)}}, {"bodies": {"b1": {"shape": turned_box}}}, {}, kernel, DOCUMENT.new())
	_expect(not alone.has("error") and alone.meshes.size() == 1 and str(alone.get("info", "")).begins_with("Section area 100 mm²"), "Section Analysis of that box turned 5 deg, alone, should cap it (%s)." % alone.get("error", alone.get("info", "")))
	# NEW-r5-2: a stepped block with a 1 mm hole along Y tangent to the step's top, turned and moved,
	# cut along the step.
	var step = kernel.boolean(kernel.make_box(Vector3(10, 10, 5) * u, Vector3.ZERO, "b"), kernel.make_box(Vector3(5, 10, 5) * u, Vector3(0, 0, 5) * u, "u"), 0, "s")
	var stepped = kernel.boolean(step, kernel.make_cylinder(1.0 * u, 20 * u, Vector3(2.5, -5, 6) * u, Vector3(0, 1, 0), "c"), 1, "y")
	for spec in [[37.0, Vector3(1, 2, 3)], [61.0, Vector3(1, 2, 3)], [37.0, Vector3(1, 0, 0)]]:
		var xf := Transform3D(Basis((spec[1] as Vector3).normalized(), deg_to_rad(spec[0])), Vector3(3, -7, 11) * u)
		var cap = kernel.section_faces(kernel.transform_shape(stepped, xf, "t"), xf * (Vector3(0, 0, 5) * u), (xf.basis * Vector3(0, 0, 1)).normalized())
		_expect(cap != null and absf(cap.area() / MM2 - 100.0) <= 1e-6 * 100.0, "A stepped block with a hole tangent to its step, turned %s deg about %s, cut along the step should section to 100 mm2 (%s; \"%s\")." % [spec[0], spec[1], cap.area() / MM2 if cap != null else "refused", kernel.get_last_error()])
	# NEW-r5-3: three 10 mm circles on an S rail of two arcs (through (5, 0), (5, 5) and (5, 10) mm,
	# bulging 1.5 mm either way): pi 25 x 10 mm3, and some ten times two lofted along a straight
	# rail (a few hundred times, made again every 5 deg the rail turns).
	var xz := Transform3D(Basis(Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(0, -1, 0)), Vector3.ZERO)
	var bend := atan2(2.5, 4.0 / 3.0)
	var s_rail = kernel.sketch_edges([_k_arc(Vector2(11.0 / 3.0, 2.5), 17.0 / 6.0, -bend, bend), _k_arc(Vector2(19.0 / 3.0, 7.5), 17.0 / 6.0, PI - bend, PI + bend)], xz)
	var discs := []
	for z in [0.0, 5.0, 10.0]:
		discs.append(kernel.sketch_regions([_k_circle(Vector2.ZERO, 5.0)], Transform3D(Basis.IDENTITY, Vector3(0, 0, z) * MM), 0.0)[0].face)
	var s_loft = kernel.loft(discs, {"rail": s_rail})
	_close(s_loft.volume() / MM3 if s_loft != null else -1.0, PI * 250.0, 1e-6, "Three 10 mm circles lofted along an S rail (volume; %s)" % kernel.get_last_error())
	if s_loft != null:
		var straight_rail = kernel.sketch_edges([_k_line(Vector2(5, 0), Vector2(5, 10))], xz)
		var ends := [discs[0], discs[2]]
		var loft_cost := TIMING.compare(func() -> void: kernel.loft(discs, {"rail": s_rail}), func() -> void: kernel.loft(ends, {"rail": straight_rail}), 3, "S rail loft / straight rail loft")
		_expect(loft_cost.ratio < 80.0, "Three alike circles lofted along an S rail should take some ten times two along a straight rail (%.0f ms against %.1f ms)." % [loft_cost.op, loft_cost.calibration])
	# NEW-r5-4: a 4 mm circle along 3 turns of a helix r 10 mm at a 4.005 mm pitch overlaps the next
	# turn by 0.003 mm (the turns lie the pitch times the cosine of its lead apart): refused, swept
	# or piped; at 4.01 mm it clears and builds.
	var by := RegEx.create_from_string("overlap itself by ([0-9.]+) mm")
	for pitch in [4.005, 4.01]:
		var hx = kernel.helix({"radius": 10 * MM, "pitch": pitch * MM, "turns": 3.0, "axis": Vector3(0, 0, 1)})
		var st: Dictionary = hx.edge_point_at(0, 0.0)
		var round4 = kernel.sketch_regions([_k_circle(Vector2.ZERO, 2.0)], Transform3D(Basis.looking_at(-(st.tangent as Vector3).normalized(), Vector3(0, 0, 1)), st.point), 0.0)[0].face
		var swept = kernel.sweep(round4, hx, {})
		var swept_said := by.search(kernel.get_last_error())
		var piped = kernel.pipe(hx, {"size": 4 * MM})
		var piped_said := by.search(kernel.get_last_error())
		if pitch < 4.01:
			_expect(swept == null and swept_said != null and absf(float(swept_said.get_string(1)) - 0.0031) < 0.0005, "A 4 mm circle swept along a helix of pitch 4.005 mm should be refused for overlapping itself by about 0.003 mm (%s)." % [swept.volume() / MM3 if swept != null else kernel.get_last_error()])
			_expect(piped == null and piped_said != null and absf(float(piped_said.get_string(1)) - 0.0031) < 0.0005, "A 4 mm pipe along that helix should be refused the same way (%s)." % ["built" if piped != null else kernel.get_last_error()])
		else:
			var along: float = PI * 4.0 * MM2 * float(hx.edge_info(0).length)
			_expect(swept != null and absf(swept.volume() - along) <= 1e-6 * along and piped != null and absf(piped.volume() - along) <= 1e-6 * along, "A 4 mm circle swept and piped along a helix of pitch 4.01 mm should build (A L; %s, %s)." % [swept.volume() / MM3 if swept != null else "null", piped.volume() / MM3 if piped != null else "null"])
	# NEW-r5-5: a 6 mm circle round a closed 20 mm square path (from a corner and from mid-side), a
	# triangle, and along an open L, and a 6 mm pipe round each: mitred, A L. (They came out empty,
	# or the L its first leg; the triangle was refused as overlapping at its corners.)
	var paths := [[_k_polygon([Vector2(0, 0), Vector2(20, 0), Vector2(20, 20), Vector2(0, 20)]), 80.0, 3.0, "a closed square path"],
		[[_k_line(Vector2(10, 0), Vector2(20, 0)), _k_line(Vector2(20, 0), Vector2(20, 20)), _k_line(Vector2(20, 20), Vector2(0, 20)), _k_line(Vector2(0, 20), Vector2(0, 0)), _k_line(Vector2(0, 0), Vector2(10, 0))], 80.0, 3.0, "a closed square path from mid-side"],
		[_k_polygon([Vector2(0, 0), Vector2(30, 0), Vector2(15, 25)]), 30.0 + 2.0 * Vector2(15, 25).length(), 2.0, "a closed triangle path"],
		[[_k_line(Vector2(0, 0), Vector2(20, 0)), _k_line(Vector2(20, 0), Vector2(20, 20))], 40.0, 3.0, "an L path"]]
	for spec in paths:
		var path = kernel.sketch_edges(spec[0], Transform3D.IDENTITY)
		var st: Dictionary = path.edge_point_at(0, 0.0)
		var frame := Transform3D(Basis.looking_at(-(st.tangent as Vector3).normalized(), Vector3(0, 0, 1)), st.point)
		var disc = kernel.sketch_regions([_k_circle(Vector2.ZERO, spec[2])], frame, 0.0)[0].face
		var want: float = PI * spec[2] * spec[2] * spec[1] * MM3
		var swept = kernel.sweep(disc, path, {})
		_expect(swept != null and absf(swept.volume() - want) <= 1e-6 * want and kernel.get_last_warning() == "", "A %s mm circle swept round %s should be mitred at its corners (A L; %s, want %s; \"%s\")." % [2.0 * spec[2], spec[3], swept.volume() / MM3 if swept != null else kernel.get_last_error(), want / MM3, kernel.get_last_warning()])
		var piped = kernel.pipe(path, {"size": 2.0 * spec[2] * MM})
		_expect(piped != null and absf(piped.volume() - want) <= 1e-6 * want, "A %s mm pipe round %s should be mitred at its corners (A L; %s, want %s)." % [2.0 * spec[2], spec[3], piped.volume() / MM3 if piped != null else kernel.get_last_error(), want / MM3])
		if spec[3] == "an L path":
			var square4 = kernel.sketch_regions(_k_square(2.0), frame, 0.0)[0].face
			_k_refused(kernel.sweep(square4, path, {"twist": deg_to_rad(30.0)}), "sharp corners", "A 4 mm square twisted 30 deg along an L path")
	# NEW-r5-6: a 2 mm square at the origin swept round a 20 mm circle through it, centred at (20, 0)
	# mm (the circle starts half way round from it): A L (refused as reaching 41 mm across the ring).
	var round_path = kernel.sketch_wire([{"type": "circle", "c": Vector2(0.02, 0), "r": 0.02}], xz)
	var at_origin = kernel.sketch_regions(_k_square(1.0), Transform3D.IDENTITY, 0.0)[0].face
	var around = kernel.sweep(at_origin, round_path, {})
	var ring_volume := 4e-6 * TAU * 0.02
	_expect(around != null and absf(around.volume() - ring_volume) <= 1e-6 * ring_volume, "A 2 mm square swept round a ring that starts half way round from it should be A L (%s)." % [around.volume() / MM3 if around != null else kernel.get_last_error()])
	# NEW-r5-8: an L sheet with 0.6 mm legs 30 mm long thickened 0.1 and 0.05 mm either way, and
	# offset (74 % short and 25 % big, unwarned).
	var narrow = kernel.extrude(kernel.sketch_edges([_k_line(Vector2(0.6, 0), Vector2.ZERO), _k_line(Vector2.ZERO, Vector2(0, 0.6))], Transform3D.IDENTITY), {"direction": Vector3(0, 0, 1), "distance": 30 * MM, "surface": true})
	for t in [0.1 * MM, 0.05 * MM, -0.05 * MM]:
		var thick = kernel.thicken(narrow, PackedInt32Array([0, 1]), {"thickness": t})
		var want: float = (2 * 0.6 * MM + t) * absf(t) * 30 * MM
		_expect(thick != null and absf(thick.volume() - want) <= 1e-6 * want, "An L sheet with 0.6 mm legs 30 mm long thickened %s mm should be mitred exactly (%s, want %s; \"%s\")." % [t / MM, thick.volume() / MM3 if thick != null else "null", want / MM3, kernel.get_last_error()])
	# NEW-r5-7: two Ls with 1.2 mm legs 20 mm apart in one body, both picked, thickened and offset
	# 0.1 mm either way (refused broken, and 8 % off unjoined).
	var a := 1.2 * MM
	var w := 0.8 * MM
	var one_l = kernel.extrude(kernel.sketch_edges([_k_line(Vector2(1.2, 0), Vector2.ZERO), _k_line(Vector2.ZERO, Vector2(0, 1.2))], Transform3D.IDENTITY), {"direction": Vector3(0, 0, 1), "distance": w, "surface": true})
	var pair = kernel.make_compound([one_l, kernel.transform_shape(one_l, Transform3D(Basis.IDENTITY, Vector3(20, 0, 0) * MM), "m")])
	var all_four := PackedInt32Array(range(pair.face_count()))
	for t in [0.1 * MM, -0.1 * MM]:
		var thick = kernel.thicken(pair, all_four, {"thickness": t})
		var want: float = 2.0 * (2 * a + t) * absf(t) * w
		_expect(thick != null and absf(thick.volume() - want) <= 1e-6 * want, "Two small Ls 20 mm apart, both picked, thickened %s mm should be mitred exactly (%s, want %s; \"%s\")." % [t / MM, thick.volume() / MM3 if thick != null else "null", want / MM3, kernel.get_last_error()])
		var moved = kernel.offset_surface(pair, all_four, t, "o")
		var area: float = 4.0 * (a + t) * w
		_expect(moved != null and absf(moved.area() - area) <= 1e-6 * area and kernel.get_last_warning() == "", "Those Ls offset %s mm should be joined exactly (%s, want %s; \"%s\" %s)." % [t / MM, moved.area() / MM2 if moved != null else "null", area / MM2, kernel.get_last_warning(), kernel.get_last_error()])
	# NEW-r5-9: a 2 mm square round a 40 mm ring turned 0.9 rad about (2, -1, 3), twisted 45 deg, and
	# a 0.1 x 0.05 mm rectangle 0.025 mm off-centre round a 2 mm ring twisted 1 deg: exact, and a
	# few times as long as the same along a twisted half ring (8 s and 79 s: the second half came out
	# turned against the first, or the ends didn't sew, and the halves were fused).
	var turn := Transform3D(Basis(Vector3(2, -1, 3).normalized(), 0.9), Vector3.ZERO)
	var rect_points := [Vector2(-0.5, -0.5), Vector2(1.5, -0.5), Vector2(1.5, 0.5), Vector2(-0.5, 0.5)]
	var rings := []
	for k in [1.0, 0.05]:
		rings.append([kernel.sketch_wire([{"type": "circle", "c": Vector2(20, 0) * MM * k, "r": 20 * MM * k}], xz), kernel.sketch_wire([{"type": "arc", "c": Vector2(20, 0) * MM * k, "r": 20 * MM * k, "a0": 0.0, "a1": PI}], xz)])
	for spec in [[kernel.transform_shape(rings[0][0], turn, "t"), kernel.transform_shape(rings[0][1], turn, "t"), _k_square(1.0), 45.0, 4.0 * TAU * 20.0, 1.0, "a 2 mm square round a turned 40 mm ring twisted 45 deg"],
		[rings[1][0], rings[1][1], _k_polygon(rect_points.map(func(p: Vector2) -> Vector2: return p * 0.05)), 1.0, 2.0 * TAU * 20.0 * (1.0 + 0.5 / 20.0 * sin(deg_to_rad(1.0)) / deg_to_rad(1.0)), 0.05, "a 0.1 x 0.05 mm rectangle off-centre round a 2 mm ring twisted 1 deg"]]:
		var start: Dictionary = spec[0].edge_point_at(0, 0.0)
		var profile = kernel.sketch_regions(spec[2], Transform3D(Basis.looking_at(-(start.tangent as Vector3).normalized(), Vector3(0, 1, 0)), start.point), 0.0)[0].face
		var tw := deg_to_rad(spec[3])
		var started := Time.get_ticks_msec()
		var twisted = kernel.sweep(profile, spec[0], {"twist": tw})
		var once := Time.get_ticks_msec() - started
		var want: float = spec[4] * pow(spec[5] * MM, 3)
		_expect(twisted != null and absf(twisted.volume() - want) <= 1e-6 * want, "%s should be exact (%s, want %s; %s)." % [spec[6], twisted.volume() / MM3 if twisted != null else "null", want / MM3, kernel.get_last_error()])
		var half_started := Time.get_ticks_msec()
		kernel.sweep(profile, spec[1], {"twist": tw})
		var half_once := Time.get_ticks_msec() - half_started
		# (Timed in turns only when it isn't minutes slow, which would take minutes more to time.)
		if once > 50 * maxi(half_once, 20):
			_expect(false, "%s should take a few times a twisted half ring's time (%d ms against %d ms)." % [spec[6], once, half_once])
		else:
			var cost := TIMING.compare(func() -> void: kernel.sweep(profile, spec[0], {"twist": tw}), func() -> void: kernel.sweep(profile, spec[1], {"twist": tw}), 3, "twisted ring / half ring")
			_expect(cost.ratio < 25.0, "%s should take a few times a twisted half ring's time (%.0f ms against %.0f ms)." % [spec[6], cost.op, cost.calibration])


## A kernel whose section through one shape is refused (as a body's that can't be made is), passing
## everything else on to the real one.
class RefusingKernel extends RefCounted:
	var real
	var refused
	var last := ""

	func _init(kernel, shape) -> void:
		real = kernel
		refused = shape

	func section_faces(solid, origin: Vector3, normal: Vector3):
		if is_same(solid, refused):
			last = "The section through this body could not be made exactly (refused for the test)"
			return null
		last = ""
		return real.section_faces(solid, origin, normal)

	func get_last_error() -> String:
		return last if last != "" else str(real.get_last_error())
