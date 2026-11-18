extends SceneTree
## Holo Forge Passthrough (Display > Passthrough): the Forge view shows the part where it stands in
## its 3D scene. The "scene" here is a SubViewport with a world of its own holding a floor, a box, a
## sun, a WorldEnvironment and the CadPart (turned and moved, with its baked bodies).
##
## 1. Off: the view has its own world, its sky and its lights; the menu item is unchecked.
## 2. On (far over near no more than the view alone uses; the grid off): the view renders the scene's world, the part's space sits at the part's transform, the
##    view's sky and lights are taken out (the scene has its own), and the part's baked nodes are
##    hidden from rendering with their visible property untouched. Saved in the store.
## 3. A point of the part projects where a camera placed in the scene would show it (0.05 px), and
##    a click picks the same face and point as with Passthrough off.
## 4. A scene with no sky or light of its own keeps the view's sky and lights.
## 5. The tab hidden goes back to the view's own world (Passthrough stays on); shown, it is back.
## 6. Moving the part in the scene moves the view's space with it; a rebuild hides the new nodes.
## 7. A scaled part shows at its modelled size, and the view says the scale is left out.
## 8. No part: the item can't be turned on and says why. A new workspace reads the saved setting.
## 9. Off again: everything is as in 1; turned on and off 20 times, no nodes or objects are left.
##
## godot --headless --path . --script res://tests/holo_forge_passthrough_test.gd
## (also with "-- --holo-forge-test-world-offset", where the view's own space is moved.)

const DOCUMENT := preload("res://addons/holo_forge/core/document.gd")
const CAD_PART := preload("res://addons/holo_forge/nodes/cad_part.gd")
const WORKSPACE := preload("res://addons/holo_forge/ui/forge_workspace.gd")
const VIEWPORT := preload("res://addons/holo_forge/ui/forge_viewport.gd")
const OPERATIONS := preload("res://addons/holo_forge/core/operations.gd")

static var PART_TRANSFORM := Transform3D(Basis(Vector3(0.2, 1.0, -0.3).normalized(), 0.9), Vector3(31.0, 4.5, -17.0))

var failures: Array[String] = []
var ws: Control
var view: Control
var part: Node3D
var store := {}
var scene_view: SubViewport
var scene: Node3D
var messages: Array[String] = []


func _init() -> void:
	call_deferred("run")


func run() -> void:
	create_timer(240.0).timeout.connect(func() -> void:
		print("FAIL holo_forge_passthrough: timed out ", failures)
		quit(1))
	ws = WORKSPACE.new()
	ws.passthrough_store = store
	root.add_child(ws)
	ws.size = Vector2(1200, 800)
	if ws.kernel == null:
		print("SKIP holo_forge_passthrough: native library missing")
		quit(1)
		return
	view = ws.viewport
	ws.message_shown.connect(func(text: String) -> void: messages.append(text))
	_make_scenes()
	for i in 4:
		await process_frame
	_case("1 off: the view's own world", _check_off("before"))
	_case("2 on: the scene's world, the part's place, hidden baked nodes", await _check_on())
	_case("3 projection and picking match the scene", await _check_projection_and_pick())
	_case("4 a scene without sky or light keeps the view's", await _check_bare_scene())
	_case("5 hidden tab leaves the scene, shown tab comes back", await _check_tab())
	_case("6 the part moved and rebuilt", await _check_follow())
	_case("7 a scaled part", await _check_scale())
	_case("8 no part, and the saved setting", await _check_blocked_and_saved())
	_case("9 off again, and 20 toggles leave nothing", await _check_toggles())
	ws.set_part(null)
	ws.queue_free()
	scene_view.queue_free()
	await process_frame
	print("PASS holo_forge_passthrough: on and off, scene world, lights and sky, hidden baked nodes, projection, picking, tab, follow, scale, saved, 20 toggles" if failures.is_empty() else "FAIL holo_forge_passthrough: %d failures" % failures.size())
	quit(0 if failures.is_empty() else 1)


# --- The scenes ------------------------------------------------------------------------------

func _make_scenes() -> void:
	scene_view = _scene_viewport()
	scene = Node3D.new()
	scene.name = "PassthroughScene"
	scene_view.add_child(scene)
	var floor := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(200, 200)
	floor.mesh = plane
	scene.add_child(floor)
	var box := MeshInstance3D.new()
	box.mesh = BoxMesh.new()
	box.position = Vector3(30, 1, -20)
	scene.add_child(box)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	scene.add_child(sun)
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	scene.add_child(environment)
	var holder := Node3D.new()
	holder.name = "Holder"
	holder.transform = PART_TRANSFORM
	scene.add_child(holder)
	part = CAD_PART.new()
	part.name = "PassPart"
	part.document = _box_document()
	holder.add_child(part)
	ws.passthrough_scene_root = scene
	ws.set_part(part)


func _scene_viewport() -> SubViewport:
	var sub := SubViewport.new()
	sub.own_world_3d = true
	sub.size = Vector2i(320, 240)
	sub.render_target_update_mode = SubViewport.UPDATE_DISABLED
	root.add_child(sub)
	return sub


## A 40 x 20 x 30 mm box with its bottom on the part's origin plane.
func _box_document() -> Resource:
	var doc: Resource = DOCUMENT.new()
	var box: Resource = doc.add_feature("box", "Block", {
		"length": doc.make_input("40 mm", "length"), "height": doc.make_input("20 mm", "length"), "width": doc.make_input("30 mm", "length"),
	}, {"operation": OPERATIONS.NEW_BODY, "position": Vector3.ZERO})
	var body: String = doc.new_body(box.id)
	box.options.body_id = body
	doc.bodies[body].name = "Block"
	return doc


# --- Checks ----------------------------------------------------------------------------------

func _sub() -> SubViewport:
	return view.get("_viewport")


func _world_node() -> Node3D:
	return view.get("_world")


func _menu_item() -> Dictionary:
	var menu: MenuButton = view.get("_style_menu")
	var popup := menu.get_popup()
	var index := popup.get_item_index(VIEWPORT.PASSTHROUGH_ITEM)
	if index < 0:
		return {}
	return {"popup": popup, "index": index, "checked": popup.is_item_checked(index), "disabled": popup.is_item_disabled(index), "tooltip": popup.get_item_tooltip(index)}


func _baked_nodes() -> Array:
	return part.find_children("*", "VisualInstance3D", true, false)


func _check_off(when: String) -> bool:
	var ok := true
	var sub := _sub()
	ok = _expect(not view.passthrough_on(), "%s: Passthrough should be off in the view." % when) and ok
	ok = _expect(sub.world_3d == view.get("_private_world") and sub.world_3d != scene.get_world_3d(), "%s: the view should have its own world." % when) and ok
	var environment: Node = view.get("_environment_node")
	ok = _expect(environment.get_parent() == _world_node(), "%s: the view's sky should be in its world." % when) and ok
	ok = _expect((view.get("_head_light") as Light3D).visible and (view.get("_top_light") as Light3D).visible, "%s: the view's lights should be on." % when) and ok
	ok = _expect(view.grid_visible and (view.get("_grid") as Node3D).visible, "%s: the view's grid should be on." % when) and ok
	var home: Transform3D = view.get("_home_world")
	ok = _expect(_world_node().transform.is_equal_approx(home), "%s: the view's space should be back home." % when) and ok
	var item := _menu_item()
	ok = _expect(not item.is_empty() and not item.checked, "%s: Display > Passthrough should be there, unchecked." % when) and ok
	for node in _baked_nodes():
		ok = _expect((node as VisualInstance3D).visible, "%s: %s should be visible." % [when, node.name]) and ok
	return ok


func _check_on() -> bool:
	var ok := true
	var baked := _baked_nodes()
	ok = _expect(baked.size() >= 1, "The part should have baked nodes in the scene (%d)." % baked.size()) and ok
	# Through the menu, as a click: the item's id_pressed asks the workspace.
	var item := _menu_item()
	(item.popup as PopupMenu).id_pressed.emit(VIEWPORT.PASSTHROUGH_ITEM)
	await process_frame
	ok = _expect(ws.passthrough and bool(store.get("passthrough", false)), "Passthrough should be on and saved (%s)." % store) and ok
	ok = _expect(view.passthrough_on(), "The view should be in Passthrough.") and ok
	var sub := _sub()
	ok = _expect(sub.world_3d == scene.get_world_3d(), "The view should render the scene's world.") and ok
	ok = _expect(_world_node().global_transform.is_equal_approx(part.global_transform.orthonormalized()), "The view's space should be the part's: %s vs %s." % [_world_node().global_transform, part.global_transform]) and ok
	ok = _expect(view.world_transform().is_equal_approx(part.global_transform), "world_transform() should be the part's.") and ok
	ok = _expect((view.get("_environment_node") as Node).get_parent() == null, "The view's sky should be out: the scene has its own.") and ok
	ok = _expect(not (view.get("_head_light") as Light3D).visible and not (view.get("_top_light") as Light3D).visible, "The view's lights should be off: the scene has a sun.") and ok
	ok = _expect(not view.grid_visible and not (view.get("_grid") as Node3D).visible, "The view's grid should be off in the scene.") and ok
	var state: Dictionary = view.passthrough_state()
	var hidden: Array = state.get("hidden", [])
	for node in baked:
		ok = _expect(hidden.has(node), "%s should be hidden from rendering." % node.name) and ok
		ok = _expect((node as VisualInstance3D).visible, "%s keeps visible = true (only rendering hides it)." % node.name) and ok
	ok = _expect(hidden.size() == baked.size(), "Only the part's nodes should be hidden (%d of %d)." % [hidden.size(), baked.size()]) and ok
	var camera: Camera3D = view.camera()
	ok = _expect(camera.far / camera.near <= VIEWPORT.PASSTHROUGH_DEPTH_RANGE * 1.001 and camera.near < view.distance, "Far over near should stay within the view's own range, near before the orbit point (near %f, far %f)." % [camera.near, camera.far]) and ok
	item = _menu_item()
	ok = _expect(item.checked and not item.disabled and item.tooltip == VIEWPORT.PASSTHROUGH_TIP, "The item should be checked with its tip: %s." % item) and ok
	return ok


## The view's camera, now in the scene's world, shows a part point (placed in the scene) where the
## view projects it; picks are the same as off.
func _check_projection_and_pick() -> bool:
	var ok := true
	var camera: Camera3D = view.camera()
	ok = _expect(camera.get_world_3d() == scene.get_world_3d(), "The view's camera should be in the scene's world.") and ok
	ok = _expect(camera.global_transform.is_equal_approx(view.world_transform() * view.camera_transform()), "The camera's place in the scene should be the part's place times its place in the part.") and ok
	var worst := 0.0
	for p in [Vector3(0.01, 0.01, 0.005), Vector3(-0.02, 0.0, 0.015), Vector3(0.02, 0.02, -0.015), Vector3.ZERO]:
		var a: Vector2 = view.project(p)
		var b := camera.unproject_position(part.global_transform.orthonormalized() * p)
		worst = maxf(worst, a.distance_to(b))
	ok = _expect(worst < 0.05, "Part points should project where the scene shows them (worst %.4f px)." % worst) and ok
	var center: Vector2 = view.project(Vector3(0.0, 0.01, 0.0))
	var on_pick: Dictionary = view.pick_at(center)
	ws.set_passthrough(false)
	await process_frame
	var off_pick: Dictionary = view.pick_at(center)
	ok = _expect(not on_pick.is_empty() and on_pick.get("body") == off_pick.get("body") and on_pick.get("kind") == off_pick.get("kind") and on_pick.get("index") == off_pick.get("index"), "A click should pick the same thing on and off: %s vs %s." % [on_pick, off_pick]) and ok
	if on_pick.has("point") and off_pick.has("point"):
		ok = _expect((on_pick.point as Vector3).distance_to(off_pick.point) < 1e-6, "The picked point should be the same on and off.") and ok
	ws.set_passthrough(true)
	await process_frame
	ok = _expect(view.passthrough_on(), "Passthrough should be on again.") and ok
	return ok


## The scene without its sun and WorldEnvironment (the view joins it again, as when it is opened).
func _check_bare_scene() -> bool:
	var ok := true
	var sun := scene.find_children("*", "DirectionalLight3D", false, false)[0] as Node
	var environment := scene.find_children("*", "WorldEnvironment", false, false)[0] as Node
	ws.set_passthrough(false)
	scene.remove_child(sun)
	scene.remove_child(environment)
	ws.set_passthrough(true)
	await process_frame
	ok = _expect(view.passthrough_on() and _sub().world_3d == scene.get_world_3d(), "The view should render the bare scene's world.") and ok
	ok = _expect((view.get("_environment_node") as Node).get_parent() == _world_node(), "With no sky of its own, the view's sky stays.") and ok
	ok = _expect((view.get("_head_light") as Light3D).visible and (view.get("_top_light") as Light3D).visible, "With no light of its own, the view's lights stay on.") and ok
	ok = _expect(scene.get_world_3d().environment == (view.get("_environment_node") as WorldEnvironment).environment, "The view's sky lights the bare scene's world while it shows.") and ok
	ws.set_passthrough(false)
	await process_frame
	ok = _expect(scene.get_world_3d().environment == null, "Off, the bare scene's world has no sky again.") and ok
	scene.add_child(sun)
	scene.add_child(environment)
	ws.set_passthrough(true)
	await process_frame
	ok = _expect((view.get("_environment_node") as Node).get_parent() == null and not (view.get("_head_light") as Light3D).visible, "The scene's sky and sun again.") and ok
	ok = _expect(_world_node().global_transform.is_equal_approx(part.global_transform.orthonormalized()), "At the part's place again.") and ok
	return ok


func _check_tab() -> bool:
	var ok := true
	ws.visible = false
	await process_frame
	ok = _expect(ws.passthrough and not view.passthrough_on(), "A hidden tab should leave the scene, Passthrough still on.") and ok
	ok = _expect(_sub().world_3d == view.get("_private_world"), "The view should have its own world while the tab is hidden.") and ok
	ws.visible = true
	await process_frame
	ok = _expect(view.passthrough_on() and _sub().world_3d == scene.get_world_3d(), "The shown tab should be in the scene again.") and ok
	return ok


func _check_follow() -> bool:
	var ok := true
	var holder := part.get_parent() as Node3D
	holder.position += Vector3(2.0, 0.5, -1.0)
	holder.rotate_y(0.4)
	await process_frame
	await process_frame
	ok = _expect(_world_node().global_transform.is_equal_approx(part.global_transform.orthonormalized()), "The view's space should follow the moved part.") and ok
	# A rebuild that makes new baked nodes: they are hidden too.
	var doc: Resource = part.document
	var block: Resource = doc.features[0]
	block.inputs.length = doc.make_input("50 mm", "length")
	ws.recompute()
	await process_frame
	await process_frame
	var hidden: Array = view.passthrough_state().get("hidden", [])
	var baked := _baked_nodes()
	ok = _expect(baked.size() >= 1, "The rebuilt part should still have baked nodes.") and ok
	for node in baked:
		ok = _expect(hidden.has(node), "%s (after the rebuild) should be hidden from rendering." % node.name) and ok
	return ok


func _check_scale() -> bool:
	var ok := true
	var holder := part.get_parent() as Node3D
	var before := holder.transform
	messages.clear()
	ws.set_passthrough(false)
	holder.scale = Vector3(2.0, 2.0, 2.0)
	ws.set_passthrough(true)
	await process_frame
	ok = _expect(_world_node().global_transform.is_equal_approx(part.global_transform.orthonormalized()), "A scaled part's space should be its place without the scale.") and ok
	ok = _expect(absf(_world_node().global_transform.basis.get_scale().x - 1.0) < 1e-5, "The view's space should not be scaled.") and ok
	var noted := false
	for text in messages:
		noted = noted or text.contains("scale in the scene (2.0, 2.0, 2.0)")
	ok = _expect(noted, "The view should say the scale is left out: %s." % str(messages)) and ok
	holder.transform = before
	await process_frame
	await process_frame
	ok = _expect(_world_node().global_transform.is_equal_approx(part.global_transform.orthonormalized()), "Back to the unscaled place.") and ok
	return ok


func _check_blocked_and_saved() -> bool:
	var ok := true
	ws.set_part(null)
	await process_frame
	ok = _expect(not view.passthrough_on() and _sub().world_3d == view.get("_private_world"), "With no part the view should be in its own world.") and ok
	var item := _menu_item()
	ok = _expect(item.checked, "The item stays checked: Passthrough is still on.") and ok
	ws.set_passthrough(false)
	item = _menu_item()
	ok = _expect(not item.checked and item.disabled and item.tooltip == WORKSPACE.S_PASSTHROUGH_NO_PART, "With no part the item can't be turned on and says why: %s." % item) and ok
	ws.set_passthrough(true)
	ok = _expect(messages.has(WORKSPACE.S_PASSTHROUGH_NO_PART), "Turning it on with no part should say why.") and ok
	ws.set_part(part)
	await process_frame
	ok = _expect(view.passthrough_on(), "With the part back it shows again.") and ok
	# Saved: a new workspace with the same store starts with it on.
	var other: Control = WORKSPACE.new()
	other.passthrough_store = store
	root.add_child(other)
	ok = _expect(other.passthrough, "A new workspace should read Passthrough from the store.") and ok
	var menu: MenuButton = other.viewport.get("_style_menu")
	var index := menu.get_popup().get_item_index(VIEWPORT.PASSTHROUGH_ITEM)
	ok = _expect(menu.get_popup().is_item_checked(index), "Its item should show checked.") and ok
	other.queue_free()
	await process_frame
	return ok


func _check_toggles() -> bool:
	var ok := true
	ws.set_passthrough(false)
	await process_frame
	ok = _check_off("off again") and ok
	ok = _expect(not bool(store.get("passthrough", true)), "Off should be saved.") and ok
	await process_frame
	var orphans := Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)
	var objects := Performance.get_monitor(Performance.OBJECT_COUNT)
	var resources := Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)
	for i in 20:
		ws.set_passthrough(true)
		await process_frame
		ws.set_passthrough(false)
		await process_frame
	await process_frame
	var orphans_after := Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)
	var objects_after := Performance.get_monitor(Performance.OBJECT_COUNT)
	var resources_after := Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)
	ok = _expect(orphans_after <= orphans, "20 toggles should leave no orphan nodes (%d -> %d)." % [orphans, orphans_after]) and ok
	# (Each private world the view gets back is a new World3D; the old one goes.)
	ok = _expect(objects_after <= objects + 2 and resources_after <= resources + 2, "20 toggles should leave no objects (%d -> %d) or resources (%d -> %d)." % [objects, objects_after, resources, resources_after]) and ok
	ok = _check_off("after 20 toggles") and ok
	return ok


func _case(label: String, ok: bool) -> void:
	print(("PASS " if ok else "FAIL ") + label)


func _expect(condition: bool, message: String) -> bool:
	if not condition:
		failures.append(message)
		push_error(message)
		print("FAIL: ", message)
	return condition
