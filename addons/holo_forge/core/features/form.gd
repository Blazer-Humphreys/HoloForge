@tool
extends RefCounted
## The Form feature (Phase 6): freeform bodies, each a subdivision cage (core/form/cage.gd,
## contract C1) whose smooth limit surface becomes exact B-spline geometry when the timeline is
## rebuilt. Form is direct modelling: the feature has no expression inputs; its options hold
##   {"form_version": 1, "bodies": {body id: cage}, "display": {body id: "box"|"frame"|"smooth"},
##    "quality": "draft"|"standard"|"high", "breps": {body id: PackedByteArray}}.
## Bodies in "breps" were converted inside the form (fixed B-rep, no cage).
##
## While the form is open in the Form environment (ctx.form_preview == its id) nothing is
## converted: the editor draws the cages and the timeline stops after the form (core/regen.gd).
## Otherwise every cage converts through the native CadSubD (one body per connected component),
## through a small cache keyed by the cage's surface content, so a rebuild that leaves a cage as it
## was hands back the very same shapes (the workspace then keeps their tessellation too).

const CAGE := preload("res://addons/holo_forge/core/form/cage.gd")
const UTIL := preload("res://addons/holo_forge/core/features/util.gd")

const DISPLAY_MODES := ["box", "frame", "smooth"]
const DEFAULT_DISPLAY := "smooth"
## Conversion isolation level per quality.
const QUALITY_LEVELS := {"draft": 4, "standard": 6, "high": 8}
## How many converted cages the cache keeps (least recently used go first).
const CACHE_SIZE := 16
## The cage keys the smooth surface depends on (symmetry, frozen and links don't change it).
const SURFACE_KEYS := ["positions", "face_counts", "face_indices", "crease_edges", "crease_weights", "corners", "corner_weights"]

## key -> {"cage": the surface keys of the converted cage, "shapes": Array of CadShape, "report"}.
static var _cache := {}
## Cache keys, least recently used first.
static var _cache_order: Array = []
## How many cages were converted rather than taken from the cache (for tests).
static var convert_count := 0


static func new_options() -> Dictionary:
	return {"form_version": 1, "bodies": {}, "display": {}, "quality": "standard", "breps": {}}


## Empties the conversion cache (tests).
static func clear_cache() -> void:
	_cache.clear()
	_cache_order.clear()


## The conversion isolation level of a quality name (standard for unknown names).
static func isolation(quality: String) -> int:
	return int(QUALITY_LEVELS.get(quality, QUALITY_LEVELS.standard))


## A body's display mode in a form feature ("smooth" when not set).
static func display_mode(feature: Resource, body_id: String) -> String:
	if feature == null:
		return DEFAULT_DISPLAY
	var mode := str((feature.options.get("display", {}) as Dictionary).get(body_id, DEFAULT_DISPLAY))
	return mode if mode in DISPLAY_MODES else DEFAULT_DISPLAY


## The cage body ids of a form feature, in creation order.
static func body_ids(feature: Resource) -> Array:
	if feature == null:
		return []
	return (feature.options.get("bodies", {}) as Dictionary).keys()


## The cage a body shows and converts: the stored one, with its associative links (Match) applied
## against the current geometry of the features before the form. The stored cage never changes.
## The form editor calls this too, so display and conversion agree.
static func effective_cage(cage: Dictionary, ctx: Dictionary, warnings: Array = []) -> Dictionary:
	if (cage.get("links", []) as Array).is_empty():
		return cage
	return _apply_links(cage, ctx, warnings)


## Associative Match links: each link's boundary chain is matched again to its targets as they are
## in this rebuild (core/form/form_fit.gd apply_links; loaded here, not preloaded, so regen's
## preload chain stays short). Targets that can't be found leave the cage as stored.
static func _apply_links(cage: Dictionary, ctx: Dictionary, warnings: Array = []) -> Dictionary:
	var fit: Script = load("res://addons/holo_forge/core/form/form_fit.gd")
	return fit.apply_links(cage, ctx, warnings)


## Text scenes and resources (.tscn / .tres, where the part's document lives) print a double that
## a float32 holds exactly in float32-shortest form and read others back an ulp off, so cage
## positions (often from Vector3 values) and symmetry planes came back changed: partners off by
## 1e-12 m, a new content hash, a changed body. Before a save every cage gets its doubles as bytes
## in "exact" (base64 text); the first rebuild after loading puts them back and drops the key
## (one that no longer matches its cage, after an edit, is just dropped).
const EXACT_KEY := "exact"


## Writes every form cage's exact doubles into it (plugin: before the scene saves; tests: before
## ResourceSaver.save).
static func store_exact(doc: Resource) -> void:
	if doc == null:
		return
	for f in doc.features:
		if f == null or f.type != "form":
			continue
		var bodies: Dictionary = f.options.get("bodies", {})
		for body_id in bodies:
			var cage: Dictionary = bodies[body_id]
			# A key still there was never resolved (no rebuild since the scene loaded: the form is
			# suppressed, after the rollback marker, or Forge wasn't opened): its doubles are the
			# exact ones and the cage holds their text rounding, so it is kept while they agree.
			if cage.has(EXACT_KEY) and not _exact_from(cage).is_empty():
				continue
			cage[EXACT_KEY] = Marshalls.raw_to_base64(_exact_values(cage).to_byte_array())


## The doubles stored under EXACT_KEY when they still agree with the cage to text rounding, else
## empty (an edit made after the save).
static func _exact_from(cage: Dictionary) -> PackedFloat64Array:
	var exact := Marshalls.base64_to_raw(str(cage.get(EXACT_KEY, ""))).to_float64_array()
	var now := _exact_values(cage)
	if exact.size() != now.size() or now.is_empty():
		return PackedFloat64Array()
	for i in now.size():
		# Text keeps about 7 significant digits at worst (float32-shortest); anything farther
		# is an edit made after the save.
		if absf(exact[i] - now[i]) > 1e-7 * maxf(absf(exact[i]), absf(now[i])) + 1e-15:
			return PackedFloat64Array()
	return exact


## positions, then per symmetry entry its origin, normal or axis and step.
static func _exact_values(cage: Dictionary) -> PackedFloat64Array:
	var out := PackedFloat64Array(cage.get("positions", PackedFloat64Array()))
	for entry in cage.get("symmetry", []):
		out.append_array(PackedFloat64Array(entry.get("origin", PackedFloat64Array([0, 0, 0]))))
		out.append_array(PackedFloat64Array(entry.get("normal" if str(entry.get("type", "")) == "mirror" else "axis", PackedFloat64Array([0, 0, 1]))))
		out.append(float(entry.get("step", 0.0)))
	return out


## Puts a cage's stored exact doubles back (true when they were used) and drops the key.
static func resolve_exact(cage: Dictionary) -> bool:
	if not cage.has(EXACT_KEY):
		return false
	var exact := _exact_from(cage)
	cage.erase(EXACT_KEY)
	if exact.is_empty():
		return false
	var n: int = (cage.positions as PackedFloat64Array).size()
	cage.positions = exact.slice(0, n)
	var at := n
	for entry in cage.get("symmetry", []):
		entry.origin = exact.slice(at, at + 3)
		var dir_key := "normal" if str(entry.get("type", "")) == "mirror" else "axis"
		entry[dir_key] = exact.slice(at + 3, at + 6)
		if entry.has("step"):
			entry.step = exact[at + 6]
		at += 7
	return true


## The keys of a cage the smooth surface depends on, for cache comparisons.
static func surface_of(cage: Dictionary) -> Dictionary:
	var out := {}
	for key in SURFACE_KEYS:
		out[key] = cage.get(key)
	return out


## Converts a cage: {"shapes": Array of CadShape (one per connected component, by lowest face),
## "report": the native report, "error": "" or why it failed, "cached": bool}. cache_key ("" for
## none) names the body, so two bodies with the same cage keep their own face names.
static func convert_cage(cage: Dictionary, quality: String, prefix: String, cache_key := "") -> Dictionary:
	var key := ""
	var surface := surface_of(cage)
	if cache_key != "":
		key = "%d:%s:%s" % [CAGE.content_hash(cage), quality, cache_key]
		var hit: Dictionary = _cache.get(key, {})
		if not hit.is_empty() and hit.cage == surface:
			_cache_order.erase(key)
			_cache_order.append(key)
			return {"shapes": hit.shapes, "report": hit.report, "error": "", "cached": true}
	if not ClassDB.class_exists("CadSubD"):
		return {"shapes": [], "report": {}, "error": "The Holo Forge kernel is not loaded", "cached": false}
	if CAGE.face_count(cage) == 0:
		return {"shapes": [], "report": {}, "error": "The cage has no faces", "cached": false}
	var subd: RefCounted = ClassDB.instantiate("CadSubD")
	if not subd.set_cage(cage):
		return {"shapes": [], "report": {}, "error": _native_error(subd, "The cage can't be subdivided"), "cached": false}
	convert_count += 1
	var shapes: Array = subd.to_shapes({"isolation": isolation(quality), "name_prefix": prefix})
	var report: Dictionary = subd.get_last_report()
	if shapes.is_empty():
		return {"shapes": [], "report": report, "error": _native_error(subd, "The smooth surface could not be converted"), "cached": false}
	if key != "":
		_cache[key] = {"cage": surface.duplicate(true), "shapes": shapes, "report": report}
		_cache_order.erase(key)
		_cache_order.append(key)
		while _cache_order.size() > CACHE_SIZE:
			_cache.erase(_cache_order.pop_front())
	return {"shapes": shapes, "report": report, "error": "", "cached": false}


static func _native_error(subd: RefCounted, fallback: String) -> String:
	var text := str(subd.get_last_error())
	return text if text != "" else fallback


## Puts the form's bodies into the rebuild: its converted B-rep bodies always, its cage bodies
## converted unless the form is open (previewing). Writes the form's summary into ctx.forms:
## {"preview", "bodies": [cage body ids], "outputs": {body id: [result body ids]},
## "errors": {body id: text}}. A body that fails is reported and the others still convert.
static func build(feature: Resource, ctx: Dictionary) -> String:
	var options: Dictionary = feature.options
	var bodies: Dictionary = options.get("bodies", {})
	var breps: Dictionary = options.get("breps", {})
	var preview: bool = str(ctx.get("form_preview", "")) == str(feature.id)
	for body_id in bodies:
		resolve_exact(bodies[body_id])
	var summary := {"preview": preview, "bodies": bodies.keys(), "outputs": {}, "errors": {}}
	if ctx.has("forms"):
		ctx.forms[feature.id] = summary
	var doc: Resource = ctx.get("doc")
	var errors := PackedStringArray()
	for body_id in breps:
		var shape: RefCounted = ClassDB.instantiate("CadShape") if ClassDB.class_exists("CadShape") else null
		if shape == null or not shape.load_brep_bytes(breps[body_id]):
			summary.errors[body_id] = "This converted body could not be read"
			errors.append("%s: %s" % [_body_name(doc, str(body_id)), summary.errors[body_id]])
			continue
		ctx.bodies[body_id] = {"id": body_id, "shape": shape, "feature": feature.id}
		summary.outputs[body_id] = [body_id]
		# What its conversion warned about (Convert keeps it): the cage is gone, the problem isn't.
		for note in (options.get("brep_notes", {}) as Dictionary).get(body_id, PackedStringArray()):
			_warn(feature, ctx, "%s %s" % [_body_name(doc, str(body_id)), note] if str(note).begins_with("converted by") else "%s: %s" % [_body_name(doc, str(body_id)), note])
	if preview:
		return "; ".join(errors)
	if bodies.is_empty() and breps.is_empty():
		_warn(feature, ctx, "%s has no bodies" % feature.label)
		return ""
	var quality := str(options.get("quality", "standard"))
	for body_id in bodies:
		var id := str(body_id)
		var name := _body_name(doc, id)
		var link_notes: Array = []
		var cage := effective_cage(bodies[body_id], ctx, link_notes)
		for note in link_notes:
			_warn(feature, ctx, "%s: %s" % [name, note])
		var r := convert_cage(cage, quality, feature.id + "/" + id, feature.id + ":" + id)
		if r.error != "":
			summary.errors[id] = r.error
			errors.append("%s: %s" % [name, r.error])
			continue
		var ids := []
		var shapes: Array = r.shapes
		for k in shapes.size():
			var out_id := id if k == 0 else UTIL.derived_body_id(id, feature.id, k + 1)
			ctx.bodies[out_id] = {"id": out_id, "shape": shapes[k], "feature": feature.id}
			ids.append(out_id)
		summary.outputs[id] = ids
		for note in conversion_notes(r.report) + flat_crease_notes(cage):
			_warn(feature, ctx, "%s %s" % [name, note] if note.begins_with("converted by") else "%s: %s" % [name, note])
	return "; ".join(errors)


## Creased edges between cage faces that are almost flat to each other (under 3 degrees), as a
## warning: such a crease (an old rim left behind by an extrude, say) ends sharp edges in smooth
## surface, and OCCT's fillets, shells and offsets near it fail ("radius too big?") though the
## radius isn't what is wrong. Empty when there are none.
static func flat_crease_notes(cage: Dictionary) -> PackedStringArray:
	var creases := CAGE.crease_map(cage)
	if creases.is_empty():
		return PackedStringArray()
	var topo := CAGE.topology(cage)
	var flat := 0
	var limit := cos(deg_to_rad(3.0))
	for key in creases:
		if float(creases[key]) <= 0.0:
			continue
		var e := topo.edge_index(int(key) >> 32, int(key) & 0xFFFFFFFF)
		if e < 0:
			continue
		var faces := topo.edge_faces(e)
		if faces.size() != 2:
			continue
		var n0 := topo.face_normal(cage, faces[0])
		var n1 := topo.face_normal(cage, faces[1])
		if n0.length() > 0.0 and n1.length() > 0.0 and n0.normalized().dot(n1.normalized()) > limit:
			flat += 1
	if flat == 0:
		return PackedStringArray()
	return PackedStringArray(["%d creased edge(s) lie between nearly flat faces; fillets, shells and offsets near them can fail, so uncrease them if they aren't wanted" % flat])


## The warnings a conversion report holds, in words: sewing, pieces that aren't valid solids, and
## the native warnings (flat or folded cages, self-intersections, degenerate faces, pinches, C0
## seams).
static func conversion_notes(report: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	var sewn := false
	var invalid := 0
	for component in report.get("components", []):
		if str((component as Dictionary).get("method", "direct")) == "sewing":
			sewn = true
		if not bool((component as Dictionary).get("valid", true)):
			invalid += 1
	if sewn:
		out.append("converted by sewing (slower path)")
	if invalid > 0:
		out.append("%d converted piece(s) failed the B-rep validity check (try Repair Body)" % invalid)
	for note in report.get("warnings", PackedStringArray()):
		if not str(note).contains("converted by sewing") and not out.has(str(note)):
			out.append(str(note))
	return out


static func _body_name(doc: Resource, body_id: String) -> String:
	return doc.body_name(body_id) if doc != null else body_id


## Adds a note to the feature's warnings (joined with "; ", as UTIL.add_warning does).
static func _warn(feature: Resource, ctx: Dictionary, note: String) -> void:
	if note == "" or not ctx.has("warnings"):
		return
	var before := str(ctx.warnings.get(feature.id, ""))
	if before.contains(note):
		return
	ctx.warnings[feature.id] = note if before == "" else before + "; " + note
