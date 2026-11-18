@tool
extends Control
## The Forge 3D view: camera navigation, view cube, grid and origin, body display styles, hover
## and selection highlights, window / freeform / paint selection, command handles, analyses, and
## canvases and decals.
##
## Mouse: Shift + middle-drag orbits, middle-drag pans, the wheel zooms at the cursor, left
## clicks select, left-drag on empty space selects by region, right-click opens the marking menu.
##
## Assemblies (spec C7): set_body_poses() moves each body's holder to its pose; whatever is drawn
## for a body (its surface and lines, analyses, decals, section caps, highlights) follows it, and
## picking tests the body where it is shown while picks keep modelled points. set_modelled_view()
## shows every body where it was modelled (while a feature tool is open). Glyphs are drawn by an
## outside drawer on one layer over the view (glyph_layer(), set_glyph_drawer()); dof_handles()
## places a joint's rings and two-way arrows as handles; set_ghost_bodies() draws start ghosts.

const PICKING := preload("res://addons/holo_forge/core/picking.gd")
const XFORM := preload("res://addons/holo_forge/core/assembly/xform64.gd")
const ASSEMBLY_DATA := preload("res://addons/holo_forge/core/assembly/assembly_data.gd")
const TESSELLATE := preload("res://addons/holo_forge/core/tessellate.gd")
const MANIPULATOR := preload("res://addons/holo_forge/core/manipulator_math.gd")
const ANALYSIS := preload("res://addons/holo_forge/core/analysis.gd")
const SECTION_EDGES_SHADER := preload("res://addons/holo_forge/render/section_edges.gdshader")
const SURFACE_BODY_SHADER := preload("res://addons/holo_forge/render/surface_body.gdshader")
const BACKGROUND_SHADER := preload("res://addons/holo_forge/render/forge_background.gdshader")
const VIEW_CUBE := preload("res://addons/holo_forge/ui/view_cube.gd")
const FORGE_THEME := preload("res://addons/holo_forge/ui/forge_theme.gd")
const MESH_DISPLAY := preload("res://addons/holo_forge/ui/mesh_display.gd")

signal pick_clicked(pick: Dictionary, shift: bool, ctrl: bool)
signal region_selected(picks: Array, additive: bool)
signal paint_picked(pick: Dictionary)
signal hover_changed(pick: Dictionary)
signal context_requested(screen_position: Vector2)
signal manipulator_changed(handle: Dictionary, value: Variant)
signal manipulator_released(handle: Dictionary)
signal camera_changed

enum NavMode { SELECT, ORBIT, PAN, ZOOM }

const STYLES := {
	"shaded": "Shaded",
	"shaded_edges": "Shaded with Visible Edges",
	"hidden_edges": "Shaded with Hidden Edges",
	"wireframe": "Wireframe",
}
const FOV := 40.0
const PICK_RADIUS_PX := 6.0
const DRAG_START_PX := 5.0
const HOME_YAW := PI * 0.25
const HOME_PITCH := -0.52
## A DOF ring handle's radius and a two-way arrow's half length on screen, and how near the cursor
## must be to grab one.
const RING_PX := 60.0
const SLIDE_PX := 70.0
const DOF_GRAB_PX := 8.0
## The node name of the glyph layer (spec C7.1).
const GLYPH_LAYER := "AssemblyGlyphs"

## (InputEventKey) -> bool; the workspace handles shortcuts and returns true when it used the key.
var key_handler: Callable
## (InputEventMouse) -> bool; when set (sketch mode), it sees left clicks, drags and hover first.
var mouse_handler: Callable
## (Control) -> void; draws extra overlay content (sketch geometry) after the built-in overlay.
var draw_handler: Callable
var filters := {"body": true, "face": true, "edge": true, "vertex": true}
var priority := "default"
var select_mode := "window"
var select_through := false
var nav_mode := NavMode.SELECT
var style := "shaded_edges"
var grid_visible := true
## Meters per document unit (0.001 for mm); sets the grid spacing.
var unit_scale := 0.001
## Snap step for dragging point handles (meters); 0 disables.
var snap_step := 0.0
var handles: Array[Dictionary] = []

var target := Vector3.ZERO
var yaw := HOME_YAW
var pitch := HOME_PITCH
var distance := 0.4
var ortho := false

var _viewport: SubViewport
var _camera: Camera3D
var _overlay: Control
var _world: Node3D
var _bodies_root: Node3D
var _highlight_root: Node3D
var _grid: MeshInstance3D
var _grid_key := ""
var _origin_root: Node3D
var _origin_nodes := {}
var _view_cube: Control
var _nav_bar: HBoxContainer
## The Orbit, Pan and Zoom toggles by NavMode.
var _nav_buttons := {}
var _style_menu: MenuButton

var _extra_root: Node3D
var _analysis_root: Node3D
var _command_root: Node3D
## The open Form environment's meshes (set_form_meshes), by key.
var _form_root: Node3D
var _form_nodes := {}
var _canvas_root: Node3D
var _decal_root: Node3D
## Analysis points drawn on the overlay: [{"position", "color", "label"}].
var _analysis_points: Array = []
## The reflection probe an Environment Map analysis adds (null when none shows).
var _reflection_probe: ReflectionProbe
## The "version" of the analysis display the lines, meshes, points and probe were made for (-1:
## none given).
var _analysis_version := -1
var _body_nodes := {}
var _prepared := {}
var _pickable: Array = []
var _selected: Array = []
var _hover := {}
var _drag := {}
var _materials := {}
## section_highlight.gdshader drawn from behind (a sectioned surface's back), made when first needed.
var _section_highlight_back: Shader
## Mesh bodies' own looks (ui/mesh_display.gd): face group colours, borders, open edges, the
## selection and hover overlays. Recoloured with the view (apply_theme).
var mesh_display: RefCounted = MESH_DISPLAY.new()
## Draws mesh bodies' triangle edges faintly (the Mesh workspace's Select Triangles mode); set
## before set_bodies.
var mesh_wire := false
## The last window or freeform selection drawn: {"rect": Rect2, "outline": PackedVector2Array
## (freeform), "freeform", "crossing", "shift", "ctrl"}. Set just before region_selected.
var last_region := {}
## Mesh bodies' open edges as point pairs (body id -> PackedVector3Array), drawn wide on the
## overlay, and the screen lines made of them for the camera as it stands.
var _boundary_segments := {}
var _boundary_lines := PackedVector2Array()
var _boundary_lines_valid := false
## Highlight meshes of mesh bodies' triangles, kept while the bodies stay.
var _mesh_highlights := {}
## The palette the view is drawn in (forge_theme.gd; apply_theme changes it).
var theme_colors := FORGE_THEME.palette("light")
## True while a sketch is open: bodies take the palette's sketch_dim (see set_sketch_dim).
var sketch_dimmed := false
var _sky_material: ShaderMaterial
var _origin_point_material: StandardMaterial3D
## The grid's [minor, major] line colours as last drawn.
var _grid_colors: Array[Color] = []
## True while every body shows where it was modelled (set_modelled_view), whatever its pose.
var modelled_view := false
## The poses set_body_poses() gave: body id -> Transform3D (only those that are not identity).
var _body_poses := {}
## The glyph layer over the view and what draws on it (set_glyph_drawer).
var _glyph_layer: Control
var _glyph_drawer := Callable()
## Start ghosts of bodies (set_ghost_bodies) and their material.
var _ghost_root: Node3D
var _ghost_material: StandardMaterial3D


func _init() -> void:
	clip_contents = true
	focus_mode = Control.FOCUS_NONE
	mouse_filter = Control.MOUSE_FILTER_PASS
	_make_materials()
	_ghost_material = StandardMaterial3D.new()
	_ghost_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ghost_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ghost_material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	_ghost_material.cull_mode = BaseMaterial3D.CULL_DISABLED

	var container := SubViewportContainer.new()
	container.stretch = true
	container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(container)
	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_viewport.msaa_3d = Viewport.MSAA_4X
	# The background gradient is long and shallow: dithered, it shows no bands.
	_viewport.use_debanding = true
	_viewport.handle_input_locally = false
	container.add_child(_viewport)

	_world = Node3D.new()
	_world.name = "ForgeWorld"
	_world.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_viewport.add_child(_world)
	_camera = Camera3D.new()
	_camera.fov = FOV
	_camera.near = 0.0005
	_camera.far = 2000.0
	_world.add_child(_camera)
	var head_light := DirectionalLight3D.new()
	head_light.light_energy = 0.85
	head_light.rotation = Vector3(-0.35, 0.3, 0)
	_camera.add_child(head_light)
	var top_light := DirectionalLight3D.new()
	top_light.light_energy = 0.35
	top_light.rotation = Vector3(-PI * 0.5, 0, 0)
	_world.add_child(top_light)
	var env := WorldEnvironment.new()
	env.environment = _make_environment()
	_world.add_child(env)
	_viewport.size_changed.connect(_update_background_height)
	_update_background_height()

	_bodies_root = Node3D.new()
	_world.add_child(_bodies_root)
	_highlight_root = Node3D.new()
	_world.add_child(_highlight_root)
	_analysis_root = Node3D.new()
	_world.add_child(_analysis_root)
	_command_root = Node3D.new()
	_world.add_child(_command_root)
	_form_root = Node3D.new()
	_form_root.name = "FormMeshes"
	_world.add_child(_form_root)
	_canvas_root = Node3D.new()
	_world.add_child(_canvas_root)
	_decal_root = Node3D.new()
	_world.add_child(_decal_root)
	_grid = MeshInstance3D.new()
	_grid.material_override = _materials.grid
	_grid.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_world.add_child(_grid)
	_origin_root = Node3D.new()
	_world.add_child(_origin_root)
	_build_origin()

	_overlay = Control.new()
	_overlay.name = "Overlay"
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.focus_mode = Control.FOCUS_ALL
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_overlay.gui_input.connect(_overlay_input)
	_overlay.draw.connect(_draw_overlay)
	_overlay.mouse_exited.connect(func() -> void: _set_hover({}))
	add_child(_overlay)

	_view_cube = VIEW_CUBE.new()
	_view_cube.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_view_cube.position = Vector2(-_view_cube.size.x - 8, 8)
	_view_cube.view_requested.connect(func(d: Vector3) -> void: look_from(d))
	_view_cube.orbit_dragged.connect(func(delta: Vector2) -> void: orbit(delta))
	_view_cube.home_requested.connect(home)
	add_child(_view_cube)

	_nav_bar = _make_nav_bar()
	add_child(_nav_bar)
	apply_theme(theme_colors)
	_update_camera()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and _nav_bar != null:
		_nav_bar.reset_size()
		_nav_bar.position = Vector2((size.x - _nav_bar.size.x) * 0.5, size.y - _nav_bar.size.y - 8)
		_view_cube.position = Vector2(size.x - _view_cube.size.x - 8, 8)


func overlay() -> Control:
	return _overlay


func camera() -> Camera3D:
	return _camera


# --- Bodies and highlights ---------------------------------------------------------------

## entries: [{"id", "tess", "visible", "selectable", "surface"?, "mesh"?}]. Rebuilds the displayed
## bodies. "mesh" (APPEARANCE.build_mesh, materials on its surfaces) replaces the plain shaded
## surface; "surface" (a surface body) draws it two-sided in the surface colors.
func set_bodies(entries: Array) -> void:
	for child in _bodies_root.get_children():
		child.queue_free()
	_body_nodes.clear()
	_prepared.clear()
	_pickable.clear()
	_boundary_segments.clear()
	_boundary_lines_valid = false
	_mesh_highlights.clear()
	for entry in entries:
		var tess: Dictionary = entry.tess
		var prepared := PICKING.prepare(entry.id, tess)
		_prepared[entry.id] = prepared
		# A mesh body (triangles and face groups): its own surface colour, and its lines are group
		# borders and open edges, each in its colour.
		var is_mesh := prepared.has(PICKING.MESH_KEY)
		var holder := Node3D.new()
		holder.name = entry.id
		holder.visible = entry.get("visible", true)
		# (Bodies shown anew keep the pose their id last had, until the next set_body_poses.)
		holder.transform = _shown_pose(entry.id)
		PICKING.set_pose(prepared, holder.transform)
		_bodies_root.add_child(holder)
		var surface := MeshInstance3D.new()
		if entry.has("mesh"):
			surface.mesh = entry.mesh
		elif is_mesh:
			surface.mesh = TESSELLATE.surface_mesh(tess)
			surface.material_override = mesh_display.materials.surface_open if entry.get("surface", false) else mesh_display.materials.surface
		else:
			surface.mesh = TESSELLATE.surface_mesh(tess)
			surface.material_override = _materials.surface_body if entry.get("surface", false) else _materials.surface
		holder.add_child(surface)
		var edges := MeshInstance3D.new()
		edges.mesh = MESH_DISPLAY.border_mesh(tess) if is_mesh else TESSELLATE.edge_mesh(tess)
		edges.material_override = mesh_display.materials.border if is_mesh else _materials.edge
		edges.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		holder.add_child(edges)
		var hidden := MeshInstance3D.new()
		hidden.mesh = edges.mesh
		hidden.material_override = _materials.hidden_edge
		hidden.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		holder.add_child(hidden)
		_body_nodes[entry.id] = {"holder": holder, "surface": surface, "edges": edges, "hidden": hidden,
			"base_mesh": surface.mesh, "base_material": surface.material_override, "sectioned": false,
			"two_sided": bool(entry.get("surface", false)), "mesh": is_mesh}
		if is_mesh:
			var boundary := MeshInstance3D.new()
			boundary.mesh = MESH_DISPLAY.boundary_mesh(tess)
			boundary.material_override = mesh_display.materials.boundary
			boundary.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			holder.add_child(boundary)
			_body_nodes[entry.id]["boundary"] = boundary
			if holder.visible:
				var segments := MESH_DISPLAY.boundary_segments(tess)
				if not segments.is_empty():
					_boundary_segments[entry.id] = segments
			if mesh_wire:
				var wire := MeshInstance3D.new()
				wire.mesh = MESH_DISPLAY.wire_mesh(tess)
				wire.material_override = mesh_display.materials.wire
				wire.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				holder.add_child(wire)
				_body_nodes[entry.id]["wire"] = wire
		if entry.get("visible", true) and entry.get("selectable", true):
			_pickable.append(prepared)
	_apply_style()
	_refresh_highlights()


## The material mesh bodies are drawn in (appearance meshes use it for groups without one).
func mesh_surface_material(open := false) -> Material:
	return mesh_display.materials.surface_open if open else mesh_display.materials.surface


## A displayed mesh body's open-edge and group-border line nodes ({} for another body).
func mesh_line_nodes(body_id: String) -> Dictionary:
	var nodes: Dictionary = _body_nodes.get(body_id, {})
	return {"border": nodes.edges, "boundary": nodes.boundary} if bool(nodes.get("mesh", false)) else {}


## The default body material (appearance meshes use it for faces without an appearance).
func surface_material() -> Material:
	return _materials.surface


## The default material of surface bodies (two-sided, front and back in different colors).
func surface_body_material() -> Material:
	return _materials.surface_body


## A displayed body's surface node (null when the body isn't shown).
func body_surface(body_id: String) -> MeshInstance3D:
	return (_body_nodes.get(body_id, {}) as Dictionary).get("surface")


# --- Assembly poses (spec C7) -------------------------------------------------------------------

## Moves every body to its pose from an assembly solve (core/assembly/solver.gd solve() output,
## C3.1): each holder's transform becomes to_transform(body_poses[id]); a body the solve doesn't
## list shows where it was modelled. Everything drawn for a body follows it (it lives under the
## holder, or is a follower node: decals, section caps, analysis lines, highlights). While the
## modelled view is on, the poses are kept and shown once it goes off.
func set_body_poses(solve: Dictionary) -> void:
	_body_poses.clear()
	var given: Variant = solve.get("body_poses", {})
	if given is Dictionary:
		for id in given:
			var pose: Variant = given[id]
			var t := Transform3D.IDENTITY
			if pose is PackedFloat64Array and (pose as PackedFloat64Array).size() == 12:
				t = XFORM.to_transform(pose)
			elif pose is Transform3D:
				t = pose
			if t != Transform3D.IDENTITY:
				_body_poses[str(id)] = t
	_apply_poses()


## Shows every body where it was modelled (on) or at its pose (off), keeping the poses.
func set_modelled_view(on: bool) -> void:
	if modelled_view == on:
		return
	modelled_view = on
	_apply_poses()


## The node a body's surface, lines, analyses and decals hang under (null when it isn't shown).
func body_holder(body_id: String) -> Node3D:
	return (_body_nodes.get(body_id, {}) as Dictionary).get("holder")


## Where a body is shown now: its pose, or identity (not posed, or the modelled view is on).
func body_pose(body_id: String) -> Transform3D:
	return _shown_pose(body_id)


## The pose set_body_poses() gave a body (identity when none), whether or not it shows.
func stored_body_pose(body_id: String) -> Transform3D:
	return _body_poses.get(body_id, Transform3D.IDENTITY)


## True when some body shows away from where it was modelled.
func is_posed() -> bool:
	return not modelled_view and not _body_poses.is_empty()


## True when the last poses move some body, whether or not they show now.
func has_poses() -> bool:
	return not _body_poses.is_empty()


## A body's modelled point where it is shown now.
func world_point(body_id: String, point: Vector3) -> Vector3:
	return _shown_pose(body_id) * point


## The pickable bodies (PICKING.prepare entries, with their poses) the view picks from.
func pickable_bodies() -> Array:
	return _pickable


## The nodes outside a body's holder that follow it (decals, section caps, analysis lines,
## highlights), for tests.
func follower_nodes(body_id: String) -> Array:
	var found := []
	for root: Node in [_decal_root, _analysis_root, _highlight_root]:
		for child in root.get_children():
			if not child.is_queued_for_deletion() and str(child.get_meta("follow_body", "")) == body_id:
				found.append(child)
	return found


func _shown_pose(body_id: String) -> Transform3D:
	return Transform3D.IDENTITY if modelled_view else _body_poses.get(body_id, Transform3D.IDENTITY)


## Makes node follow a body: shown at the body's pose times local ("" body: stays at local).
func _follow(node: Node3D, body_id: String, local: Transform3D) -> void:
	if body_id == "":
		node.transform = local
		return
	node.set_meta("follow_body", body_id)
	node.set_meta("follow_local", local)
	node.transform = _shown_pose(body_id) * local


## Puts every holder, pickable body, follower and section plane where its body shows now.
func _apply_poses() -> void:
	for id in _body_nodes:
		var t := _shown_pose(id)
		var nodes: Dictionary = _body_nodes[id]
		var holder: Node3D = nodes.holder
		if holder.transform != t:
			holder.transform = t
		var prepared: Dictionary = _prepared.get(id, {})
		if not prepared.is_empty():
			PICKING.set_pose(prepared, t)
		if nodes.get("section_source") != null:
			_pose_section(id)
	for root: Node in [_decal_root, _analysis_root, _highlight_root]:
		for child in root.get_children():
			if child.has_meta("follow_body"):
				(child as Node3D).transform = _shown_pose(str(child.get_meta("follow_body"))) * (child.get_meta("follow_local", Transform3D.IDENTITY) as Transform3D)
				if child.has_meta("clip"):
					_place_clip(child)
	_boundary_lines_valid = false
	if _overlay != null:
		_overlay.queue_redraw()
	if _glyph_layer != null:
		_glyph_layer.queue_redraw()


## A sectioned body's clip plane where the body shows: the section's plane (in the body's modelled
## space, as picking uses it) carried by the pose, on a copy of the section's material so other
## bodies keep theirs; the body's edges are clipped the same way.
func _pose_section(body_id: String) -> void:
	var nodes: Dictionary = _body_nodes[body_id]
	var source: Material = nodes.get("section_source")
	var plane := _section_plane(source)
	if plane.is_empty():
		return
	var t := _shown_pose(body_id)
	var origin: Vector3 = t * (plane.origin as Vector3)
	var normal: Vector3 = (t.basis * (plane.normal as Vector3)).normalized()
	var surface: MeshInstance3D = nodes.surface
	if t == Transform3D.IDENTITY:
		surface.material_override = source
	else:
		var posed: ShaderMaterial = nodes.get("section_posed")
		if posed == null or nodes.get("section_posed_from") != source:
			posed = source.duplicate() as ShaderMaterial
			nodes["section_posed"] = posed
			nodes["section_posed_from"] = source
		posed.set_shader_parameter("plane_origin", origin)
		posed.set_shader_parameter("plane_normal", normal)
		surface.material_override = posed
	var edges := (nodes.edges as MeshInstance3D).material_override as ShaderMaterial
	if edges != null and edges.shader == SECTION_EDGES_SHADER:
		edges.set_shader_parameter("plane_origin", origin)
		edges.set_shader_parameter("plane_normal", normal)


## Draws start ghosts (spec 6.2): [{"body": id, "transform": Transform3D}] shows each body's
## surface there in assembly_ghost, unshaded and without depth writes. [] removes them.
func set_ghost_bodies(entries: Array) -> void:
	if _ghost_root == null:
		_ghost_root = Node3D.new()
		_ghost_root.name = "AssemblyGhosts"
		_world.add_child(_ghost_root)
	for child in _ghost_root.get_children():
		child.queue_free()
	for entry in entries:
		var nodes: Dictionary = _body_nodes.get(str(entry.get("body", "")), {})
		if nodes.is_empty():
			continue
		var ghost := MeshInstance3D.new()
		ghost.mesh = nodes.base_mesh
		ghost.material_override = _ghost_material
		ghost.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		ghost.transform = entry.get("transform", Transform3D.IDENTITY)
		_ghost_root.add_child(ghost)


## How many start ghosts show (for tests).
func ghost_count() -> int:
	return _live_children(_ghost_root, false) if _ghost_root != null else 0


## The layer glyphs are drawn on (a Control named AssemblyGlyphs over the view, made when first
## asked for): it draws with the drawer set_glyph_drawer() gave and redraws with the view.
func glyph_layer() -> Control:
	if _glyph_layer == null:
		_glyph_layer = Control.new()
		_glyph_layer.name = GLYPH_LAYER
		_glyph_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_glyph_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_glyph_layer.draw.connect(func() -> void:
			if _glyph_drawer.is_valid():
				_glyph_drawer.call(_glyph_layer))
		_overlay.add_child(_glyph_layer)
	return _glyph_layer


## (Control) -> void: draws the glyphs on the glyph layer.
func set_glyph_drawer(drawer: Callable) -> void:
	_glyph_drawer = drawer
	glyph_layer().queue_redraw()


## The handles that drive a joint's DOFs (Drive, and dragging a jointed component; spec 1.2 #9):
## a "ring" about the axis of each rotation and a two-way "slide" arrow along the axis of each
## slide, at the joint frame world (C3.1 "world", as a Transform3D). values: the DOFs' values now
## (each handle's "base"). Each handle: {"type", "joint", "dof" (its index), "dof_name", "origin",
## "axis" (ring) or "direction" (slide), "base"}. Give them to set_handles; a drag emits
## manipulator_changed(handle, base + the turn or travel since the press), unclamped (radians or
## meters; rings keep counting past a full turn).
func dof_handles(joint_id: String, world: Transform3D, joint_type: String, values: PackedFloat64Array, slide_axis := "z") -> Array[Dictionary]:
	var handles_out: Array[Dictionary] = []
	var names: Array = ASSEMBLY_DATA.DOF_NAMES.get(joint_type, [])
	var columns := {"x": world.basis.x, "y": world.basis.y, "z": world.basis.z}
	for i in names.size():
		var dof_name := str(names[i])
		var handle := {"joint": joint_id, "dof": i, "dof_name": dof_name, "origin": world.origin, "base": values[i] if i < values.size() else 0.0}
		if dof_name.begins_with("rot_"):
			handle["type"] = "ring"
			handle["axis"] = (columns[dof_name.trim_prefix("rot_")] as Vector3).normalized()
		else:
			var axis := dof_name.trim_prefix("slide_") if dof_name != "slide" else slide_axis
			handle["type"] = "slide"
			handle["direction"] = (columns.get(axis, world.basis.z) as Vector3).normalized()
		handles_out.append(handle)
	return handles_out


## Shows analyses (merged ANALYSIS.build output): "body_meshes" and "body_materials" replace a
## body's mesh and material while shown, "lines" are polylines, "meshes" extra geometry (section
## caps), "points" labelled markers on the overlay, "reflection_probe" (AABB, Environment Map) a
## reflection probe over the model. {} shows none. "version" (int, optional): when it is the one
## last shown, the lines, meshes, points and probe stay as they are and only the bodies' meshes
## and materials are set again (bodies shown anew, as a command's preview, need them).
func set_analysis_display(display: Dictionary) -> void:
	var meshes: Dictionary = display.get("body_meshes", {})
	var materials: Dictionary = display.get("body_materials", {})
	var clips_changed := false
	for id in _body_nodes:
		var nodes: Dictionary = _body_nodes[id]
		var surface: MeshInstance3D = nodes.surface
		surface.mesh = meshes.get(id, nodes.base_mesh)
		var material: Material = materials.get(id, nodes.base_material)
		surface.material_override = material
		# A section hides the cut-away side of the body's edges too.
		var plane := _section_plane(material)
		if not plane.is_empty():
			_color_section(material)
		nodes.sectioned = not plane.is_empty()
		# (The section's own material, its plane in the body's modelled space; a posed body is drawn
		# with a copy whose plane is carried by the pose, _pose_section.)
		nodes["section_source"] = material if not plane.is_empty() else null
		# ...and picking, hover and highlights skip it (the _pickable entries are these dictionaries).
		var prepared: Dictionary = _prepared.get(id, {})
		if prepared.get("clip", {}) != plane:
			clips_changed = true
			if plane.is_empty():
				prepared.erase("clip")
			elif not prepared.is_empty():
				prepared["clip"] = plane
		var edges: MeshInstance3D = nodes.edges
		if plane.is_empty():
			edges.material_override = _materials.edge
		else:
			var clip := ShaderMaterial.new()
			clip.shader = SECTION_EDGES_SHADER
			clip.set_shader_parameter("plane_origin", plane.origin)
			clip.set_shader_parameter("plane_normal", plane.normal)
			clip.set_shader_parameter("color", theme_colors.edge)
			edges.material_override = clip
			# A posed body: its clip plane where it shows.
			_pose_section(id)
	if clips_changed:
		_refresh_highlights()
	var version := int(display.get("version", -1))
	if version >= 0 and version == _analysis_version:
		_apply_style()
		return
	_analysis_version = version
	for child in _analysis_root.get_children():
		child.queue_free()
	# Lines are drawn as one mesh per body they name ("body", optional: they follow that body's
	# pose) and one for the rest.
	var points_by_body := {}
	var colors_by_body := {}
	for line in display.get("lines", []):
		var body_id := str(line.get("body", ""))
		var points: PackedVector3Array = points_by_body.get(body_id, PackedVector3Array())
		var colors: PackedColorArray = colors_by_body.get(body_id, PackedColorArray())
		var polyline: PackedVector3Array = line.points
		for i in range(1, polyline.size()):
			points.append(polyline[i - 1])
			points.append(polyline[i])
			colors.append(line.color)
			colors.append(line.color)
		points_by_body[body_id] = points
		colors_by_body[body_id] = colors
	for body_id in points_by_body:
		var points: PackedVector3Array = points_by_body[body_id]
		if points.is_empty():
			continue
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = points
		arrays[Mesh.ARRAY_COLOR] = colors_by_body[body_id]
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
		var node := MeshInstance3D.new()
		node.mesh = mesh
		node.material_override = _materials.analysis_line
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_follow(node, str(body_id), Transform3D.IDENTITY)
		_analysis_root.add_child(node)
	for entry in display.get("meshes", []):
		var node := MeshInstance3D.new()
		node.mesh = entry.mesh
		node.material_override = entry.get("material")
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# (Section caps name their body: they move with it.)
		_follow(node, str(entry.get("body", "")), Transform3D.IDENTITY)
		_analysis_root.add_child(node)
	_analysis_points = (display.get("points", []) as Array).duplicate()
	_set_reflection_probe(display.get("reflection_probe"))
	_apply_style()
	_overlay.queue_redraw()


## The Environment Map's reflection probe (null when none shows), for tests.
func reflection_probe() -> ReflectionProbe:
	return _reflection_probe


## Replaces the reflection probe with one covering box (an AABB, with a margin), or removes it.
## A new probe renders once, so it picks up the bodies as they are now.
func _set_reflection_probe(box: Variant) -> void:
	if _reflection_probe != null:
		_reflection_probe.get_parent().remove_child(_reflection_probe)
		_reflection_probe.queue_free()
		_reflection_probe = null
	if not box is AABB:
		return
	var bounds: AABB = box
	bounds = bounds.grow(maxf(bounds.size.length() * 0.25, 0.01))
	var probe := ReflectionProbe.new()
	probe.name = "EnvironmentMapProbe"
	probe.position = bounds.get_center()
	probe.size = bounds.size
	probe.max_distance = bounds.size.length() * 4.0
	probe.update_mode = ReflectionProbe.UPDATE_ONCE
	probe.enable_shadows = false
	_world.add_child(probe)
	_reflection_probe = probe


## What analyses add to the view now (for tests): {"nodes": line and extra mesh nodes,
## "points": overlay markers}.
func analysis_counts() -> Dictionary:
	var nodes := 0
	for child in _analysis_root.get_children():
		if not child.is_queued_for_deletion():
			nodes += 1
	return {"nodes": nodes, "points": _analysis_points.size()}


## {"origin", "normal"} when material is a section analysis' clip material, else {}.
static func _section_plane(material: Material) -> Dictionary:
	var shader_material := material as ShaderMaterial
	if shader_material == null or shader_material.shader != ANALYSIS.SECTION_SHADER:
		return {}
	return {"origin": shader_material.get_shader_parameter("plane_origin"), "normal": shader_material.get_shader_parameter("plane_normal")}


## Replaces the meshes a running command shows (interference overlaps): [{"mesh", "material"}].
func set_command_meshes(entries: Array) -> void:
	for child in _command_root.get_children():
		child.queue_free()
	for entry in entries:
		var node := MeshInstance3D.new()
		node.mesh = entry.mesh
		node.material_override = entry.get("material")
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_command_root.add_child(node)


## How many meshes the running command shows (for tests).
func command_mesh_count() -> int:
	return _live_children(_command_root, false)


## Replaces the Form environment's meshes, reusing MeshInstance3D nodes by key: [{"key": String,
## "mesh": Mesh, "material": Material, "visible": bool}]. Keys not listed go. No shadows; form
## bodies are never dimmed by an open sketch.
func set_form_meshes(entries: Array) -> void:
	var keep := {}
	for entry in entries:
		var key := str(entry.get("key", ""))
		if key == "":
			continue
		var node: MeshInstance3D = _form_nodes.get(key)
		if node == null or not is_instance_valid(node):
			node = MeshInstance3D.new()
			node.name = key.validate_node_name()
			node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			_form_root.add_child(node)
			_form_nodes[key] = node
		node.mesh = entry.get("mesh")
		node.material_override = entry.get("material")
		node.visible = bool(entry.get("visible", true))
		keep[key] = true
	for key in _form_nodes.keys():
		if not keep.has(key):
			var node: MeshInstance3D = _form_nodes[key]
			if is_instance_valid(node):
				_form_root.remove_child(node)
				node.queue_free()
			_form_nodes.erase(key)


## Swaps one Form mesh in place (drag updates) without touching the others.
func update_form_mesh(key: String, mesh: Mesh) -> void:
	var node: MeshInstance3D = _form_nodes.get(key)
	if node != null and is_instance_valid(node):
		node.mesh = mesh


## The Form meshes shown now: key -> MeshInstance3D (for tests and the editor).
func form_meshes() -> Dictionary:
	return _form_nodes.duplicate()


## Shows canvases (reference images on planes; view only): [{"texture", "origin", "x", "y"
## (unit plane axes), "size": Vector2 meters, "opacity", "through" (drawn over bodies), "visible"}].
func set_canvases(entries: Array) -> void:
	for child in _canvas_root.get_children():
		child.queue_free()
	for entry in entries:
		var quad := QuadMesh.new()
		quad.size = Vector2.ONE
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		material.albedo_color = Color(1, 1, 1, float(entry.get("opacity", 0.5)))
		material.albedo_texture = entry.get("texture")
		material.no_depth_test = bool(entry.get("through", false))
		var node := MeshInstance3D.new()
		node.mesh = quad
		node.material_override = material
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var x: Vector3 = entry.get("x", Vector3.RIGHT)
		var y: Vector3 = entry.get("y", Vector3.FORWARD)
		var size: Vector2 = entry.get("size", Vector2.ONE)
		# QuadMesh lies in its XY plane with the image's top toward +Y.
		node.transform = Transform3D(Basis(x * maxf(size.x, 1e-6), y * maxf(size.y, 1e-6), x.cross(y)), entry.get("origin", Vector3.ZERO))
		node.visible = bool(entry.get("visible", true))
		_canvas_root.add_child(node)


## Shows decals as Godot Decal nodes (as baked): [{"transform", "size": Vector3, "texture",
## "visible", "body" (optional)}]; transforms are in the body's modelled coordinates, and a decal
## that names its body moves with it.
func set_decals(entries: Array) -> void:
	for child in _decal_root.get_children():
		child.queue_free()
	for entry in entries:
		var decal := Decal.new()
		_follow(decal, str(entry.get("body", "")), entry.get("transform", Transform3D.IDENTITY))
		decal.size = entry.get("size", Vector3.ONE * 0.01)
		decal.texture_albedo = entry.get("texture")
		decal.normal_fade = 0.3
		decal.visible = bool(entry.get("visible", true))
		_decal_root.add_child(decal)


## Shown canvases and decals (for tests): {"canvases", "decals"}.
func image_counts() -> Dictionary:
	return {"canvases": _live_children(_canvas_root, true), "decals": _live_children(_decal_root, true)}


static func _live_children(root: Node, visible_only: bool) -> int:
	var count := 0
	for child in root.get_children():
		if not child.is_queued_for_deletion() and (not visible_only or (child as Node3D).visible):
			count += 1
	return count


func bodies_aabb() -> AABB:
	var result := AABB()
	var first := true
	for id in _prepared:
		var holder: Node3D = _body_nodes[id].holder
		if not holder.visible:
			continue
		var box: AABB = _shown_pose(id) * (_prepared[id].aabb as AABB)
		result = box if first else result.merge(box)
		first = false
	# The open form's bodies (their surfaces or cage faces) count too.
	for key in _form_nodes:
		var node: MeshInstance3D = _form_nodes[key]
		if not is_instance_valid(node) or not node.visible or node.mesh == null or not (str(key).ends_with("/surface") or str(key).ends_with("/box")):
			continue
		var box := node.mesh.get_aabb()
		if box.size == Vector3.ZERO and box.position == Vector3.ZERO:
			continue
		result = box if first else result.merge(box)
		first = false
	return result if not first else AABB(Vector3(-0.05, 0, -0.05), Vector3(0.1, 0.05, 0.1))


## picks: the selection; hover: the item under the cursor ({} for none).
func set_highlights(picks: Array, hover: Dictionary) -> void:
	_selected = picks.duplicate()
	_hover = hover
	_refresh_highlights()


func set_style(value: String) -> void:
	style = value
	_apply_style()


func set_origin_visibility(visibility: Dictionary) -> void:
	for key in _origin_nodes:
		(_origin_nodes[key] as Node3D).visible = bool(visibility.get(key, true))


func set_grid_visible(value: bool) -> void:
	grid_visible = value
	_grid.visible = value


# --- Appearance ------------------------------------------------------------------------------

## Draws the view in a palette (forge_theme.gd): its background, grid, origin, the bodies' default
## colours, edges and highlights, the view cube and the navigation bar. Nothing is rebuilt: the
## materials the bodies share change in place.
func apply_theme(palette: Dictionary) -> void:
	theme_colors = palette.duplicate(true)
	_sky_material.set_shader_parameter("top_color", theme_colors.view_top)
	_sky_material.set_shader_parameter("bottom_color", theme_colors.view_bottom)
	_ghost_material.albedo_color = theme_colors.get("assembly_ghost", Color(0.6, 0.8, 1.0, 0.25))
	mesh_display.apply_theme(theme_colors)
	_color_bodies()
	(_materials.edge as StandardMaterial3D).albedo_color = theme_colors.edge
	(_materials.hidden_edge as StandardMaterial3D).albedo_color = theme_colors.hidden_edge
	for look in ["selected", "hover"]:
		var color: Color = theme_colors.select_face if look == "selected" else theme_colors.hover_face
		for key in [look, look + "_two_sided"]:
			var material := _materials[key] as StandardMaterial3D
			while material != null:
				material.albedo_color = color
				material = material.next_pass as StandardMaterial3D
	for id in _body_nodes:
		var clip := (_body_nodes[id].edges as MeshInstance3D).material_override as ShaderMaterial
		if clip != null and clip.shader == SECTION_EDGES_SHADER:
			clip.set_shader_parameter("color", theme_colors.edge)
	_color_origin()
	_grid_key = ""
	_update_grid()
	if _view_cube != null:
		_view_cube.apply_theme(theme_colors)
	if _nav_bar != null:
		_style_nav_bar()
	_refresh_highlights()


## Fades the bodies while a sketch is open (by the palette's sketch_dim: the dark palette's lit
## faces are as bright as its sketch lines), or brings them back.
func set_sketch_dim(on: bool) -> void:
	if sketch_dimmed == on:
		return
	sketch_dimmed = on
	_color_bodies()


## The bodies' default colour as drawn now (the palette's body, faded while a sketch is open).
func body_color() -> Color:
	return _dimmed(theme_colors.body)


func _dimmed(color: Color) -> Color:
	var dim := float(theme_colors.get("sketch_dim", 1.0)) if sketch_dimmed else 1.0
	return Color(color.r * dim, color.g * dim, color.b * dim, color.a)


## The default body colours, surface tints and section colours from the palette (and the fade).
func _color_bodies() -> void:
	(_materials.surface as StandardMaterial3D).albedo_color = body_color()
	# Mesh bodies fade with the others while a sketch is open (their face group colours too).
	for key in ["surface", "surface_open"]:
		(mesh_display.materials[key] as StandardMaterial3D).albedo_color = _dimmed(theme_colors.mesh_surface)
	var group_palette: Array = theme_colors.mesh_group_palette
	for i in MESH_DISPLAY.PALETTE_SIZE:
		mesh_display.group_material(i).albedo_color = _dimmed(group_palette[i % group_palette.size()])
	var surface_body: ShaderMaterial = _materials.surface_body
	surface_body.set_shader_parameter("front_color", _dimmed(theme_colors.surface_front))
	surface_body.set_shader_parameter("back_color", _dimmed(theme_colors.surface_back))
	for id in _body_nodes:
		var material: Material = (_body_nodes[id].surface as MeshInstance3D).material_override
		if not _section_plane(material).is_empty():
			_color_section(material)
		# (A posed body shows a copy of its section's material: the section's own one too.)
		var source: Material = _body_nodes[id].get("section_source")
		if source != null and source != material:
			_color_section(source)


## A section analysis' body takes the palette's body colour outside and section_inside within.
func _color_section(material: Material) -> void:
	var section := material as ShaderMaterial
	section.set_shader_parameter("base_color", body_color())
	section.set_shader_parameter("inside_color", _dimmed(theme_colors.section_inside))


## The background gradient as drawn now: [top, bottom].
func background_colors() -> Array[Color]:
	return [_sky_material.get_shader_parameter("top_color"), _sky_material.get_shader_parameter("bottom_color")]


## The grid's [minor, major] line colours as drawn now.
func grid_colors() -> Array[Color]:
	return _grid_colors.duplicate()


## The material body edges are drawn with (the view's own; baked bodies never use it).
func edge_material() -> StandardMaterial3D:
	return _materials.edge


func view_cube() -> Control:
	return _view_cube


func nav_bar() -> HBoxContainer:
	return _nav_bar


# --- Camera ----------------------------------------------------------------------------------

func orbit(delta_px: Vector2) -> void:
	yaw -= delta_px.x * 0.008
	pitch = clampf(pitch - delta_px.y * 0.008, -PI * 0.5 + 0.0005, PI * 0.5 - 0.0005)
	_update_camera()


func pan(delta_px: Vector2) -> void:
	var per_px := _world_per_pixel()
	var basis := _camera.global_transform.basis
	target += (-basis.x * delta_px.x + basis.y * delta_px.y) * per_px
	_update_camera()


## Zooms by steps (positive zooms in) keeping the point under screen_position fixed.
func zoom_at(steps: float, screen_position: Vector2) -> void:
	var factor := pow(0.87, steps)
	var anchor = MANIPULATOR.on_plane(target, _camera.global_transform.basis.z, _camera.project_ray_origin(screen_position), _camera.project_ray_normal(screen_position))
	distance = clampf(distance * factor, 0.0005, 500.0)
	if anchor != null:
		target = (anchor as Vector3).lerp(target, factor)
	_update_camera()


## Points the camera at target from direction (from the target toward the camera).
func look_from(direction: Vector3) -> void:
	var d := direction.normalized()
	yaw = atan2(d.x, d.z)
	pitch = -asin(clampf(d.y, -1.0, 1.0))
	pitch = clampf(pitch, -PI * 0.5 + 0.0005, PI * 0.5 - 0.0005)
	if absf(d.y) > 0.999:
		yaw = 0.0
	_update_camera()


## Looks straight at a face: the view direction becomes the face normal, centered on point.
func look_at_face(point: Vector3, normal: Vector3) -> void:
	target = point
	look_from(normal)


func home() -> void:
	yaw = HOME_YAW
	pitch = HOME_PITCH
	fit()


## Frames every visible body (or the origin when there are none).
func fit() -> void:
	var box := bodies_aabb()
	target = box.get_center()
	var radius := maxf(box.size.length() * 0.5, 0.005)
	distance = radius / sin(fit_half_angle(Vector2(_viewport.size))) * 1.15
	_update_camera()


## Half the narrower view angle, in radians: the camera's FOV is vertical, so a view narrower
## than it is tall sees less across than up and down, and Fit has to use that.
static func fit_half_angle(view_size: Vector2) -> float:
	var half := deg_to_rad(FOV) * 0.5
	if view_size.x <= 0.0 or view_size.y <= 0.0:
		return half
	return minf(half, atan(tan(half) * view_size.x / view_size.y))


func set_ortho(value: bool) -> void:
	ortho = value
	_update_camera()


func view_state() -> Dictionary:
	return {"target": target, "yaw": yaw, "pitch": pitch, "distance": distance, "ortho": ortho}


func set_view_state(state: Dictionary) -> void:
	target = state.get("target", target)
	yaw = float(state.get("yaw", yaw))
	pitch = float(state.get("pitch", pitch))
	distance = float(state.get("distance", distance))
	ortho = bool(state.get("ortho", ortho))
	_update_camera()


## Screen position of a world point (INF when behind the camera).
func project(point: Vector3) -> Vector2:
	if _camera.is_position_behind(point):
		return Vector2(INF, INF)
	return _camera.unproject_position(point)


func ray_from(screen_position: Vector2) -> Array:
	return [_camera.project_ray_origin(screen_position), _camera.project_ray_normal(screen_position)]


## The selectable item at a screen position, honoring filters and priority.
func pick_at(screen_position: Vector2) -> Dictionary:
	var ray := ray_from(screen_position)
	return PICKING.pick(_pickable, ray[0], ray[1], project, screen_position, filters, priority, PICK_RADIUS_PX, _is_visible)


func face_hit_at(screen_position: Vector2) -> Dictionary:
	var ray := ray_from(screen_position)
	return PICKING.ray_hit(_pickable, ray[0], ray[1])


## The outward normal of a face where the ray hit it.
func face_normal(body_id: String, face: int) -> Vector3:
	var prepared: Dictionary = _prepared.get(body_id, {})
	if prepared.is_empty():
		return Vector3.UP
	var tess: Dictionary = prepared.tess
	var face_ids: PackedInt32Array = tess.face_ids
	for t in face_ids.size():
		if face_ids[t] == face:
			var positions: PackedVector3Array = tess.positions
			var indices: PackedInt32Array = tess.indices
			var a := positions[indices[t * 3]]
			var b := positions[indices[t * 3 + 1]]
			var c := positions[indices[t * 3 + 2]]
			return (c - a).cross(b - a).normalized()
	return Vector3.UP


## Picks in a screen rectangle (used by window selection and tests).
func region_picks(rect: Rect2, crossing: bool) -> Array[Dictionary]:
	return PICKING.window_select(_pickable, project, rect.abs(), crossing, _region_kind(), _region_visible())


## The four sides of the view volume behind a screen rectangle, as Plane values whose normals
## point out of it (the form CadMesh.triangles_in_frustum takes, as Camera3D.get_frustum()), plus
## the plane through the camera that leaves out what lies behind it. [] for an empty rectangle.
func region_planes(rect: Rect2) -> Array:
	var box := rect.abs()
	if box.size.x < 1.0 or box.size.y < 1.0:
		return []
	# Screen corners clockwise on screen (y down): top left, top right, bottom right, bottom left.
	var corners := [box.position, Vector2(box.end.x, box.position.y), box.end, Vector2(box.position.x, box.end.y)]
	var origins := []
	var far := []
	for corner in corners:
		var from := _camera.project_ray_origin(corner)
		origins.append(from)
		far.append(from + _camera.project_ray_normal(corner))
	var inside: Vector3 = ((far[0] as Vector3) + (far[1] as Vector3) + (far[2] as Vector3) + (far[3] as Vector3)) * 0.25
	var planes := []
	for i in 4:
		var j := (i + 1) % 4
		var plane := Plane(origins[i], far[i], far[j])
		if plane.normal.is_zero_approx():
			# Orthographic: the corner rays are parallel, so the side holds both origins too.
			plane = Plane(origins[i], origins[j], far[j])
		if plane.normal.is_zero_approx():
			return []
		# The normal points away from the middle of the region.
		if plane.distance_to(inside) > 0.0:
			plane = -plane
		planes.append(plane)
	var forward := -_camera.global_transform.basis.z
	planes.append(Plane(-forward, _camera.global_position - forward * 1e-6) if not ortho else Plane(-forward, _camera.global_position - forward * _camera.far))
	return planes


## What the mouse is dragging in the view now: "" (nothing), "handle" (an arrow or another
## manipulator), "orbit", "pan", "zoom", "region", "paint", or a press that has not moved yet.
func drag_kind() -> String:
	return str(_drag.get("type", ""))


## The three corners of a stored triangle of a mesh body as it is shown ([] when there is none).
func mesh_triangle_points(body_id: String, triangle: int) -> PackedVector3Array:
	var prepared: Dictionary = _prepared.get(body_id, {})
	if prepared.is_empty() or not prepared.has(PICKING.MESH_KEY):
		return PackedVector3Array()
	var tess: Dictionary = prepared.tess
	var indices: PackedInt32Array = tess.get("indices", PackedInt32Array())
	var positions: PackedVector3Array = tess.get("positions", PackedVector3Array())
	if triangle < 0 or triangle * 3 + 2 >= indices.size():
		return PackedVector3Array()
	return PackedVector3Array([positions[indices[triangle * 3]], positions[indices[triangle * 3 + 1]], positions[indices[triangle * 3 + 2]]])


## The stored triangle of a mesh body under a screen position: {"body", "triangle", "group",
## "point", "normal"} or {}.
func mesh_hit_at(screen_position: Vector2) -> Dictionary:
	var hit := face_hit_at(screen_position)
	if hit.is_empty() or not bool(hit.get("mesh", false)):
		return {}
	return {"body": hit.body, "triangle": int(hit.triangle), "group": int(hit.face), "point": hit.point, "normal": hit.get("normal", Vector3.ZERO)}


func _update_camera() -> void:
	var basis := Basis.from_euler(Vector3(pitch, yaw, 0.0))
	_camera.transform = Transform3D(basis, target + basis.z * distance)
	if ortho:
		_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
		_camera.size = 2.0 * distance * tan(deg_to_rad(FOV) * 0.5)
	else:
		_camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	_camera.near = maxf(distance * 0.001, 0.00005)
	_camera.far = maxf(distance * 200.0, 10.0)
	if _view_cube != null:
		_view_cube.set_camera_basis(basis)
	_update_grid()
	_boundary_lines_valid = false
	if _overlay != null:
		_overlay.queue_redraw()
	if _glyph_layer != null:
		_glyph_layer.queue_redraw()
	camera_changed.emit()


func _world_per_pixel() -> float:
	var height := maxf(_viewport.size.y, 1.0)
	return 2.0 * distance * tan(deg_to_rad(FOV) * 0.5) / height


# --- Input -----------------------------------------------------------------------------------

func _overlay_input(event: InputEvent) -> void:
	var button := event as InputEventMouseButton
	# Sketch mode gets left clicks and plain moves first (navigation stays with the view). In Orbit,
	# Pan or Zoom a left press waits to see if it's a drag (see _left_press); plain moves still hover.
	if mouse_handler.is_valid() and str(_drag.get("type", "")) in ["", "pending"]:
		var is_left := button != null and button.button_index == MOUSE_BUTTON_LEFT and nav_mode == NavMode.SELECT
		var is_move := event is InputEventMouseMotion and ((event as InputEventMouseMotion).button_mask & (MOUSE_BUTTON_MASK_MIDDLE | MOUSE_BUTTON_MASK_RIGHT)) == 0
		if (is_left or is_move) and _handle_at((event as InputEventMouse).position).is_empty() and mouse_handler.call(event):
			if button != null and button.pressed:
				_overlay.grab_focus()
			_overlay.accept_event()
			_overlay.queue_redraw()
			return
	if button != null:
		_mouse_button(button)
		return
	var motion := event as InputEventMouseMotion
	if motion != null:
		_mouse_motion(motion)
		return
	var key := event as InputEventKey
	if key != null and key.pressed and key_handler.is_valid() and key_handler.call(key):
		_overlay.accept_event()


func _mouse_button(event: InputEventMouseButton) -> void:
	if event.pressed:
		_overlay.grab_focus()
	match event.button_index:
		MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN:
			if event.pressed:
				var steps := event.factor if event.factor > 0.0 else 1.0
				if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
					steps = -steps
				zoom_at(steps, event.position)
			_overlay.accept_event()
		MOUSE_BUTTON_MIDDLE:
			_drag = {"type": "orbit" if event.shift_pressed else "pan"} if event.pressed else {}
			_overlay.accept_event()
		MOUSE_BUTTON_RIGHT:
			if event.pressed:
				_drag = {"type": "right", "start": event.position}
			elif _drag.get("type", "") == "right":
				_drag = {}
				context_requested.emit(event.position)
			_overlay.accept_event()
		MOUSE_BUTTON_LEFT:
			_overlay.accept_event()
			if event.pressed:
				_left_press(event)
			else:
				_left_release(event)


func _left_press(event: InputEventMouseButton) -> void:
	if nav_mode != NavMode.SELECT:
		# Orbit, Pan and Zoom take left drags only: a click still selects (picks for the open command).
		_drag = {"type": "nav_pending", "start": event.position, "shift": event.shift_pressed, "ctrl": event.ctrl_pressed or event.meta_pressed}
		return
	var handle := _handle_at(event.position)
	if not handle.is_empty():
		var ray := ray_from(event.position)
		_drag = {"type": "handle", "handle": handle, "start_t": _handle_param(handle, ray[0], ray[1])}
		if str(handle.type) == "ring":
			# A ring turns from where it was grabbed; the turn is counted past a full revolution.
			var hit: Variant = MANIPULATOR.on_plane(handle.origin, handle.axis, ray[0], ray[1])
			var grab: Vector3 = (hit as Vector3) - (handle.origin as Vector3) if hit != null else Vector3.ZERO
			if grab.is_zero_approx():
				var axis: Vector3 = handle.axis
				grab = axis.cross(Vector3.UP if absf(axis.normalized().y) < 0.9 else Vector3.RIGHT)
			_drag["start_vector"] = grab
			_drag["last_angle"] = 0.0
			_drag["turned"] = 0.0
		return
	_drag = {"type": "pending", "start": event.position, "shift": event.shift_pressed, "ctrl": event.ctrl_pressed or event.meta_pressed}


func _left_release(event: InputEventMouseButton) -> void:
	var drag := _drag
	_drag = {}
	match str(drag.get("type", "")):
		"pending":
			pick_clicked.emit(pick_at(event.position), bool(drag.shift), bool(drag.ctrl))
		"nav_pending":
			_click_through(drag)
		"region":
			var picks: Array[Dictionary]
			if select_mode == "freeform":
				var outline: PackedVector2Array = drag.points
				# Drawn clockwise or counter-clockwise, a lasso takes only whole items unless
				# it was started to the right of where it ends (like a crossing window).
				var crossing := outline.size() > 1 and outline[outline.size() - 1].x < outline[0].x
				picks = PICKING.lasso_select(_pickable, project, outline, crossing, _region_kind(), _region_visible())
			else:
				var rect := Rect2(drag.start, event.position - (drag.start as Vector2))
				picks = region_picks(rect, event.position.x < (drag.start as Vector2).x)
			var drawn: PackedVector2Array = drag.get("points", PackedVector2Array())
			var bounds := Rect2(drag.start, event.position - (drag.start as Vector2)).abs()
			if select_mode == "freeform" and not drawn.is_empty():
				bounds = Rect2(drawn[0], Vector2.ZERO)
				for point in drawn:
					bounds = bounds.expand(point)
			last_region = {
				"rect": bounds, "outline": drawn if select_mode == "freeform" else PackedVector2Array(), "freeform": select_mode == "freeform",
				"crossing": (drawn.size() > 1 and drawn[drawn.size() - 1].x < drawn[0].x) if select_mode == "freeform" else event.position.x < (drag.start as Vector2).x,
				"shift": bool(drag.shift), "ctrl": bool(drag.ctrl),
			}
			region_selected.emit(picks, bool(drag.shift) or bool(drag.ctrl))
			_overlay.queue_redraw()
		"handle":
			manipulator_released.emit(drag.handle)
	_overlay.queue_redraw()


## A left click made in Orbit, Pan or Zoom (pressed and released without dragging): it selects as
## in Select, going to the open command's or sketch's handler first.
func _click_through(drag: Dictionary) -> void:
	var at: Vector2 = drag.start
	if mouse_handler.is_valid() and _handle_at(at).is_empty():
		var press := InputEventMouseButton.new()
		press.button_index = MOUSE_BUTTON_LEFT
		press.pressed = true
		press.position = at
		press.global_position = at
		press.shift_pressed = bool(drag.shift)
		press.ctrl_pressed = bool(drag.ctrl)
		if mouse_handler.call(press):
			var release := press.duplicate() as InputEventMouseButton
			release.pressed = false
			mouse_handler.call(release)
			return
	pick_clicked.emit(pick_at(at), bool(drag.shift), bool(drag.ctrl))


## Sets Orbit, Pan, Zoom or Select, keeping the navigation buttons in step.
func set_nav_mode(mode: int) -> void:
	nav_mode = mode
	for each in _nav_buttons:
		(_nav_buttons[each] as Button).set_pressed_no_signal(each == mode)


func _mouse_motion(event: InputEventMouseMotion) -> void:
	match str(_drag.get("type", "")):
		"nav_pending":
			if event.position.distance_to(_drag.start) > DRAG_START_PX:
				_drag.type = {NavMode.ORBIT: "orbit", NavMode.PAN: "pan", NavMode.ZOOM: "zoom"}.get(nav_mode, "orbit")
				_mouse_motion(event)
		"orbit":
			orbit(event.relative)
		"pan":
			pan(event.relative)
		"zoom":
			zoom_at(-event.relative.y * 0.05, _drag.start)
		"handle":
			_drag_handle(event.position)
		"pending":
			if event.position.distance_to(_drag.start) > DRAG_START_PX:
				if select_mode == "paint":
					_drag.type = "paint"
				else:
					_drag.type = "region"
					_drag.points = PackedVector2Array([_drag.start, event.position])
				_mouse_motion(event)
		"region":
			_drag.end = event.position
			if select_mode == "freeform":
				var points: PackedVector2Array = _drag.points
				points.append(event.position)
				_drag.points = points
			_overlay.queue_redraw()
		"paint":
			var pick := pick_at(event.position)
			if not pick.is_empty():
				paint_picked.emit(pick)
		"right":
			pass
		_:
			if event.button_mask == 0:
				_set_hover(pick_at(event.position))


func _set_hover(pick: Dictionary) -> void:
	var old_key := PICKING.key(_hover) if not _hover.is_empty() else ""
	var new_key := PICKING.key(pick) if not pick.is_empty() else ""
	if old_key == new_key:
		return
	_hover = pick
	hover_changed.emit(pick)
	_refresh_highlights()


func _region_kind() -> String:
	if priority in ["body", "face", "edge"] and filters.get(priority, true):
		return priority
	for kind in ["body", "face", "edge", "vertex"]:
		if filters.get(kind, true):
			return kind
	return "body"


func _region_visible() -> Callable:
	return (func(_p: Vector3) -> bool: return true) if select_through else _is_visible


## False when another surface hides the point from the camera.
func _is_visible(point: Vector3) -> bool:
	var screen := project(point)
	if not screen.is_finite():
		return false
	var from := _camera.project_ray_origin(screen)
	var dir := _camera.project_ray_normal(screen)
	var hit := PICKING.ray_hit(_pickable, from, dir)
	if hit.is_empty():
		return true
	var tolerance := distance * 0.002 + 0.00001
	return float(hit.distance) >= from.distance_to(point) - tolerance


# --- Handles ---------------------------------------------------------------------------------

func set_handles(value: Array[Dictionary]) -> void:
	handles = value
	_overlay.queue_redraw()


## The handle a press at screen_position takes. Point and angle dots come first (the nearest
## within 10 px): a dot is a small target and often sits on an arrow's shaft (Texture Map's anchor
## at the start of its Scale arrows, Section's turn dots, Place Component's turn dots), which is
## still taken along the rest of its 70 px. Then arrows, rings and slides in list order.
func _handle_at(screen_position: Vector2) -> Dictionary:
	var dot := {}
	var dot_distance := 10.0
	for handle in handles:
		if str(handle.type) != "point" and str(handle.type) != "angle":
			continue
		var shape := _handle_screen_shape(handle)
		if shape.is_empty():
			continue
		var d := (shape.at as Vector2).distance_to(screen_position)
		if d < dot_distance:
			dot = handle
			dot_distance = d
	if not dot.is_empty():
		return dot
	for handle in handles:
		var shape := _handle_screen_shape(handle)
		if shape.is_empty():
			continue
		match str(handle.type):
			"arrow":
				var closest := Geometry2D.get_closest_point_to_segment(screen_position, shape.from, shape.to)
				if closest.distance_to(screen_position) < 9.0:
					return handle
			"ring":
				var outline: PackedVector2Array = shape.points
				for i in range(1, outline.size()):
					if Geometry2D.get_closest_point_to_segment(screen_position, outline[i - 1], outline[i]).distance_to(screen_position) <= DOF_GRAB_PX:
						return handle
			"slide":
				if Geometry2D.get_closest_point_to_segment(screen_position, shape.from, shape.to).distance_to(screen_position) <= DOF_GRAB_PX:
					return handle
	return {}


## Screen geometry of a handle: arrows are 70 px long whatever the zoom.
func _handle_screen_shape(handle: Dictionary) -> Dictionary:
	match str(handle.type):
		"arrow":
			var origin: Vector3 = handle.origin
			var from := project(origin)
			var to := project(origin + (handle.direction as Vector3).normalized() * _world_per_pixel() * 70.0 * _depth_scale(origin))
			if not (from.is_finite() and to.is_finite()):
				return {}
			return {"from": from, "to": to}
		"point":
			var at := project(handle.position)
			return {"at": at} if at.is_finite() else {}
		"angle":
			var origin: Vector3 = handle.origin
			var start: Vector3 = (handle.start as Vector3).normalized() * float(handle.get("radius", 0.05))
			var at := project(origin + start)
			return {"at": at, "center": project(origin)} if at.is_finite() else {}
		"ring":
			# A DOF ring: RING_PX on screen whatever the zoom; its outline as screen points (the
			# parts behind the camera left out).
			var origin: Vector3 = handle.origin
			var radius := _world_per_pixel() * _depth_scale(origin) * RING_PX
			var outline := PackedVector2Array()
			for point in MANIPULATOR.ring_points(origin, handle.axis, radius, 48):
				var at := project(point)
				if at.is_finite():
					outline.append(at)
			return {"points": outline, "center": project(origin)} if outline.size() > 1 else {}
		"slide":
			# A two-way DOF arrow: SLIDE_PX on screen each way from the joint origin.
			var origin: Vector3 = handle.origin
			var reach := (handle.direction as Vector3).normalized() * _world_per_pixel() * _depth_scale(origin) * SLIDE_PX
			var from := project(origin - reach)
			var to := project(origin + reach)
			if not (from.is_finite() and to.is_finite()):
				return {}
			return {"from": from, "to": to, "center": project(origin)}
	return {}


## How much bigger a pixel is at point than at the target (perspective only).
func _depth_scale(point: Vector3) -> float:
	if ortho:
		return 1.0
	var depth := -(_camera.global_transform.affine_inverse() * point).z
	return maxf(depth, 0.0001) / maxf(distance, 0.0001)


func _handle_param(handle: Dictionary, from: Vector3, dir: Vector3) -> Variant:
	match str(handle.type):
		"arrow", "slide":
			return MANIPULATOR.closest_on_line(handle.origin, handle.direction, from, dir)
		"angle":
			return MANIPULATOR.angle_on_plane(handle.origin, handle.axis, handle.start, from, dir)
	return 0.0


func _drag_handle(screen_position: Vector2) -> void:
	var handle: Dictionary = _drag.handle
	var ray := ray_from(screen_position)
	match str(handle.type):
		"arrow":
			var t := MANIPULATOR.closest_on_line(handle.origin, handle.direction, ray[0], ray[1])
			if is_nan(t) or is_nan(float(_drag.start_t)):
				return
			var value := maxf(float(handle.base) + (t - float(_drag.start_t)) * float(handle.get("factor", 1.0)), float(handle.get("min", 0.00001)))
			manipulator_changed.emit(handle, value)
		"point":
			var hit = MANIPULATOR.on_plane(handle.position, handle.normal, ray[0], ray[1])
			if hit != null:
				manipulator_changed.emit(handle, MANIPULATOR.snap(hit, snap_step))
		"angle":
			var angle := MANIPULATOR.angle_on_plane(handle.origin, handle.axis, handle.start, ray[0], ray[1])
			if not is_nan(angle):
				manipulator_changed.emit(handle, float(handle.get("base", 0.0)) + angle)
		"slide":
			# A DOF slide: the travel along its axis since the press, either way (unclamped).
			var t := MANIPULATOR.closest_on_line(handle.origin, handle.direction, ray[0], ray[1])
			if is_nan(t) or is_nan(float(_drag.start_t)):
				return
			manipulator_changed.emit(handle, float(handle.get("base", 0.0)) + t - float(_drag.start_t))
		"ring":
			# A DOF ring: the turn since the press, unwrapped (two turns are 720 degrees).
			var angle := MANIPULATOR.angle_on_plane(handle.origin, handle.axis, _drag.start_vector, ray[0], ray[1])
			if is_nan(angle):
				return
			var step := wrapf(angle - float(_drag.last_angle), -PI, PI)
			_drag.last_angle = angle
			_drag.turned = float(_drag.turned) + step
			manipulator_changed.emit(handle, float(handle.get("base", 0.0)) + float(_drag.turned))


# --- Drawing ---------------------------------------------------------------------------------

## Replaces the extra 3D meshes shown in the view: [{"mesh": Mesh, "material": Material}].
func set_extra_meshes(entries: Array) -> void:
	if _extra_root == null:
		_extra_root = Node3D.new()
		_world.add_child(_extra_root)
	for child in _extra_root.get_children():
		child.queue_free()
	for entry in entries:
		var node := MeshInstance3D.new()
		node.mesh = entry.mesh
		node.material_override = entry.get("material")
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_extra_root.add_child(node)


## Where a screen position's ray meets a plane (or null).
func plane_hit(screen_position: Vector2, point: Vector3, normal: Vector3) -> Variant:
	var ray := ray_from(screen_position)
	return MANIPULATOR.on_plane(point, normal, ray[0], ray[1])


## The side length of the origin plane squares (they scale with the grid).
func origin_size() -> float:
	return _origin_root.scale.x


func pixels_per_meter_at(point: Vector3) -> float:
	return 1.0 / maxf(_world_per_pixel() * _depth_scale(point), 1e-12)


func redraw_overlay() -> void:
	_overlay.queue_redraw()
	if _glyph_layer != null:
		_glyph_layer.queue_redraw()


## Gives the view the keyboard (after a box over it closes), so its shortcuts work again.
func focus_view() -> void:
	if _overlay.is_visible_in_tree():
		_overlay.grab_focus()


func _draw_overlay() -> void:
	if not _analysis_points.is_empty():
		var font := _overlay.get_theme_default_font()
		for point in _analysis_points:
			# (A point that names its body moves with it.)
			var at := project(_shown_pose(str(point.get("body", ""))) * (point.position as Vector3))
			if at.is_finite():
				_overlay.draw_circle(at, 5.0, point.color)
				_overlay.draw_arc(at, 5.0, 0.0, TAU, 16, theme_colors.analysis_ring, 1.5, true)
				_overlay.draw_string(font, at + Vector2(8, -6), str(point.get("label", "")), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, theme_colors.analysis_text)
	_draw_boundaries()
	if draw_handler.is_valid():
		draw_handler.call(_overlay)
	var accent: Color = theme_colors.select_line
	var handle_color: Color = theme_colors.handle
	# Selected and hovered edges and vertices are drawn on top, thick enough to see.
	for pick in _selected:
		_draw_pick_2d(pick, accent, 3.0)
	if not _hover.is_empty():
		_draw_pick_2d(_hover, theme_colors.hover_line, 3.0)
	for handle in handles:
		var shape := _handle_screen_shape(handle)
		if shape.is_empty():
			continue
		match str(handle.type):
			"arrow":
				var from: Vector2 = shape.from
				var to: Vector2 = shape.to
				_overlay.draw_line(from, to, handle_color, 2.5, true)
				var dir := (to - from).normalized()
				var side := Vector2(-dir.y, dir.x)
				_overlay.draw_colored_polygon(PackedVector2Array([to + dir * 12.0, to + side * 6.0, to - side * 6.0]), handle_color)
			"point":
				_overlay.draw_circle(shape.at, 7.0, theme_colors.handle_fill)
				_overlay.draw_arc(shape.at, 7.0, 0.0, TAU, 24, handle_color, 2.0, true)
			"angle":
				_overlay.draw_line(shape.center, shape.at, handle_color, 1.5, true)
				_overlay.draw_circle(shape.at, 6.0, handle_color)
			"ring":
				_overlay.draw_polyline(shape.points, handle_color, 2.5, true)
			"slide":
				var from: Vector2 = shape.from
				var to: Vector2 = shape.to
				_overlay.draw_line(from, to, handle_color, 2.5, true)
				var dir := (to - from).normalized()
				var side := Vector2(-dir.y, dir.x)
				for tip_dir: Vector2 in [dir, -dir]:
					var tip: Vector2 = to if tip_dir == dir else from
					_overlay.draw_colored_polygon(PackedVector2Array([tip + tip_dir * 12.0, tip + side * 6.0, tip - side * 6.0]), handle_color)
	match str(_drag.get("type", "")):
		"region":
			if select_mode == "freeform":
				var points: PackedVector2Array = _drag.points
				if points.size() > 1:
					var closed := points.duplicate()
					closed.append(points[0])
					_overlay.draw_polyline(closed, theme_colors.window_box, 1.5, true)
			elif _drag.has("end"):
				var start: Vector2 = _drag.start
				var end: Vector2 = _drag.end
				var rect := Rect2(start, end - start).abs()
				var crossing := end.x < start.x
				var color: Color = theme_colors.crossing_box if crossing else theme_colors.window_box
				_overlay.draw_rect(rect, Color(color, 0.12), true)
				if crossing:
					for edge in [[rect.position, rect.position + Vector2(rect.size.x, 0)], [rect.position + Vector2(rect.size.x, 0), rect.end],
							[rect.end, rect.position + Vector2(0, rect.size.y)], [rect.position + Vector2(0, rect.size.y), rect.position]]:
						_overlay.draw_dashed_line(edge[0], edge[1], color, 1.5, 6.0)
				else:
					_overlay.draw_rect(rect, color, false, 1.5)


## Mesh bodies' open edges, drawn wide over their thin lines (as far as they are few enough,
## MESH_DISPLAY.BOUNDARY_OVERLAY_SEGMENTS; an edge its own body hides is left to the thin line).
func _draw_boundaries() -> void:
	if _boundary_segments.is_empty():
		return
	if not _boundary_lines_valid:
		_boundary_lines_valid = true
		_boundary_lines = PackedVector2Array()
		var eye := _camera.global_position
		var forward := -_camera.global_transform.basis.z
		for body_id in _boundary_segments:
			var points: PackedVector3Array = _boundary_segments[body_id]
			var mesh: RefCounted = (_prepared.get(body_id, {}) as Dictionary).get(PICKING.MESH_KEY)
			var reach := (mesh.bbox() as AABB).size.length() * 0.002 + 1e-6 if mesh != null else 0.0
			# (A posed body: its modelled segments are drawn where it shows; the check for what hides
			# them runs in its modelled space.)
			var pose := _shown_pose(str(body_id))
			var inverse := pose.affine_inverse()
			for s in range(0, points.size(), 2):
				var a := project(pose * points[s])
				var b := project(pose * points[s + 1])
				if not (a.is_finite() and b.is_finite()):
					continue
				if mesh != null:
					var local_middle := (points[s] + points[s + 1]) * 0.5
					var middle := pose * local_middle
					var from := inverse * (middle - forward * (middle - eye).dot(forward) if ortho else eye)
					var away := from.distance_to(local_middle)
					var hit: Dictionary = mesh.ray_hit(from, (local_middle - from).normalized(), away)
					if bool(hit.get("hit", false)) and float(hit.distance) < away - reach:
						continue
				_boundary_lines.append(a)
				_boundary_lines.append(b)
	if _boundary_lines.size() >= 2:
		_overlay.draw_multiline(_boundary_lines, theme_colors.mesh_boundary, 2.5, true)


## How many open-edge segments the overlay draws wide now (for tests).
func boundary_overlay_count() -> int:
	return int(_boundary_lines.size() / 2.0)


func _draw_pick_2d(pick: Dictionary, color: Color, width: float) -> void:
	var prepared: Dictionary = _prepared.get(pick.get("body", ""), {})
	if prepared.is_empty():
		return
	var pose := _shown_pose(str(pick.body))
	match str(pick.kind):
		"edge":
			var points: PackedVector3Array = prepared.tess.get("edge_points", PackedVector3Array())
			var ids: PackedInt32Array = prepared.tess.get("edge_ids", PackedInt32Array())
			for s in ids.size():
				if ids[s] == int(pick.index):
					var a := project(pose * points[s * 2])
					var b := project(pose * points[s * 2 + 1])
					if a.is_finite() and b.is_finite():
						_overlay.draw_line(a, b, color, width, true)
		"vertex":
			var vertices: PackedVector3Array = prepared.tess.get("vertices", PackedVector3Array())
			if int(pick.index) < vertices.size():
				var p := project(pose * vertices[int(pick.index)])
				if p.is_finite():
					_overlay.draw_circle(p, 5.0, color)


func _refresh_highlights() -> void:
	for child in _highlight_root.get_children():
		child.queue_free()
	var selected_faces := {}
	var selected_bodies := {}
	# Mesh bodies: selected face groups and triangles, gathered per body.
	var selected_triangles := {}
	for pick in _selected:
		if pick.kind == "face":
			var faces: PackedInt32Array = selected_faces.get(pick.body, PackedInt32Array())
			faces.append(int(pick.index))
			selected_faces[pick.body] = faces
		elif pick.kind == "body":
			selected_bodies[pick.body] = true
		elif str(pick.kind).begins_with("mesh_"):
			var triangles: PackedInt32Array = selected_triangles.get(pick.body, PackedInt32Array())
			triangles.append_array(_mesh_pick_triangles(pick))
			selected_triangles[pick.body] = triangles
	for body_id in selected_bodies:
		_add_highlight(body_id, PackedInt32Array(), "selected")
	for body_id in selected_faces:
		_add_highlight(body_id, selected_faces[body_id], "selected")
	for body_id in selected_triangles:
		_add_mesh_highlight(body_id, selected_triangles[body_id], "selected")
	if not _hover.is_empty():
		if _hover.kind == "face":
			_add_highlight(_hover.body, PackedInt32Array([int(_hover.index)]), "hover")
		elif _hover.kind == "body":
			_add_highlight(_hover.body, PackedInt32Array(), "hover")
		elif str(_hover.kind).begins_with("mesh_"):
			_add_mesh_highlight(_hover.body, _mesh_pick_triangles(_hover), "hover")
	if _overlay != null:
		_overlay.queue_redraw()


## The stored triangles a mesh pick stands for: a "mesh_group" pick's whole group ("index": the
## group), a "mesh_triangle" pick's one triangle, a "mesh_triangles" pick's list.
func _mesh_pick_triangles(pick: Dictionary) -> PackedInt32Array:
	var mesh: RefCounted = (_prepared.get(pick.get("body", ""), {}) as Dictionary).get(PICKING.MESH_KEY)
	if mesh == null:
		return PackedInt32Array()
	match str(pick.kind):
		"mesh_group":
			var group := int(pick.get("index", -1))
			return mesh.group_triangles(group) if group >= 0 and group < int(mesh.face_count()) else PackedInt32Array()
		"mesh_triangle":
			return PackedInt32Array([int(pick.get("triangle", pick.get("index", -1)))])
		"mesh_triangles":
			return pick.get("triangles", PackedInt32Array())
	return PackedInt32Array()


## Overlays triangles of a mesh body in the mesh selection or hover colour ("selected" or
## "hover"). The meshes are kept while the bodies stay, so a hover that comes and goes builds
## none again.
func _add_mesh_highlight(body_id: String, triangles: PackedInt32Array, look: String) -> void:
	var prepared: Dictionary = _prepared.get(body_id, {})
	if prepared.is_empty() or triangles.is_empty():
		return
	var key := "%s:%d:%d" % [body_id, triangles.size(), hash(triangles)]
	var mesh: ArrayMesh = _mesh_highlights.get(key)
	if mesh == null:
		if _mesh_highlights.size() >= 12:
			_mesh_highlights.clear()
		mesh = mesh_display.selection_mesh(prepared.tess, triangles)
		_mesh_highlights[key] = mesh
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = mesh
	mesh_instance.material_override = mesh_display.materials[look]
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mesh_instance.set_meta("mesh_look", look)
	_follow(mesh_instance, body_id, Transform3D.IDENTITY)
	_highlight_root.add_child(mesh_instance)


## The mesh selection and hover overlays shown now: [{"look", "triangles"}] (for tests).
func mesh_highlights() -> Array:
	var shown := []
	for child in _highlight_root.get_children():
		if child.is_queued_for_deletion() or not child.has_meta("mesh_look"):
			continue
		var mesh := (child as MeshInstance3D).mesh
		var count := 0
		if mesh != null and mesh.get_surface_count() > 0:
			# (A few triangles are drawn from their own corners, without an index list.)
			var arrays := mesh.surface_get_arrays(0)
			var listed: Variant = arrays[Mesh.ARRAY_INDEX]
			count = int((listed as PackedInt32Array).size() / 3.0) if listed is PackedInt32Array and not (listed as PackedInt32Array).is_empty() else int((arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3.0)
		shown.append({"look": str(child.get_meta("mesh_look")), "triangles": count, "material": (child as MeshInstance3D).material_override})
	return shown


## Overlays a body's faces (all of them when faces is empty) in a highlight material ("selected"
## or "hover"). A two-sided body (a surface) gets it on its back too.
func _add_highlight(body_id: String, faces: PackedInt32Array, look: String) -> void:
	var prepared: Dictionary = _prepared.get(body_id, {})
	if prepared.is_empty():
		return
	var two_sided := bool((_body_nodes.get(body_id, {}) as Dictionary).get("two_sided", false))
	var material: Material = _materials[look + "_two_sided" if two_sided else look]
	var clip: Dictionary = prepared.get("clip", {})
	if not clip.is_empty():
		# A sectioned body: the highlight hides the cut-away half as the body does.
		material = _clipped_highlight(_materials[look], clip, false)
		if two_sided:
			material.next_pass = _clipped_highlight(_materials[look], clip, true)
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = TESSELLATE.surface_mesh(prepared.tess) if faces.is_empty() else TESSELLATE.face_subset_mesh(prepared.tess, faces)
	mesh_instance.material_override = material
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# (It moves with a posed body, and its clip plane with it.)
	_follow(mesh_instance, body_id, Transform3D.IDENTITY)
	if not clip.is_empty():
		mesh_instance.set_meta("clip", clip)
		_place_clip(mesh_instance)
	_highlight_root.add_child(mesh_instance)


## A clipped highlight's plane (its "clip" meta, in its body's modelled space) where the body shows.
func _place_clip(node: MeshInstance3D) -> void:
	var clip: Dictionary = node.get_meta("clip", {})
	var pose := _shown_pose(str(node.get_meta("follow_body", "")))
	var material := node.material_override as ShaderMaterial
	while material != null:
		material.set_shader_parameter("plane_origin", pose * (clip.origin as Vector3))
		material.set_shader_parameter("plane_normal", (pose.basis * (clip.normal as Vector3)).normalized())
		material = material.next_pass as ShaderMaterial


## A highlight that hides the cut-away half of a sectioned body (section_highlight.gdshader); back:
## the pass for a surface's back, grown the other way and drawn only from behind.
func _clipped_highlight(base: StandardMaterial3D, clip: Dictionary, back: bool) -> ShaderMaterial:
	if back and _section_highlight_back == null:
		_section_highlight_back = Shader.new()
		_section_highlight_back.code = ANALYSIS.SECTION_HIGHLIGHT_SHADER.code.replace("cull_back", "cull_front")
	var clipped := ShaderMaterial.new()
	clipped.shader = _section_highlight_back if back else ANALYSIS.SECTION_HIGHLIGHT_SHADER
	clipped.set_shader_parameter("plane_origin", clip.origin)
	clipped.set_shader_parameter("plane_normal", clip.normal)
	clipped.set_shader_parameter("color", base.albedo_color)
	clipped.set_shader_parameter("grow_amount", -base.grow_amount if back else base.grow_amount)
	clipped.render_priority = base.render_priority
	return clipped


func _apply_style() -> void:
	for id in _body_nodes:
		var nodes: Dictionary = _body_nodes[id]
		(nodes.surface as MeshInstance3D).visible = style != "wireframe"
		(nodes.edges as MeshInstance3D).visible = style != "shaded"
		# Hidden edges draw through everything, so a section hides them.
		(nodes.hidden as MeshInstance3D).visible = (style == "hidden_edges" or style == "wireframe") and not bool(nodes.get("sectioned", false))
	if _style_menu != null:
		var popup := _style_menu.get_popup()
		for i in popup.item_count:
			var id := popup.get_item_id(i)
			if id < STYLES.size():
				popup.set_item_checked(i, STYLES.keys()[id] == style)


func _update_grid() -> void:
	if _grid == null:
		return
	# The grid fades out toward the horizon, where its lines would crowd into a band.
	var grid_material: StandardMaterial3D = _materials.grid
	grid_material.distance_fade_max_distance = distance * 1.3
	grid_material.distance_fade_min_distance = distance * 4.0
	# Grid lines every power of ten of the document unit, chosen from the zoom.
	var step := unit_scale * pow(10.0, floorf(log(maxf(distance / 6.0, 1e-6) / unit_scale) / log(10.0)))
	var extent := step * 60.0
	var center := Vector3(snappedf(target.x, step * 10.0), 0.0, snappedf(target.z, step * 10.0))
	var key := "%f|%s" % [step, center]
	if key == _grid_key:
		return
	_grid_key = key
	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	var count := 60
	_grid_colors = [theme_colors.grid_minor, theme_colors.grid_major]
	for i in range(-count, count + 1):
		var major := i % 10 == 0
		var color: Color = _grid_colors[1] if major else _grid_colors[0]
		var offset := i * step
		mesh.surface_set_color(color)
		mesh.surface_add_vertex(center + Vector3(offset, 0, -extent))
		mesh.surface_set_color(color)
		mesh.surface_add_vertex(center + Vector3(offset, 0, extent))
		mesh.surface_set_color(color)
		mesh.surface_add_vertex(center + Vector3(-extent, 0, offset))
		mesh.surface_set_color(color)
		mesh.surface_add_vertex(center + Vector3(extent, 0, offset))
	mesh.surface_end()
	_grid.mesh = mesh
	# Origin axes and planes scale with the grid so they stay readable.
	_origin_root.scale = Vector3.ONE * step * 20.0


## The origin's axes, planes and point (coloured by _color_origin).
func _build_origin() -> void:
	for key in ["x_axis", "y_axis", "z_axis"]:
		var node := MeshInstance3D.new()
		node.material_override = _materials.axis
		_origin_root.add_child(node)
		_origin_nodes[key] = node
	var planes := {"xy_plane": Vector3.BACK, "xz_plane": Vector3.UP, "yz_plane": Vector3.RIGHT}
	for key in planes:
		var quad := PlaneMesh.new()
		quad.size = Vector2(1, 1)
		var node := MeshInstance3D.new()
		node.mesh = quad
		node.material_override = (_materials.plane as StandardMaterial3D).duplicate()
		var normal: Vector3 = planes[key]
		# PlaneMesh faces +Y; turn it to the plane's normal, offset to the positive quadrant.
		node.basis = Basis(Quaternion(Vector3.UP, normal)) if not normal.is_equal_approx(Vector3.UP) else Basis.IDENTITY
		node.position = (Vector3.ONE - normal) * 0.5
		_origin_root.add_child(node)
		_origin_nodes[key] = node
	var point := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.02
	sphere.height = 0.04
	point.mesh = sphere
	_origin_point_material = StandardMaterial3D.new()
	_origin_point_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	point.material_override = _origin_point_material
	_origin_root.add_child(point)
	_origin_nodes["origin"] = point


func _color_origin() -> void:
	var axes := {"x_axis": [Vector3.RIGHT, theme_colors.axis_x], "y_axis": [Vector3.UP, theme_colors.axis_y], "z_axis": [Vector3.BACK, theme_colors.axis_z]}
	for key in axes:
		var mesh := ImmediateMesh.new()
		mesh.surface_begin(Mesh.PRIMITIVE_LINES)
		mesh.surface_set_color(axes[key][1])
		mesh.surface_add_vertex(Vector3.ZERO)
		mesh.surface_set_color(axes[key][1])
		mesh.surface_add_vertex(axes[key][0])
		mesh.surface_end()
		(_origin_nodes[key] as MeshInstance3D).mesh = mesh
	for spec in [["xy_plane", theme_colors.axis_z], ["xz_plane", theme_colors.axis_y], ["yz_plane", theme_colors.axis_x]]:
		var material := (_origin_nodes[spec[0]] as MeshInstance3D).material_override as StandardMaterial3D
		material.albedo_color = Color(spec[1], float(theme_colors.plane_alpha))
	_origin_point_material.albedo_color = theme_colors.origin_point


## The navigation bar: a pill of flat buttons at the view's bottom, in the palette's nav colours
## whatever the editor's theme (_style_nav_bar).
func _make_nav_bar() -> HBoxContainer:
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 2)
	bar.draw.connect(func() -> void:
		var back := StyleBoxFlat.new()
		back.bg_color = theme_colors.nav_back
		back.border_color = theme_colors.nav_border
		back.set_border_width_all(1)
		back.set_corner_radius_all(7)
		back.shadow_color = Color(0, 0, 0, 0.16)
		back.shadow_size = 5
		bar.draw_style_box(back, Rect2(Vector2(-4, -3), bar.size + Vector2(8, 6))))
	# None of the bar's buttons takes keyboard focus: Enter, Escape and the shortcuts stay with the view
	# and the open command.
	for spec in [["Orbit", NavMode.ORBIT, "Orbit: drag in the view (or Shift + middle-drag)"], ["Pan", NavMode.PAN, "Pan: drag in the view (or middle-drag)"],
			["Zoom", NavMode.ZOOM, "Zoom: drag up and down in the view (or mouse wheel)"]]:
		var button := Button.new()
		button.text = spec[0]
		button.toggle_mode = true
		button.focus_mode = Control.FOCUS_NONE
		button.tooltip_text = spec[2] + ". Clicks still select; Escape goes back to Select."
		var mode: int = spec[1]
		button.toggled.connect(func(on: bool) -> void: set_nav_mode(mode if on else NavMode.SELECT))
		bar.add_child(button)
		_nav_buttons[mode] = button
	var fit_button := Button.new()
	fit_button.text = "Fit"
	fit_button.focus_mode = Control.FOCUS_NONE
	fit_button.tooltip_text = "Fit the view to everything (F6)"
	fit_button.pressed.connect(fit)
	bar.add_child(fit_button)
	_style_menu = MenuButton.new()
	_style_menu.text = "Display"
	_style_menu.focus_mode = Control.FOCUS_NONE
	_style_menu.flat = false
	var popup := _style_menu.get_popup()
	var i := 0
	for key in STYLES:
		popup.add_radio_check_item(STYLES[key], i)
		i += 1
	popup.add_separator()
	popup.add_check_item("Orthographic", 100)
	popup.add_check_item("Grid", 101)
	popup.set_item_checked(popup.get_item_index(101), true)
	popup.id_pressed.connect(func(id: int) -> void:
		if id < STYLES.size():
			set_style(STYLES.keys()[id])
		elif id == 100:
			set_ortho(not ortho)
			popup.set_item_checked(popup.get_item_index(100), ortho)
		elif id == 101:
			set_grid_visible(not grid_visible)
			popup.set_item_checked(popup.get_item_index(101), grid_visible))
	bar.add_child(_style_menu)
	_apply_style()
	return bar


func _style_nav_bar() -> void:
	var states := {}
	for state in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		var box := StyleBoxFlat.new()
		box.bg_color = {"hover": theme_colors.nav_hover, "pressed": theme_colors.nav_pressed, "hover_pressed": theme_colors.nav_pressed}.get(state, Color(0, 0, 0, 0))
		box.set_corner_radius_all(5)
		box.content_margin_left = 9
		box.content_margin_right = 9
		box.content_margin_top = 3
		box.content_margin_bottom = 3
		states[state] = box
	for button in _nav_bar.get_children():
		if not button is Button:
			continue
		for state in states:
			(button as Button).add_theme_stylebox_override(state, states[state])
		for state in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
			(button as Button).add_theme_color_override(state, theme_colors.nav_text)
		(button as Button).add_theme_color_override("font_disabled_color", Color(theme_colors.nav_text, 0.4))
	_nav_bar.queue_redraw()


func _make_environment() -> Environment:
	var env := Environment.new()
	var sky := Sky.new()
	# A gradient fixed to the screen in the palette's colours; the light comes from a soft sky
	# that stays the same (forge_background.gdshader).
	_sky_material = ShaderMaterial.new()
	_sky_material.shader = BACKGROUND_SHADER
	sky.sky_material = _sky_material
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.7
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	return env


## The background gradient spans the view's height in pixels (forge_background.gdshader).
func _update_background_height() -> void:
	_sky_material.set_shader_parameter("view_height", float(maxi(_viewport.size.y, 1)))


func _make_materials() -> void:
	var surface := StandardMaterial3D.new()
	surface.albedo_color = Color(0.72, 0.75, 0.8)
	surface.roughness = 0.45
	surface.metallic = 0.1
	_materials.surface = surface

	# Surface bodies: both sides drawn, front and back in different colors.
	var surface_body := ShaderMaterial.new()
	surface_body.shader = SURFACE_BODY_SHADER
	_materials.surface_body = surface_body

	var edge := StandardMaterial3D.new()
	edge.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	edge.albedo_color = Color(0.08, 0.09, 0.11)
	_materials.edge = edge

	var hidden := StandardMaterial3D.new()
	hidden.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	hidden.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	hidden.no_depth_test = true
	hidden.albedo_color = Color(0.08, 0.09, 0.11, 0.22)
	_materials.hidden_edge = hidden

	for spec in [["selected", Color(0.15, 0.45, 1.0, 0.45)], ["hover", Color(0.45, 0.75, 1.0, 0.3)]]:
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.albedo_color = spec[1]
		material.grow = true
		material.grow_amount = 0.00015
		material.render_priority = 1
		_materials[spec[0]] = material
		# A surface is seen from behind too: a second pass grown the other way (in front of the
		# surface from there) and drawn only from behind. Solids keep one pass, so the highlight
		# never doubles up where their far side shows (the Wireframe style, see-through looks).
		var back: StandardMaterial3D = material.duplicate()
		back.cull_mode = BaseMaterial3D.CULL_FRONT
		back.grow_amount = -material.grow_amount
		var two_sided: StandardMaterial3D = material.duplicate()
		two_sided.next_pass = back
		_materials[spec[0] + "_two_sided"] = two_sided

	var grid := StandardMaterial3D.new()
	grid.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	grid.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	grid.vertex_color_use_as_albedo = true
	grid.vertex_color_is_srgb = true
	grid.distance_fade_mode = BaseMaterial3D.DISTANCE_FADE_PIXEL_ALPHA
	_materials.grid = grid

	var analysis_line := StandardMaterial3D.new()
	analysis_line.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	analysis_line.vertex_color_use_as_albedo = true
	analysis_line.vertex_color_is_srgb = true
	analysis_line.render_priority = 1
	_materials.analysis_line = analysis_line

	var axis := StandardMaterial3D.new()
	axis.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	axis.vertex_color_use_as_albedo = true
	axis.vertex_color_is_srgb = true
	_materials.axis = axis

	var plane := StandardMaterial3D.new()
	plane.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	plane.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	plane.cull_mode = BaseMaterial3D.CULL_DISABLED
	_materials.plane = plane
