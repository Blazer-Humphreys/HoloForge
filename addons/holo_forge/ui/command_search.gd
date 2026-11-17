@tool
extends PanelContainer
## The S-key toolbox: type to find any tool by name (all workspaces), Enter to run it. Pinned
## tools (right-click a result to pin) are listed first when the search box is empty; pins are
## kept in Editor Settings under holo_forge/pinned_tools.

const CATALOG := preload("res://addons/holo_forge/tools/catalog.gd")
const PINS_SETTING := "holo_forge/pinned_tools"

signal tool_chosen(tool: Dictionary)

var workspace := "Solid"
var _search: LineEdit
var _list: ItemList
var _results: Array[Dictionary] = []


func _init() -> void:
	custom_minimum_size = Vector2(300, 260)
	visible = false
	var box := VBoxContainer.new()
	add_child(box)
	_search = LineEdit.new()
	_search.placeholder_text = "Search tools (right-click a result to pin it)"
	_search.text_changed.connect(func(_text: String) -> void: _refresh())
	_search.text_submitted.connect(func(_text: String) -> void: _choose(maxi(_selected_index(), 0)))
	_search.gui_input.connect(_search_input)
	box.add_child(_search)
	_list = ItemList.new()
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.item_activated.connect(_choose)
	_list.item_clicked.connect(func(index: int, _at: Vector2, mouse_button: int) -> void:
		if mouse_button == MOUSE_BUTTON_RIGHT:
			_toggle_pin(index))
	box.add_child(_list)


func open(at: Vector2, p_workspace: String) -> void:
	workspace = p_workspace
	position = at
	_search.text = ""
	visible = true
	_refresh()
	_search.grab_focus()


func close() -> void:
	visible = false


## The tools listed for a query (used by tests and the search box).
func results_for(text: String) -> Array[Dictionary]:
	if text.strip_edges() == "":
		var pinned: Array[Dictionary] = []
		for id in pinned_ids():
			var tool := CATALOG.find(id)
			if not tool.is_empty():
				pinned.append(tool)
		var rest := CATALOG.search("", workspace).filter(func(t: Dictionary) -> bool: return CATALOG.is_enabled(t) and not pinned_ids().has(t.id))
		pinned.append_array(rest)
		return pinned
	return CATALOG.search(text, workspace)


static func pinned_ids() -> PackedStringArray:
	if not Engine.is_editor_hint():
		return PackedStringArray()
	var settings := EditorInterface.get_editor_settings()
	return settings.get_setting(PINS_SETTING) if settings.has_setting(PINS_SETTING) else PackedStringArray()


func _refresh() -> void:
	_results = results_for(_search.text)
	_list.clear()
	var pins := pinned_ids()
	for tool in _results.slice(0, 60):
		var label: String = ("★ " if pins.has(tool.id) else "") + tool.name
		if tool.workspace != workspace:
			label += "   (%s)" % tool.workspace
		var index := _list.add_item(label)
		if not CATALOG.is_enabled(tool):
			_list.set_item_disabled(index, true)
			_list.set_item_tooltip(index, "Arrives in Phase %d" % tool.phase)
		else:
			_list.set_item_tooltip(index, "%s > %s" % [tool.workspace, tool.group])
	if _list.item_count > 0:
		_list.select(0)


func _selected_index() -> int:
	var selected := _list.get_selected_items()
	return selected[0] if not selected.is_empty() else -1


func _choose(index: int) -> void:
	if index < 0 or index >= _results.size() or _list.is_item_disabled(index):
		return
	close()
	tool_chosen.emit(_results[index])


func _toggle_pin(index: int) -> void:
	if index < 0 or index >= _results.size() or not Engine.is_editor_hint():
		return
	var pins := pinned_ids()
	var id: String = _results[index].id
	if pins.has(id):
		pins.remove_at(pins.find(id))
	else:
		pins.append(id)
	EditorInterface.get_editor_settings().set_setting(PINS_SETTING, pins)
	_refresh()


func _search_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed:
		return
	match key.keycode:
		KEY_ESCAPE:
			close()
			_search.accept_event()
		KEY_DOWN, KEY_UP:
			var next := clampi(_selected_index() + (1 if key.keycode == KEY_DOWN else -1), 0, _list.item_count - 1)
			if _list.item_count > 0:
				_list.select(next)
				_list.ensure_current_is_visible()
			_search.accept_event()
