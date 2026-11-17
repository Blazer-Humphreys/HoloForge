@tool
extends RefCounted
## Mesh bodies: what tells a mesh body from a B-rep body, the one sentence Solid and Surface tools
## refuse it with (the gate), and the Inspect values a mesh body gives.
##
## A mesh body's entry in a regen result is {"id", "shape": CadMesh, "feature", "kind": "mesh"}.
## B-rep entries have no "kind". A CadMesh answers the read-only part of CadShape that display,
## picking, baking, measuring and export use (is_null, bbox, tessellate, volume, area, face_count,
## get_face_names, find_face, face_info, ...): its face groups stand for faces. It has no edges,
## no face_shape(), no solids(): code that needs those must ask is_mesh() first, or go through
## the gate.
##
## This file preloads nothing, so every core file can preload it.
##
## const MESH_BODY := preload("res://addons/holo_forge/core/mesh/mesh_body.gd")

const KIND := "mesh"
## What a Solid or Surface tool says of a mesh body (%s: the body's name).
const GATE := "%s is a mesh body. Convert it first (Mesh > Modify > Convert Mesh)."
## What an analysis that needs B-rep surfaces says (curvature map, minimum radius, isocurve, comb).
const ANALYSIS_GATE := "Not available on mesh bodies. Convert the body first."
const DECAL_GATE := "Decals need a B-rep face. Convert the body first."
## What a B-rep exchange file (STEP, IGES, BREP) says of a mesh body (%s: the body's name).
const EXPORT_GATE := "%s is a mesh body; STEP/IGES need B-rep bodies. Convert it first, or export STL/OBJ/3MF."
const AXIS_GATE := "Pick a B-rep face; mesh groups give only planes."
const ALREADY_MESH := "%s is already a mesh body."
## What a tool that takes B-rep bodies says of one it turned into triangles first (%s: the body's
## name, then the tool's).
const TESSELLATED_FOR := "%s was tessellated for %s."
## Measure between a whole mesh body and something else (%s: the body's name).
const MEASURE_WHOLE := "Pick a face group or a point on %s to measure a distance from it (the nearest point of a whole mesh body is not found)."
const KERNEL_MISSING := "The Holo Forge mesh kernel is not loaded"
## A face group pick (with its point and facing) whose place now holds another face group (%s: the
## feature's label, the name it was picked under, the name of the group there now, the picked name
## again). Either the face groups were renumbered (then it is the face that was picked) or the body
## moved (then the picked group is elsewhere): the pick alone cannot tell which, so both are said.
const GROUP_MOVED := "%s's pick of face group %s now lands on face group %s, which is where it was picked (an earlier change renumbered the face groups or moved the body). Pick it again if %s is meant."
## A face group pick whose name now belongs to another face, with nothing where it was picked.
const GROUP_LOST := "The picked face group %s is no longer where it was picked (an earlier change moved the body or renumbered its face groups). Pick it again."
## A face group pick that is used by its name without a check (%s: the feature's label, the
## group's name, why: one of the UNCHECKED_ texts).
const GROUP_UNCHECKED := "%s's pick of face group %s could not be confirmed (%s): an earlier change may have given that name to another face. Pick it again if it is not the one meant."
const UNCHECKED_NAME := "it is kept by name only"
const UNCHECKED_SEVERAL := "several face groups meet at the picked point"
const UNCHECKED_AWAY := "the picked point is no longer on the body"
const GROUP_GONE := "A picked face group can't be found any more"
## An open mesh body in an interference check (%s: its name).
const INTERFERENCE_OPEN := "%s is an open mesh body, so it has no volume to overlap with. Close Holes or Wrap can close it."
## Why other mesh bodies have no volume to overlap with (%s: the body's name), by the kernel's flaw.
const NO_VOLUME := {
	"wrong_way": "%s is closed, but some of its triangles face the other way than their neighbours, so it has no volume to overlap with. Reverse Normal can turn them, or Wrap can make a new closed body of it.",
	"no_volume": "%s is closed but holds no volume (its faces lie on each other), so there is nothing to overlap with.",
	"": "%s is not a closed solid, so it has no volume to overlap with. Stitch and Remove, Close Holes or Wrap can make it one.",
}
## A face group still counts as the one picked when it passes within this fraction of the body's
## size of the picked point, and (cosine) faces within about 20 degrees of how it faced then.
const GROUP_AT_TOLERANCE := 1e-4
const GROUP_NORMAL_COS := 0.94
## A pick whose point is gone is looked for by its plane among at most this many face groups.
const GROUP_PLANE_SEARCH := 5000
## The mass-property keys that tell what is wrong with a mesh body (CadMesh.mass_properties).
const FLAW_KEYS := ["flaws", "wrong_way_edges", "inside_out_parts", "self_intersections", "warning"]
## Reference kinds that point into a mesh body (core/references.gd).
const GROUP_REF := "mesh_group"
const TRIANGLES_REF := "mesh_triangles"
## Selection filter kinds a tool lists to accept mesh bodies (tools/feature_specs.gd).
const FILTER_KINDS := ["mesh_body", "mesh_group", "mesh_triangles", "mesh_boundary"]
## A common volume at or below this fraction of the smaller body is touching, not interference
## (as core/inspect.gd).
const INTERFERENCE_TOLERANCE := 1e-9

## Test seam: true makes available() answer false, as when the native library is missing.
static var force_missing := false


## True when the native mesh class is loaded.
static func available() -> bool:
	return not force_missing and ClassDB.class_exists("CadMesh")


## An empty CadMesh to fill (set_arrays, from_blob, read_stl, ...), or null without the library.
static func new_mesh() -> RefCounted:
	return ClassDB.instantiate("CadMesh") if available() else null


## True for a mesh body: a regen entry ({"kind": "mesh"} or one whose shape is a CadMesh) or a
## shape. Never test the class name instead.
static func is_mesh(entry_or_shape: Variant) -> bool:
	if entry_or_shape is Dictionary:
		var item: Dictionary = entry_or_shape
		if str(item.get("kind", "brep")) == KIND:
			return true
		return is_mesh(item.get("shape"))
	if entry_or_shape is Object and is_instance_valid(entry_or_shape):
		var shape: Object = entry_or_shape
		return shape.has_method("is_mesh") and bool(shape.is_mesh())
	return false


## "mesh" or "brep" for a regen entry.
static func kind_of(item: Dictionary) -> String:
	return KIND if is_mesh(item) else "brep"


## A regen entry for a mesh body.
static func entry(body_id: String, mesh: RefCounted, feature_id: String) -> Dictionary:
	return {"id": body_id, "shape": mesh, "feature": feature_id, "kind": KIND}


static func body_name(doc: Resource, body_id: String) -> String:
	return str(doc.body_name(body_id)) if doc != null and doc.has_method("body_name") else body_id


## The gate: "" when no entry is a mesh body, else GATE for the first one that is. entries: regen
## entries ({"id", "shape", ...}).
static func gate(doc: Resource, entries: Array) -> String:
	for item in entries:
		if item is Dictionary and is_mesh(item):
			return GATE % body_name(doc, str((item as Dictionary).get("id", "")))
	return ""


## gate() for body ids of ctx.bodies (ids that aren't there are skipped).
static func gate_ids(ctx: Dictionary, ids: Array) -> String:
	var bodies: Dictionary = ctx.get("bodies", {})
	for id in ids:
		var found: Variant = bodies.get(id)
		if found is Dictionary and is_mesh(found):
			return GATE % body_name(ctx.get("doc"), str(id))
	return ""


## gate() for one reference's body ({"body": id, ...}).
static func gate_ref(ref: Dictionary, ctx: Dictionary) -> String:
	return gate_ids(ctx, [ref.get("body", "")])


## The label of a face group in the UI: "Face Group 3" (index + 1). The name is the stored
## identity; pass either.
static func group_label(shape: RefCounted, group: Variant) -> String:
	var index: int = int(group) if group is int else (int(shape.find_face(str(group))) if shape != null else -1)
	return "Face Group %d" % (index + 1) if index >= 0 else "Face Group"


# --- Inspect ---------------------------------------------------------------------------------

## "solid" for a closed mesh that holds at least one solid part, else "surface" (the same words
## core/inspect.gd shape_kind uses; a mesh is never "mixed").
static func shape_kind(shape: RefCounted) -> String:
	if shape == null or shape.is_null():
		return "surface"
	return "solid" if not bool(shape.is_surface()) and int(shape.solid_count()) > 0 else "surface"


## The volume of a mesh body (m^3): 0 for an open one.
static func solid_volume(shape: RefCounted) -> float:
	# (An inside-out body's signed volume is negative; what it encloses is its size.)
	return absf(float(shape.volume())) if shape_kind(shape) == "solid" else 0.0


## Mass properties in the form of core/inspect.gd shape_mass_properties ({"mass", "volume", "area",
## "center", "inertia" (9 floats, row-major), "principal_moments"}). An open mesh has no volume
## and no mass: its center is its surface's and its inertia zero. A body with something wrong
## also carries what the kernel found (never a negative mass): "flaws" (PackedStringArray of
## "open", "wrong_way", "no_volume", "inside_out", "self_crossing"), the counts "wrong_way_edges",
## "inside_out_parts" and "self_intersections", and "warning" (a sentence for the user).
static func mass_properties(shape: RefCounted, density: float) -> Dictionary:
	var none := PackedFloat64Array()
	none.resize(9)
	none.fill(0.0)
	if shape == null or shape.is_null():
		return {"mass": 0.0, "volume": 0.0, "area": 0.0, "center": Vector3.ZERO, "inertia": none, "principal_moments": Vector3.ZERO}
	var props: Dictionary = shape.mass_properties(density)
	var result := {
		"mass": float(props.get("mass", 0.0)), "volume": float(props.get("volume", 0.0)), "area": float(props.get("area", 0.0)),
		"center": props.get("center", Vector3.ZERO), "inertia": PackedFloat64Array(props.get("inertia", none)),
		"principal_moments": props.get("principal_moments", Vector3.ZERO),
	}
	if shape_kind(shape) != "solid":
		# Only solids have mass (as B-rep surface bodies): no shell inertia either.
		result.mass = 0.0
		result.volume = 0.0
		result.inertia = none
		result.principal_moments = Vector3.ZERO
	for key in FLAW_KEYS:
		if props.has(key):
			result[key] = props[key]
	return result


## Measure for references on mesh bodies, in the form of core/inspect.gd measure(). One reference
## gives its own values:
##   {"kind": "body", "body"}                  {"kind": "body", "mesh": true, "volume", "area",
##                                             "triangles", "groups", "surface" (open mesh)}
##   {"kind": "mesh_group", "body", "group"}   {"kind": "face", "mesh": true, "face_type" ("plane"
##                                             | "mesh_group"), "area", "point", "normal" (flat
##                                             groups), "triangles", "group"}
##   {"kind": "mesh_triangles", "body", "triangles"}  {"kind": "triangles", "mesh": true, "count"}
## Two references give {"kind": "distance", "distance", "point_a", "point_b", "delta", "first",
## "second", "note", and "angle" between two flat groups}: the distance between the points the
## picks hit (a reference's "at"), else a face group's middle; "note" says which. The second
## reference may also be a plain point ({"kind": "vertex", "point"} or the origin point). A whole
## mesh body without a picked point has no point to measure from: MEASURE_WHOLE.
## Returns {} when the first reference is not on a mesh body (core/inspect.gd measure() takes
## every kind of reference, and sends these here), and {"error": text} for a problem.
static func measure(a: Dictionary, b: Dictionary, ctx: Dictionary) -> Dictionary:
	if not is_mesh((ctx.get("bodies", {}) as Dictionary).get(a.get("body", ""), {})):
		return {}
	var first := geometry(a, ctx)
	if first.has("error") or b.is_empty():
		return first if first.has("error") else first.values
	var second := geometry(b, ctx)
	if second.has("error"):
		return second
	for side in [[first, a], [second, b]]:
		if bool(side[0].get("whole", false)):
			return {"error": MEASURE_WHOLE % body_name(ctx.get("doc"), str(side[1].get("body", "")))}
	var point_a: Vector3 = first.point
	var point_b: Vector3 = second.point
	var measured := {
		"kind": "distance", "distance": point_a.distance_to(point_b), "point_a": point_a, "point_b": point_b,
		"delta": point_b - point_a, "first": first.values, "second": second.values,
		"note": "Measured between %s and %s." % [first.from, second.from],
	}
	if first.has("normal") and second.has("normal"):
		var na: Vector3 = (first.normal as Vector3).normalized()
		var nb: Vector3 = (second.normal as Vector3).normalized()
		measured["angle"] = atan2(na.cross(nb).length(), absf(na.dot(nb)))
	return measured


## What a reference on a mesh body (or a plain point) gives Measure: {"values" (its own values),
## "point" (where a distance is measured from: the point the pick hit, "at", else a face group's
## middle), "from" (that point in words), "normal" (flat groups), "whole": true (a body without a
## picked point: its center is no place to measure from)}, or {"error"}.
static func geometry(ref: Dictionary, ctx: Dictionary) -> Dictionary:
	var kind := str(ref.get("kind", ""))
	if kind == "vertex" and ref.get("point") is Vector3:
		return {"values": {"kind": "point", "position": ref.point}, "point": ref.point, "from": "a point"}
	if kind == "origin" and str(ref.get("name", "")) == "o":
		return {"values": {"kind": "point", "position": Vector3.ZERO}, "point": Vector3.ZERO, "from": "the origin"}
	var name := body_name(ctx.get("doc"), str(ref.get("body", "")))
	var picked := "the point picked on %s" % name
	var found: Dictionary = (ctx.get("bodies", {}) as Dictionary).get(ref.get("body", ""), {})
	if found.is_empty():
		return {"error": "That body no longer exists"}
	if not is_mesh(found):
		return {"error": "Pick points on mesh bodies to measure between them"}
	var shape: RefCounted = found.shape
	match kind:
		"body":
			var values := {
				"kind": "body", "mesh": true, "volume": solid_volume(shape), "area": float(shape.area()),
				"triangles": int(shape.triangle_count()), "groups": int(shape.face_count()),
			}
			if shape_kind(shape) == "surface":
				values["surface"] = true
			if ref.get("at") is Vector3:
				return {"values": values, "point": ref.at, "from": picked}
			return {"values": values, "point": shape.center_of_mass(), "from": "the center of %s" % name, "whole": true}
		GROUP_REF, "face":
			# (Found again where it was picked when an earlier change renumbered the groups.)
			var resolved := resolve_group(shape, ref)
			if resolved.has("error"):
				return resolved
			var index := int(resolved.index)
			var info: Dictionary = shape.face_info(index)
			var values := {
				"kind": "face", "mesh": true, "face_type": str(info.get("type", "mesh_group")), "area": float(info.get("area", 0.0)),
				"point": info.get("point", Vector3.ZERO), "triangles": int(info.get("triangles", 0)),
				"group": str(shape.get_face_names()[index]),
			}
			var of_group := {"values": values, "point": ref.get("at", values.point), "from": picked if ref.get("at") is Vector3 else "the middle of a face group of %s" % name}
			if bool(info.get("planar", false)):
				values["normal"] = info.normal
				of_group["normal"] = info.normal
			return of_group
		TRIANGLES_REF:
			var list: PackedInt32Array = ref.get("triangles", PackedInt32Array())
			if not ref.get("at") is Vector3:
				return {"values": {"kind": "triangles", "mesh": true, "count": list.size()}, "point": shape.center_of_mass(), "from": "the center of %s" % name, "whole": true}
			return {"values": {"kind": "triangles", "mesh": true, "count": list.size()}, "point": ref.at, "from": picked}
	return {"error": "That can't be measured"}


## The area-weighted middle of a mesh body's surface (as CadShape.area_center): its face groups'
## middles weighted by their areas, summed in doubles. The middle of its box when it has no area.
static func area_center(shape: RefCounted) -> Vector3:
	if shape == null or shape.is_null():
		return Vector3.ZERO
	var sum := PackedFloat64Array([0.0, 0.0, 0.0])
	var total := 0.0
	for i in int(shape.face_count()):
		var info: Dictionary = shape.face_info(i)
		var area := float(info.get("area", 0.0))
		var point: Vector3 = info.get("point", Vector3.ZERO)
		total += area
		for k in 3:
			sum[k] += area * point[k]
	if not total > 0.0:
		return (shape.bbox() as AABB).get_center()
	return Vector3(sum[0] / total, sum[1] / total, sum[2] / total)


## The overlap of two mesh bodies: {"volume", "shape" (a CadMesh, or null when they don't
## overlap)}. Only closed bodies overlap by a volume; touching is not interference. Needs the
## native mesh boolean: without it the answer is {"volume": 0.0, "shape": null, "error": why,
## "unavailable": true}. A pair the boolean can't intersect comes back with "error".
static func interference(a: RefCounted, b: RefCounted, time_limit := 20.0, name_a := "", name_b := "") -> Dictionary:
	if shape_kind(a) != "solid" or shape_kind(b) != "solid":
		return {"volume": 0.0, "shape": null}
	if not (a.bbox() as AABB).intersects(b.bbox() as AABB):
		return {"volume": 0.0, "shape": null}
	if not a.has_method("boolean"):
		return {"volume": 0.0, "shape": null, "unavailable": true,
			"error": "Interference between mesh bodies needs the mesh Combine tool, which this build does not have yet."}
	# The names go into the kernel's sentences ("<Name> crosses itself ...", "<Name> has 1 part
	# that is inside-out ...").
	var options := {"operation": "intersect", "time_limit": clampf(time_limit, 0.05, 120.0)}
	if name_a != "":
		options["name"] = name_a
	if name_b != "":
		options["tool_names"] = PackedStringArray([name_b])
	var common: RefCounted = a.boolean([b], options)
	if common == null or common.is_null():
		# An empty intersection is no interference, not a failure. The kernel says so with
		# "empty": true in its report.
		var report: Dictionary = a.get_last_report()
		if common != null or bool(report.get("empty", false)):
			return {"volume": 0.0, "shape": null}
		var why := str(a.get_last_error())
		# Fallback for a kernel build without that flag (builds before 2026-11-11 18:53 gave an
		# empty report here): its sentence for an empty result. Remove once no such build is left.
		if not report.has("empty") and (why == "" or why.contains("empty") or why.contains("do not overlap")):
			return {"volume": 0.0, "shape": null}
		return {"volume": 0.0, "shape": null, "error": why}
	var volume := float(common.volume())
	if volume > INTERFERENCE_TOLERANCE * minf(absf(float(a.volume())), absf(float(b.volume()))) + 1e-18:
		var hit := {"volume": volume, "shape": common}
		# What the kernel says of the result (a body that crosses itself makes it wrong there).
		var warning := str(a.get_last_warning())
		if warning != "":
			hit["warning"] = warning
		return hit
	return {"volume": 0.0, "shape": null}


# --- Face group picks ------------------------------------------------------------------------

## The face group a pick points to now: {"index", "name", "moved": false} when the named group is
## still the one picked; {"index", "name", "moved": true, "from": the name it was picked under}
## when the pick now lands on another group than the one of its name (the groups were renumbered,
## or the body was moved and another face is now where it was picked: which one is not known;
## moved_note says both); {"index", "name",
## "moved": false, "unchecked": true, "why"} when the group of that name is used but the pick
## could not be confirmed (why: a few words for a warning, unchecked_note); {"error"} when it
## can't be found or is clearly no longer the one picked.
##
## A pick is {"group": name} with, when it came from the view, "at" (the point picked) and
## "normal" (how the surface faced there). Names such as g0..gN are given by order, so an earlier
## change can hand a name to another face.
##
## With "at" and "normal" the pick can be followed: the named group counts when it still passes
## through "at", facing as it did. If it doesn't, the group that does is taken instead (moved).
## If no group passes there (that spot was cut away, or the body moved), a flat pick is looked for
## by its plane: the flat groups that face as it did and lie in the plane through "at"; the named
## one among them counts, else the one whose middle is nearest (moved). If that finds nothing
## either, the name is trusted (unchecked), unless the named group is flat and now faces another
## way: then the pick is lost.
##
## With "at" alone nothing is ever followed (a point does not say which of the faces that meet
## there was meant, nor whether the body moved under it): the pick is confirmed when the named
## group is the only one through the point; it is lost when the point is clearly off the named
## group (off a flat group's plane, or on another group while the named one is elsewhere); in
## between the name is used, unchecked. With the name alone nothing can be checked: unchecked.
static func resolve_group(shape: RefCounted, ref: Dictionary) -> Dictionary:
	var name := str(ref.get("group", ref.get("name", "")))
	var index := int(shape.find_face(name))
	if not (ref.get("at") is Vector3):
		return {"index": index, "name": name, "moved": false, "unchecked": true, "why": UNCHECKED_NAME} if index >= 0 else {"error": GROUP_GONE}
	var at: Vector3 = ref.at
	var wanted := Vector3.ZERO
	if ref.get("normal") is Vector3 and (ref.normal as Vector3).length() > 0.5:
		wanted = (ref.normal as Vector3).normalized()
	var here := groups_at(shape, at, wanted)
	if wanted == Vector3.ZERO:
		return _resolve_by_point(shape, name, index, at, here)
	var best := {}
	for found in here:
		if (found.normal as Vector3).dot(wanted) < GROUP_NORMAL_COS:
			continue
		if int(found.group) == index:
			return {"index": index, "name": name, "moved": false}
		if best.is_empty() or (found.normal as Vector3).dot(wanted) > (best.normal as Vector3).dot(wanted):
			best = found
	if not best.is_empty():
		return {"index": int(best.group), "name": str(shape.get_face_names()[int(best.group)]), "moved": true, "from": name}
	# Nothing at the point any more: a flat pick is still known by its plane.
	var nearest := -1
	var nearest_distance := INF
	for g in _flat_groups_through(shape, at, wanted):
		if g == index:
			return {"index": index, "name": name, "moved": false}
		var middle: Vector3 = shape.face_info(g).get("point", Vector3.ZERO)
		if middle.distance_to(at) < nearest_distance:
			nearest_distance = middle.distance_to(at)
			nearest = g
	if nearest >= 0:
		return {"index": nearest, "name": str(shape.get_face_names()[nearest]), "moved": true, "from": name}
	if index < 0:
		return {"error": GROUP_GONE}
	var info: Dictionary = shape.face_info(index)
	if bool(info.get("planar", false)) and (info.get("normal", Vector3.ZERO) as Vector3).dot(wanted) < GROUP_NORMAL_COS:
		return {"error": GROUP_LOST % name}
	return {"index": index, "name": name, "moved": false, "unchecked": true, "why": UNCHECKED_AWAY}


## resolve_group() for a pick with a point and no facing (see there).
static func _resolve_by_point(shape: RefCounted, name: String, index: int, at: Vector3, here: Array) -> Dictionary:
	var named_here := false
	for found in here:
		named_here = named_here or int(found.group) == index
	if named_here and here.size() == 1:
		return {"index": index, "name": name, "moved": false}
	if index < 0:
		return {"error": GROUP_GONE}
	if named_here:
		return {"index": index, "name": name, "moved": false, "unchecked": true, "why": UNCHECKED_SEVERAL}
	# The named group does not pass through the picked point.
	var info: Dictionary = shape.face_info(index)
	if bool(info.get("planar", false)):
		var off := absf((at - (info.get("point", Vector3.ZERO) as Vector3)).dot((info.get("normal", Vector3.UP) as Vector3).normalized()))
		if off > _pick_tolerance(shape, at) * 3.0:
			return {"error": GROUP_LOST % name}
	elif not here.is_empty():
		return {"error": GROUP_LOST % name}
	return {"index": index, "name": name, "moved": false, "unchecked": true, "why": UNCHECKED_AWAY}


## The face groups that pass through a point of a mesh body: [{"group": index, "normal": the
## triangle's there}], found with short rays at the point from several sides (along normal first
## when given). A hit counts within GROUP_AT_TOLERANCE of the body's size.
static func groups_at(shape: RefCounted, at: Vector3, normal := Vector3.ZERO) -> Array:
	var tolerance := _pick_tolerance(shape, at)
	var reach := tolerance * 10.0
	var directions: Array[Vector3] = []
	if normal.length() > 0.5:
		directions.append(normal.normalized())
		directions.append(-normal.normalized())
	for d: Vector3 in [Vector3.RIGHT, Vector3.UP, Vector3.BACK, Vector3(1, 1, 1), Vector3(1, 1, -1), Vector3(1, -1, 1), Vector3(-1, 1, 1)]:
		directions.append(d.normalized())
		directions.append(-d.normalized())
	var found := {}
	for d in directions:
		var hit: Dictionary = shape.ray_hit(at + d * reach, -d, reach * 2.0)
		if not bool(hit.get("hit", false)) or ((hit.point as Vector3) - at).length() > tolerance * 3.0:
			continue
		if not found.has(int(hit.group)):
			found[int(hit.group)] = {"group": int(hit.group), "normal": hit.normal}
	return found.values()


## How near a point counts as on a mesh body's surface (meters): GROUP_AT_TOLERANCE of its size,
## and never under what its float coordinates can tell apart.
static func _pick_tolerance(shape: RefCounted, at: Vector3) -> float:
	var size: float = (shape.bbox() as AABB).size.length()
	var reach_of_floats := maxf(maxf(absf(at.x), absf(at.y)), absf(at.z)) * 2e-6
	return maxf(maxf(size * GROUP_AT_TOLERANCE, reach_of_floats), 1e-7)


## The flat face groups that face along normal and lie in the plane through at (indices). Bodies
## with more than GROUP_PLANE_SEARCH groups are not searched.
static func _flat_groups_through(shape: RefCounted, at: Vector3, normal: Vector3) -> PackedInt32Array:
	var found := PackedInt32Array()
	var count := int(shape.face_count())
	if count > GROUP_PLANE_SEARCH:
		return found
	var tolerance := _pick_tolerance(shape, at) * 3.0
	for g in count:
		var info: Dictionary = shape.face_info(g)
		if not bool(info.get("planar", false)):
			continue
		var facing: Vector3 = info.get("normal", Vector3.ZERO)
		if facing.dot(normal) >= GROUP_NORMAL_COS and absf((at - (info.get("point", Vector3.ZERO) as Vector3)).dot(facing)) <= tolerance:
			found.append(g)
	return found


## The warning for a pick resolve_group() used without a check (its "why").
static func unchecked_note(label: String, group: String, why: String) -> String:
	return GROUP_UNCHECKED % [label, group, why if why != "" else UNCHECKED_NAME]


## Why a mesh body that is not a solid has no volume to overlap with, as a sentence: an open one
## (boundary edges), a closed one whose triangles disagree, one without volume.
static func no_volume_reason(shape: RefCounted, name: String) -> String:
	var flaws := PackedStringArray()
	if shape != null and not shape.is_null() and shape.has_method("mass_properties"):
		flaws = PackedStringArray((shape.mass_properties(1.0) as Dictionary).get("flaws", PackedStringArray()))
	if flaws.has("open") or (flaws.is_empty() and shape != null and not shape.is_null() and bool(shape.is_surface())):
		return INTERFERENCE_OPEN % name
	for flaw in ["wrong_way", "no_volume"]:
		if flaws.has(flaw):
			return str(NO_VOLUME[flaw]) % name
	return str(NO_VOLUME[""]) % name


## The warning for a pick resolve_group() found under another name.
static func moved_note(label: String, from: String, to: String) -> String:
	return GROUP_MOVED % [label, from, to, from]
