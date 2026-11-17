@tool
extends PanelContainer
## The Forge timeline: one chip per feature in order, a marker you drag to roll the design back,
## and playback buttons. Double-click a chip to edit it; right-click for Rename, Suppress,
## Roll Back Here, Group, Find in Browser and Delete. Failed features show a warning.

signal rollback_changed(count: int)
signal feature_edit_requested(feature_id: String)
signal feature_suppress_toggled(feature_id: String)
signal feature_delete_requested(feature_id: String)
signal feature_rename_requested(feature_id: String)
signal feature_group_requested(feature_id: String)
signal feature_ungroup_requested(feature_id: String)
signal feature_find_requested(feature_id: String)

const ICONS := {
	"box": "BoxMesh", "cylinder": "CylinderMesh", "sphere": "SphereMesh", "sketch": "Path2D", "torus": "TorusMesh",
	"coil": "Curve3D", "pipe": "Path3D", "extrude": "CSGPolygon3D", "revolve": "CSGTorus3D", "sweep": "Path3D",
	"loft": "CSGMesh3D", "rib": "CSGBox3D", "web": "CSGBox3D", "emboss": "Label3D", "hole": "CSGCylinder3D",
	"thread": "Curve3D", "rect_pattern": "GridMap", "circ_pattern": "RotateRight", "path_pattern": "Path3D",
	"mirror": "MirrorX", "fillet": "CSGSphere3D", "chamfer": "PrismMesh", "shell": "CSGCombiner3D", "draft": "PrismMesh",
	"scale": "ToolScale", "combine": "CSGCombiner3D", "offset_face": "ArrowUp", "replace_face": "ArrowUp",
	"split_face": "CSGBox3D", "split_body": "CSGBox3D", "silhouette_split": "CSGBox3D", "move": "ToolMove",
	"align": "ToolMove", "remove": "Remove", "thicken": "CSGBox3D", "boundary_fill": "CSGCombiner3D",
	"base_feature": "MeshInstance3D", "plane": "PlaneMesh", "axis": "Curve3D", "point": "Marker3D",
	"import": "Load", "mesh_import": "ArrayMesh", "derive": "PackedScene", "fastener": "PinJoint3D",
	"surface": "PlaneMesh", "surface:extrude": "CSGPolygon3D", "surface:revolve": "CSGTorus3D", "surface:sweep": "Path3D",
	"surface:loft": "CSGMesh3D", "surface:coil": "Curve3D", "surface:offset": "ArrowUp", "surface:trim": "Remove",
	"surface:untrim": "Reload", "surface:extend": "ArrowRight", "surface:stitch": "CSGCombiner3D",
	"surface:unstitch": "Unlinked", "surface:merge": "CSGCombiner3D", "surface:reverse_normal": "MirrorY",
	"form": "SoftBody3D",
	# Mesh features ("mesh:<method>"): the tool's own icon file under icons/tools/ ("svg:<file>").
	"mesh": "ArrayMesh", "mesh:tessellate": "svg:tessellate", "mesh:section_sketch": "svg:create_mesh_section_sketch",
	"mesh:close_holes": "svg:close_holes", "mesh:stitch_remove": "svg:stitch_and_remove", "mesh:wrap": "svg:wrap",
	"mesh:rebuild": "svg:rebuild", "mesh:generate_groups": "svg:generate_face_groups",
	"mesh:combine_groups": "svg:combine_face_groups", "mesh:create_group": "svg:create_face_group",
	"mesh:direct_edit": "svg:direct_edit", "mesh:remesh": "svg:remesh", "mesh:reduce": "svg:reduce",
	"mesh:plane_cut": "svg:plane_cut", "mesh:shell": "svg:mesh/shell", "mesh:combine": "svg:mesh/combine",
	"mesh:smooth": "svg:smooth", "mesh:reverse_normal": "svg:reverse_normal", "mesh:erase_fill": "svg:erase_and_fill",
	"mesh:align": "svg:mesh_align", "mesh:texture_extrude": "svg:texture_extrude", "mesh:separate": "svg:separate",
	"mesh:move": "svg:move_copy", "mesh:scale": "svg:scale_mesh", "mesh:convert_faceted": "svg:convert_mesh_faceted",
	"mesh:convert_prismatic": "svg:convert_mesh_prismatic", "mesh:convert_organic": "svg:convert_mesh_organic",
}
## Where the "svg:" icons live, and how big a chip's icon is at 100% editor scale.
const ICON_DIR := "res://addons/holo_forge/icons/tools/"
const SVG_ICON_SIZE := 16.0
const TOOLBAR := preload("res://addons/holo_forge/ui/toolbar.gd")
## A feature left out of a Mesh tool's preview (the rebuild stopped before it): its chip's tooltip
## line, and how much of the chip shows (a rolled-back chip is fainter still, 0.35).
const WAITING := "Not shown during the preview of %s: worked out again on OK or Cancel."
const WAITING_ALPHA := 0.65
const ROLLED_ALPHA := 0.35
## Features that bring in a file show its name on their chip.
const FILE_FEATURES := ["import", "mesh_import", "derive"]

var _chips_box: HBoxContainer
var _scroll: ScrollContainer
var _marker: ColorRect
var _context: PopupMenu
var _context_feature := ""
var _feature_count := 0
var _active := 0
var _dragging_marker := false
## While the marker is dragged: the gap it shows (how many chips are left of it). The design rolls
## back only on release; till then the marker and the chips' fade only preview it.
var _preview := -1
## Counts refresh() calls (a release that changed nothing puts the marker back itself).
var _refreshes := 0
var _chips: Array[Control] = []
## What the chips' editor icons are multiplied by (see apply_theme).
var _icon_tint := Color.WHITE


func _init() -> void:
	custom_minimum_size = Vector2(0, 44)
	var row := HBoxContainer.new()
	add_child(row)
	for spec in [["|◀", "Go to the start", func() -> void: _set_active(0)], ["◀", "Step back", func() -> void: _set_active(_active - 1)],
			["▶", "Step forward", func() -> void: _set_active(_active + 1)], ["▶|", "Go to the end", func() -> void: _set_active(_feature_count)]]:
		var button := Button.new()
		button.text = spec[0]
		button.tooltip_text = spec[1]
		button.flat = true
		button.pressed.connect(spec[2])
		row.add_child(button)
	row.add_child(VSeparator.new())
	_scroll = ScrollContainer.new()
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	row.add_child(_scroll)
	_chips_box = HBoxContainer.new()
	_chips_box.add_theme_constant_override("separation", 3)
	_scroll.add_child(_chips_box)
	_marker = ColorRect.new()
	_marker.color = Color(0.25, 0.6, 1.0)
	_marker.custom_minimum_size = Vector2(6, 30)
	_marker.mouse_default_cursor_shape = Control.CURSOR_HSPLIT
	_marker.tooltip_text = "Drag to roll the design back"
	_marker.gui_input.connect(_marker_input)
	_context = PopupMenu.new()
	_context.id_pressed.connect(_on_context)
	add_child(_context)


## The rollback marker is out of the tree until refresh() places it (a project with no part never
## does): it goes with the timeline, so it is not left over when the editor closes.
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and is_instance_valid(_marker) and _marker.get_parent() == null:
		_marker.free()


## The marker in the palette's colour (forge_theme.gd timeline_marker), and the chips' editor icons
## multiplied by icon_tint so they read on the palette's background.
func apply_theme(colors: Dictionary, icon_tint: Color) -> void:
	_marker.color = colors.get("timeline_marker", _marker.color)
	_icon_tint = icon_tint
	for chip in _chips:
		_tint_chip(chip as Button)


## The marker's colour now (for tests).
func marker_color() -> Color:
	return _marker.color


func _tint_chip(chip: Button) -> void:
	for state in ["icon_normal_color", "icon_hover_color", "icon_pressed_color", "icon_hover_pressed_color", "icon_focus_color"]:
		chip.add_theme_color_override(state, _icon_tint)


## text broken into lines of at most width characters at its spaces (a tooltip does not wrap, and
## a long warning would run off the screen).
static func wrapped(text: String, width := 78) -> String:
	var lines := PackedStringArray()
	for paragraph in text.split("\n"):
		var line := ""
		for word in paragraph.split(" "):
			if line != "" and line.length() + 1 + word.length() > width:
				lines.append(line)
				line = word
			else:
				line = word if line == "" else line + " " + word
		lines.append(line)
	return "\n".join(lines)


## features: the document's features; active: how many are rolled forward; errors: id -> text;
## warnings: id -> text (a feature that built with a warning says it in its tooltip).
## waiting: {"ids": feature ids, "label"}: features a Mesh tool's preview of the feature "label"
## left out (the rebuild stopped before them). They have not failed: their chips are only dimmed
## a little and say so (meta "waiting").
func refresh(features: Array, active: int, errors: Dictionary, warnings: Dictionary = {}, waiting: Dictionary = {}) -> void:
	if _marker.get_parent() != null:
		_marker.get_parent().remove_child(_marker)
	for child in _chips_box.get_children():
		child.queue_free()
	_chips.clear()
	_refreshes += 1
	_preview = -1
	_feature_count = features.size()
	_active = active
	var last_group := ""
	for i in features.size():
		var feature: Resource = features[i]
		if i == active:
			_chips_box.add_child(_marker)
		if feature.group != "" and feature.group != last_group:
			var group_label := Label.new()
			group_label.text = "[%s]" % feature.group
			group_label.modulate = Color(0.75, 0.85, 1.0)
			_chips_box.add_child(group_label)
		last_group = feature.group
		var chip := Button.new()
		chip.text = feature.label
		chip.icon = _icon(ICONS.get("%s:%s" % [feature.type, feature.options.get("method", "")], ICONS.get(feature.type, "Node3D")))
		chip.focus_mode = Control.FOCUS_NONE
		chip.set_meta("feature_id", feature.id)
		chip.set_meta("index", i)
		var tip := "%s (%s)" % [feature.label, String(feature.type).capitalize()]
		var file := file_of(feature)
		if file != "":
			tip += "\nFile: " + file
			if feature.type in FILE_FEATURES:
				chip.text = "%s (%s)" % [feature.label, file.get_file()]
		for key in feature.inputs:
			tip += "\n%s = %s   [%s]" % [String(key).capitalize(), feature.expression(key), feature.inputs[key].get("name", "")]
		if feature.suppressed:
			chip.text = "(%s)" % feature.label
			chip.modulate = Color(1, 1, 1, 0.45)
			tip += "\nSuppressed"
		# How much of the chip shows rolled forward (a marker drag's preview fades it to ROLLED_ALPHA).
		chip.set_meta("shown_alpha", chip.modulate.a)
		if i >= active:
			chip.modulate = Color(chip.modulate, ROLLED_ALPHA)
		if errors.has(feature.id):
			chip.icon = _icon("StatusWarning")
			chip.modulate = Color(1.0, 0.55, 0.45, chip.modulate.a)
			tip += "\n⚠ " + wrapped(str(errors[feature.id]))
		elif str(warnings.get(feature.id, "")) != "":
			tip += "\nNote: " + wrapped(str(warnings[feature.id]))
			chip.set_meta("warning", str(warnings[feature.id]))
		if i < active and not errors.has(feature.id) and (waiting.get("ids", []) as Array).has(str(feature.id)):
			chip.modulate = Color(chip.modulate, WAITING_ALPHA)
			chip.set_meta("waiting", true)
			chip.set_meta("shown_alpha", WAITING_ALPHA)
			tip += "\n" + wrapped(WAITING % str(waiting.get("label", "the feature")))
		chip.tooltip_text = tip
		_tint_chip(chip)
		chip.gui_input.connect(_chip_input.bind(chip))
		_chips_box.add_child(chip)
		_chips.append(chip)
	if active >= features.size():
		_chips_box.add_child(_marker)


func chip_count() -> int:
	return _chips.size()


## The chips' texts in order (for tests).
func chip_texts() -> PackedStringArray:
	var texts := PackedStringArray()
	for chip in _chips:
		texts.append((chip as Button).text)
	return texts


## The file a feature was inserted from ("" for none): import, mesh and derive paths, and the
## drawing an imported sketch came from.
static func file_of(feature: Resource) -> String:
	return str(feature.options.get("path", feature.options.get("source_file", ""))) if feature.type in FILE_FEATURES or feature.type == "sketch" else ""


func _set_active(count: int) -> void:
	count = clampi(count, 0, _feature_count)
	if count != _active:
		rollback_changed.emit(count)


func _chip_input(event: InputEvent, chip: Button) -> void:
	var button := event as InputEventMouseButton
	if button == null or not button.pressed:
		return
	var feature_id: String = chip.get_meta("feature_id")
	if button.button_index == MOUSE_BUTTON_LEFT and button.double_click:
		feature_edit_requested.emit(feature_id)
		chip.accept_event()
	elif button.button_index == MOUSE_BUTTON_RIGHT:
		_context_feature = feature_id
		_context.clear()
		_context.add_item("Edit Feature", 0)
		_context.add_item("Rename", 1)
		_context.add_item("Suppress / Unsuppress", 2)
		_context.add_item("Roll Back Here", 3)
		_context.add_separator()
		_context.add_item("Move to Group...", 4)
		_context.add_item("Remove from Group", 5)
		_context.add_item("Find in Browser", 6)
		_context.add_separator()
		_context.add_item("Delete", 7)
		_context.set_meta("index", chip.get_meta("index"))
		_context.position = Vector2i(chip.get_screen_position() + button.position)
		_context.popup()
		chip.accept_event()


func _on_context(id: int) -> void:
	match id:
		0:
			feature_edit_requested.emit(_context_feature)
		1:
			feature_rename_requested.emit(_context_feature)
		2:
			feature_suppress_toggled.emit(_context_feature)
		3:
			rollback_changed.emit(int(_context.get_meta("index", 0)) + 1)
		4:
			feature_group_requested.emit(_context_feature)
		5:
			feature_ungroup_requested.emit(_context_feature)
		6:
			feature_find_requested.emit(_context_feature)
		7:
			feature_delete_requested.emit(_context_feature)


## The marker drag: while the button is held the marker follows the mouse from gap to gap and the
## chips past it fade (a preview: nothing is rebuilt); the release rolls the design to that gap as
## one step. Positions are the event's own (local to the marker, as it stood when the event came),
## not the window's mouse: the same point for a mouse, and right for a pen or an event a test pushes.
func _marker_input(event: InputEvent) -> void:
	var button := event as InputEventMouseButton
	if button != null and button.button_index == MOUSE_BUTTON_LEFT:
		_dragging_marker = button.pressed
		if button.pressed:
			_preview = _active
		else:
			var target := _index_at(_marker.get_global_rect().position.x + button.position.x)
			var refreshes := _refreshes
			_set_active(target)
			if _refreshes == refreshes:
				# Nothing was rebuilt (the same gap, or the change was refused): back to how it is.
				_show_marker_at(_active)
			_preview = -1
		_marker.accept_event()
	elif event is InputEventMouseMotion and _dragging_marker:
		_show_marker_at(_index_at(_marker.get_global_rect().position.x + (event as InputEventMouseMotion).position.x))
		_marker.accept_event()


## Puts the marker in the gap after count chips and fades the chips past it, as refresh() would
## show that rollback (for the drag's preview; the document is not touched).
func _show_marker_at(count: int) -> void:
	count = clampi(count, 0, _chips.size())
	if _dragging_marker:
		_preview = count
	if _marker.get_parent() != _chips_box:
		return
	# Before the chip's group label, as refresh() places it, or after the last chip.
	var before: Control = null
	if count < _chips.size():
		before = _chips[count]
		var at := before.get_index()
		if at > 0:
			var previous := _chips_box.get_child(at - 1)
			if previous is Label:
				before = previous
	if before == null:
		_chips_box.move_child(_marker, -1)
	elif before != _marker:
		var to := before.get_index()
		_chips_box.move_child(_marker, to - 1 if _marker.get_index() < to else to)
	for i in _chips.size():
		var chip := _chips[i]
		chip.modulate.a = ROLLED_ALPHA if i >= count else float(chip.get_meta("shown_alpha", 1.0))


## While the marker is dragged, the gap it shows (how many chips are left of it); -1 otherwise.
func marker_preview() -> int:
	return _preview


## How many chips lie left of a screen x position.
func _index_at(global_x: float) -> int:
	var count := 0
	for chip in _chips:
		var rect := chip.get_global_rect()
		if global_x > rect.position.x + rect.size.x * 0.5:
			count += 1
	return count


## An editor icon by name, or ("svg:<file>") a Holo tool icon drawn in the ink of the editor's
## theme (light on a dark editor), so the chips' tint treats it as it does the editor icons.
static func _icon(name: String) -> Texture2D:
	if name.begins_with("svg:"):
		var scale := EditorInterface.get_editor_scale() if Engine.is_editor_hint() else 1.0
		return TOOLBAR.file_icon(ICON_DIR + name.trim_prefix("svg:") + ".svg", SVG_ICON_SIZE * scale, TOOLBAR._theme_ink())
	if not Engine.is_editor_hint():
		return null
	var theme := EditorInterface.get_editor_theme()
	return theme.get_icon(name, "EditorIcons") if theme != null and theme.has_icon(name, "EditorIcons") else null
