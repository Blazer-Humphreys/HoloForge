@tool
extends Control
## The right-click marking menu: eight commands in a ring around the cursor plus an overflow
## list below. Click a slot (or flick toward it and release); click outside or Esc to close.

const RADIUS := 92.0

## Each entry: {"label", "enabled", "action": Callable}, and "checked": bool for a choice that is
## on or off (shown with a tick, or kept in line with ticked ones when off).
var _slots: Array[Dictionary] = []
var _center := Vector2.ZERO
## The ring's, the centre's and the buttons' colours (apply_theme; the dark look until then).
var _colors := {
	"marking_ring": Color(0.3, 0.6, 1.0, 0.3), "marking_center": Color(0.1, 0.11, 0.14, 0.75),
	"marking_back": Color(0.14, 0.15, 0.18, 0.96), "marking_border": Color(1, 1, 1, 0.1),
	"marking_text": Color(0.88, 0.9, 0.94), "marking_hover": Color(0.2, 0.3, 0.45, 0.98),
}
var _styles := {}


func _init() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_ALL
	visible = false
	apply_theme({})


## Colours the ring and the buttons from a view palette (forge_theme.gd's marking_* keys); keys
## left out keep their colours. Buttons already open change too.
func apply_theme(palette: Dictionary) -> void:
	for key in _colors:
		if palette.get(key) is Color:
			_colors[key] = palette[key]
	_styles.clear()
	for state in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		var box := StyleBoxFlat.new()
		box.bg_color = _colors.marking_hover if state in ["hover", "pressed", "hover_pressed"] else _colors.marking_back
		if state == "disabled":
			box.bg_color = Color(_colors.marking_back, _colors.marking_back.a * 0.75)
		box.border_color = _colors.marking_border
		box.set_border_width_all(1)
		box.set_corner_radius_all(5)
		box.content_margin_left = 10
		box.content_margin_right = 10
		box.content_margin_top = 4
		box.content_margin_bottom = 4
		if state == "focus":
			box.draw_center = false
			box.border_color = Color(0, 0, 0, 0)
		_styles[state] = box
	var list_style := StyleBoxFlat.new()
	list_style.bg_color = _colors.marking_back
	list_style.border_color = _colors.marking_border
	list_style.set_border_width_all(1)
	list_style.set_corner_radius_all(6)
	list_style.set_content_margin_all(4)
	_styles["list"] = list_style
	for child in find_children("*", "Control", true, false):
		if child is Button:
			_style_button(child)
		elif child is PanelContainer:
			(child as PanelContainer).add_theme_stylebox_override("panel", list_style)
	queue_redraw()


## The colours drawn now (for tests).
func colors() -> Dictionary:
	return _colors.duplicate()


## slots: up to 8 entries placed clockwise from the top; overflow: entries listed below.
func open(at: Vector2, slots: Array[Dictionary], overflow: Array[Dictionary]) -> void:
	for child in get_children():
		child.queue_free()
	_slots = slots
	_center = at
	for i in mini(slots.size(), 8):
		var angle := -PI * 0.5 + TAU * i / 8.0
		var button := _make_button(slots[i])
		button.reset_size()
		button.position = at + Vector2(cos(angle), sin(angle)) * RADIUS - button.size * 0.5
		add_child(button)
	if not overflow.is_empty():
		var list := VBoxContainer.new()
		var panel := PanelContainer.new()
		panel.add_theme_stylebox_override("panel", _styles.list)
		panel.add_child(list)
		for entry in overflow:
			var button := _make_button(entry)
			button.alignment = HORIZONTAL_ALIGNMENT_LEFT
			list.add_child(button)
		add_child(panel)
		panel.reset_size()
		panel.position = at + Vector2(-panel.size.x * 0.5, RADIUS + 24.0)
		panel.position.y = minf(panel.position.y, size.y - panel.size.y - 4.0)
	visible = true
	grab_focus()
	queue_redraw()


func close() -> void:
	visible = false
	for child in get_children():
		child.queue_free()


## The labels currently offered (ring first, then overflow), for tests.
func labels() -> PackedStringArray:
	var result := PackedStringArray()
	for child in find_children("*", "Button", true, false):
		if not child.is_queued_for_deletion():
			result.append((child as Button).text)
	return result


func _make_button(entry: Dictionary) -> Button:
	var button := Button.new()
	button.text = str(entry.label)
	if entry.has("checked"):
		var checked := bool(entry.checked)
		button.toggle_mode = true
		button.button_pressed = checked
		var tick := "✓ " if get_theme_default_font().has_char(0x2713) else "• "
		button.text = (tick if checked else "   ") + str(entry.label)
	button.disabled = not entry.get("enabled", true)
	if entry.has("tooltip"):
		button.tooltip_text = entry.tooltip
	var action: Callable = entry.get("action", Callable())
	button.pressed.connect(func() -> void:
		close()
		if action.is_valid():
			action.call())
	_style_button(button)
	return button


func _style_button(button: Button) -> void:
	for state in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		button.add_theme_stylebox_override(state, _styles[state])
	for state in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
		button.add_theme_color_override(state, _colors.marking_text)
	button.add_theme_color_override("font_disabled_color", Color(_colors.marking_text, 0.4))


func _draw() -> void:
	draw_circle(_center, 14.0, _colors.marking_center)
	draw_arc(_center, RADIUS, 0.0, TAU, 64, _colors.marking_ring, 2.0, true)


func _gui_input(event: InputEvent) -> void:
	var button := event as InputEventMouseButton
	if button != null and button.pressed:
		close()
		accept_event()
		return
	var key := event as InputEventKey
	if key != null and key.pressed and key.keycode == KEY_ESCAPE:
		close()
		accept_event()
