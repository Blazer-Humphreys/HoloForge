@tool
extends RefCounted
## Drag to change a number field, as Godot's Inspector does: press on the field and drag right to
## raise its value, left to lower it. A press without a drag still places the caret for typing.
## Shift drags in fine steps (a tenth), Ctrl in coarse ones (ten times).
##
## attach() keeps the helper on the LineEdit (as meta), so callers need not hold it. The value is
## read from the field's text at the press (an expression that doesn't evaluate isn't dragged) and
## written back as a plain number in the document's units, as if typed: `changed` gets the text.
##
## Steps per pixel: lengths and plain numbers move by a hundredth of the power of ten at or below
## the value at the press (10 mm moves 0.1 mm a pixel, 2000 mm 10 mm), at least `MIN_STEPS`;
## angles by half a degree; "whole" numbers by one every WHOLE_PX pixels.

const UNITS := preload("res://addons/holo_forge/core/units.gd")

## How far (pixels) the mouse must move sideways with the button down before the press is a drag.
const DRAG_PX := 4.0
const ANGLE_STEP := 0.5
const WHOLE_PX := 8.0
## The smallest step per pixel (display units) by kind.
const MIN_STEPS := {UNITS.KIND_LENGTH: 0.01, UNITS.KIND_NUMBER: 0.001}
const META := "holo_forge_number_drag"

var edit: LineEdit
var kind := UNITS.KIND_NUMBER
## () -> String: the document's units now.
var units: Callable
## (text: String) -> void: the field's new text after a drag step.
var changed: Callable
## (active: bool) -> void, optional: a drag started (true) or ended (false).
var dragging_changed: Callable
## {"whole": bool, "range": [low, high] (numbers only; a bound that isn't a number is ignored),
## "bare": bool (the number is written without its unit)}.
var options := {}

var _press: Variant = null
var _dragging := false
## The value as the drag has it (display units), and its step per pixel.
var _value := 0.0
var _step := 0.0
var _decimals := 4
var _cursor := Control.CURSOR_IBEAM


## Makes edit draggable. Returns the helper (also kept as edit's meta).
static func attach(p_edit: LineEdit, p_kind: String, p_units: Callable, p_changed: Callable, p_options := {}) -> RefCounted:
	var helper: RefCounted = load("res://addons/holo_forge/ui/number_drag.gd").new()
	helper.edit = p_edit
	helper.kind = p_kind
	helper.units = p_units
	helper.changed = p_changed
	helper.options = p_options
	p_edit.gui_input.connect(helper._on_gui_input)
	p_edit.set_meta(META, helper)
	if p_edit.tooltip_text == "":
		p_edit.tooltip_text = "Drag left or right to change the value (Shift: fine, Ctrl: coarse), or click to type."
	return helper


## The helper attached to a field (null for none).
static func of(p_edit: LineEdit) -> RefCounted:
	return p_edit.get_meta(META) if p_edit != null and p_edit.has_meta(META) else null


func is_dragging() -> bool:
	return _dragging


func _on_gui_input(event: InputEvent) -> void:
	if not edit.editable:
		return
	var button := event as InputEventMouseButton
	if button != null and button.button_index == MOUSE_BUTTON_LEFT:
		if button.pressed:
			_press = null
			if not button.double_click:
				_press = button.position
		else:
			_press = null
			if _dragging:
				_end_drag()
		return
	var motion := event as InputEventMouseMotion
	if motion == null or _press == null or not (motion.button_mask & MOUSE_BUTTON_MASK_LEFT):
		return
	if not _dragging:
		if absf(motion.position.x - (_press as Vector2).x) < DRAG_PX:
			return
		if not _begin_drag():
			_press = null
			return
		# The sideways travel so far counts.
		_step_by(motion.position.x - (_press as Vector2).x, motion)
		edit.accept_event()
		return
	_step_by(motion.relative.x, motion)
	edit.accept_event()


func _begin_drag() -> bool:
	var r := UNITS.evaluate(edit.text, kind, _units(), {})
	if not r.ok or not is_finite(float(r.value)):
		return false
	_value = _to_display(float(r.value))
	_step = _step_for(_value)
	_decimals = _decimals_for(_step * 0.1)
	_dragging = true
	_cursor = edit.mouse_default_cursor_shape
	edit.mouse_default_cursor_shape = Control.CURSOR_HSIZE
	edit.deselect()
	if dragging_changed.is_valid():
		dragging_changed.call(true)
	return true


func _end_drag() -> void:
	_dragging = false
	edit.mouse_default_cursor_shape = _cursor
	edit.deselect()
	edit.caret_column = edit.text.length()
	if dragging_changed.is_valid():
		dragging_changed.call(false)


func _step_by(pixels: float, event: InputEventWithModifiers) -> void:
	if pixels == 0.0:
		return
	var factor := 1.0
	if event.shift_pressed:
		factor = 0.1
	elif event.ctrl_pressed or event.meta_pressed:
		factor = 10.0
	var step := _step * factor
	_value += pixels * step
	var shown := _value
	if bool(options.get("whole", false)):
		shown = roundf(_value)
	else:
		var rounding := step if step > 0.0 else 1e-9
		shown = snappedf(_value, rounding * 0.1)
	var span: Variant = options.get("range")
	if kind == UNITS.KIND_NUMBER and span is Array and (span as Array).size() == 2:
		if (span[0] is float or span[0] is int):
			shown = maxf(shown, float(span[0]))
		if (span[1] is float or span[1] is int):
			shown = minf(shown, float(span[1]))
	var decimals := 0 if bool(options.get("whole", false)) else _decimals_for(step * 0.1)
	var text := UNITS.format_value(_from_display(shown), kind, _units(), decimals)
	if bool(options.get("bare", false)):
		text = text.split(" ")[0]
	if text == edit.text:
		return
	edit.text = text
	edit.caret_column = text.length()
	if changed.is_valid():
		changed.call(text)


## Display units per pixel for a drag that starts at value.
func _step_for(value: float) -> float:
	if kind == UNITS.KIND_ANGLE:
		return ANGLE_STEP
	if bool(options.get("whole", false)):
		return 1.0 / WHOLE_PX
	var magnitude := absf(value)
	var step := pow(10.0, floor(log(magnitude) / log(10.0))) / 100.0 if magnitude > 0.0 else 0.0
	return maxf(step, float(MIN_STEPS.get(kind, 0.001)))


static func _decimals_for(step: float) -> int:
	if step <= 0.0 or step >= 1.0:
		return 0
	return clampi(int(ceil(-log(step) / log(10.0) - 1e-9)), 0, 6)


func _units() -> String:
	return str(units.call()) if units.is_valid() else "mm"


func _to_display(value: float) -> float:
	if kind == UNITS.KIND_ANGLE:
		return rad_to_deg(value)
	if kind == UNITS.KIND_LENGTH:
		return value / float(UNITS.LENGTH_UNITS.get(UNITS.display_unit(kind, _units()), 1.0))
	return value


func _from_display(shown: float) -> float:
	if kind == UNITS.KIND_ANGLE:
		return deg_to_rad(shown)
	if kind == UNITS.KIND_LENGTH:
		return shown * float(UNITS.LENGTH_UNITS.get(UNITS.display_unit(kind, _units()), 1.0))
	return shown
