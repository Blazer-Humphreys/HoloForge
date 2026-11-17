@tool
extends RefCounted
## Convert Mesh (the Mesh workspace): mesh bodies turned into B-rep bodies. Feature type "mesh",
## options.method convert_faceted | convert_prismatic | convert_organic; core/features/mesh.gd
## sends every method that starts with "convert_" to build() here.
##
## Methods (options hold picks and choices; lengths and numbers are inputs, read only when the
## feature has them: a missing input leaves the default):
##   convert_faceted    bodies (mesh bodies), merge_flat [true], result; input flat_tolerance
##                      [D x 1e-6, 0 .. D / 100]. Every triangle a flat face, every flat patch
##                      of a face group one face (CadMesh.to_faceted). An open body gives a
##                      surface body, with a warning.
##   convert_prismatic  bodies, allow_spheres [true], result; input tolerance [D / 1000,
##                      D x 1e-6 .. D / 20]. A plane, cylinder or sphere per face group
##                      (CadMesh.to_prismatic). Needs a closed body with face groups.
##   convert_organic    body (one mesh body), output brep | form_body [brep], result; inputs
##                      faces [500, 24 .. 5,000] and tolerance [D / 500, more than 0 .. D / 10].
##                      A smooth solid through a Form cage (core/mesh/organic.gd). Experimental.
##                      Output Form Body takes bodies of FORM_BODY_MIN and more.
## result: new_body [default: the converted body is added, and the mesh body is hidden when the
## tool is confirmed] | replace (the mesh body leaves the model). The new bodies are B-rep
## bodies; they are registered and listed in options.outputs as the Mesh tools' are
## (core/features/mesh.gd: on a full-time build; a preview shows them under passing ids).
##
## A Faceted body of a mesh that crosses itself crosses itself the same way: the feature warns
## with the Mesh tools' own sentence (core/features/mesh.gd crossing_note).
##
## Every converted body is checked in the kernel before it comes back (closed, valid, volume,
## every face drawable, and for Prismatic and Organic its distance from the mesh both ways); a
## body that fails is refused with what is off and by how much, never handed over.
##
## Results, refusals included, are kept by content (clear_cache() forgets them), so a rebuild
## that changes nothing converts nothing and gives the very same shapes back. Over KEPT bodies or
## KEPT_BYTES the least recently used are let go, but never one a rebuild's bodies still hold (the
## design open, or the one being built): the caps bound what only the cache holds. A body whose
## kept result was let go is converted again and its feature says why (OVER_KEPT). A refusal for
## lack of time is kept too, and tried again only when there is clearly more time than it had.
##
## Time: a feature's bodies share its time limit, so a feature takes no longer than the limit the
## panel names. Each body gets what the bodies before it left; a kept body is charged, on a
## full-time build, what it took when it was converted, so a design builds the same from scratch
## as in the session (a kept result that took clearly longer than the body has now is refused
## with the time sentence, as a build from scratch would refuse it). A body refused for time
## after others used some is told so (BODIES_BEFORE). A preview charges a kept body nothing.
##
## Output Form Body: a timeline feature cannot add another feature while it is rebuilt, so the
## feature itself shows the solid of its cage, and form_body(doc, feature) swaps it for a Form
## feature holding the cage (one undo step when the tool's OK calls it before committing).
##
## reports (core/features/mesh.gd `reports[feature.id]`): "op", "stat" (one line per body),
## "warnings", "bodies" (each body's kernel report: "output" {"faces", "solids", "volume", ...},
## "deviation", "checks", "phases"); no "input"/"output" of its own (a converted body has faces,
## not triangles).

const UTIL := preload("res://addons/holo_forge/core/features/util.gd")
const MESH := preload("res://addons/holo_forge/core/features/mesh.gd")
const MESH_BODY := preload("res://addons/holo_forge/core/mesh/mesh_body.gd")
const ORGANIC := preload("res://addons/holo_forge/core/mesh/organic.gd")
const FORM := preload("res://addons/holo_forge/core/features/form.gd")
const CAGE := preload("res://addons/holo_forge/core/form/cage.gd")

const METHODS := ["convert_faceted", "convert_prismatic", "convert_organic"]
const TITLES := {"convert_faceted": "Convert Mesh: Faceted", "convert_prismatic": "Convert Mesh: Prismatic", "convert_organic": "Convert Mesh: Organic"}
const RESULTS := ["new_body", "replace"]
const OUTPUTS := ["brep", "form_body"]
const NOT_A_MESH := "%s is not a mesh body: there is nothing to convert."
const FORM_NOTE := "The Form Body output is not in the timeline yet: %s shows its solid."
## How many converted bodies are kept, and how many bytes of them (as core/features/mesh.gd keeps
## its meshes). A B-rep body has no byte count of its own: BYTES_PER_FACE for each of its faces
## (a faceted face with its edges, corners and drawn triangle is about that).
const KEPT := 256
const KEPT_BYTES := 512 * 1024 * 1024
const BYTES_PER_FACE := 4096
## A refusal for lack of time is tried again only with clearly more time than it had: this
## much more, and a little. (A feature gives each body what is left of its time, a hair under
## its limit: without the margin a time-out was converted again on every rebuild.)
const RETRY_FACTOR := 1.1
const RETRY_SECONDS := 0.05
## Behind a refusal for lack of time when the feature's bodies before this one used part of its
## time (the limit the sentence names is then what they left).
const BODIES_BEFORE := " (The bodies before it used the rest of the feature's %s s: pick fewer bodies at once.)"
## What helps when a body has too little time, as each convert says it.
const TIME_HINTS := {"convert_faceted": "Reduce the body first.", "convert_prismatic": "Combine face groups to make fewer surfaces, or use Faceted.", "convert_organic": "Lower Target Cage Faces."}
## Told on a feature whose body had to be converted again because its kept result was let go
## (by KEPT or KEPT_BYTES, named; only results no rebuild's bodies hold are let go).
const OVER_KEPT := "%s was converted again: its kept result had been let go to stay within %s."
## References to a kept body that are the cache's own when _held_elsewhere() looks (the entry's,
## and the variable's there).
const HELD_BY_CACHE := 2
## Output Form Body is offered for bodies this large and more (their diagonal). Organic itself
## converts a smaller body on an enlarged copy, but a Form feature rebuilds its cage at the
## body's own size, and Form's conversion of a cage under about a millimeter takes tens of
## seconds and cannot be stopped (0.5 s at 3.5 mm, 3.3 s at 0.9 mm, 29 s at 0.35 mm).
const FORM_BODY_MIN := 0.002
const FORM_BODY_SMALL := "%s is %s across: a form body that small rebuilds too slowly (Form takes bodies of %s and more). Use Output: Solid Body."

## Converted bodies by content: key -> {"shape", "cage", "error", "warning", "report", "limit"},
## least recently used first.
static var _kept := {}
static var _kept_bytes := 0
## Keys of results pushed out by KEPT or KEPT_BYTES (not of ones dropped for any other reason):
## a body asked for again under such a key is one the design converts on every rebuild.
static var _pushed_out := {}
const PUSHED_OUT_KEPT := 4096
## Keys of the bodies the feature being built has converted so far: until the feature is done
## nothing else holds them, and they are not let go (a feature of 259 bodies let its first 3 go,
## so every next rebuild converted those again).
static var _building := {}
## How often a kept result answered (tests read it).
static var cache_hits := 0
## The cage of each convert_organic feature's last build (feature id -> cage), for form_body().
static var _cages := {}


static func build(feature: Resource, ctx: Dictionary) -> String:
	if not MESH_BODY.available() or not ClassDB.class_exists("CadShape"):
		return MESH_BODY.KERNEL_MISSING
	var method := str(feature.options.get("method", ""))
	if not METHODS.has(method):
		return "The Mesh tool '%s' is not available in this build" % method
	var r := UTIL.Reader.new(feature, ctx)
	var run := MESH.Run.new(r, MESH.time_limit(ctx))
	return MESH._finish(run, _convert(run, method))


## Forgets every kept result (tests time the converts from scratch with it).
static func clear_cache() -> void:
	_kept.clear()
	_kept_bytes = 0
	_pushed_out.clear()
	_cages.clear()
	cache_hits = 0


## Adds a Convert Mesh feature for mesh bodies (ids), as its panel writes it. options: merge_flat,
## allow_spheres, output, result; inputs: {key: [expression, kind]} ("flat_tolerance" and
## "tolerance" are lengths, "faces" a number). Returns {"feature", "error"}.
static func add_convert(doc: Resource, method: String, body_ids: Array, options := {}, inputs := {}) -> Dictionary:
	if not METHODS.has(method):
		return {"feature": null, "error": "The Mesh tool '%s' is not available in this build" % method}
	if body_ids.is_empty():
		return {"feature": null, "error": "Select a mesh body"}
	var picks := []
	for body_id in body_ids:
		picks.append({"kind": "body", "body": str(body_id)})
	var settings := {"method": method, "result": "new_body"}
	settings["body" if method == "convert_organic" else "bodies"] = picks
	settings.merge(options, true)
	var made := {}
	for key in inputs:
		made[key] = doc.make_input(str(inputs[key][0]), str(inputs[key][1]))
	var label := str(TITLES[method]).replace("Convert Mesh: ", "Convert")
	return {"feature": doc.add_feature("mesh", label, made, settings), "error": ""}


## Output Form Body: swaps a built convert_organic feature for a Form feature that holds its
## cage, in the same place in the timeline; the body the feature made becomes the form's body.
## Call it after a full-time rebuild of the feature that gave no error (the tool's OK, before the
## change is committed, so it is one undo step). The mesh body stays as the feature left it for
## New Body (hidden); for Replace it is hidden too, since a Form feature removes nothing.
## Returns {"feature" (the Form feature), "body", "error", "note"}.
static func form_body(doc: Resource, feature: Resource) -> Dictionary:
	if doc == null or feature == null or str(feature.type) != "mesh" or str(feature.options.get("method", "")) != "convert_organic":
		return {"feature": null, "body": "", "error": "Only a Convert Mesh: Organic feature can become a form body", "note": ""}
	var cage: Variant = _cages.get(feature.id)
	var outputs: Array = feature.options.get("outputs", [])
	if not cage is Dictionary or (cage as Dictionary).is_empty() or outputs.is_empty():
		return {"feature": null, "body": "", "error": "%s has not been converted yet" % feature.label, "note": ""}
	var at: int = doc.feature_index(feature.id)
	if at < 0:
		return {"feature": null, "body": "", "error": "%s is not in the timeline" % feature.label, "note": ""}
	var body_id := str(outputs[0])
	var rollback: int = doc.rollback
	var options := FORM.new_options()
	options["bodies"] = {body_id: CAGE.copy(cage)}
	var form: Resource = doc.add_feature("form", "Form", {}, options)
	# add_feature put it at the timeline marker: it takes the convert feature's place.
	doc.features.remove_at(doc.feature_index(form.id))
	at = doc.feature_index(feature.id)
	doc.features[at] = form
	doc.rollback = rollback
	if doc.bodies.has(body_id):
		doc.bodies[body_id]["feature"] = form.id
	var note := ""
	for pick in feature.options.get("body", []):
		if pick is Dictionary and doc.bodies.has(str(pick.get("body", ""))):
			var source := str(pick.body)
			if str(feature.options.get("result", "new_body")) == "replace":
				note = "%s is hidden, not removed: a form body leaves the bodies before it as they are." % doc.body_name(source)
			doc.bodies[source]["visible"] = false
	_cages.erase(feature.id)
	_cages[form.id] = cage
	return {"feature": form, "body": body_id, "error": "", "note": note}


# --- The build -------------------------------------------------------------------------------

static func _convert(run: MESH.Run, method: String) -> String:
	var r := run.r
	var feature := run.feature
	var ctx := run.ctx
	var organic := method == "convert_organic"
	var targets := _targets(run, r.refs("body" if organic else "bodies"))
	if run.failed():
		return run.problem()
	if organic and targets.size() != 1:
		return "%s takes one mesh body at a time." % TITLES[method]
	var result := str(r.opt("result", "new_body"))
	if not RESULTS.has(result):
		return "Result must be New Body or Replace."
	# What is asked of the kernel (everything that changes the result).
	var asked := {}
	match method:
		"convert_faceted":
			var merge: Variant = r.opt("merge_flat", true)
			if not merge is bool:
				return "Merge Flat Face Groups must be on or off."
			asked["merge_flat"] = merge
			if merge and r.has_input("flat_tolerance"):
				asked["flat_tolerance"] = r.num("flat_tolerance")
		"convert_prismatic":
			var spheres: Variant = r.opt("allow_spheres", true)
			if not spheres is bool:
				return "Allow Spheres must be on or off."
			asked["allow_spheres"] = spheres
			if r.has_input("tolerance"):
				asked["tolerance"] = r.num("tolerance")
		"convert_organic":
			var output := str(r.opt("output", "brep"))
			if not OUTPUTS.has(output):
				return "Output must be Solid Body or Form Body."
			if output == "form_body":
				var across: float = ((targets[0].mesh as RefCounted).bbox() as AABB).size.length()
				if across < FORM_BODY_MIN:
					return FORM_BODY_SMALL % [targets[0].name, MESH._mm(across), MESH._mm(FORM_BODY_MIN)]
			if r.has_input("faces"):
				asked["faces"] = r.num("faces")
			if r.has_input("tolerance"):
				asked["tolerance"] = r.num("tolerance")
	if not r.ok():
		return r.error
	var made := []
	# Seconds the bodies so far are charged against the feature's time (see _one).
	var spent := [0.0]
	# (The bodies this feature has converted so far are held only here until it is done.)
	_building.clear()
	for target in targets:
		var kept := _one(run, method, target, asked, spent)
		if run.failed():
			_building.clear()
			return run.problem()
		made.append(kept)
	_building.clear()
	# Every body converted: the new bodies go in (nothing changes unless all of them worked).
	for k in targets.size():
		var target: Dictionary = targets[k]
		var kept: Dictionary = made[k]
		var shape: RefCounted = kept.shape
		var source := str(target.id)
		var before := ((feature.options.get("made", {}) as Dictionary).get(source, []) as Array).size()
		var ids := MESH._made_ids(run, source, 1, source, ["%s %s" % [target.name, "Surface" if bool(shape.is_surface()) else "Solid"]])
		var out_id := str(ids[0])
		ctx.bodies[out_id] = {"id": out_id, "shape": shape, "feature": feature.id}
		run.outputs.append(out_id)
		if result == "replace":
			ctx.bodies.erase(source)
		elif run.records and ((feature.options.get("made", {}) as Dictionary).get(source, []) as Array).size() > before and run.doc.bodies.has(source):
			# New Body: the mesh body is hidden once, when its converted body is first made.
			run.doc.bodies[source]["visible"] = false
		run.kept.append({"report": kept.report})
		run.stat.append(_stat(method, str(target.name), shape, kept.report))
		if organic:
			_cages[feature.id] = kept.get("cage", {})
			if str(r.opt("output", "brep")) == "form_body":
				run.note(FORM_NOTE % feature.label)
	return ""


## The mesh bodies picked, in pick order: [{"id", "name", "mesh"}]. A component stands for its
## mesh bodies. Fails the run when a body is gone, is not a mesh body, or nothing is picked.
static func _targets(run: MESH.Run, picks: Array) -> Array:
	var targets := []
	var seen := {}
	for pick in picks:
		if not pick is Dictionary:
			continue
		var ids := []
		if str(pick.get("kind", "")) == "component":
			for body_id in run.ctx.bodies:
				if run.doc.body_component(body_id) == str(pick.get("component", "")) and MESH_BODY.is_mesh(run.ctx.bodies[body_id]):
					ids.append(str(body_id))
		else:
			ids.append(str(pick.get("body", "")))
		for id in ids:
			if seen.has(id):
				continue
			if not run.ctx.bodies.has(id):
				run.fail("Body %s no longer exists" % run.body_name(id))
				return []
			var found: Dictionary = run.ctx.bodies[id]
			if not MESH_BODY.is_mesh(found):
				run.fail(NOT_A_MESH % run.body_name(id))
				return []
			seen[id] = true
			targets.append({"id": id, "name": run.body_name(id), "mesh": found.shape})
	if targets.is_empty() and not run.failed():
		run.fail("Select a mesh body")
	return targets


## Converts one body, through the kept results: {"shape", "cage", "error", "warning", "report"}.
## A refusal fails the run with the kernel's sentence and warnings join the run's notes, both
## with the body's name in them.
##
## Time: the feature's bodies share its limit. A body gets the limit less what the bodies before
## it are charged (spent[0]), and never more than is left of the feature's time. A body converted
## now is charged what it took; on a full-time build a kept one is charged what it took when it
## was converted, and a kept result that took clearly longer than the body has now is refused as
## a build from scratch would refuse it. So a feature builds the same from scratch as in the
## session, and takes no longer than its limit. (A preview charges a kept body nothing: it
## answers at once.)
static func _one(run: MESH.Run, method: String, target: Dictionary, asked: Dictionary, spent: Array) -> Dictionary:
	var mesh: RefCounted = target.mesh
	var name := str(target.name)
	var what := asked.duplicate()
	if method == "convert_organic":
		# (The faces of an Organic solid are named after the feature and the body.)
		what["prefix"] = "%s/%s" % [run.feature.id, target.id]
	var key := MESH.cache_key(method, what, [str(mesh.digest())])
	var kept: Dictionary = _kept.get(key, {})
	_building[key] = true
	var before := float(spent[0])
	var seconds := minf(minf(run.limit - before, run.left()), 120.0)
	var after_others := before > RETRY_SECONDS
	if not kept.is_empty() and str(kept.error) != "" and seconds > float(kept.limit) * RETRY_FACTOR + RETRY_SECONDS:
		# A refusal for lack of time, made with clearly less time than there is now.
		kept = {}
	var fresh := kept.is_empty()
	if seconds < 0.05 and (fresh or run.records):
		# (A kept body too, on a full-time build: from scratch it would not have started.)
		run.fail("%s took longer than %s s on its bodies and was stopped before %s. Pick fewer bodies at once." % [run.feature.label, MESH._plain(run.limit), name])
		return {}
	if fresh:
		var native := what.duplicate()
		native["time_limit"] = seconds
		native["name"] = MESH.BODY_TOKEN
		kept = {"shape": null, "cage": {}, "error": "", "warning": "", "report": {}, "limit": seconds, "took": 0.0}
		if _pushed_out.has(key):
			run.note(OVER_KEPT % [name, _cap_words(str(_pushed_out[key]))])
			_pushed_out.erase(key)
		var started := Time.get_ticks_usec()
		match method:
			"convert_faceted":
				kept.shape = mesh.to_faceted(native)
			"convert_prismatic":
				kept.shape = mesh.to_prismatic(native)
			"convert_organic":
				var made := ORGANIC.convert(mesh, native)
				kept.shape = made.shape
				kept.cage = made.cage
				kept.error = str(made.error)
				kept.warning = str(made.warning)
				kept.report = made.report
		if method != "convert_organic":
			kept.report = mesh.get_last_report()
			kept.warning = str(mesh.get_last_warning())
			if kept.shape == null or kept.shape.is_null():
				kept.shape = null
				kept.error = str(mesh.get_last_error())
		# (The shared time sentences say "on this mesh": the body is named instead.)
		kept.error = str(kept.error).replace(" s on this mesh (limit ", " s on %s (limit " % MESH.BODY_TOKEN)
		if kept.shape == null and str(kept.error) == "":
			kept.error = "%s made nothing of %s." % [TITLES[method], MESH.BODY_TOKEN]
		# A refusal that is not about time holds whatever the time limit.
		if str(kept.error) != "" and not MESH.is_time_refusal(str(kept.error)):
			kept.limit = 120.0
		if method == "convert_faceted" and str(kept.error) == "":
			# A faceted body is the mesh, face for triangle: where the mesh crosses itself, so
			# does the body (two overlapping solids, a folded shell). The same sentence the Mesh
			# tools say; the test is part of what this body costs.
			MESH._cross(run, mesh, name)
		kept.took = (Time.get_ticks_usec() - started) / 1e6
		_keep(key, kept)
	else:
		# Most recently used last.
		_kept.erase(key)
		_kept[key] = kept
		cache_hits += 1
		if method == "convert_faceted" and str(kept.error) == "":
			MESH._cross(run, mesh, name)
		var took := float(kept.get("took", 0.0))
		if run.records and str(kept.error) == "" and took > seconds * RETRY_FACTOR + RETRY_SECONDS:
			# Converted with more time than the body has now (the bodies before it are charged the
			# rest): refused, as a build from scratch would refuse it.
			var late := "%s would take about %s s on %s (limit %s s). %s" % [TITLES[method], MESH._plain(took), MESH.BODY_TOKEN, MESH._plain(seconds), TIME_HINTS[method]]
			if after_others:
				late += BODIES_BEFORE % MESH._plain(run.limit)
			run.fail(MESH.named(late, name))
			return kept
	spent[0] = before + (float(kept.get("took", 0.0)) if fresh or run.records else 0.0)
	if str(kept.error) != "":
		var text := str(kept.error)
		if MESH.is_time_refusal(text) and after_others and float(kept.limit) < run.limit - 0.05:
			# (The limit the kernel names is what the bodies before this one left.)
			text += BODIES_BEFORE % MESH._plain(run.limit)
		run.fail(MESH.named(text, name))
		return kept
	for line in str(kept.warning).split("\n", false):
		run.note(MESH.named(line.strip_edges(), name))
	return kept


## Keeps a result. Over KEPT bodies or KEPT_BYTES the least recently used results are let go,
## but never one whose body is still held elsewhere (by the bodies of a rebuild: the design the
## user has open, or the one being built): letting it go frees nothing, and the next rebuild of
## the same design would convert it again (five large plates over 512 MB converted each other out
## on every rebuild, each in turn). So the caps bound what only this cache holds.
static func _keep(key: String, kept: Dictionary) -> void:
	if _kept.has(key):
		_kept_bytes -= int(_kept[key].get("bytes", 0))
		_kept.erase(key)
	var shape: RefCounted = kept.get("shape")
	kept["bytes"] = int(shape.face_count()) * BYTES_PER_FACE if shape != null else 0
	_kept[key] = kept
	_kept_bytes += int(kept.bytes)
	if _kept.size() <= KEPT and _kept_bytes <= KEPT_BYTES:
		return
	for oldest in _kept.keys():
		var over_bytes := _kept_bytes > KEPT_BYTES
		if not over_bytes and _kept.size() <= KEPT:
			break
		# The newest entry always stays, whatever its size.
		if oldest == key:
			continue
		var entry: Dictionary = _kept[oldest]
		if _held_elsewhere(entry) or _building.has(oldest):
			continue
		_kept_bytes -= int(entry.get("bytes", 0))
		_kept.erase(oldest)
		_pushed_out[oldest] = "bytes" if over_bytes else "bodies"
		if _pushed_out.size() > PUSHED_OUT_KEPT:
			_pushed_out.erase(_pushed_out.keys()[0])


## True when something besides this cache holds the entry's converted body (a rebuild's bodies).
static func _held_elsewhere(entry: Dictionary) -> bool:
	# (The cache's entry holds one reference and this variable one; a cast would add another.)
	var shape: RefCounted = entry.get("shape")
	return shape != null and shape.get_reference_count() > HELD_BY_CACHE


## The cap that let a kept result go, in words.
static func _cap_words(cap: String) -> String:
	return "%d MB of kept results" % (KEPT_BYTES / (1024 * 1024)) if cap == "bytes" else "%d kept results" % KEPT


## One line for the panel's stat row: what the body became.
static func _stat(method: String, name: String, shape: RefCounted, report: Dictionary) -> String:
	var output: Dictionary = report.get("output", {})
	var deviation: Dictionary = report.get("deviation", {})
	var faces := int(output.get("faces", shape.face_count()))
	var kind := "surface body" if bool(shape.is_surface()) else "solid"
	match method:
		"convert_faceted":
			return "%s: a %s of %s faces (%s merged flat ones)" % [name, kind, _commas(faces), _commas(int(output.get("merged_faces", 0)))]
		"convert_prismatic":
			return "%s: a solid of %d faces (%d flat, %d round), up to %s from the mesh" % [
				name, faces, int(output.get("planes", 0)), int(output.get("cylinders", 0)) + int(output.get("spheres", 0)), MESH._mm(float(deviation.get("max", 0.0)))]
	return "%s: a smooth solid of %s faces from a cage of %s, up to %s from the mesh" % [
		name, _commas(faces), _commas(int(report.get("cage_faces", 0))), MESH._mm(float(deviation.get("max", 0.0)))]


## 20480 as "20,480".
static func _commas(value: int) -> String:
	var digits := str(absi(value))
	var out := ""
	while digits.length() > 3:
		out = "," + digits.substr(digits.length() - 3) + out
		digits = digits.substr(0, digits.length() - 3)
	return ("-" if value < 0 else "") + digits + out
