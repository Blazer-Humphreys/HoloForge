@tool
extends PanelContainer
## A panel that floats over a view: drag it by its title bar, resize it from the grip in its
## bottom-right corner or from its right and bottom edges, and collapse it to its title bar (the
## arrow, or a double-click on the title). It stays inside its parent, also when the parent
## shrinks, is never made bigger than MAX_SHARE of it or its content's own size (so the view stays
## usable), and goes back toward where it was put and how big it was made when the parent grows. Content that
## doesn't fit scrolls up and down; the panel never gets narrower than its content's minimum
## width, so widgets that should squeeze (long checkbox labels) trim their text instead. Mouse
## events on it never reach the view underneath.
##
## Widgets go in `content` (scrolls) and `footer` (always shown under it). With a store (see
## set_store) its place, size and collapsed state are saved after each move, resize, collapse
## or expand, and read back when the store is set. Its own colours come from one palette
## (apply_style), so a light or dark theme can restyle it live.

## The user moved, resized, collapsed or expanded the panel (once, when the drag ends).
signal layout_changed

const SECTION := "holo_forge"
## Sizes in pixels at 100% editor scale.
const PAD := 8.0
const BORDER := 1.0
const TITLE_GAP := 6.0
const FOOTER_GAP := 6.0
## The strip under the content the corner grip sits in.
const BOTTOM := 12.0
const GRIP := 12.0
const EDGE := 5.0
const RADIUS := 5.0
const TITLE_FONT := 13.0
## The most of its parent's width and height the panel is made (the size the user chose is kept).
const MAX_SHARE := 0.8
## The colours the panel starts with. apply_style() takes a palette with the same keys.
const DARK_STYLE := {
	"panel": Color(0.13, 0.14, 0.17, 0.92),
	"border": Color(1, 1, 1, 0.07),
	"shadow": Color(0, 0, 0, 0.22),
	"title": Color(0.18, 0.19, 0.23, 0.96),
	"title_hover": Color(0.21, 0.22, 0.27, 0.98),
	"title_text": Color(0.8, 0.84, 0.92),
	# The grip's and title's dots at rest (brighter while used).
	"grip": Color(0.85, 0.88, 0.95, 0.3),
	# The edge being resized, and a ticked check box.
	"accent": Color(0.25, 0.55, 1.0, 0.7),
	# Check boxes on the panel: their box and its fill.
	"check": Color(0.85, 0.88, 0.95, 0.75),
	"field": Color(0.08, 0.09, 0.11),
}
const RESIZE_AXES := {"right": Vector2(1, 0), "bottom": Vector2(0, 1), "grip": Vector2(1, 1)}
const FORGE_THEME := preload("res://addons/holo_forge/ui/forge_theme.gd")

## Where layouts go outside the editor: kept in memory for the whole run.
static var _memory_store := ConfigFile.new()

var title := "":
	set(value):
		title = value
		if _title_label != null:
			_title_label.text = value
## Holds the scrolling widgets.
var content: VBoxContainer
## Holds widgets that stay shown under the scrolling ones.
var footer: VBoxContainer
## The smallest the scrolling part may get at 100% scale (the title bar and footer come on top).
var min_content_size := Vector2(150, 60):
	set(value):
		min_content_size = value
		_refit()
## True while collapsed to the title bar.
var collapsed := false

var _store: Object
var _store_key := ""
var _home_position := Vector2(10, 40)
## Where the user put the panel and how big they made it (ZERO = as big as its content);
## what's shown is this clamped into the parent.
var _wanted_position := Vector2(10, 40)
var _wanted_size := Vector2.ZERO
var _min_size := Vector2.ZERO
var _drag := {}
var _hovered: Control
var _applying := false
## The editor's display scale (1 outside the editor).
var _s := 1.0
var _colors := DARK_STYLE.duplicate()
var _parent: Control
var _body: Control
var _panel_style: StyleBoxFlat
var _title_bar: PanelContainer
var _title_style: StyleBoxFlat
var _title_label: Label
var _collapse_button: Button
var _dots: Control
var _scroll: ScrollContainer
var _right_edge: Control
var _bottom_edge: Control
var _grip: Control


func _init() -> void:
	_s = EditorInterface.get_editor_scale() if Engine.is_editor_hint() else 1.0
	mouse_filter = Control.MOUSE_FILTER_STOP
	_panel_style = StyleBoxFlat.new()
	_panel_style.set_border_width_all(int(BORDER))
	_panel_style.set_corner_radius_all(int(_px(RADIUS)))
	_panel_style.shadow_size = int(_px(5))
	_panel_style.shadow_offset = Vector2(0, _px(2))
	_panel_style.set_content_margin_all(0)
	add_theme_stylebox_override("panel", _panel_style)

	# Laid out by hand (_layout_parts) so the grip and edges can sit over the panel's border.
	_body = Control.new()
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_body)

	_title_bar = PanelContainer.new()
	_title_bar.mouse_filter = Control.MOUSE_FILTER_STOP
	_title_bar.mouse_default_cursor_shape = Control.CURSOR_MOVE
	_title_bar.tooltip_text = "Drag to move. Double-click to collapse or expand."
	_title_style = StyleBoxFlat.new()
	_title_style.set_content_margin_all(_px(3))
	_title_style.content_margin_right = _px(8)
	_title_bar.add_theme_stylebox_override("panel", _title_style)
	_body.add_child(_title_bar)
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", int(_px(4)))
	_title_bar.add_child(row)
	_collapse_button = Button.new()
	_collapse_button.flat = true
	_collapse_button.focus_mode = Control.FOCUS_NONE
	_collapse_button.custom_minimum_size = Vector2(18, 18) * _s
	_collapse_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_collapse_button.pressed.connect(func() -> void: set_collapsed(not collapsed))
	_collapse_button.draw.connect(_draw_chevron)
	row.add_child(_collapse_button)
	_title_label = Label.new()
	_title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_title_label.add_theme_font_size_override("font_size", int(_px(TITLE_FONT)))
	row.add_child(_title_label)
	_dots = Control.new()
	_dots.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dots.custom_minimum_size = Vector2(7, 12) * _s
	_dots.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_dots.draw.connect(_draw_dots)
	row.add_child(_dots)

	content = VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll = ScrollContainer.new()
	_scroll.focus_mode = Control.FOCUS_NONE
	_scroll.follow_focus = true
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	_scroll.add_child(content)
	_body.add_child(_scroll)
	footer = VBoxContainer.new()
	_body.add_child(footer)

	_right_edge = _make_handle("right", Control.CURSOR_HSIZE, "")
	_bottom_edge = _make_handle("bottom", Control.CURSOR_VSIZE, "")
	_grip = _make_handle("grip", Control.CURSOR_FDIAGSIZE, "Drag to resize")
	_title_bar.gui_input.connect(func(event: InputEvent) -> void: _handle_input(event, _title_bar, "move"))
	_title_bar.mouse_entered.connect(_set_hovered.bind(_title_bar))
	_title_bar.mouse_exited.connect(_set_hovered.bind(null))

	for watched in [_title_bar, content, footer]:
		(watched as Control).minimum_size_changed.connect(_refit)
	apply_style(DARK_STYLE)
	_update_parts()


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_PARENTED:
			_parent = get_parent() as Control
			if _parent != null and not _parent.resized.is_connected(_apply):
				_parent.resized.connect(_apply)
		NOTIFICATION_UNPARENTED:
			if _parent != null and is_instance_valid(_parent) and _parent.resized.is_connected(_apply):
				_parent.resized.disconnect(_apply)
			_parent = null
		NOTIFICATION_ENTER_TREE, NOTIFICATION_THEME_CHANGED:
			_style_checks()
			_refit()
		NOTIFICATION_VISIBILITY_CHANGED:
			if is_visible_in_tree():
				_refit()
			else:
				_drag = {}
		NOTIFICATION_RESIZED:
			_layout_parts()


# --- Look ------------------------------------------------------------------------------------

## Restyles the panel live from a palette with DARK_STYLE's keys (panel, border, shadow, title,
## title_hover, title_text, grip, accent, check, field); keys left out, or not colours, keep the
## dark look. Its check boxes get boxes in check and field, ticked in accent.
func apply_style(palette: Dictionary) -> void:
	_colors = DARK_STYLE.duplicate()
	for key in DARK_STYLE:
		if palette.get(key) is Color:
			_colors[key] = palette[key]
	_panel_style.bg_color = _colors.panel
	_panel_style.border_color = _colors.border
	_panel_style.shadow_color = _colors.shadow
	_title_style.bg_color = _colors.title_hover if _hovered == _title_bar and _title_bar != null else _colors.title
	if _title_label != null:
		_title_label.add_theme_color_override("font_color", _colors.title_text)
	for part in [_collapse_button, _dots, _right_edge, _bottom_edge, _grip]:
		if part != null:
			(part as Control).queue_redraw()
	_style_checks()


## Gives the panel's check boxes their boxes in the panel's colours (the editor's own read poorly
## on it).
func _style_checks() -> void:
	if content == null:
		return
	var accent: Color = _colors.accent
	var icons := FORGE_THEME.check_icons(_colors.check, _colors.field, Color(accent, 1.0), Color(_colors.check, _colors.check.a * 0.5), 16.0 * _s)
	for box in find_children("*", "CheckBox", true, false):
		for icon in icons:
			(box as CheckBox).add_theme_icon_override(icon, icons[icon])


## The palette the panel is drawn with now.
func get_style() -> Dictionary:
	return _colors.duplicate()


# --- Place, size, collapsing -----------------------------------------------------------------

## Sets where the panel goes when nothing was saved (and moves it there).
func place(at: Vector2) -> void:
	_home_position = at
	_wanted_position = at
	_apply()


## Collapses the panel to its title bar or expands it, as the user would (saved).
func set_collapsed(on: bool) -> void:
	if collapsed == on:
		return
	_drag = {}
	collapsed = on
	_update_parts()
	_refit()
	_changed()


## The size the panel takes when the user hasn't sized it: everything shown without scrolling.
func natural_size() -> Vector2:
	var inner := _content_natural()
	var footer_size := _footer_size()
	var width := maxf(_title_bar.get_combined_minimum_size().x + BORDER * 2.0, maxf(inner.x, footer_size.x) + _px(PAD) * 2.0)
	var height := _title_height() + _px(TITLE_GAP) + inner.y + _footer_block(footer_size) + _px(BOTTOM)
	return Vector2(ceilf(width), ceilf(height)).max(_min_size)


## The smallest the panel may be (collapsed: just the title bar).
func minimum_panel_size() -> Vector2:
	return _min_size


## The place, size (ZERO = fit the content) and collapsed state the user chose.
func get_layout() -> Dictionary:
	return {"position": _wanted_position, "size": _wanted_size, "collapsed": collapsed}


## Puts the panel where a layout says (missing or broken values fall back to the defaults),
## clamped into the parent. Not saved.
func set_layout(data: Variant) -> void:
	var layout: Dictionary = data if data is Dictionary else {}
	var at: Variant = layout.get("position")
	_wanted_position = at if at is Vector2 and (at as Vector2).is_finite() else _home_position
	var wanted: Variant = layout.get("size")
	var size_ok: bool = wanted is Vector2 and (wanted as Vector2).is_finite() and wanted.x >= 0.0 and wanted.y >= 0.0
	_wanted_size = wanted if size_ok else Vector2.ZERO
	var was_collapsed: Variant = layout.get("collapsed")
	collapsed = was_collapsed if was_collapsed is bool else false
	_drag = {}
	_update_parts()
	_refit()


# --- Saving ----------------------------------------------------------------------------------

## The store layouts are saved in: the editor's project metadata in the editor, memory elsewhere.
static func default_store() -> Object:
	if Engine.is_editor_hint():
		return EditorInterface.get_editor_settings()
	return _memory_store


## Saves this panel's layout under key in the store (the editor settings' project metadata, or
## a ConfigFile), and puts the panel where the store last had it.
func set_store(store: Object, key: String) -> void:
	_store = store
	_store_key = key
	var saved: Variant = _read_store()
	if saved is Dictionary and not (saved as Dictionary).is_empty():
		set_layout(saved)


func get_store() -> Object:
	return _store


func _read_store() -> Variant:
	if _store == null or not is_instance_valid(_store) or _store_key == "":
		return null
	if _store.has_method("get_project_metadata"):
		return _store.get_project_metadata(SECTION, _store_key, {})
	if _store.has_method("get_value"):
		return _store.get_value(SECTION, _store_key, {})
	return null


func _save() -> void:
	if _store == null or not is_instance_valid(_store) or _store_key == "":
		return
	if _store.has_method("set_project_metadata"):
		_store.set_project_metadata(SECTION, _store_key, get_layout())
	elif _store.has_method("set_value"):
		_store.set_value(SECTION, _store_key, get_layout())


func _changed() -> void:
	_save()
	layout_changed.emit()


# --- The parts used by tests and owners ------------------------------------------------------

func get_title_bar() -> Control:
	return _title_bar


func get_collapse_button() -> Button:
	return _collapse_button


func get_scroll() -> ScrollContainer:
	return _scroll


func get_grip() -> Control:
	return _grip


func get_right_edge() -> Control:
	return _right_edge


func get_bottom_edge() -> Control:
	return _bottom_edge


# --- Layout ----------------------------------------------------------------------------------

func _px(value: float) -> float:
	return roundf(value * _s)


func _refit() -> void:
	if _body == null:
		return
	var footer_size := _footer_size()
	var inner := (min_content_size * _s).min(_content_natural())
	# Never so narrow that the content (and the scroll bar beside it) gets cut off.
	inner.x = maxf(inner.x, content.get_combined_minimum_size().x + _scroll.get_v_scroll_bar().get_combined_minimum_size().x)
	var width := maxf(_title_bar.get_combined_minimum_size().x + BORDER * 2.0, maxf(inner.x, footer_size.x) + _px(PAD) * 2.0)
	var height := _title_height()
	if not collapsed:
		height += _px(TITLE_GAP) + inner.y + _footer_block(footer_size) + _px(BOTTOM)
	_min_size = Vector2(ceilf(width), ceilf(height))
	_body.custom_minimum_size = _min_size
	_apply()


## Shows the wanted place and size, clamped into the parent (when it has a size yet).
func _apply() -> void:
	if _applying or _body == null:
		return
	_applying = true
	var shown := (_wanted_size if _wanted_size != Vector2.ZERO else natural_size()).max(_min_size)
	if collapsed:
		shown.y = _min_size.y
	var at := _wanted_position
	var area := _area()
	if area.x > 0.0 and area.y > 0.0:
		shown = shown.min(_largest(area))
		at = at.clamp(Vector2.ZERO, (area - shown).max(Vector2.ZERO))
	size = shown
	position = at
	_layout_parts()
	_applying = false


## The biggest the panel shows in an area: MAX_SHARE of it, or as big as its content when that's
## more (never past the area, never under its minimum).
func _largest(area: Vector2) -> Vector2:
	return (area * MAX_SHARE).floor().max(natural_size().min(area)).max(_min_size)


func _area() -> Vector2:
	return _parent.size if _parent != null and is_instance_valid(_parent) else Vector2.ZERO


func _title_height() -> float:
	return _title_bar.get_combined_minimum_size().y + BORDER


func _footer_size() -> Vector2:
	return footer.get_combined_minimum_size() if footer.get_child_count() > 0 else Vector2.ZERO


func _footer_block(footer_size: Vector2) -> float:
	return footer_size.y + _px(FOOTER_GAP) if footer.get_child_count() > 0 else 0.0


## The content's size with nothing wrapped or cut short.
func _content_natural() -> Vector2:
	return Vector2(_natural_width(content), content.get_combined_minimum_size().y)


## How wide a control is with nothing wrapped or cut short: a flow row at its one-line width, a
## button that trims its text at its whole text.
func _natural_width(control: Control) -> float:
	var minimum := control.get_combined_minimum_size().x
	var button := control as Button
	if button != null and (button.clip_text or button.text_overrun_behavior != TextServer.OVERRUN_NO_TRIMMING):
		var font := button.get_theme_font("font")
		return minimum + ceilf(font.get_string_size(button.text, HORIZONTAL_ALIGNMENT_LEFT, -1, button.get_theme_font_size("font_size")).x)
	var row := control is HFlowContainer or control is HBoxContainer
	if not row and not (control is VBoxContainer):
		return minimum
	var widest := 0.0
	var line := 0.0
	var count := 0
	for child in control.get_children():
		var item := child as Control
		if item == null or not item.visible or item.top_level:
			continue
		var width := _natural_width(item)
		widest = maxf(widest, width)
		line += width
		count += 1
	if not row:
		return maxf(minimum, widest)
	var gap := control.get_theme_constant("h_separation" if control is HFlowContainer else "separation")
	return maxf(minimum, line + maxf(count - 1, 0) * gap)


func _layout_parts() -> void:
	if _body == null:
		return
	var w := size.x
	var h := size.y
	var pad := _px(PAD)
	var bottom := _px(BOTTOM)
	var grip := _px(GRIP)
	var edge := _px(EDGE)
	var title_h := _title_height()
	_title_bar.position = Vector2(BORDER, BORDER)
	_title_bar.size = Vector2(w - BORDER * 2.0, title_h - BORDER)
	var footer_size := _footer_size()
	var footer_top := h - bottom - footer_size.y
	footer.position = Vector2(pad, footer_top)
	footer.size = Vector2(w - pad * 2.0, footer_size.y)
	var top := title_h + _px(TITLE_GAP)
	_scroll.position = Vector2(pad, top)
	_scroll.size = Vector2(w - pad * 2.0, maxf(h - top - bottom - _footer_block(footer_size), 0.0))
	_right_edge.position = Vector2(w - edge, title_h)
	_right_edge.size = Vector2(edge, maxf(h - title_h - grip, 0.0))
	_bottom_edge.position = Vector2(0, h - edge)
	_bottom_edge.size = Vector2(maxf(w - grip, 0.0), edge)
	_grip.position = Vector2(w - grip, h - grip)
	_grip.size = Vector2(grip, grip)


## Shows or hides the parts for the collapsed state.
func _update_parts() -> void:
	for part in [_scroll, footer, _right_edge, _bottom_edge, _grip]:
		(part as Control).visible = not collapsed
	var radius := int(_px(RADIUS - 1.0))
	_title_style.corner_radius_top_left = radius
	_title_style.corner_radius_top_right = radius
	_title_style.corner_radius_bottom_left = radius if collapsed else 0
	_title_style.corner_radius_bottom_right = radius if collapsed else 0
	_collapse_button.tooltip_text = "Expand" if collapsed else "Collapse"
	_collapse_button.queue_redraw()


# --- Moving and resizing ---------------------------------------------------------------------

func _make_handle(mode: String, cursor: Control.CursorShape, tip: String) -> Control:
	var handle := Control.new()
	handle.mouse_filter = Control.MOUSE_FILTER_STOP
	handle.mouse_default_cursor_shape = cursor
	handle.tooltip_text = tip
	handle.gui_input.connect(func(event: InputEvent) -> void: _handle_input(event, handle, mode))
	handle.mouse_entered.connect(_set_hovered.bind(handle))
	handle.mouse_exited.connect(_set_hovered.bind(null))
	handle.draw.connect(_draw_handle.bind(handle, mode))
	_body.add_child(handle)
	return handle


## Drags on the title bar (mode "move"), an edge or the grip; every mouse event on them is used up.
func _handle_input(event: InputEvent, handle: Control, mode: String) -> void:
	var button := event as InputEventMouseButton
	if button != null:
		if button.button_index == MOUSE_BUTTON_LEFT:
			if button.pressed and mode == "move" and button.double_click:
				_drag = {}
				set_collapsed(not collapsed)
			elif button.pressed:
				_drag = {"mode": mode, "handle": handle, "from": _in_parent(handle, button.position),
					"position": position, "size": size}
				handle.queue_redraw()
			elif not _drag.is_empty():
				_end_drag()
		handle.accept_event()
		return
	var motion := event as InputEventMouseMotion
	if motion != null:
		if not _drag.is_empty() and _drag.handle == handle:
			if motion.button_mask & MOUSE_BUTTON_MASK_LEFT:
				_drag_to(_in_parent(handle, motion.position))
			else:
				_end_drag()
		handle.accept_event()


## A point on a handle in the parent's coordinates.
func _in_parent(handle: Control, local: Vector2) -> Vector2:
	var point := handle.get_global_transform_with_canvas() * local
	return _parent.get_global_transform_with_canvas().affine_inverse() * point if _parent != null else point


func _drag_to(point: Vector2) -> void:
	var delta: Vector2 = point - _drag.from
	var area := _area()
	var has_area := area.x > 0.0 and area.y > 0.0
	if _drag.mode == "move":
		var at: Vector2 = _drag.position + delta
		if has_area:
			at = at.clamp(Vector2.ZERO, (area - size).max(Vector2.ZERO))
		_wanted_position = at
	else:
		var axes: Vector2 = RESIZE_AXES[_drag.mode]
		var start: Vector2 = _drag.size
		var wanted := Vector2(start.x + delta.x if axes.x > 0.0 else size.x, start.y + delta.y if axes.y > 0.0 else size.y)
		if has_area:
			wanted = wanted.min((area - position).min(_largest(area)))
		_wanted_size = wanted.max(_min_size)
		_wanted_position = position
	_apply()


func _end_drag() -> void:
	var moved: bool = _drag.position != position or _drag.size != size
	var handle: Control = _drag.handle
	_drag = {}
	handle.queue_redraw()
	if moved:
		_changed()


func _set_hovered(handle: Control) -> void:
	var old := _hovered
	_hovered = handle
	for item in [old, handle]:
		if item != null and is_instance_valid(item):
			(item as Control).queue_redraw()
	_title_style.bg_color = _colors.title_hover if handle == _title_bar else _colors.title


func _draw_handle(handle: Control, mode: String) -> void:
	var active: bool = _hovered == handle or (not _drag.is_empty() and _drag.handle == handle)
	var line := maxf(_px(2), 1.0)
	match mode:
		"grip":
			# A triangle of dots in the corner, brighter while used.
			var color: Color = _colors.grip
			if active:
				color.a = minf(color.a * 1.6, 1.0)
			for row in 3:
				for col in 3 - row:
					var at := handle.size - Vector2(5.5 + col * 3.5, 5.5 + row * 3.5) * _s
					handle.draw_rect(Rect2(at, Vector2(2.5, 2.5) * _s), color)
		"right":
			if active:
				handle.draw_rect(Rect2(Vector2(handle.size.x - line, line), Vector2(line, handle.size.y - line)), _colors.accent)
		"bottom":
			if active:
				handle.draw_rect(Rect2(Vector2(_px(4), handle.size.y - line), Vector2(handle.size.x - _px(4), line)), _colors.accent)


func _draw_chevron() -> void:
	var c := _collapse_button.size * 0.5
	var r := 3.5 * _s
	var points := PackedVector2Array([c + Vector2(-r * 0.5, -r), c + Vector2(r * 0.5, 0), c + Vector2(-r * 0.5, r)]) if collapsed \
		else PackedVector2Array([c + Vector2(-r, -r * 0.5), c + Vector2(0, r * 0.5), c + Vector2(r, -r * 0.5)])
	_collapse_button.draw_polyline(points, _colors.title_text, 1.6 * _s, true)


## Two columns of dots at the title's right end: a hint that the bar is a handle.
func _draw_dots() -> void:
	for i in 6:
		var at := Vector2(1 + (i % 2) * 4, 1 + int(i / 2.0) * 4) * _s
		_dots.draw_rect(Rect2(at, Vector2(2, 2) * _s), _colors.grip)
