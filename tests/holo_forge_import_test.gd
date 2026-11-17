extends SceneTree
## Holo Forge Phase 4 Insert: the SVG and DXF fixtures become fixed sketches with the expected
## curve counts, profile counts and areas (plus Beziers, elliptical arcs, transforms, splines,
## blocks, mirrored arcs, text and layers); a STEP round trip through an Import feature keeps
## the volume (from the file and from the copy kept in the design); STL (ASCII and binary), OBJ
## and glTF cubes come in as closed solids of the right volume and winding; 3MF packages bring
## their unit, build-item transforms and (nested, mirrored) components, with one solid per piece
## (or one body per piece); Derive copies a saved design's body and refuses itself and loops; ISO
## fasteners match their exact volumes. The edit panels of Import, Insert Mesh and Derive (run
## without the editor) change units, Z-up, offsets and angles, split, the file and the derived
## bodies; a fastener placed on a face follows it when the box grows, and stays put (with a
## warning) when the face is gone.
## Review fixes: whole DXF ellipses with a rounded 2 pi, DXF drawings far from their origin,
## MINSERT arrays, every $INSUNITS code, SVG preserveAspectRatio, padded binary STL files, a
## linked (or re-sourced) import keeping references on a revised file's faces, fasteners riding
## along when their face moves within its plane, Derive's cache seeing linked files and
## same-second saves, derived face names apart from local ones, and Insert Mesh reusing its
## solids when only later features change.
##
## godot --headless --path . --script res://tests/holo_forge_import_test.gd

const DOCUMENT := preload("res://addons/holo_forge/core/document.gd")
const REGEN := preload("res://addons/holo_forge/core/regen.gd")
const SKETCH_DATA := preload("res://addons/holo_forge/core/sketch/sketch_data.gd")
const OPERATIONS := preload("res://addons/holo_forge/core/operations.gd")
const SVG_IMPORT := preload("res://addons/holo_forge/core/import/svg_import.gd")
const DXF_IMPORT := preload("res://addons/holo_forge/core/import/dxf_import.gd")
const MESH_IMPORT := preload("res://addons/holo_forge/core/import/mesh_import.gd")
const INSERT := preload("res://addons/holo_forge/core/features/insert.gd")
const PARAMETERS := preload("res://addons/holo_forge/core/parameters.gd")
const REFERENCES := preload("res://addons/holo_forge/core/references.gd")
const INSERT_COMMAND := preload("res://addons/holo_forge/tools/insert_command.gd")
const TIMING := preload("res://tests/holo_forge_timing.gd")

const FIXTURES := "res://tests/holo_forge/fixtures/"
const OUT := "user://holo_forge_import_test/"
const MM2 := 1e-6
const IN2 := 0.0254 * 0.0254
const MM3 := 1e-9

var failures: Array[String] = []
var kernel


func _init() -> void:
	call_deferred("run")


func run() -> void:
	kernel = REGEN.make_kernel()
	_expect(kernel != null, "The native kernel should load.")
	DirAccess.make_dir_recursive_absolute(OUT)
	if kernel != null:
		_check_svg_fixture()
		_check_svg_extras()
		_check_dxf_fixture()
		_check_dxf_extras()
		_check_step_round_trip()
		_check_meshes()
		_check_derive()
		_check_fasteners()
		_check_edge_cases()
		_check_3mf()
		_check_insert_edits()
		_check_fastener_follow()
		_check_dxf_review()
		_check_svg_aspect()
		_check_stl_padding()
		_check_linked_revision()
		_check_fastener_in_plane()
		_check_derive_cache_files()
		_check_derive_names()
		_check_mesh_cache()
		_check_sketch_lookups()
		_check_mesh_units_follow_file()
	print("PASS holo_forge_import: SVG (10 curves, 3 profiles) and DXF (13 curves, 4 profiles) fixtures import with exact areas, STEP round trip keeps the volume, STL/OBJ/glTF cubes are closed solids, 3MF units/transforms/components/split hold, Derive copies a saved body and refuses itself and loops (also through its cache), fasteners match ISO volumes, near-closed SVG paths, 2-vertex bulge polylines, split tools and glTF units hold, import/mesh/derive edits rebuild as expected, and fasteners follow their face; review fixes: rounded-2pi DXF ellipses, far DXF drawings, MINSERT, all $INSUNITS, SVG preserveAspectRatio, padded STL, linked/re-sourced imports keep their references, fasteners ride in-plane moves, Derive cache sees linked files and same-second saves, derived names stay apart, Insert Mesh reuses its solids, 4000-line sketches rebuild in linear time, edited mesh units follow the file." \
		if failures.is_empty() else "FAIL holo_forge_import (%d problem(s))" % failures.size())
	quit(0 if failures.is_empty() else 1)


# --- Helpers ---------------------------------------------------------------------------------

func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error(message)
		print("FAIL: ", message)


func _close(a: float, b: float, rel := 1e-6) -> bool:
	return absf(a - b) <= absf(b) * rel + 1e-15


## Sorted region areas of a sketch after a rebuild.
func _areas(result: Dictionary, feature: Resource) -> Array:
	var areas := []
	for region in result.sketches.get(feature.id, {}).get("regions", []):
		areas.append(float(region.area))
	areas.sort()
	return areas


func _expect_areas(result: Dictionary, feature: Resource, expected: Array, label: String) -> void:
	var areas := _areas(result, feature)
	var want := expected.duplicate()
	want.sort()
	_expect(areas.size() == want.size(), "%s: expected %d profiles, got %d (%s)." % [label, want.size(), areas.size(), areas])
	if areas.size() != want.size():
		return
	for k in want.size():
		_expect(_close(areas[k], want[k]), "%s: profile area %s should be %s." % [label, String.num_scientific(areas[k]), String.num_scientific(want[k])])


func _count(feature: Resource, type: String) -> int:
	var n := 0
	for e in feature.options.entities:
		if e.type == type:
			n += 1
	return n


func _body_volume(result: Dictionary, body_id: String) -> float:
	return result.bodies[body_id].shape.volume() if result.bodies.has(body_id) else -1.0


func _no_errors(result: Dictionary, label: String) -> void:
	_expect((result.errors as Dictionary).is_empty(), "%s: the timeline should rebuild cleanly (%s)." % [label, result.errors])


# --- SVG -------------------------------------------------------------------------------------

func _check_svg_fixture() -> void:
	var doc = DOCUMENT.new()
	var text := FileAccess.get_file_as_string(FIXTURES + "import_shapes.svg")
	var made := SVG_IMPORT.to_sketch(text, doc, SKETCH_DATA.ORIGIN_PLANES.xy, "xy")
	_expect(made.feature != null, "The SVG fixture should make a sketch (%s)." % [made.warnings])
	if made.feature == null:
		return
	_expect(made.curves == 10, "The SVG fixture should give 10 curves (4 lines of the rectangle, the circle, 5 path segments), got %d." % made.curves)
	_expect((made.warnings as Array).is_empty(), "The SVG fixture should import without warnings (%s)." % [made.warnings])
	var feature: Resource = made.feature
	_expect(_count(feature, "line") == 7 and _count(feature, "circle") == 1 and _count(feature, "arc") == 1 and _count(feature, "spline") == 1,
		"The SVG fixture should hold 7 lines, a circle, an arc and one cubic spline.")
	for e in feature.options.entities:
		if e.type == "spline":
			_expect(e.mode == "control" and (e.points as Array).size() == 4 and int(e.get("degree", 3)) == 3, "The cubic should be a degree-3 control-point spline of 4 poles.")
	var fixes := (feature.options.constraints as Array).filter(func(c: Dictionary) -> bool: return c.type == "fix")
	_expect(fixes.size() == 3, "Each imported SVG shape should be fixed by one constraint (got %d)." % fixes.size())
	var result := REGEN.rebuild(doc, kernel)
	_no_errors(result, "SVG fixture")
	_expect(int(result.sketches[feature.id].solve.dof) == 0, "Imported SVG curves should be fully fixed (dof %s)." % result.sketches[feature.id].solve.dof)
	_expect_areas(result, feature, [1200.0 * MM2, 100.0 * PI * MM2, (935.0 + 50.0 * PI) * MM2], "SVG fixture")
	# Upright on the page: the rectangle (top-left of the page in SVG) ends at the page's top.
	var top := -INF
	for e in feature.options.entities:
		if e.type == "point":
			top = maxf(top, float(e.y))
	_expect(_close(top, 0.09, 1e-5), "With flip_y the page's top edge should sit at y = 90 mm (got %s)." % top)


func _check_svg_extras() -> void:
	var doc = DOCUMENT.new()
	var svg := """<svg xmlns="http://www.w3.org/2000/svg" width="200mm" height="100mm" viewBox="0 0 200 100">
	<rect x="0" y="0" width="40" height="20" rx="5"/>
	<g transform="translate(70 10)"><g transform="scale(2 1)"><circle cx="0" cy="0" r="5"/></g></g>
	<path d="M100,10a20 10 0 1 0 40 0A20,10,0,1,0,100,10z"/>
	<path d="M 0 50 Q 20 30 40 50 T 80 50 V 70 H 0 Z"/>
	<defs><rect x="0" y="0" width="5" height="5"/></defs>
	<text x="0" y="0">ignored</text>
	</svg>"""
	var made := SVG_IMPORT.to_sketch(svg, doc, SKETCH_DATA.ORIGIN_PLANES.xz, "xz")
	_expect(made.feature != null and made.curves == 18, "The extra SVG should give 18 curves (8 rounded rectangle, 1 ellipse, 2 x 2 conic pieces of the elliptical arcs, 5 path), got %d." % made.curves)
	_expect((made.warnings as Array).any(func(w: String) -> bool: return w.contains("text")), "SVG text should be reported as skipped (%s)." % [made.warnings])
	if made.feature == null:
		return
	var feature: Resource = made.feature
	_expect(_count(feature, "ellipse") == 1, "A circle stretched by scale(2 1) should become an ellipse.")
	_expect(_count(feature, "conic") == 4, "Each half-ellipse arc should become two 90-degree conics (got %d)." % _count(feature, "conic"))
	var result := REGEN.rebuild(doc, kernel)
	_no_errors(result, "SVG extras")
	_expect_areas(result, feature, [(800.0 - (4.0 - PI) * 25.0) * MM2, 50.0 * PI * MM2, 200.0 * PI * MM2, 1600.0 * MM2], "SVG extras")
	_expect(int(result.sketches[feature.id].solve.dof) == 0, "Imported ellipses, conics and splines should be fully fixed too (dof %s)." % result.sketches[feature.id].solve.dof)
	# options.scale overrides the page size: 1 user unit = 2 mm doubles every length.
	var doc2 = DOCUMENT.new()
	var scaled := SVG_IMPORT.to_sketch("<svg viewBox=\"0 0 10 10\" width=\"10mm\"><circle cx=\"5\" cy=\"5\" r=\"2\"/></svg>", doc2, SKETCH_DATA.ORIGIN_PLANES.xy, "xy", {"scale": 0.002})
	var result2 := REGEN.rebuild(doc2, kernel)
	if scaled.feature != null:
		_expect_areas(result2, scaled.feature, [PI * 16.0 * MM2], "SVG scale option")
	var nothing := SVG_IMPORT.to_sketch("<html><body/></html>", DOCUMENT.new(), SKETCH_DATA.ORIGIN_PLANES.xy, "xy")
	_expect(nothing.feature == null and not (nothing.warnings as Array).is_empty(), "A file that isn't SVG should make no sketch and say why.")


# --- DXF -------------------------------------------------------------------------------------

func _check_dxf_fixture() -> void:
	var text := FileAccess.get_file_as_string(FIXTURES + "import_shapes.dxf")
	var doc = DOCUMENT.new()
	var made := DXF_IMPORT.to_sketch(text, doc, SKETCH_DATA.ORIGIN_PLANES.xy, "xy")
	_expect(made.feature != null and made.curves == 13, "The DXF fixture should give 13 curves (4 square lines, a circle, 2 arcs + 2 lines, 3 lines + 1 bulge arc), got %d (%s)." % [made.curves, made.warnings])
	_expect(Array(made.layers) == ["Bulge", "Round", "Slot", "Square"], "The DXF's layers should be listed (got %s)." % [made.layers])
	if made.feature == null:
		return
	var result := REGEN.rebuild(doc, kernel)
	_no_errors(result, "DXF fixture")
	_expect_areas(result, made.feature, [900.0 * MM2, 100.0 * PI * MM2, (600.0 + 100.0 * PI) * MM2, (800.0 + 50.0 * PI) * MM2], "DXF fixture")
	_expect(int(result.sketches[made.feature.id].solve.dof) == 0, "Imported DXF curves should be fully fixed.")
	# Ends that touch share one point: 4 each for the square, the slot's lines and the polyline.
	var line_points := {}
	for e in made.feature.options.entities:
		if e.type == "line":
			line_points[int(e.p1)] = true
			line_points[int(e.p2)] = true
	_expect(line_points.size() == 4 + 4 + 4, "Touching line ends should share points (got %d distinct)." % line_points.size())

	var per_layer = DOCUMENT.new()
	var layered := DXF_IMPORT.to_sketch(text, per_layer, SKETCH_DATA.ORIGIN_PLANES.xy, "xy", {"one_sketch_per_layer": true})
	_expect((layered.features as Array).size() == 4 and layered.curves == 13, "One sketch per layer should make 4 sketches (got %d)." % (layered.features as Array).size())
	var only = DOCUMENT.new()
	var slot := DXF_IMPORT.to_sketch(text, only, SKETCH_DATA.ORIGIN_PLANES.xy, "xy", {"layers": ["Slot"]})
	_expect(slot.feature != null and slot.curves == 4, "Importing only layer Slot should give its 4 curves (got %d)." % slot.curves)
	if slot.feature != null:
		_expect_areas(REGEN.rebuild(only, kernel), slot.feature, [(600.0 + 100.0 * PI) * MM2], "DXF layer filter")
	var inches = DOCUMENT.new()
	var big := DXF_IMPORT.to_sketch(text, inches, SKETCH_DATA.ORIGIN_PLANES.xy, "xy", {"layers": ["Square"], "units": "in"})
	if big.feature != null:
		_expect_areas(REGEN.rebuild(inches, kernel), big.feature, [900.0 * IN2], "DXF units override")


func _pair(lines: Array, code: int, value: Variant) -> void:
	lines.append(str(code))
	lines.append(str(value))


func _check_dxf_extras() -> void:
	var l := []
	_pair(l, 0, "SECTION"); _pair(l, 2, "HEADER"); _pair(l, 9, "$INSUNITS"); _pair(l, 70, 1); _pair(l, 0, "ENDSEC")
	_pair(l, 0, "SECTION"); _pair(l, 2, "BLOCKS")
	_pair(l, 0, "BLOCK"); _pair(l, 8, "0"); _pair(l, 2, "SQ"); _pair(l, 10, 0.0); _pair(l, 20, 0.0)
	_pair(l, 0, "LWPOLYLINE"); _pair(l, 8, "0"); _pair(l, 90, 4); _pair(l, 70, 1)
	for p in [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]:
		_pair(l, 10, p.x); _pair(l, 20, p.y)
	_pair(l, 0, "ENDBLK")
	_pair(l, 0, "ENDSEC")
	_pair(l, 0, "SECTION"); _pair(l, 2, "ENTITIES")
	# Shapes stay near the origin: sketch points are single-precision, so far-off small shapes
	# would lose area precision. A whole ellipse (2 x 1 inch semi-axes) and a half one with its line.
	_pair(l, 0, "ELLIPSE"); _pair(l, 8, "Parts"); _pair(l, 10, 0.0); _pair(l, 20, 0.0); _pair(l, 11, 2.0); _pair(l, 21, 0.0); _pair(l, 40, 0.5); _pair(l, 41, 0.0); _pair(l, 42, TAU)
	_pair(l, 0, "ELLIPSE"); _pair(l, 8, "Parts"); _pair(l, 10, 5.0); _pair(l, 20, 0.0); _pair(l, 11, 2.0); _pair(l, 21, 0.0); _pair(l, 40, 0.5); _pair(l, 41, 0.0); _pair(l, 42, PI)
	_pair(l, 0, "LINE"); _pair(l, 8, "Parts"); _pair(l, 10, 3.0); _pair(l, 20, 0.0); _pair(l, 11, 7.0); _pair(l, 21, 0.0)
	# A clamped cubic spline (x evenly spaced, so the area under it is 3 * 3 * 3/6) and its chord.
	_pair(l, 0, "SPLINE"); _pair(l, 8, "Parts"); _pair(l, 70, 8); _pair(l, 71, 3); _pair(l, 72, 8); _pair(l, 73, 4); _pair(l, 74, 0)
	for k in [0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0, 1.0]:
		_pair(l, 40, k)
	for p in [Vector2(0, 3), Vector2(1, 6), Vector2(2, 6), Vector2(3, 3)]:
		_pair(l, 10, p.x); _pair(l, 20, p.y); _pair(l, 30, 0.0)
	_pair(l, 0, "LINE"); _pair(l, 8, "Parts"); _pair(l, 10, 3.0); _pair(l, 20, 3.0); _pair(l, 11, 0.0); _pair(l, 21, 3.0)
	# The block (a unit square) placed twice as big and turned 45 degrees: 4 square inches.
	_pair(l, 0, "INSERT"); _pair(l, 8, "Parts"); _pair(l, 2, "SQ"); _pair(l, 10, -4.0); _pair(l, 20, 2.0); _pair(l, 41, 2.0); _pair(l, 42, 2.0); _pair(l, 50, 45.0)
	# An old-style POLYLINE triangle: 6 square inches.
	_pair(l, 0, "POLYLINE"); _pair(l, 8, "Parts"); _pair(l, 66, 1); _pair(l, 70, 1)
	for p in [Vector2(-7, -5), Vector2(-4, -5), Vector2(-7, -1)]:
		_pair(l, 0, "VERTEX"); _pair(l, 8, "Parts"); _pair(l, 10, p.x); _pair(l, 20, p.y)
	_pair(l, 0, "SEQEND")
	# An arc with a downward extrusion: object x is mirrored, so it lands at x = +1 on its line.
	_pair(l, 0, "ARC"); _pair(l, 8, "Parts"); _pair(l, 10, -1.0); _pair(l, 20, -4.0); _pair(l, 40, 1.0); _pair(l, 50, 0.0); _pair(l, 51, 180.0)
	_pair(l, 210, 0.0); _pair(l, 220, 0.0); _pair(l, 230, -1.0)
	_pair(l, 0, "LINE"); _pair(l, 8, "Parts"); _pair(l, 10, 0.0); _pair(l, 20, -4.0); _pair(l, 11, 2.0); _pair(l, 21, -4.0)
	# Notes: a point, text and multi-line text.
	_pair(l, 0, "POINT"); _pair(l, 8, "Notes"); _pair(l, 10, 8.0); _pair(l, 20, 8.0)
	_pair(l, 0, "TEXT"); _pair(l, 8, "Notes"); _pair(l, 10, 8.0); _pair(l, 20, 5.0); _pair(l, 40, 0.5); _pair(l, 1, "%%c10")
	_pair(l, 0, "MTEXT"); _pair(l, 8, "Notes"); _pair(l, 10, 8.0); _pair(l, 20, 7.0); _pair(l, 40, 0.5); _pair(l, 1, "{\\fArial|b0;Hello}\\PWorld")
	_pair(l, 0, "HATCH"); _pair(l, 8, "Parts")
	_pair(l, 0, "ENDSEC"); _pair(l, 0, "EOF")
	var text := "\n".join(PackedStringArray(l))

	var doc = DOCUMENT.new()
	var made := DXF_IMPORT.to_sketch(text, doc, SKETCH_DATA.ORIGIN_PLANES.xy, "xy", {"layers": ["Parts"]})
	_expect(made.feature != null and made.curves == 15, "The extra DXF's Parts layer should give 15 curves (ellipse, 2 conics + line, spline + line, 4 block lines, 3 polyline lines, arc + line), got %d (%s)." % [made.curves, made.warnings])
	_expect((made.warnings as Array).any(func(w: String) -> bool: return w.contains("HATCH")), "Skipped entity types should be reported (%s)." % [made.warnings])
	if made.feature != null:
		var result := REGEN.rebuild(doc, kernel)
		_no_errors(result, "DXF extras")
		_expect_areas(result, made.feature, [2.0 * PI * IN2, PI * IN2, 4.5 * IN2, 4.0 * IN2, 6.0 * IN2, PI * 0.5 * IN2], "DXF extras")
		_expect(int(result.sketches[made.feature.id].solve.dof) == 0, "The extra DXF's curves should be fully fixed (dof %s)." % result.sketches[made.feature.id].solve.dof)
		var spline := (made.feature.options.entities as Array).filter(func(e: Dictionary) -> bool: return e.type == "spline")
		_expect(spline.size() == 1 and spline[0].mode == "control" and spline[0].has("knots"), "The SPLINE should be a control-point spline keeping its knots.")
		_expect(_count(made.feature, "conic") == 2, "The half ellipse should be two conics (got %d)." % _count(made.feature, "conic"))
	var notes = DOCUMENT.new()
	var noted := DXF_IMPORT.to_sketch(text, notes, SKETCH_DATA.ORIGIN_PLANES.xy, "xy", {"layers": ["Notes"]})
	_expect(noted.feature != null, "The Notes layer should make a sketch.")
	if noted.feature != null:
		var texts := (noted.feature.options.entities as Array).filter(func(e: Dictionary) -> bool: return e.type == "text")
		var words := texts.map(func(e: Dictionary) -> String: return str(e.text))
		_expect(words.has("Ø10") and words.has("Hello World"), "TEXT and MTEXT should become plain sketch text (got %s)." % [words])
		_expect(texts.size() == 2 and _close(float(texts[0].height), 0.5 * 0.0254), "Text height should be in meters (got %s)." % (texts[0].height if not texts.is_empty() else "none"))
		_expect(_count(noted.feature, "point") == 2, "The POINT should be a sketch point (besides the origin).")
	var bad := DXF_IMPORT.to_sketch("hello\nworld\n", DOCUMENT.new(), SKETCH_DATA.ORIGIN_PLANES.xy, "xy")
	_expect(bad.feature == null and not (bad.warnings as Array).is_empty(), "A file that isn't DXF should make no sketch and say why.")


# --- STEP import -----------------------------------------------------------------------------

func _check_step_round_trip() -> void:
	var box: RefCounted = kernel.make_box(Vector3(0.04, 0.02, 0.03), Vector3.ZERO, "src")
	var bore: RefCounted = kernel.make_cylinder(0.005, 0.024, Vector3(0.02, -0.002, 0.015), Vector3.UP, "src")
	var part: RefCounted = kernel.boolean(box, bore, 1, "src")
	var expected: float = part.volume()
	_expect(_close(expected, 0.04 * 0.02 * 0.03 - PI * 0.005 * 0.005 * 0.02), "The test part should be the box minus its bore.")
	var path := OUT + "part.step"
	_expect(kernel.export_file([part], path), "The part should export to STEP (%s)." % kernel.get_last_error())

	var doc = DOCUMENT.new()
	var added := INSERT.add_import(doc, kernel, path)
	_expect(added.feature != null, "add_import should insert the STEP file (%s)." % added.error)
	if added.feature == null:
		return
	var feature: Resource = added.feature
	var body_id := str(feature.options.body_id)
	_expect(feature.options.operation == OPERATIONS.NEW_BODY and doc.bodies.has(body_id) and doc.bodies[body_id].name == "part", "The import should be a new body named after the file.")
	var result := REGEN.rebuild(doc, kernel)
	_no_errors(result, "STEP import")
	_expect(_close(_body_volume(result, body_id), expected), "STEP round trip: volume %s should be %s within 1e-6." % [String.num_scientific(_body_volume(result, body_id)), String.num_scientific(expected)])
	var kept_names: PackedStringArray = result.bodies[body_id].shape.get_face_names() if result.bodies.has(body_id) else PackedStringArray()

	# Linked: the file is read again and gives the same face names as the copy kept in the design.
	feature.options["linked"] = true
	var linked := REGEN.rebuild(doc, kernel)
	_no_errors(linked, "Linked STEP import")
	var linked_names: PackedStringArray = linked.bodies[body_id].shape.get_face_names() if linked.bodies.has(body_id) else PackedStringArray()
	_expect(kept_names.size() >= 7 and kept_names == linked_names, "The kept copy and the re-read file should name their faces alike (%s vs %s)." % [kept_names, linked_names])
	_expect(kept_names.size() > 0 and kept_names[0].begins_with(feature.id + ":"), "Imported faces should be named after the feature (%s)." % [kept_names])

	# Placement transform, and a reference to a face surviving the round trip by name.
	feature.options["transform"] = Transform3D(Basis.IDENTITY, Vector3(0.1, 0.0, 0.0))
	var moved := REGEN.rebuild(doc, kernel)
	_expect(moved.bodies.has(body_id) and _close((moved.bodies[body_id].shape.bbox() as AABB).position.x, 0.1, 1e-5), "The import's transform should place the body.")
	feature.options["transform"] = Transform3D.IDENTITY

	# Without the file the design still builds from its own copy (with a note when linked).
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	var missing := REGEN.rebuild(doc, kernel)
	_no_errors(missing, "STEP import without its file")
	_expect(_close(_body_volume(missing, body_id), expected), "Without the file the kept copy should give the same volume.")
	_expect((missing.warnings as Dictionary).has(feature.id), "A linked import whose file is gone should warn.")
	feature.options["linked"] = false
	_expect(not (REGEN.rebuild(doc, kernel).warnings as Dictionary).has(feature.id), "An unlinked import shouldn't care that the file is gone.")
	var gone := INSERT.add_import(DOCUMENT.new(), kernel, path)
	_expect(gone.feature == null and str(gone.error) != "", "Importing a missing file should give a reason.")

	# BREP keeps meters, and split makes one body per solid.
	var pair: RefCounted = kernel.make_compound([kernel.make_box(Vector3(0.01, 0.01, 0.01), Vector3.ZERO, "a"), kernel.make_box(Vector3(0.01, 0.01, 0.02), Vector3(0.05, 0, 0), "b")])
	var brep := OUT + "pair.brep"
	_expect(kernel.export_file([pair], brep), "The pair should export to BREP.")
	var two = DOCUMENT.new()
	var split := INSERT.add_import(two, kernel, brep)
	_expect(split.feature != null and int(split.solids) == 2, "The BREP pair should hold 2 solids.")
	if split.feature != null:
		split.feature.options["split"] = true
		var parts := REGEN.rebuild(two, kernel)
		_no_errors(parts, "Split import")
		var volumes := []
		for id in parts.bodies:
			volumes.append(parts.bodies[id].shape.volume())
		volumes.sort()
		_expect(volumes.size() == 2 and _close(volumes[0], 1e-6) and _close(volumes[1], 2e-6), "Split import should give one body per solid (%s)." % [volumes])


# --- Meshes ----------------------------------------------------------------------------------

## Every triangle's Godot front face (clockwise) should face away from the mesh's middle.
func _outward(mesh: Dictionary) -> bool:
	var positions: PackedVector3Array = mesh.positions
	var indices: PackedInt32Array = mesh.indices
	var middle := Vector3.ZERO
	for p in positions:
		middle += p
	middle /= maxf(positions.size(), 1)
	for t in range(0, indices.size(), 3):
		var a := positions[indices[t]]
		var b := positions[indices[t + 1]]
		var c := positions[indices[t + 2]]
		if Plane(a, b, c).normal.dot((a + b + c) / 3.0 - middle) <= 0.0:
			return false
	return true


func _check_mesh_feature(path: String, units: String, volume: float, label: String) -> void:
	var doc = DOCUMENT.new()
	var added := INSERT.add_mesh_import(doc, path, units)
	_expect(added.feature != null, "%s: add_mesh_import should work (%s)." % [label, added.error])
	if added.feature == null:
		return
	var result := REGEN.rebuild(doc, kernel)
	_no_errors(result, label)
	var body_id := str(added.feature.options.body_id)
	var shape: RefCounted = result.bodies[body_id].shape if result.bodies.has(body_id) else null
	_expect(shape != null and str(shape.shape_type()) == "SOLID", "%s should import as a closed solid (got %s)." % [label, shape.shape_type() if shape != null else "nothing"])
	_expect(shape != null and _close(shape.volume(), volume), "%s: volume %s should be %s." % [label, String.num_scientific(shape.volume() if shape != null else -1.0), String.num_scientific(volume)])


func _check_meshes() -> void:
	var stl := MESH_IMPORT.read_stl(FIXTURES + "cube_10mm.stl", "mm")
	_expect(stl.error == "" and stl.triangles == 12 and (stl.positions as PackedVector3Array).size() == 8, "The ASCII STL cube should weld to 8 vertices and 12 triangles (got %d, %d; %s)." % [(stl.positions as PackedVector3Array).size(), stl.triangles, stl.error])
	_expect(_outward(stl), "STL triangles should be wound clockwise (Godot) facing out.")
	var obj := MESH_IMPORT.read_obj(FileAccess.get_file_as_string(FIXTURES + "cube_2cm.obj"), "cm")
	_expect(obj.error == "" and obj.triangles == 12 and (obj.positions as PackedVector3Array).size() == 8, "The OBJ cube's quads should fan into 12 triangles over 8 vertices (got %d; %s)." % [obj.triangles, obj.error])
	_expect(_outward(obj), "OBJ triangles should be wound clockwise (Godot) facing out.")
	_check_mesh_feature(FIXTURES + "cube_10mm.stl", "mm", 1e-6, "STL cube")
	_check_mesh_feature(FIXTURES + "cube_2cm.obj", "cm", 8e-6, "OBJ cube")

	# Binary STL (the kernel writes binary, in millimeters), read from its bytes.
	var box: RefCounted = kernel.make_box(Vector3(0.03, 0.02, 0.01), Vector3.ZERO, "stl")
	var binary := OUT + "box.stl"
	_expect(kernel.export_file([box], binary), "The box should export to STL.")
	var read := MESH_IMPORT.read_stl(FileAccess.get_file_as_bytes(binary), "mm")
	_expect(read.error == "" and read.triangles == 12 and _outward(read), "A binary STL box should read as 12 outward triangles (%s)." % read.error)
	var solid: RefCounted = kernel.mesh_to_shape(read.positions, read.indices, "m")
	_expect(solid != null and _close(solid.volume(), 6e-6), "The binary STL box should rebuild to its volume.")

	# glTF: a unit cube under a node scaled 2x (8 cubic meters... in meters, as glTF is).
	var gltf := OUT + "cube.gltf"
	_write_gltf_cube(gltf)
	var g := MESH_IMPORT.read_gltf(gltf)
	_expect(g.error == "" and g.triangles == 12 and _outward(g), "The glTF cube should read as 12 outward triangles (%s)." % g.error)
	_check_mesh_feature(gltf, "cm", 8e-6, "glTF cube (scaled node, read in cm)")

	# Units can change after the insert; a mirrored placement keeps the solid closed and positive.
	var doc = DOCUMENT.new()
	var added := INSERT.add_mesh_import(doc, FIXTURES + "cube_10mm.stl", "mm")
	if added.feature != null:
		added.feature.options["units"] = "cm"
		added.feature.options["transform"] = Transform3D(Basis.from_scale(Vector3(-1, 1, 1)), Vector3.ZERO)
		var result := REGEN.rebuild(doc, kernel)
		var shape: RefCounted = result.bodies.get(str(added.feature.options.body_id), {}).get("shape")
		_expect(shape != null and str(shape.shape_type()) == "SOLID" and _close(shape.volume(), 1e-3), "A cube read in cm and mirrored should be a 1000 cm^3 solid.")
	var junk := INSERT.add_mesh_import(DOCUMENT.new(), FIXTURES + "import_shapes.svg", "mm")
	_expect(junk.feature == null and str(junk.error) != "", "An unsupported mesh file should give a reason.")


func _write_gltf_cube(path: String) -> void:
	var corners := [Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 1, 0), Vector3(0, 1, 0), Vector3(0, 0, 1), Vector3(1, 0, 1), Vector3(1, 1, 1), Vector3(0, 1, 1)]
	# Counter-clockwise from outside, as glTF wants.
	var triangles := [0, 3, 2, 0, 2, 1, 4, 5, 6, 4, 6, 7, 0, 1, 5, 0, 5, 4, 3, 7, 6, 3, 6, 2, 0, 4, 7, 0, 7, 3, 1, 2, 6, 1, 6, 5]
	var bytes := PackedByteArray()
	bytes.resize(96 + 72)
	for k in 8:
		bytes.encode_float(k * 12, corners[k].x)
		bytes.encode_float(k * 12 + 4, corners[k].y)
		bytes.encode_float(k * 12 + 8, corners[k].z)
	for k in 36:
		bytes.encode_u16(96 + k * 2, triangles[k])
	var gltf := {
		"asset": {"version": "2.0"}, "scene": 0, "scenes": [{"nodes": [0]}],
		"nodes": [{"children": [1], "scale": [2.0, 2.0, 2.0]}, {"mesh": 0, "translation": [5.0, 0.0, 0.0]}],
		"meshes": [{"primitives": [{"attributes": {"POSITION": 0}, "indices": 1, "mode": 4}]}],
		"buffers": [{"byteLength": bytes.size(), "uri": "data:application/octet-stream;base64," + Marshalls.raw_to_base64(bytes)}],
		"bufferViews": [{"buffer": 0, "byteOffset": 0, "byteLength": 96, "target": 34962}, {"buffer": 0, "byteOffset": 96, "byteLength": 72, "target": 34963}],
		"accessors": [
			{"bufferView": 0, "componentType": 5126, "count": 8, "type": "VEC3", "min": [0, 0, 0], "max": [1, 1, 1]},
			{"bufferView": 1, "componentType": 5123, "count": 36, "type": "SCALAR"},
		],
	}
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(gltf))
	file.close()


# --- Derive ----------------------------------------------------------------------------------

func _box_doc(size_mm: Vector3) -> Resource:
	var doc = DOCUMENT.new()
	var inputs := {"length": doc.make_input("%s mm" % size_mm.x, "length"), "height": doc.make_input("%s mm" % size_mm.y, "length"), "width": doc.make_input("%s mm" % size_mm.z, "length")}
	var feature: Resource = doc.add_feature("box", "Box", inputs, {"position": Vector3.ZERO, "operation": OPERATIONS.NEW_BODY})
	feature.options["body_id"] = doc.new_body(feature.id)
	return doc


## Saves a design and makes it that file's design (as the editor's Save As does).
func _save_as(doc: Resource, path: String) -> void:
	_expect(ResourceSaver.save(doc, path) == OK, "%s should save." % path.get_file())
	doc.take_over_path(path)


func _derive_feature(doc: Resource, path: String) -> Resource:
	var feature: Resource = doc.add_feature("derive", "Derive", {}, {"path": path, "bodies": [], "body_map": {}, "operation": OPERATIONS.NEW_BODY})
	feature.options["body_id"] = doc.new_body(feature.id)
	return feature


func _check_derive() -> void:
	INSERT.clear_derive_cache()
	var source := _box_doc(Vector3(30, 20, 10))
	var source_path := OUT + "derive_source.tres"
	_expect(ResourceSaver.save(source, source_path) == OK, "The source design should save.")
	var source_volume: float = REGEN.rebuild(source, kernel).bodies.values()[0].shape.volume()

	var doc = DOCUMENT.new()
	var added := INSERT.add_derive(doc, source_path, kernel)
	_expect(added.feature != null, "add_derive should insert the saved design's bodies (%s)." % added.error)
	if added.feature != null:
		var body_id := str(added.feature.options.body_id)
		_expect(doc.bodies[body_id].name == "Body1", "The derived body should keep its source name (got %s)." % doc.bodies[body_id].name)
		var result := REGEN.rebuild(doc, kernel)
		_no_errors(result, "Derive")
		_expect(_close(_body_volume(result, body_id), source_volume) and _close(source_volume, 6e-6), "The derived body should have the source's volume (%s vs %s)." % [_body_volume(result, body_id), source_volume])
		# Linked: saving a bigger source updates the derived body on the next rebuild.
		var bigger := _box_doc(Vector3(30, 20, 20))
		INSERT.clear_derive_cache()
		ResourceSaver.save(bigger, source_path)
		_expect(_close(_body_volume(REGEN.rebuild(doc, kernel), body_id), 12e-6), "The derived body should follow the saved source.")
		added.feature.options["transform"] = Transform3D(Basis.IDENTITY, Vector3(0, 0.5, 0))
		var placed := REGEN.rebuild(doc, kernel)
		_expect(placed.bodies.has(body_id) and _close((placed.bodies[body_id].shape.bbox() as AABB).position.y, 0.5, 1e-5), "The derive's transform should place the body.")

	# A design can't derive from itself...
	var own := _box_doc(Vector3(10, 10, 10))
	var own_path := OUT + "derive_self.tres"
	_save_as(own, own_path)
	var self_add := INSERT.add_derive(own, own_path, kernel)
	_expect(self_add.feature == null and str(self_add.error).contains("itself"), "add_derive should refuse the design's own file (%s)." % self_add.error)
	var self_feature := _derive_feature(own, own_path)
	var self_result := REGEN.rebuild(own, kernel)
	_expect(str(self_result.errors.get(self_feature.id, "")).contains("itself"), "A derive of the design itself should fail clearly (%s)." % self_result.errors)

	# ...nor from a design that derives from it.
	var a := _box_doc(Vector3(10, 10, 10))
	var b := _box_doc(Vector3(10, 10, 10))
	var a_path := OUT + "derive_loop_a.tres"
	var b_path := OUT + "derive_loop_b.tres"
	_derive_feature(a, b_path)
	var b_feature := _derive_feature(b, a_path)
	_save_as(a, a_path)
	_save_as(b, b_path)
	INSERT.clear_derive_cache()
	var loop_result := REGEN.rebuild(b, kernel)
	_expect(str(loop_result.errors.get(b_feature.id, "")).begins_with("Derive loop"), "A derive loop should be refused with a clear error (%s)." % loop_result.errors)
	var outside := INSERT.add_derive(DOCUMENT.new(), a_path, kernel)
	_expect(outside.feature == null and str(outside.error).begins_with("Derive loop"), "Deriving a design caught in a loop should say so (%s)." % outside.error)
	var nothing := INSERT.add_derive(DOCUMENT.new(), OUT + "no_such_design.tres", kernel)
	_expect(nothing.feature == null and str(nothing.error) != "", "Deriving a missing file should give a reason.")


# --- Fasteners -------------------------------------------------------------------------------

func _fastener_volume(kind: String, size: String, length := "") -> Dictionary:
	var doc = DOCUMENT.new()
	var added := INSERT.add_fastener(doc, kind, size, Vector3(0.1, 0.2, 0.3), Vector3.DOWN, length)
	if added.feature == null:
		return {"volume": -1.0, "error": added.error}
	var result := REGEN.rebuild(doc, kernel)
	var body_id := str(added.feature.options.body_id)
	return {"volume": _body_volume(result, body_id), "result": result, "body": body_id, "doc": doc, "feature": added.feature, "error": result.errors}


func _check_fasteners() -> void:
	var hexagon := func(s: float) -> float: return sqrt(3.0) * 0.5 * s * s
	var washer := _fastener_volume("washer", "M6")
	var washer_expected := PI * (12.0 * 12.0 - 6.4 * 6.4) / 4.0 * 1.6 * MM3
	_expect(_close(washer.volume, washer_expected), "An M6 washer should be pi*(d2^2-d1^2)/4*h = %s (got %s; %s)." % [String.num_scientific(washer_expected), String.num_scientific(washer.volume), washer.error])
	var nut := _fastener_volume("hex_nut", "M8")
	var nut_expected: float = (hexagon.call(13.0) * 6.8 - PI * (6.647 * 0.5) ** 2 * 6.8) * MM3
	_expect(_close(nut.volume, nut_expected), "An M8 nut should be the hexagon prism minus its bore = %s (got %s; %s)." % [String.num_scientific(nut_expected), String.num_scientific(nut.volume), nut.error])
	var bolt := _fastener_volume("hex_bolt", "M6", "20 mm")
	var bolt_expected: float = (hexagon.call(10.0) * 4.0 + PI * 9.0 * 20.0) * MM3
	_expect(_close(bolt.volume, bolt_expected), "An M6x20 hex bolt should be head + shank = %s (got %s; %s)." % [String.num_scientific(bolt_expected), String.num_scientific(bolt.volume), bolt.error])
	var socket := _fastener_volume("socket_bolt", "M5", "16 mm")
	var socket_expected: float = (PI * 4.25 * 4.25 * 5.0 - hexagon.call(4.0) * 2.5 + PI * 2.5 * 2.5 * 16.0) * MM3
	_expect(_close(socket.volume, socket_expected), "An M5x16 socket head screw should be head - socket + shank = %s (got %s; %s)." % [String.num_scientific(socket_expected), String.num_scientific(socket.volume), socket.error])
	if bolt.has("result"):
		# Axis down: the head stands above the position and the shank reaches 20 mm below it.
		var box: AABB = bolt.result.bodies[bolt.body].shape.bbox()
		_expect(_close(box.end.y, 0.2 + 0.004, 1e-5) and _close(box.position.y, 0.2 - 0.02, 1e-5), "The bolt's head should sit on the position with the shank below (%s)." % box)
		var thread: Dictionary = bolt.result.threads.get("%s:%s" % [bolt.feature.id, bolt.body], {})
		_expect(not thread.is_empty() and _close(float(thread.length), 0.02) and _close(float(thread.pitch), 0.001), "The bolt's cosmetic thread should be noted (%s)." % thread)
		# Parametric length.
		bolt.feature.set_expression("length", "30 mm")
		var longer := REGEN.rebuild(bolt.doc, kernel)
		_expect(_close(_body_volume(longer, bolt.body), (hexagon.call(10.0) * 4.0 + PI * 9.0 * 30.0) * MM3), "Changing the bolt's length should rebuild it longer.")
	var default_length := _fastener_volume("hex_bolt", "M8")
	_expect(_close(default_length.volume, (hexagon.call(13.0) * 5.3 + PI * 16.0 * 25.0) * MM3), "A bolt without a length should take its size's default (M8: 25 mm).")
	var unknown := INSERT.add_fastener(DOCUMENT.new(), "hex_bolt", "M7", Vector3.ZERO)
	_expect(unknown.feature == null and str(unknown.error) != "", "An unknown size should give a reason.")
	_expect(INSERT.fastener_sizes("washer").size() == 7 and INSERT.fastener_kinds().size() == 4, "The table should list 4 kinds and 7 washer sizes.")


# --- Edge cases (review) ---------------------------------------------------------------------

## Profile count and area of an SVG made of one path on a 200 x 200 mm page.
func _svg_path_profiles(d: String, label: String) -> Dictionary:
	var doc = DOCUMENT.new()
	var svg := "<svg width=\"200mm\" height=\"200mm\" viewBox=\"0 0 200 200\"><path d=\"%s\"/></svg>" % d
	var made := SVG_IMPORT.to_sketch(svg, doc, SKETCH_DATA.ORIGIN_PLANES.xy, "xy")
	_expect(made.feature != null, "%s should make a sketch (%s)." % [label, made.warnings])
	if made.feature == null:
		return {"curves": 0, "areas": []}
	return {"curves": made.curves, "areas": _areas(REGEN.rebuild(doc, kernel), made.feature), "feature": made.feature}


func _check_edge_cases() -> void:
	# A path whose last point misses its start by 0.5 micrometers (inside is_equal_approx's
	# relative tolerance at 100 mm, outside the writer's merge distance) still closes with Z.
	var gap := _svg_path_profiles("M 100 100 L 150 100 L 150 150 L 100 100.0005 Z", "Near-closed SVG path")
	_expect(gap.curves == 4 and (gap.areas as Array).size() == 1, "A near-closed SVG path should get its closing line and one profile (%d curves, %s)." % [gap.curves, gap.areas])
	if (gap.areas as Array).size() == 1:
		_expect(_close(gap.areas[0], 1250.0125 * MM2, 1e-5), "The near-closed path's area should be 1250.0125 mm2 (got %s)." % String.num_scientific(gap.areas[0]))
	# An arc whose ends are nearly (not exactly) equal is drawn, not dropped.
	var arc := _svg_path_profiles("M 100 100 L 150 100 L 150 150 L 100 150 L 100 100.0005 A 1 1 0 0 1 100 100 Z", "Near-equal SVG arc ends")
	_expect(arc.curves == 5 and (arc.areas as Array).size() == 1, "An arc between nearly equal points should stay, closing the path (%d curves, %s)." % [arc.curves, arc.areas])
	# rotate(a cx cy) and matrix() transforms: a 20 x 10 rectangle turned 90 degrees about (50, 50).
	var lone := SVG_IMPORT.to_sketch("<svg viewBox=\"0 0 10 10\"><path d=\"M 0 0\"/></svg>", DOCUMENT.new(), SKETCH_DATA.ORIGIN_PLANES.xy, "xy")
	_expect(lone.feature == null and lone.curves == 0, "A lone moveto draws nothing.")
	var doc = DOCUMENT.new()
	var svg := "<svg width=\"100mm\" height=\"100mm\" viewBox=\"0 0 100 100\"><g transform=\"matrix(1 0 0 1 0 0) rotate(90 50 50)\"><rect x=\"50\" y=\"50\" width=\"20\" height=\"10\"/></g></svg>"
	var rect := SVG_IMPORT.to_sketch(svg, doc, SKETCH_DATA.ORIGIN_PLANES.xy, "xy")
	if rect.feature != null:
		var lo := Vector2(INF, INF)
		var hi := Vector2(-INF, -INF)
		for e in rect.feature.options.entities:
			if e.type == "point" and not e.get("origin", false):
				lo = Vector2(minf(lo.x, e.x), minf(lo.y, e.y))
				hi = Vector2(maxf(hi.x, e.x), maxf(hi.y, e.y))
		_expect(lo.distance_to(Vector2(0.04, 0.03)) < 1e-6 and hi.distance_to(Vector2(0.05, 0.05)) < 1e-6, "rotate(90 50 50) should turn the rectangle onto x 40..50, y 30..50 mm (got %s..%s)." % [lo, hi])
		_expect_areas(REGEN.rebuild(doc, kernel), rect.feature, [200.0 * MM2], "Rotated SVG rectangle")

	# DXF: a closed two-vertex LWPOLYLINE with bulges of 1 is a circle (radius 5 mm).
	var l := []
	_pair(l, 0, "SECTION"); _pair(l, 2, "ENTITIES")
	_pair(l, 0, "LWPOLYLINE"); _pair(l, 8, "C"); _pair(l, 90, 2); _pair(l, 70, 1)
	_pair(l, 10, 0.0); _pair(l, 20, 0.0); _pair(l, 42, 1.0); _pair(l, 10, 10.0); _pair(l, 20, 0.0); _pair(l, 42, 1.0)
	# ...while a closed straight pair stays one line (no second line on top of it).
	_pair(l, 0, "LWPOLYLINE"); _pair(l, 8, "L"); _pair(l, 90, 2); _pair(l, 70, 1)
	_pair(l, 10, 20.0); _pair(l, 20, 0.0); _pair(l, 10, 30.0); _pair(l, 20, 0.0)
	_pair(l, 0, "ENDSEC"); _pair(l, 0, "EOF")
	var circle_doc = DOCUMENT.new()
	var circle := DXF_IMPORT.to_sketch("\n".join(PackedStringArray(l)), circle_doc, SKETCH_DATA.ORIGIN_PLANES.xy, "xy")
	_expect(circle.feature != null and circle.curves == 3, "A closed bulged 2-vertex polyline should give 2 arcs, the straight one 1 line (got %d)." % circle.curves)
	if circle.feature != null:
		_expect_areas(REGEN.rebuild(circle_doc, kernel), circle.feature, [25.0 * PI * MM2], "DXF 2-vertex bulge circle")

	# Derive: a design caught in a loop is refused even when the other design is already cached
	# (rebuilt earlier for a third design that isn't part of the loop).
	INSERT.clear_derive_cache()
	var d := _box_doc(Vector3(10, 10, 10))
	var d_path := OUT + "cache_loop_d.tres"
	_save_as(d, d_path)
	var x := _box_doc(Vector3(5, 5, 5))
	_derive_feature(x, d_path)
	var x_path := OUT + "cache_loop_x.tres"
	_save_as(x, x_path)
	var third := INSERT.add_derive(DOCUMENT.new(), x_path, kernel)
	_expect(third.feature != null and (third.bodies as Array).size() == 2, "A third design should derive X's 2 bodies (%s)." % third.error)
	var back := INSERT.add_derive(d, x_path, kernel)
	_expect(back.feature == null and str(back.error).begins_with("Derive loop"), "D deriving X (which derives D) should be a loop even with X cached (%s)." % back.error)
	var loop_feature := _derive_feature(d, x_path)
	var looped := REGEN.rebuild(d, kernel)
	_expect(str(looped.errors.get(loop_feature.id, "")).begins_with("Derive loop"), "Rebuilding D with the cached X should report the loop (%s)." % looped.errors)
	var again := INSERT.add_derive(DOCUMENT.new(), x_path, kernel)
	_expect(again.feature != null, "X should still derive cleanly outside the loop (%s)." % again.error)

	# Split import: the feature's tool shape (for patterns and mirrors) holds every solid.
	var two = DOCUMENT.new()
	var pair: RefCounted = kernel.make_compound([kernel.make_box(Vector3(0.01, 0.01, 0.01), Vector3.ZERO, "a"), kernel.make_box(Vector3(0.01, 0.01, 0.02), Vector3(0.05, 0, 0), "b")])
	var brep := OUT + "pair_tools.brep"
	kernel.export_file([pair], brep)
	var split := INSERT.add_import(two, kernel, brep)
	if split.feature != null:
		split.feature.options["split"] = true
		var ctx := {"kernel": kernel, "doc": two, "values": PARAMETERS.evaluate(two), "bodies": {}, "sketches": {}, "construction": {}, "tools": {}, "warnings": {}, "threads": {}}
		var error := INSERT.build(split.feature, ctx)
		_expect(error == "" and ctx.bodies.size() == 2, "A split import should build 2 bodies (%s)." % error)
		var tool: RefCounted = (ctx.tools.get(split.feature.id, {}) as Dictionary).get("shape")
		_expect(tool != null and int(tool.solid_count()) == 2, "A split import's tool shape should hold both solids (got %s)." % (tool.solid_count() if tool != null else "none"))

	# Mesh units default by format: glTF in meters, STL in millimeters.
	var gltf := OUT + "cube_units.gltf"
	_write_gltf_cube(gltf)
	var g_doc = DOCUMENT.new()
	var g := INSERT.add_mesh_import(g_doc, gltf)
	_expect(g.feature != null and str(g.feature.options.units) == "m", "A glTF mesh should default to meters (%s)." % (g.feature.options.units if g.feature != null else g.error))
	if g.feature != null:
		var g_result := REGEN.rebuild(g_doc, kernel)
		_expect(_close(_body_volume(g_result, str(g.feature.options.body_id)), 8.0), "The 2x-scaled unit glTF cube should be 8 cubic meters (got %s)." % _body_volume(g_result, str(g.feature.options.body_id)))
	var s := INSERT.add_mesh_import(DOCUMENT.new(), FIXTURES + "cube_10mm.stl")
	_expect(s.feature != null and str(s.feature.options.units) == "mm", "An STL mesh should default to millimeters.")


# --- 3MF -------------------------------------------------------------------------------------

func _bounds(result: Dictionary, body_id: String) -> AABB:
	return result.bodies[body_id].shape.bbox() if result.bodies.has(body_id) else AABB()


## Two boxes agree to within tolerance (meters) at both corners.
func _same_box(a: AABB, b: AABB, tolerance := 1e-6) -> bool:
	return a.position.distance_to(b.position) <= tolerance and a.end.distance_to(b.end) <= tolerance


func _mesh_bounds(mesh: Dictionary) -> AABB:
	var positions: PackedVector3Array = mesh.positions
	var box := AABB(positions[0], Vector3.ZERO)
	for p in positions:
		box = box.expand(p)
	return box


func _check_3mf() -> void:
	# A 10 mm cube (no unit attribute: millimeters) turned 90 degrees about Z and moved (20, 0, 5)
	# by its build item: the row-vector transform lands it on x 10..20, y 0..10, z 5..15 mm.
	var placed_path := FIXTURES + "cube_10mm_placed.3mf"
	var cube := MESH_IMPORT.read_3mf(placed_path)
	_expect(cube.error == "" and cube.triangles == 12 and (cube.positions as PackedVector3Array).size() == 8 and str(cube.file_units) == "mm",
		"The 3MF cube should weld to 8 vertices and 12 triangles in millimeters (got %d, %d, %s; %s)." % [(cube.positions as PackedVector3Array).size(), cube.triangles, cube.get("file_units"), cube.error])
	if cube.error != "":
		return
	_expect(_outward(cube), "3MF triangles should be wound clockwise (Godot) facing out.")
	var expected := AABB(Vector3(0.01, 0.0, 0.005), Vector3.ONE * 0.01)
	_expect(_same_box(_mesh_bounds(cube), expected), "The build item's transform should place the cube on %s (got %s)." % [expected, _mesh_bounds(cube)])
	var doc = DOCUMENT.new()
	var added := INSERT.add_mesh_import(doc, placed_path)
	_expect(added.feature != null and str(added.feature.options.units) == "mm", "Insert Mesh should take the 3MF's unit (%s)." % (added.feature.options.units if added.feature != null else added.error))
	_check_mesh_feature(placed_path, "", 1e-6, "3MF cube")
	if added.feature != null:
		var result := REGEN.rebuild(doc, kernel)
		_expect(_same_box(_bounds(result, str(added.feature.options.body_id)), expected, 1e-5), "The inserted 3MF cube should sit where its build item put it (%s)." % _bounds(result, str(added.feature.options.body_id)))

	# Centimeters, with the model part named by _rels/.rels: an object of three components of a
	# 1 cm cube (as it is, scaled 2x, mirrored) placed by its build item; the support is left out.
	var parts_path := FIXTURES + "components_cm.3mf"
	var parts := MESH_IMPORT.read_3mf(parts_path)
	_expect(parts.error == "" and parts.triangles == 36 and str(parts.file_units) == "cm",
		"The 3MF assembly should give 3 cubes (36 triangles) in centimeters without its support (got %d, %s; %s)." % [parts.triangles, parts.get("file_units"), parts.error])
	if parts.error != "":
		return
	var pieces := MESH_IMPORT.pieces(parts.positions, parts.indices)
	_expect(pieces.size() == 3 and pieces.all(func(piece: Dictionary) -> bool: return (piece.positions as PackedVector3Array).size() == 8 and _outward(piece)),
		"The assembly should split into 3 cubes of 8 vertices, each wound outward, also the mirrored one (got %d pieces)." % pieces.size())
	_expect(_same_box(_mesh_bounds(parts), AABB(Vector3(-0.03, 0.0, 0.1), Vector3(0.08, 0.02, 0.02))), "Components and the build item should place the cubes on x -3..5, y 0..2, z 10..12 cm (got %s)." % _mesh_bounds(parts))
	var override := MESH_IMPORT.read_3mf(parts_path, "mm")
	_expect(override.error == "" and _same_box(_mesh_bounds(override), AABB(Vector3(-0.003, 0.0, 0.01), Vector3(0.008, 0.002, 0.002))), "A units override should win over the file's unit (got %s)." % _mesh_bounds(override))

	var assembly = DOCUMENT.new()
	var inserted := INSERT.add_mesh_import(assembly, parts_path)
	_expect(inserted.feature != null and str(inserted.feature.options.units) == "cm", "Insert Mesh should read the assembly in centimeters (%s)." % (inserted.feature.options.units if inserted.feature != null else inserted.error))
	if inserted.feature == null:
		return
	var body_id := str(inserted.feature.options.body_id)
	var result := REGEN.rebuild(assembly, kernel)
	_no_errors(result, "3MF assembly")
	_expect(not (result.warnings as Dictionary).has(inserted.feature.id), "Three closed cubes shouldn't warn about open meshes (%s)." % result.warnings)
	var shape: RefCounted = result.bodies[body_id].shape if result.bodies.has(body_id) else null
	_expect(shape != null and int(shape.solid_count()) == 3 and _close(shape.volume(), 1e-5), "The assembly should be 3 solids of 1 + 8 + 1 cm^3 (got %s solids, %s)." % [shape.solid_count() if shape != null else 0, String.num_scientific(shape.volume() if shape != null else -1.0)])
	if shape != null:
		var names: PackedStringArray = shape.get_face_names()
		var unique := {}
		for name in names:
			unique[name] = true
		_expect(names.size() == 36 and unique.size() == 36, "Each piece's faces should keep their own names (%d names, %d unique)." % [names.size(), unique.size()])
	inserted.feature.options["units"] = "mm"
	_expect(_close(_body_volume(REGEN.rebuild(assembly, kernel), body_id), 1e-8), "The assembly read in millimeters should be 10 mm^3.")
	inserted.feature.options["units"] = "cm"
	inserted.feature.options["split"] = true
	var split := REGEN.rebuild(assembly, kernel)
	_no_errors(split, "Split 3MF assembly")
	var volumes := []
	for id in split.bodies:
		volumes.append(split.bodies[id].shape.volume())
	volumes.sort()
	_expect(volumes.size() == 3 and _close(volumes[0], 1e-6) and _close(volumes[1], 1e-6) and _close(volumes[2], 8e-6), "One Body per Piece should give 3 bodies of 1, 1 and 8 cm^3 (%s)." % [volumes])

	var junk := OUT + "not_a_package.3mf"
	var file := FileAccess.open(junk, FileAccess.WRITE)
	file.store_string("solid nothing")
	file.close()
	_expect(str(MESH_IMPORT.read_3mf(junk).error) != "", "A 3MF that isn't a zip package should give a reason.")


# --- Insert edit panels ----------------------------------------------------------------------

## The edit command for a feature, as a timeline double-click opens it (without the editor).
func _editor_for(feature: Resource) -> RefCounted:
	var command: RefCounted = INSERT_COMMAND.new(feature.type)
	command.feature = feature
	command.editing = true
	command.hints = {"units": "mm", "default_size_m": 0.05}
	return command


func _check_insert_edits() -> void:
	# Insert Mesh: units, offset and angle, Z-up, then another file.
	var doc = DOCUMENT.new()
	var added := INSERT.add_mesh_import(doc, FIXTURES + "cube_10mm.stl", "mm")
	if added.feature == null:
		_expect(false, "The STL cube should insert for the edit test (%s)." % added.error)
		return
	var feature: Resource = added.feature
	var body_id := str(feature.options.body_id)
	var mesh := _editor_for(feature)
	var values: Dictionary = mesh.read_values()
	_expect(str(values.path) == FIXTURES + "cube_10mm.stl" and str(values.units) == "mm" and values.z_up == false and str(values.x) == "0" and str(values.ry) == "0",
		"The mesh's edit panel should open on its file, units and a zero placement (%s)." % [values])
	_expect(mesh.fields().any(func(f: Dictionary) -> bool: return f.key == "source" and str(f.text).contains("12 triangles")), "The Source row should name the file and its triangles.")
	values.units = "cm"
	values.x = "5 mm"
	values.ry = "45"
	mesh.write_values(doc, values)
	_expect(feature.inputs.has("x") and feature.inputs.has("rz") and not feature.options.has("z_up") and not feature.options.has("browse") and not feature.options.has("source"),
		"The edit should add the placement inputs and keep panel-only rows out of the options (%s)." % [feature.options.keys()])
	var result := REGEN.rebuild(doc, kernel)
	_no_errors(result, "Edited mesh")
	# A 10 cm cube turned 45 degrees about Y around its middle (5, 5, 5) cm, then moved 5 mm in x.
	var half := 0.05 * sqrt(2.0)
	var turned := AABB(Vector3(0.05 - half + 0.005, 0.0, 0.05 - half), Vector3(2.0 * half, 0.1, 2.0 * half))
	_expect(_close(_body_volume(result, body_id), 1e-3) and _same_box(_bounds(result, body_id), turned, 1e-5),
		"Units cm, 45 degrees about Y and +5 mm in x should give a 1000 cm^3 cube on %s (got %s, %s)." % [turned, _body_volume(result, body_id), _bounds(result, body_id)])
	values.ry = "0"
	values.z_up = true
	mesh.write_values(doc, values)
	_expect((feature.options.transform as Transform3D).is_equal_approx(INSERT.Z_UP), "Ticking Z-Up should stand the file up.")
	var upright := REGEN.rebuild(doc, kernel)
	_expect(_same_box(_bounds(upright, body_id), AABB(Vector3(0.005, 0.0, -0.1), Vector3.ONE * 0.1), 1e-5), "A Z-up file's +Z should become +Y (got %s)." % _bounds(upright, body_id))
	values.z_up = false
	mesh.write_values(doc, values)
	_expect((feature.options.transform as Transform3D).is_equal_approx(Transform3D.IDENTITY), "Unticking Z-Up should take the turn away.")
	# Another file: the 2 cm OBJ cube (still read in cm), then one that can't be read.
	values.path = FIXTURES + "cube_2cm.obj"
	mesh.write_values(doc, values)
	_expect(str(feature.options.path) == FIXTURES + "cube_2cm.obj" and doc.bodies[body_id].name == "cube_2cm", "The new file should be taken and the body renamed after it (%s, %s)." % [feature.options.path, doc.bodies[body_id].name])
	_expect(_close(_body_volume(REGEN.rebuild(doc, kernel), body_id), 8e-6), "The OBJ cube read in cm should be 8 cm^3.")
	values.path = OUT + "no_such_mesh.stl"
	mesh.write_values(doc, values)
	_expect(str(feature.options.path) == FIXTURES + "cube_2cm.obj" and mesh.fields().any(func(f: Dictionary) -> bool: return f.key == "source" and str(f.text).contains("can't be found")),
		"A file that can't be read should leave the old one in use and say why.")
	values.path = FIXTURES + "components_cm.3mf"
	mesh.write_values(doc, values)
	_expect(str(feature.options.units) == "cm" and str(values.units) == "cm", "A 3MF file should bring its own unit into the panel.")
	values.units = "mm"
	values.x = "0"
	values.split = true
	mesh.write_values(doc, values)
	var parts := REGEN.rebuild(doc, kernel)
	_expect(parts.bodies.size() == 3 and _close(_body_volume(parts, body_id), 1e-9), "One Body per Piece from the panel should give 3 bodies (got %d)." % parts.bodies.size())

	# Import: an angle and an offset, then another file split into bodies.
	var box: RefCounted = kernel.make_box(Vector3(0.02, 0.01, 0.03), Vector3.ZERO, "edit")
	var step := OUT + "edit_box.step"
	kernel.export_file([box], step)
	var pair: RefCounted = kernel.make_compound([kernel.make_box(Vector3(0.01, 0.01, 0.01), Vector3.ZERO, "a"), kernel.make_box(Vector3(0.01, 0.01, 0.02), Vector3(0.05, 0, 0), "b")])
	var brep := OUT + "edit_pair.brep"
	kernel.export_file([pair], brep)
	var import_doc = DOCUMENT.new()
	var imported := INSERT.add_import(import_doc, kernel, step)
	_expect(imported.feature != null, "The STEP box should import for the edit test (%s)." % imported.error)
	if imported.feature != null:
		var import_body := str(imported.feature.options.body_id)
		var edit := _editor_for(imported.feature)
		var v: Dictionary = edit.read_values()
		v.z = "10 mm"
		v.rz = "90"
		edit.write_values(import_doc, v)
		var moved := REGEN.rebuild(import_doc, kernel)
		# 20 x 10 x 30 mm turned 90 degrees about Z around its middle (10, 5, 15) mm, then +10 mm in z.
		_expect(_same_box(_bounds(moved, import_body), AABB(Vector3(0.005, -0.005, 0.01), Vector3(0.01, 0.02, 0.03)), 1e-5) and _close(_body_volume(moved, import_body), 6e-6),
			"The import's angle and offset should place it (got %s)." % _bounds(moved, import_body))
		v.rz = "0"
		v.z = "0"
		v.path = brep
		v.split = true
		edit.write_values(import_doc, v)
		var two := REGEN.rebuild(import_doc, kernel)
		_no_errors(two, "Import edited to the BREP pair")
		_expect(str(imported.feature.options.path) == brep and two.bodies.size() == 2 and _close(_body_volume(two, import_body), 1e-6) and import_doc.bodies[import_body].name == "edit_pair",
			"The import should switch to the pair and split it into 2 bodies (got %d, %s)." % [two.bodies.size(), import_doc.bodies[import_body].name])
		DirAccess.remove_absolute(ProjectSettings.globalize_path(brep))
		_expect(_close(_body_volume(REGEN.rebuild(import_doc, kernel), import_body), 1e-6), "The new file's copy should be kept in the design.")

	# Derive: another design with two bodies, then only one of them, moved.
	INSERT.clear_derive_cache()
	var one_box := _box_doc(Vector3(30, 20, 10))
	var one_path := OUT + "edit_derive_one.tres"
	ResourceSaver.save(one_box, one_path)
	var two_boxes := _box_doc(Vector3(10, 10, 10))
	var big: Resource = two_boxes.add_feature("box", "Box", {"length": two_boxes.make_input("20 mm", "length"), "height": two_boxes.make_input("20 mm", "length"),
		"width": two_boxes.make_input("20 mm", "length")}, {"position": Vector3(0.1, 0, 0), "operation": OPERATIONS.NEW_BODY})
	big.options["body_id"] = two_boxes.new_body(big.id)
	var two_path := OUT + "edit_derive_two.tres"
	ResourceSaver.save(two_boxes, two_path)
	var derive_doc = DOCUMENT.new()
	var derived := INSERT.add_derive(derive_doc, one_path, kernel)
	if derived.feature == null:
		_expect(false, "The derive for the edit test should insert (%s)." % derived.error)
		return
	var main_body := str(derived.feature.options.body_id)
	var d := _editor_for(derived.feature)
	var dv: Dictionary = d.read_values()
	_expect(dv.get("body:body1", false) == true and d.fields().filter(func(f: Dictionary) -> bool: return str(f.key).begins_with("body:")).size() == 1,
		"The derive panel should list the source's one body, ticked (%s)." % [dv])
	dv.path = two_path
	d.write_values(derive_doc, dv)
	var map: Dictionary = derived.feature.options.body_map
	_expect(map.size() == 2 and str(map.get("body1", "")) == main_body and derive_doc.bodies.size() == 2 and dv.get("body:body2", false) == true,
		"The new design's bodies should map onto the feature's body (same source id) plus a new one (%s, %d bodies)." % [map, derive_doc.bodies.size()])
	var both := REGEN.rebuild(derive_doc, kernel)
	_no_errors(both, "Derive switched to two bodies")
	_expect(both.bodies.size() == 2 and _close(_body_volume(both, main_body), 1e-6) and _close(_body_volume(both, str(map.get("body2", ""))), 8e-6), "Both bodies of the new design should come in.")
	dv["body:body1"] = false
	dv.y = "5 mm"
	d.write_values(derive_doc, dv)
	_expect(Array(derived.feature.options.bodies) == ["body2"], "Unticking a body should leave it out (%s)." % [derived.feature.options.bodies])
	var one := REGEN.rebuild(derive_doc, kernel)
	var kept_id := str(map.get("body2", ""))
	_expect(one.bodies.size() == 1 and one.bodies.has(kept_id) and _same_box(_bounds(one, kept_id), AABB(Vector3(0.09, 0.005, -0.01), Vector3.ONE * 0.02), 1e-5),
		"Only the big body should come in, 5 mm higher (got %s, %s)." % [one.bodies.keys(), _bounds(one, kept_id)])
	dv["body:body2"] = false
	d.write_values(derive_doc, dv)
	_expect(Array(derived.feature.options.bodies) == ["body2"] and dv.get("body:body2", false) == true, "The last ticked body should stay ticked.")


# --- Fasteners following their face ----------------------------------------------------------

func _face_toward(shape: RefCounted, normal: Vector3) -> int:
	for i in shape.face_count():
		var info: Dictionary = shape.face_info(i)
		if info.get("planar", false) and (info.normal as Vector3).dot(normal) > 0.999:
			return i
	return -1


func _check_fastener_follow() -> void:
	var doc := _box_doc(Vector3(20, 10, 20))
	var box_feature: Resource = doc.features[0]
	var box_body := str(box_feature.options.body_id)
	var first := REGEN.rebuild(doc, kernel)
	var shape: RefCounted = first.bodies[box_body].shape
	var top := REFERENCES.from_pick({"kind": "face", "body": box_body, "index": _face_toward(shape, Vector3.UP)}, first)
	var side := REFERENCES.from_pick({"kind": "face", "body": box_body, "index": _face_toward(shape, Vector3.RIGHT)}, first)
	var washer := INSERT.add_fastener(doc, "washer", "M6", Vector3(0.002, 0.01, 0.003), Vector3.UP, "", top)
	# The bolt's stored axis is wrong on purpose: "auto" takes it from the side face (into it).
	var bolt := INSERT.add_fastener(doc, "hex_bolt", "M6", Vector3(0.01, 0.005, 0.0), Vector3.DOWN, "8 mm", side)
	var fixed := INSERT.add_fastener(doc, "washer", "M6", Vector3(-0.004, 0.01, 0.0), Vector3.UP)
	var lost := INSERT.add_fastener(doc, "hex_nut", "M6", Vector3(0.0, 0.05, 0.0), Vector3.UP, "", {"kind": "face", "body": "body99", "name": "f9:top", "sig": {}})
	if washer.feature == null or bolt.feature == null or fixed.feature == null or lost.feature == null:
		_expect(false, "The fasteners for the follow test should insert.")
		return
	var w_id := str(washer.feature.options.body_id)
	var b_id := str(bolt.feature.options.body_id)
	var f_id := str(fixed.feature.options.body_id)
	var l_id := str(lost.feature.options.body_id)
	var h := float(INSERT.fastener_size("washer", "M6").h)
	var k := float(INSERT.fastener_size("hex_bolt", "M6").k)
	var before := REGEN.rebuild(doc, kernel)
	_expect(_close(_bounds(before, w_id).position.y, 0.01, 1e-5) and _close(_bounds(before, w_id).get_center().x, 0.002, 1e-4), "The washer should stand on the top face where it was placed (%s)." % _bounds(before, w_id))
	_expect(_close(_bounds(before, b_id).position.x, 0.002, 1e-4) and _close(_bounds(before, b_id).end.x, 0.01 + k, 1e-4), "The bolt should run into the side face, its head outside (%s)." % _bounds(before, b_id))
	var volume := _body_volume(before, w_id)

	# The box grows: 25 mm tall and 30 mm long.
	box_feature.set_expression("height", "25 mm")
	box_feature.set_expression("length", "30 mm")
	var after := REGEN.rebuild(doc, kernel)
	_expect(not (after.warnings as Dictionary).has(washer.feature.id) and not (after.errors as Dictionary).has(washer.feature.id), "Following a face that is still there shouldn't warn (%s)." % after.warnings)
	_expect(_close(_bounds(after, w_id).position.y, 0.025, 1e-5) and _close(_bounds(after, w_id).end.y, 0.025 + h, 1e-5) and _close(_body_volume(after, w_id), volume),
		"The washer should stay on the top face of the taller box (%s)." % _bounds(after, w_id))
	_expect(_close(_bounds(after, w_id).get_center().x, 0.002, 1e-4) and _close(_bounds(after, w_id).get_center().z, 0.003, 1e-4), "The washer should keep its place across the face.")
	_expect(_close(_bounds(after, b_id).position.x, 0.007, 1e-4) and _close(_bounds(after, b_id).end.x, 0.015 + k, 1e-4), "The bolt should follow the side face out to x = 15 mm (%s)." % _bounds(after, b_id))
	_expect(_close(_bounds(after, f_id).position.y, 0.01, 1e-5), "A fastener placed by coordinates should stay put (%s)." % _bounds(after, f_id))
	_expect(str((after.warnings as Dictionary).get(lost.feature.id, "")).contains("stays where it was placed") and _close(_bounds(after, l_id).position.y, 0.05, 1e-5),
		"A fastener whose face is gone should stay at its stored place with a warning (%s)." % after.warnings)
	# The cosmetic thread follows too.
	var thread: Dictionary = after.threads.get("%s:%s" % [bolt.feature.id, b_id], {})
	_expect(not thread.is_empty() and (thread.axis as Vector3).is_equal_approx(Vector3.LEFT), "The bolt's thread should run along its new axis (%s)." % thread)


# --- Review fixes ----------------------------------------------------------------------------

## A DXF of the given entity lines (already paired) in millimeters ($INSUNITS 4 unless units).
func _dxf(entities: Array, units := 4, blocks := []) -> String:
	var l := []
	_pair(l, 0, "SECTION"); _pair(l, 2, "HEADER"); _pair(l, 9, "$INSUNITS"); _pair(l, 70, units); _pair(l, 0, "ENDSEC")
	if not blocks.is_empty():
		_pair(l, 0, "SECTION"); _pair(l, 2, "BLOCKS")
		l.append_array(blocks)
		_pair(l, 0, "ENDSEC")
	_pair(l, 0, "SECTION"); _pair(l, 2, "ENTITIES")
	l.append_array(entities)
	_pair(l, 0, "ENDSEC"); _pair(l, 0, "EOF")
	return "\n".join(PackedStringArray(l))


func _ellipse_dxf(end_parameter: String, ratio := "0.5") -> String:
	var e := []
	_pair(e, 0, "ELLIPSE"); _pair(e, 8, "0"); _pair(e, 10, "0.0"); _pair(e, 20, "0.0"); _pair(e, 11, "20.0"); _pair(e, 21, "0.0")
	_pair(e, 40, ratio); _pair(e, 41, "0.000000"); _pair(e, 42, end_parameter)
	return _dxf(e)


## A closed LWPOLYLINE through points (drawing units) with optional bulges.
func _lwpolyline(points: Array, bulges := []) -> Array:
	var e := []
	_pair(e, 0, "LWPOLYLINE"); _pair(e, 8, "0"); _pair(e, 90, points.size()); _pair(e, 70, 1)
	for k in points.size():
		_pair(e, 10, "%.6f" % points[k].x); _pair(e, 20, "%.6f" % points[k].y)
		if k < bulges.size() and float(bulges[k]) != 0.0:
			_pair(e, 42, bulges[k])
	return e


func _check_dxf_review() -> void:
	# A whole ELLIPSE whose end parameter is 2 pi printed with 6 or 7 decimals (6.283185 misses
	# TAU by 3e-7) is one ellipse, not a dropped near-closed arc with a stray point.
	for end in ["6.283185", "6.2831853", "6.28318", "6.283185307179586"]:
		var doc = DOCUMENT.new()
		var made := DXF_IMPORT.to_sketch(_ellipse_dxf(end), doc, SKETCH_DATA.ORIGIN_PLANES.xy, "xy")
		_expect(made.feature != null and made.curves == 1 and _count(made.feature, "ellipse") == 1, "An ELLIPSE ending at %s should be one whole ellipse (got %d curves; %s)." % [end, made.curves, made.warnings])
		if made.feature != null:
			_expect_areas(REGEN.rebuild(doc, kernel), made.feature, [PI * 20.0 * 10.0 * MM2], "Whole DXF ellipse ending at %s" % end)
	var round_doc = DOCUMENT.new()
	var whole_circle := DXF_IMPORT.to_sketch(_ellipse_dxf("6.283185", "1.0"), round_doc, SKETCH_DATA.ORIGIN_PLANES.xy, "xy")
	_expect(whole_circle.feature != null and whole_circle.curves == 1 and _count(whole_circle.feature, "circle") == 1, "A ratio-1 ELLIPSE ending at 6.283185 should be one circle (got %d)." % whole_circle.curves)
	if whole_circle.feature != null:
		_expect_areas(REGEN.rebuild(round_doc, kernel), whole_circle.feature, [PI * 400.0 * MM2], "Whole ratio-1 DXF ellipse")
	# Nothing drawable (a zero-length line) makes no empty sketch and says so.
	var nothing := []
	_pair(nothing, 0, "LINE"); _pair(nothing, 8, "0"); _pair(nothing, 10, "5.0"); _pair(nothing, 20, "5.0"); _pair(nothing, 11, "5.0"); _pair(nothing, 21, "5.0")
	var empty := DXF_IMPORT.to_sketch(_dxf(nothing), DOCUMENT.new(), SKETCH_DATA.ORIGIN_PLANES.xy, "xy")
	_expect(empty.feature == null and (empty.warnings as Array).any(func(w: String) -> bool: return w.contains("nothing to import")),
		"A DXF of one zero-length line should make no sketch and say there is nothing to import (%s)." % [empty.warnings])

	# Far from the drawing's origin: a 2-arc + 2-line slot (600 + 100 pi mm2) at +6 m and +15 m,
	# and a bulged LWPOLYLINE slot at +20 m, still close into one exact profile, where they were.
	var slot_area := (600.0 + 100.0 * PI) * MM2
	for off in [6000.0, 15000.0]:
		var e := []
		_pair(e, 0, "ARC"); _pair(e, 8, "S"); _pair(e, 10, "%.6f" % (130 + off)); _pair(e, 20, "%.6f" % (10 + off)); _pair(e, 40, "10.0"); _pair(e, 50, "270.0"); _pair(e, 51, "90.0")
		_pair(e, 0, "LINE"); _pair(e, 8, "S"); _pair(e, 10, "%.6f" % (130 + off)); _pair(e, 20, "%.6f" % (20 + off)); _pair(e, 11, "%.6f" % (100 + off)); _pair(e, 21, "%.6f" % (20 + off))
		_pair(e, 0, "ARC"); _pair(e, 8, "S"); _pair(e, 10, "%.6f" % (100 + off)); _pair(e, 20, "%.6f" % (10 + off)); _pair(e, 40, "10.0"); _pair(e, 50, "90.0"); _pair(e, 51, "270.0")
		_pair(e, 0, "LINE"); _pair(e, 8, "S"); _pair(e, 10, "%.6f" % (100 + off)); _pair(e, 20, "%.6f" % off); _pair(e, 11, "%.6f" % (130 + off)); _pair(e, 21, "%.6f" % off)
		var doc = DOCUMENT.new()
		var made := DXF_IMPORT.to_sketch(_dxf(e), doc, SKETCH_DATA.ORIGIN_PLANES.xy, "xy")
		_expect(made.feature != null and made.curves == 4, "The far slot at +%s mm should give 4 curves (got %d)." % [off, made.curves])
		if made.feature == null:
			continue
		_expect((made.warnings as Array).any(func(w: String) -> bool: return w.contains("origin was moved")), "Moving a far drawing to the sketch origin should be noted (%s)." % [made.warnings])
		var result := REGEN.rebuild(doc, kernel)
		_expect_areas(result, made.feature, [slot_area], "DXF slot at +%s mm" % off)
		var regions: Array = result.sketches.get(made.feature.id, {}).get("regions", [])
		if regions.size() == 1:
			var middle := (regions[0].face.bbox() as AABB).get_center()
			var expected := Vector3(0.115 + off * 0.001, 0.01 + off * 0.001, 0.0)
			_expect(middle.distance_to(expected) < 1e-5, "The far slot's profile should stay where the drawing puts it (%s, expected %s)." % [middle, expected])
	var lw_doc = DOCUMENT.new()
	var lw_off := Vector2(20000.0, 20000.0)
	var lw := DXF_IMPORT.to_sketch(_dxf(_lwpolyline([lw_off, lw_off + Vector2(30, 0), lw_off + Vector2(30, 20), lw_off + Vector2(0, 20)], [0.0, 1.0, 0.0, 1.0])),
		lw_doc, SKETCH_DATA.ORIGIN_PLANES.xy, "xy")
	_expect(lw.feature != null, "The far LWPOLYLINE slot should make a sketch (%s)." % [lw.warnings])
	if lw.feature != null:
		_expect_areas(REGEN.rebuild(lw_doc, kernel), lw.feature, [slot_area], "Bulged LWPOLYLINE slot at +20 m")
	# A big drawing that starts at its origin (a 1.2 m panel) keeps the sketch origin where it is.
	var panel := DXF_IMPORT.to_sketch(_dxf(_lwpolyline([Vector2(0, 0), Vector2(1200, 0), Vector2(1200, 1200), Vector2(0, 1200)])), DOCUMENT.new(), SKETCH_DATA.ORIGIN_PLANES.xy, "xy")
	_expect(panel.feature != null and (panel.feature.options.plane.origin as Vector3) == Vector3.ZERO and not (panel.warnings as Array).any(func(w: String) -> bool: return w.contains("origin was moved")),
		"A 1.2 m panel drawn from its origin should keep the sketch origin (%s)." % [panel.warnings])

	# MINSERT: a 1 mm square block arrayed 3 columns x 2 rows, 5 mm apart: 6 squares.
	var block := []
	_pair(block, 0, "BLOCK"); _pair(block, 8, "0"); _pair(block, 2, "SQ"); _pair(block, 10, "0.0"); _pair(block, 20, "0.0")
	block.append_array(_lwpolyline([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]))
	_pair(block, 0, "ENDBLK")
	var array := []
	_pair(array, 0, "INSERT"); _pair(array, 8, "0"); _pair(array, 2, "SQ"); _pair(array, 10, "0.0"); _pair(array, 20, "0.0")
	_pair(array, 70, 3); _pair(array, 71, 2); _pair(array, 44, "5.0"); _pair(array, 45, "5.0")
	var array_doc = DOCUMENT.new()
	var arrayed := DXF_IMPORT.to_sketch(_dxf(array, 4, block), array_doc, SKETCH_DATA.ORIGIN_PLANES.xy, "xy")
	_expect(arrayed.feature != null and arrayed.curves == 24, "A 3 x 2 MINSERT of a square should give 24 curves (got %d)." % arrayed.curves)
	if arrayed.feature != null:
		_expect_areas(REGEN.rebuild(array_doc, kernel), arrayed.feature, [MM2, MM2, MM2, MM2, MM2, MM2], "DXF MINSERT array")

	# $INSUNITS 15 (decameters) and 21 (US survey feet); an unknown code is read as mm with a note.
	var unit_square := _lwpolyline([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)])
	var deca_doc = DOCUMENT.new()
	var deca := DXF_IMPORT.to_sketch(_dxf(unit_square, 15), deca_doc, SKETCH_DATA.ORIGIN_PLANES.xy, "xy")
	_expect(deca.feature != null, "The decameter DXF should make a sketch (%s)." % [deca.warnings])
	if deca.feature != null:
		_expect_areas(REGEN.rebuild(deca_doc, kernel), deca.feature, [100.0], "DXF in decameters ($INSUNITS 15)")
	var survey_doc = DOCUMENT.new()
	var survey := DXF_IMPORT.to_sketch(_dxf(_lwpolyline([Vector2(0, 0), Vector2(2, 0), Vector2(2, 2), Vector2(0, 2)]), 21), survey_doc, SKETCH_DATA.ORIGIN_PLANES.xy, "xy")
	_expect(survey.feature != null, "The survey-feet DXF should make a sketch (%s)." % [survey.warnings])
	if survey.feature != null:
		_expect_areas(REGEN.rebuild(survey_doc, kernel), survey.feature, [pow(2.0 * 1200.0 / 3937.0, 2.0)], "DXF in US survey feet ($INSUNITS 21)")
	var odd := DXF_IMPORT.to_sketch(_dxf(unit_square, 99), DOCUMENT.new(), SKETCH_DATA.ORIGIN_PLANES.xy, "xy")
	_expect((odd.warnings as Array).any(func(w: String) -> bool: return w.contains("isn't known")), "An unknown $INSUNITS code should be reported (%s)." % [odd.warnings])


## Bounds (mm) of a sketch's points besides its origin, and its profile areas (mm2).
func _svg_layout(svg: String) -> Dictionary:
	var doc = DOCUMENT.new()
	var made := SVG_IMPORT.to_sketch(svg, doc, SKETCH_DATA.ORIGIN_PLANES.xy, "xy")
	if made.feature == null:
		return {"lo": Vector2.ZERO, "hi": Vector2.ZERO, "areas": []}
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for e in made.feature.options.entities:
		if e.type == "point" and not e.get("origin", false):
			lo = Vector2(minf(lo.x, e.x), minf(lo.y, e.y))
			hi = Vector2(maxf(hi.x, e.x), maxf(hi.y, e.y))
	var areas := _areas(REGEN.rebuild(doc, kernel), made.feature).map(func(a: float) -> float: return a / MM2)
	return {"lo": lo * 1000.0, "hi": hi * 1000.0, "areas": areas}


func _check_svg_aspect() -> void:
	var square := "<rect width=\"100\" height=\"100\"/>"
	var none := _svg_layout("<svg width=\"200mm\" height=\"100mm\" viewBox=\"0 0 100 100\" preserveAspectRatio=\"none\">%s</svg>" % square)
	_expect((none.areas as Array).size() == 1 and _close(none.areas[0], 20000.0, 1e-5) and none.lo.distance_to(Vector2.ZERO) < 1e-3 and none.hi.distance_to(Vector2(200, 100)) < 1e-3,
		"preserveAspectRatio none should stretch the viewBox over the 200 x 100 mm page (got %s..%s, %s)." % [none.lo, none.hi, none.areas])
	var meet := _svg_layout("<svg width=\"200mm\" height=\"100mm\" viewBox=\"0 0 100 100\">%s</svg>" % square)
	_expect((meet.areas as Array).size() == 1 and _close(meet.areas[0], 10000.0, 1e-5) and meet.lo.distance_to(Vector2(50, 0)) < 1e-3 and meet.hi.distance_to(Vector2(150, 100)) < 1e-3,
		"The default xMidYMid meet should center the square on the wide page, x 50..150 mm (got %s..%s)." % [meet.lo, meet.hi])
	var tall := _svg_layout("<svg width=\"100mm\" height=\"200mm\" viewBox=\"0 0 100 100\"><rect width=\"10\" height=\"10\"/></svg>")
	_expect(tall.lo.distance_to(Vector2(0, 140)) < 1e-3 and tall.hi.distance_to(Vector2(10, 150)) < 1e-3,
		"On a tall page the viewBox should be centered and flipped about the page's own height: the top-left 10 mm square at y 140..150 mm (got %s..%s)." % [tall.lo, tall.hi])
	var left := _svg_layout("<svg width=\"200mm\" height=\"100mm\" viewBox=\"0 0 100 100\" preserveAspectRatio=\"xMinYMin meet\">%s</svg>" % square)
	_expect(left.lo.distance_to(Vector2.ZERO) < 1e-3 and left.hi.distance_to(Vector2(100, 100)) < 1e-3, "xMinYMin should keep the square at x 0..100 mm (got %s..%s)." % [left.lo, left.hi])
	var slice := _svg_layout("<svg width=\"200mm\" height=\"100mm\" viewBox=\"0 0 100 100\" preserveAspectRatio=\"xMidYMid slice\">%s</svg>" % square)
	_expect((slice.areas as Array).size() == 1 and _close(slice.areas[0], 40000.0, 1e-5) and slice.lo.distance_to(Vector2(0, -50)) < 1e-3 and slice.hi.distance_to(Vector2(200, 150)) < 1e-3,
		"slice should scale the viewBox to cover the page (200 x 200 mm about its middle; got %s..%s, %s)." % [slice.lo, slice.hi, slice.areas])


func _check_stl_padding() -> void:
	var box: RefCounted = kernel.make_box(Vector3(0.03, 0.02, 0.01), Vector3.ZERO, "pad")
	var path := OUT + "pad_source.stl"
	kernel.export_file([box], path)
	var exact := FileAccess.get_file_as_bytes(path)
	_expect(exact.size() == 84 + 12 * 50, "The kernel's binary STL box should be 684 bytes (got %d)." % exact.size())
	var padded := exact.duplicate()
	padded.append_array(PackedByteArray([0, 0]))
	var zero_count := exact.duplicate()
	zero_count.encode_u32(80, 0)
	var over_count := exact.duplicate()
	over_count.encode_u32(80, 13)
	for case in [[padded, "2 bytes of padding"], [zero_count, "a count of 0"], [over_count, "a count of 13"]]:
		var read := MESH_IMPORT.read_stl(case[0], "mm")
		_expect(read.error == "" and read.triangles == 12 and _outward(read), "A binary STL with %s should still read as its 12 triangles (got %d; %s)." % [case[1], read.triangles, read.error])
	var padded_path := OUT + "padded.stl"
	var file := FileAccess.open(padded_path, FileAccess.WRITE)
	file.store_buffer(padded)
	file.close()
	var added := INSERT.add_mesh_import(DOCUMENT.new(), padded_path, "mm")
	_expect(added.feature != null, "Insert Mesh should take a padded binary STL (%s)." % added.error)
	var text := ("solid nothing here\n" + "just words, ".repeat(20)).to_ascii_buffer()
	_expect(str(MESH_IMPORT.read_stl(text, "mm").error) != "", "Text without triangles should still be refused, not read as binary.")


func _check_linked_revision() -> void:
	# A linked import of a 40 x 20 x 30 mm box, its top face offset 5 mm. The file is then revised
	# with a 6 mm bore through the top: the offset must stay on the top face.
	var path := OUT + "linked_revision.brep"
	kernel.export_file([kernel.make_box(Vector3(0.04, 0.02, 0.03), Vector3.ZERO, "v1")], path)
	var doc = DOCUMENT.new()
	var added := INSERT.add_import(doc, kernel, path, true)
	if added.feature == null:
		_expect(false, "The linked BREP should import (%s)." % added.error)
		return
	var body := str(added.feature.options.body_id)
	var first := REGEN.rebuild(doc, kernel)
	var top := REFERENCES.from_pick({"kind": "face", "body": body, "index": _face_toward(first.bodies[body].shape, Vector3.UP)}, first)
	var offset: Resource = doc.add_feature("offset_face", "OffsetFace", {"distance": doc.make_input("5 mm", "length")}, {"faces": [top]})
	var before := REGEN.rebuild(doc, kernel)
	_expect(_same_box(_bounds(before, body), AABB(Vector3.ZERO, Vector3(0.04, 0.025, 0.03))), "Offsetting the import's top should raise it 5 mm (%s)." % _bounds(before, body))
	var bored: RefCounted = kernel.boolean(kernel.make_box(Vector3(0.04, 0.02, 0.03), Vector3.ZERO, "v2"),
		kernel.make_cylinder(0.003, 0.022, Vector3(0.01, -0.001, 0.015), Vector3.UP, "v2"), 1, "v2")
	kernel.export_file([bored], path)
	var after := REGEN.rebuild(doc, kernel)
	_no_errors(after, "Linked import revised")
	_expect(_same_box(_bounds(after, body), AABB(Vector3.ZERO, Vector3(0.04, 0.025, 0.03))) and not (after.warnings as Dictionary).has(offset.id),
		"After the file gains a bore the offset should still raise the top face (%s, warnings %s)." % [_bounds(after, body), after.warnings])
	var revised: RefCounted = after.bodies[body].shape if after.bodies.has(body) else null
	if revised != null:
		var names := {}
		for name in revised.get_face_names():
			names[name] = true
		_expect(names.size() == revised.face_count(), "The revised file's faces should all have their own names (%s)." % [revised.get_face_names()])

	# Change Source on an unlinked import: the new file's top face keeps the old top's name.
	var plain := OUT + "source_plain.brep"
	var holed := OUT + "source_bored.step"
	kernel.export_file([kernel.make_box(Vector3(0.04, 0.02, 0.03), Vector3.ZERO, "p")], plain)
	kernel.export_file([bored], holed)
	var doc2 = DOCUMENT.new()
	var second := INSERT.add_import(doc2, kernel, plain)
	if second.feature == null:
		_expect(false, "The plain BREP should import (%s)." % second.error)
		return
	var body2 := str(second.feature.options.body_id)
	var built := REGEN.rebuild(doc2, kernel)
	var top2 := REFERENCES.from_pick({"kind": "face", "body": body2, "index": _face_toward(built.bodies[body2].shape, Vector3.UP)}, built)
	doc2.add_feature("offset_face", "OffsetFace", {"distance": doc2.make_input("5 mm", "length")}, {"faces": [top2]})
	var changed := INSERT.change_source(doc2, second.feature, holed, kernel)
	_expect(str(changed.error) == "", "Change Source to the bored STEP should work (%s)." % changed.error)
	var swapped := REGEN.rebuild(doc2, kernel)
	_no_errors(swapped, "Import with a changed source")
	_expect(_same_box(_bounds(swapped, body2), AABB(Vector3.ZERO, Vector3(0.04, 0.025, 0.03))), "After Change Source the offset should still raise the top face (%s)." % _bounds(swapped, body2))


func _center_of(result: Dictionary, body_id: String) -> Vector3:
	return _bounds(result, body_id).get_center()


func _check_fastener_in_plane() -> void:
	# An M6 washer at the middle of a 20 x 10 x 20 mm box's top face; the box then slides in x.
	var doc := _box_doc(Vector3(20, 10, 20))
	var box_feature: Resource = doc.features[0]
	var box_body := str(box_feature.options.body_id)
	var first := REGEN.rebuild(doc, kernel)
	var top := REFERENCES.from_pick({"kind": "face", "body": box_body, "index": _face_toward(first.bodies[box_body].shape, Vector3.UP)}, first)
	var washer := INSERT.add_fastener(doc, "washer", "M6", Vector3(0.0, 0.01, 0.0), Vector3.UP, "", top)
	if washer.feature == null:
		_expect(false, "The washer should insert.")
		return
	var w_id := str(washer.feature.options.body_id)
	for dx in [0.005, 0.05]:
		box_feature.options["position"] = Vector3(dx, 0.0, 0.0)
		var moved := REGEN.rebuild(doc, kernel)
		var c := _center_of(moved, w_id)
		_expect(absf(c.x - dx) < 1e-5 and absf(c.z) < 1e-5 and _close(_bounds(moved, w_id).position.y, 0.01, 1e-5) and not (moved.warnings as Dictionary).has(washer.feature.id),
			"A box moved %s m in x should carry its washer to the moved top's middle (got %s, warnings %s)." % [dx, c, moved.warnings])
	# The edit panel writes the followed spot back as the position (the reference's sig stays as
	# picked): that spot is taken as it is, not carried by the move a second time.
	var ctx := {"kernel": kernel, "doc": doc, "values": PARAMETERS.evaluate(doc), "bodies": REGEN.rebuild(doc, kernel).bodies, "sketches": {}, "construction": {}}
	var followed := INSERT.fastener_placement(washer.feature, ctx)
	washer.feature.options["position"] = followed.position
	var written := REGEN.rebuild(doc, kernel)
	_expect(absf(_center_of(written, w_id).x - 0.05) < 1e-5 and not (written.warnings as Dictionary).has(washer.feature.id),
		"A followed position written back should keep the washer where it is (got %s, warnings %s)." % [_center_of(written, w_id), written.warnings])
	# Shrunk under it: the old spot (x = 8 mm) is off the 10 mm top, so the washer sits on the
	# face's edge, with a warning.
	var off_doc := _box_doc(Vector3(20, 10, 20))
	var off_box: Resource = off_doc.features[0]
	var off_body := str(off_box.options.body_id)
	var off_first := REGEN.rebuild(off_doc, kernel)
	var off_top := REFERENCES.from_pick({"kind": "face", "body": off_body, "index": _face_toward(off_first.bodies[off_body].shape, Vector3.UP)}, off_first)
	var edge := INSERT.add_fastener(off_doc, "washer", "M6", Vector3(0.008, 0.01, 0.0), Vector3.UP, "", off_top)
	off_box.set_expression("length", "10 mm")
	var shrunk := REGEN.rebuild(off_doc, kernel)
	var e_id := str(edge.feature.options.body_id)
	_expect(str((shrunk.warnings as Dictionary).get(edge.feature.id, "")).contains("off the face") and absf(_center_of(shrunk, e_id).x - 0.005) < 1e-5,
		"A washer whose spot is off its shrunk face should sit on the face's edge with a warning (%s, %s)." % [_center_of(shrunk, e_id), shrunk.warnings])

	# A nut on a 30 mm cylinder's top, off its middle; the cylinder slides 4 mm, then 60 mm in z.
	var cyl_doc = DOCUMENT.new()
	var cyl: Resource = cyl_doc.add_feature("cylinder", "Cylinder", {"diameter": cyl_doc.make_input("30 mm", "length"), "height": cyl_doc.make_input("10 mm", "length")},
		{"position": Vector3.ZERO, "operation": OPERATIONS.NEW_BODY})
	cyl.options["body_id"] = cyl_doc.new_body(cyl.id)
	var cyl_body := str(cyl.options.body_id)
	var cyl_first := REGEN.rebuild(cyl_doc, kernel)
	var cyl_top := REFERENCES.from_pick({"kind": "face", "body": cyl_body, "index": _face_toward(cyl_first.bodies[cyl_body].shape, Vector3.UP)}, cyl_first)
	var nut := INSERT.add_fastener(cyl_doc, "hex_nut", "M6", Vector3(0.005, 0.01, 0.002), Vector3.UP, "", cyl_top)
	var n_id := str(nut.feature.options.body_id)
	var start := _center_of(REGEN.rebuild(cyl_doc, kernel), n_id)
	for dz in [0.004, 0.06]:
		cyl.options["position"] = Vector3(0.0, 0.0, dz)
		var slid := REGEN.rebuild(cyl_doc, kernel)
		var c := _center_of(slid, n_id)
		_expect(absf(c.x - start.x) < 1e-5 and absf(c.z - (start.z + dz)) < 1e-5 and not (slid.warnings as Dictionary).has(nut.feature.id),
			"A cylinder moved %s m in z should carry its nut along (%s -> %s, warnings %s)." % [dz, start, c, slid.warnings])


func _check_derive_cache_files() -> void:
	# A: the source design links a BREP; the file changes, the source isn't saved again.
	INSERT.clear_derive_cache()
	var brep := OUT + "derive_linked_part.brep"
	kernel.export_file([kernel.make_box(Vector3(0.01, 0.01, 0.01), Vector3.ZERO, "a")], brep)
	var source = DOCUMENT.new()
	INSERT.add_import(source, kernel, brep, true)
	var source_path := OUT + "derive_linked_source.tres"
	_expect(ResourceSaver.save(source, source_path) == OK, "The linked source should save.")
	var target = DOCUMENT.new()
	var derived := INSERT.add_derive(target, source_path, kernel)
	if derived.feature == null:
		_expect(false, "The linked source should derive (%s)." % derived.error)
		return
	var body := str(derived.feature.options.body_id)
	_expect(_close(_body_volume(REGEN.rebuild(target, kernel), body), 1e-6), "The derived linked cube should be 1 cm^3.")
	kernel.export_file([kernel.make_box(Vector3(0.02, 0.02, 0.02), Vector3.ZERO, "a")], brep)
	var followed := _body_volume(REGEN.rebuild(target, kernel), body)
	_expect(_close(followed, 8e-6), "A derive should follow its source's linked file when it changes (got %s)." % followed)

	# B: the source is saved twice within one second (file times have whole seconds).
	INSERT.clear_derive_cache()
	while fmod(Time.get_unix_time_from_system(), 1.0) > 0.3:
		OS.delay_msec(5)
	var path := OUT + "derive_same_second.tres"
	ResourceSaver.save(_box_doc(Vector3(10, 10, 10)), path)
	var stamp := FileAccess.get_modified_time(path)
	var t2 = DOCUMENT.new()
	var d2 := INSERT.add_derive(t2, path, kernel)
	if d2.feature == null:
		_expect(false, "The same-second source should derive (%s)." % d2.error)
		return
	var b2 := str(d2.feature.options.body_id)
	_expect(_close(_body_volume(REGEN.rebuild(t2, kernel), b2), 1e-6), "The derived 10 mm box should be 1 cm^3.")
	ResourceSaver.save(_box_doc(Vector3(20, 20, 20)), path)
	var same_second := FileAccess.get_modified_time(path) == stamp
	var resaved := _body_volume(REGEN.rebuild(t2, kernel), b2)
	_expect(_close(resaved, 8e-6), "A source saved again within the same second (%s) should still update the derive (got %s)." % [same_second, resaved])


func _check_derive_names() -> void:
	# This design's own box (feature f1) at x = 30 mm and a derived box (also f1 in its source) at
	# the origin, joined; the local top is offset 5 mm, then the local box moves to x = -30 mm.
	INSERT.clear_derive_cache()
	var source := _box_doc(Vector3(10, 10, 10))
	var source_path := OUT + "derive_names_source.tres"
	ResourceSaver.save(source, source_path)
	var doc = DOCUMENT.new()
	var inputs := {"length": doc.make_input("10 mm", "length"), "height": doc.make_input("10 mm", "length"), "width": doc.make_input("10 mm", "length")}
	var local: Resource = doc.add_feature("box", "Box", inputs, {"position": Vector3(0.03, 0, 0), "operation": OPERATIONS.NEW_BODY})
	local.options["body_id"] = doc.new_body(local.id)
	var local_body := str(local.options.body_id)
	var derived := INSERT.add_derive(doc, source_path, kernel)
	if derived.feature == null:
		_expect(false, "The names source should derive (%s)." % derived.error)
		return
	var derived_body := str(derived.feature.options.body_id)
	var first := REGEN.rebuild(doc, kernel)
	var derived_names: PackedStringArray = first.bodies[derived_body].shape.get_face_names()
	var prefix := str(derived.feature.id) + ":"
	_expect(not derived_names.is_empty() and Array(derived_names).all(func(n: String) -> bool: return n.begins_with(prefix)),
		"Derived faces should be named under the derive feature %s (got %s)." % [derived.feature.id, derived_names])
	doc.add_feature("combine", "Combine", {}, {"target": [{"kind": "body", "body": local_body}], "tools": [{"kind": "body", "body": derived_body}], "operation": "join"})
	var joined := REGEN.rebuild(doc, kernel)
	var shape: RefCounted = joined.bodies[local_body].shape
	var pick := -1
	for i in shape.face_count():
		var info: Dictionary = shape.face_info(i)
		if info.get("planar", false) and (info.normal as Vector3).dot(Vector3.UP) > 0.999 and (info.point as Vector3).x > 0.02:
			pick = i
	var ref := REFERENCES.from_pick({"kind": "face", "body": local_body, "index": pick}, joined)
	doc.add_feature("offset_face", "OffsetFace", {"distance": doc.make_input("5 mm", "length")}, {"faces": [ref]})
	local.options["position"] = Vector3(-0.03, 0, 0)
	var after := REGEN.rebuild(doc, kernel)
	_no_errors(after, "Derived and local boxes joined")
	var local_top := -INF
	var derived_top := -INF
	var moved: RefCounted = after.bodies[local_body].shape if after.bodies.has(local_body) else null
	if moved != null:
		for i in moved.face_count():
			var info: Dictionary = moved.face_info(i)
			if info.get("planar", false) and (info.normal as Vector3).dot(Vector3.UP) > 0.999:
				if (info.point as Vector3).x < -0.01:
					local_top = maxf(local_top, (info.point as Vector3).y)
				else:
					derived_top = maxf(derived_top, (info.point as Vector3).y)
	_expect(_close(local_top, 0.015, 1e-5) and _close(derived_top, 0.01, 1e-5), "Moving the local box should keep the offset on its own top (local %s, derived %s)." % [local_top, derived_top])


## A closed UV sphere of 2 * (rings - 1) * segments triangles as binary STL bytes.
func _sphere_stl(rings: int, segments: int, radius: float) -> PackedByteArray:
	var points := []
	for i in rings + 1:
		var theta := PI * i / rings
		for j in segments:
			var phi := TAU * j / segments
			points.append(Vector3(sin(theta) * cos(phi), cos(theta), sin(theta) * sin(phi)) * radius)
	var triangles := []
	for i in rings:
		for j in segments:
			var a: int = i * segments + j
			var b: int = i * segments + (j + 1) % segments
			var c: int = (i + 1) * segments + j
			var d: int = (i + 1) * segments + (j + 1) % segments
			if i > 0:
				triangles.append([points[a], points[b], points[c]])
			if i < rings - 1:
				triangles.append([points[b], points[d], points[c]])
	var bytes := PackedByteArray()
	bytes.resize(84 + triangles.size() * 50)
	bytes.encode_u32(80, triangles.size())
	for t in triangles.size():
		for k in 3:
			var p: Vector3 = triangles[t][k]
			bytes.encode_float(84 + t * 50 + 12 + k * 12, p.x)
			bytes.encode_float(84 + t * 50 + 16 + k * 12, p.y)
			bytes.encode_float(84 + t * 50 + 20 + k * 12, p.z)
	return bytes


func _check_mesh_cache() -> void:
	# A ~5000-triangle sphere and a later box: editing only the box reuses the sphere's solid.
	var path := OUT + "cache_sphere.stl"
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_buffer(_sphere_stl(50, 50, 10.0))
	file.close()
	var doc = DOCUMENT.new()
	var added := INSERT.add_mesh_import(doc, path, "mm")
	if added.feature == null:
		_expect(false, "The sphere STL should insert (%s)." % added.error)
		return
	var mesh_body := str(added.feature.options.body_id)
	var inputs := {"length": doc.make_input("5 mm", "length"), "height": doc.make_input("5 mm", "length"), "width": doc.make_input("5 mm", "length")}
	var box: Resource = doc.add_feature("box", "Box", inputs, {"position": Vector3(0.05, 0, 0), "operation": OPERATIONS.NEW_BODY})
	box.options["body_id"] = doc.new_body(box.id)
	var first := REGEN.rebuild(doc, kernel)
	_no_errors(first, "Sphere mesh and box")
	_expect(first.bodies.has(mesh_body) and str(first.bodies[mesh_body].shape.shape_type()) == "SOLID", "The sphere mesh should be a closed solid.")
	box.set_expression("length", "7 mm")
	var second := REGEN.rebuild(doc, kernel)
	_expect(second.bodies.has(mesh_body) and second.bodies[mesh_body].shape == first.bodies[mesh_body].shape, "Editing a later feature should reuse the mesh body's solid.")
	# Fifty rebuilds after editing the box (the sphere's solid reused) against one with the kept
	# solids forgotten, in turns: about a fiftieth (a limit in milliseconds failed whenever the
	# machine was busy; making the solid again each time is fifty times).
	var lengths := ["6 mm", "7 mm"]
	var edited := func() -> void:
		for k in 50:
			lengths.reverse()
			box.set_expression("length", lengths[0])
			REGEN.rebuild(doc, kernel)
	var cold := func() -> void:
		INSERT.clear_mesh_cache()
		REGEN.rebuild(doc, kernel)
	var timing := TIMING.compare(edited, cold, 3, "50 rebuilds reusing the mesh solid / 1 making it again")
	_expect(timing.ratio < 0.05, "50 rebuilds that reuse the mesh solid should take under a twentieth of one that makes it again (%.1f ms against %.1f ms)." % [timing.op, timing.calibration])
	box.set_expression("length", "7 mm")
	REGEN.rebuild(doc, kernel)
	var volume: float = first.bodies[mesh_body].shape.volume()
	added.feature.options["units"] = "cm"
	var bigger := REGEN.rebuild(doc, kernel)
	_expect(bigger.bodies[mesh_body].shape != first.bodies[mesh_body].shape and _close(_body_volume(bigger, mesh_body), volume * 1000.0, 1e-5), "Changing the mesh's units should make it again, 1000 times the volume.")

	# Linked: an unchanged file reuses the solid; a rewritten one (even within the same second)
	# is read again.
	var linked_path := OUT + "cache_linked.stl"
	kernel.export_file([kernel.make_box(Vector3(0.01, 0.01, 0.01), Vector3.ZERO, "l")], linked_path)
	var linked_doc = DOCUMENT.new()
	var linked := INSERT.add_mesh_import(linked_doc, linked_path, "mm", true)
	if linked.feature == null:
		_expect(false, "The linked STL should insert (%s)." % linked.error)
		return
	var l_body := str(linked.feature.options.body_id)
	var l1 := REGEN.rebuild(linked_doc, kernel)
	var l2 := REGEN.rebuild(linked_doc, kernel)
	_expect(l2.bodies.has(l_body) and l2.bodies[l_body].shape == l1.bodies[l_body].shape, "An unchanged linked mesh file should reuse its solid.")
	kernel.export_file([kernel.make_box(Vector3(0.02, 0.01, 0.01), Vector3.ZERO, "l")], linked_path)
	_expect(_close(_body_volume(REGEN.rebuild(linked_doc, kernel), l_body), 2e-6), "A rewritten linked mesh file should be read again.")


# --- Large sketches and edited mesh units ----------------------------------------------------

## SketchData looks entities and constraints up through an index (checked on each use), so a
## 4000-curve DXF rebuilds in linear time; lookups stay right after adds, removals and a replaced
## entity array.
func _check_sketch_lookups() -> void:
	var lines := []
	var made_lines := 0
	for row in 64:
		for col in 63:
			if made_lines == 4000:
				break
			_pair(lines, 0, "LINE"); _pair(lines, 8, "0")
			_pair(lines, 10, "%d.0" % (col * 2)); _pair(lines, 20, "%d.0" % (row * 2)); _pair(lines, 30, "0.0")
			_pair(lines, 11, "%d.0" % (col * 2 + 1)); _pair(lines, 21, "%d.0" % (row * 2)); _pair(lines, 31, "0.0")
			made_lines += 1
	var doc = DOCUMENT.new()
	var made := DXF_IMPORT.to_sketch(_dxf(lines), doc, SKETCH_DATA.ORIGIN_PLANES.xy, "xy")
	_expect(made.feature != null and int(made.curves) == 4000, "4000 separate DXF lines should import as 4000 curves (got %s; %s)." % [made.get("curves"), made.get("warnings")])
	if made.feature != null:
		var result := REGEN.rebuild(doc, kernel)
		var solved: Dictionary = result.sketches.get(made.feature.id, {}).get("solve", {})
		_expect(int(solved.get("dof", -1)) == 0, "A 4000-line sketch should rebuild fully fixed (dof %s)." % solved.get("dof"))
		# Against a 1000-line sketch, in turns: about seven times as long (quadratic lookups made it
		# sixteen; a limit in milliseconds failed whenever the machine was busy).
		var small_doc = DOCUMENT.new()
		DXF_IMPORT.to_sketch(_dxf(lines.slice(0, lines.size() / 4)), small_doc, SKETCH_DATA.ORIGIN_PLANES.xy, "xy")
		var timing := TIMING.compare(func() -> void: REGEN.rebuild(doc, kernel), func() -> void: REGEN.rebuild(small_doc, kernel), 3, "rebuild a 4000-line sketch / a 1000-line one")
		_expect(timing.ratio < 12.0, "A 4000-line sketch should rebuild in under 12 times a 1000-line one's time (%.1f ms against %.1f ms)." % [timing.op, timing.calibration])
	var sketch_doc = DOCUMENT.new()
	var feature: Resource = sketch_doc.add_feature("sketch", "Sketch", {}, SKETCH_DATA.new_options(SKETCH_DATA.ORIGIN_PLANES.xy, "xy"))
	var sketch = SKETCH_DATA.new(feature, sketch_doc)
	var a: int = sketch.add_point(Vector2(0, 0))
	var b: int = sketch.add_point(Vector2(0.01, 0))
	var line: int = sketch.add_line(a, b)
	_expect(str(sketch.entity(line).get("type", "")) == "line" and int(sketch.entity(b).id) == b, "Lookups should find a new line and its point.")
	var c: int = sketch.add_point(Vector2(0, 0.01))
	var other: int = sketch.add_line(a, c)
	_expect(int(sketch.entity(other).get("p2", -1)) == c, "A line added after the index was built should be found.")
	sketch.remove_entities([line])
	_expect(sketch.entity(line).is_empty() and sketch.entity(b).is_empty() and int(sketch.entity(other).id) == other, "A removed line (and its unused point) should be gone; the rest stays.")
	sketch.options.entities = sketch.options.entities.filter(func(e: Dictionary) -> bool: return int(e.id) != other)
	_expect(sketch.entity(other).is_empty() and int(sketch.entity(a).id) == a and int(sketch.entity(c).id) == c, "A replaced entity array should be looked up afresh.")


## Insert Mesh edit: units that only came from the old file (a glTF's meters) follow the new file
## (an STL's millimeters), as a fresh insert would; units the user chose stay.
func _check_mesh_units_follow_file() -> void:
	var gltf := OUT + "units_cube.gltf"
	_write_gltf_cube(gltf)
	var doc = DOCUMENT.new()
	var added := INSERT.add_mesh_import(doc, gltf, "")
	if added.feature == null:
		_expect(false, "The glTF cube should insert (%s)." % added.error)
		return
	var feature: Resource = added.feature
	var body_id := str(feature.options.body_id)
	_expect(str(feature.options.units) == "m", "A glTF comes in meters (%s)." % feature.options.units)
	var edit := _editor_for(feature)
	var values: Dictionary = edit.read_values()
	values.path = FIXTURES + "cube_10mm.stl"
	edit.write_values(doc, values)
	_expect(str(feature.options.units) == "mm" and str(values.units) == "mm", "Switching from the glTF to an STL should take the STL's millimeters (%s, %s)." % [feature.options.units, values.units])
	_expect(_close(_body_volume(REGEN.rebuild(doc, kernel), body_id), 1e-6), "The STL cube should then be 1 cm^3, as a fresh insert.")
	# Control: an STL the user read in cm keeps cm on another unit-less file.
	var chosen_doc = DOCUMENT.new()
	var chosen := INSERT.add_mesh_import(chosen_doc, FIXTURES + "cube_10mm.stl", "cm")
	if chosen.feature == null:
		_expect(false, "The STL cube should insert in cm (%s)." % chosen.error)
		return
	var chosen_edit := _editor_for(chosen.feature)
	var chosen_values: Dictionary = chosen_edit.read_values()
	chosen_values.path = FIXTURES + "cube_2cm.obj"
	chosen_edit.write_values(chosen_doc, chosen_values)
	_expect(str(chosen.feature.options.units) == "cm", "Units the user chose should stay on another file (%s)." % chosen.feature.options.units)
