extends SceneTree
## Passthrough draws the part inside its scene, in every renderer. A scene (a SubViewport with a
## world of its own: a sun, a blue sky colour, the CadPart turned and moved) gets, from where the
## Forge camera looks, a green wall far behind the part and a red board between the camera and the
## part over the left half of the view (both unshaded). With Passthrough on:
##   - a corner of the view is the green wall, and with the wall hidden the scene's blue sky;
##   - the right half of the part shows the part (neither green nor red), lit by the scene's sun;
##   - the left half of the part is the red board: the scene's object in front hides the part;
##   - with the view's bodies hidden the part's place shows the wall: the part's baked node in the
##     scene is hidden from rendering, so it is not drawn twice.
## With Passthrough off the corner is the view's own background again (not green, not blue) and the
## whole part shows (no red).
##
## Needs a window (headless runs draw nothing). Run it in both renderers:
## godot --path . --rendering-method forward_plus --script res://tests/holo_forge_passthrough_render_test.gd
## godot --path . --rendering-method gl_compatibility --script res://tests/holo_forge_passthrough_render_test.gd

const DOCUMENT := preload("res://addons/holo_forge/core/document.gd")
const CAD_PART := preload("res://addons/holo_forge/nodes/cad_part.gd")
const WORKSPACE := preload("res://addons/holo_forge/ui/forge_workspace.gd")
const OPERATIONS := preload("res://addons/holo_forge/core/operations.gd")
const GREEN := Color(0.1, 0.85, 0.15)
const RED := Color(0.9, 0.1, 0.1)
const SKY := Color(0.1, 0.2, 0.9)
static var PART_PLACE := Transform3D(Basis(Vector3(0.2, 1.0, -0.3).normalized(), 0.9), Vector3(31.0, 4.5, -17.0))

var failures: Array[String] = []
var ws: Control
var view: Control
var scene: Node3D
var part: Node3D
var wall: MeshInstance3D
var board: MeshInstance3D
var method := ""


func _init() -> void:
	call_deferred("run")


func run() -> void:
	create_timer(180.0).timeout.connect(func() -> void:
		print("FAIL holo_forge_passthrough_render: timed out ", failures)
		quit(1))
	method = RenderingServer.get_current_rendering_method()
	if DisplayServer.get_name() == "headless":
		print("FAIL holo_forge_passthrough_render: needs a window (headless runs draw nothing)")
		quit(1)
		return
	root.size = Vector2i(1200, 800)
	ws = WORKSPACE.new()
	ws.passthrough_store = {}
	ws.theme_store = {}
	root.add_child(ws)
	ws.size = Vector2(1200, 800)
	view = ws.viewport
	_make_scene()
	ws.passthrough_scene_root = scene
	ws.set_part(part)
	for i in 4:
		await process_frame
	view.fit()
	# (The grid and the origin would cross the corner and the part.)
	view.set_grid_visible(false)
	(view.get("_origin_root") as Node3D).visible = false
	ws.set_passthrough(true)
	await _settle()
	_expect(view.passthrough_on(), "Passthrough should be on.")
	_place_wall_and_board()
	var px: Vector2 = Vector2(view.get("_viewport").size)
	var center := px * 0.5
	var corner := Vector2(px.x - 12, 12)
	var left := center + Vector2(-25, 0)
	var right := center + Vector2(25, 0)
	var image := await _grab()
	_expect(_like(image, corner, GREEN), "On: a corner should be the scene's green wall, got %s." % _at(image, corner))
	_expect(not _like(image, right, GREEN) and not _like(image, right, RED), "On: the right half of the part should show the part, got %s." % _at(image, right))
	_expect(_like(image, left, RED), "On: the left half of the part should be hidden by the scene's red board, got %s." % _at(image, left))
	var lit := _at(image, right)
	# The body's own baked node is hidden from rendering: with the view's bodies hidden, the wall.
	(view.get("_bodies_root") as Node3D).visible = false
	image = await _grab()
	_expect(_like(image, right, GREEN), "On, the view's bodies hidden: the part's baked node should be hidden too (the wall shows), got %s." % _at(image, right))
	(view.get("_bodies_root") as Node3D).visible = true
	wall.visible = false
	image = await _grab()
	_expect(_like(image, corner, SKY), "On, the wall hidden: a corner should be the scene's blue sky, got %s." % _at(image, corner))
	wall.visible = true
	ws.set_passthrough(false)
	await _settle()
	image = await _grab()
	var off_corner := _at(image, corner)
	_expect(not _like(image, corner, GREEN) and not _like(image, corner, SKY), "Off: a corner should be the view's own background, got %s." % off_corner)
	_expect(not _like(image, left, RED) and not _like(image, left, GREEN), "Off: the whole part should show (no red board), got %s." % _at(image, left))
	print(("PASS holo_forge_passthrough_render (%s): on, the scene's wall and sky show around the part, the scene's board in front hides it, its baked node is not drawn twice, the part is lit (%s); off, the view's own background (%s) and the whole part." % [method, lit, off_corner]) \
		if failures.is_empty() else "FAIL holo_forge_passthrough_render (%s): %d failures" % [method, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _make_scene() -> void:
	var holder := SubViewport.new()
	holder.own_world_3d = true
	holder.size = Vector2i(64, 64)
	holder.render_target_update_mode = SubViewport.UPDATE_DISABLED
	root.add_child(holder)
	scene = Node3D.new()
	scene.name = "RenderScene"
	holder.add_child(scene)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, 35, 0)
	scene.add_child(sun)
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = SKY
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color(0.3, 0.3, 0.3)
	scene.add_child(environment)
	wall = _flat(GREEN)
	board = _flat(RED)
	part = CAD_PART.new()
	part.name = "RenderPart"
	var doc: Resource = DOCUMENT.new()
	var box: Resource = doc.add_feature("box", "Block", {
		"length": doc.make_input("40 mm", "length"), "height": doc.make_input("20 mm", "length"), "width": doc.make_input("30 mm", "length"),
	}, {"operation": OPERATIONS.NEW_BODY, "position": Vector3.ZERO})
	box.options.body_id = doc.new_body(box.id)
	part.document = doc
	part.transform = PART_PLACE
	scene.add_child(part)


func _flat(color: Color) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	var quad := QuadMesh.new()
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	quad.material = material
	node.mesh = quad
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	scene.add_child(node)
	return node


## In the camera's frame (in the scene): the wall a metre behind the part facing the camera, the
## board halfway to the part over the left half of the view.
func _place_wall_and_board() -> void:
	var camera: Camera3D = view.camera()
	var eye := camera.global_transform
	var middle: Vector3 = view.to_world(Vector3(0.0, 0.01, 0.0))
	var depth := (middle - eye.origin).dot(-eye.basis.z)
	wall.global_transform = eye * Transform3D(Basis.from_scale(Vector3(50, 50, 1)), Vector3(0, 0, -(depth + 1.0)))
	board.global_transform = eye * Transform3D(Basis.from_scale(Vector3(depth * 4.0, depth * 4.0, 1)), Vector3(-depth * 2.0, 0, -depth * 0.5))


func _settle() -> void:
	for i in 6:
		await process_frame


func _grab() -> Image:
	for i in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	return (view.get("_viewport") as SubViewport).get_texture().get_image()


func _at(image: Image, at: Vector2) -> Color:
	return image.get_pixelv(Vector2i(at))


## Close to the colour (unshaded colours come back as they were set, give or take dithering).
func _like(image: Image, at: Vector2, color: Color) -> bool:
	var got := _at(image, at)
	return absf(got.r - color.r) < 0.08 and absf(got.g - color.g) < 0.08 and absf(got.b - color.b) < 0.08


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		print("  ", message)
