@tool
extends PanelContainer
## The floating command panel: one row per command field (expressions, choices, points,
## selection slots, checkboxes, read-only info text, buttons), live error hints, and OK / Cancel
## (Enter / Esc).
##
## An expression field with "slider": {"min", "max", "tooltip"} (base units: meters, radians) gets
## a slider row under it. Moving the slider writes its value into the field as text in the
## document's units (as if typed, values_changed); typing moves the slider. slider_drag tells
## when a drag starts and ends, so a command can treat a drag like a handle drag.
##
## Expression and point fields also drag like the Inspector's numbers (ui/number_drag.gd): press
## and drag right to raise the value, left to lower it, as if typed; slider_drag tells of these
## drags too.

const UNITS := preload("res://addons/holo_forge/core/units.gd")
const POINT64 := preload("res://addons/holo_forge/core/point64.gd")
const DIMENSION_LAYOUT := preload("res://addons/holo_forge/core/sketch/dimension_layout.gd")
const NUMBER_DRAG := preload("res://addons/holo_forge/ui/number_drag.gd")
## A note hint's colour (amber: it tells of something the user may not want).
const NOTE_COLOR := Color(1.0, 0.78, 0.4, 0.9)
## The item id of a choice field's choice for a value it doesn't offer (see _select_value).
const UNOFFERED := 1 << 30

signal values_changed(values: Dictionary)
signal accepted
signal cancelled
## A selection slot was clicked: viewport picks now fill this field.
signal selection_field_activated(key: String)
## A "button" field was pressed.
signal button_pressed(key: String)
## A field's slider drag started (active) or ended.
signal slider_drag(key: String, active: bool)

## How many steps a slider's span is split into (the step is the power of ten below span / this).
const SLIDER_STEPS := 1000.0

var values := {}
var document_units := "mm"
var active_selection_key := ""
## (item) -> String: a short label for a picked item (single-pick slots show it).
var describer: Callable
## The tallest the panel may be (0 = no limit); past that its rows scroll, so tall panels
## (Canvas, Fastener) stay usable in a short view.
var max_height := 0.0:
	set(value):
		max_height = value
		_fit_rows()

var _title: Label
var _scroll: ScrollContainer
var _rows: VBoxContainer
## Rows of fields marked "pinned" (a Mesh tool's result row): under the scrolling rows, so they
## stay in sight when a short panel scrolls the others.
var _pinned: VBoxContainer
var _fields: Array[Dictionary] = []
var _row_nodes := {}
var _hints := {}
var _editors := {}
## The sliders of fields with "slider" (key -> HSlider) and their rows (key -> row).
var _sliders := {}
var _slider_rows := {}
## Spans given with set_slider_range() (key -> PackedFloat64Array [low, high], base units), over
## the fields' own.
var _slider_spans := {}
## The key of the slider being dragged ("" for none).
var dragged_slider := ""
var _ok: Button
## What a choice field with "auto" shows while its value is that auto value (key -> the choice
## the auto value stands for now; see show_auto).
var _auto_shown := {}


func _init() -> void:
	custom_minimum_size = Vector2(290, 0)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.13, 0.14, 0.17, 0.95)
	style.border_color = Color(0.25, 0.55, 1.0, 0.8)
	style.set_border_width_all(1)
	style.border_width_top = 3
	style.set_corner_radius_all(4)
	style.set_content_margin_all(8)
	add_theme_stylebox_override("panel", style)
	var box := VBoxContainer.new()
	add_child(box)
	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 15)
	box.add_child(_title)
	_rows = VBoxContainer.new()
	_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	# The rows are always laid out as if the scrollbar were showing (it still shows only when
	# needed). Word-wrapped info rows change height with their width, so when the scrollbar took
	# its width only while showing, the rows' width followed the scrollbar, their height their
	# width and the scrollbar their height: at some heights it switched on and off for ever,
	# flooding the message queue with layout updates (a rendering editor stalled).
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_RESERVE
	_scroll.follow_focus = true
	_scroll.add_child(_rows)
	box.add_child(_scroll)
	_rows.minimum_size_changed.connect(_fit_rows)
	_pinned = VBoxContainer.new()
	_pinned.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(_pinned)
	_pinned.minimum_size_changed.connect(_fit_rows)
	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_END
	_ok = Button.new()
	_ok.text = "OK"
	_ok.pressed.connect(func() -> void: accepted.emit())
	var cancel := Button.new()
	cancel.text = "Cancel"
	cancel.pressed.connect(func() -> void: cancelled.emit())
	buttons.add_child(_ok)
	buttons.add_child(cancel)
	box.add_child(buttons)


func setup(title: String, fields: Array[Dictionary], p_values: Dictionary, p_units: String) -> void:
	_title.text = title.to_upper()
	_fields = fields
	values = p_values.duplicate(true)
	document_units = p_units
	active_selection_key = ""
	# Out of the rows at once: rows only queued for freeing would still count towards the new
	# panel's size (and get layout updates) until the end of the frame.
	for holder in [_rows, _pinned]:
		for child in holder.get_children():
			holder.remove_child(child)
			child.queue_free()
	_row_nodes.clear()
	_hints.clear()
	_editors.clear()
	_auto_shown.clear()
	_sliders.clear()
	_slider_rows.clear()
	_slider_spans.clear()
	if dragged_slider != "":
		# (The dragged slider is gone with its row: the drag is over.)
		var key := dragged_slider
		dragged_slider = ""
		slider_drag.emit(key, false)
	for field in fields:
		_add_row(field)
	# (An empty holder would still take its gap in the panel.)
	_pinned.visible = _pinned.get_child_count() > 0
	_update_visibility()
	_scroll.scroll_vertical = 0
	_fit_rows()
	reset_size()


## Refreshes the editors from values (after a handle drag) without emitting values_changed. The
## field that has the keyboard keeps its text (it is being typed in, and what is typed is what
## values holds for it), except for the keys in changed_elsewhere: values that something other
## than typing changed (a dragged handle), which the field shows at once, the caret at the end.
func set_values(p_values: Dictionary, changed_elsewhere: Array = []) -> void:
	values = p_values.duplicate(true)
	for field in _fields:
		var key: String = field.key
		var editor = _editors.get(key)
		var shown_anyway := changed_elsewhere.has(key)
		match str(field.type):
			"expression", "text":
				if editor is LineEdit and (shown_anyway or not (editor as LineEdit).has_focus()):
					_show_text(editor as LineEdit, str(values.get(key, "")))
				if dragged_slider != key:
					_sync_slider(key)
			"point":
				var p := POINT64.exact(values, key)
				for axis in 3:
					var line: LineEdit = editor[axis]
					if shown_anyway or not line.has_focus():
						_show_text(line, UNITS.format_value(p[axis], UNITS.KIND_LENGTH, document_units).split(" ")[0])
			"selection":
				_update_selection_button(key)
			"enum":
				_show_choice(editor, field)
			"bool":
				(editor as CheckBox).set_pressed_no_signal(bool(values.get(key, false)))
	_update_visibility()


## Lets a number field drag (ui/number_drag.gd): each step goes in as if typed (text_changed), and
## slider_drag tells when the drag starts and ends.
func _drag_number(edit: LineEdit, key: String, kind: String, options: Dictionary) -> void:
	var helper: RefCounted = NUMBER_DRAG.attach(edit, kind, func() -> String: return document_units,
		func(text: String) -> void: edit.text_changed.emit(text), options)
	helper.dragging_changed = func(active: bool) -> void: slider_drag.emit(key, active)


## Puts text in a field; one that has the keyboard keeps its caret at the end of the new text.
static func _show_text(line: LineEdit, text: String) -> void:
	if line.text == text:
		return
	line.text = text
	if line.has_focus():
		line.caret_column = text.length()


## Scrolls the rows so a field's row shows (a panel shortened to stay off the edited body keeps
## its result row in sight).
func ensure_row_visible(key: String) -> void:
	var row: Control = _row_nodes.get(key)
	if row != null and row.visible and _scroll != null and row.get_parent() == _rows:
		_scroll.ensure_control_visible(row)


## Shows each expression's evaluated value (not for a plain number, which it would only repeat),
## or its error in red. hints: key -> {"ok", "text"}, optionally "note": true (shown in amber even
## beside a plain number) and "tooltip" (the longer text on hover).
func set_hints(hints: Dictionary) -> void:
	var all_ok := true
	for key in _hints:
		var label: Label = _hints[key]
		var hint: Dictionary = hints.get(key, {})
		var text := str(hint.get("text", ""))
		var edit := _editors.get(key) as LineEdit
		# (A plain number needs no hint, but a note, {"note": true}, shows anyway.)
		if hint.get("ok", true) and not hint.get("note", false) and edit != null and DIMENSION_LAYOUT.is_literal(edit.text.strip_edges()):
			text = ""
		label.text = text
		label.modulate = Color(1, 1, 1, 0.55) if hint.get("ok", true) else Color(1.0, 0.45, 0.4)
		if hint.get("note", false):
			label.modulate = NOTE_COLOR
		# The hint is narrow: a longer explanation ("tooltip") shows on hover.
		label.tooltip_text = str(hint.get("tooltip", ""))
		label.mouse_filter = Control.MOUSE_FILTER_PASS if label.tooltip_text != "" else Control.MOUSE_FILTER_IGNORE
		var row: Control = _row_nodes.get(key)
		if not hint.get("ok", true) and row != null and row.visible:
			all_ok = false
	_ok.disabled = not all_ok


func focus_first() -> void:
	for field in _fields:
		var editor = _editors.get(field.key)
		if editor is LineEdit:
			(editor as LineEdit).grab_focus()
			(editor as LineEdit).select_all()
			return


## Takes the OK button away or gives it back (a tool that is computing takes no second OK). The
## next set_hints() decides again from the fields.
func set_ok_enabled(on: bool) -> void:
	_ok.disabled = not on


## Sets the OK button's label (e.g. "Close" for tools that apply on click).
func set_ok_text(text: String) -> void:
	_ok.text = text


## Sets the text of a read-only "info" field (measure results, mass numbers).
func set_info(key: String, text: String) -> void:
	var label = _editors.get(key)
	if label is Label and (label as Label).text != text:
		(label as Label).text = text
		reset_size()


## Gives the rows their full height, or what is left of max_height (they scroll past that).
func _fit_rows() -> void:
	if _scroll == null:
		return
	# The scroll area's own frame (its theme margins) comes on top of the rows.
	var frame := _scroll.get_minimum_size().y
	var wanted := _rows.get_combined_minimum_size().y + frame
	if max_height > 0.0:
		# The title, OK / Cancel and the margins keep their room; only the rows give up height.
		var others := get_combined_minimum_size().y - _scroll.get_combined_minimum_size().y
		wanted = minf(wanted, maxf(max_height - others, 80.0 + frame))
	if not is_equal_approx(_scroll.custom_minimum_size.y, wanted):
		_scroll.custom_minimum_size.y = wanted
		reset_size()


## The text an "info" field shows ("" when there is no such field).
func info(key: String) -> String:
	var label = _editors.get(key)
	return (label as Label).text if label is Label else ""


## The field of the active selection slot ({} when none).
func active_field() -> Dictionary:
	for field in _fields:
		if field.key == active_selection_key:
			return field
	return {}


## Adds a pick (a body id, or a reference dictionary) to the active selection slot, or takes it
## out again when it is already there; single-pick slots swap it in and move on to the next
## empty slot, except for kinds the field "gather"s (Trim's sketch curves), which add up while
## the slot holds only those. Returns true when the slot took it.
func add_selection(item: Variant) -> bool:
	if active_selection_key == "":
		return false
	var field := active_field()
	var key := active_selection_key
	var list: Array = (values.get(key, []) as Array).duplicate()
	var at := -1
	for i in list.size():
		if _same(list[i], item):
			at = i
	var single := bool(field.get("single", false)) and not _gathers(field, list, item)
	if at >= 0:
		list.remove_at(at)
	elif single:
		list = [item]
	else:
		list.append(item)
	values[key] = list
	_update_selection_button(key)
	if single and at < 0:
		_advance_from(key)
	values_changed.emit(values)
	return true


## True when item is of a kind the field gathers and the slot holds only that kind so far.
static func _gathers(field: Dictionary, list: Array, item: Variant) -> bool:
	var kinds: Array = field.get("gather", [])
	if kinds.is_empty() or not item is Dictionary or not kinds.has(str(item.get("kind", ""))):
		return false
	for other in list:
		if not other is Dictionary or str(other.get("kind", "")) != str(item.get("kind", "")):
			return false
	return true


## Makes the slot after key that is shown and still empty the active one.
func _advance_from(key: String) -> void:
	var past := false
	for field in _fields:
		if field.key == key:
			past = true
			continue
		var row: Control = _row_nodes.get(field.key)
		if past and field.type == "selection" and row != null and row.visible and (values.get(field.key, []) as Array).is_empty():
			activate_selection(field.key)
			return


## Makes a selection slot the active one (viewport picks go to it).
func activate_selection(key: String) -> void:
	for field in _fields:
		if field.type == "selection":
			(_editors[field.key] as Button).set_pressed_no_signal(field.key == key)
	active_selection_key = key
	selection_field_activated.emit(key)


## The same pick (a face clicked again elsewhere is still that face).
static func _same(a: Variant, b: Variant) -> bool:
	if a is Dictionary and b is Dictionary:
		var x: Dictionary = (a as Dictionary).duplicate()
		var y: Dictionary = (b as Dictionary).duplicate()
		# (Where a pick was made and how the surface faced there don't make it another pick.)
		for extra in ["key", "at", "normal"]:
			x.erase(extra)
			y.erase(extra)
		return str(x) == str(y)
	return typeof(a) == typeof(b) and a == b


func _add_row(field: Dictionary) -> void:
	var key: String = field.key
	var row := HBoxContainer.new()
	# Info text and buttons use the whole row.
	if not str(field.type) in ["info", "button"]:
		var label := Label.new()
		label.text = str(field.get("label", key.capitalize()))
		label.custom_minimum_size = Vector2(92, 0)
		row.add_child(label)
	match str(field.type):
		"info":
			var text := Label.new()
			text.text = str(field.get("text", ""))
			text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			text.custom_minimum_size = Vector2(270, 0)
			text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			text.add_theme_font_size_override("font_size", 13)
			row.add_child(text)
			_editors[key] = text
		"button":
			var button := Button.new()
			button.text = str(field.get("label", key.capitalize()))
			button.tooltip_text = str(field.get("tooltip", ""))
			button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			button.pressed.connect(func() -> void: button_pressed.emit(key))
			row.add_child(button)
			_editors[key] = button
		"expression":
			var edit := LineEdit.new()
			edit.text = str(values.get(key, ""))
			edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			edit.text_changed.connect(func(text: String) -> void:
				values[key] = text
				_sync_slider(key)
				values_changed.emit(values))
			edit.text_submitted.connect(func(_text: String) -> void: accepted.emit())
			edit.gui_input.connect(_escape_input)
			_drag_number(edit, key, str(field.get("kind", UNITS.KIND_NUMBER)), {"whole": field.get("whole", false), "range": field.get("range")})
			row.add_child(edit)
			_editors[key] = edit
			var hint := Label.new()
			hint.custom_minimum_size = Vector2(70, 0)
			hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			hint.clip_text = true
			hint.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			row.add_child(hint)
			_hints[key] = hint
		"text":
			var line := LineEdit.new()
			line.text = str(values.get(key, ""))
			line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			line.text_changed.connect(func(text: String) -> void:
				values[key] = text
				values_changed.emit(values))
			line.text_submitted.connect(func(_text: String) -> void: accepted.emit())
			line.gui_input.connect(_escape_input)
			row.add_child(line)
			_editors[key] = line
		"enum":
			var option := OptionButton.new()
			option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			for i in (field.options as Array).size():
				option.add_item(field.options[i][1])
				option.set_item_metadata(i, field.options[i][0])
			_show_choice(option, field)
			if field.has("auto"):
				# A choice picked by hand, even the one the auto value shows, replaces the auto value
				# (item_selected doesn't come for the item already showing).
				option.get_popup().index_pressed.connect(func(index: int) -> void:
					if values.get(key) == field.auto and index >= 0 and index < option.item_count:
						values[key] = option.get_item_metadata(index)
						_update_visibility()
						values_changed.emit(values))
			option.item_selected.connect(func(index: int) -> void:
				if field.has("auto") and values.get(key) == option.get_item_metadata(index):
					return
				values[key] = option.get_item_metadata(index)
				# An offered choice made: the choice of a value not offered goes.
				var extra := option.get_item_index(UNOFFERED)
				if extra >= 0 and extra != index:
					option.remove_item(extra)
				_update_visibility()
				values_changed.emit(values))
			row.add_child(option)
			_editors[key] = option
		"point":
			var lines: Array[LineEdit] = []
			var p := POINT64.exact(values, key)
			for axis in 3:
				var edit := LineEdit.new()
				edit.custom_minimum_size = Vector2(58, 0)
				edit.tooltip_text = ["X", "Y", "Z"][axis] + " (" + document_units + ")"
				edit.text = UNITS.format_value(p[axis], UNITS.KIND_LENGTH, document_units).split(" ")[0]
				edit.text_submitted.connect(func(_text: String) -> void: accepted.emit())
				edit.text_changed.connect(func(text: String) -> void:
					var r := UNITS.evaluate(text, UNITS.KIND_LENGTH, document_units, {})
					if r.ok:
						# (The typed double is kept beside the float32 Vector3: core/point64.gd.)
						POINT64.set_axis(values, key, axis, float(r.value))
						values_changed.emit(values))
				edit.gui_input.connect(_escape_input)
				_drag_number(edit, key, UNITS.KIND_LENGTH, {"bare": true})
				row.add_child(edit)
				lines.append(edit)
			_editors[key] = lines
		"selection":
			var button := Button.new()
			button.toggle_mode = true
			button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			button.toggled.connect(func(on: bool) -> void:
				# A click on another slot makes it the active one (and the one before it is no
				# longer shown pressed). A click on the active slot leaves it active: there is
				# always one slot the view's picks go to, and turning it off made the first slot
				# the active one behind the user's back.
				if on:
					activate_selection(key)
				elif active_selection_key == key or active_selection_key == "":
					button.set_pressed_no_signal(true)
					active_selection_key = key)
			row.add_child(button)
			var clear := Button.new()
			clear.text = "×"
			clear.tooltip_text = "Clear"
			clear.pressed.connect(func() -> void:
				values[key] = []
				_update_selection_button(key)
				values_changed.emit(values))
			row.add_child(clear)
			_editors[key] = button
			_update_selection_button(key)
		"bool":
			var check := CheckBox.new()
			check.button_pressed = bool(values.get(key, false))
			check.toggled.connect(func(on: bool) -> void:
				values[key] = on
				# Rows that depend on it (visible_if) show or hide at once, as enums do.
				_update_visibility()
				values_changed.emit(values))
			row.add_child(check)
			_editors[key] = check
	var holder := _pinned if bool(field.get("pinned", false)) else _rows
	holder.add_child(row)
	_row_nodes[key] = row
	if str(field.type) == "expression" and field.get("slider") is Dictionary:
		holder.add_child(_slider_row(field))


# --- Sliders -------------------------------------------------------------------------------------

## The slider row under an expression field: a gap the width of the labels, then the slider.
func _slider_row(field: Dictionary) -> HBoxContainer:
	var key: String = field.key
	var row := HBoxContainer.new()
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(92, 0)
	row.add_child(gap)
	var bar := HSlider.new()
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bar.tooltip_text = str((field.slider as Dictionary).get("tooltip", ""))
	row.add_child(bar)
	_sliders[key] = bar
	_slider_rows[key] = row
	_apply_slider_range(key)
	bar.value_changed.connect(func(shown: float) -> void: _slider_moved(key, shown))
	bar.drag_started.connect(func() -> void:
		dragged_slider = key
		slider_drag.emit(key, true))
	bar.drag_ended.connect(func(_changed: bool) -> void:
		if dragged_slider == key:
			dragged_slider = ""
		slider_drag.emit(key, false))
	return row


## Gives a field's slider another span (base units; a command whose span depends on another row).
## It holds until the panel is set up again; the field itself is left as it was.
func set_slider_range(key: String, low: float, high: float) -> void:
	_slider_spans[key] = PackedFloat64Array([low, high])
	_apply_slider_range(key)


## The slider of a field (null when it has none), for tests and the workspace.
func slider(key: String) -> HSlider:
	return _sliders.get(key) as HSlider


func _field(key: String) -> Dictionary:
	for field in _fields:
		if field.key == key:
			return field
	return {}


## Sets a slider's span and step from its field (in display units: degrees, the document's
## length unit), then puts it at the field's value. The ends go out to whole steps, so every
## place on the slider is a whole number of steps (a limit between two steps is still held by the
## command). A span that is empty or not finite turns the slider off.
func _apply_slider_range(key: String) -> void:
	var slider_node := _sliders.get(key) as HSlider
	var field := _field(key)
	if slider_node == null or not (field.get("slider") is Dictionary):
		return
	var kind := str(field.get("kind", UNITS.KIND_LENGTH))
	# (Doubles: a Vector2 is float32, and a 90° limit would come out 90.0000025°.)
	var span: PackedFloat64Array = _slider_spans.get(key, PackedFloat64Array([float(field.slider.get("min", 0.0)), float(field.slider.get("max", 0.0))]))
	var low := _to_display(span[0], kind)
	var high := _to_display(span[1], kind)
	var usable := is_finite(low) and is_finite(high) and high > low
	slider_node.editable = usable
	if not usable:
		slider_node.set_block_signals(true)
		slider_node.min_value = 0.0
		slider_node.max_value = 1.0
		slider_node.set_block_signals(false)
		return
	var step := pow(10.0, floor(log((high - low) / SLIDER_STEPS) / log(10.0)))
	slider_node.set_block_signals(true)
	slider_node.step = step
	# (A hair of slack keeps an end that is already a whole step from moving a step out.)
	slider_node.min_value = floor(low / step + 1e-9) * step
	slider_node.max_value = ceil(high / step - 1e-9) * step
	slider_node.set_block_signals(false)
	_sync_slider(key)


## Puts a slider where its field's text says (without values_changed); text that does not
## evaluate to a plain value leaves it where it is.
func _sync_slider(key: String) -> void:
	var slider_node := _sliders.get(key) as HSlider
	if slider_node == null:
		return
	var kind := str(_field(key).get("kind", UNITS.KIND_LENGTH))
	var r := UNITS.evaluate(str(values.get(key, "")), kind, document_units, {})
	if r.ok and is_finite(float(r.value)):
		slider_node.set_value_no_signal(_to_display(float(r.value), kind))


## The slider moved: its value goes into the field as text (as if typed).
func _slider_moved(key: String, shown: float) -> void:
	var slider_node := _sliders.get(key) as HSlider
	var kind := str(_field(key).get("kind", UNITS.KIND_LENGTH))
	var decimals := maxi(0, int(ceil(-log(slider_node.step) / log(10.0) - 1e-9))) if slider_node != null and slider_node.step > 0.0 else 4
	var text := UNITS.format_value(_from_display(shown, kind), kind, document_units, decimals)
	values[key] = text
	var edit := _editors.get(key) as LineEdit
	if edit != null:
		_show_text(edit, text)
	values_changed.emit(values)


## A base-unit value in display units (degrees; the document's length unit).
func _to_display(value: float, kind: String) -> float:
	if kind == UNITS.KIND_ANGLE:
		return rad_to_deg(value)
	if kind == UNITS.KIND_LENGTH:
		return value / float(UNITS.LENGTH_UNITS.get(UNITS.display_unit(kind, document_units), 1.0))
	return value


func _from_display(shown: float, kind: String) -> float:
	if kind == UNITS.KIND_ANGLE:
		return deg_to_rad(shown)
	if kind == UNITS.KIND_LENGTH:
		return shown * float(UNITS.LENGTH_UNITS.get(UNITS.display_unit(kind, document_units), 1.0))
	return shown


## Selects the choice holding value (of the same type: a number never matches a text choice). A
## value the field doesn't offer (a document's from before) gets a choice of its own showing it,
## so the panel never shows the first choice instead and has OK write back a value it didn't show;
## no value shows the field's default (or its first choice). There is one such choice at most,
## after the offered ones (id UNOFFERED), and none while the value is an offered one. Returns the
## value shown.
## Shows a choice field's value. A field with "auto" (tools/command.gd operation_fields) whose
## value is that auto value keeps it, and shows the choice it stands for now (show_auto, or the
## field's "auto_shows" before the first build).
func _show_choice(option: OptionButton, field: Dictionary) -> void:
	var key: String = field.key
	var value: Variant = values.get(key)
	if field.has("auto") and (value == field.auto or (value == null and field.get("default") == field.auto)):
		values[key] = field.auto
		_select_value(option, _auto_shown.get(key, field.get("auto_shows")))
		return
	values[key] = _select_value(option, value, field.get("default"))


## What a field with "auto" shows while its value is the auto value: the choice it stands for now
## (an automatic operation's Join, Cut or New Body after a build). The value itself stays auto.
func show_auto(key: String, shown: Variant) -> void:
	if shown == null or str(shown) == "" or _auto_shown.get(key) == shown:
		return
	_auto_shown[key] = shown
	for field in _fields:
		if field.key == key and field.has("auto") and _editors.get(key) is OptionButton:
			_show_choice(_editors[key], field)


## The choice a field shows (its value, or for an auto value the choice it stands for), or null.
func shown_choice(key: String) -> Variant:
	var option := _editors.get(key) as OptionButton
	if option == null or option.selected < 0:
		return null
	return option.get_item_metadata(option.selected)


static func _select_value(option: OptionButton, value: Variant, fallback: Variant = null) -> Variant:
	var wanted: Variant = fallback if value == null else value
	var numbers := [TYPE_INT, TYPE_FLOAT]
	var extra := option.get_item_index(UNOFFERED)
	for i in option.item_count:
		var held: Variant = option.get_item_metadata(i)
		if i != extra and ((typeof(held) == typeof(wanted) and held == wanted) or (typeof(held) in numbers and typeof(wanted) in numbers and float(held) == float(wanted))):
			if extra >= 0:
				option.remove_item(extra)
			option.select(i)
			return held
	if value == null:
		if extra >= 0:
			option.remove_item(extra)
		if option.item_count > 0:
			option.select(0)
		return option.get_item_metadata(0) if option.item_count > 0 else null
	if extra < 0:
		option.add_item("", UNOFFERED)
		extra = option.item_count - 1
	option.set_item_text(extra, "%s (not offered)" % str(value))
	option.set_item_metadata(extra, value)
	option.select(extra)
	return value


func _update_selection_button(key: String) -> void:
	var button: Button = _editors.get(key)
	if button == null:
		return
	var list: Array = values.get(key, [])
	if list.size() == 1 and describer.is_valid():
		button.text = str(describer.call(list[0]))
	else:
		button.text = "%d selected" % list.size() if list.size() > 0 else "Select"


## Hides rows whose visible_if condition is not met (e.g. Bodies only for Join/Cut/Intersect).
func _update_visibility() -> void:
	for field in _fields:
		var row: Control = _row_nodes.get(field.key)
		if row == null:
			continue
		var condition: Dictionary = field.get("visible_if", {})
		var shown := true
		for other in condition:
			shown = shown and (condition[other] as Array).has(values.get(other))
		row.visible = shown
		if _slider_rows.has(field.key):
			(_slider_rows[field.key] as Control).visible = shown
		# A selection slot becomes the active one when it appears.
		if shown and field.type == "selection" and active_selection_key == "":
			active_selection_key = field.key
			(_editors[field.key] as Button).set_pressed_no_signal(true)
			selection_field_activated.emit(field.key)
		elif not shown and active_selection_key == field.key:
			active_selection_key = ""
			(_editors[field.key] as Button).set_pressed_no_signal(false)
			selection_field_activated.emit("")


func _escape_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key != null and key.pressed and key.keycode == KEY_ESCAPE:
		cancelled.emit()
