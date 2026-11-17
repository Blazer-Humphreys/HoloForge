extends SceneTree
## Holo Forge picking on a kernel box seen from straight above (orthographic, 1 mm = 1 px):
## a ray hits the top face; the cursor near an edge picks that edge, near a corner the vertex,
## and in the middle the face; selection priority and filters change the winner; a hidden
## edge is skipped; window selection takes whole items left-to-right and touched ones
## right-to-left; a lasso does the same with an outline.
##
## godot --headless --path . --script res://tests/holo_forge_picking_test.gd

const PICKING := preload("res://addons/holo_forge/core/picking.gd")
const TESSELLATE := preload("res://addons/holo_forge/core/tessellate.gd")
const REGEN := preload("res://addons/holo_forge/core/regen.gd")
const MANIPULATOR := preload("res://addons/holo_forge/core/manipulator_math.gd")

var failures: Array[String] = []


func _init() -> void:
	call_deferred("run")


func run() -> void:
	var kernel := REGEN.make_kernel()
	_expect(kernel != null, "The native kernel should load.")
	if kernel != null:
		_check(kernel)
	print("PASS holo_forge_picking: top face by ray, edge, vertex, priority and filters, hidden edges skipped, window and crossing selection, lasso, section-clipped halves skipped." \
		if failures.is_empty() else "FAIL holo_forge_picking")
	quit(0 if failures.is_empty() else 1)


func _check(kernel: RefCounted) -> void:
	# A 100 x 50 x 80 mm box (x, y, z) with its min corner at the origin.
	var shape: RefCounted = kernel.make_box(Vector3(0.1, 0.05, 0.08))
	var tess := TESSELLATE.tessellate(shape)
	var bodies := [PICKING.prepare("body1", tess)]
	var project := func(p: Vector3) -> Vector2: return Vector2(p.x, p.z) * 1000.0
	var all_visible := func(_p: Vector3) -> bool: return true
	var top_only := func(p: Vector3) -> bool: return p.y > 0.049
	var down := Vector3.DOWN
	var filters := {"body": true, "face": true, "edge": true, "vertex": true}

	var hit := PICKING.ray_hit(bodies, Vector3(0.05, 1, 0.04), down)
	_expect(not hit.is_empty() and absf((hit.point as Vector3).y - 0.05) < 1e-6, "A ray down the middle should hit the top at y = 50 mm (%s)" % hit)
	var top_face: int = hit.get("face", -1)
	_expect(top_face >= 0 and _face_normal(tess, top_face).is_equal_approx(Vector3.UP), "The ray should hit the face whose normal is up.")

	var middle := PICKING.pick(bodies, Vector3(0.05, 1, 0.04), down, project, Vector2(50, 40), filters, "default", 6.0, top_only)
	_expect(middle.get("kind") == "face" and middle.get("index") == top_face, "The middle of the top should pick the top face (%s)" % middle)

	# 2 px from the x = 100 mm edge, half way along it.
	var near_edge := PICKING.pick(bodies, Vector3(0.098, 1, 0.04), down, project, Vector2(98, 40), filters, "default", 6.0, top_only)
	_expect(near_edge.get("kind") == "edge" and _edge_is_top_line_at_x(tess, near_edge.index, 0.1), "Near the right edge the edge should win (%s)" % near_edge)
	var face_first := PICKING.pick(bodies, Vector3(0.098, 1, 0.04), down, project, Vector2(98, 40), filters, "face", 6.0, top_only)
	_expect(face_first.get("kind") == "face", "Face priority should prefer the face there (%s)" % face_first)
	var body_first := PICKING.pick(bodies, Vector3(0.098, 1, 0.04), down, project, Vector2(98, 40), filters, "body", 6.0, top_only)
	_expect(body_first.get("kind") == "body" and body_first.get("body") == "body1", "Body priority should pick the body (%s)" % body_first)
	var no_edges := PICKING.pick(bodies, Vector3(0.098, 1, 0.04), down, project, Vector2(98, 40), {"body": true, "face": true, "edge": false, "vertex": false}, "default", 6.0, top_only)
	_expect(no_edges.get("kind") == "face", "With edges filtered out the face should be picked (%s)" % no_edges)

	var corner := PICKING.pick(bodies, Vector3(0.0995, 1, 0.0795), down, project, Vector2(99.5, 79.5), filters, "default", 6.0, top_only)
	_expect(corner.get("kind") == "vertex" and ((corner.point as Vector3) - Vector3(0.1, 0.05, 0.08)).length() < 1e-6, "Near a top corner the vertex should win (%s)" % corner)
	# The bottom edges project to the same screen lines but are hidden by the top face.
	var hidden := PICKING.nearest_edge(bodies, project, Vector2(98, 40), 6.0, top_only)
	_expect(not hidden.is_empty() and (hidden.point as Vector3).y > 0.049, "A hidden bottom edge must not be picked over the visible top one.")

	var window := PICKING.window_select(bodies, project, Rect2(-10, -10, 120, 100), false, "body", all_visible)
	_expect(window.size() == 1 and window[0].kind == "body", "A window around the whole box should select the body.")
	var partial := PICKING.window_select(bodies, project, Rect2(-10, -10, 60, 100), false, "body", all_visible)
	_expect(partial.is_empty(), "A window over half the box should not select it left-to-right.")
	var crossing := PICKING.window_select(bodies, project, Rect2(-10, -10, 60, 100), true, "body", all_visible)
	_expect(crossing.size() == 1, "A crossing window over half the box should select it.")
	# Seen from above the side faces and upright edges are edge-on but still visible; only the
	# bottom face and the bottom edges are hidden.
	var faces := PICKING.window_select(bodies, project, Rect2(-10, -10, 120, 100), false, "face", top_only)
	var bottom_taken := faces.any(func(p: Dictionary) -> bool: return _face_normal(tess, p.index).is_equal_approx(Vector3.DOWN))
	_expect(faces.size() == 5 and not bottom_taken, "A face window from above should take every face but the hidden bottom (%s)" % [faces])
	var edges := PICKING.window_select(bodies, project, Rect2(-10, -10, 120, 100), false, "edge", top_only)
	_expect(edges.size() == 8, "A window should take the 8 edges that reach the top, not the 4 hidden bottom ones (got %d)" % edges.size())
	var lasso := PICKING.lasso_select(bodies, project, PackedVector2Array([Vector2(-5, -5), Vector2(105, -5), Vector2(105, 85), Vector2(-5, 85)]), false, "vertex", top_only)
	_expect(lasso.size() == 4, "A lasso around the box should take the 4 visible top corners (got %d)" % lasso.size())
	_expect(PICKING.from_key(PICKING.key(corner)).index == corner.index, "Pick keys should round-trip.")

	# A Section analysis cutting away x > 50 mm: nothing in that half can be picked, hovered or
	# window-selected; a ray through the cut-away end hits the -X wall behind it.
	var clipped := PICKING.prepare("body1", tess)
	clipped["clip"] = {"origin": Vector3(0.05, 0, 0), "normal": Vector3.RIGHT}
	var plain_hit := PICKING.ray_hit(bodies, Vector3(1, 0.025, 0.04), Vector3.LEFT)
	_expect(not plain_hit.is_empty() and absf((plain_hit.point as Vector3).x - 0.1) < 1e-6, "Unclipped, a ray from +X hits the +X end (%s)." % plain_hit)
	var through := PICKING.ray_hit([clipped], Vector3(1, 0.025, 0.04), Vector3.LEFT)
	_expect(not through.is_empty() and (through.point as Vector3).x < 0.05 and _face_normal(tess, int(through.face)).is_equal_approx(Vector3.LEFT),
		"With the +X half cut away the ray should hit the -X wall (%s)." % through)
	_expect(PICKING.nearest_vertex([clipped], project, Vector2(99.5, 79.5), 6.0, all_visible).is_empty(), "A corner in the cut-away half can't be picked.")
	_expect(not PICKING.nearest_vertex([clipped], project, Vector2(0.5, 0.5), 6.0, all_visible).is_empty(), "A corner in the kept half still can.")
	_expect(PICKING.nearest_edge([clipped], project, Vector2(98, 40), 6.0, all_visible).is_empty(), "The x = 100 mm edges are cut away, so none is near.")
	var clipped_faces := PICKING.window_select([clipped], project, Rect2(-10, -10, 120, 100), false, "face", all_visible)
	_expect(not clipped_faces.any(func(p: Dictionary) -> bool: return _face_normal(tess, p.index).is_equal_approx(Vector3.RIGHT)) \
			and clipped_faces.any(func(p: Dictionary) -> bool: return _face_normal(tess, p.index).is_equal_approx(Vector3.UP)),
		"A face window should skip the cut-away +X end but keep the half-cut top (%s)." % [clipped_faces])
	var clipped_vertices := PICKING.window_select([clipped], project, Rect2(-10, -10, 120, 100), false, "vertex", all_visible)
	_expect(clipped_vertices.size() == 4, "Only the 4 corners at x = 0 remain to window-select (got %d)." % clipped_vertices.size())

	# Handle math: a ray crossing the arrow's axis, a point on a plane, an angle around an axis.
	var t := MANIPULATOR.closest_on_line(Vector3.ZERO, Vector3.UP, Vector3(1, 0.3, 0), Vector3.LEFT)
	_expect(absf(t - 0.3) < 1e-6, "A ray crossing the up axis at y = 0.3 should give t = 0.3 (got %f)" % t)
	_expect(is_nan(MANIPULATOR.closest_on_line(Vector3.ZERO, Vector3.UP, Vector3(1, 0, 0), Vector3.UP)), "A ray parallel to the axis has no closest point.")
	var on_ground = MANIPULATOR.on_plane(Vector3.ZERO, Vector3.UP, Vector3(0.2, 1, 0.1), Vector3.DOWN)
	_expect(on_ground is Vector3 and (on_ground as Vector3).is_equal_approx(Vector3(0.2, 0, 0.1)), "A ray down should meet the ground under it.")
	var angle := MANIPULATOR.angle_on_plane(Vector3.ZERO, Vector3.UP, Vector3.RIGHT, Vector3(0, 1, -1), Vector3.DOWN)
	_expect(absf(angle - PI * 0.5) < 1e-6, "Turning from +X to -Z about +Y is +90 degrees (got %f)" % rad_to_deg(angle))
	_expect(MANIPULATOR.snap(Vector3(0.0123, 0.0, -0.0047), 0.001).is_equal_approx(Vector3(0.012, 0.0, -0.005)), "Point handles snap to the step.")


func _face_normal(tess: Dictionary, face: int) -> Vector3:
	var face_ids: PackedInt32Array = tess.face_ids
	for t in face_ids.size():
		if face_ids[t] == face:
			return (tess.normals as PackedVector3Array)[(tess.indices as PackedInt32Array)[t * 3]].normalized()
	return Vector3.ZERO


func _edge_is_top_line_at_x(tess: Dictionary, edge: int, x: float) -> bool:
	var points: PackedVector3Array = tess.edge_points
	var ids: PackedInt32Array = tess.edge_ids
	var found := false
	for s in ids.size():
		if ids[s] == edge:
			found = true
			for p in [points[s * 2], points[s * 2 + 1]]:
				if absf(p.x - x) > 1e-6 or absf(p.y - 0.05) > 1e-6:
					return false
	return found


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error(message)
		print("FAIL: ", message)
