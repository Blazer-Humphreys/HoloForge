@tool
extends RefCounted
## Holo Forge Phase 8 test fixtures (spec 5.0): small assemblies built through the real document,
## real features and REGEN.rebuild. A helper, not a test. Other teams may add functions; never
## change an existing one.
##
## Every fixture takes an optional kernel (one is made when it is null) and returns
## {"doc", "kernel", "result", "bodies": {name: body id}, "components": {name: comp id},
## "joints": {name: joint id}}. Sizes below are in mm (part space); the document stores meters.
## Plain boxes are Box primitives; bodies with holes, round bodies and slanted bars are sketches
## on the XY plane extruded along +Z (so their Z levels come from exact length inputs).

const DOCUMENT := preload("res://addons/holo_forge/core/document.gd")
const REGEN := preload("res://addons/holo_forge/core/regen.gd")
const SKETCH_DATA := preload("res://addons/holo_forge/core/sketch/sketch_data.gd")
const OPERATIONS := preload("res://addons/holo_forge/core/operations.gd")
const REFERENCES := preload("res://addons/holo_forge/core/references.gd")
const MESH := preload("res://addons/holo_forge/core/features/mesh.gd")
const MESH_BODY := preload("res://addons/holo_forge/core/mesh/mesh_body.gd")
const XFORM := preload("res://addons/holo_forge/core/assembly/xform64.gd")
const DATA := preload("res://addons/holo_forge/core/assembly/assembly_data.gd")
const SNAPS := preload("res://addons/holo_forge/core/assembly/snaps.gd")
const JOINT_MATH := preload("res://addons/holo_forge/core/assembly/joint_math.gd")

const MM := 0.001
## Four-bar pivots (mm): A and D on the ground 60 apart; |AB| = 20, |BC| = 50, |CD| = 40.
const FOUR_BAR_A := Vector2(0.0, 0.0)
const FOUR_BAR_D := Vector2(60.0, 0.0)
const FOUR_BAR_B := Vector2(0.0, 20.0)
## all_types() limits: rotations -30°..60°, slides -5..10 mm.
const ALL_TYPES_ROT := [-30.0, 60.0]
const ALL_TYPES_SLIDE := [-5.0, 10.0]


# --- Fixtures ------------------------------------------------------------------------------------

## Ground body Base (0,0,0)-(100,100,10); component Cube with body (40,40,40)-(60,60,60).
static func stack(kernel: RefCounted = null) -> Dictionary:
	var f := _start(kernel)
	_box(f, "Base", Vector3(0, 0, 0), Vector3(100, 100, 10), "")
	_box(f, "Cube", Vector3(40, 40, 40), Vector3(60, 60, 60), "Cube")
	return _finish(f)


## Ground body Base (-50,-50,0)-(50,50,10) with a Ø10 through hole on Z at (0,0); component Lever
## with body (-10,-10,10)-(95,10,20) and a Ø10 through hole on Z at (0,0). Lever tip (95, 0, 15).
static func lever(kernel: RefCounted = null) -> Dictionary:
	var f := _start(kernel)
	_lever_bodies(f)
	return _finish(f)


## lever() plus ground body Stop (40,20,10)-(60,50,20).
static func lever_stop(kernel: RefCounted = null) -> Dictionary:
	var f := _start(kernel)
	_lever_bodies(f)
	_box(f, "Stop", Vector3(40, 20, 10), Vector3(60, 50, 20), "")
	return _finish(f)


## Ground Base (-50,-50,0)-(80,50,10) with Ø4 holes at (0,0) and (30,0); components Gear1
## (cylinder r 20, z 10..20 on Z at (0,0)) and Gear2 (r 10, z 10..20 at (30,0)); revolutes Joint1
## (Gear1) and Joint2 (Gear2) from each gear's bottom circle centre to its hole's top circle centre.
static func gears(kernel: RefCounted = null) -> Dictionary:
	var f := _start(kernel)
	_plate(f, "Base", Vector2(-50, -50), Vector2(80, 50), [[0.0, 0.0, 2.0], [30.0, 0.0, 2.0]], 0.0, 10.0, "")
	_disc(f, "Gear1", Vector2(0, 0), 20.0, 10.0, 20.0, "Gear1")
	_disc(f, "Gear2", Vector2(30, 0), 10.0, 10.0, 20.0, "Gear2")
	_rebuild(f)
	for gear in [["Gear1", Vector2(0, 0), 20.0, "Joint1"], ["Gear2", Vector2(30, 0), 10.0, "Joint2"]]:
		var at: Vector2 = gear[1]
		var snap_a := circle_snap(f, gear[0], Vector3(at.x, at.y, 10), gear[2])
		var snap_b := circle_snap(f, "Base", Vector3(at.x, at.y, 10), 2.0)
		f.joints[gear[3]] = add_joint(f.doc, "revolute", f.components[gear[0]], snap_a, "", snap_b)
	return _finish(f, false)


## Ground Base (-20,-50,0)-(200,50,10) and Wall (30,-30,0)-(40,30,40); component Block
## (0,-10,10)-(20,10,30); an as-built slider on the Block's bottom face centre with slide axis X
## (positive moves toward the Wall; the gap is 10 mm); contact set {Block, Wall}; contact on.
static func slider_wall(kernel: RefCounted = null) -> Dictionary:
	var f := _start(kernel)
	_box(f, "Base", Vector3(-20, -50, 0), Vector3(200, 50, 10), "")
	_box(f, "Wall", Vector3(30, -30, 0), Vector3(40, 30, 40), "")
	_box(f, "Block", Vector3(0, -10, 10), Vector3(20, 10, 30), "Block")
	_rebuild(f)
	var picked := face_snap(f, "Block", Vector3(10, 0, 10), Vector3(0, 0, -1))
	f.joints["Slider"] = add_as_built(f.doc, f.result, "slider", f.components.Block, picked, "", {"slide_axis": "x"})
	_contact_set(f, [{"component": f.components.Block}, {"body": f.bodies.Wall}])
	return _finish(f, false)


## lever()'s Base; component Pin, a cylinder r 5 (exact fit), z -5..25 on Z at (0,0); a revolute
## from the Pin's bottom circle centre to the hole's bottom circle centre, turned over and offset
## 5 mm so the Pin stays where it is modelled; contact set {Pin, Base}; contact on.
static func pin_hole(kernel: RefCounted = null) -> Dictionary:
	var f := _start(kernel)
	_plate(f, "Base", Vector2(-50, -50), Vector2(50, 50), [[0.0, 0.0, 5.0]], 0.0, 10.0, "")
	_disc(f, "Pin", Vector2(0, 0), 5.0, -5.0, 25.0, "Pin")
	_rebuild(f)
	var snap_a := circle_snap(f, "Pin", Vector3(0, 0, -5), 5.0)
	var snap_b := circle_snap(f, "Base", Vector3(0, 0, 0), 5.0)
	f.joints["Joint1"] = add_joint(f.doc, "revolute", f.components.Pin, snap_a, "", snap_b, {"flip": true, "offset": [0.0, 0.0, 5.0 * MM]})
	_contact_set(f, [{"component": f.components.Pin}, {"body": f.bodies.Base}])
	return _finish(f, false)


## Ground body Base, a 10 mm cube at (0..10)³; components C1..Cn, 10 mm cubes in a row along X,
## each joined to the previous by a revolute at the shared face centre (a = its -X face, b = the
## previous one's +X face).
static func chain(n: int, kernel: RefCounted = null) -> Dictionary:
	var f := _start(kernel)
	_box(f, "Base", Vector3(0, 0, 0), Vector3(10, 10, 10), "")
	for i in range(1, n + 1):
		_box(f, "C%d" % i, Vector3(10 * i, 0, 0), Vector3(10 * i + 10, 10, 10), "C%d" % i)
	_rebuild(f)
	for i in range(1, n + 1):
		var previous := "Base" if i == 1 else "C%d" % (i - 1)
		var snap_a := face_snap(f, "C%d" % i, Vector3(10 * i, 5, 5), Vector3(-1, 0, 0))
		var snap_b := face_snap(f, previous, Vector3(10 * i, 5, 5), Vector3(1, 0, 0))
		f.joints["J%d" % i] = add_joint(f.doc, "revolute", f.components["C%d" % i], snap_a, f.components.get(previous, ""), snap_b)
	return _finish(f, false)


## A ground plate with pivots A (0,0) and D (60,0); bars AB (20), BC (50) and CD (40) as
## components (5 mm plates on top of the ground plate); as-built revolutes J1 (AB-ground at A),
## J2 (BC-AB at B), J3 (CD-BC at C) and J4 (CD-ground at D), each about Z at z = 10. The search
## places AB by J1, CD by J4 and BC by J2, so J3 closes the loop (it holds as built).
static func four_bar(kernel: RefCounted = null) -> Dictionary:
	var f := _start(kernel)
	var c := four_bar_c()
	_plate(f, "Base", Vector2(-10, -10), Vector2(70, 10), [], 0.0, 10.0, "")
	_bar(f, "AB", FOUR_BAR_A, FOUR_BAR_B, "AB")
	_bar(f, "BC", FOUR_BAR_B, c, "BC")
	_bar(f, "CD", c, FOUR_BAR_D, "CD")
	_rebuild(f)
	var at := func(p: Vector2) -> PackedFloat64Array:
		return XFORM.frame(PackedFloat64Array([p.x * MM, p.y * MM, 10.0 * MM]), PackedFloat64Array([0.0, 0.0, 1.0]))
	f.joints["J1"] = add_as_built_frame(f.doc, "revolute", f.components.AB, "", at.call(FOUR_BAR_A))
	f.joints["J2"] = add_as_built_frame(f.doc, "revolute", f.components.BC, f.components.AB, at.call(FOUR_BAR_B))
	f.joints["J3"] = add_as_built_frame(f.doc, "revolute", f.components.CD, f.components.BC, at.call(c))
	f.joints["J4"] = add_as_built_frame(f.doc, "revolute", f.components.CD, "", at.call(FOUR_BAR_D))
	return _finish(f, false)


## The four-bar's pivot C (mm): 50 from B and 40 from D, above the ground line.
static func four_bar_c() -> Vector2:
	var b := FOUR_BAR_B
	var d := FOUR_BAR_D
	var dist := b.distance_to(d)
	var along := (50.0 * 50.0 - 40.0 * 40.0 + dist * dist) / (2.0 * dist)
	var up := sqrt(50.0 * 50.0 - along * along)
	var u := (d - b) / dist
	var p := b + u * along
	var c1 := p + Vector2(-u.y, u.x) * up
	var c2 := p - Vector2(-u.y, u.x) * up
	return c1 if c1.y > c2.y else c2


## One component per joint type on a common Base (-100,-100,0)-(100,100,10): 10 mm cubes on top
## in a row (x = -60, -40, ..., 60), each joined from its bottom face centre to the Base's top
## face centre with an offset that keeps it where it is modelled; every DOF limited
## (rotations -30°..60°, slides -5..10 mm), values 0. Joints are named after their types.
static func all_types(kernel: RefCounted = null) -> Dictionary:
	var f := _start(kernel)
	_box(f, "Base", Vector3(-100, -100, 0), Vector3(100, 100, 10), "")
	var x := -60.0
	for joint_type in DATA.TYPES:
		_box(f, joint_type.capitalize(), Vector3(x - 5, -5, 10), Vector3(x + 5, 5, 20), joint_type.capitalize())
		x += 20.0
	_rebuild(f)
	var snap_b := face_snap(f, "Base", Vector3(0, 0, 10), Vector3(0, 0, 1))
	x = -60.0
	for joint_type in DATA.TYPES:
		var name: String = joint_type.capitalize()
		var snap_a := face_snap(f, name, Vector3(x, 0, 10), Vector3(0, 0, -1))
		var dofs := []
		for dof_name in DATA.dof_names(joint_type):
			var range_mm: Array = ALL_TYPES_ROT if DATA.is_rotation(dof_name) else ALL_TYPES_SLIDE
			var scale := deg_to_rad(1.0) if DATA.is_rotation(dof_name) else MM
			dofs.append({"value": 0.0, "min": float(range_mm[0]) * scale, "max": float(range_mm[1]) * scale, "limited_min": true, "limited_max": true, "rest": 0.0})
		var id := add_joint(f.doc, joint_type, f.components[name], snap_a, "", snap_b, {"offset": [x * MM, 0.0, 0.0], "dofs": dofs})
		_rename_joint(f.doc, id, name)
		f.joints[name] = id
		x += 20.0
	return _finish(f, false)


## slider_wall() with the Block made a mesh body (Tessellate, High, original not kept); the slider's
## Block side snaps to the mesh's bottom face group centre.
static func mesh_block(kernel: RefCounted = null) -> Dictionary:
	var f := slider_wall(kernel)
	var block_body: String = f.bodies.Block
	var made := MESH.add_tessellate(f.doc, [block_body], {"quality": "high", "keep_original": false})
	var outputs: Array = made.bodies
	var mesh_body := str(outputs[0])
	f.doc.bodies[mesh_body]["component"] = f.components.Block
	f.bodies["Block"] = mesh_body
	f.bodies["BlockBrep"] = block_body
	_rebuild(f)
	var group := group_at(f, "Block", Vector3(10, 0, 10), Vector3(0, 0, -1))
	var made_snap := SNAPS.make_snap("group_center", group, f.result, f.doc)
	var assembly: Dictionary = DATA.normalized(f.doc.assembly)
	for joint in assembly.joints:
		if str(joint.id) == str(f.joints.Slider):
			joint.a.snap = made_snap.get("snap", {})
	f.doc.assembly = assembly
	return f


## lever_stop() with a revolute "Lever" (f.joints.Lever: the Lever's bottom hole circle on the
## Base's top hole circle, value 0, unlimited) and contact set {Lever, Stop}; contact on. A positive
## angle swings the Lever's tip toward +Y: its side plane y = 10 reaches the Stop's vertical edge at
## (60, 20) at θ = acos(10 / R) − atan2(60, 20), R = √(60² + 20²) (about 9.34°). Added in Stage 2.
static func lever_stop_contact(kernel: RefCounted = null) -> Dictionary:
	var f := lever_stop(kernel)
	var snap_a := circle_snap(f, "Lever", Vector3(0, 0, 10), 5.0)
	var snap_b := circle_snap(f, "Base", Vector3(0, 0, 10), 5.0)
	var id := add_joint(f.doc, "revolute", f.components.Lever, snap_a, "", snap_b)
	_rename_joint(f.doc, id, "Lever")
	f.joints["Lever"] = id
	_contact_set(f, [{"component": f.components.Lever}, {"body": f.bodies.Stop}])
	return f


## lever_stop_contact() plus component Knob, a 10 mm cube (-45,-45,10)-(-35,-35,20) on an as-built
## revolute "Knob" about Z through (-40, -40, 10), and the link Knob -> Lever, ratio 1, offset 0:
## driving the Knob turns the Lever by the same angle. The Knob is in no contact set. Stage 2.
static func lever_stop_linked(kernel: RefCounted = null) -> Dictionary:
	var f := lever_stop_contact(kernel)
	_box(f, "Knob", Vector3(-45, -45, 10), Vector3(-35, -35, 20), "Knob")
	_rebuild(f)
	var world := XFORM.frame(PackedFloat64Array([-40.0 * MM, -40.0 * MM, 10.0 * MM]), PackedFloat64Array([0.0, 0.0, 1.0]))
	var knob := add_as_built_frame(f.doc, "revolute", f.components.Knob, "", world)
	_rename_joint(f.doc, knob, "Knob")
	f.joints["Knob"] = knob
	var assembly: Dictionary = DATA.normalized(f.doc.assembly)
	var link_id := DATA.new_id(assembly, "link")
	var link: Dictionary = DATA.LINK_DEFAULT.duplicate(true)
	link["id"] = link_id
	link["name"] = DATA.name_for("link", link_id)
	link["driver"] = {"joint": knob, "dof": 0}
	link["follower"] = {"joint": f.joints.Lever, "dof": 0}
	link["ratio"] = 1.0
	link["offset"] = 0.0
	(assembly.links as Array).append(link)
	f.doc.assembly = assembly
	return f


## slider_wall()'s layout with the Wall replaced by a ground Plate t_mm thick, (30,-30,0)-(30 + t,
## 30,40): Base, Plate, component Block, the as-built slider f.joints.Slider (axis X, the gap is
## 10 mm), contact set {Block, Plate}; contact on. Stage 2.
static func slider_plate(t_mm: float, kernel: RefCounted = null) -> Dictionary:
	var f := _start(kernel)
	_box(f, "Base", Vector3(-20, -50, 0), Vector3(200, 50, 10), "")
	_box(f, "Plate", Vector3(30, -30, 0), Vector3(30 + t_mm, 30, 40), "")
	_box(f, "Block", Vector3(0, -10, 10), Vector3(20, 10, 30), "Block")
	_rebuild(f)
	var picked := face_snap(f, "Block", Vector3(10, 0, 10), Vector3(0, 0, -1))
	f.joints["Slider"] = add_as_built(f.doc, f.result, "slider", f.components.Block, picked, "", {"slide_axis": "x"})
	_contact_set(f, [{"component": f.components.Block}, {"body": f.bodies.Plate}])
	return _finish(f, false)


## Two plates t_mm thick slanted 45° about Z (their boxes are not thin), 40 mm long along
## (1, -1)/√2 and t_mm across (1, 1)/√2: ground "Fin" centred at (10.5, 0), z 0..40; "Blade" in
## component Blade centred at the origin, z 10..30, on an as-built slider f.joints.Slider along X;
## a ground Base (-20,-60,-10)-(200,60,0); contact set {Blade, Fin}, contact on. Sliding the Blade
## 10.5 mm passes it through the Fin (the verifier's slanted thin case). Added in fix round 1.
static func slanted_plates(t_mm: float, kernel: RefCounted = null) -> Dictionary:
	var f := _start(kernel)
	_box(f, "Base", Vector3(-20, -60, -10), Vector3(200, 60, 0), "")
	var n := Vector2(1, 1).normalized()
	var u := Vector2(1, -1).normalized()
	for item in [["Fin", Vector2(10.5, 0), "", 0.0, 40.0], ["Blade", Vector2(0, 0), "Blade", 10.0, 30.0]]:
		var c: Vector2 = item[1]
		var h := t_mm * 0.5
		var made := _sketch(f)
		_polygon(made[1], [c - u * 20.0 - n * h, c + u * 20.0 - n * h, c + u * 20.0 + n * h, c - u * 20.0 + n * h])
		_extrude(f, made[0], c, float(item[3]), float(item[4]), str(item[0]), str(item[2]))
	_rebuild(f)
	var world := XFORM.frame(PackedFloat64Array([0.0, 0.0, 20.0 * MM]), PackedFloat64Array([0.0, 0.0, 1.0]))
	f.joints["Slider"] = add_as_built_frame(f.doc, "slider", f.components.Blade, "", world, {"slide_axis": "x"})
	_contact_set(f, [{"component": f.components.Blade}, {"body": f.bodies.Fin}])
	return _finish(f, false)


## slider_wall()'s layout with the Wall at x = wall_mm..wall_mm + 10 (the Block's +X face is at
## 20 mm, so the gap is wall_mm − 20): Base, Wall, component Block, the as-built slider
## f.joints.Slider (axis X), contact set {Block, Wall}; contact on. Added in fix round 1.
static func slider_gap(wall_mm: float, kernel: RefCounted = null) -> Dictionary:
	var f := _start(kernel)
	_box(f, "Base", Vector3(-20, -50, 0), Vector3(200, 50, 10), "")
	_box(f, "Wall", Vector3(wall_mm, -30, 0), Vector3(wall_mm + 10.0, 30, 40), "")
	_box(f, "Block", Vector3(0, -10, 10), Vector3(20, 10, 30), "Block")
	_rebuild(f)
	var picked := face_snap(f, "Block", Vector3(10, 0, 10), Vector3(0, 0, -1))
	f.joints["Slider"] = add_as_built(f.doc, f.result, "slider", f.components.Block, picked, "", {"slide_axis": "x"})
	_contact_set(f, [{"component": f.components.Block}, {"body": f.bodies.Wall}])
	return _finish(f, false)


## stack()'s bodies moved by offset_mm, with no joint: Base (0,0,0)-(100,100,10) and component Cube
## (40,40,40)-(60,60,60), both + offset_mm. Added in fix round 1 (snaps far from the origin).
static func stack_at(offset_mm: Vector3, kernel: RefCounted = null) -> Dictionary:
	var f := _start(kernel)
	_box(f, "Base", Vector3(0, 0, 0) + offset_mm, Vector3(100, 100, 10) + offset_mm, "")
	_box(f, "Cube", Vector3(40, 40, 40) + offset_mm, Vector3(60, 60, 60) + offset_mm, "Cube")
	_rebuild(f)
	return f


## slanted_plates()' layout with a 60×30×20 mm lump on each plate (one body each, joined by a
## neck), so each body is thin only along its t_mm strip: ground "Fin" (strip centred at (10.5, 0),
## z 0..40, lump above y = 20) and "Blade" in component Blade (strip at the origin, z 10..30, lump
## below y = -20) on an as-built slider f.joints.Slider along X; Base; contact set {Blade, Fin},
## contact on. Sliding the Blade 10.5 mm passes the strips through each other. Fix round 2 (SB2).
static func thin_lump(t_mm: float, kernel: RefCounted = null) -> Dictionary:
	var f := _start(kernel)
	_box(f, "Base", Vector3(-20, -60, -10), Vector3(200, 60, 0), "")
	var n := Vector2(1, 1).normalized()
	var u := Vector2(1, -1).normalized()
	var h := t_mm * 0.5
	var fa := Vector2(10.5, 0) - u * 20.0
	var fb := Vector2(10.5, 0) + u * 20.0
	var fin := _sketch(f)
	_polygon(fin[1], [fb + n * h, fb - n * h, fa - n * h, Vector2((fa - n * h).x, 20.0), Vector2(-40, 20), Vector2(-40, 50), Vector2(30, 50), Vector2(30, 20),
		Vector2((fa + n * h).x, 20.0), fa + n * h])
	_extrude(f, fin[0], Vector2(0, 35), 0.0, 40.0, "Fin", "")
	var a := -u * 20.0
	var b := u * 20.0
	var blade := _sketch(f)
	_polygon(blade[1], [a + n * h, a - n * h, b - n * h, Vector2((b - n * h).x, -20.0), Vector2(-16, -20), Vector2(-16, -50), Vector2(44, -50), Vector2(44, -20),
		Vector2((b + n * h).x, -20.0), b + n * h])
	_extrude(f, blade[0], Vector2(14, -35), 10.0, 30.0, "Blade", "Blade")
	_rebuild(f)
	var world := XFORM.frame(PackedFloat64Array([0.0, 0.0, 20.0 * MM]), PackedFloat64Array([0.0, 0.0, 1.0]))
	f.joints["Slider"] = add_as_built_frame(f.doc, "slider", f.components.Blade, "", world, {"slide_axis": "x"})
	_contact_set(f, [{"component": f.components.Blade}, {"body": f.bodies.Fin}])
	return _finish(f, false)


## A solid side_mm cube "Block" (0, -side/2, 10)-(side, side/2, 10 + side) in component Block on an
## as-built slider f.joints.Slider (axis X) toward a ground Wall (30,-30,0)-(40,30,40), on a Base;
## contact set {Block, Wall}, contact on. Fix round 2 (N4).
static func cube_block(side_mm: float, kernel: RefCounted = null) -> Dictionary:
	var f := _start(kernel)
	_box(f, "Base", Vector3(-20, -50, 0), Vector3(200, 50, 10), "")
	_box(f, "Wall", Vector3(30, -30, 0), Vector3(40, 30, 40), "")
	_box(f, "Block", Vector3(0, -side_mm / 2.0, 10), Vector3(side_mm, side_mm / 2.0, 10 + side_mm), "Block")
	_rebuild(f)
	var picked := face_snap(f, "Block", Vector3(side_mm / 2.0, 0, 10), Vector3(0, 0, -1))
	f.joints["Slider"] = add_as_built(f.doc, f.result, "slider", f.components.Block, picked, "", {"slide_axis": "x"})
	_contact_set(f, [{"component": f.components.Block}, {"body": f.bodies.Wall}])
	return _finish(f, false)


## A ground Base plate (-50,-50,0)-(50,50,10) with a Ø10 hole; component Lever, a plate
## (-10,-10,10)-(95,10,20) with a Ø10 hole, on an as-built cylindrical joint f.joints.Cyl about Z
## through (0, 0, 10) (DOF 0 slides along Z, DOF 1 turns); a ground Stop (40,20,31)-(60,50,40) high
## above the Lever; contact set {Lever, Stop}, contact on, Step step_mm. The Lever first touches the
## Stop with its turn at 9.34° when lifted past 11 mm. Fix round 2 (N1, from the verifier's probe).
static func helix_lever(step_mm: float, kernel: RefCounted = null) -> Dictionary:
	var f := _start(kernel)
	_plate(f, "Base", Vector2(-50, -50), Vector2(50, 50), [[0.0, 0.0, 5.0]], 0.0, 10.0, "")
	_plate(f, "Lever", Vector2(-10, -10), Vector2(95, 10), [[0.0, 0.0, 5.0]], 10.0, 20.0, "Lever")
	_box(f, "Stop", Vector3(40, 20, 31), Vector3(60, 50, 40), "")
	_rebuild(f)
	var world := XFORM.frame(PackedFloat64Array([0.0, 0.0, 10.0 * MM]), PackedFloat64Array([0.0, 0.0, 1.0]))
	f.joints["Cyl"] = add_as_built_frame(f.doc, "cylindrical", f.components.Lever, "", world)
	_contact_set(f, [{"component": f.components.Lever}, {"body": f.bodies.Stop}])
	var assembly: Dictionary = DATA.normalized(f.doc.assembly)
	assembly.contact["step"] = step_mm * MM
	f.doc.assembly = assembly
	return f


# --- Helpers other tests use ---------------------------------------------------------------------

## Adds a joint to doc.assembly (normalized); returns its id. settings are merged into the entry
## ("offset", "angle", "flip", "slide_axis", "dofs", "as_built", ...).
static func add_joint(doc: Resource, joint_type: String, comp_a: String, snap_a: Dictionary, comp_b: String, snap_b: Dictionary, settings := {}) -> String:
	var assembly: Dictionary = DATA.normalized(doc.assembly)
	var id := DATA.new_id(assembly, "joint")
	var entry := {
		"id": id, "name": DATA.name_for("joint", id), "type": joint_type,
		"a": {"component": comp_a, "snap": snap_a.duplicate(true)}, "b": {"component": comp_b, "snap": snap_b.duplicate(true)},
		"dofs": DATA.retype_dofs("rigid", [], joint_type), "slide_axis": DATA.DEFAULT_SLIDE_AXIS.get(joint_type, "z"),
	}
	entry.merge(settings.duplicate(true), true)
	(assembly.joints as Array).append(entry)
	doc.assembly = DATA.normalized(assembly)
	return id


## An as-built joint (C2.4) at the frame of picked (a snap on side a's unit, resolved in the current
## pose): side a keeps the snap, side b a fixed frame P_b⁻¹ · W. Returns its id.
static func add_as_built(doc: Resource, result: Dictionary, joint_type: String, comp_a: String, picked: Dictionary, comp_b: String,
		settings := {}) -> String:
	var poses: Dictionary = preload("res://addons/holo_forge/core/assembly/solver.gd").solve(doc, result, null).poses
	var pose_a: PackedFloat64Array = poses.get(comp_a, XFORM.identity())
	var pose_b: PackedFloat64Array = poses.get(comp_b, XFORM.identity())
	var world := XFORM.compose(pose_a, PackedFloat64Array(picked.frame))
	var frames := JOINT_MATH.as_built_frames(pose_a, pose_b, world)
	var all := {"as_built": true}
	all.merge(settings, true)
	return add_joint(doc, joint_type, comp_a, picked, comp_b, SNAPS.fixed_snap(frames[1]), all)


## An as-built joint at the part-space frame world, with fixed frames on both sides.
static func add_as_built_frame(doc: Resource, joint_type: String, comp_a: String, comp_b: String, world: PackedFloat64Array, settings := {}) -> String:
	var assembly: Dictionary = DATA.normalized(doc.assembly)
	var pose_a := DATA.placement(assembly, comp_a) if comp_a != "" else XFORM.identity()
	var pose_b := DATA.placement(assembly, comp_b) if comp_b != "" else XFORM.identity()
	var frames := JOINT_MATH.as_built_frames(pose_a, pose_b, world)
	var all := {"as_built": true}
	all.merge(settings, true)
	return add_joint(doc, joint_type, comp_a, SNAPS.fixed_snap(frames[0]), comp_b, SNAPS.fixed_snap(frames[1]), all)


## The plane face of a fixture body whose outward normal is normal and whose centre is nearest
## to point_mm, as a face reference ({} when there is none).
static func face_ref(f: Dictionary, body_name: String, point_mm: Vector3, normal: Vector3) -> Dictionary:
	var body_id: String = f.bodies[body_name]
	var shape: RefCounted = f.result.bodies[body_id].shape
	var best := -1
	var best_d := INF
	for i in shape.face_count():
		var info: Dictionary = shape.face_info(i)
		if not bool(info.get("planar", false)) or not (info.get("normal") is Vector3) or (info.normal as Vector3).dot(normal) < 0.999:
			continue
		var d := (info.point as Vector3).distance_to(point_mm * MM)
		if d < best_d:
			best_d = d
			best = i
	if best < 0:
		return {}
	return REFERENCES.from_pick({"kind": "face", "body": body_id, "index": best}, f.result)


## A face_center snap on that face.
static func face_snap(f: Dictionary, body_name: String, point_mm: Vector3, normal: Vector3) -> Dictionary:
	return _made(SNAPS.make_snap("face_center", face_ref(f, body_name, point_mm, normal), f.result, f.doc), "face_center on " + body_name)


## The circle edge of a fixture body with this centre (mm) and radius (mm), as an edge reference.
static func circle_ref(f: Dictionary, body_name: String, center_mm: Vector3, radius_mm: float) -> Dictionary:
	var body_id: String = f.bodies[body_name]
	var shape: RefCounted = f.result.bodies[body_id].shape
	for i in shape.edge_count():
		var info: Dictionary = shape.edge_info(i)
		if str(info.get("type", "")) != "circle" or not (info.get("center") is Vector3):
			continue
		if (info.center as Vector3).distance_to(center_mm * MM) < 1e-7 and absf(float(info.get("radius", 0.0)) - radius_mm * MM) < 1e-7:
			return REFERENCES.from_pick({"kind": "edge", "body": body_id, "index": i}, f.result)
	return {}


## A circle_center snap on that circle.
static func circle_snap(f: Dictionary, body_name: String, center_mm: Vector3, radius_mm: float) -> Dictionary:
	return _made(SNAPS.make_snap("circle_center", circle_ref(f, body_name, center_mm, radius_mm), f.result, f.doc), "circle_center on " + body_name)


## The face group of a mesh fixture body that is flat with this normal and nearest point_mm, as a
## mesh_group reference.
static func group_at(f: Dictionary, body_name: String, point_mm: Vector3, normal: Vector3) -> Dictionary:
	var body_id: String = f.bodies[body_name]
	var shape: RefCounted = f.result.bodies[body_id].shape
	var best := -1
	var best_d := INF
	for i in shape.face_count():
		var info: Dictionary = shape.face_info(i)
		if not bool(info.get("planar", false)) or (info.normal as Vector3).dot(normal) < 0.999:
			continue
		var d := (info.point as Vector3).distance_to(point_mm * MM)
		if d < best_d:
			best_d = d
			best = i
	if best < 0:
		return {}
	var info: Dictionary = shape.face_info(best)
	return REFERENCES.from_pick({"kind": "face", "body": body_id, "index": best, "point": info.point, "normal": info.normal}, f.result)


## Rebuilds the fixture's document (after a change) and returns the new result.
static func rebuild(f: Dictionary) -> Dictionary:
	_rebuild(f)
	return f.result


# --- Building ------------------------------------------------------------------------------------

static func _lever_bodies(f: Dictionary) -> void:
	_plate(f, "Base", Vector2(-50, -50), Vector2(50, 50), [[0.0, 0.0, 5.0]], 0.0, 10.0, "")
	_plate(f, "Lever", Vector2(-10, -10), Vector2(95, 10), [[0.0, 0.0, 5.0]], 10.0, 20.0, "Lever")


static func _start(kernel: RefCounted) -> Dictionary:
	return {
		"doc": DOCUMENT.new(), "kernel": kernel if kernel != null else REGEN.make_kernel(), "result": {},
		"bodies": {}, "components": {}, "joints": {},
	}


static func _finish(f: Dictionary, build := true) -> Dictionary:
	if build:
		_rebuild(f)
	return f


static func _rebuild(f: Dictionary) -> void:
	SNAPS.clear_cache()
	f["result"] = REGEN.rebuild(f.doc, f.kernel)
	var errors: Variant = f.result.get("errors", {})
	if (errors is Dictionary or errors is Array) and not errors.is_empty():
		push_error("Holo Forge assembly fixture: the rebuild failed: %s" % [errors])


static func _made(made: Dictionary, what: String) -> Dictionary:
	if made.has("error"):
		push_error("Holo Forge assembly fixture: %s: %s" % [what, made.error])
		return {}
	return made.snap


## A Box primitive from min to max (mm); a component named component_name when it is not "".
static func _box(f: Dictionary, name: String, low: Vector3, high: Vector3, component_name: String) -> void:
	var doc: Resource = f.doc
	var size := (high - low)
	var feature: Resource = doc.add_feature("box", "Box", {
		"length": doc.make_input(_mm(size.x), "length"), "height": doc.make_input(_mm(size.y), "length"), "width": doc.make_input(_mm(size.z), "length"),
	}, {"position": Vector3((low.x + high.x) * 0.5, low.y, (low.z + high.z) * 0.5) * MM, "operation": OPERATIONS.NEW_COMPONENT if component_name != "" else OPERATIONS.NEW_BODY})
	_register(f, feature, name, component_name)


## A plate on the XY plane: rectangle low-high (mm) with circular holes [[x, y, r]] (mm), extruded
## from z0 to z1 (mm).
static func _plate(f: Dictionary, name: String, low: Vector2, high: Vector2, holes: Array, z0: float, z1: float, component_name: String) -> void:
	var sketch := _sketch(f)
	var s: RefCounted = sketch[1]
	_polygon(s, [low, Vector2(high.x, low.y), high, Vector2(low.x, high.y)])
	var inside := (low + high) * 0.5
	for hole in holes:
		s.add_circle(s.add_point(Vector2(hole[0], hole[1]) * MM), float(hole[2]) * MM)
	# A point inside the plate but outside every hole picks the profile.
	var tries := [inside, low.lerp(high, 0.8), low.lerp(high, 0.2), Vector2(low.x, high.y).lerp(Vector2(high.x, low.y), 0.15)]
	for p in tries:
		var clear := true
		for hole in holes:
			clear = clear and (p as Vector2).distance_to(Vector2(hole[0], hole[1])) > float(hole[2]) + 0.5
		if clear:
			inside = p
			break
	_extrude(f, sketch[0], inside, z0, z1, name, component_name)


## A cylinder about Z: circle at center (mm) of radius r (mm), from z0 to z1 (mm).
static func _disc(f: Dictionary, name: String, center: Vector2, r: float, z0: float, z1: float, component_name: String) -> void:
	var sketch := _sketch(f)
	var s: RefCounted = sketch[1]
	s.add_circle(s.add_point(center * MM), r * MM)
	_extrude(f, sketch[0], center, z0, z1, name, component_name)


## A 6 mm wide bar from p to q (mm, 3 mm past each end), 5 mm thick on top of z = 10.
static func _bar(f: Dictionary, name: String, p: Vector2, q: Vector2, component_name: String) -> void:
	var u := (q - p).normalized()
	var n := Vector2(-u.y, u.x) * 3.0
	var a := p - u * 3.0
	var b := q + u * 3.0
	var sketch := _sketch(f)
	_polygon(sketch[1], [a - n, b - n, b + n, a + n])
	_extrude(f, sketch[0], (p + q) * 0.5, 10.0, 15.0, name, component_name)


static func _sketch(f: Dictionary) -> Array:
	var doc: Resource = f.doc
	var feature: Resource = doc.add_feature("sketch", "Sketch", {}, SKETCH_DATA.new_options(SKETCH_DATA.ORIGIN_PLANES.xy, "xy"))
	return [feature, SKETCH_DATA.new(feature, doc)]


static func _polygon(s: RefCounted, points: Array) -> void:
	var ids := []
	for p in points:
		ids.append(s.add_point((p as Vector2) * MM))
	for i in ids.size():
		s.add_line(ids[i], ids[(i + 1) % ids.size()])


static func _extrude(f: Dictionary, sketch: Resource, inside_mm: Vector2, z0: float, z1: float, name: String, component_name: String) -> void:
	var doc: Resource = f.doc
	var feature: Resource = doc.add_feature("extrude", "Extrude", {
		"distance": doc.make_input(_mm(z1 - z0), "length"), "start_offset": doc.make_input(_mm(z0), "length"),
	}, {
		"profiles": [{"kind": "profile", "sketch": sketch.id, "point": inside_mm * MM}],
		"operation": OPERATIONS.NEW_COMPONENT if component_name != "" else OPERATIONS.NEW_BODY, "start": "offset",
	})
	_register(f, feature, name, component_name)


## Gives a body-making feature its body (named name) and, when component_name is not "", a new
## top-level component of that name holding it.
static func _register(f: Dictionary, feature: Resource, name: String, component_name: String) -> void:
	var doc: Resource = f.doc
	var body_id: String = doc.new_body(feature.id)
	feature.options["body_id"] = body_id
	doc.bodies[body_id]["name"] = name
	f.bodies[name] = body_id
	if component_name != "":
		var component_id: String = doc.new_component(feature.id)
		feature.options["component_id"] = component_id
		doc.components[component_id]["name"] = component_name
		doc.bodies[body_id]["component"] = component_id
		f.components[component_name] = component_id


static func _contact_set(f: Dictionary, members: Array) -> void:
	var assembly: Dictionary = DATA.normalized(f.doc.assembly)
	var id := DATA.new_id(assembly, "contact")
	var entry: Dictionary = DATA.CONTACT_SET_DEFAULT.duplicate(true)
	entry["id"] = id
	entry["name"] = DATA.name_for("contact", id)
	entry["members"] = members
	(assembly.contact_sets as Array).append(entry)
	assembly.contact["enabled"] = true
	f.doc.assembly = assembly


static func _rename_joint(doc: Resource, joint_id: String, name: String) -> void:
	var assembly: Dictionary = DATA.normalized(doc.assembly)
	for joint in assembly.joints:
		if str(joint.id) == joint_id:
			joint["name"] = name
	doc.assembly = assembly


## A length in mm as an input expression ("10 mm"), exact for the values the fixtures use.
static func _mm(value: float) -> String:
	return "%s mm" % String.num(value, 6)
