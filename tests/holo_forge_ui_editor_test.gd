@tool
extends RefCounted
## The Forge toolbar inside the real editor (never saves the test scene or changes settings; its
## pins are kept in memory): on the Forge tab, at the main screen's real width and the editor's
## scale, the toolbar fits in every workspace and in sketch mode, the part's name isn't clipped
## when there's room, and a CREATE dropdown and one of its folders open. With
## --holo-forge-screenshots=<dir> in a windowed editor it also saves PNGs of the editor window:
## each workspace's toolbar, sketch mode with its palette, the CREATE dropdown with a folder open,
## the » menu on a narrow main screen, and the Solid, Surface and Sketch bars at 1480 and 900 px.
## Then Dark and Light (on a store of its own): the view, the toolbar's ink and the tab's controls
## switch and the bar still fits, with shots of every workspace's bar, sketch mode and an open
## dropdown in both modes (theme_<mode>_*.png), sketching over a box with dimensions drawn in the
## editor's font (its Ø, and its ƒ marker or the plain f it falls back to). The editor draws only when
## something changes, so each shot asks for a redraw before it waits for the drawn frame; a menu
## that closes before its shot fails the test.
##
## godot --headless --path . --editor -- --holo-forge-ui-editor-test
## godot --path . --editor -- --holo-forge-ui-editor-test --holo-forge-screenshots=C:/shots

const CATALOG := preload("res://addons/holo_forge/tools/catalog.gd")
const SKETCH := preload("res://addons/holo_forge/core/sketch/sketch_data.gd")
const FORGE_THEME := preload("res://addons/holo_forge/ui/forge_theme.gd")
const SHOTS_ARG := "--holo-forge-screenshots="

var failures: Array[String] = []
var _tree: SceneTree
var _shots := ""


func check(ok: bool, detail: String) -> void:
	if not ok:
		failures.append(detail)
		push_error(detail)
		print("FAIL: ", detail)


func run(plugin: EditorPlugin) -> void:
	_tree = plugin.get_tree()
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with(SHOTS_ARG):
			_shots = arg.trim_prefix(SHOTS_ARG)
	if DisplayServer.get_name() == "headless":
		_shots = ""
	# A screenshot run saves some 40 PNGs: it gets longer.
	_tree.create_timer(900.0 if _shots != "" else 300.0).timeout.connect(func() -> void:
		print("FAIL Holo Forge UI EDITOR: timed out ", failures)
		_tree.quit(1))
	if _shots != "":
		DirAccess.make_dir_recursive_absolute(_shots)
	var stable := 0
	for i in 900:
		await _tree.process_frame
		var opened := EditorInterface.get_edited_scene_root()
		if opened != null and opened.name == "ForgeEditorTest" and opened.is_inside_tree():
			stable += 1
			if stable >= 60:
				break
		else:
			stable = 0
			if i % 30 == 0:
				EditorInterface.open_scene_from_path("res://tests/holo_forge/forge_editor_test.tscn")
	EditorInterface.set_main_screen_editor("Forge")
	await _frames(10)
	var ws = plugin.get("workspace")
	check(ws != null and ws.visible, "The Forge main-screen tab should open.")
	if ws == null:
		_finish()
		return
	var bar: HBoxContainer = ws.toolbar
	# Defaults, and never the user's saved pins.
	bar.pin_store = {}
	var part: Node3D = ws.add_part_to_scene()
	await _frames(4)
	check(part != null and ws.part == part, "A part should be added to edit.")
	var scale := EditorInterface.get_editor_scale()
	var main := EditorInterface.get_editor_main_screen()
	print("Forge UI: main screen %s, editor scale %.2f, display %s" % [main.size, scale, DisplayServer.get_name()])

	# Every workspace through the switcher, as a user picks it.
	var switcher: OptionButton = bar.get_child(0)
	for i in CATALOG.WORKSPACES.size():
		var workspace: String = CATALOG.WORKSPACES[i]
		switcher.select(i)
		switcher.item_selected.emit(i)
		await _frames(4)
		check(ws.workspace == workspace and bar.workspace == workspace, "Picking %s should switch the workspace." % workspace)
		_check_fits(bar, workspace)
		await _shot("toolbar_%s.png" % CATALOG.slug(workspace))
	switcher.select(0)
	switcher.item_selected.emit(0)
	await _frames(4)
	var first: Array[Button] = bar.icon_buttons("Create")
	check(not first.is_empty() and first[0].custom_minimum_size.x == roundf(28.0 * scale), "The icon buttons should be 28 px at editor scale %.2f (%s)." % [scale, str(first[0].custom_minimum_size) if not first.is_empty() else "none"])
	check(not first.is_empty() and first[0].icon != null, "Icon buttons should have icons.")

	# The part's name: the user's own case ("ForgePart" cut to "ForgeP") and a longer one.
	for text in ["ForgePart", "Hoverboard Deck v003 (board body)"]:
		bar.set_part_name(text)
		await _frames(3)
		_check_name(bar, text)

	# Sketch mode: the Sketch toolbar with the palette.
	var feature: Resource = ws.create_sketch(SKETCH.ORIGIN_PLANES.xz, "xz")
	await _frames(6)
	check(feature != null and ws.sketch_editor.active and bar.workspace == CATALOG.SKETCH_WORKSPACE, "Create Sketch should show the Sketch toolbar.")
	_check_fits(bar, "Sketch")
	_check_name(bar, bar.part_label().text)
	await _shot("sketch_mode.png")
	if _shots != "":
		for width in [1480, 900]:
			await _shot_at_width(bar, width, "toolbar_sketch_%d.png" % width)
	ws.run_action("finish_sketch")
	await _frames(4)
	check(bar.workspace == "Solid", "Finish Sketch should put back the Solid toolbar (%s)." % bar.workspace)
	if _shots != "":
		for workspace in ["Solid", "Surface"]:
			switcher.select(CATALOG.WORKSPACES.find(workspace))
			switcher.item_selected.emit(CATALOG.WORKSPACES.find(workspace))
			await _frames(4)
			for width in [1480, 900]:
				await _shot_at_width(bar, width, "toolbar_%s_%d.png" % [CATALOG.slug(workspace), width])
		switcher.select(0)
		switcher.item_selected.emit(0)
		await _frames(4)

	# A CREATE dropdown, then its Pattern folder.
	var create: MenuButton = bar.group_menu("Create")
	var popup: PopupMenu = await _open_menu(create)
	check(popup.visible, "The CREATE dropdown should open.")
	var folder := -1
	for i in popup.item_count:
		if popup.get_item_text(i) == "Pattern":
			folder = i
	check(folder >= 0 and popup.get_item_submenu_node(folder) != null, "CREATE should have a Pattern folder.")
	if folder >= 0:
		var sub := popup.get_item_submenu_node(folder)
		await _open_folder(popup, folder)
		check(sub.visible and sub.item_count == 3, "The Pattern folder should open with its 3 tools (visible %s)." % sub.visible)
		await _shot("create_dropdown_folder.png", [popup, sub])
		# A dropdown hidden by code with its folder open leaves the folder's window behind, and the
		# next popup to open closes at once: close the folder first, as the user's click would.
		sub.hide()
	popup.hide()
	await _frames(3)

	# A narrow main screen folds blocks into »; the » menu opens with their submenus.
	bar.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	bar.custom_minimum_size.x = 640.0 * scale
	await _frames(6)
	check(not bar.folded_groups().is_empty() and bar.more_menu().visible and bar.size.x <= 640.0 * scale + 0.5,
		"At 640 px the bar should fold blocks into » (folded %s, width %d)." % [bar.folded_groups(), int(bar.size.x)])
	var more: MenuButton = bar.more_menu()
	var more_popup: PopupMenu = await _open_menu(more)
	check(more_popup.visible and more_popup.item_count == bar.folded_groups().size(), "» should list the %d folded groups (%d)." % [bar.folded_groups().size(), more_popup.item_count])
	if more_popup.item_count > 0:
		var sub := more_popup.get_item_submenu_node(0)
		await _open_folder(more_popup, 0)
		check(sub != null and sub.visible, "A folded group's submenu should open from ».")
		await _shot("more_menu_narrow.png", [more_popup, sub])
		if sub != null:
			sub.hide()
	more_popup.hide()
	bar.custom_minimum_size.x = 0.0
	bar.size_flags_horizontal = Control.SIZE_FILL
	await _frames(4)
	await _check_appearance(ws, bar, switcher)
	_finish()


## Dark and Light in the real editor (on a store of the test's own, never the user's): the view,
## the toolbar's ink and, where the editor's theme isn't as dark, the tab's controls change; the
## bar still fits every workspace; shots of each workspace's bar, sketch mode with its palette and
## an open dropdown in both modes.
func _check_appearance(ws: Control, bar: HBoxContainer, switcher: OptionButton) -> void:
	ws.theme_store = {}
	await _frames(2)
	# A box to sketch over (sketching on a face is the usual case; the part is never saved).
	ws.run_tool(CATALOG.find("solid.create.box"))
	ws.accept_command()
	await _frames(4)
	var editor_dark: bool = FORGE_THEME.resolve("editor") == "dark"
	check(ws.theme_mode == "editor" and ws.theme_name == FORGE_THEME.resolve("editor") and ws.timeline.theme == null,
		"Follow Editor should match the editor's theme (%s) with the editor's own controls." % ws.theme_name)
	print("Forge UI: the editor's base colour is %s, so Follow Editor shows %s." % [FORGE_THEME.host_base_color().to_html(false), ws.theme_name])
	for mode in ["dark", "light"]:
		ws.set_theme_mode(mode)
		await _frames(4)
		var p := FORGE_THEME.palette(mode)
		check(ws.theme_name == mode and ws.viewport.background_colors() == [p.view_top, p.view_bottom] and bar.ink_color == p.toolbar_ink,
			"%s: the view and the toolbar's ink should switch." % mode)
		check((ws.timeline.theme != null) == ((mode == "dark") != editor_dark) and bar.theme == ws.timeline.theme,
			"%s: the tab's controls get their own theme only where the editor's isn't as dark." % mode)
		for i in CATALOG.WORKSPACES.size():
			switcher.select(i)
			switcher.item_selected.emit(i)
			await _frames(4)
			_check_fits(bar, "%s (%s)" % [CATALOG.WORKSPACES[i], mode])
			await _shot("theme_%s_toolbar_%s.png" % [mode, CATALOG.slug(CATALOG.WORKSPACES[i])])
		switcher.select(0)
		switcher.item_selected.emit(0)
		await _frames(4)
		# Sketch mode with a little geometry, the palette and a dimension.
		var feature: Resource = ws.create_sketch(SKETCH.ORIGIN_PLANES.xz, "xz")
		await _frames(4)
		var editor: RefCounted = ws.sketch_editor
		check(feature != null and editor.active and editor.palette.get_style().panel == p.panel_style.panel, "%s: the sketch palette should take the palette's look." % mode)
		editor.start_tool("rect_2pt")
		editor.tool_click(Vector2(-0.02, -0.015), {}, {})
		editor.tool_click(Vector2(0.02, 0.015), {}, {})
		editor.start_tool("circle_center")
		editor.tool_click(Vector2(0.045, 0.0), {}, {})
		editor.tool_click(Vector2(0.055, 0.0), {}, {})
		editor.cancel_tool()
		await _frames(4)
		# Dimensions in the editor's own font and scale: two plain lengths and a diameter set by an
		# expression (its marker and the Ø).
		var s: RefCounted = editor.sketch()
		var sides := {}
		for e in s.entities():
			if e.type == "line":
				var a: Vector2 = s.point(int(e.p1))
				var b: Vector2 = s.point(int(e.p2))
				if absf(a.y - b.y) < 1e-6 and a.y < 0.0:
					sides["bottom"] = int(e.id)
				elif absf(a.x - b.x) < 1e-6 and a.x > 0.0:
					sides["right"] = int(e.id)
			elif e.type == "circle":
				sides["circle"] = int(e.id)
		check(sides.size() == 3, "%s: the rectangle's bottom and right side and the circle should be found (%s)." % [mode, sides])
		if sides.size() == 3:
			ws.change("Test: Dimensions", func() -> void:
				var live: RefCounted = editor.sketch()
				var width: int = live.add_constraint("length", [sides.bottom], "40 mm")
				live.constraint(width)["offset"] = Vector2(0.0, -0.016)
				var height: int = live.add_constraint("length", [sides.right], "30 mm")
				live.constraint(height)["offset"] = Vector2(0.013, 0.0)
				var hole: int = live.add_constraint("diameter", [sides.circle], str(live.feature.inputs[live.constraint(width).key].name) + " / 4")
				live.constraint(hole)["offset"] = Vector2(0.004, 0.006))
			ws.viewport.redraw_overlay()
			await _frames(4)
			var marker: String = editor._expression_marker(ws.viewport._overlay)
			var texts := []
			for id in editor._dim_draw_log:
				texts.append(str(editor._dim_draw_log[id].text))
			check(editor._dim_hits.size() == 3 and texts.has("40.00") and texts.has("30.00") and texts.has(marker + "Ø10.00"),
				"%s: the sketch's dimensions should draw (%s)." % [mode, texts])
			check(ws.viewport._overlay.get_theme_default_font().has_char(0xD8), "%s: the editor's font should have Ø." % mode)
			print("Forge UI: the editor's font %s ƒ, so values set by an expression show '%s'." % ["has" if marker == "ƒ " else "lacks", marker.strip_edges()])
		check(ws.viewport.sketch_dimmed, "%s: the bodies should fade while the sketch is open." % mode)
		await _shot("theme_%s_sketch.png" % mode)
		var create: MenuButton = bar.group_menu("Create")
		var popup: PopupMenu = await _open_menu(create)
		var folder := -1
		for i in popup.item_count:
			if popup.get_item_text(i) == "Rectangle":
				folder = i
		if folder >= 0:
			var sub := popup.get_item_submenu_node(folder)
			await _open_folder(popup, folder)
			check(sub.visible, "%s: the Rectangle folder should open." % mode)
			await _shot("theme_%s_dropdown.png" % mode, [popup, sub])
			sub.hide()
		popup.hide()
		await _frames(3)
		ws.run_action("finish_sketch")
		await _frames(4)
	ws.set_theme_mode("editor")
	await _frames(2)


## The bar fits the main screen and everything on it lies inside it.
func _check_fits(bar: HBoxContainer, at: String) -> void:
	var main := EditorInterface.get_editor_main_screen()
	check(bar.size.x <= main.size.x + 0.5, "%s: the toolbar (%d px) should fit the main screen (%d px)." % [at, int(bar.size.x), int(main.size.x)])
	var groups: Array = CATALOG.groups(bar.workspace)
	var shown := []
	for group in groups:
		if bar.group_menu(group) != null and bar.group_menu(group).visible:
			shown.append(group)
	check(shown + bar.folded_groups() == groups, "%s: every group should be on the bar or under » (%s + %s)." % [at, shown, bar.folded_groups()])
	var right_edge := bar.global_position.x + bar.size.x
	for control in bar.find_children("*", "Control", true, false):
		var item := control as Control
		if item.is_visible_in_tree() and item.size.x > 0.0:
			check(item.global_position.x + item.size.x <= right_edge + 0.5, "%s: %s should end inside the toolbar." % [at, item.get_class()])
	print("Forge UI %s: bar %d px of %d, compact %s, folded %s, name %d px" % [at, int(bar.size.x), int(main.size.x), bar.compact_groups(), bar.folded_groups(), int(bar.part_label().size.x)])


## The part's name shows whole when the blocks leave room for it (measured in its own font).
func _check_name(bar: HBoxContainer, text: String) -> void:
	var label: Label = bar.part_label()
	check(label.text == text, "The toolbar should show the part's name %s (%s)." % [text, label.text])
	var font := label.get_theme_font("font")
	var needed := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, label.get_theme_font_size("font_size")).x
	var area: Control = label.get_parent()
	var used := 0.0
	for child in area.get_children():
		if child != label and child is Control and child.visible:
			used = maxf(used, child.position.x + child.size.x)
	var room := area.size.x - used - 6.0
	check(label.size.x >= minf(needed, room) - 0.5, "The part's name '%s' needs %d px and has %d with %d to spare: it shouldn't be cut." % [text, int(needed), int(label.size.x), int(room)])


## Opens a group's dropdown and waits for it to show (once more if something closed it).
func _open_menu(button: MenuButton) -> PopupMenu:
	var popup := button.get_popup()
	for attempt in 2:
		if not popup.visible:
			button.show_popup()
		await _frames(4)
		if popup.visible:
			break
		print("Forge UI: %s's menu closed; opening it again." % button.text)
	return popup


## Opens a dropdown's folder (submenu) at index with the Right key, as a user would.
func _open_folder(popup: PopupMenu, index: int) -> void:
	var sub := popup.get_item_submenu_node(index)
	for attempt in 3:
		if not popup.visible:
			popup.popup()
			await _frames(3)
		popup.set_focused_item(index)
		_send_key(popup, KEY_RIGHT)
		for i in 60:
			await _tree.process_frame
			if sub == null or sub.visible:
				return


## Sends a key to a dropdown (its own window, or the editor's when it's embedded).
func _send_key(popup: Window, key: Key) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = key
		event.physical_keycode = key
		event.pressed = pressed
		if not popup.is_embedded():
			event.window_id = popup.get_window_id()
		Input.parse_input_event(event)


func _frames(count: int) -> void:
	for i in count:
		await _tree.process_frame


## Saves the editor window as a PNG, with the given popups drawn over it where they are.
func _shot(file: String, popups: Array = []) -> void:
	if _shots == "":
		return
	await _frames(3)
	EditorInterface.get_base_control().queue_redraw()
	await RenderingServer.frame_post_draw
	var window := EditorInterface.get_base_control().get_window()
	var image := window.get_texture().get_image()
	for popup: Window in popups:
		check(popup == null or popup.visible, "%s: a menu closed before the shot." % file)
		if popup != null and popup.visible and not popup.is_embedded():
			var drawn := popup.get_texture().get_image()
			drawn.convert(image.get_format())
			image.blit_rect(drawn, Rect2i(Vector2i.ZERO, drawn.get_size()), popup.position - window.position)
	image.save_png(_shots.path_join(file))
	print("Forge UI: saved ", _shots.path_join(file))


## The bar alone, width px wide (as on a main screen that wide), cut from the editor window.
func _shot_at_width(bar: HBoxContainer, width: int, file: String) -> void:
	var main := EditorInterface.get_editor_main_screen()
	if main.size.x < width:
		print("Forge UI: the main screen (%d px) is narrower than %d px; %s shows it at its own width." % [int(main.size.x), width, file])
	else:
		bar.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		bar.custom_minimum_size.x = width
	await _frames(6)
	_check_fits(bar, "%s at %d px" % [bar.workspace, width])
	await _frames(2)
	EditorInterface.get_base_control().queue_redraw()
	await RenderingServer.frame_post_draw
	var window := EditorInterface.get_base_control().get_window()
	var image := window.get_texture().get_image()
	var rect := Rect2i(bar.get_global_rect().grow(6.0)).intersection(Rect2i(Vector2i.ZERO, image.get_size()))
	image.get_region(rect).save_png(_shots.path_join(file))
	print("Forge UI: saved ", _shots.path_join(file))
	bar.custom_minimum_size.x = 0.0
	bar.size_flags_horizontal = Control.SIZE_FILL
	await _frames(4)


func _finish() -> void:
	await _frames(4)
	if failures.is_empty():
		print("PASS Holo Forge UI EDITOR: toolbar fits the main screen in every workspace and sketch mode at editor scale, part name not cut, CREATE dropdown and a folder open, » on a narrow screen, Dark and Light switch the view, ink and controls and still fit")
	else:
		print("FAIL Holo Forge UI EDITOR: ", failures)
	_tree.quit(0 if failures.is_empty() else 1)
