@tool
extends RefCounted
## Geometry for on-canvas handles: where a mouse ray meets an arrow's axis, a point handle's
## plane, or an angle handle's rotation plane.


## The parameter t of the point on the line origin + direction * t closest to the ray.
## Returns NAN when the ray runs parallel to the line.
static func closest_on_line(origin: Vector3, direction: Vector3, ray_from: Vector3, ray_dir: Vector3) -> float:
	var d1 := direction.normalized()
	var d2 := ray_dir.normalized()
	var r := origin - ray_from
	var b := d1.dot(d2)
	var denom := 1.0 - b * b
	if denom < 1e-8:
		return NAN
	var d := d1.dot(r)
	var e := d2.dot(r)
	return (b * e - d) / denom


## Where the ray meets the plane through point with the given normal, or null.
static func on_plane(point: Vector3, normal: Vector3, ray_from: Vector3, ray_dir: Vector3) -> Variant:
	return Plane(normal.normalized(), point).intersects_ray(ray_from, ray_dir)


## The signed angle (radians) from start to the ray's hit on the plane through origin
## perpendicular to axis, measured around axis. Returns NAN when the ray misses the plane.
static func angle_on_plane(origin: Vector3, axis: Vector3, start: Vector3, ray_from: Vector3, ray_dir: Vector3) -> float:
	var hit = on_plane(origin, axis, ray_from, ray_dir)
	if hit == null:
		return NAN
	var a := start - axis.normalized() * start.dot(axis.normalized())
	var b: Vector3 = (hit as Vector3) - origin
	b -= axis.normalized() * b.dot(axis.normalized())
	if a.is_zero_approx() or b.is_zero_approx():
		return 0.0
	return a.signed_angle_to(b, axis.normalized())


## Rounds v to the nearest multiple of step on each axis (step <= 0 leaves it).
static func snap(v: Vector3, step: float) -> Vector3:
	return v.snapped(Vector3.ONE * step) if step > 0.0 else v


## The points of a circle of radius (meters) around center in the plane perpendicular to axis,
## closed (the first point repeats at the end).
static func ring_points(center: Vector3, axis: Vector3, radius: float, segments := 48) -> PackedVector3Array:
	var n := axis.normalized()
	var u := n.cross(Vector3.UP if absf(n.y) < 0.9 else Vector3.RIGHT).normalized()
	var v := n.cross(u)
	var points := PackedVector3Array()
	for i in segments + 1:
		var a := TAU * float(i) / float(segments)
		points.append(center + (u * cos(a) + v * sin(a)) * radius)
	return points


## True when screen_pos lies within tolerance_px of the on-screen outline of a ring of radius_px
## pixels around center, perpendicular to axis. project: Callable(Vector3) -> Vector2 (INF when
## behind the camera). world_per_px: meters per pixel at center (<= 0: measured through project).
static func ring_hit(screen_pos: Vector2, center: Vector3, axis: Vector3, radius_px: float, project: Callable,
		world_per_px := 0.0, tolerance_px := 6.0) -> bool:
	var per_px := world_per_px
	if per_px <= 0.0:
		per_px = _world_per_px(center, axis, project)
		if per_px <= 0.0:
			return false
	var points := ring_points(center, axis, radius_px * per_px, 48)
	var previous: Vector2 = project.call(points[0])
	for i in range(1, points.size()):
		var current: Vector2 = project.call(points[i])
		if previous.is_finite() and current.is_finite():
			var closest := Geometry2D.get_closest_point_to_segment(screen_pos, previous, current)
			if closest.distance_to(screen_pos) <= tolerance_px:
				return true
		previous = current
	return false


## A scale handle's factor: 1 + travel / reference (both meters), never below minimum.
static func scale_factor(travel: float, reference: float, minimum := 0.01) -> float:
	if reference <= 0.0:
		return 1.0
	return maxf(1.0 + travel / reference, minimum)


## Meters per pixel at center, measured along the ring plane's least foreshortened direction.
static func _world_per_px(center: Vector3, axis: Vector3, project: Callable) -> float:
	var n := axis.normalized()
	var u := n.cross(Vector3.UP if absf(n.y) < 0.9 else Vector3.RIGHT).normalized()
	var v := n.cross(u)
	var at: Vector2 = project.call(center)
	if not at.is_finite():
		return 0.0
	var step := 1e-3
	var best := 0.0
	for d in [u, v]:
		var q: Vector2 = project.call(center + d * step)
		if q.is_finite():
			best = maxf(best, q.distance_to(at))
	return step / best if best > 0.0 else 0.0
