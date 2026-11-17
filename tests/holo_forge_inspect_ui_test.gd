extends SceneTree
## Holo Forge Inspect and appearance UI behaviors that need no editor (the Forge workspace in a
## plain scene tree; undo and redo are driven by applying the recorded step's snapshots, as the
## editor's history does):
## - a model edit made while a command is open (a body's eye during a Box preview or a Zebra panel,
##   an appearance applied while Texture Map Controls previews a mapping) survives Cancel and OK,
##   and its undo step never holds the command's preview;
## - dragging Texture Map Controls' offset point past the face's edge doesn't run away;
## - hidden bodies draw no section cap, isocurve or center point and count in no readout;
## - Section and Draft follow their picked plane or face through model edits;
## - Curvature Comb keeps which sketch curves were picked, and its Scale is a multiple of the
##   automatic size;
## - Physical Material's components mode gives what its preview shows;
## - double-clicking an analysis or canvas while its own panel is open keeps it;
## - the Appearance panel doesn't round a stored scale or offset when another field is edited;
## - the browser opens Analysis, Canvases and Decals once they have entries;
## - a kept Center of Mass reopens on its own bodies;
## - handle drags and picks rebuild no analysis whose inputs didn't change.
##
## godot --headless --path . --script res://tests/holo_forge_inspect_ui_test.gd

const WORKSPACE := preload("res://addons/holo_forge/ui/forge_workspace.gd")
const CAD_PART := preload("res://addons/holo_forge/nodes/cad_part.gd")
const DOCUMENT := preload("res://addons/holo_forge/core/document.gd")
const CATALOG := preload("res://addons/holo_forge/tools/catalog.gd")
const SKETCH_DATA := preload("res://addons/holo_forge/core/sketch/sketch_data.gd")
const ANALYSIS := preload("res://addons/holo_forge/core/analysis.gd")
const APPEARANCE := preload("res://addons/holo_forge/core/appearance.gd")
const REFERENCES := preload("res://addons/holo_forge/core/references.gd")
const PHYSICAL := preload("res://addons/holo_forge/core/physical_materials.gd")
const INSPECT := preload("res://addons/holo_forge/core/inspect.gd")
const BROWSER := preload("res://addons/holo_forge/ui/browser.gd")
const INSPECT_COMMAND := preload("res://addons/holo_forge/tools/inspect_command.gd")

var failures: Array[String] = []
var ws: Control


func _init() -> void:
	call_deferred("run")


func run() -> void:
	create_timer(300.0).timeout.connect(func() -> void:
		print("FAIL holo_forge_inspect_ui: timed out ", failures)
		quit(1))
	ws = WORKSPACE.new()
	root.add_child(ws)
	ws.size = Vector2(1400, 900)
	for i in 3:
		await process_frame
	if ws.kernel == null:
		_expect(false, "The native kernel should load.")
	else:
		await _check_edit_under_command()
		await _check_texture_drag_past_edge()
		await _check_hidden_bodies()
		await _check_follows_model()
		await _check_comb_options()
		await _check_physical_components()
		await _check_double_click_keeps()
		await _check_panel_rounding()
		_check_browser_folders()
		await _check_com_reopens()
		await _check_drag_rebuilds_nothing()
	print("PASS holo_forge_inspect_ui: edits under an open command survive Cancel/OK without its preview in their undo step, the texture offset drag past the edge stays put, hidden bodies draw no caps/isocurves/points, section and draft follow their picks, comb picks and scale, physical material components, double-click keeps an open panel, panel rounding, browser folders, Center of Mass reopens on its bodies, drags rebuild no analysis." \
		if failures.is_empty() else "FAIL holo_forge_inspect_ui")
	ws.set_part(null)
	ws.queue_free()
	await process_frame
	quit(0 if failures.is_empty() else 1)


# --- A model edit while a command is open --------------------------------------------------

func _check_edit_under_command() -> void:
	var part := await _new_part()
	var doc: Resource = part.document
	var body1 := _box()

	# A: the eye pressed in the browser while a Box previews a second box, then Cancel.
	ws.run_tool(CATALOG.find("solid.create.box"))
	_expect(doc.features.size() == 2, "The Box command should preview a second box.")
	_press_eye("body", body1)
	var step: Dictionary = ws.last_step
	_expect(ws.command != null and not bool(doc.bodies[body1].visible), "The eye should hide Body1 with the Box still open.")
	_expect(step.get("name") == "Show/Hide Body" and (step.before.features as Array).size() == 1 and (step.after.features as Array).size() == 1,
		"The eye's undo step should hold no previewed box (%d, %d features)." % [(step.get("before", {}).get("features", []) as Array).size(), (step.get("after", {}).get("features", []) as Array).size()])
	ws.cancel_command()
	_expect(doc.features.size() == 1 and not bool(doc.bodies[body1].visible), "After Cancel Body1 should stay hidden and the box go (%d features, visible %s)." % [doc.features.size(), doc.bodies[body1].visible])
	ws._apply_snapshot(part, step.before)
	_expect(doc.features.size() == 1 and ws.result.bodies.size() == 1 and bool(doc.bodies[body1].visible), "Undoing the eye should show Body1 and not bring the cancelled box back (%d features)." % doc.features.size())
	ws._apply_snapshot(part, step.after)
	_expect(doc.features.size() == 1 and not bool(doc.bodies[body1].visible), "Redoing the eye should hide Body1 only.")
	ws._apply_snapshot(part, step.before)

	# The same with OK: the box is kept, and undoing the box keeps the eye's change.
	ws.run_tool(CATALOG.find("solid.create.box"))
	_press_eye("body", body1)
	var eye_step: Dictionary = ws.last_step
	ws.accept_command()
	var box_step: Dictionary = ws.last_step
	_expect(doc.features.size() == 2 and not bool(doc.bodies[body1].visible), "OK should keep the second box and the hidden Body1.")
	_expect((box_step.before.features as Array).size() == 1 and not bool(box_step.before.bodies[body1].visible) and box_step.before == eye_step.after,
		"The box's undo step should start where the eye left the document.")
	ws._apply_snapshot(part, box_step.before)
	_expect(doc.features.size() == 1 and not bool(doc.bodies[body1].visible), "Undoing the box should keep Body1 hidden.")
	ws._apply_snapshot(part, eye_step.before)
	_expect(doc.features.size() == 1 and bool(doc.bodies[body1].visible), "Undoing the eye then should show Body1 with one box.")

	# B: Apply Appearance on a face while Texture Map Controls previews a mapping, then Cancel.
	ws.change("Apply Appearance", func() -> void: doc.appearances[APPEARANCE.body_target(body1)] = {"material": "builtin:paint_red", "mapping": {}})
	ws.selection.append({"kind": "body", "body": body1, "index": -1, "point": Vector3.ZERO})
	ws.run_tool(CATALOG.find("solid.modify.texture_map_controls"))
	var arrow := _handle("arrow", "scale_u")
	if not arrow.is_empty():
		ws._on_manipulator_changed(arrow, float(arrow.base) * 2.0)
	var body_key := APPEARANCE.body_target(body1)
	_expect(not (doc.appearances[body_key].mapping as Dictionary).is_empty(), "Texture Map Controls should preview a mapping.")
	var face_key := APPEARANCE.face_target(body1, ws.result.bodies[body1].shape.get_face_names()[0])
	ws.apply_appearance("builtin:paint_blue", PackedStringArray([face_key]))
	step = ws.last_step
	_expect((step.after.appearances[body_key].mapping as Dictionary).is_empty(), "The Apply step should not hold the previewed mapping (%s)." % [step.after.appearances[body_key]])
	ws.cancel_command()
	_expect(str((doc.appearances.get(face_key, {}) as Dictionary).get("material", "")) == "builtin:paint_blue" and (doc.appearances[body_key].mapping as Dictionary).is_empty(),
		"After Cancel the blue face should stay and the mapping go back (%s)." % [doc.appearances])
	ws.selection.clear()

	# C: the eye while Zebra's panel is open, then Cancel.
	ws.run_tool(CATALOG.find("solid.inspect.zebra_analysis"))
	ws._change_body(body1, "visible", "Show/Hide Body")
	step = ws.last_step
	ws.cancel_command()
	_expect(not bool(doc.bodies[body1].visible) and doc.analyses.is_empty(), "After Cancel Body1 should stay hidden with no zebra (%s, %d analyses)." % [doc.bodies[body1].visible, doc.analyses.size()])
	ws._apply_snapshot(part, step.before)
	_expect(doc.analyses.is_empty() and bool(doc.bodies[body1].visible), "Undoing the eye should not bring the cancelled zebra back (%s)." % [doc.analyses])


# --- Texture Map Controls: the offset point dragged past the face's edge -------------------

func _check_texture_drag_past_edge() -> void:
	var part := await _new_part()
	var doc: Resource = part.document
	var body1 := _box()
	ws.change("Apply Appearance", func() -> void: doc.appearances[APPEARANCE.body_target(body1)] = {"material": "builtin:paint_red", "mapping": {}})
	ws.selection.append({"kind": "body", "body": body1, "index": -1, "point": Vector3.ZERO})
	ws.run_tool(CATALOG.find("solid.modify.texture_map_controls"))
	var anchor := _handle("point", "anchor")
	_expect(not anchor.is_empty(), "Texture Map Controls should show the anchor point.")
	if anchor.is_empty():
		ws.cancel_command()
		return
	var frame: Dictionary = ws.command._frame()
	var u: Vector3 = (frame.u as Vector3).normalized()
	var start: Vector3 = anchor.position
	var key := APPEARANCE.body_target(body1)
	# One repeat is 100 mm along u; the anchor sits 25 mm from the face's edge. A drag 35 mm out
	# and back, one event per millimetre: the offset follows the cursor both ways.
	var at_30 := 0.0
	var out_30 := 0.0
	for mm in range(1, 36):
		ws._on_manipulator_changed(anchor, start + u * (mm * 0.001))
		if mm == 30:
			out_30 = _offset_u(doc, key)
	for mm in range(34, -1, -1):
		ws._on_manipulator_changed(anchor, start + u * (mm * 0.001))
		if mm == 30:
			at_30 = _offset_u(doc, key)
	var back := _offset_u(doc, key)
	_expect(absf(out_30 + 0.3) < 2e-3 and absf(at_30 + 0.3) < 2e-3 and absf(back) < 2e-3,
		"A drag 30 mm along U should read -0.3 going out and coming back, and 0 at the start (%s, %s, %s)." % [out_30, at_30, back])
	ws._on_manipulator_released(anchor)
	# The same point 5 mm past the edge, sent again and again (the mouse held still).
	var still := _handle("point", "anchor")
	var offsets := []
	for i in 4:
		ws._on_manipulator_changed(still, start + u * 0.030)
		offsets.append(_offset_u(doc, key))
	_expect(offsets.all(func(o: float) -> bool: return absf(o + 0.3) < 1e-3), "The same point 5 mm past the edge should give offset -0.3 every time (%s)." % [offsets])
	# After the drag ends, the next drag starts at the handle again (now on the edge).
	ws._on_manipulator_released(still)
	var moved := _handle("point", "anchor")
	if not moved.is_empty():
		ws._on_manipulator_changed(moved, (moved.position as Vector3) + u * 0.010)
	_expect(absf(_offset_u(doc, key) + 0.4) < 2e-3, "A new 10 mm drag from the handle should add -0.1 (%s)." % _offset_u(doc, key))
	ws.cancel_command()
	ws.selection.clear()


func _offset_u(doc: Resource, key: String) -> float:
	return float((APPEARANCE.mapping_with_defaults(doc.appearances[key].get("mapping", {})).offset as Vector2).x)


# --- Hidden bodies in analyses --------------------------------------------------------------

func _check_hidden_bodies() -> void:
	var part := await _new_part()
	var doc: Resource = part.document
	var body1 := _box()
	ws.run_tool(CATALOG.find("solid.inspect.section_analysis"))
	ws.accept_command()
	var section_id := str(doc.analyses[0].id)
	_expect(ws.analysis_text(section_id).contains("2500") and int(ws.viewport.analysis_counts().nodes) == 1, "The section should cap the box (%s)." % ws.analysis_text(section_id))
	ws._change_body(body1, "visible", "Show/Hide Body")
	_expect(int(ws.viewport.analysis_counts().nodes) == 0 and not ws.analysis_text(section_id).contains("2500"),
		"A hidden box should draw no cap and count in no area (%s, %s)." % [ws.viewport.analysis_counts(), ws.analysis_text(section_id)])
	ws._change_body(body1, "visible", "Show/Hide Body")
	ws.delete_analysis(section_id)

	# Isocurves on a cylinder, then hidden.
	ws.run_tool(CATALOG.find("solid.create.cylinder"))
	_values({"position": Vector3(0.1, 0.0, 0.0)})
	ws.accept_command()
	var cylinder := ""
	for body_id in ws.result.bodies:
		if body_id != body1:
			cylinder = body_id
	ws.run_tool(CATALOG.find("solid.inspect.isocurve_analysis"))
	ws.accept_command()
	var iso_id := str(doc.analyses[0].id)
	_expect(ws.analysis_text(iso_id).contains("10 isocurves") and int(ws.viewport.analysis_counts().nodes) == 1, "The cylinder should show 10 isocurves (%s)." % ws.analysis_text(iso_id))
	ws._change_body(cylinder, "visible", "Show/Hide Body")
	_expect(int(ws.viewport.analysis_counts().nodes) == 0 and ws.analysis_text(iso_id).contains("0 isocurves"),
		"A hidden cylinder should draw no isocurves (%s, %s)." % [ws.viewport.analysis_counts(), ws.analysis_text(iso_id)])
	ws.delete_analysis(iso_id)

	# Center of Mass of everything: the hidden cylinder has no point and no mass in it.
	ws._change_body(cylinder, "visible", "Show/Hide Body")
	ws.change("Center of Mass", func() -> void: doc.analyses.append({"id": "analysis99", "type": "center_of_mass", "name": "CenterofMass1", "visible": true, "options": {"body_ids": []}}))
	_expect(int(ws.viewport.analysis_counts().points) == 3, "Two shown bodies should give three points (%s)." % [ws.viewport.analysis_counts()])
	ws._change_body(cylinder, "visible", "Show/Hide Body")
	var box_mass: float = INSPECT.mass_properties(doc, ws.result, [body1]).mass
	var both: Dictionary = INSPECT.mass_properties(doc, ws.result, [])
	var text: String = ws.analysis_text("analysis99")
	_expect(int(ws.viewport.analysis_counts().points) == 1 and text.contains("center (0 mm, 25 mm, 0 mm)") and float(both.mass) > box_mass * 1.01,
		"With the cylinder hidden only the box should count (%s, %s)." % [ws.viewport.analysis_counts(), text])


# --- Section and Draft follow the model -----------------------------------------------------

func _check_follows_model() -> void:
	var part := await _new_part()
	var doc: Resource = part.document
	var body1 := _box()

	# A section on an offset plane: the plane moves to 30 mm, the cut follows.
	ws.run_tool(CATALOG.find("solid.construct.offset_plane"))
	_values({"plane": [{"kind": "origin", "name": "xz"}], "distance": "10"})
	ws.recompute()
	ws.accept_command()
	var plane_id: String = doc.features[doc.features.size() - 1].id
	ws.run_tool(CATALOG.find("solid.inspect.section_analysis"))
	_values({"plane": [{"kind": "construct", "feature": plane_id}]})
	ws.accept_command()
	_expect(_clip_origin(body1).is_equal_approx(Vector3(0, 0.01, 0)), "The section should cut at 10 mm (%s)." % _clip_origin(body1))
	ws._change_model_expression(plane_id, "distance", "30")
	_expect(_clip_origin(body1).is_equal_approx(Vector3(0, 0.03, 0)), "The section should follow its plane to 30 mm (%s)." % _clip_origin(body1))
	ws.delete_analysis(str(doc.analyses[0].id))

	# A section on the box's +X face, 5 mm in: the box gets shorter, the cut follows its face.
	var box_id: String = doc.features[0].id
	ws.edit_feature(box_id)
	_values({"length": "40"})
	ws.accept_command()
	var shape: RefCounted = ws.result.bodies[body1].shape
	var face_ref := REFERENCES.from_pick({"kind": "face", "body": body1, "index": _face(shape, Vector3.RIGHT)}, ws.result)
	ws.run_tool(CATALOG.find("solid.inspect.section_analysis"))
	ws.panel.activate_selection("plane")
	ws._on_reference_picked(face_ref)
	_values({"offset": "-5"})
	ws.accept_command()
	var section_id := str(doc.analyses[0].id)
	_expect(absf(_clip_origin(body1).x - 0.015) < 1e-6, "The section should sit 5 mm inside the +X face (%s)." % _clip_origin(body1))
	ws.edit_feature(box_id)
	_values({"length": "10"})
	ws.accept_command()
	var size: Vector3 = (ws.result.bodies[body1].shape.bbox() as AABB).size
	var area := size.y * size.z * 1e6
	var shown: float = ws.analysis_text(section_id).trim_prefix("Section area ").get_slice(" ", 0).to_float()
	_expect(absf(_clip_origin(body1).x) < 1e-6 and absf(shown - area) < 0.01,
		"The section should follow the face to x = 0 and cut %s mm² (%s, %s)." % [area, _clip_origin(body1), ws.analysis_text(section_id)])
	ws.delete_analysis(section_id)

	# Draft along a plane at an angle: the angle changes, the draft follows its normal (on a box
	# that isn't square across Y and Z, so the readout differs).
	ws.edit_feature(box_id)
	_values({"width": "20", "height": "30"})
	ws.accept_command()
	ws.run_tool(CATALOG.find("solid.construct.plane_at_angle"))
	ws._on_reference_picked({"kind": "origin", "name": "x"})
	_values({"angle": "0"})
	var angle_plane: String = ws.command.feature.id
	ws.accept_command()
	ws.run_tool(CATALOG.find("solid.inspect.draft_analysis"))
	ws.panel.activate_selection("direction")
	ws._on_reference_picked({"kind": "construct", "feature": angle_plane})
	ws.accept_command()
	var draft_id := str(doc.analyses[0].id)
	var before: String = ws.analysis_text(draft_id)
	ws._change_model_expression(angle_plane, "angle", "90")
	var normal: Vector3 = ws.result.construction.get(angle_plane, {}).get("normal", Vector3.UP)
	var fresh: Dictionary = doc.analyses[0].duplicate(true)
	fresh.options["pull"] = normal.normalized()
	var expected: String = ANALYSIS.build(fresh, ws.result, ws.tessellations, ws.kernel, doc).info
	_expect(ws.analysis_text(draft_id) == expected and expected != before, "The draft should follow the plane's new normal (%s, expected %s, was %s)." % [ws.analysis_text(draft_id), expected, before])


func _clip_origin(body_id: String) -> Vector3:
	var surface: MeshInstance3D = ws.viewport.body_surface(body_id)
	var material := surface.material_override as ShaderMaterial if surface != null else null
	return material.get_shader_parameter("plane_origin") if material != null and material.shader == ANALYSIS.SECTION_SHADER else Vector3(INF, INF, INF)


# --- Curvature Comb options ------------------------------------------------------------------

func _check_comb_options() -> void:
	var part := await _new_part()
	var doc: Resource = part.document
	var a := await _circle_sketch("xz", Vector2(0.0, 0.0), 0.01, Vector2(0.05, 0.0))
	var b := await _circle_sketch("xy", Vector2(0.0, 0.03), 0.02)
	ws.recompute()
	# A's 10 mm circle and B's circle picked: exactly those two are combed, on both sketches.
	var small := {"kind": "sketch_curve", "sketch": a.id, "entity": a.circles[0]}
	var other := {"kind": "sketch_curve", "sketch": b.id, "entity": b.circles[0]}
	ws.run_tool(CATALOG.find("solid.inspect.curvature_comb_analysis"))
	_values({"curves": [small, other]})
	var options: Dictionary = ws.command.entry().get("options", {})
	_expect(options.get("curves", []) == [small, other], "The comb should keep the picked curves (%s)." % [options.get("curves")])
	var comb_id := str(ws.command.entry_id)
	var built := ANALYSIS.build(ws.command.entry(), ws.result, ws.tessellations, ws.kernel, doc)
	var on_a := 0
	var on_b := 0
	for line in built.lines:
		var p: Vector3 = (line.points as PackedVector3Array)[0]
		if absf(p.y) < 1e-9 and absf(p.z) > 1e-6:
			on_a += 1
		elif absf(p.z) < 1e-9:
			on_b += 1
	_expect(on_a > 0 and on_b > 0 and ws.analysis_text(comb_id) == "Largest curvature 0.1 1/mm (radius 10 mm)",
		"Both picked circles should be combed, the 10 mm one the most curved (%d on A, %d on B, %s)." % [on_a, on_b, ws.analysis_text(comb_id)])
	_values({"curves": [small]})
	built = ANALYSIS.build(ws.command.entry(), ws.result, ws.tessellations, ws.kernel, doc)
	var envelopes: int = built.lines.filter(func(l: Dictionary) -> bool: return (l.points as PackedVector3Array).size() > 2).size()
	_expect(envelopes == 1, "Only the picked 10 mm circle should get a comb, not A's other circle (%d envelopes)." % envelopes)
	# Scale is a multiple of the automatic tooth size (0 counts as 1): 2 doubles the teeth.
	var factors := []
	for text in ["0", "1", "2", "0.5"]:
		_values({"scale": text})
		factors.append(float(ws.command.entry().get("options", {}).get("scale", -1.0)))
	_expect(factors == [1.0, 1.0, 2.0, 0.5], "Scale should be stored as a multiple of the automatic size (%s)." % [factors])
	var teeth := []
	for text in ["1", "2"]:
		_values({"scale": text})
		teeth.append(_longest_tooth(ANALYSIS.build(ws.command.entry(), ws.result, ws.tessellations, ws.kernel, doc)))
	_expect(teeth[0] > 0.0 and teeth[0] < 0.05 and absf(teeth[1] - 2.0 * teeth[0]) < 1e-6 * teeth[0] + 1e-9,
		"Scale 1 should give teeth of the automatic size (not 100 m) and 2 twice that (%s m)." % [teeth])
	ws.cancel_command()
	ws.run_tool(CATALOG.find("solid.inspect.isocurve_analysis"))
	_values({"comb": true, "comb_scale": "3"})
	options = ws.command.entry().get("options", {})
	_expect(float(options.get("comb_scale", -1.0)) == 3.0, "Comb Scale should be stored as a multiple (%s)." % [options])
	ws.cancel_command()


func _longest_tooth(built: Dictionary) -> float:
	var longest := 0.0
	for line in built.get("lines", []):
		var pts: PackedVector3Array = line.points
		if pts.size() == 2:
			longest = maxf(longest, pts[0].distance_to(pts[1]))
	return longest


func _circle_sketch(plane: String, center: Vector2, r: float, second_center := Vector2.INF) -> Dictionary:
	var editor: RefCounted = ws.sketch_editor
	var feature: Resource = ws.create_sketch(SKETCH_DATA.ORIGIN_PLANES[plane], plane)
	editor.start_tool("circle_center")
	editor.tool_click(center, {}, {})
	editor.tool_click(center + Vector2(r, 0), {}, {})
	if second_center != Vector2.INF:
		editor.start_tool("circle_center")
		editor.tool_click(second_center, {}, {})
		editor.tool_click(second_center + Vector2(r * 2.0, 0), {}, {})
	await process_frame
	var circles := []
	for e in editor.sketch().entities():
		if e.type == "circle":
			circles.append(int(e.id))
	ws.run_action("finish_sketch")
	return {"id": feature.id, "circles": circles}


# --- Physical Material: Apply To Components ---------------------------------------------------

func _check_physical_components() -> void:
	var part := await _new_part()
	var doc: Resource = part.document
	ws.run_action("new_component")
	var body1 := _box()
	var component: String = doc.body_component(body1)
	_expect(component != "", "The box should be in a component.")
	var volume: float = ws.result.bodies[body1].shape.volume()
	ws.selection.append({"kind": "body", "body": body1, "index": -1, "point": Vector3.ZERO})
	ws.run_tool(CATALOG.find("solid.modify.physical_material"))
	_values({"material": "Aluminum", "apply_to": "bodies"})
	ws.accept_command()
	ws.run_tool(CATALOG.find("solid.modify.physical_material"))
	_values({"material": "Copper", "apply_to": "components"})
	var copper := INSPECT_COMMAND.significant(volume * PHYSICAL.density("Copper"))
	var preview: String = ws.panel.info("result")
	_expect(preview.contains("With Copper: %s kg" % copper), "The preview should show the copper mass (%s, expected %s kg)." % [preview, copper])
	ws.accept_command()
	var mass: float = INSPECT.mass_properties(doc, ws.result, [body1]).mass
	_expect(PHYSICAL.material_for(doc, body1) == "Copper" and absf(mass - volume * PHYSICAL.density("Copper")) < 1e-6 and not doc.physical_materials.has("body:" + body1),
		"OK should make the box copper as previewed (%s, %s kg)." % [doc.physical_materials, mass])
	ws.selection.clear()


# --- Double-clicking an entry while its own panel is open ------------------------------------

func _check_double_click_keeps() -> void:
	var part := await _new_part()
	var doc: Resource = part.document
	_box()
	ws.run_tool(CATALOG.find("solid.inspect.zebra_analysis"))
	_values({"stripes": "30"})
	var zebra_id := str(ws.command.entry_id)
	ws.browser.analysis_edit_requested.emit(zebra_id)
	_expect(ws.command != null and doc.analyses.size() == 1 and str(ws.command_values.get("stripes", "")) == "30",
		"Double-clicking the zebra being made should keep its panel (%d analyses, %s)." % [doc.analyses.size(), ws.command_values])
	ws.accept_command()
	_expect(doc.analyses.size() == 1 and float(doc.analyses[0].options.get("stripes", 0)) == 30.0, "OK should keep the 30-stripe zebra (%s)." % [doc.analyses])
	ws.run_tool(CATALOG.find("sketch.insert.canvas"))
	_values({"width": "123", "image": "res://icon.svg"})
	var canvas_id := str(ws.command.entry_id)
	ws.browser.image_edit_requested.emit("canvases", canvas_id)
	_expect(ws.command != null and doc.canvases.size() == 1 and str(ws.command_values.get("width", "")) == "123",
		"Double-clicking the canvas being made should keep its panel (%d canvases, %s)." % [doc.canvases.size(), ws.command_values.get("width")])
	ws.accept_command()
	_expect(ws.command == null and doc.canvases.size() == 1, "OK should keep the canvas (%d)." % doc.canvases.size())
	# An entry kept earlier still opens while another command runs (that command is cancelled).
	ws.run_tool(CATALOG.find("solid.inspect.zebra_analysis"))
	ws.browser.analysis_edit_requested.emit(zebra_id)
	_expect(ws.command != null and ws.command.editing and str(ws.command.entry_id) == zebra_id and doc.analyses.size() == 1 and str(ws.command_values.get("stripes", "")) == "30",
		"Double-clicking the kept zebra during another zebra should edit the kept one (%s)." % [ws.command_values])
	ws.cancel_command()


# --- Appearance panel rounding --------------------------------------------------------------

func _check_panel_rounding() -> void:
	var part := await _new_part()
	var doc: Resource = part.document
	var body1 := _box()
	var key := APPEARANCE.body_target(body1)
	ws.change("Apply Appearance", func() -> void: doc.appearances[key] = {"material": "builtin:paint_red", "mapping": {}})
	ws._change_units("m")
	ws.selection.append({"kind": "body", "body": body1, "index": -1, "point": Vector3.ZERO})
	ws.open_appearance_panel()
	var panel = ws.appearance_panel
	panel.refresh()
	for axis in 2:
		panel._scale[axis].text = "12.34 mm"
		panel._scale[axis].text_submitted.emit("12.34 mm")
	var mapping: Dictionary = doc.appearances[key].mapping
	_expect((mapping.get("scale", Vector2.ZERO) as Vector2).is_equal_approx(Vector2(0.01234, 0.01234)) and panel._scale[0].text == "0.0123",
		"Typing 12.34 mm should store it and show 0.0123 m (%s, %s)." % [mapping, panel._scale[0].text])
	var rebuilds: int = ws.rebuild_count
	panel._rotation.focus_exited.emit()
	_expect(ws.rebuild_count == rebuilds and doc.appearances[key].mapping == mapping, "Tabbing through should change nothing (%s)." % [doc.appearances[key].mapping])
	panel._rotation.text = "30"
	panel._rotation.text_submitted.emit("30")
	mapping = doc.appearances[key].mapping
	_expect((mapping.get("scale", Vector2.ZERO) as Vector2).is_equal_approx(Vector2(0.01234, 0.01234)) and absf(float(mapping.get("rotation", 0.0)) - deg_to_rad(30.0)) < 1e-6,
		"Editing the rotation should keep the 12.34 mm scale (%s)." % [mapping])
	# A finely typed offset in millimetres is kept the same way.
	ws._change_units("mm")
	panel.refresh()
	for axis in 2:
		panel._offset[axis].text = "0.12345"
		panel._offset[axis].text_submitted.emit("0.12345")
	panel._rotation.text = "45"
	panel._rotation.text_submitted.emit("45")
	mapping = doc.appearances[key].mapping
	_expect((mapping.get("offset", Vector2.ZERO) as Vector2).is_equal_approx(Vector2(0.12345, 0.12345)), "Editing the rotation should keep the 0.12345 offset (%s)." % [mapping])
	panel.visible = false
	ws.selection.clear()


# --- Browser folders --------------------------------------------------------------------------

func _check_browser_folders() -> void:
	var browser: Tree = BROWSER.new()
	root.add_child(browser)
	var doc: Resource = DOCUMENT.new()
	browser.refresh(doc, [], {})
	_expect(browser._collapsed.is_empty(), "A refresh should remember no folder as the user's (%s)." % [browser._collapsed])
	doc.analyses.append({"id": "analysis1", "type": "zebra", "name": "Zebra1", "visible": true, "options": {}})
	doc.canvases.append({"id": "canvas1", "name": "Canvas1", "image": "", "visible": true})
	doc.decals.append({"id": "decal1", "name": "Decal1", "image": "", "visible": true, "body": ""})
	browser.refresh(doc, [], {})
	for folder in ["Analysis", "Canvases", "Decals"]:
		var item := _folder(browser, folder)
		_expect(item != null and not item.collapsed, "%s should open once it has an entry." % folder)
	# A folder the user shuts stays shut.
	var analysis := _folder(browser, "Analysis")
	if analysis != null:
		analysis.collapsed = true
	browser.refresh(doc, [], {})
	analysis = _folder(browser, "Analysis")
	_expect(analysis != null and analysis.collapsed, "Analysis should stay shut after the user shut it.")
	browser.queue_free()


func _folder(browser: Tree, text: String) -> TreeItem:
	for item in browser.get_root().get_children():
		if item.get_text(0) == text:
			return item
	return null


# --- A kept Center of Mass reopens on its bodies ----------------------------------------------

func _check_com_reopens() -> void:
	var part := await _new_part()
	var doc: Resource = part.document
	var body1 := _box()
	ws.run_tool(CATALOG.find("solid.create.box"))
	_values({"position": Vector3(0.1, 0.0, 0.0)})
	ws.accept_command()
	var body2 := ""
	for body_id in ws.result.bodies:
		if body_id != body1:
			body2 = body_id
	ws.selection.append({"kind": "body", "body": body1, "index": -1, "point": Vector3.ZERO})
	ws.run_tool(CATALOG.find("solid.inspect.center_of_mass"))
	_values({"keep": true})
	ws.accept_command()
	var com_id := str(doc.analyses[0].id) if doc.analyses.size() == 1 else ""
	ws.selection.clear()
	ws.selection.append({"kind": "body", "body": body2, "index": -1, "point": Vector3.ZERO})
	ws.edit_analysis(com_id)
	_expect(ws.command_values.get("bodies", []) == [body1], "Editing the kept Center of Mass should show Body1, not the selection (%s)." % [ws.command_values.get("bodies")])
	ws.cancel_command()
	ws.selection.clear()
	ws.edit_analysis(com_id)
	_expect(ws.command_values.get("bodies", []) == [body1], "With nothing selected it should still show Body1 (%s)." % [ws.command_values.get("bodies")])
	ws.cancel_command()
	# An entry kept before panel values were stored reads its own bodies too.
	ws.change("Old Center of Mass", func() -> void: doc.analyses.append({"id": "analysis98", "type": "center_of_mass", "name": "Old", "visible": true, "options": {"body_ids": [body2]}}))
	ws.edit_analysis("analysis98")
	_expect(ws.command_values.get("bodies", []) == [body2], "An old entry should open on its own bodies (%s)." % [ws.command_values.get("bodies")])
	ws.cancel_command()


# --- Drags and picks rebuild no unchanged analysis --------------------------------------------

func _check_drag_rebuilds_nothing() -> void:
	var part := await _new_part()
	var doc: Resource = part.document
	var body1 := _box()
	ws.run_tool(CATALOG.find("solid.create.cylinder"))
	_values({"position": Vector3(0.1, 0.0, 0.0)})
	ws.accept_command()
	ws.change("Apply Appearance", func() -> void: doc.appearances[APPEARANCE.body_target(body1)] = {"material": "builtin:paint_red", "mapping": {}})
	for tool_id in ["isocurve_analysis", "section_analysis"]:
		ws.run_tool(CATALOG.find("solid.inspect." + tool_id))
		ws.accept_command()
	var builds: int = ws.analysis_build_count
	var nodes: Array = ws.viewport._analysis_root.get_children().filter(func(n: Node) -> bool: return not n.is_queued_for_deletion())
	ws.selection.append({"kind": "body", "body": body1, "index": -1, "point": Vector3.ZERO})
	ws.run_tool(CATALOG.find("solid.modify.texture_map_controls"))
	var arrow := _handle("arrow", "scale_u")
	for i in 3:
		if not arrow.is_empty():
			ws._on_manipulator_changed(arrow, float(arrow.base) * (1.5 + i * 0.25))
	var kept: bool = nodes.size() > 0 and nodes.all(func(n: Node) -> bool: return is_instance_valid(n) and not n.is_queued_for_deletion())
	_expect(ws.analysis_build_count == builds and kept, "Scale drags should rebuild no analysis and keep their nodes (%d builds)." % (ws.analysis_build_count - builds))
	var surface: MeshInstance3D = ws.viewport.body_surface(body1)
	var material := surface.material_override as ShaderMaterial if surface != null else null
	_expect(material != null and material.shader == ANALYSIS.SECTION_SHADER, "The previewed box should still be cut by the section.")
	ws.cancel_command()
	builds = ws.analysis_build_count
	ws.run_tool(CATALOG.find("solid.inspect.measure"))
	ws._on_reference_picked({"kind": "body", "body": body1})
	ws.refresh_view()
	_expect(ws.analysis_build_count == builds, "A Measure pick should rebuild no analysis (%d builds)." % (ws.analysis_build_count - builds))
	ws.cancel_command()
	ws.selection.clear()


# --- Helpers ----------------------------------------------------------------------------------

func _new_part() -> Node3D:
	var part: Node3D = CAD_PART.new()
	part.document = DOCUMENT.new()
	root.add_child(part)
	ws.set_part(part)
	await process_frame
	return part


## A default 50 mm box (one undo step); returns its body id.
func _box() -> String:
	var before: Array = ws.result.get("bodies", {}).keys()
	ws.run_tool(CATALOG.find("solid.create.box"))
	ws.accept_command()
	for body_id in ws.result.get("bodies", {}):
		if not before.has(body_id):
			return str(body_id)
	_expect(false, "The box should be built (%s)." % [ws.result.get("errors", {})])
	return ""


## Merges values into the running command's panel values and applies them.
func _values(values: Dictionary) -> void:
	var merged: Dictionary = ws.command_values.duplicate(true)
	merged.merge(values, true)
	ws.set_command_values(merged)
	if ws.command != null and not ws._is_inspect(ws.command):
		ws.recompute()
	else:
		ws.refresh_view()


func _handle(type: String, key: String) -> Dictionary:
	for h in ws.viewport.handles:
		if str(h.get("type", "")) == type and str(h.get("key", "")) == key:
			return h
	return {}


func _face(shape: RefCounted, normal: Vector3) -> int:
	for f in shape.face_count():
		var info: Dictionary = shape.face_info(f)
		if bool(info.get("planar", false)) and (info.normal as Vector3).is_equal_approx(normal):
			return f
	return -1


func _press_eye(type: String, id: String) -> void:
	var item: TreeItem = ws.browser.item_for(type, id) if type != "body" else ws.browser.body_item(id)
	_expect(item != null, "The browser should list %s %s." % [type, id])
	if item != null:
		ws.browser.button_clicked.emit(item, 0, BROWSER.BUTTON_EYE, MOUSE_BUTTON_LEFT)


func _expect(ok: bool, detail: String) -> void:
	if not ok:
		failures.append(detail)
		push_error(detail)
		print("FAIL: ", detail)
