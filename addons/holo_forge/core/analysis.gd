@tool
extends RefCounted
## Inspect analyses: the display data the view shows for an entry of doc.analyses
## ({"id", "type", "name", "visible", "options"}).
##
## build(analysis, result, tessellations, kernel, doc, poses = {}) returns:
##   "body_meshes"     {body id: ArrayMesh} vertex-colored copies of bodies (draft, curvature_map,
##                     minimum_radius, accessibility); other types leave the view's own mesh
##   "body_materials"  {body id: Material} what each body is drawn with while the analysis shows
##   "lines"           [{"points": PackedVector3Array (a polyline), "color": Color, "body": id}]
##   "meshes"          [{"mesh": ArrayMesh, "material": Material, "body": id}] extra geometry
##   "points"          [{"position": Vector3, "color": Color, "label": String, "body": id}]
##                     ("body", Phase 8: the body an entry belongs to, in its modelled place; the
##                     view moves it with that body's pose. Entries of no body, such as combs of
##                     sketch curves and the total Center of Mass of several bodies, have none.)
## poses ({body id: xform64}, optional): where an assembly puts the bodies; only the total Center
## of Mass of several bodies uses it (every other entry follows its body).
##   "info"            a one-line readout for the analysis
##   "values"          {body id: PackedFloat64Array} the per-vertex numbers behind vertex colors
##   "reflection_probe" AABB (environment_map only): the model's bounds, for the view to cover
##                     with a reflection probe so bodies reflect each other
##   "error"           only when the analysis can't be built (the rest is then empty)
## tessellations maps body id -> a tessellation (TESSELLATE.tessellate); missing ones are made
## here. Lengths are meters, angles radians, curvature 1/m (convex positive).
##
## Hidden bodies (doc.body_visible false, a hidden component's too) are left out: they get no
## colors, lines, caps or markers and don't count in readouts. Center of Mass with a body_ids list
## measures exactly the listed bodies.
##
## References in options (plane_ref, direction_ref, curves, edges) are found again in result on
## every build, so the analysis follows model edits; one that is gone makes the analysis an error.
##
## What depends only on a shape (vertex curvatures, isocurve runs, edge combs) is kept per shape
## (shapes don't change once made), so a view that redraws without a rebuild doesn't ask the
## kernel again. Flat faces are found from the tessellation (flat_faces), not face by face.
##
## Types and options (defaults in brackets):
##   zebra            stripes [12], direction "horizontal" | "vertical": render/zebra.gdshader on
##                    every body; stripes kink where faces meet without tangency.
##   draft            pull (Vector3) [UP], or direction_ref (a plane or axis reference: its normal
##                    or direction) turned round by flip [false]; angle [3 deg]. The draft angle
##                    asin(normal . pull) per
##                    vertex (values) on a ramp: DRAFT_COLORS.square (blue) within 1 deg of +-90
##                    (flat to the pull), .positive (green) at >= angle, .negative (red) at
##                    <= -angle (an undercut), .needs (yellow) in between. Unshaded.
##   curvature_map    mode "gaussian" | "mean" | "maximum" | "minimum" (k1, k2), scale [0 = the
##                    largest absolute value]: CURVATURE_RAMP from -scale (blue) through 0
##                    (green) to +scale (red). values: the curvature.
##   minimum_radius   radius [1 mm]: MIN_RADIUS_COLORS.below (red) where the smallest radius of
##                    curvature 1/max(|k1|, |k2|) is under radius, .ok (grey) elsewhere. values:
##                    that radius (INF on flat faces).
##   accessibility    direction (Vector3, from the tool toward the part) [DOWN], or direction_ref
##                    (a plane or axis reference: where the tool comes from, turned round by flip
##                    [false]; direction is its opposite):
##                    ACCESS_COLORS.reachable (green) where normal . -direction > 0, .blocked
##                    (red) elsewhere. values: normal . -direction. Unshaded.
##   isocurve         u_count [5], v_count [5], planar [false], comb [false], comb_density [32],
##                    comb_scale [0 = 1]: lines of constant u (ISO_COLORS.u) and v (.v) on every
##                    face (curved faces only unless planar), trimmed to the face: they stop at its
##                    edges and holes (CadShape.face_isocurves). With comb, each curved line gets a
##                    curvature comb drawn like curvature_comb's (comb_density teeth across the
##                    face's whole parameter range, comb_scale times the automatic size); straight
##                    lines get none.
##   curvature_comb   curves (sketch curve references {"kind": "sketch_curve", "sketch", "entity"}:
##                    exactly these are combed, each found in its own sketch), sketch (a sketch
##                    feature id, for entries without curves: every curve in it) and/or edges (edge
##                    or body references), density [32] (teeth per curve), scale [0 = 1]: a tooth
##                    per sample from the curve to point - toward_center * |curvature| * size
##                    (teeth stand on the convex side, away from the center of curvature), and the
##                    envelope through the tips (COMB_COLORS). size makes the longest tooth 15% of
##                    the curves' size, times scale (a plain multiplier: 2 doubles the teeth).
##                    Straight lines are skipped.
##   section          plane_ref (a plane reference: the plane's point, normal and x axis) and
##                    offset [0] (along the turned normal), or origin (Vector3, a point on the
##                    plane) [the shown model's center, moved offset along the turned normal] and
##                    normal (Vector3, before turning) [RIGHT] and x (Vector3, the unturned plane's
##                    x axis) [ZERO = section_basis' default]; tilt and spin (radians) [0], flip
##                    [false]: the plane is section_basis(normal, x, tilt, spin) (section_plane()).
##                    render/section_clip.gdshader on every body hides its normal's side; "meshes"
##                    holds the cut faces (caps, CAP_COLOR) of every solid. A body whose section
##                    can't be made is left uncapped and named, with why, in info (an error only
##                    when no body's section can be made).
##   environment_map  a chrome material (metallic 1, roughness 0.05) on every body, and
##                    "reflection_probe" (the model's bounds) so the view adds a reflection probe:
##                    bodies reflect each other as well as the view's environment.
##   component_colors each body in its component's color (component_color(): by the component's
##                    place among the document's components); top-level bodies TOP_LEVEL_COLOR.
##   center_of_mass   body_ids [all]: a point at each body's center of mass and one at the total
##                    (COM_COLORS), from mass_properties() (inspect.mass_properties() with mesh
##                    bodies taken in).
##
## Mesh bodies (core/mesh/mesh_body.gd) have triangles and face groups, no B-rep surfaces:
##   zebra, draft, accessibility, environment_map, component_colors work on them as on any body
##   (they read the display mesh);
##   curvature_map, minimum_radius, isocurve and curvature_comb leave them out: with only mesh
##   bodies shown the analysis is the error MESH_BODY.ANALYSIS_GATE, beside B-rep bodies the
##   readout names the mesh bodies left out with that sentence;
##   section clips them like any body and draws where the plane cuts them as "lines"
##   (CadMesh.section) instead of a filled cap; closed mesh bodies count in the section area;
##   center_of_mass takes them in (a closed mesh has mass; an open one only an area).

const TESSELLATE := preload("res://addons/holo_forge/core/tessellate.gd")
const REFERENCES := preload("res://addons/holo_forge/core/references.gd")
const INSPECT := preload("res://addons/holo_forge/core/inspect.gd")
const UNITS := preload("res://addons/holo_forge/core/units.gd")
const MESH_BODY := preload("res://addons/holo_forge/core/mesh/mesh_body.gd")
const PHYSICAL := preload("res://addons/holo_forge/core/physical_materials.gd")
const ZEBRA_SHADER := preload("res://addons/holo_forge/render/zebra.gdshader")
const SECTION_SHADER := preload("res://addons/holo_forge/render/section_clip.gdshader")
## For the view's selection and hover highlights on a sectioned body (clipped like it).
const SECTION_HIGHLIGHT_SHADER := preload("res://addons/holo_forge/render/section_highlight.gdshader")

const TYPES := [
	"zebra", "draft", "curvature_map", "minimum_radius", "accessibility", "isocurve", "curvature_comb",
	"section", "environment_map", "component_colors", "center_of_mass",
]
const LABELS := {
	"zebra": "Zebra", "draft": "Draft", "curvature_map": "Curvature Map", "minimum_radius": "Minimum Radius",
	"accessibility": "Accessibility", "isocurve": "Isocurve", "curvature_comb": "Curvature Comb",
	"section": "Section", "environment_map": "Environment Map", "component_colors": "Component Colors",
	"center_of_mass": "Center of Mass",
}

const DRAFT_COLORS := {
	"positive": Color(0.2, 0.75, 0.3), "negative": Color(0.85, 0.2, 0.2),
	"needs": Color(0.95, 0.8, 0.15), "square": Color(0.25, 0.45, 0.9),
}
## Faces within this of square to the pull (radians) count as flat to it.
const SQUARE_TOLERANCE := 0.017453292519943295
const ACCESS_COLORS := {"reachable": Color(0.2, 0.75, 0.3), "blocked": Color(0.85, 0.2, 0.2)}
const MIN_RADIUS_COLORS := {"below": Color(0.9, 0.15, 0.15), "ok": Color(0.62, 0.63, 0.66)}
## -1 .. 1 in five even steps.
const CURVATURE_RAMP := [Color(0.1, 0.25, 0.95), Color(0.1, 0.8, 0.95), Color(0.2, 0.8, 0.25), Color(0.95, 0.85, 0.1), Color(0.9, 0.15, 0.1)]
const ISO_COLORS := {"u": Color(0.95, 0.45, 0.1), "v": Color(0.2, 0.55, 0.95)}
const COMB_COLORS := {"teeth": Color(0.85, 0.3, 0.85), "envelope": Color(0.55, 0.15, 0.6)}
const CAP_COLOR := Color(0.95, 0.55, 0.15)
const COM_COLORS := {"body": Color(0.3, 0.7, 0.95), "total": Color(0.95, 0.3, 0.2)}
const TOP_LEVEL_COLOR := Color(0.6, 0.61, 0.64)
const COMPONENT_PALETTE := [
	Color(0.9, 0.3, 0.25), Color(0.25, 0.6, 0.9), Color(0.35, 0.75, 0.3), Color(0.95, 0.7, 0.15),
	Color(0.65, 0.4, 0.85), Color(0.2, 0.75, 0.7), Color(0.9, 0.45, 0.65), Color(0.6, 0.45, 0.3),
	Color(0.55, 0.8, 0.2), Color(0.3, 0.35, 0.85),
]
## How far toward the face's middle (a fraction of the way) to look again at a singular point.
const NUDGE := 1e-5
## Samples across a face's parameter range per isocurve (more where combs need them).
const ISO_SAMPLES := 64
## An isocurve or edge that turns less than this in all (radians, largest curvature x length) is
## straight and gets no comb.
const STRAIGHT_TURN := 1e-6
## A face whose tessellation normals all lie within this angle (radians, as a sine) of each other
## is flat: a curved face would have to turn less than this across its whole width.
const FLAT_SINE := 1e-6
## Shapes whose results are kept (the least recently stored go first), and results kept per shape.
const CACHE_SHAPES := 64
const CACHE_KEYS := 8

## Results that depend only on a shape: {shape instance id: {"shape": WeakRef, key: value}}.
static var _cache := {}


static func build(analysis: Dictionary, result: Dictionary, tessellations: Dictionary, kernel: RefCounted, doc: Resource, poses := {}) -> Dictionary:
	var out := {"body_meshes": {}, "body_materials": {}, "lines": [], "meshes": [], "points": [], "info": "", "values": {}}
	var options: Dictionary = analysis.get("options", {})
	var type := str(analysis.get("type", ""))
	if kernel == null and type in ["isocurve", "curvature_comb", "section"]:
		return _fail(out, "The Holo Forge kernel is not loaded")
	var bodies: Dictionary = result.get("bodies", {})
	var ctx := {
		"result": result, "all_bodies": bodies, "bodies": shown_bodies(bodies, doc), "tessellations": tessellations,
		"kernel": kernel, "doc": doc, "poses": poses,
	}
	match type:
		"zebra":
			_zebra(out, options, ctx)
		"draft":
			_draft(out, options, ctx)
		"curvature_map":
			_curvature_map(out, options, ctx)
		"minimum_radius":
			_minimum_radius(out, options, ctx)
		"accessibility":
			_accessibility(out, options, ctx)
		"isocurve":
			_isocurve(out, options, ctx)
		"curvature_comb":
			_curvature_comb(out, options, ctx)
		"section":
			_section(out, options, ctx)
		"environment_map":
			var chrome := StandardMaterial3D.new()
			chrome.albedo_color = Color(0.96, 0.96, 0.97)
			chrome.metallic = 1.0
			chrome.roughness = 0.05
			chrome.cull_mode = BaseMaterial3D.CULL_DISABLED
			for body_id in ctx.bodies:
				out.body_materials[body_id] = chrome
			if not ctx.bodies.is_empty():
				out["reflection_probe"] = _model_box(ctx.bodies)
		"component_colors":
			_component_colors(out, ctx)
		"center_of_mass":
			_center_of_mass(out, options, ctx)
		_:
			return _fail(out, "Unknown analysis '%s'" % type)
	return out


static func _fail(out: Dictionary, text: String) -> Dictionary:
	out.body_meshes.clear()
	out.body_materials.clear()
	out.lines.clear()
	out.meshes.clear()
	out.points.clear()
	out.values.clear()
	out.erase("reflection_probe")
	out["error"] = text
	return out


# --- Shared helpers --------------------------------------------------------------------------

## The bodies the view shows: all of them without a document, else those doc.body_visible() keeps.
static func shown_bodies(bodies: Dictionary, doc: Resource) -> Dictionary:
	if doc == null:
		return bodies
	var shown := {}
	for body_id in bodies:
		if doc.body_visible(str(body_id)):
			shown[body_id] = bodies[body_id]
	return shown


## A body's tessellation: the given one, or a new one.
static func _tess(ctx: Dictionary, body_id: Variant) -> Dictionary:
	var tess: Dictionary = ctx.tessellations.get(body_id, {})
	if tess.is_empty():
		tess = TESSELLATE.tessellate(ctx.bodies[body_id].shape)
	return tess


## A key for a tessellation's vertices (results that follow them are kept under it).
static func _tess_key(tess: Dictionary) -> String:
	var positions: PackedVector3Array = tess.get("positions", PackedVector3Array())
	return "%d:%d" % [positions.size(), hash(positions)]


## A result kept for shape under key, or null.
static func _cached(shape: RefCounted, key: String) -> Variant:
	var entry: Dictionary = _cache.get(shape.get_instance_id(), {})
	if entry.is_empty() or (entry.shape as WeakRef).get_ref() != shape:
		return null
	return entry.get(key)


## Keeps value for shape under key. Freed shapes' entries go first when the cache is full, then
## the oldest; a shape keeps its CACHE_KEYS latest results.
static func _store(shape: RefCounted, key: String, value: Variant) -> void:
	var id := shape.get_instance_id()
	var entry: Dictionary = _cache.get(id, {})
	if entry.is_empty() or (entry.shape as WeakRef).get_ref() != shape:
		if _cache.size() >= CACHE_SHAPES:
			for old in _cache.keys():
				if (_cache[old].shape as WeakRef).get_ref() == null:
					_cache.erase(old)
			while _cache.size() >= CACHE_SHAPES:
				_cache.erase(_cache.keys()[0])
		entry = {"shape": weakref(shape)}
		_cache[id] = entry
	entry.erase(key)
	entry[key] = value
	while entry.size() > CACHE_KEYS + 1:
		entry.erase(entry.keys()[1])


## Forgets every kept result (tests time builds from scratch with it).
static func clear_cache() -> void:
	_cache.clear()


## The faces of a tessellation whose vertex normals all agree within FLAT_SINE: flat faces, found
## from the mesh rather than face by face from the kernel (each kernel call walks the whole shape,
## so asking per face grows with the square of the face count: minutes on a faceted mesh).
## lists: face_vertices(tess). {face id: true}.
static func flat_faces(tess: Dictionary, lists: Dictionary) -> Dictionary:
	var normals: PackedVector3Array = tess.get("normals", PackedVector3Array())
	var flat := {}
	if normals.size() != (tess.get("positions", PackedVector3Array()) as PackedVector3Array).size():
		return flat
	for f in lists:
		var list: Array = lists[f]
		var first := normals[list[0]]
		if first.length_squared() < 0.25:
			continue
		first = first.normalized()
		var same := true
		for v in list:
			var n := normals[v]
			if n.length_squared() < 0.25 or n.dot(first) <= 0.0 or n.normalized().cross(first).length_squared() > FLAT_SINE * FLAT_SINE:
				same = false
				break
		if same:
			flat[f] = true
	return flat


## The vertex indices of each face: {face id: Array of vertex indices}. Tessellations keep each
## face's vertices separate, so every vertex belongs to one face.
static func face_vertices(tess: Dictionary) -> Dictionary:
	var face_ids: PackedInt32Array = tess.get("face_ids", PackedInt32Array())
	var indices: PackedInt32Array = tess.get("indices", PackedInt32Array())
	var seen := PackedByteArray()
	seen.resize((tess.get("positions", PackedVector3Array()) as PackedVector3Array).size())
	seen.fill(0)
	var lists := {}
	for t in face_ids.size():
		# Arrays are shared references, so appending needs no write-back (packed arrays would).
		var list: Array = lists.get(face_ids[t], [])
		if list.is_empty():
			lists[face_ids[t]] = list
		for k in 3:
			var v := indices[t * 3 + k]
			if seen[v] == 0:
				seen[v] = 1
				list.append(v)
	return lists


## Principal curvatures at every vertex of a body's tessellation (1/m, convex positive):
## {"k1" (largest), "k2" (smallest), "gaussian", "mean"} as PackedFloat64Array. Flat faces
## (flat_faces) are 0. Kept per shape and tessellation; treat the result as read-only.
static func vertex_curvatures(shape: RefCounted, tess: Dictionary) -> Dictionary:
	var key := "curvature:" + _tess_key(tess)
	var kept: Variant = _cached(shape, key)
	if kept != null:
		return kept
	var found := _vertex_curvatures(shape, tess)
	_store(shape, key, found)
	return found


static func _vertex_curvatures(shape: RefCounted, tess: Dictionary) -> Dictionary:
	var count := (tess.get("positions", PackedVector3Array()) as PackedVector3Array).size()
	# Packed arrays copy when changed through a dictionary, so the results stay in locals.
	var k1 := PackedFloat64Array()
	var k2 := PackedFloat64Array()
	var gaussian := PackedFloat64Array()
	var mean := PackedFloat64Array()
	k1.resize(count)
	k2.resize(count)
	gaussian.resize(count)
	mean.resize(count)
	# Flat faces stay zero.
	k1.fill(0.0)
	k2.fill(0.0)
	gaussian.fill(0.0)
	mean.fill(0.0)
	var uvs: PackedVector2Array = tess.get("uvs", PackedVector2Array())
	var lists := face_vertices(tess)
	var flat := flat_faces(tess, lists)
	for f in lists:
		if flat.has(f):
			continue
		var list: Array = lists[f]
		var face_uvs := PackedVector2Array()
		var middle := Vector2.ZERO
		for v in list:
			face_uvs.append(uvs[v])
			middle += uvs[v]
		middle /= float(list.size())
		var found: Dictionary = shape.surface_curvatures(f, face_uvs)
		var f1: PackedFloat64Array = found.get("k1", PackedFloat64Array())
		var f2: PackedFloat64Array = found.get("k2", PackedFloat64Array())
		var fg: PackedFloat64Array = found.get("gaussian", PackedFloat64Array())
		var fm: PackedFloat64Array = found.get("mean", PackedFloat64Array())
		if f1.size() != list.size() or f2.size() != list.size() or fg.size() != list.size() or fm.size() != list.size():
			continue
		# At singular points (a sphere's poles) the kernel reports all zeros: look again a hair
		# toward the middle of the face.
		var retry := PackedInt32Array()
		var nudged := PackedVector2Array()
		for i in list.size():
			if f1[i] == 0.0 and f2[i] == 0.0 and not face_uvs[i].is_equal_approx(middle):
				retry.append(i)
				nudged.append(face_uvs[i] + (middle - face_uvs[i]) * NUDGE)
		if not retry.is_empty():
			var again: Dictionary = shape.surface_curvatures(f, nudged)
			var a1: PackedFloat64Array = again.get("k1", PackedFloat64Array())
			var a2: PackedFloat64Array = again.get("k2", PackedFloat64Array())
			var ag: PackedFloat64Array = again.get("gaussian", PackedFloat64Array())
			var am: PackedFloat64Array = again.get("mean", PackedFloat64Array())
			if a1.size() == retry.size() and a2.size() == retry.size() and ag.size() == retry.size() and am.size() == retry.size():
				for j in retry.size():
					f1[retry[j]] = a1[j]
					f2[retry[j]] = a2[j]
					fg[retry[j]] = ag[j]
					fm[retry[j]] = am[j]
		for i in list.size():
			var v: int = list[i]
			k1[v] = f1[i]
			k2[v] = f2[i]
			gaussian[v] = fg[i]
			mean[v] = fm[i]
	return {"k1": k1, "k2": k2, "gaussian": gaussian, "mean": mean}


static func colored_mesh(tess: Dictionary, colors: PackedColorArray) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	if not TESSELLATE.has_triangles(tess):
		return mesh
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = tess.positions
	arrays[Mesh.ARRAY_NORMAL] = tess.normals
	arrays[Mesh.ARRAY_TEX_UV] = tess.uvs
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = tess.indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Analysis materials draw both sides: a surface body is seen from behind too (a solid's far side
## stays hidden behind its near side anyway).
static func _vertex_color_material(shaded: bool) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.vertex_color_is_srgb = true
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	if not shaded:
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return material


static func _set_colored(out: Dictionary, body_id: Variant, tess: Dictionary, colors: PackedColorArray, values: PackedFloat64Array, material: Material) -> void:
	out.body_meshes[body_id] = colored_mesh(tess, colors)
	out.body_materials[body_id] = material
	out.values[body_id] = values


## The share of the surface area in each category (a vertex's category gets a third of each
## triangle it is a corner of): {category: fraction}.
static func _area_shares(tess: Dictionary, categories: PackedByteArray) -> Dictionary:
	var positions: PackedVector3Array = tess.positions
	var indices: PackedInt32Array = tess.indices
	var sums := {}
	var total := 0.0
	for t in int(indices.size() / 3.0):
		var a := positions[indices[t * 3]]
		var area := (positions[indices[t * 3 + 1]] - a).cross(positions[indices[t * 3 + 2]] - a).length() * 0.5
		total += area
		for k in 3:
			var c := categories[indices[t * 3 + k]]
			sums[c] = float(sums.get(c, 0.0)) + area / 3.0
	for c in sums:
		sums[c] = float(sums[c]) / total if total > 0.0 else 0.0
	return sums


static func _units(doc: Resource) -> String:
	return str(doc.units) if doc != null else "mm"


static func _length(value: float, doc: Resource) -> String:
	return UNITS.format_value(value, UNITS.KIND_LENGTH, _units(doc))


## A value in 1/length^power, in the document's length unit.
static func _per_length(value: float, power: int, doc: Resource) -> String:
	var unit := _units(doc)
	var shown := value * pow(float(UNITS.LENGTH_UNITS.get(unit, 1.0)), power)
	# Four significant digits (String % has no %g).
	var decimals := 0 if shown == 0.0 else clampi(3 - int(floor(log(absf(shown)) / log(10.0))), 0, 12)
	return "%s 1/%s%s" % [String.num(shown, decimals), unit, "²" if power == 2 else ""]


## A number to four or five significant digits without trailing zeros ("0.00003348", "7.85"), so
## small masses and areas don't round to 0.
static func significant(value: float) -> String:
	if value == 0.0 or not is_finite(value):
		return "0" if value == 0.0 else str(value)
	var decimals := clampi(4 - int(floor(log(absf(value)) / log(10.0))), 0, 12)
	var text := String.num(value, decimals)
	if text.contains("."):
		text = text.rstrip("0").rstrip(".")
	return "0" if text == "-0" else text


static func _model_box(bodies: Dictionary) -> AABB:
	var box := AABB()
	var first := true
	for body_id in bodies:
		var b: AABB = bodies[body_id].shape.bbox()
		box = b if first else box.merge(b)
		first = false
	return box


## The names of the shown mesh bodies (an analysis of B-rep surfaces leaves them out).
static func _mesh_names(ctx: Dictionary) -> PackedStringArray:
	var names := PackedStringArray()
	for body_id in ctx.bodies:
		if MESH_BODY.is_mesh(ctx.bodies[body_id]):
			names.append(MESH_BODY.body_name(ctx.doc, str(body_id)))
	return names


## Ends an analysis that left mesh bodies out: the gate sentence as the error when it showed
## nothing else (shown false), else added to the readout with their names. False when it failed.
static func _note_mesh(out: Dictionary, names: PackedStringArray, shown: bool) -> bool:
	if names.is_empty():
		return true
	if not shown:
		_fail(out, MESH_BODY.ANALYSIS_GATE)
		return false
	var note := "%s: %s" % [", ".join(names), MESH_BODY.ANALYSIS_GATE]
	out.info = note if str(out.info) == "" else "%s. %s" % [str(out.info).rstrip("."), note]
	return true


# --- Material analyses -----------------------------------------------------------------------

static func _zebra(out: Dictionary, options: Dictionary, ctx: Dictionary) -> void:
	var material := ShaderMaterial.new()
	material.shader = ZEBRA_SHADER
	material.set_shader_parameter("stripes", maxf(float(options.get("stripes", 12)), 1.0))
	material.set_shader_parameter("vertical", str(options.get("direction", "horizontal")) == "vertical")
	for body_id in ctx.bodies:
		out.body_materials[body_id] = material


static func _component_colors(out: Dictionary, ctx: Dictionary) -> void:
	var doc: Resource = ctx.doc
	var materials := {}
	for body_id in ctx.bodies:
		var component_id: String = doc.body_component(body_id) if doc != null else ""
		if not materials.has(component_id):
			var material := StandardMaterial3D.new()
			material.albedo_color = component_color(component_id, doc)
			material.cull_mode = BaseMaterial3D.CULL_DISABLED
			materials[component_id] = material
		out.body_materials[body_id] = materials[component_id]
	var count := materials.size() - (1 if materials.has("") else 0)
	out.info = "%d component%s" % [count, "" if count == 1 else "s"]


## A component's display color. With the document: by its place among doc.components, so the
## components there always get different colors (the palette's ten first, then golden-ratio hues),
## whatever numbers their ids have. Without it: by the number in its id ("comp3" is the third).
static func component_color(component_id: String, doc: Resource = null) -> Color:
	if component_id == "":
		return TOP_LEVEL_COLOR
	var index := -1
	if doc != null:
		index = (doc.components as Dictionary).keys().find(component_id)
	if index < 0:
		var digits := ""
		for i in range(component_id.length() - 1, -1, -1):
			if not component_id[i].is_valid_int():
				break
			digits = component_id[i] + digits
		index = int(digits) - 1 if digits != "" else posmod(hash(component_id), 1000)
	if index >= 0 and index < COMPONENT_PALETTE.size():
		return COMPONENT_PALETTE[index]
	# Golden-ratio steps round the hue circle keep later colors apart.
	return Color.from_hsv(fposmod(0.07 + float(index) * 0.6180339887, 1.0), 0.6, 0.85)


# --- Vertex-color analyses -------------------------------------------------------------------

## The draft ramp's color for a draft angle (radians) against the required angle.
static func draft_color(draft: float, angle: float) -> Color:
	if absf(draft) >= PI * 0.5 - SQUARE_TOLERANCE:
		return DRAFT_COLORS.square
	if draft >= angle - 1e-6:
		return DRAFT_COLORS.positive
	if draft <= -angle + 1e-6:
		return DRAFT_COLORS.negative
	return DRAFT_COLORS.needs


## A picked direction found again in result: a plane reference's normal or an axis reference's
## direction (origin and construction geometry, flat or round faces, straight edges, sketch lines),
## turned round by flip. {"direction"} or {"error"}.
static func picked_direction(ref: Variant, flip: bool, result: Dictionary, doc: Resource, kernel: RefCounted) -> Dictionary:
	if not ref is Dictionary:
		return {"error": "Nothing is picked"}
	var ctx := INSPECT.context(result, doc, kernel)
	var d := Vector3.ZERO
	var plane := REFERENCES.plane(ref, ctx)
	if not plane.has("error"):
		d = plane.normal
	else:
		var axis := REFERENCES.axis(ref, ctx)
		if axis.has("error"):
			return axis
		d = axis.direction
	if d.is_zero_approx():
		return {"error": "The picked direction is zero"}
	return {"direction": -d.normalized() if flip else d.normalized()}


static func _draft(out: Dictionary, options: Dictionary, ctx: Dictionary) -> void:
	var pull: Vector3 = options.get("pull", Vector3.UP)
	if options.has("direction_ref"):
		var picked := picked_direction(options.direction_ref, bool(options.get("flip", false)), ctx.result, ctx.doc, ctx.kernel)
		if picked.has("error"):
			_fail(out, "The pull direction can't be found: %s" % picked.error)
			return
		pull = picked.direction
	if pull.is_zero_approx():
		_fail(out, "The pull direction is zero")
		return
	pull = pull.normalized()
	var angle := absf(float(options.get("angle", deg_to_rad(3.0))))
	var material := _vertex_color_material(false)
	var shares := {}
	var total_area := 0.0
	for body_id in ctx.bodies:
		var tess := _tess(ctx, body_id)
		if not TESSELLATE.has_triangles(tess):
			continue
		var normals: PackedVector3Array = tess.normals
		var colors := PackedColorArray()
		var values := PackedFloat64Array()
		var categories := PackedByteArray()
		colors.resize(normals.size())
		values.resize(normals.size())
		categories.resize(normals.size())
		for i in normals.size():
			var draft := asin(clampf(normals[i].normalized().dot(pull), -1.0, 1.0))
			var color := draft_color(draft, angle)
			values[i] = draft
			colors[i] = color
			categories[i] = 1 if color == DRAFT_COLORS.needs else (2 if color == DRAFT_COLORS.negative else 0)
		_set_colored(out, body_id, tess, colors, values, material)
		var area: float = ctx.bodies[body_id].shape.area()
		var body_shares := _area_shares(tess, categories)
		for c in body_shares:
			shares[c] = float(shares.get(c, 0.0)) + float(body_shares[c]) * area
		total_area += area
	if total_area > 0.0:
		# (Shares of the display mesh, by its vertices: about right, not exact.)
		out.info = "Needs draft: about %d%% of the surface, undercut: about %d%% (at %s deg)" % [
			roundi(float(shares.get(1, 0.0)) / total_area * 100.0), roundi(float(shares.get(2, 0.0)) / total_area * 100.0),
			String.num(rad_to_deg(angle), 2)]


static func _accessibility(out: Dictionary, options: Dictionary, ctx: Dictionary) -> void:
	var direction: Vector3 = options.get("direction", Vector3.DOWN)
	if options.has("direction_ref"):
		var picked := picked_direction(options.direction_ref, bool(options.get("flip", false)), ctx.result, ctx.doc, ctx.kernel)
		if picked.has("error"):
			_fail(out, "The tool direction can't be found: %s" % picked.error)
			return
		# The pick is where the tool comes from; the analysis looks from the tool toward the part.
		direction = -(picked.direction as Vector3)
	if direction.is_zero_approx():
		_fail(out, "The direction is zero")
		return
	var toward_tool := -direction.normalized()
	var material := _vertex_color_material(false)
	var reachable := 0.0
	var total_area := 0.0
	for body_id in ctx.bodies:
		var tess := _tess(ctx, body_id)
		if not TESSELLATE.has_triangles(tess):
			continue
		var normals: PackedVector3Array = tess.normals
		var colors := PackedColorArray()
		var values := PackedFloat64Array()
		var categories := PackedByteArray()
		colors.resize(normals.size())
		values.resize(normals.size())
		categories.resize(normals.size())
		for i in normals.size():
			var facing := normals[i].normalized().dot(toward_tool)
			values[i] = facing
			# Walls exactly along the direction aren't reachable; the margin keeps float noise out.
			var ok := facing > 1e-6
			colors[i] = ACCESS_COLORS.reachable if ok else ACCESS_COLORS.blocked
			categories[i] = 1 if ok else 0
		_set_colored(out, body_id, tess, colors, values, material)
		var area: float = ctx.bodies[body_id].shape.area()
		reachable += float(_area_shares(tess, categories).get(1, 0.0)) * area
		total_area += area
	if total_area > 0.0:
		out.info = "Reachable: about %d%% of the surface" % roundi(reachable / total_area * 100.0)


## A color on CURVATURE_RAMP for t in -1..1.
static func ramp_color(t: float) -> Color:
	var x := (clampf(t, -1.0, 1.0) + 1.0) * 0.5 * (CURVATURE_RAMP.size() - 1)
	var i := mini(int(floor(x)), CURVATURE_RAMP.size() - 2)
	return (CURVATURE_RAMP[i] as Color).lerp(CURVATURE_RAMP[i + 1], x - i)


static func _curvature_map(out: Dictionary, options: Dictionary, ctx: Dictionary) -> void:
	var mode := str(options.get("mode", "gaussian"))
	var key := str({"gaussian": "gaussian", "mean": "mean", "maximum": "k1", "minimum": "k2"}.get(mode, ""))
	if key == "":
		_fail(out, "Unknown curvature mode '%s'" % mode)
		return
	var found := {}
	var lo := INF
	var hi := -INF
	var left_out := _mesh_names(ctx)
	for body_id in ctx.bodies:
		if MESH_BODY.is_mesh(ctx.bodies[body_id]):
			continue
		var tess := _tess(ctx, body_id)
		if not TESSELLATE.has_triangles(tess):
			continue
		var values: PackedFloat64Array = vertex_curvatures(ctx.bodies[body_id].shape, tess)[key]
		found[body_id] = {"tess": tess, "values": values}
		for v in values:
			lo = minf(lo, v)
			hi = maxf(hi, v)
	if found.is_empty():
		_note_mesh(out, left_out, false)
		return
	var scale := absf(float(options.get("scale", 0.0)))
	if scale <= 0.0:
		scale = maxf(absf(lo), absf(hi))
	if scale <= 0.0:
		scale = 1.0
	var material := _vertex_color_material(true)
	for body_id in found:
		var values: PackedFloat64Array = found[body_id].values
		var colors := PackedColorArray()
		colors.resize(values.size())
		for i in values.size():
			colors[i] = ramp_color(values[i] / scale)
		_set_colored(out, body_id, found[body_id].tess, colors, values, material)
	var power := 2 if key == "gaussian" else 1
	out.info = "%s curvature from %s to %s at the display mesh's points" % [mode.capitalize(), _per_length(lo, power, ctx.doc), _per_length(hi, power, ctx.doc)]
	_note_mesh(out, left_out, true)


static func _minimum_radius(out: Dictionary, options: Dictionary, ctx: Dictionary) -> void:
	var radius := absf(float(options.get("radius", 0.001)))
	var material := _vertex_color_material(true)
	var smallest := INF
	var flagged := 0
	var left_out := _mesh_names(ctx)
	var measured := 0
	for body_id in ctx.bodies:
		if MESH_BODY.is_mesh(ctx.bodies[body_id]):
			continue
		var tess := _tess(ctx, body_id)
		if not TESSELLATE.has_triangles(tess):
			continue
		measured += 1
		var curvature := vertex_curvatures(ctx.bodies[body_id].shape, tess)
		var k1: PackedFloat64Array = curvature.k1
		var k2: PackedFloat64Array = curvature.k2
		var colors := PackedColorArray()
		var values := PackedFloat64Array()
		colors.resize(k1.size())
		values.resize(k1.size())
		for i in k1.size():
			var k := maxf(absf(k1[i]), absf(k2[i]))
			var r := 1.0 / k if k > 0.0 else INF
			values[i] = r
			smallest = minf(smallest, r)
			var below := r < radius
			flagged += 1 if below else 0
			colors[i] = MIN_RADIUS_COLORS.below if below else MIN_RADIUS_COLORS.ok
		_set_colored(out, body_id, tess, colors, values, material)
	if measured == 0 and not left_out.is_empty():
		_note_mesh(out, left_out, false)
		return
	if is_inf(smallest):
		out.info = "No curved faces"
	else:
		out.info = "Smallest radius %s at the display mesh's points; %s below %s" % [_length(smallest, ctx.doc), "some faces" if flagged > 0 else "nothing", _length(radius, ctx.doc)]
	_note_mesh(out, left_out, true)


# --- Line analyses ---------------------------------------------------------------------------

static func _isocurve(out: Dictionary, options: Dictionary, ctx: Dictionary) -> void:
	var u_count := maxi(int(options.get("u_count", 5)), 0)
	var v_count := maxi(int(options.get("v_count", 5)), 0)
	var planar := bool(options.get("planar", false))
	var comb := bool(options.get("comb", false))
	var density := maxi(int(options.get("comb_density", 32)), 2)
	# A comb needs a sample per tooth; its teeth then stand on every stride-th sample.
	var samples := maxi(ISO_SAMPLES, density) if comb else ISO_SAMPLES
	var stride := maxi(roundi(float(samples) / float(density)), 1)
	var combed := []
	var left_out := _mesh_names(ctx)
	if not left_out.is_empty() and left_out.size() == (ctx.bodies as Dictionary).size():
		_note_mesh(out, left_out, false)
		return
	for body_id in ctx.bodies:
		if u_count + v_count == 0:
			break
		if MESH_BODY.is_mesh(ctx.bodies[body_id]):
			continue
		var shape: RefCounted = ctx.bodies[body_id].shape
		for run in _isocurve_runs(shape, {} if planar else _tess(ctx, body_id), u_count, v_count, samples, planar):
			var points: PackedVector3Array = run.get("points", PackedVector3Array())
			if points.size() < 2:
				continue
			out.lines.append({"points": points, "color": ISO_COLORS.u if str(run.get("direction", "u")) == "u" else ISO_COLORS.v, "body": body_id})
			if comb:
				var teeth := _iso_comb(points, run.get("normals", PackedVector3Array()), run.get("curvature", PackedFloat64Array()), stride)
				if not teeth.is_empty():
					teeth["body"] = body_id
					combed.append(teeth)
	out.info = "%d isocurves" % out.lines.size()
	if not combed.is_empty():
		var largest := _draw_combs(out, combed, absf(float(options.get("comb_scale", 0.0))))
		out.info += ", largest curvature %s (radius %s)" % [_per_length(largest, 1, ctx.doc), _length(1.0 / largest, ctx.doc) if largest > 0.0 else "none"]
	_note_mesh(out, left_out, true)


## The isocurve runs (CadShape.face_isocurves) on a shape's faces: every face with planar, else
## the faces tess doesn't show as flat (flat_faces; a face it has no triangles for is asked of the
## kernel). Kept per shape; treat the result as read-only.
static func _isocurve_runs(shape: RefCounted, tess: Dictionary, u_count: int, v_count: int, samples: int, planar: bool) -> Array:
	var key := "isocurves:%d:%d:%d:%s" % [u_count, v_count, samples, "all" if planar else _tess_key(tess)]
	var kept: Variant = _cached(shape, key)
	if kept != null:
		return kept
	var lists := {} if planar else face_vertices(tess)
	var flat := {} if planar else flat_faces(tess, lists)
	var runs := []
	for f in shape.face_count():
		if not planar and (flat.has(f) or (not lists.has(f) and bool(shape.face_info(f).get("planar", false)))):
			continue
		runs.append_array(shape.face_isocurves(f, u_count, v_count, samples))
	_store(shape, key, runs)
	return runs


## A comb sample ({"points", "toward", "k"}) from every stride-th point of an isocurve run (and its
## last point); {} for a straight run.
static func _iso_comb(points: PackedVector3Array, normals: PackedVector3Array, curvature: PackedFloat64Array, stride: int) -> Dictionary:
	if normals.size() != points.size() or curvature.size() != points.size():
		return {}
	var largest := 0.0
	var length := 0.0
	for i in points.size():
		largest = maxf(largest, absf(curvature[i]))
		if i > 0:
			length += points[i].distance_to(points[i - 1])
	if largest * length < STRAIGHT_TURN:
		return {}
	var pts := PackedVector3Array()
	var toward := PackedVector3Array()
	var ks := PackedFloat64Array()
	var last := points.size() - 1
	for i in points.size():
		if i % stride == 0 or i == last:
			pts.append(points[i])
			toward.append(normals[i])
			ks.append(absf(curvature[i]))
	return {"points": pts, "toward": toward, "k": ks}


static func _curvature_comb(out: Dictionary, options: Dictionary, ctx: Dictionary) -> void:
	var density := maxi(int(options.get("density", 32)), 2)
	var kernel: RefCounted = ctx.kernel
	# Each sampled curve: {"points", "toward" (unit, to the center of curvature), "k" (>= 0)}.
	var samples := []
	# Sketch curves to comb, [curve, sketch plane]: the picked ones, or a whole sketch's.
	var curves := []
	if options.has("curves"):
		var curve_ctx := {"sketches": ctx.result.get("sketches", {}), "doc": ctx.doc}
		for ref in options.curves:
			if not ref is Dictionary:
				continue
			var picked := INSPECT.sketch_curve(ref, curve_ctx)
			if picked.has("error"):
				_fail(out, "A combed sketch curve is gone")
				return
			curves.append([picked.curve, picked.frame])
	elif str(options.get("sketch", "")) != "":
		var state: Dictionary = (ctx.result.get("sketches", {}) as Dictionary).get(str(options.sketch), {})
		if state.is_empty():
			_fail(out, "The comb's sketch is missing")
			return
		for curve in state.get("curves", []):
			curves.append([curve, state.plane])
	for pair in curves:
		var curve: Dictionary = pair[0]
		var frame: Transform3D = pair[1]
		if str(curve.get("type", "")) in ["line", "polyline"]:
			continue
		var found: Dictionary = kernel.curve_curvature(curve, density)
		var points2: PackedVector2Array = found.get("points", PackedVector2Array())
		var signed: PackedFloat64Array = found.get("curvature", PackedFloat64Array())
		var left: PackedVector2Array = found.get("normals", PackedVector2Array())
		if points2.is_empty() or signed.size() != points2.size() or left.size() != points2.size():
			continue
		var pts := PackedVector3Array()
		var toward := PackedVector3Array()
		var ks := PackedFloat64Array()
		for i in points2.size():
			pts.append(frame * Vector3(points2[i].x, points2[i].y, 0.0))
			# Positive curvature turns left, so the center is on the left normal's side.
			toward.append((frame.basis * Vector3(left[i].x, left[i].y, 0.0)).normalized() * signf(signed[i]))
			ks.append(absf(signed[i]))
		samples.append({"points": pts, "toward": toward, "k": ks})
	# Edge and body picks are found among all bodies, so a hidden one isn't "gone"; it just isn't
	# combed (its comb would hang where nothing shows).
	var edge_ctx := {"bodies": ctx.all_bodies, "doc": ctx.doc, "kernel": kernel}
	for ref in options.get("edges", []):
		if not ref is Dictionary:
			continue
		var body_id := str(ref.get("body", ""))
		if ctx.all_bodies.has(body_id) and not ctx.bodies.has(body_id):
			continue
		if MESH_BODY.is_mesh(ctx.all_bodies.get(body_id, {})):
			# A mesh body has no edges to comb.
			_fail(out, MESH_BODY.ANALYSIS_GATE)
			return
		var targets := []
		match str(ref.get("kind", "")):
			"edge":
				var found := REFERENCES.edge(ref, edge_ctx)
				if found.has("error"):
					_fail(out, found.error)
					return
				targets.append([found.shape, found.index])
			"body":
				var shape := REFERENCES.body_shape(ref, edge_ctx)
				if shape == null:
					_fail(out, "A comb's body no longer exists")
					return
				for e in shape.edge_count():
					targets.append([shape, e])
		for target in targets:
			var sample := _edge_comb(target[0], target[1], density)
			if not sample.is_empty():
				# (A copy: the kept sample is the shape's; the body is this reference's.)
				sample = sample.duplicate()
				sample["body"] = body_id
				samples.append(sample)
	if samples.is_empty():
		out.info = "No curves to comb"
		return
	var largest := _draw_combs(out, samples, absf(float(options.get("scale", 0.0))))
	out.info = "Largest curvature %s (radius %s)" % [_per_length(largest, 1, ctx.doc), _length(1.0 / largest, ctx.doc) if largest > 0.0 else "none"]


## A comb sample ({"points", "toward", "k"}) of density points along a shape's edge, or {} for a
## straight one (it turns less than STRAIGHT_TURN), read from the curvature itself: asking the
## kernel an edge's type walks the whole shape each time. Kept per shape.
static func _edge_comb(shape: RefCounted, edge: int, density: int) -> Dictionary:
	var key := "edge_combs:%d" % density
	var known: Variant = _cached(shape, key)
	if known == null:
		known = {}
		_store(shape, key, known)
	if (known as Dictionary).has(edge):
		return known[edge]
	var sample := {}
	var found: Dictionary = shape.edge_curvature(edge, density)
	var pts: PackedVector3Array = found.get("points", PackedVector3Array())
	var ks: PackedFloat64Array = found.get("curvature", PackedFloat64Array())
	var toward: PackedVector3Array = found.get("normals", PackedVector3Array())
	if not pts.is_empty() and ks.size() == pts.size() and toward.size() == pts.size():
		var magnitudes := PackedFloat64Array()
		var largest := 0.0
		var length := 0.0
		for i in ks.size():
			magnitudes.append(absf(ks[i]))
			largest = maxf(largest, absf(ks[i]))
			if i > 0:
				length += pts[i].distance_to(pts[i - 1])
		if largest * length >= STRAIGHT_TURN:
			sample = {"points": pts, "toward": toward, "k": magnitudes}
	known[edge] = sample
	return sample


## Draws curvature combs into out.lines for samples [{"points", "toward" (unit, to the center of
## curvature), "k" (>= 0)}]: a tooth per point from the curve to point - toward * k * size (on the
## convex side) and the envelope through the tips. size makes the longest tooth 15% of the curves'
## size, times scale (0 counts as 1). Returns the largest curvature.
static func _draw_combs(out: Dictionary, samples: Array, scale: float) -> float:
	var box := AABB()
	var first := true
	var largest := 0.0
	for sample in samples:
		for p in sample.points:
			box = AABB(p, Vector3.ZERO) if first else box.expand(p)
			first = false
		for k in sample.k:
			largest = maxf(largest, k)
	# A typed scale is a multiple of the automatic size: a bare number in 1/m * m^2 would mean
	# nothing to the user (1 made teeth 100 m long on a millimeter part).
	var size := 0.15 * maxf(box.size.length(), 1e-6) / largest if largest > 0.0 else 1.0
	size *= scale if scale > 0.0 else 1.0
	for sample in samples:
		var pts: PackedVector3Array = sample.points
		var toward: PackedVector3Array = sample.toward
		var ks: PackedFloat64Array = sample.k
		var envelope := PackedVector3Array()
		for i in pts.size():
			var tip := pts[i] - toward[i].normalized() * (ks[i] * size)
			envelope.append(tip)
			if ks[i] * size > 1e-12:
				out.lines.append(_on_body({"points": PackedVector3Array([pts[i], tip]), "color": COMB_COLORS.teeth}, sample))
		out.lines.append(_on_body({"points": envelope, "color": COMB_COLORS.envelope}, sample))
	return largest


## line with the sample's "body" (when it has one: a comb on a body's edge or face moves with it,
## one on a sketch curve does not).
static func _on_body(line: Dictionary, sample: Dictionary) -> Dictionary:
	if sample.has("body"):
		line["body"] = sample.body
	return line


# --- Section ---------------------------------------------------------------------------------

## The section plane's frame: x and y lie in the plane, z is its normal. The unturned plane (normal,
## and x: its in-plane x axis, or ZERO for the default) is turned by tilt about its own x axis,
## then by spin about its y axis as tilted (radians, right-handed), so dragging either angle turns
## the plane about an axis lying in it. The default x is the first of +X, -Z, +Y that isn't along
## the normal (as sketch planes on faces choose).
static func section_basis(normal: Vector3, x: Vector3, tilt: float, spin: float) -> Basis:
	var n := normal.normalized()
	var along := x - n * x.dot(n)
	if x.is_zero_approx() or along.length() <= 1e-3 * x.length():
		along = Vector3.ZERO
		for axis: Vector3 in [Vector3.RIGHT, Vector3.FORWARD, Vector3.UP]:
			var projected := axis - n * axis.dot(n)
			if projected.length() > 0.5:
				along = projected
				break
	var u := along.normalized()
	return Basis(u, n.cross(u), n) * Basis(Vector3.RIGHT, tilt) * Basis(Vector3.UP, spin)


## The section plane of options in a build: {"origin", "normal" (turned, and turned round with
## flip), "basis" (section_basis, before flip)} or {"error"}. plane_ref is found again in result
## every time, so the section follows the plane or face it was picked on, moved offset along the
## turned normal. Without it the stored normal and origin are used (no origin: the middle of
## bodies, moved offset along the turned normal).
static func section_plane(options: Dictionary, result: Dictionary, doc: Resource, kernel: RefCounted, bodies: Dictionary) -> Dictionary:
	var normal: Vector3 = options.get("normal", Vector3.RIGHT)
	var x: Vector3 = options.get("x", Vector3.ZERO)
	var base := Vector3.ZERO
	var has_base := options.has("origin")
	if options.has("plane_ref"):
		var ref: Variant = options.plane_ref
		var found: Dictionary = REFERENCES.plane(ref, INSPECT.context(result, doc, kernel)) if ref is Dictionary else {"error": "Not a plane"}
		if found.has("error"):
			return {"error": "The section's plane can't be found: %s" % found.error}
		normal = found.normal
		x = found.get("x", Vector3.ZERO)
		base = found.origin
		has_base = false
	if normal.is_zero_approx():
		return {"error": "The section plane's normal is zero"}
	var turned := section_basis(normal, x, float(options.get("tilt", 0.0)), float(options.get("spin", 0.0)))
	var origin: Vector3
	if has_base:
		origin = options.origin
	else:
		if not options.has("plane_ref"):
			base = _model_box(bodies).get_center()
		origin = base + turned.z.normalized() * float(options.get("offset", 0.0))
	return {"origin": origin, "normal": turned.z.normalized() * (-1.0 if bool(options.get("flip", false)) else 1.0), "basis": turned}


static func _section(out: Dictionary, options: Dictionary, ctx: Dictionary) -> void:
	var found := section_plane(options, ctx.result, ctx.doc, ctx.kernel, ctx.bodies)
	if found.has("error"):
		_fail(out, found.error)
		return
	var origin: Vector3 = found.origin
	var normal: Vector3 = found.normal
	var material := ShaderMaterial.new()
	material.shader = SECTION_SHADER
	material.set_shader_parameter("plane_origin", origin)
	material.set_shader_parameter("plane_normal", normal)
	for body_id in ctx.bodies:
		out.body_materials[body_id] = material
	if ctx.bodies.is_empty():
		return
	var kernel: RefCounted = ctx.kernel
	var cap_material := StandardMaterial3D.new()
	cap_material.albedo_color = CAP_COLOR
	cap_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	var area := 0.0
	# Bodies whose section can't be made are left uncapped and named in the readout; the others
	# still show (one body's failure dropped every cap). Only when none can be made is it an error.
	var failed := []
	var made := 0
	var open_curves := 0
	for body_id in ctx.bodies:
		if MESH_BODY.is_mesh(ctx.bodies[body_id]):
			# A mesh body's section is the lines where the plane cuts its triangles.
			var cut := mesh_section(ctx.bodies[body_id].shape, origin, normal)
			for line in cut.lines:
				out.lines.append({"points": line, "color": CAP_COLOR, "body": body_id})
			area += float(cut.area)
			open_curves += int(cut.open)
			made += 1
			continue
		# Only solids have an inside to cap: surfaces are skipped, a body's open faces left out.
		var solid := INSPECT.solid_shape(kernel, ctx.bodies[body_id].shape)
		if solid == null or solid.is_null() or float(solid.volume()) <= 0.0:
			continue
		# The solid's cross-section, checked against where the plane crosses its faces (a common with
		# a plane came out empty, or without its hole, on small stitched and thickened caps).
		var cap: RefCounted = kernel.section_faces(solid, origin, normal)
		if cap == null:
			var name: String = ctx.doc.body_name(body_id) if ctx.doc != null else str(body_id)
			failed.append("The section through %s could not be made: %s" % [name, kernel.get_last_error()])
			continue
		made += 1
		if cap.is_null() or cap.face_count() == 0:
			continue
		var mesh := TESSELLATE.surface_mesh(TESSELLATE.tessellate(cap))
		if mesh.get_surface_count() == 0:
			continue
		out.meshes.append({"mesh": mesh, "material": cap_material, "body": body_id})
		area += cap.area()
	if made == 0 and not failed.is_empty():
		_fail(out, "; ".join(failed))
		return
	var unit := _units(ctx.doc)
	var factor := float(UNITS.LENGTH_UNITS.get(unit, 1.0))
	out.info = "Section area %s %s²" % [significant(area / (factor * factor)), unit]
	if open_curves > 0:
		out.info += " (%d section curve%s of mesh bodies %s open)" % [open_curves, "" if open_curves == 1 else "s", "is" if open_curves == 1 else "are"]
	if not failed.is_empty():
		out.info += " (not counting %d bod%s left uncapped: %s)" % [failed.size(), "y" if failed.size() == 1 else "ies", "; ".join(failed)]


## Where a plane cuts a mesh body (CadMesh.section): {"lines": [PackedVector3Array, a closed curve
## ends on its first point], "area": the area the curves enclose (m^2; 0 for an open mesh, which has
## no inside; a curve inside another is a hole, one inside that an island), "open": how many curves
## aren't closed}.
static func mesh_section(shape: RefCounted, origin: Vector3, normal: Vector3) -> Dictionary:
	var lines := []
	var loops := []
	var open := 0
	var n := normal.normalized()
	var u := n.cross(Vector3.UP if absf(n.y) < 0.9 else Vector3.RIGHT).normalized()
	var v := n.cross(u)
	for curve in shape.section(origin, n):
		var points: PackedVector3Array = curve.get("points", PackedVector3Array())
		if points.size() < 2:
			continue
		if not bool(curve.get("closed", false)):
			open += 1
			lines.append(points)
			continue
		var flat := PackedVector2Array()
		for p in points:
			flat.append(Vector2((p - origin).dot(u), (p - origin).dot(v)))
		loops.append(flat)
		var closed := points.duplicate()
		closed.append(points[0])
		lines.append(closed)
	var area := 0.0
	if MESH_BODY.shape_kind(shape) == "solid":
		for i in loops.size():
			var loop: PackedVector2Array = loops[i]
			var twice := 0.0
			for k in loop.size():
				twice += loop[k].cross(loop[(k + 1) % loop.size()])
			var depth := 0
			for j in loops.size():
				if j != i and Geometry2D.is_point_in_polygon(loop[0], loops[j]):
					depth += 1
			area += absf(twice) * 0.5 * (1.0 if depth % 2 == 0 else -1.0)
	return {"lines": lines, "area": maxf(area, 0.0), "open": open}


# --- Center of mass --------------------------------------------------------------------------

## INSPECT.mass_properties() (it takes mesh bodies in itself now; kept for its callers). poses
## ({body id: xform64}, Phase 8 C7.4): posed bodies, as INSPECT.mass_properties takes them.
static func mass_properties(doc: Resource, result: Dictionary, body_ids: Array, poses := {}) -> Dictionary:
	return INSPECT.mass_properties(doc, result, body_ids, poses)


## Each body's point is where it is modelled with "body" (the view moves it with the body's pose);
## with several bodies the total's point is where build()'s poses put it (no "body"), with one it
## is that body's own point.
static func _center_of_mass(out: Dictionary, options: Dictionary, ctx: Dictionary) -> void:
	var doc: Resource = ctx.doc
	var ids: Array = options.get("body_ids", [])
	# Listed bodies are measured as listed; otherwise every shown body.
	var source: Dictionary = ctx.result if not ids.is_empty() else {"bodies": ctx.bodies}
	var props := mass_properties(doc, source, ids)
	var per_body: Dictionary = props.bodies
	if per_body.is_empty():
		out.info = "No bodies"
		return
	var poses: Dictionary = ctx.get("poses", {})
	var total: Dictionary = props if poses.is_empty() else mass_properties(doc, source, ids, poses)
	if per_body.size() > 1:
		for body_id in per_body:
			out.points.append({"position": per_body[body_id].center, "color": COM_COLORS.body, "label": doc.body_name(body_id) if doc != null else str(body_id), "body": body_id})
		out.points.append({"position": total.center, "color": COM_COLORS.total, "label": "Center of Mass"})
	else:
		out.points.append({"position": props.center, "color": COM_COLORS.total, "label": "Center of Mass", "body": per_body.keys()[0]})
	props = total
	out.info = "Mass %s kg, center (%s, %s, %s)" % [significant(float(props.mass)), _length(props.center.x, doc), _length(props.center.y, doc), _length(props.center.z, doc)]
	# What is wrong with a mesh body (open, inside-out, crossing itself, ...) is said with its name.
	var told := PackedStringArray(props.get("warnings", PackedStringArray()))
	if not told.is_empty():
		out.info += " (%s)" % " ".join(told)
