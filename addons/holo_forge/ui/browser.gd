@tool
extends Tree
## The Forge browser: the design's contents as a tree. Document Settings (units), Named Views,
## Origin, Analysis, Joints, Joint Origins, Rigid Groups, Motion Links, Contact Sets, Motion
## Studies, Sketches, Canvases, Decals, Bodies, Components and Construction. Eyes show and hide,
## locks make bodies unselectable; right-click for more; double-click a body or view to rename, a
## sketch, analysis, canvas, decal or joint to edit it.
##
## The assembly (spec C7.5): Joints lists the document's joints with their type's icon, an eye
## and, when the last solve (core/assembly/solver.gd, C3.1) left a joint in a loop, unresolved,
## failed or waiting, a state badge whose tooltip is the solve's sentence. The other assembly
## folders (Joint Origins, Rigid Groups, Motion Links, Contact Sets, Motion Studies) hide while
## empty. Each top-level component has a ground button (Ground / Unground).

signal body_visibility_toggled(body_id: String)
signal body_selectable_toggled(body_id: String)
signal body_renamed(body_id: String, new_name: String)
signal body_clicked(body_id: String)
signal body_delete_requested(body_id: String)
signal body_feature_requested(body_id: String)
signal origin_visibility_toggled(key: String)
signal units_changed(units: String)
signal named_view_activated(view_name: String)
signal named_view_renamed(old_name: String, new_name: String)
signal named_view_deleted(view_name: String)
signal save_view_requested
signal sketch_visibility_toggled(feature_id: String)
signal sketch_edit_requested(feature_id: String)
signal construction_visibility_toggled(feature_id: String)
signal construction_clicked(feature_id: String)
signal construction_edit_requested(feature_id: String)
signal component_activated(component_id: String)
signal component_visibility_toggled(component_id: String)
signal component_renamed(component_id: String, new_name: String)
signal origin_clicked(key: String)
signal analysis_visibility_toggled(analysis_id: String)
signal analysis_edit_requested(analysis_id: String)
signal analysis_renamed(analysis_id: String, new_name: String)
signal analysis_delete_requested(analysis_id: String)
## Canvases and decals: list is "canvases" or "decals" (the document list), id the entry's id.
signal image_visibility_toggled(list: String, id: String)
signal image_edit_requested(list: String, id: String)
signal image_renamed(list: String, id: String, new_name: String)
signal image_delete_requested(list: String, id: String)
## The ground button of a top-level component: ground it, or unground it when grounded.
signal component_ground_toggled(component_id: String)
signal joint_clicked(joint_id: String)
signal joint_edit_requested(joint_id: String)
## An assembly entry's eye: list is the assembly list ("joints", "origins", ...), id the entry's.
signal assembly_visibility_toggled(list: String, id: String)
## A component item was clicked (New Contact Set and Rigid Group take browser selections).
signal component_clicked(component_id: String)
## An assembly entry other than a joint was clicked (origin, group, link, contact set, study).
signal assembly_entry_clicked(list: String, id: String)
## An assembly entry (a joint too) was renamed in place.
signal assembly_entry_renamed(list: String, id: String, new_name: String)
## A right-click menu is being built for a component, a body, an assembly entry or the Contact
## Sets folder: the workspace adds its entries (ids from 720 up) to menu.
signal assembly_menu_requested(menu: PopupMenu, meta: Dictionary)
## One of those entries was chosen.
signal assembly_menu_chosen(id: int, meta: Dictionary)

const TOOLBAR := preload("res://addons/holo_forge/ui/toolbar.gd")
const ASSEMBLY_DATA := preload("res://addons/holo_forge/core/assembly/assembly_data.gd")
const FORGE_THEME := preload("res://addons/holo_forge/ui/forge_theme.gd")

const BUTTON_EYE := 0
const BUTTON_LOCK := 1
const BUTTON_ACTIVATE := 2
const BUTTON_GROUND := 3
## A joint's state badge (loop, unresolved, error, waiting); its tooltip is the solve's sentence.
const BUTTON_STATE := 4
## The joint type icons (spec 6.3; team T draws them) and the stand-in until they exist.
const JOINT_ICON_DIR := "res://addons/holo_forge/icons/assemble/"
const JOINT_ICON_FALLBACK := "res://addons/holo_forge/icons/tools/joint.svg"
const ASSEMBLY_ICON_PX := 16.0
## Joint states that get a badge, and the palette colour of its dot.
const STATE_BADGES := {"loop": "assembly_warning", "unresolved": "assembly_unresolved", "error": "assembly_unresolved", "waiting": "assembly_ground"}
## The assembly folders after Joints: [folder, assembly list, item type, default name].
const ASSEMBLY_FOLDERS := [
	["Joint Origins", "origins", "joint_origin", "Origin"], ["Rigid Groups", "rigid_groups", "rigid_group", "Rigid Group"],
	["Motion Links", "links", "motion_link", "Motion Link"], ["Contact Sets", "contact_sets", "contact_set", "Contact Set"],
	["Motion Studies", "studies", "motion_study", "Motion Study"],
]
const CONSTRUCTION_ICONS := {"plane": "PlaneMesh", "axis": "Curve3D", "point": "Marker3D"}
const UNITS := ["mm", "cm", "m", "in", "ft"]
const ORIGIN_ITEMS := [["origin", "O"], ["x_axis", "X"], ["y_axis", "Y"], ["z_axis", "Z"], ["xy_plane", "XY"], ["xz_plane", "XZ"], ["yz_plane", "YZ"]]

## The stand-in for tree button icons the editor theme can't give (see _button_icon()).
static var _blank: Texture2D

## What the items' editor icons are multiplied by (set_icon_tint).
var icon_tint := Color.WHITE

var _context: PopupMenu
var _context_meta := {}
## Folder name -> collapsed, for folders the user opened or closed.
var _collapsed := {}
var _body_items := {}
## True while refresh() rebuilds the tree: selecting the selected bodies' items again must not
## act like clicks (a running command would toggle them out of its body slot).
var _refreshing := false
## The palette the joint state badges and type icons are drawn in (set_assembly_colors).
var _assembly_colors := FORGE_THEME.palette("dark")


func _init() -> void:
	columns = 1
	hide_root = true
	select_mode = Tree.SELECT_SINGLE
	allow_rmb_select = true
	custom_minimum_size = Vector2(220, 0)
	button_clicked.connect(_on_button)
	item_activated.connect(_on_activated)
	item_edited.connect(_on_edited)
	item_selected.connect(_on_selected)
	item_mouse_selected.connect(_on_mouse_selected)
	# Only the user's own toggles are remembered: refresh() setting a folder's state emits this too,
	# and remembering that would keep Analysis, Canvases and Decals shut once entries arrive.
	item_collapsed.connect(func(item: TreeItem) -> void:
		if not _refreshing:
			_collapsed[item.get_text(0)] = item.collapsed)
	_context = PopupMenu.new()
	_context.id_pressed.connect(_on_context)
	add_child(_context)


## Rebuilds the tree. bodies: ordered body ids present after the last rebuild; surfaces: the
## surface bodies among them (id -> true), shown with their own icon; assembly_solve: the last
## assembly solve output (C3.1), whose joint states and sentences badge the joints.
func refresh(doc: Resource, bodies: Array, selected_bodies: Dictionary, surfaces := {}, assembly_solve := {}) -> void:
	_refreshing = true
	_refresh(doc, bodies, selected_bodies, surfaces, assembly_solve)
	_tint_icons()
	_refreshing = false


## Takes the Forge palette (ui/forge_theme.gd) the joint icons and state badges are drawn in; the
## next refresh() uses it.
func set_assembly_colors(palette: Dictionary) -> void:
	_assembly_colors = palette


## Multiplies the items' editor icons and buttons by tint, so they read on the Forge palette's
## background where it isn't as dark as the editor's (forge_theme.gd icon_tint).
func set_icon_tint(tint: Color) -> void:
	if tint == icon_tint:
		return
	icon_tint = tint
	_tint_icons()


func _tint_icons() -> void:
	var item := get_root()
	while item != null:
		item.set_icon_modulate(0, icon_tint)
		for i in item.get_button_count(0):
			# (A state badge keeps its own colour.)
			if item.get_button_id(0, i) != BUTTON_STATE:
				item.set_button_color(0, i, icon_tint)
		item = item.get_next_in_tree()


func _refresh(doc: Resource, bodies: Array, selected_bodies: Dictionary, surfaces: Dictionary, assembly_solve: Dictionary) -> void:
	clear()
	_body_items.clear()
	var root := create_item()
	if doc == null:
		return
	var settings := _folder(root, "Document Settings", "Tools")
	var units := create_item(settings)
	units.set_text(0, "Units: %s" % doc.units)
	units.set_tooltip_text(0, "Click to change the document's length unit.")
	units.set_metadata(0, {"type": "units"})

	var views := _folder(root, "Named Views", "Camera3D")
	for view_name in doc.named_views:
		var item := create_item(views)
		item.set_text(0, view_name)
		item.set_icon(0, _icon("Camera3D"))
		item.set_metadata(0, {"type": "view", "name": view_name})

	var origin := _folder(root, "Origin", "Node3D")
	for spec in ORIGIN_ITEMS:
		var item := create_item(origin)
		item.set_text(0, spec[1])
		item.set_metadata(0, {"type": "origin", "key": spec[0]})
		_add_eye(item, bool(doc.origin_visibility.get(spec[0], true)))

	var analyses := _folder(root, "Analysis", "Search")
	if not _collapsed.has("Analysis"):
		analyses.collapsed = doc.analyses.is_empty()
	for entry in doc.analyses:
		var item := create_item(analyses)
		item.set_text(0, str(entry.get("name", "Analysis")))
		item.set_icon(0, _icon("Search"))
		item.set_tooltip_text(0, "Double-click to change its options; right-click to rename or delete.")
		item.set_metadata(0, {"type": "analysis", "id": str(entry.get("id", ""))})
		_add_eye(item, bool(entry.get("visible", true)))
	_add_assembly(root, doc, assembly_solve)

	var sketches := _folder(root, "Sketches", "Path2D")
	for feature in doc.features:
		if feature.type != "sketch":
			continue
		var item := create_item(sketches)
		item.set_text(0, feature.label)
		item.set_icon(0, _icon("Path2D"))
		item.set_tooltip_text(0, "Double-click to edit")
		item.set_metadata(0, {"type": "sketch", "id": feature.id})
		_add_eye(item, bool(feature.options.get("visible", true)))

	for spec in [["Canvases", "canvases", "Image"], ["Decals", "decals", "ImageTexture"]]:
		var folder := _folder(root, spec[0], spec[2])
		var entries: Array = doc.get(spec[1])
		if not _collapsed.has(spec[0]):
			folder.collapsed = entries.is_empty()
		for entry in entries:
			var item := create_item(folder)
			item.set_text(0, str(entry.get("name", spec[0])))
			item.set_icon(0, _icon(spec[2]))
			item.set_tooltip_text(0, "Double-click to change it; right-click to rename or delete.")
			item.set_metadata(0, {"type": "image", "list": spec[1], "id": str(entry.get("id", ""))})
			_add_eye(item, bool(entry.get("visible", true)))

	var body_folder := _folder(root, "Bodies", "MeshInstance3D")
	for body_id in bodies:
		var settings_for: Dictionary = doc.body_settings(body_id)
		var item := create_item(body_folder)
		item.set_text(0, doc.body_name(body_id))
		item.set_icon(0, _icon("PlaneMesh" if surfaces.has(body_id) else "MeshInstance3D"))
		item.set_metadata(0, {"type": "body", "id": body_id})
		var component: String = doc.body_component(body_id)
		item.set_tooltip_text(0, "In %s" % (doc.component_name(component) if component != "" else "the top level"))
		_add_eye(item, bool(settings_for.get("visible", true)))
		var locked := bool(settings_for.get("locked", false))
		item.add_button(0, _button_icon("Lock" if locked else "Unlock"), BUTTON_LOCK, false, "Unselectable" if locked else "Selectable")
		_body_items[body_id] = item
		if selected_bodies.has(body_id):
			item.select(0)

	var components := _folder(root, "Components", "PackedScene")
	var component_items := {"": create_item(components)}
	component_items[""].set_text(0, "(Top level)")
	component_items[""].set_metadata(0, {"type": "component", "id": ""})
	_add_activate(component_items[""], doc.active_component == "")
	# Parents before children: keep adding until every component has a place.
	var pending: Array = doc.components.keys()
	var guard := 0
	while not pending.is_empty() and guard < 64:
		guard += 1
		for component_id in pending.duplicate():
			var parent := str(doc.components[component_id].get("parent", ""))
			if not component_items.has(parent) and doc.components.has(parent):
				continue
			var item := create_item(component_items.get(parent, component_items[""]))
			item.set_text(0, doc.component_name(component_id))
			item.set_icon(0, _icon("PackedScene"))
			item.set_tooltip_text(0, "Double-click to rename. The round button makes it active: new bodies go into it.")
			item.set_metadata(0, {"type": "component", "id": component_id})
			_add_eye(item, bool(doc.components[component_id].get("visible", true)))
			_add_activate(item, doc.active_component == component_id)
			if parent == "" or not doc.components.has(parent):
				var grounded := ASSEMBLY_DATA.is_grounded(_assembly_of(doc), str(component_id))
				item.add_button(0, _ground_icon(grounded), BUTTON_GROUND, false, "Unground" if grounded else "Ground")
			component_items[component_id] = item
			pending.erase(component_id)

	var construction := _folder(root, "Construction", "PlaneMesh")
	for feature in doc.features:
		if not CONSTRUCTION_ICONS.has(feature.type):
			continue
		var item := create_item(construction)
		item.set_text(0, feature.label)
		item.set_icon(0, _icon(CONSTRUCTION_ICONS[feature.type]))
		item.set_tooltip_text(0, "Double-click to edit")
		item.set_metadata(0, {"type": "construction", "id": feature.id})
		_add_eye(item, bool(feature.options.get("visible", true)))


## The Joints folder and the assembly folders after it (C7.5).
func _add_assembly(root: TreeItem, doc: Resource, solve: Dictionary) -> void:
	var assembly := _assembly_of(doc)
	var states: Dictionary = solve.get("joints", {}) if solve.get("joints") is Dictionary else {}
	var joints := _folder(root, "Joints", "PinJoint3D")
	if not _collapsed.has("Joints"):
		joints.collapsed = assembly.joints.is_empty()
	for joint in assembly.joints:
		if not joint is Dictionary:
			continue
		var id := str(joint.get("id", ""))
		var type := str(joint.get("type", ASSEMBLY_DATA.DEFAULT_TYPE))
		var solved: Dictionary = states.get(id, {})
		var state := str(solved.get("state", ""))
		var item := create_item(joints)
		item.set_text(0, str(joint.get("name", ASSEMBLY_DATA.name_for("joint", id))))
		item.set_icon(0, _joint_icon(type))
		var tooltip := "%s joint. Double-click to edit." % type.capitalize().replace("_", "-")
		if bool(joint.get("suppressed", false)):
			tooltip = "Suppressed. " + tooltip
			item.set_custom_color(0, Color(_assembly_colors.get("toolbar_ink", Color.WHITE), 0.5))
		item.set_tooltip_text(0, tooltip)
		item.set_metadata(0, {"type": "joint", "id": id, "joint_type": type, "state": state})
		_add_eye(item, bool(joint.get("visible", true)))
		if STATE_BADGES.has(state):
			item.add_button(0, _state_dot(_assembly_colors.get(STATE_BADGES[state], Color.ORANGE)), BUTTON_STATE, false, str(solved.get("sentence", state.capitalize())))
	for spec in ASSEMBLY_FOLDERS:
		var entries: Array = assembly.get(spec[1], [])
		var folder := _folder(root, spec[0], "Node3D")
		folder.visible = not entries.is_empty()
		if spec[1] == "contact_sets":
			# Its right-click menu holds Contact Settings... (spec 3.9).
			folder.set_selectable(0, true)
			folder.set_metadata(0, {"type": "contact_folder"})
			folder.set_tooltip_text(0, "Right-click for Contact Settings.")
		for entry in entries:
			if not entry is Dictionary:
				continue
			var id := str(entry.get("id", ""))
			var item := create_item(folder)
			item.set_text(0, str(entry.get("name", spec[3])))
			item.set_icon(0, _joint_icon("origin") if spec[2] == "joint_origin" else _icon("Node3D"))
			item.set_metadata(0, {"type": spec[2], "list": spec[1], "id": id})
			if entry.has("visible"):
				_add_eye(item, bool(entry.get("visible", true)))


## The document's assembly with every key filled (assembly_data.gd normalized()).
static func _assembly_of(doc: Resource) -> Dictionary:
	var stored: Variant = doc.get("assembly") if doc != null else null
	return ASSEMBLY_DATA.normalized(stored if stored is Dictionary else {})


## A joint type's icon (icons/assemble/joint_<type>.svg, or the Joint tool's icon until it exists);
## "origin" gives the Joint Origin icon.
func _joint_icon(type: String) -> Texture2D:
	var ink: Color = _assembly_colors.get("toolbar_ink", Color("#dfe3ea"))
	var paths := [JOINT_ICON_DIR + "joint_%s.svg" % type, JOINT_ICON_FALLBACK]
	if type == "origin":
		paths = [JOINT_ICON_DIR + "joint_origin.svg", "res://addons/holo_forge/icons/tools/joint_origin.svg", JOINT_ICON_FALLBACK]
	for path in paths:
		var icon := TOOLBAR.file_icon(path, ASSEMBLY_ICON_PX, ink)
		if icon != null:
			return icon
	return _button_icon("PinJoint3D")


## The ground button's icon: icons/assemble/ground.svg or unground.svg when they exist, else a pin
## drawn here.
func _ground_icon(grounded: bool) -> Texture2D:
	var ink: Color = _assembly_colors.get("toolbar_ink", Color("#dfe3ea"))
	var icon := TOOLBAR.file_icon(JOINT_ICON_DIR + ("unground.svg" if grounded else "ground.svg"), ASSEMBLY_ICON_PX, ink)
	if icon != null:
		return icon
	var image := Image.create_empty(16, 16, false, Image.FORMAT_RGBA8)
	var color: Color = _assembly_colors.get("assembly_ground", Color("#9aa4b2"))
	if not grounded:
		color.a = 0.45
	# A block on a base line.
	image.fill_rect(Rect2i(5, 4, 6, 6), color)
	image.fill_rect(Rect2i(2, 11, 12, 2), color)
	return ImageTexture.create_from_image(image)


## A 16 px button texture with a 8 px dot of color in the middle (a joint's state badge).
static func _state_dot(color: Color) -> Texture2D:
	var image := Image.create_empty(16, 16, false, Image.FORMAT_RGBA8)
	for y in 16:
		for x in 16:
			var d := Vector2(x + 0.5, y + 0.5).distance_to(Vector2(8, 8))
			if d <= 4.5:
				image.set_pixel(x, y, Color(color, clampf(4.5 - d, 0.0, 1.0) * color.a))
	return ImageTexture.create_from_image(image)


func body_item(body_id: String) -> TreeItem:
	return _body_items.get(body_id)


## The item of an entry by its type ("analysis", "image", "sketch", "construction", ...) and id,
## or null (for tests: press its eye with button_clicked).
func item_for(type: String, id: String) -> TreeItem:
	var item := get_root()
	while item != null:
		var meta = item.get_metadata(0)
		if meta is Dictionary and str(meta.get("type", "")) == type and str(meta.get("id", "")) == id:
			return item
		item = item.get_next_in_tree()
	return null


func _folder(parent: TreeItem, text: String, icon_name: String) -> TreeItem:
	var item := create_item(parent)
	item.set_text(0, text)
	item.set_icon(0, _icon(icon_name))
	item.set_selectable(0, false)
	item.collapsed = bool(_collapsed.get(text, text in ["Origin", "Document Settings", "Analysis", "Joints", "Construction"]))
	return item


func _add_activate(item: TreeItem, active: bool) -> void:
	item.add_button(0, _button_icon("GuiRadioChecked" if active else "GuiRadioUnchecked"), BUTTON_ACTIVATE, false, "Active component" if active else "Activate")


func _add_eye(item: TreeItem, visible: bool) -> void:
	item.add_button(0, _button_icon("GuiVisibilityVisible" if visible else "GuiVisibilityHidden"), BUTTON_EYE, false, "Hide" if visible else "Show")


func _on_button(item: TreeItem, _column: int, id: int, _mouse_button: int) -> void:
	var meta = item.get_metadata(0)
	if not meta is Dictionary:
		return
	match str(meta.type):
		"body":
			if id == BUTTON_EYE:
				body_visibility_toggled.emit(meta.id)
			elif id == BUTTON_LOCK:
				body_selectable_toggled.emit(meta.id)
		"origin":
			origin_visibility_toggled.emit(meta.key)
		"sketch":
			sketch_visibility_toggled.emit(meta.id)
		"construction":
			construction_visibility_toggled.emit(meta.id)
		"analysis":
			analysis_visibility_toggled.emit(meta.id)
		"image":
			image_visibility_toggled.emit(meta.list, meta.id)
		"component":
			if id == BUTTON_ACTIVATE:
				component_activated.emit(meta.id)
			elif id == BUTTON_EYE:
				component_visibility_toggled.emit(meta.id)
			elif id == BUTTON_GROUND:
				component_ground_toggled.emit(meta.id)
		"joint":
			if id == BUTTON_EYE:
				assembly_visibility_toggled.emit("joints", meta.id)
		"joint_origin", "rigid_group", "motion_link", "contact_set", "motion_study":
			if id == BUTTON_EYE:
				assembly_visibility_toggled.emit(str(meta.list), meta.id)


func _on_activated() -> void:
	var item := get_selected()
	if item == null:
		return
	var meta = item.get_metadata(0)
	if not meta is Dictionary:
		return
	match str(meta.type):
		"body":
			_begin_rename(item)
		"view":
			named_view_activated.emit(meta.name)
		"sketch":
			sketch_edit_requested.emit(meta.id)
		"construction":
			construction_edit_requested.emit(meta.id)
		"analysis":
			analysis_edit_requested.emit(meta.id)
		"image":
			image_edit_requested.emit(meta.list, meta.id)
		"joint":
			joint_edit_requested.emit(meta.id)
		"component":
			if meta.id != "":
				_begin_rename(item)


func _on_selected() -> void:
	if _refreshing:
		return
	var item := get_selected()
	var meta = item.get_metadata(0) if item != null else null
	if meta is Dictionary:
		match str(meta.type):
			"body":
				body_clicked.emit(meta.id)
			"units":
				_show_units_menu()
			"view":
				named_view_activated.emit(meta.name)
			"construction":
				construction_clicked.emit(meta.id)
			"origin":
				origin_clicked.emit(meta.key)
			"joint":
				joint_clicked.emit(meta.id)
			"component":
				if str(meta.id) != "":
					component_clicked.emit(meta.id)
			"joint_origin", "rigid_group", "motion_link", "contact_set", "motion_study":
				assembly_entry_clicked.emit(str(meta.list), str(meta.id))


## Starts renaming the selected item (an assembly entry's Rename).
func rename_selected() -> void:
	var item := get_selected()
	if item != null:
		_begin_rename(item)


func _on_mouse_selected(mouse_position: Vector2, mouse_button: int) -> void:
	if mouse_button != MOUSE_BUTTON_RIGHT:
		return
	var item := get_selected()
	var meta = item.get_metadata(0) if item != null else null
	_context.clear()
	_context_meta = meta if meta is Dictionary else {}
	match str(_context_meta.get("type", "")):
		"body":
			var visible := item.get_button_tooltip_text(0, item.get_button_by_id(0, BUTTON_EYE)) == "Hide"
			_context.add_item("Rename", 0)
			_context.add_item("Hide" if visible else "Show", 1)
			_context.add_item("Toggle Selectable", 2)
			_context.add_item("Find in Timeline", 3)
			_context.add_separator()
			_context.add_item("Delete", 4)
		"view":
			_context.add_item("Go to View", 10)
			_context.add_item("Rename", 11)
			_context.add_item("Delete", 12)
		"analysis":
			var visible := item.get_button_tooltip_text(0, item.get_button_by_id(0, BUTTON_EYE)) == "Hide"
			_context.add_item("Edit", 30)
			_context.add_item("Rename", 31)
			_context.add_item("Hide" if visible else "Show", 32)
			_context.add_separator()
			_context.add_item("Delete", 33)
		"image":
			var visible := item.get_button_tooltip_text(0, item.get_button_by_id(0, BUTTON_EYE)) == "Hide"
			_context.add_item("Edit", 40)
			_context.add_item("Rename", 41)
			_context.add_item("Hide" if visible else "Show", 42)
			_context.add_separator()
			_context.add_item("Delete", 43)
		"component", "joint", "joint_origin", "rigid_group", "motion_link", "contact_set", "motion_study", "contact_folder":
			# (The workspace knows what applies: grounded, placed, suppressed, the selection.)
			pass
		_:
			_context.add_item("Save Current View...", 20)
	if str(_context_meta.get("type", "")) in ["body", "component", "joint", "joint_origin", "rigid_group", "motion_link", "contact_set", "motion_study", "contact_folder"]:
		assembly_menu_requested.emit(_context, _context_meta)
	if _context.item_count == 0:
		return
	_context.position = Vector2i(get_screen_position() + mouse_position)
	_context.popup()


func _on_context(id: int) -> void:
	var meta := _context_meta
	match id:
		0:
			var item: TreeItem = _body_items.get(meta.get("id", ""))
			if item != null:
				_begin_rename(item)
		1:
			body_visibility_toggled.emit(meta.id)
		2:
			body_selectable_toggled.emit(meta.id)
		3:
			body_feature_requested.emit(meta.id)
		4:
			body_delete_requested.emit(meta.id)
		10:
			named_view_activated.emit(meta.name)
		11:
			var item := get_selected()
			if item != null:
				_begin_rename(item)
		12:
			named_view_deleted.emit(meta.name)
		20:
			save_view_requested.emit()
		30:
			analysis_edit_requested.emit(meta.id)
		31:
			var item := get_selected()
			if item != null:
				_begin_rename(item)
		32:
			analysis_visibility_toggled.emit(meta.id)
		33:
			analysis_delete_requested.emit(meta.id)
		40:
			image_edit_requested.emit(meta.list, meta.id)
		41:
			var item := get_selected()
			if item != null:
				_begin_rename(item)
		42:
			image_visibility_toggled.emit(meta.list, meta.id)
		43:
			image_delete_requested.emit(meta.list, meta.id)
		_:
			if id >= 720 and id < 800:
				assembly_menu_chosen.emit(id, meta)


func _begin_rename(item: TreeItem) -> void:
	item.set_editable(0, true)
	item.select(0)
	edit_selected(true)


func _on_edited() -> void:
	var item := get_edited()
	if item == null:
		return
	item.set_editable(0, false)
	var meta = item.get_metadata(0)
	if not meta is Dictionary:
		return
	var text := item.get_text(0).strip_edges()
	match str(meta.type):
		"body":
			if text != "":
				body_renamed.emit(meta.id, text)
		"view":
			if text != "" and text != meta.name:
				named_view_renamed.emit(meta.name, text)
		"component":
			if text != "":
				component_renamed.emit(meta.id, text)
		"analysis":
			if text != "":
				analysis_renamed.emit(meta.id, text)
		"image":
			if text != "":
				image_renamed.emit(meta.list, meta.id, text)
		"joint":
			if text != "":
				assembly_entry_renamed.emit("joints", str(meta.id), text)
		"joint_origin", "rigid_group", "motion_link", "contact_set", "motion_study":
			if text != "":
				assembly_entry_renamed.emit(str(meta.list), str(meta.id), text)


func _show_units_menu() -> void:
	_context.clear()
	_context_meta = {"type": "units"}
	for i in UNITS.size():
		_context.add_item(UNITS[i], 100 + i)
	_context.id_pressed.connect(_on_units_picked, CONNECT_ONE_SHOT)
	_context.position = Vector2i(get_screen_position() + get_local_mouse_position())
	_context.popup()


func _on_units_picked(id: int) -> void:
	if id >= 100 and id - 100 < UNITS.size():
		units_changed.emit(UNITS[id - 100])


static func _icon(name: String) -> Texture2D:
	if not Engine.is_editor_hint():
		return null
	var theme := EditorInterface.get_editor_theme()
	return theme.get_icon(name, "EditorIcons") if theme != null and theme.has_icon(name, "EditorIcons") else null


## An icon for a tree button, which needs a texture: a blank one where the editor's is missing
## (outside the editor, in headless test runs).
static func _button_icon(name: String) -> Texture2D:
	var icon := _icon(name)
	if icon != null:
		return icon
	if _blank == null:
		_blank = ImageTexture.create_from_image(Image.create_empty(16, 16, false, Image.FORMAT_RGBA8))
	return _blank
