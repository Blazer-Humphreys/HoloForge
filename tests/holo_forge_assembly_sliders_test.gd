extends SceneTree
## Holo Forge: the Drive Joints Value sliders and the Motion Link Test slider (spec 3.7, 3.8).
##
## 1. Panel: an expression field with "slider" gets a slider row; its span and step are in
##    display units; moving it writes the field as text (values_changed); typing moves it; the row
##    hides with its field; set_slider_range(); an empty span turns it off; drag start and end
##    are signalled.
## 2. Drive, limited Lever (-30..90°): the slider spans the limits; moving it to 60° previews and
##    OK stores exactly 60°; past the limit is not offered.
## 3. Drive, unlimited gear: the slider spans -360..360°.
## 4. Drive with contact (slider_wall, gap 10 mm): the slider spans ± the Block's box diagonal; a
##    slider drag sets dragging, stops at the Wall (S-CONTACT-STOP) and its end clears dragging.
## 5. Motion Link Test (gears, 2:1): moving Test to 30° shows Gear2 at 60° (view-only); OK stores
##    only the link (the joints keep their values); another driver sets Test up again at its value;
##    with contact on the note says the test ignores it.
##
## godot --headless --path . --script res://tests/holo_forge_assembly_sliders_test.gd

const WORKSPACE := preload("res://addons/holo_forge/ui/forge_workspace.gd")
const COMMAND_PANEL := preload("res://addons/holo_forge/ui/command_panel.gd")
const CAD_PART := preload("res://addons/holo_forge/nodes/cad_part.gd")
const CATALOG := preload("res://addons/holo_forge/tools/catalog.gd")
const F := preload("res://tests/holo_forge_assembly_fixtures.gd")
const DATA := preload("res://addons/holo_forge/core/assembly/assembly_data.gd")
const LINK := preload("res://addons/holo_forge/tools/assemble_link_command.gd")

const MM := 0.001

var failures: Array[String] = []
var ws: Control
var native := false


func _init() -> void:
	call_deferred("run")


func run() -> void:
	create_timer(300.0).timeout.connect(func() -> void:
		print("FAIL holo_forge_assembly_sliders: timed out ", failures)
		quit(1))
	_case("1 panel slider", await _check_panel())
	native = ClassDB.class_exists("CadShape") and ClassDB.class_exists("CadMesh")
	if native:
		ws = WORKSPACE.new()
		root.add_child(ws)
		ws.size = Vector2(1400, 900)
		for i in 3:
			await process_frame
		_case("2 drive slider on a limited joint", await _check_drive_limited())
		_case("3 drive slider on an unlimited turn", await _check_drive_unlimited())
		_case("4 drive slider drag stops at contact", await _check_drive_contact())
		_case("5 motion link test slider", await _check_link_test())
		ws.set_part(null)
		ws.queue_free()
		await process_frame
	else:
		print("SKIP 2-5: native library missing")
	print("PASS holo_forge_assembly_sliders: all cases" if failures.is_empty() else "FAIL holo_forge_assembly_sliders: %d failures" % failures.size())
	quit(0 if failures.is_empty() else 1)


# --- 1 -----------------------------------------------------------------------------------------

func _check_panel() -> bool:
	var panel: PanelContainer = COMMAND_PANEL.new()
	root.add_child(panel)
	var changed := []
	var drags := []
	panel.values_changed.connect(func(values: Dictionary) -> void: changed.append(values.duplicate()))
	panel.slider_drag.connect(func(key: String, active: bool) -> void: drags.append([key, active]))
	var fields: Array[Dictionary] = [
		{"key": "show", "label": "Show", "type": "bool"},
		{"key": "turn", "label": "Turn", "type": "expression", "kind": "angle", "slider": {"min": -PI, "max": PI}},
		{"key": "slide", "label": "Slide", "type": "expression", "kind": "length", "slider": {"min": 0.0, "max": 0.2}, "visible_if": {"show": [true]}},
		{"key": "plain", "label": "Plain", "type": "expression", "kind": "length"},
		{"key": "flat", "label": "Flat", "type": "expression", "kind": "length", "slider": {"min": 0.01, "max": 0.01}},
	]
	panel.setup("Test", fields, {"show": false, "turn": "30 deg", "slide": "12 mm", "plain": "1 mm", "flat": "10 mm"}, "mm")
	await process_frame
	var turn: HSlider = panel.slider("turn")
	var ok := _expect(turn != null and panel.slider("plain") == null, "Only fields with \"slider\" get one.")
	if turn == null:
		panel.queue_free()
		return ok
	ok = _expect(is_equal_approx(turn.min_value, -180.0) and is_equal_approx(turn.max_value, 180.0) and is_equal_approx(turn.step, 0.1), "The turn slider spans -180..180° in 0.1° steps (%s..%s by %s)." % [turn.min_value, turn.max_value, turn.step]) and ok
	ok = _expect(is_equal_approx(turn.value, 30.0), "The slider starts at the field's 30° (%s)." % turn.value) and ok
	turn.value = 45.0
	ok = _expect(str(panel.values.turn) == "45 deg" and not changed.is_empty() and str(changed[-1].turn) == "45 deg", "Moving it writes \"45 deg\" (%s)." % str(panel.values.turn)) and ok
	var edit: LineEdit = panel._editors["turn"]
	ok = _expect(edit.text == "45 deg", "The field shows it (%s)." % edit.text) and ok
	edit.text = "-90 deg"
	edit.text_changed.emit(edit.text)
	ok = _expect(is_equal_approx(turn.value, -90.0), "Typing moves the slider (%s)." % turn.value) and ok
	edit.text = "width * 2"
	edit.text_changed.emit(edit.text)
	ok = _expect(is_equal_approx(turn.value, -90.0), "Text that is not a plain value leaves it (%s)." % turn.value) and ok
	var slide: HSlider = panel.slider("slide")
	ok = _expect(slide != null and is_equal_approx(slide.max_value, 200.0) and is_equal_approx(slide.step, 0.1) and is_equal_approx(slide.value, 12.0), "The slide slider spans 0..200 mm in 0.1 mm steps at 12 mm.") and ok
	ok = _expect(not (panel._slider_rows["slide"] as Control).visible, "A hidden field's slider row hides too.") and ok
	(panel._editors["show"] as CheckBox).button_pressed = true
	ok = _expect((panel._slider_rows["slide"] as Control).visible, "It shows with its field.") and ok
	slide.value = 12.34
	ok = _expect(str(panel.values.slide) == "12.3 mm", "A slide writes to its step (%s)." % str(panel.values.slide)) and ok
	panel.set_slider_range("slide", -0.05, 0.05)
	ok = _expect(is_equal_approx(slide.min_value, -50.0) and is_equal_approx(slide.max_value, 50.0) and is_equal_approx(slide.value, 12.3), "set_slider_range gives a new span (%s..%s at %s)." % [slide.min_value, slide.max_value, slide.value]) and ok
	ok = _expect(not (panel.slider("flat") as HSlider).editable, "An empty span turns the slider off.") and ok
	turn.drag_started.emit()
	ok = _expect(panel.dragged_slider == "turn" and drags == [["turn", true]], "A drag start is signalled (%s)." % str(drags)) and ok
	turn.drag_ended.emit(true)
	ok = _expect(panel.dragged_slider == "" and drags.size() == 2 and drags[1] == ["turn", false], "A drag end is signalled (%s)." % str(drags)) and ok
	turn.drag_started.emit()
	panel.setup("Again", fields, {"turn": "0 deg"}, "mm")
	ok = _expect(panel.dragged_slider == "" and drags[-1] == ["turn", false], "A panel set up again mid-drag ends the drag.") and ok
	panel.setup("Inches", fields, {"show": true, "slide": "1 in"}, "in")
	slide = panel.slider("slide")
	ok = _expect(slide != null and slide.max_value >= 0.2 / 0.0254 and slide.max_value - 0.2 / 0.0254 <= slide.step and is_equal_approx(slide.value, 1.0), "An inch document shows inches, ends on whole steps (%s..%s by %s at %s)." % [slide.min_value, slide.max_value, slide.step, slide.value]) and ok
	ok = _expect(is_equal_approx(slide.min_value, 0.0), "An end on a whole step stays (%s)." % slide.min_value) and ok
	panel.queue_free()
	return ok


# --- 2 -----------------------------------------------------------------------------------------

func _check_drive_limited() -> bool:
	var f := F.lever()
	F.add_joint(f.doc, "revolute", f.components.Lever, F.circle_snap(f, "Lever", Vector3(0, 0, 10), 5.0), "", F.circle_snap(f, "Base", Vector3(0, 0, 10), 5.0),
		{"dofs": [{"value": 0.0, "min": deg_to_rad(-30.0), "max": deg_to_rad(90.0), "limited_min": true, "limited_max": true, "rest": 0.0}]})
	var part := await _start(f)
	var joint_id := str(DATA.normalized(f.doc.assembly).joints[0].id)
	ws.drive_joint(joint_id)
	var bar: HSlider = ws.panel.slider("dof0_value")
	var ok := _expect(bar != null, "Drive shows a slider under Turn Z.")
	if bar == null:
		return _finish(part, ok)
	ok = _expect(is_equal_approx(bar.min_value, -30.0) and is_equal_approx(bar.max_value, 90.0) and is_equal_approx(bar.value, 0.0), "It spans the limits -30..90° at 0 (%s..%s at %s)." % [bar.min_value, bar.max_value, bar.value]) and ok
	var lever_body: String = f.bodies.Lever
	var before: Transform3D = ws.viewport.body_pose(lever_body)
	bar.value = 60.0
	await _frames()
	ok = _expect(str(ws.command_values.get("dof0_value", "")) == "60 deg", "The Value row says 60 deg (%s)." % ws.command_values.get("dof0_value", "")) and ok
	ok = _expect(not ws.viewport.body_pose(lever_body).is_equal_approx(before), "The preview turns the Lever.") and ok
	ok = _expect(_status() == "", "No stop sentence inside the limits (%s)." % _status()) and ok
	bar.value = 120.0
	ok = _expect(is_equal_approx(bar.value, 90.0), "The slider does not go past the limit (%s)." % bar.value) and ok
	bar.value = 60.0
	await _frames()
	ws.accept_command()
	var stored := float(DATA.normalized(f.doc.assembly).joints[0].dofs[0].value)
	ok = _expect(ws.command == null and absf(stored - deg_to_rad(60.0)) < 1e-12, "OK stores 60° (%s rad)." % stored) and ok
	return _finish(part, ok)


# --- 3 -----------------------------------------------------------------------------------------

func _check_drive_unlimited() -> bool:
	var f := F.gears()
	var part := await _start(f)
	ws.drive_joint(str(f.joints.Joint1))
	var bar: HSlider = ws.panel.slider("dof0_value")
	var ok := _expect(bar != null and is_equal_approx(bar.min_value, -360.0) and is_equal_approx(bar.max_value, 360.0), "An unlimited turn spans -360..360° (%s..%s)." % ([bar.min_value, bar.max_value] if bar != null else ["-", "-"]))
	return _finish(part, ok)


# --- 4 -----------------------------------------------------------------------------------------

func _check_drive_contact() -> bool:
	var f := F.slider_wall()
	var part := await _start(f)
	ws.drive_joint(str(f.joints.Slider))
	var bar: HSlider = ws.panel.slider("dof0_value")
	var ok := _expect(bar != null, "Drive shows a slider under Slide.")
	if bar == null:
		return _finish(part, ok)
	# The Block's box is 20 x 20 x 20 mm: its diagonal is about 34.64 mm.
	var diagonal := sqrt(3.0) * 20.0
	ok = _expect(absf(bar.max_value - diagonal) < 0.5 and absf(bar.min_value + diagonal) < 0.5, "An unlimited slide spans ± the Block's box diagonal (%s..%s, about %s)." % [bar.min_value, bar.max_value, diagonal]) and ok
	bar.drag_started.emit()
	ok = _expect(bool(ws.command.dragging), "A slider drag sets dragging.") and ok
	for mm in [5.0, 15.0, 30.0]:
		bar.value = mm
		await _frames()
	ok = _expect(_status().begins_with("Motion stopped at ") and _status().contains("Wall"), "The drag stops at the Wall (%s)." % _status()) and ok
	bar.drag_ended.emit(true)
	ok = _expect(not bool(ws.command.dragging), "The drag's end clears dragging.") and ok
	ws.accept_command()
	var value := float(DATA.normalized(f.doc.assembly).joints[0].dofs[0].value)
	ok = _expect(absf(value - 10.0 * MM) < 0.05 * MM, "OK stores the stop near 10 mm (%s m)." % value) and ok
	return _finish(part, ok)


# --- 5 -----------------------------------------------------------------------------------------

func _check_link_test() -> bool:
	var f := F.gears()
	var part := await _start(f)
	var j1: String = f.joints.Joint1
	var j2: String = f.joints.Joint2
	var before: Dictionary = f.doc.assembly.duplicate(true)
	var cmd := _tool("solid.assemble.motion_link")
	if cmd == null:
		return _finish(part, _expect(false, "Motion Link should open."))
	await _put({"driver": j1 + "|0", "follower": j2 + "|0", "ratio": "2"})
	var bar: HSlider = ws.panel.slider(LINK.TEST_KEY)
	var ok := _expect(bar != null and is_equal_approx(bar.min_value, -360.0) and is_equal_approx(bar.max_value, 360.0) and is_equal_approx(bar.value, 0.0), "Test spans -360..360° at 0 (%s; sliders %s; fields %s)." % [
		[bar.min_value, bar.max_value, bar.value] if bar != null else "none", str(ws.panel._sliders.keys()), str(cmd.fields().map(func(field: Dictionary) -> String: return str(field.key)))])
	if bar == null:
		return _finish(part, ok)
	var gear2: String = f.bodies.Gear2
	var stored_pose: Transform3D = ws.viewport.body_pose(gear2)
	bar.value = 30.0
	await _frames()
	var shown: Dictionary = (cmd.preview.get("joints", {}) as Dictionary).get(j2, {})
	var values: PackedFloat64Array = shown.get("values", PackedFloat64Array())
	ok = _expect(values.size() == 1 and absf(values[0] - deg_to_rad(60.0)) < 1e-9, "Test 30° shows Gear2 at 60° (%s)." % str(values)) and ok
	ok = _expect(not ws.viewport.body_pose(gear2).is_equal_approx(stored_pose), "The view turns Gear2.") and ok
	ok = _expect(_status() == "", "No refusal or note (%s)." % _status()) and ok
	# Another driver: Test is set up again at that joint's value.
	await _put({"driver": j2 + "|0", "follower": j1 + "|0"})
	bar = ws.panel.slider(LINK.TEST_KEY)
	ok = _expect(bar != null and is_equal_approx(bar.value, 0.0) and str(ws.command_values.get(LINK.TEST_KEY, "")) == "0 deg", "Another driver puts Test at its value (%s)." % str(ws.command_values.get(LINK.TEST_KEY, ""))) and ok
	await _put({"driver": j1 + "|0", "follower": j2 + "|0"})
	bar = ws.panel.slider(LINK.TEST_KEY)
	bar.value = 30.0
	await _frames()
	ws.accept_command()
	var asm: Dictionary = DATA.normalized(f.doc.assembly)
	ok = _expect(ws.command == null and asm.links.size() == 1 and float(asm.links[0].ratio) == 2.0, "OK makes the 2:1 link (%d links)." % asm.links.size()) and ok
	var kept := DATA.normalized(before)
	for i in asm.joints.size():
		ok = _expect(float(asm.joints[i].dofs[0].value) == float(kept.joints[i].dofs[0].value), "Test stores no joint value (%s)." % asm.joints[i].name) and ok
	ok = _expect(ws.viewport.body_pose(gear2).is_equal_approx(stored_pose), "The view goes back to the stored poses.") and ok
	# With contact on, the note says the test does not stop at contact sets.
	var on: Dictionary = DATA.normalized(f.doc.assembly)
	on.links = []
	on.contact["enabled"] = true
	f.doc.assembly = on
	ws.set_part(null)
	ws.set_part(part)
	await process_frame
	cmd = _tool("solid.assemble.motion_link")
	await _put({"driver": j1 + "|0", "follower": j2 + "|0", "ratio": "2"})
	bar = ws.panel.slider(LINK.TEST_KEY)
	bar.value = 20.0
	await _frames()
	ok = _expect(_status().contains(LINK.S_TEST_NO_CONTACT), "With contact on, Test says it ignores contact (%s)." % _status()) and ok
	ws.cancel_command()
	return _finish(part, ok)


# --- helpers -----------------------------------------------------------------------------------

func _start(f: Dictionary) -> Node3D:
	var part: Node3D = CAD_PART.new()
	part.document = f.doc
	root.add_child(part)
	ws.set_part(part)
	await process_frame
	return part


func _finish(part: Node3D, ok: bool) -> bool:
	if ws.command != null:
		ws.cancel_command()
	ws.set_part(null)
	part.queue_free()
	return ok


func _tool(id: String) -> RefCounted:
	var tool := CATALOG.find(id)
	if tool.is_empty():
		return null
	ws.run_tool(tool)
	return ws.command


## Sets panel values as if typed and lets the deferred refresh run.
func _put(values: Dictionary) -> void:
	if ws.command == null:
		return
	var merged: Dictionary = ws.command_values.duplicate(true)
	merged.merge(values, true)
	ws.set_command_values(merged)
	await _frames()


func _frames() -> void:
	await process_frame
	await process_frame


func _status() -> String:
	return ws.panel.info("status")


func _case(label: String, passed: bool) -> void:
	print(("PASS " if passed else "FAIL ") + label)


func _expect(ok: bool, detail: String) -> bool:
	if not ok:
		failures.append(detail)
		print("  - " + detail)
	return ok
