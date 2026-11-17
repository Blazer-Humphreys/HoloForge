@tool
extends RefCounted
## The "pull the handles" hook's form section (tests/holo_forge_handles_editor_test.gd). A helper of
## that hook, not a test of its own. In a blank part's form, with real mouse events
## (tests/holo_forge_mouse.gd):
##   - every Form primitive (Box, Plane, Cylinder, Sphere, Quadball, Torus) is placed with real
##     clicks (an origin plane, the centre, the size, the height), then its arrows and face counts
##     are pulled: the field reads what the drag gives; OK is one step "Form: <Title>" (undo and
##     redo exact) and the cage is the one the same typed values make (a box's and a plane's also
##     measure the pulled sizes);
##   - Form Extrude's distance arrow and, on two sides, its second one: the cage spans them;
##   - Insert Edge's, Slide Edge's and Smooth's sliders: the field and the step;
##   - every part of the Edit Form gizmo (move arrows, plane squares, rings with and without Shift,
##     scale bars, plane brackets, the centre): the cage moves by the transform the gizmo's own
##     math gives for the mouse travel, as one step "Form: Edit Form", undo and redo exact.

const CAGE := preload("res://addons/holo_forge/core/form/cage.gd")
const FORM_OPS := preload("res://addons/holo_forge/core/form/form_ops.gd")
const FORM_GIZMO := preload("res://addons/holo_forge/ui/form_gizmo.gd")
const FORM_TOOLS := preload("res://addons/holo_forge/ui/form_tools.gd")
const SKETCH_DATA := preload("res://addons/holo_forge/core/sketch/sketch_data.gd")
const MM := 0.001
## Where the primitives go: along X on the ground plane, clear of the origin plane squares.
const ROW_Z := -0.06
## The extrude sketch's circle (on a plane facing +Z).
const CIRCLE_AT := Vector3(0.0, 0.0, 0.09)
## Each primitive's handles and how far each is pulled (pixels along its own screen direction).
const PRIMITIVES := [
	{"id": "box", "title": "Box", "arrows": {"length": 30.0, "width": 16.0, "height": 34.0}, "counts": {"length_faces": 45.0, "width_faces": 25.0, "height_faces": 45.0}},
	# A thin box (its size click on the X axis leaves the width at its least): its Length Faces and
	# Height Faces knobs sit on the Width and Length arrows' shafts and must still take a press
	# (form_editor.gd _handle_at checks knobs first).
	{"id": "box", "title": "Box", "thin": true, "arrows": {}, "counts": {"length_faces": 45.0, "height_faces": 45.0}},
	{"id": "plane", "title": "Plane", "arrows": {"length": 26.0, "width": 30.0}, "counts": {"length_faces": 65.0, "width_faces": 45.0}},
	{"id": "cylinder", "title": "Cylinder", "arrows": {"diameter": 24.0, "height": 30.0}, "counts": {"around_faces": 45.0}},
	{"id": "sphere", "title": "Sphere", "arrows": {"diameter": -14.0}, "counts": {"around_faces": 65.0}},
	{"id": "quadball", "title": "Quadball", "arrows": {"diameter": 22.0}, "counts": {"span_faces": 25.0}},
	{"id": "torus", "title": "Torus", "arrows": {"diameter": 26.0, "tube_diameter": 12.0}, "counts": {"around_faces": 45.0}},
]
## The Edit Form gizmo parts pulled, with pixels and keys held.
const GIZMO_PULLS := [
	["move_x", 40.0, {}], ["move_y", 36.0, {}], ["move_z", -34.0, {}],
	["plane_xy", 30.0, {}], ["plane_yz", 28.0, {}], ["plane_zx", 28.0, {}],
	["rot_x", 40.0, {}], ["rot_y", 46.0, {}], ["rot_z", 50.0, {"shift": true}],
	["scale_x", 30.0, {}], ["scale_y", -18.0, {}], ["scale_z", 26.0, {}],
	["pscale_xy", 24.0, {}], ["pscale_yz", 22.0, {}], ["pscale_zx", -16.0, {}],
	["uniform", 40.0, {}],
]


static func run(m, hook) -> void:
	var ws = m.ws
	if not ClassDB.class_exists("CadSubD"):
		m.check(false, "The form section needs the native kernel (CadSubD).")
		return
	if await hook.blank_part() == null:
		return
	var ids := {}
	ws.change("Handles Test: Circle", func() -> void:
		var circle: Resource = ws.doc.add_feature("sketch", "Sketch", {}, SKETCH_DATA.new_options({"origin": CIRCLE_AT, "x": Vector3.RIGHT, "y": Vector3.UP}, "frame"))
		var s = SKETCH_DATA.new(circle, ws.doc)
		s.add_circle(s.add_point(Vector2.ZERO), 8 * MM)
		ids["sketch"] = circle.id)
	await m.frames(2)
	var form: Resource = ws.create_form()
	await m.frames(2)
	if not m.check(form != null and ws.form_editor.active, "A form should open in the blank part."):
		return
	var i := 0
	for spec in PRIMITIVES:
		await _primitive(m, hook, spec, Vector3(-0.18 + 0.06 * i, 0.0, ROW_Z))
		i += 1
	await _extrude(m, hook, str(ids.get("sketch", "")))
	var box := await _typed_box(m)
	if box == "":
		return
	await _sliders(m, box)
	await _gizmo(m, hook, box)


# --- Helpers -------------------------------------------------------------------------------------

static func _bodies(m) -> Array:
	var f: Resource = m.ws.form_editor.feature
	return (f.options.get("bodies", {}) as Dictionary).keys() if f != null else []


static func _added(m, known: Array) -> Array:
	var out := []
	for b in _bodies(m):
		if not known.has(b):
			out.append(b)
	return out


static func _positions(cage: Dictionary) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	for v in CAGE.vertex_count(cage):
		out.append_array(CAGE.position_d(cage, v))
	return out


static func _vef(cage: Dictionary) -> String:
	if cage.is_empty():
		return "-"
	return "%d/%d/%d" % [CAGE.vertex_count(cage), CAGE.topology(cage).nE, CAGE.face_count(cage)]


## The largest coordinate difference of two cages' points (INF when their counts differ).
static func _gap(a: PackedFloat64Array, b: PackedFloat64Array) -> float:
	if a.size() != b.size():
		return INF
	var worst := 0.0
	for k in a.size():
		worst = maxf(worst, absf(a[k] - b[k]))
	return worst


## The cage's span along a direction from a point: Vector2(min, max).
static func _span(cage: Dictionary, origin: Vector3, axis: Vector3) -> Vector2:
	var lo := INF
	var hi := -INF
	for v in CAGE.vertex_count(cage):
		var q := CAGE.position_d(cage, v)
		var d := (q[0] - origin.x) * axis.x + (q[1] - origin.y) * axis.y + (q[2] - origin.z) * axis.z
		lo = minf(lo, d)
		hi = maxf(hi, d)
	return Vector2(lo, hi)


static func _select(editor, items: Array) -> void:
	editor.selection.clear()
	for item in items:
		editor.selection.append(item)
	editor._selection_changed()


static func _edge(body: String, a: int, b: int) -> Dictionary:
	return {"kind": "edge", "body": body, "index": -1, "pair": Vector2i(mini(a, b), maxi(a, b))}


static func _face(body: String, f: int) -> Dictionary:
	return {"kind": "face", "body": body, "index": f, "pair": Vector2i(-1, -1)}


## The last step is named name (the workspace's record of it; the editor's history shows it as
## "Forge: <name>").
static func _step_named(m, name: String) -> bool:
	return str(m.ws.last_step.get("name", "")) == name and m.undo_name() == "Forge: " + name


## OK with the mouse: one step named "Form: <title>", undo gives the design of begun back exactly
## and redo the accepted one. Returns the accepted text ("" when OK made no step).
static func _form_ok(m, begun: Dictionary, title: String) -> String:
	await m.press_ok()
	var ok: bool = m.check(m.action() == int(begun.action) + 1, "%s: OK should be one undo step (%d -> %d; %s)." % [title, begun.action, m.action(), m.ws.last_message])
	ok = m.check(_step_named(m, "Form: " + title), "%s: the step should be named Form: %s (%s, %s)." % [title, title, m.ws.last_step.get("name", ""), m.undo_name()]) and ok
	if not ok:
		return ""
	var accepted: String = m.doc_print()
	await m.undo()
	m.check(m.doc_print() == str(begun.print), "%s: undo should put the design back exactly." % title)
	await m.redo()
	m.check(m.doc_print() == accepted, "%s: redo should make it again exactly." % title)
	return accepted


# --- Primitives ----------------------------------------------------------------------------------

static func _primitive(m, hook, spec: Dictionary, centre: Vector3) -> void:
	var ws = m.ws
	var editor = ws.form_editor
	var id := str(spec.id)
	var title := str(spec.title)
	var begun := {"print": m.doc_print(), "action": m.action()}
	editor.start_tool(id)
	await m.frames(2)
	if not m.check(editor.tool == id and ws.is_picking_plane(), "Form %s should start and ask for a plane (tool '%s')." % [title, editor.tool]):
		editor.cancel_tool()
		return
	# A click on the ground's origin square.
	var size: float = ws.viewport.origin_size()
	await m.look(Vector3(size * 0.5, 0.0, size * 0.5), 0.6, -0.7, size * 5.0)
	var on_square := Vector2.INF
	for f in [Vector2(0.5, 0.5), Vector2(0.3, 0.7), Vector2(0.7, 0.3), Vector2(0.25, 0.25), Vector2(0.75, 0.75)]:
		var at: Vector2 = (ws.viewport.project(Vector3(size * f.x, 0.0, size * f.y)) as Vector2).round()
		if at.is_finite() and not m.covered(at) and str(ws.plane_at(at).get("ref", "")) == "xz":
			on_square = at
			break
	if not m.check(on_square.is_finite(), "Form %s: some point of the ground's origin square should be clickable." % title):
		editor.cancel_tool()
		return
	await m.click_view(on_square)
	var plane: Dictionary = editor.tool_state.get("plane", {})
	if not m.check(not ws.is_picking_plane() and not plane.is_empty(), "Form %s: a click on the ground square should give the tool its plane (%s)." % [title, plane]):
		editor.cancel_tool()
		return
	var x: Vector3 = plane.x
	var n: Vector3 = (plane.x as Vector3).cross(plane.y).normalized()
	# The centre, the size and (Box, Cylinder) the height, clicked in the view.
	await m.look(centre + n * 0.01, 0.55, -0.5, 0.17)
	var y: Vector3 = (plane.y as Vector3).normalized()
	var clicks := [centre, centre + x * 0.01 + (Vector3.ZERO if bool(spec.get("thin", false)) else y * 0.007)]
	var needed := int(FORM_TOOLS.spec(id).get("clicks", 2))
	if needed >= 3:
		clicks.append(centre + n * 0.015)
	m.check(await m.clear_view(clicks), "Form %s: the view should show the placement points clear of the panel." % title)
	for p in clicks:
		var at: Vector2 = ws.viewport.project(p)
		m.move(m.g(at.round()))
		await m.frames(1)
		await m.click_view(at)
	if not m.check((editor.tool_state.get("clicks", []) as Array).size() == needed and not m.form_handles().is_empty(),
			"Form %s: %d clicks should place it and show its handles (%d clicks, handles %s)." % [title, needed, (editor.tool_state.get("clicks", []) as Array).size(), m.form_handles().map(func(h): return h.key)]):
		editor.cancel_tool()
		return
	if id == "box":
		await hook.shot("handles_form_box.png")
	# Each arrow and count pulled: the field reads what the drag gives.
	for group in ["arrows", "counts"]:
		for key in spec[group]:
			var h: Dictionary = m.form_handle(key)
			if not m.check(not h.is_empty(), "Form %s should show a %s handle (%s)." % [title, key, m.form_handles().map(func(q): return q.key)]):
				continue
			await m.clear_view([h.origin])
			h = m.form_handle(key)
			var before := str(editor.tool_values.get(key, ""))
			var r: Dictionary = await m.form_pull(h, float(spec[group][key]))
			if bool(r.get("ok", false)):
				m.check(str(editor.tool_values.get(key, "")) == str(r.value) and str(r.value) != before,
					"Form %s %s pulled: the field should read %s (it reads %s, was %s)." % [title, key, r.value, editor.tool_values.get(key, ""), before])
	var values: Dictionary = editor.tool_values.duplicate(true)
	var ev: Dictionary = editor.evaluated_values()
	var placement: Dictionary = (editor.tool_picks.get("placement", [{}]) as Array)[0].duplicate(true)
	var known := _bodies(m)
	if await _form_ok(m, begun, title) == "":
		editor.cancel_tool()
		return
	editor.cancel_tool()
	await m.frames(1)
	var added := _added(m, known)
	if not m.check(added.size() == 1, "Form %s's OK should add one body (%s)." % [title, added]):
		return
	var cage: Dictionary = editor.cage_of(str(added[0]))
	var o: Vector3 = placement.origin
	var px: Vector3 = (placement.x as Vector3).normalized()
	var py: Vector3 = (placement.y as Vector3).normalized()
	var pn: Vector3 = (placement.normal as Vector3).normalized()
	if id == "box" or id == "plane":
		var l := float(ev.get("length", 0.0))
		var w := float(ev.get("width", 0.0))
		var h := float(ev.get("height", 0.0)) if id == "box" else 0.0
		var sx := _span(cage, o, px)
		var sy := _span(cage, o, py)
		var sn := _span(cage, o, pn)
		m.check(sx.distance_to(Vector2(-l, l) * 0.5) < 1e-9 and sy.distance_to(Vector2(-w, w) * 0.5) < 1e-9 and sn.distance_to(Vector2(0.0, h)) < 1e-9,
			"Form %s's cage should be the pulled size %s x %s x %s (spans %s %s %s)." % [title, l, w, h, sx, sy, sn])
		var lf := int(str(values.length_faces))
		var wf := int(str(values.width_faces))
		var faces := lf * wf if id == "plane" else 2 * (lf * wf + lf * int(str(values.height_faces)) + wf * int(str(values.height_faces)))
		m.check(CAGE.face_count(cage) == faces, "Form %s's cage should have the pulled face counts (%d faces, expected %d)." % [title, CAGE.face_count(cage), faces])
	# The same values typed (no drag) make the very same cage.
	var dragged := _positions(cage)
	var shape := _vef(cage)
	await m.undo()
	var typed_known := _bodies(m)
	editor.start_tool(id)
	await m.frames(1)
	if ws.is_picking_plane():
		ws._end_plane_pick()
	editor.set_placement(placement.origin, placement.x, placement.y, placement.normal)
	editor.set_tool_values(values)
	editor.tool_ok()
	await m.frames(2)
	editor.cancel_tool()
	var typed := _added(m, typed_known)
	if m.check(typed.size() == 1, "Form %s with the pulled values typed should add one body (%s)." % [title, typed]):
		var again: Dictionary = editor.cage_of(str(typed[0]))
		m.check(_vef(again) == shape and _gap(_positions(again), dragged) <= 1e-12,
			"Form %s: the cage the drags made should be the one the same typed values make (%s vs %s, off by %s m)." % [title, shape, _vef(again), _gap(_positions(again), dragged)])
	await m.undo()
	m.check(m.doc_print() == str(begun.print), "Form %s: undoing the typed copy should leave the design as before the tool." % title)


# --- Form Extrude --------------------------------------------------------------------------------

static func _extrude(m, hook, sketch: String) -> void:
	var ws = m.ws
	var editor = ws.form_editor
	var begun := {"print": m.doc_print(), "action": m.action()}
	editor.start_tool("extrude")
	await m.frames(2)
	ws._on_reference_picked({"kind": "profile", "sketch": sketch, "point": Vector2.ZERO})
	await m.frames(2)
	if not m.check(editor.tool == "extrude" and (editor.tool_values.get("profile", []) as Array).size() == 1, "Form Extrude should take the circle as its profile (%s)." % [editor.tool_values.get("profile")]):
		editor.cancel_tool()
		return
	await m.type_into("distance", "10")
	await m.look(CIRCLE_AT + Vector3(0, 0, 0.012), 1.0, -0.4, 0.15)
	var h: Dictionary = m.form_handle("distance")
	if not m.check(not h.is_empty(), "Form Extrude should show its distance arrow (%s)." % [m.form_handles()]):
		editor.cancel_tool()
		return
	await m.clear_view([h.origin, CIRCLE_AT])
	await hook.shot("handles_form_extrude.png")
	var r: Dictionary = await m.form_pull(m.form_handle("distance"), 30.0)
	if bool(r.get("ok", false)):
		m.check(str(editor.tool_values.get("distance", "")) == str(r.value), "Form Extrude distance pulled: the field should read %s (%s)." % [r.value, editor.tool_values.get("distance")])
	# Two sides: the second arrow points the other way.
	var merged: Dictionary = editor.tool_values.duplicate(true)
	merged.merge({"direction": "two_sides", "distance2": "6 mm"}, true)
	ws.panel.set_values(merged)
	ws._on_panel_values_changed(merged)
	await m.frames(2)
	var h2: Dictionary = m.form_handle("distance2")
	if m.check(not h2.is_empty(), "Form Extrude on two sides should show a second arrow (%s)." % [m.form_handles().map(func(q): return q.key)]):
		await m.clear_view([h2.origin])
		r = await m.form_pull(m.form_handle("distance2"), 24.0)
		if bool(r.get("ok", false)):
			m.check(str(editor.tool_values.get("distance2", "")) == str(r.value), "Form Extrude distance2 pulled: the field should read %s (%s)." % [r.value, editor.tool_values.get("distance2")])
	var ev: Dictionary = editor.evaluated_values()
	var frame: Dictionary = editor.tool_state.get("extrude_frame", {})
	var known := _bodies(m)
	if await _form_ok(m, begun, "Extrude") == "":
		editor.cancel_tool()
		return
	editor.cancel_tool()
	var added := _added(m, known)
	if m.check(added.size() == 1 and not frame.is_empty(), "Form Extrude's OK should add one body (%s)." % [added]):
		var span := _span(editor.cage_of(str(added[0])), frame.origin, (frame.normal as Vector3).normalized())
		var want := Vector2(-float(ev.get("distance2", 0.0)), float(ev.get("distance", 0.0)))
		m.check(span.distance_to(want) < 1e-9, "Form Extrude's cage should span the two pulled distances (%s, expected %s)." % [span, want])
	await m.undo()


# --- A typed box for the sliders and the gizmo ------------------------------------------------------

static func _typed_box(m) -> String:
	var ws = m.ws
	var editor = ws.form_editor
	var known := _bodies(m)
	editor.start_tool("box")
	await m.frames(1)
	if ws.is_picking_plane():
		ws._end_plane_pick()
	editor.set_tool_values({"length": "20 mm", "width": "20 mm", "height": "20 mm", "length_faces": "2", "width_faces": "2", "height_faces": "2"})
	editor.set_placement(Vector3(0.0, 0.0, ROW_Z), Vector3.RIGHT, Vector3.FORWARD, Vector3.UP)
	editor.tool_ok()
	await m.frames(2)
	editor.cancel_tool()
	var added := _added(m, known)
	if not m.check(added.size() == 1 and _vef(editor.cage_of(str(added[0]))) == "26/48/24", "A typed 2 x 2 x 2 box should be added for the sliders and the gizmo (%s)." % [added]):
		return ""
	return str(added[0])


# --- Insert Edge, Slide Edge, Smooth -------------------------------------------------------------

static func _sliders(m, box: String) -> void:
	var ws = m.ws
	var editor = ws.form_editor
	await m.look(Vector3(0.0, 0.01, ROW_Z), 0.7, -0.45, 0.12)
	var cage: Dictionary = editor.cage_of(box)
	var topo = CAGE.topology(cage)
	# The loop round the middle (y = 10 mm).
	var loop := []
	for e in topo.nE:
		var ab: Vector2i = topo.edge_vertices(e)
		if absf(CAGE.position(cage, ab.x).y - 0.01) < 1e-9 and absf(CAGE.position(cage, ab.y).y - 0.01) < 1e-9:
			for k in topo.edge_loop(e):
				var xy: Vector2i = topo.edge_vertices(k)
				loop.append(_edge(box, xy.x, xy.y))
			break
	var faces := []
	for f in CAGE.face_count(cage):
		faces.append(_face(box, f))
	for job in [["insert_edge", "Insert Edge", "location", loop, 0.3], ["slide_edge", "Slide Edge", "slide", loop, 0.4], ["smooth", "Smooth", "amount", faces, 0.5]]:
		var tool_id: String = job[0]
		var title: String = job[1]
		var key: String = job[2]
		if not m.check(not (job[3] as Array).is_empty(), "%s needs its picks from the box." % title):
			continue
		var start := _positions(editor.cage_of(box))
		_select(editor, job[3])
		var begun := {"print": m.doc_print(), "action": m.action()}
		editor.start_tool(tool_id)
		await m.frames(2)
		var h: Dictionary = m.form_handle(key)
		if not m.check(editor.tool == tool_id and not h.is_empty() and str(h.type) == "slider", "%s should show its %s slider (%s)." % [title, key, m.form_handles()]):
			editor.cancel_tool()
			continue
		await m.clear_view([h.origin, (h.origin as Vector3) + (h.direction as Vector3)])
		h = m.form_handle(key)
		var shape: Dictionary = editor._handle_shape(h)
		var track: float = (shape.from as Vector2).distance_to(shape.to) if not shape.is_empty() else 0.0
		var r: Dictionary = await m.form_pull(h, track * float(job[4]))
		if bool(r.get("ok", false)):
			m.check(str(editor.tool_values.get(key, "")) == str(r.value), "%s's slider pulled: the field should read %s (%s)." % [title, r.value, editor.tool_values.get(key)])
		if await _form_ok(m, begun, title) != "":
			var now: Dictionary = editor.cage_of(box)
			m.check(_gap(_positions(now), start) > 1e-6 or CAGE.vertex_count(now) * 3 != start.size(), "%s should change the box (%s)." % [title, _vef(now)])
			if tool_id == "insert_edge":
				m.check(_vef(now) == "34/64/32", "Insert Edge round the middle should give 34/64/32 (%s)." % _vef(now))
			await m.undo()
			m.check(_positions(editor.cage_of(box)) == start, "%s: undo should leave the box as it was." % title)
		editor.cancel_tool()
		await m.frames(1)


# --- The Edit Form gizmo -------------------------------------------------------------------------

static func _gizmo(m, hook, box: String) -> void:
	var ws = m.ws
	var editor = ws.form_editor
	var cage: Dictionary = editor.cage_of(box)
	var topo = CAGE.topology(cage)
	var top := -1
	for f in topo.nF:
		if topo.face_normal(cage, f).dot(Vector3.UP) > 0.9:
			top = f
			break
	if not m.check(top >= 0, "The box should have a top face for the gizmo."):
		return
	_select(editor, [_face(box, top)])
	editor.start_tool("edit_form")
	await m.frames(1)
	var merged: Dictionary = editor.tool_values.duplicate(true)
	merged.merge({"transform_mode": "multi", "space": "world", "soft": false}, true)
	ws.panel.set_values(merged)
	ws._on_panel_values_changed(merged)
	await m.frames(2)
	if not m.check(editor.gizmo.visible, "Edit Form should show its gizmo on the top face."):
		editor.cancel_tool()
		return
	await m.look(editor.gizmo.pivot, 0.75, -0.5, 0.1)
	await m.clear_view([editor.gizmo.pivot])
	await hook.shot("handles_form_gizmo.png")
	for job in GIZMO_PULLS:
		var id: String = job[0]
		if not editor.gizmo.visible:
			_select(editor, [_face(box, top)])
			await m.frames(1)
		var before: int = m.action()
		var r: Dictionary = await m.gizmo_pull(id, float(job[1]), job[2])
		if not bool(r.get("ok", false)):
			continue
		var xf: PackedFloat64Array = r.xf
		m.check(not FORM_GIZMO.is_identity(xf), "The gizmo's %s drag should make a transform." % id)
		if id == "rot_z":
			var angle := acos(clampf((xf[0] + xf[4] + xf[8] - 1.0) * 0.5, -1.0, 1.0))
			m.check(angle > 1e-6 and absf(angle - snappedf(angle, PI / 12.0)) < 1e-9, "A ring drag with Shift should turn by whole 15 degree steps (%s degrees)." % rad_to_deg(angle))
		var bodies: Dictionary = r.bodies
		var starts := {}
		var moved := {}
		for body_id in bodies:
			var info: Dictionary = bodies[body_id]
			var want: Dictionary = FORM_OPS.transform_vertices(info.cage, info.verts, info.weights, xf).cage
			starts[body_id] = _positions(info.cage)
			moved[body_id] = _positions(editor.cage_of(body_id))
			var off := _gap(moved[body_id], _positions(want))
			m.check(off <= 1e-12, "The gizmo's %s drag should move the cage by the drag's transform (off by %s m)." % [id, off])
		m.check(m.action() == before + 1 and _step_named(m, "Form: Edit Form"), "The gizmo's %s drag should be one step named Form: Edit Form (%d -> %d, %s)." % [id, before, m.action(), m.undo_name()])
		await m.undo()
		for body_id in starts:
			m.check(_positions(editor.cage_of(body_id)) == starts[body_id], "Undo of the %s drag should put the cage back exactly." % id)
		await m.redo()
		for body_id in moved:
			m.check(_positions(editor.cage_of(body_id)) == moved[body_id], "Redo of the %s drag should move the cage again exactly." % id)
		await m.undo()
		_select(editor, [_face(box, top)])
		await m.frames(1)
	await _free_drag(m, box, top)
	editor.cancel_tool()


## Free move: a press on the selected face itself (clear of every gizmo part) and a drag moves it
## in the view's plane (form_editor.gd _drag_motion starts the gizmo's "free" drag).
static func _free_drag(m, box: String, top: int) -> void:
	var ws = m.ws
	var editor = ws.form_editor
	var gz = editor.gizmo
	var cage: Dictionary = editor.cage_of(box)
	var corners: PackedInt32Array = CAGE.face_vertices(cage, top)
	var centre := Vector3.ZERO
	for v in corners:
		centre += CAGE.position(cage, v)
	centre /= float(corners.size())
	# Close in from above, as a user would, so the face is wider on screen than the gizmo.
	await m.look(centre, 0.4, -1.2, 0.03)
	await m.clear_view([centre])
	var at := Vector2.INF
	for v in corners:
		for f in [0.75, 0.6, 0.85]:
			var p: Vector2 = (ws.viewport.project(centre.lerp(CAGE.position(cage, v), f)) as Vector2).round()
			var under: Dictionary = editor.pick_at(p)
			if p.is_finite() and not m.covered(p) and gz.hit(ws.viewport, p) == "" and str(under.get("kind", "")) == "face" and int(under.get("index", -1)) == top:
				at = p
				break
		if at.is_finite():
			break
	if not m.check(at.is_finite(), "Some point of the selected face should be clear of the gizmo to drag it freely (centre at %s, gizmo %s, under the corner side %s)." % [ws.viewport.project(centre), gz.screen_rect(ws.viewport), editor.pick_at((ws.viewport.project(centre.lerp(CAGE.position(cage, corners[0]), 0.85)) as Vector2).round())]):
		return
	var before: int = m.action()
	var points := PackedVector2Array()
	for k in range(1, 7):
		points.append((at + Vector2(30.0, -18.0) * float(k) / 6.0).round())
	m.move(m.g(at))
	await m.frames(1)
	m.button(m.g(at), true)
	m.move(m.g(points[0]), MOUSE_BUTTON_MASK_LEFT)
	await m.frames(1)
	var drag: Dictionary = editor.get("_drag")
	if not m.check(str(drag.get("type", "")) == "gizmo" and str(drag.get("handle", "")) == "free", "A drag on the selected face should move it freely (took %s)." % [drag.get("handle", drag.get("type", ""))]):
		m.button(m.g(points[0]), false)
		await m.frames(2)
		return
	var info: Dictionary = (drag.bodies as Dictionary).get(box, {})
	var xf: PackedFloat64Array = gz.drag_xf(drag.state, ws.viewport, points[points.size() - 1], false, float(ws.viewport.snap_step))
	for k in range(1, points.size()):
		m.move(m.g(points[k]), MOUSE_BUTTON_MASK_LEFT)
		await m.frames(1)
	m.button(m.g(points[points.size() - 1]), false)
	await m.frames(3)
	m._counted()
	if info.is_empty():
		m.check(false, "The free drag should move the box.")
		return
	var want: Dictionary = FORM_OPS.transform_vertices(info.cage, info.verts, info.weights, xf).cage
	var off := _gap(_positions(editor.cage_of(box)), _positions(want))
	m.check(not FORM_GIZMO.is_identity(xf) and off <= 1e-12, "The free drag should move the face in the view's plane by the mouse travel (off by %s m)." % off)
	m.check(m.action() == before + 1 and _step_named(m, "Form: Edit Form"), "The free drag should be one step named Form: Edit Form (%s)." % m.undo_name())
	await m.undo()
	m.check(_positions(editor.cage_of(box)) == _positions(info.cage), "Undo of the free drag should put the face back exactly.")
