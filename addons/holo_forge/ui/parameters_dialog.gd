@tool
extends AcceptDialog
## Change Parameters: user parameters (name, unit, expression, comment, favorite) and every
## model parameter (d1, d2, ... from feature inputs). Edits apply live; errors show in red.

const UNITS := preload("res://addons/holo_forge/core/units.gd")

signal user_parameter_added
signal user_parameter_removed(index: int)
## field: "name", "unit", "expression", "comment" or "favorite".
signal user_parameter_changed(index: int, field: String, value: Variant)
signal model_expression_changed(feature_id: String, key: String, expression: String)

const UNIT_CHOICES := ["mm", "cm", "m", "in", "ft", "deg", "rad", ""]
const COL_STAR := 0
const COL_NAME := 1
const COL_UNIT := 2
const COL_EXPRESSION := 3
const COL_VALUE := 4
const COL_COMMENT := 5
const BUTTON_DELETE := 0

var _tree: Tree
var _filter: LineEdit


func _init() -> void:
	title = "Parameters"
	ok_button_text = "Close"
	min_size = Vector2i(820, 460)
	var box := VBoxContainer.new()
	add_child(box)
	var row := HBoxContainer.new()
	var add := Button.new()
	add.text = "+ User Parameter"
	add.pressed.connect(func() -> void: user_parameter_added.emit())
	row.add_child(add)
	_filter = LineEdit.new()
	_filter.placeholder_text = "Filter"
	_filter.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_filter)
	box.add_child(row)
	_tree = Tree.new()
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.columns = 6
	_tree.column_titles_visible = true
	_tree.hide_root = true
	for spec in [[COL_STAR, "★", 30], [COL_NAME, "Name", 140], [COL_UNIT, "Unit", 70], [COL_EXPRESSION, "Expression", 200], [COL_VALUE, "Value", 110], [COL_COMMENT, "Comment", 180]]:
		_tree.set_column_title(spec[0], spec[1])
		_tree.set_column_custom_minimum_width(spec[0], spec[2])
		_tree.set_column_expand(spec[0], spec[0] in [COL_EXPRESSION, COL_COMMENT])
	_tree.item_edited.connect(_on_edited)
	_tree.button_clicked.connect(_on_button)
	box.add_child(_tree)
	_filter.text_changed.connect(func(_t: String) -> void: _apply_filter())


## doc: the document; values: parameter results from parameters.gd.
func refresh(doc: Resource, values: Dictionary) -> void:
	_tree.clear()
	var root := _tree.create_item()
	var user := _tree.create_item(root)
	user.set_text(COL_NAME, "User Parameters")
	user.set_selectable(COL_NAME, false)
	for i in doc.user_parameters.size():
		var p: Dictionary = doc.user_parameters[i]
		var item := _tree.create_item(user)
		item.set_metadata(0, {"type": "user", "index": i})
		item.set_cell_mode(COL_STAR, TreeItem.CELL_MODE_CHECK)
		item.set_checked(COL_STAR, bool(p.get("favorite", false)))
		item.set_editable(COL_STAR, true)
		item.set_text(COL_NAME, str(p.get("name", "")))
		item.set_editable(COL_NAME, true)
		item.set_cell_mode(COL_UNIT, TreeItem.CELL_MODE_RANGE)
		item.set_text(COL_UNIT, ",".join(UNIT_CHOICES.map(func(u: String) -> String: return u if u != "" else "No Units")))
		item.set_range(COL_UNIT, maxi(UNIT_CHOICES.find(str(p.get("unit", ""))), 0))
		item.set_editable(COL_UNIT, true)
		item.set_text(COL_EXPRESSION, str(p.get("expression", "")))
		item.set_editable(COL_EXPRESSION, true)
		_set_value(item, values.get(str(p.get("name", ""))), UNITS.unit_kind(str(p.get("unit", ""))), doc.units)
		item.set_text(COL_COMMENT, str(p.get("comment", "")))
		item.set_editable(COL_COMMENT, true)
		item.add_button(COL_COMMENT, _icon("Remove"), BUTTON_DELETE, false, "Delete parameter")

	var model := _tree.create_item(root)
	model.set_text(COL_NAME, "Model Parameters")
	model.set_selectable(COL_NAME, false)
	var by_feature := {}
	for p in doc.model_parameters():
		var parent: TreeItem = by_feature.get(p.feature)
		if parent == null:
			parent = _tree.create_item(model)
			parent.set_text(COL_NAME, str(p.label).split(" ")[0])
			parent.set_selectable(COL_NAME, false)
			by_feature[p.feature] = parent
		var item := _tree.create_item(parent)
		item.set_metadata(0, {"type": "model", "feature": p.feature, "key": p.key})
		item.set_text(COL_NAME, p.name)
		item.set_tooltip_text(COL_NAME, p.label)
		item.set_text(COL_UNIT, UNITS.display_unit(p.kind, doc.units))
		item.set_text(COL_EXPRESSION, p.expression)
		item.set_editable(COL_EXPRESSION, true)
		_set_value(item, values.get(p.name), p.kind, doc.units)
		# What it sizes ("Length", "Diameter"): its label after the feature's name.
		var owner: Resource = doc.find_feature(str(p.feature))
		item.set_text(COL_COMMENT, str(p.label).trim_prefix(str(owner.label) + " ") if owner != null else str(p.key).capitalize())
	_apply_filter()


func _set_value(item: TreeItem, result, kind: String, units: String) -> void:
	if result is Dictionary and result.get("ok", false):
		item.set_text(COL_VALUE, UNITS.format_value(float(result.value), kind, units))
		item.set_custom_color(COL_VALUE, Color(1, 1, 1, 0.75))
		item.set_tooltip_text(COL_VALUE, "")
	else:
		var error := str(result.get("error", "Not evaluated")) if result is Dictionary else "Not evaluated"
		item.set_text(COL_VALUE, "⚠ error")
		item.set_custom_color(COL_VALUE, Color(1.0, 0.45, 0.4))
		item.set_tooltip_text(COL_VALUE, error)


func _on_edited() -> void:
	var item := _tree.get_edited()
	var column := _tree.get_edited_column()
	var meta = item.get_metadata(0) if item != null else null
	if not meta is Dictionary:
		return
	if meta.type == "model":
		if column == COL_EXPRESSION:
			model_expression_changed.emit(meta.feature, meta.key, item.get_text(COL_EXPRESSION).strip_edges())
		return
	match column:
		COL_STAR:
			user_parameter_changed.emit(meta.index, "favorite", item.is_checked(COL_STAR))
		COL_NAME:
			user_parameter_changed.emit(meta.index, "name", item.get_text(COL_NAME).strip_edges())
		COL_UNIT:
			user_parameter_changed.emit(meta.index, "unit", UNIT_CHOICES[int(item.get_range(COL_UNIT))])
		COL_EXPRESSION:
			user_parameter_changed.emit(meta.index, "expression", item.get_text(COL_EXPRESSION).strip_edges())
		COL_COMMENT:
			user_parameter_changed.emit(meta.index, "comment", item.get_text(COL_COMMENT))


func _on_button(item: TreeItem, _column: int, id: int, _mouse_button: int) -> void:
	var meta = item.get_metadata(0)
	if id == BUTTON_DELETE and meta is Dictionary and meta.type == "user":
		user_parameter_removed.emit(meta.index)


## Hides rows whose name, expression and comment do not contain the filter text.
func _apply_filter() -> void:
	var needle := _filter.text.strip_edges().to_lower()
	var root := _tree.get_root()
	if root == null:
		return
	for section in root.get_children():
		for item in _leaf_items(section):
			var text := (item.get_text(COL_NAME) + " " + item.get_text(COL_EXPRESSION) + " " + item.get_text(COL_COMMENT) + " " + item.get_tooltip_text(COL_NAME)).to_lower()
			item.visible = needle == "" or text.contains(needle)


func _leaf_items(item: TreeItem) -> Array[TreeItem]:
	var result: Array[TreeItem] = []
	for child in item.get_children():
		if child.get_child_count() > 0:
			result.append_array(_leaf_items(child))
		else:
			result.append(child)
	return result


static func _icon(name: String) -> Texture2D:
	if not Engine.is_editor_hint():
		return null
	var theme := EditorInterface.get_editor_theme()
	return theme.get_icon(name, "EditorIcons") if theme != null and theme.has_icon(name, "EditorIcons") else null
