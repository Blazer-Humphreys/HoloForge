extends SceneTree
## Holo Forge workspace behaviors that need no editor (the Forge workspace in a plain scene tree;
## undo and redo are driven by calling what the editor's history calls): Measure, Curvature Comb
## and Canvas run over an open sketch, pick its points and curves, and give the sketch back with
## the same tool, points, options, selection and a dimension being typed (Escape, Enter, a sketch
## key, Finish Sketch);
## an analysis' eye, rename and delete (and a canvas' or decal's) rebuild nothing, also when undone
## and redone, while a model edit still rebuilds; and Component Colors and a Zebra analysis stay
## on through box edits, including Shift+N pressed while the box edit is open and then cancelled
## or accepted; and Texture Map Controls' live preview on the view's bodies goes away on Cancel
## without a rebuild. In the Surface workspace: E in a sketch is the surface Extrude, a Trim piece
## goes where it was clicked, a surface's highlight has a pass for its back, and Delete takes
## selected faces out of their body and removes split-off bodies.
##
## godot --headless --path . --script res://tests/holo_forge_workspace_test.gd

const WORKSPACE := preload("res://addons/holo_forge/ui/forge_workspace.gd")
const CAD_PART := preload("res://addons/holo_forge/nodes/cad_part.gd")
const DOCUMENT := preload("res://addons/holo_forge/core/document.gd")
const CATALOG := preload("res://addons/holo_forge/tools/catalog.gd")
const SKETCH_DATA := preload("res://addons/holo_forge/core/sketch/sketch_data.gd")
const ANALYSIS := preload("res://addons/holo_forge/core/analysis.gd")
const BROWSER := preload("res://addons/holo_forge/ui/browser.gd")
const IMAGE_COMMAND := preload("res://addons/holo_forge/tools/image_command.gd")
const MEASURE_COMMAND := preload("res://addons/holo_forge/tools/measure_command.gd")
const APPEARANCE := preload("res://addons/holo_forge/core/appearance.gd")
const REFERENCES := preload("res://addons/holo_forge/core/references.gd")
const PHYSICAL := preload("res://addons/holo_forge/core/physical_materials.gd")
const EXPORT := preload("res://addons/holo_forge/core/export.gd")
const INSPECT := preload("res://addons/holo_forge/core/inspect.gd")
const COMMAND := preload("res://addons/holo_forge/tools/command.gd")
const COMMAND_PANEL := preload("res://addons/holo_forge/ui/command_panel.gd")
const OPERATIONS := preload("res://addons/holo_forge/core/operations.gd")

var failures: Array[String] = []
var ws: Control
## A per-process scratch folder (never the real board models folder).
var temp := "user://holo_forge_workspace_test_%d" % OS.get_process_id()


func _init() -> void:
	call_deferred("run")


func run() -> void:
	create_timer(240.0).timeout.connect(func() -> void:
		print("FAIL holo_forge_workspace: timed out ", failures)
		quit(1))
	ws = WORKSPACE.new()
	root.add_child(ws)
	ws.size = Vector2(1400, 900)
	for i in 3:
		await process_frame
	if ws.kernel == null:
		_expect(false, "The native kernel should load.")
	else:
		await _check_measure_in_sketch()
		await _check_view_only_changes()
		await _check_display_survives_edits()
		await _check_preview_cancel()
		await _check_exports_close_edits()
		await _check_export_notes()
		await _check_fastener_rides_moves()
		await _check_component_material()
		await _check_surface_measure()
		await _check_edit_pending_feature()
		await _check_surface_workspace()
		await _check_view_picks()
		await _check_stored_choices()
	print("PASS holo_forge_workspace: Measure, Curvature Comb and Canvas run over an open sketch and give it back unchanged, analysis/canvas/decal eye, rename and delete (and their undo) rebuild nothing, Component Colors and Zebra stay on through box edits and Shift+N mid-edit, a cancelled Texture Map Controls puts the view's texture back, exports and board saves drop an open preview, glb exports name the decals they leave out, an Insert Fastener washer rides its face through moves and edits, Apply To Components reaches every body of the component, Measure calls an open mesh a surface body, double-clicking the feature being made keeps its command, E in a Surface sketch runs the surface Extrude, a Trim piece goes where it was clicked, surface highlights show from behind, Surface Delete takes faces and split-off bodies, a clicked face colors its whole body by default and its mapping can be edited, a leftover face pick doesn't narrow Export STEP, and Insert/Export without a part refuse before any dialog." \
		if failures.is_empty() else "FAIL holo_forge_workspace")
	ws.set_part(null)
	ws.queue_free()
	await process_frame
	_remove_tree(ProjectSettings.globalize_path(temp))
	quit(0 if failures.is_empty() else 1)


# --- Measure inside a sketch ------------------------------------------------------------------

func _check_measure_in_sketch() -> void:
	var part := await _new_part()
	var doc: Resource = part.document
	var editor: RefCounted = ws.sketch_editor
	var feature: Resource = ws.create_sketch(SKETCH_DATA.ORIGIN_PLANES.xz, "xz")
	_expect(feature != null and editor.active, "Create Sketch should open the sketch.")
	editor.start_tool("rect_2pt")
	editor.tool_click(Vector2(0.0, 0.0), {}, {})
	editor.tool_click(Vector2(0.04, 0.02), {}, {})
	editor.start_tool("circle_center")
	editor.tool_click(Vector2(0.08, 0.01), {}, {})
	editor.tool_click(Vector2(0.09, 0.01), {}, {})
	await process_frame
	var s: RefCounted = editor.sketch()
	var corner_a := _point_at(s, Vector2(0.0, 0.0))
	var corner_b := _point_at(s, Vector2(0.04, 0.02))
	var circle := -1
	var a_line := -1
	for e in s.entities():
		if e.type == "circle":
			circle = int(e.id)
		elif e.type == "line" and a_line < 0:
			a_line = int(e.id)
	_expect(corner_a >= 0 and corner_b >= 0 and circle >= 0 and a_line >= 0, "The sketch should hold a rectangle and a circle.")

	# A tool half way: Inscribed Polygon with its center placed and 8 sides typed, a line selected.
	editor.start_tool("polygon_inscribed")
	editor.tool_click(Vector2(0.12, 0.0), {}, {})
	var typed: Dictionary = ws.panel.values.duplicate(true)
	typed["sides"] = "8"
	ws.panel.set_values(typed)
	ws._on_panel_values_changed(typed)
	editor.selection.clear()
	editor.selection.append({"kind": "entity", "id": a_line})
	var tool_state := _tool_state(editor)
	var model_before: Dictionary = ws._model_of(doc.snapshot())
	var analyses_before: Array = doc.analyses.duplicate(true)
	var features_before: int = doc.features.size()
	var rebuilds: int = ws.rebuild_count

	# I (Measure) keeps the sketch open under it.
	ws.handle_key(_key(KEY_I))
	_expect(ws.command != null and ws.command.get_script() == MEASURE_COMMAND, "I in a sketch should start Measure.")
	_expect(editor.active and editor.suspended and editor.feature_id == feature.id, "Measure should run over the open sketch, not finish it.")
	_expect(ws.panel.visible and ws.panel._title.text == "MEASURE" and ws.panel._ok.text == "OK", "The panel should be Measure's with an OK button (%s, %s)." % [ws.panel._title.text, ws.panel._ok.text])
	_expect(ws.viewport.mouse_handler == Callable(ws, "_command_mouse"), "View clicks should go to Measure's picking.")

	# The open sketch's points and curves are picked on screen.
	var world_b: Vector3 = s.to_world(s.point(corner_b))
	var hit: Dictionary = ws.picker.pick(ws.viewport.project(world_b))
	_expect(str(hit.get("kind", "")) == "sketch_point" and str(hit.get("sketch", "")) == feature.id and int(hit.get("entity", -1)) == corner_b,
		"A click on a corner of the open sketch should pick that sketch point (%s)." % [hit])
	if not hit.is_empty():
		hit.erase("key")
		ws._on_reference_picked(hit)
	else:
		ws._on_reference_picked({"kind": "sketch_point", "sketch": feature.id, "entity": corner_b})
	ws.panel.activate_selection("second")
	ws._on_reference_picked({"kind": "sketch_point", "sketch": feature.id, "entity": corner_a})
	ws.refresh_view()
	var measured: Dictionary = ws.command.measured
	_expect(absf(float(measured.get("distance", 0.0)) - Vector2(0.04, 0.02).length()) < 1e-6,
		"Two rectangle corners should measure their diagonal (%s)." % [measured])
	var on_circle: Vector3 = s.to_world(Vector2(0.09, 0.01))
	var curve_hit: Dictionary = ws.picker.pick(ws.viewport.project(on_circle))
	_expect(str(curve_hit.get("kind", "")) == "sketch_curve" and int(curve_hit.get("entity", -1)) == circle,
		"A click on the open sketch's circle should pick it as a sketch curve (%s)." % [curve_hit])
	ws.set_command_values({"first": [{"kind": "sketch_curve", "sketch": feature.id, "entity": circle}], "second": []})
	ws.refresh_view()
	_expect(ws.panel.info("result").contains("radius 10 mm"), "The circle should measure a 10 mm radius (%s)." % ws.panel.info("result"))

	# Delete waits while Measure is open; Enter closes it and the sketch is back as it was.
	ws.handle_key(_key(KEY_DELETE))
	_expect(ws.command != null and editor.sketch().entity(a_line).size() > 0, "Delete should do nothing while Measure is open.")
	ws.handle_key(_key(KEY_ENTER))
	_expect(ws.command == null, "Enter should close Measure.")
	_sketch_back(editor, feature, tool_state, "after Measure's OK")
	_expect(ws.panel.visible and ws.panel._title.text == "INSCRIBED POLYGON" and ws.panel._ok.text == "Close" and str(ws.panel.values.get("sides", "")) == "8",
		"The polygon's own panel should come back with its 8 sides (%s, %s)." % [ws.panel._title.text, ws.panel.values])
	_expect(ws._model_of(doc.snapshot()) == model_before and doc.analyses == analyses_before and doc.features.size() == features_before and ws.rebuild_count == rebuilds,
		"Measure should change nothing and rebuild nothing.")

	# Escape closes it the same way; so does Measure from the Solid menus.
	ws.run_tool(CATALOG.find("solid.inspect.measure"))
	_expect(ws.command != null and editor.suspended, "Measure from the Solid menu should also run over the sketch.")
	ws.handle_key(_key(KEY_ESCAPE))
	_expect(ws.command == null, "Escape should close Measure.")
	_sketch_back(editor, feature, tool_state, "after Measure's Escape")

	# Curvature Comb over the sketch: OK keeps its analysis (no rebuild) and gives the sketch back.
	ws.run_tool(CATALOG.find("sketch.inspect.curvature_comb_analysis"))
	_expect(ws.command != null and editor.active and editor.suspended, "Curvature Comb should run over the sketch.")
	ws._on_reference_picked({"kind": "sketch_curve", "sketch": feature.id, "entity": circle})
	ws.accept_command()
	var comb: Dictionary = doc.analyses[0] if doc.analyses.size() == 1 else {}
	var comb_result: Dictionary = ws.analysis_results.get(str(comb.get("id", "")), {})
	var combed: Array = comb.get("options", {}).get("curves", []) if not comb.is_empty() else []
	_expect(str(comb.get("type", "")) == "curvature_comb" and combed.size() == 1 and str(combed[0].get("sketch", "")) == feature.id
		and int(combed[0].get("entity", -1)) == circle and str(comb_result.get("error", "?")) == "",
		"OK should keep a comb on exactly the picked curve (%s, %s)." % [comb, comb_result])
	_expect(int(ws.viewport.analysis_counts().nodes) >= 1 and ws.rebuild_count == rebuilds, "The comb should show without a rebuild.")
	_sketch_back(editor, feature, tool_state, "after Curvature Comb")

	# Canvas over the sketch: Cancel takes its entry out and gives the sketch back.
	ws.run_tool(CATALOG.find("sketch.insert.canvas"))
	_expect(ws.command != null and editor.suspended and doc.canvases.size() == 1, "Canvas should run over the sketch with its entry shown.")
	ws.handle_key(_key(KEY_ESCAPE))
	_expect(ws.command == null and doc.canvases.is_empty() and ws.rebuild_count == rebuilds, "Cancelling Canvas should take its entry out without a rebuild.")
	_sketch_back(editor, feature, tool_state, "after Canvas")

	# A dimension being typed waits under Measure and comes back with its editor.
	var bottom := _line_between(editor.sketch(), corner_a, Vector2(0.04, 0.0))
	editor.start_tool("dimension")
	editor.tool_click(Vector2(0.02, 0.0), {}, {"kind": "entity", "id": bottom})
	editor.mouse_plane = Vector2(0.02, -0.01)
	editor.tool_click(Vector2(0.02, -0.01), {}, {})
	var pending: Dictionary = editor._pending_dimension.duplicate(true)
	_expect(bottom >= 0 and not pending.is_empty() and editor._edit.visible, "Placing the bottom line's dimension should open its editor (%s)." % [pending])
	ws.handle_key(_key(KEY_I))
	_expect(ws.command != null and not editor._edit.visible and editor._pending_dimension == pending, "Measure should hide the dimension editor and keep the dimension waiting.")
	ws.handle_key(_key(KEY_ESCAPE))
	_expect(ws.command == null and editor._edit.visible and editor._pending_dimension == pending and editor.tool == "dimension", "The dimension editor should come back after Measure.")
	editor._on_edit_submitted("30")
	var line: Dictionary = editor.sketch().entity(bottom)
	_expect(not line.is_empty() and absf(editor.sketch().point(int(line.p1)).distance_to(editor.sketch().point(int(line.p2))) - 0.03) < 1e-7,
		"The waiting dimension should still size the line to 30 mm.")

	# A sketch tool's key closes Measure and starts that tool.
	ws.run_tool(CATALOG.find("sketch.inspect.measure"))
	ws.handle_key(_key(KEY_L))
	_expect(ws.command == null and editor.active and not editor.suspended and editor.tool == "line", "L should close Measure and start Line (%s)." % editor.tool)
	_expect(ws.viewport.mouse_handler == Callable(editor, "handle_mouse"), "The sketch should take clicks again.")

	# Finish Sketch while Measure is open closes both.
	ws.run_tool(CATALOG.find("sketch.inspect.measure"))
	ws.run_action("finish_sketch")
	_expect(ws.command == null and not editor.active and not editor.suspended and not ws.panel.visible, "Finish Sketch should close Measure and the sketch.")

	# Other commands still finish the sketch first.
	ws.edit_feature(feature.id)
	_expect(editor.active, "Double-click editing should reopen the sketch.")
	ws.run_tool(CATALOG.find("solid.create.box"))
	_expect(not editor.active and ws.command != null, "Box should finish the sketch before it starts.")
	ws.cancel_command()


func _tool_state(editor: RefCounted) -> Dictionary:
	return {"tool": editor.tool, "points": editor.tool_points.duplicate(true), "picks": editor.tool_picks.duplicate(true),
		"values": editor.tool_values.duplicate(true), "selection": editor.selection.duplicate(true)}


func _sketch_back(editor: RefCounted, feature: Resource, state: Dictionary, when: String) -> void:
	_expect(editor.active and not editor.suspended and editor.feature_id == feature.id, "The sketch should be open again %s." % when)
	var now := _tool_state(editor)
	_expect(now == state, "The sketch tool should be as it was %s (%s, was %s)." % [when, now, state])
	_expect(ws.viewport.mouse_handler == Callable(editor, "handle_mouse"), "The sketch should take clicks again %s." % when)


## The line from the point with id start to the point at end, or -1.
func _line_between(s: RefCounted, start: int, end: Vector2) -> int:
	for e in s.entities():
		if e.type != "line":
			continue
		var ends := [int(e.p1), int(e.p2)]
		if ends.has(start) and s.point(ends[1] if ends[0] == start else ends[0]).distance_to(end) < 1e-7:
			return int(e.id)
	return -1


func _point_at(s: RefCounted, at: Vector2) -> int:
	for e in s.entities():
		if e.type == "point" and not e.get("origin", false) and s.point(int(e.id)).distance_to(at) < 1e-7:
			return int(e.id)
	return -1


# --- View-only changes rebuild nothing --------------------------------------------------------

func _check_view_only_changes() -> void:
	var part := await _new_part()
	var doc: Resource = part.document
	var body_id := _box()
	var rebuilds: int = ws.rebuild_count

	# A Zebra analysis made with its command: OK records it without a rebuild.
	ws.run_tool(CATALOG.find("solid.inspect.zebra_analysis"))
	ws.accept_command()
	_expect(doc.analyses.size() == 1 and _shader_of(body_id) == ANALYSIS.ZEBRA_SHADER and ws.rebuild_count == rebuilds,
		"Zebra should be kept and shown without a rebuild (%d rebuilds)." % (ws.rebuild_count - rebuilds))
	var zebra_id := str(doc.analyses[0].id) if doc.analyses.size() == 1 else ""

	# The eye in the browser: hides it, no rebuild; undo and redo neither.
	var before: Dictionary = doc.snapshot()
	_press_eye("analysis", zebra_id)
	var after: Dictionary = doc.snapshot()
	_expect(not bool(doc.analyses[0].visible) and ws.viewport.body_surface(body_id).material_override == ws.viewport.surface_material(),
		"The eye should hide the stripes.")
	_expect(_eye_tooltip("analysis", zebra_id) == "Show", "The browser's eye should turn to Show.")
	ws._apply_snapshot(part, before)
	_expect(bool(doc.analyses[0].visible) and _shader_of(body_id) == ANALYSIS.ZEBRA_SHADER and _eye_tooltip("analysis", zebra_id) == "Hide", "Undo should show the stripes again.")
	ws._apply_snapshot(part, after)
	_expect(not bool(doc.analyses[0].visible) and ws.viewport.body_surface(body_id).material_override == ws.viewport.surface_material(), "Redo should hide them again.")
	ws._apply_snapshot(part, before)
	_expect(ws.rebuild_count == rebuilds, "The eye, its undo and redo should rebuild nothing (%d rebuilds)." % (ws.rebuild_count - rebuilds))

	# Rename and delete from the browser.
	before = doc.snapshot()
	ws.browser.analysis_renamed.emit(zebra_id, "Stripes")
	_expect(str(doc.analyses[0].name) == "Stripes" and _item_text("analysis", zebra_id) == "Stripes", "Rename should show the new name in the browser.")
	ws._apply_snapshot(part, before)
	_expect(str(doc.analyses[0].name) == "Zebra1" and _item_text("analysis", zebra_id) == "Zebra1", "Undo should bring the old name back.")
	before = doc.snapshot()
	ws.browser.analysis_delete_requested.emit(zebra_id)
	_expect(doc.analyses.is_empty() and ws.browser.item_for("analysis", zebra_id) == null and ws.viewport.body_surface(body_id).material_override == ws.viewport.surface_material(),
		"Delete should take the analysis out of the browser and the view.")
	ws._apply_snapshot(part, before)
	_expect(doc.analyses.size() == 1 and _shader_of(body_id) == ANALYSIS.ZEBRA_SHADER, "Undo should bring the deleted analysis back.")
	_expect(ws.rebuild_count == rebuilds, "Rename, delete and their undo should rebuild nothing (%d rebuilds)." % (ws.rebuild_count - rebuilds))

	# A canvas and a decal: eye, rename, delete, undo.
	ws.change("Insert Canvas", func() -> void:
		var canvas := IMAGE_COMMAND.new_entry(doc, "canvas")
		canvas.merge({"origin": Vector3.ZERO, "x": Vector3.RIGHT, "y": Vector3.FORWARD, "size": Vector2(0.05, 0.05), "opacity": 0.5, "through": false})
		doc.canvases.append(canvas))
	var canvas_id := str(doc.canvases[0].id)
	_expect(int(ws.viewport.image_counts().canvases) == 1, "The canvas should show.")
	before = doc.snapshot()
	_press_eye("image", canvas_id)
	_expect(not bool(doc.canvases[0].visible) and int(ws.viewport.image_counts().canvases) == 0, "The eye should hide the canvas.")
	ws._apply_snapshot(part, before)
	_expect(int(ws.viewport.image_counts().canvases) == 1, "Undo should show the canvas again.")
	ws.rename_image("canvases", canvas_id, "Blueprint")
	_expect(_item_text("image", canvas_id) == "Blueprint", "Rename should show the canvas' new name.")
	ws.delete_image("canvases", canvas_id)
	_expect(doc.canvases.is_empty() and int(ws.viewport.image_counts().canvases) == 0, "Delete should take the canvas out.")

	ws.change("Insert Decal", func() -> void:
		var decal := IMAGE_COMMAND.new_entry(doc, "decal")
		decal.merge({"body": body_id, "face": "", "position": Vector3(0.0, 0.05, 0.0), "normal": Vector3.UP, "up": Vector3.FORWARD,
			"size": Vector2(0.01, 0.01), "rotation": 0.0})
		doc.decals.append(decal))
	var decal_id := str(doc.decals[0].id)
	_expect(_baked_decals(part, body_id).size() == 1, "The decal should be baked under its body.")
	before = doc.snapshot()
	_press_eye("image", decal_id)
	_expect(_baked_decals(part, body_id).is_empty() and int(ws.viewport.image_counts().decals) == 0, "The eye should take the decal off the view and the bake.")
	ws._apply_snapshot(part, before)
	_expect(_baked_decals(part, body_id).size() == 1, "Undo should bake the decal again.")
	ws.rename_image("decals", decal_id, "Logo")
	var baked := _baked_decals(part, body_id)
	_expect(baked.size() == 1 and str(baked[0].name) == "Logo", "Rename should rename the baked decal (%s)." % [baked])
	ws.delete_image("decals", decal_id)
	_expect(_baked_decals(part, body_id).is_empty(), "Delete should take the baked decal away.")
	_expect(ws.rebuild_count == rebuilds, "Canvas and decal edits should rebuild nothing (%d rebuilds)." % (ws.rebuild_count - rebuilds))

	# A model edit still rebuilds, and its undo too.
	before = doc.snapshot()
	ws._change_body(body_id, "visible", "Show/Hide Body")
	_expect(ws.rebuild_count == rebuilds + 1, "Hiding a body should rebuild once (%d)." % (ws.rebuild_count - rebuilds))
	ws._apply_snapshot(part, before)
	_expect(ws.rebuild_count == rebuilds + 2, "Undoing it should rebuild once more (%d)." % (ws.rebuild_count - rebuilds))


func _press_eye(type: String, id: String) -> void:
	var item: TreeItem = ws.browser.item_for(type, id)
	_expect(item != null, "The browser should list %s %s." % [type, id])
	if item != null:
		ws.browser.button_clicked.emit(item, 0, BROWSER.BUTTON_EYE, MOUSE_BUTTON_LEFT)


func _eye_tooltip(type: String, id: String) -> String:
	var item: TreeItem = ws.browser.item_for(type, id)
	return item.get_button_tooltip_text(0, item.get_button_by_id(0, BROWSER.BUTTON_EYE)) if item != null else ""


func _item_text(type: String, id: String) -> String:
	var item: TreeItem = ws.browser.item_for(type, id)
	return item.get_text(0) if item != null else ""


func _baked_decals(part: Node3D, body_id: String) -> Array:
	var body: Node = part.body_nodes().get(body_id)
	if body == null:
		return []
	return body.get_children().filter(func(child: Node) -> bool: return child is Decal and not child.is_queued_for_deletion())


# --- Display survives model edits -------------------------------------------------------------

func _check_display_survives_edits() -> void:
	var part := await _new_part()
	var doc: Resource = part.document
	var body_id := _box()
	var box_id: String = doc.features[0].id
	ws.run_tool(CATALOG.find("solid.inspect.zebra_analysis"))
	ws.accept_command()
	ws.handle_key(_shift_n())
	var zebra_id := str(doc.analyses[0].id)
	var colors_id := str(doc.analyses[1].id) if doc.analyses.size() == 2 else ""
	_expect(_shown(zebra_id) and _shown(colors_id) and _colored(body_id), "Zebra and Component Colors should both be on, colors on top.")

	# An unrelated edit (the box's size) keeps both on.
	await _edit_box(box_id, "30")
	_expect(absf(_box_size(body_id) - 0.03) < 1e-6, "The box should be 30 mm long (%s)." % _box_size(body_id))
	_expect(_shown(zebra_id) and _shown(colors_id) and _colored(body_id), "Zebra and Component Colors should stay on through the box edit.")
	ws.handle_key(_shift_n())
	await _edit_box(box_id, "40")
	_expect(_shown(zebra_id) and not _shown(colors_id) and _shader_of(body_id) == ANALYSIS.ZEBRA_SHADER, "With colors off, the zebra should stay on through another edit.")

	# Shift+N while the box edit is open, then Cancel: the colors stay on, the box goes back.
	ws.edit_feature(box_id)
	await _set_length("45")
	ws.handle_key(_shift_n())
	_expect(_shown(colors_id) and ws.command != null, "Shift+N should show colors while the box edit stays open.")
	var carried: Dictionary = ws._command_before.analyses[1] if ws._command_before.analyses.size() == 2 else {}
	_expect(bool(carried.get("visible", false)), "The colors should go into the edit's starting state (%s)." % [carried])
	ws.cancel_command()
	_expect(absf(_box_size(body_id) - 0.04) < 1e-6 and _shown(colors_id) and _colored(body_id), "Cancel should put the box back and keep the colors on.")

	# Shift+N mid-edit, then OK: colors off, box changed; undoing the edit keeps the colors off.
	ws.edit_feature(box_id)
	await _set_length("45")
	ws.handle_key(_shift_n())
	var start: Dictionary = ws._command_before
	ws.accept_command()
	_expect(absf(_box_size(body_id) - 0.045) < 1e-6 and not _shown(colors_id) and _shader_of(body_id) == ANALYSIS.ZEBRA_SHADER, "OK should keep the new size and the colors off.")
	ws._apply_snapshot(part, start)
	_expect(absf(_box_size(body_id) - 0.04) < 1e-6 and not _shown(colors_id) and _shown(zebra_id), "Undoing the edit should restore the box and keep the colors off.")

	# Shift+N while Zebra's own panel is open and cancelled: only the new zebra goes away.
	ws.run_tool(CATALOG.find("solid.inspect.zebra_analysis"))
	_expect(doc.analyses.size() == 3, "A second zebra should show while its panel is open.")
	ws.handle_key(_shift_n())
	ws.cancel_command()
	_expect(doc.analyses.size() == 2 and _shown(colors_id) and _colored(body_id), "Cancel should drop the new zebra and keep the colors on (%s)." % [doc.analyses])


# --- A command's previewed bodies go back on Cancel -------------------------------------------

## Texture Map Controls previews a mapping on the view's bodies without a rebuild; Cancel (a
## view-only refresh, since the model is the one last rebuilt) must show the document's again.
func _check_preview_cancel() -> void:
	var part := await _new_part()
	var doc: Resource = part.document
	var body_id := _box()
	ws.change("Apply Appearance", func() -> void: doc.appearances[APPEARANCE.body_target(body_id)] = {"material": "builtin:paint_red", "mapping": {}})
	var before := _uv_span(body_id)
	ws.selection.append({"kind": "body", "body": body_id, "index": -1, "point": Vector3.ZERO})
	var rebuilds: int = ws.rebuild_count
	ws.run_tool(CATALOG.find("solid.modify.texture_map_controls"))
	var arrow := {}
	for h in ws.viewport.handles:
		if str(h.get("key", "")) == "scale_u":
			arrow = h
	_expect(not arrow.is_empty(), "Texture Map Controls should show a Scale U arrow.")
	if not arrow.is_empty():
		ws._on_manipulator_changed(arrow, float(arrow.base) * 2.0)
	var during := _uv_span(body_id)
	_expect(not during.is_equal_approx(before), "Dragging Scale U should change the view's texture at once (%s -> %s)." % [before, during])
	ws.cancel_command()
	_expect(_uv_span(body_id).is_equal_approx(before) and (doc.appearances[APPEARANCE.body_target(body_id)].mapping as Dictionary).is_empty(),
		"Cancel should put the mapping and the view's texture back (%s, was %s)." % [_uv_span(body_id), before])
	_expect(ws.rebuild_count == rebuilds, "Previewing and cancelling should rebuild nothing (%d rebuilds)." % (ws.rebuild_count - rebuilds))
	ws.selection.clear()


## How many texture repeats a body's first view surface spans along U and V.
func _uv_span(body_id: String) -> Vector2:
	var mesh: Mesh = ws.viewport.body_surface(body_id).mesh
	var uvs: PackedVector2Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV] if mesh != null else PackedVector2Array()
	if uvs.is_empty():
		return Vector2(-1, -1)
	var lo := uvs[0]
	var hi := uvs[0]
	for uv in uvs:
		lo = lo.min(uv)
		hi = hi.max(uv)
	return hi - lo


func _edit_box(box_id: String, length: String) -> void:
	ws.edit_feature(box_id)
	await _set_length(length)
	ws.accept_command()


func _set_length(length: String) -> void:
	var values: Dictionary = ws.command_values.duplicate(true)
	values["length"] = length
	ws.set_command_values(values)
	await process_frame


func _box_size(body_id: String) -> float:
	var body: Dictionary = ws.result.get("bodies", {}).get(body_id, {})
	return (body.shape.bbox() as AABB).size.x if not body.is_empty() else -1.0


func _shown(analysis_id: String) -> bool:
	var r: Dictionary = ws.analysis_results.get(analysis_id, {})
	return not r.is_empty() and str(r.error) == ""


func _colored(body_id: String) -> bool:
	var material := ws.viewport.body_surface(body_id).material_override as StandardMaterial3D
	return material != null and material.albedo_color == ANALYSIS.TOP_LEVEL_COLOR


# --- Helpers ----------------------------------------------------------------------------------

func _new_part() -> Node3D:
	var part: Node3D = CAD_PART.new()
	part.document = DOCUMENT.new()
	root.add_child(part)
	ws.set_part(part)
	await process_frame
	return part


## A default box (one undo step, as from the toolbar); returns its body id.
func _box() -> String:
	ws.run_tool(CATALOG.find("solid.create.box"))
	ws.accept_command()
	var bodies: Array = ws.result.get("bodies", {}).keys()
	_expect(bodies.size() == 1, "The box should be built (%s)." % [ws.result.get("errors", {})])
	return str(bodies[0]) if bodies.size() == 1 else ""


func _shader_of(body_id: String) -> Shader:
	var surface: MeshInstance3D = ws.viewport.body_surface(body_id)
	var material := surface.material_override as ShaderMaterial if surface != null else null
	return material.shader if material != null else null


func _key(code: Key) -> InputEventKey:
	var key := InputEventKey.new()
	key.keycode = code
	key.pressed = true
	return key


func _shift_n() -> InputEventKey:
	var key := _key(KEY_N)
	key.shift_pressed = true
	return key


func _expect(ok: bool, detail: String) -> void:
	if not ok:
		failures.append(detail)
		push_error(detail)
		print("FAIL: ", detail)


func _remove_tree(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	for file in dir.get_files():
		DirAccess.remove_absolute(path.path_join(file))
	for sub in dir.get_directories():
		_remove_tree(path.path_join(sub))
	DirAccess.remove_absolute(path)


func _set_values(changes: Dictionary) -> void:
	var values: Dictionary = ws.command_values.duplicate(true)
	values.merge(changes, true)
	ws.set_command_values(values)


## A box of the given size (mm) at position, accepted; returns its feature.
func _sized_box(length: String, width: String, height: String, position := Vector3.ZERO) -> Resource:
	ws.run_tool(CATALOG.find("solid.create.box"))
	_set_values({"length": length, "width": width, "height": height, "position": position})
	ws.recompute()
	ws.accept_command()
	return ws.doc.features.back()


func _face_toward(shape: RefCounted, normal: Vector3) -> int:
	for i in shape.face_count():
		var info: Dictionary = shape.face_info(i)
		if info.get("planar", false) and (info.normal as Vector3).dot(normal) > 0.999:
			return i
	return -1


# --- Exports and saves see only accepted work ------------------------------------------------

func _check_exports_close_edits() -> void:
	_remove_tree(ProjectSettings.globalize_path(temp))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(temp))
	var part := await _new_part()
	var doc: Resource = part.document
	_box()
	ws.run_tool(CATALOG.find("solid.create.cylinder"))
	await process_frame
	_expect(ws.command != null and doc.features.size() == 2, "A Cylinder preview should be open over the box.")
	ws.run_tool(CATALOG.find("utilities.utility.export_step"))
	_expect(ws.command == null and doc.features.size() == 1 and part.body_nodes().size() == 1,
		"Export STEP should drop the unaccepted Cylinder first (command %s, %d features, %d baked bodies)." % [ws.command, doc.features.size(), part.body_nodes().size()])
	var step := ProjectSettings.globalize_path(temp + "/closed.step")
	ws.files._file_chosen(step)
	var back: RefCounted = ws.kernel.import_file(step)
	_expect(back != null and not back.is_null() and back.solids().size() == 1, "The STEP should hold only the box (%s)." % ws.last_message)
	ws.run_tool(CATALOG.find("solid.create.cylinder"))
	await process_frame
	var boards := temp + "/boards"
	var out: Dictionary = ws.files.save_board_model("CloseBoard", ["tres", "step"], boards)
	_expect(str(out.get("error", "?")) == "" and ws.command == null, "Save Board Model Version should close the preview and save (%s)." % [out])
	var saved: Resource = null
	var saved_step := ""
	for path in out.get("paths", []):
		if str(path).ends_with(".tres"):
			saved = ResourceLoader.load(str(path), "", ResourceLoader.CACHE_MODE_IGNORE)
		elif str(path).ends_with(".step"):
			saved_step = str(path)
	_expect(saved != null and saved.features.size() == 1, "The saved design should hold only the accepted box.")
	var saved_shape: RefCounted = ws.kernel.import_file(saved_step) if saved_step != "" else null
	_expect(saved_shape != null and not saved_shape.is_null() and saved_shape.solids().size() == 1, "The saved STEP should hold one solid.")
	var manifest = JSON.parse_string(FileAccess.get_file_as_string(boards.path_join(EXPORT.MANIFEST_NAME)))
	var records: Array = manifest.get("files", []) if manifest is Dictionary else []
	_expect(not records.is_empty() and records.all(func(r: Dictionary) -> bool: return int(r.get("bodies", -1)) == 1),
		"Every manifest record should count one body (%s)." % [records.map(func(r: Dictionary) -> Variant: return r.get("bodies"))])


# --- Export notes ------------------------------------------------------------------------------

func _check_export_notes() -> void:
	var part := await _new_part()
	var doc: Resource = part.document
	var box := str(_sized_box("20", "20", "10").options.body_id)
	var shape: RefCounted = ws.result.bodies[box].shape
	var top := _face_toward(shape, Vector3.UP)
	ws.change("Add Decal", func() -> void:
		doc.decals.append({"id": "decal1", "name": "Sticker", "image": "res://icon.svg", "body": box, "face": str(shape.get_face_names()[top]),
			"position": Vector3(0, 0.01, 0), "normal": Vector3.UP, "size": Vector2(0.005, 0.005), "visible": true}))
	ws.recompute()
	_expect(EXPORT.decal_names(part) == PackedStringArray(["Sticker"]), "The baked part should hold the Sticker decal (%s)." % [EXPORT.decal_names(part)])
	ws.files.export_components(temp + "/glb", "glb")
	_expect(ws.last_message.contains("glTF can't hold decals, so Sticker was left out"), "A .glb export should say the decal was left out (%s)." % ws.last_message)
	ws.files.export_components(temp + "/tscn", "tscn")
	_expect(ws.last_message.begins_with("Exported 1 scene(s)") and not ws.last_message.contains("decals") and not ws.last_message.contains("could not be written"),
		"A .tscn export keeps decals and says nothing more (%s)." % ws.last_message)
	ws.files.export_body_meshes(temp + "/meshes")
	_expect(ws.last_message.begins_with("Exported 1 body mesh(es)") and not ws.last_message.contains("could not be written"),
		"Body meshes export without a note (%s)." % ws.last_message)


# --- Insert Fastener follows its face ----------------------------------------------------------

## An M6 washer from the Insert Fastener command on a 20 x 10 x 20 mm box's top rides the box as it
## moves 50 mm, keeps riding after an edit to M8 in its panel, and again after another 50 mm.
func _check_fastener_rides_moves() -> void:
	await _new_part()
	var doc: Resource = ws.doc
	var box_feature := _sized_box("20", "20", "10")
	var box := str(box_feature.options.body_id)
	ws.run_tool(CATALOG.find("solid.insert.insert_fastener"))
	_set_values({"kind": "washer", "size": "M6"})
	ws._on_reference_picked(REFERENCES.from_pick({"kind": "face", "body": box, "index": _face_toward(ws.result.bodies[box].shape, Vector3.UP)}, ws.result))
	ws.recompute()
	ws.accept_command()
	var fastener: Resource = doc.features.back()
	var washer := str(fastener.options.get("body_id", ""))
	_expect(fastener.type == "fastener" and ws.result.bodies.has(washer), "The washer should be made (%s)." % [ws.result.get("errors", {})])
	if not ws.result.bodies.has(washer):
		return
	var place: Array = fastener.options.get("place", [])
	_expect(not place.is_empty() and place[0].get("at") is Vector3 and (place[0].at as Vector3).is_equal_approx(fastener.options.position),
		"The command should anchor its face reference at the washer's position (%s)." % [place])
	# Its exact center of mass (a bbox follows the meshed circle, a few um off round).
	var centre := func() -> Vector3: return ws.result.bodies[washer].shape.center_of_mass()
	var moves := [Vector3(0.05, 0, 0), Vector3(0.1, 0, 0)]
	for k in moves.size():
		ws.edit_feature(box_feature.id)
		_set_values({"position": moves[k]})
		ws.recompute()
		ws.accept_command()
		var at: Vector3 = centre.call()
		_expect(absf(at.x - moves[k].x) < 1e-6 and absf(at.z) < 1e-6 and not (ws.result.get("warnings", {}) as Dictionary).has(fastener.id),
			"After the box moves to x = %s m the washer should be on its top's middle (%s; %s)." % [moves[k].x, at, ws.result.get("warnings", {})])
		if k == 0:
			# An edit in the fastener's own panel re-anchors it where it sits now.
			ws.edit_feature(fastener.id)
			_set_values({"size": "M8"})
			ws.recompute()
			ws.accept_command()
			place = fastener.options.get("place", [])
			_expect(str(fastener.options.size) == "M8" and not place.is_empty() and place[0].get("at") is Vector3
				and (place[0].at as Vector3).is_equal_approx(fastener.options.position) and absf((fastener.options.position as Vector3).x - 0.05) < 1e-6,
				"The M8 edit should keep the washer anchored where it sits (%s, %s)." % [fastener.options.position, place])


# --- Physical Material on components -----------------------------------------------------------

## Apply To Components gives the component the material and takes the own materials off every
## body in it, so the preview's mass is the one OK gives.
func _check_component_material() -> void:
	await _new_part()
	var doc: Resource = ws.doc
	var first := str(_sized_box("10", "10", "10").options.body_id)
	var second := str(_sized_box("10", "10", "10", Vector3(0.05, 0, 0)).options.body_id)
	ws.change("Group", func() -> void:
		doc.components["comp1"] = {"name": "Group", "parent": ""}
		doc.bodies[first]["component"] = "comp1"
		doc.bodies[second]["component"] = "comp1"
		doc.physical_materials["body:" + first] = "Aluminum"
		doc.physical_materials["body:" + second] = "Titanium")
	ws.selection.clear()
	ws.selection.append({"kind": "body", "body": first, "index": -1, "point": Vector3.ZERO})
	ws.run_tool(CATALOG.find("solid.modify.physical_material"))
	_expect(ws.command != null, "Physical Material should open.")
	if ws.command == null:
		return
	_set_values({"bodies": [first], "apply_to": "components", "material": "Copper"})
	var volume: float = ws.result.bodies[first].shape.volume()
	ws.accept_command()
	_expect(PHYSICAL.material_for(doc, first) == "Copper" and PHYSICAL.material_for(doc, second) == "Copper"
		and not doc.physical_materials.has("body:" + first) and not doc.physical_materials.has("body:" + second) and doc.physical_materials.get("component:comp1") == "Copper",
		"Apply To Components should reach both bodies of the component (%s)." % [doc.physical_materials])
	_expect(volume > 0.0 and absf(volume - 1e-6) < 1e-9, "The 10 mm box should be 1 cm^3 (%s)." % volume)
	ws.selection.clear()


# --- Measure on an open mesh -------------------------------------------------------------------

func _check_surface_measure() -> void:
	await _new_part()
	var doc: Resource = ws.doc
	# An open box mesh (its top missing): a surface body with no volume.
	var c := [Vector3(0, 0, 0), Vector3(0.01, 0, 0), Vector3(0.01, 0.01, 0), Vector3(0, 0.01, 0),
		Vector3(0, 0, 0.01), Vector3(0.01, 0, 0.01), Vector3(0.01, 0.01, 0.01), Vector3(0, 0.01, 0.01)]
	var quads := [[0, 1, 5, 4], [3, 7, 6, 2], [0, 3, 2, 1], [4, 5, 6, 7], [0, 4, 7, 3], [1, 2, 6, 5]]
	var positions := PackedVector3Array()
	var indices := PackedInt32Array()
	for q in quads.size():
		if q == 1:
			continue
		var base := positions.size()
		for k in quads[q]:
			positions.append(c[k])
		indices.append_array([base, base + 1, base + 2, base, base + 2, base + 3])
	var shape: RefCounted = ws.kernel.mesh_to_shape(positions, indices, "surf")
	_expect(shape != null and shape.solid_count() == 0, "The open mesh should be a surface.")
	if shape == null:
		return
	var measure: RefCounted = MEASURE_COMMAND.new()
	measure.workspace = ws
	var text: String = measure.describe(INSPECT.measure({"kind": "body", "body": "s"}, {}, INSPECT.context({"bodies": {"s": {"shape": shape}}}, doc, ws.kernel)))
	_expect(text.begins_with("Surface body (no volume), area"), "Measure should call an open mesh a surface body (%s)." % text)


# --- Editing the feature a command is making ---------------------------------------------------

## A double-click on the timeline's pending feature (its own command open) keeps the command and
## the feature, instead of cancelling a feature that was never accepted.
func _check_edit_pending_feature() -> void:
	await _new_part()
	var doc: Resource = ws.doc
	ws.run_tool(CATALOG.find("solid.create.box"))
	_expect(ws.command != null and doc.features.size() == 1, "A Box preview should be open.")
	if ws.command == null:
		return
	var running: RefCounted = ws.command
	ws.edit_feature(doc.features[0].id)
	_expect(ws.command == running and doc.features.size() == 1, "Editing the box its own command is making should keep the command (%s, %d features)." % [ws.command, doc.features.size()])
	ws.accept_command()
	_expect(ws.command == null and doc.features.size() == 1 and ws.result.bodies.size() == 1, "OK should then keep the box.")
	ws.run_tool(CATALOG.find("solid.create.cylinder"))
	ws.edit_feature(doc.features[0].id)
	_expect(ws.command != null and ws.command.feature != null and str(ws.command.feature.id) == str(doc.features[0].id) and doc.features.size() == 1,
		"Editing another feature should still cancel the open Cylinder and edit the box (%d features)." % doc.features.size())
	ws.cancel_command()


# --- What a click in the view means to Appearance and Export ------------------------------------

## A click in the view picks a face. Appearance's Apply To starts on Bodies, so that face colors its
## whole body (Faces gives the face its own); the mapping editors edit whatever the picked face
## shows. Export STEP narrows to picked bodies and components only, so a leftover face pick still
## writes every body. Insert and Export without a Forge part refuse before any file dialog.
func _check_view_picks() -> void:
	await _new_part()
	var doc: Resource = ws.doc
	var first := str(_sized_box("20", "20", "10").options.body_id)
	var second := str(_sized_box("20", "20", "10", Vector3(0.05, 0, 0)).options.body_id)
	var shape: RefCounted = ws.result.bodies[first].shape
	var top := _face_toward(shape, Vector3.UP)
	var face_pick := {"kind": "face", "body": first, "index": top, "point": Vector3.ZERO}
	ws.run_action("appearance")
	var panel = ws.appearance_panel
	_expect(panel.visible and panel._apply_to.selected == 0, "The Appearance panel should open on Apply To: Bodies.")
	ws.selection.clear()
	ws.selection.append(face_pick)
	panel.select_id("builtin:paint_red")
	panel.apply_selected()
	_expect(doc.appearances.has(APPEARANCE.body_target(first)) and not doc.appearances.keys().any(func(key: Variant) -> bool: return str(key).begins_with("face:")),
		"A clicked face should color its whole body in Bodies mode (%s)." % [doc.appearances.keys()])
	panel.refresh()
	_expect(not panel._type.disabled, "The picked face shows the body's appearance, so its mapping should be editable.")
	panel._scale[0].text = "40"
	panel._scale[0].text_submitted.emit("40")
	var mapping: Dictionary = (doc.appearances[APPEARANCE.body_target(first)] as Dictionary).get("mapping", {})
	_expect((mapping.get("scale", Vector2.ZERO) as Vector2).is_equal_approx(Vector2(0.04, 0.1)), "Typing a U scale should change the body's mapping (%s)." % [mapping])
	panel._apply_to.select(1)
	panel.select_id("builtin:metal_chrome")
	panel.apply_selected()
	var face_target := APPEARANCE.face_target(first, str(shape.get_face_names()[top]))
	_expect(doc.appearances.has(face_target) and str(doc.appearances[APPEARANCE.body_target(first)].material) == "builtin:paint_red",
		"Faces mode should give the face its own appearance and keep the body's (%s)." % [doc.appearances.keys()])
	panel._apply_to.select(0)
	panel.visible = false

	var step := ProjectSettings.globalize_path(temp + "/picks_all.step")
	_expect(ws.files.export_cad(step) == "", "Export STEP with a face picked should work (%s)." % ws.last_message)
	var back: RefCounted = ws.kernel.import_file(step)
	_expect(back != null and not back.is_null() and back.solids().size() == 2, "A leftover face pick should not narrow the STEP to one body (%s)." % ws.last_message)
	ws.selection.clear()
	ws.selection.append({"kind": "body", "body": second, "index": -1, "point": Vector3.ZERO})
	step = ProjectSettings.globalize_path(temp + "/picks_body.step")
	ws.files.export_cad(step)
	back = ws.kernel.import_file(step)
	_expect(back != null and not back.is_null() and back.solids().size() == 1 and ws.last_message.begins_with("Exported 1 body"),
		"A picked body should still narrow the STEP to that body (%s)." % ws.last_message)
	ws.change("Group", func() -> void:
		doc.components["comp1"] = {"name": "Group", "parent": ""}
		doc.bodies[first]["component"] = "comp1")
	ws.selection.clear()
	ws.selection.append({"kind": "component", "component": "comp1"})
	step = ProjectSettings.globalize_path(temp + "/picks_component.step")
	ws.files.export_cad(step)
	back = ws.kernel.import_file(step)
	_expect(back != null and not back.is_null() and back.solids().size() == 1 and ws.last_message.begins_with("Exported 1 body"),
		"A picked component should export its body (%s)." % ws.last_message)
	ws.selection.clear()

	ws.set_part(null)
	await process_frame
	for action in ["insert_svg", "insert_mesh", "insert_derive", "export_step", "export_components", "save_board_model"]:
		ws.files._file_callback = Callable()
		ws.files._options_callback = Callable()
		ws.last_message = ""
		ws.run_action(action)
		_expect(ws.last_message == "Select or add a Forge part first." and not ws.files._file_callback.is_valid() and not ws.files._options_callback.is_valid(),
			"%s without a part should refuse before any dialog (%s)." % [action, ws.last_message])


# --- The Surface workspace ----------------------------------------------------------------------

## E in a sketch in the Surface workspace is the surface Extrude (the sketch's own keys stay); a
## piece clicked for Trim goes where the click hit, so a holed strip's outer piece (its middle is
## on the disc) is the one removed; a surface's highlight shows from behind too, a solid's draws
## once; Delete takes selected faces out of their body and removes a split-off body.
func _check_surface_workspace() -> void:
	await _new_part()
	var doc: Resource = ws.doc
	ws.workspace = "Surface"
	ws.create_sketch(SKETCH_DATA.ORIGIN_PLANES.xy, "xy")
	var editor: RefCounted = ws.sketch_editor
	_expect(str(ws.tool_for_key("L").get("sketch", "")) == "line", "L in a sketch should stay the sketch's Line.")
	editor.start_tool("line")
	editor.tool_click(Vector2(0.0, 0.0), {}, {})
	editor.tool_click(Vector2(0.02, 0.0), {}, {})
	editor.cancel_tool()
	ws.handle_key(_key(KEY_E))
	_expect(ws.command != null and str(ws.command.get("key")) == "surface:extrude" and not editor.active,
		"E in a sketch in the Surface workspace should end it and start the surface Extrude (%s)." % [ws.command.get("key") if ws.command != null else null])
	if ws.command == null:
		return
	ws.viewport.look_from(Vector3(0.3, 1.0, 0.6))
	ws.viewport.fit()
	await process_frame
	_click(ws.viewport.project(Vector3(0.012, 0, 0)))
	_expect((ws.command_values.get("profiles", []) as Array).size() == 1, "Clicking the line should pick it (%s)." % [ws.command_values.get("profiles", [])])
	_set_values({"distance": "10"})
	ws.recompute()
	var strip := str(ws.command.feature.options.get("body_id", ""))
	ws.accept_command()
	_expect(ws.result.bodies.has(strip) and ws.result.bodies[strip].shape.is_surface(), "The clicked line should extrude into a surface (%s)." % [ws.result.get("errors", {})])
	ws.run_tool(CATALOG.find("solid.create.cylinder"))
	_set_values({"diameter": "4", "height": "20", "position": Vector3(0.01, -0.01, 0.005)})
	ws.recompute()
	var post := str(ws.command.feature.options.get("body_id", ""))
	ws.accept_command()

	ws.run_tool(CATALOG.find("surface.modify.trim"))
	ws._on_reference_picked({"kind": "body", "body": post})
	ws.recompute()
	_expect(ws.panel.active_selection_key == "remove" and ws.kernel.pieces(ws.result.bodies[strip].shape).size() == 2, "Trim by the post should show the strip's two pieces.")
	ws.viewport.look_from(Vector3.UP)
	await process_frame
	_click(ws.viewport.project(Vector3(0.002, 0, 0.002)))
	ws.recompute()
	var picks: Array = ws.command_values.get("remove", [])
	_expect(picks.size() == 1 and (picks[0].get("at", Vector3.INF) as Vector3).distance_to(Vector3(0.002, 0, 0.002)) < 1e-4,
		"A piece clicked for Trim should keep where the click hit (%s)." % [picks])
	ws.accept_command()
	_expect(absf(ws.result.bodies[strip].shape.area() * 1e6 - PI * 4.0) < 1e-3, "Clicking the outer piece should leave the disc (%s mm2)." % (ws.result.bodies[strip].shape.area() * 1e6))

	# Highlights: a surface's has a second pass for its back; a solid's draws once.
	var box := str(_sized_box("10", "10", "10", Vector3(0, -0.03, 0)).options.body_id)
	for spec in [[strip, true], [box, false]]:
		ws.selection.clear()
		ws.selection.append({"kind": "body", "body": spec[0], "index": -1, "point": Vector3.ZERO})
		ws._selection_changed(false)
		var shown: Array = ws.viewport._highlight_root.get_children().filter(func(n: Node) -> bool: return not n.is_queued_for_deletion())
		var material: BaseMaterial3D = (shown[0] as MeshInstance3D).material_override if shown.size() == 1 else null
		var back := material.next_pass as BaseMaterial3D if material != null else null
		var ok: bool = material != null and material.cull_mode == BaseMaterial3D.CULL_BACK and material.grow_amount > 0.0
		if spec[1]:
			ok = ok and back != null and back.cull_mode == BaseMaterial3D.CULL_FRONT and back.grow_amount < 0.0
		else:
			ok = ok and back == null
		_expect(ok, "The %s's highlight should draw %s." % ["surface" if spec[1] else "solid", "from both sides" if spec[1] else "its front once"])
	# Sectioned, a surface's highlight keeps its back pass.
	ws.run_tool(CATALOG.find("surface.inspect.section_analysis"))
	ws.accept_command()
	ws.selection.clear()
	ws.selection.append({"kind": "body", "body": strip, "index": -1, "point": Vector3.ZERO})
	ws._selection_changed(false)
	var cut_shown: Array = ws.viewport._highlight_root.get_children().filter(func(n: Node) -> bool: return not n.is_queued_for_deletion())
	var clipped: ShaderMaterial = (cut_shown[0] as MeshInstance3D).material_override as ShaderMaterial if cut_shown.size() == 1 else null
	var clipped_back := clipped.next_pass as ShaderMaterial if clipped != null else null
	_expect(clipped_back != null and clipped_back.shader.code.contains("cull_front") and float(clipped_back.get_shader_parameter("grow_amount")) < 0.0,
		"A sectioned surface's highlight should have a pass for its back.")
	ws.delete_analysis(str(doc.analyses[0].id) if not doc.analyses.is_empty() else "")
	ws.selection.clear()
	ws._selection_changed(false)

	# Delete: a split-off body goes (it has no feature of its own), and a face leaves its body.
	ws.run_tool(CATALOG.find("surface.modify.split_body"))
	ws._on_reference_picked({"kind": "body", "body": box})
	ws._on_reference_picked({"kind": "origin", "name": "yz"})
	ws.recompute()
	ws.accept_command()
	var piece := ""
	for body_id in ws.result.bodies:
		if str(body_id).begins_with(box + "."):
			piece = body_id
	var shape: RefCounted = ws.result.bodies[box].shape
	var top := -1
	for f in shape.face_count():
		if (shape.face_info(f).normal as Vector3).y > 0.99:
			top = f
	_expect(piece != "" and top >= 0, "The box should split in two (%s)." % [ws.result.bodies.keys()])
	var features_before: int = doc.features.size()
	ws.workspace = "Solid"
	ws.selection.clear()
	ws.selection.append({"kind": "face", "body": box, "index": top, "point": Vector3.ZERO})
	ws.run_action("delete")
	_expect(doc.features.size() == features_before and ws.last_message == "Select bodies to delete.", "In the Solid workspace a face alone isn't deleted (%s)." % ws.last_message)
	ws.workspace = "Surface"
	ws.selection.clear()
	ws.selection.append({"kind": "face", "body": box, "index": top, "point": Vector3.ZERO})
	ws.selection.append({"kind": "body", "body": piece, "index": -1, "point": Vector3.ZERO})
	ws.run_action("delete")
	var opened: RefCounted = ws.result.bodies.get(box, {}).get("shape")
	_expect(not ws.result.bodies.has(piece) and opened != null and opened.is_surface() and opened.face_count() == 5,
		"Delete should remove the split-off body and take the face out of the box (errors %s)." % [ws.result.get("errors", {})])
	ws.workspace = "Solid"


func _click(at: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	event.position = at
	ws.picker.handle_mouse(event)


# --- Stored choices the panel shows as others -----------------------------------------------------

## A stored choice the panel shows as another (a Patch's G2, which it can't build, reads as G1; a
## continuity kept as the number 1 is G1 too; an empty one is the field's default) goes into the
## feature when its edit opens, so the preview and OK build what the panel shows: OK with nothing
## changed closes the command and stores the choice shown (it flashed G2's error and stayed open).
## The panel takes a number without a script error and shows it, and no value as the default.
func _check_stored_choices() -> void:
	await _new_part()
	var doc: Resource = ws.doc
	var cube := _sized_box("10", "10", "10")
	var body := str(cube.options.get("body_id", ""))
	var shape: RefCounted = ws.result.get("bodies", {}).get(body, {}).get("shape")
	_expect(shape != null, "The cube should be built.")
	if shape == null:
		return
	var top: float = (shape.bbox() as AABB).end.y
	var rim := []
	for e in shape.edge_count():
		if absf((shape.edge_info(e).midpoint as Vector3).y - top) < 1e-7:
			rim.append(REFERENCES.from_pick({"kind": "edge", "body": body, "index": e}, ws.result))
	var cases := [["continuity", "g2", "g1", {}], ["other_continuity", "g2", "g1", {"continuity": "g0", "other_edges": [rim[0]]}], ["continuity", 1, "g1", {}], ["continuity", null, "g0", {}]]
	for spec in cases:
		var options := {"method": "patch", "boundary": rim.duplicate(true), "operation": OPERATIONS.NEW_BODY}
		options.merge(spec[3], true)
		options[spec[0]] = spec[1]
		var feature: Resource = doc.add_feature("surface", "Patch", {}, options)
		COMMAND.sync_body(doc, feature)
		ws.recompute()
		ws.edit_feature(feature.id)
		var shown: OptionButton = ws.panel._editors.get(spec[0]) if ws.command != null else null
		_expect(shown != null and str(shown.get_item_metadata(shown.selected)) == spec[2], "A Patch stored with %s %s should show %s (%s)." % [spec[0], spec[1], spec[2], shown.get_item_text(shown.selected) if shown != null else "no panel"])
		ws.accept_command()
		var kept: Resource = doc.find_feature(feature.id)
		_expect(ws.command == null and kept != null and str(kept.options.get(spec[0])) == spec[2] and not ws.result.get("errors", {}).has(feature.id),
			"OK with nothing changed should close it and store %s (open %s, stored %s, error '%s')." % [spec[2], ws.command != null, kept.options.get(spec[0]) if kept != null else null, ws.result.get("errors", {}).get(feature.id, "")])
		if ws.command != null:
			ws.cancel_command()
	var panel := COMMAND_PANEL.new()
	root.add_child(panel)
	var fields: Array[Dictionary] = [{"key": "c", "label": "C", "type": "enum", "options": [["g0", "G0"], ["g1", "G1"]], "default": "g1"}]
	panel.setup("T", fields, {"c": 1}, "mm")
	var choice: OptionButton = panel._editors.c
	_expect(typeof(choice.get_item_metadata(choice.selected)) == TYPE_INT and str(choice.get_item_metadata(choice.selected)) == "1" and str(panel.values.c) == "1", "A choice held as the number 1 should show as itself (%s)." % choice.get_item_text(choice.selected))
	panel.setup("T", fields, {"c": null}, "mm")
	choice = panel._editors.c
	_expect(str(choice.get_item_metadata(choice.selected)) == "g1" and str(panel.values.c) == "g1", "No value should show the field's default (%s, %s)." % [choice.get_item_text(choice.selected), panel.values.c])
	panel.set_values({"c": "g0"})
	panel.set_values({"c": null})
	choice = panel._editors.c
	_expect(str(choice.get_item_metadata(choice.selected)) == "g1" and str(panel.values.c) == "g1", "Refreshed with no value, it should show the default again (%s)." % panel.values.c)
	panel.queue_free()
