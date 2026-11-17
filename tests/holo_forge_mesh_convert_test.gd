extends SceneTree
## Holo Forge Convert Mesh (Phase 7 work order, 5.4, stage C): mesh bodies turned into B-rep
## bodies through the features and the rebuild, and the kernel calls behind them.
##
## Faceted (the L-bracket's flat face groups merged into one face each, the hole's triangles kept
## as faces; an icosahedron; a hollow cube with an island; the triangle cap refused before any
## work; an open plate as a surface body with a warning), Prismatic (the L-bracket as 8 planes
## and 1 cylinder with its hole's radius and the original body's volume; one group, a group that
## fits nothing, crossing holes refused by their time estimate before any kernel call; tangent
## rounds, a hollow body, coplanar groups on one surface; a body the fits do not describe is
## refused, never handed over), Organic (a ball as one smooth solid within its deviation; the
## Form Body output as a Form feature holding the cage), then what every convert keeps to: the
## new body and the mesh body (New Body hides it, Replace takes it out), kept results, refusals
## with the body's name, the time bound, and timing ratios.
## (HOLO_FORGE_TIMING_SLOWDOWN=3 fails all four timing checks: checked on 2026-11-12.)
##
## godot --headless --path . --script res://tests/holo_forge_mesh_convert_test.gd

const DOCUMENT := preload("res://addons/holo_forge/core/document.gd")
const REGEN := preload("res://addons/holo_forge/core/regen.gd")
const OPERATIONS := preload("res://addons/holo_forge/core/operations.gd")
const INSERT := preload("res://addons/holo_forge/core/features/insert.gd")
const MESH_FEATURE := preload("res://addons/holo_forge/core/features/mesh.gd")
const MESH_CONVERT := preload("res://addons/holo_forge/core/features/mesh_convert.gd")
const MESH_BODY := preload("res://addons/holo_forge/core/mesh/mesh_body.gd")
const MESH_BLOB := preload("res://addons/holo_forge/core/mesh/mesh_blob.gd")
const ORGANIC := preload("res://addons/holo_forge/core/mesh/organic.gd")
const CAGE := preload("res://addons/holo_forge/core/form/cage.gd")
const FIXTURES := preload("res://tests/holo_forge_mesh_fixtures.gd")
const TIMING := preload("res://tests/holo_forge_timing.gd")

const MM := 0.001
const MM3 := 1e-9
## Timing ratio limits (work order 5.7): 2 x the ratio measured on the dev machine (Ryzen 9
## 5900HX) on 2026-11-12 against a sphere make + tessellate calibration. Each op runs on a fresh
## CadMesh (set_arrays and every structure the op builds count), with all its checks.
const LIMITS := {
	"faceted_5120": 424.0,       # measured 705 to 979 ms against a calibration of 3.6 to 4.6 ms (other teams' tests were running), ratio 196 to 212
	"prismatic_bracket": 20.0,   # measured 37 to 41 ms, ratio 9.0 to 9.9: the L-bracket, 384 triangles, 9 surfaces
	"prismatic_crossing": 209.0,  # measured 377 to 384 ms, ratio 98 to 104: 3,636 triangles, 10 surfaces, 4 crossing pairs
	"organic_200": 370.0,        # measured 678 to 700 ms, ratio 182 to 185: a 20,480-triangle ball, a cage of about 200 faces
}

var failures: Array[String] = []
var checked: Array[String] = []
var notes: Array[String] = []
var kernel: RefCounted
var _started := false
var _finished := false


func _init() -> void:
	call_deferred("run")


## A script error stops run() in the middle: the test then fails here and does not hang.
func _process(_delta: float) -> bool:
	if _started and not _finished:
		print("FAIL holo_forge_mesh_convert: the test stopped on a script error.")
		_finished = true
		quit(1)
	return false


func run() -> void:
	_started = true
	kernel = REGEN.make_kernel()
	if kernel == null or not ClassDB.class_exists("CadMesh") or not ClassDB.class_exists("CadSubD"):
		print("NOTE: CadMesh is not registered (the holo_forge native DLL is missing): the convert checks are skipped.")
		print("PASS holo_forge_mesh_convert: skipped, the native library is not loaded.")
		_finished = true
		quit(0)
		return
	var only := OS.get_environment("HOLO_FORGE_MESH_CONVERT_ONLY")
	for part in [["faceted", _check_faceted], ["faceted_cap", _check_faceted_cap], ["faceted_open", _check_faceted_open],
			["prismatic", _check_prismatic_bracket], ["prismatic_refusals", _check_prismatic_refusals], ["prismatic_more", _check_prismatic_more],
			["crossing", _check_prismatic_crossing], ["organic", _check_organic], ["form_body", _check_form_body], ["bodies", _check_bodies],
			["refusals", _check_refusals], ["bound", _check_time_bound], ["timing", _check_timing]]:
		if only == "" or only.split(",").has(str(part[0])):
			MESH_FEATURE.clear_cache()
			MESH_CONVERT.clear_cache()
			(part[1] as Callable).call()
	for note in notes:
		print("NOTE holo_forge_mesh_convert: " + note)
	if failures.is_empty():
		print("PASS holo_forge_mesh_convert: " + "; ".join(checked) + ".")
	else:
		print("FAIL holo_forge_mesh_convert")
		for failure in failures:
			print("  " + failure)
	_finished = true
	quit(0 if failures.is_empty() else 1)


# --- Helpers ---------------------------------------------------------------------------------

func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _new() -> RefCounted:
	return ClassDB.instantiate("CadMesh")


## A mesh body from a stored mesh (an Insert Mesh feature), as the tools test makes them.
func _add_mesh(doc: Resource, mesh: RefCounted, name := "") -> String:
	var feature: Resource = doc.add_feature("mesh_import", "Mesh", {}, {
		"path": "", "kind": INSERT.KIND_MESH, "units": "mm", "mesh_units": "mm", "linked": false, "split": false,
		"transform": Transform3D.IDENTITY, "operation": OPERATIONS.NEW_BODY, "mesh": MESH_BLOB.from_mesh(mesh),
	})
	var body_id: String = doc.new_body(feature.id)
	feature.options["body_id"] = body_id
	if name != "":
		doc.bodies[body_id]["name"] = name
	return body_id


func _len(meters: float) -> Array:
	return ["%s mm" % String.num(meters * 1000.0, 9), "length"]


func _num(value: float) -> Array:
	return [String.num(value, 9), "number"]


func _convert(doc: Resource, method: String, body_id: String, options := {}, inputs := {}) -> Resource:
	var made := MESH_CONVERT.add_convert(doc, method, [body_id], options, inputs)
	_expect(str(made.error) == "", "A Convert Mesh feature should be added (%s)." % made.error)
	return made.feature


func _rebuild(doc: Resource, limit := -1.0) -> Dictionary:
	return REGEN.rebuild(doc, kernel, {} if limit < 0.0 else {"mesh_time_limit": limit})


func _error(result: Dictionary, feature: Resource) -> String:
	return str(result.errors.get(feature.id, ""))


func _warning(result: Dictionary, feature: Resource) -> String:
	return str(result.warnings.get(feature.id, ""))


## The body a convert feature made (its only output), or null.
func _made(result: Dictionary, feature: Resource) -> RefCounted:
	var outputs: Array = feature.options.get("outputs", [])
	if outputs.size() != 1 or not result.bodies.has(outputs[0]):
		return null
	var entry: Dictionary = result.bodies[outputs[0]]
	_expect(not entry.has("kind") and not MESH_BODY.is_mesh(entry), "A converted body should be a B-rep body (no kind).")
	return entry.shape


## The kernel's report of a convert feature's only body.
func _report(feature: Resource) -> Dictionary:
	var bodies: Array = (MESH_FEATURE.reports.get(feature.id, {}) as Dictionary).get("bodies", [])
	return bodies[0] if bodies.size() == 1 else {}


func _face_kinds(shape: RefCounted) -> Dictionary:
	var kinds := {}
	for i in int(shape.face_count()):
		var kind := str((shape.face_info(i) as Dictionary).get("type", ""))
		kinds[kind] = int(kinds.get(kind, 0)) + 1
	return kinds


func _refused(error: String, what: String, fragments: Array) -> void:
	_expect(error != "", "%s should be refused." % what)
	for fragment in fragments:
		_expect(error.contains(str(fragment)), "%s should say '%s' ('%s')." % [what, fragment, error])


## The drawn triangles of a body, as the viewport makes them: {"triangles", "warnings"}.
func _drawn(shape: RefCounted) -> Dictionary:
	var linear := clampf(((shape.bbox() as AABB).size.length()) * 0.0015, 0.00001, 0.01)
	var tess: Dictionary = shape.tessellate(linear, 0.3)
	return {"triangles": (tess.get("indices", PackedInt32Array()) as PackedInt32Array).size() / 3, "warnings": Array(tess.get("warnings", []))}


func _fast_groups(fixture: Dictionary, options := {}) -> RefCounted:
	var mesh := FIXTURES.to_mesh(fixture)
	var grouped: RefCounted = mesh.generate_groups(options)
	_expect(grouped != null, "A fixture should take face groups (%s)." % mesh.get_last_error())
	return grouped


func _tessellated(shape: RefCounted, detail := 5000.0, degrees := 8.0) -> RefCounted:
	var mesh := _new()
	var diagonal: float = (shape.bbox() as AABB).size.length()
	_expect(mesh.from_shape(shape, diagonal / detail, deg_to_rad(degrees), false, 20.0), "A body should tessellate (%s)." % mesh.get_last_error())
	return mesh


# --- 5.4 #1: Faceted, Merge Flat ---------------------------------------------------------------

func _check_faceted() -> void:
	var bracket := FIXTURES.l_bracket()
	var mesh: RefCounted = bracket.mesh
	var doc: Resource = DOCUMENT.new()
	var body := _add_mesh(doc, mesh, "Bracket")
	var merged := _convert(doc, "convert_faceted", body)
	var result := _rebuild(doc)
	_expect(_error(result, merged) == "" and _warning(result, merged) == "", "Faceted of the bracket should build clean ('%s' / '%s')." % [_error(result, merged), _warning(result, merged)])
	var shape := _made(result, merged)
	if shape != null:
		# Each flat group one face, the hole's group a face per triangle.
		var flat := 0
		var others := 0
		var names: PackedStringArray = mesh.get_face_names()
		var flat_names := {}
		for g in int(mesh.face_count()):
			if str((mesh.face_info(g) as Dictionary).get("type", "")) == "plane":
				flat += 1
				flat_names[names[g]] = true
			else:
				others += (mesh.group_triangles(g) as PackedInt32Array).size()
		_expect(flat == 8, "The bracket should have 8 flat face groups (%d)." % flat)
		_expect(int(shape.face_count()) == flat + others, "Faceted with Merge Flat should give %d + %d faces (%d)." % [flat, others, int(shape.face_count())])
		_expect(int(shape.solid_count()) == 1 and not bool(shape.is_surface()), "Faceted of the bracket should be one solid.")
		var report := _report(merged)
		_expect(bool((report.get("output", {}) as Dictionary).get("valid", false)) and int(report.output.merged_faces) == 8, "The kernel should report a valid body with 8 merged faces (%s)." % [report.get("output", {})])
		var relative := absf(float(shape.volume()) - float(mesh.volume())) / float(mesh.volume())
		_expect(relative <= 1e-6, "Faceted should keep the mesh's volume (off by %s)." % str(relative))
		# The merged faces carry their groups' names; the hole's triangles <group>/t<k>.
		var face_names: PackedStringArray = shape.get_face_names()
		var found := 0
		var numbered := 0
		for name in face_names:
			found += 1 if flat_names.has(name) else 0
			numbered += 1 if str(name).contains("/t") else 0
		_expect(found == 8 and numbered == others, "Merged faces should be named after their groups and the others <group>/t<k> (%d, %d)." % [found, numbered])
		# What is drawn is the mesh that was converted.
		var drawn := _drawn(shape)
		_expect(int(drawn.triangles) == int(mesh.triangle_count()) and (drawn.warnings as Array).is_empty(), "The faceted body should draw the mesh's own %d triangles (%d, %s)." % [
			int(mesh.triangle_count()), int(drawn.triangles), drawn.warnings])
		var stat := str((MESH_FEATURE.reports.get(merged.id, {}) as Dictionary).get("stat", ""))
		_expect(stat.contains("Bracket") and stat.contains("8 merged"), "The stat line should tell what the body became ('%s')." % stat)
	# Merge Flat off: a face per triangle.
	var plain_doc: Resource = DOCUMENT.new()
	var plain_body := _add_mesh(plain_doc, mesh, "Bracket")
	var plain := _convert(plain_doc, "convert_faceted", plain_body, {"merge_flat": false})
	var plain_result := _rebuild(plain_doc)
	var plain_shape := _made(plain_result, plain)
	_expect(plain_shape != null and int(plain_shape.face_count()) == int(mesh.triangle_count()) and int(plain_shape.solid_count()) == 1,
		"Faceted without Merge Flat should give a face per triangle ('%s')." % _error(plain_result, plain))
	# A ball (no flat group), 5.3 #4's other body; and an icosahedron, whose 20 groups are flat.
	var ball := FIXTURES.to_mesh(FIXTURES.icosphere(0.05, 4))
	var ball_shape: RefCounted = ball.to_faceted({})
	_expect(ball_shape != null and int(ball_shape.face_count()) == 5120 and int(ball_shape.solid_count()) == 1, "Faceted of a ball should give 5,120 faces (%s)." % ball.get_last_error())
	if ball_shape != null:
		var off := absf(float(ball_shape.volume()) - float(ball.volume())) / float(ball.volume())
		_expect(off <= 1e-6, "Faceted of a ball should keep its volume (off by %s)." % str(off))
	# A hollow cube with an island: two solids, the void in the outer one.
	var hollow := FIXTURES.to_mesh(FIXTURES.hollow_cube(true))
	var hollow_shape: RefCounted = hollow.to_faceted({})
	_expect(hollow_shape != null and int(hollow_shape.solid_count()) == 2, "Faceted of a hollow cube with an island should give two solids (%s)." % hollow.get_last_error())
	if hollow_shape != null:
		_expect(absf(float(hollow_shape.volume()) - 7064.0 * MM3) <= 1e-3 * MM3, "The hollow cube's solids should hold 7,064 mm3 (%s)." % str(float(hollow_shape.volume()) / MM3))
	# A Flat Tolerance that lets slightly bent groups merge: the faces say how far their corners
	# lie off them, the volume moves by no more than that explains, and the drawn triangles
	# stay the mesh's own. At the default tolerance the same body keeps a face per triangle.
	var bent := FIXTURES.to_mesh(FIXTURES.with_noise(bracket, 0.0005))
	var diagonal: float = (bent.bbox() as AABB).size.length()
	var strict: RefCounted = bent.to_faceted({})
	_expect(strict != null and int(strict.face_count()) == int(bent.triangle_count()), "A slightly bent body should keep a face per triangle at the default Flat Tolerance (%s)." % bent.get_last_error())
	var loose: RefCounted = bent.to_faceted({"flat_tolerance": diagonal / 1000.0})
	_expect(loose != null and int(loose.face_count()) < int(bent.triangle_count()), "A Flat Tolerance of D / 1000 should merge the slightly bent groups (%s)." % bent.get_last_error())
	if loose != null:
		var bent_report: Dictionary = bent.get_last_report()
		var bent_off := float(bent_report.deviation.max)
		_expect(bent_off > 0.0 and bent_off <= diagonal / 1000.0 and absf(float(bent_report.volume_change)) <= 0.01, "The merged faces should say what they moved (%s, %s)." % [str(bent_off), str(bent_report.volume_change)])
		_expect(int(_drawn(loose).triangles) == int(bent.triangle_count()) and (_drawn(loose).warnings as Array).is_empty(), "A merged body should still draw the mesh's own triangles.")
	var wavy := FIXTURES.to_mesh(FIXTURES.with_noise(FIXTURES.open_plate(), 0.02))
	var sheet: RefCounted = wavy.to_faceted({"flat_tolerance": 0.0002})
	_expect(sheet != null and int(sheet.face_count()) == 1 and bool(sheet.is_surface()), "A wavy plate within the Flat Tolerance should become one face (%s)." % wavy.get_last_error())
	# A mesh that crosses itself converts as it is, and the feature says so.
	var crossing_doc: Resource = DOCUMENT.new()
	var crossing_body := _add_mesh(crossing_doc, FIXTURES.to_mesh(FIXTURES.self_crossing()), "Pair")
	var crossing := _convert(crossing_doc, "convert_faceted", crossing_body)
	var crossing_result := _rebuild(crossing_doc)
	_expect(_error(crossing_result, crossing) == "" and _warning(crossing_result, crossing).contains("Pair crosses itself, so the result may be wrong there."), "A body that crosses itself should convert with a warning ('%s' / '%s')." % [
		_error(crossing_result, crossing), _warning(crossing_result, crossing)])
	checked.append("#1 Faceted with Merge Flat (the bracket: 8 merged planes + the hole's triangles, one valid solid, volume to 1e-6, names, drawn as the mesh's own triangles; without Merge Flat; a 5,120-face ball; a hollow cube with an island as two solids; slightly bent groups merged at a wider Flat Tolerance; a body that crosses itself warned of)")


# --- 5.4 #2: Faceted cap -----------------------------------------------------------------------

func _check_faceted_cap() -> void:
	var grid := FIXTURES.to_mesh(FIXTURES.large_grid(71))
	_expect(int(grid.triangle_count()) == 60492, "The cap fixture should have 60,492 triangles (%d)." % int(grid.triangle_count()))
	var fastest := INF
	var shape: RefCounted = null
	for k in 3:
		var started := Time.get_ticks_usec()
		shape = grid.to_faceted({})
		fastest = minf(fastest, (Time.get_ticks_usec() - started) / 1e6)
	_expect(shape == null, "A body over the triangle cap should not convert.")
	_refused(str(grid.get_last_error()), "Faceted over the cap", ["60,492 triangles", "up to 60,000", "Reduce it first"])
	_expect(fastest <= 0.2, "The cap should be refused before any work (%.3f s)." % fastest)
	# Through the feature, with the body's name.
	var doc: Resource = DOCUMENT.new()
	var body := _add_mesh(doc, grid, "Grid")
	var feature := _convert(doc, "convert_faceted", body)
	var result := _rebuild(doc)
	_refused(_error(result, feature), "Faceted over the cap, as a feature", ["Grid has 60,492 triangles", "Reduce it first"])
	_expect(not result.bodies.has("body2") and (feature.options.get("outputs", []) as Array).is_empty(), "A refused convert should add no body.")
	checked.append("#2 Faceted cap (60,492 triangles refused with 'Reduce it first' in %.1f ms)" % (fastest * 1000.0))


# --- 5.4 #3: Faceted open ----------------------------------------------------------------------

func _check_faceted_open() -> void:
	var doc: Resource = DOCUMENT.new()
	var plate := FIXTURES.to_mesh(FIXTURES.open_plate())
	var body := _add_mesh(doc, plate, "Plate")
	var feature := _convert(doc, "convert_faceted", body)
	var result := _rebuild(doc)
	_expect(_error(result, feature) == "", "Faceted of an open plate should build ('%s')." % _error(result, feature))
	var shape := _made(result, feature)
	_expect(shape != null and bool(shape.is_surface()) and int(shape.solid_count()) == 0, "An open body should become a surface body.")
	_expect(_warning(result, feature).contains("Plate is open, so the result is a surface body."), "The open body should be warned of ('%s')." % _warning(result, feature))
	if shape != null:
		_expect(int(shape.face_count()) == 1, "The flat plate should become one face (%d)." % int(shape.face_count()))
		_expect(absf(float(shape.area()) - 1600.0 * MM * MM) <= 1e-3 * MM * MM, "The plate's face should hold 1,600 mm2 (%s)." % str(float(shape.area()) / (MM * MM)))
		_expect(str(doc.body_name(str(feature.options.outputs[0]))) == "Plate Surface", "The new body should be named after the mesh body ('%s')." % doc.body_name(str(feature.options.outputs[0])))
	checked.append("#3 Faceted open (a surface body of one face with the 'is open' warning)")


# --- 5.4 #4: Prismatic L-bracket ---------------------------------------------------------------

func _check_prismatic_bracket() -> void:
	var bracket := FIXTURES.l_bracket()
	var mesh: RefCounted = bracket.mesh
	var doc: Resource = DOCUMENT.new()
	var body := _add_mesh(doc, mesh, "Bracket")
	var feature := _convert(doc, "convert_prismatic", body)
	var result := _rebuild(doc)
	_expect(_error(result, feature) == "" and _warning(result, feature) == "", "Prismatic of the bracket should build clean ('%s' / '%s')." % [_error(result, feature), _warning(result, feature)])
	var shape := _made(result, feature)
	var radius_off := -1.0
	var volume_off := -1.0
	if shape != null:
		var kinds := _face_kinds(shape)
		_expect(int(shape.face_count()) == 9 and int(kinds.get("plane", 0)) == 8 and int(kinds.get("cylinder", 0)) == 1, "Prismatic of the bracket should give 8 planes and 1 cylinder (%s)." % [kinds])
		_expect(int(shape.solid_count()) == 1 and not bool(shape.is_surface()), "Prismatic of the bracket should be one closed solid.")
		for i in int(shape.face_count()):
			var info: Dictionary = shape.face_info(i)
			if str(info.get("type", "")) == "cylinder":
				radius_off = absf(float(info.radius) - float(bracket.hole_radius)) / float(bracket.hole_radius)
				var axis: Vector3 = info.axis
				_expect(absf(axis.normalized().dot(bracket.hole_axis)) > 1.0 - 1e-9, "The hole's axis should be the original's (%s)." % [axis])
		_expect(radius_off >= 0.0 and radius_off <= 0.005, "The hole's radius should be within 0.5 %% of 5 mm (off by %s)." % str(radius_off))
		volume_off = absf(float(shape.volume()) - float(bracket.shape.volume())) / float(bracket.shape.volume())
		_expect(volume_off <= 0.005, "The volume should be within 0.5 %% of the original body's (off by %s)." % str(volume_off))
		# Every face carries the name of its face group (which Tessellate took from the original
		# body's faces).
		var groups := {}
		for name in mesh.get_face_names():
			groups[name] = true
		var named := 0
		for name in shape.get_face_names():
			named += 1 if groups.has(name) else 0
		_expect(named == 9, "Every face should be named after its face group (%d of 9)." % named)
		var report := _report(feature)
		var deviation: Dictionary = report.get("deviation", {})
		_expect(float(deviation.get("max", INF)) <= float(deviation.get("allowed", 0.0)) and int(deviation.get("samples", 0)) >= 2000,
			"The result should be measured against the mesh both ways (%s)." % [deviation])
		_expect((_drawn(shape).warnings as Array).is_empty(), "Every face of the result should draw right.")
	# Defaults, as the panel asks for them.
	var defaults: Dictionary = mesh.convert_defaults("prismatic", {})
	var diagonal: float = (mesh.bbox() as AABB).size.length()
	_expect(absf(float(defaults.get("tolerance", 0.0)) - diagonal / 1000.0) <= 1e-9 and int(defaults.get("surfaces", 0)) == 9 and not defaults.has("problem"),
		"convert_defaults should give the Fit Tolerance, the surfaces and no problem (%s)." % [defaults])
	checked.append("#4 Prismatic L-bracket (9 faces: 8 planes + 1 cylinder, one solid, hole radius off by %s %%, volume off by %s %% of the original body, faces named after their groups)" % [
		String.num(radius_off * 100.0, 7), String.num(volume_off * 100.0, 7)])


# --- 5.4 #5 and #6: Prismatic refusals ---------------------------------------------------------

func _check_prismatic_refusals() -> void:
	# One group that is several flat areas (a ball in one group is one round area and converts:
	# tests/holo_forge_mesh_regress_convert_test.gd, P1d).
	var ball := FIXTURES.to_mesh(FIXTURES.large_grid(4))
	_expect(ball.to_prismatic({}) == null, "Prismatic of a cube in one face group should be refused.")
	_refused(str(ball.get_last_error()), "Prismatic with one group", ["Generate Face Groups (Accurate) first"])
	# A coarse ball in groups by angle: no group is flat or round within the tolerance.
	var coarse := _fast_groups(FIXTURES.icosphere(0.05, 1), {"method": "fast", "angle": 20.0})
	_expect(int(coarse.group_count()) > 1, "The coarse ball should fall into several groups (%d)." % int(coarse.group_count()))
	var doc: Resource = DOCUMENT.new()
	var body := _add_mesh(doc, coarse, "Ball")
	var feature := _convert(doc, "convert_prismatic", body)
	var result := _rebuild(doc)
	var error := _error(result, feature)
	_refused(error, "Prismatic of groups that fit nothing", ["Face Group ", "is not flat or round within", "(best: ", "off by ", "mm", "Generate Face Groups (Accurate)"])
	_expect(error.begins_with("Ball: "), "The refusal should carry the body's name ('%s')." % error)
	# Open, and too many triangles: refused before any fit.
	var plate := _fast_groups(FIXTURES.open_plate(), {})
	_expect(plate.to_prismatic({"name": "Plate"}) == null, "Prismatic of an open body should be refused.")
	_refused(str(plate.get_last_error()), "Prismatic of an open body", ["Plate is not closed", "Close Holes"])
	var big := FIXTURES.to_mesh(FIXTURES.large_grid(130))
	var started := Time.get_ticks_usec()
	_expect(big.to_prismatic({}) == null, "Prismatic over its triangle cap should be refused.")
	var seconds := (Time.get_ticks_usec() - started) / 1e6
	_refused(str(big.get_last_error()), "Prismatic over the cap", ["202,800 triangles", "up to 200,000", "Reduce it first"])
	_expect(seconds <= 0.2, "Prismatic's cap should be refused before any work (%.3f s)." % seconds)
	# Ranges, by field name.
	var bracket: RefCounted = FIXTURES.l_bracket().mesh
	_expect(bracket.to_prismatic({"tolerance": 1.0}) == null and str(bracket.get_last_error()).begins_with("Fit Tolerance must be between "), "A Fit Tolerance out of range should be refused by name ('%s')." % bracket.get_last_error())
	_expect(bracket.to_prismatic({"allow_spheres": 3}) == null and str(bracket.get_last_error()) == "Allow Spheres must be on or off.", "Allow Spheres of the wrong kind should be refused ('%s')." % bracket.get_last_error())
	_expect(bracket.to_faceted({"flat_tolerance": 1.0}) == null and str(bracket.get_last_error()).begins_with("Flat Tolerance must be between "), "A Flat Tolerance out of range should be refused by name ('%s')." % bracket.get_last_error())
	# A tolerance below what the hole's triangles lie off the round surface: refused with the number.
	_expect(bracket.to_prismatic({"tolerance": 1e-6}) == null, "A Fit Tolerance below the hole's chords should refuse the hole.")
	_refused(str(bracket.get_last_error()), "Prismatic below the chord height", ["is not flat or round within 0.001 mm", "best: cylinder"])
	checked.append("#5 Prismatic one group ('Generate Face Groups (Accurate) first')")
	checked.append("#6 Prismatic no fit (a coarse ball in 20 groups: '%s'); an open body, 202,800 triangles (%.1f ms) and out-of-range fields refused before any fit" % [
		error.get_slice(". ", 0), seconds * 1000.0])


# --- Prismatic: more shapes, and bodies the fits do not describe ---------------------------------

func _check_prismatic_more() -> void:
	# An icosahedron: 20 flat groups, 20 faces.
	var twenty := _fast_groups(FIXTURES.icosphere(0.05, 0), {"method": "fast", "angle": 20.0})
	var solid: RefCounted = twenty.to_prismatic({})
	_expect(solid != null and int(solid.face_count()) == 20 and int(_face_kinds(solid).get("plane", 0)) == 20, "An icosahedron should convert to 20 planes (%s)." % twenty.get_last_error())
	if solid != null:
		_expect(absf(float(solid.volume()) - float(twenty.volume())) <= 1e-6 * float(twenty.volume()), "The icosahedron's volume should be kept.")
	# A hollow cube: the void stays a void (12 planes, 7,000 mm3).
	var hollow := _fast_groups(FIXTURES.hollow_cube(false), {})
	var hollow_solid: RefCounted = hollow.to_prismatic({})
	_expect(hollow_solid != null and int(hollow_solid.face_count()) == 12 and int(hollow_solid.solid_count()) == 1, "A hollow cube should convert to one solid of 12 faces (%s)." % hollow.get_last_error())
	if hollow_solid != null:
		_expect(absf(float(hollow_solid.volume()) - 7000.0 * MM3) <= 1e-2 * MM3, "The hollow cube should keep its void (%s mm3)." % str(float(hollow_solid.volume()) / MM3))
	# A box with rounded upright edges: cylinders that touch their planes.
	var box: RefCounted = kernel.make_box(Vector3(40, 30, 10) * MM)
	var upright := PackedInt32Array()
	for e in int(box.edge_count()):
		if absf(((box.edge_info(e) as Dictionary).tangent as Vector3).z) > 0.9:
			upright.append(e)
	var rounded: RefCounted = kernel.fillet(box, upright, {"radius": 4 * MM})
	_expect(rounded != null, "The rounded box should build (%s)." % kernel.get_last_error())
	if rounded != null:
		var rounded_mesh := _tessellated(rounded)
		var back: RefCounted = rounded_mesh.to_prismatic({})
		var kinds := _face_kinds(back) if back != null else {}
		_expect(back != null and int(kinds.get("plane", 0)) == 6 and int(kinds.get("cylinder", 0)) == 4, "A box with four rounds should convert to 6 planes and 4 cylinders (%s, %s)." % [kinds, rounded_mesh.get_last_error()])
		if back != null:
			_expect(absf(float(back.volume()) - float(rounded.volume())) <= 1e-3 * float(rounded.volume()), "The rounded box's volume should come back.")
	# A cylinder with a ball on it: a sphere, and the same body without spheres is refused.
	var post: RefCounted = kernel.boolean(kernel.make_cylinder(10 * MM, 30 * MM, Vector3.ZERO, Vector3(0, 0, 1)), kernel.make_sphere(12 * MM, Vector3(0, 0, 30) * MM), 0)
	var post_mesh := _tessellated(post)
	var post_solid: RefCounted = post_mesh.to_prismatic({})
	_expect(post_solid != null and int(_face_kinds(post_solid).get("sphere", 0)) == 1, "A ball on a post should convert with one sphere (%s)." % post_mesh.get_last_error())
	_expect(post_mesh.to_prismatic({"allow_spheres": false}) == null and str(post_mesh.get_last_error()).contains("is not flat or round within"), "Without spheres the ball should be refused ('%s')." % post_mesh.get_last_error())
	# Two flat groups on one plane (a slot cuts a face in two): one surface, two faces, named
	# after their own groups.
	var slotted: RefCounted = kernel.boolean(kernel.make_box(Vector3(40, 30, 10) * MM), kernel.make_box(Vector3(6, 40, 5) * MM, Vector3(17, -5, 7) * MM), 1)
	var slotted_mesh := _tessellated(slotted)
	var slotted_solid: RefCounted = slotted_mesh.to_prismatic({})
	_expect(slotted_solid != null and int(slotted_solid.face_count()) == int(slotted.face_count()), "A slotted box should come back with its %d faces (%s)." % [int(slotted.face_count()), slotted_mesh.get_last_error()])
	if slotted_solid != null:
		var report: Dictionary = slotted_mesh.get_last_report()
		_expect(int(report.surfaces) < int(slotted_solid.face_count()), "Coplanar groups should share one surface (%d surfaces, %d faces)." % [int(report.surfaces), int(slotted_solid.face_count())])
		var unique := {}
		for name in slotted_solid.get_face_names():
			unique[name] = true
		_expect(unique.size() == int(slotted_solid.face_count()), "The faces of a slotted box should have names of their own (%s)." % [slotted_solid.get_face_names()])
	# Bodies the fits do not describe are refused, never handed over: a noisy bracket at a
	# tolerance that lets the fits pass, and a bracket whose two wall groups are one group.
	var bracket := FIXTURES.l_bracket()
	var noisy := FIXTURES.to_mesh(FIXTURES.with_noise(bracket, 0.02))
	for tolerance: float in [0.00078, 0.002, 0.0039]:
		var wrong: RefCounted = noisy.to_prismatic({"tolerance": tolerance})
		if wrong != null:
			# Kept only when it passed every check: then it is within them.
			var report: Dictionary = noisy.get_last_report()
			_expect(absf(float(report.volume_change)) <= 0.005 and float(report.deviation.max) <= 3.0 * tolerance, "A noisy body that converts should be within the checks (%s)." % [report.deviation])
		else:
			_expect(str(noisy.get_last_error()) != "", "A refused noisy body should say why.")
	var merged: RefCounted = (bracket.mesh as RefCounted).regroup({"groups": PackedInt32Array([0, 1])})
	if merged != null:
		var one: RefCounted = merged.to_prismatic({})
		_expect(one == null or absf(float(merged.get_last_report().volume_change)) <= 0.005, "Two faces in one group should be refused, or convert within the checks.")
		if one == null:
			_expect(str(merged.get_last_error()).contains("is not flat or round") or str(merged.get_last_error()).contains("do not close") or str(merged.get_last_error()).contains("away from"),
				"Two faces in one group should be refused with what is off ('%s')." % merged.get_last_error())
	checked.append("Prismatic on more shapes (an icosahedron as 20 planes; a hollow cube keeps its void; four rounds touching their planes; a sphere, refused without Allow Spheres; coplanar groups on one surface with names of their own; a noisy bracket and a mis-grouped one refused or within the checks)")


# --- 5.4 #9: Prismatic crossing holes ----------------------------------------------------------

func _check_prismatic_crossing() -> void:
	var fixture := FIXTURES.crossing_holes()
	var mesh: RefCounted = fixture.mesh
	# The estimate was measured again inside the real op (mesh_budget.h, stage C): 4 crossing
	# pairs are 0.44 s of an estimate of about 0.58 s, so the limit that refuses them is 0.3 s
	# (the work order's 1.0 s held for the spike's 0.25 s a pair).
	var fastest := INF
	var shape: RefCounted = null
	for k in 3:
		var started := Time.get_ticks_usec()
		shape = mesh.to_prismatic({"time_limit": 0.3, "name": "Block"})
		fastest = minf(fastest, (Time.get_ticks_usec() - started) / 1e6)
	_expect(shape == null, "Crossing holes over the time limit should not convert.")
	var error := str(mesh.get_last_error())
	_refused(error, "Prismatic of crossing holes", ["Convert Mesh: Prismatic would take about ", " s on Block (limit 0.3 s)", "4 pairs of round holes cross", "Use Convert Mesh: Faceted"])
	_expect(fastest <= 0.2, "Crossing holes should be refused before any kernel call (%.3f s)." % fastest)
	var report: Dictionary = mesh.get_last_report()
	_expect(int(report.get("crossing_pairs", 0)) == 4 and (report.get("phases", {}) as Dictionary).is_empty(), "The refusal should come from the plan alone (%s)." % [report])
	# The same through the feature in a preview, and then with the full time: it converts.
	var doc: Resource = DOCUMENT.new()
	var body := _add_mesh(doc, mesh, "Block")
	var feature := _convert(doc, "convert_prismatic", body)
	var preview := _rebuild(doc, 0.3)
	_expect(MESH_FEATURE.is_time_refusal(_error(preview, feature)) and _error(preview, feature).contains("4 pairs"), "A preview should get the time refusal ('%s')." % _error(preview, feature))
	var full := _rebuild(doc)
	_expect(_error(full, feature) == "", "With the full time the crossing holes should convert ('%s')." % _error(full, feature))
	var solid := _made(full, feature)
	var estimate := 0.0
	var took := 0.0
	if solid != null:
		var kinds := _face_kinds(solid)
		_expect(int(kinds.get("plane", 0)) == 6 and int(kinds.get("cylinder", 0)) == int(fixture.shape.face_count()) - 6, "The crossing holes should come back as 6 planes and the original's round faces (%s)." % [kinds])
		_expect(absf(float(solid.volume()) - float(fixture.shape.volume())) <= 1e-3 * float(fixture.shape.volume()), "The crossing holes' volume should come back.")
		estimate = float(_report(feature).get("estimate", 0.0))
		took = float(_report(feature).get("ms", 0.0)) / 1000.0
		_expect(took <= estimate * 2.0 + 1.0, "The estimate should not be far under the real time (%.2f s against %.2f s)." % [estimate, took])
	checked.append("#9 Prismatic crossing holes (refused in %.1f ms at a 0.3 s limit with the estimate and '4 pairs'; converted with the full time in %.2f s against an estimate of %.2f s)" % [fastest * 1000.0, took, estimate])


# --- 5.4 #7: Organic sphere --------------------------------------------------------------------

func _check_organic() -> void:
	var ball := FIXTURES.to_mesh(FIXTURES.icosphere(0.05, 5))
	var doc: Resource = DOCUMENT.new()
	var body := _add_mesh(doc, ball, "Ball")
	var feature := _convert(doc, "convert_organic", body, {}, {"faces": _num(200)})
	var result := _rebuild(doc)
	_expect(_error(result, feature) == "", "Organic of a ball should build ('%s')." % _error(result, feature))
	var shape := _made(result, feature)
	var worst := 0.0
	var tolerance := (ball.bbox() as AABB).size.length() / 500.0
	var cage_faces := 0
	if shape != null:
		_expect(int(shape.solid_count()) == 1 and not bool(shape.is_surface()), "Organic of a ball should be one closed solid.")
		var report := _report(feature)
		var deviation: Dictionary = report.get("deviation", {})
		worst = float(deviation.get("max", INF))
		cage_faces = int(report.get("cage_faces", 0))
		_expect(worst <= 4.0 * tolerance and absf(float(deviation.get("allowed", 0.0)) - 4.0 * tolerance) <= 1e-9, "The deviation should be within 4 x the tolerance and reported (%s)." % [deviation])
		_expect(deviation.has("solid_to_mesh") and deviation.has("mesh_to_solid") and float(deviation.solid_to_mesh) <= 4.0 * tolerance + 0.0003, "The solid itself should be measured against the mesh (%s)." % [deviation])
		_expect(cage_faces >= 150 and cage_faces <= 300, "The cage should have about the 200 faces asked for (%d)." % cage_faces)
		_expect(absf(float(report.get("volume_change", 1.0))) <= 0.01, "The ball's volume should come back within 1 %% (%s)." % str(report.get("volume_change")))
		_expect((_drawn(shape).warnings as Array).is_empty(), "Every face of the smooth solid should draw right.")
		var stat := str((MESH_FEATURE.reports.get(feature.id, {}) as Dictionary).get("stat", ""))
		_expect(stat.contains("smooth solid") and stat.contains("from the mesh"), "The stat line should give the deviation ('%s')." % stat)
	# Refusals: an open body, two solids, a face count and a deviation out of range, and a shape
	# the cage cannot follow (the bracket's sharp edges) with the number.
	var plate := FIXTURES.to_mesh(FIXTURES.open_plate())
	_refused(str(ORGANIC.convert(plate, {}).error), "Organic of an open body", ["is not closed"])
	_refused(str(ORGANIC.convert(FIXTURES.to_mesh(FIXTURES.two_cubes(Vector3(0.05, 0, 0))), {}).error), "Organic of two solids", ["2 separate solids"])
	_refused(str(ORGANIC.convert(ball, {"faces": 10}).error), "Organic with 10 faces", ["Target Cage Faces must be a whole number between 24 and 5,000."])
	_refused(str(ORGANIC.convert(ball, {"tolerance": 0.0}).error), "Organic with no deviation", ["Allowed Deviation must be more than 0"])
	_refused(str(ORGANIC.convert(ball, {"faces": 5000}).error), "Organic with 5,000 faces in 20 s", ["Convert Mesh: Organic would take about ", "(limit 20 s)", "Lower Target Cage Faces."])
	var sharp_doc: Resource = DOCUMENT.new()
	var sharp_body := _add_mesh(sharp_doc, FIXTURES.l_bracket().mesh, "Bracket")
	var sharp := _convert(sharp_doc, "convert_organic", sharp_body)
	var sharp_result := _rebuild(sharp_doc)
	_refused(_error(sharp_result, sharp), "Organic of a sharp-edged body", ["Bracket: The smooth surface is up to ", " away from the mesh (allowed ", "Raise Target Cage Faces or Allowed Deviation."])
	checked.append("#7 Organic sphere (a 20,480-triangle ball at 200 faces: a cage of %d faces, one solid, up to %s mm from the mesh against an allowed %s mm; refusals for open, split, out-of-range, too slow and sharp-edged bodies)" % [
		cage_faces, String.num(worst * 1000.0, 4), String.num(4.0 * tolerance * 1000.0, 4)])


# --- 5.4 #8: Organic form body -----------------------------------------------------------------

func _check_form_body() -> void:
	var ball := FIXTURES.to_mesh(FIXTURES.icosphere(0.05, 5))
	var doc: Resource = DOCUMENT.new()
	var body := _add_mesh(doc, ball, "Ball")
	var feature := _convert(doc, "convert_organic", body, {"output": "form_body"}, {"faces": _num(200)})
	_expect(str(MESH_CONVERT.form_body(doc, feature).error) != "", "A feature that was not built yet should not become a form body.")
	var result := _rebuild(doc)
	_expect(_error(result, feature) == "", "Organic with Output Form Body should build ('%s')." % _error(result, feature))
	_expect(_warning(result, feature).contains("The Form Body output is not in the timeline yet"), "Until it is swapped, the feature should say it shows the solid ('%s')." % _warning(result, feature))
	var out_id := str((feature.options.get("outputs", [""]) as Array)[0])
	var swapped := MESH_CONVERT.form_body(doc, feature)
	_expect(str(swapped.error) == "", "The built feature should become a form body (%s)." % swapped.error)
	var forms := 0
	var cage_faces := -1
	var converts := 0
	for f in doc.features:
		if str(f.type) == "form":
			forms += 1
			var cages: Dictionary = f.options.get("bodies", {})
			_expect(cages.size() == 1 and cages.has(out_id), "The Form feature should hold the converted body's cage (%s)." % [cages.keys()])
			if cages.has(out_id):
				cage_faces = CAGE.face_count(cages[out_id])
		if str(f.type) == "mesh" and str(f.options.get("method", "")) == "convert_organic":
			converts += 1
	_expect(forms == 1 and converts == 0, "The convert feature should be swapped for one Form feature (%d forms, %d converts)." % [forms, converts])
	_expect(cage_faces > 0 and cage_faces <= 5000, "The form body's cage should have at most 5,000 faces (%d)." % cage_faces)
	_expect(doc.features.size() == 2 and str(doc.features[1].type) == "form", "The Form feature should stand where the convert feature stood.")
	_expect(not bool(doc.bodies[body].visible), "The mesh body should be hidden.")
	var again := _rebuild(doc)
	_expect(again.errors.is_empty(), "The design with the form body should rebuild clean (%s)." % [again.errors])
	_expect(again.bodies.has(out_id) and not MESH_BODY.is_mesh(again.bodies[out_id]) and int(again.bodies[out_id].shape.solid_count()) == 1, "The form body should convert to one solid on rebuild.")
	_expect(again.bodies.has(body) and MESH_BODY.is_mesh(again.bodies[body]), "The mesh body should still be in the model (hidden).")
	checked.append("#8 Organic form body (the feature swapped for a Form feature whose cage has %d faces; the design rebuilds clean with the form body as one solid and the mesh body hidden)" % cage_faces)


# --- Bodies, kept results ------------------------------------------------------------------------

func _check_bodies() -> void:
	var cube := _fast_groups(FIXTURES.large_grid(4), {})
	var doc: Resource = DOCUMENT.new()
	var body := _add_mesh(doc, cube, "Cube")
	var feature := _convert(doc, "convert_prismatic", body)
	# A preview (short time limit) shows the body under a passing id and registers nothing.
	var bodies_before: int = doc.bodies.size()
	var preview := _rebuild(doc, MESH_FEATURE.PREVIEW_SECONDS)
	_expect(_error(preview, feature) == "" or MESH_FEATURE.is_time_refusal(_error(preview, feature)), "A preview should build or say it has no time ('%s')." % _error(preview, feature))
	_expect(doc.bodies.size() == bodies_before and (feature.options.get("outputs", []) as Array).is_empty() and bool(doc.bodies[body].visible), "A preview should register no body and hide nothing.")
	# New Body: the converted body is added, the mesh body stays in the model, hidden.
	var result := _rebuild(doc)
	var shape := _made(result, feature)
	_expect(shape != null and int(shape.face_count()) == 6, "The cube should convert to 6 faces ('%s')." % _error(result, feature))
	_expect(result.bodies.has(body) and MESH_BODY.is_mesh(result.bodies[body]) and not bool(doc.bodies[body].visible), "New Body should keep the mesh body, hidden.")
	var out_id := str(feature.options.outputs[0])
	_expect(str(doc.body_name(out_id)) == "Cube Solid" and str(result.bodies[out_id].feature) == feature.id, "The new body should be named after the mesh body and belong to the feature.")
	# A rebuild that changes nothing converts nothing: the same shape, the same id; and a mesh
	# body the user showed again stays shown.
	doc.bodies[body]["visible"] = true
	var hits: int = MESH_CONVERT.cache_hits
	var again := _rebuild(doc)
	_expect(MESH_CONVERT.cache_hits == hits + 1 and is_same(_made(again, feature), shape) and str(feature.options.outputs[0]) == out_id, "A rebuild should give the kept body back under the same id.")
	_expect(bool(doc.bodies[body].visible), "A mesh body shown again should stay shown.")
	# A Solid tool takes the converted body, and still refuses the mesh body.
	_expect(MESH_BODY.gate(doc, [again.bodies[out_id]]) == "" and MESH_BODY.gate(doc, [again.bodies[body]]) != "", "The converted body should pass the gate, the mesh body not.")
	# Replace: the mesh body leaves the model.
	feature.options["result"] = "replace"
	var replaced := _rebuild(doc)
	_expect(_error(replaced, feature) == "" and not replaced.bodies.has(body) and replaced.bodies.has(out_id), "Replace should take the mesh body out ('%s')." % _error(replaced, feature))
	# Two bodies in one feature; one that cannot convert stops the feature and adds nothing.
	var pair_doc: Resource = DOCUMENT.new()
	var first := _add_mesh(pair_doc, FIXTURES.to_mesh(FIXTURES.icosphere(0.02, 2)), "First")
	var second := _add_mesh(pair_doc, FIXTURES.to_mesh(FIXTURES.hollow_cube(false)), "Second")
	var pair: Resource = MESH_CONVERT.add_convert(pair_doc, "convert_faceted", [first, second]).feature
	var pair_result := _rebuild(pair_doc)
	_expect(_error(pair_result, pair) == "" and (pair.options.get("outputs", []) as Array).size() == 2, "Two bodies should convert in one feature ('%s')." % _error(pair_result, pair))
	var bad_doc: Resource = DOCUMENT.new()
	var good := _add_mesh(bad_doc, FIXTURES.to_mesh(FIXTURES.icosphere(0.02, 2)), "Good")
	var bad := _add_mesh(bad_doc, FIXTURES.to_mesh(FIXTURES.cube_debris()), "Debris")
	var mixed: Resource = MESH_CONVERT.add_convert(bad_doc, "convert_faceted", [good, bad]).feature
	var mixed_result := _rebuild(bad_doc)
	_refused(_error(mixed_result, mixed), "A body with edges three triangles share", ["Debris has ", "edges that more than two triangles share", "Stitch and Remove"])
	_expect((mixed.options.get("outputs", []) as Array).is_empty() and mixed_result.bodies.size() == 2, "A feature that fails on one body should add none.")
	checked.append("bodies (a preview registers nothing; New Body adds '<Body> Solid' and hides the mesh body once; a rebuild gives the kept shape back; the converted body passes the gate; Replace takes the mesh body out; two bodies in one feature; one failing body adds none)")


# --- Refusals through the feature ----------------------------------------------------------------

func _check_refusals() -> void:
	var doc: Resource = DOCUMENT.new()
	var cube := _add_mesh(doc, _fast_groups(FIXTURES.large_grid(4), {}), "Cube")
	var box_feature: Resource = doc.add_feature("box", "Box", {
		"length": doc.make_input("0.02 m", "length"), "height": doc.make_input("0.02 m", "length"), "width": doc.make_input("0.02 m", "length"),
	}, {"operation": OPERATIONS.NEW_BODY, "position": Vector3(0.2, 0, 0)})
	box_feature.options.body_id = doc.new_body(box_feature.id)
	var on_brep := _convert(doc, "convert_faceted", str(box_feature.options.body_id))
	var on_gone := _convert(doc, "convert_prismatic", "body42")
	var on_nothing: Resource = doc.add_feature("mesh", "ConvertFaceted", {}, {"method": "convert_faceted", "bodies": [], "result": "new_body"})
	var bad_result := _convert(doc, "convert_faceted", cube, {"result": "both"})
	var bad_output := _convert(doc, "convert_organic", cube, {"output": "cloud"})
	var bad_flat := _convert(doc, "convert_faceted", cube, {}, {"flat_tolerance": _len(1.0)})
	var bad_fit := _convert(doc, "convert_prismatic", cube, {}, {"tolerance": _len(0.0)})
	var bad_faces := _convert(doc, "convert_organic", cube, {}, {"faces": _num(12.5)})
	var unknown: Resource = doc.add_feature("mesh", "ConvertMagic", {}, {"method": "convert_magic", "bodies": [{"kind": "body", "body": cube}]})
	var result := _rebuild(doc)
	_expect(_error(result, on_brep) == "%s is not a mesh body: there is nothing to convert." % doc.body_name(str(box_feature.options.body_id)), "Convert of a B-rep body should say so ('%s')." % _error(result, on_brep))
	_refused(_error(result, on_gone), "Convert of a body that is gone", ["no longer exists"])
	_expect(_error(result, on_nothing) == "Select a mesh body", "Convert with nothing picked should ask for a body ('%s')." % _error(result, on_nothing))
	_expect(_error(result, bad_result) == "Result must be New Body or Replace.", "An unknown Result should be refused ('%s')." % _error(result, bad_result))
	_expect(_error(result, bad_output) == "Output must be Solid Body or Form Body.", "An unknown Output should be refused ('%s')." % _error(result, bad_output))
	_refused(_error(result, bad_flat), "A Flat Tolerance out of range", ["Flat Tolerance must be between 0 mm and "])
	_refused(_error(result, bad_fit), "A Fit Tolerance out of range", ["Fit Tolerance must be between "])
	_refused(_error(result, bad_faces), "A Target Cage Faces that is not whole", ["Target Cage Faces must be a whole number between 24 and 5,000."])
	_expect(_error(result, unknown) == "The Mesh tool 'convert_magic' is not available in this build", "An unknown convert should say so ('%s')." % _error(result, unknown))
	_expect(result.bodies.size() == 2, "Refused converts should add no bodies (%d)." % result.bodies.size())
	# Meshes Faceted cannot take, each with what to run first.
	for case in [[FIXTURES.flipped_half(), ["face the wrong way", "Reverse Normal"]], [FIXTURES.cube_debris(), ["more than two triangles share", "Stitch and Remove"]]]:
		var mesh := FIXTURES.to_mesh(case[0])
		_expect(mesh.to_faceted({}) == null, "Faceted should refuse a mesh it cannot take.")
		_refused(str(mesh.get_last_error()), "Faceted of a broken mesh", case[1])
	var inside_out: RefCounted = FIXTURES.to_mesh(FIXTURES.icosphere(0.02, 2)).reverse({"mode": "whole"})
	_expect(inside_out != null and inside_out.to_faceted({}) == null and str(inside_out.get_last_error()).contains("inside-out"), "Faceted should refuse an inside-out body ('%s')." % (inside_out.get_last_error() if inside_out != null else "no mesh"))
	# Every range, a thousandth outside each bound (refused by field name) and a thousandth inside (taken).
	var box := _fast_groups(FIXTURES.large_grid(4), {})
	var size: float = (box.bbox() as AABB).size.length()
	var outside := 0
	var inside := 0
	for case in [["to_faceted", "flat_tolerance", -1e-9 * size, "Flat Tolerance", false], ["to_faceted", "flat_tolerance", size / 100.0 * 1.001, "Flat Tolerance", false],
			["to_faceted", "flat_tolerance", size / 100.0 * 0.999, "", true], ["to_faceted", "flat_tolerance", 0.0, "", true],
			["to_prismatic", "tolerance", size * 1e-6 * 0.999, "Fit Tolerance", false], ["to_prismatic", "tolerance", size / 20.0 * 1.001, "Fit Tolerance", false],
			["to_prismatic", "tolerance", size * 1e-6 * 1.001, "", true], ["to_prismatic", "tolerance", size / 20.0 * 0.999, "", true]]:
		var out: RefCounted = box.call(str(case[0]), {str(case[1]): float(case[2])})
		if bool(case[4]):
			inside += 1
			_expect(out != null, "%s with %s = %s should be taken ('%s')." % [case[0], case[1], str(case[2]), box.get_last_error()])
		else:
			outside += 1
			_expect(out == null and str(box.get_last_error()).begins_with("%s must be between " % case[3]), "%s with %s = %s should be refused by name ('%s')." % [case[0], case[1], str(case[2]), box.get_last_error()])
	var round_ball := FIXTURES.to_mesh(FIXTURES.icosphere(0.05, 3))
	var ball_size: float = (round_ball.bbox() as AABB).size.length()
	for case in [[{"faces": 23}, "Target Cage Faces must be"], [{"faces": 5001}, "Target Cage Faces must be"], [{"tolerance": ball_size / 10.0 * 1.001}, "Allowed Deviation must be"], [{"tolerance": -1.0}, "Allowed Deviation must be"]]:
		outside += 1
		_expect(ORGANIC.refusal(round_ball, case[0]).begins_with(str(case[1])), "Organic with %s should be refused by name ('%s')." % [case[0], ORGANIC.refusal(round_ball, case[0])])
	for options in [{"faces": 24}, {"faces": 5000}, {"tolerance": ball_size / 10.0 * 0.999}]:
		inside += 1
		_expect(ORGANIC.refusal(round_ball, options) == "", "Organic with %s should be in range ('%s')." % [options, ORGANIC.refusal(round_ball, options)])
	checked.append("refusals (a B-rep body, a missing body, nothing picked, unknown Result, Output and method, every range by field name, flipped, non-manifold and inside-out meshes), none adds a body; %d values just outside the ranges refused and %d just inside taken" % [outside, inside])


# --- The time bound ------------------------------------------------------------------------------

func _check_time_bound() -> void:
	# Faceted: the estimate refuses before any work; with the estimate skipped (tests only) the
	# deadline stops it within its limit + 1 s.
	# (Merge Flat off: the estimate counts the faces the result will have, and merged the grid is
	# six faces that convert in a moment.)
	var grid := FIXTURES.to_mesh(FIXTURES.large_grid(40))
	var started := Time.get_ticks_usec()
	_expect(grid.to_faceted({"time_limit": 1.0, "merge_flat": false}) == null, "Faceted over its time estimate should be refused.")
	var refused_in := (Time.get_ticks_usec() - started) / 1e6
	_refused(str(grid.get_last_error()), "Faceted over its estimate", ["Convert Mesh: Faceted would take about ", "(limit 1 s)", "Reduce the body first."])
	_expect(refused_in <= 0.2, "Faceted's estimate should refuse before any work (%.3f s)." % refused_in)
	started = Time.get_ticks_usec()
	_expect(grid.to_faceted({"time_limit": 1.0, "skip_estimate": true, "merge_flat": false}) == null, "Faceted past its deadline should be stopped.")
	var stopped_in := (Time.get_ticks_usec() - started) / 1e6
	_refused(str(grid.get_last_error()), "Faceted past its deadline", ["Convert Mesh: Faceted took longer than 1 s and was stopped."])
	_expect(stopped_in <= 2.0, "Faceted should stop within its limit + 1 s (%.2f s at a 1 s limit)." % stopped_in)
	# Prismatic: the same on the crossing holes at 0.05 s.
	var mesh: RefCounted = FIXTURES.crossing_holes().mesh
	started = Time.get_ticks_usec()
	_expect(mesh.to_prismatic({"time_limit": 0.05, "skip_estimate": true}) == null, "Prismatic past its deadline should be stopped.")
	var prismatic_in := (Time.get_ticks_usec() - started) / 1e6
	_refused(str(mesh.get_last_error()), "Prismatic past its deadline", ["Convert Mesh: Prismatic took longer than 0.05 s and was stopped.", "Combine face groups to make fewer surfaces, or use Faceted."])
	_expect(prismatic_in <= 1.05, "Prismatic should stop within its limit + 1 s (%.2f s at a 0.05 s limit)." % prismatic_in)
	# Organic: a limit below its own estimate is refused before any work.
	var ball := FIXTURES.to_mesh(FIXTURES.icosphere(0.05, 5))
	started = Time.get_ticks_usec()
	var organic := ORGANIC.convert(ball, {"faces": 500, "time_limit": 0.5})
	var organic_in := (Time.get_ticks_usec() - started) / 1e6
	_refused(str(organic.error), "Organic over its estimate", ["Convert Mesh: Organic would take about ", "(limit 0.5 s)"])
	_expect(organic_in <= 0.2, "Organic's estimate should refuse before any work (%.3f s)." % organic_in)
	checked.append("the time bound (Faceted refused by its estimate in %.1f ms and stopped %.2f s into a 1 s limit; Prismatic stopped %.2f s into a 0.05 s limit; Organic refused by its estimate in %.1f ms)" % [
		refused_in * 1000.0, stopped_in, prismatic_in, organic_in * 1000.0])


# --- Timing --------------------------------------------------------------------------------------

func _check_timing() -> void:
	var calibration := func() -> void:
		var sphere: RefCounted = kernel.make_sphere(0.02, Vector3.ZERO, "cal")
		sphere.tessellate(0.0002, 0.3)
	var ball := FIXTURES.icosphere(0.05, 4)
	var smooth := FIXTURES.icosphere(0.05, 5)
	var bracket: Dictionary = (FIXTURES.l_bracket().mesh as RefCounted).get_arrays()
	var crossing: Dictionary = (FIXTURES.crossing_holes().mesh as RefCounted).get_arrays()
	var results := {}
	var counts := {}
	var fresh := func(arrays: Dictionary) -> RefCounted:
		var m := _new()
		m.set_arrays(arrays.positions, arrays.indices, arrays.groups, arrays.get("group_names", arrays.get("names", PackedStringArray())))
		return m
	var faceted := func() -> void:
		var shape: RefCounted = (fresh.call(ball) as RefCounted).to_faceted({})
		counts["faceted_5120"] = int(shape.face_count()) if shape != null else -1
	results["faceted_5120"] = TIMING.compare(faceted, calibration, 3, "set_arrays + to_faceted, 5,120 triangles")
	var prismatic := func() -> void:
		var shape: RefCounted = (fresh.call(bracket) as RefCounted).to_prismatic({})
		counts["prismatic_bracket"] = int(shape.face_count()) if shape != null else -1
	results["prismatic_bracket"] = TIMING.compare(prismatic, calibration, 3, "set_arrays + to_prismatic, the L-bracket")
	var crossed := func() -> void:
		var shape: RefCounted = (fresh.call(crossing) as RefCounted).to_prismatic({})
		counts["prismatic_crossing"] = int(shape.face_count()) if shape != null else -1
	results["prismatic_crossing"] = TIMING.compare(crossed, calibration, 3, "set_arrays + to_prismatic, 4 crossing pairs")
	var organic := func() -> void:
		var made := ORGANIC.convert(fresh.call(smooth), {"faces": 200})
		counts["organic_200"] = int(made.shape.solid_count()) if made.shape != null else -1
	results["organic_200"] = TIMING.compare(organic, calibration, 3, "set_arrays + Organic at 200 faces, 20,480 triangles")
	_expect(counts.faceted_5120 == 5120 and counts.prismatic_bracket == 9 and counts.prismatic_crossing > 9 and counts.organic_200 == 1, "The timed converts should give their bodies (%s)." % [counts])
	var over := []
	for key: String in results:
		var t: Dictionary = results[key]
		print("mesh convert timing %s: %.1f ms (calibration %.3f ms), ratio %.2f, limit %.2f" % [key, t.op, t.calibration, t.ratio, LIMITS[key]])
		if t.ratio > LIMITS[key]:
			over.append("%s ratio %.2f > %.2f" % [key, t.ratio, LIMITS[key]])
	_expect(over.is_empty(), "Timing ratios over their limits: %s." % [over])
	checked.append("timing ratios (Faceted 5,120 triangles %.0f ms; Prismatic L-bracket %.0f ms; Prismatic 4 crossing pairs %.0f ms; Organic 200 faces %.0f ms)" \
		% [results.faceted_5120.op, results.prismatic_bracket.op, results.prismatic_crossing.op, results.organic_200.op])
