@tool
extends RefCounted
## The "pull the handles" hook's assemble and mesh sections (tests/holo_forge_handles_editor_test.gd).
## A helper of that hook, not a test of its own. Handles are dragged with real mouse events
## (tests/holo_forge_mouse.gd pull()) on the hook's fixture parts: stack() (Place Component),
## all_types() (Drive on every DOF of every joint type, the Joint panel) and mesh_block() (Direct
## Edit's move arrows, Plane Cut's offset).

const CATALOG := preload("res://addons/holo_forge/tools/catalog.gd")
const DATA := preload("res://addons/holo_forge/core/assembly/assembly_data.gd")
const XFORM := preload("res://addons/holo_forge/core/assembly/xform64.gd")
const MODEL := preload("res://tests/holo_forge_handles_model_checks.gd")
const UNITS := preload("res://addons/holo_forge/core/units.gd")
const FIXTURES := preload("res://tests/holo_forge_assembly_fixtures.gd")
const MM := 0.001


static func run(m, hook, section: String) -> void:
	match section:
		"assemble":
			await _place(m, hook)
			await _drive_all(m, hook)
			await _joint_panel(m, hook)
		"mesh":
			await _direct_edit(m, hook)
			await _plane_cut(m, hook)


static func _assembly(m) -> Dictionary:
	return DATA.normalized(m.ws.doc.assembly)


static func _joint(m, id: String) -> Dictionary:
	for joint in _assembly(m).get("joints", []):
		if joint is Dictionary and str(joint.id) == id:
			return joint
	return {}


## The value a DOF shows in the open command's preview.
static func _shown(m, joint_id: String, dof: int) -> float:
	var cmd = m.ws.command
	if cmd == null:
		return NAN
	var values: PackedFloat64Array = ((cmd.preview.get("joints", {}) as Dictionary).get(joint_id, {}) as Dictionary).get("values", PackedFloat64Array())
	return values[dof] if dof < values.size() else NAN


# --- Place Component -----------------------------------------------------------------------------

static func _place(m, hook) -> void:
	var ws = m.ws
	if not await hook.edit_fixture("stack"):
		return
	var f: Dictionary = hook.designs.stack
	var cube_body: String = f.bodies.Cube
	var center := Vector3(0.05, 0.05, 0.05)
	await m.look(center, 0.6, -0.5, 0.32)
	var begun := MODEL.begin(m)
	ws.place_component(str(f.components.Cube))
	await m.frames(3)
	if not m.check(ws.command != null and str(ws.command.type) == "assemble:place", "Place Component should open on Cube."):
		return
	await hook.shot("handles_place_component.png")
	# The three move arrows start at one point: each takes its own press along its shaft.
	var move := Vector3.ZERO
	for axis in ["x", "y", "z"]:
		var got: float = await MODEL.pull_arrow(m, "move_" + axis, 26.0 if axis != "z" else -26.0, "Place Move %s pulled" % axis.to_upper())
		if is_finite(got):
			move["xyz".find(axis)] = got
	var pose: Transform3D = ws.viewport.body_pose(cube_body)
	m.check((pose * center).distance_to(center + move) < 1e-7 and pose.basis.is_equal_approx(Basis.IDENTITY), "The cube should move by the pulled amounts (%s, moved %s)." % [pose * center - center, move])
	# The turn dots (each about its axis through the box centre).
	var turns := Vector3.ZERO
	for axis in ["x", "y", "z"]:
		var got: float = await MODEL.pull_angle(m, "turn_" + axis, 22.0, "Place Turn %s dot turned" % axis.to_upper())
		if is_finite(got):
			turns["xyz".find(axis)] = m.value_of("turn_" + axis, "angle")
	pose = ws.viewport.body_pose(cube_body)
	var want := Basis(Vector3.RIGHT, turns.x) * Basis(Vector3.UP, turns.y) * Basis(Vector3.BACK, turns.z)
	m.check((pose * center).distance_to(center + move) < 1e-6 and pose.basis.is_equal_approx(want), "The cube should turn about its centre by the dots' angles (%s; basis %s, expected %s)." % [turns, pose.basis, want])
	await MODEL.ok_step(m, begun, "Forge: Place Cube", "Place Component")


# --- Drive: every DOF of every joint type --------------------------------------------------------

static func _drive_all(m, hook) -> void:
	var ws = m.ws
	if not await hook.edit_fixture("types"):
		return
	var f: Dictionary = hook.designs.types
	var x := -60.0
	for joint_type in DATA.TYPES:
		var name: String = joint_type.capitalize()
		var at := Vector3(x * MM, 0.0, 0.012)
		x += 20.0
		var names := DATA.dof_names(joint_type)
		if names.is_empty():
			continue
		var id := str(f.joints[name])
		await m.look(at, 0.5, -0.65, 0.16)
		var begun := MODEL.begin(m)
		ws.drive_joint(id)
		await m.frames(3)
		if not m.check(ws.command != null and str(ws.command.type) == "assemble:drive", "Drive should open on %s." % name):
			continue
		if joint_type == "ball":
			await hook.shot("handles_drive_ball_rings.png")
		for i in names.size():
			var key := "dof%d_value" % i
			var rotation: bool = DATA.is_rotation(names[i])
			var h: Dictionary = m.handle(key, "ring" if rotation else "slide")
			if not m.check(not h.is_empty(), "%s Drive should show a %s for %s (handles %s)." % [name, "ring" if rotation else "slide", names[i], m.handle_keys()]):
				continue
			var path: Variant = m.ring_path(h, 3) if rotation else m.screen_along(h) * 18.0
			var r: Dictionary = await m.pull(h, path)
			if not bool(r.get("ok", false)):
				continue
			var kind := UNITS.KIND_ANGLE if rotation else UNITS.KIND_LENGTH
			m.check_value(key, kind, float(r.value), "%s %s dragged" % [name, names[i]], 6)
			var limits: Array = limits_of(rotation)
			# (The joint is driven from the field's text, which keeps 6 decimals of the drag.)
			var reached := clampf(float(m.value_of(key, kind)), float(limits[0]), float(limits[1]))
			m.check(absf(_shown(m, id, i) - reached) < 1e-9, "%s %s should reach the dragged value within its limits (%s, expected %s)." % [name, names[i], _shown(m, id, i), reached])
			m.check(not bool(ws.command.get("dragging")), "Drive should hear the drag end (dragging is still on).")
		if joint_type == "revolute":
			# Past the limit: a quarter turn stops at -30 or 60 degrees and the status says so.
			var h: Dictionary = m.handle("dof0_value", "ring")
			var r: Dictionary = await m.pull(h, m.ring_path(h, 12)) if not h.is_empty() else {}
			if bool(r.get("ok", false)):
				var limits: Array = limits_of(true)
				var reached := clampf(float(r.value), float(limits[0]), float(limits[1]))
				m.check(absf(_shown(m, id, 0) - reached) < 1e-9 and (absf(reached - float(limits[0])) < 1e-12 or absf(reached - float(limits[1])) < 1e-12),
					"A quarter turn should stop Revolute at its limit (%s)." % rad_to_deg(_shown(m, id, 0)))
				m.check(str(ws.panel.info("status")) != "", "The status row should say why the drive stopped.")
		await MODEL.ok_step(m, begun, "Forge: Drive " + name, "Drive " + name)


## all_types()' limits in base units: [min, max].
static func limits_of(rotation: bool) -> Array:
	if rotation:
		return [deg_to_rad(FIXTURES.ALL_TYPES_ROT[0]), deg_to_rad(FIXTURES.ALL_TYPES_ROT[1])]
	return [FIXTURES.ALL_TYPES_SLIDE[0] * MM, FIXTURES.ALL_TYPES_SLIDE[1] * MM]


# --- The Joint panel's handles -------------------------------------------------------------------

static func _joint_panel(m, hook) -> void:
	var ws = m.ws
	var f: Dictionary = hook.designs.types
	var x := -60.0
	for joint_type in DATA.TYPES:
		var name: String = joint_type.capitalize()
		var at := Vector3(x * MM, 0.0, 0.012)
		x += 20.0
		if not joint_type in ["revolute", "slider"]:
			continue
		var id := str(f.joints[name])
		await m.look(at, 0.5, -0.65, 0.16)
		var begun := MODEL.begin(m)
		ws.edit_joint(id)
		await m.frames(3)
		if not m.check(ws.command != null and str(ws.command.type) == "assemble:joint", "Editing %s should open the Joint panel." % name):
			continue
		var rotation: bool = joint_type == "revolute"
		var h: Dictionary = m.handle("dof0_value", "ring" if rotation else "slide")
		if not m.check(not h.is_empty(), "The Joint panel should show %s's %s (handles %s)." % [name, "ring" if rotation else "slide", m.handle_keys()]):
			ws.cancel_command()
			continue
		var r: Dictionary = await m.pull(h, m.ring_path(h, 3) if rotation else m.screen_along(h) * 18.0)
		if bool(r.get("ok", false)):
			m.check_value("dof0_value", UNITS.KIND_ANGLE if rotation else UNITS.KIND_LENGTH, float(r.value), "%s's Joint panel handle dragged" % name, 6)
			var limits: Array = limits_of(rotation)
			m.check(absf(_shown(m, id, 0) - clampf(float(r.value), float(limits[0]), float(limits[1]))) < 1e-9, "The Joint panel's preview should show %s at the dragged value (%s)." % [name, _shown(m, id, 0)])
		await MODEL.ok_step(m, begun, "Forge: Edit " + name, "Joint panel " + name)


# --- Direct Edit ---------------------------------------------------------------------------------

static func _direct_edit(m, hook) -> void:
	var ws = m.ws
	if not await hook.edit_fixture("mesh"):
		return
	var block: String = hook.designs.mesh.bodies.Block
	var box: AABB = m.bbox(block)
	await m.look_at_box(box, 0.6, -0.5, 3.0)
	ws.selection.clear()
	ws.mesh_selection.clear()
	ws.selection.append({"kind": "body", "body": block, "index": -1, "point": Vector3.ZERO})
	ws._selection_changed(true)
	var begun := MODEL.begin(m)
	ws.run_tool(CATALOG.find("mesh.modify.direct_edit"))
	await m.frames(3)
	var tool = ws.mesh_direct_edit
	if not m.check(tool.active, "Direct Edit should open (%s)." % ws.last_message):
		return
	# One triangle of the face looking most at the camera, clicked.
	var spot := Vector2.INF
	var view: Control = ws.viewport
	var y := 40.0
	while y < view.size.y - 40.0 and not spot.is_finite():
		var xx := 40.0
		while xx < view.size.x - 40.0:
			var p := Vector2(xx, y)
			xx += 16.0
			if m.covered(p):
				continue
			var hit: Dictionary = view.face_hit_at(p)
			if str(hit.get("body", "")) == block:
				spot = p
				break
		y += 16.0
	if not m.check(spot.is_finite(), "The block should be under the mouse somewhere."):
		tool.cancel()
		return
	await m.click_view(spot)
	m.check(ws.mesh_selection.count() == 1, "A click should select one triangle (%d)." % ws.mesh_selection.count())
	await m.press(tool.buttons().move)
	await m.frames(2)
	m.check(m.handles().size() == 3, "Move should show three arrows (%s)." % [m.handle_keys()])
	for axis in ["x", "y", "z"]:
		var h: Dictionary = m.handle(axis, "arrow")
		if h.is_empty():
			m.check(false, "Direct Edit should show its %s arrow." % axis)
			continue
		var from: Vector3 = tool._selection_center()
		var count: int = tool.steps.size()
		var r: Dictionary = await m.pull(h, m.screen_along(h) * (28.0 if axis != "y" else -28.0))
		if not bool(r.get("ok", false)):
			continue
		var moved: Vector3 = tool._selection_center() - from
		var want: Vector3 = tool.AXES[axis] * float(r.value)
		m.check(tool.steps.size() == count + 1 and tool.steps[tool.steps.size() - 1] == "move" and moved.distance_to(want) < 1e-6,
			"Direct Edit's %s arrow should move the triangle by the drag as one step (moved %s, expected %s; steps %s)." % [axis.to_upper(), moved, want, tool.steps])
	await m.press(tool.buttons().done)
	await m.frames(4)
	m.check(not tool.active and m.action() == int(begun.action) + 1 and m.undo_name() == "Forge: Mesh: Direct Edit", "Done should be one undo step named Forge: Mesh: Direct Edit (%s)." % m.undo_name())
	var accepted: String = m.doc_print()
	await m.undo()
	m.check(m.doc_print() == str(begun.print), "Undo should take Direct Edit's moves back exactly.")
	await m.redo()
	m.check(m.doc_print() == accepted, "Redo should put them again exactly.")


# --- Plane Cut: the offset below zero ------------------------------------------------------------

static func _plane_cut(m, hook) -> void:
	var ws = m.ws
	var block: String = hook.designs.mesh.bodies.Block
	var box: AABB = m.bbox(block)
	# A construction plane through the block's middle, then the cut 5 mm or so under it.
	ws.run_tool(CATALOG.find("mesh.construct.offset_plane"))
	await m.frames(2)
	if not m.check(ws.command != null, "Offset Plane should open in Mesh."):
		return
	ws._on_reference_picked({"kind": "origin", "name": "xy"})
	await MODEL.set_values(m, {"distance": UNITS.format_value(box.get_center().z, UNITS.KIND_LENGTH, ws.doc.units)})
	ws.accept_command()
	await m.frames(3)
	var plane_id := str(ws.doc.features.back().id)
	var frame: Dictionary = ws.result.construction.get(plane_id, {})
	if not m.check(not frame.is_empty(), "The construction plane should be made."):
		return
	ws.selection.clear()
	ws.mesh_selection.clear()
	ws.selection.append({"kind": "body", "body": block, "index": -1, "point": Vector3.ZERO})
	ws._selection_changed(true)
	await m.look_at_box(box, 0.7, -0.3, 3.0)
	var begun := MODEL.begin(m)
	ws.run_tool(CATALOG.find("mesh.modify.plane_cut"))
	await m.frames(3)
	if not m.check(ws.command != null, "Plane Cut should open."):
		return
	ws.panel.activate_selection("plane")
	ws._on_reference_picked({"kind": "construct", "feature": plane_id})
	await m.frames(4)
	var h: Dictionary = m.handle("offset", "arrow")
	if not m.check(not h.is_empty() and float(h.get("min", 0.0)) < 0.0, "Plane Cut should show its signed offset arrow (%s)." % [m.handle_keys()]):
		return
	await hook.shot("handles_plane_cut.png")
	var r: Dictionary = await m.pull(h, m.screen_along(h) * -30.0)
	if not bool(r.get("ok", false)):
		return
	var offset := float(r.value)
	m.check(offset < 0.0, "Pulling the offset arrow back should take it below zero (%s)." % offset)
	m.check_value("offset", UNITS.KIND_LENGTH, offset, "Plane Cut offset pulled below zero")
	await m.frames(6)
	await m.focus_view()
	await m.key(KEY_ENTER)
	await m.frames(4)
	var cut: AABB = m.bbox(block)
	var level: float = (frame.origin as Vector3).z + offset * (frame.normal as Vector3).z
	m.check(ws.command == null and absf(cut.position.z - level) < 1e-5 and cut.end.z > level, "The cut should keep the block above the pulled plane at %s mm (box %s)." % [level / MM, cut])
	m.check(m.action() == int(begun.action) + 1 and m.undo_name() == "Forge: Mesh: Plane Cut", "Plane Cut should be one undo step named Forge: Mesh: Plane Cut (%s)." % m.undo_name())
	var accepted: String = m.doc_print()
	await m.undo()
	m.check(m.doc_print() == str(begun.print), "Undo should take the cut back exactly.")
	await m.redo()
	m.check(m.doc_print() == accepted, "Redo should cut again exactly.")
