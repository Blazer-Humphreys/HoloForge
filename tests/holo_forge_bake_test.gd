extends SceneTree
## Holo Forge baking: a part with two bodies bakes to two separate MeshInstance3D nodes with the
## right sizes and places; renaming a body keeps the same node (and the material the user put on
## it); hiding a body hides its node; collision adds a trimesh StaticBody3D per body; removing a
## feature removes its node; and the bodies export to a .glb that loads back with both meshes.
##
## godot --headless --path . --script res://tests/holo_forge_bake_test.gd

const CAD_PART := preload("res://addons/holo_forge/nodes/cad_part.gd")
const DOCUMENT := preload("res://addons/holo_forge/core/document.gd")
const REGEN := preload("res://addons/holo_forge/core/regen.gd")
const OPERATIONS := preload("res://addons/holo_forge/core/operations.gd")

var failures: Array[String] = []


func _init() -> void:
	call_deferred("run")


func run() -> void:
	var kernel := REGEN.make_kernel()
	_expect(kernel != null, "The native kernel should load.")
	if kernel != null:
		await _check(kernel)
	print("PASS holo_forge_bake: two bodies as two MeshInstance3D nodes with correct bounds, node reuse on rename, hide, collision, removal, .glb export." \
		if failures.is_empty() else "FAIL holo_forge_bake")
	quit(0 if failures.is_empty() else 1)


func _check(kernel: RefCounted) -> void:
	var doc: Resource = DOCUMENT.new()
	var deck := _add_box(doc, Vector3(0.6, 0.02, 0.2), Vector3.ZERO)
	var pod := _add_box(doc, Vector3(0.1, 0.08, 0.1), Vector3(0.0, 0.0, 0.5))
	var part: Node3D = CAD_PART.new()
	part.name = "Board"
	part.document = doc
	root.add_child(part)
	part.apply_result(REGEN.rebuild(doc, kernel))
	await process_frame

	var nodes: Dictionary = part.body_nodes()
	_expect(nodes.size() == 2, "Two bodies should bake to two nodes (got %d)." % nodes.size())
	var deck_node: MeshInstance3D = nodes.get(deck.options.body_id)
	var pod_node: MeshInstance3D = nodes.get(pod.options.body_id)
	_expect(deck_node != null and pod_node != null, "Each body should have its own MeshInstance3D.")
	if deck_node == null or pod_node == null:
		return
	_expect(_aabb_close(deck_node.get_aabb(), AABB(Vector3(-0.3, 0, -0.1), Vector3(0.6, 0.02, 0.2))), "The deck bounds should be 600 x 20 x 200 mm at the origin (%s)." % deck_node.get_aabb())
	_expect(_aabb_close(pod_node.get_aabb(), AABB(Vector3(-0.05, 0, 0.45), Vector3(0.1, 0.08, 0.1))), "The pod bounds should be 100 x 80 x 100 mm at z = 0.5 m (%s)." % pod_node.get_aabb())
	_expect(deck_node.name == "Body1" and pod_node.name == "Body2", "Body nodes should be named after the bodies (%s, %s)." % [deck_node.name, pod_node.name])

	var paint := StandardMaterial3D.new()
	deck_node.material_override = paint
	doc.bodies[deck.options.body_id].name = "Deck"
	doc.bodies[pod.options.body_id].visible = false
	part.generate_collision = true
	part.apply_result(REGEN.rebuild(doc, kernel))
	await process_frame
	nodes = part.body_nodes()
	_expect(nodes.get(deck.options.body_id) == deck_node and deck_node.name == "Deck", "Renaming a body should keep the same node and rename it.")
	_expect(deck_node.material_override == paint, "A rebuild should keep the material the user set on a body node.")
	_expect(not pod_node.visible, "A hidden body should bake to a hidden node.")
	var collision := deck_node.get_node_or_null("Collision/Shape") as CollisionShape3D
	_expect(collision != null and collision.shape is ConcavePolygonShape3D and (collision.shape as ConcavePolygonShape3D).get_faces().size() >= 36,
		"Collision should add a trimesh shape covering the body.")

	doc.bodies[pod.options.body_id].visible = true
	var path := "user://holo_forge_bake_test.glb"
	var written: String = part.export_glb(path)
	_expect(written == path and FileAccess.file_exists(path), "The bodies should export to a .glb.")
	var gltf := GLTFDocument.new()
	var state := GLTFState.new()
	if gltf.append_from_file(path, state) == OK:
		var scene := gltf.generate_scene(state)
		var meshes := scene.find_children("*", "MeshInstance3D", true, false)
		_expect(meshes.size() == 2, "The .glb should load back with both body meshes (got %d)." % meshes.size())
		scene.free()
	else:
		_expect(false, "The exported .glb should load back.")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

	doc.remove_feature(pod.id)
	part.apply_result(REGEN.rebuild(doc, kernel))
	await process_frame
	_expect(part.body_nodes().size() == 1 and not is_instance_valid(pod_node) or (is_instance_valid(pod_node) and pod_node.is_queued_for_deletion()),
		"Removing a feature should remove its body node.")
	part.queue_free()


func _add_box(doc: Resource, size: Vector3, position: Vector3) -> Resource:
	var feature: Resource = doc.add_feature("box", "Box", {
		"length": doc.make_input("%f m" % size.x, "length"), "height": doc.make_input("%f m" % size.y, "length"),
		"width": doc.make_input("%f m" % size.z, "length"),
	}, {"operation": OPERATIONS.NEW_BODY, "position": position})
	feature.options.body_id = doc.new_body(feature.id)
	return feature


func _aabb_close(a: AABB, b: AABB) -> bool:
	return a.position.distance_to(b.position) < 1e-5 and a.size.distance_to(b.size) < 1e-5


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error(message)
		print("FAIL: ", message)
