@tool
extends RefCounted
## Mesh features (the Mesh workspace): feature type "mesh", one method per tool in options.method.
##
## Body entries of mesh bodies are {"id", "shape": CadMesh, "feature", "kind": "mesh"}
## (core/mesh/mesh_body.gd). A CadMesh never changes: every method makes a new one.
##
## Methods:
##   tessellate   options bodies (B-rep body picks), quality (low | medium | high | very_high |
##                custom), relative (custom: the deviation is relative to each face's size),
##                keep_original [true], outputs (the mesh body ids, one per picked body, filled in
##                on the first build); inputs linear (Surface Deviation, a length) and angular
##                (Normal Deviation, an angle) for custom. Each picked body gives a mesh body with
##                one face group per B-rep face, named after the face
##                (CadMesh.group_name_for). The kernel refuses a result that isn't closed for a
##                solid, or whose volume is more than 1 % off.
## The tools (options hold picks and choices; lengths, angles and numbers are inputs, read only
## when the tool's choices use them; an input that is missing leaves the kernel's own default):
##   section_sketch   body (one mesh body), plane (a plane or a flat face group), fit; input
##                    tolerance. The feature checks and reports the section; add_section_sketch()
##                    makes the sketch itself (a plain, fixed "sketch" feature).
##   close_holes      bodies, loops (open-loop picks; none: every hole), fill, refine; max_edges
##   stitch_remove    bodies, remove_small, remove_inner, fix_non_manifold; tolerance, min_size
##   wrap             bodies (several become one body, the first one's); detail, gap, offset
##   rebuild          bodies, algorithm (union | exact_surface); detail
##   generate_groups  bodies, algorithm (fast | accurate); angle, tolerance, min_size
##   combine_groups   groups (two or more face groups of one body)
##   create_group     selection (triangles of one body)
##   direct_edit      bodies (one), mesh (a MeshBlob: the body becomes it), input_digest, outputs
##                    and extract_<k> (bodies the tool took out); see ui/mesh_direct_edit.gd
##   remesh           bodies, selection (triangles), mode, keep_sharp, keep_boundary, keep_groups;
##                    density, edge_length, min_edge, max_edge, approx_error, iterations,
##                    sharp_angle
##   reduce           bodies, selection, target, algorithm (adaptive | fast), keep_boundary,
##                    keep_groups, keep_sharp; proportion, face_count, tolerance, sharp_angle
##   plane_cut        bodies, plane, type (trim | split_body | split_faces), flip, fill; offset
##   shell            bodies, direction, algorithm (fast | accurate); thickness, detail
##   combine          target, tools (mesh bodies, or B-rep bodies: tessellated), operation (join |
##                    cut | intersect | merge), keep_tools, new_body
##   smooth           bodies, selection, keep_volume, keep_sharp, keep_boundary; strength,
##                    iterations, sharp_angle
##   reverse_normal   mode (auto | whole | selection), bodies, selection (groups or triangles)
##   erase_fill       selection (triangles or groups of one body), fill
##   align            source (a flat face group) or points (three triangle picks with "at"), to (a
##                    plane), flip; offset
##   texture_extrude  selection (groups or triangles of one body), image (a file), mapping,
##                    invert; depth, tile, angle, detail
##   separate         bodies, by (components | groups)
##   move             the Solid Move/Copy's options (core/features/modify.gd), on mesh bodies
##   scale            bodies, point (empty: each body's middle), uniform; scale, or sx, sy, sz
##   convert_*        core/features/mesh_convert.gd, when the build has it
## A tool's Method choice is options.algorithm (options.method is the tool).
##
## What every tool keeps to:
##   - One time limit for the whole feature (time_limit(ctx)): each body's op gets what is left
##     of it, and a body there is no time left for stops the feature with a sentence.
##   - Every kernel error and warning reaches the feature with the body's name in it (named()).
##   - Results, refusals included, are kept by content (the cache), so a rebuild that changes
##     nothing computes nothing and gives the very same CadMesh instances back.
##   - Plane Cut, Separate and Combine's Merge say when a body crosses itself (their result is
##     then as wrong as the body): crossing_note().
##   - Bodies a tool adds (Separate's pieces, Plane Cut's other half, Combine's New Body) are
##     registered in the document on a full-time build (not on a command's preview, which shows
##     them under passing ids) and kept in options.made ({slot: ids}); options.outputs lists
##     every body the feature made on its last full-time build.
##   - reports[feature id]: what the op made of the bodies, for the command panel's stat row.
##
## Shared by every method (and by Insert Mesh and Move/Copy on mesh bodies):
##   time_limit(ctx)          how long an op may run in this rebuild (seconds)
##   cache_key / lookup / store / clear_cache   results kept by content
##   transformed(mesh, xform) a mesh moved, kept by content
##   output_ids / set_body / replace_body      body entries
##   blob_mesh(feature)       the CadMesh of options.mesh (a MeshBlob), checked
##   tessellated(shape, ...)  a B-rep shape as a mesh at a Tessellate preset, kept by content
##   check_warnings(...)      what a mesh that isn't closed or manifold is told

const UTIL := preload("res://addons/holo_forge/core/features/util.gd")
const MESH_BODY := preload("res://addons/holo_forge/core/mesh/mesh_body.gd")
const MESH_BLOB := preload("res://addons/holo_forge/core/mesh/mesh_blob.gd")
const REFERENCES := preload("res://addons/holo_forge/core/references.gd")
const SKETCH_DATA := preload("res://addons/holo_forge/core/sketch/sketch_data.gd")
const FEATURE := preload("res://addons/holo_forge/core/feature.gd")
## Loaded when first needed (they preload this file, or may not be in the build).
const MODIFY_PATH := "res://addons/holo_forge/core/features/modify.gd"
const CONVERT_PATH := "res://addons/holo_forge/core/features/mesh_convert.gd"

## The tools build() runs through a Run (every method but tessellate, move and convert_*).
const TOOLS := ["section_sketch", "close_holes", "stitch_remove", "wrap", "rebuild", "generate_groups", "combine_groups",
	"create_group", "direct_edit", "remesh", "reduce", "plane_cut", "shell", "combine", "smooth", "reverse_normal",
	"erase_fill", "align", "texture_extrude", "separate", "scale"]
## Stands for the body's name in what the kernel says (named() puts the name in), so a kept
## result does not hang on what the body is called.
const BODY_TOKEN := "{body}"
const NOT_A_MESH := "%s is not a mesh body. Tessellate it first (Mesh > Create > Tessellate)."
const CROSSES := "%s crosses itself, so the result may be wrong there. Rebuild it first."
const NOT_TESTED := "%s is too large to test for places where it crosses itself in %s s; if it does, the result is wrong there."
const RESULT_CROSSES := "%s crosses itself in %s place%s after %s; the result may be wrong there. Rebuild it first."
const BODIES_BEFORE := " (The bodies before it used the rest of the feature's %s s: pick fewer bodies at once.)"
const STALE_TRIANGLES := "%s: the triangle selection was made on an older version of %s; it may now cover other triangles. Reselect to be sure."
const STALE_HOLES := "%s: the holes were picked on an older version of %s; they may now be other holes. Pick them again to be sure."
const SNAPSHOT_NOTE := "%s holds a copy of %s; changes made to it earlier in the timeline no longer reach it."
## How long the test for places where a mesh crosses itself may take (as the kernel's own
## post-checks).
const SELF_INTERSECTION_SECONDS := 1.0
## Scale Mesh factors.
const SCALE_MIN := 0.001
const SCALE_MAX := 1000.0
const SCALE_LABELS := {"scale": "Scale Factor", "sx": "X Scale", "sy": "Y Scale", "sz": "Z Scale"}
## Arcs of a fitted section: at least this many points, this much turn, and no more than half a
## circle each.
const ARC_MIN_POINTS := 3
const ARC_MIN_ANGLE := 0.2617993877991494
const ARC_MAX_ANGLE := 3.141592653589793
## Option keys the tools keep for themselves (not part of what the feature asks for).
const BOOKKEEPING := ["outputs", "made", "made_with", "made_count", "picked_on"]
## What kind each option must be of, by key (checked before a tool reads any of them, so an
## option of the wrong kind is the feature's error with a sentence, never a script error).
## Switches are true or false; pick lists are lists; choices and texts are text.
const SWITCHES := ["remove_small", "remove_inner", "fix_non_manifold", "refine", "keep_sharp", "keep_boundary", "keep_groups", "keep_volume",
	"keep_tools", "new_body", "flip", "invert", "uniform", "fit", "emptied", "relative", "keep_original", "copy"]
const PICK_LISTS := ["bodies", "body", "selection", "loops", "groups", "tools", "source", "points", "to", "plane", "point", "objects", "axis",
	"from_point", "to_point", "outputs"]
const TEXTS := ["fill", "mode", "algorithm", "type", "direction", "operation", "mapping", "by", "quality", "image", "input_digest", "move_type",
	"made_with"]
const TABLES := ["made", "picked_on"]
const REPORTS_KEPT := 64

## Budgets (as N\src\mesh_budget.h).
const MAX_TRIANGLES_MESH := 2000000
const MAX_TRIANGLES_FACETED := 60000
const MAX_VOXEL_SAMPLES := 2000000
const MAX_PRISMATIC_SURFACES := 150
const MAX_PRISMATIC_TRIANGLES := 200000
const MAX_ORGANIC_FACES := 5000
const MAX_SECTION_SEGMENTS := 5000
## A command's preview runs with PREVIEW_SECONDS, its OK with OK_SECONDS.
const PREVIEW_SECONDS := 0.5
const OK_SECONDS := 20.0
## The cache holds at most this many bytes of meshes (CadMesh.memory_bytes) and this many entries.
## (Every op result, moved mesh, decoded stored mesh and inserted mesh is an entry; a design with
## more of them than the cache holds would compute all of them again on every rebuild, the oldest
## going out just before it is asked for. The bytes are what bounds the memory.)
const CACHE_BYTES := 512 * 1024 * 1024
const CACHE_ENTRIES := 256
## Tessellate presets: [the deviation as a fraction of the body's diagonal, the angle in degrees].
const TESSELLATE_PRESETS := {
	"low": [1.0 / 200.0, 30.0], "medium": [1.0 / 1000.0, 15.0], "high": [1.0 / 5000.0, 8.0], "very_high": [1.0 / 20000.0, 4.0],
}
const TESSELLATE_QUALITIES := ["low", "medium", "high", "very_high", "custom"]
## Custom Tessellate ranges: Surface Deviation 0.001 mm .. D / 10, Normal Deviation 1 .. 45 degrees.
const TESSELLATE_MIN_LINEAR := 1e-6
const TESSELLATE_MAX_LINEAR_FRACTION := 0.1
const TESSELLATE_MIN_ANGLE := 0.017453292519943295
const TESSELLATE_MAX_ANGLE := 0.7853981633974483
## How long the open-edge count for a warning may take (the linear part of CadMesh.check).
const CHECK_SECONDS := 0.25
## How long a tool may spend counting open edges for its report, over all its bodies; past it the
## report carries no counts (the panel then counts for itself).
const TALLY_SECONDS := 0.5

## Results by content: key -> {"meshes": Array of CadMesh (null where an op made none), "error",
## "warning", "report", "limit" (the time limit it was made with), "bytes"}, least recently used
## first.
static var _cache := {}
static var _cache_bytes := 0
## How often lookup() found a result (tests read it).
static var cache_hits := 0
## What the last build of each feature made, for the command panel's stat row: feature id ->
## {"op", "input": {"triangles"}, "output": {"triangles", "boundary_edges"}, "deviation": {"max"}
## (when an op measured one), "stat" (a line of the tool's own), "bodies": [each op's own
## CadMesh.get_last_report()], "warnings": [each warning the tool gave, one sentence each]}.
## "input" and "output" are missing when the open edges could not be counted in time. A feature
## that failed has no entry.
static var reports := {}
## Places where a mesh crosses itself, by content: digest -> {"count" (-1: not tested in
## "seconds"), "seconds"}.
static var _crossings := {}
## Brightness of image files, by path: {"stamp", "bytes", "width", "height", "digest"}.
static var _images := {}


## One build of a tool: the reader, the time the whole feature has, what to tell the user and
## the bodies it makes.
class Run:
	extends RefCounted
	var r: UTIL.Reader
	var feature: Resource
	var ctx: Dictionary
	var doc: Resource
	## The feature's time limit (seconds) and when it started.
	var limit := 20.0
	var started := 0
	## True on a full-time build: bodies the tool adds are registered and kept in the feature.
	var records := true
	var error := ""
	var notes := PackedStringArray()
	## The kept result of each op, in order (for the report).
	var kept := []
	var stat := PackedStringArray()
	## Every body the tool made, in order, when it is one that adds bodies.
	var outputs := []
	var creates := false
	## Triangles before and after, open edges and deviation, summed over the bodies (_tally).
	var tally := {}
	## Seconds each body's ops and tests took in this build, by body name: a later body's op gets
	## the feature's time less what the bodies before it took.
	var spent := {}
	## How many places each input body crosses itself, by body name (-1: could not be tested);
	## told once at the end, unless a sentence of the kernel's says it already.
	var crossing := {}
	## How many places a tool's result crosses itself, by body name, where the kernel counted.
	var result_crossing := {}
	## What was said of selections made on an older version of a body (it also goes behind a
	## refusal).
	var stale := PackedStringArray()
	## Picks that carry no record of their body's version, as used in this build: {"<body id>:
	## <hash of the pick>": the body's digest they stand for}; kept in options.picked_on on a
	## full-time build, so a later build can tell that the body is another one.
	var picked := {}

	func _init(reader: UTIL.Reader, seconds: float) -> void:
		r = reader
		feature = reader.feature
		ctx = reader.ctx
		doc = reader.ctx.get("doc")
		limit = seconds
		started = Time.get_ticks_usec()
		records = seconds >= OK_SECONDS - 1e-6

	## The seconds left of the feature's time.
	func left() -> float:
		return limit - (Time.get_ticks_usec() - started) / 1e6

	func fail(text: String) -> void:
		if error == "" and r.error == "":
			error = text

	func failed() -> bool:
		return error != "" or r.error != ""

	## The first problem ("" while all is well).
	func problem() -> String:
		return error if error != "" else r.error

	func note(text: String) -> void:
		if text != "" and not notes.has(text):
			notes.append(text)

	func body_name(body_id: String) -> String:
		return MESH_BODY.body_name(doc, body_id)


static func build(feature: Resource, ctx: Dictionary) -> String:
	if not MESH_BODY.available():
		return MESH_BODY.KERNEL_MISSING
	var r := UTIL.Reader.new(feature, ctx)
	var method := str(feature.options.get("method", ""))
	reports.erase(feature.id)
	var unreadable := option_problem(feature)
	if unreadable != "":
		return unreadable
	if method == "tessellate":
		return _tessellate(r)
	if method == "move":
		# Move/Copy: the Solid tool's build (it moves mesh bodies with transformed()).
		var modify: Variant = load(MODIFY_PATH)
		return str(modify._move(r)) if modify != null else "Move/Copy is not available in this build"
	if method.begins_with("convert_"):
		# Convert Mesh lives in its own file, which a build may not have.
		var convert: Variant = load(CONVERT_PATH) if ResourceLoader.exists(CONVERT_PATH) else null
		if convert == null:
			return "The Mesh tool '%s' is not available in this build" % method
		return str(convert.build(feature, ctx))
	if not TOOLS.has(method):
		return "The Mesh tool '%s' is not available in this build" % method
	var run := Run.new(r, time_limit(ctx))
	var error := ""
	match method:
		"section_sketch":
			error = _section_sketch(run)
		"close_holes":
			error = _close_holes(run)
		"stitch_remove":
			error = _stitch_remove(run)
		"wrap":
			error = _wrap(run)
		"rebuild":
			error = _rebuild(run)
		"generate_groups":
			error = _generate_groups(run)
		"combine_groups":
			error = _combine_groups(run)
		"create_group":
			error = _create_group(run)
		"direct_edit":
			error = _direct_edit(run)
		"remesh":
			error = _remesh(run)
		"reduce":
			error = _reduce(run)
		"plane_cut":
			error = _plane_cut(run)
		"shell":
			error = _shell(run)
		"combine":
			error = _combine(run)
		"smooth":
			error = _smooth(run)
		"reverse_normal":
			error = _reverse_normal(run)
		"erase_fill":
			error = _erase_fill(run)
		"align":
			error = _align(run)
		"texture_extrude":
			error = _texture_extrude(run)
		"separate":
			error = _separate(run)
		"scale":
			error = _scale(run)
	return _finish(run, error)


## Why a Mesh feature's options can't be read ("" when they can): an option of the wrong kind (a
## switch that is not true or false, picks that are not a list, a choice that is not text; a
## design written by hand or damaged). Said before any tool reads them.
static func option_problem(feature: Resource) -> String:
	var method := str(feature.options.get("method", ""))
	for key in feature.options:
		var value: Variant = feature.options[key]
		if value == null:
			continue
		var name := str(key)
		# ("target" is Combine's pick and Reduce's choice.)
		var wanted := ""
		if name == "target":
			wanted = "text" if method == "reduce" else "list"
		elif SWITCHES.has(name):
			wanted = "switch"
		elif PICK_LISTS.has(name):
			wanted = "list"
		elif TEXTS.has(name):
			wanted = "text"
		elif TABLES.has(name):
			wanted = "table"
		elif name == "made_count":
			wanted = "number"
		match wanted:
			"switch":
				if not value is bool:
					return "%s: %s must be on or off (it holds %s). Open the feature and set it again." % [feature.label, name.capitalize(), _shown(value)]
			"list":
				if not value is Array:
					return "%s: its picks under '%s' can't be read (they are not a list). Open the feature and pick again." % [feature.label, name]
			"text":
				if not (value is String or value is StringName):
					if name == "image":
						return "%s: Image must be a file's path (it holds %s). Open the feature and choose the file again." % [feature.label, _shown(value)]
					return "%s: %s must be one of its choices (it holds %s). Open the feature and choose again." % [feature.label, name.capitalize(), _shown(value)]
			"table", "number":
				if (wanted == "table" and not value is Dictionary) or (wanted == "number" and not (value is int or value is float)):
					return "%s: its own record '%s' can't be read. Delete %s and make it again." % [feature.label, name, feature.label]
	return ""


## A value in a few characters, for a sentence.
static func _shown(value: Variant) -> String:
	var text := var_to_str(value) if not value is Object else "an object"
	return text if text.length() <= 24 else text.substr(0, 21) + "..."


# --- Shared ----------------------------------------------------------------------------------

## How long an op may run in this rebuild: ctx.mesh_time_limit (core/regen.gd), OK_SECONDS when
## the context has none.
static func time_limit(ctx: Dictionary) -> float:
	return clampf(float(ctx.get("mesh_time_limit", OK_SECONDS)), 0.05, 120.0)


## A cache key: the method, what was asked (options: only what changes the result; a MeshBlob
## counts by its digest and a long triangle list by its hash) and the inputs' content digests.
static func cache_key(method: String, options: Dictionary, digests: Array) -> String:
	return "%s|%s|%s" % [method, _canonical(options), ",".join(PackedStringArray(digests))]


static func _canonical(value: Variant) -> String:
	if value is Dictionary:
		var item: Dictionary = value
		var keys: Array = item.keys()
		keys.sort_custom(func(a: Variant, b: Variant) -> bool: return str(a) < str(b))
		var parts := PackedStringArray()
		for key in keys:
			parts.append("%s:%s" % [str(key), _canonical(item[key])])
		return "{" + ",".join(parts) + "}"
	if value is Array:
		var parts := PackedStringArray()
		for inner in value:
			parts.append(_canonical(inner))
		return "[" + ",".join(parts) + "]"
	if value is Resource:
		var digest: Variant = (value as Resource).get("digest")
		return "blob:%s" % str(digest) if digest != null else "res:%d" % (value as Resource).get_instance_id()
	if value is PackedInt32Array and (value as PackedInt32Array).size() > 16:
		return "ints:%d:%d" % [(value as PackedInt32Array).size(), hash(value)]
	if value is Object:
		return "obj:%d" % (value as Object).get_instance_id()
	# (var_to_str keeps every digit of a float; str would round it.)
	return var_to_str(value)


## A kept result for key, or {}. A refusal ("error") made with a shorter time limit than limit
## doesn't count: the op may fit in the longer one.
static func lookup(key: String, limit := OK_SECONDS) -> Dictionary:
	var found: Dictionary = _cache.get(key, {})
	if found.is_empty():
		return {}
	if str(found.get("error", "")) != "" and float(found.get("limit", OK_SECONDS)) < limit:
		return {}
	# Most recently used last.
	_cache.erase(key)
	_cache[key] = found
	cache_hits += 1
	return found


## Keeps a result: meshes (CadMesh, null where the op made none; empty for a refusal), the error
## (a refusal is kept too, so an op that can't work doesn't run again on every rebuild), the
## warning and the op's report. Returns the kept entry.
static func store(key: String, meshes: Array, error := "", warning := "", report := {}, limit := OK_SECONDS) -> Dictionary:
	var bytes := 0
	for mesh in meshes:
		if mesh != null:
			bytes += int(mesh.memory_bytes())
	var kept := {"meshes": meshes, "error": error, "warning": warning, "report": report, "limit": limit, "bytes": bytes}
	if _cache.has(key):
		_cache_bytes -= int(_cache[key].bytes)
		_cache.erase(key)
	_cache[key] = kept
	_cache_bytes += bytes
	# The newest entry always stays, whatever its size.
	while _cache.size() > 1 and (_cache.size() > CACHE_ENTRIES or _cache_bytes > CACHE_BYTES):
		var oldest: String = _cache.keys()[0]
		_cache_bytes -= int(_cache[oldest].bytes)
		_cache.erase(oldest)
	return kept


## Forgets every kept result (tests time ops from scratch with it), and with them the reports,
## the self-crossing tests and the images read.
static func clear_cache() -> void:
	_cache.clear()
	_cache_bytes = 0
	cache_hits = 0
	reports.clear()
	_crossings.clear()
	_images.clear()


## {"entries", "bytes"} of the cache now.
static func cache_stats() -> Dictionary:
	return {"entries": _cache.size(), "bytes": _cache_bytes}


## mesh moved by xform (CadMesh.transformed), kept by content, so a rebuild that changes nothing
## gives the same instance back (and the view doesn't draw it again). The same mesh for the
## identity; null when the kernel refuses (its get_last_error says why).
static func transformed(mesh: RefCounted, xform: Transform3D) -> RefCounted:
	if mesh == null or xform == Transform3D.IDENTITY:
		return mesh
	var key := cache_key("transformed", {"xform": xform}, [str(mesh.digest())])
	var kept := lookup(key)
	if not kept.is_empty() and not (kept.meshes as Array).is_empty():
		return kept.meshes[0]
	var moved: RefCounted = mesh.transformed(xform)
	if moved == null or moved.is_null():
		return null
	store(key, [moved])
	return moved


## The body ids a create-style feature fills: options.outputs, with a new body registered in the
## document (named after source_names[k] + suffix when given) for each one still missing. The ids
## are kept in the feature, so later rebuilds reuse them.
static func output_ids(feature: Resource, doc: Resource, count: int, source_names: Array = [], suffix := "") -> Array:
	var outputs: Array = (feature.options.get("outputs", []) as Array).duplicate()
	var changed := false
	while outputs.size() < count:
		var body_id: String = doc.new_body(feature.id)
		if outputs.size() < source_names.size():
			doc.bodies[body_id]["name"] = str(source_names[outputs.size()]) + suffix
		outputs.append(body_id)
		changed = true
	if changed:
		feature.options["outputs"] = outputs
	return outputs


## Puts a mesh body into the result under body_id (a new entry, or a mesh in place of the one
## there).
static func set_body(ctx: Dictionary, body_id: String, mesh: RefCounted, feature_id: String) -> void:
	ctx.bodies[body_id] = MESH_BODY.entry(body_id, mesh, feature_id)


## Ends a modify-style method: the body keeps its id and takes the new mesh.
static func replace_body(r: UTIL.Reader, body_id: String, mesh: RefCounted) -> void:
	set_body(r.ctx, body_id, mesh, r.feature.id)


## Adds text to the feature's warnings (after any it has).
static func warn(r: UTIL.Reader, text: String) -> void:
	UTIL.add_warning(r, text)


## The CadMesh of the feature's stored blob (options[key]): {"mesh"} or {"error"}. A blob whose
## bytes no longer match their checksum is an error, never a body; so is one that is not there
## (its file beside the scene is gone or can't be read): stored_mesh_problem() says which file.
static func blob_mesh(feature: Resource, key := "mesh") -> Dictionary:
	var blob: Variant = feature.options.get(key)
	if not (blob is Resource) or (blob as Resource).get_script() != MESH_BLOB:
		return {"error": stored_mesh_problem(feature, key)}
	var mesh: RefCounted = blob.to_mesh()
	if mesh == null:
		# (The file it is kept in: its own, or the one the scene names for it.)
		var file := str((blob as Resource).resource_path)
		if file.contains("::") or file == "":
			file = _stored_file(feature, key)
		if file != "":
			return {"error": "The stored mesh of %s is damaged (%s). Put back a sound copy of %s, or delete %s." % [feature.label, blob.last_error, file.get_file(), feature.label]}
		return {"error": "The stored mesh of %s is damaged (%s). Open a copy of the design that still has it, or delete %s." % [feature.label, blob.last_error, feature.label]}
	return {"mesh": mesh}


## What a feature whose stored mesh (options[key]) is not there says: with the file it was kept
## in when the design's scene names one (a large stored mesh lives in a file beside the scene,
## and a file that is gone, empty or cut short leaves nothing in the feature).
static func stored_mesh_problem(feature: Resource, key := "mesh") -> String:
	var file := _stored_file(feature, key)
	if file == "":
		return "%s holds no stored mesh (it was not found with the design). Open a copy of the design that still has it, or delete %s." % [feature.label, feature.label]
	return "%s holds no stored mesh: its file %s is missing or can't be read (%s). Put the file back, or delete %s." % [feature.label, file.get_file(), file, feature.label]


## The file a feature's stored mesh (options[key]) is kept in, read from the text of the scene
## (or resource) file the feature was loaded from: "" when the feature is not from such a file,
## or the file keeps the mesh inside itself.
static func _stored_file(feature: Resource, key: String) -> String:
	var own := str(feature.resource_path)
	if not own.contains("::"):
		return ""
	var scene := own.get_slice("::", 0)
	if not scene.get_extension().to_lower() in ["tscn", "tres"] or not FileAccess.file_exists(scene) or FileAccess.get_size(scene) > 64 * 1024 * 1024:
		return ""
	var text := FileAccess.get_file_as_string(scene)
	var at := text.find('id="%s"]' % own.get_slice("::", 1))
	if at < 0:
		return ""
	var end := text.find("\n[", at)
	var block := text.substr(at, (end if end >= 0 else text.length()) - at)
	var linked := RegEx.create_from_string('"%s": ExtResource\\("([^"]+)"\\)' % key).search(block)
	if linked == null:
		return ""
	var named_at := RegEx.create_from_string('\\[ext_resource[^\\]]*path="([^"]+)"[^\\]]*id="%s"\\]' % linked.get_string(1)).search(text)
	return named_at.get_string(1) if named_at != null else ""


## What a mesh that isn't closed or manifold is told (Insert Mesh): [] when all is well, or when
## the count can't be made within CHECK_SECONDS.
static func check_warnings(mesh: RefCounted, body_name: String) -> PackedStringArray:
	var notes := PackedStringArray()
	var found: Dictionary = mesh.check(CHECK_SECONDS)
	if found.is_empty():
		return notes
	var open := int(found.get("boundary_edges", 0))
	if open > 0:
		var holes := int(found.get("boundary_loops", 0))
		notes.append("%s has %d open edge%s in %d hole%s. Prepare > Close Holes can fix them." % [
			body_name, open, "" if open == 1 else "s", holes, "" if holes == 1 else "s"])
	var shared := int(found.get("non_manifold_edges", 0))
	if shared > 0:
		notes.append("%d edge%s shared by more than two triangles. Stitch and Remove can fix them." % [shared, " is" if shared == 1 else "s are"])
	return notes


# --- Tessellate ------------------------------------------------------------------------------

static func _tessellate(r: UTIL.Reader) -> String:
	var feature := r.feature
	var ctx := r.ctx
	# Mesh bodies are told what they are, not sent to Convert.
	for pick in r.refs("bodies"):
		if pick is Dictionary and MESH_BODY.is_mesh(ctx.bodies.get(pick.get("body", ""), {})):
			return MESH_BODY.ALREADY_MESH % MESH_BODY.body_name(ctx.doc, str(pick.body))
	var ids := r.bodies("bodies")
	var quality := str(r.opt("quality", "medium"))
	if not TESSELLATE_QUALITIES.has(quality):
		r.fail("Refinement must be Low, Medium, High, Very High or Custom")
	var relative := quality == "custom" and bool(r.opt("relative", false))
	var custom_linear := r.num("linear", 0.0001, "positive") if quality == "custom" else 0.0
	var custom_angular := r.num("angular", deg_to_rad(15.0), "positive") if quality == "custom" else 0.0
	if not r.ok():
		return r.error
	var names := ids.map(func(id: String) -> String: return MESH_BODY.body_name(ctx.doc, id))
	var outputs := output_ids(feature, ctx.doc, ids.size(), names, " Mesh")
	var limit := time_limit(ctx)
	var notes := PackedStringArray()
	var made := []
	for k in ids.size():
		var body_id: String = ids[k]
		var shape: RefCounted = ctx.bodies[body_id].shape
		var diagonal: float = (shape.bbox() as AABB).size.length()
		var linear := custom_linear
		var angular := custom_angular
		if quality == "custom":
			var most := maxf(diagonal * TESSELLATE_MAX_LINEAR_FRACTION, TESSELLATE_MIN_LINEAR)
			if linear < TESSELLATE_MIN_LINEAR * (1.0 - 1e-9) or linear > most * (1.0 + 1e-9):
				return "Surface Deviation must be between 0.001 mm and %s mm (a tenth of %s's size)." % [String.num(most * 1000.0, 3), names[k]]
			if angular < TESSELLATE_MIN_ANGLE * (1.0 - 1e-9) or angular > TESSELLATE_MAX_ANGLE * (1.0 + 1e-9):
				return "Normal Deviation must be between 1 and 45 degrees."
			if relative:
				# The kernel takes a relative deviation as a fraction of each face's size.
				linear = linear / maxf(diagonal, 1e-12)
		else:
			var preset: Array = TESSELLATE_PRESETS[quality]
			linear = diagonal * float(preset[0])
			angular = deg_to_rad(float(preset[1]))
		var key := cache_key("tessellate", {"linear": linear, "angular": angular, "relative": relative}, [_brep_digest(shape)])
		var kept := lookup(key, limit)
		if kept.is_empty():
			var mesh: RefCounted = MESH_BODY.new_mesh()
			if mesh.from_shape(shape, linear, angular, relative, limit):
				kept = store(key, [mesh], "", str(mesh.get_last_warning()), mesh.get_last_report(), limit)
			else:
				kept = store(key, [], str(mesh.get_last_error()), "", mesh.get_last_report(), limit)
		if str(kept.error) != "":
			return "%s: %s" % [names[k], kept.error] if ids.size() > 1 else str(kept.error)
		for line in str(kept.warning).split("\n", false):
			if line.strip_edges() != "":
				notes.append("%s: %s" % [names[k], line.strip_edges()] if ids.size() > 1 else line.strip_edges())
		made.append(kept.meshes[0])
	for k in ids.size():
		set_body(ctx, str(outputs[k]), made[k], feature.id)
		if not bool(r.opt("keep_original", true)):
			ctx.bodies.erase(ids[k])
	if outputs.size() > ids.size():
		notes.append("%s now makes %d bod%s instead of %d." % [feature.label, ids.size(), "y" if ids.size() == 1 else "ies", outputs.size()])
	UTIL._warn(r)
	for note in notes:
		warn(r, note)
	return ""


## A B-rep shape as a mesh at a Tessellate preset (one face group per face), for tools that work on
## triangles (Inspect's Interference against a mesh body): {"mesh", "warning"} or {"error"}. Kept
## by content under the Tessellate feature's own keys, so a body already tessellated at that
## preset is not meshed again.
static func tessellated(shape: RefCounted, quality := "medium", limit := OK_SECONDS) -> Dictionary:
	if not MESH_BODY.available():
		return {"error": MESH_BODY.KERNEL_MISSING}
	if shape == null or shape.is_null() or MESH_BODY.is_mesh(shape):
		return {"error": "There is no B-rep body to tessellate"}
	var preset: Array = TESSELLATE_PRESETS.get(quality, TESSELLATE_PRESETS.medium)
	var linear: float = (shape.bbox() as AABB).size.length() * float(preset[0])
	var angular := deg_to_rad(float(preset[1]))
	var key := cache_key("tessellate", {"linear": linear, "angular": angular, "relative": false}, [_brep_digest(shape)])
	var kept := lookup(key, limit)
	if kept.is_empty():
		var mesh: RefCounted = MESH_BODY.new_mesh()
		if mesh.from_shape(shape, linear, angular, false, clampf(limit, 0.05, 120.0)):
			kept = store(key, [mesh], "", str(mesh.get_last_warning()), mesh.get_last_report(), limit)
		else:
			kept = store(key, [], str(mesh.get_last_error()), "", mesh.get_last_report(), limit)
	if str(kept.error) != "":
		return {"error": str(kept.error)}
	return {"mesh": kept.meshes[0], "warning": str(kept.warning)}


## A content digest of a B-rep shape: its BRep bytes and its face names hashed (the bytes hold no
## names, and a tessellation's face groups are named after the faces). The same shape with the
## same names gives the same digest, so its tessellation is found again; the same shape under
## other names (the same box made by another feature) is another one.
static func _brep_digest(shape: RefCounted) -> String:
	var bytes: PackedByteArray = shape.to_brep_bytes()
	if bytes.is_empty():
		return "shape:%d" % shape.get_instance_id()
	var names: PackedStringArray = shape.get_face_names()
	return "brep:%s:%s" % [MESH_BLOB.sha256_hex(bytes).substr(0, 32), MESH_BLOB.sha256_hex("\n".join(names).to_utf8_buffer()).substr(0, 16)]


## Adds a Tessellate feature for B-rep bodies (ids) with its mesh bodies registered. options may
## give quality, relative and keep_original; inputs "linear" and "angular" (expressions) for a
## custom refinement. Returns {"feature", "error", "bodies": the new mesh body ids}.
static func add_tessellate(doc: Resource, body_ids: Array, options := {}, inputs := {}) -> Dictionary:
	if body_ids.is_empty():
		return {"feature": null, "error": "Select a body", "bodies": []}
	var picks := []
	for body_id in body_ids:
		picks.append({"kind": "body", "body": str(body_id)})
	var settings := {"method": "tessellate", "bodies": picks, "quality": "medium", "relative": false, "keep_original": true, "outputs": []}
	settings.merge(options, true)
	var feature: Resource = doc.add_feature("mesh", "Tessellate", inputs, settings)
	var names := body_ids.map(func(id: Variant) -> String: return MESH_BODY.body_name(doc, str(id)))
	var outputs := output_ids(feature, doc, body_ids.size(), names, " Mesh")
	return {"feature": feature, "error": "", "bodies": outputs}


# --- Tools: shared ---------------------------------------------------------------------------

## text with the body's name in it: BODY_TOKEN and the kernel's "The mesh" become the name, and a
## sentence that names no body is led by "<name>: " (others: further bodies the op took, whose
## names count too: a Combine's tools).
static func named(text: String, name: String, others := PackedStringArray()) -> String:
	if text == "":
		return ""
	var out := text.replace(BODY_TOKEN, name).replace("The mesh", name)
	var names := PackedStringArray([name])
	names.append_array(others)
	for known in names:
		if out.begins_with(known):
			return out
		for after in [" ", ".", ":", ";", ",", "'", ")"]:
			if out.contains(" %s%s" % [known, after]):
				return out
	return "%s: %s" % [name, out]


## True for the two sentences an op says when it is over its time limit: the estimate made up
## front and the time-out.
static func is_time_refusal(error: String) -> bool:
	return (error.contains("would take about") and error.contains("(limit")) or (error.contains("took longer than") and error.contains("was stopped"))


## How many places a mesh crosses itself, or -1 when that could not be tested within `seconds`
## (at most SELF_INTERSECTION_SECONDS). Kept by content.
static func crossing_count(mesh: RefCounted, seconds := SELF_INTERSECTION_SECONDS) -> int:
	if mesh == null or mesh.is_null():
		return 0
	seconds = clampf(seconds, 0.05, SELF_INTERSECTION_SECONDS)
	var digest := str(mesh.digest())
	var known: Dictionary = _crossings.get(digest, {})
	if known.is_empty() or (int(known.count) < 0 and float(known.seconds) < seconds):
		var found: Dictionary = mesh.check(seconds)
		known = {"count": int(found.get("self_intersections", -1)) if not found.is_empty() else -1, "seconds": seconds}
		if _crossings.size() >= 64:
			_crossings.erase(_crossings.keys()[0])
		_crossings[digest] = known
	return int(known.count)


## What a tool that needs a clear inside is told of a body that crosses itself (its result is as
## wrong as the body there), or "" when it doesn't. The test may take `seconds` (at most
## SELF_INTERSECTION_SECONDS) and is kept by content; a mesh too large to test in that time gives
## a sentence saying so when tell_untested, since nothing can be promised about it.
static func crossing_note(mesh: RefCounted, name: String, seconds := SELF_INTERSECTION_SECONDS, tell_untested := true) -> String:
	var count := crossing_count(mesh, seconds)
	if count > 0:
		return CROSSES % name
	if count < 0 and tell_untested:
		return NOT_TESTED % [name, _seconds_text(clampf(seconds, 0.05, SELF_INTERSECTION_SECONDS))]
	return ""


## Notes how many places an input body crosses itself (it is told once, by _finish): the
## kernel's own count when its report gives one (counted: an int, -1 for "not tested"), else the
## test made here in what is left of the feature's time.
static func _cross(run: Run, mesh: RefCounted, name: String, counted: Variant = null) -> void:
	var count := 0
	if counted is int or counted is float:
		count = int(counted)
	else:
		var started := Time.get_ticks_usec()
		count = crossing_count(mesh, clampf(run.left(), 0.05, SELF_INTERSECTION_SECONDS) if run.records else clampf(run.left(), 0.05, CHECK_SECONDS))
		run.spent[name] = float(run.spent.get(name, 0.0)) + (Time.get_ticks_usec() - started) / 1e6
	var before: Variant = run.crossing.get(name)
	# (A count found stands over "not tested", and a larger one over a smaller.)
	if before == null or int(before) < 0 or count > int(before):
		run.crossing[name] = count


## _cross() for the inputs of an op that is done: names and meshes side by side (a Combine's
## target, then its tools), with the counts of the op's report ("input_self_intersections": one
## number, or one per input) where the kernel tested them itself.
static func _cross_after(run: Run, report: Dictionary, names: Array, meshes: Array) -> void:
	var counted: Variant = report.get("input_self_intersections")
	for k in names.size():
		var value: Variant = null
		if (counted is int or counted is float) and names.size() == 1:
			value = counted
		elif (counted is PackedInt64Array or counted is PackedInt32Array or counted is Array) and k < counted.size():
			value = int(counted[k])
		_cross(run, meshes[k], str(names[k]), value)


## A length in millimeters, as the kernel writes them ("0.25 mm").
static func _mm(meters: float) -> String:
	return _plain(meters * 1000.0) + " mm"


static func _seconds_text(seconds: float) -> String:
	return _plain(seconds)


## A number with about four significant digits and no trailing zeros.
static func _plain(value: float) -> String:
	if value == 0.0 or not is_finite(value):
		return "0"
	var decimals := clampi(3 - int(floor(log(absf(value)) / log(10.0))), 0, 9)
	var text := String.num(value, decimals)
	if text.contains("."):
		text = text.rstrip("0").rstrip(".")
	return "0" if text == "-0" or text == "" else text


## The kernel's options for an op: what was asked, the time it may take, and (for the ops that
## name the body themselves) the token named() turns into the body's name.
static func _native(options: Dictionary, seconds: float, with_name := false) -> Dictionary:
	var native := options.duplicate()
	native["time_limit"] = seconds
	if with_name:
		native["name"] = BODY_TOKEN
	return native


## Puts the input `key` into native (under as_key when given), when the feature has it: an
## "angle" in degrees, a "whole" number as an int when it is one. A missing input leaves the
## kernel's own default.
static func _take(run: Run, native: Dictionary, key: String, kind := "", as_key := "") -> void:
	if not run.r.has_input(key):
		return
	var value := run.r.num(key)
	if not run.r.ok():
		return
	if kind == "angle":
		value = rad_to_deg(value)
	var target := as_key if as_key != "" else key
	if kind == "whole" and absf(value - roundf(value)) < 1e-9:
		native[target] = int(roundf(value))
	else:
		native[target] = value


## Puts the option `key` (a choice or a switch) into native, when the feature holds it.
static func _choice(run: Run, native: Dictionary, key: String, as_key := "") -> void:
	var value: Variant = run.feature.options.get(key)
	if value != null:
		native[as_key if as_key != "" else key] = value


## Runs a kernel op on a body's mesh, through the cache. key: what was asked (everything that
## changes the result); work: Callable(seconds) -> what the op returns (a CadMesh, an Array of
## them, or null), called only when nothing is kept; digests: the content digests of other
## meshes that go in; others: the names of those bodies. Returns the kept entry ({"meshes",
## "error", "warning", "report"}). A refusal fails the run with the kernel's sentence and
## warnings join the run's notes, both with the body's name in them.
##
## Time: the op gets the feature's limit less what the bodies before this one took. What is kept:
##   - a result, for the feature's limit: a build with as much time or less gets it; a build with
##     more (OK after a preview) computes its own, since a result's checks had the time of the
##     build that made it and its warnings may be fewer;
##   - a refusal by time, for the time the op had: the next rebuild that gives it the same or
##     less answers at once;
##   - any other refusal, whatever the time.
static func _op(run: Run, name: String, mesh: RefCounted, method: String, key: Dictionary, work: Callable, digests: Array = [], others := PackedStringArray()) -> Dictionary:
	var nothing := {"meshes": [], "error": "", "warning": "", "report": {}}
	if run.failed():
		nothing.error = run.problem()
		return nothing
	var before := 0.0
	for other in run.spent:
		if str(other) != name:
			before += float(run.spent[other])
	var after_others := before > 0.01 * run.limit
	var seconds := run.limit - before
	var id := cache_key("op:" + method, key, [str(mesh.digest())] + digests)
	var kept := lookup(id, maxf(seconds, 0.05))
	if not kept.is_empty() and str(kept.error) == "" and float(kept.get("limit", OK_SECONDS)) < run.limit * 0.999:
		kept = {}
	if kept.is_empty():
		if seconds < 0.05 and after_others:
			run.fail("%s took longer than %s s on its bodies and was stopped before %s. Pick fewer bodies at once." % [run.feature.label, _seconds_text(run.limit), name])
			nothing.error = run.error
			return nothing
		seconds = clampf(seconds, 0.05, 120.0)
		var started := Time.get_ticks_usec()
		var out: Variant = work.call(seconds)
		run.spent[name] = float(run.spent.get(name, 0.0)) + (Time.get_ticks_usec() - started) / 1e6
		var meshes := []
		if out is Array:
			meshes = out
		elif out != null:
			meshes = [out]
		var any := false
		for made in meshes:
			if made != null:
				any = true
		var error := ""
		if not any:
			meshes = []
			error = str(mesh.get_last_error())
			if error == "":
				error = "%s made nothing of %s." % [method.capitalize(), BODY_TOKEN]
			elif is_time_refusal(error) and after_others:
				# The limit the kernel names is what the bodies before this one left.
				error += BODIES_BEFORE % _seconds_text(run.limit)
		var holds := run.limit
		if error != "":
			holds = seconds if is_time_refusal(error) else 120.0
		kept = store(id, meshes, error, str(mesh.get_last_warning()), mesh.get_last_report(), holds)
	if str(kept.error) != "":
		run.fail(named(str(kept.error), name, others))
	else:
		for line in str(kept.warning).split("\n", false):
			run.note(named(line.strip_edges(), name, others))
		run.kept.append(kept)
		# Where the kernel counted the places the result crosses itself, that is told (_finish).
		var crossings: Variant = (kept.report as Dictionary).get("self_intersections") if kept.report is Dictionary else null
		if crossings is int and int(crossings) > 0:
			run.result_crossing[name] = {"count": maxi(int(crossings), int((run.result_crossing.get(name, {}) as Dictionary).get("count", 0))), "tool": method}
	return kept


## The mesh bodies a tool works on, in pick order: those picked in options[bodies_key] (whole
## bodies; a component stands for its mesh bodies) and those the picks of options[picks_key]
## lie on (face groups, triangles, open loops). Each is {"id", "name", "mesh", "triangles"
## (PackedInt32Array), "groups" (names), "loops" (open-loop ids), "points" (where triangle picks
## hit)}. Triangles and loops picked on an older version of a body are kept where they still
## exist, with a warning. Fails the run when a body is gone, is not a mesh body, or nothing is
## picked.
static func _targets(run: Run, bodies_key: String, picks_key := "") -> Array:
	var order := []
	var by := {}
	var picks := []
	if bodies_key != "":
		picks.append_array(run.r.refs(bodies_key))
	if picks_key != "":
		picks.append_array(run.r.refs(picks_key))
	for pick in picks:
		if not pick is Dictionary:
			continue
		var kind := str(pick.get("kind", ""))
		var ids := []
		if kind == "component":
			for body_id in run.ctx.bodies:
				if run.doc.body_component(body_id) == str(pick.get("component", "")) and MESH_BODY.is_mesh(run.ctx.bodies[body_id]):
					ids.append(str(body_id))
		else:
			ids.append(str(pick.get("body", "")))
		for id in ids:
			if not run.ctx.bodies.has(id):
				run.fail("Body %s no longer exists" % run.body_name(id))
				return []
			var found: Dictionary = run.ctx.bodies[id]
			var name := run.body_name(id)
			if not MESH_BODY.is_mesh(found):
				run.fail(NOT_A_MESH % name)
				return []
			if not by.has(id):
				by[id] = {"id": id, "name": name, "mesh": found.shape, "triangles": PackedInt32Array(), "groups": PackedStringArray(),
					"loops": PackedInt32Array(), "points": PackedVector3Array()}
				order.append(id)
			var target: Dictionary = by[id]
			var mesh: RefCounted = target.mesh
			var recorded := str(pick.get("digest", "")) != ""
			var stale: bool = recorded and str(pick.digest) != str(mesh.digest())
			if not recorded and (kind == MESH_BODY.TRIANGLES_REF or kind == "mesh_boundary"):
				# No record of the version it was made on: the feature remembers the body it first
				# built on (options.picked_on), and doubts the pick once the body is another one.
				var memo := "%s:%d" % [id, hash(pick.get("triangles", pick.get("loop")))]
				var remembered: Variant = (run.feature.options.get("picked_on", {}) as Dictionary).get(memo)
				stale = remembered != null and str(remembered) != str(mesh.digest())
				run.picked[memo] = str(remembered) if remembered != null else str(mesh.digest())
			match kind:
				MESH_BODY.GROUP_REF, "face":
					# The group as it is now: face groups are named by order, so an earlier change
					# can hand the picked name to another face. The pick's point and facing find
					# the face again (said in a warning); a pick that is lost fails the feature.
					var now: Dictionary = MESH_BODY.resolve_group(mesh, pick)
					if now.has("error"):
						run.fail(named(str(now.error), name))
						return []
					var group := str(now.name)
					if bool(now.get("moved", false)):
						run.note(MESH_BODY.moved_note(run.feature.label, str(now.get("from", "")), group))
					var groups: PackedStringArray = target.groups
					if not groups.has(group):
						groups.append(group)
						target["groups"] = groups
				MESH_BODY.TRIANGLES_REF:
					var triangles: PackedInt32Array = target.triangles
					var held: Variant = pick.get("triangles", PackedInt32Array())
					if held is Array:
						# (A list of plain numbers, as a design written by hand may hold.)
						var numbers := PackedInt32Array()
						for t in held:
							if not (t is int or t is float):
								numbers = PackedInt32Array()
								held = null
								break
							numbers.append(int(t))
						if held != null:
							held = numbers
					if not held is PackedInt32Array:
						run.fail("%s: the triangle selection on %s can't be read (it is not a list of triangle numbers). Select the triangles again." % [run.feature.label, name])
						return []
					var picked: PackedInt32Array = held
					if stale or not recorded:
						# (A pick with no record is checked too: a triangle the body does not have
						# is reason enough to doubt it.)
						var count := int(mesh.triangle_count())
						var dropped := 0
						for t in picked:
							if t >= 0 and t < count:
								triangles.append(t)
							else:
								dropped += 1
						if stale or dropped > 0:
							var text := STALE_TRIANGLES % [run.feature.label, name]
							if dropped > 0:
								text += " %d triangle%s no longer there and left out." % [dropped, " is" if dropped == 1 else "s are"]
							run.note(text)
							run.stale.append(text)
					else:
						triangles.append_array(picked)
					target["triangles"] = triangles
					if pick.get("at") is Vector3:
						var points: PackedVector3Array = target.points
						points.append(pick.at)
						target["points"] = points
				"mesh_boundary":
					var loops: PackedInt32Array = target.loops
					var held_loop: Variant = pick.get("loop", -1)
					if not (held_loop is int or held_loop is float):
						run.fail("%s: a picked hole of %s can't be read (it is not a hole's number). Pick the holes again." % [run.feature.label, name])
						return []
					var loop := int(held_loop)
					if stale:
						run.note(STALE_HOLES % [run.feature.label, name])
						run.stale.append(STALE_HOLES % [run.feature.label, name])
					if loop >= 0 and not loops.has(loop):
						loops.append(loop)
						target["loops"] = loops
	if order.is_empty() and not run.failed():
		run.fail("Select a mesh body")
	var targets := []
	for id in order:
		targets.append(by[id])
	return targets


## The triangles a target's picks name: its picked triangles and those of its picked face
## groups, each once.
static func _picked_triangles(target: Dictionary) -> PackedInt32Array:
	var triangles: PackedInt32Array = (target.triangles as PackedInt32Array).duplicate()
	var groups: PackedStringArray = target.groups
	if groups.is_empty():
		return triangles
	var mesh: RefCounted = target.mesh
	for group in groups:
		triangles.append_array(mesh.group_triangles(int(mesh.find_face(group))))
	if (target.triangles as PackedInt32Array).is_empty() and groups.size() == 1:
		return triangles
	var seen := {}
	var once := PackedInt32Array()
	for t in triangles:
		if not seen.has(t):
			seen[t] = true
			once.append(t)
	once.sort()
	return once


## Runs one kernel op (method, with options) on every target and puts each result in its
## body's place; nothing changes unless every body's op works. per_target: Callable(target,
## options) may add what hangs on the body (its picked triangles). with_name: the op names the
## body itself (the Manifold and voxel ops).
static func _each(run: Run, targets: Array, method: String, options: Dictionary, per_target := Callable(), with_name := false) -> String:
	var made := []
	for target in targets:
		var asked := options.duplicate()
		if per_target.is_valid():
			per_target.call(target, asked)
		var mesh: RefCounted = target.mesh
		var kept := _op(run, str(target.name), mesh, method, asked, func(seconds: float) -> Variant: return mesh.call(method, _native(asked, seconds, with_name)))
		if run.failed():
			return run.problem()
		made.append(kept.meshes[0])
		_tally(run, mesh, kept.meshes[0], kept.report)
	for k in targets.size():
		replace_body(run.r, str(targets[k].id), made[k])
	return ""


## Adds a target's picked triangles to an op's options (ops that take a selection).
static func _with_selection(target: Dictionary, options: Dictionary) -> void:
	var triangles := _picked_triangles(target)
	if not triangles.is_empty():
		options["triangles"] = triangles


## Counts a body into the report: its mesh before (null for a new body) and after, and the op's
## own report of the result when there is one (else the open edges are counted here).
static func _tally(run: Run, before: RefCounted, after: RefCounted, report: Dictionary = {}) -> void:
	var tally: Dictionary = run.tally
	if tally.is_empty():
		tally = {"before": 0, "after": 0, "open": 0, "known": true, "deviation": -1.0, "spent": 0.0}
	tally.before += int(before.triangle_count()) if before != null else 0
	if after != null and not after.is_null():
		tally.after += int(after.triangle_count())
		var output: Variant = report.get("output")
		var open := -1
		if output is Dictionary and (output as Dictionary).get("boundary_edges") is int and (output as Dictionary).get("triangles") is int and int(output.triangles) == int(after.triangle_count()):
			open = int(output.boundary_edges)
		elif bool(tally.known) and float(tally.spent) < TALLY_SECONDS:
			var started := Time.get_ticks_usec()
			var found: Dictionary = after.check(minf(CHECK_SECONDS, TALLY_SECONDS - float(tally.spent)))
			tally.spent = float(tally.spent) + (Time.get_ticks_usec() - started) / 1e6
			open = int(found.get("boundary_edges", -1)) if not found.is_empty() else -1
		if open < 0:
			tally.known = false
		else:
			tally.open += open
	var deviation: Variant = report.get("deviation")
	if deviation is Dictionary and ((deviation as Dictionary).get("max") is float or (deviation as Dictionary).get("max") is int):
		tally.deviation = maxf(float(tally.deviation), float(deviation.max))
	run.tally = tally


## The ids of `count` bodies a tool adds under slot (the body they come from, or a word): those
## options.made[slot] holds, then new ones. On a full-time build a new one is registered in the
## document (named names[k], in source's component) and kept; a preview shows it under a
## passing id derived from source.
static func _made_ids(run: Run, slot: String, count: int, source: String, names: Array) -> Array:
	run.creates = true
	var made: Dictionary = run.feature.options.get("made", {})
	var have: Array = (made.get(slot, []) as Array).duplicate()
	var before := have.size()
	var ids := []
	for k in count:
		if k < have.size():
			ids.append(str(have[k]))
		elif run.records:
			var body_id: String = run.doc.new_body(run.feature.id)
			if k < names.size():
				run.doc.bodies[body_id]["name"] = str(names[k])
			run.doc.bodies[body_id]["component"] = run.doc.body_component(source)
			have.append(body_id)
			ids.append(body_id)
		else:
			ids.append(UTIL.derived_body_id(source, run.feature.id, k + 2))
	if have.size() > before:
		var next: Dictionary = made.duplicate(true)
		next[slot] = have
		run.feature.options["made"] = next
	return ids


## What the feature asks for, as one text: its options (without the tools' own bookkeeping) and
## its inputs' expressions. A feature edited since its bodies were counted reads differently.
static func _signature(feature: Resource) -> String:
	var asked := {}
	for key in feature.options:
		if not BOOKKEEPING.has(key):
			asked[key] = feature.options[key]
	var inputs := {}
	for key in feature.inputs:
		inputs[key] = str((feature.inputs[key] as Dictionary).get("expression", ""))
	return str(hash(_canonical(asked) + "|" + _canonical(inputs)))


## Ends a tool: the first problem, or its warnings, its bodies' bookkeeping and its report.
static func _finish(run: Run, error: String) -> String:
	var tally: Dictionary = run.tally
	if error == "":
		error = run.problem()
	if error != "":
		# A refusal over a selection made on an older version of the body says that too.
		for text in run.stale:
			if not error.contains(text):
				error += " " + text
		return error
	# Bodies that cross themselves are told once each, by name, first; a sentence of the
	# kernel's that names the body stands in place of ours.
	var told := PackedStringArray()
	for name in run.crossing:
		var count := int(run.crossing[name])
		var said := false
		for note in run.notes:
			if note.contains("%s crosses itself" % name) or note.contains("%s may cross itself" % name) or (count < 0 and note.contains(str(name)) and note.contains("crosses itself") and note.contains("test")):
				said = true
		if said:
			continue
		if count > 0:
			told.append(CROSSES % name)
		elif count < 0 and run.records:
			told.append(NOT_TESTED % [name, _seconds_text(SELF_INTERSECTION_SECONDS)])
	for name in run.result_crossing:
		if int(run.crossing.get(name, 0)) > 0:
			continue
		var said := false
		for note in run.notes:
			if note.contains(str(name)) and note.contains("cross"):
				said = true
		if not said:
			var made: Dictionary = run.result_crossing[name]
			told.append(RESULT_CROSSES % [name, _commas(int(made.count)), "" if int(made.count) == 1 else "s", str(made.tool).capitalize()])
	if not told.is_empty():
		told.append_array(run.notes)
		run.notes = told
	if run.records and not run.picked.is_empty() and (run.feature.options.get("picked_on", {}) as Dictionary) != run.picked:
		run.feature.options["picked_on"] = run.picked.duplicate()
	if run.creates:
		# A tool that makes fewer bodies than it did with the same settings says so (a change
		# earlier in the timeline took them); edited, it counts afresh.
		var options: Dictionary = run.feature.options
		var signature := _signature(run.feature)
		var count := run.outputs.size()
		var same := str(options.get("made_with", "")) == signature
		if same and count < int(options.get("made_count", 0)):
			run.note("%s now makes %d bod%s instead of %d." % [run.feature.label, count, "y" if count == 1 else "ies", int(options.made_count)])
		if run.records:
			if (options.get("outputs", []) as Array) != run.outputs:
				options["outputs"] = run.outputs.duplicate()
			if not same:
				options["made_with"] = signature
				options["made_count"] = count
			elif count > int(options.get("made_count", 0)):
				options["made_count"] = count
	UTIL._warn(run.r)
	for note in run.notes:
		warn(run.r, note)
	# One op on one body: the kernel's own report, with the tool's keys over it.
	var report := {}
	if run.kept.size() == 1 and run.kept[0].get("report") is Dictionary:
		report = (run.kept[0].report as Dictionary).duplicate(true)
	var own_input: Variant = report.get("input")
	var own_output: Variant = report.get("output")
	report.erase("input")
	report.erase("output")
	report.erase("deviation")
	report["op"] = str(run.feature.options.get("method", ""))
	report["stat"] = "\n".join(run.stat)
	report["warnings"] = Array(run.notes)
	report["bodies"] = []
	for kept in run.kept:
		(report.bodies as Array).append(kept.get("report", {}))
	if not tally.is_empty() and bool(tally.known):
		var input: Dictionary = (own_input as Dictionary).duplicate() if own_input is Dictionary else {}
		var output: Dictionary = (own_output as Dictionary).duplicate() if own_output is Dictionary else {}
		input["triangles"] = int(tally.before)
		output["triangles"] = int(tally.after)
		output["boundary_edges"] = int(tally.open)
		report["input"] = input
		report["output"] = output
		report["deviation"] = {"max": float(tally.deviation)} if float(tally.deviation) >= 0.0 else {}
	while reports.size() >= REPORTS_KEPT:
		reports.erase(reports.keys()[0])
	reports[run.feature.id] = report
	return ""


## The CadMesh of a stored blob (options[key]), kept by the blob's digest, so every rebuild
## gives the same instance: {"mesh"} or {"error"}.
static func _blob(feature: Resource, key: String) -> Dictionary:
	var blob: Variant = feature.options.get(key)
	if not (blob is Resource) or (blob as Resource).get_script() != MESH_BLOB or str(blob.digest) == "":
		return blob_mesh(feature, key)
	var id := cache_key("blob", {}, [str(blob.digest)])
	var kept := lookup(id)
	if not kept.is_empty() and not (kept.meshes as Array).is_empty():
		return {"mesh": kept.meshes[0]}
	var made := blob_mesh(feature, key)
	if made.has("mesh"):
		store(id, [made.mesh])
	return made


## How many: a count as a number, or the size of a list.
static func _count(value: Variant) -> int:
	if value is int or value is float:
		return int(value)
	if value is Array or value is PackedInt32Array or value is PackedInt64Array or value is PackedStringArray:
		return value.size()
	return 0


## 20480 as "20,480".
static func _commas(value: int) -> String:
	var digits := str(absi(value))
	var out := ""
	while digits.length() > 3:
		out = "," + digits.substr(digits.length() - 3) + out
		digits = digits.substr(0, digits.length() - 3)
	return ("-" if value < 0 else "") + digits + out


# --- Prepare ---------------------------------------------------------------------------------

static func _close_holes(run: Run) -> String:
	var targets := _targets(run, "bodies", "loops")
	var native := {}
	_choice(run, native, "fill")
	_choice(run, native, "refine")
	_take(run, native, "max_edges", "whole")
	if run.failed():
		return run.problem()
	var error := _each(run, targets, "close_holes", native, func(target: Dictionary, options: Dictionary) -> void:
		if not (target.loops as PackedInt32Array).is_empty():
			options["loops"] = target.loops)
	if error != "":
		return error
	var filled := 0
	var left := 0
	for kept in run.kept:
		filled += _count(kept.report.get("filled_loops"))
		left += _count(kept.report.get("skipped_loops")) + _count(kept.report.get("broken_loops"))
	run.stat.append("Holes closed: %d%s" % [filled, ", %d left open" % left if left > 0 else ""])
	return ""


static func _stitch_remove(run: Run) -> String:
	var targets := _targets(run, "bodies")
	var native := {}
	_take(run, native, "tolerance")
	_choice(run, native, "remove_small")
	if bool(run.r.opt("remove_small", true)):
		_take(run, native, "min_size")
	_choice(run, native, "remove_inner")
	_choice(run, native, "fix_non_manifold")
	if run.failed():
		return run.problem()
	var error := _each(run, targets, "stitch_and_remove", native)
	if error != "":
		return error
	for k in run.kept.size():
		var summary := str(run.kept[k].report.get("summary", ""))
		if summary != "":
			run.stat.append(summary if targets.size() == 1 else "%s: %s" % [targets[k].name, summary])
	return ""


static func _wrap(run: Run) -> String:
	var targets := _targets(run, "bodies")
	var native := {}
	_take(run, native, "detail")
	_take(run, native, "gap")
	_take(run, native, "offset")
	if run.failed():
		return run.problem()
	# Several bodies are wrapped as one: put together first, with no boolean.
	var first: Dictionary = targets[0]
	var source: RefCounted = first.mesh
	var name := str(first.name)
	var before := int(source.triangle_count())
	# Where each picked body's triangles end in the merged mesh (they are put one after the other).
	var ends := PackedInt32Array([before])
	if targets.size() > 1:
		var all_names := PackedStringArray()
		for target in targets:
			all_names.append(str(target.name))
		name = "%s and %s" % [", ".join(all_names.slice(0, all_names.size() - 1)), all_names[all_names.size() - 1]]
		var others := []
		var digests := []
		for k in range(1, targets.size()):
			others.append(targets[k].mesh)
			digests.append(str(targets[k].mesh.digest()))
			before += int(targets[k].mesh.triangle_count())
			ends.append(before)
		var whole: RefCounted = source
		var merged := _op(run, name, whole, "merge_with", {}, func(_seconds: float) -> Variant: return whole.merge_with(others), digests)
		if run.failed():
			return run.problem()
		source = merged.meshes[0]
	var kept := _op(run, name, source, "wrap", native, func(seconds: float) -> Variant: return source.wrap(_native(native, seconds, true)))
	if run.failed():
		return run.problem()
	var wrapped: RefCounted = kept.meshes[0]
	if targets.size() > 1:
		_name_left_out(run, targets, ends, kept.report)
	_tally(run, null, wrapped, kept.report)
	run.tally["before"] = before
	replace_body(run.r, str(first.id), wrapped)
	for k in range(1, targets.size()):
		run.ctx.bodies.erase(targets[k].id)
	if kept.report.has("detail"):
		run.stat.append("Detail: %s, %d cells" % [_mm(float(kept.report.detail)), _count(kept.report.get("cells"))])
	return ""


## After a Wrap of several bodies: says which of them have parts that are not in the wrap. The
## kernel lists the connected parts of the merged mesh that are more than half out
## (report.left_out_parts: "first_triangle", "triangles", "area_share"); a part's first triangle
## tells which picked body it is of (ends: where each body's triangles end in the merged mesh).
static func _name_left_out(run: Run, targets: Array, ends: PackedInt32Array, report: Dictionary) -> void:
	var parts: Variant = report.get("left_out_parts")
	if not (parts is Array) or (parts as Array).is_empty():
		return
	var counts := {}
	var triangles := {}
	var shares := {}
	for part in parts:
		if not (part is Dictionary):
			continue
		var at := int(part.get("first_triangle", -1))
		var body := -1
		for k in ends.size():
			if at >= 0 and at < ends[k]:
				body = k
				break
		if body < 0:
			continue
		counts[body] = int(counts.get(body, 0)) + 1
		triangles[body] = int(triangles.get(body, 0)) + int(part.get("triangles", 0))
		shares[body] = float(shares.get(body, 0.0)) + float(part.get("area_share", 0.0))
	for body in counts:
		var body_name := str(targets[body].name)
		# (Two digits, as the kernel writes a share.)
		var percent := float(shares[body]) * 100.0
		var digits := 0 if percent >= 10.0 else clampi(1 - int(floor(log(maxf(percent, 1e-12)) / log(10.0))), 0, 6)
		var share := "about %s %% of the wrapped surface" % String.num(percent, digits) if percent > 0.0 else "a very small share of the wrapped surface"
		if int(triangles[body]) >= int(targets[body].mesh.triangle_count()):
			run.note("%s is not in the wrap at all (%s)." % [body_name, share])
		else:
			run.note("%d part%s of %s %s not in the wrap (%s)." % [int(counts[body]), "" if int(counts[body]) == 1 else "s", body_name, "is" if int(counts[body]) == 1 else "are", share])
	if (parts as Array).size() >= 100:
		run.note("Only the first 100 parts left out of the wrap are counted here.")


static func _rebuild(run: Run) -> String:
	var targets := _targets(run, "bodies")
	var native := {}
	_take(run, native, "detail")
	_choice(run, native, "algorithm", "method")
	if run.failed():
		return run.problem()
	var error := _each(run, targets, "rebuild", native, Callable(), true)
	if error == "" and run.kept.size() == 1 and run.kept[0].report.has("detail"):
		run.stat.append("Detail: %s, %d cells" % [_mm(float(run.kept[0].report.detail)), _count(run.kept[0].report.get("cells"))])
	return error


static func _generate_groups(run: Run) -> String:
	var targets := _targets(run, "bodies")
	var native := {}
	_choice(run, native, "algorithm", "method")
	var fast := str(native.get("method", "accurate")) == "fast"
	if fast:
		_take(run, native, "angle", "angle")
	else:
		_take(run, native, "tolerance")
	_take(run, native, "min_size", "whole")
	if run.failed():
		return run.problem()
	var error := _each(run, targets, "generate_groups", native)
	if error != "":
		return error
	var groups := 0
	for kept in run.kept:
		groups += int(kept.meshes[0].group_count())
	run.stat.append("Face groups: %d" % groups)
	return ""


static func _combine_groups(run: Run) -> String:
	var targets := _targets(run, "", "groups")
	if run.failed():
		return run.problem()
	if targets.size() != 1:
		return "Pick the face groups of one body to combine."
	var target: Dictionary = targets[0]
	var names: PackedStringArray = target.groups
	if names.size() < 2:
		return "Pick two or more face groups of %s to combine." % target.name
	var mesh: RefCounted = target.mesh
	var asked := {"groups": names}
	var kept := _op(run, str(target.name), mesh, "regroup", asked, func(_seconds: float) -> Variant: return mesh.regroup({"groups": Array(names)}))
	if run.failed():
		return run.problem()
	_tally(run, mesh, kept.meshes[0], kept.report)
	replace_body(run.r, str(target.id), kept.meshes[0])
	run.stat.append("Face groups: %d" % int(kept.meshes[0].group_count()))
	return ""


static func _create_group(run: Run) -> String:
	var targets := _targets(run, "", "selection")
	if run.failed():
		return run.problem()
	if targets.size() != 1:
		return "Pick the triangles of one body for the new face group."
	var target: Dictionary = targets[0]
	var triangles := _picked_triangles(target)
	if triangles.is_empty():
		return "Pick the triangles of the new face group on %s." % target.name
	var mesh: RefCounted = target.mesh
	var kept := _op(run, str(target.name), mesh, "regroup", {"triangles": triangles}, func(_seconds: float) -> Variant: return mesh.regroup({"triangles": triangles}))
	if run.failed():
		return run.problem()
	_tally(run, mesh, kept.meshes[0], kept.report)
	replace_body(run.r, str(target.id), kept.meshes[0])
	run.stat.append("Face groups: %d" % int(kept.meshes[0].group_count()))
	return ""


# --- Modify ----------------------------------------------------------------------------------

## Direct Edit: the body becomes the stored snapshot (ui/mesh_direct_edit.gd wrote it), and the
## bodies the tool took out come back from their own snapshots. A stored mesh that is not there
## (its file is gone, empty or cut short) is an error that names the file, and the body stays as
## it was before the feature. Only options.emptied == true, with no stored mesh, means that every
## triangle was taken out: the body is then gone.
static func _direct_edit(run: Run) -> String:
	var feature := run.feature
	var pick := run.r.ref("bodies")
	var body_id := str(pick.get("body", ""))
	if body_id == "":
		return "%s names no body" % feature.label
	var name := run.body_name(body_id)
	if not run.ctx.bodies.has(body_id):
		return "Body %s no longer exists" % name
	if not MESH_BODY.is_mesh(run.ctx.bodies[body_id]):
		return NOT_A_MESH % name
	var incoming: RefCounted = run.ctx.bodies[body_id].shape
	var stays := " %s stays as it was before %s." % [name, feature.label]
	var emptied: bool = not feature.options.has("mesh") and feature.options.get("emptied") == true
	var stored := {}
	if not emptied:
		stored = _blob(feature, "mesh")
		if stored.has("error"):
			return str(stored.error) + stays
	var pieces := []
	var outputs: Array = run.r.opt("outputs", [])
	for k in outputs.size():
		var piece := _blob(feature, "extract_%d" % k)
		if piece.has("error"):
			return str(piece.error) + stays
		pieces.append(piece.mesh)
	var edited := str(run.r.opt("input_digest", ""))
	if edited != "" and str(incoming.digest()) != edited:
		run.note(SNAPSHOT_NOTE % [feature.label, name])
	if emptied:
		run.ctx.bodies.erase(body_id)
		_tally(run, incoming, null)
	else:
		replace_body(run.r, body_id, stored.mesh)
		_tally(run, incoming, stored.mesh)
	for k in outputs.size():
		set_body(run.ctx, str(outputs[k]), pieces[k], feature.id)
	return ""


static func _remesh(run: Run) -> String:
	var targets := _targets(run, "bodies", "selection")
	var native := {}
	_choice(run, native, "mode")
	if str(native.get("mode", "uniform")) == "adaptive":
		_take(run, native, "min_edge")
		_take(run, native, "max_edge")
		_take(run, native, "approx_error")
		if native.has("min_edge") and native.has("max_edge") and float(native.max_edge) <= float(native.min_edge):
			return "Maximum Edge (%s) must be more than the Minimum Edge (%s)." % [_mm(float(native.max_edge)), _mm(float(native.min_edge))]
	else:
		_take(run, native, "density")
		_take(run, native, "edge_length")
	_take(run, native, "iterations", "whole")
	_choice(run, native, "keep_sharp")
	if bool(run.r.opt("keep_sharp", true)):
		_take(run, native, "sharp_angle", "angle")
	_choice(run, native, "keep_boundary")
	_choice(run, native, "keep_groups")
	if run.failed():
		return run.problem()
	var error := _each(run, targets, "remesh", native, func(target: Dictionary, options: Dictionary) -> void: _with_selection(target, options))
	if error == "" and run.kept.size() == 1 and run.kept[0].report.has("mean_edge"):
		var report: Dictionary = run.kept[0].report
		var line := "Edges: %s on average" % _mm(float(report.mean_edge))
		if report.has("min_edge") and report.has("max_edge"):
			line += " (Minimum Edge %s, Maximum Edge %s used)" % [_mm(float(report.min_edge)), _mm(float(report.max_edge))]
		run.stat.append(line)
	return error


static func _reduce(run: Run) -> String:
	var targets := _targets(run, "bodies", "selection")
	var native := {}
	_choice(run, native, "target")
	match str(native.get("target", "proportion")):
		"face_count":
			_take(run, native, "face_count", "whole")
		"tolerance":
			_take(run, native, "tolerance")
		_:
			_take(run, native, "proportion")
	_choice(run, native, "algorithm", "method")
	_choice(run, native, "keep_boundary")
	_choice(run, native, "keep_groups")
	_choice(run, native, "keep_sharp")
	if bool(run.r.opt("keep_sharp", false)):
		_take(run, native, "sharp_angle", "angle")
	if run.failed():
		return run.problem()
	return _each(run, targets, "reduce", native, func(target: Dictionary, options: Dictionary) -> void: _with_selection(target, options))


static func _plane_cut(run: Run) -> String:
	var targets := _targets(run, "bodies")
	if run.failed():
		return run.problem()
	var plane := run.r.plane("plane")
	if not run.r.ok():
		return run.r.error
	var native := {"origin": plane.origin, "normal": (plane.normal as Vector3).normalized()}
	_choice(run, native, "type")
	_choice(run, native, "flip")
	_choice(run, native, "fill")
	_take(run, native, "offset")
	if run.failed():
		return run.problem()
	var splits := str(native.get("type", "trim")) == "split_body"
	var cut := []
	for target in targets:
		var mesh: RefCounted = target.mesh
		var kept := _op(run, str(target.name), mesh, "plane_cut", native, func(seconds: float) -> Variant: return mesh.plane_cut(_native(native, seconds, true)))
		if run.failed():
			return run.problem()
		_cross_after(run, kept.report, [target.name], [mesh])
		cut.append(kept)
	var caps := 0
	for k in targets.size():
		var id := str(targets[k].id)
		var parts: Array = cut[k].meshes
		var above: RefCounted = parts[0] if parts.size() > 0 else null
		var below: RefCounted = parts[1] if parts.size() > 1 else null
		caps += _count(cut[k].report.get("cap_triangles"))
		if splits and above != null and below != null:
			var other: String = _made_ids(run, id, 1, id, ["%s (2)" % targets[k].name])[0]
			replace_body(run.r, id, above)
			set_body(run.ctx, other, below, run.feature.id)
			run.outputs.append(id)
			run.outputs.append(other)
			_tally(run, targets[k].mesh, above)
			_tally(run, null, below)
		else:
			var one: RefCounted = above if above != null else below
			replace_body(run.r, id, one)
			_tally(run, targets[k].mesh, one)
			if splits:
				run.creates = true
				run.outputs.append(id)
	if caps > 0:
		run.stat.append("Cut face: %d triangles" % caps)
	return ""


static func _shell(run: Run) -> String:
	var targets := _targets(run, "bodies")
	var native := {}
	_take(run, native, "thickness")
	_choice(run, native, "direction")
	_choice(run, native, "algorithm", "method")
	if str(native.get("method", "accurate")) == "accurate":
		_take(run, native, "detail")
	if run.failed():
		return run.problem()
	var error := _each(run, targets, "shell", native, Callable(), true)
	if error == "":
		for k in targets.size():
			_cross_after(run, run.kept[k].report, [targets[k].name], [targets[k].mesh])
	if error == "" and run.kept.size() == 1:
		var wall: Variant = run.kept[0].report.get("wall")
		if wall is Dictionary and (wall as Dictionary).has("min") and (wall as Dictionary).has("max"):
			run.stat.append("Wall: %s to %s" % [_mm(float(wall.min)), _mm(float(wall.max))])
	return error


static func _combine(run: Run) -> String:
	var r := run.r
	var targets := _targets(run, "target")
	if run.failed():
		return run.problem()
	if targets.size() != 1:
		return "Pick one target mesh body."
	var target: Dictionary = targets[0]
	var target_id := str(target.id)
	var target_mesh: RefCounted = target.mesh
	var operation := str(r.opt("operation", "join"))
	# The tools: mesh bodies as they are, B-rep bodies as triangles (said in a warning).
	var tool_ids := []
	var tool_meshes := []
	var tool_names := PackedStringArray()
	var digests := []
	for pick in r.refs("tools"):
		if not pick is Dictionary:
			continue
		var ids := []
		if str(pick.get("kind", "")) == "component":
			for body_id in run.ctx.bodies:
				if run.doc.body_component(body_id) == str(pick.get("component", "")) and str(body_id) != target_id:
					ids.append(str(body_id))
		else:
			ids.append(str(pick.get("body", "")))
		for id in ids:
			var name := run.body_name(id)
			if id == target_id:
				return "%s can't be its own tool. Pick other bodies as tools." % name
			if not run.ctx.bodies.has(id):
				return "Body %s no longer exists" % name
			if tool_ids.has(id):
				continue
			var found: Dictionary = run.ctx.bodies[id]
			var mesh: RefCounted = found.shape
			if not MESH_BODY.is_mesh(found):
				var made := tessellated(found.shape, "medium", maxf(run.left(), 0.05))
				if made.has("error"):
					return named(str(made.error), name)
				mesh = made.mesh
				run.note(MESH_BODY.TESSELLATED_FOR % [name, "Combine"])
				for line in str(made.get("warning", "")).split("\n", false):
					run.note(named(line.strip_edges(), name))
			tool_ids.append(id)
			tool_meshes.append(mesh)
			tool_names.append(name)
			digests.append(str(mesh.digest()))
	if tool_ids.is_empty():
		return "Pick the tool bodies to combine with %s." % target.name
	var kept: Dictionary
	var input_names := [str(target.name)]
	input_names.append_array(Array(tool_names))
	var input_meshes := [target_mesh]
	input_meshes.append_array(tool_meshes)
	if operation == "merge":
		kept = _op(run, str(target.name), target_mesh, "merge_with", {}, func(_seconds: float) -> Variant: return target_mesh.merge_with(tool_meshes), digests, tool_names)
	else:
		var asked := {"operation": operation, "tool_names": tool_names}
		kept = _op(run, str(target.name), target_mesh, "boolean", asked, func(seconds: float) -> Variant: return target_mesh.boolean(tool_meshes, _native(asked, seconds, true)), digests, tool_names)
	if run.failed():
		# A refusal of bodies that cross themselves names them (a boolean of such a body fails its
		# own checks, and the kernel's sentence may only say to look for them).
		if run.error != "" and not is_time_refusal(run.error):
			for k in input_names.size():
				if crossing_count(input_meshes[k], clampf(run.left(), 0.05, SELF_INTERSECTION_SECONDS)) > 0 and not run.error.contains("%s crosses itself" % input_names[k]):
					run.error += " " + CROSSES % input_names[k]
		return run.problem()
	_cross_after(run, kept.report, input_names, input_meshes)
	var result: RefCounted = kept.meshes[0]
	# A cut that takes all of the target away leaves no body (the kernel's warning says so).
	var empty: bool = result == null or result.is_null()
	if not bool(r.opt("keep_tools", false)):
		for id in tool_ids:
			run.ctx.bodies.erase(id)
	if bool(r.opt("new_body", false)):
		run.creates = true
		if not empty:
			var made_id: String = _made_ids(run, "combine", 1, target_id, ["%s Combined" % target.name])[0]
			set_body(run.ctx, made_id, result, run.feature.id)
			run.outputs.append(made_id)
			_tally(run, null, result, kept.report)
	elif empty:
		run.ctx.bodies.erase(target_id)
		_tally(run, target_mesh, null)
	else:
		replace_body(r, target_id, result)
		_tally(run, target_mesh, result, kept.report)
	return ""


static func _smooth(run: Run) -> String:
	var targets := _targets(run, "bodies", "selection")
	var native := {}
	_take(run, native, "strength")
	_take(run, native, "iterations", "whole")
	_choice(run, native, "keep_volume")
	_choice(run, native, "keep_sharp")
	if bool(run.r.opt("keep_sharp", false)):
		_take(run, native, "sharp_angle", "angle")
	_choice(run, native, "keep_boundary")
	if run.failed():
		return run.problem()
	var error := _each(run, targets, "smooth", native, func(target: Dictionary, options: Dictionary) -> void: _with_selection(target, options))
	if error == "" and run.kept.size() == 1 and run.kept[0].report.has("max_move"):
		run.stat.append("Largest move: %s" % _mm(float(run.kept[0].report.max_move)))
	return error


static func _reverse_normal(run: Run) -> String:
	var mode := str(run.r.opt("mode", "auto"))
	var by_selection := mode == "selection"
	var targets := _targets(run, "", "selection") if by_selection else _targets(run, "bodies")
	if run.failed():
		return run.problem()
	var error := _each(run, targets, "reverse", {"mode": mode}, func(target: Dictionary, options: Dictionary) -> void:
		if by_selection:
			if not (target.triangles as PackedInt32Array).is_empty():
				options["triangles"] = target.triangles
			if not (target.groups as PackedStringArray).is_empty():
				options["groups"] = target.groups)
	if error != "":
		return error
	var flipped := 0
	for kept in run.kept:
		flipped += _count(kept.report.get("flipped_triangles"))
	run.stat.append("Triangles turned round: %d" % flipped)
	return ""


## Erase and Fill: the picked triangles go, and only the holes that leaves are closed. What is
## said is what was done: the holes really filled are counted from Close Holes' own report, a
## hole that stays open is counted too (the kernel's warning says why), and a selection that ran
## into an open edge is told whether that hole was filled with it or not.
static func _erase_fill(run: Run) -> String:
	var targets := _targets(run, "", "selection")
	if run.failed():
		return run.problem()
	if targets.size() != 1:
		return "Pick triangles or face groups of one body to erase."
	var target: Dictionary = targets[0]
	var name := str(target.name)
	var triangles := _picked_triangles(target)
	if triangles.is_empty():
		return "Pick the triangles or face groups of %s to erase." % name
	var mesh: RefCounted = target.mesh
	var erased := _op(run, name, mesh, "delete_triangles", {"triangles": triangles}, func(_seconds: float) -> Variant: return mesh.delete_triangles(triangles))
	if run.failed():
		return run.problem()
	var open: RefCounted = erased.meshes[0]
	var result := open
	var report := {}
	var loops: PackedInt32Array = PackedInt32Array(erased.report.get("new_loops", PackedInt32Array()))
	var merged: PackedInt32Array = PackedInt32Array(erased.report.get("merged_loops", PackedInt32Array()))
	var filled := 0
	var merged_filled := 0
	var outline := PackedInt32Array()
	if not loops.is_empty():
		var native := {"loops": loops}
		_choice(run, native, "fill")
		var notes_before := run.notes.size()
		var closed := _op(run, name, open, "close_holes", native, func(seconds: float) -> Variant: return open.close_holes(_native(native, seconds)))
		if run.failed():
			return run.problem()
		result = closed.meshes[0]
		report = closed.report
		# A loop named to Close Holes is closed whatever it is. Where the erased triangles opened
		# into the outline of an open sheet, that "hole" is the sheet's outline: closing it lays a
		# second surface on the sheet. Such loops are left open: the holes are closed again
		# without them.
		var as_outline: Variant = report.get("picked_outline_loops")
		if (as_outline is PackedInt32Array or as_outline is PackedInt64Array or as_outline is Array) and not as_outline.is_empty():
			for loop in as_outline:
				outline.append(int(loop))
			run.notes.resize(notes_before)
			run.kept.pop_back()
			run.result_crossing.erase(name)
			var rest := PackedInt32Array()
			for loop in loops:
				if not outline.has(loop):
					rest.append(loop)
			result = open
			report = {}
			if not rest.is_empty():
				var native_rest := native.duplicate()
				native_rest["loops"] = rest
				var closed_rest := _op(run, name, open, "close_holes", native_rest, func(seconds: float) -> Variant: return open.close_holes(_native(native_rest, seconds)))
				if run.failed():
					return run.problem()
				result = closed_rest.meshes[0]
				report = closed_rest.report
			run.note("The selection reaches the open outline of %s: the gap it leaves is part of that outline and stays open (filling it would lay a second surface on the sheet)." % name)
		var done: Variant = report.get("filled_loops")
		if done is PackedInt32Array or done is PackedInt64Array or done is Array:
			filled = done.size()
			for loop in merged:
				merged_filled += 1 if done.has(loop) else 0
		else:
			# (A kernel that only counts: the holes asked for less those it says stay open.)
			filled = maxi(loops.size() - _count(report.get("skipped_loops")) - _count(report.get("broken_loops")), 0) if is_same(result, open) == false else 0
			merged_filled = merged.size() if filled == loops.size() else 0
	var left := loops.size() - filled
	if merged_filled > 0:
		run.note("The selection touches an open edge of %s; that hole was filled too." % name)
	elif not merged.is_empty() and outline.is_empty():
		run.note("The selection touches an open edge of %s: the hole it leaves runs into that open edge and was not filled." % name)
	if left > 0:
		var why := not outline.is_empty() and left <= outline.size()
		for note in run.notes:
			why = why or (note.contains(name) and (note.contains("could not be closed") or note.contains("stay open") or note.contains("stays open")))
		if not why:
			run.note("%d of the %d hole%s the erased triangles left in %s could not be closed and stay%s open." % [left, loops.size(), "" if loops.size() == 1 else "s", name, "s" if left == 1 else ""])
	_tally(run, mesh, result, report)
	replace_body(run.r, str(target.id), result)
	var erased_text := "Erased %s triangle%s" % [_commas(triangles.size()), "" if triangles.size() == 1 else "s"]
	if loops.is_empty():
		run.stat.append("%s, no hole to close" % erased_text)
	elif left == 0:
		run.stat.append("%s, closed %d hole%s" % [erased_text, filled, "" if filled == 1 else "s"])
	else:
		run.stat.append("%s, closed %d of %d hole%s (%d stay%s open)" % [erased_text, filled, loops.size(), "" if loops.size() == 1 else "s", left, "s" if left == 1 else ""])
	return ""


## Mesh Align: moves a body so a flat face group of it (or the plane through three points picked
## on it) lies on a plane, face to face (the same way round with flip).
static func _align(run: Run) -> String:
	var r := run.r
	var by_group := not r.refs("source").is_empty()
	var targets := _targets(run, "", "source" if by_group else "points")
	if run.failed():
		return "Pick a flat face group, or three points on the mesh, to align." if r.refs("source").is_empty() and r.refs("points").is_empty() else run.problem()
	if targets.size() != 1:
		return "Pick the face group, or the three points, on one body."
	var target: Dictionary = targets[0]
	var mesh: RefCounted = target.mesh
	var size: float = (mesh.bbox() as AABB).size.length()
	var point := Vector3.ZERO
	var normal := Vector3.ZERO
	if by_group:
		if (target.groups as PackedStringArray).size() != 1:
			return "Pick one flat face group to align."
		var index := int(mesh.find_face(str(target.groups[0])))
		var fit: Dictionary = mesh.fit_primitive(mesh.group_triangles(index))
		var flat: Dictionary = fit.get("plane", {})
		if not bool(flat.get("valid", false)):
			return "That face group is not flat; pick a flat group or three points."
		if float(flat.get("rms", 0.0)) > size / 1000.0:
			return "That face group is not flat (off by %s); pick a flat group or three points." % _mm(float(flat.rms))
		var info: Dictionary = mesh.face_info(index)
		point = info.get("point", Vector3.ZERO)
		normal = (info.get("normal", Vector3.ZERO) as Vector3).normalized()
	else:
		var points: PackedVector3Array = target.points
		if points.size() != 3:
			return "Pick three points on the mesh (or one flat face group); %d %s picked." % [points.size(), "is" if points.size() == 1 else "are"]
		normal = (points[1] - points[0]).cross(points[2] - points[0])
		if normal.length() < 1e-9 * size * size:
			return "The three points lie on one line; pick points that span a plane."
		normal = normal.normalized()
		point = (points[0] + points[1] + points[2]) / 3.0
		# The plane faces the way the surface does where the points were picked.
		var reach := maxf(size * 1e-4, 1e-7)
		var agree := 0.0
		for p in points:
			var hit: Dictionary = mesh.ray_hit(p + normal * reach, -normal, reach * 2.0)
			if bool(hit.get("hit", false)):
				agree += (hit.normal as Vector3).dot(normal)
		if agree < 0.0:
			normal = -normal
	if normal.length() < 0.5:
		return "That face group has no direction to align; pick a flat group or three points."
	var to := r.plane("to")
	if not r.ok():
		return r.error
	var offset := r.num("offset", 0.0)
	if not r.ok():
		return r.error
	var facing: Vector3 = (to.normal as Vector3).normalized()
	var basis := UTIL.rotation_between(normal, facing if bool(r.opt("flip", false)) else -facing)
	var on_plane: Vector3 = (to.origin as Vector3) + facing * offset
	var goal := point - facing * (point - on_plane).dot(facing)
	var xform := Transform3D(basis, goal - basis * point)
	var group := str(target.groups[0]) if by_group else ""
	var asked := {"xform": xform, "group": group, "plane": on_plane, "facing": facing}
	var kept := _op(run, str(target.name), mesh, "align", asked, func(_seconds: float) -> Variant:
		var moved: RefCounted = mesh.transformed(xform)
		# A transform holds single-precision numbers, so the face lands a few nanometers off the
		# plane: measured on the moved mesh and taken out (a pure shift along the plane's normal).
		for pass_index in 3:
			if moved == null or moved.is_null() or not by_group:
				break
			var now: Dictionary = moved.face_info(int(moved.find_face(group)))
			var off := ((now.get("point", on_plane) as Vector3) - on_plane).dot(facing)
			if absf(off) < 1e-10:
				break
			var shifted: RefCounted = moved.transformed(Transform3D(Basis.IDENTITY, -facing * off))
			if shifted == null or shifted.is_null():
				break
			moved = shifted
		return moved)
	if run.failed():
		return run.problem()
	_tally(run, mesh, kept.meshes[0])
	replace_body(r, str(target.id), kept.meshes[0])
	return ""


## The brightness of an image file (the mean of red, green and blue, a byte a pixel, rows from the
## top), kept by path while the file stays as it is: {"bytes", "width", "height", "digest"} or
## {"error"}.
static func _brightness(path: String) -> Dictionary:
	if path.strip_edges() == "":
		return {"error": "Texture Extrude needs an image. Choose a PNG or JPG file."}
	if not FileAccess.file_exists(path):
		return {"error": "The image %s can't be found." % path.get_file()}
	var stamp := "%d:%d" % [FileAccess.get_modified_time(path), FileAccess.get_size(path)]
	var known: Dictionary = _images.get(path, {})
	if not known.is_empty() and str(known.stamp) == stamp:
		return known
	var image := Image.load_from_file(ProjectSettings.globalize_path(path))
	if image == null or image.is_empty():
		return {"error": "The image %s can't be read. Choose a PNG or JPG file." % path.get_file()}
	if image.is_compressed() and image.decompress() != OK:
		return {"error": "The image %s can't be read. Choose a PNG or JPG file." % path.get_file()}
	image.convert(Image.FORMAT_L8)
	var bytes := image.get_data()
	known = {"stamp": stamp, "bytes": bytes, "width": image.get_width(), "height": image.get_height(), "digest": MESH_BLOB.sha256_hex(bytes).substr(0, 32)}
	if _images.size() >= 4:
		_images.erase(_images.keys()[0])
	_images[path] = known
	return known


static func _texture_extrude(run: Run) -> String:
	var targets := _targets(run, "", "selection")
	if run.failed():
		return run.problem()
	if targets.size() != 1:
		return "Pick face groups or triangles of one body to extrude."
	var target: Dictionary = targets[0]
	var mesh: RefCounted = target.mesh
	var image := _brightness(str(run.r.opt("image", "")))
	if image.has("error"):
		return image.error
	var asked := {"image_digest": str(image.digest), "width": int(image.width), "height": int(image.height)}
	_take(run, asked, "depth")
	_choice(run, asked, "mapping")
	_take(run, asked, "tile")
	_take(run, asked, "angle", "angle")
	_choice(run, asked, "invert")
	_take(run, asked, "detail")
	if run.failed():
		return run.problem()
	if not (target.triangles as PackedInt32Array).is_empty():
		asked["triangles"] = target.triangles
	var groups := PackedInt32Array()
	for group in (target.groups as PackedStringArray):
		groups.append(int(mesh.find_face(group)))
	if not groups.is_empty():
		asked["groups"] = groups
	var bytes: PackedByteArray = image.bytes
	var kept := _op(run, str(target.name), mesh, "displace", asked, func(seconds: float) -> Variant:
		var native := _native(asked, seconds, true)
		native.erase("image_digest")
		native["image"] = bytes
		return mesh.displace(native))
	if run.failed():
		return run.problem()
	_cross_after(run, kept.report, [target.name], [mesh])
	_tally(run, mesh, kept.meshes[0], kept.report)
	replace_body(run.r, str(target.id), kept.meshes[0])
	if kept.report.has("max_displacement"):
		run.stat.append("Largest move: %s" % _mm(float(kept.report.max_displacement)))
	return ""


static func _separate(run: Run) -> String:
	var targets := _targets(run, "bodies")
	var native := {}
	_choice(run, native, "by")
	if run.failed():
		return run.problem()
	var split := []
	for target in targets:
		var mesh: RefCounted = target.mesh
		var kept := _op(run, str(target.name), mesh, "separate", native, func(seconds: float) -> Variant: return mesh.separate(_native(native, seconds, true)))
		if run.failed():
			return run.problem()
		_cross_after(run, kept.report, [target.name], [mesh])
		split.append(kept.meshes)
		# The pieces hold the body's own triangles and open edges, so the body is what is counted.
		var same := {"output": {"triangles": int(mesh.triangle_count()), "boundary_edges": ((kept.report as Dictionary).get("input", {}) as Dictionary).get("boundary_edges")}}
		_tally(run, mesh, mesh, same)
	run.creates = true
	var bodies := 0
	for k in targets.size():
		var id := str(targets[k].id)
		var pieces: Array = split[k]
		var names := []
		for i in range(1, pieces.size()):
			names.append("%s (%d)" % [targets[k].name, i + 1])
		var others := _made_ids(run, id, pieces.size() - 1, id, names)
		replace_body(run.r, id, pieces[0])
		run.outputs.append(id)
		for i in range(1, pieces.size()):
			set_body(run.ctx, str(others[i - 1]), pieces[i], run.feature.id)
			run.outputs.append(str(others[i - 1]))
		bodies += pieces.size()
	run.stat.append("Bodies: %d" % bodies)
	return ""


static func _scale(run: Run) -> String:
	var r := run.r
	var targets := _targets(run, "bodies")
	if run.failed():
		return run.problem()
	var factors := Vector3.ONE
	if bool(r.opt("uniform", true)):
		factors = Vector3.ONE * r.num("scale", 1.0)
	else:
		factors = Vector3(r.num("sx", 1.0), r.num("sy", 1.0), r.num("sz", 1.0))
	if not r.ok():
		return r.error
	var keys := ["scale", "scale", "scale"] if bool(r.opt("uniform", true)) else ["sx", "sy", "sz"]
	for axis in 3:
		if factors[axis] < SCALE_MIN * (1.0 - 1e-9) or factors[axis] > SCALE_MAX * (1.0 + 1e-9):
			return "%s must be between %s and %s." % [SCALE_LABELS[keys[axis]], _plain(SCALE_MIN), _plain(SCALE_MAX)]
	var made := []
	for target in targets:
		var mesh: RefCounted = target.mesh
		var pivot := r.point("point", (mesh.bbox() as AABB).get_center())
		if not r.ok():
			return r.error
		var basis := Basis.from_scale(factors)
		var scaled := transformed(mesh, Transform3D(basis, pivot - basis * pivot))
		if scaled == null:
			return named("Scale Mesh failed: %s" % str(mesh.get_last_error()), str(target.name))
		made.append(scaled)
	for k in targets.size():
		_tally(run, targets[k].mesh, made[k])
		replace_body(r, str(targets[k].id), made[k])
	return ""


# --- Create Mesh Section Sketch --------------------------------------------------------------

## The feature itself: it works the section out, refuses what can't be drawn and reports what the
## sketch will hold. The body is left as it is; add_section_sketch() makes the sketch.
static func _section_sketch(run: Run) -> String:
	var found := _section(run)
	if found.has("error"):
		return found.error
	var target: Dictionary = found.target
	_tally(run, target.mesh, target.mesh)
	run.stat.append("Section: %d closed and %d open curve%s, %d line%s%s" % [int(found.closed), int(found.open), "" if int(found.closed) + int(found.open) == 1 else "s",
		int(found.lines), "" if int(found.lines) == 1 else "s", " and %d arc%s" % [int(found.arcs), "" if int(found.arcs) == 1 else "s"] if int(found.arcs) > 0 else ""])
	return ""


## The section a Create Mesh Section Sketch feature asks for: {"target", "frame" (the sketch
## plane: {"origin", "x", "y"}), "plane_ref", "curves": [{"points": PackedVector2Array (plane
## meters), "closed", "pieces": [{"a", "b" (point indices; b may be 0 again on a closed curve),
## "center" (an arc's; lines have none), "ccw"}]}], "closed", "open", "lines", "arcs"}, or
## {"error"}. Warnings join the run's notes.
static func _section(run: Run) -> Dictionary:
	var r := run.r
	var targets := _targets(run, "body")
	if run.failed():
		return {"error": run.problem()}
	if targets.size() != 1:
		return {"error": "Pick one mesh body for the section."}
	var target: Dictionary = targets[0]
	var mesh: RefCounted = target.mesh
	var name := str(target.name)
	var plane := r.plane("plane")
	if not r.ok():
		return {"error": r.error}
	var size: float = (mesh.bbox() as AABB).size.length()
	var tolerance := r.num("tolerance", size / 2000.0)
	if not r.ok():
		return {"error": r.error}
	if tolerance < 0.0 or tolerance > size / 20.0 * (1.0 + 1e-9):
		return {"error": "Simplify Tolerance must be between 0 mm and %s (a twentieth of %s's size)." % [_mm(size / 20.0), name]}
	var pick := r.ref("plane")
	var frame: Dictionary = {}
	var plane_ref := ""
	if str(pick.get("kind", "")) == "origin" and SKETCH_DATA.ORIGIN_PLANES.has(str(pick.get("name", ""))):
		frame = SKETCH_DATA.ORIGIN_PLANES[str(pick.name)]
		plane_ref = str(pick.name)
	else:
		frame = SKETCH_DATA.face_plane(plane.origin, plane.normal)
	var lines: Array = mesh.section(plane.origin, (plane.normal as Vector3).normalized())
	if lines.is_empty():
		return {"error": "The plane does not cut %s." % name}
	var fit := bool(r.opt("fit", false))
	var curves := []
	var closed := 0
	var open := 0
	var line_count := 0
	var arc_count := 0
	var small := 0
	for line in lines:
		var world: PackedVector3Array = line.points
		var loop := bool(line.closed)
		var flat := PackedVector2Array()
		for p in world:
			var rel: Vector3 = p - (frame.origin as Vector3)
			flat.append(Vector2(rel.dot(frame.x), rel.dot(frame.y)))
		if loop and flat.size() > 1 and flat[0].distance_to(flat[flat.size() - 1]) <= size * 1e-9:
			flat.remove_at(flat.size() - 1)
		var late := "Create Mesh Section Sketch took longer than %s s on %s and was stopped. Raise the Simplify Tolerance, or Reduce the body first." % [_seconds_text(run.limit), name]
		var deadline := run.started + int(run.limit * 1e6)
		if Time.get_ticks_usec() > deadline:
			return {"error": late}
		var kept := _simplified(flat, loop, tolerance, deadline)
		if Time.get_ticks_usec() > deadline:
			return {"error": late}
		if kept.size() < (3 if loop else 2):
			small += 1
			continue
		var pieces := _fitted(kept, loop, maxf(tolerance, size * 1e-7), deadline) if fit else _chain(kept.size(), loop)
		if Time.get_ticks_usec() > deadline:
			return {"error": late}
		for piece in pieces:
			if piece.has("center"):
				arc_count += 1
			else:
				line_count += 1
		curves.append({"points": kept, "closed": loop, "pieces": pieces})
		if loop:
			closed += 1
		else:
			open += 1
	if curves.is_empty():
		return {"error": "The section of %s is smaller than the Simplify Tolerance. Lower it." % name}
	if line_count + arc_count > MAX_SECTION_SEGMENTS:
		return {"error": "The section has %d segments; raise the Simplify Tolerance." % (line_count + arc_count)}
	if open > 0:
		run.note("%d section curve%s open." % [open, " is" if open == 1 else "s are"])
	if small > 0:
		run.note("%d section curve%s smaller than the Simplify Tolerance and left out." % [small, " is" if small == 1 else "s are"])
	return {"target": target, "frame": frame, "plane_ref": plane_ref, "curves": curves, "closed": closed, "open": open, "lines": line_count, "arcs": arc_count}


## A chain of points with those left out that lie within tolerance of the line between the ones
## kept (Douglas-Peucker). A closed chain keeps its first point and the one farthest from it.
## Past deadline (Time.get_ticks_usec) it stops with what it has: the caller reads the clock.
static func _simplified(points: PackedVector2Array, closed: bool, tolerance: float, deadline := 0) -> PackedVector2Array:
	var n := points.size()
	if tolerance <= 0.0 or n < 3:
		return points
	var keep := PackedByteArray()
	keep.resize(n)
	keep.fill(0)
	var spans := []
	keep[0] = 1
	if closed:
		var far := 0
		var most := 0.0
		for i in n:
			var d := points[i].distance_squared_to(points[0])
			if d > most:
				most = d
				far = i
		if far == 0:
			return PackedVector2Array()
		keep[far] = 1
		spans.append(Vector2i(0, far))
		spans.append(Vector2i(far, n))
	else:
		keep[n - 1] = 1
		spans.append(Vector2i(0, n - 1))
	while not spans.is_empty():
		var span: Vector2i = spans.pop_back()
		if span.y - span.x < 2:
			continue
		if deadline > 0 and span.y - span.x > 256 and Time.get_ticks_usec() > deadline:
			break
		var a := points[span.x]
		var b := points[span.y % n]
		var along := b - a
		var length := along.length()
		var worst := -1.0
		var at := -1
		for i in range(span.x + 1, span.y):
			var rel := points[i] - a
			var d := 0.0
			if length < 1e-15:
				d = rel.length()
			else:
				var t := clampf(rel.dot(along) / (length * length), 0.0, 1.0)
				d = (rel - along * t).length()
			if d > worst:
				worst = d
				at = i
		if worst > tolerance:
			keep[at] = 1
			spans.append(Vector2i(span.x, at))
			spans.append(Vector2i(at, span.y))
	var out := PackedVector2Array()
	for i in n:
		if keep[i] == 1:
			out.append(points[i])
	return out


## Plain lines along a chain of count points: [{"a", "b"}].
static func _chain(count: int, closed: bool) -> Array:
	var pieces := []
	for i in (count if closed else count - 1):
		pieces.append({"a": i, "b": (i + 1) % count})
	return pieces


## A chain as lines and arcs: a run of ARC_MIN_POINTS or more points that lies on one circle
## within tolerance, turns one way by ARC_MIN_ANGLE or more (and by no more than half a circle)
## and whose chords stay within twice the tolerance of the circle becomes an arc; the rest are
## lines. [{"a", "b"}] with "center" and "ccw" on arcs. Past deadline it stops with what it has.
static func _fitted(points: PackedVector2Array, closed: bool, tolerance: float, deadline := 0) -> Array:
	var n := points.size()
	var last := n if closed else n - 1
	var pieces := []
	var i := 0
	while i < last:
		if deadline > 0 and (i & 63) == 0 and Time.get_ticks_usec() > deadline:
			break
		var best := -1
		var best_center := Vector2.ZERO
		var best_ccw := true
		var j := i + ARC_MIN_POINTS - 1
		while j <= last and j - i < n:
			if deadline > 0 and Time.get_ticks_usec() > deadline:
				break
			var a := points[i]
			var m := points[((i + j) / 2) % n]
			var b := points[j % n]
			var found := _circle(a, m, b)
			if found.is_empty():
				break
			var center: Vector2 = found.center
			var radius: float = found.radius
			var ccw := (m - a).cross(b - m) > 0.0
			var fits := true
			var turned := 0.0
			for k in range(i, j + 1):
				var p := points[k % n]
				if absf(p.distance_to(center) - radius) > tolerance:
					fits = false
					break
				if k > i:
					var q := points[(k - 1) % n]
					var step := (q - center).angle_to(p - center)
					if (step > 0.0) != ccw or absf(step) < 1e-12:
						fits = false
						break
					# The chord between two points must stay near the circle too.
					if radius * (1.0 - cos(absf(step) * 0.5)) > 2.0 * tolerance:
						fits = false
						break
					turned += absf(step)
			if not fits or turned > ARC_MAX_ANGLE + 1e-9:
				break
			if turned >= ARC_MIN_ANGLE:
				best = j
				best_center = center
				best_ccw = ccw
			j += 1
		if best > 0:
			pieces.append({"a": i, "b": best % n, "center": best_center, "ccw": best_ccw})
			i = best
		else:
			pieces.append({"a": i, "b": (i + 1) % n})
			i += 1
	return pieces


## The circle through three points: {"center", "radius"}, or {} when they lie on a line.
static func _circle(a: Vector2, b: Vector2, c: Vector2) -> Dictionary:
	var d := 2.0 * (a.x * (b.y - c.y) + b.x * (c.y - a.y) + c.x * (a.y - b.y))
	var scale := maxf(maxf(a.distance_to(b), b.distance_to(c)), 1e-30)
	if absf(d) < 1e-9 * scale * scale:
		return {}
	var a2 := a.length_squared()
	var b2 := b.length_squared()
	var c2 := c.length_squared()
	var center := Vector2(
		(a2 * (b.y - c.y) + b2 * (c.y - a.y) + c2 * (a.y - b.y)) / d,
		(a2 * (c.x - b.x) + b2 * (a.x - c.x) + c2 * (b.x - a.x)) / d)
	return {"center": center, "radius": center.distance_to(a)}


## Makes the sketch of a Create Mesh Section Sketch feature (section_feature: a "mesh" feature
## with method "section_sketch") from the last rebuild (result): a plain "sketch" feature on the
## cut plane holding the section as fixed lines (and arcs, with Fit Lines and Arcs) that meet at
## shared points. It is not tied to the mesh: later changes to the body leave it as it is. With
## replace, the sketch takes the mesh feature's place in the timeline (the mesh feature is
## removed), so one OK leaves one sketch. Call it inside one document change.
## Returns {"feature" (the sketch; null on a problem), "error", "warning", "curves", "segments"}.
static func add_section_sketch(doc: Resource, result: Dictionary, section_feature: Resource, replace := true) -> Dictionary:
	var failed := {"feature": null, "error": "", "warning": "", "curves": 0, "segments": 0}
	if not MESH_BODY.available():
		failed.error = MESH_BODY.KERNEL_MISSING
		return failed
	if section_feature == null or str(section_feature.options.get("method", "")) != "section_sketch":
		failed.error = "That feature is not a Create Mesh Section Sketch"
		return failed
	var ctx := {
		"kernel": null, "doc": doc, "values": result.get("values", {}), "bodies": result.get("bodies", {}), "sketches": result.get("sketches", {}),
		"construction": result.get("construction", {}), "warnings": {},
	}
	var run := Run.new(UTIL.Reader.new(section_feature, ctx), OK_SECONDS)
	var found := _section(run)
	if found.has("error"):
		failed.error = str(found.error)
		return failed
	var holder: Resource = FEATURE.new()
	holder.options = SKETCH_DATA.new_options(found.frame, str(found.plane_ref))
	var sketch = SKETCH_DATA.new(holder, doc)
	var segments := 0
	for curve in found.curves:
		var points: PackedVector2Array = curve.points
		var ids := {}
		for piece in curve.pieces:
			for end in [int(piece.a), int(piece.b)]:
				if not ids.has(end):
					ids[end] = sketch.add_point(points[end], true)
			if piece.has("center"):
				var center: int = sketch.add_point(piece.center, true)
				if bool(piece.ccw):
					sketch.add_arc(center, ids[int(piece.a)], ids[int(piece.b)])
				else:
					sketch.add_arc(center, ids[int(piece.b)], ids[int(piece.a)])
			else:
				sketch.add_line(ids[int(piece.a)], ids[int(piece.b)])
			segments += 1
	holder.options["note"] = "Made from a section of %s" % str(found.target.name)
	var feature: Resource = doc.add_feature("sketch", "Sketch", {}, holder.options)
	if replace:
		var at: int = doc.feature_index(section_feature.id)
		var from: int = doc.feature_index(feature.id)
		if at >= 0 and from > at:
			doc.features.remove_at(from)
			doc.features.insert(at, feature)
		if at >= 0:
			doc.remove_feature(section_feature.id)
	return {"feature": feature, "error": "", "warning": "; ".join(run.notes), "curves": (found.curves as Array).size(), "segments": segments}
