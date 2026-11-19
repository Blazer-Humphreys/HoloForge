@tool
extends RefCounted
## Replays a document's timeline through the CAD kernel.
##
## rebuild() returns {"bodies": {id: {"id", "shape", "feature"}; a mesh body's entry also has
## "kind": "mesh" and a CadMesh as its shape (core/mesh/mesh_body.gd)}, "errors": {feature_id: text},
## "warnings": {feature_id: text}, "values": parameter results, "sketches": {id: profiles},
## "construction": {id: plane/axis/point}, "threads": {key: cosmetic thread}, "forms": {id: form
## summary (core/features/form.gd)}, "made_by": {body_id: the feature that last made or changed
## it}}. Features after the rollback marker and suppressed ones are
## skipped; a failing feature is reported and the rest of the timeline still runs.
##
## options: "form_preview" (a form feature id): that form is open in the Form environment, so its
## cage bodies are not converted (the editor draws them) and the timeline stops after it.
## "mesh_time_limit" (seconds): how long a Mesh feature may run (MESH.OK_SECONDS when missing; a
## command preview passes MESH.PREVIEW_SECONDS). Handlers read it as ctx.mesh_time_limit.
## "mesh_preview_feature" (a feature id): the feature a command is previewing. With it, that
## feature gets "mesh_time_limit", and the timeline stops after it, as it does for an open form:
## the features after it are not run (they would each run in full on every preview tick), so the
## result shows the bodies as they leave the previewed feature. result.preview_stops_at then names
## that feature (only when an active feature after it, not suppressed, was left out). With a
## limit under MESH.OK_SECONDS, the Mesh features before it (PREVIEW_TIMED types) use their kept
## results; one whose kept result is gone
## has to be worked out again, and together they get PREVIEW_LEAD_SECONDS for that: each runs with
## what is left of it as its limit, and none starts once it is used up. When they do not fit, the
## preview stops before the one that does not (it is not run, or its refusal under the shortened
## limit is not kept as its error): result.preview_stops_at names the feature before it, and
## result.preview_stopped (also the previewed feature's warning) says why. B-rep features before
## the previewed one run as in every rebuild. Without the option the limit is the whole rebuild's
## and every feature runs.
##
## Stored meshes: a feature whose stored mesh (a MeshBlob in its options) is damaged, or is not the
## one its file beside the scene is named after, is not run; its error says so (stored_mesh_problem).
## Each blob is checked once (MeshBlob.check), whether or not its result is still kept.
##
## After a feature ran, feature_note() adds what it left out without an error: a Mirror or
## Pattern of a feature leaves that feature's mesh bodies out; a Derive whose source stopped
## making a body no longer brings it in.
##
## Mesh bodies and B-rep features: a feature of a type not in MESH_AWARE whose picks point at a
## mesh body is not run; its error is the gate sentence (UTIL.MESH_GATE). The handlers refuse mesh
## bodies themselves too (UTIL.Reader); this check also covers picks a handler reads on its own.

const PARAMETERS := preload("res://addons/holo_forge/core/parameters.gd")
const PRIMITIVE := preload("res://addons/holo_forge/core/features/primitive.gd")
const SKETCH := preload("res://addons/holo_forge/core/features/sketch.gd")
const SKETCH_SOLID := preload("res://addons/holo_forge/core/features/sketch_solid.gd")
const HOLE := preload("res://addons/holo_forge/core/features/hole.gd")
const PATTERN := preload("res://addons/holo_forge/core/features/pattern.gd")
const MODIFY := preload("res://addons/holo_forge/core/features/modify.gd")
const CONSTRUCT := preload("res://addons/holo_forge/core/features/construct.gd")
const INSERT := preload("res://addons/holo_forge/core/features/insert.gd")
const SURFACE := preload("res://addons/holo_forge/core/features/surface.gd")
const FORM := preload("res://addons/holo_forge/core/features/form.gd")
const MESH := preload("res://addons/holo_forge/core/features/mesh.gd")
const MESH_BODY := preload("res://addons/holo_forge/core/mesh/mesh_body.gd")
const MESH_BLOB := preload("res://addons/holo_forge/core/mesh/mesh_blob.gd")

const HANDLERS := {
	"box": PRIMITIVE, "cylinder": PRIMITIVE, "sphere": PRIMITIVE, "torus": PRIMITIVE, "coil": PRIMITIVE, "pipe": PRIMITIVE,
	"sketch": SKETCH,
	"extrude": SKETCH_SOLID, "revolve": SKETCH_SOLID, "sweep": SKETCH_SOLID, "loft": SKETCH_SOLID,
	"rib": SKETCH_SOLID, "web": SKETCH_SOLID, "emboss": SKETCH_SOLID,
	"hole": HOLE, "thread": HOLE,
	"rect_pattern": PATTERN, "circ_pattern": PATTERN, "path_pattern": PATTERN, "mirror": PATTERN,
	"fillet": MODIFY, "chamfer": MODIFY, "shell": MODIFY, "draft": MODIFY, "scale": MODIFY, "combine": MODIFY,
	"offset_face": MODIFY, "replace_face": MODIFY, "split_face": MODIFY, "split_body": MODIFY,
	"silhouette_split": MODIFY, "move": MODIFY, "align": MODIFY, "remove": MODIFY, "thicken": MODIFY,
	"boundary_fill": MODIFY, "base_feature": MODIFY,
	"plane": CONSTRUCT, "axis": CONSTRUCT, "point": CONSTRUCT,
	"import": INSERT, "mesh_import": INSERT, "derive": INSERT, "fastener": INSERT,
	"surface": SURFACE,
	"form": FORM,
	"mesh": MESH,
}
## Feature types that take mesh bodies (their handlers check each pick themselves).
const MESH_AWARE := ["mesh", "mesh_import", "move", "remove"]
## Feature types whose kept results a preview leans on (see "mesh_preview_feature").
const PREVIEW_TIMED := ["mesh"]
## How long the Mesh features before a previewed one may take together when they have to be
## worked out again (seconds; the previewed feature has its own "mesh_time_limit").
const PREVIEW_LEAD_SECONDS := 1.0
## Why a preview stopped before the previewed feature (%s: its label, then the earlier feature's /
## the seconds the earlier features took).
const PREVIEW_STOPPED_FEATURE := "%s is not previewed: %s, earlier in the timeline, has to be worked out again (its kept result is gone) and takes longer than a preview may. Click OK to build it in full."
const PREVIEW_STOPPED_TIME := "%s is not previewed: the Mesh features before it took %s s to work out again (their kept results are gone), longer than a preview may. Click OK to build it in full."
## Reference kinds that point at a B-rep body or a part of one.
const BREP_PICK_KINDS := ["body", "face", "edge", "vertex"]
## How deep a feature's options are searched for picks.
const PICK_DEPTH := 6
## Feature types that copy other features (options.object_type "features" or "faces").
const COPY_TYPES := ["rect_pattern", "circ_pattern", "path_pattern", "mirror"]
## Operations that give a feature bodies of its own (as core/operations.gd creates_body).
const BODY_OPERATIONS := ["new_body", "new_component"]


## The native kernel, or null when the GDExtension is not loaded (exported games, broken builds).
static func make_kernel() -> RefCounted:
	if ClassDB.class_exists("CadKernel"):
		return ClassDB.instantiate("CadKernel")
	return null


static func rebuild(doc: Resource, kernel: RefCounted, options := {}) -> Dictionary:
	var result := {
		"bodies": {}, "errors": {}, "warnings": {}, "values": PARAMETERS.evaluate(doc), "sketches": {},
		"construction": {}, "threads": {}, "forms": {}, "made_by": {},
		# Where each Extrude starts: {feature id: {"origin", "normal"}} (the profile's plane, its
		# normal before Flip). Its arrow stands there even when a Join swallowed the pulled face.
		"profile_frames": {},
	}
	var form_preview := str(options.get("form_preview", ""))
	var mesh_preview := str(options.get("mesh_preview_feature", ""))
	# Tool shapes of Create features, for patterns and mirrors of features.
	var tools := {}
	var count: int = doc.active_count()
	# Where the previewed feature is (-1: no preview), and when the rebuild started.
	var previewed := -1
	for i in count:
		if mesh_preview != "" and str(doc.features[i].id) == mesh_preview:
			previewed = i
			break
	var started := Time.get_ticks_usec()
	# (Only a preview with a short limit leans on kept results; one with the full time runs all.)
	var leaning := previewed >= 0 and float(options.get("mesh_time_limit", MESH.OK_SECONDS)) < MESH.OK_SECONDS
	for i in count:
		var feature: Resource = doc.features[i]
		# The open form is the last feature replayed while it previews.
		# So is the feature a Mesh command previews (see "mesh_preview_feature" above).
		var last: bool = (form_preview != "" and feature.id == form_preview) or i == previewed
		if i == previewed and _active_after(doc, i, count):
			result["preview_stops_at"] = feature.id
		# A Mesh feature before the previewed one gets what is left of PREVIEW_LEAD_SECONDS.
		var lead := -1.0
		if leaning and i < previewed and not feature.suppressed and PREVIEW_TIMED.has(feature.type):
			var spent := (Time.get_ticks_usec() - started) / 1000000.0
			lead = PREVIEW_LEAD_SECONDS - spent
			if lead <= 0.0:
				_stop_preview(result, doc, previewed, i, PREVIEW_STOPPED_TIME % [doc.features[previewed].label, String.num(spent, 1)])
				break
		if feature.suppressed:
			if last:
				break
			continue
		if kernel == null:
			result.errors[feature.id] = "The Holo Forge kernel is not loaded"
			if last:
				break
			continue
		var handler = HANDLERS.get(feature.type)
		if handler == null:
			result.errors[feature.id] = "Unknown feature type '%s'" % feature.type
			if last:
				break
			continue
		var ctx := {
			"kernel": kernel, "doc": doc, "values": result.values, "bodies": result.bodies, "sketches": result.sketches,
			"construction": result.construction, "tools": tools, "warnings": result.warnings, "threads": result.threads,
			"forms": result.forms, "form_preview": form_preview, "profile_frames": result.profile_frames,
			"mesh_time_limit": maxf(lead, 0.05) if lead > 0.0 else feature_time_limit(feature, options),
		}
		var error := stored_mesh_problem(feature)
		if error == "":
			error = mesh_gate(feature, result.bodies, doc)
		# (Looked at before the feature runs: the picks point into the bodies as they are now.)
		var unconfirmed := unconfirmed_picks(feature, result.bodies) if error == "" else ""
		var shapes_before := {}
		for body_id in result.bodies:
			shapes_before[body_id] = (result.bodies[body_id] as Dictionary).get("shape")
		if error == "":
			error = handler.build(feature, ctx)
		if lead > 0.0 and error != "" and _preview_refusal(error):
			# It would fit the full time: only the preview has no room for it.
			_stop_preview(result, doc, previewed, i, PREVIEW_STOPPED_FEATURE % [doc.features[previewed].label, feature.label])
			break
		# Which feature last made or changed each body (a Combine changes its target): what is
		# found wrong with a body's drawing later is told on that feature (see note_drawing).
		for body_id in result.bodies:
			if not shapes_before.has(body_id) or not is_same(shapes_before[body_id], (result.bodies[body_id] as Dictionary).get("shape")):
				result.made_by[body_id] = feature.id
		if error != "":
			result.errors[feature.id] = error
		else:
			var note := feature_note(feature, result, doc)
			if unconfirmed != "":
				note = unconfirmed if note == "" else note + " " + unconfirmed
			if note != "":
				var before := str(result.warnings.get(feature.id, ""))
				result.warnings[feature.id] = note if before == "" else before + "; " + note
		if last:
			break
	# What each Create feature did (an automatic one's Join, Cut or New Body), for its panel, and
	# the tool shape of each Join or Cut, which its open command draws as what it adds or takes away.
	result["operations"] = {}
	result["tool_shapes"] = {}
	for id in tools:
		var op := str(tools[id].get("operation", ""))
		result.operations[id] = op
		if op == "join" or op == "cut":
			result.tool_shapes[id] = tools[id].get("shape")
	return result


## True when an active feature after index i is not suppressed (a preview that stops at i leaves
## something out).
static func _active_after(doc: Resource, i: int, count: int) -> bool:
	for j in range(i + 1, count):
		if not doc.features[j].suppressed:
			return true
	return false


## True for a refusal a Mesh feature gave only because a preview shortened its time limit (its
## estimate or its run is over that limit, not over the full one).
static func _preview_refusal(error: String) -> bool:
	if not MESH.is_time_refusal(error):
		return false
	var full := MESH._seconds_text(MESH.OK_SECONDS)
	return not (error.contains("(limit %s s)" % full) or error.contains("longer than %s s" % full))


## Ends a preview before the feature at index at (it is not run, or what it did is not kept): the
## bodies are as the features before it leave them. preview_stops_at names the feature before it;
## the sentence is preview_stopped and the previewed feature's warning.
static func _stop_preview(result: Dictionary, doc: Resource, previewed: int, at: int, sentence: String) -> void:
	result["preview_stops_at"] = doc.features[maxi(at - 1, 0)].id
	result["preview_stopped"] = sentence
	var feature_id: String = doc.features[previewed].id
	var before := str(result.warnings.get(feature_id, ""))
	result.warnings[feature_id] = sentence if before == "" else before + "; " + sentence


## Tells what a body's tessellation found wrong with its drawing (CadShape.tessellate's
## "warnings": a face the mesher left out, a mesh that doesn't cover a face) on the feature that
## last made or changed the body, as that feature's warning, so the timeline shows it and not the
## console alone. body_name names the body in the note.
static func note_drawing(result: Dictionary, body_id: String, tess: Dictionary, body_name: String) -> void:
	var told: Array = Array(tess.get("warnings", []))
	var feature_id := str((result.get("made_by", {}) as Dictionary).get(body_id, ""))
	if told.is_empty() or feature_id == "" or (result.get("errors", {}) as Dictionary).has(feature_id):
		return
	var note := "%s is drawn wrong: %s" % [body_name, "; ".join(PackedStringArray(told))]
	var before := str(result.warnings.get(feature_id, ""))
	if not before.contains(note):
		result.warnings[feature_id] = note if before == "" else before + "; " + note


## The warning for a feature's face group picks that could not be confirmed ("" when every pick
## is sure): a pick kept by name alone, or by name and point without how the face looked there,
## cannot be told from another face that got its name (MESH_BODY.resolve_group "unchecked"). The
## feature still works on the group of that name; the warning says that it could not be checked.
static func unconfirmed_picks(feature: Resource, bodies: Dictionary) -> String:
	var any := false
	for body_id in bodies:
		if MESH_BODY.is_mesh(bodies[body_id]):
			any = true
			break
	if not any:
		return ""
	var found := {}
	_unconfirmed(feature.options, bodies, PICK_DEPTH, found)
	var notes := PackedStringArray()
	for group in found:
		notes.append(MESH_BODY.unchecked_note(feature.label, str(group), str(found[group])))
	return " ".join(notes)


static func _unconfirmed(value: Variant, bodies: Dictionary, depth: int, found: Dictionary) -> void:
	if value is Dictionary:
		var item: Dictionary = value
		if str(item.get("kind", "")) == MESH_BODY.GROUP_REF and item.get("body") is String:
			var entry: Variant = bodies.get(item.body)
			if entry is Dictionary and MESH_BODY.is_mesh(entry):
				var now: Dictionary = MESH_BODY.resolve_group(entry.shape, item)
				if bool(now.get("unchecked", false)) and not found.has(str(now.name)):
					found[str(now.name)] = str(now.get("why", ""))
			return
		if depth > 0:
			for key in item:
				if item[key] is Dictionary or item[key] is Array:
					_unconfirmed(item[key], bodies, depth - 1, found)
	elif value is Array and depth > 0:
		for inner in value:
			if inner is Dictionary or inner is Array:
				_unconfirmed(inner, bodies, depth - 1, found)


## The gate sentence when a feature that only takes B-rep bodies picks a mesh body (or a face,
## edge or vertex of one), else "". Costs nothing in a design without mesh bodies.
static func mesh_gate(feature: Resource, bodies: Dictionary, doc: Resource) -> String:
	if MESH_AWARE.has(feature.type):
		return ""
	var any := false
	for body_id in bodies:
		if MESH_BODY.is_mesh(bodies[body_id]):
			any = true
			break
	if not any:
		return ""
	var hit := _mesh_pick(feature.options, bodies, PICK_DEPTH)
	return MESH_BODY.GATE % MESH_BODY.body_name(doc, hit) if hit != "" else ""


## The id of the first mesh body a B-rep pick in value (options, lists of picks) points at, or "".
static func _mesh_pick(value: Variant, bodies: Dictionary, depth: int) -> String:
	if value is Dictionary:
		var item: Dictionary = value
		if BREP_PICK_KINDS.has(item.get("kind")) and item.get("body") is String:
			var found: Variant = bodies.get(item.body)
			if found is Dictionary and MESH_BODY.is_mesh(found):
				return str(item.body)
		if depth > 0:
			for key in item:
				var inner: Variant = item[key]
				if inner is Dictionary or inner is Array:
					var hit := _mesh_pick(inner, bodies, depth - 1)
					if hit != "":
						return hit
	elif value is Array and depth > 0:
		for inner in value:
			if inner is Dictionary or inner is Array:
				var hit := _mesh_pick(inner, bodies, depth - 1)
				if hit != "":
					return hit
	return ""


## How long a Mesh feature may run in a rebuild with these options (seconds): the rebuild's
## "mesh_time_limit" for the previewed feature ("mesh_preview_feature"), or for every feature when
## none is named; MESH.OK_SECONDS otherwise.
static func feature_time_limit(feature: Resource, options: Dictionary) -> float:
	var previewed := str(options.get("mesh_preview_feature", ""))
	if previewed != "" and str(feature.id) != previewed:
		return MESH.OK_SECONDS
	return float(options.get("mesh_time_limit", MESH.OK_SECONDS))


## What is wrong with a feature's stored mesh (a MeshBlob among its options), or "":
## its bytes no longer match their checksum ("The stored mesh of <Feature> is damaged (...)."), or
## the file it was loaded from is named after another mesh (the files beside a scene are named
## <part>_mesh_<the digest's first 16 characters>.res, so a file swapped for another one shows).
static func stored_mesh_problem(feature: Resource) -> String:
	for key in feature.options:
		var blob: Variant = feature.options[key]
		if not (blob is Resource) or (blob as Resource).get_script() != MESH_BLOB:
			continue
		var missing := str(blob.missing_file())
		if missing != "":
			# (A stand-in a Save put there so the scene keeps pointing at the file: CadPart.)
			return "%s holds no stored mesh: its file %s is missing or can't be read (%s). Put the file back and open the scene again, or delete %s." % [feature.label, missing.get_file(), missing, feature.label]
		var file := str((blob as Resource).resource_path).get_file()
		if names_another(blob):
			return "The stored mesh of %s is not the one saved with it: %s holds another mesh. Put back the file that was saved with the design, or delete %s." % [feature.label, file, feature.label]
		var problem: String = blob.check()
		if problem != "":
			if file != "" and not str((blob as Resource).resource_path).contains("::"):
				return "The stored mesh of %s is damaged (%s). Put back a sound copy of %s, or delete %s." % [feature.label, problem, file, feature.label]
			return "The stored mesh of %s is damaged (%s). Open a copy of the design that still has it, or delete %s." % [feature.label, problem, feature.label]
	return ""


## True when a stored mesh was loaded from a file that is named after another mesh (the files
## beside a scene are named <part>_mesh_<the digest's first 16 characters>.res). The name the
## scene points at is the truth: a Save never takes such a mesh over (CadPart.save_mesh_blobs).
static func names_another(blob: Resource) -> bool:
	var file := str(blob.resource_path).get_file()
	var mark := file.rfind("_mesh_")
	var named := file.substr(mark + 6).trim_suffix(".res") if mark >= 0 and file.ends_with(".res") else ""
	# (Only a name of the kind CadPart writes: 16 hex digits of the digest.)
	return named.length() == 16 and named.is_valid_hex_number() and not str(blob.digest).begins_with(named)


## The file a feature's stored mesh (options[key]) is kept in, read from the text of the scene
## (or resource) file the feature was loaded from: "" when the feature is not from such a file,
## or the file keeps the mesh inside itself. (For an option that came back empty because its
## file is gone.)
static func stored_file(feature: Resource, key: String, texts := {}) -> String:
	var own := str(feature.resource_path)
	if not own.contains("::"):
		return ""
	var scene := own.get_slice("::", 0)
	if not scene.get_extension().to_lower() in ["tscn", "tres"] or not FileAccess.file_exists(scene) or FileAccess.get_size(scene) > 64 * 1024 * 1024:
		return ""
	# (texts keeps the files read during one Save.)
	if not texts.has(scene):
		texts[scene] = FileAccess.get_file_as_string(scene)
	var text := str(texts[scene])
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


## What a feature that built without an error still left out, as a warning ("" when nothing):
##   a Mirror or Pattern of features copies only the B-rep results of those features; the mesh
##   bodies they made (a Derive of a design with mesh bodies) are named;
##   a Derive (of every body of its source) whose source stopped making a body names the bodies
##   that no longer come in.
static func feature_note(feature: Resource, result: Dictionary, doc: Resource) -> String:
	var bodies: Dictionary = result.bodies
	if COPY_TYPES.has(feature.type) and str(feature.options.get("object_type", "bodies")) in ["features", "faces"]:
		var notes := PackedStringArray()
		for pick in feature.options.get("objects", []):
			if not (pick is Dictionary) or str(pick.get("kind", "")) != "feature":
				continue
			var source: Resource = doc.find_feature(str(pick.get("feature", "")))
			var names := PackedStringArray()
			for body_id in doc.bodies:
				if str((doc.bodies[body_id] as Dictionary).get("feature", "")) == str(pick.get("feature", "")) and MESH_BODY.is_mesh(bodies.get(body_id, {})):
					names.append(doc.body_name(body_id))
			if not names.is_empty():
				notes.append("%s copies only the B-rep bodies of %s: its mesh bod%s (%s) %s left out. Use Move/Copy for mesh bodies." % [
					feature.label, source.label if source != null else "that feature", "y" if names.size() == 1 else "ies", ", ".join(names), "is" if names.size() == 1 else "are"])
		return " ".join(notes)
	if feature.type == "derive" and (feature.options.get("bodies", []) as Array).is_empty() and BODY_OPERATIONS.has(str(feature.options.get("operation", "new_body"))):
		var gone := PackedStringArray()
		for mapped in (feature.options.get("body_map", {}) as Dictionary).values():
			if not bodies.has(str(mapped)) and doc.bodies.has(str(mapped)):
				gone.append(doc.body_name(str(mapped)))
		if not gone.is_empty():
			return "%s no longer brings in %s: %s does not make %s any more." % [feature.label, ", ".join(gone), str(feature.options.get("path", "")).get_file(), "it" if gone.size() == 1 else "them"]
	return ""
