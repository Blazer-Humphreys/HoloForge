@tool
extends RefCounted
## Hole and Thread.
##
## Hole options: points (point picks), face (the face it starts on; sets the direction),
## hole_type (simple | counterbore | countersink), tap_type (simple | clearance | tapped |
## taper_tapped), standard, size, fit (close | normal | loose), modeled (cut real threads),
## drill_point (flat | angled), extent (distance | to | all), to_object, flip.
## Inputs: diameter, depth, cb_diameter, cb_depth, cs_diameter, cs_angle, drill_angle.
## Clearance and tapped holes take their drill size from the standard's table.
##
## Thread options: faces (round faces), standard, size ("" picks the closest size), modeled
## (false keeps a cosmetic thread: no geometry, just a note), full_length, left, flip.
## Inputs: length, offset.

const UTIL := preload("res://addons/holo_forge/core/features/util.gd")
const REFERENCES := preload("res://addons/holo_forge/core/references.gd")
const SKETCH_SOLID := preload("res://addons/holo_forge/core/features/sketch_solid.gd")

const TABLE_PATH := "res://addons/holo_forge/data/hole_thread_tables.json"
const UNIT_METERS := {"mm": 0.001, "in": 0.0254}
## Thread depth as a share of the pitch (ISO basic profile): external and internal.
const EXTERNAL_DEPTH := 0.6134
const INTERNAL_DEPTH := 0.5413

static var _table := {}


static func build(feature: Resource, ctx: Dictionary) -> String:
	match feature.type:
		"hole":
			return hole(feature, ctx)
		"thread":
			return thread(feature, ctx)
	return "Unknown feature '%s'" % feature.type


# --- Size table ------------------------------------------------------------------------------

static func table() -> Dictionary:
	if _table.is_empty():
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(TABLE_PATH))
		_table = parsed.get("standards", {}) if parsed is Dictionary else {}
	return _table


static func standards() -> Array:
	return table().keys()


static func size_names(standard: String) -> Array:
	var names := []
	for size in (table().get(standard, {}) as Dictionary).get("sizes", []):
		names.append(size.name)
	return names


## A size with every length in meters: {"name", "major", "pitch", "tap_drill", "clearance":
## {close, normal, loose}, "counterbore": {diameter, depth}, "countersink", "countersink_angle"},
## or {} when the standard has no such size.
static func size_info(standard: String, name: String) -> Dictionary:
	var std: Dictionary = table().get(standard, {})
	var unit := float(UNIT_METERS.get(std.get("unit", "mm"), 0.001))
	for size in std.get("sizes", []):
		if size.name != name:
			continue
		var clearance := {}
		for fit in size.clearance:
			clearance[fit] = float(size.clearance[fit]) * unit
		return {
			"name": name, "major": float(size.major) * unit,
			"pitch": float(size.pitch) * unit if size.has("pitch") else unit / float(size.tpi),
			"tap_drill": float(size.tap_drill) * unit, "clearance": clearance,
			"counterbore": {"diameter": float(size.counterbore.diameter) * unit, "depth": float(size.counterbore.depth) * unit},
			"countersink": float(size.countersink) * unit, "countersink_angle": deg_to_rad(float(std.get("countersink_angle", 90))),
		}
	return {}


## The size whose major (or, for holes, tap drill) diameter is closest to diameter.
static func closest_size(standard: String, diameter: float, internal: bool) -> Dictionary:
	var best := {}
	var best_gap := INF
	for name in size_names(standard):
		var info := size_info(standard, name)
		var gap := absf(float(info.tap_drill if internal else info.major) - diameter)
		if gap < best_gap:
			best_gap = gap
			best = info
	return best


# --- Hole ------------------------------------------------------------------------------------

static func hole(feature: Resource, ctx: Dictionary) -> String:
	var r := UTIL.Reader.new(feature, ctx)
	var tap := str(r.opt("tap_type", "simple"))
	var size := {}
	if tap != "simple":
		size = size_info(str(r.opt("standard", "ISO Metric")), str(r.opt("size", "M6")))
		if size.is_empty():
			return "Unknown thread size %s %s" % [r.opt("standard", ""), r.opt("size", "")]
	var diameter: float
	match tap:
		"clearance":
			diameter = float(size.clearance.get(str(r.opt("fit", "normal")), size.clearance.normal))
		"tapped", "taper_tapped":
			diameter = float(size.tap_drill)
		_:
			diameter = r.num("diameter", null, "positive")
	var hole_type := str(r.opt("hole_type", "simple"))
	var cb_diameter := 0.0
	var cb_depth := 0.0
	var cs_diameter := 0.0
	var cs_angle := 0.0
	if hole_type == "counterbore":
		cb_diameter = r.num("cb_diameter", size.get("counterbore", {}).get("diameter", diameter * 1.8), "positive")
		cb_depth = r.num("cb_depth", size.get("counterbore", {}).get("depth", diameter), "positive")
		if cb_diameter <= diameter:
			r.fail("The counterbore must be wider than the hole")
	elif hole_type == "countersink":
		cs_diameter = r.num("cs_diameter", size.get("countersink", diameter * 2.0), "positive")
		cs_angle = r.num("cs_angle", size.get("countersink_angle", PI * 0.5), "positive")
		if cs_diameter <= diameter:
			r.fail("The countersink must be wider than the hole")
	var drill_angle := r.num("drill_angle", deg_to_rad(118.0), "positive") if str(r.opt("drill_point", "flat")) == "angled" else 0.0
	if not r.ok():
		return r.error

	# Where each hole starts and which way it goes.
	var face_plane := {}
	var face_body := ""
	if not r.ref("face").is_empty():
		face_plane = r.plane("face")
		face_body = str(r.ref("face").get("body", ""))
	var starts := r.points("points")
	if starts.is_empty() and not face_plane.is_empty() and r.ok():
		starts.append(face_plane.origin)
	if starts.is_empty():
		r.fail("Select where the hole goes")
	if not r.ok():
		return r.error
	var directions := []
	for i in starts.size():
		var direction := Vector3.DOWN
		if not face_plane.is_empty():
			var n: Vector3 = face_plane.normal
			starts[i] = starts[i] - n * (starts[i] - (face_plane.origin as Vector3)).dot(n)
			direction = -n
		else:
			var sketch_state: Dictionary = ctx.sketches.get(r.refs("points")[i].get("sketch", ""), {})
			if not sketch_state.is_empty():
				direction = -(sketch_state.plane as Transform3D).basis.z
		directions.append(direction * (-1.0 if bool(r.opt("flip", false)) else 1.0))

	var radius := diameter * 0.5
	var cutters := []
	for i in starts.size():
		var start: Vector3 = starts[i]
		var direction: Vector3 = directions[i]
		var depth := 0.0
		match str(r.opt("extent", "distance")):
			"distance":
				depth = r.num("depth", null, "positive")
			"to":
				depth = SKETCH_SOLID.distance_to(r, "to_object", start, direction)
			"all":
				depth = UTIL.model_span(ctx, start, direction).y + UTIL.model_size(ctx) * 0.01
		if not r.ok():
			return r.error
		if depth <= 0.0:
			return "The hole doesn't go into anything (try Flip)"
		var cutter := _cutter(r, start, direction, radius, depth, hole_type, cb_diameter * 0.5, cb_depth, cs_diameter * 0.5, cs_angle, drill_angle)
		if cutter == null:
			return r.error
		if tap in ["tapped", "taper_tapped"]:
			var thread_info := {"origin": start, "axis": direction, "radius": radius, "pitch": size.pitch, "major": size.major, "length": depth}
			if bool(r.opt("modeled", false)):
				var groove := r.noted(r.kernel.thread({
					"origin": start, "axis": direction, "radius": radius, "pitch": size.pitch, "length": depth,
					"depth": (float(size.major) - diameter) * 0.5, "internal": true, "left": bool(r.opt("left", false)), "tag": feature.id,
				}), "Thread")
				if groove == null:
					return r.error
				# (When joining the groove to the hole comes out wrong, both cut the body as they are.)
				var joined: RefCounted = r.kernel.boolean(cutter, groove, 0, feature.id)
				cutter = joined if joined != null else r.checked(r.kernel.make_compound([cutter, groove]), "Thread")
				if cutter == null:
					return r.error
			elif ctx.has("threads"):
				ctx.threads["%s:%d" % [feature.id, i]] = thread_info
		cutters.append(cutter)
	var tool: RefCounted = cutters[0] if cutters.size() == 1 else r.kernel.make_compound(cutters)
	if ctx.has("tools"):
		ctx.tools[feature.id] = {"shape": tool, "operation": UTIL.OPERATIONS.CUT}
	UTIL._warn(r)
	return UTIL.OPERATIONS.apply_shape(ctx, feature, tool, UTIL.OPERATIONS.CUT, [face_body] if face_body != "" and ctx.bodies.has(face_body) else r.bodies("targets", false), "")


## The solid a hole removes: a plain cylinder for a flat simple hole (exact), otherwise its
## half-section revolved about the hole's axis. It starts a little above the face so the cut is
## clean (that part is outside the body).
static func _cutter(r: UTIL.Reader, start: Vector3, direction: Vector3, radius: float, depth: float, hole_type: String,
		cb_radius: float, cb_depth: float, cs_radius: float, cs_angle: float, drill_angle: float) -> RefCounted:
	var lip := maxf(radius, 1e-4)
	var up := -direction.normalized()
	if hole_type == "simple" and drill_angle <= 0.0:
		return r.checked(r.kernel.make_cylinder(radius, depth + lip, start + up * lip, direction, r.feature.id), "Hole")
	var outline := PackedVector2Array([Vector2(0.0, lip)])
	match hole_type:
		"counterbore":
			outline.append_array([Vector2(cb_radius, lip), Vector2(cb_radius, -cb_depth), Vector2(radius, -cb_depth)])
		"countersink":
			var sink := (cs_radius - radius) / tan(cs_angle * 0.5)
			outline.append_array([Vector2(cs_radius, lip), Vector2(cs_radius, 0.0), Vector2(radius, -sink)])
		_:
			outline.append(Vector2(radius, lip))
	outline.append(Vector2(radius, -depth))
	outline.append(Vector2(0.0, -depth - (radius / tan(drill_angle * 0.5) if drill_angle > 0.0 else 0.0)))
	var curves := []
	for i in outline.size():
		curves.append({"type": "line", "a": outline[i], "b": outline[(i + 1) % outline.size()]})
	var radial := up.cross(Vector3.RIGHT if absf(up.x) < 0.9 else Vector3.BACK).normalized()
	var frame := Transform3D(Basis(radial, up, radial.cross(up)), start)
	var regions: Array = r.kernel.sketch_regions(curves, frame, 0.0002)
	if regions.is_empty():
		r.fail("The hole's shape is not valid (check its sizes)")
		return null
	return r.checked(r.kernel.revolve(regions[0].face, {"axis_origin": start, "axis": up, "angle": TAU, "tag": r.feature.id}), "Hole")


# --- Thread ----------------------------------------------------------------------------------

static func thread(feature: Resource, ctx: Dictionary) -> String:
	var r := UTIL.Reader.new(feature, ctx)
	var groups := r.sub_shapes("faces", "face")
	if not r.ok():
		return r.error
	var standard := str(r.opt("standard", "ISO Metric"))
	for body_id in groups:
		var shape: RefCounted = groups[body_id].shape
		var grooves := []
		for face_index in groups[body_id].indices:
			var info: Dictionary = shape.face_info(face_index)
			if info.get("type", "") != "cylinder":
				return "Threads go on round (cylindrical) faces"
			var axis: Vector3 = (info.axis as Vector3).normalized()
			var axis_origin: Vector3 = info.axis_origin
			# Outside of a shaft or inside a hole: does the face point away from its axis?
			var edge_ids: PackedInt32Array = info.get("edges", PackedInt32Array())
			if edge_ids.is_empty():
				return "The round face has no edges to start a thread from"
			var on_surface: Vector3 = shape.edge_point_at(edge_ids[0], 0.0).get("point", Vector3.ZERO)
			var rel := on_surface - axis_origin
			var radial := rel - axis * rel.dot(axis)
			var external := (shape.face_normal_at(face_index, on_surface) as Vector3).dot(radial) > 0.0
			var radius := float(info.radius)
			var size := size_info(standard, str(r.opt("size", "")))
			if size.is_empty():
				size = closest_size(standard, radius * 2.0, not external)
			if size.is_empty():
				return "No thread sizes for %s" % standard
			# The face's extent along its axis, from its circular edges.
			var lo := INF
			var hi := -INF
			for e in info.get("edges", []):
				var edge: Dictionary = shape.edge_info(int(e))
				if edge.has("center"):
					var t := ((edge.center as Vector3) - axis_origin).dot(axis)
					lo = minf(lo, t)
					hi = maxf(hi, t)
			if lo > hi:
				return "The round face's ends couldn't be found"
			var offset := r.num("offset", 0.0, "non_negative")
			# Full length runs from the offset to the face's far end (no further: a groove running
			# on past an end face is cut by it partway along its flanks, which the boolean gets
			# wrong).
			var length := hi - lo - offset if bool(r.opt("full_length", true)) else r.num("length", null, "positive")
			if not r.ok():
				return r.error
			if length <= 0.0:
				return "The thread's offset leaves none of the round face to thread"
			var flip := bool(r.opt("flip", false))
			var origin := axis_origin + axis * ((hi - offset) if flip else (lo + offset))
			var thread_axis := -axis if flip else axis
			var depth := float(size.pitch) * (EXTERNAL_DEPTH if external else INTERNAL_DEPTH)
			if not bool(r.opt("modeled", false)):
				if ctx.has("threads"):
					ctx.threads["%s:%s:%d" % [feature.id, body_id, face_index]] = {
						"origin": origin, "axis": thread_axis, "radius": radius, "pitch": size.pitch, "length": length, "size": size.name,
					}
				continue
			var params := {
				"origin": origin, "axis": thread_axis, "radius": radius, "pitch": size.pitch, "length": length,
				"depth": depth, "internal": not external, "left": bool(r.opt("left", false)), "tag": feature.id,
			}
			var groove := r.noted(r.kernel.thread(params), "Thread")
			if groove == null:
				return r.error
			grooves.append([groove, params if bool(r.opt("full_length", true)) else {}])
		var cut := shape
		for entry in grooves:
			var next: RefCounted = r.kernel.boolean(cut, entry[0], 1, feature.id)
			var params: Dictionary = entry[1]
			if next == null and not params.is_empty() and float(params.length) > float(params.pitch):
				# The cut where a full-length groove meets the face's far end can come out wrong: the
				# groove then stops a pitch short of it, and the warning says so.
				var short := params.duplicate()
				short.length = float(params.length) - float(params.pitch)
				var shorter: RefCounted = r.kernel.thread(short)
				next = r.kernel.boolean(cut, shorter, 1, feature.id) if shorter != null else null
				if next != null:
					r.notes.append("The thread stops %.2f mm short of the round face's end (the cut through the end came out wrong)" % (float(params.pitch) * 1000.0))
			cut = r.checked(next, "Thread")
			if cut == null:
				return r.error
		ctx.bodies[body_id].shape = cut
	UTIL._warn(r)
	return ""
