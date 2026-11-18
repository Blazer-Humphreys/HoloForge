extends SceneTree
## The floating panel the sketch palette uses, driven by real mouse events through the GUI:
## dragging its title bar moves it and the view under it gets none of the events (middle and
## right drags and the wheel on it don't reach the view either, and the view keeps keyboard
## focus), while clicks beside it still reach the view; the grip and the right and bottom edges
## resize it; it never gets smaller than its minimum (title and footer button shown); made small,
## its content scrolls (the wheel scrolls it) and its buttons still work; the arrow and a
## double-click on the title collapse and expand it; it stays inside a parent that shrinks and
## goes back when the parent grows; its layout is saved through a store (a ConfigFile or the
## editor settings' project metadata calls), only when the user changes it, and comes back
## clamped into view (broken values are ignored); its colours come from one palette that
## restyles it live (for a light or dark theme). Then the real sketch palette in a Forge
## workspace: moved and resized with real events without touching the view or the sketch, its
## checkboxes, line types, Look At, Fully Define and FINISH SKETCH still act, it stays inside a
## shrunk workspace, and the next sketch opens it where it was left.
##
## A panel is never made bigger than MAX_SHARE of the view (or its content), whatever size was
## saved, and its check boxes are drawn in its own colours.
##
## godot --headless --path . --script res://tests/holo_forge_palette_test.gd

const FLOATING := preload("res://addons/holo_forge/ui/floating_panel.gd")
const WORKSPACE := preload("res://addons/holo_forge/ui/forge_workspace.gd")
const CAD_PART := preload("res://addons/holo_forge/nodes/cad_part.gd")
const DOCUMENT := preload("res://addons/holo_forge/core/document.gd")
const SKETCH_DATA := preload("res://addons/holo_forge/core/sketch/sketch_data.gd")


## A store with the editor settings' project metadata calls that counts its writes.
class MetadataStore extends RefCounted:
	var data := {}
	var writes := 0

	func get_project_metadata(section: String, key: String, default: Variant = null) -> Variant:
		return data.get(section + "/" + key, default)

	func set_project_metadata(section: String, key: String, value: Variant) -> void:
		data[section + "/" + key] = value
		writes += 1


var failures: Array[String] = []
var _mouse := Vector2.ZERO
var _mask := 0


func _init() -> void:
	call_deferred("run")


func run() -> void:
	create_timer(180.0).timeout.connect(func() -> void:
		print("FAIL holo_forge_palette: timed out ", failures)
		quit(1))
	await _check_moving()
	await _check_resizing()
	await _check_collapsing()
	await _check_clamping()
	await _check_store()
	await _check_style()
	await _check_sketch_palette()
	print("PASS holo_forge_palette: title drags move the panel and nothing reaches the view (clicks beside it do), grip and edges resize it down to a minimum that keeps the title and footer, a small panel scrolls and its buttons work, the arrow and a title double-click collapse it, it stays inside a shrinking parent and goes back, layouts round-trip through a store only on user changes and come back clamped, apply_style restyles it live, and the real sketch palette moves, resizes, keeps working and keeps its place across sketches." \
		if failures.is_empty() else "FAIL holo_forge_palette")
	quit(0 if failures.is_empty() else 1)


# --- A panel over a stand-in view ------------------------------------------------------------

## A view (an overlay that counts the mouse events it gets, like the Forge view's) with a
## floating panel of 14 buttons and a footer button over it.
func _make_view(view_size: Vector2, store: Object = null, key := "test_panel") -> Dictionary:
	var view := Control.new()
	view.size = view_size
	root.add_child(view)
	var overlay := Control.new()
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.focus_mode = Control.FOCUS_ALL
	var seen := {"count": 0}
	overlay.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouse:
			seen.count += 1)
	view.add_child(overlay)
	var panel = FLOATING.new()
	panel.title = "TEST PANEL"
	var pressed := {}
	for i in 14:
		var button := Button.new()
		button.text = "Item number %d" % i
		var index := i
		button.pressed.connect(func() -> void: pressed[index] = true)
		panel.content.add_child(button)
	var done := Button.new()
	done.text = "DONE"
	done.pressed.connect(func() -> void: pressed["done"] = true)
	panel.footer.add_child(done)
	view.add_child(panel)
	panel.place(Vector2(20, 30))
	panel.set_store(store if store != null else ConfigFile.new(), key)
	await _frames(3)
	return {"view": view, "overlay": overlay, "seen": seen, "panel": panel, "pressed": pressed, "done": done}


func _free_view(made: Dictionary) -> void:
	(made.view as Control).queue_free()
	await _frames(1)


func _check_moving() -> void:
	var made := await _make_view(Vector2(1200, 900))
	var panel = made.panel
	var overlay: Control = made.overlay
	_expect(_near(panel.position, Vector2(20, 30)), "The panel should start where it was placed (%s)." % panel.position)
	_expect(_near(panel.size, panel.natural_size()), "The panel should start as big as its content (%s, wants %s)." % [panel.size, panel.natural_size()])
	_expect(not panel.get_scroll().get_v_scroll_bar().visible, "At its natural size nothing should scroll.")
	var start_size: Vector2 = panel.size
	overlay.grab_focus()

	# Drag by the title bar.
	await _drag(_title_point(panel), _title_point(panel) + Vector2(200, 120))
	_expect(_near(panel.position, Vector2(220, 150)), "Dragging the title by (200, 120) should move the panel there (%s)." % panel.position)
	_expect(_near(panel.size, start_size), "Moving shouldn't resize the panel (%s)." % panel.size)
	_expect(made.seen.count == 0, "The view under the panel should get none of the drag's events (%d)." % made.seen.count)
	_expect(overlay.has_focus(), "The view should keep the keyboard focus through the drag.")
	_expect(panel.get_title_bar().mouse_default_cursor_shape == Control.CURSOR_MOVE, "The title bar should show the move cursor.")

	# Middle and right drags and the wheel on the title don't move it or reach the view.
	for button in [MOUSE_BUTTON_MIDDLE, MOUSE_BUTTON_RIGHT]:
		await _drag(_title_point(panel), _title_point(panel) + Vector2(80, 40), button)
	_wheel(_title_point(panel), MOUSE_BUTTON_WHEEL_UP)
	await _frames(1)
	_expect(_near(panel.position, Vector2(220, 150)) and made.seen.count == 0, "Middle/right drags and the wheel on the title should do nothing (at %s, view saw %d)." % [panel.position, made.seen.count])

	# Dragged past the edge, it stops at the edge.
	await _drag(_title_point(panel), _title_point(panel) + Vector2(5000, 5000))
	var view_size: Vector2 = (made.view as Control).size
	_expect(_near(panel.position + panel.size, view_size), "Dragged far past the corner it should stop in the corner (%s + %s)." % [panel.position, panel.size])
	await _drag(_title_point(panel), _title_point(panel) - Vector2(5000, 5000))
	_expect(_near(panel.position, Vector2.ZERO), "Dragged far up-left it should stop at the top-left (%s)." % panel.position)

	# Clicks beside the panel still reach the view.
	_click(Vector2(900, 600))
	await _frames(1)
	_expect(made.seen.count > 0, "A click beside the panel should reach the view.")
	await _free_view(made)


func _check_resizing() -> void:
	# Tall enough that growing the panel 80 px stays within MAX_SHARE of the view.
	var made := await _make_view(Vector2(1000, 900))
	var panel = made.panel
	var start: Vector2 = panel.size
	await _drag(_center(panel.get_grip()), _center(panel.get_grip()) + Vector2(60, 80))
	_expect(_near(panel.size, start + Vector2(60, 80)), "The grip should resize both ways (%s, from %s)." % [panel.size, start])
	await _drag(_center(panel.get_right_edge()), _center(panel.get_right_edge()) + Vector2(30, 50))
	_expect(_near(panel.size, start + Vector2(90, 80)), "The right edge should resize only the width (%s)." % panel.size)
	await _drag(_center(panel.get_bottom_edge()), _center(panel.get_bottom_edge()) + Vector2(-70, -40))
	_expect(_near(panel.size, start + Vector2(90, 40)), "The bottom edge should resize only the height (%s)." % panel.size)
	_expect(_near(panel.position, Vector2(20, 30)), "Resizing shouldn't move the panel (%s)." % panel.position)
	_expect(panel.get_grip().mouse_default_cursor_shape == Control.CURSOR_FDIAGSIZE and panel.get_right_edge().mouse_default_cursor_shape == Control.CURSOR_HSIZE \
		and panel.get_bottom_edge().mouse_default_cursor_shape == Control.CURSOR_VSIZE, "The grip and edges should show resize cursors.")
	# Grown past the view, it stops at the view's edge, or at MAX_SHARE of the view when its content
	# needs less (the view stays usable).
	await _drag(_center(panel.get_grip()), _center(panel.get_grip()) + Vector2(3000, 3000))
	var view_size: Vector2 = (made.view as Control).size
	var largest: Vector2 = (view_size - panel.position).min((view_size * FLOATING.MAX_SHARE).floor().max(panel.natural_size().min(view_size)))
	_expect(_near(panel.size, largest), "Resized past the view it should stop at the view's edges or %d%% of the view (%s, expected %s)." % [roundi(FLOATING.MAX_SHARE * 100), panel.size, largest])

	# The minimum holds: the title and footer button stay whole.
	await _drag(_center(panel.get_grip()), _center(panel.get_grip()) - Vector2(3000, 3000))
	var minimum: Vector2 = panel.minimum_panel_size()
	_expect(_near(panel.size, minimum), "Shrunk far it should stop at its minimum (%s, minimum %s)." % [panel.size, minimum])
	var title: Control = panel.get_title_bar()
	_expect(title.size.x + 0.5 >= title.get_combined_minimum_size().x, "At the minimum the title bar should fit its title (%s)." % title.size)
	var done: Button = made.done
	_expect(panel.get_global_rect().encloses(done.get_global_rect()) and done.size.x + 0.5 >= done.get_combined_minimum_size().x,
		"At the minimum the footer button should be whole and inside the panel (%s in %s)." % [done.get_global_rect(), panel.get_global_rect()])
	_expect(made.seen.count == 0, "Resizing should send nothing to the view (%d)." % made.seen.count)

	# A small panel scrolls; the wheel scrolls it, and its buttons work.
	var scroll: ScrollContainer = panel.get_scroll()
	var content: Control = panel.content
	_expect(not scroll.get_h_scroll_bar().visible and content.size.x <= scroll.size.x + 0.5 and content.size.x + 0.5 >= content.get_combined_minimum_size().x,
		"At the minimum nothing should be cut off on the right (no sideways scrolling; content %s in %s)." % [content.size, scroll.size])
	var bar := scroll.get_v_scroll_bar()
	_expect(bar.visible and bar.max_value > bar.page, "At the minimum the content should scroll (bar %s, %s of %s)." % [bar.visible, bar.page, bar.max_value])
	_wheel(_center(scroll), MOUSE_BUTTON_WHEEL_DOWN)
	await _frames(3)
	_expect(scroll.scroll_vertical > 0, "The wheel over the content should scroll it (%d)." % scroll.scroll_vertical)
	var last: Button = panel.content.get_child(13)
	scroll.ensure_control_visible(last)
	await _frames(3)
	_click(_center(last))
	_click(_center(done))
	await _frames(1)
	_expect(made.pressed.get(13, false) and made.pressed.get("done", false), "The last item (scrolled to) and the footer button should still press (%s)." % [made.pressed])
	_expect(made.seen.count == 0, "Scrolling and clicking in the panel should send nothing to the view (%d)." % made.seen.count)
	await _free_view(made)


func _check_collapsing() -> void:
	var store := ConfigFile.new()
	var made := await _make_view(Vector2(1000, 700), store)
	var panel = made.panel
	var open_size: Vector2 = panel.size
	_click(_center(panel.get_collapse_button()))
	await _frames(1)
	_expect(panel.collapsed and _near(panel.size, Vector2(open_size.x, panel.minimum_panel_size().y)) and panel.size.y < 40.0,
		"The arrow should collapse the panel to its title bar (%s)." % panel.size)
	_expect(not panel.get_scroll().visible and not panel.get_grip().visible and not panel.footer.visible, "Collapsed, only the title bar should show.")
	_expect(bool(store.get_value("holo_forge", "test_panel", {}).get("collapsed", false)), "Collapsing should be saved.")
	_click(_center(panel.get_collapse_button()))
	await _frames(1)
	_expect(not panel.collapsed and _near(panel.size, open_size), "The arrow again should expand it to its size (%s)." % panel.size)
	_double_click(_title_point(panel))
	await _frames(1)
	_expect(panel.collapsed, "A double-click on the title should collapse it.")
	_double_click(_title_point(panel))
	await _frames(1)
	_expect(not panel.collapsed and _near(panel.size, open_size) and _near(panel.position, Vector2(20, 30)), "A second double-click should expand it in place (%s at %s)." % [panel.size, panel.position])
	_expect(made.seen.count == 0, "Collapsing and expanding should send nothing to the view (%d)." % made.seen.count)
	await _free_view(made)


func _check_clamping() -> void:
	var made := await _make_view(Vector2(1000, 700))
	var panel = made.panel
	var view: Control = made.view
	await _drag(_title_point(panel), _title_point(panel) + Vector2(600, 150))
	await _drag(_center(panel.get_grip()), _center(panel.get_grip()) + Vector2(40, 20))
	var put_at: Vector2 = panel.position
	var put_size: Vector2 = panel.size
	for shrunk in [Vector2(700, 480), Vector2(420, 260), Vector2(100, 80)]:
		view.size = shrunk
		await _frames(1)
		var rect := Rect2(panel.position, panel.size)
		var minimum: Vector2 = panel.minimum_panel_size()
		if shrunk.x >= minimum.x and shrunk.y >= minimum.y:
			_expect(Rect2(Vector2.ZERO, shrunk).grow(0.5).encloses(rect), "In a %s parent the panel should be inside it (%s)." % [shrunk, rect])
		else:
			_expect(_near(panel.position, Vector2.ZERO) and _near(panel.size, minimum), "In a %s parent too small for it, it should sit top-left at its minimum (%s)." % [shrunk, rect])
	view.size = Vector2(1000, 700)
	await _frames(1)
	_expect(_near(panel.position, put_at) and _near(panel.size, put_size), "When the parent grows back the panel should go back where it was (%s %s, was %s %s)." % [panel.position, panel.size, put_at, put_size])
	# Collapsed panels clamp too, and expanding keeps the whole panel inside.
	panel.set_collapsed(true)
	await _drag(_title_point(panel), _title_point(panel) + Vector2(0, 2000))
	_expect(absf(panel.position.y + panel.size.y - 700.0) < 0.75, "A collapsed panel should go down to the bottom edge (%s)." % panel.position)
	panel.set_collapsed(false)
	await _frames(1)
	_expect(Rect2(Vector2.ZERO, view.size).grow(0.5).encloses(Rect2(panel.position, panel.size)), "Expanded at the bottom edge it should move up to fit (%s %s)." % [panel.position, panel.size])
	await _free_view(made)


func _check_store() -> void:
	# A round trip through a ConfigFile.
	var store := ConfigFile.new()
	var a := await _make_view(Vector2(1000, 700), store, "round_trip")
	var panel_a = a.panel
	await _drag(_title_point(panel_a), _title_point(panel_a) + Vector2(310, 90))
	await _drag(_center(panel_a.get_grip()), _center(panel_a.get_grip()) + Vector2(-20, -60))
	var saved: Dictionary = store.get_value("holo_forge", "round_trip", {})
	_expect(saved == panel_a.get_layout() and _near(saved.get("position", Vector2.INF), panel_a.position) and _near(saved.get("size", Vector2.INF), panel_a.size),
		"The store should hold the panel's place and size (%s)." % [saved])
	var b := await _make_view(Vector2(1000, 700), store, "round_trip")
	_expect(_near(b.panel.position, panel_a.position) and _near(b.panel.size, panel_a.size) and b.panel.collapsed == panel_a.collapsed,
		"A panel reading the same store should come back the same (%s %s, saved %s %s)." % [b.panel.position, b.panel.size, panel_a.position, panel_a.size])
	await _free_view(a)
	await _free_view(b)

	# A saved place that no longer fits comes back into view; broken values are ignored.
	store.set_value("holo_forge", "far", {"position": Vector2(5000, 4000), "size": Vector2(3000, 2500), "collapsed": false})
	var far := await _make_view(Vector2(900, 600), store, "far")
	_expect(Rect2(0, 0, 900, 600).grow(0.5).encloses(Rect2(far.panel.position, far.panel.size)), "A saved place outside the view should be clamped into it (%s %s)." % [far.panel.position, far.panel.size])
	# A size saved on a bigger screen leaves most of the view free, and is kept for a bigger view.
	var share: Vector2 = (Vector2(900, 600) * FLOATING.MAX_SHARE).max(far.panel.natural_size())
	_expect(far.panel.size.x <= share.x + 0.5 and far.panel.size.y <= share.y + 0.5 and far.panel.get_layout().size == Vector2(3000, 2500),
		"A saved size bigger than the view should show at most %d%% of it and stay saved (%s, kept %s)." % [roundi(FLOATING.MAX_SHARE * 100), far.panel.size, far.panel.get_layout().size])
	_click(Vector2(20, 20))
	await _frames(1)
	_expect(far.seen.count > 0, "With a too-big saved size, a click in the view's free corner should still reach the view.")
	await _free_view(far)
	store.set_value("holo_forge", "broken", {"position": Vector2(NAN, 3), "size": "big", "collapsed": 7})
	var broken := await _make_view(Vector2(900, 600), store, "broken")
	_expect(_near(broken.panel.position, Vector2(20, 30)) and _near(broken.panel.size, broken.panel.natural_size()) and not broken.panel.collapsed,
		"Broken saved values should fall back to the defaults (%s %s)." % [broken.panel.position, broken.panel.size])
	await _free_view(broken)

	# The editor settings' calls: section holo_forge, written only when the user changes it.
	var metadata := MetadataStore.new()
	var c := await _make_view(Vector2(1000, 700), metadata, "sketch_palette")
	(c.view as Control).size = Vector2(500, 400)
	await _frames(1)
	c.panel.set_layout({"position": Vector2(40, 40)})
	c.panel.place(Vector2(15, 15))
	_click(Vector2(480, 380))
	await _frames(1)
	_expect(metadata.writes == 0, "Clamping, set_layout, place and clicks beside it shouldn't save (%d writes)." % metadata.writes)
	await _drag(_title_point(c.panel), _title_point(c.panel) + Vector2(30, 10))
	_click(_title_point(c.panel))
	await _frames(1)
	_expect(metadata.writes == 1 and metadata.data.has("holo_forge/sketch_palette"), "A drag should save once under holo_forge/sketch_palette, a still click not at all (%d writes, %s)." % [metadata.writes, metadata.data.keys()])
	await _free_view(c)
	var outside: Object = FLOATING.default_store()
	_expect(outside is ConfigFile and FLOATING.default_store() == outside, "Outside the editor the default store should be one in-memory ConfigFile.")


## The panel's colours come from one palette and change live; keys left out keep the dark look.
func _check_style() -> void:
	var made := await _make_view(Vector2(800, 600))
	var panel = made.panel
	var style: StyleBoxFlat = panel.get_theme_stylebox("panel")
	var title_style: StyleBoxFlat = panel.get_title_bar().get_theme_stylebox("panel")
	var label: Label = panel.get_title_bar().find_children("*", "Label", true, false)[0]
	_expect(style.bg_color == FLOATING.DARK_STYLE.panel and title_style.bg_color == FLOATING.DARK_STYLE.title and panel.get_style() == FLOATING.DARK_STYLE,
		"The panel should start dark (%s, %s)." % [style.bg_color, title_style.bg_color])
	var light := {"panel": Color(0.95, 0.95, 0.97, 0.94), "border": Color(0, 0, 0, 0.12), "title": Color(0.86, 0.87, 0.9),
		"title_text": Color(0.15, 0.16, 0.2), "grip": "not a colour"}
	panel.apply_style(light)
	await _frames(1)
	_expect(style.bg_color == light.panel and style.border_color == light.border and title_style.bg_color == light.title
		and label.get_theme_color("font_color") == light.title_text, "apply_style should restyle the panel, border, title bar and title text live.")
	_expect(panel.get_style().grip == FLOATING.DARK_STYLE.grip and panel.get_style().accent == FLOATING.DARK_STYLE.accent,
		"Keys left out or not colours should keep the dark look (%s)." % [panel.get_style()])
	# Hovering the title uses the palette's hover colour.
	_move(_title_point(panel))
	await _frames(1)
	_expect(title_style.bg_color == FLOATING.DARK_STYLE.title_hover, "Hovering the title should use the hover colour (%s)." % title_style.bg_color)
	panel.apply_style({"title_hover": Color(0.8, 0.82, 0.86)})
	_expect(title_style.bg_color == Color(0.8, 0.82, 0.86), "Restyled while hovered, the title should take the new hover colour.")
	_move(Vector2(700, 550))
	await _frames(1)
	_expect(title_style.bg_color == FLOATING.DARK_STYLE.title, "Off the title it should go back to the title colour (%s)." % title_style.bg_color)
	panel.apply_style(FLOATING.DARK_STYLE)
	_expect(panel.get_style() == FLOATING.DARK_STYLE and style.bg_color == FLOATING.DARK_STYLE.panel, "apply_style(DARK_STYLE) should bring the dark look back.")
	await _free_view(made)


# --- The sketch palette in a Forge workspace -------------------------------------------------

func _check_sketch_palette() -> void:
	var ws: Control = WORKSPACE.new()
	root.add_child(ws)
	ws.size = Vector2(1400, 900)
	await _frames(3)
	if ws.kernel == null:
		_expect(false, "The native kernel should load.")
		ws.queue_free()
		return
	var editor: RefCounted = ws.sketch_editor
	var palette = editor.palette
	_expect(palette != null and palette.get_script() == FLOATING, "The sketch palette should be a floating panel.")
	_expect(palette.get_store() == FLOATING.default_store(), "Outside the editor the palette should save to the in-memory store.")
	var index: int = palette.get_index()
	_expect(index > ws.viewport.overlay().get_index() and index < ws.panel.get_index() and index < ws.marking_menu.get_index() and index < ws.command_search.get_index(),
		"The palette should be over the view but under the command panel and the menus that open over the view.")
	var store := ConfigFile.new()
	palette.set_store(store, "sketch_palette")
	var part: Node3D = CAD_PART.new()
	part.document = DOCUMENT.new()
	root.add_child(part)
	ws.set_part(part)
	await _frames(1)
	var feature: Resource = ws.create_sketch(SKETCH_DATA.ORIGIN_PLANES.xz, "xz")
	await _frames(3)
	_expect(editor.active and palette.visible and palette.title == "SKETCH PALETTE", "Create Sketch should show the palette.")
	_expect(editor._palette_checks.size() == 8 and editor._palette_checks.values().all(func(c: CheckBox) -> bool: return palette.content.is_ancestor_of(c)),
		"The palette's 8 checkboxes should be in its scrolling content.")
	var labels := {}
	for button in palette.find_children("*", "BaseButton", true, false):
		labels[(button as BaseButton).get("text")] = button
	for text in ["Look At", "Normal", "Construction", "Centerline", "3D Sketch", "Fully Define", "FINISH SKETCH"]:
		_expect(labels.has(text), "The palette should have %s." % text)
	if not labels.has("FINISH SKETCH") or not labels.has("3D Sketch"):
		ws.queue_free()
		return
	_expect(palette.footer.is_ancestor_of(labels["FINISH SKETCH"]), "FINISH SKETCH should stay shown in the footer.")
	_expect(labels["3D Sketch"].disabled and str(labels["3D Sketch"].tooltip_text).contains("later phase"), "3D Sketch should stay disabled with its tooltip.")
	# Its check boxes are drawn in the panel's colours (the editor's own read poorly on it).
	for check in palette.find_children("*", "CheckBox", true, false):
		_expect((check as CheckBox).has_theme_icon_override("unchecked") and (check as CheckBox).has_theme_icon_override("checked"), "%s should have the panel's check box icons." % (check as CheckBox).text)
	var viewport_rect: Rect2 = ws.viewport.get_global_rect()
	_expect(_near(palette.position, Vector2(10, 40)) and viewport_rect.encloses(palette.get_global_rect()), "The palette should open at the view's top-left (%s)." % palette.position)
	var projected: CheckBox = editor._palette_checks["projected"]
	_expect(_near(palette.size, palette.natural_size()) and projected.size.x + 0.5 >= _full_width(projected) and not palette.get_scroll().get_v_scroll_bar().visible,
		"At first the palette should show everything whole without scrolling (%s, Show Projected Geometries %.0f of %.0f)." % [palette.size, projected.size.x, _full_width(projected)])

	# A rectangle to act on, and the view and sketch as they are.
	editor.start_tool("rect_2pt")
	editor.tool_click(Vector2(0.01, 0.005), {}, {})
	editor.tool_click(Vector2(0.05, 0.025), {}, {})
	editor.cancel_tool()
	await _frames(1)
	var line_id := -1
	for e in editor.sketch().entities():
		if e.type == "line" and line_id < 0:
			line_id = int(e.id)
	var seen := {"count": 0}
	ws.viewport.overlay().gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouse:
			seen.count += 1)
	var view_before := str(ws.viewport.view_state())
	var selection_before := str(editor.selection)

	# Move and resize it with real events.
	var from: Vector2 = palette.position
	await _drag(_title_point(palette), _title_point(palette) + Vector2(400, 120))
	_expect(_near(palette.position, from + Vector2(400, 120)), "Dragging the palette's title should move it (%s)." % palette.position)
	await _drag(_center(palette.get_grip()), _center(palette.get_grip()) + Vector2(-70, -200))
	await _drag(_center(palette.get_right_edge()), _center(palette.get_right_edge()) + Vector2(30, 0))
	await _frames(2)
	_expect(palette.size.y < palette.natural_size().y - 150.0 and palette.get_scroll().get_v_scroll_bar().visible, "Made shorter, the palette should scroll (%s)." % palette.size)
	_expect(seen.count == 0 and str(ws.viewport.view_state()) == view_before and str(editor.selection) == selection_before and editor.tool == "",
		"Moving and resizing the palette should leave the view and the sketch alone (view saw %d events)." % seen.count)
	_expect(store.has_section_key("holo_forge", "sketch_palette"), "The palette's place should be saved in its store.")
	var types: Control = labels["Normal"].get_parent()
	var narrow_at: Vector2 = palette.position
	var narrow_size: Vector2 = palette.size
	await _drag(_center(palette.get_right_edge()), _center(palette.get_right_edge()) - Vector2(1000, 0))
	await _frames(2)
	_expect(labels["Centerline"].position.y > labels["Normal"].position.y, "At its narrowest the line types should wrap onto another row (%s)." % types.size)
	var scroll_rect: Rect2 = palette.get_scroll().get_global_rect()
	_expect(not palette.get_scroll().get_h_scroll_bar().visible and projected.get_global_rect().end.x <= scroll_rect.end.x + 0.5 and labels["Construction"].get_global_rect().end.x <= scroll_rect.end.x + 0.5,
		"At its narrowest nothing should be cut off on the right (%s, %s in %s)." % [projected.get_global_rect(), labels["Construction"].get_global_rect(), scroll_rect])
	_expect(projected.size.x < _full_width(projected) and projected.tooltip_text == "Show Projected Geometries", "At its narrowest a long checkbox label should be cut short, whole in its tooltip (%.0f)." % projected.size.x)
	await _drag(_center(palette.get_right_edge()), _center(palette.get_right_edge()) + Vector2(narrow_size.x - palette.size.x, 0))
	await _frames(2)
	_expect(_near(palette.size, narrow_size) and _near(palette.position, narrow_at), "Widened again it should be as before (%s)." % palette.size)

	# Its checkboxes and buttons still act (and leave the keyboard with the view).
	ws.viewport.overlay().grab_focus()
	for key in ["points", "grid", "slice"]:
		var check: CheckBox = editor._palette_checks[key]
		var was: bool = editor.show[key]
		await _press_in_palette(palette, check)
		_expect(editor.show[key] == (not was) and check.button_pressed == (not was), "The %s checkbox should toggle after moving the palette." % key)
		await _press_in_palette(palette, check)
		_expect(editor.show[key] == was, "The %s checkbox should toggle back." % key)
	editor.selection.clear()
	editor.selection.append({"kind": "entity", "id": line_id})
	await _press_in_palette(palette, labels["Construction"])
	_expect(bool(editor.sketch().entity(line_id).get("construction", false)), "Construction should make the selected line a construction line.")
	await _press_in_palette(palette, labels["Centerline"])
	_expect(bool(editor.sketch().entity(line_id).get("centerline", false)), "Centerline should make it a centerline.")
	await _press_in_palette(palette, labels["Normal"])
	_expect(not bool(editor.sketch().entity(line_id).get("construction", true)), "Normal should make it a normal line again.")
	editor.selection.clear()
	ws.viewport.orbit(Vector2(120, 60))
	await _press_in_palette(palette, labels["Look At"])
	var facing: Vector3 = ws.viewport.camera_basis().z
	_expect(absf(facing.dot(Vector3.UP)) > 0.999, "Look At should face the ground-plane sketch (%s)." % facing)
	_expect(int(ws.result.sketches[feature.id].solve.dof) > 0, "The rectangle should start with free sizes.")
	await _press_in_palette(palette, labels["Fully Define"])
	await _frames(1)
	_expect(int(ws.result.sketches[feature.id].solve.dof) == 0, "Fully Define should leave nothing free (%d)." % int(ws.result.sketches[feature.id].solve.dof))
	_expect(seen.count == 0, "Using the palette should send nothing to the view (%d)." % seen.count)
	_expect(ws.viewport.overlay().has_focus(), "Using the palette should leave the keyboard with the view, for sketch shortcuts.")

	# It stays inside a shrunk workspace and goes back when it grows.
	var placed_at: Vector2 = palette.position
	var placed_size: Vector2 = palette.size
	ws.size = Vector2(760, 520)
	await _frames(3)
	_expect(ws.viewport.get_global_rect().grow(0.5).encloses(palette.get_global_rect()), "In a smaller workspace the palette should stay inside the view (%s in %s)." % [palette.get_global_rect(), ws.viewport.get_global_rect()])
	ws.size = Vector2(1400, 900)
	await _frames(3)
	_expect(_near(palette.position, placed_at) and _near(palette.size, placed_size), "Back at full size the palette should be where it was (%s %s)." % [palette.position, palette.size])

	# A layout saved on a bigger screen never covers the whole view.
	var kept: Dictionary = palette.get_layout()
	palette.set_layout({"position": Vector2(5000, 4000), "size": Vector2(3000, 2500)})
	await _frames(1)
	var view_size: Vector2 = ws.viewport.size
	_expect(palette.size.x <= view_size.x * FLOATING.MAX_SHARE + 0.5 and palette.size.y <= view_size.y * FLOATING.MAX_SHARE + 0.5,
		"A too-big saved palette should cover at most %d%% of the view (%s in %s)." % [roundi(FLOATING.MAX_SHARE * 100), palette.size, view_size])
	palette.set_layout(kept)
	await _frames(1)

	# FINISH SKETCH, then the next sketch opens it where it was left.
	await _press_in_palette(palette, labels["FINISH SKETCH"])
	_expect(not editor.active and not palette.visible, "FINISH SKETCH should finish the sketch and hide the palette.")
	ws.create_sketch(SKETCH_DATA.ORIGIN_PLANES.xy, "xy")
	await _frames(3)
	_expect(editor.active and palette.visible and _near(palette.position, placed_at) and _near(palette.size, placed_size),
		"The next sketch should open the palette where it was left (%s %s)." % [palette.position, palette.size])
	ws.run_action("finish_sketch")
	ws.set_part(null)
	ws.queue_free()
	part.queue_free()
	await _frames(1)


## How wide a button that trims its text is with its whole text.
func _full_width(button: Button) -> float:
	var font := button.get_theme_font("font")
	return button.get_combined_minimum_size().x + font.get_string_size(button.text, HORIZONTAL_ALIGNMENT_LEFT, -1, button.get_theme_font_size("font_size")).x


## Clicks a control inside the palette, scrolled into view first.
func _press_in_palette(palette, control: Control) -> void:
	if palette.content.is_ancestor_of(control):
		palette.get_scroll().ensure_control_visible(control)
		await _frames(2)
	_click(_center(control))
	await _frames(1)


# --- Mouse events ----------------------------------------------------------------------------

## A point on the title bar away from its collapse arrow.
func _title_point(panel) -> Vector2:
	var title: Control = panel.get_title_bar()
	return title.get_global_rect().position + Vector2(title.size.x * 0.6, title.size.y * 0.5)


func _center(control: Control) -> Vector2:
	return control.get_global_rect().get_center()


func _drag(from: Vector2, to: Vector2, button := MOUSE_BUTTON_LEFT) -> void:
	_move(from)
	_button(from, button, true)
	for i in 6:
		_move(from.lerp(to, (i + 1) / 6.0))
	_button(to, button, false)
	await _frames(1)


func _click(at: Vector2) -> void:
	_move(at)
	_button(at, MOUSE_BUTTON_LEFT, true)
	_button(at, MOUSE_BUTTON_LEFT, false)


func _double_click(at: Vector2) -> void:
	_click(at)
	_button(at, MOUSE_BUTTON_LEFT, true, true)
	_button(at, MOUSE_BUTTON_LEFT, false)


func _wheel(at: Vector2, button: MouseButton) -> void:
	_move(at)
	_button(at, button, true)
	_button(at, button, false)


func _button(at: Vector2, button: MouseButton, pressed: bool, double := false) -> void:
	var bit := 1 << (int(button) - 1) if int(button) <= 3 else 0
	_mask = (_mask | bit) if pressed else (_mask & ~bit)
	var event := InputEventMouseButton.new()
	event.button_index = button
	event.pressed = pressed
	event.double_click = double
	event.button_mask = _mask
	event.position = at
	event.global_position = at
	_mouse = at
	root.push_input(event, true)


func _move(to: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = to
	event.global_position = to
	event.relative = to - _mouse
	event.button_mask = _mask
	_mouse = to
	root.push_input(event, true)


func _key(keycode: Key) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.pressed = true
	return event


func _frames(count: int) -> void:
	for i in count:
		await process_frame


func _near(a: Vector2, b: Vector2) -> bool:
	return a.distance_to(b) < 0.75


func _expect(ok: bool, detail: String) -> void:
	if not ok:
		failures.append(detail)
		push_error(detail)
		print("FAIL: ", detail)
