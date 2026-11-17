@tool
extends RefCounted
## The assembly in the Forge view (spec C7.1 and 6.2): poses the bodies from a solve and draws the
## assembly's glyphs on the view's glyph layer (ui/forge_viewport.gd glyph_layer(), a Control
## named AssemblyGlyphs over the 3D view).
##
## apply() hands a solve output (core/assembly/solver.gd solve(), C3.1) to the view, which moves
## each body's holder to its pose. refresh() builds the glyph records from the document's assembly
## and the same solve; draw() draws them, screen-constant, on top of the bodies:
##   "joint"     a rounded hexagon badge (BADGE_PX) at the joint frame, the type's pictogram inside
##               and a state dot at its upper right (amber loop, red unresolved and error, grey
##               waiting); a suppressed joint at SUPPRESSED_ALPHA. None for visible: false.
##   "axis"      the joint Z, AXIS_SHARE x the moving unit's box diagonal (at least MIN_AXIS_PX on
##               screen), an open arrowhead; slides get one at both ends.
##   "sector"    a revolute's limits: a filled sector from min to max about Z (LIMIT_SHARE x the
##               diagonal), a tick at rest, a needle at the value; an open end fades out.
##   "bar"       a slide's limits along its axis: min to max, a rest tick and a value marker.
##   "origin"    a Joint Origin's triad in the axis colours (ORIGIN_SHARE x the diagonal, at least
##               MIN_AXIS_PX) with a small open circle.
##   "ground"    under a grounded unit while its browser item is hovered or selected
##               (set_ground_shown): a base line with three slanted ticks under a small block.
##   "candidate" snap candidates of the face under the cursor (set_candidates): CANDIDATE_PX marks
##               by kind, the hovered one CANDIDATE_HOVER_PX in the selection colour.
##   "contact"   a contact stop's point (flash_contact): an 8 px dot for CONTACT_SECONDS.
## Every record holds its world "position" (and what else it draws with) and its colour, so tests
## read what is drawn without a screen. While the view shows modelled positions (set_modelled) no
## glyph is drawn: they belong to the posed view.

const XFORM := preload("res://addons/holo_forge/core/assembly/xform64.gd")
const DATA := preload("res://addons/holo_forge/core/assembly/assembly_data.gd")
const FORGE_THEME := preload("res://addons/holo_forge/ui/forge_theme.gd")
const TOOLBAR := preload("res://addons/holo_forge/ui/toolbar.gd")
const MANIPULATOR := preload("res://addons/holo_forge/core/manipulator_math.gd")

const BADGE_PX := 22.0
const PICTOGRAM_PX := 14.0
const STATE_DOT_PX := 7.0
const SUPPRESSED_ALPHA := 0.4
const CANDIDATE_PX := 6.0
const CANDIDATE_HOVER_PX := 10.0
## A joint badge or a candidate mark is found within this many pixels of the cursor.
const PICK_PX := 8.0
const AXIS_SHARE := 0.15
const LIMIT_SHARE := 0.12
const ORIGIN_SHARE := 0.08
const MIN_AXIS_PX := 24.0
const CONTACT_DOT_PX := 8.0
const CONTACT_SECONDS := 1.0
## The diagonal used when a unit has no body to measure (meters).
const DEFAULT_DIAGONAL := 0.05
## The mark drawn for each snap kind (spec 6.2).
const CANDIDATE_SHAPES := {
	"face_center": "dot", "sphere_center": "dot", "group_center": "dot", "edge_mid": "diamond", "vertex": "square",
	"circle_center": "ring", "origin": "ring", "axis_mid": "plus", "axis_start": "plus", "axis_end": "plus", "group_axis_mid": "plus",
}
## Joint states that show a dot on the badge, and the palette colour of each.
const STATE_COLORS := {"loop": "assembly_warning", "unresolved": "assembly_unresolved", "error": "assembly_unresolved", "waiting": "assembly_ground"}
## The type pictograms (spec 6.3; drawn by team T) and the stand-in until they exist.
const ICON_DIR := "res://addons/holo_forge/icons/assemble/"
const FALLBACK_ICON := "res://addons/holo_forge/icons/tools/joint.svg"

## The palette glyphs are drawn in (ui/forge_theme.gd).
var palette := FORGE_THEME.palette("dark")
## True while the view shows modelled positions: no glyph is drawn.
var modelled := false
## The joint drawn in the selection colour ("" for none).
var selected_joint := ""
## The unit whose ground glyph shows ("" for none).
var ground_shown := ""

var _glyphs: Array[Dictionary] = []
var _candidates: Array[Dictionary] = []
var _contact: Dictionary = {}
## What refresh() last built from, to build again on a theme change or a selection.
var _doc: Resource
var _solve := {}


## Hands the view the poses of a solve output (C3.1): every body holder moves to its pose.
func apply(viewport: Control, solve_out: Dictionary) -> void:
	viewport.set_body_poses(solve_out)


## Makes this display draw the glyphs of viewport on its glyph layer.
func attach(viewport: Control) -> void:
	viewport.set_glyph_drawer(func(canvas: Control) -> void: draw(canvas, viewport))


## Shows modelled positions (on: every holder at identity, no glyphs) or the poses again.
func set_modelled(viewport: Control, on: bool) -> void:
	modelled = on
	viewport.set_modelled_view(on)
	viewport.glyph_layer().queue_redraw()


## Takes a palette (spec 6.1 tokens) and builds the glyphs again in it.
func apply_theme(viewport: Control, p_palette: Dictionary) -> void:
	palette = p_palette.duplicate(true)
	if _doc != null:
		refresh(viewport, _doc, _solve, palette)


## Draws the joint at id in the selection colour ("" for none).
func set_selected_joint(viewport: Control, joint_id: String) -> void:
	selected_joint = joint_id
	if _doc != null:
		refresh(viewport, _doc, _solve)


## Shows the ground glyph under a grounded unit ("" hides it).
func set_ground_shown(viewport: Control, unit_id: String) -> void:
	ground_shown = unit_id
	if _doc != null:
		refresh(viewport, _doc, _solve)


## Builds the glyph records of doc's assembly at the poses of solve_out (C3.1) and redraws.
## p_palette: the palette to draw in ({} keeps the one in use).
func refresh(viewport: Control, doc: Resource, solve_out: Dictionary, p_palette := {}) -> void:
	if not p_palette.is_empty():
		palette = p_palette.duplicate(true)
	_doc = doc
	_solve = solve_out
	_glyphs.clear()
	if doc != null:
		var stored: Variant = doc.get("assembly")
		var assembly: Dictionary = DATA.normalized(stored if stored is Dictionary else {})
		var diagonals := _unit_diagonals(viewport, doc)
		var solved: Dictionary = solve_out.get("joints", {})
		for joint in assembly.joints:
			if joint is Dictionary:
				_joint_glyphs(joint, solved.get(str(joint.get("id", "")), {}), doc, diagonals)
		for origin in assembly.origins:
			if origin is Dictionary:
				_origin_glyph(origin, doc, solve_out, diagonals)
		if ground_shown != "" and DATA.is_grounded(assembly, ground_shown):
			_ground_glyph(viewport, doc, ground_shown)
	viewport.glyph_layer().queue_redraw()


## Every glyph record (joints and their axes and limits, origins, the ground, candidate marks, a
## contact dot), for tests and drawing.
func glyphs() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	out.append_array(_glyphs)
	out.append_array(_candidates)
	if not _contact.is_empty():
		out.append(_contact)
	return out


## Shows snap candidates (spec C2.3, 6.2) of the face under the cursor: [{"kind", "body", "at"
## (the point in the body's modelled space: Vector3, or 3 numbers)}] or {"kind", "world":
## Vector3}; hovered: the index drawn bigger in the selection colour (-1 none). [] clears them.
func set_candidates(viewport: Control, candidates: Array, hovered := -1) -> void:
	_candidates.clear()
	for i in candidates.size():
		var candidate: Dictionary = candidates[i]
		var position: Vector3
		if candidate.get("world") is Vector3:
			position = candidate.world
		else:
			position = viewport.world_point(str(candidate.get("body", "")), _vector(candidate.get("at", Vector3.ZERO)))
		var hot := i == hovered
		_candidates.append({
			"kind": "candidate", "index": i, "snap": str(candidate.get("kind", "")), "shape": CANDIDATE_SHAPES.get(str(candidate.get("kind", "")), "dot"),
			"position": position, "px": CANDIDATE_HOVER_PX if hot else CANDIDATE_PX,
			"color": palette.assembly_joint_selected if hot else palette.assembly_joint,
		})
	viewport.glyph_layer().queue_redraw()


## The index of the candidate mark nearest screen_position within PICK_PX (-1 for none).
func candidate_at(viewport: Control, screen_position: Vector2) -> int:
	var best := -1
	var best_px := PICK_PX
	for mark in _candidates:
		var at: Vector2 = viewport.project(mark.position)
		if at.is_finite() and at.distance_to(screen_position) <= best_px:
			best_px = at.distance_to(screen_position)
			best = int(mark.index)
	return best


## The joint whose badge is within PICK_PX of screen_position ("" for none): badges win over the
## bodies behind them (spec 3.11).
func joint_at(viewport: Control, screen_position: Vector2) -> String:
	if modelled:
		return ""
	var best := ""
	var best_px := PICK_PX + BADGE_PX * 0.5
	for glyph in _glyphs:
		if str(glyph.kind) != "joint":
			continue
		var at: Vector2 = viewport.project(glyph.position)
		if at.is_finite() and at.distance_to(screen_position) <= best_px:
			best_px = at.distance_to(screen_position)
			best = str(glyph.joint)
	return best


## Marks a contact stop (spec 6.2): an 8 px dot at the world point for CONTACT_SECONDS.
func flash_contact(viewport: Control, point: Vector3) -> void:
	_contact = {"kind": "contact", "position": point, "color": palette.assembly_contact, "until": Time.get_ticks_msec() + int(CONTACT_SECONDS * 1000.0)}
	viewport.glyph_layer().queue_redraw()


## Shows where a unit's bodies start during a Joint or Drive preview: [body id] at their poses in
## solve_out (spec 6.2 ghost). [] removes the ghosts.
func show_ghost(viewport: Control, body_ids: Array, solve_out: Dictionary) -> void:
	var entries := []
	var poses: Dictionary = solve_out.get("body_poses", {})
	for body_id in body_ids:
		var pose: Variant = poses.get(body_id)
		entries.append({"body": body_id, "transform": XFORM.to_transform(pose) if pose is PackedFloat64Array and (pose as PackedFloat64Array).size() == 12 else Transform3D.IDENTITY})
	viewport.set_ghost_bodies(entries)


# --- Building ----------------------------------------------------------------------------------

func _joint_glyphs(joint: Dictionary, solved: Dictionary, doc: Resource, diagonals: Dictionary) -> void:
	if not bool(joint.get("visible", true)):
		return
	var id := str(joint.get("id", ""))
	var type := str(joint.get("type", DATA.DEFAULT_TYPE))
	var state := str(solved.get("state", ""))
	var suppressed := bool(joint.get("suppressed", false)) or state == "suppressed"
	var alpha := SUPPRESSED_ALPHA if suppressed else 1.0
	var world: Variant = solved.get("world")
	var frame := XFORM.to_transform(world) if world is PackedFloat64Array and (world as PackedFloat64Array).size() == 12 else Transform3D.IDENTITY
	var color: Color = palette.assembly_joint_selected if id == selected_joint else palette.assembly_joint
	var state_color: Variant = palette.get(STATE_COLORS[state]) if STATE_COLORS.has(state) else null
	_glyphs.append({
		"kind": "joint", "joint": id, "type": type, "state": state, "position": frame.origin, "frame": frame,
		"alpha": alpha, "color": color, "state_color": state_color, "icon": _icon_path(type),
	})
	var moving := _unit_of(doc, str((joint.get("a", {}) as Dictionary).get("component", "")))
	var diagonal: float = diagonals.get(moving, DEFAULT_DIAGONAL)
	var z := frame.basis.z.normalized()
	var names := DATA.dof_names(type)
	var slides := names.filter(func(n: String) -> bool: return not DATA.is_rotation(n))
	_glyphs.append({
		"kind": "axis", "joint": id, "position": frame.origin, "direction": z, "length": AXIS_SHARE * diagonal,
		"two_way": not slides.is_empty() and type != "planar", "alpha": alpha, "color": color,
	})
	var dofs: Array = joint.get("dofs", [])
	var values: PackedFloat64Array = solved.get("values", PackedFloat64Array())
	for i in mini(names.size(), dofs.size()):
		var dof: Dictionary = dofs[i] if dofs[i] is Dictionary else DATA.DOF_DEFAULT
		var limited_min := bool(dof.get("limited_min", false))
		var limited_max := bool(dof.get("limited_max", false))
		if not (limited_min or limited_max):
			continue
		var value := values[i] if i < values.size() else float(dof.get("value", 0.0))
		var limits := {
			"joint": id, "dof": i, "position": frame.origin, "frame": frame, "min": float(dof.get("min", 0.0)), "max": float(dof.get("max", 0.0)),
			"open_min": not limited_min, "open_max": not limited_max, "rest": float(dof.get("rest", 0.0)), "value": value,
			"alpha": alpha, "color": palette.assembly_limit, "line_color": color,
		}
		var name := str(names[i])
		if name == "rot_z" and type != "ball":
			limits["kind"] = "sector"
			limits["radius"] = LIMIT_SHARE * diagonal
		elif not DATA.is_rotation(name):
			limits["kind"] = "bar"
			var axis := name.trim_prefix("slide_") if name != "slide" else str(joint.get("slide_axis", "z"))
			limits["direction"] = ({"x": frame.basis.x, "y": frame.basis.y, "z": frame.basis.z}.get(axis, frame.basis.z) as Vector3).normalized()
		else:
			continue
		_glyphs.append(limits)


func _origin_glyph(origin: Dictionary, doc: Resource, solve_out: Dictionary, diagonals: Dictionary) -> void:
	if not bool(origin.get("visible", true)):
		return
	var component := str(origin.get("component", ""))
	var snap: Variant = origin.get("snap", {})
	var stored: Variant = (snap as Dictionary).get("frame") if snap is Dictionary else null
	var frame64 := PackedFloat64Array(stored) if stored is PackedFloat64Array and (stored as PackedFloat64Array).size() == 12 else XFORM.identity()
	var offset: Array = origin.get("offset", [0.0, 0.0, 0.0])
	var local := XFORM.compose(XFORM.translation(float(offset[0]), float(offset[1]), float(offset[2])), XFORM.rot_z(float(origin.get("angle", 0.0))))
	if bool(origin.get("flip", false)):
		local = XFORM.compose(local, XFORM.rot_x(PI))
	var pose: Variant = (solve_out.get("poses", {}) as Dictionary).get(component)
	var placed := pose if pose is PackedFloat64Array and (pose as PackedFloat64Array).size() == 12 else XFORM.identity()
	var frame := XFORM.to_transform(XFORM.compose(XFORM.compose(placed, frame64), local))
	_glyphs.append({
		"kind": "origin", "origin": str(origin.get("id", "")), "position": frame.origin, "frame": frame,
		"length": ORIGIN_SHARE * float(diagonals.get(_unit_of(doc, component), DEFAULT_DIAGONAL)), "alpha": 1.0,
	})


func _ground_glyph(viewport: Control, doc: Resource, unit: String) -> void:
	var box := _unit_box(viewport, doc, unit)
	if box.size == Vector3.ZERO and box.position == Vector3.ZERO:
		return
	_glyphs.append({"kind": "ground", "unit": unit, "position": Vector3(box.get_center().x, box.position.y, box.get_center().z), "color": palette.assembly_ground, "alpha": 1.0})


## The top-level unit a component belongs to ("" for the ground).
static func _unit_of(doc: Resource, component: String) -> String:
	var id := component
	for i in 64:
		var parent := str((doc.components.get(id, {}) as Dictionary).get("parent", ""))
		if parent == "" or not doc.components.has(parent):
			return id if doc.components.has(id) else ""
		id = parent
	return id


## Each unit's box diagonal where its bodies show (meters).
func _unit_diagonals(viewport: Control, doc: Resource) -> Dictionary:
	var out := {}
	for component in doc.components:
		var unit := _unit_of(doc, str(component))
		if unit == str(component):
			var box := _unit_box(viewport, doc, unit)
			var diagonal := box.size.length()
			out[unit] = diagonal if diagonal > 1e-9 else DEFAULT_DIAGONAL
	return out


## The box around a unit's shown bodies (an empty AABB when none shows).
func _unit_box(viewport: Control, doc: Resource, unit: String) -> AABB:
	var box := AABB()
	var first := true
	for body in viewport.pickable_bodies():
		var body_id := str(body.id)
		if _unit_of(doc, str(doc.body_component(body_id))) != unit:
			continue
		var shown: AABB = viewport.body_pose(body_id) * (body.aabb as AABB)
		box = shown if first else box.merge(shown)
		first = false
	return box


func _icon_path(type: String) -> String:
	var path := ICON_DIR + "joint_%s.svg" % type
	return path if FileAccess.file_exists(path) else FALLBACK_ICON


static func _vector(value: Variant) -> Vector3:
	if value is Vector3:
		return value
	if (value is Array or value is PackedFloat64Array or value is PackedFloat32Array) and value.size() >= 3:
		return Vector3(float(value[0]), float(value[1]), float(value[2]))
	return Vector3.ZERO


# --- Drawing -----------------------------------------------------------------------------------

## Draws every glyph on canvas (the view's glyph layer), projected through viewport.
func draw(canvas: Control, viewport: Control) -> void:
	if modelled:
		return
	for glyph in _glyphs:
		match str(glyph.kind):
			"sector":
				_draw_sector(canvas, viewport, glyph)
			"bar":
				_draw_bar(canvas, viewport, glyph)
	for glyph in _glyphs:
		match str(glyph.kind):
			"axis":
				_draw_axis(canvas, viewport, glyph)
			"origin":
				_draw_origin(canvas, viewport, glyph)
			"ground":
				_draw_ground(canvas, viewport, glyph)
	for glyph in _glyphs:
		if str(glyph.kind) == "joint":
			_draw_badge(canvas, viewport, glyph)
	for mark in _candidates:
		_draw_candidate(canvas, viewport, mark)
	if not _contact.is_empty():
		if Time.get_ticks_msec() > int(_contact.until):
			_contact = {}
		else:
			var at: Vector2 = viewport.project(_contact.position)
			if at.is_finite():
				canvas.draw_circle(at, CONTACT_DOT_PX * 0.5, _contact.color)
			canvas.queue_redraw.call_deferred()


func _draw_badge(canvas: Control, viewport: Control, glyph: Dictionary) -> void:
	var at: Vector2 = viewport.project(glyph.position)
	if not at.is_finite():
		return
	var alpha := float(glyph.alpha)
	var fill: Color = (palette.panel_style as Dictionary).get("panel", Color(0.13, 0.14, 0.17))
	var outline: Color = glyph.color
	var hexagon := PackedVector2Array()
	var radius := BADGE_PX * 0.5
	for i in 6:
		var angle := PI / 6.0 + TAU * i / 6.0
		hexagon.append(at + Vector2(cos(angle), sin(angle)) * radius)
	canvas.draw_colored_polygon(hexagon, Color(fill, fill.a * alpha))
	var closed := hexagon.duplicate()
	closed.append(hexagon[0])
	canvas.draw_polyline(closed, Color(outline, outline.a * alpha), 1.6, true)
	var icon: Texture2D = TOOLBAR.file_icon(str(glyph.icon), PICTOGRAM_PX, palette.get("toolbar_ink", Color("#dfe3ea")))
	if icon != null:
		canvas.draw_texture_rect(icon, Rect2(at - Vector2.ONE * PICTOGRAM_PX * 0.5, Vector2.ONE * PICTOGRAM_PX), false, Color(1, 1, 1, alpha))
	if glyph.state_color is Color:
		var dot: Color = glyph.state_color
		canvas.draw_circle(at + Vector2(radius * 0.75, -radius * 0.75), STATE_DOT_PX * 0.5, Color(dot, dot.a * alpha))


## The world length that shows as at least min_px at point.
static func _at_least(viewport: Control, point: Vector3, length: float, min_px: float) -> float:
	var per_m: float = viewport.pixels_per_meter_at(point)
	return maxf(length, min_px / maxf(per_m, 1e-9))


func _draw_axis(canvas: Control, viewport: Control, glyph: Dictionary) -> void:
	var origin: Vector3 = glyph.position
	var length := _at_least(viewport, origin, float(glyph.length), MIN_AXIS_PX)
	var direction: Vector3 = glyph.direction
	var tail: Vector3 = origin - direction * length if bool(glyph.two_way) else origin
	var a: Vector2 = viewport.project(tail)
	var b: Vector2 = viewport.project(origin + direction * length)
	if not (a.is_finite() and b.is_finite()) or a.is_equal_approx(b):
		return
	var color: Color = glyph.color
	color.a *= float(glyph.alpha)
	canvas.draw_line(a, b, color, 1.6, true)
	_open_head(canvas, a, b, color)
	if bool(glyph.two_way):
		_open_head(canvas, b, a, color)


static func _open_head(canvas: Control, from: Vector2, to: Vector2, color: Color) -> void:
	var dir := (to - from).normalized()
	var side := Vector2(-dir.y, dir.x)
	canvas.draw_line(to, to - dir * 8.0 + side * 5.0, color, 1.6, true)
	canvas.draw_line(to, to - dir * 8.0 - side * 5.0, color, 1.6, true)


func _draw_sector(canvas: Control, viewport: Control, glyph: Dictionary) -> void:
	var frame: Transform3D = glyph.frame
	var center: Vector3 = frame.origin
	var radius := _at_least(viewport, center, float(glyph.radius), MIN_AXIS_PX)
	var x := frame.basis.x.normalized()
	var y := frame.basis.y.normalized()
	var on_circle := func(angle: float) -> Vector3: return center + (x * cos(angle) + y * sin(angle)) * radius
	var low := float(glyph.min) if not bool(glyph.open_min) else float(glyph.value) - PI * 0.5
	var high := float(glyph.max) if not bool(glyph.open_max) else float(glyph.value) + PI * 0.5
	# (A range over a full turn is drawn as one turn.)
	high = minf(high, low + TAU)
	var fill: Color = glyph.color
	fill.a *= float(glyph.alpha)
	var at_center: Vector2 = viewport.project(center)
	if not at_center.is_finite():
		return
	var steps := maxi(4, ceili((high - low) / (PI / 24.0)))
	for k in steps:
		var a0 := low + (high - low) * k / steps
		var a1 := low + (high - low) * (k + 1) / steps
		var p0: Vector2 = viewport.project(on_circle.call(a0))
		var p1: Vector2 = viewport.project(on_circle.call(a1))
		if not (p0.is_finite() and p1.is_finite()):
			continue
		# An open end fades out over its last quarter.
		var fade := 1.0
		var share := (float(k) + 0.5) / steps
		if bool(glyph.open_min) and share < 0.25:
			fade = share / 0.25
		if bool(glyph.open_max) and share > 0.75:
			fade = (1.0 - share) / 0.25
		canvas.draw_colored_polygon(PackedVector2Array([at_center, p0, p1]), Color(fill, fill.a * fade))
	var line: Color = glyph.line_color
	line.a *= float(glyph.alpha)
	var rest_in: Vector2 = viewport.project(center + (x * cos(float(glyph.rest)) + y * sin(float(glyph.rest))) * radius * 0.85)
	var rest_out: Vector2 = viewport.project(on_circle.call(float(glyph.rest)))
	if rest_in.is_finite() and rest_out.is_finite():
		canvas.draw_line(rest_in, rest_out, line, 1.6, true)
	var needle: Vector2 = viewport.project(on_circle.call(float(glyph.value)))
	if needle.is_finite():
		canvas.draw_line(at_center, needle, line, 1.6, true)


func _draw_bar(canvas: Control, viewport: Control, glyph: Dictionary) -> void:
	var center: Vector3 = glyph.position
	var direction: Vector3 = glyph.direction
	var reach := _at_least(viewport, center, 0.0, MIN_AXIS_PX * 3.0)
	var low := float(glyph.min) if not bool(glyph.open_min) else float(glyph.value) - reach
	var high := float(glyph.max) if not bool(glyph.open_max) else float(glyph.value) + reach
	var a: Vector2 = viewport.project(center + direction * low)
	var b: Vector2 = viewport.project(center + direction * high)
	if not (a.is_finite() and b.is_finite()) or a.is_equal_approx(b):
		return
	var fill: Color = glyph.color
	fill.a *= float(glyph.alpha)
	var side := (b - a).normalized().orthogonal()
	var start_color := Color(fill, 0.0) if bool(glyph.open_min) else fill
	var end_color := Color(fill, 0.0) if bool(glyph.open_max) else fill
	canvas.draw_polygon(PackedVector2Array([a + side * 3.0, b + side * 3.0, b - side * 3.0, a - side * 3.0]), PackedColorArray([start_color, end_color, end_color, start_color]))
	var line: Color = glyph.line_color
	line.a *= float(glyph.alpha)
	for mark in [[float(glyph.rest), 6.0], [float(glyph.value), 9.0]]:
		var at: Vector2 = viewport.project(center + direction * float(mark[0]))
		if at.is_finite():
			canvas.draw_line(at + side * float(mark[1]), at - side * float(mark[1]), line, 1.6, true)


func _draw_origin(canvas: Control, viewport: Control, glyph: Dictionary) -> void:
	var frame: Transform3D = glyph.frame
	var at: Vector2 = viewport.project(frame.origin)
	if not at.is_finite():
		return
	var length := _at_least(viewport, frame.origin, float(glyph.length), MIN_AXIS_PX)
	for axis in [[frame.basis.x, palette.axis_x], [frame.basis.y, palette.axis_y], [frame.basis.z, palette.axis_z]]:
		var tip: Vector2 = viewport.project(frame.origin + (axis[0] as Vector3).normalized() * length)
		if tip.is_finite():
			canvas.draw_line(at, tip, axis[1], 1.6, true)
	canvas.draw_arc(at, 4.0, 0.0, TAU, 16, palette.assembly_joint, 1.6, true)


func _draw_ground(canvas: Control, viewport: Control, glyph: Dictionary) -> void:
	var at: Vector2 = viewport.project(glyph.position)
	if not at.is_finite():
		return
	var color: Color = glyph.color
	var base_y := at.y + 10.0
	canvas.draw_rect(Rect2(at.x - 6.0, base_y - 9.0, 12.0, 7.0), color, false, 1.6)
	canvas.draw_line(Vector2(at.x - 12.0, base_y), Vector2(at.x + 12.0, base_y), color, 1.6, true)
	for k in 3:
		var x := at.x - 9.0 + 9.0 * k
		canvas.draw_line(Vector2(x, base_y), Vector2(x - 5.0, base_y + 6.0), color, 1.6, true)


func _draw_candidate(canvas: Control, viewport: Control, mark: Dictionary) -> void:
	var at: Vector2 = viewport.project(mark.position)
	if not at.is_finite():
		return
	var r := float(mark.px) * 0.5
	var color: Color = mark.color
	match str(mark.shape):
		"dot":
			canvas.draw_circle(at, r, color)
		"diamond":
			canvas.draw_colored_polygon(PackedVector2Array([at + Vector2(0, -r), at + Vector2(r, 0), at + Vector2(0, r), at + Vector2(-r, 0)]), color)
		"square":
			canvas.draw_rect(Rect2(at - Vector2.ONE * r, Vector2.ONE * r * 2.0), color, true)
		"ring":
			canvas.draw_arc(at, r, 0.0, TAU, 16, color, 1.6, true)
		"plus":
			canvas.draw_line(at - Vector2(r, 0), at + Vector2(r, 0), color, 1.6, true)
			canvas.draw_line(at - Vector2(0, r), at + Vector2(0, r), color, 1.6, true)
