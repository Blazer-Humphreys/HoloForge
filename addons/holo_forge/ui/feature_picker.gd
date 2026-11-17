@tool
extends RefCounted
## Picking for feature commands: turns a click in the Forge view into a reference (see
## core/references.gd) of the kinds the active selection field accepts: sketch profiles, curves
## and points, faces, edges, vertices and bodies, origin and construction planes, axes and
## points. Also draws construction geometry, the hovered item and what the command has picked.
##
## kinds: "profile", "face", "edge", "vertex", "body", "plane", "axis", "point", "path",
## "sketch_curve", "feature", "component".

const REFERENCES := preload("res://addons/holo_forge/core/references.gd")
const SKETCH := preload("res://addons/holo_forge/core/sketch/sketch_data.gd")
const TESSELLATE := preload("res://addons/holo_forge/core/tessellate.gd")

signal picked(ref: Dictionary)

const ACCENT := Color(0.2, 0.55, 1.0)
const HOVER := Color(0.45, 0.75, 1.0)
const CONSTRUCTION := Color(0.95, 0.6, 0.15)
const RADIUS_PX := 7.0
const ORIGIN_AXES := {"x": Vector3.RIGHT, "y": Vector3.UP, "z": Vector3.BACK}
const ORIGIN_PLANE_KEYS := {"xy": "xy_plane", "xz": "xz_plane", "yz": "yz_plane"}

var workspace: Object
var viewport: Control
## () -> Array: the kinds the active selection field accepts ([] when none is active).
var kinds_provider: Callable
## () -> Array: the references the command has picked so far (drawn highlighted).
var picked_provider: Callable
var hover := {}
## The last clicked pick: {"ref", "point": where the click hit the body (or null)}.
var last_click := {}

var _sketches := {}
## Where the last body pick hit (pick() resets it), for last_click.
var _hit_point: Variant = null
var _profile_entries := []
var _material: StandardMaterial3D
var _material_hover: StandardMaterial3D
var _material_picked: StandardMaterial3D


func _init(p_workspace: Object, p_viewport: Control) -> void:
	workspace = p_workspace
	viewport = p_viewport
	_material = _flat_material(Color(0.35, 0.55, 0.95, 0.18))
	_material_hover = _flat_material(Color(0.35, 0.65, 1.0, 0.42))
	_material_picked = _flat_material(Color(0.2, 0.5, 1.0, 0.55))


func active() -> bool:
	return kinds_provider.is_valid() and not (kinds_provider.call() as Array).is_empty()


## Re-reads sketches after a rebuild (curves and points for picking, regions for profiles).
func refresh() -> void:
	_sketches.clear()
	_profile_entries.clear()
	var doc: Resource = workspace.doc
	var result: Dictionary = workspace.result
	if doc == null:
		return
	var deflection: float = maxf(viewport.distance * 0.0008, 0.000005)
	for feature in doc.features.slice(0, doc.active_count()):
		if feature.type != "sketch" or feature.suppressed:
			continue
		var state: Dictionary = result.get("sketches", {}).get(feature.id, {})
		var s := SKETCH.new(feature, doc)
		var curves := {}
		var points := {}
		for e in s.entities():
			var id := int(e.id)
			if e.get("construction", false) and e.type != "line":
				continue
			match str(e.type):
				"point":
					if not e.get("origin", false):
						points[id] = s.to_world(s.point(id))
				"text", "ref3d":
					pass
				_:
					var world := PackedVector3Array()
					for p in s.sample(id, workspace.kernel, deflection):
						world.append(s.to_world(p))
					curves[id] = world
		_sketches[feature.id] = {"sketch": s, "state": state, "curves": curves, "points": points, "visible": bool(feature.options.get("visible", true))}
		if feature.options.get("visible", true):
			for region in state.get("regions", []):
				_profile_entries.append({"sketch": feature.id, "region": region, "key": _profile_key(feature.id, region),
					"mesh": TESSELLATE.surface_mesh(TESSELLATE.tessellate(region.face))})
	update_display()


## Shows profile shading while profiles can be picked, and the origin planes while planes can.
func update_display() -> void:
	var kinds: Array = kinds_provider.call() if kinds_provider.is_valid() else []
	var entries := []
	if kinds.has("profile"):
		var chosen := _picked_keys()
		for entry in _profile_entries:
			var material := _material_picked if chosen.has(entry.key) else (_material_hover if hover.get("key", "") == entry.key else _material)
			entries.append({"mesh": entry.mesh, "material": material})
	if not workspace.sketch_editor.active:
		viewport.set_extra_meshes(entries)
	if workspace.doc != null and not bool(workspace.get("_plane_pick")):
		var visibility: Dictionary = (workspace.doc.origin_visibility as Dictionary).duplicate()
		if kinds.has("plane"):
			for key in ORIGIN_PLANE_KEYS.values():
				visibility[key] = true
		if kinds.has("axis") or kinds.has("point"):
			for key in ["origin", "x_axis", "y_axis", "z_axis"]:
				visibility[key] = true
		viewport.set_origin_visibility(visibility)
	viewport.redraw_overlay()


func handle_mouse(event: InputEvent) -> bool:
	if not active():
		return false
	var motion := event as InputEventMouseMotion
	if motion != null:
		var next := pick(motion.position)
		if str(next.get("key", "")) != str(hover.get("key", "")):
			hover = next
			update_display()
		return true
	var button := event as InputEventMouseButton
	if button == null or button.button_index != MOUSE_BUTTON_LEFT:
		return false
	if button.pressed:
		var ref := pick(button.position)
		if not ref.is_empty():
			ref.erase("key")
			last_click = {"ref": ref.duplicate(true), "point": _hit_point}
			picked.emit(ref)
	return true


## Where the last click hit the body for ref (a face picked on screen), or null when ref came
## from somewhere else (the browser, a test) or the click hit no body.
func click_point(ref: Dictionary) -> Variant:
	if last_click.is_empty() or last_click.ref != ref:
		return null
	return last_click.point


## The reference under a screen position for the active kinds, or {}. Carries a "key" naming
## the item (for hover).
func pick(screen: Vector2) -> Dictionary:
	var kinds: Array = kinds_provider.call() if kinds_provider.is_valid() else []
	_hit_point = null
	if kinds.is_empty():
		return {}
	var wants_point := kinds.has("point")
	var wants_curve := kinds.has("path") or kinds.has("sketch_curve") or kinds.has("axis")
	# Sketch points, then sketch curves (lines only for axes).
	if wants_point:
		var found := _nearest_sketch_point(screen)
		if not found.is_empty():
			return found
	if wants_curve:
		var found := _nearest_sketch_curve(screen, not (kinds.has("path") or kinds.has("sketch_curve")))
		if not found.is_empty():
			return found
	# Construction and origin points and axes.
	var special := _nearest_construction(screen, kinds)
	if not special.is_empty():
		return special
	# Profiles under the cursor beat the faces they lie on.
	var ray: Array = viewport.ray_from(screen)
	var face_hit: Dictionary = viewport.face_hit_at(screen)
	var face_distance := INF
	if not face_hit.is_empty():
		face_distance = (ray[0] as Vector3).distance_to(face_hit.point)
	if kinds.has("profile"):
		var profile := _profile_at(ray, face_distance)
		if not profile.is_empty():
			return profile
	var body_ref := _body_pick(screen, kinds)
	if not body_ref.is_empty():
		return body_ref
	if kinds.has("plane"):
		return _plane_at(ray)
	return {}


# --- Drawing ---------------------------------------------------------------------------------

func draw(overlay: Control) -> void:
	var result: Dictionary = workspace.result
	var size: float = viewport.origin_size()
	for id in result.get("construction", {}):
		var feature: Resource = workspace.doc.find_feature(id) if workspace.doc != null else null
		if feature != null and feature.options.get("visible", true):
			_draw_construction(overlay, result.construction[id], size, CONSTRUCTION, 1.5)
	if not active() and picked_provider.is_valid() and (picked_provider.call() as Array).is_empty():
		return
	if picked_provider.is_valid():
		for ref in picked_provider.call():
			if ref is Dictionary:
				_draw_ref(overlay, ref, ACCENT, 3.0)
	if not hover.is_empty():
		_draw_ref(overlay, hover, HOVER, 3.0)


func _draw_ref(overlay: Control, ref: Dictionary, color: Color, width: float) -> void:
	var size: float = viewport.origin_size()
	match str(ref.get("kind", "")):
		"sketch_curve":
			var line: PackedVector3Array = _sketches.get(ref.sketch, {}).get("curves", {}).get(int(ref.entity), PackedVector3Array())
			_polyline(overlay, line, color, width)
		"sketch_point":
			var p: Variant = _sketches.get(ref.sketch, {}).get("points", {}).get(int(ref.entity))
			if p != null:
				var at: Vector2 = viewport.project(p)
				if at.is_finite():
					overlay.draw_rect(Rect2(at - Vector2(4, 4), Vector2(8, 8)), color, true)
		"origin":
			if ORIGIN_AXES.has(ref.name):
				_draw_construction(overlay, {"type": "axis", "origin": Vector3.ZERO, "direction": ORIGIN_AXES[ref.name]}, size, color, width)
			elif ref.name == "o":
				_draw_construction(overlay, {"type": "point", "position": Vector3.ZERO}, size, color, width)
			else:
				var frame: Dictionary = SKETCH.ORIGIN_PLANES.get(ref.name, {})
				if not frame.is_empty():
					var corners := [Vector3.ZERO, (frame.x as Vector3).abs() * size, ((frame.x as Vector3).abs() + (frame.y as Vector3).abs()) * size, (frame.y as Vector3).abs() * size, Vector3.ZERO]
					_polyline(overlay, PackedVector3Array(corners), color, width)
		"construct":
			var c: Dictionary = workspace.result.get("construction", {}).get(ref.feature, {})
			_draw_construction(overlay, c, size, color, width)
		"vertex":
			var at: Vector2 = viewport.project(ref.get("point", Vector3.ZERO))
			if at.is_finite():
				overlay.draw_circle(at, 5.0, color)


func _draw_construction(overlay: Control, c: Dictionary, size: float, color: Color, width: float) -> void:
	match str(c.get("type", "")):
		"plane":
			var x: Vector3 = c.x
			var y: Vector3 = (c.normal as Vector3).cross(x)
			var o: Vector3 = c.origin
			var h := size * 0.5
			_polyline(overlay, PackedVector3Array([o - x * h - y * h, o + x * h - y * h, o + x * h + y * h, o - x * h + y * h, o - x * h - y * h]), color, width)
		"axis":
			var d: Vector3 = c.direction
			_polyline(overlay, PackedVector3Array([(c.origin as Vector3) - d * size, (c.origin as Vector3) + d * size]), color, width)
		"point":
			var at: Vector2 = viewport.project(c.position)
			if at.is_finite():
				overlay.draw_polyline(PackedVector2Array([at + Vector2(0, -5), at + Vector2(5, 0), at + Vector2(0, 5), at + Vector2(-5, 0), at + Vector2(0, -5)]), color, width)


func _polyline(overlay: Control, line: PackedVector3Array, color: Color, width: float) -> void:
	for i in range(1, line.size()):
		var a: Vector2 = viewport.project(line[i - 1])
		var b: Vector2 = viewport.project(line[i])
		if a.is_finite() and b.is_finite():
			overlay.draw_line(a, b, color, width, true)


# --- Hit tests -------------------------------------------------------------------------------

func _nearest_sketch_point(screen: Vector2) -> Dictionary:
	var best := {}
	var best_px := RADIUS_PX
	for sketch_id in _sketches:
		var entry: Dictionary = _sketches[sketch_id]
		if not entry.visible:
			continue
		for id in entry.points:
			var at: Vector2 = viewport.project(entry.points[id])
			if at.is_finite() and at.distance_to(screen) < best_px:
				best_px = at.distance_to(screen)
				best = {"kind": "sketch_point", "sketch": sketch_id, "entity": id, "key": "sp:%s:%d" % [sketch_id, id]}
	return best


func _nearest_sketch_curve(screen: Vector2, lines_only: bool) -> Dictionary:
	var best := {}
	var best_px := RADIUS_PX
	for sketch_id in _sketches:
		var entry: Dictionary = _sketches[sketch_id]
		if not entry.visible:
			continue
		var s = entry.sketch
		for id in entry.curves:
			if lines_only and s.entity(id).get("type", "") != "line":
				continue
			var line: PackedVector3Array = entry.curves[id]
			for i in range(1, line.size()):
				var a: Vector2 = viewport.project(line[i - 1])
				var b: Vector2 = viewport.project(line[i])
				if not a.is_finite() or not b.is_finite():
					continue
				var d := screen.distance_to(Geometry2D.get_closest_point_to_segment(screen, a, b))
				if d < best_px:
					best_px = d
					best = {"kind": "sketch_curve", "sketch": sketch_id, "entity": id, "key": "sc:%s:%d" % [sketch_id, id]}
	return best


## Construction points and axes, then the origin point and axes (when shown).
func _nearest_construction(screen: Vector2, kinds: Array) -> Dictionary:
	var size: float = viewport.origin_size()
	var best := {}
	var best_px := RADIUS_PX
	var candidates := []
	for id in workspace.result.get("construction", {}):
		var c: Dictionary = workspace.result.construction[id]
		if c.type == "point" and kinds.has("point") or c.type == "axis" and kinds.has("axis"):
			candidates.append([{"kind": "construct", "feature": id, "key": "c:" + id}, c])
	if kinds.has("axis"):
		for key in ORIGIN_AXES:
			candidates.append([{"kind": "origin", "name": key, "key": "o:" + key}, {"type": "axis", "origin": Vector3.ZERO, "direction": ORIGIN_AXES[key]}])
	if kinds.has("point"):
		candidates.append([{"kind": "origin", "name": "o", "key": "o:o"}, {"type": "point", "position": Vector3.ZERO}])
	for candidate in candidates:
		var c: Dictionary = candidate[1]
		var d := INF
		if c.type == "point":
			var at: Vector2 = viewport.project(c.position)
			d = at.distance_to(screen) if at.is_finite() else INF
		else:
			var reach := size if candidate[0].kind == "origin" else size
			var a: Vector2 = viewport.project((c.origin as Vector3) - (c.direction as Vector3) * (0.0 if candidate[0].kind == "origin" else reach))
			var b: Vector2 = viewport.project((c.origin as Vector3) + (c.direction as Vector3) * reach)
			if a.is_finite() and b.is_finite():
				d = screen.distance_to(Geometry2D.get_closest_point_to_segment(screen, a, b))
		if d < best_px:
			best_px = d
			best = candidate[0]
	return best


func _profile_at(ray: Array, face_distance: float) -> Dictionary:
	var best := {}
	var best_t := face_distance + 1e-6
	var best_area := INF
	for entry in _profile_entries:
		var plane: Transform3D = _sketches[entry.sketch].state.plane
		var normal := plane.basis.z
		var denom: float = (ray[1] as Vector3).dot(normal)
		if absf(denom) < 1e-9:
			continue
		var t: float = (plane.origin - (ray[0] as Vector3)).dot(normal) / denom
		if t < 0.0 or t > best_t + 1e-9:
			continue
		var hit: Vector3 = (ray[0] as Vector3) + (ray[1] as Vector3) * t
		var local := plane.affine_inverse() * hit
		var p := Vector2(local.x, local.y)
		var loops: Array = entry.region.loops
		if loops.is_empty() or not Geometry2D.is_point_in_polygon(p, loops[0]):
			continue
		var in_hole := false
		for k in range(1, loops.size()):
			in_hole = in_hole or Geometry2D.is_point_in_polygon(p, loops[k])
		if in_hole:
			continue
		var area := float(entry.region.area)
		if t < best_t - 1e-9 or area < best_area:
			best_t = minf(best_t, t)
			best_area = area
			best = {"kind": "profile", "sketch": entry.sketch, "point": _inside_point(entry.region), "key": entry.key}
	return best


## Faces, edges, vertices and bodies from the view's own picking, filtered by kind.
func _body_pick(screen: Vector2, kinds: Array) -> Dictionary:
	var filters := {
		"vertex": kinds.has("vertex") or kinds.has("point"),
		"edge": kinds.has("edge") or kinds.has("path") or kinds.has("axis") or kinds.has("point"),
		"face": kinds.has("face") or kinds.has("plane") or kinds.has("axis") or kinds.has("feature") or kinds.has("profile"),
		"body": kinds.has("body") or kinds.has("component"),
	}
	var saved: Dictionary = viewport.filters
	var saved_priority: String = viewport.priority
	viewport.filters = filters
	viewport.priority = "body" if (filters.body and not filters.face and not filters.edge) else "default"
	var hit: Dictionary = viewport.pick_at(screen)
	viewport.filters = saved
	viewport.priority = saved_priority
	if hit.is_empty():
		return {}
	_hit_point = hit.get("point")
	var result: Dictionary = workspace.result
	if hit.kind == "face" and not kinds.has("face") and kinds.has("body") or kinds.has("component") and not kinds.has("face"):
		hit = {"kind": "body", "body": hit.body, "index": -1, "point": hit.get("point", Vector3.ZERO)}
	var ref := REFERENCES.from_pick(hit, result)
	if ref.is_empty():
		return {}
	var shape: RefCounted = result.bodies[hit.body].shape
	match str(ref.kind):
		"face":
			var info: Dictionary = shape.face_info(int(hit.index))
			if kinds.has("feature") and not kinds.has("face"):
				var source := str(ref.name).get_slice(":", 0)
				if workspace.doc.find_feature(source) == null:
					return {}
				return {"kind": "feature", "feature": source, "key": "f:" + source}
			if not kinds.has("face") and not kinds.has("profile"):
				if kinds.has("plane") and not info.get("planar", false) and not (kinds.has("axis") and info.has("axis")):
					return {}
				if not kinds.has("plane") and not info.has("axis"):
					return {}
			if kinds.has("profile") and not kinds.has("face") and not info.get("planar", false):
				return {}
		"edge":
			var info: Dictionary = shape.edge_info(int(hit.index))
			if not kinds.has("edge") and not kinds.has("path"):
				if kinds.has("axis") and info.get("type", "") != "line" and info.get("type", "") != "circle":
					return {}
				if not kinds.has("axis") and not info.has("center"):
					return {}
		"body":
			if kinds.has("component") and not kinds.has("body"):
				var component: String = workspace.doc.body_component(hit.body)
				if component == "":
					return {}
				return {"kind": "component", "component": component, "key": "comp:" + component}
	ref["key"] = "%s:%s:%s" % [ref.kind, ref.get("body", ""), ref.get("name", hit.get("index", -1))]
	return ref


## Origin plane squares and construction planes under the cursor (nearest first).
func _plane_at(ray: Array) -> Dictionary:
	var size: float = viewport.origin_size()
	var best := {}
	var best_t := INF
	var candidates := []
	for key in SKETCH.ORIGIN_PLANES:
		var frame: Dictionary = SKETCH.ORIGIN_PLANES[key]
		candidates.append([{"kind": "origin", "name": key, "key": "o:" + key}, Vector3.ZERO, (frame.x as Vector3).cross(frame.y), (frame.x as Vector3).abs(), (frame.y as Vector3).abs(), true])
	for id in workspace.result.get("construction", {}):
		var c: Dictionary = workspace.result.construction[id]
		if c.type == "plane":
			candidates.append([{"kind": "construct", "feature": id, "key": "c:" + id}, c.origin, c.normal, c.x, (c.normal as Vector3).cross(c.x), false])
	for candidate in candidates:
		var n: Vector3 = candidate[2]
		var denom: float = (ray[1] as Vector3).dot(n)
		if absf(denom) < 1e-9:
			continue
		var t: float = ((candidate[1] as Vector3) - (ray[0] as Vector3)).dot(n) / denom
		if t < 0.0 or t >= best_t:
			continue
		var rel: Vector3 = (ray[0] as Vector3) + (ray[1] as Vector3) * t - (candidate[1] as Vector3)
		var u: float = rel.dot(candidate[3])
		var v: float = rel.dot(candidate[4])
		# Origin squares span 0..size; construction planes are centered on their origin.
		var inside: bool = (u >= 0.0 and u <= size and v >= 0.0 and v <= size) if candidate[5] else (absf(u) <= size * 0.5 and absf(v) <= size * 0.5)
		if inside:
			best_t = t
			best = candidate[0]
	return best


# --- Helpers ---------------------------------------------------------------------------------

func _picked_keys() -> Dictionary:
	var keys := {}
	if picked_provider.is_valid():
		for ref in picked_provider.call():
			if ref is Dictionary and ref.get("kind", "") == "profile":
				# The smallest region around the point, not in one of its holes (as regen finds it).
				var p: Vector2 = ref.point
				var best_key := ""
				var best_area := INF
				for entry in _profile_entries_for(ref.sketch):
					var loops: Array = entry.region.loops
					if loops.is_empty() or not Geometry2D.is_point_in_polygon(p, loops[0]):
						continue
					var in_hole := false
					for k in range(1, loops.size()):
						in_hole = in_hole or Geometry2D.is_point_in_polygon(p, loops[k])
					if not in_hole and float(entry.region.area) < best_area:
						best_area = float(entry.region.area)
						best_key = entry.key
				if best_key != "":
					keys[best_key] = true
	return keys


func _profile_entries_for(sketch_id: String) -> Array:
	return _profile_entries.filter(func(entry: Dictionary) -> bool: return entry.sketch == sketch_id)


static func _profile_key(sketch_id: String, region: Dictionary) -> String:
	var loops: Array = region.loops
	var first: Vector2 = (loops[0] as PackedVector2Array)[0] if not loops.is_empty() and not (loops[0] as PackedVector2Array).is_empty() else Vector2.ZERO
	return "p:%s:%.6f:%.6f:%.9f" % [sketch_id, first.x, first.y, float(region.area)]


## A point well inside a region (so it still finds the region after small edits): the middle
## of the longest chord through the region's center height, avoiding holes.
static func _inside_point(region: Dictionary) -> Vector2:
	var loops: Array = region.loops
	var outer: PackedVector2Array = loops[0]
	var box := Rect2(outer[0], Vector2.ZERO)
	for p in outer:
		box = box.expand(p)
	for fraction in [0.5, 0.35, 0.65, 0.2, 0.8]:
		var y: float = box.position.y + box.size.y * fraction
		var hits: Array[float] = []
		for loop in loops:
			var pts: PackedVector2Array = loop
			for i in pts.size():
				var a := pts[i]
				var b := pts[(i + 1) % pts.size()]
				if (a.y <= y and b.y > y) or (b.y <= y and a.y > y):
					hits.append(a.x + (y - a.y) / (b.y - a.y) * (b.x - a.x))
		hits.sort()
		var best_span := 0.0
		var best := Vector2.INF
		for i in range(0, hits.size() - 1, 2):
			if hits[i + 1] - hits[i] > best_span:
				best_span = hits[i + 1] - hits[i]
				best = Vector2((hits[i] + hits[i + 1]) * 0.5, y)
		if best.is_finite():
			return best
	return box.get_center()


static func _flat_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.no_depth_test = false
	return material
