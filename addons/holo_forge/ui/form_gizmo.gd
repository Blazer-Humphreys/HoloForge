@tool
extends RefCounted
## The Edit Form gizmo: a combined move / rotate / scale handle set drawn and hit-tested on the
## view's 2D overlay (not as view handles, whose drags rebuild the timeline on every motion).
##
## Sixteen handles about the pivot (the selection centroid) in a frame (basis): three axis arrows
## (70 px, 10 px heads) and three plane squares (10 px at 24, 24 px) translate; three rings (55 px,
## a 7 px knob toward the camera's up) rotate; three axis bars (12 px dashes at 45 px), three plane
## brackets (at 38, 38 px) and the centre circle (9 px) scale. Sizes are pixels at the pivot's
## depth. A drag gives one transform about the pivot, always measured from where the drag started
## (drag_xf), so long drags don't drift; the editor applies it to the drag-start cage positions.

const MANIPULATOR := preload("res://addons/holo_forge/core/manipulator_math.gd")
const FORM_OPS := preload("res://addons/holo_forge/core/form/form_ops.gd")

const ARROW_PX := 70.0
const ARROW_HEAD_PX := 10.0
const PLANE_AT_PX := 24.0
const PLANE_SIZE_PX := 10.0
const RING_PX := 55.0
const RING_KNOB_PX := 7.0
const RING_HIT_PX := 6.0
const SCALE_AT_PX := 45.0
const SCALE_DASH_PX := 12.0
const BRACKET_AT_PX := 38.0
const BRACKET_ARM_PX := 7.0
const CENTER_PX := 9.0
## Uniform scale: the factor is exp(pixels dragged right / (UNIFORM_PX * px)).
const UNIFORM_PX := 120.0
const HIT_PX := 6.0
## Editor scale: every *_PX size above is multiplied by it (a 2x editor gets a 2x gizmo).
var px := 1.0
## A rotation drag with Shift held snaps to this step (radians).
const ANGLE_SNAP := PI / 12.0

## The handles each transform mode shows.
const MODE_HANDLES := {
	"translate": ["move_x", "move_y", "move_z", "plane_xy", "plane_yz", "plane_zx"],
	"rotate": ["rot_x", "rot_y", "rot_z"],
	"scale": ["scale_x", "scale_y", "scale_z", "pscale_xy", "pscale_yz", "pscale_zx", "uniform"],
}
## Handles Alt (extrude / extend) works with.
const ALT_HANDLES := ["move_x", "move_y", "move_z", "plane_xy", "plane_yz", "plane_zx", "free", "pscale_xy", "pscale_yz", "pscale_zx"]
## Plane handles: the two axes they span (and so the axis whose colour they take: the third).
const PLANES := {"xy": [0, 1, 2], "yz": [1, 2, 0], "zx": [2, 0, 1]}

var pivot := Vector3.ZERO
var basis := Basis.IDENTITY
var mode := "multi"
var visible := false


## Every handle id the current mode shows, front-most hit first.
func handle_ids() -> Array:
	if MODE_HANDLES.has(mode):
		return MODE_HANDLES[mode]
	return MODE_HANDLES.translate + MODE_HANDLES.rotate + MODE_HANDLES.scale


func axis(i: int) -> Vector3:
	return basis[i].normalized()


## Meters per screen pixel at the pivot.
func world_per_px(viewport: Object) -> float:
	return 1.0 / maxf(float(viewport.pixels_per_meter_at(pivot)), 1e-12)


## The handle under a screen position ("" for none).
func hit(viewport: Object, screen: Vector2) -> String:
	if not visible:
		return ""
	var wpp := world_per_px(viewport)
	var shown := handle_ids()
	var c: Vector2 = viewport.project(pivot)
	if not c.is_finite():
		return ""
	if shown.has("uniform") and screen.distance_to(c) <= (CENTER_PX * px) + 2.0:
		return "uniform"
	for key in PLANES:
		var id: String = "plane_" + key
		if shown.has(id):
			var quad := _plane_quad(viewport, key, wpp)
			if quad.size() == 4 and Geometry2D.is_point_in_polygon(screen, quad):
				return id
	for key in PLANES:
		var id: String = "pscale_" + key
		if shown.has(id):
			for seg in _bracket(viewport, key, wpp):
				if _near_segment(screen, seg[0], seg[1], (HIT_PX * px)):
					return id
	for i in 3:
		var id: String = "scale_" + "xyz"[i]
		if shown.has(id):
			var dash := _scale_dash(viewport, i, wpp)
			if not dash.is_empty() and _near_segment(screen, dash[0], dash[1], (HIT_PX * px)):
				return id
	for i in 3:
		var id: String = "move_" + "xyz"[i]
		if shown.has(id):
			var tip := _arrow_tip(viewport, i, wpp)
			if tip.is_finite() and tip.distance_to(c) > 8.0 and _near_segment(screen, c.lerp(tip, 0.2), tip + (tip - c).normalized() * (ARROW_HEAD_PX * px), (HIT_PX * px) + 1.0):
				return id
	for i in 3:
		var id: String = "rot_" + "xyz"[i]
		if shown.has(id) and MANIPULATOR.ring_hit(screen, pivot, axis(i), (RING_PX * px), Callable(viewport, "project"), wpp, (RING_HIT_PX * px)):
			return id
	return ""


## Draws the gizmo; active is the dragged or hovered handle (drawn in handle / handle_fill).
func draw(overlay: Control, viewport: Object, colors: Dictionary, active := "") -> void:
	if not visible:
		return
	var c: Vector2 = viewport.project(pivot)
	if not c.is_finite():
		return
	var wpp := world_per_px(viewport)
	var shown := handle_ids()
	var axis_colors: Array = [colors.get("axis_x", Color.RED), colors.get("axis_y", Color.GREEN), colors.get("axis_z", Color.BLUE)]
	var lit: Color = colors.get("handle", Color(0.36, 0.72, 1.0))
	var fill: Color = colors.get("handle_fill", Color.WHITE)
	var tone := func(id: String, base: Color) -> Color:
		return lit if id == active else Color(base, base.a * 0.9)
	# Rings first (behind the rest).
	for i in 3:
		var id: String = "rot_" + "xyz"[i]
		if not shown.has(id):
			continue
		var color: Color = tone.call(id, axis_colors[i])
		var ring := MANIPULATOR.ring_points(pivot, axis(i), (RING_PX * px) * wpp, 64)
		# The ring's far half (behind the pivot from the camera) is drawn faint.
		var toward: Vector3 = (viewport.camera_position() - pivot).normalized()
		var front := PackedVector2Array()
		var back := PackedVector2Array()
		for k in ring.size() - 1:
			var a: Vector2 = viewport.project(ring[k])
			var b: Vector2 = viewport.project(ring[k + 1])
			if not (a.is_finite() and b.is_finite()):
				continue
			var mid: Vector3 = (ring[k] + ring[k + 1]) * 0.5 - pivot
			if mid.dot(toward) >= 0.0:
				front.append(a)
				front.append(b)
			else:
				back.append(a)
				back.append(b)
		var width := 2.5 if id == active else 1.6
		if back.size() > 1:
			overlay.draw_multiline(back, Color(color, color.a * 0.3), width * 0.75, true)
		if front.size() > 1:
			overlay.draw_multiline(front, color, width, true)
		var knob := _ring_knob(viewport, i, wpp)
		if knob.is_finite():
			overlay.draw_circle(knob, (RING_KNOB_PX * px) * 0.5 + 1.0, fill if id == active else color)
			overlay.draw_arc(knob, (RING_KNOB_PX * px) * 0.5 + 1.0, 0.0, TAU, 16, color, 1.5, true)
	# Axis arrows.
	for i in 3:
		var id: String = "move_" + "xyz"[i]
		if not shown.has(id):
			continue
		var tip := _arrow_tip(viewport, i, wpp)
		if not tip.is_finite() or tip.distance_to(c) < 8.0:
			continue
		var color: Color = tone.call(id, axis_colors[i])
		var dir := (tip - c).normalized()
		var side := Vector2(-dir.y, dir.x)
		overlay.draw_line(c + dir * ((CENTER_PX * px) + 3.0), tip, color, 3.0 if id == active else 2.2, true)
		overlay.draw_colored_polygon(PackedVector2Array([tip + dir * (ARROW_HEAD_PX * px), tip + side * (ARROW_HEAD_PX * px) * 0.5, tip - side * (ARROW_HEAD_PX * px) * 0.5]), color)
	# Plane squares.
	for key in PLANES:
		var id: String = "plane_" + key
		if not shown.has(id):
			continue
		var quad := _plane_quad(viewport, key, wpp)
		if quad.size() != 4:
			continue
		var color: Color = tone.call(id, axis_colors[PLANES[key][2]])
		overlay.draw_colored_polygon(quad, Color(fill, 0.85) if id == active else Color(color, 0.35))
		var closed := quad.duplicate()
		closed.append(quad[0])
		overlay.draw_polyline(closed, color, 1.5, true)
	# Axis scale bars.
	for i in 3:
		var id: String = "scale_" + "xyz"[i]
		if not shown.has(id):
			continue
		var dash := _scale_dash(viewport, i, wpp)
		if dash.is_empty():
			continue
		var color: Color = tone.call(id, axis_colors[i])
		overlay.draw_line(dash[0], dash[1], color, 4.0 if id == active else 3.0, true)
	# Plane scale brackets.
	for key in PLANES:
		var id: String = "pscale_" + key
		if not shown.has(id):
			continue
		var color: Color = tone.call(id, axis_colors[PLANES[key][2]])
		for seg in _bracket(viewport, key, wpp):
			overlay.draw_line(seg[0], seg[1], color, 2.5 if id == active else 1.8, true)
	# The centre circle.
	if shown.has("uniform"):
		var color: Color = tone.call("uniform", colors.get("form_point", Color.WHITE))
		overlay.draw_circle(c, (CENTER_PX * px), Color(fill, 0.9) if active == "uniform" else Color(color, 0.25))
		overlay.draw_arc(c, (CENTER_PX * px), 0.0, TAU, 24, lit if active == "uniform" else color, 1.8, true)
	else:
		overlay.draw_circle(c, 3.0, lit)


## The screen rectangle the gizmo covers (every handle the mode shows: arrows with their heads,
## rings with their knobs, squares, bars, brackets and the centre circle), grown by the hit
## margin; an empty Rect2 when it isn't shown or its pivot doesn't project. The command panel
## stays out of it (form_editor.panel_spot).
func screen_rect(viewport: Object) -> Rect2:
	if not visible:
		return Rect2()
	var c: Vector2 = viewport.project(pivot)
	if not c.is_finite():
		return Rect2()
	var wpp := world_per_px(viewport)
	var shown := handle_ids()
	var points := PackedVector2Array([c])
	var reach := maxf((CENTER_PX * px), 3.0)
	for i in 3:
		if shown.has("move_" + "xyz"[i]):
			var tip := _arrow_tip(viewport, i, wpp)
			if tip.is_finite():
				points.append(tip + (tip - c).normalized() * (ARROW_HEAD_PX * px))
		if shown.has("rot_" + "xyz"[i]):
			for q in MANIPULATOR.ring_points(pivot, axis(i), (RING_PX * px) * wpp, 32):
				var s: Vector2 = viewport.project(q)
				if s.is_finite():
					points.append(s)
			reach = maxf(reach, (RING_KNOB_PX * px) * 0.5 + 1.0)
		if shown.has("scale_" + "xyz"[i]):
			for end in _scale_dash(viewport, i, wpp):
				points.append(end)
	for key in PLANES:
		if shown.has("plane_" + key):
			points.append_array(_plane_quad(viewport, key, wpp))
		if shown.has("pscale_" + key):
			for seg in _bracket(viewport, key, wpp):
				points.append(seg[0])
				points.append(seg[1])
	var rect := Rect2(c, Vector2.ZERO)
	for p in points:
		rect = rect.expand(p)
	return rect.grow(reach + (HIT_PX * px))


## What a drag needs to remember from its press: {"id", "start", "t0" | "hit0" | "vec0"}.
func begin_drag(id: String, viewport: Object, screen: Vector2) -> Dictionary:
	var state := {"id": id, "start": screen, "wpp": world_per_px(viewport), "pivot": pivot, "basis": basis}
	var ray: Array = viewport.ray_from(screen)
	match _kind(id):
		"move", "scale":
			state["t0"] = MANIPULATOR.closest_on_line(pivot, axis(_axis_index(id)), ray[0], ray[1])
		"plane", "pscale":
			var n := axis(PLANES[_plane_key(id)][2])
			var at: Variant = MANIPULATOR.on_plane(pivot, n, ray[0], ray[1])
			state["hit0"] = at if at != null else pivot
		"rot":
			var a := axis(_axis_index(id))
			var at: Variant = MANIPULATOR.on_plane(pivot, a, ray[0], ray[1])
			var v: Vector3 = (at as Vector3) - pivot if at != null else Vector3.ZERO
			v -= a * v.dot(a)
			if v.length() < 1e-12:
				v = _knob_dir(viewport, _axis_index(id))
			state["vec0"] = v
		"free":
			var view_basis: Basis = viewport.camera_basis()
			var n := -view_basis.z
			var at: Variant = MANIPULATOR.on_plane(pivot, n, ray[0], ray[1])
			state["hit0"] = at if at != null else pivot
			state["view_basis"] = view_basis
	return state


## The transform (12 doubles, about the drag's pivot) a drag has made so far. shift snaps rotation
## to 15 degrees; snap (meters, 0 = off) snaps translation distances.
func drag_xf(state: Dictionary, viewport: Object, screen: Vector2, shift := false, snap := 0.0) -> PackedFloat64Array:
	var id := str(state.id)
	var p: Vector3 = state.pivot
	var b: Basis = state.basis
	var wpp := float(state.wpp)
	var ray: Array = viewport.ray_from(screen)
	var identity := FORM_OPS.xf_identity()
	match _kind(id):
		"move":
			var a := b[_axis_index(id)].normalized()
			var t := MANIPULATOR.closest_on_line(p, a, ray[0], ray[1])
			if is_nan(t) or is_nan(float(state.t0)):
				return identity
			var d := _snap(t - float(state.t0), snap)
			return FORM_OPS.xf_translation(a.x * d, a.y * d, a.z * d)
		"plane":
			var axes: Array = PLANES[_plane_key(id)]
			var n := b[axes[2]].normalized()
			var at: Variant = MANIPULATOR.on_plane(p, n, ray[0], ray[1])
			if at == null:
				return identity
			var delta: Vector3 = (at as Vector3) - (state.hit0 as Vector3)
			var u := b[axes[0]].normalized()
			var v := b[axes[1]].normalized()
			var du := _snap(delta.dot(u), snap)
			var dv := _snap(delta.dot(v), snap)
			return FORM_OPS.xf_translation(u.x * du + v.x * dv, u.y * du + v.y * dv, u.z * du + v.z * dv)
		"free":
			var vb: Basis = state.view_basis
			var at: Variant = MANIPULATOR.on_plane(p, -vb.z, ray[0], ray[1])
			if at == null:
				return identity
			var delta: Vector3 = (at as Vector3) - (state.hit0 as Vector3)
			var dx := _snap(delta.dot(vb.x.normalized()), snap)
			var dy := _snap(delta.dot(vb.y.normalized()), snap)
			var w: Vector3 = vb.x.normalized() * dx + vb.y.normalized() * dy
			return FORM_OPS.xf_translation(w.x, w.y, w.z)
		"rot":
			var a := b[_axis_index(id)].normalized()
			var angle := MANIPULATOR.angle_on_plane(p, a, state.vec0, ray[0], ray[1])
			if is_nan(angle):
				return identity
			if shift:
				angle = snappedf(angle, ANGLE_SNAP)
			return FORM_OPS.rotation_xf(_d(p), _d(a), angle)
		"scale":
			var a := b[_axis_index(id)].normalized()
			var t := MANIPULATOR.closest_on_line(p, a, ray[0], ray[1])
			if is_nan(t) or is_nan(float(state.t0)):
				return identity
			var f := MANIPULATOR.scale_factor(t - float(state.t0), (SCALE_AT_PX * px) * wpp)
			return scale_xf(p, [a], f)
		"pscale":
			var axes: Array = PLANES[_plane_key(id)]
			var n := b[axes[2]].normalized()
			var at: Variant = MANIPULATOR.on_plane(p, n, ray[0], ray[1])
			if at == null:
				return identity
			var u := b[axes[0]].normalized()
			var v := b[axes[1]].normalized()
			var diagonal := (u + v).normalized()
			var travel := ((at as Vector3) - (state.hit0 as Vector3)).dot(diagonal)
			var f := MANIPULATOR.scale_factor(travel, (BRACKET_AT_PX * px) * sqrt(2.0) * wpp)
			return scale_xf(p, [u, v], f)
		"uniform":
			var f := exp((screen.x - (state.start as Vector2).x) / (UNIFORM_PX * px))
			return scale_xf(p, [], f)
	return identity


## A scale by f along the given unit axes (all three when empty) about pivot, in doubles.
static func scale_xf(pivot_point: Vector3, axes: Array, f: float) -> PackedFloat64Array:
	var m := PackedFloat64Array([1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0])
	if axes.is_empty():
		for i in 3:
			m[4 * i] = f
	else:
		for a in axes:
			var d := [float(a.x), float(a.y), float(a.z)]
			for r in 3:
				for c in 3:
					m[3 * r + c] += (f - 1.0) * d[r] * d[c]
	return FORM_OPS.xf_about(m, pivot_point.x, pivot_point.y, pivot_point.z)


## The transform of the Edit Form panel's numbers about the pivot in the frame b: scales, then
## rotations about X, Y, Z, then the translation. Neutral values give the identity.
static func numeric_xf(pivot_point: Vector3, b: Basis, v: Dictionary) -> PackedFloat64Array:
	var x := b.x.normalized()
	var y := b.y.normalized()
	var z := b.z.normalized()
	var xf := FORM_OPS.xf_identity()
	var scales := [[float(v.get("x_scale", 1.0)), [x]], [float(v.get("y_scale", 1.0)), [y]], [float(v.get("z_scale", 1.0)), [z]],
		[float(v.get("xy_scale", 1.0)), [x, y]], [float(v.get("yz_scale", 1.0)), [y, z]], [float(v.get("zx_scale", 1.0)), [z, x]],
		[float(v.get("uniform_scale", 1.0)), []]]
	for entry in scales:
		if float(entry[0]) != 1.0 and float(entry[0]) > 0.0:
			xf = FORM_OPS.xf_compose(scale_xf(pivot_point, entry[1], float(entry[0])), xf)
	for spec in [["x_angle", x], ["y_angle", y], ["z_angle", z]]:
		var angle := float(v.get(spec[0], 0.0))
		if angle != 0.0:
			xf = FORM_OPS.xf_compose(FORM_OPS.rotation_xf(_d(pivot_point), _d(spec[1]), angle), xf)
	var t: Vector3 = x * float(v.get("x_distance", 0.0)) + y * float(v.get("y_distance", 0.0)) + z * float(v.get("z_distance", 0.0))
	var dx := float(v.get("x_distance", 0.0)) * x.x + float(v.get("y_distance", 0.0)) * y.x + float(v.get("z_distance", 0.0)) * z.x
	var dy := float(v.get("x_distance", 0.0)) * x.y + float(v.get("y_distance", 0.0)) * y.y + float(v.get("z_distance", 0.0)) * z.y
	var dz := float(v.get("x_distance", 0.0)) * x.z + float(v.get("y_distance", 0.0)) * y.z + float(v.get("z_distance", 0.0)) * z.z
	if t != Vector3.ZERO:
		xf = FORM_OPS.xf_compose(FORM_OPS.xf_translation(dx, dy, dz), xf)
	return xf


static func is_identity(xf: PackedFloat64Array) -> bool:
	return xf == FORM_OPS.xf_identity()


# --- Geometry on screen ----------------------------------------------------------------------

func _arrow_tip(viewport: Object, i: int, wpp: float) -> Vector2:
	return viewport.project(pivot + axis(i) * (ARROW_PX * px) * wpp)


func _plane_quad(viewport: Object, key: String, wpp: float) -> PackedVector2Array:
	var axes: Array = PLANES[key]
	var u := axis(axes[0]) * wpp
	var v := axis(axes[1]) * wpp
	var lo := (PLANE_AT_PX * px) - (PLANE_SIZE_PX * px) * 0.5
	var hi := (PLANE_AT_PX * px) + (PLANE_SIZE_PX * px) * 0.5
	var quad := PackedVector2Array()
	for corner in [Vector2(lo, lo), Vector2(hi, lo), Vector2(hi, hi), Vector2(lo, hi)]:
		var q: Vector2 = viewport.project(pivot + u * corner.x + v * corner.y)
		if not q.is_finite():
			return PackedVector2Array()
		quad.append(q)
	# Seen edge-on the square is a sliver: no handle then.
	var area := absf((quad[1] - quad[0]).cross(quad[3] - quad[0]))
	return quad if area > 12.0 else PackedVector2Array()


func _bracket(viewport: Object, key: String, wpp: float) -> Array:
	var axes: Array = PLANES[key]
	var u := axis(axes[0]) * wpp
	var v := axis(axes[1]) * wpp
	var corner := pivot + (u + v) * (BRACKET_AT_PX * px)
	var a: Vector2 = viewport.project(corner)
	var b: Vector2 = viewport.project(corner - u * (BRACKET_ARM_PX * px))
	var d: Vector2 = viewport.project(corner - v * (BRACKET_ARM_PX * px))
	if not (a.is_finite() and b.is_finite() and d.is_finite()):
		return []
	if a.distance_to(b) < 2.0 and a.distance_to(d) < 2.0:
		return []
	return [[a, b], [a, d]]


func _scale_dash(viewport: Object, i: int, wpp: float) -> Array:
	var at: Vector2 = viewport.project(pivot + axis(i) * (SCALE_AT_PX * px) * wpp)
	var c: Vector2 = viewport.project(pivot)
	if not (at.is_finite() and c.is_finite()) or at.distance_to(c) < 6.0:
		return []
	var dir := (at - c).normalized()
	var side := Vector2(-dir.y, dir.x) * (SCALE_DASH_PX * px) * 0.5
	return [at - side, at + side]


## Where a ring's knob sits: the ring point toward the camera's up (its right when the ring faces up).
func _knob_dir(viewport: Object, i: int) -> Vector3:
	var view_basis: Basis = viewport.camera_basis()
	var a := axis(i)
	var up := view_basis.y
	var d := up - a * up.dot(a)
	if d.length() < 1e-3:
		var right := view_basis.x
		d = right - a * right.dot(a)
	return d.normalized()


func _ring_knob(viewport: Object, i: int, wpp: float) -> Vector2:
	return viewport.project(pivot + _knob_dir(viewport, i) * (RING_PX * px) * wpp)


static func _near_segment(p: Vector2, a: Vector2, b: Vector2, px: float) -> bool:
	return Geometry2D.get_closest_point_to_segment(p, a, b).distance_to(p) <= px


static func _kind(id: String) -> String:
	return id.split("_")[0]


static func _axis_index(id: String) -> int:
	return "xyz".find(id.substr(id.length() - 1))


static func _plane_key(id: String) -> String:
	return id.split("_")[1]


static func _snap(value: float, step: float) -> float:
	return snappedf(value, step) if step > 0.0 else value


static func _d(v: Vector3) -> PackedFloat64Array:
	return PackedFloat64Array([v.x, v.y, v.z])
