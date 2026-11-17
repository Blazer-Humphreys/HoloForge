@tool
extends Node3D
## A Holo Forge part placed in a scene.
##
## The document is the design; the children are the baked result, one MeshInstance3D per body
## (each a separate object you can move, hide or give materials) plus optional collision, inside
## a Node3D per component. Bodies carry their appearances (one mesh surface per appearance, with
## real-size UVs) and their decals (Decal children). The game only ever uses those baked
## children: the CAD kernel runs in the editor alone.
##
## Saving (editor): while the editor writes the scene this part sits in, the part's baked meshes
## and its large stored meshes are written as .res files in "<scene>_forge" beside it, so the
## scene points at them instead of holding them (scene_is_being_written). One Save is enough.
## Nothing is written for a scene that was not saved, a Save As writes beside the new scene only,
## and the part never saves a scene itself: a Save writes what the editor writes, and these files.
##
## The rule of the whole save path: after any Save, whatever failed, opening the scene again
## gives the same bodies as before the Save, or a clear error on the feature; never a silently
## different body or a body that is silently gone. So: a file is named after what it holds and is
## never written over with something else; a mesh whose file cannot be written stays in the
## scene; a stored mesh that is not the one its file is named after is never taken over; a link
## to a missing file is kept (see _save_meshes, save_mesh_blobs); a baked body whose file was lost
## is baked again before the scene is written (_bake_lost_meshes); a file beside the scene is
## removed only when no scene file on disk points at it any more (_clean_folder).
##
## Inheriting scenes: a part that comes from a base scene keeps the base scene's design, which only
## the base scene's file holds. When the design is changed in the inheriting scene, that scene keeps
## its own copy of it from its next Save on (local_document), so the change is not lost.
##
## Baking: a mesh body whose triangles and look did not change keeps its baked mesh (a mesh body
## can hold millions of triangles); see apply_result.
##
## The assembly (Phase 8, spec C8): every component node takes the pose the assembly gives it at
## the bake pose (bake_pose), local to its parent component; body meshes stay in modelled
## coordinates under their component node. With component_node_type RigidBody3D each top-level
## component bakes as a RigidBody3D (mass, centre of mass and inertia from the bodies' physical
## materials, one convex CollisionShape3D per body; the engine's inertia is read back a physics step
## later, check_inertia), the ground bodies go under a StaticBody3D named Ground,
## and the joints become Godot Joint3D nodes under a Node3D named Joints
## (core/assembly/bake_joints.gd). What the bake had to say is in last_bake_report.

const DOCUMENT := preload("res://addons/holo_forge/core/document.gd")
const REGEN := preload("res://addons/holo_forge/core/regen.gd")
const TESSELLATE := preload("res://addons/holo_forge/core/tessellate.gd")
const APPEARANCE := preload("res://addons/holo_forge/core/appearance.gd")
const MATERIAL_LIBRARY := preload("res://addons/holo_forge/core/material_library.gd")
const EXPORT := preload("res://addons/holo_forge/core/export.gd")
const MESH_BLOB := preload("res://addons/holo_forge/core/mesh/mesh_blob.gd")
const FORM_FEATURE := preload("res://addons/holo_forge/core/features/form.gd")
const SOLVER := preload("res://addons/holo_forge/core/assembly/solver.gd")
const BAKE_JOINTS := preload("res://addons/holo_forge/core/assembly/bake_joints.gd")
const XFORM := preload("res://addons/holo_forge/core/assembly/xform64.gd")
const ASSEMBLY_DATA := preload("res://addons/holo_forge/core/assembly/assembly_data.gd")
const RESOURCE_FILE := preload("res://addons/holo_forge/core/resource_file_check.gd")
## (Loaded when a RigidBody3D bake needs it, not preloaded: the part also runs in the game.)
const INSPECT_PATH := "res://addons/holo_forge/core/inspect.gd"
## component_node_type: plain Node3D components (default) or a RigidBody3D per top-level component.
const COMPONENT_NODE3D := 0
const COMPONENT_RIGID_BODY := 1
## bake_pose: the joints' current values (default) or every DOF at its rest value.
const BAKE_POSE_CURRENT := 0
const BAKE_POSE_REST := 1
## On the StaticBody3D that holds the ground bodies in RigidBody3D mode.
const GROUND_META := "holo_forge_ground"
const GROUND_NAME := "Ground"
## On a CollisionShape3D the RigidBody3D bake made: the id of the body it is the shape of.
const SHAPE_META := "holo_forge_shape"
## A body whose convex hull is more than this much larger than the body gets S-BAKE-HULL.
const HULL_GROWTH_NOTE := 0.05
## Not in the spec's C10 table (added in Stage 2, reported): a unit whose bodies have no mass.
const S_BAKE_NO_MASS := "<Comp> has no mass (its bodies hold no volume), so it bakes with Godot's default of 1 kg."
const S_BAKE_NO_HULL := "<Body> could not be given a convex collision shape, so it does not collide."
## Fix round 1 (B5), not in the spec's C10 table. A unit's inertia tensor (about its centre of mass,
## in its own axes) whose largest product of inertia is more than this fraction of its largest
## moment gets S_BAKE_INERTIA_PRODUCTS: Godot's RigidBody3D.inertia holds the moments about the
## body's own axes only (Jolt zeroes the rest), and turning the body's frame onto the principal axes
## would move the component node off solve.transforms, its children and the joints with it.
const INERTIA_PRODUCTS_NOTE := 0.01
## The engine's inertia read back after the bake (check_inertia) more than this fraction off the
## bake's gets S_BAKE_INERTIA.
const INERTIA_READBACK_NOTE := 0.1
## Physics frames the read-back waits after a bake (the engine takes a new inertia at a step).
const INERTIA_READBACK_FRAMES := 2
## Jolt Physics takes no inertia whose moments (as a vector) are shorter than 1e-6 kg m²: its
## MotionProperties::SetMassProperties treats them as zero and gives the body a 1 m sphere's
## (0.4 m · 1 m²), whatever RigidBody3D.inertia says (seen in the bake test: a 10 mm steel cube,
## 1.3e-7 kg m² per axis, read back 3.1e-3). A smaller unit's moments are raised to this, their
## ratios kept, with S_BAKE_INERTIA_FLOOR (a few times too much instead of thousands).
const JOLT_INERTIA_FLOOR := 1.05e-6
const S_BAKE_INERTIA_FLOOR := "<Comp> is too small for Jolt Physics to turn as modelled: Jolt takes no inertia below about 1e-6 kg·m² (it would use a 1 m sphere's), so its moments are raised <n>× to the smallest Jolt takes, and it is slower to start and stop turning than the design."
const S_BAKE_INERTIA_PRODUCTS :="<Comp> has products of inertia (up to <n> % of its largest moment): Godot holds a body's moments about its own axes only, so they are dropped and <Comp> turns as if its mass were balanced about those axes."
const S_BAKE_INERTIA := "<Comp> has an inertia of <got> kg·m² in the physics engine, not the <want> kg·m² the bake set, so it turns differently than the design."
const BODY_META := "holo_forge_body"
const COMPONENT_META := "holo_forge_component"
const DECAL_META := "holo_forge_decal"
## On a baked mesh body: what its mesh was baked from (the CadMesh's digest and its look), so an
## unchanged one is not baked again.
const BAKE_META := "holo_forge_bake"
const COLLISION_NAME := "Collision"
## How far a decal fades on surfaces turned away from it (keeps it off the far side of thin parts).
const DECAL_NORMAL_FADE := 0.3

signal baked

@export var document: Resource
## Adds a StaticBody3D with trimesh collision under every baked body.
@export var generate_collision := false:
	set(value):
		generate_collision = value
		if is_inside_tree() and Engine.is_editor_hint():
			bake()
## Component Node Type: how components bake. Node3D (default): a Node3D per component at the pose
## the assembly gives it; no joints are baked. RigidBody3D: each top-level component a RigidBody3D
## (grounded ones frozen), the ground bodies under a StaticBody3D named Ground, and the joints as
## Godot Joint3D nodes under Joints (with Bake Joints). Changing it bakes again.
## (Named component_node_type: the part already has a component_nodes() method.)
@export_enum("Node3D", "RigidBody3D") var component_node_type: int = COMPONENT_NODE3D:
	set(value):
		component_node_type = value
		_bake_after_change()
## Bakes the assembly's joints as Godot joints. Joints are baked only when Component Nodes is
## RigidBody3D. Changing it bakes again.
@export var bake_joints := true:
	set(value):
		bake_joints = value
		_bake_after_change()
## The pose the assembly is baked at: Current (the joints' values) or Rest (every DOF at its rest
## value). Godot's joints measure from this pose. Changing it bakes again.
@export_enum("Current", "Rest") var bake_pose: int = BAKE_POSE_CURRENT:
	set(value):
		bake_pose = value
		_bake_after_change()
@export_tool_button("Bake Bodies", "MeshInstance3D") var bake_button := bake
@export_tool_button("Export .glb", "Save") var export_button := export_glb
@export_tool_button("Edit in Forge", "Edit") var edit_button := edit_in_forge
## Only in the file of a scene that inherits this part from a base scene and changed its design
## there: that scene's own copy of the design (the base scene's file holds the base's). Opened
## again, the copy becomes the part's document. Set by the part while its scene is saved
## (_before_scene_save); null otherwise.
@export_storage var local_document: Resource:
	set(value):
		local_document = value
		if value != null and not _holding:
			document = value
			local_document = null

static var _default_material: StandardMaterial3D
static var _surface_material: StandardMaterial3D
## Stored mesh files this session wrote or checked: path -> {"md5": the file's, "digest": the
## blob's}. A file that still has that md5 is sound; another one is looked at again.
static var _saved_files := {}
## Baked mesh files this session wrote or checked: path -> [modified time, size]. A file that
## still has that stamp is sound; another one is looked at again.
static var _baked_files := {}
## Parts whose scene the editor is about to write: scene root's instance id -> {"frame": the
## frame it said so in, "parts": the parts in that scene}. Filled when the editor tells the scene's
## nodes it is about to save, emptied when the scene is written (or right after, when it was not).
static var _waiting := {}
## The plugin's saver (nodes/cad_part_saver.gd; null in a game): what tells the parts where their
## scene is being written.
static var _saver: ResourceFormatSaver
## What the scene and resource files of the project point at, for _clean_folder: path ->
## {"stamp": [modified time, size], "named": the file's dependencies as one text}.
static var _file_refs := {}
## How many Saves the parts were told of (a scene's parts share one), and the scene and Save whose
## folder was cleaned last (each part of the scene is told after the Save).
static var _save_count := 0
static var _cleaned := ""
## The names of the files the parts write beside a scene: baked meshes and stored meshes.
static var _forge_file: RegEx

## True while the part sets local_document itself (it is then not the design to take over).
var _holding := false
## What the last bake had to say: {"notes": PackedStringArray (sentences: hull, half limits, cone,
## not Jolt, not baked, ...), "errors": PackedStringArray (a joint property that did not read back
## as set)}. Each is also pushed as a warning or an error.
var last_bake_report := {"notes": PackedStringArray(), "errors": PackedStringArray()}
## The notes the last bake pushed as warnings (a note is pushed again only after a bake without it).
var _said := PackedStringArray()
## The inertia notes the last read-back pushed (check_inertia; pushed again only after one without).
var _said_inertia := PackedStringArray()
## Counts bakes, so a read-back waiting for physics frames gives up when another bake came after.
var _bake_serial := 0
static var _inspect_script: Script


func _ready() -> void:
	if document == null and Engine.is_editor_hint():
		document = DOCUMENT.new()
	if Engine.is_editor_hint():
		note_baked_files()
		# A baked mesh whose file was deleted or damaged did not load: bake it again now (the
		# scene would otherwise be saved without it).
		if _saved_with() != null:
			_bake_lost_meshes.call_deferred()


## Rebuilds the design with the kernel and refreshes the baked children (editor only).
func bake() -> Dictionary:
	if not Engine.is_editor_hint() or document == null:
		return {}
	var kernel := REGEN.make_kernel()
	if kernel == null:
		push_error("Holo Forge: the CAD kernel is not loaded, so %s cannot be baked." % name)
		return {}
	var result := REGEN.rebuild(document, kernel)
	apply_result(result)
	return result


## Refreshes the baked children from a regen result. Existing children are reused by body id,
## so anything set on them (materials, scripts, groups) survives a rebuild.
## tessellations may pass already-made tessellations (body id -> Dictionary) to save time.
## A mesh body is baked again only when its triangles (the CadMesh's digest) or what it shows (the
## appearances that reach it) changed since its node was baked; its name, visibility, collision
## and decals are still brought up to date. B-rep bodies are baked every time, as ever.
## The assembly is baked too (spec C8.3, C8.4): component transforms from the solve at bake_pose,
## and in RigidBody3D mode the physics bodies, their collision and the joints.
func apply_result(result: Dictionary, tessellations := {}) -> void:
	var report := {"notes": PackedStringArray(), "errors": PackedStringArray()}
	last_bake_report = report
	var rigid := component_node_type == COMPONENT_RIGID_BODY
	var solved := solve_for_bake(result)
	var existing := body_nodes()
	var scene_owner := _scene_owner()
	var components := _sync_components(scene_owner, solved, rigid)
	var ground := _sync_ground(scene_owner, rigid)
	# Ground bodies: under the Ground StaticBody3D in RigidBody3D mode, else under the part.
	var ground_home: Node = ground if rigid else self
	var collide := generate_collision and not rigid
	# Decals are put back on their faces with the kernel (none in a game: they stay as stored).
	var kernel: RefCounted = REGEN.make_kernel() if not document.decals.is_empty() else null
	for body_id in result.get("bodies", {}):
		var shape: RefCounted = result.bodies[body_id].shape
		var body: MeshInstance3D = existing.get(body_id)
		var signature := bake_signature(document, body_id, shape)
		var kept := signature != "" and body != null and body.mesh != null and str(body.get_meta(BAKE_META, "")) == signature
		var tess: Dictionary = tessellations.get(body_id, {})
		if tess.is_empty() and not kept:
			tess = TESSELLATE.tessellate(shape)
		existing.erase(body_id)
		var parent: Node = components.get(document.body_component(body_id), ground_home)
		if body == null:
			body = MeshInstance3D.new()
			body.set_meta(BODY_META, body_id)
			parent.add_child(body)
			body.owner = scene_owner
		elif body.get_parent() != parent:
			body.reparent(parent, false)
			_reown(body, scene_owner)
		body.name = _node_name(document.body_name(body_id))
		body.visible = bool(document.body_settings(body_id).get("visible", true))
		if kept:
			# The same triangles and look as when it was baked: only its collision may be missing.
			if not collide or body.get_node_or_null(COLLISION_NAME) == null:
				_sync_collision(body, TESSELLATE.tessellate(shape) if collide and tess.is_empty() else tess, scene_owner, APPEARANCE.two_sided(shape), collide)
			_sync_decals(body, body_id, shape, kernel, scene_owner)
			continue
		# One surface per appearance; the materials are set on the mesh, so a material the
		# user put on the node itself (override) still wins.
		var built: Dictionary = APPEARANCE.build_mesh(document, body_id, shape, tess, default_material(), surface_material())
		body.mesh = built.mesh
		for note in built.get("notes", PackedStringArray()):
			push_warning("Holo Forge: %s" % note)
		if signature != "":
			body.set_meta(BAKE_META, signature)
		elif body.has_meta(BAKE_META):
			body.remove_meta(BAKE_META)
		_sync_collision(body, tess, scene_owner, APPEARANCE.two_sided(shape), collide)
		_sync_decals(body, body_id, shape, kernel, scene_owner)
	for stale in existing.values():
		stale.get_parent().remove_child(stale)
		stale.queue_free()
	# Components that no longer exist go once their bodies have moved out.
	for node in find_children("*", "Node3D", true, false):
		if node.has_meta(COMPONENT_META) and not document.components.has(str(node.get_meta(COMPONENT_META))):
			for child in node.get_children():
				if child.has_meta(BODY_META):
					child.reparent(ground_home, false)
					_reown(child, scene_owner)
			node.get_parent().remove_child(node)
			node.queue_free()
	if ground != null and not rigid:
		# Back to Node3D mode: the ground bodies moved out above; the Ground node goes.
		for child in ground.get_children():
			if child.has_meta(BODY_META):
				child.reparent(self, false)
				_reown(child, scene_owner)
		remove_child(ground)
		ground.queue_free()
		ground = null
	_bake_assembly(result, solved, components, ground, scene_owner, report)
	baked.emit()


## Bakes the assembly again onto the nodes the last apply_result made, in the same mode: the
## solve at bake_pose, the component transforms and, in RigidBody3D mode, mass, collision and
## joints (meshes are not touched). Returns the bake report (last_bake_report).
func bake_assembly(result: Dictionary) -> Dictionary:
	var report := {"notes": PackedStringArray(), "errors": PackedStringArray()}
	last_bake_report = report
	var rigid := component_node_type == COMPONENT_RIGID_BODY
	var solved := solve_for_bake(result)
	var components := {}
	var nodes := component_nodes()
	for component_id in nodes:
		if document.components.has(component_id):
			components[component_id] = nodes[component_id]
			(nodes[component_id] as Node3D).transform = solved.transforms.get(component_id, Transform3D.IDENTITY)
	var ground: StaticBody3D = null
	for child in get_children():
		if child.has_meta(GROUND_META):
			ground = child
	_bake_assembly(result, solved, components, ground if rigid else null, _scene_owner(), report)
	return report


## The assembly solved at bake_pose (spec C8.2): the joints' values, or every DOF at its rest value.
func solve_for_bake(result: Dictionary) -> Dictionary:
	var overrides := {}
	if bake_pose == BAKE_POSE_REST and document != null and document.assembly is Dictionary:
		var assembly: Dictionary = ASSEMBLY_DATA.normalized(document.assembly)
		for joint in assembly.joints:
			if not (joint is Dictionary):
				continue
			var rest := {}
			var dofs: Array = joint.get("dofs", [])
			for i in dofs.size():
				rest[i] = float((dofs[i] as Dictionary).get("rest", 0.0)) if dofs[i] is Dictionary else 0.0
			overrides[str(joint.get("id", ""))] = rest
	return SOLVER.solve(document, result, null, overrides)


## The assembly part of a bake (after the bodies are in place): in RigidBody3D mode each unit's
## freeze, mass, centre of mass and convex collision, the Ground's trimesh collision and the joints;
## the notes the bake has (pushed as warnings, errors as errors).
func _bake_assembly(result: Dictionary, solved: Dictionary, components: Dictionary, ground: StaticBody3D, scene_owner: Node, report: Dictionary) -> void:
	var rigid := component_node_type == COMPONENT_RIGID_BODY
	# (An Array while it grows: a packed array read from a Dictionary is a copy.)
	var notes := Array(solved.get("warnings", PackedStringArray()))
	var assembly: Dictionary = ASSEMBLY_DATA.normalized(document.assembly if document.assembly is Dictionary else {})
	var units := {}
	if rigid:
		for component_id in components:
			if components[component_id] is RigidBody3D:
				units[component_id] = components[component_id]
		_sync_physics(result, solved, assembly, units, ground, scene_owner, notes)
	elif not (assembly.joints as Array).is_empty():
		notes.append(ASSEMBLY_DATA.S_BAKE_NO_JOINTS)
	report["notes"] = PackedStringArray(notes)
	BAKE_JOINTS.sync(self, document, solved, units, scene_owner, rigid and bake_joints, report)
	notes = Array(report.notes)
	if rigid:
		var left := PackedStringArray()
		for item in [["links", "motion links"], ["contact_sets", "contact sets"], ["studies", "motion studies"]]:
			if not (assembly[item[0]] as Array).is_empty():
				left.append(item[1])
		if not left.is_empty():
			notes.append(ASSEMBLY_DATA.fill(ASSEMBLY_DATA.S_BAKE_NOT_BAKED, {"list": ", ".join(left)}))
	# Each note once, in order.
	var unique := PackedStringArray()
	for note in notes:
		if not unique.has(note):
			unique.append(note)
	report["notes"] = unique
	# (The workspace bakes after every edit: a note is pushed when it is new, not at every bake.
	# S-BAKE-NO-JOINTS is the inspector's hint; it stays in the report only.)
	for note in unique:
		if not _said.has(note) and note != ASSEMBLY_DATA.S_BAKE_NO_JOINTS:
			push_warning("Holo Forge: %s: %s" % [name, note])
	_said = unique
	for error in report.errors:
		push_error("Holo Forge: %s: %s" % [name, error])
	_bake_serial += 1
	if rigid and is_inside_tree():
		_read_back_inertia()


## RigidBody3D mode: each unit's freeze (grounded units are frozen static bodies), mass, centre
## of mass and inertia (INSPECT.mass_properties: the bodies' physical materials; the inertia is
## always set, since left to itself Jolt gives a shape whose inertia is below about 1e-6 kg m² that
## of a 1 m sphere, 0.4 m · 1 m², thousands of times too much for a small part), and one convex
## CollisionShape3D per body ("<Body>Shape", a direct child of the unit, at the body's place in
## it); each ground body a trimesh CollisionShape3D under Ground.
func _sync_physics(result: Dictionary, solved: Dictionary, assembly: Dictionary, units: Dictionary, ground: StaticBody3D, scene_owner: Node, notes: Array) -> void:
	var nodes := body_nodes()
	var bodies: Dictionary = result.get("bodies", {})
	var by_unit := {}
	var ground_bodies := []
	for body_id in bodies:
		var unit := SOLVER.unit_of(document.components, str(document.body_component(body_id)))
		if unit != "" and units.has(unit):
			if not by_unit.has(unit):
				by_unit[unit] = []
			(by_unit[unit] as Array).append(str(body_id))
		else:
			ground_bodies.append(str(body_id))
	var poses: Dictionary = solved.get("poses", {})
	for unit in units:
		var rigid_body: RigidBody3D = units[unit]
		var grounded := ASSEMBLY_DATA.is_grounded(assembly, unit)
		rigid_body.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
		rigid_body.freeze = grounded
		var ids: Array = by_unit.get(unit, [])
		var unit_pose: PackedFloat64Array = poses.get(unit, XFORM.identity())
		var props: Dictionary = _inspect().mass_properties(document, result, ids) if not ids.is_empty() else {"mass": 0.0, "bodies": {}}
		# The centre of mass in the unit's own frame: each body's centre moved by its component's
		# place in the unit (nested components), in doubles.
		var mass := 0.0
		var moment := PackedFloat64Array([0.0, 0.0, 0.0])
		var places := {}
		for body_id in ids:
			var entry: Dictionary = (props.bodies as Dictionary).get(body_id, {})
			var m := float(entry.get("mass", 0.0))
			var center: Vector3 = entry.get("center", Vector3.ZERO)
			var local := XFORM.compose(XFORM.inverse(unit_pose), poses.get(str(document.body_component(body_id)), unit_pose))
			var placed := XFORM.apply(local, PackedFloat64Array([center.x, center.y, center.z]))
			places[body_id] = [local, placed]
			mass += m
			for k in 3:
				moment[k] += m * placed[k]
		if mass > 0.0:
			var com := PackedFloat64Array([moment[0] / mass, moment[1] / mass, moment[2] / mass])
			rigid_body.mass = mass
			rigid_body.center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
			rigid_body.center_of_mass = Vector3(com[0], com[1], com[2])
			_set_inertia(rigid_body, _unit_inertia(props, ids, places, com), document.component_name(unit), notes)
		else:
			rigid_body.mass = 1.0
			rigid_body.center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_AUTO
			rigid_body.inertia = Vector3.ZERO
			notes.append(ASSEMBLY_DATA.fill(S_BAKE_NO_MASS, {"Comp": document.component_name(unit)}))
		var shapes := {}
		for child in rigid_body.get_children():
			if child is CollisionShape3D and child.has_meta(SHAPE_META):
				shapes[str(child.get_meta(SHAPE_META))] = child
		for body_id in ids:
			var body: MeshInstance3D = nodes.get(body_id)
			var shape_node: CollisionShape3D = shapes.get(body_id)
			shapes.erase(body_id)
			var hull: Shape3D = body.mesh.create_convex_shape(true, false) if body != null and body.mesh != null else null
			if not (hull is ConvexPolygonShape3D):
				notes.append(ASSEMBLY_DATA.fill(S_BAKE_NO_HULL, {"Body": document.body_name(body_id)}))
				if shape_node != null:
					rigid_body.remove_child(shape_node)
					shape_node.queue_free()
				continue
			shape_node = _shape_node(rigid_body, shape_node, body_id, body, scene_owner)
			shape_node.shape = hull
			var volume := float(((props.bodies as Dictionary).get(body_id, {}) as Dictionary).get("volume", 0.0))
			if volume > 0.0:
				var grown := BAKE_JOINTS.hull_volume((hull as ConvexPolygonShape3D).points) / volume - 1.0
				if grown > HULL_GROWTH_NOTE:
					notes.append(ASSEMBLY_DATA.fill(ASSEMBLY_DATA.S_BAKE_HULL, {"Body": document.body_name(body_id), "n": str(roundi(grown * 100.0))}))
		for stale in shapes.values():
			rigid_body.remove_child(stale)
			stale.queue_free()
	if ground == null:
		return
	var ground_shapes := {}
	for child in ground.get_children():
		if child is CollisionShape3D and child.has_meta(SHAPE_META):
			ground_shapes[str(child.get_meta(SHAPE_META))] = child
	for body_id in ground_bodies:
		var body: MeshInstance3D = nodes.get(body_id)
		var shape_node: CollisionShape3D = ground_shapes.get(body_id)
		ground_shapes.erase(body_id)
		if body == null or body.mesh == null:
			continue
		shape_node = _shape_node(ground, shape_node, body_id, body, scene_owner)
		var trimesh := ConcavePolygonShape3D.new()
		trimesh.set_faces(body.mesh.get_faces())
		trimesh.backface_collision = APPEARANCE.two_sided(bodies[body_id].shape)
		shape_node.shape = trimesh
	for stale in ground_shapes.values():
		ground.remove_child(stale)
		stale.queue_free()


## A unit's inertia tensor (9 doubles, row-major, kg m²) about its centre of mass com, in the
## unit's own axes: each body's tensor (INSPECT, about the body's centre in its component's frame)
## turned into the unit (R I Rᵀ, nested components) and moved to com (parallel axis theorem).
## places: body id -> [the body's component pose in the unit (xform64), its centre there].
static func _unit_inertia(props: Dictionary, ids: Array, places: Dictionary, com: PackedFloat64Array) -> PackedFloat64Array:
	var total := PackedFloat64Array()
	total.resize(9)
	for body_id in ids:
		var entry: Dictionary = (props.get("bodies", {}) as Dictionary).get(body_id, {})
		var m := float(entry.get("mass", 0.0))
		var own := PackedFloat64Array(entry.get("inertia", []))
		var local: PackedFloat64Array = places[body_id][0]
		var placed: PackedFloat64Array = places[body_id][1]
		var d := PackedFloat64Array([placed[0] - com[0], placed[1] - com[1], placed[2] - com[2]])
		var d2 := d[0] * d[0] + d[1] * d[1] + d[2] * d[2]
		for row in 3:
			for col in 3:
				var turned := 0.0
				if own.size() == 9:
					# (An xform64's basis is column-major: R[row][i] = local[i * 3 + row].)
					for i in 3:
						for j in 3:
							turned += local[i * 3 + row] * own[i * 3 + j] * local[j * 3 + col]
				total[row * 3 + col] += turned + m * ((d2 if row == col else 0.0) - d[row] * d[col])
	return total


## Sets rigid_body.inertia to the moments of tensor about the unit's own axes (its diagonal), and
## says S_BAKE_INERTIA_PRODUCTS when its products of inertia are more than INERTIA_PRODUCTS_NOTE of
## its largest moment (see there); under Jolt, moments below JOLT_INERTIA_FLOOR are raised to it
## (S_BAKE_INERTIA_FLOOR). A tensor without three positive moments leaves the inertia to Godot (zero).
func _set_inertia(rigid_body: RigidBody3D, tensor: PackedFloat64Array, comp_name: String, notes: Array) -> void:
	var moments := Vector3(tensor[0], tensor[4], tensor[8])
	if not (moments.x > 0.0 and moments.y > 0.0 and moments.z > 0.0) or not moments.is_finite():
		rigid_body.inertia = Vector3.ZERO
		return
	var length := sqrt(tensor[0] * tensor[0] + tensor[4] * tensor[4] + tensor[8] * tensor[8])
	if BAKE_JOINTS.is_jolt() and length < JOLT_INERTIA_FLOOR:
		var raise := JOLT_INERTIA_FLOOR / length
		moments = Vector3(tensor[0] * raise, tensor[4] * raise, tensor[8] * raise)
		notes.append(ASSEMBLY_DATA.fill(S_BAKE_INERTIA_FLOOR, {"Comp": comp_name, "n": str(snappedf(raise, 0.1))}))
	rigid_body.inertia = moments
	var largest := maxf(tensor[0], maxf(tensor[4], tensor[8]))
	var products := maxf(absf(tensor[1]), maxf(absf(tensor[2]), absf(tensor[5])))
	if products > INERTIA_PRODUCTS_NOTE * largest:
		notes.append(ASSEMBLY_DATA.fill(S_BAKE_INERTIA_PRODUCTS, {"Comp": comp_name, "n": str(snappedf(products / largest * 100.0, 0.1))}))


## The inertia read-back (fix round 1, B5): each moving RigidBody3D unit's inertia as the physics
## engine holds it (1 / inverse_inertia of its direct state) against the inertia the bake set
## (RigidBody3D.inertia); one S_BAKE_INERTIA per unit more than INERTIA_READBACK_NOTE off on any
## axis. Meaningful a physics step after the bake (the bake calls it INERTIA_READBACK_FRAMES physics
## frames later, _read_back_inertia). Frozen units, units whose inertia Godot computes (zero) and
## bodies the engine holds no inertia for are left out. Returns the notes.
func check_inertia() -> Array:
	var told := []
	if document == null or component_node_type != COMPONENT_RIGID_BODY:
		return told
	var nodes := component_nodes()
	for component_id in nodes:
		var rigid_body := nodes[component_id] as RigidBody3D
		if rigid_body == null or not rigid_body.is_inside_tree() or rigid_body.freeze:
			continue
		var want := rigid_body.inertia
		if not (want.x > 0.0 and want.y > 0.0 and want.z > 0.0):
			continue
		var state := PhysicsServer3D.body_get_direct_state(rigid_body.get_rid())
		if state == null:
			continue
		var inverse: Vector3 = state.inverse_inertia
		if not (inverse.x > 0.0 and inverse.y > 0.0 and inverse.z > 0.0) or not inverse.is_finite():
			continue
		var got := Vector3(1.0 / inverse.x, 1.0 / inverse.y, 1.0 / inverse.z)
		var off := 0.0
		for k in 3:
			off = maxf(off, absf(got[k] / want[k] - 1.0))
		if off > INERTIA_READBACK_NOTE:
			told.append(ASSEMBLY_DATA.fill(S_BAKE_INERTIA, {"Comp": document.component_name(str(component_id)), "got": _moments_text(got), "want": _moments_text(want)}))
	return told


## The read-back after a bake, INERTIA_READBACK_FRAMES physics frames later (given up when the part
## left the tree or baked again): its notes join last_bake_report and new ones are pushed.
func _read_back_inertia() -> void:
	var serial := _bake_serial
	for i in INERTIA_READBACK_FRAMES:
		if not is_inside_tree():
			return
		await get_tree().physics_frame
		if serial != _bake_serial:
			return
	if not is_inside_tree():
		return
	var told := PackedStringArray(check_inertia())
	var notes: PackedStringArray = last_bake_report.get("notes", PackedStringArray())
	for note in told:
		if not notes.has(note):
			notes.append(note)
		if not _said_inertia.has(note):
			push_warning("Holo Forge: %s: %s" % [name, note])
	last_bake_report["notes"] = notes
	_said_inertia = told


static func _moments_text(moments: Vector3) -> String:
	return "(%s, %s, %s)" % [String.num_scientific(moments.x), String.num_scientific(moments.y), String.num_scientific(moments.z)]


## The CollisionShape3D for body under holder (made when shape_node is null), named
## "<Body>Shape", at the body's place under holder.
func _shape_node(holder: Node3D, shape_node: CollisionShape3D, body_id: String, body: MeshInstance3D, scene_owner: Node) -> CollisionShape3D:
	if shape_node == null:
		shape_node = CollisionShape3D.new()
		shape_node.set_meta(SHAPE_META, body_id)
		holder.add_child(shape_node)
		shape_node.owner = scene_owner
	var wanted := "%sShape" % str(body.name)
	if str(shape_node.name) != wanted:
		var holding := holder.get_node_or_null(NodePath(wanted))
		if holding != null and holding != shape_node:
			holding.name = "%s_%d" % [wanted, holding.get_instance_id()]
		shape_node.name = wanted
	shape_node.transform = _transform_under(holder, body)
	return shape_node


## node's transform relative to ancestor (the transforms of the Node3Ds in between).
static func _transform_under(ancestor: Node, node: Node3D) -> Transform3D:
	var t := node.transform
	var parent := node.get_parent()
	while parent != null and parent != ancestor:
		if parent is Node3D:
			t = (parent as Node3D).transform * t
		parent = parent.get_parent()
	return t


## The StaticBody3D named Ground that holds the ground bodies in RigidBody3D mode (made when
## rigid and missing); the existing one (or null) otherwise.
func _sync_ground(scene_owner: Node, rigid: bool) -> StaticBody3D:
	var ground: StaticBody3D = null
	for child in get_children():
		if child.has_meta(GROUND_META) and child is StaticBody3D:
			ground = child
	if rigid and ground == null:
		ground = StaticBody3D.new()
		ground.set_meta(GROUND_META, true)
		ground.name = GROUND_NAME
		add_child(ground)
		ground.owner = scene_owner
	if ground != null and rigid:
		ground.transform = Transform3D.IDENTITY
	return ground


## Bakes again after an inspector setting changed (editor, in a scene).
func _bake_after_change() -> void:
	if is_inside_tree() and Engine.is_editor_hint():
		bake()


static func _inspect() -> Script:
	if _inspect_script == null:
		_inspect_script = load(INSPECT_PATH)
	return _inspect_script


## What a mesh body's baked mesh depends on, as text: its CadMesh's digest and every appearance
## that reaches the body (its own, its face groups', its components'). "" for a B-rep body (it has
## no content digest, so it is baked every time).
static func bake_signature(doc: Resource, body_id: String, shape: RefCounted) -> String:
	if shape == null or not shape.has_method("is_mesh") or not shape.is_mesh() or shape.is_null():
		return ""
	var looks := []
	for target in doc.appearances:
		if APPEARANCE.reaches(doc, body_id, str(target)):
			looks.append([str(target), doc.appearances[target]])
	return "%s|%d" % [str(shape.digest()), hash(var_to_str(looks))]


## Baked body nodes by body id (in any component).
func body_nodes() -> Dictionary:
	var nodes := {}
	for child in find_children("*", "MeshInstance3D", true, false):
		if child.has_meta(BODY_META):
			nodes[str(child.get_meta(BODY_META))] = child
	return nodes


## Baked component nodes by component id.
func component_nodes() -> Dictionary:
	var nodes := {}
	for child in find_children("*", "Node3D", true, false):
		if child.has_meta(COMPONENT_META):
			nodes[str(child.get_meta(COMPONENT_META))] = child
	return nodes


## A Node3D per component, nested like the components, named after them, at the pose the
## assembly gives it (solved.transforms: local to the parent component). rigid: top-level
## components are RigidBody3D nodes (a node of the other kind is replaced, its children kept).
func _sync_components(scene_owner: Node, solved := {}, rigid := false) -> Dictionary:
	var nodes := component_nodes()
	var placed := {}
	var transforms: Dictionary = solved.get("transforms", {})
	var pending: Array = document.components.keys()
	var guard := 0
	while not pending.is_empty() and guard < 64:
		guard += 1
		for component_id in pending.duplicate():
			var info: Dictionary = document.components[component_id]
			var parent_id := str(info.get("parent", ""))
			if parent_id != "" and document.components.has(parent_id) and not placed.has(parent_id):
				continue
			var parent: Node = placed.get(parent_id, self)
			var node: Node3D = nodes.get(component_id)
			var want_rigid := rigid and parent == self
			if node != null and (node is RigidBody3D) != want_rigid:
				node = _replace_component_node(node, want_rigid, scene_owner)
			if node == null:
				node = RigidBody3D.new() if want_rigid else Node3D.new()
				node.set_meta(COMPONENT_META, component_id)
				parent.add_child(node)
				node.owner = scene_owner
			elif node.get_parent() != parent:
				node.reparent(parent, false)
				_reown(node, scene_owner)
			node.name = _node_name(str(info.get("name", component_id)))
			node.visible = bool(info.get("visible", true))
			node.transform = transforms.get(component_id, Transform3D.IDENTITY)
			placed[component_id] = node
			pending.erase(component_id)
	return placed


## A component node of the other kind (RigidBody3D or Node3D) in old's place, holding old's
## children (bodies and nested components; the collision shapes the RigidBody3D bake made go with
## old).
func _replace_component_node(old: Node3D, want_rigid: bool, scene_owner: Node) -> Node3D:
	var fresh: Node3D = RigidBody3D.new() if want_rigid else Node3D.new()
	fresh.set_meta(COMPONENT_META, old.get_meta(COMPONENT_META))
	fresh.visible = old.visible
	var parent := old.get_parent()
	var index := old.get_index()
	parent.add_child(fresh)
	parent.move_child(fresh, index)
	fresh.owner = scene_owner
	for child in old.get_children():
		if child.has_meta(SHAPE_META):
			continue
		child.reparent(fresh, false)
		_reown(child, scene_owner)
	parent.remove_child(old)
	old.queue_free()
	return fresh


static func _reown(node: Node, scene_owner: Node) -> void:
	node.owner = scene_owner
	for child in node.find_children("*", "", true, false):
		child.owner = scene_owner


func _notification(what: int) -> void:
	if not Engine.is_editor_hint():
		return
	if what == NOTIFICATION_EDITOR_PRE_SAVE:
		_before_scene_save()
	elif what == NOTIFICATION_EDITOR_POST_SAVE:
		_after_scene_save()


## The root of the scene this part is saved with, or null when it is saved with another one (a
## part inside an instanced scene is saved with that scene, not with the one it is used in).
## (A part that comes from a base scene is told when the inheriting scene is saved, too: its files
## are left alone there while that scene's file does not hold its design, see _state_holds and
## local_document.)
func _saved_with() -> Node:
	var scene_root: Node = owner if owner != null else self
	if scene_root.owner != null or (owner != null and scene_file_path != ""):
		return null
	return scene_root


## The editor is about to write this part's scene (it tells every node of the scene; where the
## scene goes is not known yet). The part waits for the scene to be written. Before the scene is
## packed: Form cages get their exact numbers (so they are in the scene that is written, not one
## Save later); a body whose baked mesh was lost is baked again; and a part that comes from a base
## scene and whose design was changed here gets its own copy of the design (local_document).
func _before_scene_save() -> void:
	var scene_root := _saved_with()
	if scene_root == null:
		return
	_ensure_saver()
	FORM_FEATURE.store_exact(document)
	_bake_lost_meshes()
	_keep_changed_design(scene_root)
	var frame := Engine.get_process_frames()
	var waiting: Dictionary = _waiting.get(scene_root.get_instance_id(), {})
	if waiting.is_empty() or int(waiting.frame) != frame:
		waiting = {"frame": frame, "parts": []}
		_save_count += 1
		_waiting[scene_root.get_instance_id()] = waiting
	if not (waiting.parts as Array).has(self):
		(waiting.parts as Array).append(self)


## Bakes the part again when a baked body has no mesh: its file beside the scene was deleted or
## damaged, so the scene opened without it, and a Save would write the scene without it (the
## body's node would point at nothing). True when it baked.
func _bake_lost_meshes() -> bool:
	var lost := PackedStringArray()
	for body in body_nodes().values():
		if (body as MeshInstance3D).mesh == null:
			lost.append(str(body.name))
	if lost.is_empty() or document == null:
		return false
	var kernel := REGEN.make_kernel()
	if kernel == null:
		push_error("Holo Forge: %s has no baked mesh for %s (its file beside the scene is missing or damaged), and the CAD kernel is not loaded, so it could not be baked again." % [name, ", ".join(lost)])
		return false
	apply_result(REGEN.rebuild(document, kernel))
	push_warning("Holo Forge: the baked mesh of %s in %s was missing or damaged on disk; it was baked again from the design." % [", ".join(lost), name])
	return true


## A part that comes from a base scene (the scene being saved inherits it, and the design is the
## base scene's: the document is that file's own) keeps the base's design, which only the base
## scene's file holds: the inheriting scene's file does not, so a change made here would be lost.
## When the design differs from the one in the base scene's file, the inheriting scene gets its
## own copy (local_document, written into its file; opened again, the copy is the design), and the
## part's files are then written beside the inheriting scene. Otherwise local_document stays null.
func _keep_changed_design(scene_root: Node) -> void:
	_holding = true
	local_document = null
	var base := _changed_from_base(scene_root)
	if base != "":
		var copy: Resource = DOCUMENT.new()
		copy.restore(document.snapshot())
		local_document = copy
		print("Holo Forge: the design of %s was changed in %s, which inherits it from %s: from this Save on %s keeps its own copy of the design (%s keeps its own)." % [name, str(scene_root.scene_file_path).get_file(), base.get_file(), str(scene_root.scene_file_path).get_file(), base.get_file()])
	_holding = false


## The base scene's file when this part comes from a base scene whose file holds another design
## than the part has now; "" when the part is the scene's own, or its design is the base's.
## (A scene that inherits the part and was never saved is not known as one: its first Save keeps
## the base's design.)
func _changed_from_base(scene_root: Node) -> String:
	var own := str(document.resource_path) if document != null else ""
	var scene_path := str(scene_root.scene_file_path)
	if not own.contains("::") or scene_path == "":
		return ""
	var base := own.get_slice("::", 0)
	if base == scene_path or not FileAccess.file_exists(base) or not ResourceLoader.exists(scene_path):
		return ""
	var place := "." if self == scene_root else str(scene_root.get_path_to(self))
	# The scene being saved inherits its root from a base scene that has this part there.
	var saved := ResourceLoader.load(scene_path, "PackedScene") as PackedScene
	var inherited: SceneState = saved.get_state().get_base_scene_state() if saved != null else null
	if inherited == null or _state_value(inherited, place, "document") == null:
		return ""
	# The design as the base scene's file holds it (read again, with the scripts and files it
	# points at taken as they are: the design in memory is this one).
	var original := ResourceLoader.load(base, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	if original == null:
		return ""
	var held: Variant = _state_value(original.get_state(), place, "local_document")
	if held == null:
		held = _state_value(original.get_state(), place, "document")
	if not (held is Resource) or _design_text(held) == _design_text(document):
		return ""
	return base


## The value a packed state gives a property of the node at place (a path from its root), or null.
static func _state_value(state: SceneState, place: String, property_name: String) -> Variant:
	for node in state.get_node_count():
		var packed_place := str(state.get_node_path(node))
		if packed_place != place and packed_place.trim_prefix("./") != place:
			continue
		for property in state.get_node_property_count(node):
			if str(state.get_node_property_name(node, property)) == property_name:
				return state.get_node_property_value(node, property)
	return null


## A design as text that is the same for the same design (a stored mesh counts by its digest).
static func _design_text(doc: Resource) -> String:
	var parts := PackedStringArray()
	for key in ["units", "user_parameters", "rollback", "named_views", "selection_sets", "bodies", "components", "active_component",
			"appearances", "physical_materials", "analyses", "canvases", "decals", "origin_visibility", "counters", "assembly"]:
		parts.append("%s=%s" % [key, _value_text(doc.get(key), 0)])
	for feature in doc.get("features"):
		parts.append("feature=%s" % _value_text([feature.id, feature.type, feature.label, feature.suppressed, feature.group, feature.inputs, feature.options], 0))
	return "\n".join(parts)


static func _value_text(value: Variant, depth: int) -> String:
	if value is Dictionary:
		var keys: Array = (value as Dictionary).keys()
		keys.sort_custom(func(a: Variant, b: Variant) -> bool: return str(a) < str(b))
		var items := PackedStringArray()
		for key in keys:
			items.append("%s:%s" % [var_to_str(key), _value_text(value[key], depth + 1)])
		return "{%s}" % ",".join(items)
	if value is Array:
		var items := PackedStringArray()
		for inner in value:
			items.append(_value_text(inner, depth + 1))
		return "[%s]" % ",".join(items)
	if value is Resource and (value as Resource).get_script() == MESH_BLOB:
		var missing := str(value.missing_file())
		return "blob-missing:%s" % missing.get_file() if missing != "" else "blob:%s" % str(value.digest)
	if value is Object:
		return _look_text(value, mini(depth, 3))
	return var_to_str(value)


## Gives the parts the plugin's saver (null takes it away) and registers it with the engine.
static func use_saver(saver: ResourceFormatSaver) -> void:
	_saver = saver
	_ensure_saver()


## Registers the saver with the engine when it is not (any more): the editor drops every scripted
## saver whenever its list of script classes changes (a script was added, renamed or removed), so
## each part looks before its scene is written.
static func _ensure_saver() -> void:
	if _saver != null and not _saver.call("is_registered"):
		ResourceSaver.add_resource_format_saver(_saver, true)


## True while parts wait for their scene to be written (the saver looks at no other save).
static func parts_wait_for_save() -> bool:
	return not _waiting.is_empty()


## The editor is writing a packed scene to path (nodes/cad_part_saver.gd hears it first, before the
## file is written). Each waiting part whose design this very packed scene holds puts its baked
## meshes and its large stored meshes into "<path>_forge", so the scene that is written points at
## those files. Only here is anything written beside a scene: never for a scene that was not
## saved, and for a Save As only beside the new scene (the old one and its files stay as they are).
## A part is matched to the packed scene by its design itself (the packed node at the part's place
## holds this part's document object), not by names: another scene told in the same frame, with
## the same root name, is not it; neither is a scene that inherits the part from a base scene
## without changing its design (that scene's file does not hold the design, and the meshes stay
## with the base scene).
static func scene_is_being_written(packed: PackedScene, path: String) -> void:
	var scene_path := ProjectSettings.localize_path(path)
	var state := packed.get_state() if packed != null else null
	if state == null or state.get_node_count() == 0 or not (scene_path.begins_with("res://") or scene_path.begins_with("user://")):
		return
	for root_id in _waiting.keys():
		var waiting: Dictionary = _waiting[root_id]
		var scene_root := instance_from_id(root_id) as Node
		# (Only what the editor said in this very frame: a save that failed leaves nothing behind.)
		if scene_root == null or int(waiting.frame) != Engine.get_process_frames():
			_waiting.erase(root_id)
			continue
		for part in (waiting.parts as Array).duplicate():
			if is_instance_valid(part) and _state_holds(state, scene_root, part, true):
				(waiting.parts as Array).erase(part)
				part._write_beside(scene_path)
		if (waiting.parts as Array).is_empty():
			_waiting.erase(root_id)


## True when a packed scene's state holds the design of part, a node of the scene under
## scene_root: the packed node at the part's place has a "document", or a "local_document" (an
## inheriting scene's own copy); the part's own object when same_object is asked, as in the packed
## scene the editor is writing right now.
static func _state_holds(state: SceneState, scene_root: Node, part: Node, same_object: bool) -> bool:
	var document_held: Variant = part.get("document")
	if document_held == null:
		return false
	var place := "." if part == scene_root else str(scene_root.get_path_to(part))
	for property_name in ["local_document", "document"]:
		var held: Variant = _state_value(state, place, property_name)
		if held == null:
			continue
		var own: Variant = part.get(property_name)
		return not same_object or (own != null and is_same(held, own))
	return false


## The scene this part sits in was saved (the editor tells every node of a scene after writing it,
## when the scene has the path it was saved to). The part's files were written while the scene was
## (scene_is_being_written); files beside the scene that no scene on disk points at any more are
## cleared away now (_clean_folder). A part that still waits was not in the scene that was
## written: nothing is written for it, unless there is no saver at all (the plugin is off). Then
## its files are written now, when its scene is the one the editor shows, and the scene, which
## still holds the meshes, is marked as changed: the next Save makes it point at the files. (A
## scene in a background tab is left as it is, meshes inside: there is no way to mark it, and it
## stays true to its file.) The part never saves the scene itself.
func _after_scene_save() -> void:
	var scene_root := _saved_with()
	if scene_root == null:
		return
	var scene_path := str(scene_root.scene_file_path)
	var waiting: Dictionary = _waiting.get(scene_root.get_instance_id(), {})
	if waiting.is_empty() or not (waiting.parts as Array).has(self):
		if scene_path != "":
			_clean_folder(scene_root, scene_path)
		return
	(waiting.parts as Array).erase(self)
	if (waiting.parts as Array).is_empty():
		_waiting.erase(scene_root.get_instance_id())
	if _saver != null or scene_path == "" or not FileAccess.file_exists(scene_path):
		return
	var editor: Object = Engine.get_singleton("EditorInterface") if Engine.is_editor_hint() else null
	if editor != null and editor.get_edited_scene_root() != scene_root:
		return
	var written: PackedScene = ResourceLoader.load(scene_path, "", ResourceLoader.CACHE_MODE_IGNORE)
	if written == null or not _state_holds(written.get_state(), scene_root, self, false) or not _write_beside(scene_path):
		return
	if editor != null:
		editor.mark_scene_as_unsaved()
	print("Holo Forge: the meshes of %s were written beside %s after the scene was; save the scene once more and it points at them." % [name, scene_path.get_file()])


## Puts this part's baked meshes and large stored meshes into "<scene_path>_forge". True when
## that changed where any of them is kept.
func _write_beside(scene_path: String) -> bool:
	var folder := scene_path.get_basename() + "_forge"
	var changed := _save_meshes(folder)
	var blobs_before := _blob_paths()
	save_mesh_blobs(folder)
	return changed or _blob_paths() != blobs_before


## Removes the files in the scene's folder ("<scene>_forge") that nothing points at any more (a
## newer bake or an edit took their place, or their body went), once a Save is over. A file stays
## while any of these points at it: a part of the scene (also an unsaved change), the scene's own
## file on disk (after a Save that failed that is the old scene, which still points at its files),
## or any other scene or resource file (a copy of the scene, a scene that inherits it): every one
## under res:// for a scene in the project, those in the scene's own folder for a user:// scene.
## Only files of the kinds the parts write are looked at (<part>_<body>_<12 hex>.res,
## <part>_mesh_<16 hex>.res); nothing else in the folder is touched.
static func _clean_folder(scene_root: Node, scene_path: String) -> void:
	var folder := scene_path.get_basename() + "_forge"
	# (Every part of the scene is told: the folder is looked at once per Save.)
	var turn := "%s|%d" % [scene_path, _save_count]
	if _cleaned == turn or not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(folder)):
		return
	_cleaned = turn
	if _forge_file == null:
		_forge_file = RegEx.create_from_string("_([0-9a-f]{12}|mesh_[0-9a-f]{16})\\.res$")
	var used := {}
	var parts: Array = scene_root.find_children("*", "Node3D", true, false)
	parts.append(scene_root)
	for part in parts:
		if part.has_method("_files_used"):
			for path in part._files_used():
				used[path] = true
	var unused := PackedStringArray()
	for file in DirAccess.get_files_at(folder):
		if _forge_file.search(file) != null and not used.has(folder.path_join(file)):
			unused.append(folder.path_join(file))
	if unused.is_empty():
		return
	unused = _not_named_by(unused, scene_path, true)
	if unused.is_empty():
		return
	var others := PackedStringArray()
	_resource_files("res://" if scene_path.begins_with("res://") else scene_path.get_base_dir(), others, 0)
	for other in others:
		if other != scene_path:
			unused = _not_named_by(unused, other, false)
			if unused.is_empty():
				return
	for path in unused:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
		_baked_files.erase(path)
		_saved_files.erase(path)


## The files of paths that the file at holder does not point at (by its dependencies). fresh reads
## it again; otherwise what was read is used while the file keeps its modified time and size.
static func _not_named_by(paths: PackedStringArray, holder: String, fresh: bool) -> PackedStringArray:
	var stamp := _stamp(holder)
	var known: Dictionary = _file_refs.get(holder, {})
	var named := ""
	if not fresh and not known.is_empty() and known.stamp == stamp:
		named = str(known.named)
	else:
		named = "\n".join(ResourceLoader.get_dependencies(holder))
		_file_refs[holder] = {"stamp": stamp, "named": named}
	var left := PackedStringArray()
	for path in paths:
		if not named.contains(path.get_file()):
			left.append(path)
	return left


## Every scene and resource file under folder (.tscn, .scn, .tres, .res), leaving out hidden
## folders and the "_forge" folders (which hold meshes only).
static func _resource_files(folder: String, out: PackedStringArray, depth: int) -> void:
	if depth > 24:
		return
	for file in DirAccess.get_files_at(folder):
		if file.get_extension().to_lower() in ["tscn", "scn", "tres", "res"]:
			out.append(folder.path_join(file))
	for sub in DirAccess.get_directories_at(folder):
		if not sub.begins_with(".") and not sub.ends_with("_forge"):
			_resource_files(folder.path_join(sub), out, depth + 1)


## The files this part's baked meshes and stored meshes are kept in now.
func _files_used() -> PackedStringArray:
	var paths := PackedStringArray()
	for body in body_nodes().values():
		var path := str(body.mesh.resource_path) if body.mesh != null else ""
		if path != "" and not path.contains("::"):
			paths.append(path)
	for path in _blob_paths():
		if path != "" and not path.contains("::"):
			paths.append(path)
	return paths


## Notes the baked mesh files this part's bodies were loaded from as they are right now (the
## editor calls it when the scene is opened), so a file that is damaged later is seen at the next
## Save without reading it.
func note_baked_files() -> void:
	for body in body_nodes().values():
		var path := str(body.mesh.resource_path) if body.mesh != null else ""
		if path != "" and not path.contains("::") and not _baked_files.has(path) and FileAccess.file_exists(path):
			_baked_files[path] = _stamp(path)


## Saves each baked mesh as a .res next to the scene, so the scene file stays small. Unsaved
## scenes keep meshes embedded. (The editor does this by itself while it writes a scene:
## scene_is_being_written.)
func externalize_meshes() -> void:
	if not Engine.is_editor_hint():
		return
	var scene_root := _scene_owner()
	var scene_path := scene_root.scene_file_path if scene_root != null else ""
	if scene_path == "":
		return
	_save_meshes(scene_path.get_basename() + "_forge")


## externalize_meshes() into a given folder. Every baked mesh is kept in
## <folder>/<part>_<body id>_<tag>.res, where the tag comes from what the mesh holds (its
## triangles and its look): a file is never written over with another mesh, so a scene on disk
## that points at it keeps the mesh it was saved with, also when a later Save fails. A mesh whose
## file is there and sound writes nothing; one whose file is gone or damaged is written again; one
## that cannot be written stays in the scene. True when where any mesh is kept changed.
func _save_meshes(folder: String) -> bool:
	var changed := false
	var nodes := body_nodes()
	for body_id in nodes:
		var body: MeshInstance3D = nodes[body_id]
		var mesh: Mesh = body.mesh
		if mesh == null:
			continue
		var held := str(mesh.resource_path)
		if held.contains("::"):
			held = ""
		# (A mesh that has its file here keeps it: a baked mesh never changes, a new bake is a new
		# mesh. Only one without a file here is given its tag, which reads all its triangles.)
		var stem := "%s_%s_" % [_node_name(name), body_id]
		var path := held if held.get_base_dir() == folder and held.get_file().begins_with(stem) and held.get_file().length() == stem.length() + 16 else "%s/%s%s.res" % [folder, stem, _bake_tag(body)]
		if not _baked_file_is_sound(path, mesh):
			DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder))
			# (path is not the mesh's own path here, or its file is gone or damaged.)
			if ResourceSaver.save(mesh, path, ResourceSaver.FLAG_COMPRESS) != OK or not FileAccess.file_exists(path):
				# Not written: the mesh stays in the scene, whatever file it pointed at before
				# (that one is another scene's, or the one that is gone or damaged).
				if held != "":
					mesh.resource_path = ""
					changed = true
				push_warning("Holo Forge: the baked mesh of %s could not be saved to %s; it stays in the scene." % [body.name, path])
				continue
			_baked_files[path] = _stamp(path)
		if held != path:
			mesh.take_over_path(path)
			changed = true
	return changed


## What a baked body's file is named after: for a mesh body what it was baked from (BAKE_META:
## the CadMesh's digest and its look), else the baked triangles and materials themselves.
static func _bake_tag(body: MeshInstance3D) -> String:
	var hashing := HashingContext.new()
	hashing.start(HashingContext.HASH_MD5)
	var signature := str(body.get_meta(BAKE_META, ""))
	if signature != "":
		hashing.update(signature.to_utf8_buffer())
	else:
		var mesh: Mesh = body.mesh
		for surface in mesh.get_surface_count():
			hashing.update(var_to_bytes(mesh.surface_get_arrays(surface)))
			hashing.update(_look_text(mesh.surface_get_material(surface), 0).to_utf8_buffer())
		hashing.update(("surfaces %d" % mesh.get_surface_count()).to_utf8_buffer())
	return hashing.finish().hex_encode().substr(0, 12)


## A material (or any value in it) as text that is the same for the same look: a resource with a
## file of its own by its path, another one by its stored properties.
static func _look_text(value: Variant, depth: int) -> String:
	if not (value is Object):
		return var_to_str(value)
	if value is Resource and str((value as Resource).resource_path) != "" and not str((value as Resource).resource_path).contains("::"):
		return str((value as Resource).resource_path)
	if depth > 3:
		return (value as Object).get_class()
	var parts := PackedStringArray([(value as Object).get_class()])
	for property in (value as Object).get_property_list():
		var property_name := str(property.name)
		if int(property.usage) & PROPERTY_USAGE_STORAGE and not property_name in ["resource_path", "resource_scene_unique_id", "script"]:
			parts.append("%s=%s" % [property_name, _look_text((value as Object).get(property_name), depth + 1)])
	return "{%s}" % ",".join(parts)


## True when the file at path holds mesh: it is as this session wrote, noted or checked it (the
## same modified time and size), or, looked at for the first time or changed since, it loads as
## a mesh with the same surfaces. A file that is missing, empty, cut short or another mesh's is not.
static func _baked_file_is_sound(path: String, mesh: Mesh) -> bool:
	if not FileAccess.file_exists(path):
		return false
	var stamp := _stamp(path)
	if _baked_files.get(path) == stamp:
		return true
	# (A file cut short or damaged can crash Godot's loader itself, so it is checked first.)
	if int(stamp[1]) < 16 or not RESOURCE_FILE.safe_to_load(path):
		return false
	var loaded := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as Mesh
	if loaded == null or loaded.get_surface_count() != mesh.get_surface_count():
		return false
	for surface in mesh.get_surface_count():
		if loaded is ArrayMesh and mesh is ArrayMesh and ((loaded as ArrayMesh).surface_get_array_len(surface) != (mesh as ArrayMesh).surface_get_array_len(surface) or (loaded as ArrayMesh).surface_get_array_index_len(surface) != (mesh as ArrayMesh).surface_get_array_index_len(surface)):
			return false
	if not loaded.get_aabb().is_equal_approx(mesh.get_aabb()):
		return false
	_baked_files[path] = stamp
	return true


## A file's [modified time, size].
static func _stamp(path: String) -> Array:
	return [FileAccess.get_modified_time(path), FileAccess.get_size(path)]


## Saves each large stored mesh of the design (a MeshBlob in a feature's options whose bytes are
## over MESH_BLOB.EMBED_LIMIT: Insert Mesh as a mesh body, Direct Edit) as a .res next to the
## scene, <scene>_forge/<part>_mesh_<digest>.res, so the scene file stays small. The name comes
## from the content: a blob already saved writes nothing, and undo states that share a blob share
## its file. Small blobs stay in the scene. Unsaved scenes keep their blobs embedded. Returns the
## paths of the blobs now kept beside the scene. (The editor does this by itself while it writes a
## scene: scene_is_being_written.)
func externalize_mesh_blobs() -> Array:
	var kept := []
	if not Engine.is_editor_hint() or document == null:
		return kept
	var scene_root := _scene_owner()
	var scene_path := scene_root.scene_file_path if scene_root != null else ""
	if scene_path == "":
		return kept
	return save_mesh_blobs(scene_path.get_basename() + "_forge")


## externalize_mesh_blobs() into a given folder. What keeps a Save from losing or changing a mesh:
##   - A file that is already there is trusted only when it is sound (_file_is_sound): one that
##     was damaged on disk, or holds something else, is written again from the design's own blob.
##   - A stored mesh that cannot be written (the folder or the file is not writable) really stays
##     in the scene: it lets go of whatever file it pointed at, so the scene file holds it.
##   - A stored mesh that is damaged itself (MeshBlob.check), or is not the one its file is named
##     after (the file was swapped), is never written and never given another file: the scene
##     keeps pointing at the file it pointed at, and the feature keeps its error until the right
##     file is back or the feature is deleted.
##   - A stored mesh that is not there (its file is gone, so the option came back empty) gets a
##     stand-in that only holds the file's path (MeshBlob.missing): the scene keeps pointing at the
##     file, so putting it back works also after a Save.
##   - Two stored meshes with the same content (one file inserted twice) share the one file.
func save_mesh_blobs(folder: String) -> Array:
	var kept := []
	if document == null:
		return kept
	var texts := {}
	for feature in _features():
		for key in feature.options.keys():
			var blob: Variant = feature.options[key]
			if blob == null:
				var gone := REGEN.stored_file(feature, str(key), texts)
				if gone != "":
					feature.options[key] = MESH_BLOB.missing(gone)
				continue
			if not (blob is Resource) or (blob as Resource).get_script() != MESH_BLOB or str(blob.missing_file()) != "" or not blob.is_large():
				continue
			var held := str(blob.resource_path)
			if held.contains("::"):
				held = ""
			var problem: String = blob.check()
			if problem != "" or REGEN.names_another(blob):
				push_warning("Holo Forge: %s It was not saved beside the scene%s." % [REGEN.stored_mesh_problem(feature), "; the scene keeps pointing at %s" % held.get_file() if held != "" else ""])
				continue
			var path := "%s/%s_mesh_%s.res" % [folder, _node_name(name), blob.short_digest()]
			if not _file_is_sound(path, blob):
				var damaged := FileAccess.file_exists(path)
				DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder))
				if ResourceSaver.save(blob, path, ResourceSaver.FLAG_COMPRESS) != OK or not FileAccess.file_exists(path):
					if held != "":
						blob.resource_path = ""
					push_warning("Holo Forge: the stored mesh of %s could not be saved to %s; it stays in the scene." % [feature.label, path])
					continue
				_saved_files[path] = {"md5": FileAccess.get_md5(path), "digest": str(blob.digest)}
				if damaged:
					push_warning("Holo Forge: %s (the stored mesh of %s) was damaged on disk and has been written again." % [path.get_file(), feature.label])
			if held != path:
				var holder: Resource = ResourceLoader.get_cached_ref(path) if ResourceLoader.has_cached(path) else null
				if holder != null and holder != blob and holder.get_script() == MESH_BLOB and str(holder.get("digest")) == str(blob.digest):
					# (The same mesh stored twice: both keep the one file, neither takes it from the other.)
					blob.set_path_cache(path)
				else:
					blob.take_over_path(path)
			if not kept.has(path):
				kept.append(path)
	return kept


## True when the file at path holds blob: it is as this session wrote or checked it (the same
## md5), or, the first time it is met in a session, it loads as a sound MeshBlob with the blob's
## digest. A file that is missing, empty, cut off, changed or another mesh's is not.
static func _file_is_sound(path: String, blob: Resource) -> bool:
	if not FileAccess.file_exists(path):
		return false
	var md5 := FileAccess.get_md5(path)
	var known: Dictionary = _saved_files.get(path, {})
	if not known.is_empty():
		return str(known.digest) == str(blob.digest) and str(known.md5) == md5
	var file := FileAccess.open(path, FileAccess.READ)
	var length := file.get_length() if file != null else 0
	if file != null:
		file.close()
	if length < 64 or not RESOURCE_FILE.safe_to_load(path):
		return false
	var loaded: Resource = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	if loaded == null or loaded.get_script() != MESH_BLOB or str(loaded.digest) != str(blob.digest) or loaded.check() != "":
		return false
	_saved_files[path] = {"md5": md5, "digest": str(blob.digest)}
	return true


## Forgets which files this session wrote or checked (tests start from scratch).
static func forget_saved_files() -> void:
	_saved_files.clear()
	_baked_files.clear()


## The file of every stored mesh of the design ("" for one kept in the scene), in order.
func _blob_paths() -> PackedStringArray:
	var paths := PackedStringArray()
	for feature in _features():
		for key in feature.options:
			var blob: Variant = feature.options[key]
			if blob is Resource and (blob as Resource).get_script() == MESH_BLOB:
				paths.append(str((blob as Resource).resource_path))
	return paths


## The features of the design, and of the inheriting scene's own copy of it when there is one
## (local_document: its stored meshes are written beside that scene too).
func _features() -> Array:
	var features := []
	if document != null:
		features.append_array(document.features)
	if local_document != null and local_document != document:
		features.append_array(local_document.features)
	return features


## Writes the baked bodies to a .glb (next to the scene unless a path is given). Returns the path
## ("" when writing failed). As core/export.gd export_part_scene: plain copies of the baked nodes,
## hidden bodies kept (marked hidden through an optional extension, so other tools can still open
## the file), and decals left out with a warning, since glTF can't hold them.
func export_glb(path := "") -> String:
	if path == "":
		var scene_root := _scene_owner()
		var base := scene_root.scene_file_path.get_base_dir() if scene_root != null and scene_root.scene_file_path != "" else "res://"
		path = base.path_join(_node_name(name).to_snake_case() + ".glb")
	if str(EXPORT.export_part_scene(self, path).path) == "":
		push_error("Holo Forge: exporting %s to %s failed." % [name, path])
		return ""
	var editor: Object = Engine.get_singleton("EditorInterface") if Engine.is_editor_hint() else null
	if editor != null:
		editor.get_resource_filesystem().update_file(path)
	print("Holo Forge: exported %s to %s" % [name, path])
	return path


## Selects this part and opens the Forge tab on it.
func edit_in_forge() -> void:
	var editor: Object = Engine.get_singleton("EditorInterface") if Engine.is_editor_hint() else null
	if editor == null:
		return
	editor.edit_node(self)
	editor.set_main_screen_editor("Forge")


static func default_material() -> StandardMaterial3D:
	if _default_material == null:
		_default_material = StandardMaterial3D.new()
		_default_material.albedo_color = Color(0.72, 0.75, 0.8)
		_default_material.roughness = 0.45
		_default_material.metallic = 0.1
	return _default_material


## Surface bodies' default material: drawn from both sides (they are open sheets), in the
## Forge view's surface color.
static func surface_material() -> StandardMaterial3D:
	if _surface_material == null:
		_surface_material = StandardMaterial3D.new()
		_surface_material.albedo_color = Color(0.93, 0.76, 0.45)
		_surface_material.roughness = 0.5
		_surface_material.metallic = 0.05
		_surface_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return _surface_material


## The body's trimesh collision; a two-sided body (a surface: an open sheet, a ramp) collides from
## both sides, not only along its face normals. wanted false removes it (RigidBody3D mode: the
## units and the Ground hold the collision).
func _sync_collision(body: MeshInstance3D, tess: Dictionary, scene_owner: Node, two_sided := false, wanted := true) -> void:
	var collision := body.get_node_or_null(COLLISION_NAME) as StaticBody3D
	if not generate_collision or not wanted:
		if collision != null:
			body.remove_child(collision)
			collision.queue_free()
		return
	if collision == null:
		collision = StaticBody3D.new()
		collision.name = COLLISION_NAME
		body.add_child(collision)
		collision.owner = scene_owner
		var shape_node := CollisionShape3D.new()
		shape_node.name = "Shape"
		collision.add_child(shape_node)
		shape_node.owner = scene_owner
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(TESSELLATE.collision_faces(tess))
	shape.backface_collision = two_sided
	(collision.get_node("Shape") as CollisionShape3D).shape = shape


## A Decal node per visible decal on this body, named after it; others are removed. Each sits on
## its face as the body is now (APPEARANCE.placed_decal), so it follows the face through edits;
## one whose face can't be found stays at its stored place, with a warning.
func _sync_decals(body: MeshInstance3D, body_id: String, shape: RefCounted, kernel: RefCounted, scene_owner: Node) -> void:
	# Nodes by decal id, a list each: entries without an id (or sharing one) still reuse theirs.
	var existing := {}
	for child in body.get_children():
		if child is Decal and child.has_meta(DECAL_META):
			var id := str(child.get_meta(DECAL_META))
			if not existing.has(id):
				existing[id] = []
			(existing[id] as Array).append(child)
	for info in document.decals:
		if str(info.get("body", "")) != body_id or not bool(info.get("visible", true)):
			continue
		var decal_id := str(info.get("id", ""))
		var pool: Array = existing.get(decal_id, [])
		var decal: Decal = pool.pop_front() if not pool.is_empty() else null
		if decal == null:
			decal = Decal.new()
			decal.set_meta(DECAL_META, decal_id)
			body.add_child(decal)
			decal.owner = scene_owner
		var label := str(info.get("name", "")).validate_node_name().strip_edges()
		# The collision node is found by its name, so a decal never takes it.
		if label == COLLISION_NAME:
			label += " Decal"
		decal.name = label if label != "" else "Decal"
		var placed := APPEARANCE.placed_decal(info, shape, kernel)
		if placed.has("error"):
			push_warning("Holo Forge: decal %s on %s stays where it was. %s" % [decal.name, document.body_name(body_id), placed.error])
		elif bool(placed.get("lost", false)):
			push_warning("Holo Forge: decal %s on %s can't find its face any more, so it stays where it was." % [decal.name, document.body_name(body_id)])
		decal.transform = APPEARANCE.decal_transform(placed)
		decal.size = APPEARANCE.decal_size(placed)
		decal.texture_albedo = MATERIAL_LIBRARY.load_texture(str(info.get("image", "")))
		decal.normal_fade = DECAL_NORMAL_FADE
	for pool in existing.values():
		for stale in pool:
			body.remove_child(stale)
			stale.queue_free()


func _scene_owner() -> Node:
	if Engine.is_editor_hint() and is_inside_tree():
		var edited := get_tree().edited_scene_root
		if edited != null and (edited == self or edited.is_ancestor_of(self)):
			return edited
	return owner if owner != null else self


static func _node_name(text: String) -> String:
	var clean := text.validate_node_name().strip_edges()
	return clean if clean != "" else "Body"
