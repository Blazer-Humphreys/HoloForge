@tool
extends Control
## The view cube: shows the camera's orientation; clicking a face, edge or corner turns the view
## to one of 26 directions, dragging it orbits, and the house button goes to the home view. The
## face, edge or corner under the mouse lights up. Its colours come from the view's palette
## (apply_theme).

signal view_requested(direction: Vector3)
signal orbit_dragged(delta: Vector2)
signal home_requested

const SIZE := 104
const FACES := {
	"FRONT": Vector3.BACK, "BACK": Vector3.FORWARD, "RIGHT": Vector3.RIGHT,
	"LEFT": Vector3.LEFT, "TOP": Vector3.UP, "BOTTOM": Vector3.DOWN,
}

var _viewport: SubViewport
var _camera: Camera3D
var _press := Vector2.INF
var _dragged := false
var _home: Button
var _face_material: StandardMaterial3D
var _edge_material: StandardMaterial3D
var _hover_material: StandardMaterial3D
var _hover_box: MeshInstance3D
var _labels: Array[Label3D] = []
## The region under the mouse: -1, 0 or 1 per axis (ZERO for none).
var _hover := Vector3.ZERO


func _init() -> void:
	custom_minimum_size = Vector2(SIZE, SIZE + 22)
	size = custom_minimum_size
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_exited.connect(func() -> void: _set_hover(Vector3.ZERO))

	_home = Button.new()
	_home.flat = true
	_home.focus_mode = Control.FOCUS_NONE
	_home.tooltip_text = "Home view"
	_home.text = "⌂"
	_home.position = Vector2(2, 0)
	_home.size = Vector2(22, 22)
	_home.pressed.connect(func() -> void: home_requested.emit())
	add_child(_home)

	var container := SubViewportContainer.new()
	container.stretch = true
	container.position = Vector2(0, 22)
	container.size = Vector2(SIZE, SIZE)
	container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(container)
	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_viewport.transparent_bg = true
	_viewport.msaa_3d = Viewport.MSAA_4X
	_viewport.size = Vector2i(SIZE, SIZE)
	container.add_child(_viewport)

	var world := Node3D.new()
	world.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_viewport.add_child(world)
	_camera = Camera3D.new()
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.size = 3.4
	world.add_child(_camera)

	var cube := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(2, 2, 2)
	_face_material = StandardMaterial3D.new()
	_face_material.roughness = 0.85
	box.material = _face_material
	cube.mesh = box
	world.add_child(cube)

	# The twelve edges, a hair outside the faces.
	var edges := ImmediateMesh.new()
	edges.surface_begin(Mesh.PRIMITIVE_LINES)
	for axis in 3:
		for a in [-1.0, 1.0]:
			for b in [-1.0, 1.0]:
				var from := Vector3.ZERO
				from[axis] = -1.0
				from[(axis + 1) % 3] = a
				from[(axis + 2) % 3] = b
				var to := from
				to[axis] = 1.0
				edges.surface_add_vertex(from * 1.004)
				edges.surface_add_vertex(to * 1.004)
	edges.surface_end()
	_edge_material = StandardMaterial3D.new()
	_edge_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var edge_node := MeshInstance3D.new()
	edge_node.mesh = edges
	edge_node.material_override = _edge_material
	world.add_child(edge_node)

	_hover_material = StandardMaterial3D.new()
	_hover_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_hover_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_hover_material.render_priority = 1
	_hover_box = MeshInstance3D.new()
	_hover_box.mesh = BoxMesh.new()
	_hover_box.material_override = _hover_material
	_hover_box.visible = false
	world.add_child(_hover_box)

	var light := DirectionalLight3D.new()
	light.rotation = Vector3(-0.7, 0.5, 0)
	light.light_energy = 0.5
	_camera.add_child(light)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_CLEAR_COLOR
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.9, 0.9, 0.92)
	env.environment.ambient_light_energy = 0.85
	env.environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	world.add_child(env)

	for face_name in FACES:
		var normal: Vector3 = FACES[face_name]
		var label := Label3D.new()
		label.text = face_name
		label.font_size = 64
		label.pixel_size = 0.0055
		label.outline_size = 0
		label.double_sided = false
		label.position = normal * 1.006
		var up := Vector3.UP if absf(normal.y) < 0.5 else (Vector3.FORWARD if normal.y > 0 else Vector3.BACK)
		label.basis = Basis.looking_at(-normal, up)
		world.add_child(label)
		_labels.append(label)
	apply_theme({})
	set_camera_basis(Basis.IDENTITY)


## Colours the cube from a view palette (forge_theme.gd keys cube_face, cube_edge, cube_text,
## cube_hover and status_text for the house button); missing keys keep the light look.
func apply_theme(palette: Dictionary) -> void:
	_face_material.albedo_color = palette.get("cube_face", Color(0.9, 0.92, 0.95))
	_edge_material.albedo_color = palette.get("cube_edge", Color(0.44, 0.48, 0.56))
	_hover_material.albedo_color = palette.get("cube_hover", Color(0.15, 0.5, 1.0, 0.5))
	var text: Color = palette.get("cube_text", Color(0.16, 0.18, 0.22))
	for label in _labels:
		label.modulate = text
	var home: Color = palette.get("status_text", text)
	for state in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
		_home.add_theme_color_override(state, home if state == "font_color" else home.lerp(_hover_material.albedo_color, 0.5))


## The colours the cube is drawn in now: {"face", "edge", "text", "hover"}.
func colors() -> Dictionary:
	return {"face": _face_material.albedo_color, "edge": _edge_material.albedo_color, "text": _labels[0].modulate,
		"hover": _hover_material.albedo_color}


## Turns the cube camera to match the main camera's orientation.
func set_camera_basis(basis: Basis) -> void:
	_camera.transform = Transform3D(basis.orthonormalized(), basis.z.normalized() * 6.0)


## The view direction (from the target toward the camera) for a point on the cube:
## near a face's middle gives that face, near an edge gives the edge, near a corner the corner.
static func direction_for_hit(point: Vector3) -> Vector3:
	return _region_for_hit(point).normalized()


static func _region_for_hit(point: Vector3) -> Vector3:
	var d := Vector3.ZERO
	for i in 3:
		if absf(point[i]) > 0.6:
			d[i] = signf(point[i])
	return d


## The face, edge or corner under the mouse (ZERO for none), for tests.
func hovered_region() -> Vector3:
	return _hover


func _gui_input(event: InputEvent) -> void:
	var button := event as InputEventMouseButton
	if button != null and button.button_index == MOUSE_BUTTON_LEFT:
		if button.pressed:
			_press = button.position
			_dragged = false
		else:
			if not _dragged and _press.is_finite():
				var direction := _direction_at(button.position)
				if not direction.is_zero_approx():
					view_requested.emit(direction)
			_press = Vector2.INF
		accept_event()
		return
	var motion := event as InputEventMouseMotion
	if motion != null and _press.is_finite() and (motion.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
		if _dragged or motion.position.distance_to(_press) > 3.0:
			_dragged = true
			_set_hover(Vector3.ZERO)
			orbit_dragged.emit(motion.relative)
		accept_event()
	elif motion != null and motion.button_mask == 0:
		_set_hover(_region_at(motion.position))


func _direction_at(local: Vector2) -> Vector3:
	return _region_at(local).normalized()


func _region_at(local: Vector2) -> Vector3:
	var p := local - Vector2(0, 22)
	if p.x < 0 or p.y < 0 or p.x > SIZE or p.y > SIZE:
		return Vector3.ZERO
	var from := _camera.project_ray_origin(p)
	var dir := _camera.project_ray_normal(p)
	var hit = AABB(Vector3(-1, -1, -1), Vector3(2, 2, 2)).intersects_ray(from, dir)
	if hit == null:
		return Vector3.ZERO
	return _region_for_hit(hit)


## Lights up a face, edge or corner region: a thin see-through box over it, just outside the cube.
func _set_hover(region: Vector3) -> void:
	if region == _hover:
		return
	_hover = region
	_hover_box.visible = region != Vector3.ZERO
	if not _hover_box.visible:
		return
	var center := Vector3.ZERO
	var extent := Vector3.ZERO
	for i in 3:
		if region[i] != 0.0:
			center[i] = region[i] * 0.81
			extent[i] = 0.42
		else:
			extent[i] = 1.22
	(_hover_box.mesh as BoxMesh).size = extent
	_hover_box.position = center
