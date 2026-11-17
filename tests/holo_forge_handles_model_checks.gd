@tool
extends RefCounted
## The "pull the handles" hook's model sections (tests/holo_forge_handles_editor_test.gd): primitives,
## features, insert, inspect and edges. A helper of that hook, not a test of its own. Every handle
## is dragged with real mouse events (tests/holo_forge_mouse.gd pull()); what is set up around the
## drags (a part, a sketch, a pick) goes through the workspace as the other hooks do, since the
## drags are what this hook checks.

const CATALOG := preload("res://addons/holo_forge/tools/catalog.gd")
const SKETCH := preload("res://addons/holo_forge/core/sketch/sketch_data.gd")
const OPERATIONS := preload("res://addons/holo_forge/core/operations.gd")
const REFERENCES := preload("res://addons/holo_forge/core/references.gd")
const ANALYSIS := preload("res://addons/holo_forge/core/analysis.gd")
const APPEARANCE := preload("res://addons/holo_forge/core/appearance.gd")
const UNITS := preload("res://addons/holo_forge/core/units.gd")
const MM := 0.001
const RED := "builtin:paint_red"
const IMAGE := "user://holo_forge_handles_test/grid.png"


static func run(m, hook, section: String) -> void:
	match section:
		"primitives":
			await _primitives(m, hook)
		"features":
			await _features(m, hook)
		"insert":
			await _insert(m, hook)
		"inspect":
			await _inspect(m, hook)
		"edges":
			await _edges(m, hook)


# --- Shared --------------------------------------------------------------------------------------

## What the design is before a command opens: its text and the undo position.
static func begin(m) -> Dictionary:
	return {"print": m.doc_print(), "action": m.action()}


## OK pressed with the mouse: the command closes as one undo step named name ("" takes any name);
## undo gives the design of begun back exactly, redo the accepted one. Returns true when all held.
static func ok_step(m, begun: Dictionary, name: String, what: String) -> bool:
	await m.press_ok()
	var ws = m.ws
	var ok: bool = m.check(ws.command == null, "%s: OK should close the panel (%s)." % [what, ws.last_message])
	ok = m.check(m.action() == int(begun.action) + 1, "%s: OK should be one undo step (%d -> %d)." % [what, begun.action, m.action()]) and ok
	if name != "":
		ok = m.check(m.undo_name() == name, "%s: the undo step should be named %s (%s)." % [what, name, m.undo_name()]) and ok
	var accepted: String = m.doc_print()
	await m.undo()
	ok = m.check(m.doc_print() == str(begun.print), "%s: undo should put the design back exactly." % what) and ok
	await m.redo()
	ok = m.check(m.doc_print() == accepted, "%s: redo should make it again exactly." % what) and ok
	return ok


## Panel values set as the panel would (for what is not a drag: a kind, a size, a typed value).
static func set_values(m, values: Dictionary) -> void:
	var merged: Dictionary = m.ws.command_values.duplicate(true)
	merged.merge(values, true)
	m.ws.set_command_values(merged)
	await m.frames(2)


## Pulls a view arrow by pixels along its own screen direction and checks its field; returns the
## dragged value (NAN when the drag could not be made).
static func pull_arrow(m, key: String, pixels: float, what: String) -> float:
	var h: Dictionary = m.handle(key, "arrow")
	if not m.check(not h.is_empty(), "%s: the %s arrow should show (handles %s)." % [what, key, m.handle_keys()]):
		return NAN
	var r: Dictionary = await m.pull(h, m.screen_along(h) * pixels)
	if not bool(r.get("ok", false)):
		return NAN
	m.check_value(key, UNITS.KIND_LENGTH, float(r.value), what)
	# (The model is built from the field's text, which keeps 4 decimals of the drag.)
	return m.value_of(key, UNITS.KIND_LENGTH)


## Pulls an angle dot round its centre by pixels and checks its field; returns the angle.
static func pull_angle(m, key: String, pixels: float, what: String) -> float:
	var h: Dictionary = m.handle(key, "angle")
	if not m.check(not h.is_empty(), "%s: the %s dot should show (handles %s)." % [what, key, m.handle_keys()]):
		return NAN
	var r: Dictionary = await m.pull(h, m.screen_along(h) * pixels)
	if not bool(r.get("ok", false)):
		return NAN
	m.check_value(key, UNITS.KIND_ANGLE, float(r.value), what)
	return m.value_of(key, UNITS.KIND_ANGLE)


## Pulls a point handle by a screen offset and checks the field holds the point the drag gives.
static func pull_point(m, key: String, offset: Vector2, what: String) -> Variant:
	var h: Dictionary = m.handle(key, "point")
	if not m.check(not h.is_empty(), "%s: the %s point should show (handles %s)." % [what, key, m.handle_keys()]):
		return null
	var r: Dictionary = await m.pull(h, offset)
	if not bool(r.get("ok", false)):
		return null
	var got: Variant = m.ws.command_values.get(key)
	var want: Vector3 = r.value
	m.check(got is Vector3 and (got as Vector3).distance_to(want) < 1e-9 and want.distance_to(h.position) > 1e-6,
		"%s: the %s point should be where the drag left it (%s, expected %s, from %s)." % [what, key, got, want, h.position])
	return want


static func add_box(m, name: String, low_mm: Vector3, high_mm: Vector3) -> String:
	var ws = m.ws
	var doc: Resource = ws.doc
	var ids := [""]
	ws.change("Handles Test Box", func() -> void:
		var size := high_mm - low_mm
		var feature: Resource = doc.add_feature("box", "Box", {
			"length": doc.make_input("%s mm" % size.x, "length"), "height": doc.make_input("%s mm" % size.y, "length"), "width": doc.make_input("%s mm" % size.z, "length"),
		}, {"position": Vector3((low_mm.x + high_mm.x) * 0.5, low_mm.y, (low_mm.z + high_mm.z) * 0.5) * MM, "operation": OPERATIONS.NEW_BODY})
		feature.options["body_id"] = doc.new_body(feature.id)
		doc.bodies[feature.options.body_id]["name"] = name
		ids[0] = str(feature.options.body_id))
	await m.frames(2)
	return str(ids[0])


static func face(m, body_id: String, normal: Vector3) -> int:
	var shape: RefCounted = m.shape_of(body_id)
	if shape == null:
		return -1
	for f in shape.face_count():
		var info: Dictionary = shape.face_info(f)
		if info.get("planar", false) and (info.normal as Vector3).is_equal_approx(normal):
			return f
	return -1


static func face_point(m, body_id: String, normal: Vector3) -> Vector3:
	var f := face(m, body_id, normal)
	return m.shape_of(body_id).face_info(f).point if f >= 0 else Vector3.INF


static func body_of_command(m) -> String:
	var cmd = m.ws.command
	return str(cmd.feature.options.get("body_id", "")) if cmd != null and cmd.get("feature") != null else ""


static func rect_sketch(m, a: Vector2, b: Vector2) -> void:
	var ws = m.ws
	ws.create_sketch(SKETCH.ORIGIN_PLANES.xz, "xz")
	ws.sketch_editor.start_tool("rect_2pt")
	ws.sketch_editor.tool_click(a, {}, {})
	ws.sketch_editor.tool_click(b, {}, {})
	ws.run_action("finish_sketch")
	await m.frames(2)


static func image_path() -> String:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(IMAGE.get_base_dir()))
	if not FileAccess.file_exists(IMAGE):
		var image := Image.create(64, 32, false, Image.FORMAT_RGBA8)
		image.fill(Color(0.2, 0.6, 0.9))
		image.save_png(IMAGE)
	return IMAGE


# --- primitives ----------------------------------------------------------------------------------

static func _primitives(m, hook) -> void:
	var ws = m.ws
	if await hook.blank_part() == null:
		return
	await m.look(Vector3(0.0, 0.03, 0.0), 0.65, -0.42, 0.34)
	# Box: three size arrows and the position point.
	var begun := begin(m)
	ws.run_tool(CATALOG.find("solid.create.box"))
	await m.frames(3)
	if not m.check(ws.command != null and str(ws.command.feature.type) == "box", "Box should open."):
		return
	var body := body_of_command(m)
	var label := str(ws.command.feature.label)
	await hook.shot("handles_box_arrows.png")
	var height := await pull_arrow(m, "height", 40.0, "Box height pulled up")
	var length := await pull_arrow(m, "length", 30.0, "Box length pulled out")
	var width := await pull_arrow(m, "width", -24.0, "Box width pulled in")
	var where: Variant = await pull_point(m, "position", Vector2(36.0, 14.0), "Box position dragged")
	var l: float = m.value_of("length", "length")
	var w: float = m.value_of("width", "length")
	var h: float = m.value_of("height", "length")
	var box: AABB = m.bbox(body)
	m.check(is_finite(height) and is_finite(length) and is_finite(width) and box.size.distance_to(Vector3(l, h, w)) < 1e-7,
		"The box should be the pulled size %s (it is %s)." % [Vector3(l, h, w), box.size])
	m.check(absf(m.volume_mm3(body) - l * w * h * 1e9) <= l * w * h * 1e9 * 1e-6, "The box's volume should be L x W x H (%s mm3)." % m.volume_mm3(body))
	if where is Vector3:
		var p: Vector3 = where
		m.check(absf(box.get_center().x - p.x) < 1e-7 and absf(box.get_center().z - p.z) < 1e-7 and absf(box.position.y - p.y) < 1e-7,
			"The box should stand where its point was dragged (%s, box %s)." % [p, box])
	await ok_step(m, begun, "Forge: Create " + label, "Box")
	# Cylinder: a pull, then Esc leaves the design as it was.
	begun = begin(m)
	ws.run_tool(CATALOG.find("solid.create.cylinder"))
	await m.frames(3)
	if m.check(ws.command != null, "Cylinder should open."):
		await pull_arrow(m, "height", 30.0, "Cylinder height before Esc")
		await m.escape()
		m.check(ws.command == null and m.doc_print() == str(begun.print) and m.action() == int(begun.action), "Esc after a drag should leave the design as it was.")
	begun = begin(m)
	ws.run_tool(CATALOG.find("solid.create.cylinder"))
	await m.frames(3)
	if m.check(ws.command != null, "Cylinder should open again."):
		body = body_of_command(m)
		label = str(ws.command.feature.label)
		await pull_arrow(m, "height", 35.0, "Cylinder height pulled up")
		await pull_arrow(m, "diameter", 28.0, "Cylinder diameter pulled out")
		var r: float = m.value_of("diameter", "length") * 0.5
		h = m.value_of("height", "length")
		var v := PI * r * r * h * 1e9
		m.check(absf(m.volume_mm3(body) - v) <= v * 1e-6, "The cylinder's volume should be pi r^2 h of its pulled sizes (%s vs %s mm3)." % [m.volume_mm3(body), v])
		await ok_step(m, begun, "Forge: Create " + label, "Cylinder")
	begun = begin(m)
	ws.run_tool(CATALOG.find("solid.create.sphere"))
	await m.frames(3)
	if m.check(ws.command != null, "Sphere should open."):
		body = body_of_command(m)
		label = str(ws.command.feature.label)
		await pull_arrow(m, "diameter", -20.0, "Sphere diameter pulled in")
		var r: float = m.value_of("diameter", "length") * 0.5
		var v := 4.0 / 3.0 * PI * r * r * r * 1e9
		m.check(absf(m.volume_mm3(body) - v) <= v * 1e-5, "The sphere's volume should be 4/3 pi r^3 of its pulled diameter (%s vs %s mm3)." % [m.volume_mm3(body), v])
		await ok_step(m, begun, "Forge: Create " + label, "Sphere")


# --- features ------------------------------------------------------------------------------------

static func _features(m, hook) -> void:
	var ws = m.ws
	if await hook.blank_part() == null:
		return
	await rect_sketch(m, Vector2(0, 0), Vector2(0.04, 0.02))
	await rect_sketch(m, Vector2(0.07, 0), Vector2(0.1, 0.02))
	await m.look(Vector3(0.05, 0.01, -0.01), 0.55, -0.5, 0.3)
	# Extrude: the profile clicked, the distance typed, then its arrow pulled.
	var begun := begin(m)
	ws.run_tool(CATALOG.find("solid.create.extrude"))
	await m.frames(2)
	if not m.check(ws.command != null, "Extrude should open."):
		return
	await m.click_view(ws.viewport.project(Vector3(0.02, 0.0, -0.01)))
	m.check((ws.command_values.get("profiles", []) as Array).size() == 1, "A click inside the rectangle should pick its profile (%s)." % [ws.command_values.get("profiles", [])])
	await m.type_into("distance", "10")
	var body := body_of_command(m)
	var label := str(ws.command.feature.label)
	await hook.shot("handles_extrude_arrow.png")
	var d := await pull_arrow(m, "distance", 36.0, "Extrude distance pulled up")
	m.check(absf(m.volume_mm3(body) - 800.0 * d / MM) <= 800.0 * d / MM * 1e-6, "The extrusion should be 40 x 20 x the pulled distance (%s mm3, %s mm)." % [m.volume_mm3(body), d / MM])
	if not await ok_step(m, begun, "Forge: Create " + label, "Extrude"):
		return
	var height := d
	# Offset Face on the top face.
	begun = begin(m)
	ws.run_tool(CATALOG.find("solid.modify.offset_face"))
	await m.frames(2)
	if m.check(ws.command != null, "Offset Face should open."):
		await m.click_view(ws.viewport.project(Vector3(0.02, height, -0.01)))
		await m.type_into("distance", "2")
		label = str(ws.command.feature.label)
		var off := await pull_arrow(m, "distance", 30.0, "Offset Face distance pulled")
		var v := 800.0 * (height + off) / MM
		m.check(absf(m.volume_mm3(body) - v) <= v * 1e-6, "Offset Face should raise the top by the pulled distance (%s vs %s mm3)." % [m.volume_mm3(body), v])
		if await ok_step(m, begun, "Forge: Create " + label, "Offset Face"):
			height += off
	# Press Pull on the right-hand end face offsets it; on an edge it is a fillet, with no arrow.
	await m.look(Vector3(0.04, height * 0.5, -0.01), 1.1, -0.35, 0.22)
	begun = begin(m)
	ws.run_tool(CATALOG.find("solid.modify.press_pull"))
	await m.frames(2)
	if m.check(ws.command != null, "Press Pull should open."):
		await m.click_view(ws.viewport.project(Vector3(0.04, height * 0.5, -0.01)))
		m.check(ws.command != null and str(ws.command.feature.type) == "offset_face", "Press Pull on a face should offset it (%s)." % [ws.command.feature.type if ws.command != null else "closed"])
		await m.type_into("distance", "3")
		label = str(ws.command.feature.label) if ws.command != null else ""
		var off := await pull_arrow(m, "distance", 26.0, "Press Pull on a face pulled")
		var v := (0.04 * 0.02 * height + 0.02 * height * off) * 1e9
		m.check(absf(m.volume_mm3(body) - v) <= v * 1e-6, "Press Pull should push the end face out by the pulled distance (%s vs %s mm3)." % [m.volume_mm3(body), v])
		await ok_step(m, begun, "Forge: Create " + label, "Press Pull on a face")
	begun = begin(m)
	ws.run_tool(CATALOG.find("solid.modify.press_pull"))
	await m.frames(2)
	if ws.command != null:
		var shape: RefCounted = m.shape_of(body)
		var edge := -1
		for e in shape.edge_count():
			var info: Dictionary = shape.edge_info(e)
			var mid: Vector3 = info.midpoint
			if info.type == "line" and absf(mid.y - height) < 1e-6 and absf(mid.z) < 1e-6:
				edge = e
		if edge >= 0:
			await m.click_view(ws.viewport.project(shape.edge_info(edge).midpoint))
		m.check(ws.command != null and str(ws.command.feature.type) == "fillet" and m.handle("distance").is_empty(), "Press Pull on an edge should be a fillet, with no arrow (%s, %s)." % [ws.command.feature.type if ws.command != null else "closed", m.handle_keys()])
		await m.escape()
		m.check(m.doc_print() == str(begun.print), "Esc should drop the edge's Press Pull.")
	# Surface Extrude of the second rectangle.
	await m.look(Vector3(0.085, 0.01, -0.01), 0.55, -0.5, 0.25)
	begun = begin(m)
	ws.run_tool(CATALOG.find("surface.create.extrude"))
	await m.frames(2)
	if m.check(ws.command != null, "Surface Extrude should open."):
		m.check(await m.clear_view([Vector3(0.085, 0.0, -0.01)]), "Some framing should show the second rectangle clear of the panel.")
		var at: Vector2 = ws.viewport.project(Vector3(0.085, 0.0, -0.01))
		var under: Dictionary = ws.picker.pick(at)
		await m.click_view(at)
		m.check((ws.command_values.get("profiles", []) as Array).size() == 1, "A click inside the second rectangle should pick its profile (%s; under the press %s, kinds %s, active %s, covered %s)." % [ws.command_values.get("profiles", []), under, ws._active_kinds(), ws.panel.active_selection_key, m.covered(at)])
		await m.type_into("distance", "10")
		var surface := body_of_command(m)
		label = str(ws.command.feature.label)
		var dist := await pull_arrow(m, "distance", 30.0, "Surface Extrude distance pulled")
		var box: AABB = m.bbox(surface)
		m.check(absf(box.size.y - dist) < 1e-7, "The surface should rise by the pulled distance (%s vs %s)." % [box.size.y, dist])
		await ok_step(m, begun, "Forge: Create " + label, "Surface Extrude")
	# Offset Plane from the ground plane.
	begun = begin(m)
	ws.run_tool(CATALOG.find("solid.construct.offset_plane"))
	await m.frames(2)
	if m.check(ws.command != null, "Offset Plane should open."):
		ws._on_reference_picked({"kind": "origin", "name": "xz"})
		await m.type_into("distance", "30")
		await m.look(Vector3(0.0, 0.03, 0.0), 0.6, -0.3, 0.3)
		var plane: Resource = ws.command.feature
		var off := await pull_arrow(m, "distance", 34.0, "Offset Plane distance pulled")
		var c: Dictionary = ws.result.construction.get(plane.id, {})
		m.check(not c.is_empty() and absf((c.origin as Vector3).y - off) < 1e-7, "The plane should sit at the pulled distance (%s, %s)." % [c.get("origin"), off])
		await ok_step(m, begun, "Forge: Create " + str(plane.label), "Offset Plane")


# --- insert --------------------------------------------------------------------------------------

static func _insert(m, hook) -> void:
	var ws = m.ws
	if await hook.blank_part() == null:
		return
	var block := await add_box(m, "Block", Vector3(-20, 0, -20), Vector3(20, 10, 20))
	await m.look(Vector3(0.0, 0.0, 0.0), 0.6, -0.45, 0.3)
	# Fastener: a hex bolt at the origin going down; its length arrow and its position point.
	var begun := begin(m)
	ws.run_tool(CATALOG.find("solid.insert.insert_fastener"))
	await m.frames(2)
	if m.check(ws.command != null and str(ws.command.feature.type) == "fastener", "Insert Fastener should open."):
		await set_values(m, {"kind": "hex_bolt", "size": "M6", "direction": "down", "position": Vector3(0.0, 0.03, 0.0)})
		ws.recompute()
		await m.frames(2)
		var bolt := body_of_command(m)
		var label := str(ws.command.feature.label)
		var before: float = m.value_of("length", "length")
		var tall: float = m.bbox(bolt).size.y
		var length := await pull_arrow(m, "length", 30.0, "Bolt length pulled")
		m.check(absf(m.bbox(bolt).size.y - tall - (length - before)) < 1e-7, "The bolt should grow by the pulled length (%s vs %s)." % [m.bbox(bolt).size.y - tall, length - before])
		var where: Variant = await pull_point(m, "position", Vector2(30.0, 10.0), "Bolt position dragged")
		if where is Vector3:
			var box: AABB = m.bbox(bolt)
			m.check(absf(box.get_center().x - (where as Vector3).x) < 1e-7 and absf(box.get_center().z - (where as Vector3).z) < 1e-7, "The bolt should move with its point (%s, %s)." % [where, box.get_center()])
		await ok_step(m, begun, "Forge: Create " + label, "Fastener")
	# Canvas on the ground plane: its centre dragged.
	begun = begin(m)
	ws.run_tool(CATALOG.find("solid.insert.canvas"))
	await m.frames(2)
	if m.check(ws.command != null, "Canvas should open."):
		ws._on_reference_picked({"kind": "origin", "name": "xz"})
		ws.command.set_image(image_path())
		await set_values(m, {"width": "60"})
		ws.refresh_view()
		await m.frames(2)
		var where: Variant = await pull_point(m, "center", Vector2(-40.0, 24.0), "Canvas centre dragged")
		var canvas: Dictionary = ws.command.entry() if ws.command != null else {}
		if where is Vector3:
			m.check((canvas.get("origin", Vector3.INF) as Vector3).distance_to(where) < 1e-9, "The canvas should move with its centre (%s, %s)." % [canvas.get("origin"), where])
		await ok_step(m, begun, "", "Canvas")
	# Decal on the block's top face: its position dragged on the face.
	begun = begin(m)
	ws.run_tool(CATALOG.find("solid.insert.decal"))
	await m.frames(2)
	if m.check(ws.command != null, "Decal should open."):
		ws._on_reference_picked(REFERENCES.from_pick({"kind": "face", "body": block, "index": face(m, block, Vector3.UP)}, ws.result))
		ws.command.set_image(image_path())
		await set_values(m, {"width": "10", "height": "5"})
		ws.refresh_view()
		await m.frames(2)
		var where: Variant = await pull_point(m, "position", Vector2(28.0, -12.0), "Decal position dragged")
		var decal: Dictionary = ws.command.entry() if ws.command != null else {}
		if where is Vector3:
			m.check((decal.get("position", Vector3.INF) as Vector3).distance_to(where) < 1e-9 and absf((where as Vector3).y - 0.01) < 1e-9,
				"The decal should move with its point, on the face (%s, %s)." % [decal.get("position"), where])
		await ok_step(m, begun, "", "Decal")


# --- inspect -------------------------------------------------------------------------------------

static func _inspect(m, hook) -> void:
	var ws = m.ws
	if await hook.blank_part() == null:
		return
	var body := await add_box(m, "Cube", Vector3(-10, 0, -10), Vector3(10, 20, 10))
	await m.look(Vector3(0.0, 0.01, 0.0), 0.6, -0.45, 0.24)
	# Section: the offset arrow, then the Tilt and Spin dots turn the plane.
	var begun := begin(m)
	ws.run_tool(CATALOG.find("solid.inspect.section_analysis"))
	await m.frames(2)
	if m.check(ws.command != null, "Section Analysis should open."):
		ws._on_reference_picked({"kind": "origin", "name": "yz"})
		await m.type_into("offset", "2")
		await hook.shot("handles_section.png")
		var off := await pull_arrow(m, "offset", -30.0, "Section offset pulled")
		var section: Dictionary = ws.doc.analyses[ws.doc.analyses.size() - 1]
		var n: Vector3 = section.options.get("normal", Vector3.ZERO)
		m.check(((section.options.get("origin", Vector3.INF) as Vector3) - n * off).length() < 1e-9, "The section plane should sit at the pulled offset (%s, %s)." % [section.options.get("origin"), off])
		var tilt := await pull_angle(m, "tilt", 30.0, "Section Tilt dot turned")
		var spin := await pull_angle(m, "spin", -26.0, "Section Spin dot turned")
		section = ws.doc.analyses[ws.doc.analyses.size() - 1]
		var turned: Basis = ANALYSIS.section_basis(section.options.normal, section.options.get("x", Vector3.ZERO), m.value_of("tilt", "angle"), m.value_of("spin", "angle"))
		var clip := _clip_normal(ws, body)
		m.check(is_finite(tilt) and is_finite(spin) and absf(tilt) > 0.01 and absf(spin) > 0.01 and clip.distance_to(turned.z) < 1e-5,
			"The clip plane should face the turned normal (%s vs %s; tilt %s, spin %s)." % [clip, turned.z, tilt, spin])
		await ok_step(m, begun, "", "Section")
	# Texture Map Controls on a red top face: the anchor, Scale U and V, the turn dot.
	ws.run_action("appearance")
	await m.frames(2)
	var top := face(m, body, Vector3.UP)
	ws.appearance_panel._apply_to.select(1)
	_select(ws, {"kind": "face", "body": body, "index": top, "point": Vector3.ZERO})
	ws.appearance_panel.select_id(RED)
	ws.appearance_panel.apply_selected()
	ws.appearance_panel._apply_to.select(0)
	await m.frames(2)
	if ws.appearance_panel.visible:
		ws.appearance_panel.hide()
	var target: String = APPEARANCE.face_target(body, str(m.shape_of(body).get_face_names()[top]))
	if not m.check(ws.doc.appearances.has(target), "The top face should get its own appearance (%s)." % [ws.doc.appearances.keys()]):
		return
	await m.look(Vector3(0.0, 0.02, 0.0), 0.6, -0.9, 0.2)
	_select(ws, {"kind": "face", "body": body, "index": top, "point": Vector3.ZERO})
	begun = begin(m)
	ws.run_tool(CATALOG.find("solid.modify.texture_map_controls"))
	await m.frames(3)
	if not m.check(ws.command != null and str(ws.command.get("target_key")) == target, "Texture Map Controls should open on the red face (%s)." % [ws.command.get("target_key") if ws.command != null else "closed"]):
		return
	await hook.shot("handles_texture_map.png")
	var frame: Dictionary = ws.command._frame()
	var mapping: Dictionary = APPEARANCE.mapping_with_defaults(ws.doc.appearances[target].get("mapping", {}))
	var offset0: Vector2 = mapping.offset
	# The anchor dot is pressed at its centre, at the start of the Scale arrows (a dot takes the
	# press before an arrow's shaft: forge_viewport.gd _handle_at). It writes no field of its own:
	# the texture's offset slides with it and the gizmo follows.
	var pressed: Dictionary = await m.pull(m.handle("anchor", "point"), Vector2(26.0, 0.0))
	if bool(pressed.get("ok", false)) and not frame.is_empty():
		var moved: Vector3 = pressed.value
		var delta: Vector3 = moved - (frame.anchor as Vector3)
		var u: Vector3 = frame.u
		var v: Vector3 = frame.v
		var want := offset0 - Vector2(delta.dot(u) / u.length_squared(), delta.dot(v) / v.length_squared())
		mapping = APPEARANCE.mapping_with_defaults(ws.doc.appearances[target].get("mapping", {}))
		m.check(delta.length() > 1e-6 and (mapping.offset as Vector2).distance_to(want) < 1e-4, "The texture should slide with its anchor (offset %s, expected %s)." % [mapping.offset, want])
		m.check((ws.command.anchor as Vector3).distance_to(moved) < 1e-6, "The gizmo should follow the anchor (%s vs %s)." % [ws.command.anchor, moved])
	var su := await pull_arrow(m, "scale_u", 30.0, "Texture Scale U pulled")
	var sv := await pull_arrow(m, "scale_v", -20.0, "Texture Scale V pulled")
	mapping = ws.doc.appearances[target].get("mapping", {})
	m.check((mapping.get("scale", Vector2.ZERO) as Vector2).distance_to(Vector2(m.value_of("scale_u", "length"), m.value_of("scale_v", "length"))) < 1e-9 and is_finite(su) and is_finite(sv),
		"The mapping's repeat should be the pulled scales (%s; %s, %s)." % [mapping.get("scale"), su, sv])
	var turn := await pull_angle(m, "rotation", 28.0, "Texture turn dot turned")
	mapping = ws.doc.appearances[target].get("mapping", {})
	m.check(is_finite(turn) and absf(float(mapping.get("rotation", 0.0)) - m.value_of("rotation", "angle")) < 1e-9, "The texture should turn as far as the dot (%s vs %s)." % [mapping.get("rotation"), turn])
	# A cylindrical projection's origin point.
	await set_values(m, {"type": "cylindrical"})
	ws.refresh_view()
	await m.frames(2)
	var origin: Variant = await pull_point(m, "origin", Vector2(-24.0, 18.0), "Cylindrical projection origin dragged")
	mapping = ws.doc.appearances[target].get("mapping", {})
	if origin is Vector3:
		m.check((mapping.get("origin", Vector3.INF) as Vector3).distance_to(origin) < 1e-9, "The projection's origin should be where it was dragged (%s, %s)." % [mapping.get("origin"), origin])
	await ok_step(m, begun, "", "Texture Map Controls")


## The field key's hint is the amber note that a drag replaced the expression was (forge_workspace
## drag_replaced): "was <expression>", with the longer why as its tooltip.
static func _check_replaced_note(m, key: String, was: String, when: String) -> void:
	var ws = m.ws
	var hint: Label = ws.panel.get("_hints").get(key)
	var held: Dictionary = ws.drag_replaced.get(key, {})
	m.check(str(held.get("was", "")) == was and hint != null and hint.text == "was " + was and hint.tooltip_text == ws.DRAG_REPLACED_NOTE % was
		and hint.modulate == ws.panel.NOTE_COLOR and str(held.get("now", "")) == str(ws.command_values.get(key, "")),
		"%s, %s's hint should say it was %s (%s; '%s', '%s')." % [when.capitalize(), key, was, held, hint.text if hint != null else "no hint", hint.tooltip_text if hint != null else ""])


static func _select(ws, pick: Dictionary) -> void:
	ws.selection.clear()
	ws.selection.append(pick)
	ws._selection_changed(true)


static func _clip_normal(ws, body_id: String) -> Vector3:
	var material := ws.viewport.body_surface(body_id).material_override as ShaderMaterial
	return material.get_shader_parameter("plane_normal") if material != null and material.shader == ANALYSIS.SECTION_SHADER else Vector3.ZERO


# --- edges ---------------------------------------------------------------------------------------

static func _edges(m, hook) -> void:
	var ws = m.ws
	if await hook.blank_part() == null:
		return
	var begun := begin(m)
	ws.run_tool(CATALOG.find("solid.create.box"))
	await m.frames(3)
	if not m.check(ws.command != null, "Box should open."):
		return
	# A typed expression, then a drag: the drag writes the number it reached over the expression.
	await m.type_into("height", "20 + 5")
	await m.look(Vector3(0.0, 0.02, 0.0), 0.65, -0.42, 0.3)
	var pulled := await pull_arrow(m, "height", 20.0, "Height pulled after a typed expression")
	var text := str(ws.command_values.get("height", ""))
	m.check(is_finite(pulled) and not text.contains("+") and absf(pulled - 0.025) > 1e-6, "The drag should replace the typed 20 + 5 with the number it reached (%s)." % text)
	# ... and the field's hint says what it was (amber "was 20 + 5", the why on hover).
	_check_replaced_note(m, "height", "20 + 5", "after the drag")
	m.note("a drag writes its number over a typed expression (%s); the field shows \"was 20 + 5\"" % text)
	# Below the minimum: the arrow stops at its smallest value, the box still builds.
	var low := await pull_arrow(m, "height", -400.0, "Height pulled far below zero")
	var body := body_of_command(m)
	m.check(absf(low - 0.00001) < 1e-12 and m.shape_of(body) != null and absf(m.bbox(body).size.y - 0.00001) < 1e-9 and not (ws.result.get("errors", {}) as Dictionary).has(ws.command.feature.id),
		"A drag past the end should stop at the smallest height, 0.01 mm, and the box still build (%s, %s)." % [low, ws.result.get("errors", {})])
	# A second drag keeps the note of the first expression.
	_check_replaced_note(m, "height", "20 + 5", "after a second drag")
	await m.type_into("height", "20")
	await m.frames(2)
	var hint: Label = ws.panel.get("_hints").get("height")
	m.check(ws.drag_replaced.is_empty() and hint != null and not hint.text.begins_with("was ") and hint.tooltip_text == "",
		"Typing in the field should take the replaced-expression note away (%s; '%s')." % [ws.drag_replaced, hint.text if hint != null else "no hint"])
	# A field that held a plain number gets no note from a drag.
	await pull_arrow(m, "length", 12.0, "Length pulled from a plain number")
	m.check(not ws.drag_replaced.has("length"), "A drag over a plain number should leave no note (%s)." % [ws.drag_replaced])
	# Seen end-on (from the right, orthographic): the length arrow runs along the view and a drag
	# moves nothing (no NaN in the field, nothing in the design). (From the top the height arrow
	# lies on the position dot, which takes that press.)
	ws.viewport.set_ortho(true)
	await m.look(Vector3(0.0, 0.01, 0.0), PI * 0.5, 0.0, 0.3)
	var h: Dictionary = m.handle("length", "arrow")
	var before := str(ws.command_values.get("length", ""))
	var printed: String = m.doc_print()
	if not h.is_empty():
		var shape: Dictionary = ws.viewport._handle_screen_shape(h)
		var at: Vector2 = (shape.get("from", Vector2.INF) as Vector2).round()
		m.check(shape.is_empty() or (shape.from as Vector2).distance_to(shape.to) < 1.0, "Seen end-on the length arrow should be a dot on screen (%s)." % [shape])
		if at.is_finite() and m.same_handle(ws.viewport._handle_at(at), h):
			var r: Dictionary = await m.pull(h, Vector2(30.0, 30.0))
			m.check(bool(r.get("ok", false)) and str(ws.command_values.get("length", "")) == before and m.doc_print() == printed and is_finite(m.value_of("length", "length")),
				"An end-on arrow drag should move nothing (%s -> %s)." % [before, ws.command_values.get("length", "")])
		else:
			m.check(false, "The end-on length arrow should take its own press (it was under %s)." % [ws.viewport._handle_at(at)])
	ws.viewport.set_ortho(false)
	await m.frames(2)
	await m.escape()
	m.check(ws.command == null and m.doc_print() == str(begun.print), "Esc should leave the design as it was after the edge drags.")
