@tool
extends PanelContainer
## The Appearance panel (A): the appearance library (built-in finishes, the project's texture
## sets and any Material resource dropped on the list or added from a file), applied to the
## faces, bodies or components selected in the view, and the texture mapping (type, scale,
## rotation, offset, and for projections their origin and axis) of the selection's own
## appearances. Every change is one undo step. Texture Map Controls opens the same mapping with
## handles in the view (tools/texture_map_command.gd).
## Manage Materials opens it with the design's materials listed too: how often each is used,
## and swapping one for another everywhere.

const MATERIAL_LIBRARY := preload("res://addons/holo_forge/core/material_library.gd")
const APPEARANCE := preload("res://addons/holo_forge/core/appearance.gd")
const UNITS := preload("res://addons/holo_forge/core/units.gd")
const NUMBER_DRAG := preload("res://addons/holo_forge/ui/number_drag.gd")
const TEXTURE_MAP_COMMAND := "res://addons/holo_forge/tools/texture_map_command.gd"

const ICON_SIZE := 32
const MATERIAL_EXTENSIONS := ["tres", "res", "material"]

## The Forge workspace (ui/forge_workspace.gd).
var workspace: Object
## True when opened as Manage Materials.
var manage := false

var _title: Label
var _target_label: Label
var _apply_to: OptionButton
var _list: ItemList
var _ids := PackedStringArray()
## Material resources added this session (res:// paths).
var _custom := PackedStringArray()
var _type: OptionButton
var _scale: Array[LineEdit] = []
var _offset: Array[LineEdit] = []
var _rotation: LineEdit
## A projection's origin (document units) and axis (x, y, z; all 0 is automatic).
var _origin: Array[LineEdit] = []
var _axis: Array[LineEdit] = []
## The Origin and Axis labels and rows, hidden for automatic mapping.
var _placed_rows: Array[Control] = []
var _mapping_hint: Label
var _manage_box: VBoxContainer
var _used_list: ItemList
var _used_ids := PackedStringArray()
var _file_dialog: Node
## The mapping the editors show, to tell which ones changed.
var _shown_mapping := {}
## Appearance id -> list icon (previews load once).
var _icons := {}


func _init(p_workspace: Object = null) -> void:
	workspace = p_workspace
	custom_minimum_size = Vector2(250, 0)
	position = Vector2(10, 64)
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

	var header := HBoxContainer.new()
	_title = Label.new()
	_title.text = "APPEARANCE"
	_title.add_theme_font_size_override("font_size", 15)
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(_title)
	var close := Button.new()
	close.text = "×"
	close.flat = true
	close.tooltip_text = "Close"
	close.pressed.connect(func() -> void: visible = false)
	header.add_child(close)
	box.add_child(header)

	_target_label = Label.new()
	_target_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_target_label.custom_minimum_size = Vector2(234, 0)
	_target_label.modulate = Color(1, 1, 1, 0.75)
	box.add_child(_target_label)
	var apply_row := HBoxContainer.new()
	var apply_label := Label.new()
	apply_label.text = "Apply To"
	apply_label.custom_minimum_size = Vector2(70, 0)
	apply_row.add_child(apply_label)
	_apply_to = OptionButton.new()
	_apply_to.add_item("Bodies")
	_apply_to.add_item("Faces")
	_apply_to.add_item("Components")
	_apply_to.tooltip_text = "Bodies: a picked face colors its whole body. Faces: picked faces get their own appearance. Components: everything picked colors its component."
	_apply_to.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_apply_to.item_selected.connect(func(_index: int) -> void: refresh())
	apply_row.add_child(_apply_to)
	box.add_child(apply_row)

	_list = ItemList.new()
	_list.custom_minimum_size = Vector2(0, 170)
	_list.fixed_icon_size = Vector2i(ICON_SIZE, ICON_SIZE)
	_list.tooltip_text = "Double-click to apply. Drop Material resources here to add them."
	_list.item_activated.connect(func(_index: int) -> void: apply_selected())
	_list.set_drag_forwarding(Callable(), _can_drop, _drop)
	box.add_child(_list)
	var buttons := HBoxContainer.new()
	for spec in [["Apply", apply_selected, "Give the selection the chosen appearance"],
			["Remove", remove_from_selection, "Take the selection's own appearance off"],
			["Add...", _browse_material, "Add a Material resource to the list"],
			["Refresh", refresh_library, "Read the material library folder again"]]:
		var button := Button.new()
		button.text = spec[0]
		button.tooltip_text = spec[2]
		button.pressed.connect(spec[1])
		buttons.add_child(button)
	box.add_child(buttons)

	var mapping_title := Label.new()
	mapping_title.text = "Texture Mapping"
	box.add_child(mapping_title)
	var grid := GridContainer.new()
	grid.columns = 2
	box.add_child(grid)
	_add_label(grid, "Type")
	_type = OptionButton.new()
	for type in APPEARANCE.TYPES:
		_type.add_item(APPEARANCE.TYPE_LABELS[type])
	_type.item_selected.connect(func(_index: int) -> void: _mapping_edited())
	grid.add_child(_type)
	_add_label(grid, "Scale")
	_scale = _pair(grid, "Meters per texture repeat, U and V (document units)", UNITS.KIND_LENGTH)
	_add_label(grid, "Rotation")
	_rotation = LineEdit.new()
	_rotation.tooltip_text = "Degrees, counter-clockwise on the surface. Drag left or right to change it."
	_connect_edit(_rotation, UNITS.KIND_ANGLE)
	grid.add_child(_rotation)
	_add_label(grid, "Offset")
	_offset = _pair(grid, "Offset in texture repeats, U and V", UNITS.KIND_NUMBER)
	_add_label(grid, "Origin")
	_origin = _edits(grid, ["X", "Y", "Z"], "The projection's center (document units)", UNITS.KIND_LENGTH)
	_add_label(grid, "Axis")
	_axis = _edits(grid, ["X", "Y", "Z"], "The projection's direction; 0, 0, 0 is automatic", UNITS.KIND_NUMBER)
	var children := grid.get_children()
	for i in range(children.size() - 4, children.size()):
		_placed_rows.append(children[i] as Control)
	var controls := Button.new()
	controls.text = "Texture Map Controls..."
	controls.tooltip_text = "Edit the mapping with handles in the view"
	controls.pressed.connect(open_texture_map)
	box.add_child(controls)
	_mapping_hint = Label.new()
	_mapping_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_mapping_hint.custom_minimum_size = Vector2(234, 0)
	_mapping_hint.modulate = Color(1, 1, 1, 0.6)
	box.add_child(_mapping_hint)

	_manage_box = VBoxContainer.new()
	var used_title := Label.new()
	used_title.text = "In This Design"
	_manage_box.add_child(used_title)
	_used_list = ItemList.new()
	_used_list.custom_minimum_size = Vector2(0, 80)
	_manage_box.add_child(_used_list)
	var manage_buttons := HBoxContainer.new()
	var replace := Button.new()
	replace.text = "Replace with Chosen"
	replace.tooltip_text = "Use the appearance chosen in the library wherever this one is used"
	replace.pressed.connect(func() -> void: replace_used(selected_id()))
	manage_buttons.add_child(replace)
	var remove_all := Button.new()
	remove_all.text = "Remove"
	remove_all.tooltip_text = "Take this appearance off everything that uses it"
	remove_all.pressed.connect(func() -> void: replace_used(""))
	manage_buttons.add_child(remove_all)
	_manage_box.add_child(manage_buttons)
	box.add_child(_manage_box)

	if workspace != null:
		workspace.selection_updated.connect(refresh)


## Shows the panel (manage: as Manage Materials) and fills it.
func open(p_manage := false) -> void:
	manage = p_manage
	_title.text = "MANAGE MATERIALS" if manage else "APPEARANCE"
	_manage_box.visible = manage
	visible = true
	if _list.item_count == 0:
		_fill_library()
	_fit()
	refresh()


## The appearance ids the library list shows, in order.
func library_ids() -> PackedStringArray:
	return _ids.duplicate()


## The id chosen in the library list ("" when none).
func selected_id() -> String:
	var chosen := _list.get_selected_items()
	return _ids[chosen[0]] if not chosen.is_empty() and chosen[0] < _ids.size() else ""


## Chooses an id in the library list; false when it isn't listed.
func select_id(id: String) -> bool:
	var index := _ids.find(id)
	if index < 0:
		return false
	_list.select(index)
	_list.ensure_current_is_visible()
	return true


## Gives the selection the chosen appearance. Returns how many targets it set.
func apply_selected() -> int:
	var id := selected_id()
	if id == "":
		workspace.flash("Choose an appearance in the list.")
		return 0
	var targets := _targets()
	if targets.is_empty():
		workspace.flash("Select faces, bodies or components in the view first.")
		return 0
	var count: int = workspace.apply_appearance(id, targets)
	workspace.flash("%s on %s." % [MATERIAL_LIBRARY.name_of(id), _describe(targets)])
	return count


## Where Apply and Remove act for the view selection, by Apply To (Bodies, Faces, Components).
func _targets() -> PackedStringArray:
	return workspace.appearance_targets(_apply_to.selected == 2, _apply_to.selected == 1)


## The appearances whose mapping the editors show and change: with Components, the picked
## components' own; otherwise whatever the picked faces and bodies show.
func _mapping_targets() -> PackedStringArray:
	var doc: Resource = workspace.doc
	var targets := PackedStringArray()
	var candidates: PackedStringArray = _targets() if _apply_to.selected == 2 else workspace.shown_appearance_targets()
	for target in candidates:
		if doc.appearances.has(target):
			targets.append(target)
	return targets


## Starts Texture Map Controls on the selection (handles for the mapping in the view).
func open_texture_map() -> void:
	if workspace == null or workspace.doc == null:
		return
	workspace.start_command(load(TEXTURE_MAP_COMMAND).new("appearance:texture_map"))


func remove_from_selection() -> void:
	var targets := _targets()
	if targets.is_empty():
		workspace.flash("Select faces, bodies or components in the view first.")
		return
	workspace.clear_appearance(targets)


## Adds a Material resource (by path) to the list and chooses it.
func add_material(path: String) -> bool:
	var material: Resource = load(path) if ResourceLoader.exists(path) else null
	if not material is Material:
		workspace.flash("%s is not a Material." % path.get_file())
		return false
	if not _custom.has(path):
		_custom.append(path)
	_fill_library()
	select_id(path)
	return true


## Reads the material library folder again (after texture sets were added or changed).
func refresh_library() -> void:
	MATERIAL_LIBRARY.clear_cache()
	_icons.clear()
	_fill_library()
	refresh()


## Manage Materials: swaps the appearance chosen under In This Design for new_id everywhere
## ("" removes it). Returns how many targets changed.
func replace_used(new_id: String) -> int:
	var chosen := _used_list.get_selected_items()
	if chosen.is_empty() or chosen[0] >= _used_ids.size():
		workspace.flash("Choose an appearance under In This Design.")
		return 0
	if new_id == "" and not manage:
		return 0
	return workspace.replace_appearance(_used_ids[chosen[0]], new_id)


## Shows what the selection is and its mapping. Called when the selection or design changes.
func refresh() -> void:
	if not visible or workspace == null or workspace.doc == null:
		return
	var doc: Resource = workspace.doc
	var targets := _targets()
	var mapping_targets := _mapping_targets()
	var own := mapping_targets[0] if not mapping_targets.is_empty() else ""
	if targets.is_empty():
		_target_label.text = "Select faces, bodies or components in the view."
	else:
		var shows := _current(targets[0])
		_target_label.text = "%s: %s" % [_describe(targets), shows]
	var editable := own != ""
	var edits: Array[LineEdit] = [_rotation]
	edits.append_array(_scale)
	edits.append_array(_offset)
	edits.append_array(_origin)
	edits.append_array(_axis)
	for edit in edits:
		edit.editable = editable
	_type.disabled = not editable
	var mapping := APPEARANCE.mapping_with_defaults((doc.appearances[own] as Dictionary).get("mapping", {}) if editable else {})
	_shown_mapping = mapping
	_type.select(maxi(APPEARANCE.TYPES.find(str(mapping.type)), 0))
	var scale: Vector2 = mapping.scale
	var offset: Vector2 = mapping.offset
	# Each editor keeps the (rounded) text it was given as "shown": only an editor whose text
	# differs from it was typed in (_typed()), so tabbing through never rounds a stored value.
	for axis in 2:
		_show(_scale[axis], UNITS.format_value(scale[axis], UNITS.KIND_LENGTH, doc.units).split(" ")[0])
		_show(_offset[axis], _num(offset[axis]))
	_show(_rotation, _num(rad_to_deg(float(mapping.rotation))))
	var origin: Vector3 = mapping.origin
	var direction: Vector3 = mapping.axis
	for i in 3:
		_show(_origin[i], UNITS.format_value(origin[i], UNITS.KIND_LENGTH, doc.units).split(" ")[0])
		_show(_axis[i], _num(direction[i]))
	# Automatic mapping follows the face itself: it has no origin or axis.
	for row in _placed_rows:
		row.visible = str(mapping.type) != "automatic"
	_mapping_hint.text = "Editing the mapping of %s." % _describe(PackedStringArray([own])) if editable else "Apply an appearance to the selection to edit its mapping."
	if manage:
		_fill_used()


func _current(target: String) -> String:
	var doc: Resource = workspace.doc
	var parts := target.split(":")
	var found := {}
	match parts[0]:
		"face":
			found = APPEARANCE.resolve(doc, parts[1], target.substr(target.find(":", 5) + 1))
		"body":
			found = APPEARANCE.resolve(doc, parts[1], "")
		"component":
			var entry: Dictionary = doc.appearances.get(target, {})
			found = {"material": str(entry.get("material", "")), "source": "component" if not entry.is_empty() else ""}
	var name := MATERIAL_LIBRARY.name_of(str(found.get("material", "")))
	var source := str(found.get("source", ""))
	return name + (" (from its %s)" % source if source != "" and source != parts[0] else "")


## "Face of Body1", "Body1", "Component2", or counts for several.
func _describe(targets: PackedStringArray) -> String:
	var doc: Resource = workspace.doc
	if targets.size() == 1:
		var parts := targets[0].split(":")
		match parts[0]:
			"face":
				return "Face of " + doc.body_name(parts[1])
			"body":
				return doc.body_name(parts[1])
			"component":
				return doc.component_name(parts[1])
	var counts := {"face": 0, "body": 0, "component": 0}
	for target in targets:
		var kind := target.get_slice(":", 0)
		counts[kind] = int(counts.get(kind, 0)) + 1
	var nouns := {"face": ["face", "faces"], "body": ["body", "bodies"], "component": ["component", "components"]}
	var words := PackedStringArray()
	for kind in nouns:
		var n := int(counts[kind])
		if n > 0:
			words.append("%d %s" % [n, nouns[kind][0 if n == 1 else 1]])
	return ", ".join(words)


func _fill_library() -> void:
	var keep := selected_id()
	_list.clear()
	_ids.clear()
	for e in MATERIAL_LIBRARY.sets():
		_add_item(str(e.id), str(e.name), str(e.preview))
	var extra := _custom.duplicate()
	# Materials the design already uses but the list doesn't have (dragged in another session).
	if workspace != null and workspace.doc != null:
		for id in workspace.appearance_uses():
			if not str(id).begins_with("builtin:") and not str(id).begins_with("library:") and not extra.has(id):
				extra.append(id)
	for id in extra:
		_add_item(id, MATERIAL_LIBRARY.name_of(id), "")
	if keep != "":
		select_id(keep)


func _add_item(id: String, label: String, preview: String) -> void:
	var index := _list.add_item(label, _icon_for(id, preview))
	_list.set_item_tooltip(index, id)
	_ids.append(id)


func _fill_used() -> void:
	var keep := ""
	var chosen := _used_list.get_selected_items()
	if not chosen.is_empty() and chosen[0] < _used_ids.size():
		keep = _used_ids[chosen[0]]
	_used_list.clear()
	_used_ids.clear()
	var uses: Dictionary = workspace.appearance_uses()
	for id in uses:
		var index := _used_list.add_item("%s (%d)" % [MATERIAL_LIBRARY.name_of(id), uses[id]], _icon_for(id, str(MATERIAL_LIBRARY.entry(id).get("preview", ""))))
		_used_list.set_item_tooltip(index, id)
		_used_ids.append(id)
		if id == keep:
			_used_list.select(index)


## A small picture for an appearance: the set's preview, else a swatch of its color.
func _icon_for(id: String, preview: String) -> Texture2D:
	if _icons.has(id):
		return _icons[id]
	var icon: Texture2D = null
	if preview != "":
		icon = MATERIAL_LIBRARY.load_texture(preview)
	if icon == null:
		var color := Color(0, 0, 0, 0)
		if id.begins_with("builtin:"):
			color = (MATERIAL_LIBRARY.BUILTINS.get(id.trim_prefix("builtin:"), [null, Color(0.5, 0.5, 0.5)]) as Array)[1]
		elif not id.begins_with("library:"):
			var material := MATERIAL_LIBRARY.material(id) as BaseMaterial3D
			if material != null:
				color = material.albedo_color
		if color.a > 0.0:
			var image := Image.create(ICON_SIZE, ICON_SIZE, false, Image.FORMAT_RGBA8)
			image.fill(Color(color, maxf(color.a, 0.35)))
			icon = ImageTexture.create_from_image(image)
	_icons[id] = icon
	return icon


func _mapping_edited() -> void:
	var targets := _mapping_targets()
	if targets.is_empty():
		return
	var changes := {}
	var type: String = APPEARANCE.TYPES[maxi(_type.selected, 0)]
	if type != str(_shown_mapping.get("type", "")):
		changes["type"] = type
	# A value changes only when its editor's text does (the shown text is rounded); the other half
	# of a pair keeps the stored value exactly.
	var scale: Vector2 = _shown_mapping.scale
	var offset: Vector2 = _shown_mapping.offset
	for axis in 2:
		if _typed(_scale[axis]):
			scale[axis] = _length(_scale[axis].text, scale[axis])
		if _typed(_offset[axis]):
			offset[axis] = _number(_offset[axis].text, offset[axis])
	if scale != _shown_mapping.scale:
		changes["scale"] = scale
	if offset != _shown_mapping.offset:
		changes["offset"] = offset
	if _typed(_rotation):
		var rotation := deg_to_rad(_number(_rotation.text, rad_to_deg(float(_shown_mapping.rotation))))
		if not is_equal_approx(rotation, float(_shown_mapping.rotation)):
			changes["rotation"] = rotation
	var origin: Vector3 = _shown_mapping.origin
	var direction: Vector3 = _shown_mapping.axis
	for i in 3:
		if _typed(_origin[i]):
			origin[i] = _position(_origin[i].text, origin[i])
		if _typed(_axis[i]):
			direction[i] = _number(_axis[i].text, direction[i])
	if origin != _shown_mapping.origin:
		changes["origin"] = origin
	if direction != _shown_mapping.axis:
		changes["axis"] = direction
	if not changes.is_empty():
		workspace.set_appearance_mapping(targets, changes)


## Puts text in a mapping editor and remembers it as what the panel shows.
func _show(edit: LineEdit, text: String) -> void:
	edit.text = text
	edit.set_meta("shown", text)


## True when a mapping editor's text was changed from what refresh() showed.
func _typed(edit: LineEdit) -> bool:
	return edit.text != str(edit.get_meta("shown", ""))


func _length(text: String, fallback: float) -> float:
	var r := UNITS.evaluate(text, UNITS.KIND_LENGTH, str(workspace.doc.units), {})
	return float(r.value) if r.ok and absf(float(r.value)) > 1e-9 else fallback


## A coordinate (any length, zero too).
func _position(text: String, fallback: float) -> float:
	var r := UNITS.evaluate(text, UNITS.KIND_LENGTH, str(workspace.doc.units), {})
	return float(r.value) if r.ok else fallback


func _number(text: String, fallback: float) -> float:
	var r := UNITS.evaluate(text, UNITS.KIND_NUMBER, str(workspace.doc.units), {})
	return float(r.value) if r.ok else fallback


static func _num(value: float) -> String:
	var text := String.num(snappedf(value, 0.0001), 4)
	return text.rstrip("0").rstrip(".") if text.contains(".") else text


func _add_label(grid: GridContainer, text: String) -> void:
	var label := Label.new()
	label.text = text
	label.custom_minimum_size = Vector2(70, 0)
	grid.add_child(label)


func _pair(grid: GridContainer, tooltip: String, kind: String) -> Array[LineEdit]:
	return _edits(grid, ["U", "V"], tooltip, kind)


## A row of line edits, one per name (tooltips "<name>: <tooltip>"), holding values of a kind.
func _edits(grid: GridContainer, names: Array, tooltip: String, kind: String) -> Array[LineEdit]:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var edits: Array[LineEdit] = []
	for axis in names.size():
		var edit := LineEdit.new()
		edit.tooltip_text = str(names[axis]) + ": " + tooltip + ". Drag left or right to change it."
		edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		edit.custom_minimum_size = Vector2(120.0 / names.size(), 0)
		_connect_edit(edit, kind)
		row.add_child(edit)
		edits.append(edit)
	grid.add_child(row)
	return edits


## Applies an editor's text on Enter and when it loses the keyboard; dragging it (ui/number_drag.gd)
## changes the text as it goes and applies it, as one undo step, when the drag ends.
func _connect_edit(edit: LineEdit, kind: String) -> void:
	edit.text_submitted.connect(func(_text: String) -> void: _mapping_edited())
	edit.focus_exited.connect(_mapping_edited)
	var helper: RefCounted = NUMBER_DRAG.attach(edit, kind, func() -> String: return str(workspace.doc.units) if workspace != null and workspace.doc != null else "mm",
		Callable(), {"bare": true})
	helper.dragging_changed = func(active: bool) -> void:
		if not active:
			_mapping_edited()


## Keeps the panel inside a small view: the library list gives up height first.
func _fit() -> void:
	var parent := get_parent() as Control
	if parent == null:
		return
	if not parent.resized.is_connected(_fit):
		parent.resized.connect(_fit)
	var spare := parent.size.y - 80.0 - (get_combined_minimum_size().y - _list.custom_minimum_size.y)
	_list.custom_minimum_size.y = clampf(spare, 60.0, 170.0)
	reset_size()


func _browse_material() -> void:
	if not Engine.is_editor_hint():
		return
	if _file_dialog == null:
		var dialog := EditorFileDialog.new()
		dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
		dialog.access = EditorFileDialog.ACCESS_RESOURCES
		dialog.add_filter("*.tres, *.res, *.material", "Materials")
		dialog.file_selected.connect(func(path: String) -> void: add_material(path))
		add_child(dialog)
		_file_dialog = dialog
	(_file_dialog as EditorFileDialog).popup_file_dialog()


func _can_drop(_at: Vector2, data: Variant) -> bool:
	if not data is Dictionary:
		return false
	if str(data.get("type", "")) == "resource":
		return data.get("resource") is Material
	if str(data.get("type", "")) == "files":
		for path in data.get("files", []):
			if MATERIAL_EXTENSIONS.has(str(path).get_extension().to_lower()):
				return true
	return false


func _drop(_at: Vector2, data: Variant) -> void:
	if str(data.get("type", "")) == "resource":
		var resource: Resource = data.resource
		if resource.resource_path != "":
			add_material(resource.resource_path)
		return
	for path in data.get("files", []):
		if MATERIAL_EXTENSIONS.has(str(path).get_extension().to_lower()):
			add_material(str(path))
