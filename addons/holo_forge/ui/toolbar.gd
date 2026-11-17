@tool
extends HBoxContainer
## The Forge toolbar on one row: a workspace switcher (Solid, Surface, Mesh, ...), then a block per
## tool group - the group's pinned tools as icon buttons over its name, which opens a dropdown of
## all its tools (families of like tools in submenus, later-phase tools greyed with their phase,
## the Select menu's filters, priority and selection sets, Pin to Toolbar and Reset Toolbar) - then
## the part's name, Parameters and the appearance button (Dark, Light, Follow Editor).
##
## When the blocks don't fit, the part's name gives way first (down to PART_LABEL_MIN), then the
## other blocks' icons go from the right end (a block keeps the icons that fit under its name),
## then those blocks fold from the right into a » menu; only then do the first PRIMARY_BLOCKS
## (Create and Modify) lose icons and fold. Icons come back from the left while they fit, so a
## block may show only its first few. Every tool stays on the bar, and the bar's minimum width
## never depends on that layout.
##
## Pins are kept per workspace and group in the editor's project metadata (in memory outside the
## editor, or in pin_store when a test sets one). A right-click on a tool in a dropdown pins or
## unpins it; a right-click on an icon on the bar unpins it or moves it.
##
## Icons and the bar's own lines and labels are drawn in ink_color (set_ink_color, bar_colors()).
## While the Sketch toolbar shows, the switcher is locked: Finish Sketch first.

const CATALOG := preload("res://addons/holo_forge/tools/catalog.gd")
## Tool icons: <slug>.svg shared by every workspace, <workspace slug>/<slug>.svg for a workspace's own.
const ICON_DIR := "res://addons/holo_forge/icons/tools/"
## The neutral colour the icon SVGs are drawn in; it's swapped for ink_color as an icon loads.
const SVG_INK := "#dfe3ea"
## The SVGs' accents and the darker shades they take under a dark ink (a light background), so
## they read there as well as on the dark one (3:1 or better on the light chrome).
const LIGHT_ACCENTS := {
	"#22b8cc": "#0b8294", "#d14fc0": "#b23ca3", "#e0a526": "#a06c00",
	"#f05a5a": "#cc3838", "#8d74f0": "#6a4fd8", "#3fb26a": "#22864c",
}
## The ink on a dark and on a light editor theme, until set_ink_color picks another.
const DARK_THEME_INK := Color("#dfe3ea")
const LIGHT_THEME_INK := Color("#2c323c")
## The part's name gives way down to this before any block changes, and takes back what's left.
const PART_LABEL_MIN := 60.0
## The blocks that keep their icons while any other block is on the bar (Create and Modify).
const PRIMARY_BLOCKS := 2
## Sizes at editor scale 1: an icon button on the bar, the icon in it, an icon in a dropdown.
const BUTTON_SIZE := 28.0
const BAR_ICON_SIZE := 24.0
const MENU_ICON_SIZE := 16.0
## Space on each side of the line between two blocks, and between two icons.
const BLOCK_GAP := 5.0
const ICON_GAP := 2.0
## Dropdown item ids past the tools' own (a tool's id is its index in its group).
const SELECT_THROUGH_ID := 1000
const RESET_ID := 1001
const PIN_MENU_ID := 1002
const SUBMENU_ID := 2000
const PINS_SECTION := "holo_forge"
const PINS_KEY := "toolbar_pins"
const _GENERIC_SVG := "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"24\" height=\"24\" viewBox=\"0 0 24 24\"><rect x=\"5\" y=\"5\" width=\"14\" height=\"14\" rx=\"3\" fill=\"none\" stroke=\"#dfe3ea\" stroke-opacity=\"0.7\" stroke-width=\"1.6\"/><circle cx=\"12\" cy=\"12\" r=\"2\" fill=\"#dfe3ea\" fill-opacity=\"0.7\"/></svg>"
const _CARET_SVG := "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\" viewBox=\"0 0 10 10\"><path d=\"M2.6 3.8 5 6.2 7.4 3.8\" fill=\"none\" stroke=\"#dfe3ea\" stroke-opacity=\"0.85\" stroke-width=\"1.4\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/></svg>"

signal workspace_changed(workspace: String)
signal tool_activated(tool: Dictionary)
## key: "filter:<kind>", "priority", "select_through", "selection_set"
signal select_option_changed(key: String, value: Variant)
signal parameters_requested
## The appearance button's menu picked a mode: "dark", "light" or "editor".
signal theme_mode_requested(mode: String)

## The appearance button's menu, in order (its item ids are the indexes).
const THEME_MODES := [["dark", "Dark"], ["light", "Light"], ["editor", "Follow Editor"]]

var workspace := "Solid"
var filters := {"body": true, "face": true, "edge": true, "vertex": true}
var priority := "default"
var select_through := false
var selection_sets: PackedStringArray = []
## The colour icons, labels and lines are drawn in (see set_ink_color).
var ink_color := DARK_THEME_INK
## Where pins are kept: null for the default (the editor's project metadata, memory elsewhere), or
## a Dictionary the bar reads and writes them in under PINS_KEY (tests).
var pin_store: Variant = null:
	set(value):
		pin_store = value
		_pins = _read_pins()
		_rebuild_rows()
## How many times the blocks were built (for tests).
var build_count := 0

## Pins outside the editor: workspace -> group -> [tool ids].
static var _memory_pins := {}
## Rendered icons by source, size and ink; a tool's SVG file ("" for none) by workspace and name.
static var _icon_cache := {}
static var _icon_files := {}

var _workspace_button: OptionButton
var _menu_area: Control
var _more: MenuButton
var _part_label: Label
## The right-click menu of an icon on the bar.
var _icon_menu: PopupMenu
var _icon_menu_tool := ""
var _menus := {}
var _rows := {}
var _lines := {}
## The groups folded into the » menu, and how many of its icons each block shows.
var _folded: Array[String] = []
var _shown_icons := {}
var _fit_queued := false
var _rebuild_queued := false
var _pins := {}
var _ink_chosen := false
## The group names' font size the blocks were built with (a theme change rebuilds only if it changed).
var _built_font_size := -1
## Dropdowns the mouse last moved over (by instance id): a right-click there pins the item under it.
var _mouse_menus := {}
## What a dropdown's pick runs at the end of the frame, by dropdown (see _on_menu_input).
var _picks := {}
var _styles := {}
## The appearance button at the bar's right end: a moon or a sun for the palette shown, and a
## menu of the modes (set_theme_state).
var _theme_button: MenuButton
var _theme_mode := "editor"
var _theme_dark := true


func _init() -> void:
	ink_color = _theme_ink()
	add_theme_constant_override("separation", 6)
	_workspace_button = OptionButton.new()
	for name in CATALOG.WORKSPACES:
		_workspace_button.add_item(name)
	_workspace_button.tooltip_text = "Workspace"
	_workspace_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_workspace_button.item_selected.connect(func(index: int) -> void:
		workspace = CATALOG.WORKSPACES[index]
		_rebuild_groups()
		workspace_changed.emit(workspace))
	add_child(_workspace_button)
	add_child(VSeparator.new())
	# The blocks and the part's name share a clipped area that may be narrower than they are;
	# _fit_menus() lays them out in it by hand. (The area's own minimum never depends on that
	# layout, so the bar can always shrink to what it's given.)
	_menu_area = Control.new()
	_menu_area.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_menu_area.clip_contents = true
	_menu_area.resized.connect(_queue_fit)
	add_child(_menu_area)
	_more = MenuButton.new()
	_more.text = "»"
	_more.tooltip_text = "The groups that don't fit the bar"
	_more.flat = false
	_more.switch_on_hover = true
	_more.set_disable_shortcuts(true)
	_more.visible = false
	_more.about_to_popup.connect(_fill_more)
	_menu_area.add_child(_more)
	_part_label = Label.new()
	_part_label.clip_text = true
	_part_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_part_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_part_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_part_label.mouse_filter = Control.MOUSE_FILTER_PASS
	_menu_area.add_child(_part_label)
	var parameters := Button.new()
	parameters.text = "Parameters"
	parameters.tooltip_text = "Change Parameters"
	parameters.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	parameters.pressed.connect(func() -> void: parameters_requested.emit())
	add_child(parameters)
	_theme_button = MenuButton.new()
	_theme_button.flat = true
	_theme_button.focus_mode = Control.FOCUS_NONE
	_theme_button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_theme_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_theme_button.set_disable_shortcuts(true)
	var theme_popup := _theme_button.get_popup()
	for i in THEME_MODES.size():
		theme_popup.add_radio_check_item(THEME_MODES[i][1], i)
	theme_popup.id_pressed.connect(func(id: int) -> void: theme_mode_requested.emit(THEME_MODES[id][0]))
	add_child(_theme_button)
	_show_theme_state()
	_icon_menu = PopupMenu.new()
	_icon_menu.add_item("Unpin from Toolbar", 0)
	_icon_menu.add_separator()
	_icon_menu.add_item("Move Left", 1)
	_icon_menu.add_item("Move Right", 2)
	_icon_menu.id_pressed.connect(func(id: int) -> void:
		if id == 0:
			pin(_icon_menu_tool, false)
		else:
			move_pin(_icon_menu_tool, -1 if id == 1 else 1))
	add_child(_icon_menu, false, Node.INTERNAL_MODE_BACK)
	_pins = _read_pins()


func _ready() -> void:
	_rebuild_groups()


func _notification(what: int) -> void:
	if what != NOTIFICATION_THEME_CHANGED or not is_node_ready() or _rebuild_queued:
		return
	# The blocks are built again only when the ink (following the editor) or the group names'
	# font size changed; otherwise they only need laying out again in the new sizes.
	var ink := ink_color if _ink_chosen else _theme_ink()
	if ink != ink_color or _font_size() != _built_font_size:
		ink_color = ink
		_show_theme_state()
		_rebuild_queued = true
		_rebuild_groups.call_deferred()
	else:
		_update_area_minimum()
		_queue_fit()


func set_workspace(value: String, locked := false) -> void:
	workspace = value
	var index := CATALOG.WORKSPACES.find(value)
	_workspace_button.select(index)
	# The Sketch toolbar isn't one of the switcher's workspaces; the switcher waits for Finish Sketch.
	# A locked workspace (the open Form environment) shows its name but waits for its own Finish.
	_workspace_button.disabled = index < 0 or locked
	if index < 0:
		_workspace_button.tooltip_text = "Finish the sketch to change the workspace."
	elif locked:
		_workspace_button.tooltip_text = "Finish the %s to change the workspace." % value.to_lower()
	else:
		_workspace_button.tooltip_text = "Workspace"
	if index < 0:
		_workspace_button.text = value
	_rebuild_groups()


## The workspace switcher (locked while the Sketch toolbar shows).
func workspace_switcher() -> OptionButton:
	return _workspace_button


## The part's name at the bar's right end (measured with its real font each layout).
func set_part_name(text: String) -> void:
	_part_label.text = text
	_part_label.tooltip_text = text
	_queue_fit()


func set_selection_sets(names: PackedStringArray) -> void:
	if names == selection_sets:
		return
	selection_sets = names
	_rebuild_groups()


func set_select_state(p_filters: Dictionary, p_priority: String, p_through: bool) -> void:
	# The Select menus show these each time they open.
	filters = p_filters.duplicate()
	priority = p_priority
	select_through = p_through


## Draws the icons, the group names, the part's name and the lines in another ink (dark ink for a
## light background, with darker accents): re-renders the icons and rebuilds the bar.
func set_ink_color(color: Color) -> void:
	_ink_chosen = true
	if color == ink_color:
		return
	ink_color = color
	_show_theme_state()
	_rebuild_groups()


## Shows the appearance mode on its button: mode "dark", "light" or "editor", dark the palette
## shown (a moon for dark, a sun for light; the menu ticks the mode).
func set_theme_state(mode: String, dark: bool) -> void:
	_theme_mode = mode
	_theme_dark = dark
	_show_theme_state()


## The appearance button (its popup lists Dark, Light and Follow Editor).
func theme_button() -> MenuButton:
	return _theme_button


func _show_theme_state() -> void:
	var s := _scale()
	_theme_button.icon = file_icon(ICON_DIR + ("dark_mode.svg" if _theme_dark else "light_mode.svg"), 20.0 * s, ink_color)
	_theme_button.custom_minimum_size = Vector2.ONE * roundf(BUTTON_SIZE * s)
	for state in ["hover", "pressed", "hover_pressed"]:
		var box := StyleBoxFlat.new()
		box.bg_color = Color(ink_color, 0.1 if state == "hover" else 0.2)
		box.set_corner_radius_all(roundi(4.0 * s))
		_theme_button.add_theme_stylebox_override(state, box)
	var popup := _theme_button.get_popup()
	for i in THEME_MODES.size():
		popup.set_item_checked(i, THEME_MODES[i][0] == _theme_mode)
	var shown := "Dark" if _theme_dark else "Light"
	_theme_button.tooltip_text = "Appearance: %s%s. Click to pick Dark, Light or Follow Editor." % [shown, " (following the editor)" if _theme_mode == "editor" else ""]


## The bar's own colours, all from the ink: group names, the part's name, the lines between
## blocks, and the icon buttons' hover and pressed backgrounds.
func bar_colors() -> Dictionary:
	return {
		"group": Color(ink_color, 0.78), "group_hover": ink_color, "part_name": Color(ink_color, 0.62),
		"line": Color(ink_color, 0.16), "hover": Color(ink_color, 0.1), "pressed": Color(ink_color, 0.2),
		"icon_disabled": Color(1, 1, 1, 0.32),
	}


## The group menus by name (tests and the marking menu read them), folded or not.
func group_menu(group: String) -> MenuButton:
	return _menus.get(group)


## The groups folded into the » menu because the bar is too narrow for them.
func folded_groups() -> Array[String]:
	return _folded.duplicate()


## The groups on the bar that show fewer of their pinned icons than they have, for want of room.
func compact_groups() -> Array[String]:
	var groups: Array[String] = []
	for group in _menus:
		if not _folded.has(group) and int(_shown_icons.get(group, 0)) < icon_buttons(group).size():
			groups.append(group)
	return groups


## How many of a group's pinned icons the bar shows (its first ones; 0 when folded).
func shown_icons(group: String) -> int:
	return int(_shown_icons.get(group, 0))


## The » menu (shown only while some group is folded into it).
func more_menu() -> MenuButton:
	return _more


## The icon buttons of a group's pinned tools, in order (those past shown_icons() are hidden).
func icon_buttons(group: String) -> Array[Button]:
	var buttons: Array[Button] = []
	if _rows.has(group):
		for child in (_rows[group] as Node).get_children():
			if child is Button and not child.is_queued_for_deletion():
				buttons.append(child)
	return buttons


## The right-click menu of an icon on the bar (Unpin from Toolbar, Move Left, Move Right).
func icon_menu() -> PopupMenu:
	return _icon_menu


func part_label() -> Label:
	return _part_label


## The ids of the tools pinned to a group's block (in the current workspace unless given).
func pinned(group: String, in_workspace := "") -> Array[String]:
	var space := in_workspace if in_workspace != "" else workspace
	var saved: Variant = null
	if _pins.get(space) is Dictionary:
		saved = (_pins[space] as Dictionary).get(group)
	if not saved is Array:
		return CATALOG.default_pins(space, group)
	var ids: Array[String] = []
	for id in saved:
		# Ids that no longer name a tool of this group are skipped.
		var tool := CATALOG.find(str(id))
		if not tool.is_empty() and tool.workspace == space and tool.group == group and not ids.has(tool.id):
			ids.append(tool.id)
	return ids


## Pins a tool to its group's block (at the end) or unpins it.
func pin(id: String, on: bool) -> void:
	var tool := CATALOG.find(id)
	if tool.is_empty():
		return
	var ids := pinned(tool.group, tool.workspace)
	if ids.has(id) == on:
		return
	if on:
		ids.append(id)
	else:
		ids.erase(id)
	_store_pins(tool.workspace, tool.group, ids)


## Moves a pinned tool one place left (step -1) or right (step 1) in its block.
func move_pin(id: String, step: int) -> void:
	var tool := CATALOG.find(id)
	if tool.is_empty():
		return
	var ids := pinned(tool.group, tool.workspace)
	var at := ids.find(id)
	var to := at + step
	if at < 0 or to < 0 or to >= ids.size():
		return
	ids[at] = ids[to]
	ids[to] = id
	_store_pins(tool.workspace, tool.group, ids)


## Puts back the current workspace's default pins.
func reset_pins() -> void:
	if _pins.has(workspace):
		_pins.erase(workspace)
		_write_pins()
	_rebuild_rows()


## A tool's icon at px pixels in the given ink: its workspace's own SVG, the shared SVG, its
## editor icon, or a generic glyph (cached: a second call reads no file).
static func tool_icon(tool: Dictionary, px: float, ink := DARK_THEME_INK) -> Texture2D:
	var name := str(tool.get("name", ""))
	var space := str(tool.get("workspace", ""))
	var key := "%s|%s" % [space, name]
	var cache_key := "tool:%s#%d#%s" % [key, roundi(px), ink.to_html()]
	if _icon_cache.has(cache_key):
		return _icon_cache[cache_key]
	if not _icon_files.has(key):
		var file := CATALOG.slug(name) + ".svg"
		_icon_files[key] = ""
		for path in [ICON_DIR + CATALOG.slug(space) + "/" + file, ICON_DIR + file]:
			if FileAccess.file_exists(path):
				_icon_files[key] = path
				break
	var texture: Texture2D = null
	if _icon_files[key] != "":
		texture = svg_icon(FileAccess.get_file_as_string(_icon_files[key]), px, ink)
	if texture == null:
		texture = _editor_icon(str(tool.get("icon", "")))
	if texture == null:
		texture = svg_icon(_GENERIC_SVG, px, ink, "generic")
	_icon_cache[cache_key] = texture
	return texture


## An SVG file's icon (cached by path, size and ink); null when the file is missing.
static func file_icon(path: String, px: float, ink: Color) -> Texture2D:
	var cache_key := "file:%s#%d#%s" % [path, roundi(px), ink.to_html()]
	if not _icon_cache.has(cache_key):
		_icon_cache[cache_key] = svg_icon(FileAccess.get_file_as_string(path), px, ink) if FileAccess.file_exists(path) else null
	return _icon_cache[cache_key]


## Every icon loads here: an SVG drawn px wide (from its own width), its neutral SVG_INK swapped
## for ink (and, under a dark ink, its accents for LIGHT_ACCENTS), cached by key (when given),
## size and ink.
static func svg_icon(svg: String, px: float, ink: Color, key := "") -> Texture2D:
	var cache_key := "%s#%d#%s" % [key, roundi(px), ink.to_html()]
	if key != "" and _icon_cache.has(cache_key):
		return _icon_cache[cache_key]
	var base := 24.0
	var width_at := svg.find(" width=\"")
	if width_at >= 0:
		base = maxf(1.0, svg.substr(width_at + 8, 8).to_float())
	var text := svg
	if ink.get_luminance() < 0.5:
		for accent: String in LIGHT_ACCENTS:
			text = text.replace(accent, LIGHT_ACCENTS[accent]).replace(accent.to_upper(), LIGHT_ACCENTS[accent])
	var ink_text := "#" + ink.to_html(false)
	text = text.replace(SVG_INK, ink_text).replace(SVG_INK.to_upper(), ink_text)
	var image := Image.new()
	if text == "" or image.load_svg_from_string(text, px / base) != OK or image.is_empty():
		return null
	var texture := ImageTexture.create_from_image(image)
	if key != "":
		_icon_cache[cache_key] = texture
	return texture


func _icon(tool: Dictionary, px: float) -> Texture2D:
	return tool_icon(tool, px, ink_color)


func _rebuild_groups() -> void:
	_rebuild_queued = false
	if not is_inside_tree():
		return
	build_count += 1
	for group in _menus:
		for node: Variant in [_menus.get(group), _rows.get(group), _lines.get(group)]:
			if node is Control:
				_menu_area.remove_child(node)
				node.queue_free()
	_menus.clear()
	_rows.clear()
	_lines.clear()
	_shown_icons.clear()
	var s := _scale()
	var colors := bar_colors()
	_styles = _make_styles(s, colors)
	var caret := svg_icon(_CARET_SVG, 10.0 * s, ink_color, "caret")
	_built_font_size = _font_size()
	var line_style := StyleBoxLine.new()
	line_style.vertical = true
	line_style.color = colors.line
	line_style.thickness = maxi(1, roundi(s))
	for group in CATALOG.groups(workspace):
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", roundi(ICON_GAP * s))
		_menu_area.add_child(row)
		var menu := MenuButton.new()
		menu.text = str(group).to_upper()
		menu.tooltip_text = "Every %s tool" % str(group).to_lower()
		menu.flat = true
		menu.switch_on_hover = true
		# The workspace handles tool keys itself; the menus only show them.
		menu.set_disable_shortcuts(true)
		# A group of one tool has no family to show: no caret.
		if CATALOG.tools_in(workspace, group).size() > 1:
			menu.icon = caret
		menu.icon_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		menu.add_theme_constant_override("h_separation", roundi(3.0 * s))
		menu.add_theme_font_size_override("font_size", _built_font_size)
		for state in ["font_color", "font_focus_color", "font_disabled_color"]:
			menu.add_theme_color_override(state, colors.group)
		for state in ["font_hover_color", "font_pressed_color", "font_hover_pressed_color"]:
			menu.add_theme_color_override(state, colors.group_hover)
		_fill_group(menu.get_popup(), group)
		_menu_area.add_child(menu)
		var line := VSeparator.new()
		line.mouse_filter = Control.MOUSE_FILTER_IGNORE
		line.add_theme_stylebox_override("separator", line_style)
		_menu_area.add_child(line)
		_menus[group] = menu
		_rows[group] = row
		_lines[group] = line
	_part_label.add_theme_color_override("font_color", colors.part_name)
	_update_area_minimum()
	_rebuild_rows()


## The area's minimum: room for » and the part's name at its smallest, and one block's height.
func _update_area_minimum() -> void:
	var s := _scale()
	var label_height := 0.0
	for group in _menus:
		label_height = maxf(label_height, (_menus[group] as Control).get_combined_minimum_size().y)
	var more := _more.get_combined_minimum_size()
	var wanted := Vector2(
		ceilf(more.x + BLOCK_GAP * s + PART_LABEL_MIN * s),
		ceilf(maxf(_top_pad(s) + roundf(BUTTON_SIZE * s) + label_height + s, more.y)))
	if _menu_area.custom_minimum_size != wanted:
		_menu_area.custom_minimum_size = wanted


func _font_size() -> int:
	return maxi(8, roundi(get_theme_font_size("font_size", "Button") * 0.8))


## Remakes the icon buttons of the current workspace's pinned tools.
func _rebuild_rows() -> void:
	if not is_inside_tree():
		return
	for group in _rows:
		var row: HBoxContainer = _rows[group]
		for child in row.get_children():
			row.remove_child(child)
			child.queue_free()
		for id in pinned(group):
			row.add_child(_icon_button(CATALOG.find(id)))
	_queue_fit()


func _icon_button(tool: Dictionary) -> Button:
	var s := _scale()
	var button := Button.new()
	button.focus_mode = Control.FOCUS_NONE
	button.icon = _icon(tool, BAR_ICON_SIZE * s)
	button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	button.custom_minimum_size = Vector2.ONE * roundf(BUTTON_SIZE * s)
	for state in _styles:
		button.add_theme_stylebox_override(state, _styles[state])
	button.add_theme_color_override("icon_disabled_color", bar_colors().icon_disabled)
	button.disabled = not CATALOG.is_enabled(tool)
	button.tooltip_text = _tip(tool)
	button.set_meta("tool_id", tool.id)
	button.pressed.connect(func() -> void: tool_activated.emit(tool))
	button.gui_input.connect(func(event: InputEvent) -> void:
		var click := event as InputEventMouseButton
		if click != null and click.pressed and click.button_index == MOUSE_BUTTON_RIGHT:
			_open_icon_menu(tool.id, button.get_screen_position() + click.position))
	return button


func _open_icon_menu(id: String, at: Vector2) -> void:
	var tool := CATALOG.find(id)
	var ids := pinned(tool.group, tool.workspace)
	var index := ids.find(id)
	_icon_menu_tool = id
	_icon_menu.set_item_disabled(_icon_menu.get_item_index(1), index <= 0)
	_icon_menu.set_item_disabled(_icon_menu.get_item_index(2), index < 0 or index >= ids.size() - 1)
	_icon_menu.reset_size()
	_icon_menu.popup(Rect2i(Vector2i(at), Vector2i.ZERO))


## Lists a group's tools in popup (a dropdown on the bar, or one under the » menu): families in
## submenus, then the Select options, Pin to Toolbar (filled as it opens) and Reset Toolbar.
func _fill_group(popup: PopupMenu, group: String) -> void:
	var px := MENU_ICON_SIZE * _scale()
	var tools := CATALOG.tools_in(workspace, group)
	var ids := {}
	for i in tools.size():
		ids[tools[i].id] = i
	var menus: Array[PopupMenu] = [popup]
	var submenu_id := SUBMENU_ID
	for entry in CATALOG.menu_entries(workspace, group):
		if entry.has("tools"):
			var folder := PopupMenu.new()
			for tool in entry.tools:
				_add_tool_item(folder, tool, ids[tool.id], px)
			popup.add_submenu_node_item(entry.folder, folder, submenu_id)
			popup.set_item_icon(popup.get_item_index(submenu_id), _icon(entry.tools[0], px))
			submenu_id += 1
			menus.append(folder)
		else:
			_add_tool_item(popup, entry.tool, ids[entry.tool.id], px)
	for menu in menus:
		_watch_tool_menu(menu)
	if group == "Select":
		_add_select_options(popup)
	popup.add_separator()
	var pins := PopupMenu.new()
	pins.about_to_popup.connect(_fill_pin_menu.bind(pins, workspace, group))
	popup.add_submenu_node_item("Pin to Toolbar", pins, PIN_MENU_ID)
	popup.set_item_tooltip(popup.get_item_index(PIN_MENU_ID), "Choose the %s tools shown as icons on the bar." % str(group).to_upper())
	popup.add_item("Reset Toolbar", RESET_ID)
	popup.set_item_tooltip(popup.get_item_index(RESET_ID), "Put back the %s workspace's default icons." % workspace)
	popup.id_pressed.connect(func(id: int) -> void:
		if id == RESET_ID:
			_pick(popup, reset_pins))


func _add_tool_item(popup: PopupMenu, tool: Dictionary, id: int, px: float) -> void:
	popup.add_icon_item(_icon(tool, px), tool.name, id)
	var index := popup.get_item_index(id)
	popup.set_item_metadata(index, tool)
	if tool.shortcut != "":
		popup.set_item_accelerator(index, OS.find_keycode_from_string(tool.shortcut))
	if not CATALOG.is_enabled(tool):
		popup.set_item_disabled(index, true)
		popup.set_item_tooltip(index, _tip(tool))


## Runs a dropdown's tools, and pins the one under the mouse on a right-click.
func _watch_tool_menu(menu: PopupMenu) -> void:
	menu.id_pressed.connect(func(id: int) -> void:
		var tool: Variant = menu.get_item_metadata(menu.get_item_index(id))
		if tool is Dictionary and tool.has("id"):
			_pick(menu, func() -> void: tool_activated.emit(tool)))
	menu.window_input.connect(_on_menu_input.bind(menu))
	menu.about_to_popup.connect(func() -> void:
		_mouse_menus.erase(menu.get_instance_id())
		_show_pin_hints(menu))


## A dropdown's pick runs at the end of the frame, unless the release that made it was of another
## button than the left: a PopupMenu also runs an item on the release of any button held when it
## opened (a submenu opened while the right button was down), and a right-click must never run
## a tool. (The menu handles the event before its window_input signal reports it.)
func _pick(menu: PopupMenu, action: Callable) -> void:
	var key := menu.get_instance_id()
	_picks[key] = action
	_run_pick.call_deferred(key)


func _run_pick(key: int) -> void:
	var action: Callable = _picks.get(key, Callable())
	_picks.erase(key)
	if action.is_valid():
		action.call()


## A right-click on a tool in a dropdown pins it to the bar or unpins it, and the release of a
## button other than the left drops the menu's pick. The item pinned is the one the mouse last
## moved onto, not one reached with the keys or scrolled under the mouse.
func _on_menu_input(event: InputEvent, menu: PopupMenu) -> void:
	var key := menu.get_instance_id()
	var click := event as InputEventMouseButton
	if event is InputEventMouseMotion:
		_mouse_menus[key] = true
	elif event is InputEventKey or event is InputEventJoypadButton:
		_mouse_menus.erase(key)
	elif click == null:
		return
	elif click.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN, MOUSE_BUTTON_WHEEL_LEFT, MOUSE_BUTTON_WHEEL_RIGHT]:
		_mouse_menus.erase(key)
	elif not click.pressed and click.button_index != MOUSE_BUTTON_LEFT:
		_picks.erase(key)
	elif click.pressed and click.button_index == MOUSE_BUTTON_RIGHT and _mouse_menus.has(key):
		var index := menu.get_focused_item()
		var tool: Variant = menu.get_item_metadata(index) if index >= 0 else null
		if tool is Dictionary and tool.has("id"):
			pin(tool.id, not pinned(tool.group, tool.workspace).has(tool.id))
			_show_pin_hints(menu)


func _show_pin_hints(menu: PopupMenu) -> void:
	for i in menu.item_count:
		var tool: Variant = menu.get_item_metadata(i)
		if tool is Dictionary and tool.has("id") and not menu.is_item_disabled(i):
			var on := pinned(tool.group, tool.workspace).has(tool.id)
			menu.set_item_tooltip(i, "Right-click to %s." % ("unpin it from the toolbar" if on else "pin it to the toolbar"))


## Pin to Toolbar, filled the first time it opens: a check item per tool of the group (families
## nested as in the dropdown); ticking one pins or unpins it at once and keeps the menu open.
func _fill_pin_menu(root: PopupMenu, space: String, group: String) -> void:
	if root.item_count > 0:
		_show_pin_checks(root)
		return
	var px := MENU_ICON_SIZE * _scale()
	var tools := CATALOG.tools_in(space, group)
	var ids := {}
	for i in tools.size():
		ids[tools[i].id] = i
	var menus: Array[PopupMenu] = [root]
	var submenu_id := SUBMENU_ID
	for entry in CATALOG.menu_entries(space, group):
		if entry.has("tools"):
			var folder := PopupMenu.new()
			for tool in entry.tools:
				_add_pin_item(folder, tool, ids[tool.id], px)
			root.add_submenu_node_item(entry.folder, folder, submenu_id)
			submenu_id += 1
			menus.append(folder)
		else:
			_add_pin_item(root, entry.tool, ids[entry.tool.id], px)
	for menu in menus:
		menu.hide_on_checkable_item_selection = false
		menu.id_pressed.connect(func(id: int) -> void:
			var index := menu.get_item_index(id)
			var tool_id: Variant = menu.get_item_metadata(index)
			if tool_id is String:
				pin(tool_id, not menu.is_item_checked(index))
				_show_pin_checks(menu))
		if menu != root:
			menu.about_to_popup.connect(_show_pin_checks.bind(menu))
		_show_pin_checks(menu)


func _add_pin_item(menu: PopupMenu, tool: Dictionary, id: int, px: float) -> void:
	menu.add_icon_check_item(_icon(tool, px), tool.name, id)
	menu.set_item_metadata(menu.get_item_index(id), tool.id)


func _show_pin_checks(menu: PopupMenu) -> void:
	for i in menu.item_count:
		var tool_id: Variant = menu.get_item_metadata(i)
		if tool_id is String:
			var tool := CATALOG.find(tool_id)
			menu.set_item_checked(i, pinned(tool.group, tool.workspace).has(tool_id))


func _queue_fit() -> void:
	if not _fit_queued:
		_fit_queued = true
		_fit_menus.call_deferred()


## Lays out the area: the blocks from its left, in order (as plan_blocks() shares out the room),
## » after them when some are folded, and the part's name at its right end with what's left.
func _fit_menus() -> void:
	_fit_queued = false
	if not is_inside_tree():
		return
	var s := _scale()
	var room := _menu_area.size.x
	var height := _menu_area.size.y
	var gap := roundf(BLOCK_GAP * s)
	var button := roundf(BUTTON_SIZE * s)
	var icon_gap := roundf(ICON_GAP * s)
	var groups: Array = _menus.keys()
	var count := groups.size()
	var bare := PackedFloat32Array()
	var pins := PackedInt32Array()
	for group in groups:
		bare.append((_menus[group] as Control).get_combined_minimum_size().x)
		pins.append(icon_buttons(group).size())
	var line_width := maxf(1.0, (_lines[groups[0]] as Control).get_combined_minimum_size().x) if count > 0 else 1.0
	var step := gap * 2.0 + line_width
	var more_width := _more.get_combined_minimum_size().x
	var name_full := _part_text_width()
	var name_min := minf(name_full, PART_LABEL_MIN * s)
	var tail := gap + name_min if name_min > 0.0 else 0.0
	var plan := plan_blocks(bare, pins, button, icon_gap, step, more_width, room - tail, PRIMARY_BLOCKS)
	var shown: int = plan.shown
	var icons: PackedInt32Array = plan.icons
	_folded.clear()
	_shown_icons.clear()
	var top := _top_pad(s)
	var x := 0.0
	# A final Finish block (Finish Form, Finish Sketch) sits at the bar's right end, beside the
	# part's name, when every block fits.
	var finish_last := count > 0 and str(groups[count - 1]) == "Finish" and shown == count
	for i in count:
		var group: String = groups[i]
		var menu: MenuButton = _menus[group]
		var row: Control = _rows[group]
		var line: Control = _lines[group]
		menu.visible = i < shown
		if not menu.visible:
			row.visible = false
			line.visible = false
			_folded.append(group)
			continue
		_shown_icons[group] = icons[i]
		var buttons := icon_buttons(group)
		for k in buttons.size():
			if buttons[k].visible != (k < icons[i]):
				buttons[k].visible = k < icons[i]
		var row_w := row_width(icons[i], button, icon_gap)
		var width := maxf(bare[i], row_w)
		if finish_last and i == count - 1:
			x = maxf(x, room - (gap + name_full if name_full > 0.0 else 0.0) - width)
		row.visible = icons[i] > 0
		if row.visible:
			row.position = Vector2(roundf(x + (width - row_w) * 0.5), top)
			row.size = Vector2(row_w, button)
		var menu_size := menu.get_combined_minimum_size()
		menu.position = Vector2(roundf(x + (width - menu_size.x) * 0.5), height - menu_size.y - roundf(s))
		menu.size = menu_size
		x += width
		line.visible = i < count - 1
		if line.visible:
			line.position = Vector2(x + gap, top)
			line.size = Vector2(line_width, height - top * 2.0)
			x += step
	_more.visible = shown < count
	if _more.visible:
		var more_size := _more.get_combined_minimum_size()
		_more.position = Vector2(x, roundf((height - more_size.y) * 0.5))
		_more.size = more_size
		x += more_size.x
	var label := clampf(room - x - gap, name_min, name_full)
	_part_label.position = Vector2(room - label, 0.0)
	_part_label.size = Vector2(label, height)


## Shares out room (past the part's name at its smallest) among blocks of name widths bare and
## pins icons each: {"shown": how many blocks from the left stay on the bar (the rest fold into
## »), "icons": how many of its icons each shows}. A block keeps the icons that fit under its
## name. When everything doesn't fit, the blocks past the first `primary` drop their other
## icons and then fold from the right; only once they're all folded do the primary blocks do the
## same. Icons then come back from the left while they fit.
static func plan_blocks(bare: PackedFloat32Array, pins: PackedInt32Array, button: float, icon_gap: float, step: float, more_width: float, room: float, primary: int) -> Dictionary:
	var count := bare.size()
	var icons := pins.duplicate()
	var least := PackedInt32Array()
	for i in count:
		least.append(mini(pins[i], maxi(0, floori((bare[i] + icon_gap) / (button + icon_gap)))))
	var shown := count
	var sizes := [bare, button, icon_gap, step, more_width]
	if _plan_width(sizes, icons, shown) > room:
		for i in range(mini(primary, count), count):
			icons[i] = least[i]
		while shown > primary and _plan_width(sizes, icons, shown) > room:
			shown -= 1
		if _plan_width(sizes, icons, shown) > room:
			icons = least.duplicate()
			while shown > 0 and _plan_width(sizes, icons, shown) > room:
				shown -= 1
		# (A block that can't take its next icon back leaves the blocks right of it at their least.)
		for i in shown:
			var room_left := true
			while icons[i] < pins[i]:
				icons[i] += 1
				if _plan_width(sizes, icons, shown) > room:
					icons[i] -= 1
					room_left = false
					break
			if not room_left:
				break
	for i in range(shown, count):
		icons[i] = 0
	return {"shown": shown, "icons": icons}


## The blocks' width with the first `shown` on the bar showing icons[i] icons each, and the » menu
## if any are folded. sizes: [bare, button, icon_gap, step, more_width].
static func _plan_width(sizes: Array, icons: PackedInt32Array, shown: int) -> float:
	var bare: PackedFloat32Array = sizes[0]
	var width := 0.0
	for i in shown:
		width += maxf(bare[i], row_width(icons[i], sizes[1], sizes[2])) + (float(sizes[3]) if i > 0 else 0.0)
	if shown < bare.size():
		width += float(sizes[4]) + (float(sizes[3]) if shown > 0 else 0.0)
	return width


## How wide a row of count icon buttons is.
static func row_width(count: int, button: float, icon_gap: float) -> float:
	return count * button + maxi(count - 1, 0) * icon_gap


## The part's name's full width in the label's own font (as laid out, in the editor's theme).
func _part_text_width() -> float:
	if _part_label.text == "":
		return 0.0
	var font := _part_label.get_theme_font("font")
	if font == null:
		return 0.0
	var style := _part_label.get_theme_stylebox("normal")
	var text := font.get_string_size(_part_label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, _part_label.get_theme_font_size("font_size")).x
	return ceilf(text + (style.get_minimum_size().x if style != null else 0.0)) + 2.0


## The » menu: one submenu per folded group, built as it opens.
func _fill_more() -> void:
	var popup := _more.get_popup()
	popup.clear(true)
	for i in _folded.size():
		var submenu := PopupMenu.new()
		_fill_group(submenu, _folded[i])
		popup.add_submenu_node_item(_folded[i].to_upper(), submenu, SUBMENU_ID + i)


func _add_select_options(popup: PopupMenu) -> void:
	popup.add_separator("Options")
	var filter_menu := PopupMenu.new()
	var kinds := ["body", "face", "edge", "vertex"]
	for i in kinds.size():
		filter_menu.add_check_item(str(kinds[i]).capitalize() + "s", i)
	filter_menu.id_pressed.connect(func(id: int) -> void:
		var kind: String = kinds[id]
		filters[kind] = not filters.get(kind, true)
		filter_menu.set_item_checked(id, filters[kind])
		select_option_changed.emit("filter:" + kind, filters[kind]))
	popup.add_submenu_node_item("Selection Filters", filter_menu, SUBMENU_ID + 100)

	var priority_menu := PopupMenu.new()
	var priorities := [["default", "Default"], ["body", "Select Body Priority"], ["face", "Select Face Priority"], ["edge", "Select Edge Priority"]]
	for i in priorities.size():
		priority_menu.add_radio_check_item(priorities[i][1], i)
	priority_menu.id_pressed.connect(func(id: int) -> void:
		priority = priorities[id][0]
		for j in priorities.size():
			priority_menu.set_item_checked(j, j == id)
		select_option_changed.emit("priority", priority))
	popup.add_submenu_node_item("Selection Priority", priority_menu, SUBMENU_ID + 101)

	popup.add_check_item("Select Through", SELECT_THROUGH_ID)
	popup.id_pressed.connect(func(id: int) -> void:
		if id == SELECT_THROUGH_ID:
			select_through = not select_through
			popup.set_item_checked(popup.get_item_index(SELECT_THROUGH_ID), select_through)
			select_option_changed.emit("select_through", select_through))

	# The checks show the current state each time (the same options can sit in a menu on the bar
	# and under the » menu).
	var show_state := func() -> void:
		for i in kinds.size():
			filter_menu.set_item_checked(i, filters.get(kinds[i], true))
		for i in priorities.size():
			priority_menu.set_item_checked(i, priorities[i][0] == priority)
		popup.set_item_checked(popup.get_item_index(SELECT_THROUGH_ID), select_through)
	show_state.call()
	popup.about_to_popup.connect(show_state)
	filter_menu.about_to_popup.connect(show_state)
	priority_menu.about_to_popup.connect(show_state)

	if not selection_sets.is_empty():
		var sets_menu := PopupMenu.new()
		for i in selection_sets.size():
			sets_menu.add_item(selection_sets[i], i)
		sets_menu.id_pressed.connect(func(id: int) -> void: select_option_changed.emit("selection_set", selection_sets[id]))
		popup.add_submenu_node_item("Selection Sets", sets_menu, SUBMENU_ID + 102)


func _store_pins(space: String, group: String, ids: Array[String]) -> void:
	if not _pins.get(space) is Dictionary:
		_pins[space] = {}
	_pins[space][group] = Array(ids)
	_write_pins()
	if space == workspace:
		_rebuild_rows()


func _read_pins() -> Dictionary:
	var saved: Variant = {}
	if pin_store is Dictionary:
		saved = (pin_store as Dictionary).get(PINS_KEY, {})
	elif Engine.is_editor_hint():
		saved = EditorInterface.get_editor_settings().get_project_metadata(PINS_SECTION, PINS_KEY, {})
	else:
		saved = _memory_pins
	return (saved as Dictionary).duplicate(true) if saved is Dictionary else {}


func _write_pins() -> void:
	var copy := _pins.duplicate(true)
	if pin_store is Dictionary:
		pin_store[PINS_KEY] = copy
	elif Engine.is_editor_hint():
		EditorInterface.get_editor_settings().set_project_metadata(PINS_SECTION, PINS_KEY, copy)
	else:
		_memory_pins = copy


func _tip(tool: Dictionary) -> String:
	if not CATALOG.is_enabled(tool):
		if int(tool.phase) <= CATALOG.IMPLEMENTED_PHASE:
			# A tool of the current phase whose registry entry hasn't landed yet.
			return "%s isn't wired yet (Phase %d of Holo Forge)." % [tool.name, tool.phase]
		return "%s arrives in Phase %d of Holo Forge." % [tool.name, tool.phase]
	return "%s (%s)" % [tool.name, tool.shortcut] if tool.shortcut != "" else str(tool.name)


## The icon buttons' looks: no frame until hovered, a soft rounded one then.
static func _make_styles(s: float, colors: Dictionary) -> Dictionary:
	var hover := StyleBoxFlat.new()
	hover.bg_color = colors.hover
	hover.set_corner_radius_all(roundi(4.0 * s))
	var pressed := hover.duplicate() as StyleBoxFlat
	pressed.bg_color = colors.pressed
	var empty := StyleBoxEmpty.new()
	return {"normal": empty, "hover": hover, "pressed": pressed, "hover_pressed": pressed, "disabled": empty, "focus": empty}


static func _top_pad(s: float) -> float:
	return roundf(2.0 * s)


static func _scale() -> float:
	return EditorInterface.get_editor_scale() if Engine.is_editor_hint() else 1.0


## The ink for the editor's theme: dark ink when the editor is light (light ink elsewhere).
static func _theme_ink() -> Color:
	if not Engine.is_editor_hint():
		return DARK_THEME_INK
	var theme := EditorInterface.get_editor_theme()
	if theme != null and theme.has_constant("dark_theme", "Editor"):
		return DARK_THEME_INK if theme.get_constant("dark_theme", "Editor") != 0 else LIGHT_THEME_INK
	var base: Variant = EditorInterface.get_editor_settings().get_setting("interface/theme/base_color")
	return LIGHT_THEME_INK if base is Color and (base as Color).get_luminance() > 0.5 else DARK_THEME_INK


static func _editor_icon(name: String) -> Texture2D:
	if name == "" or not Engine.is_editor_hint():
		return null
	var theme := EditorInterface.get_editor_theme()
	return theme.get_icon(name, "EditorIcons") if theme != null and theme.has_icon(name, "EditorIcons") else null
