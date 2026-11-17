extends SceneTree
## The Forge toolbar: in every workspace and the Sketch toolbar, at widths from 1600 px down to 380
## px and back, the bar is never wider than the space it's given and its minimum stays put; when
## the blocks don't fit, the part's name gives way first, then blocks drop their icons from the
## right end (a block keeps those that fit under its name, and may show only its first few) while
## Create and Modify keep theirs, then whole blocks fold from the right into the » menu, and the
## same width always gives the same layout. Every catalog tool is reachable exactly once through
## the dropdowns (in their folders) and through » when folded; the tools the tests and the marking
## menu need stay top level. Default pins show as icon buttons, greyed when not ready, that run
## their tool. Pin to Toolbar (filled as it opens), a right-click on a dropdown item, the icons'
## right-click menu (unpin, move) and Reset Toolbar change the pins, which a new bar on the same
## store keeps (stale ids ignored). The part's name gets its full width, measured in its own font,
## when there's room. Icons load in the bar's ink (set_ink_color re-renders them and the bar's own
## colours; a dark ink darkens the accents), a right button let go over a dropdown that opened
## while it was down never runs a tool, the switcher is locked on the Sketch toolbar, and
## rebuilds are quick and skipped on theme changes that don't need one.
##
## godot --headless --path . --script res://tests/holo_forge_toolbar_test.gd

const TOOLBAR := preload("res://addons/holo_forge/ui/toolbar.gd")
const CATALOG := preload("res://addons/holo_forge/tools/catalog.gd")
const TIMING := preload("res://tests/holo_forge_timing.gd")
const WIDTHS := [1600, 1300, 1100, 900, 800, 700, 560, 460, 380, 560, 800, 1100, 1600]
const PART_NAME := "Hoverboard Deck v003 (board body)"

var failures: Array[String] = []


func _init() -> void:
	call_deferred("run")


func run() -> void:
	# Room for the dropdowns opened below (a headless root starts 64 px square).
	root.size = Vector2i(1800, 1000)
	for workspace in CATALOG.WORKSPACES + [CATALOG.SKETCH_WORKSPACE]:
		await _check_workspace(workspace)
	await _check_top_level_items()
	await _check_folded_select()
	await _check_pins()
	await _check_part_name()
	await _check_ink()
	await _check_right_release()
	await _check_switcher_lock()
	await _check_speed()
	print("PASS holo_forge_toolbar: fits at every width in every workspace and Sketch (name, then icons, then blocks give way, same layout each way), every tool reachable once through dropdowns, folders and », default pins as working icons, Pin to Toolbar, right-click pin, icon menu, reset, saved and stale pins, part name at full width, icons in the bar's ink, no tool run by a right release, switcher locked in Sketch, quick rebuilds that skip theme changes needing none." \
		if failures.is_empty() else "FAIL holo_forge_toolbar")
	quit(0 if failures.is_empty() else 1)


## A toolbar in a box laid out like the Forge tab's VBox, on its own pin store.
func _make_bar(workspace: String, store := {}) -> Array:
	var holder := VBoxContainer.new()
	root.add_child(holder)
	var bar: HBoxContainer = TOOLBAR.new()
	bar.pin_store = store
	holder.add_child(bar)
	bar.set_workspace(workspace)
	bar.set_part_name(PART_NAME)
	return [holder, bar]


## Sets the box's width as a parent container would on each layout pass, until it settles.
func _resize(holder: VBoxContainer, width: float) -> void:
	for i in 8:
		holder.size = Vector2(width, 40)
		await process_frame


func _free(holder: Node) -> void:
	holder.queue_free()
	await process_frame


func _check_workspace(workspace: String) -> void:
	var made := _make_bar(workspace)
	var holder: VBoxContainer = made[0]
	var bar: HBoxContainer = made[1]
	var groups: Array = CATALOG.groups(workspace)
	var minimum := -1.0
	var layouts := {}
	var last_stage := 0
	var stages := {}
	var partial := {}
	for k in WIDTHS.size():
		var width: int = WIDTHS[k]
		await _resize(holder, width)
		var at := "%s at %d px" % [workspace, width]
		_expect(bar.size.x <= width + 0.5, "%s: the bar should fit (it is %d px)." % [at, int(bar.size.x)])
		# Its minimum is fixed: it never grows with how the space was shared out.
		var now := bar.get_combined_minimum_size().x
		_expect(minimum < 0.0 or absf(now - minimum) < 0.5, "%s: the bar's minimum width should stay put (%d, was %d)." % [at, int(now), int(minimum)])
		minimum = now
		var folded: Array[String] = bar.folded_groups()
		var shown := []
		for group in groups:
			var menu: MenuButton = bar.group_menu(group)
			_expect(menu != null, "%s: %s should have a menu." % [at, group])
			if menu != null and menu.visible:
				shown.append(group)
		_expect(shown + folded == groups, "%s: the blocks on the bar then the folded ones should be every group in order (%s + %s)." % [at, shown, folded])
		var more: MenuButton = bar.more_menu()
		_expect(more.visible == (not folded.is_empty()), "%s: » should show exactly when blocks are folded." % at)
		# Each block shows its first shown_icons() icons, at least those that fit under its name;
		# a block that shows fewer than it pins is compact.
		var trimmed := []
		var counts := []
		for group in groups:
			var buttons: Array[Button] = bar.icon_buttons(group)
			var n: int = bar.shown_icons(group)
			counts.append(n)
			for b in buttons.size():
				_expect(buttons[b].is_visible_in_tree() == (b < n and shown.has(group)), "%s: %s should show its first %d icons (icon %d)." % [at, group, n, b])
			if shown.has(group):
				_expect(n >= _least(bar, group), "%s: %s should keep the %d icons that fit under its name (shows %d)." % [at, group, _least(bar, group), n])
				if n < buttons.size():
					trimmed.append(group)
			else:
				_expect(n == 0, "%s: folded %s should show no icons." % [at, group])
		_expect(Array(bar.compact_groups()) == trimmed, "%s: compact_groups() should be the blocks showing fewer icons than they pin (%s vs %s)." % [at, bar.compact_groups(), trimmed])
		# Icons go from the right end: every block right of one that lost icons is down to its least.
		for group in trimmed:
			for later in shown.slice(shown.find(group) + 1):
				_expect(bar.shown_icons(later) == _least(bar, later), "%s: %s lost icons while %s, right of it, kept more than its least." % [at, group, later])
		# Create and Modify keep all their icons while any other block is on the bar.
		if shown.size() > TOOLBAR.PRIMARY_BLOCKS:
			for i in TOOLBAR.PRIMARY_BLOCKS:
				_expect(not trimmed.has(groups[i]), "%s: %s should keep its icons while %s is on the bar." % [at, groups[i], shown.back()])
		# The part's name gives way first: what it has past its smallest pays for no more icons on the
		# leftmost compact block, nor for the first folded block.
		var label: Label = bar.part_label()
		var name_min := minf(_text_width(label), TOOLBAR.PART_LABEL_MIN)
		var spare := label.size.x - name_min
		if not trimmed.is_empty():
			var group: String = trimmed[0]
			var n: int = bar.shown_icons(group)
			var cost := _block_width(bar, group, n + 1) - _block_width(bar, group, n)
			_expect(spare < cost + 0.5, "%s: the part's name has %d px to spare, enough for another %s icon (%d)." % [at, int(spare), group, int(cost)])
		if folded.size() > 1:
			var next: float = bar.group_menu(folded[0]).get_combined_minimum_size().x + TOOLBAR.BLOCK_GAP * 2.0 + 4.0
			_expect(spare < next, "%s: the part's name has %d px to spare, enough for %s (%d)." % [at, int(spare), folded[0], int(next)])
		_expect(label.size.x >= name_min - 0.5, "%s: the part's name should keep at least %d px (has %d)." % [at, int(name_min), int(label.size.x)])
		var stage := 2 if not folded.is_empty() else (1 if not trimmed.is_empty() else 0)
		stages[stage] = true
		if k > 0 and width < WIDTHS[k - 1]:
			_expect(stage >= last_stage, "%s: narrowing the bar shouldn't go back a fitting stage (%d after %d)." % [at, stage, last_stage])
		last_stage = stage
		for group in trimmed:
			if bar.shown_icons(group) > 0:
				partial[group] = true
		if width == 900 and workspace in ["Solid", CATALOG.SKETCH_WORKSPACE]:
			# The user's narrow main screen: Create and Modify show every icon.
			for i in TOOLBAR.PRIMARY_BLOCKS:
				_expect(shown.has(groups[i]) and not trimmed.has(groups[i]), "%s: %s should show all its icons (%d of %d)." % [at, groups[i], bar.shown_icons(groups[i]), bar.icon_buttons(groups[i]).size()])
		if width == 700 and workspace == "Solid":
			_expect(bar.shown_icons(groups[0]) > 0, "%s: CREATE should still show some icons." % at)
		# The same width gives the same layout, narrowing or widening.
		var layout := [shown, counts, folded, roundi(label.size.x)]
		if layouts.has(width):
			_expect(layouts[width] == layout, "%s: the layout should be the same as before (%s vs %s)." % [at, layout, layouts[width]])
		layouts[width] = layout
		if not folded.is_empty():
			await _check_more(bar, workspace, folded, at)
		# Everything on the bar lies inside it, the part's name included.
		for control in bar.find_children("*", "Control", true, false):
			var item := control as Control
			if item.is_visible_in_tree() and item.size.x > 0.0:
				var right := item.global_position.x + item.size.x - bar.global_position.x
				_expect(right <= width + 0.5, "%s: %s should end inside the bar (at %d)." % [at, item.get_class(), int(right)])
	_expect(minimum <= 400.0, "%s: the bar should fit in 400 px (needs %d)." % [workspace, int(minimum)])
	_expect(stages.has(0) and stages.has(2), "%s: the sweep should show every block with icons and some folded (%s)." % [workspace, stages.keys()])
	if workspace == CATALOG.SKETCH_WORKSPACE:
		_expect(stages.has(1), "%s: some width should drop icons before any block folds." % workspace)
		_expect(partial.has("Constraints"), "%s: CONSTRAINTS should show part of its icon row at some width (%s)." % [workspace, partial.keys()])
	await _resize(holder, 1600)
	for group in groups:
		_check_dropdown(bar, workspace, group, bar.group_menu(group).get_popup(), workspace + " " + group)
		_check_default_pins(bar, workspace, group)
	var kinds := []
	for child in bar.get_children():
		kinds.append(child.get_class())
	_expect(kinds == ["OptionButton", "VSeparator", "Control", "Button", "MenuButton"] and bar.get_child(4) == bar.theme_button(),
		"%s: the bar should hold the switcher, the block area, Parameters and the appearance button (%s)." % [workspace, kinds])
	await _free(holder)


## How many of a block's icons fit under its name (it always keeps those).
func _least(bar: HBoxContainer, group: String) -> int:
	var fit := floori((bar.group_menu(group).get_combined_minimum_size().x + TOOLBAR.ICON_GAP) / (TOOLBAR.BUTTON_SIZE + TOOLBAR.ICON_GAP))
	return mini(bar.icon_buttons(group).size(), fit)


## A block's width showing n icons.
func _block_width(bar: HBoxContainer, group: String, n: int) -> float:
	return maxf(bar.group_menu(group).get_combined_minimum_size().x, TOOLBAR.row_width(n, TOOLBAR.BUTTON_SIZE, TOOLBAR.ICON_GAP))


## A dropdown lists each of the group's tools once, in the catalog's folders, greyed only when not
## ready, with Pin to Toolbar (every tool, same folders) and Reset Toolbar at the end.
func _check_dropdown(bar: HBoxContainer, workspace: String, group: String, popup: PopupMenu, at: String) -> void:
	var tools := CATALOG.tools_in(workspace, group)
	var found := _tools_in_menu(popup)
	var ids := []
	for tool in found:
		ids.append(tool.id)
	for tool in tools:
		_expect(ids.count(tool.id) == 1, "%s: %s should be listed once (%d)." % [at, tool.name, ids.count(tool.id)])
	_expect(ids.size() == tools.size(), "%s: the dropdown should list %d tools (lists %d)." % [at, tools.size(), ids.size()])
	# Top level: the catalog's entries in order, folders as submenus holding their tools.
	var entries := CATALOG.menu_entries(workspace, group)
	var k := 0
	for i in popup.item_count:
		if k >= entries.size():
			break
		var entry: Dictionary = entries[k]
		if entry.has("tools"):
			var sub := popup.get_item_submenu_node(i)
			_expect(sub != null and popup.get_item_text(i) == entry.folder, "%s: item %d should be the %s folder (%s)." % [at, i, entry.folder, popup.get_item_text(i)])
			if sub != null:
				var inside := []
				for j in sub.item_count:
					inside.append(sub.get_item_text(j))
				var wanted := []
				for tool in entry.tools:
					wanted.append(tool.name)
				_expect(inside == wanted, "%s: the %s folder should hold %s (%s)." % [at, entry.folder, wanted, inside])
		else:
			_expect(popup.get_item_text(i) == entry.tool.name and popup.get_item_submenu_node(i) == null, "%s: item %d should be %s (%s)." % [at, i, entry.tool.name, popup.get_item_text(i)])
		k += 1
	_expect(k == entries.size(), "%s: the dropdown should start with its %d entries." % [at, entries.size()])
	var texts := []
	for i in popup.item_count:
		texts.append(popup.get_item_text(i))
	var pin_index := texts.find("Pin to Toolbar")
	_expect(pin_index >= 0 and texts.back() == "Reset Toolbar" and popup.get_item_submenu_node(pin_index) != null, "%s: the dropdown should end with Pin to Toolbar and Reset Toolbar (%s)." % [at, texts.slice(-3)])
	if pin_index >= 0 and popup.get_item_submenu_node(pin_index) != null:
		var pin_ids := _pin_items(popup.get_item_submenu_node(pin_index))
		_expect(pin_ids.size() == tools.size(), "%s: Pin to Toolbar should list all %d tools (%d)." % [at, tools.size(), pin_ids.size()])
		var pinned: Array[String] = bar.pinned(group)
		for item in pin_ids:
			_expect(item[1] == pinned.has(item[0]), "%s: Pin to Toolbar should tick %s exactly when it's pinned." % [at, item[0]])
	if group == "Select":
		_expect(texts.has("Selection Filters") and texts.has("Selection Priority") and texts.has("Select Through"), "%s: SELECT should keep its options (%s)." % [at, texts])


## The tools a menu runs, through its folders (not Pin to Toolbar's check items).
func _tools_in_menu(popup: PopupMenu) -> Array:
	var found := []
	for i in popup.item_count:
		var meta: Variant = popup.get_item_metadata(i)
		if meta is Dictionary and meta.has("id"):
			found.append(meta)
			_expect(popup.is_item_disabled(i) == (not CATALOG.is_enabled(meta)), "%s should be greyed only if not ready yet." % meta.name)
		var sub := popup.get_item_submenu_node(i)
		if sub != null and popup.get_item_text(i) != "Pin to Toolbar":
			found.append_array(_tools_in_menu(sub))
	return found


## [tool id, checked] for each check item of a Pin to Toolbar menu, through its folders.
func _pin_items(menu: PopupMenu) -> Array:
	menu.about_to_popup.emit()
	var items := []
	for i in menu.item_count:
		if menu.get_item_metadata(i) is String:
			items.append([menu.get_item_metadata(i), menu.is_item_checked(i)])
		if menu.get_item_submenu_node(i) != null:
			items.append_array(_pin_items(menu.get_item_submenu_node(i)))
	return items


## The bar shows the group's default pins as icon buttons, greyed when not ready, that run their tool.
func _check_default_pins(bar: HBoxContainer, workspace: String, group: String) -> void:
	var wanted := CATALOG.default_pins(workspace, group)
	var buttons: Array[Button] = bar.icon_buttons(group)
	var ids := []
	for button in buttons:
		ids.append(button.get_meta("tool_id"))
	_expect(ids == Array(wanted), "%s %s: the bar should show the default pins %s (%s)." % [workspace, group, wanted, ids])
	_expect(not wanted.is_empty(), "%s %s: the group should pin some tools by default." % [workspace, group])
	for button in buttons:
		var tool := CATALOG.find(button.get_meta("tool_id"))
		_expect(button.disabled == (not CATALOG.is_enabled(tool)), "%s %s: %s's icon should be greyed only if not ready." % [workspace, group, tool.name])
		_expect(button.icon != null and button.tooltip_text.begins_with(tool.name), "%s %s: %s's icon button should have an icon and its name as tooltip." % [workspace, group, tool.name])
		if button.disabled:
			_expect(button.tooltip_text.contains("Phase %d" % tool.phase), "%s %s: greyed %s should say which phase it arrives in." % [workspace, group, tool.name])
	for button in buttons:
		if not button.disabled:
			var got := []
			var take := func(t: Dictionary) -> void: got.append(t)
			bar.tool_activated.connect(take)
			button.pressed.emit()
			bar.tool_activated.disconnect(take)
			_expect(got.size() == 1 and got[0].id == button.get_meta("tool_id"), "%s %s: the %s icon should run its tool." % [workspace, group, button.get_meta("tool_id")])
			break


## The » menu lists the folded groups, each with all its tools once (greyed as on the bar, in
## folders), and runs them.
func _check_more(bar: HBoxContainer, workspace: String, folded: Array[String], at: String) -> void:
	var more: MenuButton = bar.more_menu()
	more.about_to_popup.emit()
	var popup := more.get_popup()
	var subs := []
	for i in popup.item_count:
		if popup.get_item_submenu_node(i) != null:
			subs.append([popup.get_item_text(i), popup.get_item_submenu_node(i)])
	_expect(subs.size() == folded.size(), "%s: » should list %d folded groups (has %d)." % [at, folded.size(), subs.size()])
	for k in mini(subs.size(), folded.size()):
		var group := folded[k]
		var sub: PopupMenu = subs[k][1]
		_expect(subs[k][0] == group.to_upper(), "%s: » item %d should be %s (is %s)." % [at, k, group.to_upper(), subs[k][0]])
		_check_dropdown(bar, workspace, group, sub, at + " » " + group)
		# Picking a ready tool there (in a folder if it has one) runs it.
		var ready := _tools_in_menu(sub).filter(func(t: Dictionary) -> bool: return CATALOG.is_enabled(t))
		if not ready.is_empty():
			var tool: Dictionary = ready.back()
			var menu := _menu_holding(sub, tool.id)
			var got := []
			var take := func(t: Dictionary) -> void: got.append(t)
			bar.tool_activated.connect(take)
			for j in menu.item_count:
				var meta: Variant = menu.get_item_metadata(j)
				if meta is Dictionary and meta.get("id", "") == tool.id:
					menu.id_pressed.emit(menu.get_item_id(j))
			# Picks run at the end of the frame.
			_expect(got.is_empty(), "%s: picking %s should wait for the end of the frame." % [at, tool.name])
			await process_frame
			bar.tool_activated.disconnect(take)
			_expect(got.size() == 1 and got[0].id == tool.id, "%s: picking %s under » should run it once (%d)." % [at, tool.name, got.size()])


func _menu_holding(popup: PopupMenu, id: String) -> PopupMenu:
	for i in popup.item_count:
		var meta: Variant = popup.get_item_metadata(i)
		if meta is Dictionary and meta.get("id", "") == id:
			return popup
		var sub := popup.get_item_submenu_node(i)
		if sub != null and popup.get_item_text(i) != "Pin to Toolbar":
			var found := _menu_holding(sub, id)
			if found != null:
				return found
	return null


## The items other tests and the marking menu look for stay top level in their CREATE dropdowns.
func _check_top_level_items() -> void:
	var made := _make_bar("Solid")
	var holder: VBoxContainer = made[0]
	var bar: HBoxContainer = made[1]
	await _resize(holder, 1480)
	for wanted in [["Solid", "Box", true], ["Solid", "Create Form", true], ["Mesh", "Tessellate", true], ["Sheet Metal", "Flange", false], ["Surface", "Patch", true], ["Sketch", "Line", true], ["Sketch", "Sketch Dimension", true]]:
		bar.set_workspace(wanted[0])
		await process_frame
		var popup: PopupMenu = bar.group_menu("Create").get_popup()
		var index := -1
		for i in popup.item_count:
			if popup.get_item_text(i) == wanted[1]:
				index = i
		_expect(index >= 0, "%s CREATE should list %s at its top level." % [wanted[0], wanted[1]])
		if index >= 0:
			_expect(popup.is_item_disabled(index) != wanted[2], "%s CREATE: %s should be %s." % [wanted[0], wanted[1], "enabled" if wanted[2] else "greyed"])
			if not wanted[2]:
				_expect(popup.get_item_tooltip(index).contains("Phase 9"), "%s should say it arrives in Phase 9." % wanted[1])
	# Shortcuts show as the items' accelerators.
	bar.set_workspace("Solid")
	await process_frame
	var create: PopupMenu = bar.group_menu("Create").get_popup()
	for i in create.item_count:
		if create.get_item_text(i) == "Extrude":
			_expect(create.get_item_accelerator(i) == KEY_E, "Extrude should show its E shortcut.")
	await _free(holder)


## Select folded into »: its options are there, and a change made there shows in the bar's own
## Select menu (and the other way round).
func _check_folded_select() -> void:
	var made := _make_bar("Solid")
	var holder: VBoxContainer = made[0]
	var bar: HBoxContainer = made[1]
	await _resize(holder, 560)
	_expect(bar.folded_groups().has("Select"), "At 560 px Select should be folded into ».")
	var more: MenuButton = bar.more_menu()
	more.about_to_popup.emit()
	var select: PopupMenu = null
	for i in more.get_popup().item_count:
		if more.get_popup().get_item_text(i) == "SELECT":
			select = more.get_popup().get_item_submenu_node(i)
	_expect(select != null, "» should hold SELECT.")
	if select == null:
		await _free(holder)
		return
	var changes := []
	var take := func(key: String, value: Variant) -> void: changes.append([key, value])
	bar.select_option_changed.connect(take)
	select.id_pressed.emit(TOOLBAR.SELECT_THROUGH_ID)
	bar.select_option_changed.disconnect(take)
	_expect(changes == [["select_through", true]], "Select Through under » should turn it on (%s)." % [changes])
	var own: PopupMenu = bar.group_menu("Select").get_popup()
	own.about_to_popup.emit()
	_expect(own.is_item_checked(own.get_item_index(TOOLBAR.SELECT_THROUGH_ID)), "The bar's own SELECT should show Select Through on after it was set under ».")
	await _free(holder)


## Pin to Toolbar, a right-click on a dropdown item, the icon menu and Reset Toolbar change the
## pins; a new bar on the same store keeps them; stale ids are skipped.
func _check_pins() -> void:
	var store := {}
	var made := _make_bar("Solid", store)
	var holder: VBoxContainer = made[0]
	var bar: HBoxContainer = made[1]
	await _resize(holder, 1600)
	var defaults := CATALOG.default_pins("Solid", "Create")
	var popup: PopupMenu = bar.group_menu("Create").get_popup()
	var pin_menu: PopupMenu = popup.get_item_submenu_node(popup.get_item_index(TOOLBAR.PIN_MENU_ID))
	# It fills as it opens.
	_expect(pin_menu.item_count == 0, "Pin to Toolbar should wait to be opened before it lists its tools.")
	pin_menu.about_to_popup.emit()

	# Pin to Toolbar: Circular Pattern, inside the Pattern folder, goes on the end of the block.
	var pattern: PopupMenu = null
	for i in pin_menu.item_count:
		if pin_menu.get_item_text(i) == "Pattern":
			pattern = pin_menu.get_item_submenu_node(i)
	_expect(pattern != null, "Pin to Toolbar should nest the Pattern folder.")
	if pattern != null:
		var index := -1
		for i in pattern.item_count:
			if pattern.get_item_metadata(i) == "solid.create.circular_pattern":
				index = i
		pattern.id_pressed.emit(pattern.get_item_id(index))
		await process_frame
		_expect(bar.pinned("Create") == defaults + ["solid.create.circular_pattern"] and pattern.is_item_checked(index), "Pin to Toolbar should pin Circular Pattern and tick it (%s)." % [bar.pinned("Create")])
		_expect(_button_ids(bar, "Create").back() == "solid.create.circular_pattern", "The new pin should show as the block's last icon.")
		_expect(not pattern.hide_on_checkable_item_selection, "Pin to Toolbar should stay open while ticking.")
		pattern.id_pressed.emit(pattern.get_item_id(index))
		await process_frame
		_expect(bar.pinned("Create") == defaults and not pattern.is_item_checked(index), "Ticking it again should unpin it (%s)." % [bar.pinned("Create")])

	# A right-click on a dropdown item pins the item under the mouse and never runs it.
	popup.position = Vector2i(40, 80)
	popup.popup()
	await process_frame
	var activated := []
	var take := func(t: Dictionary) -> void: activated.append(t)
	bar.tool_activated.connect(take)
	var thread_index := -1
	for i in popup.item_count:
		if popup.get_item_text(i) == "Thread":
			thread_index = i
	var motion := InputEventMouseMotion.new()
	motion.velocity = Vector2(30, 0)
	popup.window_input.emit(motion)
	popup.set_focused_item(thread_index)
	var right := InputEventMouseButton.new()
	right.button_index = MOUSE_BUTTON_RIGHT
	right.pressed = true
	popup.window_input.emit(right)
	await process_frame
	_expect(bar.pinned("Create").has("solid.create.thread"), "A right-click on Thread in the dropdown should pin it (%s)." % [bar.pinned("Create")])
	_expect(popup.get_item_tooltip(thread_index).contains("unpin"), "Thread's hint should then offer to unpin it.")
	# After a key press the focused item may not be under the mouse: a right-click then does nothing.
	var key := InputEventKey.new()
	key.keycode = KEY_DOWN
	key.pressed = true
	popup.window_input.emit(key)
	popup.window_input.emit(right)
	await process_frame
	_expect(bar.pinned("Create").has("solid.create.thread"), "A right-click after a key press shouldn't change pins.")
	popup.window_input.emit(motion)
	popup.window_input.emit(right)
	await process_frame
	_expect(not bar.pinned("Create").has("solid.create.thread"), "A second right-click should unpin it.")
	# A real right-click, through the popup's own input, pins and runs nothing.
	var at := Vector2(popup.position) + Vector2(popup.size.x * 0.5, 14.0)
	var real_motion := InputEventMouseMotion.new()
	real_motion.position = at
	real_motion.global_position = at
	real_motion.velocity = Vector2(40, 10)
	real_motion.relative = Vector2(2, 1)
	Input.parse_input_event(real_motion)
	await process_frame
	await process_frame
	var under: int = popup.get_focused_item()
	var under_tool: Variant = popup.get_item_metadata(under) if under >= 0 else null
	_expect(under_tool is Dictionary, "Moving the mouse over the dropdown should focus a tool (%d)." % under)
	for pressed in [true, false]:
		var real_click := InputEventMouseButton.new()
		real_click.position = at
		real_click.global_position = at
		real_click.button_index = MOUSE_BUTTON_RIGHT
		real_click.pressed = pressed
		real_click.button_mask = MOUSE_BUTTON_MASK_RIGHT if pressed else 0
		Input.parse_input_event(real_click)
		await process_frame
		await process_frame
	if under_tool is Dictionary:
		_expect(bar.pinned("Create").has(under_tool.id) != defaults.has(under_tool.id), "A real right-click should toggle %s's pin (%s)." % [under_tool.name, bar.pinned("Create")])
		pin_back(bar, under_tool.id, defaults.has(under_tool.id))
	_expect(popup.visible, "A right-click should leave the dropdown open.")
	bar.tool_activated.disconnect(take)
	_expect(activated.is_empty(), "Right-clicks in the dropdown should never run a tool (%s)." % [activated.map(func(t: Dictionary) -> String: return t.name)])
	popup.hide()
	await process_frame
	_expect(bar.pinned("Create") == defaults, "The pins should be back to the defaults (%s)." % [bar.pinned("Create")])

	# The icons' right-click menu: move Revolve left, then right, then unpin it.
	var revolve := _button(bar, "Create", "solid.create.revolve")
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_RIGHT
	click.pressed = true
	click.position = Vector2(4, 4)
	revolve.gui_input.emit(click)
	await process_frame
	var menu: PopupMenu = bar.icon_menu()
	_expect(menu.visible and menu.get_item_text(0) == "Unpin from Toolbar", "A right-click on an icon should open its menu.")
	menu.id_pressed.emit(1)
	menu.hide()
	await process_frame
	var order := _button_ids(bar, "Create")
	_expect(order.find("solid.create.revolve") == defaults.find("solid.create.revolve") - 1, "Move Left should move Revolve one place left (%s)." % [order])
	_button(bar, "Create", "solid.create.revolve").gui_input.emit(click)
	menu.id_pressed.emit(2)
	menu.hide()
	await process_frame
	_expect(_button_ids(bar, "Create") == Array(defaults), "Move Right should move it back (%s)." % [_button_ids(bar, "Create")])
	_button(bar, "Create", "solid.create.create_sketch").gui_input.emit(click)
	await process_frame
	_expect(menu.is_item_disabled(menu.get_item_index(1)) and not menu.is_item_disabled(menu.get_item_index(2)), "The first icon can't move left but can move right.")
	menu.hide()
	_button(bar, "Create", "solid.create.revolve").gui_input.emit(click)
	menu.id_pressed.emit(0)
	menu.hide()
	await process_frame
	_expect(not _button_ids(bar, "Create").has("solid.create.revolve"), "Unpin from Toolbar should take Revolve off the bar.")
	bar.pin("solid.modify.draft", true)
	await process_frame
	var kept_create: Array = bar.pinned("Create")
	var kept_modify: Array = bar.pinned("Modify")
	await _free(holder)

	# A new bar on the same store shows the same pins.
	made = _make_bar("Solid", store)
	holder = made[0]
	bar = made[1]
	await _resize(holder, 1600)
	_expect(bar.pinned("Create") == kept_create and bar.pinned("Modify") == kept_modify and _button_ids(bar, "Modify") == Array(kept_modify), "A new bar on the same store should keep the pins (%s, %s)." % [bar.pinned("Create"), bar.pinned("Modify")])
	# Pins are per workspace: Surface still has its defaults.
	bar.set_workspace("Surface")
	await process_frame
	_expect(bar.pinned("Create") == CATALOG.default_pins("Surface", "Create"), "Surface's pins shouldn't change with Solid's.")
	bar.set_workspace("Solid")
	await process_frame
	# Reset Toolbar puts back the workspace's defaults.
	popup = bar.group_menu("Modify").get_popup()
	popup.id_pressed.emit(TOOLBAR.RESET_ID)
	await process_frame
	_expect(bar.pinned("Create") == defaults and bar.pinned("Modify") == CATALOG.default_pins("Solid", "Modify") and _button_ids(bar, "Create") == Array(defaults), "Reset Toolbar should put back the defaults (%s)." % [bar.pinned("Create")])
	_expect(not (store.get(TOOLBAR.PINS_KEY, {}) as Dictionary).has("Solid"), "Reset Toolbar should drop the saved Solid pins (%s)." % [store])
	await _free(holder)

	# Saved ids that aren't tools of the group are skipped.
	var stale := {TOOLBAR.PINS_KEY: {"Solid": {"Create": ["solid.create.extrude", "solid.create.no_such_tool", "solid.modify.fillet", "solid.create.extrude", 7]}}}
	made = _make_bar("Solid", stale)
	holder = made[0]
	bar = made[1]
	await _resize(holder, 1600)
	_expect(bar.pinned("Create") == ["solid.create.extrude"] and _button_ids(bar, "Create") == ["solid.create.extrude"], "Stale pins should be skipped (%s)." % [bar.pinned("Create")])
	await _free(holder)


func pin_back(bar: HBoxContainer, id: String, on: bool) -> void:
	bar.pin(id, on)


func _button(bar: HBoxContainer, group: String, id: String) -> Button:
	for button in bar.icon_buttons(group):
		if button.get_meta("tool_id") == id:
			return button
	return null


func _button_ids(bar: HBoxContainer, group: String) -> Array:
	return bar.icon_buttons(group).map(func(b: Button) -> String: return b.get_meta("tool_id"))


## The part's name gets its full width (in the label's own font) when there's room, and never
## spills past the bar.
func _check_part_name() -> void:
	var made := _make_bar("Solid")
	var holder: VBoxContainer = made[0]
	var bar: HBoxContainer = made[1]
	await _resize(holder, 1600)
	var label: Label = bar.part_label()
	var width := _text_width(label)
	_expect(label.size.x >= width - 0.5, "At 1600 px the part's name should get its full %d px (has %d)." % [int(width), int(label.size.x)])
	await _free(holder)
	# Named before it joins a tree whose theme has a bigger font (as the Forge tab names it before
	# the editor's theme applies): the layout measures the font the label really has.
	holder = VBoxContainer.new()
	holder.theme = Theme.new()
	holder.theme.default_font_size = 24
	bar = TOOLBAR.new()
	bar.pin_store = {}
	bar.set_part_name(PART_NAME)
	holder.add_child(bar)
	root.add_child(holder)
	await _resize(holder, 2400)
	label = bar.part_label()
	width = _text_width(label)
	_expect(label.get_theme_font_size("font_size") == 24 and label.size.x >= width - 0.5, "Named before the theme applied, the part's name should still get its full %d px (has %d, font %d)." \
		% [int(width), int(label.size.x), label.get_theme_font_size("font_size")])
	_expect(bar.size.x <= 2400.5 and bar.folded_groups().is_empty() and bar.compact_groups().is_empty(), "The bar with a big font should fit 2400 px with every icon (%d)." % int(bar.size.x))
	await _free(holder)


## Icons load in the bar's ink: the SVGs' neutral colour is swapped for it (accents stay), and
## set_ink_color re-renders the icons and recolours the group names and the part's name.
func _check_ink() -> void:
	var svg := "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"24\" height=\"24\" viewBox=\"0 0 24 24\"><rect x=\"2\" y=\"2\" width=\"20\" height=\"20\" fill=\"#dfe3ea\"/><rect x=\"8\" y=\"8\" width=\"8\" height=\"8\" fill=\"#22b8cc\"/></svg>"
	var pink := TOOLBAR.svg_icon(svg, 48.0, Color("#ffc0c0"))
	var image := pink.get_image() if pink != null else null
	_expect(image != null and image.get_width() == 48, "An icon should render at the size asked for.")
	if image != null:
		_expect(_near(image.get_pixel(8, 8), Color("#ffc0c0")) and _near(image.get_pixel(24, 24), Color("#22b8cc")), "A light ink should replace the SVG's neutral colour and leave its accents (%s, %s)." % [image.get_pixel(8, 8), image.get_pixel(24, 24)])
	# Under the light theme's dark ink every accent takes its darker shade, readable at 3:1 on the
	# light chrome.
	for accent: String in TOOLBAR.LIGHT_ACCENTS:
		var shade := Color(TOOLBAR.LIGHT_ACCENTS[accent])
		var dark := TOOLBAR.svg_icon(svg.replace("#22b8cc", accent), 48.0, TOOLBAR.LIGHT_THEME_INK)
		_expect(dark != null and _near(dark.get_image().get_pixel(24, 24), shade) and _near(dark.get_image().get_pixel(8, 8), TOOLBAR.LIGHT_THEME_INK),
			"Under a dark ink the accent %s should become %s." % [accent, shade.to_html(false)])
		_expect(_contrast(shade, Color("#e9ecf1")) >= 3.0, "The light theme's %s should read at 3:1 on the light chrome (%.2f)." % [shade.to_html(false), _contrast(shade, Color("#e9ecf1"))])
	var plain := TOOLBAR.svg_icon(svg, 24.0, TOOLBAR.DARK_THEME_INK)
	_expect(plain != null and _near(plain.get_image().get_pixel(4, 4), Color(TOOLBAR.SVG_INK)), "The dark theme's ink is the SVGs' own colour.")
	var made := _make_bar("Solid")
	var holder: VBoxContainer = made[0]
	var bar: HBoxContainer = made[1]
	await _resize(holder, 1600)
	var before: Texture2D = bar.icon_buttons("Create")[0].icon
	var light := TOOLBAR.LIGHT_THEME_INK
	bar.set_ink_color(light)
	await process_frame
	var buttons: Array[Button] = bar.icon_buttons("Create")
	_expect(bar.ink_color == light and not buttons.is_empty() and buttons[0].icon != before, "set_ink_color should re-render the icons.")
	var colors: Dictionary = bar.bar_colors()
	_expect(bar.part_label().get_theme_color("font_color") == colors.part_name and bar.group_menu("Create").get_theme_color("font_color") == colors.group, "The part's name and the group names should follow the ink.")
	_expect(_near(Color(colors.group, 1.0), light), "The bar's colours should come from the ink.")
	var missing := []
	var own := 0
	for tool in CATALOG.all_tools():
		if TOOLBAR.tool_icon(tool, 16.0, light) == null:
			missing.append(tool.id)
		var file := CATALOG.slug(tool.name) + ".svg"
		if FileAccess.file_exists(TOOLBAR.ICON_DIR + file) or FileAccess.file_exists(TOOLBAR.ICON_DIR + CATALOG.slug(tool.workspace) + "/" + file):
			own += 1
	_expect(missing.is_empty(), "Every tool should have an icon, its own or a stand-in (%s)." % [missing])
	print("holo_forge_toolbar: %d of %d tools have their own SVG icon." % [own, CATALOG.all_tools().size()])
	await _free(holder)


## A dropdown that opens while the right button is down (a folder opening under a held
## right-click) runs no tool when that button is let go over one; the left button still does.
func _check_right_release() -> void:
	var made := _make_bar("Solid")
	var holder: VBoxContainer = made[0]
	var bar: HBoxContainer = made[1]
	await _resize(holder, 1600)
	var popup: PopupMenu = bar.group_menu("Create").get_popup()
	var activated := []
	var take := func(t: Dictionary) -> void: activated.append(t.name)
	bar.tool_activated.connect(take)
	var picks := []
	var count := func(id: int) -> void: picks.append(id)
	popup.id_pressed.connect(count)
	_send_button(Vector2(1700, 960), MOUSE_BUTTON_RIGHT, true)
	await process_frame
	await process_frame
	popup.position = Vector2i(40, 80)
	popup.popup()
	await create_timer(0.5).timeout
	var at: Variant = await _point_at(popup, "Extrude")
	_expect(at != null, "The mouse should find Extrude in the dropdown.")
	if at != null:
		_send_button(at, MOUSE_BUTTON_RIGHT, false)
		await process_frame
		await process_frame
		_expect(activated.is_empty(), "Letting go of the right button over Extrude should run nothing (%s; the menu picked %d)." % [activated, picks.size()])
		print("holo_forge_toolbar: a right release in a dropdown opened with it held picked %d item(s), ran %d tool(s)." % [picks.size(), activated.size()])
	# The left button still runs the tool.
	if not popup.visible:
		popup.popup()
	await create_timer(0.5).timeout
	at = await _point_at(popup, "Extrude")
	if at != null:
		_send_button(at, MOUSE_BUTTON_LEFT, true)
		await process_frame
		_send_button(at, MOUSE_BUTTON_LEFT, false)
		await process_frame
		await process_frame
		_expect(activated == ["Extrude"], "A left click on Extrude should run it once (%s)." % [activated])
	bar.tool_activated.disconnect(take)
	popup.hide()
	await _free(holder)


## Moves the mouse down a dropdown until the named item is under it; its position, or null.
func _point_at(popup: PopupMenu, text: String) -> Variant:
	for y in range(4, popup.size.y, 3):
		var at := Vector2(popup.position) + Vector2(popup.size.x * 0.4, y)
		var motion := InputEventMouseMotion.new()
		motion.position = at
		motion.global_position = at
		motion.relative = Vector2(0, 3)
		motion.velocity = Vector2(0, 60)
		Input.parse_input_event(motion)
		await process_frame
		var index := popup.get_focused_item()
		if index >= 0 and popup.get_item_text(index) == text:
			return at
	return null


func _send_button(at: Vector2, button: MouseButton, pressed: bool) -> void:
	var click := InputEventMouseButton.new()
	click.position = at
	click.global_position = at
	click.button_index = button
	click.pressed = pressed
	click.button_mask = (1 << (button - 1)) if pressed else 0
	Input.parse_input_event(click)


func _contrast(a: Color, b: Color) -> float:
	var la := _lum(a)
	var lb := _lum(b)
	return (maxf(la, lb) + 0.05) / (minf(la, lb) + 0.05)


func _lum(c: Color) -> float:
	var l := Color(c.r, c.g, c.b).srgb_to_linear()
	return 0.2126 * l.r + 0.7152 * l.g + 0.0722 * l.b


func _near(a: Color, b: Color) -> bool:
	return absf(a.r - b.r) < 0.03 and absf(a.g - b.g) < 0.03 and absf(a.b - b.b) < 0.03


func _text_width(label: Label) -> float:
	var font := label.get_theme_font("font")
	return font.get_string_size(label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, label.get_theme_font_size("font_size")).x if label.text != "" else 0.0


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error(message)
		print("FAIL: ", message)


## While the Sketch toolbar shows, the workspace switcher is locked (Finish Sketch first).
func _check_switcher_lock() -> void:
	var made := _make_bar("Solid")
	var holder: VBoxContainer = made[0]
	var bar: HBoxContainer = made[1]
	await _resize(holder, 1400)
	var switcher: OptionButton = bar.workspace_switcher()
	_expect(switcher == bar.get_child(0) and not switcher.disabled, "The switcher should work in Solid.")
	bar.set_workspace(CATALOG.SKETCH_WORKSPACE)
	await process_frame
	_expect(switcher.disabled and switcher.text == CATALOG.SKETCH_WORKSPACE and switcher.tooltip_text.contains("Finish"), "The switcher should be locked on Sketch (%s, %s)." % [switcher.disabled, switcher.text])
	bar.set_workspace("Surface")
	await process_frame
	_expect(not switcher.disabled and switcher.get_item_text(switcher.selected) == "Surface", "The switcher should work again after the sketch.")
	await _free(holder)


## Rebuilding the bar is quick (icons and catalog lookups are cached, Pin to Toolbar fills as it
## opens), and a theme change that leaves the ink and font size alone only lays it out again.
func _check_speed() -> void:
	var made := _make_bar("Solid")
	var holder: VBoxContainer = made[0]
	var bar: HBoxContainer = made[1]
	await _resize(holder, 1400)
	for workspace in [CATALOG.SKETCH_WORKSPACE, "Solid"]:
		bar.set_workspace(workspace)
		await process_frame
	# Timed against building and freeing a row of 60 buttons and a 40-item menu, in turns, so a busy
	# machine slows both alike (holo_forge_timing.gd): about 2-3 times that warm, 45-55 before the
	# caches.
	var spaces := [CATALOG.SKETCH_WORKSPACE, "Solid", "Surface"]
	var turn := [0]
	var switch := func() -> void:
		turn[0] = (turn[0] + 1) % spaces.size()
		bar.set_workspace(spaces[turn[0]])
	var calibration := func() -> void:
		var row := HBoxContainer.new()
		holder.add_child(row)
		for i in 60:
			var button := Button.new()
			button.text = "Tool %d" % i
			row.add_child(button)
		var menu := MenuButton.new()
		for i in 40:
			menu.get_popup().add_item("Item %d" % i, i)
		row.add_child(menu)
		row.get_combined_minimum_size()
		row.free()
	var timing := TIMING.compare(switch, calibration, 5, "warm workspace switch / a 60-button row")
	print("holo_forge_toolbar: warm workspace switch %.1f ms, %.2f times a 60-button row." % [timing.op, timing.ratio])
	_expect(timing.ratio < 8.0, "A warm workspace switch should cost under 8 times a 60-button row (%.1f ms, %.2f times)." % [timing.op, timing.ratio])
	bar.set_workspace("Solid")
	await process_frame
	var t1 := Time.get_ticks_usec()
	for i in 200:
		TOOLBAR.tool_icon(CATALOG.find("solid.create.extrude"), 24.0)
	var per := (Time.get_ticks_usec() - t1) / 200000.0
	_expect(per < 0.1, "A cached icon should cost no file reads (%.3f ms each)." % per)
	var builds: int = bar.build_count
	holder.theme = Theme.new()
	await process_frame
	await process_frame
	_expect(bar.build_count == builds, "A theme change keeping the ink and font size shouldn't rebuild the bar (%d -> %d)." % [builds, bar.build_count])
	holder.theme.default_font_size = 22
	await process_frame
	await process_frame
	_expect(bar.build_count == builds + 1, "A bigger font should rebuild the bar once (%d -> %d)." % [builds, bar.build_count])
	await _free(holder)
