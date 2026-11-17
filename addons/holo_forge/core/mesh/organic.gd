@tool
extends RefCounted
## Convert Mesh: Organic (experimental): a closed mesh body turned into a smooth solid through a
## Form cage. For sculpted shapes. It may refuse.
##
## How: the body is remeshed evenly to about twice the Target Cage Faces triangles, the triangles
## are paired into quads (a Form cage), the cage is moved so its smooth surface passes through
## the remeshed points (which lie on the body), and the smooth surface becomes exact B-spline
## faces through the Form workspace's own conversion (CadSubD.to_shapes).
##
## Nothing is handed over unchecked: the smooth surface is measured against the body both ways
## (refused above 4 x the Allowed Deviation, warned above 1 x), and the solid itself is checked
## again once made: one closed solid, every face drawn right, its own triangles against the body
## both ways, its volume against the body's.
##
## A body under 10 mm across is converted on a copy brought to 100 mm, and the solid and the
## cage are brought back to its size: the Form conversion's tolerances are absolute, and on a
## ball of 0.2 mm it ran for half a minute (verifier V3, B3).
##
## convert(mesh, options) -> {"error", "warning" (lines), "cage", "shape", "report"}.
## options: faces [500] (24..5,000), tolerance [D / 500] (more than 0, at most D / 10),
## time_limit [20], prefix (the face names' prefix), brep [true] (false: stop at the cage),
## name [DEFAULT_NAME] (the body's name in the sentences; the Convert feature passes BODY,
## "{body}", and puts the name in itself; refusal() always says BODY).
##
## const ORGANIC := preload("res://addons/holo_forge/core/mesh/organic.gd")

const CAGE := preload("res://addons/holo_forge/core/form/cage.gd")
const FORM_FIT := preload("res://addons/holo_forge/core/form/form_fit.gd")
const FORM := preload("res://addons/holo_forge/core/features/form.gd")

const TITLE := "Convert Mesh: Organic"
const BODY := "{body}"
const DEFAULT_NAME := "the mesh"
const MAX_TRIANGLES := 200000
const MIN_FACES := 24
const MAX_FACES := 5000
const DEFAULT_FACES := 500
## Remesh's own range for an edge length, as fractions of the body's diagonal.
const MIN_EDGE_FRACTION := 1.0 / 2000.0
const MAX_EDGE_FRACTION := 1.0 / 5.0
## Samples each way when the smooth surface and the solid are measured against the body.
const SAMPLES := 20000
## The viewport's meshing of a body (core/tessellate.gd): the solid is checked on that mesh.
const DISPLAY_FRACTION := 0.0015
const DISPLAY_ANGLE := 0.3
## Triangles the remesh aims at for each cage face asked for. Two triangles make a quad, but
## about a third of them find no partner and stay triangles (measured: 277 cage faces from 418
## triangles, 648 from 1,000, 2,628 from 4,010), so 1.55 lands on the Target Cage Faces.
const TRIANGLES_PER_FACE := 1.55
## What the steps after the remesh cost, in seconds (the cage fit, the measuring, the
## conversion to faces and the checks on the solid; the conversion cannot be stopped once
## started): BASE + PER_FACE x cage faces. Measured on the dev machine on 2026-11-12 on a ball
## (cage faces: seconds): 277: 1.1; 648: 2.3; 2,628: 10.1; about 0.25 s + 3.8 ms a face, stored
## x 1.5. So about 3,300 cage faces fit in 20 s; more is refused before any work.
const SECONDS_BASE := 0.4
const SECONDS_PER_FACE := 0.006
## Bodies smaller than this are converted at WORK_SIZE and brought back (meters across).
const SMALL_BODY := 0.01
const WORK_SIZE := 0.1
## The solid's volume may differ from the body's by this much at most, whatever the Allowed
## Deviation.
const MAX_VOLUME_CHANGE := 0.05
const OTHER_HINT := "Try another Target Cage Faces, or use Convert Mesh: Faceted."
const TIME_HINT := "Lower Target Cage Faces."
const REDUCE_HINT := "Reduce the body first (Fast method)."


## What Organic would refuse before any work ("" when it can start), for a mesh and its options.
static func refusal(mesh: RefCounted, options: Dictionary) -> String:
	if mesh == null or mesh.is_null():
		return "%s has no triangles." % BODY
	var triangles := int(mesh.triangle_count())
	if triangles > MAX_TRIANGLES:
		return "%s has %s triangles; %s takes up to %s. %s" % [BODY, _commas(triangles), TITLE, _commas(MAX_TRIANGLES), REDUCE_HINT]
	if bool(mesh.is_surface()):
		return "%s is not closed. Close Holes or Wrap it first." % BODY
	var solids := int(mesh.solid_count())
	if solids != 1:
		return "%s is %d separate solids; %s takes one at a time. Separate it first." % [BODY, solids, TITLE]
	var found: Dictionary = mesh.check(0.25)
	var surfaces := int(found.get("components", 1)) if not found.is_empty() else 1
	if surfaces != 1:
		# (One solid of several closed surfaces: it has voids.)
		return "%s is hollow (%d closed surfaces); %s makes one smooth surface. Use Convert Mesh: Faceted." % [BODY, surfaces, TITLE]
	var across: float = (mesh.bbox() as AABB).size.length()
	if absf(float(mesh.volume())) <= 1e-12 * across * across * across:
		return "%s encloses no volume (its triangles lie back to back): there is nothing to make a solid of." % BODY
	var faces: Variant = options.get("faces", DEFAULT_FACES)
	if not (faces is int or faces is float) or not is_finite(float(faces)) or absf(float(faces) - roundf(float(faces))) > 1e-9 or float(faces) < MIN_FACES or float(faces) > MAX_FACES:
		return "Target Cage Faces must be a whole number between %d and %s." % [MIN_FACES, _commas(MAX_FACES)]
	var diagonal: float = (mesh.bbox() as AABB).size.length()
	var tolerance: Variant = options.get("tolerance", diagonal / 500.0)
	if not (tolerance is int or tolerance is float) or not is_finite(float(tolerance)) or float(tolerance) <= 0.0 or float(tolerance) > diagonal / 10.0 * (1.0 + 1e-6):
		return "Allowed Deviation must be more than 0 and at most %s." % _mm(diagonal / 10.0)
	return ""


## What the steps after the remesh cost for a cage of that many faces (seconds).
static func seconds_after_remesh(faces: int) -> float:
	return SECONDS_BASE + SECONDS_PER_FACE * faces


static func convert(mesh: RefCounted, options: Dictionary) -> Dictionary:
	var made := _convert(mesh, options)
	var who := str(options.get("name", DEFAULT_NAME))
	if who != BODY:
		made["error"] = _named(str(made.error), who)
		made["warning"] = _named(str(made.warning), who)
	return made


## Puts the body's name into every BODY of a sentence (lines), and starts a line with a capital.
static func _named(text: String, who: String) -> String:
	if text == "":
		return text
	var lines := text.replace(BODY, who).split("\n")
	for i in lines.size():
		var line := lines[i]
		if line != "" and line.begins_with(who):
			lines[i] = line.left(1).to_upper() + line.substr(1)
	return "\n".join(lines)


static func _convert(mesh: RefCounted, options: Dictionary) -> Dictionary:
	var diagonal: float = (mesh.bbox() as AABB).size.length() if mesh != null and not mesh.is_null() else 0.0
	if diagonal <= 0.0 or diagonal >= SMALL_BODY or refusal(mesh, options) != "" or not ClassDB.class_exists("CadKernel"):
		return _convert_at(mesh, options, 1.0)
	# A small body: converted on a copy at WORK_SIZE, its middle at the origin.
	var started := Time.get_ticks_usec()
	var scale := WORK_SIZE / diagonal
	var centre: Vector3 = (mesh.bbox() as AABB).get_center()
	var larger: RefCounted = mesh.transformed(Transform3D(Basis.from_scale(Vector3.ONE * scale), -centre * scale))
	if larger == null or larger.is_null():
		return _convert_at(mesh, options, 1.0)
	var asked := options.duplicate()
	if options.has("tolerance"):
		asked["tolerance"] = float(options.tolerance) * scale
	var made := _convert_at(larger, asked, 1.0 / scale)
	var report: Dictionary = made.report
	report["scale"] = scale
	for key in ["tolerance", "edge_length", "fit_residual"]:
		if report.has(key):
			report[key] = float(report[key]) / scale
	if report.get("deviation") is Dictionary:
		var deviation: Dictionary = report.deviation
		for key in deviation.keys():
			if key != "samples":
				deviation[key] = float(deviation[key]) / scale
	if report.get("output") is Dictionary and (report.output as Dictionary).has("volume"):
		report.output["volume"] = float(report.output.volume) / (scale * scale * scale)
	if str(made.error) != "":
		return made
	# Back to the body's size and place: the cage, and the solid (with its face names).
	var cage: Dictionary = CAGE.copy(made.cage)
	var points: PackedFloat64Array = cage.positions
	for i in range(0, points.size(), 3):
		points[i] = points[i] / scale + centre.x
		points[i + 1] = points[i + 1] / scale + centre.y
		points[i + 2] = points[i + 2] / scale + centre.z
	cage.positions = points
	made["cage"] = cage
	if made.shape != null:
		var kernel: RefCounted = ClassDB.instantiate("CadKernel")
		var back: RefCounted = kernel.transform_shape(made.shape, Transform3D(Basis.from_scale(Vector3.ONE / scale), centre), "organic")
		var box: AABB = back.bbox() if back != null and not back.is_null() else AABB()
		if back == null or back.is_null() or int(back.solid_count()) != 1 or absf(box.size.length() - diagonal) > 0.1 * diagonal or box.get_center().distance_to(centre) > 0.1 * diagonal:
			made["shape"] = null
			made["cage"] = {}
			made["error"] = "The solid made of %s could not be brought back to its size (%s). %s" % [BODY, str(kernel.get_last_error()), OTHER_HINT]
			return made
		made["shape"] = back
	report["ms"] = (Time.get_ticks_usec() - started) / 1000.0
	return made


## convert() on the mesh as it is. unit: the body's meters for one of this mesh's (lengths in
## sentences are the body's).
static func _convert_at(mesh: RefCounted, options: Dictionary, unit: float) -> Dictionary:
	var started := Time.get_ticks_usec()
	var limit := clampf(float(options.get("time_limit", 20.0)), 0.05, 120.0)
	var phases := {}
	var last := [started]
	var mark := func(name: String) -> void:
		var now := Time.get_ticks_usec()
		phases[name] = (now - int(last[0])) / 1000.0
		last[0] = now
	var left := func() -> float:
		return limit - (Time.get_ticks_usec() - started) / 1e6
	var report := {"op": "convert_organic", "phases": phases}
	var fail := func(text: String) -> Dictionary:
		report["ms"] = (Time.get_ticks_usec() - started) / 1000.0
		return {"error": text, "warning": "", "cage": {}, "shape": null, "report": report}
	if not ClassDB.class_exists("CadSubD"):
		return fail.call("The Holo Forge kernel is not loaded")
	var problem := refusal(mesh, options)
	if problem != "":
		return fail.call(problem)
	var faces := int(roundf(float(options.get("faces", DEFAULT_FACES))))
	var diagonal: float = (mesh.bbox() as AABB).size.length()
	var tolerance := float(options.get("tolerance", diagonal / 500.0))
	var after := seconds_after_remesh(faces)
	report["estimate"] = after
	report["tolerance"] = tolerance
	if after > limit:
		return fail.call("%s would take about %s s on %s (limit %s s). %s" % [TITLE, _plain(after), BODY, _plain(limit), TIME_HINT])

	# 1. Even triangles, about two for each cage face: an edge length from the body's area.
	var area := float(mesh.area())
	var edge := sqrt(4.0 * area / (sqrt(3.0) * TRIANGLES_PER_FACE * faces))
	# (Just inside Remesh's own range: a few faces on a long body ask for longer edges than it takes.)
	edge = clampf(edge, diagonal * MIN_EDGE_FRACTION * 1.001, diagonal * MAX_EDGE_FRACTION * 0.999)
	var remeshed: RefCounted = mesh.remesh({
		"mode": "uniform", "edge_length": edge, "iterations": 10, "keep_sharp": false, "keep_boundary": true, "keep_groups": false,
		"time_limit": maxf(left.call() - after, 0.05),
	})
	mark.call("remesh")
	if remeshed == null or remeshed.is_null():
		var why := str(mesh.get_last_error()).replace("The mesh", BODY).replace("this mesh", BODY)
		if _is_time_refusal(why):
			# Remesh's own sentence, with what helps here.
			var cut := why.find("). ")
			var stop := why.find("was stopped.")
			if cut >= 0:
				why = why.substr(0, cut + 2)
			elif stop >= 0:
				why = why.substr(0, stop + 12)
			return fail.call("%s (the first step of %s) %s" % [why, TITLE, REDUCE_HINT])
		# (Remesh speaks of its own fields; here only Target Cage Faces sets the triangles.)
		if why.contains("moved the surface"):
			return fail.call("A cage of %s faces cannot follow %s: its even triangles would lie too far off it. Raise Target Cage Faces, or use Convert Mesh: Faceted." % [_commas(faces), BODY])
		if why.contains("Stitch and Remove"):
			return fail.call(why)
		return fail.call("%s could not remesh %s into the even triangles of a cage of %s faces. %s" % [TITLE, BODY, _commas(faces), OTHER_HINT])
	report["edge_length"] = edge
	report["remesh_triangles"] = int(remeshed.triangle_count())
	if bool(remeshed.is_surface()) or int(remeshed.solid_count()) != 1:
		return fail.call("%s could not remesh %s into one closed surface. %s" % [TITLE, BODY, OTHER_HINT])

	# 2. The cage: the triangles paired into quads.
	var arrays: Dictionary = remeshed.get_arrays()
	var positions: PackedVector3Array = arrays.positions
	var indices: PackedInt32Array = arrays.indices
	var points := PackedFloat64Array()
	points.resize(positions.size() * 3)
	for i in positions.size():
		points[3 * i] = positions[i].x
		points[3 * i + 1] = positions[i].y
		points[3 * i + 2] = positions[i].z
	var polygons := []
	for t in range(0, indices.size() - 2, 3):
		# (get_arrays speaks Godot's clockwise order; a cage's faces run counter-clockwise.)
		polygons.append(PackedInt32Array([indices[t], indices[t + 2], indices[t + 1]]))
	var built := FORM_FIT.mesh_to_cage(points, polygons, {"merge": true, "tolerance": 0.0})
	if str(built.get("error", "")) != "":
		return fail.call("%s could not make a cage of %s: %s. %s" % [TITLE, BODY, str(built.error), OTHER_HINT])
	var cage: Dictionary = built.cage
	var cage_faces := CAGE.face_count(cage)
	var cage_vertices := CAGE.vertex_count(cage)
	var quads := 0
	for n in (cage.face_counts as PackedInt32Array):
		quads += 1 if n == 4 else 0
	report["cage_faces"] = cage_faces
	report["cage_vertices"] = cage_vertices
	report["cage_quads"] = quads
	mark.call("cage")
	var many := cage_faces > 2 * faces
	if cage_faces > MAX_FACES:
		return fail.call("The cage of %s came out with %s faces; %s takes up to %s. Lower Target Cage Faces." % [BODY, _commas(cage_faces), TITLE, _commas(MAX_FACES)])
	var still := seconds_after_remesh(cage_faces)
	if still > left.call():
		# (An estimate, made before the steps that cannot be stopped: nothing ran that long.)
		return fail.call("%s would take about %s s on %s (limit %s s). %s" % [TITLE, _plain(limit - float(left.call()) + still), BODY, _plain(limit), TIME_HINT])

	# 3. The fit: the smooth surface through the cage's points, which lie on the body.
	var free := PackedInt32Array()
	free.resize(cage_vertices)
	var targets := {}
	var cage_points: PackedFloat64Array = cage.positions
	for v in cage_vertices:
		free[v] = v
		targets[v] = cage_points.slice(3 * v, 3 * v + 3)
	var fitted := FORM_FIT.solve_limit_targets(cage, targets, free)
	if str(fitted.get("error", "")) != "":
		return fail.call("%s could not fit the cage of %s: %s. %s" % [TITLE, BODY, str(fitted.error), OTHER_HINT])
	cage = fitted.cage
	report["fit_residual"] = float(fitted.get("residual", 0.0))
	mark.call("fit")

	# 4. The smooth surface against the body, both ways.
	var made := FORM_FIT.subd_of(cage)
	if made.has("error"):
		return fail.call("%s could not fit the cage of %s: %s." % [TITLE, BODY, str(made.error)])
	var subd: RefCounted = made.subd
	var smooth := _mesh_of(subd.tessellate({"rate": 8, "edges": false}))
	if smooth == null:
		return fail.call("%s could not measure the smooth surface of %s (%s)." % [TITLE, BODY, str(subd.get_last_error())])
	var deviation := _two_sided(smooth, mesh, maxf(left.call(), 0.05))
	mark.call("measure")
	if bool(deviation.timed_out):
		return fail.call("%s took longer than %s s and was stopped. %s" % [TITLE, _plain(limit), TIME_HINT])
	var worst := float(deviation.max)
	var allowed := 4.0 * tolerance
	report["deviation"] = {"max": worst, "mean": float(deviation.mean), "samples": int(deviation.samples), "surface_to_mesh": float(deviation.forward),
		"mesh_to_surface": float(deviation.back), "allowed": allowed}
	if not worst <= allowed:
		return fail.call("The smooth surface is up to %s away from the mesh (allowed %s). Raise Target Cage Faces or Allowed Deviation." % [_mm(worst * unit), _mm(allowed * unit)])
	var warnings := PackedStringArray()
	if many:
		warnings.append("The cage of %s has %s faces (Target Cage Faces %s): fewer would need edges longer than a fifth of the body." % [BODY, _commas(cage_faces), _commas(faces)])
	if worst > tolerance:
		warnings.append("The smooth surface is up to %s away from %s (Allowed Deviation %s)." % [_mm(worst * unit), BODY, _mm(tolerance * unit)])
	if not bool(options.get("brep", true)):
		report["ms"] = (Time.get_ticks_usec() - started) / 1000.0
		return {"error": "", "warning": "\n".join(warnings), "cage": cage, "shape": null, "report": report}

	# 5. The solid, through the Form workspace's conversion, and the checks on the solid itself.
	var converted := FORM.convert_cage(cage, "standard", str(options.get("prefix", "organic")))
	mark.call("convert")
	if str(converted.get("error", "")) != "":
		return fail.call("%s could not make a solid of the smooth surface of %s: %s. %s" % [TITLE, BODY, str(converted.error), OTHER_HINT])
	var shapes: Array = converted.shapes
	var notes := FORM.conversion_notes(converted.report as Dictionary)
	var shape: RefCounted = shapes[0] if shapes.size() == 1 else null
	if shape == null or bool(shape.is_surface()) or int(shape.solid_count()) != 1:
		return fail.call("The smooth surface of %s did not close one solid (%d pieces). Use Convert Mesh: Faceted." % [BODY, shapes.size()])
	for note in notes:
		if str(note).contains("failed the B-rep validity check"):
			return fail.call("The solid made of %s failed the solid check. %s" % [BODY, OTHER_HINT])
		warnings.append("%s: %s" % [BODY, note] if not str(note).begins_with("converted by") else "%s was %s." % [BODY, note])
	var linear := clampf(diagonal * DISPLAY_FRACTION, 0.00001, 0.01)
	var drawn: Dictionary = shape.tessellate(linear, DISPLAY_ANGLE)
	var undrawn: Array = Array(drawn.get("warnings", []))
	if not undrawn.is_empty():
		return fail.call("%d face%s of the solid made of %s would be drawn wrong (%s). %s" % [undrawn.size(), "" if undrawn.size() == 1 else "s", BODY, str(undrawn[0]), OTHER_HINT])
	var solid_mesh := _mesh_of(drawn)
	if solid_mesh == null:
		return fail.call("The solid made of %s has no triangles to check (internal error). Please report it." % BODY)
	var solid_deviation := _two_sided(solid_mesh, mesh, maxf(left.call(), 0.05))
	mark.call("check")
	if bool(solid_deviation.timed_out):
		return fail.call("%s took longer than %s s and was stopped. %s" % [TITLE, _plain(limit), TIME_HINT])
	# (The solid's drawn triangles lie up to the viewport's deflection off its faces.)
	var solid_worst := float(solid_deviation.max)
	if not solid_worst <= allowed + linear:
		return fail.call("The solid is up to %s away from the mesh (allowed %s). Raise Target Cage Faces or Allowed Deviation." % [_mm(solid_worst * unit), _mm(allowed * unit)])
	# Its volume, from its drawn triangles (the exact volume of a few thousand spline faces takes
	# longer than the whole convert): a surface that stays within the allowed deviation moves
	# the volume by at most that times the body's area. Only when the drawn triangles close
	# (they do unless the mesher left a crack, which the distances above would not show).
	var mesh_volume := float(mesh.volume())
	var welded: RefCounted = solid_mesh.welded()
	var volume := float(welded.volume()) if welded != null and not bool(welded.is_surface()) else NAN
	mark.call("volume")
	if is_nan(volume):
		warnings.append("The volume of the solid made of %s was not checked (its drawn triangles do not close)." % BODY)
	elif not absf(volume - mesh_volume) <= MAX_VOLUME_CHANGE * absf(mesh_volume):
		# (A wide Allowed Deviation lets a thin body lose a quarter of itself and stay inside it.)
		return fail.call("The solid's volume is off by %s %% from %s's (limit %s %%). Lower Allowed Deviation or raise Target Cage Faces." % [
			_plain(100.0 * absf(volume - mesh_volume) / maxf(absf(mesh_volume), 1e-30)), BODY, _plain(100.0 * MAX_VOLUME_CHANGE)])
	elif not absf(volume - mesh_volume) <= (allowed + linear) * area + 1e-3 * absf(mesh_volume):
		return fail.call("The solid's volume is off by %s %% from %s's, more than the Allowed Deviation explains. %s" % [
			_plain(100.0 * absf(volume - mesh_volume) / maxf(absf(mesh_volume), 1e-30)), BODY, OTHER_HINT])
	(report.deviation as Dictionary)["solid_to_mesh"] = float(solid_deviation.forward)
	(report.deviation as Dictionary)["mesh_to_solid"] = float(solid_deviation.back)
	report["volume_change"] = (volume - mesh_volume) / absf(mesh_volume) if mesh_volume != 0.0 and not is_nan(volume) else 0.0
	report["output"] = {"faces": int(shape.face_count()), "solids": 1, "closed": true, "valid": true, "volume": volume if not is_nan(volume) else 0.0}
	report["ms"] = (Time.get_ticks_usec() - started) / 1000.0
	return {"error": "", "warning": "\n".join(warnings), "cage": cage, "shape": shape, "report": report}


## A CadMesh of a tessellation's triangles ({"positions", "indices"} in Godot's order), or null.
static func _mesh_of(tess: Dictionary) -> RefCounted:
	var positions: Variant = tess.get("positions")
	var indices: Variant = tess.get("indices")
	if not positions is PackedVector3Array or not indices is PackedInt32Array or (indices as PackedInt32Array).is_empty():
		return null
	var out: RefCounted = ClassDB.instantiate("CadMesh") if ClassDB.class_exists("CadMesh") else null
	if out == null or not out.set_arrays(positions, indices, PackedInt32Array(), PackedStringArray(), "godot"):
		return null
	return out


## The sampled distance between two meshes, both ways: {"max", "mean", "forward" (a to b),
## "back" (b to a), "samples", "timed_out"}.
static func _two_sided(a: RefCounted, b: RefCounted, seconds: float) -> Dictionary:
	var started := Time.get_ticks_usec()
	var forward: Dictionary = a.distance_to(b, SAMPLES, seconds)
	var rest := maxf(seconds - (Time.get_ticks_usec() - started) / 1e6, 0.05)
	var back: Dictionary = b.distance_to(a, SAMPLES, rest)
	var timed_out := forward.is_empty() or back.is_empty() or bool(forward.get("timed_out", false)) or bool(back.get("timed_out", false))
	return {
		"max": maxf(float(forward.get("max", INF)), float(back.get("max", INF))), "mean": 0.5 * (float(forward.get("mean", 0.0)) + float(back.get("mean", 0.0))),
		"forward": float(forward.get("max", INF)), "back": float(back.get("max", INF)),
		"samples": int(forward.get("samples", 0)) + int(back.get("samples", 0)), "timed_out": timed_out,
	}


static func _is_time_refusal(error: String) -> bool:
	return (error.contains("would take about") and error.contains("(limit")) or (error.contains("took longer than") and error.contains("was stopped"))


## A length in millimeters ("0.25 mm").
static func _mm(meters: float) -> String:
	return _plain(meters * 1000.0) + " mm"


## A number with about four significant digits and no trailing zeros.
static func _plain(value: float) -> String:
	if value == 0.0 or not is_finite(value):
		return "0"
	var decimals := clampi(3 - int(floor(log(absf(value)) / log(10.0))), 0, 9)
	var text := String.num(value, decimals)
	if text.contains("."):
		text = text.rstrip("0").rstrip(".")
	return "0" if text == "-0" or text == "" else text


## 20480 as "20,480".
static func _commas(value: int) -> String:
	var digits := str(absi(value))
	var out := ""
	while digits.length() > 3:
		out = "," + digits.substr(digits.length() - 3) + out
		digits = digits.substr(0, digits.length() - 3)
	return ("-" if value < 0 else "") + digits + out
