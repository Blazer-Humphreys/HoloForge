@tool
extends VBoxContainer
## The Forge workspace (the "Forge" main-screen tab).
##
## It edits the document of the CadPart selected in the scene: rebuilds it through the kernel,
## shows the bodies, runs commands with live previews, and records every change as one editor
## undo step on that part's scene. The part's baked children update as you work. The tab is drawn
## dark or light (set_theme_mode, ui/forge_theme.gd).

const CAD_PART := preload("res://addons/holo_forge/nodes/cad_part.gd")
const DOCUMENT := preload("res://addons/holo_forge/core/document.gd")
const REGEN := preload("res://addons/holo_forge/core/regen.gd")
const TESSELLATE := preload("res://addons/holo_forge/core/tessellate.gd")
const PARAMETERS := preload("res://addons/holo_forge/core/parameters.gd")
const UNITS := preload("res://addons/holo_forge/core/units.gd")
const DIMENSION_LAYOUT := preload("res://addons/holo_forge/core/sketch/dimension_layout.gd")
## The hint of a field whose expression a handle drag replaced (drag_replaced).
const DRAG_REPLACED_NOTE := "Was %s: the drag set a number (Undo or type it again to keep the link)."
const PICKING := preload("res://addons/holo_forge/core/picking.gd")
const OPERATIONS := preload("res://addons/holo_forge/core/operations.gd")
const CATALOG := preload("res://addons/holo_forge/tools/catalog.gd")
const TOOLBAR := preload("res://addons/holo_forge/ui/toolbar.gd")
const BROWSER := preload("res://addons/holo_forge/ui/browser.gd")
const TIMELINE := preload("res://addons/holo_forge/ui/timeline.gd")
const VIEWPORT := preload("res://addons/holo_forge/ui/forge_viewport.gd")
const COMMAND_PANEL := preload("res://addons/holo_forge/ui/command_panel.gd")
const PARAMETERS_DIALOG := preload("res://addons/holo_forge/ui/parameters_dialog.gd")
const MARKING_MENU := preload("res://addons/holo_forge/ui/marking_menu.gd")
const COMMAND_SEARCH := preload("res://addons/holo_forge/ui/command_search.gd")
const SKETCH_EDITOR := preload("res://addons/holo_forge/ui/sketch_editor.gd")
const FORM_EDITOR := preload("res://addons/holo_forge/ui/form_editor.gd")
const FORM := preload("res://addons/holo_forge/core/features/form.gd")
const SKETCH_DATA := preload("res://addons/holo_forge/core/sketch/sketch_data.gd")
const FEATURE_PICKER := preload("res://addons/holo_forge/ui/feature_picker.gd")
const REFERENCES := preload("res://addons/holo_forge/core/references.gd")
const ANALYSIS := preload("res://addons/holo_forge/core/analysis.gd")
const APPEARANCE := preload("res://addons/holo_forge/core/appearance.gd")
const APPEARANCE_PANEL := preload("res://addons/holo_forge/ui/appearance_panel.gd")
const ANALYSIS_COMMAND := preload("res://addons/holo_forge/tools/analysis_command.gd")
const IMAGE_COMMAND := preload("res://addons/holo_forge/tools/image_command.gd")
const MATERIAL_LIBRARY := preload("res://addons/holo_forge/core/material_library.gd")
const FORGE_FILES := preload("res://addons/holo_forge/ui/forge_files.gd")
const FORGE_THEME := preload("res://addons/holo_forge/ui/forge_theme.gd")
const MESH_BODY := preload("res://addons/holo_forge/core/mesh/mesh_body.gd")
const MESH_FEATURE := preload("res://addons/holo_forge/core/features/mesh.gd")
const MESH_SELECTION := preload("res://addons/holo_forge/ui/mesh_selection.gd")
const MESH_DIRECT_EDIT := preload("res://addons/holo_forge/ui/mesh_direct_edit.gd")
const ASSEMBLY_DATA := preload("res://addons/holo_forge/core/assembly/assembly_data.gd")
const ASSEMBLY_SOLVER := preload("res://addons/holo_forge/core/assembly/solver.gd")
const ASSEMBLY_DISPLAY := preload("res://addons/holo_forge/ui/assembly_display.gd")
const XFORM := preload("res://addons/holo_forge/core/assembly/xform64.gd")
const MOTION_STUDY_PANEL := preload("res://addons/holo_forge/ui/motion_study_panel.gd")
const ASSEMBLE_JOINT := "res://addons/holo_forge/tools/assemble_joint_command.gd"
const ASSEMBLE_DRIVE := "res://addons/holo_forge/tools/assemble_drive_command.gd"
const ASSEMBLE_PLACE := "res://addons/holo_forge/tools/assemble_place_command.gd"
const ASSEMBLE_CONTACT := "res://addons/holo_forge/tools/assemble_contact_command.gd"
## The browser's assembly menu entries (ids past the browser's own and the Mesh entries).
const ASSEMBLY_MENU := {
	"edit": 720, "drive": 721, "rename": 722, "suppress": 723, "delete": 724, "ground": 725, "place": 726,
	"reset": 727, "new_set": 728, "move_to": 729, "set_enabled": 730, "add_selected": 731, "remove_selected": 732,
	"contact_settings": 733, "open_study": 734,
}
## The assembly lists by browser item type.
const ASSEMBLY_ITEM_LISTS := {
	"joint": "joints", "joint_origin": "origins", "rigid_group": "rigid_groups", "motion_link": "links", "contact_set": "contact_sets",
	"motion_study": "studies",
}
const NESTED_GROUND_TIP := "Nested components move with their top-level component."
const FEATURE_COMMAND := "res://addons/holo_forge/tools/feature_command.gd"
const INSERT_COMMAND := "res://addons/holo_forge/tools/insert_command.gd"
const SHORTCUTS_SETTING := "holo_forge/shortcut_overrides"
## Where the command panel's top sits in the view (below the view cube).
const PANEL_TOP := 150.0
## The room the status line leaves on the right of the view (the view cube and its home button).
const STATUS_RIGHT_MARGIN := 150.0
## Frames drawn between a Mesh tool's OK and its full-time rebuild, so the panel is seen to say
## that it is working.
const ACCEPT_DELAY_FRAMES := 2
## Document lists that change only what the view overlays (and the part's baked decals): a
## change to nothing else redraws them without replaying the timeline.
const VIEW_KEYS := ["analyses", "canvases", "decals"]
## The document's assembly: a change to nothing else re-solves and re-poses (_refresh_assembly())
## without replaying the timeline. Kept apart from VIEW_KEYS so the two stay distinguishable.
const ASSEMBLY_KEYS := ["assembly"]
## The Mesh workspace's own actions: the pick modes and the selection helpers (Mesh > Select).
const MESH_SELECT_ACTIONS := ["mesh_pick_groups", "mesh_pick_triangles", "mesh_grow", "mesh_shrink", "mesh_connected", "mesh_boundary"]
const MESH_WORKSPACE := "Mesh"
## Passthrough: where it is saved, and what the view says when it can't show or leaves scale out.
const PASSTHROUGH_KEY := "passthrough"
const S_PASSTHROUGH_NO_PART := "Passthrough needs a part: select a CadPart in a 3D scene."
const S_PASSTHROUGH_NO_SCENE := "Passthrough needs the part in an open 3D scene."
const S_PASSTHROUGH_SCALE := "Passthrough shows the part at its modelled size; its scale in the scene (%s, %s, %s) is left out."
const NO_MESH_BODY :="There is no mesh body yet. Insert a mesh (Mesh > Create > Insert Mesh) or Tessellate a body."
## Ids of the entries the workspace adds to the browser's body menu.
const BROWSER_CONVERT := 700
const BROWSER_REDUCE := 701
const BROWSER_CLOSE_HOLES := 702
const BROWSER_TESSELLATE := 703
## A window or freeform selection checks each triangle against what hides it only up to this
## many triangles (above it, triangles facing away are left out and nothing else).
const REGION_HIDDEN_CHECKS := 20000
## Paint selection's brush radius on screen.
const PAINT_PX := 14.0

signal recomputed(result: Dictionary)
signal message_shown(text: String)
## The view selection changed (or the design rebuilt, which can drop picks).
signal selection_updated

var plugin: EditorPlugin
var part: Node3D
var doc: Resource
var kernel: RefCounted
var result := {}
var tessellations := {}
## The shapes the tessellations were made from (body id -> CadShape): a rebuild that hands back the
## same shape object (Insert Mesh's kept solids, Derive's cached source, an untouched body) keeps
## its tessellation, since meshing tens of thousands of faces again takes seconds.
var _tessellated_shapes := {}
var selection: Array[Dictionary] = []
var hover := {}
var workspace := "Solid"
var command: RefCounted
var command_values := {}
## Fields of the open command whose expression a handle drag replaced with a number: key ->
## {"was": the expression, "now": the text the drag wrote}. The field's hint says so (the link to a
## parameter is gone) until the field is typed in or the command ends.
var drag_replaced := {}
var last_tool := {}
var last_message := ""

var toolbar: HBoxContainer
var browser: Tree
var timeline: PanelContainer
var viewport: Control
var panel: PanelContainer
var parameters_dialog: AcceptDialog
var marking_menu: Control
var command_search: PanelContainer
var sketch_editor: RefCounted
## The Form environment (ui/form_editor.gd).
var form_editor: RefCounted
## The id of the form feature open in the Form environment ("" for none): rebuilds preview it
## (no conversion, the timeline stops after it) and don't bake.
var form_preview := ""
var picker: RefCounted
var appearance_panel: PanelContainer
## Insert and export: file dialogs, option prompts and the changes they make (ui/forge_files.gd).
var files: Node
## The Mesh workspace's selection (ui/mesh_selection.gd): triangles of mesh bodies, picked as
## face groups or one by one.
var mesh_selection: RefCounted
## Direct Edit (ui/mesh_direct_edit.gd).
var mesh_direct_edit: RefCounted
## Display Mesh Face Groups: mesh bodies draw each face group in a colour of its own (view only).
var mesh_face_groups := false
## The time limit (seconds) the last rebuild gave Mesh features: MESH_FEATURE.PREVIEW_SECONDS while
## a Mesh tool previews, else OK_SECONDS.
var last_mesh_limit := 0.0
## What the appearances of the bodies shown say (APPEARANCE.build_mesh notes: a face group's
## appearance that followed its group to another name, or is not shown), for the status line.
var appearance_notes := PackedStringArray()
## True while OK computes a Mesh tool's feature with the full time limit.
var _accepting_mesh := false
## A deferred check of the command panel against the bodies the open Mesh tool works on is queued
## (_queue_mesh_panel_check): "home" places the panel again from its own spot, "keep" only moves
## it when it covers them, "" none.
var _mesh_panel_check := ""
## True between a Mesh tool's OK and its full-time rebuild (accept_from_ui()).
var _mesh_accept_pending := false
## What the panel was last placed for while it still covered the bodies: [their screen rectangle,
## the view's size, the panel's size].
var _mesh_panel_placed := []
## What is under the cursor for the running Mesh tool's active slot (a view pick, or {}).
var _mesh_hover := {}
## The visible analyses after the last refresh: id -> {"name", "info", "error"}.
var analysis_results := {}
## How many times recompute() has replayed the timeline (REGEN.rebuild), for tests.
var rebuild_count := 0
## How many times an analysis was built (ANALYSIS.build) rather than taken from the cache, for tests.
var analysis_build_count := 0
## The last undo step recorded: {"name", "before", "after"} (doc.snapshot()s), for tests.
var last_step := {}
## How many undo steps the workspace has recorded (for tests: one edit, one step).
var undo_step_count := 0
## The Motion Study panel (made when first opened).
var motion_study_panel: PanelContainer
## Components picked in the browser (New Contact Set takes them with the selected bodies).
var selected_components: Array = []
## The assembly entry selected in the browser or the view ({"list", "id"}; {} for none).
var selected_assembly := {}
## The last assembly solve (core/assembly/solver.gd solve() output) and how many times
## _refresh_assembly() made one, for tests.
var assembly_solve := {}
var assembly_refresh_count := 0
## doc.assembly as _refresh_assembly() last solved it.
var _solved_assembly := {}
## Poses the bodies from assembly_solve and draws the assembly's glyphs (ui/assembly_display.gd).
var assembly_display: RefCounted

var _command_before := {}
var _recompute_queued := false
var _view_refresh_queued := false
var _analysis_label: Label
var _placeholder: CenterContainer
var _status: Label
var _status_timer: Timer
var _prompt: ConfirmationDialog
var _prompt_edit: LineEdit
var _prompt_callback: Callable
var _plane_pick := false
## (frame: Dictionary, plane_ref: String) -> void: what the plane pick is for (Insert SVG/DXF);
## invalid means Create Sketch.
var _plane_pick_callback := Callable()
## A sketch tool to start once Create Sketch has its plane (pressing L outside a sketch).
var _pending_sketch_tool := ""
## Canvas and decal images by path: {"stamp", "texture"} (read again when the file changes).
var _textures := {}
## The model the last rebuild was made from (_model_of(doc.snapshot())), {} before one.
var _rebuilt_model := {}
## The last rebuild of the whole timeline (not a Mesh tool's preview that stopped after its
## feature): what the features after a previewed one made is held over from it.
var _whole_result := {}
## doc.decals as the part last baked them.
var _baked_decals: Array = []
## True while the view shows bodies a command previewed (preview_bodies) instead of the rebuild's.
var _bodies_previewed := false
## The tool shape a Join or Cut command draws (_show_operation_preview), and its looks by operation.
const OPERATION_PREVIEW_COLORS := {"join": Color(0.3, 0.85, 0.45, 0.4), "cut": Color(0.95, 0.32, 0.26, 0.4)}
var _operation_preview_shape: Variant = null
var _operation_preview_materials := {}
## Built analyses by entry id: {"input": {"type", "options"} as built, "built": ANALYSIS.build()
## output}, valid for _analysis_cache_result and the bodies in _analysis_cache_bodies.
var _analysis_cache := {}
var _analysis_cache_result: Variant = null
var _analysis_cache_bodies: Array = []
## The ids of the analyses the view showed last, and a number that changes whenever what they
## draw does (the view keeps its analysis nodes while it stays the same).
var _analysis_shown: Array = []
var _analysis_version := 0

## The appearance the user picked: "dark", "light" or "editor" (follow the editor's theme); see
## set_theme_mode and ui/forge_theme.gd.
var theme_mode := FORGE_THEME.DEFAULT_MODE
## The palette shown now ("dark" or "light") and its colours.
var theme_name := "dark"
var theme_colors := {}
## Where theme_mode is saved: null for the default (the editor's project metadata, memory
## outside the editor), or a Dictionary or ConfigFile (tests). Setting it reads the mode saved there.
var theme_store: Variant = null:
	set(value):
		theme_store = value
		theme_mode = FORGE_THEME.read_mode(_theme_store())
		apply_theme()
## Passthrough (Display > Passthrough): the view shows the part where it stands in its 3D scene,
## lit by it (see set_passthrough). Saved per project beside the theme.
var passthrough := false
## Where passthrough is saved: null for the default (as theme_store), or a Dictionary or ConfigFile
## (tests). Setting it reads what is saved there.
var passthrough_store: Variant = null:
	set(value):
		passthrough_store = value
		passthrough = _read_passthrough()
		sync_passthrough()
## The scene Passthrough shows: null for the edited scene (tests set a Node3D in a world of its own).
var passthrough_scene_root: Node = null:
	set(value):
		passthrough_scene_root = value
		sync_passthrough()
var _passthrough_transform := Transform3D.IDENTITY
var _passthrough_hide_queued := false
## Whether the scene world had a light of its own at the last full sync_passthrough.
var _passthrough_lit := false
var _passthrough_scale_noted := false
## The editor's base colour as the "editor" mode sees it: null for the real one (tests set a Color).
var theme_host_base: Variant = null:
	set(value):
		theme_host_base = value
		apply_theme()
## How many times apply_theme ran (for tests).
var theme_apply_count := 0
var _chrome_color := Color(0, 0, 0, 0)
## What the status line shows: "status", "info" (a flash) or "error"; it takes that palette colour.
var _status_kind := "status"
var _theme_queued := false


func _init() -> void:
	name = "Forge"
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	kernel = REGEN.make_kernel()

	toolbar = TOOLBAR.new()
	toolbar.workspace_changed.connect(func(value: String) -> void:
		workspace = value
		_on_workspace_changed()
		_flash("%s workspace" % value))
	toolbar.tool_activated.connect(run_tool)
	toolbar.select_option_changed.connect(_on_select_option)
	toolbar.parameters_requested.connect(open_parameters)
	toolbar.theme_mode_requested.connect(set_theme_mode)
	add_child(toolbar)

	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(split)
	browser = BROWSER.new()
	split.add_child(browser)
	viewport = VIEWPORT.new()
	viewport.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	viewport.key_handler = handle_key
	viewport.snap_step = 0.001
	split.add_child(viewport)

	timeline = TIMELINE.new()
	add_child(timeline)

	_status = Label.new()
	_status.position = Vector2(10, 8)
	_status.add_theme_color_override("font_color", Color(0.12, 0.13, 0.16))
	_status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# A long message (a feature's refusal, an insert with its warning) wraps inside the view.
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	viewport.add_child(_status)
	viewport.resized.connect(_fit_status)
	_status_timer = Timer.new()
	_status_timer.one_shot = true
	_status_timer.timeout.connect(_update_status)
	add_child(_status_timer)

	# Analysis readouts sit bottom left, above the navigation bar, growing upward.
	_analysis_label = Label.new()
	_analysis_label.anchor_top = 1.0
	_analysis_label.anchor_bottom = 1.0
	_analysis_label.offset_left = 10.0
	_analysis_label.offset_top = -48.0
	_analysis_label.offset_bottom = -48.0
	_analysis_label.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_analysis_label.add_theme_color_override("font_color", Color(0.12, 0.13, 0.16))
	_analysis_label.add_theme_font_size_override("font_size", 13)
	_analysis_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	viewport.add_child(_analysis_label)

	panel = COMMAND_PANEL.new()
	panel.visible = false
	viewport.add_child(panel)
	panel.values_changed.connect(_on_panel_values_changed)
	panel.slider_drag.connect(_on_panel_slider_drag)
	panel.accepted.connect(accept_from_ui)
	panel.cancelled.connect(cancel_command)
	panel.button_pressed.connect(func(key: String) -> void:
		if command != null and command.has_method("on_button"):
			command.on_button(key)
		elif command == null and form_editor != null and form_editor.active:
			form_editor.on_button(key))
	viewport.resized.connect(_place_panel)
	panel.resized.connect(_keep_panel_inside)
	panel.resized.connect(_queue_mesh_panel_check.bind(false))
	viewport.camera_changed.connect(_queue_mesh_panel_check.bind(false))

	appearance_panel = APPEARANCE_PANEL.new(self)
	appearance_panel.visible = false
	viewport.add_child(appearance_panel)
	files = FORGE_FILES.new(self)
	add_child(files)

	marking_menu = MARKING_MENU.new()
	viewport.add_child(marking_menu)
	command_search = COMMAND_SEARCH.new()
	command_search.tool_chosen.connect(run_tool)
	viewport.add_child(command_search)

	sketch_editor = SKETCH_EDITOR.new(self, viewport)
	form_editor = FORM_EDITOR.new(self, viewport)
	mesh_selection = MESH_SELECTION.new()
	mesh_selection.changed.connect(_on_mesh_selection_changed)
	mesh_direct_edit = MESH_DIRECT_EDIT.new(self, viewport)
	_hook_browser_menu()
	picker = FEATURE_PICKER.new(self, viewport)
	picker.kinds_provider = _active_kinds
	picker.picked_provider = _picked_refs
	viewport.outline_provider = _outlines_picks
	picker.picked.connect(_on_reference_picked)
	viewport.draw_handler = func(overlay: Control) -> void:
		sketch_editor.draw(overlay)
		form_editor.draw(overlay)
		picker.draw(overlay)
		_draw_mesh_picks(overlay)
		if _is_inspect(command):
			command.draw(overlay)
	panel.describer = func(item: Variant) -> String:
		if item is Dictionary and str(item.get("kind", "")) == "snap":
			# (An Assemble snap slot's pick: the body and the snap kind, or the Joint Origin.)
			return str(item.get("label", "Snap"))
		if item is Dictionary and str(item.get("kind", "")) == "mesh_boundary":
			# (A hole picked for Close Holes, by the open edges around it.)
			var edges := int(item.get("edges", 0))
			return "Hole (%d edge%s)" % [edges, "" if edges == 1 else "s"] if edges > 0 else "Hole"
		return doc.body_name(item) if item is String and doc != null else REFERENCES.describe(item, doc)
	panel.selection_field_activated.connect(func(_key: String) -> void:
		picker.hover = {}
		picker.update_display())

	parameters_dialog = PARAMETERS_DIALOG.new()
	parameters_dialog.user_parameter_added.connect(_add_user_parameter)
	parameters_dialog.user_parameter_removed.connect(_remove_user_parameter)
	parameters_dialog.user_parameter_changed.connect(_change_user_parameter)
	parameters_dialog.model_expression_changed.connect(_change_model_expression)
	add_child(parameters_dialog)

	_prompt = ConfirmationDialog.new()
	_prompt_edit = LineEdit.new()
	_prompt.add_child(_prompt_edit)
	_prompt.register_text_enter(_prompt_edit)
	_prompt.confirmed.connect(func() -> void:
		if _prompt_callback.is_valid():
			_prompt_callback.call(_prompt_edit.text.strip_edges()))
	add_child(_prompt)

	_placeholder = CenterContainer.new()
	_placeholder.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var box := VBoxContainer.new()
	var label := Label.new()
	label.text = "Select a Forge part (a CadPart node) in the scene, or add one."
	label.add_theme_color_override("font_color", Color(0.12, 0.13, 0.16))
	box.add_child(label)
	var add := Button.new()
	add.text = "Add Forge Part to Scene"
	add.pressed.connect(add_part_to_scene)
	box.add_child(add)
	_placeholder.add_child(box)
	viewport.add_child(_placeholder)

	viewport.pick_clicked.connect(_on_pick_clicked)
	viewport.passthrough_requested.connect(set_passthrough)
	viewport.region_selected.connect(_on_region_selected)
	viewport.paint_picked.connect(_on_paint_picked)
	viewport.hover_changed.connect(func(pick: Dictionary) -> void: hover = pick)
	viewport.context_requested.connect(_open_marking_menu)
	viewport.manipulator_changed.connect(_on_manipulator_changed)
	viewport.manipulator_released.connect(_on_manipulator_released)

	browser.body_visibility_toggled.connect(func(id: String) -> void: _change_body(id, "visible", "Show/Hide Body"))
	browser.body_selectable_toggled.connect(func(id: String) -> void: _change_body(id, "locked", "Toggle Selectable"))
	browser.body_renamed.connect(_rename_body)
	browser.body_clicked.connect(func(id: String) -> void:
		var kinds := _active_kinds()
		if kinds.has("body") or kinds.has("component") or kinds.has("mesh_body"):
			_on_reference_picked({"kind": "body", "body": id} if kinds.has("body") or kinds.has("mesh_body") else {"kind": "component", "component": doc.body_component(id)})
			return
		selection = [{"kind": "body", "body": id, "index": -1, "point": Vector3.ZERO}]
		# (A plain body click starts a new browser selection: picked components and the selected
		# assembly entry go.)
		selected_components.clear()
		_select_assembly_entry({})
		_selection_changed(false))
	browser.construction_visibility_toggled.connect(func(id: String) -> void:
		var feature: Resource = doc.find_feature(id)
		if feature != null:
			_set_feature_option(id, "visible", not bool(feature.options.get("visible", true)), "Show/Hide Construction"))
	browser.construction_clicked.connect(func(id: String) -> void:
		var kinds := _active_kinds()
		var c: Dictionary = result.get("construction", {}).get(id, {})
		if kinds.has(str(c.get("type", ""))):
			_on_reference_picked({"kind": "construct", "feature": id}))
	browser.construction_edit_requested.connect(edit_feature)
	browser.component_activated.connect(activate_component)
	browser.component_visibility_toggled.connect(func(id: String) -> void:
		if doc.components.has(id):
			change("Show/Hide Component", func() -> void:
				if doc.components.has(id):
					doc.components[id]["visible"] = not bool(doc.components[id].get("visible", true))))
	browser.component_renamed.connect(func(id: String, new_name: String) -> void:
		if doc.components.has(id):
			change("Rename Component", func() -> void:
				if doc.components.has(id):
					doc.components[id]["name"] = new_name))
	browser.origin_clicked.connect(func(key: String) -> void:
		var names := {"origin": "o", "x_axis": "x", "y_axis": "y", "z_axis": "z", "xy_plane": "xy", "xz_plane": "xz", "yz_plane": "yz"}
		var kinds := _active_kinds()
		var name: String = names.get(key, "")
		var kind := "point" if name == "o" else ("axis" if name.length() == 1 else "plane")
		if kinds.has(kind):
			_on_reference_picked({"kind": "origin", "name": name}))
	browser.body_delete_requested.connect(func(id: String) -> void: _delete_bodies([id]))
	browser.body_feature_requested.connect(_find_body_feature)
	browser.origin_visibility_toggled.connect(_toggle_origin)
	browser.units_changed.connect(_change_units)
	browser.named_view_activated.connect(go_to_view)
	browser.named_view_renamed.connect(_rename_view)
	browser.named_view_deleted.connect(_delete_view)
	browser.save_view_requested.connect(save_view)
	browser.sketch_visibility_toggled.connect(func(id: String) -> void:
		var feature: Resource = doc.find_feature(id)
		if feature != null:
			_set_feature_option(id, "visible", not bool(feature.options.get("visible", true)), "Show/Hide Sketch"))
	browser.sketch_edit_requested.connect(edit_feature)
	browser.analysis_visibility_toggled.connect(toggle_analysis)
	browser.analysis_edit_requested.connect(edit_analysis)
	browser.analysis_renamed.connect(rename_analysis)
	browser.analysis_delete_requested.connect(delete_analysis)
	browser.image_visibility_toggled.connect(toggle_image)
	browser.image_edit_requested.connect(edit_image)
	browser.image_renamed.connect(rename_image)
	browser.image_delete_requested.connect(delete_image)

	timeline.rollback_changed.connect(set_rollback)
	timeline.feature_edit_requested.connect(edit_feature)
	timeline.feature_suppress_toggled.connect(_toggle_suppress)
	timeline.feature_delete_requested.connect(delete_feature)
	timeline.feature_rename_requested.connect(_rename_feature)
	timeline.feature_group_requested.connect(_group_feature)
	timeline.feature_ungroup_requested.connect(func(id: String) -> void: _set_feature_field(id, "group", "", "Remove from Group"))
	timeline.feature_find_requested.connect(_find_feature_bodies)

	if Engine.is_editor_hint():
		var settings := EditorInterface.get_editor_settings()
		if not settings.has_setting(SHORTCUTS_SETTING):
			settings.set_setting(SHORTCUTS_SETTING, {})
		settings.set_initial_value(SHORTCUTS_SETTING, {}, false)
		settings.add_property_info({"name": SHORTCUTS_SETTING, "type": TYPE_DICTIONARY, "hint_string": "Key letter -> tool id"})

	assembly_display = ASSEMBLY_DISPLAY.new()
	assembly_display.attach(viewport)
	browser.component_ground_toggled.connect(_toggle_ground)
	browser.assembly_visibility_toggled.connect(_toggle_assembly_visible)
	browser.joint_clicked.connect(func(id: String) -> void: select_assembly("joints", id))
	browser.joint_edit_requested.connect(edit_joint)
	browser.component_clicked.connect(func(id: String) -> void: component_clicked(id, Input.is_key_pressed(KEY_CTRL) or Input.is_key_pressed(KEY_SHIFT)))
	browser.assembly_entry_clicked.connect(_on_assembly_entry_clicked)
	browser.assembly_entry_renamed.connect(rename_assembly)
	browser.assembly_menu_requested.connect(_fill_assembly_menu)
	browser.assembly_menu_chosen.connect(_on_assembly_menu)

	theme_mode = FORGE_THEME.read_mode(_theme_store())
	apply_theme()
	passthrough = _read_passthrough()
	viewport.set_passthrough_menu(passthrough, passthrough_blocker())


func _process(_delta: float) -> void:
	# A sketch or form opened or closed outside a command (they don't tell the workspace).
	_sync_modelled_view()
	_follow_passthrough_part()


func _notification(what: int) -> void:
	# The editor's theme changed (or the tab entered it): "editor" may now mean the other palette,
	# and the tab's controls may need their own theme, or no longer.
	if what == NOTIFICATION_THEME_CHANGED and not _theme_queued:
		_theme_queued = true
		_refresh_theme.call_deferred()
	# Passthrough shows the scene only while the tab is shown (the 3D tab draws the part's own nodes).
	if what == NOTIFICATION_VISIBILITY_CHANGED:
		sync_passthrough()
	elif what == NOTIFICATION_EXIT_TREE:
		end_passthrough()


func _draw() -> void:
	# Behind the toolbar and between the panes, where the tab's controls have their own theme.
	if _chrome_color.a > 0.0:
		draw_rect(Rect2(Vector2.ZERO, size), _chrome_color)


# --- Part and rebuild ------------------------------------------------------------------------

## Points the workspace at a CadPart (or null for none).
func set_part(new_part: Node3D) -> void:
	if new_part == part:
		return
	if command != null:
		cancel_command()
	if form_editor != null and form_editor.active:
		form_editor.end_without_recompute()
	form_preview = ""
	if sketch_editor != null and sketch_editor.active:
		sketch_editor.end()
	_end_plane_pick()
	if part != null and is_instance_valid(part) and part.tree_exiting.is_connected(_on_part_leaving):
		part.tree_exiting.disconnect(_on_part_leaving)
	if mesh_direct_edit != null and mesh_direct_edit.active:
		mesh_direct_edit.cancel()
	part = new_part
	doc = null
	selection.clear()
	hover = {}
	_mesh_hover = {}
	if mesh_selection != null:
		mesh_selection.clear()
	if part != null:
		if part.document == null:
			part.document = DOCUMENT.new()
		doc = part.document
		part.tree_exiting.connect(_on_part_leaving)
		viewport.unit_scale = float(UNITS.LENGTH_UNITS.get(doc.units, 0.001))
	_placeholder.visible = part == null
	toolbar.set_part_name(part.name if part != null else "")
	selected_components.clear()
	selected_assembly = {}
	if motion_study_panel != null and motion_study_panel.visible:
		motion_study_panel.close()
	recompute()
	viewport.fit()
	_sync_contact_toggle()
	if doc != null and doc.assembly is Dictionary and ASSEMBLY_DATA.is_newer(doc.assembly):
		# Shown, never edited here (C1.6).
		_flash(ASSEMBLY_DATA.S_NEWER_ASSEMBLY)
	_passthrough_scale_noted = false
	sync_passthrough()


## Replays the timeline, redraws everything and refreshes the part's baked bodies.
func recompute() -> void:
	_recompute_queued = false
	var previous := tessellations
	var previous_shapes := _tessellated_shapes
	tessellations = {}
	_tessellated_shapes = {}
	if doc == null:
		result = {}
		_whole_result = {}
		_rebuilt_model = {}
		_bodies_previewed = false
		viewport.set_bodies([])
		_refresh_analyses()
		_refresh_images()
		_refresh_assembly()
		browser.refresh(null, [], {})
		timeline.refresh([], 0, {})
		_update_status()
		selection_updated.emit()
		return
	# A Mesh tool's preview may take half a second at most; OK (and everything else) the full time.
	last_mesh_limit = MESH_FEATURE.PREVIEW_SECONDS if _previews_mesh() else MESH_FEATURE.OK_SECONDS
	var rebuild_options := {"form_preview": form_preview, "mesh_time_limit": last_mesh_limit}
	if _previews_mesh() and command.feature != null:
		# Only the feature being previewed gets the short limit (core/regen.gd): the Mesh features
		# before it keep the full time, so none of them shows a "would take" refusal of its own.
		rebuild_options["mesh_preview_feature"] = str(command.feature.id)
	result = REGEN.rebuild(doc, kernel, rebuild_options)
	rebuild_count += 1
	if result.has("preview_stops_at"):
		# A Mesh tool's preview of a feature with others after it: the rebuild stopped after that
		# feature. What the later ones made stays as the last whole rebuild left it, and decals and
		# canvases are not moved to follow a model that is only shown while the tool is open.
		_hold_later_features()
	else:
		_whole_result = result
		# Decals and canvases follow the faces and planes they sit on (tools/image_command.gd).
		IMAGE_COMMAND.follow_geometry(doc, result, kernel)
	_rebuilt_model = _model_of(doc.snapshot())
	for body_id in result.bodies:
		var shape: RefCounted = result.bodies[body_id].shape
		if previous.has(body_id) and is_same(previous_shapes.get(body_id), shape):
			tessellations[body_id] = previous[body_id]
		else:
			tessellations[body_id] = TESSELLATE.tessellate(shape)
		_tessellated_shapes[body_id] = shape
		REGEN.note_drawing(result, str(body_id), tessellations[body_id], doc.body_name(body_id))
	_show_bodies()
	viewport.set_origin_visibility(doc.origin_visibility)
	selection = selection.filter(func(pick: Dictionary) -> bool: return result.bodies.has(pick.body))
	# Triangles picked on a mesh that changed mean nothing on the new one.
	mesh_selection.prune(mesh_shapes())
	if mesh_direct_edit.active:
		mesh_direct_edit.refresh()
	_update_highlights()
	_refresh_browser()
	_sync_mesh_tools()
	timeline.refresh(doc.features, doc.active_count(), result.errors, result.get("warnings", {}), _waiting_features())
	toolbar.set_selection_sets(PackedStringArray(doc.selection_sets.keys()))
	# While a form previews its bodies aren't in the rebuild: baking now would take their baked
	# nodes (and the materials and scripts on them) away. Finish Form bakes.
	# Nor while a Mesh tool is open: baking a big mesh body takes longer than its preview may (a
	# second and a half for a million triangles), and OK's own rebuild bakes what was accepted.
	if form_preview == "" and not _is_mesh_tool(command) and part != null and is_instance_valid(part) and part.is_inside_tree():
		part.apply_result(result, tessellations)
		_baked_decals = doc.decals.duplicate(true)
		_rehide_passthrough()
	_refresh_analyses()
	_refresh_images()
	if command != null:
		_update_command_feedback()
	sketch_editor.refresh(result)
	form_editor.refresh(result)
	picker.refresh()
	# Poses after the model they place (10.1 #7): re-solve, re-pose, glyphs and browser states.
	# (apply_result() above baked the assembly with the bodies.)
	_refresh_assembly(false)
	_update_status()
	selection_updated.emit()
	recomputed.emit(result)


## A Mesh tool's preview stops after its feature (REGEN "mesh_preview_feature"; the result names
## it in "preview_stops_at"), so the result holds the model as that feature leaves it. The features
## after it were not run: nothing they made is gone, it is only not worked out again until OK or
## Cancel. So what they made in the last whole rebuild is put into the result as it was: the
## bodies only they make ("preview_held": their ids), their sketches, construction geometry,
## threads and forms. The view, the browser, the selection and the picks then see them as before.
## A body the previewed feature works on shows as it leaves that feature, and so does a body a
## later feature would change or take away. "preview_later": the ids of the features left out.
func _hold_later_features() -> void:
	var at: int = doc.feature_index(str(result.get("preview_stops_at", "")))
	var later := {}
	if at >= 0:
		for i in range(at + 1, doc.active_count()):
			later[str(doc.features[i].id)] = true
	result["preview_later"] = later.keys()
	var held := []
	for body_id in _whole_result.get("bodies", {}):
		if result.bodies.has(body_id):
			continue
		var entry: Dictionary = _whole_result.bodies[body_id]
		if later.has(_maker_of(str(body_id), entry)):
			result.bodies[body_id] = entry
			held.append(str(body_id))
	result["preview_held"] = held
	for key in ["sketches", "construction", "forms"]:
		var made: Dictionary = _whole_result.get(key, {})
		for id in made:
			if later.has(str(id)) and not (result[key] as Dictionary).has(id):
				result[key][id] = made[id]
	# (A thread's key starts with its feature's id.)
	var threads: Dictionary = _whole_result.get("threads", {})
	for key in threads:
		if later.has(str(key).get_slice(":", 0)) and not (result.threads as Dictionary).has(key):
			result.threads[key] = threads[key]


## The id of the feature that made a body (the document's record of it; else the rebuild's entry,
## which names the feature that touched the body last).
func _maker_of(body_id: String, entry: Dictionary) -> String:
	var known: Dictionary = doc.bodies.get(body_id, {})
	return str(known.get("feature", entry.get("feature", "")))


## The features a Mesh tool's preview left out, for the timeline: {"ids", "label": the previewed
## feature's} ({} when the rebuild ran the whole timeline).
func _waiting_features() -> Dictionary:
	if not result.has("preview_stops_at"):
		return {}
	# A stopped preview (result.preview_stopped) ends before the previewed feature, so
	# preview_stops_at names an earlier one: the label is the open command's own feature then.
	var previewed: Resource = doc.find_feature(str(result.preview_stops_at))
	if result.has("preview_stopped") and command != null and command.get("feature") != null:
		previewed = command.feature
	return {"ids": result.get("preview_later", []), "label": str(previewed.label) if previewed != null else "", "stopped": str(result.get("preview_stopped", ""))}


## Why a body can't be picked for the Mesh tool that is previewing: a feature after the tool's own
## makes it, so it is not there yet where the tool works ("" when it can be picked).
func later_body_refusal(body_id: String) -> String:
	if command == null or command.get("feature") == null or not (result.get("preview_held", []) as Array).has(body_id):
		return ""
	var maker: Resource = doc.find_feature(_maker_of(body_id, result.bodies[body_id]))
	return "%s is made later in the timeline (by %s), so %s can't work on it." % [doc.body_name(body_id), str(maker.label) if maker != null else "a later feature", str(command.feature.label)]


## The bodies the browser lists: the rebuild's, and the open form's cage bodies (not in a preview).
func _browser_bodies() -> Array:
	var ids: Array = result.get("bodies", {}).keys()
	if form_editor != null and form_editor.active:
		for body_id in form_editor.body_ids():
			if not ids.has(body_id):
				ids.append(body_id)
	return ids


## Shows the last rebuild's bodies in the view from their cached tessellations, with the
## document's appearances (the same surfaces and UVs as the bake).
func _show_bodies(overrides := {}) -> void:
	var entries := []
	appearance_notes = PackedStringArray()
	for body_id in result.get("bodies", {}):
		var tess: Dictionary = tessellations.get(body_id, {})
		if tess.is_empty():
			tess = TESSELLATE.tessellate(result.bodies[body_id].shape)
			tessellations[body_id] = tess
			_tessellated_shapes[body_id] = result.bodies[body_id].shape
		var settings: Dictionary = doc.body_settings(body_id)
		var shape: RefCounted = result.bodies[body_id].shape
		if overrides.has(body_id):
			# Direct Edit shows its working mesh in the body's place.
			tess = overrides[body_id].tess
			shape = overrides[body_id].shape
		if overrides.has(body_id) and (tess.is_empty() or shape == null):
			continue
		var is_mesh := MESH_BODY.is_mesh(shape)
		var entry := {"id": body_id, "tess": tess, "visible": doc.body_visible(body_id), "selectable": not bool(settings.get("locked", false)),
			"surface": APPEARANCE.two_sided(shape)}
		if is_mesh and mesh_face_groups:
			# Display Mesh Face Groups: the groups' colours stand in for the body's appearances.
			entry["mesh"] = viewport.mesh_display.group_mesh(tess, shape)
		elif not doc.appearances.is_empty():
			var plain: Material = viewport.mesh_surface_material(false) if is_mesh else viewport.surface_material()
			var open: Material = viewport.mesh_surface_material(true) if is_mesh else viewport.surface_body_material()
			var built: Dictionary = APPEARANCE.build_mesh(doc, body_id, shape, tess, plain, open)
			entry["mesh"] = built.mesh
			# (A face group's appearance that moved with its group, or is not shown: said in the
			# status line.)
			for note in built.get("notes", PackedStringArray()):
				if not appearance_notes.has(str(note)):
					appearance_notes.append(str(note))
		entries.append(entry)
	viewport.mesh_wire = workspace == MESH_WORKSPACE and mesh_selection.mode == MESH_SELECTION.TRIANGLES
	viewport.set_bodies(entries)
	_bodies_previewed = not overrides.is_empty()


## Shows the bodies again as they are (after a view-only change: Display Mesh Face Groups, the
## pick mode's triangle wire, Direct Edit closing), with the highlights.
func refresh_bodies() -> void:
	if doc == null:
		return
	_show_bodies()
	_update_highlights()
	_refresh_analyses()


## Shows the last rebuild's bodies with some of them replaced: {body id: {"tess", "shape"}}
## (Direct Edit's working mesh). The rebuild's own come back with refresh_bodies() or a rebuild.
func show_bodies_with(overrides: Dictionary) -> void:
	if doc == null:
		return
	_show_bodies(overrides)
	_update_highlights()


## Shows bodies a running command made (viewport.set_bodies entries) without a rebuild, as Texture
## Map Controls previews a mapping. The rebuild's bodies come back with the next view refresh after
## the command (Cancel, undo) or the next rebuild.
func preview_bodies(entries: Array) -> void:
	viewport.set_bodies(entries)
	_bodies_previewed = true


func _queue_recompute() -> void:
	if not _recompute_queued:
		_recompute_queued = true
		recompute.call_deferred()


## Redraws analyses and the running inspect command without rebuilding the model; with_browser
## false leaves the browser as it is (a handle drag changes nothing it lists).
func refresh_view(with_browser := true) -> void:
	_view_refresh_queued = false
	_refresh_analyses()
	_refresh_images()
	if command != null:
		_update_command_feedback()
	if with_browser:
		_refresh_browser()
	viewport.redraw_overlay()


func _queue_view_refresh() -> void:
	if not _view_refresh_queued:
		_view_refresh_queued = true
		refresh_view.call_deferred()


func _on_part_leaving() -> void:
	set_part.call_deferred(null)


## Follows the editor selection: a selected CadPart (or one of its baked bodies) becomes the part.
func on_editor_selection_changed() -> void:
	for node in EditorInterface.get_selection().get_selected_nodes():
		var candidate: Node = node
		while candidate != null:
			if candidate.get_script() == CAD_PART:
				set_part(candidate)
				return
			candidate = candidate.get_parent()


## When the edited scene changes, keep the part only if it belongs to that scene.
func on_scene_changed(scene_root: Node) -> void:
	if part != null and is_instance_valid(part) and scene_root != null and (scene_root == part or scene_root.is_ancestor_of(part)):
		return
	var first: Node = null
	if scene_root != null:
		if scene_root.get_script() == CAD_PART:
			first = scene_root
		else:
			for node in scene_root.find_children("*", "Node3D", true, false):
				if node.get_script() == CAD_PART:
					first = node
					break
	set_part(first)


## Adds a new CadPart to the edited scene (undoable) and starts editing it.
func add_part_to_scene() -> Node3D:
	var scene := EditorInterface.get_edited_scene_root()
	if scene == null:
		_flash("Open or create a scene first.")
		return null
	var new_part: Node3D = CAD_PART.new()
	new_part.name = "ForgePart"
	new_part.document = DOCUMENT.new()
	var undo := plugin.get_undo_redo()
	undo.create_action("Add Forge Part", UndoRedo.MERGE_DISABLE, scene)
	undo.add_do_method(scene, "add_child", new_part, true)
	undo.add_do_method(new_part, "set_owner", scene)
	undo.add_do_reference(new_part)
	undo.add_undo_method(scene, "remove_child", new_part)
	undo.commit_action()
	EditorInterface.edit_node(new_part)
	set_part(new_part)
	return new_part


# --- Undo ------------------------------------------------------------------------------------

## Records the change from before to now as one undo step on the part's scene. A change to
## VIEW_KEYS only (an analysis' eye, a rename) redraws the view without a rebuild; made while a
## command runs, it also goes into the command's starting state, so Cancel keeps it, and its
## undo step is taken against that state instead of the command's preview.
func commit_change(action_name: String, before: Dictionary) -> void:
	var after: Dictionary = doc.snapshot()
	var now := after
	var view_only := _model_of(before) == _model_of(after)
	if view_only and command != null and not _command_before.is_empty():
		var start := _command_before
		_command_before = _with_view_change(start, before, after)
		before = start
		after = _command_before
	_record(action_name, before, after)
	if view_only:
		_refresh_for(now)
	else:
		recompute()


## Runs mutate on the document and records it as one undo step. A model change made while a
## command runs whose Cancel restores the document (a feature's preview, an analysis, Texture Map
## Controls' mapping) goes into that command's starting state too, so Cancel keeps it, OK's step
## starts from it, and its own undo step never holds the command's uncommitted preview.
func change(action_name: String, mutate: Callable) -> void:
	if doc == null:
		return
	var before: Dictionary = doc.snapshot()
	var known := {}
	if form_editor != null and form_editor.active:
		for feature in doc.features:
			known[feature.id] = true
	mutate.call()
	if not known.is_empty():
		for feature in doc.features.duplicate():
			if not known.has(feature.id):
				_move_before_form(feature)
	var held_assembly: Dictionary = before.get("assembly", {})
	if ASSEMBLY_DATA.is_newer(held_assembly) and doc.assembly != held_assembly:
		# An assembly saved by a newer Holo Forge is shown but never edited here (spec C1.6): the
		# change to it is refused; a change that touched nothing else records nothing.
		doc.assembly = held_assembly.duplicate(true)
		_flash(ASSEMBLY_DATA.S_NEWER_ASSEMBLY)
		var now: Dictionary = doc.snapshot()
		if _model_of(now) == _model_of(before) and VIEW_KEYS.all(func(key: String) -> bool: return now.get(key) == before.get(key)):
			return
	if _command_restores() and _model_of(before) != _model_of(doc.snapshot()):
		_commit_under_command(action_name, mutate)
		return
	commit_change(action_name, before)


## A feature made while a form is open goes just before the form: the preview stops after the form,
## so a feature after it wouldn't exist yet (construction planes, sketches, inserted meshes).
func _move_before_form(feature: Resource) -> void:
	if feature == null or form_editor == null or not form_editor.active or feature.id == form_editor.feature_id:
		return
	var at: int = doc.feature_index(form_editor.feature_id)
	var index: int = doc.feature_index(feature.id)
	if at < 0 or index < 0 or index < at:
		return
	doc.features.remove_at(index)
	doc.features.insert(doc.feature_index(form_editor.feature_id), feature)


## True while a command runs whose Cancel puts _command_before back: feature commands, and inspect
## commands that edit the document.
func _command_restores() -> bool:
	return command != null and not _command_before.is_empty() and (not _is_inspect(command) or command.changes_document())


## Records a model change made while a command runs (see change()): mutate runs again on a scratch
## copy of the command's starting state, which becomes the new starting state, and the undo step
## goes from the old starting state to the new one. The document keeps the command's preview with
## the change made to it too, and rebuilds.
func _commit_under_command(action_name: String, mutate: Callable) -> void:
	var start := _command_before
	var scratch: Resource = DOCUMENT.new()
	scratch.restore(start)
	var previewed: Resource = doc
	# Workspace edits reach the document through `doc`, so for this call it is the scratch copy.
	doc = scratch
	mutate.call()
	doc = previewed
	_command_before = scratch.snapshot()
	_record(action_name, start, _command_before)
	recompute()


## Adds one undo step on the part's scene that puts the document to after (redo) or before (undo).
func _record(action_name: String, before: Dictionary, after: Dictionary) -> void:
	last_step = {"name": action_name, "before": before, "after": after}
	undo_step_count += 1
	if plugin != null and part != null:
		var undo := plugin.get_undo_redo()
		# Every step gets the "Forge: " prefix, a Mesh tool's too ("Forge: Mesh: Reduce"): the editor's
		# history mixes them with scene edits. (last_step keeps the plain name.)
		undo.create_action("Forge: " + action_name, UndoRedo.MERGE_DISABLE, part)
		undo.add_do_method(self, "_apply_snapshot", part, after)
		undo.add_undo_method(self, "_apply_snapshot", part, before)
		undo.commit_action(false)


func _apply_snapshot(target_part: Node3D, state: Dictionary) -> void:
	if not is_instance_valid(target_part) or target_part.document == null:
		return
	if target_part == part and command != null:
		_end_command()
	if target_part == part and mesh_direct_edit.active:
		# An undo or redo of the design under an open Direct Edit: its working copy no longer fits.
		mesh_direct_edit.cancel()
	target_part.document.restore(state)
	if target_part == part:
		_refresh_for(state)
	elif target_part.is_inside_tree():
		target_part.bake()


## Shows the document after it became state (a doc.snapshot()): recompute(), or only the view
## (analyses, canvases, decals) when the model is still the one last rebuilt.
func _refresh_for(state: Dictionary) -> void:
	# (A result that stopped after a previewed feature is not the model: once its tool has
	# closed, the whole timeline is replayed, also when Cancel left nothing changed.)
	var stopped: bool = result.has("preview_stops_at") and not _previews_mesh()
	if doc != null and not _rebuilt_model.is_empty() and _model_of(state) == _rebuilt_model and not stopped:
		# Only the assembly (or view data) changed: re-solve against the result shown, no rebuild.
		if state.get("assembly", {}) != _solved_assembly:
			_refresh_assembly()
		_refresh_view_data()
	else:
		recompute()


## Solves the document's assembly against the result shown (core/assembly/solver.gd, no rebuild),
## poses the bodies (ui/assembly_display.gd apply()), rebuilds the glyphs and the browser's joint
## states, and shows modelled positions instead while a tool needs them (C7.2). recompute() calls
## it last, so poses are never stale after a model change (10.1 #7).
## bake_part: also bakes the edited part's component transforms (and, in RigidBody3D mode, its
## mass, collision and joints) again, so an assembly-only change reaches the scene live; recompute()
## passes false, as its apply_result() bakes the assembly with the bodies.
func _refresh_assembly(bake_part := true) -> void:
	assembly_refresh_count += 1
	if doc == null:
		assembly_solve = {}
		_solved_assembly = {}
	else:
		_solved_assembly = doc.assembly.duplicate(true)
		assembly_solve = ASSEMBLY_SOLVER.solve(doc, result, kernel)
		# (Not from a preview that stopped after its feature: the result is not the whole model.)
		if bake_part and part != null and is_instance_valid(part) and part.is_inside_tree() \
				and part.has_method("bake_assembly") and not result.has("preview_stops_at"):
			part.bake_assembly(result)
	if assembly_display == null:
		return
	assembly_display.apply(viewport, assembly_solve)
	assembly_display.refresh(viewport, doc, assembly_solve)
	_sync_modelled_view()
	_refresh_browser()
	_sync_contact_toggle()
	if motion_study_panel != null and motion_study_panel.visible:
		# The study's frames are worked out again for the changed assembly (and the playhead's
		# frame shows instead of the stored poses).
		motion_study_panel.refresh()


## True while the view should show modelled positions (C7.2): a feature command, a sketch, a form,
## Direct Edit or a Mesh tool is open. Inspect and Assemble commands (they make no feature) and the
## browser keep the posed view.
func _wants_modelled_view() -> bool:
	if command != null and not _is_inspect(command):
		return true
	return (sketch_editor != null and sketch_editor.active) or (form_editor != null and form_editor.active) \
		or (mesh_direct_edit != null and mesh_direct_edit.active)


## True while the view shows modelled positions in place of the assembly's poses.
func modelled_view() -> bool:
	return viewport != null and viewport.modelled_view


## Shows modelled positions or the poses, as _wants_modelled_view() says, and the status line's
## note with them.
func _sync_modelled_view() -> void:
	if assembly_display == null or viewport == null:
		return
	var wanted := _wants_modelled_view()
	if wanted == bool(viewport.modelled_view):
		return
	assembly_display.set_modelled(viewport, wanted)
	_update_status()


## A pick's point where it shows now: its "world_point" in the posed view, else the point.
func world_point(pick: Dictionary) -> Variant:
	return pick.get("world_point", pick.get("point"))


## The browser's ground button (spec 3.2 #2): grounds a top-level component where it shows now
## (its pose becomes its placement, C3.5, so it does not jump), or ungrounds it.
func _toggle_ground(component_id: String) -> void:
	if doc == null or not doc.components.has(component_id):
		return
	var grounded := ASSEMBLY_DATA.is_grounded(ASSEMBLY_DATA.normalized(doc.assembly), component_id)
	var label: String = doc.component_name(component_id)
	change(("Unground %s" if grounded else "Ground %s") % label, func() -> void:
		var assembly: Dictionary = ASSEMBLY_DATA.normalized(doc.assembly)
		if grounded:
			assembly.grounded.erase(component_id)
		else:
			var pose: Variant = (assembly_solve.get("poses", {}) as Dictionary).get(component_id)
			if pose is PackedFloat64Array and (pose as PackedFloat64Array).size() == 12:
				assembly.placements[component_id] = PackedFloat64Array(pose)
			assembly.grounded[component_id] = true
		doc.assembly = assembly)


## An assembly entry's eye in the browser: shows or hides its glyph (an assembly-only change).
func _toggle_assembly_visible(list: String, id: String) -> void:
	if doc == null:
		return
	var label := id
	for entry in ASSEMBLY_DATA.normalized(doc.assembly).get(list, []):
		if entry is Dictionary and str(entry.get("id", "")) == id:
			label = str(entry.get("name", id))
	change("Show/Hide %s" % label, func() -> void:
		var assembly: Dictionary = ASSEMBLY_DATA.normalized(doc.assembly)
		for entry in assembly.get(list, []):
			if entry is Dictionary and str(entry.get("id", "")) == id:
				entry["visible"] = not bool(entry.get("visible", true))
		doc.assembly = assembly)


# --- Assemble actions (spec 3.2, 3.9-3.11) ------------------------------------------------------

## Grounds a top-level component where it shows now (the browser's ground button and menu item).
func ground_component(component_id: String) -> void:
	if doc != null and not ASSEMBLY_DATA.is_grounded(ASSEMBLY_DATA.normalized(doc.assembly), component_id):
		_toggle_ground(component_id)


func unground_component(component_id: String) -> void:
	if doc != null and ASSEMBLY_DATA.is_grounded(ASSEMBLY_DATA.normalized(doc.assembly), component_id):
		_toggle_ground(component_id)


## Opens Place Component on a component (3.2 #3).
func place_component(component_id: String) -> void:
	if doc == null or not doc.components.has(component_id):
		return
	var placing: RefCounted = load(ASSEMBLE_PLACE).new("assemble:place")
	placing.component_id = component_id
	start_command(placing)


## Puts a component's placement back to identity (3.2 #4).
func reset_placement(component_id: String) -> void:
	if doc == null or not doc.components.has(component_id):
		return
	if ASSEMBLY_DATA.placement(ASSEMBLY_DATA.normalized(doc.assembly), component_id) == XFORM.identity():
		return
	change("Reset Placement %s" % doc.component_name(component_id), func() -> void:
		var assembly: Dictionary = ASSEMBLY_DATA.normalized(doc.assembly)
		(assembly.placements as Dictionary).erase(component_id)
		doc.assembly = assembly)


## Moves a body into the active component (a model change: it rebuilds).
func move_to_active_component(body_id: String) -> void:
	if doc == null or not doc.bodies.has(body_id):
		return
	var target: String = doc.active_component
	if doc.body_component(body_id) == target:
		_flash("%s is in %s already." % [doc.body_name(body_id), doc.component_name(target) if target != "" else "the top level"])
		return
	change("Move to %s" % (doc.component_name(target) if target != "" else "Top Level"), func() -> void:
		if doc.bodies.has(body_id):
			doc.bodies[body_id]["component"] = target)


## A browser click on a component: with ctrl it adds to (or takes from) the picked components and
## keeps the body selection; without, it starts a new browser selection.
func component_clicked(component_id: String, ctrl: bool) -> void:
	if command != null and panel.active_selection_key != "":
		# A running tool's body slot takes the component's bodies.
		for body_id in result.get("bodies", {}):
			if doc.body_component(str(body_id)) == component_id:
				_on_reference_picked({"kind": "body", "body": str(body_id)})
		return
	if not ctrl:
		selected_components.clear()
		selection.clear()
		_select_assembly_entry({})
	if selected_components.has(component_id):
		selected_components.erase(component_id)
	else:
		selected_components.append(component_id)
	_selection_changed(false)


## New Contact Set from the browser selection: the picked components and the selected bodies.
func new_contact_set() -> void:
	if doc == null:
		return
	var members := []
	for component_id in selected_components:
		if doc.components.has(component_id):
			members.append({"component": str(component_id)})
	for body_id in _selected_bodies():
		members.append({"body": str(body_id)})
	if members.is_empty():
		_flash("Select components or bodies in the browser first, then New Contact Set.")
		return
	change("Contact Set", func() -> void:
		var assembly: Dictionary = ASSEMBLY_DATA.normalized(doc.assembly)
		var id := ASSEMBLY_DATA.new_id(assembly, "contact")
		var entry: Dictionary = ASSEMBLY_DATA.CONTACT_SET_DEFAULT.duplicate(true)
		entry["id"] = id
		entry["name"] = ASSEMBLY_DATA.name_for("contact", id)
		entry["members"] = members
		(assembly.contact_sets as Array).append(entry)
		doc.assembly = assembly)


## Adds the browser selection to a contact set (add true) or takes it out.
func change_contact_set(set_id: String, add: bool) -> void:
	var picked := []
	for component_id in selected_components:
		picked.append({"component": str(component_id)})
	for body_id in _selected_bodies():
		picked.append({"body": str(body_id)})
	if picked.is_empty():
		_flash("Select components or bodies in the browser first.")
		return
	var entry := _assembly_entry("contact_sets", set_id)
	change("%s %s" % ["Add to" if add else "Remove from", str(entry.get("name", set_id))], func() -> void:
		var assembly: Dictionary = ASSEMBLY_DATA.normalized(doc.assembly)
		for found in assembly.contact_sets:
			if found is Dictionary and str(found.get("id", "")) == set_id:
				var members: Array = found.members
				for member in picked:
					if add and not members.has(member):
						members.append(member)
					elif not add:
						members.erase(member)
		doc.assembly = assembly)


## Opens Contact Settings (3.9).
func open_contact_settings() -> void:
	if doc != null:
		start_command(load(ASSEMBLE_CONTACT).new("assemble:contact_settings"))


## Opens the Motion Study panel (3.10).
func open_motion_study() -> void:
	if doc == null:
		_flash("Select or add a Forge part first.")
		return
	if motion_study_panel == null:
		motion_study_panel = MOTION_STUDY_PANEL.new(self)
		motion_study_panel.visible = false
		viewport.add_child(motion_study_panel)
		motion_study_panel.set_store(MOTION_STUDY_PANEL.default_store(), "motion_study_panel")
		motion_study_panel.place(Vector2(10.0, maxf(viewport.size.y - 260.0, 40.0)))
	motion_study_panel.apply_style(theme_colors.get("panel_style", {}))
	motion_study_panel.open()


## Opens Joint on a stored joint (browser double-click or Edit).
func edit_joint(joint_id: String) -> void:
	var joint := _assembly_entry("joints", joint_id)
	if joint.is_empty():
		return
	var editing: RefCounted = load(ASSEMBLE_JOINT).new("assemble:as_built_joint" if bool(joint.get("as_built", false)) else "assemble:joint")
	editing.joint_id = joint_id
	editing.editing = true
	start_command(editing)


## Opens Drive Joints on a joint.
func drive_joint(joint_id: String) -> void:
	if doc == null:
		return
	var driving: RefCounted = load(ASSEMBLE_DRIVE).new("assemble:drive")
	driving.joint_id = joint_id
	start_command(driving)


## The stored entry of an assembly list by id ({} when it is gone).
func _assembly_entry(list: String, id: String) -> Dictionary:
	if doc == null:
		return {}
	for entry in ASSEMBLY_DATA.normalized(doc.assembly).get(list, []):
		if entry is Dictionary and str(entry.get("id", "")) == id:
			return entry
	return {}


## Selects an assembly entry (browser or view): a joint is drawn in the selection colour and both
## of its units are highlighted (3.11).
func select_assembly(list: String, id: String) -> void:
	_select_assembly_entry({"list": list, "id": id})
	selection.clear()
	selected_components.clear()
	_selection_changed(false)


func _select_assembly_entry(entry: Dictionary) -> void:
	selected_assembly = entry
	if assembly_display != null and viewport != null:
		var joint := str(entry.get("id", "")) if str(entry.get("list", "")) == "joints" else ""
		if assembly_display.selected_joint != joint:
			assembly_display.set_selected_joint(viewport, joint)


## A browser click on an origin, group, link, contact set or study: a running Joint's snap slot
## takes a Joint Origin; otherwise the entry is selected (a study opens its panel on it).
func _on_assembly_entry_clicked(list: String, id: String) -> void:
	if list == "origins" and command != null and bool(panel.active_field().get("snap", false)) and command.has_method("origin_item"):
		var item: Dictionary = command.origin_item(id)
		if not item.is_empty():
			panel.add_selection(item)
		return
	select_assembly(list, id)


## Deletes an assembly entry (one undo step "Delete <name>"); a joint takes the links that use it.
func delete_assembly(list: String, id: String) -> void:
	var entry := _assembly_entry(list, id)
	if entry.is_empty():
		return
	var name := str(entry.get("name", id))
	var linked := 0
	if list == "joints":
		for link in ASSEMBLY_DATA.normalized(doc.assembly).links:
			if link is Dictionary and (str(link.driver.get("joint", "")) == id or str(link.follower.get("joint", "")) == id):
				linked += 1
	change("Delete %s" % name, func() -> void:
		var assembly: Dictionary = ASSEMBLY_DATA.normalized(doc.assembly)
		assembly[list] = (assembly[list] as Array).filter(func(e: Variant) -> bool: return not (e is Dictionary and str(e.get("id", "")) == id))
		if list == "joints":
			assembly["links"] = (assembly.links as Array).filter(func(l: Variant) -> bool:
				return not (l is Dictionary and (str(l.driver.get("joint", "")) == id or str(l.follower.get("joint", "")) == id)))
		doc.assembly = assembly)
	if selected_assembly.get("id", "") == id:
		_select_assembly_entry({})
	if linked > 0:
		_flash("%s and the %s that used it were deleted." % [name, counted(linked, "motion link")])


## Suppress / Unsuppress a joint (or a rigid group): "Suppress Joint1".
func toggle_assembly_suppressed(list: String, id: String) -> void:
	var entry := _assembly_entry(list, id)
	if entry.is_empty() or not entry.has("suppressed"):
		return
	var on := not bool(entry.get("suppressed", false))
	change("%s %s" % ["Suppress" if on else "Unsuppress", str(entry.get("name", id))], func() -> void:
		var assembly: Dictionary = ASSEMBLY_DATA.normalized(doc.assembly)
		for found in assembly.get(list, []):
			if found is Dictionary and str(found.get("id", "")) == id:
				found["suppressed"] = on
		doc.assembly = assembly)


## Turns a contact set on or off.
func toggle_contact_set(set_id: String) -> void:
	var entry := _assembly_entry("contact_sets", set_id)
	if entry.is_empty():
		return
	var on := not bool(entry.get("enabled", true))
	change("%s %s" % ["Enable" if on else "Disable", str(entry.get("name", set_id))], func() -> void:
		var assembly: Dictionary = ASSEMBLY_DATA.normalized(doc.assembly)
		for found in assembly.contact_sets:
			if found is Dictionary and str(found.get("id", "")) == set_id:
				found["enabled"] = on
		doc.assembly = assembly)


## Renames an assembly entry ("Rename <old>").
func rename_assembly(list: String, id: String, new_name: String) -> void:
	var entry := _assembly_entry(list, id)
	if entry.is_empty() or str(entry.get("name", "")) == new_name:
		return
	change("Rename %s" % str(entry.get("name", id)), func() -> void:
		var assembly: Dictionary = ASSEMBLY_DATA.normalized(doc.assembly)
		for found in assembly.get(list, []):
			if found is Dictionary and str(found.get("id", "")) == id:
				found["name"] = new_name
		doc.assembly = assembly)


## Enable Contact Sets: one undo step, "Contact On" / "Contact Off"; no rebuild.
func toggle_contact_sets() -> void:
	if doc == null:
		return
	var on := not bool(ASSEMBLY_DATA.normalized(doc.assembly).contact.get("enabled", false))
	change("Contact On" if on else "Contact Off", func() -> void:
		var assembly: Dictionary = ASSEMBLY_DATA.normalized(doc.assembly)
		assembly.contact["enabled"] = on
		doc.assembly = assembly)
	_sync_contact_toggle()


## The toolbar's Enable Contact Sets shows pressed while contact is on.
func _sync_contact_toggle() -> void:
	if toolbar == null:
		return
	var on := doc != null and bool(ASSEMBLY_DATA.normalized(doc.assembly).contact.get("enabled", false))
	for button in toolbar.icon_buttons("Assemble"):
		if str(CATALOG.find(str(button.get_meta("tool_id", ""))).get("action", "")) == "toggle_contact_sets":
			button.toggle_mode = true
			button.set_pressed_no_signal(on)


## The browser's right-click entries for components, bodies and assembly entries (3.2, 3.9, 3.11).
func _fill_assembly_menu(menu: PopupMenu, meta: Dictionary) -> void:
	if doc == null:
		return
	var id := str(meta.get("id", ""))
	var assembly: Dictionary = ASSEMBLY_DATA.normalized(doc.assembly)
	if str(meta.get("type", "")) == "component" and id == "":
		# (The top level is no component: nothing to ground or place.)
		return
	if menu.item_count > 0:
		menu.add_separator()
	match str(meta.get("type", "")):
		"component":
			var nested := ASSEMBLY_SOLVER.parent_of(doc.components, id) != ""
			var grounded := ASSEMBLY_DATA.is_grounded(assembly, id)
			menu.add_item("Unground" if grounded else "Ground", ASSEMBLY_MENU.ground)
			if nested:
				menu.set_item_disabled(menu.item_count - 1, true)
				menu.set_item_tooltip(menu.item_count - 1, NESTED_GROUND_TIP)
			menu.add_item("Place Component...", ASSEMBLY_MENU.place)
			menu.add_item("Reset Placement", ASSEMBLY_MENU.reset)
			menu.set_item_disabled(menu.item_count - 1, ASSEMBLY_DATA.placement(assembly, id) == XFORM.identity())
			menu.add_item("New Contact Set", ASSEMBLY_MENU.new_set)
		"body":
			menu.add_item("Move to Active Component", ASSEMBLY_MENU.move_to)
			menu.set_item_disabled(menu.item_count - 1, doc.body_component(id) == doc.active_component)
			menu.add_item("New Contact Set", ASSEMBLY_MENU.new_set)
		"joint":
			var suppressed := bool(_assembly_entry("joints", id).get("suppressed", false))
			menu.add_item("Edit", ASSEMBLY_MENU.edit)
			menu.add_item("Drive", ASSEMBLY_MENU.drive)
			menu.add_item("Rename", ASSEMBLY_MENU.rename)
			menu.add_item("Unsuppress" if suppressed else "Suppress", ASSEMBLY_MENU.suppress)
			menu.add_separator()
			menu.add_item("Delete", ASSEMBLY_MENU.delete)
		"contact_set":
			menu.add_item("Disable" if bool(_assembly_entry("contact_sets", id).get("enabled", true)) else "Enable", ASSEMBLY_MENU.set_enabled)
			menu.add_item("Rename", ASSEMBLY_MENU.rename)
			menu.add_item("Add Selected", ASSEMBLY_MENU.add_selected)
			menu.add_item("Remove Selected", ASSEMBLY_MENU.remove_selected)
			menu.add_item("Contact Settings...", ASSEMBLY_MENU.contact_settings)
			menu.add_separator()
			menu.add_item("Delete", ASSEMBLY_MENU.delete)
		"contact_folder":
			menu.add_item("Contact Settings...", ASSEMBLY_MENU.contact_settings)
		"rigid_group":
			menu.add_item("Rename", ASSEMBLY_MENU.rename)
			menu.add_item("Unsuppress" if bool(_assembly_entry("rigid_groups", id).get("suppressed", false)) else "Suppress", ASSEMBLY_MENU.suppress)
			menu.add_separator()
			menu.add_item("Delete", ASSEMBLY_MENU.delete)
		"motion_study":
			menu.add_item("Open", ASSEMBLY_MENU.open_study)
			menu.add_item("Rename", ASSEMBLY_MENU.rename)
			menu.add_separator()
			menu.add_item("Delete", ASSEMBLY_MENU.delete)
		_:
			menu.add_item("Rename", ASSEMBLY_MENU.rename)
			menu.add_separator()
			menu.add_item("Delete", ASSEMBLY_MENU.delete)


func _on_assembly_menu(chosen: int, meta: Dictionary) -> void:
	var id := str(meta.get("id", ""))
	var list: String = ASSEMBLY_ITEM_LISTS.get(str(meta.get("type", "")), "")
	match str(ASSEMBLY_MENU.find_key(chosen)):
		"ground":
			# (The same as the browser's ground button, 10.2 V #4.)
			_toggle_ground(id)
		"place":
			place_component(id)
		"reset":
			reset_placement(id)
		"new_set":
			if str(meta.get("type", "")) == "component" and not selected_components.has(id):
				selected_components.append(id)
			new_contact_set()
		"move_to":
			move_to_active_component(id)
		"edit":
			edit_joint(id)
		"drive":
			drive_joint(id)
		"rename":
			browser.rename_selected()
		"suppress":
			toggle_assembly_suppressed(list, id)
		"delete":
			delete_assembly(list, id)
		"set_enabled":
			toggle_contact_set(id)
		"add_selected":
			change_contact_set(id, true)
		"remove_selected":
			change_contact_set(id, false)
		"contact_settings":
			open_contact_settings()
		"open_study":
			open_motion_study()
			motion_study_panel.study_id = id
			motion_study_panel.refresh()


## The body poses the Inspect tools work on while the view is posed (C7.4); {} when nothing is
## posed, so results stay as they were without an assembly.
func inspect_poses() -> Dictionary:
	if viewport == null or not viewport.is_posed():
		return {}
	return assembly_solve.get("body_poses", {})


## Redraws what VIEW_KEYS drive (analyses, canvases, decals, the browser) without replaying the
## timeline; the part's baked decals follow when they changed, and previewed bodies go back to the
## document's.
func _refresh_view_data() -> void:
	# (Never from a preview that stopped after its feature: the result is not the whole model.)
	if part != null and is_instance_valid(part) and part.is_inside_tree() and doc.decals != _baked_decals and not result.has("preview_stops_at"):
		part.apply_result(result, tessellations)
		_baked_decals = doc.decals.duplicate(true)
		_rehide_passthrough()
	if mesh_direct_edit.active:
		# (Direct Edit keeps showing its working mesh in its body's place.)
		mesh_direct_edit.refresh()
	elif _bodies_previewed:
		_show_bodies()
	refresh_view()
	if form_editor.active:
		form_editor.refresh_view()
	_update_status()


## The model in a doc.snapshot(): everything but VIEW_KEYS, ASSEMBLY_KEYS and the view id counters, with features
## as plain dictionaries, so two models compare with ==.
static func _model_of(state: Dictionary) -> Dictionary:
	var model := {}
	for key in state:
		if not key in VIEW_KEYS and not key in ASSEMBLY_KEYS:
			model[key] = state[key]
	var counters := {}
	for counter in state.get("counters", {}):
		if not _is_view_counter(str(counter)):
			counters[counter] = state.counters[counter]
	model["counters"] = counters
	var features := []
	for feature in state.get("features", []):
		var options: Dictionary = feature.options
		if feature.type == "form" and options.has("display"):
			# A form body's display mode is a view setting: changing it rebuilds nothing.
			options = options.duplicate()
			options.erase("display")
		features.append({"id": feature.id, "type": feature.type, "label": feature.label, "suppressed": feature.suppressed,
			"group": feature.group, "inputs": feature.inputs, "options": options})
	model["features"] = features
	return model


## Counters that only number analyses, canvases and decals (see doc.next_number()).
static func _is_view_counter(counter: String) -> bool:
	return counter == "analysis" or counter.begins_with("analysis:") or counter == "canvas" or counter == "decal"


## start (a doc.snapshot()) with the view-only change before -> after made to it too: entries of
## VIEW_KEYS matched by id (changed fields, added and removed entries) and the view counters.
## Entries start doesn't hold (one a running command added) are left alone.
static func _with_view_change(start: Dictionary, before: Dictionary, after: Dictionary) -> Dictionary:
	var out := start.duplicate()
	for key in VIEW_KEYS:
		var old := _entries_by_id(before.get(key, []))
		var new := _entries_by_id(after.get(key, []))
		var list: Array = (start.get(key, []) as Array).duplicate(true)
		for id in old:
			if not new.has(id):
				var gone := _entry_index(list, id)
				if gone >= 0:
					list.remove_at(gone)
		for id in new:
			var at := _entry_index(list, id)
			if not old.has(id):
				if at < 0:
					list.append((new[id] as Dictionary).duplicate(true))
				continue
			if at < 0:
				continue
			var entry: Dictionary = list[at]
			for field in new[id]:
				if old[id].get(field) != new[id][field]:
					var value: Variant = new[id][field]
					entry[field] = value.duplicate(true) if value is Array or value is Dictionary else value
			for field in old[id]:
				if not (new[id] as Dictionary).has(field):
					entry.erase(field)
		out[key] = list
	var counters: Dictionary = (start.get("counters", {}) as Dictionary).duplicate()
	var old_counters: Dictionary = before.get("counters", {})
	var new_counters: Dictionary = after.get("counters", {})
	for counter in new_counters:
		if _is_view_counter(str(counter)) and old_counters.get(counter) != new_counters[counter]:
			counters[counter] = new_counters[counter]
	out["counters"] = counters
	# The assembly (ASSEMBLY_KEYS) is no model either: a change to it made under a command whose
	# Cancel restores the document (a ground toggle while a feature tool is open) goes into the
	# command's starting state too, so Cancel keeps it (10.1 #7).
	for key in ASSEMBLY_KEYS:
		if before.get(key) != after.get(key):
			if after.has(key):
				var value: Variant = after[key]
				out[key] = value.duplicate(true) if value is Dictionary or value is Array else value
			else:
				out.erase(key)
	return out


static func _entries_by_id(entries: Array) -> Dictionary:
	var by_id := {}
	for entry in entries:
		by_id[str((entry as Dictionary).get("id", ""))] = entry
	return by_id


static func _entry_index(entries: Array, id: String) -> int:
	for i in entries.size():
		if str((entries[i] as Dictionary).get("id", "")) == id:
			return i
	return -1


## The undo history of the current part's scene (for the marking menu and tests).
func history() -> UndoRedo:
	if plugin == null or part == null:
		return null
	var undo := plugin.get_undo_redo()
	return undo.get_history_undo_redo(undo.get_object_history_id(part))


# --- Tools and commands ----------------------------------------------------------------------

func run_tool(tool: Dictionary) -> void:
	if tool.is_empty():
		return
	if not CATALOG.is_enabled(tool):
		if int(tool.get("phase", 99)) <= CATALOG.IMPLEMENTED_PHASE:
			_flash("%s isn't wired yet." % tool.name)
		else:
			_flash("%s arrives in Phase %d of Holo Forge." % [tool.name, tool.phase])
		return
	# Dark Mode needs no part.
	if doc == null and tool.action != "theme":
		_flash("Select or add a Forge part first.")
		return
	last_tool = tool
	if str(tool.get("form", "")) != "":
		_run_form_tool(tool)
		return
	# A tool from outside the Form toolbar (a Solid shortcut, the marking menu) finishes an open
	# form first; the Form toolbar's own (Construct, Inspect, Insert, Select...) run over it.
	if form_editor.active and str(tool.get("workspace", "")) != "Form" and tool.action != "theme":
		form_editor.end()
	# A tool with a panel keeps an open Direct Edit's steps first (its selection helpers, view
	# toggles and its own button run over it).
	if mesh_direct_edit.active and (tool.command != "" or str(tool.get("sketch", "")) != ""):
		mesh_direct_edit.done()
	if str(tool.get("sketch", "")) != "":
		if sketch_editor.active:
			sketch_editor.start_tool(tool.sketch)
		else:
			# Like CAD apps: a sketch tool outside a sketch first asks for the sketch plane.
			start_plane_pick()
			_pending_sketch_tool = tool.sketch
			_flash("%s: pick a plane or a flat face for the new sketch." % tool.name)
	elif tool.command != "":
		if sketch_editor.active and not _runs_in_sketch(tool):
			sketch_editor.end()
		start_command(load(tool.command).new(tool.type))
	elif tool.action == "finish_form" and form_editor.active:
		# The toolbar's Finish Form shows "Converting form bodies..." before the conversion.
		form_editor.finish()
	elif tool.action != "":
		run_action(tool.action)


## A Form tool: runs in the open form; a Create tool outside one makes a form first.
func _run_form_tool(tool: Dictionary) -> void:
	if form_editor.active:
		form_editor.start_tool(str(tool.form))
	elif str(tool.get("group", "")) == "Create":
		if sketch_editor.active:
			sketch_editor.end()
		if command != null:
			cancel_command()
		if create_form() != null:
			form_editor.start_tool(str(tool.form))
	else:
		_flash(FORM_EDITOR.OPEN_FIRST)


## True for the Sketch toolbar's commands (Measure, Curvature Comb, Canvas), from any menu or key:
## they run over an open sketch instead of finishing it.
func _runs_in_sketch(tool: Dictionary) -> bool:
	for group in CATALOG.groups(CATALOG.SKETCH_WORKSPACE):
		for sketch_tool in CATALOG.tools_in(CATALOG.SKETCH_WORKSPACE, group):
			if sketch_tool.command != "" and sketch_tool.command == tool.command and sketch_tool.type == tool.type:
				return true
	return false


func start_command(new_command: RefCounted, editing_feature: Resource = null) -> void:
	# A pending plane pick (Create Sketch, Insert SVG / DXF) ends: the command takes the view's clicks.
	_pending_sketch_tool = ""
	_end_plane_pick()
	if command != null:
		cancel_command()
	# An open Direct Edit keeps its steps (as one feature) before another tool starts.
	if mesh_direct_edit.active:
		mesh_direct_edit.done()
	# An open sketch keeps its tool under the command and gets it back when the command closes; so
	# does an open form.
	if sketch_editor.active:
		sketch_editor.suspend()
	elif form_editor.active:
		form_editor.suspend()
	command = new_command
	# A feature command shows modelled positions; Inspect and Assemble keep the poses (C7.2).
	_sync_modelled_view()
	_command_before = doc.snapshot()
	var size_m := _nice_size(viewport.distance * 0.25)
	command.hints = {
		"default_size": UNITS.format_value(size_m, UNITS.KIND_LENGTH, doc.units).split(" ")[0],
		"default_size_m": size_m,
		"position": Vector3(viewport.target.x, 0.0, viewport.target.z).snapped(Vector3.ONE * viewport.unit_scale),
		"units": doc.units,
	}
	command.result = result
	_mesh_hover = {}
	if "workspace" in command:
		command.workspace = self
	if editing_feature != null:
		command.feature = editing_feature
		command.editing = true
	drag_replaced = {}
	# Inspect commands that edit an analysis come in with editing already set.
	if command.editing:
		command_values = command.read_values()
		if _is_mesh_tool(command) and command.feature != null:
			# An existing Mesh feature is opened: its picks are of the bodies as they stand before
			# it, which the result on screen no longer shows.
			command.note_input(bodies_before(str(command.feature.id)))
		if not _is_inspect(command) and command.get("reads_otherwise") == true:
			# A stored choice the panel shows as another (one no longer offered reads as the one it
			# stands for): the feature takes what the panel shows, so the preview and OK build that.
			command.write_values(doc, command_values)
	else:
		command_values = command.defaults()
		command.create_feature(doc, command_values)
		if form_editor.active and "feature" in command and command.feature != null:
			_move_before_form(command.feature)
	panel.setup(command.title(), command.fields(), command_values, doc.units)
	panel.visible = true
	_watch_typing()
	viewport.mouse_handler = _command_mouse
	_place_panel.call_deferred()
	if _is_inspect(command):
		# Nothing in the model changes: only the view and the panel need refreshing.
		refresh_view()
	else:
		recompute()
	panel.focus_first()
	# (A command that outlines its picks, not tints them: the view shows its outlines at once.)
	_update_highlights()
	if _is_mesh_tool(command) and is_inside_tree():
		# A Mesh panel may show no text field at first (Tessellate, Separate): the view then takes
		# the keyboard, so Enter and Escape work without a click.
		var focused := get_viewport().gui_get_focus_owner()
		if focused == null or not panel.is_ancestor_of(focused) or not focused.is_visible_in_tree():
			viewport.focus_view()


## The model as it stands before a feature of the timeline (what that feature works on): the
## timeline replayed up to it on a scratch copy of the design, with the full time for Mesh
## features (their results come from the Mesh cache). A REGEN result, or {} when the feature is
## not in the timeline.
func bodies_before(feature_id: String) -> Dictionary:
	if doc == null:
		return {}
	var at: int = doc.feature_index(feature_id)
	if at < 0:
		return {}
	var scratch: Resource = DOCUMENT.new()
	scratch.restore(doc.snapshot())
	scratch.rollback = at
	return REGEN.rebuild(scratch, kernel, {"mesh_time_limit": MESH_FEATURE.OK_SECONDS})


## True for commands that make no feature (tools/inspect_command.gd).
func _is_inspect(c: RefCounted) -> bool:
	return c != null and c.has_method("finish")


## While a command runs, view clicks go to the command first (Canvas calibration clicks, a Mesh
## tool's picks on mesh bodies), then to the picker. A click on a mesh body for a tool that only
## takes B-rep bodies says so instead of picking it.
func _command_mouse(event: InputEvent) -> bool:
	if command != null and command.has_method("handle_mouse") and command.handle_mouse(event):
		return true
	var button := event as InputEventMouseButton
	if button != null and button.pressed and button.button_index == MOUSE_BUTTON_LEFT:
		var gate := _pick_gate(button.position)
		if gate != "":
			_flash(gate)
			return true
	return picker.handle_mouse(event)


## The gate sentence when a click would give the running command's active slot a mesh body it
## can't take: the command makes a Solid or Surface feature (not one of REGEN.MESH_AWARE) and the
## slot picks bodies, faces, edges or points of bodies. "" otherwise.
func _pick_gate(screen: Vector2) -> String:
	if command == null or _is_inspect(command) or command.feature == null or REGEN.MESH_AWARE.has(command.feature.type):
		return ""
	var kinds := _active_kinds()
	var on_bodies := false
	for kind in ["body", "face", "edge", "vertex", "point", "plane", "axis", "path", "component", "feature"]:
		on_bodies = on_bodies or kinds.has(kind)
	if not on_bodies:
		return ""
	var hit: Dictionary = viewport.face_hit_at(screen)
	if hit.is_empty() or not bool(hit.get("mesh", false)):
		return ""
	# (Sketch points and curves, construction and origin geometry in front of it still pick.)
	var found: Dictionary = picker.pick(screen)
	if found.is_empty() or not result.get("bodies", {}).has(found.get("body", "")):
		return ""
	if str(found.get("kind", "")) == MESH_BODY.GROUP_REF and (kinds.has("plane") or kinds.has("axis")):
		# A flat face group gives a plane (Construct, a sketch plane); it never gives an axis.
		var shape: RefCounted = result.bodies[found.body].shape
		var info: Dictionary = shape.face_info(int(shape.find_face(str(found.get("group", "")))))
		if kinds.has("plane"):
			return "" if bool(info.get("planar", false)) else "That face group isn't flat. Pick a flat one, a plane or a flat face."
		return MESH_BODY.AXIS_GATE
	return MESH_BODY.GATE % doc.body_name(str(hit.body))


## Puts new values in the running command's panel and applies them, as if they were typed.
## typed: the keys of a Mesh tool's fields to count as typed in even when their value reads the
## same as the one the panel chose (a field nobody typed in follows the picked body; a value that
## differs from the panel's own counts as typed by itself).
func set_command_values(values: Dictionary, typed: Array = []) -> void:
	if command == null:
		return
	if _is_mesh_tool(command):
		for key in typed:
			command.mark_typed(str(key))
	# (Shown also in the field that has the keyboard: these values were not typed there.)
	panel.set_values(values, values.keys())
	_on_panel_values_changed(values)


## OK or Enter, from the panel or the view. A Mesh tool's OK computes its feature again with the
## full time (up to MESH_FEATURE.OK_SECONDS, also after an instant preview), during which nothing
## is drawn: so the panel first says that it is working and takes OK away, a frame is drawn, and
## then accept_command() runs. Everything else is accepted at once. (accept_command() itself stays
## in one call for tests and the workspace's own callers.)
func accept_from_ui() -> void:
	if _mesh_accept_pending:
		return
	var builds_again: bool = _is_mesh_tool(command) and is_inside_tree() and command.refusal(command_values) == ""
	if builds_again:
		builds_again = result.get("errors", {}).has(command.feature.id) or last_mesh_limit < MESH_FEATURE.OK_SECONDS
	if not builds_again:
		accept_command()
		return
	var working: RefCounted = command
	_mesh_accept_pending = true
	panel.set_info(command.STAT_KEY, command.COMPUTING % [command.title(), int(MESH_FEATURE.OK_SECONDS)])
	panel.set_ok_enabled(false)
	for i in ACCEPT_DELAY_FRAMES:
		await get_tree().process_frame
	_mesh_accept_pending = false
	if command != working:
		return
	panel.set_ok_enabled(true)
	accept_command()


func accept_command() -> void:
	if command == null:
		if sketch_editor.tool != "":
			sketch_editor.tool_ok()
		elif form_editor.active and form_editor.tool != "":
			form_editor.tool_ok()
		return
	if _is_inspect(command):
		var why: String = command.accept_error()
		if why != "":
			_flash(why)
			return
		var ending: RefCounted = command
		var started := _command_before
		if ending.has_method("apply_document"):
			# An Assemble tool writes doc.assembly only now (its preview was view-only).
			ending.apply_document(doc)
		_end_command()
		if ending.changes_document():
			commit_change(ending.action_name(), started)
		ending.finish()
		return
	if _is_mesh_tool(command):
		# A value out of its range is refused, never clamped.
		var refused: String = command.refusal(command_values)
		if refused != "":
			_flash(refused)
			return
		if result.get("errors", {}).has(command.feature.id) or last_mesh_limit < MESH_FEATURE.OK_SECONDS:
			# The preview had half a second; OK computes the op again with the full time limit
			# (a full-time build does not take a preview's kept result: the preview's checks had
			# less time, so its warnings may be fewer). It can take up to OK_SECONDS also when the
			# preview was instant, which is why accept_from_ui() says so first.
			_accepting_mesh = true
			recompute()
			_accepting_mesh = false
			if command == null:
				return
	if result.get("errors", {}).has(command.feature.id):
		_flash("Can't finish %s: %s" % [command.feature.label, result.errors[command.feature.id]])
		return
	var action_name: String = ("Edit " if command.editing else "Create ") + str(command.feature.label)
	if _is_mesh_tool(command):
		action_name = command.undo_name()
		if str(command.spec.get("method", "")) == "section_sketch":
			# Create Mesh Section Sketch: its feature only computes and checks the section (a
			# feature can't add another one while the timeline replays). OK puts the fixed sketch
			# in its place, all in the tool's one undo step.
			var made: Dictionary = MESH_FEATURE.add_section_sketch(doc, result, command.feature)
			if str(made.get("error", "")) != "" or made.get("feature") == null:
				_flash("Can't finish %s: %s" % [command.title(), str(made.get("error", "no sketch was made"))])
				return
			var sketch_label := str(made.feature.label)
			var before_sketch := _command_before
			_end_command()
			commit_change(action_name, before_sketch)
			var warning := str(made.get("warning", ""))
			_flash("%s holds the section: %d curve%s, %d line%s and arc%s.%s" % [sketch_label, int(made.get("curves", 0)), "" if int(made.get("curves", 0)) == 1 else "s",
				int(made.get("segments", 0)), "" if int(made.get("segments", 0)) == 1 else "s", "" if int(made.get("segments", 0)) == 1 else "s", (" " + warning) if warning != "" else ""])
			return
		if str(command.spec.get("method", "")) == "convert_organic" and str(command.feature.options.get("output", "brep")) == "form_body":
			# Convert Mesh: Organic with the Form Body output: its feature made the solid of its
			# cage (a feature can't add another one while the timeline replays). OK swaps it for a
			# Form feature that holds the cage, all in the tool's one undo step.
			var converter: Script = load(MESH_FEATURE.CONVERT_PATH) if ResourceLoader.exists(MESH_FEATURE.CONVERT_PATH) else null
			var swapped: Dictionary = converter.call("form_body", doc, command.feature) if converter != null else {"error": "Convert Mesh is not in this build"}
			if str(swapped.get("error", "")) != "" or swapped.get("feature") == null:
				_flash("Can't finish %s: %s" % [command.title(), str(swapped.get("error", "no form body was made"))])
				return
			var form_label := str(swapped.feature.label)
			var form_body_name: String = doc.body_name(str(swapped.get("body", "")))
			var before_form := _command_before
			_end_command()
			commit_change(action_name, before_form)
			var form_note := str(swapped.get("note", ""))
			_flash("%s holds the cage of %s: double-click it in the timeline to sculpt it.%s" % [form_label, form_body_name, (" " + form_note) if form_note != "" else ""])
			return
	var before := _command_before
	var built_id := str(command.feature.id) if _is_mesh_tool(command) and command.feature != null else ""
	_end_command()
	commit_change(action_name, before)
	# A Mesh tool that built with a warning (a body left as it was, a hole left open, a solid
	# tessellated on the way) says it when the panel has gone; the timeline keeps it in the chip.
	var said := str((result.get("warnings", {}) as Dictionary).get(built_id, "")) if built_id != "" else ""
	if said != "":
		_flash(said)


func cancel_command() -> void:
	if command == null:
		if sketch_editor != null and sketch_editor.tool != "":
			sketch_editor.cancel_tool()
		elif form_editor != null and form_editor.active and form_editor.tool != "":
			form_editor.cancel_tool()
		return
	var before := _command_before
	var restores: bool = not _is_inspect(command) or command.changes_document()
	_end_command()
	if restores:
		doc.restore(before)
		_refresh_for(before)


func edit_feature(feature_id: String) -> void:
	var feature: Resource = doc.find_feature(feature_id) if doc != null else null
	if feature == null:
		return
	if command != null and not _is_inspect(command) and command.feature != null and command.feature.id == feature_id:
		# Its own command is already open (a double-click on the feature being made or edited):
		# keep it, rather than cancelling it and losing a feature that was never accepted.
		panel.focus_first()
		return
	if feature.type == "form":
		_pending_sketch_tool = ""
		_end_plane_pick()
		if command != null:
			cancel_command()
		if sketch_editor.active:
			sketch_editor.end()
		form_editor.begin(feature)
		_sync_modelled_view()
		return
	# Editing another feature finishes an open form first.
	if form_editor.active:
		form_editor.end()
		feature = doc.find_feature(feature_id)
		if feature == null:
			return
	if feature.type == "sketch":
		_pending_sketch_tool = ""
		_end_plane_pick()
		if command != null:
			cancel_command()
		sketch_editor.begin(feature)
		_sync_modelled_view()
		return
	var tool_key: String = feature.type + (":" + str(feature.options.method) if feature.options.has("method") else "")
	for tool in CATALOG.all_tools():
		if tool.type == tool_key and tool.command != "":
			start_command(load(tool.command).new(tool.type), feature)
			return
	if feature.type == "base_feature":
		_flash("%s holds fixed bodies; there is nothing to edit." % feature.label)
		return
	if tool_key == "mesh:" + MESH_DIRECT_EDIT.METHOD:
		_flash("%s holds a fixed copy of its body. Use Direct Edit on the body to change it again." % feature.label)
		return
	if feature.type in TIMELINE.FILE_FEATURES:
		# Import, Insert Mesh and Derive: their file, placement and options (tools/insert_command.gd).
		start_command(load(INSERT_COMMAND).new(feature.type), feature)
		return
	_flash("%s can't be edited yet." % feature.label)


func _end_command() -> void:
	var ending: RefCounted = command
	command = null
	command_values = {}
	drag_replaced = {}
	panel.visible = false
	panel.active_selection_key = ""
	_mesh_hover = {}
	var no_handles: Array[Dictionary] = []
	viewport.set_handles(no_handles)
	viewport.mouse_handler = sketch_editor.handle_mouse if sketch_editor.active else (form_editor.handle_mouse if form_editor.active else Callable())
	picker.hover = {}
	picker.update_display()
	_update_highlights()
	if _is_inspect(ending):
		ending.end()
	else:
		# (A Mesh tool's overlays, or a Join or Cut's tool shape.)
		viewport.set_command_meshes([])
		_operation_preview_shape = null
	if sketch_editor.active:
		sketch_editor.resume()
	elif form_editor.active:
		form_editor.resume()
	_sync_modelled_view()


## The kinds the active selection slot accepts ([] when no slot is active).
func _active_kinds() -> Array:
	if command == null and form_editor != null and form_editor.active and not form_editor.suspended:
		# A Form tool's model pick slot (Extrude's profile, Revolve's axis...).
		return form_editor.model_kinds()
	if command == null or panel == null or panel.active_selection_key == "":
		return []
	var field: Dictionary = panel.active_field()
	if field.get("filter") is String:
		return [field.filter]
	if command.has_method("filter_for"):
		return command.filter_for(panel.active_selection_key, command_values)
	return field.get("filter", [])


## Every reference the running command has picked (for drawing).
func _picked_refs() -> Array:
	var refs := []
	if command == null:
		if form_editor != null and form_editor.active:
			return form_editor.model_refs()
		return refs
	for field in command.fields():
		if field.type == "selection":
			for item in command_values.get(field.key, []):
				refs.append(item)
	return refs


func _on_reference_picked(ref: Dictionary) -> void:
	if panel.active_selection_key == "":
		return
	if command == null and not (form_editor != null and form_editor.active and form_editor.tool != ""):
		return
	var field: Dictionary = panel.active_field()
	if _is_mesh_tool(command) and ref.has("body") and later_body_refusal(str(ref.body)) != "":
		# (A body that a feature after the previewed one makes.)
		_flash(later_body_refusal(str(ref.body)))
	elif bool(field.get("snap", false)) and command != null and command.has_method("take_pick"):
		# An Assemble snap slot: the pick becomes a snap (the face's centre or axis, the edge's
		# middle or circle centre, the vertex), or says why it can't.
		var item: Dictionary = command.take_pick(panel.active_selection_key, ref)
		if item.has("error"):
			_flash(str(item.error))
		elif not item.is_empty():
			panel.add_selection(item)
	elif field.get("filter") is String:
		# Body slots (Join/Cut targets) hold body ids.
		if ref.has("body"):
			panel.add_selection(str(ref.body))
	elif _is_mesh_tool(command) and ref.has("body") and not _mesh_slot_takes(field, ref):
		# (A pick from the browser, or one the picker made for a slot's other kinds.)
		pass
	else:
		var clicked: Variant = picker.click_point(ref) if bool(field.get("at_click", false)) else null
		if clicked != null:
			# Where the click hit (Trim's pieces: a piece's middle can lie on another piece).
			ref = ref.duplicate()
			ref["at"] = clicked
		panel.add_selection(ref)
	picker.update_display()
	_update_highlights()


## Selection (the Mesh selection too) plus what the running command has picked, as view highlights.
func _update_highlights() -> void:
	var picks: Array = _selection_picks()
	for item in _picked_refs():
		var body_id := str(item) if item is String else str((item as Dictionary).get("body", ""))
		var shape: RefCounted = result.get("bodies", {}).get(body_id, {}).get("shape")
		if shape == null:
			continue
		if item is String or item.kind == "body":
			picks.append({"kind": "body", "body": body_id, "index": -1, "point": Vector3.ZERO})
		elif MESH_BODY.is_mesh(shape):
			# A mesh body's face groups and triangles (it has no faces or edges to find by name).
			if item.kind == MESH_BODY.GROUP_REF:
				var group: int = shape.find_face(str(item.get("group", "")))
				if group >= 0:
					picks.append({"kind": "mesh_group", "body": body_id, "index": group, "point": Vector3.ZERO})
			elif item.kind == MESH_BODY.TRIANGLES_REF:
				# (Picked on another mesh than the one shown, as when the tool's preview has changed
				# it: the numbers mean other triangles here. The command draws them itself, from
				# the mesh they were picked on: FEATURE_COMMAND.preview_meshes().)
				if _is_mesh_tool(command) and not command.triangles_shown(body_id, item):
					continue
				picks.append({"kind": "mesh_triangles", "body": body_id, "index": -1, "triangles": item.get("triangles", PackedInt32Array()), "point": Vector3.ZERO})
		elif item.kind == "face" or item.kind == "edge":
			var index: int = shape.find_face(item.name) if item.kind == "face" else shape.find_edge(item.name)
			if index >= 0:
				picks.append({"kind": item.kind, "body": body_id, "index": index, "point": Vector3.ZERO})
	viewport.set_highlights(picks, _mesh_hover if not _mesh_hover.is_empty() else hover)


## Whether the open command wants faces outlined, not tinted (Texture Map Controls: the face's
## texture stays in clear view).
func _outlines_picks() -> bool:
	return command != null and "outlines_picks" in command and bool(command.outlines_picks)


## The view selection as highlight picks: the picked items, and the Mesh selection's triangles.
func _selection_picks() -> Array:
	var picks: Array = selection.duplicate()
	# Components picked in the browser, and both units of a selected joint (3.11, 10.2 V #6),
	# show their bodies highlighted.
	var units := {}
	for component_id in selected_components:
		units[str(component_id)] = "component"
	if str(selected_assembly.get("list", "")) == "joints" and doc != null:
		var joint := _assembly_entry("joints", str(selected_assembly.get("id", "")))
		for side in ["a", "b"]:
			var component := str((joint.get(side, {}) as Dictionary).get("component", ""))
			if component != "":
				units[ASSEMBLY_SOLVER.unit_of(doc.components, component)] = "unit"
	if not units.is_empty() and doc != null:
		for body_id in result.get("bodies", {}):
			var component: String = doc.body_component(str(body_id))
			var unit := str(ASSEMBLY_SOLVER.unit_of(doc.components, component))
			var hit: bool = units.has(component) or str(units.get(unit, "")) == "unit"
			if hit and _selection_index(PICKING.key({"kind": "body", "body": str(body_id), "index": -1, "point": Vector3.ZERO})) < 0:
				picks.append({"kind": "body", "body": str(body_id), "index": -1, "point": Vector3.ZERO})
	if mesh_selection != null:
		for body_id in mesh_selection.bodies():
			if result.get("bodies", {}).has(body_id):
				picks.append({"kind": "mesh_triangles", "body": body_id, "index": -1, "triangles": mesh_selection.triangles_of(body_id), "point": Vector3.ZERO})
	return picks


func _on_panel_values_changed(values: Dictionary) -> void:
	if command == null:
		if sketch_editor.tool != "":
			sketch_editor.on_panel_values(values)
		elif form_editor.active and form_editor.tool != "":
			form_editor.on_panel_values(values)
		return
	if _is_mesh_tool(command) and command.picked_bodies(command_values) != command.picked_bodies(values):
		# Other bodies to keep the panel off.
		_queue_mesh_panel_check(true)
	for key in drag_replaced.keys():
		if str(values.get(key, "")) != str(drag_replaced[key].now):
			# Typed in since the drag: the note about the replaced expression goes.
			drag_replaced.erase(key)
	command_values = values.duplicate(true)
	if _is_mesh_tool(command):
		# Fields still holding the value the panel chose follow the picked body (another diagonal).
		var before_adjust := command_values.duplicate(true)
		if command.adjust_values(command_values):
			_show_adjusted(before_adjust)
	command.write_values(doc, command_values)
	if not panel.active_field().is_empty() and command.fields().size() != 0:
		picker.update_display()
	if _is_inspect(command):
		_queue_view_refresh()
	else:
		_queue_recompute()


func _on_manipulator_changed(handle: Dictionary, value: Variant) -> void:
	if command == null:
		# Direct Edit's Move arrows.
		if mesh_direct_edit.active:
			mesh_direct_edit.on_handle(handle, value)
		return
	var before := str(command_values.get(handle.key, "")).strip_edges()
	match str(handle.type):
		"point":
			command_values[handle.key] = value
		"arrow":
			command_values[handle.key] = UNITS.format_value(float(value), UNITS.KIND_LENGTH, doc.units)
		"angle":
			command_values[handle.key] = UNITS.format_value(float(value), UNITS.KIND_ANGLE, doc.units)
		"ring":
			command_values[handle.key] = UNITS.format_value(float(value), UNITS.KIND_ANGLE, doc.units, 6)
		"slide":
			command_values[handle.key] = UNITS.format_value(float(value), UNITS.KIND_LENGTH, doc.units, 6)
		"scale":
			# A uniform scale dot: each of its length fields becomes its base times the ratio.
			var keys: Array = handle.get("keys", [])
			var bases: Array = handle.get("bases", [])
			for i in mini(keys.size(), bases.size()):
				var was := str(command_values.get(keys[i], "")).strip_edges()
				command_values[keys[i]] = UNITS.format_value(maxf(float(bases[i]) * float(value), float(handle.get("min", 0.0))), UNITS.KIND_LENGTH, doc.units)
				if drag_replaced.has(keys[i]):
					drag_replaced[keys[i]].now = str(command_values[keys[i]])
				elif was != "" and not DIMENSION_LAYOUT.is_number(was):
					drag_replaced[keys[i]] = {"was": was, "now": str(command_values[keys[i]])}
	if not str(handle.type) in ["point", "scale"]:
		# A field that held an expression ("width * 2"): the drag wrote a number over it.
		if drag_replaced.has(handle.key):
			drag_replaced[handle.key].now = str(command_values[handle.key])
		elif before != "" and not DIMENSION_LAYOUT.is_number(before):
			drag_replaced[handle.key] = {"was": before, "now": str(command_values[handle.key])}
	if str(handle.type) in ["ring", "slide"] and "dragging" in command:
		# A DOF drag (Drive Joints): each event drives on from the last one, with a short contact
		# deadline (spec 3.7, 8.1 #13).
		command.dragging = true
	command.write_values(doc, command_values)
	# (The dragged value shows also in the field that has the keyboard: it was not typed there.)
	panel.set_values(command_values, handle.get("keys", [handle.key]))
	if _is_inspect(command):
		# A drag changes only the command's values: the browser stays, and analyses whose inputs
		# didn't change come from the cache.
		refresh_view(false)
	else:
		recompute()


## A panel slider drag started or ended (Drive Joints' Value sliders, Motion Link's Test): a
## command with "dragging" treats it like a DOF handle drag (each event drives on from the last,
## with the short contact deadline), and hears its end as drag_ended().
func _on_panel_slider_drag(key: String, active: bool) -> void:
	if command == null:
		return
	if active:
		if "dragging" in command:
			command.dragging = true
	elif _is_inspect(command):
		command.drag_ended({"key": key, "type": "slider"})


## A handle drag ended: an inspect command hears it (Texture Map Controls measures its next drag
## from the handle again), then the handles are placed from the values.
func _on_manipulator_released(handle: Dictionary) -> void:
	if command == null and mesh_direct_edit.active:
		mesh_direct_edit.on_handle_released(handle)
		return
	if _is_inspect(command):
		command.drag_ended(handle)
	_update_command_handles()
	# (The panel stays put during a drag; the body may have moved under it.)
	_queue_mesh_panel_check(false)


## Panel hints (each expression's value or error) and the on-canvas handles.
func _update_command_feedback() -> void:
	if _is_inspect(command):
		command.result = result
		panel.set_hints(_with_drag_notes(command.hints_for(command_values)))
		command.update()
		_update_command_handles()
		return
	# An automatic operation shows in the Operation list as what it did (Join, Cut or New Body).
	if command.feature != null:
		panel.show_auto("operation", result.get("operations", {}).get(command.feature.id))
	var hints := {}
	for field in command.fields():
		if field.type != "expression":
			continue
		var input: Dictionary = command.feature.inputs.get(field.key, {})
		var r: Dictionary = result.get("values", {}).get(str(input.get("name", "")), {})
		if r.get("ok", false):
			hints[field.key] = {"ok": true, "text": UNITS.format_value(float(r.value), str(field.get("kind", "length")), doc.units)}
		else:
			hints[field.key] = {"ok": false, "text": str(r.get("error", ""))}
	if _is_mesh_tool(command):
		command.result = result
		# A field left to the kernel (empty: no input) has nothing to evaluate; its hint says so,
		# with the value the kernel used once the build reported it.
		for field in command.fields():
			var auto: String = command.auto_hint(field, command_values)
			if auto != "":
				hints[field.key] = {"ok": true, "text": auto}
		# A value out of its range: the field turns red (OK is off) and the stat row says why.
		for key in command.range_problems(command_values):
			hints[key] = {"ok": false, "text": "out of range"}
		panel.set_hints(_with_drag_notes(hints))
		panel.set_info(command.STAT_KEY, command.stat_text(command_values, last_mesh_limit < MESH_FEATURE.OK_SECONDS))
		# What the tool takes away, and what it filled in, drawn over the bodies.
		var overlays := []
		for entry in command.preview_meshes(command_values):
			overlays.append({"mesh": entry.mesh, "material": viewport.mesh_display.materials[str(entry.look)]})
		viewport.set_command_meshes(overlays)
		# (The preview may have moved the body under the panel.)
		_queue_mesh_panel_check(false)
	else:
		panel.set_hints(_with_drag_notes(hints))
		_show_operation_preview()
	_update_command_handles()


## A Join's or Cut's tool shape (an Extrude's pulled piece) drawn over the bodies while its
## command is open: green for what it adds, red for what it takes away. The rest of the body looks
## as it always does.
func _show_operation_preview() -> void:
	var id := str(command.feature.id) if command != null and command.get("feature") != null else ""
	var op := str(result.get("operations", {}).get(id, ""))
	var shape: Variant = result.get("tool_shapes", {}).get(id)
	if id == "" or result.get("errors", {}).has(id) or not OPERATION_PREVIEW_COLORS.has(op) or shape == null:
		if _operation_preview_shape != null:
			viewport.set_command_meshes([])
			_operation_preview_shape = null
		return
	if is_same(shape, _operation_preview_shape):
		return
	_operation_preview_shape = shape
	var mesh := TESSELLATE.surface_mesh(TESSELLATE.tessellate(shape))
	viewport.set_command_meshes([{"mesh": mesh, "material": _operation_preview_material(op)}])


func _operation_preview_material(op: String) -> StandardMaterial3D:
	if not _operation_preview_materials.has(op):
		var material := StandardMaterial3D.new()
		material.albedo_color = OPERATION_PREVIEW_COLORS[op]
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		# (Over the body it joins, whose faces lie on its own, and seen through what it cuts.)
		material.no_depth_test = true
		material.render_priority = 1
		_operation_preview_materials[op] = material
	return _operation_preview_materials[op]


## hints with a note on each field whose expression a handle drag replaced (drag_replaced). A
## field's own error stays: it says more.
func _with_drag_notes(hints: Dictionary) -> Dictionary:
	if drag_replaced.is_empty():
		return hints
	var out := hints.duplicate()
	for key in drag_replaced:
		if (out.get(key, {}) as Dictionary).get("ok", true):
			var was := str(drag_replaced[key].was)
			out[key] = {"ok": true, "note": true, "text": "was " + was, "tooltip": DRAG_REPLACED_NOTE % was}
	return out


func _update_command_handles() -> void:
	if command == null:
		return
	if _is_inspect(command):
		viewport.set_handles(command.manipulators(command_values, command.evaluated(command_values)))
		return
	var evaluated := {}
	for key in command.feature.inputs:
		var r: Dictionary = result.get("values", {}).get(str(command.feature.inputs[key].get("name", "")), {})
		if r.get("ok", false):
			evaluated[key] = float(r.value)
	command.result = result
	viewport.set_handles(command.manipulators(command_values, evaluated))


func _place_panel() -> void:
	if panel == null or not panel.visible:
		return
	# Below the view cube, down to the view's bottom edge; a taller panel scrolls its rows.
	panel.max_height = maxf(viewport.size.y - PANEL_TOP - 10.0, 1.0) if viewport.size.y > 0.0 else 0.0
	panel.reset_size()
	panel.position = Vector2(maxf(viewport.size.x - panel.size.x - 10.0, 10.0), PANEL_TOP)
	# Edit Form's panel moves off the gizmo when it would cover it.
	if form_editor != null and form_editor.active:
		form_editor.keep_panel_clear(true)
	# A Mesh tool's panel moves off the bodies the tool works on.
	_keep_mesh_panel_clear()


## Checks the command panel against the bodies of the open Mesh tool once, at the end of the
## frame. home (other bodies were picked): the panel is placed again from its own spot; otherwise
## (the view turned, the preview moved the body, the panel grew) it only moves when it covers
## them, so it does not jump about.
func _queue_mesh_panel_check(home: bool) -> void:
	if not _is_mesh_tool(command):
		return
	if _mesh_panel_check == "":
		_run_mesh_panel_check.call_deferred()
	if home:
		_mesh_panel_check = "home"
	elif _mesh_panel_check == "":
		_mesh_panel_check = "keep"


func _run_mesh_panel_check() -> void:
	var home := _mesh_panel_check == "home"
	_mesh_panel_check = ""
	if not _is_mesh_tool(command) or panel == null or not panel.visible:
		return
	if home:
		_place_panel()
		return
	# The panel covers the bodies now (the view turned, the preview moved them, the panel grew):
	# it is placed again from its own spot, once for each such state (where no place is clear it
	# stays at the one that covers least, and is not placed over and over).
	var rect := mesh_tool_rect()
	if not rect.has_area() or not Rect2(panel.position, panel.size).intersects(rect) or viewport.drag_kind() == "handle":
		return
	var state := [rect, viewport.size, panel.size]
	if state == _mesh_panel_placed:
		return
	_place_panel()
	_mesh_panel_placed = [mesh_tool_rect(), viewport.size, panel.size]


## The screen rectangle of the bodies the open Mesh tool works on, as they are shown now (the
## part of it inside the view); no area when none is picked or in view.
func mesh_tool_rect() -> Rect2:
	if not _is_mesh_tool(command) or doc == null:
		return Rect2()
	var found := false
	var rect := Rect2()
	for body_id in command.picked_bodies(command_values):
		var shape: Variant = (result.get("bodies", {}) as Dictionary).get(body_id, {}).get("shape")
		if shape == null or not doc.body_visible(body_id):
			continue
		var box: AABB = shape.bbox()
		for i in 8:
			var at: Vector2 = viewport.project(box.get_endpoint(i))
			if not at.is_finite():
				continue
			rect = rect.expand(at) if found else Rect2(at, Vector2.ZERO)
			found = true
	if not found:
		return Rect2()
	var view := Rect2(Vector2.ZERO, viewport.size)
	return rect.intersection(view) if rect.intersects(view) else Rect2()


## Moves the command panel off the bodies the open Mesh tool works on, where the view has room
## (the Form environment's rule and places: FORM_EDITOR.panel_spot()): the left side, under the
## bodies (shorter: its rows scroll, the result row is pinned under them) or beside them; where every
## place covers them, the one that covers least. The panel stays put while a handle is dragged.
func _keep_mesh_panel_clear() -> void:
	if not _is_mesh_tool(command) or panel == null or not panel.visible or form_editor == null or viewport.drag_kind() == "handle":
		return
	var rect := mesh_tool_rect()
	if not rect.has_area():
		return
	var spot: Dictionary = form_editor.panel_spot(panel, rect)
	if spot.is_empty():
		return
	var own_spot: Vector2 = panel.position
	var own_height: float = panel.max_height
	if float(spot.max_height) != float(panel.max_height):
		panel.max_height = float(spot.max_height)
		panel.reset_size()
	panel.position = spot.position
	# A shortened panel has a least height (its title, result row, buttons and a few rows). Where
	# the room under the bodies is less than that, the panel would run out of the view's bottom:
	# it goes back to its own spot, whole, or to the view's left side when that covers less.
	if panel.position.y + panel.size.y > viewport.size.y + 0.5:
		panel.max_height = own_height
		panel.reset_size()
		panel.position = own_spot
		var left := Vector2(10.0, own_spot.y)
		var covered_here := Rect2(own_spot, panel.size).intersection(rect).get_area()
		if left.x + panel.size.x <= viewport.size.x - 10.0 and Rect2(left, panel.size).intersection(rect).get_area() < covered_here:
			panel.position = left


## The command panel grew after it was placed (a slot's text, a long file name, a longer stat
## line): it moves left so its right edge, with OK and Cancel, stays inside the view.
func _keep_panel_inside() -> void:
	if panel == null or not panel.visible or viewport.size.x <= 0.0:
		return
	var right: float = viewport.size.x - 10.0
	if panel.position.x + panel.size.x > right + 0.5:
		panel.position.x = maxf(right - panel.size.x, 10.0)


# --- Actions ---------------------------------------------------------------------------------

func run_action(action: String) -> void:
	if files.run(action):
		return
	match action:
		"create_sketch":
			start_plane_pick()
		"finish_sketch":
			sketch_editor.end()
			_flash("Sketch finished.")
			if form_editor.active and form_editor.suspended:
				# A sketch made inside a form: back to the form, previewed with the new sketch.
				form_editor.resume()
				recompute()
		"create_form":
			if sketch_editor.active:
				sketch_editor.end()
			if command != null:
				cancel_command()
			if form_editor.active:
				form_editor.end()
			create_form()
		"finish_form":
			if form_editor.active:
				form_editor.end()
			else:
				_flash("No form is open.")
		"form_display_box", "form_display_frame", "form_display_smooth":
			if form_editor.active:
				form_editor.set_display(action.trim_prefix("form_display_"))
			else:
				_flash(FORM_EDITOR.OPEN_FIRST)
		"form_select_loop", "form_select_ring", "form_select_grow", "form_select_shrink", "form_select_range", "form_select_feature":
			if form_editor.active:
				form_editor.select_helper(action.trim_prefix("form_select_"))
			else:
				_flash(FORM_EDITOR.OPEN_FIRST)
		"fully_define":
			sketch_editor.fully_define()
		"toggle_construction":
			sketch_editor.toggle_construction()
		"explode_text":
			sketch_editor.explode_text()
		"delete":
			if sketch_editor.active:
				sketch_editor.delete_selection()
			elif form_editor.active:
				form_editor.delete_selection()
			else:
				delete_selection()
		"change_parameters":
			open_parameters()
		"compute_all":
			recompute()
			_flash("Recomputed %d feature(s)." % doc.active_count())
		"select_mode_window", "select_mode_freeform", "select_mode_paint":
			viewport.select_mode = action.trim_prefix("select_mode_")
			_flash("%s selection" % String(viewport.select_mode).capitalize())
		"mesh_pick_groups", "mesh_pick_triangles", "mesh_grow", "mesh_shrink", "mesh_connected", "mesh_boundary":
			run_mesh_select(action)
		"mesh_face_groups":
			toggle_mesh_face_groups()
		"mesh_direct_edit":
			start_direct_edit()
		"select_all" when workspace == MESH_WORKSPACE and mesh_direct_edit.active:
			var edited: RefCounted = mesh_direct_edit.working
			var every := PackedInt32Array()
			every.resize(int(edited.triangle_count()))
			for t in every.size():
				every[t] = t
			mesh_selection.set_triangles(mesh_direct_edit.body_id, every, edited)
		"clear_selection" when workspace == MESH_WORKSPACE and not mesh_selection.is_empty():
			selection.clear()
			mesh_selection.clear()
			_selection_changed(false)
		"select_all" when form_editor.active:
			form_editor.select_all()
		"invert_selection" when form_editor.active:
			form_editor.invert_selection()
		"clear_selection" when form_editor.active:
			form_editor.clear_selection()
		"select_all":
			selection.clear()
			for body_id in result.get("bodies", {}):
				if doc.body_visible(body_id):
					selection.append({"kind": "body", "body": body_id, "index": -1, "point": Vector3.ZERO})
			_selection_changed(false)
		"invert_selection":
			var chosen := _selected_bodies()
			selection.clear()
			for body_id in result.get("bodies", {}):
				if not chosen.has(body_id) and doc.body_visible(body_id):
					selection.append({"kind": "body", "body": body_id, "index": -1, "point": Vector3.ZERO})
			_selection_changed(false)
		"clear_selection":
			selection.clear()
			_selection_changed(false)
		"create_selection_set":
			if selection.is_empty():
				_flash("Select something first.")
				return
			ask("Selection Set Name", "Set%d" % (doc.selection_sets.size() + 1), func(set_name: String) -> void:
				if set_name == "":
					return
				var keys := selection.map(func(p: Dictionary) -> String: return PICKING.key(p))
				change("Create Selection Set", func() -> void: doc.selection_sets[set_name] = keys))
		"export_glb":
			if part != null:
				var path: String = part.export_glb()
				_flash(("Exported " + path + FORGE_FILES.glb_decal_note(part)) if path != "" else "Export failed")
		"new_component":
			change("New Component", func() -> void: doc.active_component = doc.new_component())
			_flash("%s is active: new bodies go into it." % doc.component_name(doc.active_component))
		"create_base_feature":
			create_base_feature()
		"toggle_contact_sets":
			toggle_contact_sets()
		"motion_study":
			open_motion_study()
		"toggle_component_colors":
			toggle_component_colors()
		"appearance":
			open_appearance_panel(false)
		"manage_materials":
			open_appearance_panel(true)
		"theme":
			# Dark Mode: switches between the dark and the light look.
			set_theme_mode("light" if theme_name == "dark" else "dark")
			_flash("%s appearance. The moon/sun button at the toolbar's right picks Dark, Light or Follow Editor." % theme_name.capitalize())


## Makes a component active (new bodies go into it); "" is the top level.
func activate_component(component_id: String) -> void:
	if doc != null and doc.active_component != component_id:
		change("Activate Component", func() -> void: doc.active_component = component_id)


## Create Base Feature: the selected bodies (or all of them) become fixed shapes in a base
## feature, so later direct edits don't depend on the history before it.
func create_base_feature() -> void:
	var bodies := _selected_bodies().keys()
	if bodies.is_empty():
		bodies = result.get("bodies", {}).keys()
	if bodies.is_empty():
		_flash("There are no bodies to put in a base feature.")
		return
	# A base feature holds B-rep shapes: a mesh body is told so.
	var gate := MESH_BODY.gate_ids({"bodies": result.get("bodies", {}), "doc": doc}, bodies)
	if gate != "":
		_flash(gate)
		return
	change("Create Base Feature", func() -> void:
		var breps := {}
		for body_id in bodies:
			breps[body_id] = result.bodies[body_id].shape.to_brep_bytes()
		doc.add_feature("base_feature", "BaseFeature", {}, {"breps": breps}))


## Deletes the selected bodies (by removing the features that created them). In the Surface
## workspace selected faces go too: they leave their bodies (a solid opens into a surface).
func delete_selection() -> void:
	if form_editor.active:
		form_editor.delete_selection()
		return
	if mesh_direct_edit.active:
		mesh_direct_edit.press("delete")
		return
	if not selected_assembly.is_empty() and selection.is_empty():
		# A selected joint, origin, group, link, contact set or study (3.11).
		delete_assembly(str(selected_assembly.list), str(selected_assembly.id))
		return
	if workspace == MESH_WORKSPACE and not mesh_selection.is_empty() and _selected_bodies().is_empty():
		delete_mesh_triangles()
		return
	var bodies := _selected_bodies().keys()
	var faces := []
	if workspace == "Surface":
		for pick in selection:
			if pick.kind == "face" and not bodies.has(pick.body):
				var ref := REFERENCES.from_pick(pick, result)
				if not ref.is_empty():
					faces.append(ref)
	if bodies.is_empty() and faces.is_empty():
		_flash("Select bodies or faces to delete." if workspace == "Surface" else "Select bodies to delete.")
		return
	_delete_bodies(bodies, faces)


func delete_feature(feature_id: String) -> void:
	var feature: Resource = doc.find_feature(feature_id)
	if feature == null:
		return
	change("Delete " + str(feature.label), func() -> void: doc.remove_feature(feature_id))


func set_rollback(count: int) -> void:
	change("Roll Back Timeline", func() -> void: doc.rollback = -1 if count >= doc.features.size() else count)


func open_parameters() -> void:
	if doc == null:
		_flash("Select or add a Forge part first.")
		return
	parameters_dialog.refresh(doc, result.get("values", {}))
	if not parameters_dialog.visible:
		parameters_dialog.popup_centered()


## Create Sketch: shows the origin planes and waits for a click on a plane or a flat face.
## on_plane(frame, plane_ref) takes the plane instead of a new sketch (Insert SVG / DXF); prompt
## replaces the status line's hint.
func start_plane_pick(on_plane := Callable(), prompt := "") -> void:
	if doc == null:
		_flash("Select or add a Forge part first.")
		return
	if command != null:
		cancel_command()
	sketch_editor.end()
	_plane_pick = true
	_plane_pick_callback = on_plane
	viewport.set_origin_visibility({"origin": true, "x_axis": true, "y_axis": true, "z_axis": true, "xy_plane": true, "xz_plane": true, "yz_plane": true})
	viewport.mouse_handler = _plane_pick_mouse
	_flash(prompt if prompt != "" else "Create Sketch: click an origin plane or a flat face (Esc to cancel).")


## True while the view waits for a plane click (Create Sketch, Insert SVG / DXF).
func is_picking_plane() -> bool:
	return _plane_pick


func _end_plane_pick() -> void:
	if not _plane_pick:
		return
	_plane_pick = false
	_plane_pick_callback = Callable()
	if command != null:
		viewport.mouse_handler = _command_mouse
	elif sketch_editor.active:
		viewport.mouse_handler = sketch_editor.handle_mouse
	elif form_editor.active and not form_editor.suspended:
		viewport.mouse_handler = form_editor.handle_mouse
	else:
		viewport.mouse_handler = Callable()
	if doc != null:
		viewport.set_origin_visibility(doc.origin_visibility)


func _plane_pick_mouse(event: InputEvent) -> bool:
	var button := event as InputEventMouseButton
	if button == null:
		return false
	if not button.pressed:
		return true
	var plane := plane_at(button.position)
	if plane.is_empty():
		_flash("Click an origin plane or a flat face.")
		return true
	var on_plane := _plane_pick_callback
	_end_plane_pick()
	if on_plane.is_valid():
		on_plane.call(plane.frame, plane.ref)
	else:
		create_sketch(plane.frame, plane.ref)
	return true


## The sketch plane under a screen position: a planar face, or the nearest origin plane square.
## Returns {"frame": {"origin", "x", "y"}, "ref"} or {}.
func plane_at(screen: Vector2) -> Dictionary:
	var face_pick: Dictionary = viewport.face_hit_at(screen)
	if not face_pick.is_empty() and result.get("bodies", {}).has(face_pick.body):
		var info: Dictionary = result.bodies[face_pick.body].shape.face_info(int(face_pick.face))
		if info.get("planar", false):
			return {"frame": SKETCH_DATA.face_plane(info.point, info.normal), "ref": "face:%s:%d" % [face_pick.body, int(face_pick.face)]}
	var size: float = viewport.origin_size()
	var camera_position: Vector3 = viewport.camera_position()
	var best := {}
	var best_distance := INF
	for key in ["xy", "xz", "yz"]:
		var frame: Dictionary = SKETCH_DATA.ORIGIN_PLANES[key]
		var normal: Vector3 = (frame.x as Vector3).cross(frame.y)
		var hit = viewport.plane_hit(screen, Vector3.ZERO, normal)
		if hit == null:
			continue
		var p: Vector3 = hit
		# The origin plane squares span 0..size along the plane's two world axes.
		var spans := [absf(normal.x) < 0.5 and p.x >= 0.0 and p.x <= size, absf(normal.y) < 0.5 and p.y >= 0.0 and p.y <= size,
			absf(normal.z) < 0.5 and p.z >= 0.0 and p.z <= size]
		var inside := 0
		for flag in spans:
			inside += 1 if flag else 0
		if inside < 2:
			continue
		var d := camera_position.distance_to(p)
		if d < best_distance:
			best_distance = d
			best = {"frame": frame, "ref": key}
	return best


## Adds a sketch on a plane frame (one undo step) and starts editing it.
func create_sketch(frame: Dictionary, plane_ref: String) -> Resource:
	var created := [""]
	change("Create Sketch", func() -> void:
		var feature: Resource = doc.add_feature("sketch", "Sketch", {}, SKETCH_DATA.new_options(frame, plane_ref))
		created[0] = feature.id
		# Inside a form the sketch goes before it (the form's preview stops after the form).
		_move_before_form(feature))
	var feature: Resource = doc.find_feature(created[0])
	if feature != null:
		if form_editor.active:
			form_editor.suspend()
		sketch_editor.begin(feature)
		if _pending_sketch_tool != "":
			sketch_editor.start_tool(_pending_sketch_tool)
	_pending_sketch_tool = ""
	return feature


## Create Form: adds a Form feature at the timeline marker (one undo step) and opens it. The
## preview id is set inside the step, since change() rebuilds before it returns.
func create_form() -> Resource:
	if doc == null:
		_flash("Select or add a Forge part first.")
		return null
	var created := [""]
	change("Create Form", func() -> void:
		var f: Resource = doc.add_feature("form", "Form", {}, FORM.new_options())
		created[0] = f.id
		form_preview = f.id)
	var feature: Resource = doc.find_feature(created[0])
	if feature != null:
		form_editor.begin(feature)
	else:
		form_preview = ""
	return feature


func _set_feature_option(feature_id: String, key: String, value: Variant, action_name: String) -> void:
	change(action_name, func() -> void:
		var feature: Resource = doc.find_feature(feature_id)
		if feature != null:
			feature.options[key] = value)


func save_view() -> void:
	ask("Named View", "View%d" % (doc.named_views.size() + 1), func(view_name: String) -> void:
		if view_name == "":
			return
		var state: Dictionary = viewport.view_state()
		change("Save Named View", func() -> void: doc.named_views[view_name] = state))


func go_to_view(view_name: String) -> void:
	if doc != null and doc.named_views.has(view_name):
		viewport.set_view_state(doc.named_views[view_name])


## A one-line text prompt; callback receives the entered text.
func ask(title: String, default_text: String, callback: Callable) -> void:
	_prompt.title = title
	_prompt_edit.text = default_text
	_prompt_callback = callback
	_prompt.popup_centered(Vector2i(320, 90))
	_prompt_edit.grab_focus()
	_prompt_edit.select_all()


# --- Analyses (Inspect) ----------------------------------------------------------------------

## Shows every visible doc.analyses entry in the view (core/analysis.gd build output). Per body
## the last analysis that recolors it wins; lines, extra meshes and points stack. Readouts go to
## the bottom-left label and analysis_results.
## Analyses are built from their live options (_live_input(); the build leaves hidden bodies out
## and finds picked references again). An entry whose input is as last built, on the same rebuild
## with the same bodies shown, comes from the cache, so handle drags and picks that change no
## analysis rebuild none.
func _refresh_analyses() -> void:
	analysis_results.clear()
	var display := {"body_meshes": {}, "body_materials": {}, "lines": [], "meshes": [], "points": []}
	var lines := PackedStringArray()
	var shown_ids := []
	var changed := false
	if doc != null:
		var shown_bodies := _shown_bodies()
		var poses := inspect_poses()
		if not is_same(result, _analysis_cache_result) or shown_bodies != _analysis_cache_bodies:
			_analysis_cache.clear()
			_analysis_cache_result = result
			_analysis_cache_bodies = shown_bodies
			changed = true
		for entry in doc.analyses:
			if not bool(entry.get("visible", true)):
				continue
			var id := str(entry.get("id", ""))
			var label := str(entry.get("name", entry.get("type", "")))
			shown_ids.append(id)
			var input := _live_input(entry)
			var cached: Dictionary = _analysis_cache.get(id, {})
			var built: Dictionary
			if not cached.is_empty() and cached.input == input and cached.get("poses", {}) == poses:
				built = cached.built
			else:
				# (The posed bodies, for the total Center of Mass point: C7.4.)
				built = ANALYSIS.build(input, result, tessellations, kernel, doc, poses)
				analysis_build_count += 1
				_analysis_cache[id] = {"input": input, "built": built, "poses": poses}
				changed = true
			if built.has("error"):
				analysis_results[id] = {"name": label, "info": "", "error": str(built.error)}
				lines.append("⚠ %s: %s" % [label, built.error])
				continue
			analysis_results[id] = {"name": label, "info": str(built.info), "error": ""}
			for body_id in built.body_materials:
				display.body_materials[body_id] = built.body_materials[body_id]
				if built.body_meshes.has(body_id):
					display.body_meshes[body_id] = built.body_meshes[body_id]
				else:
					display.body_meshes.erase(body_id)
			display.lines.append_array(built.lines)
			display.meshes.append_array(built.meshes)
			display.points.append_array(built.points)
			# Environment Map: one reflection probe over the model while it shows.
			if built.has("reflection_probe"):
				display["reflection_probe"] = built.reflection_probe
			if str(built.info) != "":
				lines.append("%s: %s" % [label, built.info])
		for id in _analysis_cache.keys():
			if not shown_ids.has(id):
				_analysis_cache.erase(id)
	if changed or shown_ids != _analysis_shown:
		_analysis_version += 1
		_analysis_shown = shown_ids
	display["version"] = _analysis_version
	viewport.set_analysis_display(display)
	_analysis_label.text = "\n".join(lines)


## The ids of the rebuild's bodies the view shows (analyses leave the others out).
func _shown_bodies() -> Array:
	return result.get("bodies", {}).keys().filter(func(body_id: Variant) -> bool: return doc.body_visible(str(body_id)))


## What an analysis entry is built from now: {"type", "options"} with its options taken from its
## panel values again (ANALYSIS_COMMAND.live_options), so expressions follow their parameters.
func _live_input(entry: Dictionary) -> Dictionary:
	var type := str(entry.get("type", ""))
	var reader: RefCounted = ANALYSIS_COMMAND.new("analysis:" + type)
	reader.workspace = self
	return {"type": type, "options": reader.live_options(entry.get("options", {})).duplicate(true)}


## A visible analysis' readout (its info or error), "Hidden." for a hidden one.
func analysis_text(analysis_id: String) -> String:
	var r: Dictionary = analysis_results.get(analysis_id, {})
	if r.is_empty():
		return "Hidden." if analysis_index(analysis_id) >= 0 else ""
	return str(r.error) if str(r.error) != "" else str(r.info)


func analysis_index(analysis_id: String) -> int:
	if doc == null:
		return -1
	for i in doc.analyses.size():
		if str(doc.analyses[i].get("id", "")) == analysis_id:
			return i
	return -1


## Shows or hides an analysis (the browser's eye), one undo step.
func toggle_analysis(analysis_id: String) -> void:
	var i := analysis_index(analysis_id)
	if i < 0:
		return
	var shown := bool(doc.analyses[i].get("visible", true))
	change("Hide Analysis" if shown else "Show Analysis", func() -> void: doc.analyses[i]["visible"] = not shown)


func rename_analysis(analysis_id: String, new_name: String) -> void:
	var i := analysis_index(analysis_id)
	if i >= 0 and new_name != "" and str(doc.analyses[i].get("name", "")) != new_name:
		change("Rename Analysis", func() -> void: doc.analyses[i]["name"] = new_name)


func delete_analysis(analysis_id: String) -> void:
	var i := analysis_index(analysis_id)
	if i >= 0:
		change("Delete " + str(doc.analyses[i].get("name", "Analysis")), func() -> void: doc.analyses.remove_at(i))


## Opens an analysis' options again (double-click in the browser). While its own panel is open
## (the entry it is making or editing) that panel stays; another running command is cancelled
## first, and the analysis is opened only if it is still there afterwards.
func edit_analysis(analysis_id: String) -> void:
	if _command_edits(ANALYSIS_COMMAND, analysis_id):
		panel.focus_first()
		return
	if command != null:
		cancel_command()
	var i := analysis_index(analysis_id)
	if i < 0:
		return
	var analysis_command: RefCounted = ANALYSIS_COMMAND.new("analysis:" + str(doc.analyses[i].get("type", "")))
	analysis_command.entry_id = analysis_id
	analysis_command.editing = true
	start_command(analysis_command)


## True when the running command is a script's command (analysis or image) on the entry entry_id:
## the one it added when it started, or the one it edits.
func _command_edits(command_script: Script, entry_id: String) -> bool:
	return command != null and command.get_script() == command_script and str(command.get("entry_id")) == entry_id


## Display Component Colors (Shift+N): shows or hides the component colors analysis, adding it
## the first time. One undo step.
func toggle_component_colors() -> void:
	if doc == null:
		_flash("Select or add a Forge part first.")
		return
	for i in doc.analyses.size():
		if str(doc.analyses[i].get("type", "")) == "component_colors":
			var shown := bool(doc.analyses[i].get("visible", true))
			change("Display Component Colors", func() -> void: doc.analyses[i]["visible"] = not shown)
			return
	change("Display Component Colors", func() -> void: doc.analyses.append(ANALYSIS_COMMAND.new_entry(doc, "component_colors", {})))


# --- Appearances -----------------------------------------------------------------------------

## Opens the Appearance panel (manage: Manage Materials, which also lists the design's own
## materials); running the same tool again closes it.
func open_appearance_panel(manage := false) -> void:
	if doc == null:
		_flash("Select or add a Forge part first.")
		return
	if appearance_panel.visible and appearance_panel.manage == manage:
		appearance_panel.visible = false
		return
	appearance_panel.open(manage)


## doc.appearances keys for the view selection: picked faces by their persistent names (with
## faces false, their body), other picks by their body; with components true, the components of
## everything picked (top-level bodies keep a body target).
func appearance_targets(components := false, faces := true) -> PackedStringArray:
	var targets := PackedStringArray()
	if doc == null:
		return targets
	for pick in selection:
		var body_id := str(pick.get("body", ""))
		var body: Dictionary = result.get("bodies", {}).get(body_id, {})
		if body.is_empty():
			continue
		var target := APPEARANCE.body_target(body_id)
		var component: String = doc.body_component(body_id)
		if components and component != "":
			target = APPEARANCE.component_target(component)
		elif not components and faces and str(pick.kind) in ["face", "mesh_group"]:
			# (A face group of a mesh body is a face here: it takes an appearance of its own.)
			var face_name := _picked_face_name(body, pick)
			if face_name != "":
				target = APPEARANCE.face_target(body_id, face_name)
		if not targets.has(target):
			targets.append(target)
	return targets


## The doc.appearances keys whose looks the picked faces and bodies show (a face's own entry, a
## split face's original, its body's or a component's; see APPEARANCE.resolve), for editing the
## mapping of what is on screen. Picks that show no appearance are left out.
func shown_appearance_targets() -> PackedStringArray:
	var targets := PackedStringArray()
	if doc == null:
		return targets
	for pick in selection:
		var body_id := str(pick.get("body", ""))
		var body: Dictionary = result.get("bodies", {}).get(body_id, {})
		if body.is_empty():
			continue
		var face_name := _picked_face_name(body, pick) if str(pick.kind) in ["face", "mesh_group"] else ""
		var target := str(APPEARANCE.resolve(doc, body_id, face_name).get("target", ""))
		if target != "" and not targets.has(target):
			targets.append(target)
	return targets


func _picked_face_name(body: Dictionary, pick: Dictionary) -> String:
	var names: PackedStringArray = body.shape.get_face_names()
	var index := int(pick.get("index", -1))
	return names[index] if index >= 0 and index < names.size() else ""


## Gives each target an appearance id (keeping its texture mapping), one undo step. Returns how
## many targets it set.
func apply_appearance(material_id: String, targets: PackedStringArray) -> int:
	if doc == null or material_id == "" or targets.is_empty():
		return 0
	# Where each picked face group of a mesh body was picked (APPEARANCE.face_anchor): kept with
	# its entry, so the appearance follows the group when an earlier change renumbers the groups.
	var anchors := {}
	for pick in selection:
		var body: Dictionary = result.get("bodies", {}).get(str(pick.get("body", "")), {})
		var anchor: Dictionary = APPEARANCE.face_anchor(pick)
		if body.is_empty() or anchor.is_empty():
			continue
		var face_name := _picked_face_name(body, pick)
		if face_name != "":
			anchors[APPEARANCE.face_target(str(pick.body), face_name)] = anchor
	change("Apply Appearance", func() -> void:
		for target in targets:
			var old: Dictionary = doc.appearances.get(target, {})
			var entry := {"material": material_id, "mapping": (old.get("mapping", {}) as Dictionary).duplicate(true)}
			# (The place it was picked now, else the one it had.)
			for key in ["at", "normal"]:
				if (anchors.get(target, {}) as Dictionary).has(key):
					entry[key] = anchors[target][key]
				elif old.get(key) is Vector3 and not anchors.has(target):
					entry[key] = old[key]
			doc.appearances[target] = entry)
	return targets.size()


## Takes the targets' own appearances off (they show their body's or component's again).
func clear_appearance(targets: PackedStringArray) -> void:
	var present := Array(targets).filter(func(target: String) -> bool: return doc.appearances.has(target))
	if present.is_empty():
		_flash("The selection has no appearance of its own.")
		return
	change("Remove Appearance", func() -> void:
		for target in present:
			doc.appearances.erase(target))


## Changes texture mapping keys (type, scale, rotation, offset, origin, axis) of the targets
## that have an appearance of their own, one undo step.
func set_appearance_mapping(targets: PackedStringArray, changes: Dictionary) -> void:
	var own := Array(targets).filter(func(target: String) -> bool: return doc.appearances.has(target))
	if own.is_empty():
		_flash("Apply an appearance to the selection first.")
		return
	change("Texture Mapping", func() -> void:
		for target in own:
			# A running command's starting state (change()) may not have the target's entry.
			var entry: Variant = doc.appearances.get(target)
			if not entry is Dictionary:
				continue
			var mapping: Dictionary = ((entry as Dictionary).get("mapping", {}) as Dictionary).duplicate(true)
			mapping.merge(changes, true)
			entry["mapping"] = mapping)


## How many targets use each appearance id: {id: count}.
func appearance_uses() -> Dictionary:
	var uses := {}
	if doc == null:
		return uses
	for target in doc.appearances:
		var id := str((doc.appearances[target] as Dictionary).get("material", ""))
		if id != "":
			uses[id] = int(uses.get(id, 0)) + 1
	return uses


## Swaps one appearance for another everywhere it is used ("" new_id removes it), one undo step.
## Returns how many targets changed.
func replace_appearance(old_id: String, new_id: String) -> int:
	if doc == null or old_id == "" or old_id == new_id:
		return 0
	var keys := []
	for target in doc.appearances:
		if str((doc.appearances[target] as Dictionary).get("material", "")) == old_id:
			keys.append(target)
	if keys.is_empty():
		return 0
	change("Replace Appearance" if new_id != "" else "Remove Appearance", func() -> void:
		for target in keys:
			if new_id == "":
				doc.appearances.erase(target)
			elif doc.appearances.get(target) is Dictionary:
				doc.appearances[target]["material"] = new_id)
	return keys.size()


# --- Canvases and decals ---------------------------------------------------------------------

## Shows doc.canvases (view only) and doc.decals in the view; a hidden body hides its decals.
func _refresh_images() -> void:
	var canvases := []
	var decals := []
	if doc != null:
		for entry in doc.canvases:
			canvases.append({"texture": image_texture(str(entry.get("image", ""))), "origin": entry.get("origin", Vector3.ZERO),
				"x": entry.get("x", Vector3.RIGHT), "y": entry.get("y", Vector3.FORWARD), "size": entry.get("size", Vector2.ONE),
				"opacity": float(entry.get("opacity", 0.5)), "through": bool(entry.get("through", false)),
				"visible": bool(entry.get("visible", true))})
		for entry in doc.decals:
			var body_id := str(entry.get("body", ""))
			if not result.get("bodies", {}).has(body_id):
				continue
			# On its face as the body is now (the bake does the same), so the view's decal follows
			# parametric edits even where follow_geometry left the entry (a lost face keeps it).
			var placed := APPEARANCE.placed_decal(entry, result.bodies[body_id].shape, kernel)
			# ("body": the view shows the decal where the assembly places its body.)
			decals.append({"body": body_id, "transform": APPEARANCE.decal_transform(placed), "size": APPEARANCE.decal_size(placed),
				"texture": image_texture(str(entry.get("image", ""))), "visible": bool(entry.get("visible", true)) and doc.body_visible(body_id)})
	viewport.set_canvases(canvases)
	viewport.set_decals(decals)


## An image file's texture (null when it can't be read), read again when the file changes.
func image_texture(path: String) -> Texture2D:
	if path == "":
		return null
	var stamp := FileAccess.get_modified_time(path) if FileAccess.file_exists(path) else 0
	var cached: Dictionary = _textures.get(path, {})
	if cached.is_empty() or int(cached.stamp) != stamp:
		cached = {"stamp": stamp, "texture": MATERIAL_LIBRARY.load_texture(path)}
		_textures[path] = cached
	return cached.texture


## The index of a canvas or decal (list: "canvases" | "decals"), or -1.
func image_index(list: String, image_id: String) -> int:
	if doc == null or not list in ["canvases", "decals"]:
		return -1
	var entries: Array = doc.get(list)
	for i in entries.size():
		if str(entries[i].get("id", "")) == image_id:
			return i
	return -1


func _image_entry(list: String, image_id: String) -> Dictionary:
	var i := image_index(list, image_id)
	return (doc.get(list) as Array)[i] if i >= 0 else {}


## Shows or hides a canvas or decal (the browser's eye), one undo step.
func toggle_image(list: String, image_id: String) -> void:
	var target := _image_entry(list, image_id)
	if target.is_empty():
		return
	var shown := bool(target.get("visible", true))
	change(("Hide " if shown else "Show ") + str(target.get("name", "Image")), func() -> void:
		var entry := _image_entry(list, image_id)
		entry["visible"] = not shown)


func rename_image(list: String, image_id: String, new_name: String) -> void:
	var target := _image_entry(list, image_id)
	if not target.is_empty() and new_name != "" and str(target.get("name", "")) != new_name:
		change("Rename " + str(target.get("name", "Image")), func() -> void:
			var entry := _image_entry(list, image_id)
			entry["name"] = new_name)


func delete_image(list: String, image_id: String) -> void:
	var i := image_index(list, image_id)
	if i >= 0:
		change("Delete " + str((doc.get(list) as Array)[i].get("name", "Image")), func() -> void: (doc.get(list) as Array).remove_at(i))


## Opens a canvas or decal's panel again (double-click in the browser), like edit_analysis(): its
## own open panel stays, another running command is cancelled first.
func edit_image(list: String, image_id: String) -> void:
	if _command_edits(IMAGE_COMMAND, image_id) and IMAGE_COMMAND.list_name(str(command.type)) == list:
		panel.focus_first()
		return
	if command != null:
		cancel_command()
	if image_index(list, image_id) < 0:
		return
	var image_command: RefCounted = IMAGE_COMMAND.new("insert:decal" if list == "decals" else "insert:canvas")
	image_command.entry_id = image_id
	image_command.editing = true
	start_command(image_command)


# --- Keys and menus --------------------------------------------------------------------------

## Escape in Orbit, Pan or Zoom goes back to Select and does nothing else: the open command and its
## picks stay. True when it did.
func _leave_navigation() -> bool:
	if viewport == null or viewport.nav_mode == VIEWPORT.NavMode.SELECT:
		return false
	viewport.set_nav_mode(VIEWPORT.NavMode.SELECT)
	_flash("Back to Select")
	return true


## Escape reaches Orbit, Pan or Zoom before a focused panel field takes it (the field would cancel
## the command).
func _input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo or key.keycode != KEY_ESCAPE or not is_visible_in_tree():
		return
	if key.ctrl_pressed or key.alt_pressed or key.meta_pressed:
		return
	var focus := get_viewport().gui_get_focus_owner()
	if (focus == null or is_ancestor_of(focus)) and _leave_navigation():
		get_viewport().set_input_as_handled()


## Single-key shortcuts while the Forge view has focus. Modified keys (Ctrl+Z, ...) go to Godot.
func handle_key(event: InputEventKey) -> bool:
	if form_editor.active and not _plane_pick and form_editor.handle_key(event):
		return true
	# Direct Edit takes Ctrl+Z (its own steps), Enter, Escape and Delete while it is open.
	if mesh_direct_edit.active and command == null and mesh_direct_edit.handle_key(event):
		return true
	if event.ctrl_pressed or event.alt_pressed or event.meta_pressed:
		return false
	if event.keycode == KEY_ESCAPE and _leave_navigation():
		return true
	if _plane_pick and event.keycode == KEY_ESCAPE and viewport.mouse_handler == _plane_pick_mouse:
		var inserting := _plane_pick_callback.is_valid()
		_pending_sketch_tool = ""
		_end_plane_pick()
		if form_editor.active and form_editor.tool != "":
			# A Form primitive's plane pick: the tool stays open and OK places it on the XY plane.
			_flash("Plane pick cancelled: OK places the %s on the XY plane, or pick a plane again." % str(form_editor.tool_title()))
		else:
			_flash("Insert cancelled." if inserting else "Create Sketch cancelled.")
		return true
	if sketch_editor.active and sketch_editor.handle_key(event):
		return true
	if event.shift_pressed and event.keycode == KEY_N:
		run_action("toggle_component_colors")
		return true
	# Shift+F: Display Mesh Face Groups, where mesh bodies are worked on (elsewhere F is Fillet).
	if event.shift_pressed and event.keycode == KEY_F and workspace in [MESH_WORKSPACE, "Utilities"]:
		run_action("mesh_face_groups")
		return true
	match event.keycode:
		KEY_ESCAPE:
			if marking_menu.visible:
				marking_menu.close()
			elif command != null:
				cancel_command()
			else:
				selection.clear()
				mesh_selection.clear()
				_selection_changed(false)
			return true
		KEY_ENTER, KEY_KP_ENTER:
			if command != null:
				accept_from_ui()
				return true
			return false
		KEY_DELETE, KEY_BACKSPACE:
			delete_selection()
			return true
		KEY_S:
			var at := viewport.get_local_mouse_position() + Vector2(8, 8)
			at.x = clampf(at.x, 4.0, maxf(viewport.size.x - command_search.custom_minimum_size.x - 4.0, 4.0))
			at.y = clampf(at.y, 4.0, maxf(viewport.size.y - command_search.custom_minimum_size.y - 4.0, 4.0))
			command_search.open(at, "Form" if form_editor.active else workspace)
			return true
		KEY_F6:
			viewport.fit()
			return true
	var tool := tool_for_key(OS.get_keycode_string(event.keycode))
	if not tool.is_empty():
		run_tool(tool)
		return true
	return false


## The tool for a shortcut letter: Editor Settings overrides first, then the defaults. In a
## sketch the Sketch toolbar's keys come first; other letters run the workspace's own tools (E in
## a sketch in the Surface workspace is the surface Extrude).
func tool_for_key(letter: String) -> Dictionary:
	if letter.length() != 1:
		return {}
	if Engine.is_editor_hint():
		var overrides = EditorInterface.get_editor_settings().get_setting(SHORTCUTS_SETTING)
		if overrides is Dictionary and overrides.has(letter):
			return CATALOG.find(str(overrides[letter]))
	if sketch_editor.active:
		var sketch_tool := CATALOG.for_shortcut(CATALOG.SKETCH_WORKSPACE, letter)
		if sketch_tool.is_empty() or sketch_tool.workspace == CATALOG.SKETCH_WORKSPACE:
			return sketch_tool
	if form_editor.active:
		# Only the Form toolbar's keys: another workspace's tool would finish the form.
		var form_tool := CATALOG.for_shortcut("Form", letter)
		return form_tool if str(form_tool.get("workspace", "")) == "Form" else {}
	return CATALOG.for_shortcut(workspace, letter)


func _open_marking_menu(at: Vector2) -> void:
	var face_pick: Dictionary = viewport.face_hit_at(at)
	var tool_or_phase := func(name: String) -> Dictionary:
		var tool := _first_tool(name)
		return {"label": name, "enabled": CATALOG.is_enabled(tool), "tooltip": "" if CATALOG.is_enabled(tool) else "Phase %d" % tool.get("phase", 0), "action": func() -> void: run_tool(tool)}
	var repeat_label := "Repeat " + str(last_tool.get("name", "")) if not last_tool.is_empty() else "Repeat"
	# While sketching, Delete takes the sketch's selection.
	var delete_slot := {"label": "Delete", "enabled": not selection.is_empty(), "action": delete_selection}
	if sketch_editor.active:
		delete_slot = {"label": "Delete", "enabled": not sketch_editor.selection.is_empty(), "action": func() -> void: sketch_editor.delete_selection()}
	elif form_editor.active:
		delete_slot = {"label": "Delete", "enabled": not form_editor.selection.is_empty(), "action": func() -> void: form_editor.delete_selection()}
	var slots: Array[Dictionary] = [
		{"label": repeat_label, "enabled": not last_tool.is_empty(), "action": func() -> void: run_tool(last_tool)},
		delete_slot,
		tool_or_phase.call("Press Pull"),
		{"label": "Undo", "enabled": history() != null and history().has_undo(), "action": func() -> void: history().undo()},
		{"label": "Redo", "enabled": history() != null and history().has_redo(), "action": func() -> void: history().redo()},
		{"label": "Finish Sketch", "action": func() -> void: run_action("finish_sketch")} if sketch_editor.active else ({"label": "Finish Form", "action": func() -> void: form_editor.finish()} if form_editor.active else tool_or_phase.call("Create Sketch")),
		tool_or_phase.call("Extrude"),
		tool_or_phase.call("Move/Copy"),
	]
	# The sketch's own entries come first: a dimension's choices while placing it, or what can be
	# done with the dimension right-clicked.
	var overflow: Array[Dictionary] = []
	if sketch_editor.active:
		overflow.append_array(sketch_editor.context_entries(at))
	elif form_editor.active:
		overflow.append_array(form_editor.context_entries(at))
	else:
		# A body a form made: open its form again.
		for pick in selection:
			var made_by: Resource = doc.find_feature(str(result.get("bodies", {}).get(pick.body, {}).get("feature", ""))) if doc != null else null
			if made_by != null and made_by.type == "form":
				var form_id: String = made_by.id
				overflow.append({"label": "Edit Form", "action": func() -> void: edit_feature(form_id)})
				break
		# The body under the cursor (else the selected one): what a mesh body is usually sent to
		# next, or Tessellate for a solid in the Mesh workspace.
		var menu_body := str(face_pick.get("body", "")) if not face_pick.is_empty() else ""
		if menu_body == "":
			for pick in _selection_picks():
				menu_body = str(pick.get("body", ""))
				break
		for entry in mesh_body_entries(menu_body):
			overflow.append(entry)
	if not face_pick.is_empty():
		var normal: Vector3 = viewport.face_normal(face_pick.body, face_pick.face)
		var point: Vector3 = face_pick.point
		overflow.append({"label": "Look At", "action": func() -> void: viewport.look_at_face(point, normal)})
	overflow.append({"label": "Fit (F6)", "action": viewport.fit})
	overflow.append({"label": "Home View", "action": viewport.home})
	overflow.append({"label": "Save Named View...", "action": save_view})
	overflow.append({"label": "Select All", "action": func() -> void: run_action("select_all")})
	if not selection.is_empty():
		overflow.append({"label": "Hide Selected", "action": _hide_selected})
	overflow.append({"label": "Show All Bodies", "action": _show_all_bodies})
	overflow.append({"label": "Change Parameters", "action": open_parameters})
	overflow.append({"label": "Search Tools (S)", "action": func() -> void: command_search.open(at, workspace)})
	marking_menu.open(at, slots, overflow)


func _first_tool(tool_name: String) -> Dictionary:
	for tool in CATALOG.all_tools():
		if tool.name == tool_name and tool.workspace == workspace:
			return tool
	for tool in CATALOG.all_tools():
		if tool.name == tool_name:
			return tool
	return {}


# --- Selection -------------------------------------------------------------------------------

func _on_pick_clicked(pick: Dictionary, shift: bool, ctrl: bool) -> void:
	if sketch_editor.active and not pick.is_empty() and sketch_editor.add_3d_pick(pick):
		return
	if command != null and panel.active_selection_key != "":
		if not pick.is_empty():
			panel.add_selection(pick.body)
		return
	if command == null and not sketch_editor.active and not form_editor.active and assembly_display != null and is_inside_tree():
		# A joint badge wins over the bodies behind it (3.11): it selects the joint.
		var joint_id: String = assembly_display.joint_at(viewport, viewport.get_local_mouse_position())
		if joint_id != "":
			select_assembly("joints", joint_id)
			return
	if not selected_assembly.is_empty() or not selected_components.is_empty():
		selected_components.clear()
		_select_assembly_entry({})
	if _selects_mesh() and (pick.is_empty() or str(pick.kind).begins_with("mesh_")):
		# The Mesh workspace: a click on a mesh body picks a face group or a triangle.
		if pick.is_empty() and not shift and not ctrl:
			selection.clear()
		mesh_selection.click(pick, shift, ctrl, mesh_shapes().get(pick.get("body", "")))
		_selection_changed(true)
		return
	if pick.is_empty():
		if not shift and not ctrl:
			selection.clear()
	else:
		var index := _selection_index(PICKING.key(pick))
		if index >= 0:
			selection.remove_at(index)
		else:
			selection.append(pick)
	_selection_changed(true)


func _on_region_selected(picks: Array, _additive: bool) -> void:
	if command != null and panel.active_selection_key != "":
		for pick in picks:
			if pick.kind == "body":
				panel.add_selection(pick.body)
		return
	var on_mesh := _selects_mesh()
	if on_mesh:
		_select_mesh_region(viewport.last_region)
	for pick in picks:
		# (In the Mesh workspace a region takes a mesh body's triangles, not the body.)
		if on_mesh and MESH_BODY.is_mesh(result.get("bodies", {}).get(pick.body, {})):
			continue
		if _selection_index(PICKING.key(pick)) < 0:
			selection.append(pick)
	_selection_changed(true)


func _on_paint_picked(pick: Dictionary) -> void:
	if _selects_mesh() and str(pick.kind).begins_with("mesh_"):
		var shape: RefCounted = mesh_shapes().get(pick.body)
		if shape != null:
			if mesh_selection.mode == MESH_SELECTION.GROUPS:
				mesh_selection.add(str(pick.body), PackedInt32Array([int(pick.triangle)]), shape)
			else:
				mesh_selection.paint(str(pick.body), shape, pick.point, PAINT_PX / maxf(viewport.pixels_per_meter_at(pick.point), 1e-9))
			_selection_changed(false)
		return
	if _selection_index(PICKING.key(pick)) < 0:
		selection.append(pick)
		_selection_changed(true)


func _selection_index(key: String) -> int:
	for i in selection.size():
		if PICKING.key(selection[i]) == key:
			return i
	return -1


## The last rebuild's surface bodies (id -> true): open shells, shown with their own look.
func _surface_bodies() -> Dictionary:
	var ids := {}
	for body_id in result.get("bodies", {}):
		var shape: RefCounted = result.bodies[body_id].shape
		if shape != null and shape.is_surface():
			ids[body_id] = true
	return ids


func _selected_bodies() -> Dictionary:
	var bodies := {}
	for pick in selection:
		if pick.kind == "body":
			bodies[pick.body] = true
	return bodies


func _selection_changed(update_browser: bool) -> void:
	viewport.set_highlights(_selection_picks(), hover)
	if update_browser:
		browser.refresh(doc, result.get("bodies", {}).keys(), _selected_bodies(), _surface_bodies())
		_mark_mesh_bodies()
	_update_status()
	selection_updated.emit()


# --- Mesh bodies and the Mesh workspace -------------------------------------------------------

## The rebuild's mesh bodies as {body id: CadMesh} (Direct Edit's working mesh for its body).
func mesh_shapes() -> Dictionary:
	var shapes := {}
	for body_id in result.get("bodies", {}):
		var shape: RefCounted = result.bodies[body_id].shape
		if MESH_BODY.is_mesh(shape):
			shapes[body_id] = shape
	if mesh_direct_edit != null and mesh_direct_edit.active and shapes.has(mesh_direct_edit.body_id) and mesh_direct_edit.working != null:
		shapes[mesh_direct_edit.body_id] = mesh_direct_edit.working
	return shapes


## The kinds the active selection slot accepts ([] when no slot is active).
func active_kinds() -> Array:
	return _active_kinds()


## Redraws the view's highlights from the running command's picks.
func refresh_picks() -> void:
	picker.update_display()
	_update_highlights()


## Shows what is under the cursor for a Mesh tool's active slot: a reference it would pick
## ({"kind": "body" | "mesh_group" | "mesh_triangles", ...}), or {}.
func set_mesh_hover(ref: Dictionary) -> void:
	var next := {}
	var shape: RefCounted = mesh_shapes().get(ref.get("body", ""))
	if shape != null:
		match str(ref.get("kind", "")):
			"body":
				next = {"kind": "body", "body": ref.body, "index": -1, "point": Vector3.ZERO}
			"mesh_group":
				next = {"kind": "mesh_group", "body": ref.body, "index": int(shape.find_face(str(ref.get("group", "")))), "point": Vector3.ZERO}
			"mesh_triangles":
				var triangles: PackedInt32Array = ref.get("triangles", PackedInt32Array())
				next = {"kind": "mesh_triangle", "body": ref.body, "index": triangles[0] if not triangles.is_empty() else -1, "point": Vector3.ZERO}
	if str(next) == str(_mesh_hover):
		return
	_mesh_hover = next
	_update_highlights()


## True for a Mesh workspace tool's command (tools/feature_command.gd is_mesh_tool()).
func _is_mesh_tool(c: RefCounted) -> bool:
	return c != null and not _is_inspect(c) and c.has_method("is_mesh_tool") and c.is_mesh_tool()


## True while a rebuild is a Mesh tool's preview (half a second at most), not its OK.
func _previews_mesh() -> bool:
	return _is_mesh_tool(command) and not _accepting_mesh


## True when view clicks select face groups or triangles: the Mesh workspace, no sketch or form.
func _selects_mesh() -> bool:
	return workspace == MESH_WORKSPACE and doc != null and not sketch_editor.active and not form_editor.active


## True when a Mesh tool's slot takes a picked reference: a body reference goes into a slot for
## bodies ("mesh_body" for a mesh body, "body" for another), anything else as the slot's kinds say.
func _mesh_slot_takes(field: Dictionary, ref: Dictionary) -> bool:
	var kinds: Array = field.get("filter", []) if field.get("filter") is Array else []
	var on_mesh := MESH_BODY.is_mesh(result.get("bodies", {}).get(ref.get("body", ""), {}))
	match str(ref.get("kind", "")):
		"body":
			if not (kinds.has("mesh_body") if on_mesh else kinds.has("body")):
				_flash((MESH_BODY.ALREADY_MESH if on_mesh else command.NOT_A_MESH) % doc.body_name(str(ref.body)))
				return false
			return true
		"mesh_group":
			return kinds.has("mesh_group")
		"mesh_triangles":
			return kinds.has("mesh_triangles")
	return true


## Tells a Mesh tool's command of every field the user types in: a typed value is theirs, also
## one typed the same as the value the panel had chosen, and never follows the picked body again.
## (The panel's own handler runs first, so the typed text is already applied.)
func _watch_typing() -> void:
	if not _is_mesh_tool(command):
		return
	var editors: Variant = panel.get("_editors")
	if not (editors is Dictionary):
		return
	var typing: RefCounted = command
	for field in command.fields():
		# (A field that may stay empty says what empty means.)
		if bool(field.get("optional", false)) and (editors as Dictionary).get(field.key) is LineEdit:
			((editors as Dictionary)[field.key] as LineEdit).placeholder_text = "auto"
	for key in editors:
		var editor: Variant = editors[key]
		if editor is LineEdit:
			var field_key := str(key)
			(editor as LineEdit).text_changed.connect(func(_text: String) -> void: _typed_in(typing, field_key))


func _typed_in(typing: RefCounted, key: String) -> void:
	if command != typing:
		return
	var was_untouched: bool = command.is_untouched(key, command_values)
	command.mark_typed(key)
	if was_untouched:
		# (Typed the same as the panel's own value: written now as the user's.)
		command.write_values(doc, command_values)
		_queue_recompute()


## Puts the values a Mesh tool's command gave its fields into the panel (command_values against
## before): a field that follows the picked body shows its new value even while it has the
## keyboard (it was not typed in: a typed value is never changed).
func _show_adjusted(before: Dictionary) -> void:
	var changed := []
	for key in command_values:
		if str(command_values[key]) != str(before.get(key)):
			changed.append(key)
	panel.set_values(command_values, changed)


func _on_workspace_changed() -> void:
	if workspace != MESH_WORKSPACE:
		if mesh_direct_edit.active:
			mesh_direct_edit.done()
		if not mesh_selection.is_empty():
			mesh_selection.clear()
	viewport.filters["mesh_triangle"] = workspace == MESH_WORKSPACE and mesh_selection.mode == MESH_SELECTION.TRIANGLES
	if doc != null and viewport.mesh_wire != (workspace == MESH_WORKSPACE and mesh_selection.mode == MESH_SELECTION.TRIANGLES):
		refresh_bodies()
	_sync_mesh_tools.call_deferred()


func _on_mesh_selection_changed() -> void:
	if mesh_direct_edit != null and mesh_direct_edit.active:
		mesh_direct_edit.on_selection_changed()
	if doc == null:
		return
	_update_highlights()
	_update_status()


## Mesh > Select: the two pick modes and the helpers that change the selection.
func run_mesh_select(action: String) -> void:
	var shapes := mesh_shapes()
	if workspace != MESH_WORKSPACE:
		_flash("Switch to the Mesh workspace to select face groups and triangles.")
		return
	if shapes.is_empty():
		_flash(NO_MESH_BODY)
		return
	match action:
		"mesh_pick_groups", "mesh_pick_triangles":
			if mesh_direct_edit.active and action == "mesh_pick_groups":
				_flash("Direct Edit works on triangles.")
				return
			mesh_selection.set_mode(MESH_SELECTION.GROUPS if action == "mesh_pick_groups" else MESH_SELECTION.TRIANGLES, shapes)
			viewport.filters["mesh_triangle"] = mesh_selection.mode == MESH_SELECTION.TRIANGLES
			# What was under the cursor in the other mode (a triangle, or a whole group) is forgotten.
			hover = {}
			_mesh_hover = {}
			_update_highlights()
			if viewport.mesh_wire != (mesh_selection.mode == MESH_SELECTION.TRIANGLES):
				if mesh_direct_edit.active:
					mesh_direct_edit.refresh()
				else:
					refresh_bodies()
			_sync_mesh_tools()
			_flash("A click now picks a whole face group." if mesh_selection.mode == MESH_SELECTION.GROUPS else "A click now picks one triangle.")
			return
	if mesh_selection.is_empty() and action != "mesh_boundary":
		_flash("Select face groups or triangles first.")
		return
	var before: int = mesh_selection.count()
	match action:
		"mesh_grow":
			mesh_selection.grow(shapes)
		"mesh_shrink":
			mesh_selection.shrink(shapes)
		"mesh_connected":
			# Held with Shift the tool takes the whole connected piece, whatever its edges turn by.
			var whole := Input.is_key_pressed(KEY_SHIFT)
			mesh_selection.connected(shapes, MESH_SELECTION.WHOLE_ANGLE if whole else MESH_SELECTION.CONNECTED_ANGLE)
		"mesh_boundary":
			if mesh_selection.boundary(shapes) == 0:
				_flash("No open edge touches the selection." if before > 0 else "The mesh bodies have no open edges.")
				return
	_flash("%s selected (%s before)." % [counted(mesh_selection.count(), "triangle"), command_count(before)])


## A count with its noun, singular for 1 ("1 triangle", "20,480 triangles"; many: an irregular
## plural).
static func counted(value: int, one: String, many := "") -> String:
	return "%s %s" % [command_count(value), one if absi(value) == 1 else (many if many != "" else one + "s")]


## A count with thousands separators ("20,480").
static func command_count(value: int) -> String:
	var digits := str(absi(value))
	var out := ""
	while digits.length() > 3:
		out = "," + digits.substr(digits.length() - 3) + out
		digits = digits.substr(0, digits.length() - 3)
	return digits + out


## Display Mesh Face Groups: each face group of every mesh body in a colour of its own, or back
## to the plain mesh colour. A view setting: nothing is rebuilt and nothing can be undone.
func toggle_mesh_face_groups() -> void:
	if doc == null:
		return
	mesh_face_groups = not mesh_face_groups
	if mesh_direct_edit.active:
		mesh_direct_edit.refresh()
	else:
		refresh_bodies()
	if mesh_shapes().is_empty():
		_flash("Face group colours are %s. %s" % ["on" if mesh_face_groups else "off", NO_MESH_BODY])
	else:
		_flash("Face group colours are %s." % ("on" if mesh_face_groups else "off"))


## Direct Edit: opens the tool on the selected mesh body (the one with selected triangles, the
## selected body, or the only mesh body there is).
func start_direct_edit() -> void:
	if doc == null:
		return
	if mesh_direct_edit.active:
		_flash("Direct Edit is open: Done keeps its steps, Cancel drops them.")
		return
	var shapes := mesh_shapes()
	var body_id := ""
	for id in mesh_selection.bodies():
		body_id = id
		break
	if body_id == "":
		for id in _selected_bodies():
			if shapes.has(id):
				body_id = id
				break
	if body_id == "" and shapes.size() == 1:
		body_id = shapes.keys()[0]
	if body_id == "":
		_flash(NO_MESH_BODY if shapes.is_empty() else "Select the mesh body to edit, then start Direct Edit.")
		return
	if command != null:
		cancel_command()
	if sketch_editor.active:
		sketch_editor.end()
	if form_editor.active:
		form_editor.end()
	if workspace != MESH_WORKSPACE:
		toolbar.set_workspace(MESH_WORKSPACE)
		workspace = MESH_WORKSPACE
	selection.clear()
	var why: String = mesh_direct_edit.begin(body_id)
	if why != "":
		_flash(why)
		return
	_on_workspace_changed()
	_selection_changed(false)
	_flash("Direct Edit: select triangles, then Delete, Fill Holes, Flip, Extract or Move. Done keeps the edit.")


## Delete with triangles selected in the Mesh workspace: they leave their bodies, kept as one
## snapshot feature per body (one undo step "Forge: Mesh: Delete Triangles").
func delete_mesh_triangles() -> void:
	var shapes := mesh_shapes()
	var edits := []
	for body_id in mesh_selection.bodies():
		var shape: RefCounted = shapes.get(body_id)
		var triangles: PackedInt32Array = mesh_selection.triangles_of(body_id)
		if shape == null or triangles.is_empty():
			continue
		if triangles.size() >= int(shape.triangle_count()):
			_flash("Every triangle of %s is selected. Select the body to delete it whole." % doc.body_name(body_id))
			return
		if not shape.has_method("delete_triangles"):
			_flash("Deleting triangles needs the mesh kernel's delete, which this build does not have.")
			return
		var left: RefCounted = shape.delete_triangles(triangles)
		if left == null:
			_flash(str(shape.get_last_error()))
			return
		edits.append([body_id, left, str(shape.digest())])
	if edits.is_empty():
		return
	mesh_selection.clear()
	change(MESH_DIRECT_EDIT.DELETE_UNDO_NAME, func() -> void:
		for edit in edits:
			MESH_DIRECT_EDIT.add_snapshot(doc, edit[0], edit[1], edit[2], PackedStringArray(["delete"])))


## A window or freeform region in the Mesh workspace: the triangles of the shown mesh bodies in
## it join the Mesh selection (Ctrl takes them out). A region dragged to the left (crossing)
## takes triangles that reach into it, else only those wholly inside. Without Select Through,
## triangles facing away are left out, and (up to REGION_HIDDEN_CHECKS) those another part of the
## body hides.
func _select_mesh_region(region: Dictionary) -> void:
	if region.is_empty():
		return
	var planes: Array = viewport.region_planes(region.rect)
	if planes.is_empty():
		return
	var shapes := mesh_shapes()
	var eye: Vector3 = viewport.camera_position()
	var forward: Vector3 = -viewport.camera_basis().z
	for body_id in shapes:
		var settings: Dictionary = doc.body_settings(body_id)
		if not doc.body_visible(body_id) or bool(settings.get("locked", false)):
			continue
		var shape: RefCounted = shapes[body_id]
		var crossing := bool(region.crossing)
		var found: PackedInt32Array = shape.triangles_in_frustum(planes, "crossing" if crossing or bool(region.freeform) else "inside")
		if found.is_empty():
			continue
		var tess: Dictionary = mesh_direct_edit.tessellation() if mesh_direct_edit.active and body_id == mesh_direct_edit.body_id else tessellations.get(body_id, {})
		var positions: PackedVector3Array = tess.get("positions", PackedVector3Array())
		var indices: PackedInt32Array = tess.get("indices", PackedInt32Array())
		var outline: PackedVector2Array = region.get("outline", PackedVector2Array())
		var check_hidden: bool = not viewport.select_through and found.size() <= REGION_HIDDEN_CHECKS
		if bool(region.freeform) or not viewport.select_through:
			var kept := PackedInt32Array()
			var reach := (shape.bbox() as AABB).size.length() * 0.002 + 1e-6
			for t in found:
				if t * 3 + 2 >= indices.size():
					continue
				var a := positions[indices[t * 3]]
				var b := positions[indices[t * 3 + 1]]
				var c := positions[indices[t * 3 + 2]]
				var middle := (a + b + c) / 3.0
				if bool(region.freeform):
					# The lasso: corners inside its outline (all three, or any when crossing).
					var inside := 0
					for corner in [a, b, c]:
						var at: Vector2 = viewport.project(corner)
						if at.is_finite() and Geometry2D.is_point_in_polygon(at, outline):
							inside += 1
					if inside == 0 or (not crossing and inside < 3):
						continue
				if not viewport.select_through:
					# Godot's front faces wind clockwise: (c - a) x (b - a) points out of the body.
					var normal := (c - a).cross(b - a)
					var toward: Vector3 = -forward if viewport.ortho else eye - middle
					if normal.dot(toward) <= 0.0:
						continue
					if check_hidden:
						var from: Vector3 = middle - forward * (middle - eye).dot(forward) if viewport.ortho else eye
						var away := from.distance_to(middle)
						var hit: Dictionary = shape.ray_hit(from, (middle - from).normalized(), away)
						if bool(hit.get("hit", false)) and float(hit.distance) < away - reach and int(hit.triangle) != t:
							continue
				kept.append(t)
			found = kept
		if bool(region.get("ctrl", false)):
			mesh_selection.remove(body_id, found, shape)
		else:
			mesh_selection.add(body_id, found, shape)


## Gives the browser's mesh bodies their own icon and a tooltip with their triangle and face
## group counts.
func _mark_mesh_bodies() -> void:
	if doc == null:
		return
	var icon: Texture2D = null
	if Engine.is_editor_hint():
		var editor_theme := EditorInterface.get_editor_theme()
		if editor_theme != null and editor_theme.has_icon("ArrayMesh", "EditorIcons"):
			icon = editor_theme.get_icon("ArrayMesh", "EditorIcons")
	var shapes := mesh_shapes()
	for body_id in shapes:
		var item: TreeItem = browser.body_item(body_id)
		if item == null:
			continue
		if icon != null:
			item.set_icon(0, icon)
		item.set_tooltip_text(0, mesh_body_tip(body_id, shapes[body_id]))
		item.set_meta("holo_forge_mesh_body", true)


## A mesh body's browser tooltip: where it is, and its size.
func mesh_body_tip(body_id: String, shape: RefCounted) -> String:
	var component: String = doc.body_component(body_id)
	var groups := int(shape.face_count())
	return "Mesh body in %s\n%s, %s%s" % [
		doc.component_name(component) if component != "" else "the top level",
		counted(int(shape.triangle_count()), "triangle"), counted(groups, "face group"),
		"\nOpen (not a closed volume)" if bool(shape.is_surface()) else ""]


## Rebuilds the browser, then marks its mesh bodies.
func _refresh_browser() -> void:
	browser.refresh(doc, _browser_bodies(), _selected_bodies(), _surface_bodies(), assembly_solve)
	_mark_mesh_bodies()


## Keeps the Mesh > Select tools in step with the workspace: the pick mode in use shows as pressed
## on the bar and ticked in the menu, and the six tools are greyed while there is no mesh body.
func _sync_mesh_tools() -> void:
	if toolbar == null or workspace != MESH_WORKSPACE:
		return
	var has_mesh := not mesh_shapes().is_empty()
	var pressed := {"mesh_pick_groups": mesh_selection.mode == MESH_SELECTION.GROUPS, "mesh_pick_triangles": mesh_selection.mode == MESH_SELECTION.TRIANGLES}
	for button in toolbar.icon_buttons("Select"):
		var tool := CATALOG.find(str(button.get_meta("tool_id", "")))
		var action := str(tool.get("action", ""))
		if not MESH_SELECT_ACTIONS.has(action):
			continue
		button.disabled = not has_mesh
		if pressed.has(action):
			button.toggle_mode = true
			button.set_pressed_no_signal(pressed[action] and has_mesh)
	var menu: MenuButton = toolbar.group_menu("Select")
	if menu == null:
		return
	var popup := menu.get_popup()
	if not popup.about_to_popup.is_connected(_sync_mesh_tools):
		popup.about_to_popup.connect(_sync_mesh_tools)
	for i in popup.item_count:
		var meta: Variant = popup.get_item_metadata(i)
		var action := str(meta.get("action", "")) if meta is Dictionary else ""
		if not MESH_SELECT_ACTIONS.has(action):
			continue
		popup.set_item_disabled(i, not has_mesh)
		popup.set_item_tooltip(i, "" if has_mesh else NO_MESH_BODY)
		if pressed.has(action):
			popup.set_item_as_radio_checkable(i, true)
			popup.set_item_checked(i, pressed[action])


## What the view's and the browser's menus offer for a body: a mesh body can be converted,
## reduced or have its holes closed; in the Mesh workspace another body can be tessellated. Each
## entry {"label", "action"} starts the tool with the body picked.
func mesh_body_entries(body_id: String) -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	var found: Dictionary = result.get("bodies", {}).get(body_id, {})
	if found.is_empty() or doc == null or sketch_editor.active or form_editor.active:
		return entries
	if MESH_BODY.is_mesh(found):
		for spec in [["Convert Mesh...", "Convert Mesh: Faceted"], ["Reduce...", "Reduce"], ["Close Holes...", "Close Holes"]]:
			var name: String = spec[1]
			entries.append({"label": spec[0], "action": func() -> void: run_tool_on_body(name, body_id)})
	elif workspace == MESH_WORKSPACE:
		entries.append({"label": "Tessellate...", "action": func() -> void: run_tool_on_body("Tessellate", body_id)})
	return entries


## Starts a Mesh workspace tool by name with one body selected, so its panel opens on that body.
func run_tool_on_body(tool_name: String, body_id: String) -> void:
	var tool := {}
	for candidate in CATALOG.tools_in(MESH_WORKSPACE, "Create") + CATALOG.tools_in(MESH_WORKSPACE, "Prepare") + CATALOG.tools_in(MESH_WORKSPACE, "Modify"):
		if candidate.name == tool_name:
			tool = candidate
	if tool.is_empty() or not result.get("bodies", {}).has(body_id):
		return
	if mesh_direct_edit.active:
		mesh_direct_edit.done()
	selection = [{"kind": "body", "body": body_id, "index": -1, "point": Vector3.ZERO}]
	mesh_selection.clear()
	run_tool(tool)


## The browser's own right-click menu gets the mesh entries for the body it was opened on.
func _hook_browser_menu() -> void:
	var menu: Variant = browser.get("_context")
	if not (menu is PopupMenu):
		return
	(menu as PopupMenu).about_to_popup.connect(func() -> void:
		var meta: Variant = browser.get("_context_meta")
		if not (meta is Dictionary) or str(meta.get("type", "")) != "body":
			return
		var labels := {"Convert Mesh...": BROWSER_CONVERT, "Reduce...": BROWSER_REDUCE, "Close Holes...": BROWSER_CLOSE_HOLES, "Tessellate...": BROWSER_TESSELLATE}
		var entries := mesh_body_entries(str(meta.get("id", "")))
		if entries.is_empty():
			return
		(menu as PopupMenu).add_separator()
		for entry in entries:
			(menu as PopupMenu).add_item(str(entry.label), int(labels.get(entry.label, BROWSER_CONVERT))))
	(menu as PopupMenu).id_pressed.connect(func(id: int) -> void:
		var meta: Variant = browser.get("_context_meta")
		var names := {BROWSER_CONVERT: "Convert Mesh: Faceted", BROWSER_REDUCE: "Reduce", BROWSER_CLOSE_HOLES: "Close Holes", BROWSER_TESSELLATE: "Tessellate"}
		if names.has(id) and meta is Dictionary:
			run_tool_on_body(names[id], str(meta.get("id", ""))))


## Draws what a Mesh tool picked that no mesh shows: the open-edge loops (Close Holes).
func _draw_mesh_picks(overlay: Control) -> void:
	if not _is_mesh_tool(command):
		return
	var color: Color = theme_colors.get("mesh_fill", Color.ORANGE)
	for ref in _picked_refs():
		if not (ref is Dictionary) or str(ref.get("kind", "")) != "mesh_boundary":
			continue
		var points: PackedVector3Array = command.boundary_points(ref)
		var line := PackedVector2Array()
		for point in points:
			var at: Vector2 = viewport.project(point)
			if at.is_finite():
				line.append(at)
		if line.size() >= 2:
			line.append(line[0])
			overlay.draw_polyline(line, color, 3.5, true)
	# Points picked one by one on a mesh (Mesh Align's three): a numbered dot at each, on the body
	# as it is shown (a preview that moved the body takes the dots along).
	var ink: Color = theme_colors.get("mesh_selected", Color.DODGER_BLUE)
	ink.a = 1.0
	var rim: Color = theme_colors.get("background_bottom", Color.BLACK)
	var font := get_theme_default_font()
	for field in command.fields():
		if field.type != "selection" or not bool(field.get("separate", false)):
			continue
		var number := 0
		for ref in command_values.get(field.key, []):
			number += 1
			var point: Variant = command.shown_point(ref) if ref is Dictionary else null
			if not (point is Vector3):
				continue
			var at: Vector2 = viewport.project(point)
			if not at.is_finite():
				continue
			overlay.draw_circle(at, 7.0, rim)
			overlay.draw_circle(at, 5.0, ink)
			overlay.draw_string_outline(font, at + Vector2(9, -7), str(number), HORIZONTAL_ALIGNMENT_LEFT, -1, 13, 4, rim)
			overlay.draw_string(font, at + Vector2(9, -7), str(number), HORIZONTAL_ALIGNMENT_LEFT, -1, 13, ink)


func _on_select_option(key: String, value: Variant) -> void:
	if key.begins_with("filter:"):
		viewport.filters[key.trim_prefix("filter:")] = value
	elif key == "priority":
		viewport.priority = value
	elif key == "select_through":
		viewport.select_through = value
	elif key == "selection_set" and doc != null:
		selection.clear()
		for item_key in doc.selection_sets.get(value, []):
			var pick := PICKING.from_key(item_key)
			if not pick.is_empty() and result.get("bodies", {}).has(pick.body):
				pick["point"] = Vector3.ZERO
				selection.append(pick)
		_selection_changed(true)


# --- Browser and timeline edits --------------------------------------------------------------

func _change_body(body_id: String, field: String, action_name: String) -> void:
	if not doc.bodies.has(body_id):
		return
	# The edit runs again on a running command's starting state (change()), where a body only the
	# command's preview makes isn't registered.
	change(action_name, func() -> void:
		if doc.bodies.has(body_id):
			var current := bool(doc.bodies[body_id].get(field, field == "visible"))
			doc.bodies[body_id][field] = not current)


func _rename_body(body_id: String, new_name: String) -> void:
	if doc.bodies.has(body_id) and doc.bodies[body_id].get("name", "") != new_name:
		change("Rename Body", func() -> void:
			if doc.bodies.has(body_id):
				doc.bodies[body_id]["name"] = new_name)


## Deletes bodies by removing the features that created them; bodies a feature split off or
## copied (no feature of their own) and faces (refs) go through a Remove feature instead.
func _delete_bodies(bodies: Array, faces := []) -> void:
	var features := {}
	var gone := {}
	for body_id in bodies:
		var feature_id := str((doc.bodies.get(body_id, {}) as Dictionary).get("feature", ""))
		if feature_id != "":
			features[feature_id] = true
			gone[body_id] = true
	var pieces := []
	for body_id in bodies:
		if not gone.has(body_id) and not gone.has(str(body_id).split(".")[0]) and result.get("bodies", {}).has(body_id):
			pieces.append({"kind": "body", "body": body_id})
	if features.is_empty() and pieces.is_empty() and faces.is_empty():
		return
	selection.clear()
	change("Delete Bodies" if faces.is_empty() else "Delete", func() -> void:
		for feature_id in features:
			doc.remove_feature(feature_id)
		if not pieces.is_empty() or not faces.is_empty():
			doc.add_feature("remove", "Delete", {}, {"bodies": pieces.duplicate(true), "faces": faces.duplicate(true)}))


func _hide_selected() -> void:
	var bodies := _selected_bodies()
	change("Hide Bodies", func() -> void:
		for body_id in bodies:
			if doc.bodies.has(body_id):
				doc.bodies[body_id]["visible"] = false)
	selection.clear()
	_selection_changed(true)


func _show_all_bodies() -> void:
	change("Show All Bodies", func() -> void:
		for body_id in doc.bodies:
			doc.bodies[body_id]["visible"] = true)


func _find_body_feature(body_id: String) -> void:
	var feature: Resource = doc.find_feature(str((doc.bodies.get(body_id, {}) as Dictionary).get("feature", "")))
	_flash("%s was created by %s." % [doc.body_name(body_id), feature.label] if feature != null else "No feature found.")


func _find_feature_bodies(feature_id: String) -> void:
	selection.clear()
	for body_id in result.get("bodies", {}):
		if str(result.bodies[body_id].feature) == feature_id or str((doc.bodies.get(body_id, {}) as Dictionary).get("feature", "")) == feature_id:
			selection.append({"kind": "body", "body": body_id, "index": -1, "point": Vector3.ZERO})
	_selection_changed(true)


func _toggle_origin(key: String) -> void:
	change("Show/Hide Origin", func() -> void: doc.origin_visibility[key] = not bool(doc.origin_visibility.get(key, true)))


func _change_units(units: String) -> void:
	if units == doc.units:
		return
	change("Change Units", func() -> void: doc.units = units)
	viewport.unit_scale = float(UNITS.LENGTH_UNITS.get(units, 0.001))
	viewport.snap_step = viewport.unit_scale


func _rename_view(old_name: String, new_name: String) -> void:
	if doc.named_views.has(new_name):
		_flash("A view named %s already exists." % new_name)
		recompute()
		return
	change("Rename Named View", func() -> void:
		doc.named_views[new_name] = doc.named_views[old_name]
		doc.named_views.erase(old_name))


func _delete_view(view_name: String) -> void:
	change("Delete Named View", func() -> void: doc.named_views.erase(view_name))


func _toggle_suppress(feature_id: String) -> void:
	var feature: Resource = doc.find_feature(feature_id)
	if feature != null:
		_set_feature_field(feature_id, "suppressed", not feature.suppressed, ("Unsuppress " if feature.suppressed else "Suppress ") + str(feature.label))


func _rename_feature(feature_id: String) -> void:
	var feature: Resource = doc.find_feature(feature_id)
	if feature == null:
		return
	ask("Rename Feature", feature.label, func(text: String) -> void:
		if text != "":
			_set_feature_field(feature_id, "label", text, "Rename Feature"))


func _group_feature(feature_id: String) -> void:
	var feature: Resource = doc.find_feature(feature_id)
	if feature == null:
		return
	ask("Group Name", feature.group if feature.group != "" else "Group1", func(text: String) -> void:
		_set_feature_field(feature_id, "group", text, "Move to Group"))


func _set_feature_field(feature_id: String, field: String, value: Variant, action_name: String) -> void:
	change(action_name, func() -> void:
		var feature: Resource = doc.find_feature(feature_id)
		if feature != null:
			feature.set(field, value))


# --- Parameters ------------------------------------------------------------------------------

func _add_user_parameter() -> void:
	var n: int = doc.user_parameters.size() + 1
	var param_name := "param%d" % n
	while not PARAMETERS.is_valid_name(doc, param_name):
		n += 1
		param_name = "param%d" % n
	change("Add Parameter", func() -> void:
		doc.user_parameters.append({"name": param_name, "unit": doc.units, "expression": "10", "comment": "", "favorite": false}))
	parameters_dialog.refresh(doc, result.values)


func _remove_user_parameter(index: int) -> void:
	change("Delete Parameter", func() -> void: doc.user_parameters.remove_at(index))
	parameters_dialog.refresh(doc, result.values)


func _change_user_parameter(index: int, field: String, value: Variant) -> void:
	if index < 0 or index >= doc.user_parameters.size():
		return
	var current: Dictionary = doc.user_parameters[index]
	if field == "name":
		var old_name := str(current.get("name", ""))
		if not PARAMETERS.is_valid_name(doc, str(value), old_name):
			_flash("'%s' can't be used as a parameter name." % value)
			parameters_dialog.refresh(doc, result.values)
			return
	change("Change Parameter", func() -> void: doc.user_parameters[index][field] = value)
	parameters_dialog.refresh(doc, result.values)


func _change_model_expression(feature_id: String, key: String, expression: String) -> void:
	change("Change Parameter", func() -> void:
		var feature: Resource = doc.find_feature(feature_id)
		if feature != null:
			feature.set_expression(key, expression))
	parameters_dialog.refresh(doc, result.values)


# --- Dark and light mode ---------------------------------------------------------------------

## Picks the look: "dark", "light" or "editor" (follow the editor's theme). Saved (see
## theme_store) and shown at once.
func set_theme_mode(mode: String) -> void:
	if not FORGE_THEME.MODES.has(mode):
		return
	theme_mode = mode
	FORGE_THEME.write_mode(_theme_store(), mode)
	apply_theme()


## Draws the Forge tab in the palette theme_mode stands for: the view, the sketch overlay and
## palette, the panels and menus over the view, the toolbar's icons and labels, and, where the
## editor's theme isn't as dark as the palette, the tab's own buttons, lists and menus. Only
## colours change: the document isn't rebuilt and the baked bodies keep their materials.
func apply_theme() -> void:
	theme_apply_count += 1
	theme_name = FORGE_THEME.resolve(theme_mode, theme_host_base)
	theme_colors = FORGE_THEME.palette(theme_name)
	var c := theme_colors
	viewport.apply_theme(c)
	sketch_editor.apply_theme(c)
	form_editor.apply_theme(c)
	mesh_direct_edit.apply_theme(c)
	marking_menu.apply_theme(c)
	toolbar.set_ink_color(c.toolbar_ink)
	toolbar.set_theme_state(theme_mode, bool(c.dark))
	var controls := FORGE_THEME.control_theme(theme_name, theme_host_base, EditorInterface.get_editor_scale() if Engine.is_editor_hint() else 1.0)
	for part: Control in [toolbar, viewport.get_parent(), timeline]:
		part.theme = controls
	# The tab's own dialogs are windows of their own: they take the same controls.
	for window: Window in [parameters_dialog, _prompt]:
		window.theme = controls
	_chrome_color = c.chrome if controls != null else Color(0, 0, 0, 0)
	queue_redraw()
	var tint := FORGE_THEME.icon_tint(theme_name, theme_host_base)
	browser.set_assembly_colors(c)
	browser.set_icon_tint(tint)
	if assembly_display != null:
		assembly_display.apply_theme(viewport, c)
	timeline.apply_theme(c, tint)
	# The command and appearance panels keep their own frames; only their colours change.
	for over: Control in [panel, appearance_panel]:
		var frame := over.get_theme_stylebox("panel") as StyleBoxFlat
		if frame != null:
			frame = frame.duplicate()
			frame.bg_color = c.command_back
			frame.border_color = c.command_border
			over.add_theme_stylebox_override("panel", frame)
	_color_status()
	_analysis_label.add_theme_color_override("font_color", c.status_text)
	for label in _placeholder.find_children("*", "Label", true, false):
		(label as Label).add_theme_color_override("font_color", c.status_text)


## The editor's theme changed: shows the palette again if what it stands for changed.
func _refresh_theme() -> void:
	_theme_queued = false
	var wanted := FORGE_THEME.resolve(theme_mode, theme_host_base)
	var controls := FORGE_THEME.control_theme(wanted, theme_host_base, EditorInterface.get_editor_scale() if Engine.is_editor_hint() else 1.0)
	if wanted != theme_name or controls != timeline.theme:
		apply_theme()


func _theme_store() -> Variant:
	return theme_store if theme_store != null else FORGE_THEME.default_store()


# --- Passthrough -----------------------------------------------------------------------------

## Display > Passthrough: turns it on or off (saved, see passthrough_store) and shows the part in
## its scene now if it can; if it can't, says why.
func set_passthrough(on: bool) -> void:
	passthrough = on
	var store: Variant = _passthrough_store()
	if store is Dictionary:
		(store as Dictionary)[PASSTHROUGH_KEY] = on
	elif store is Object and is_instance_valid(store):
		if store.has_method("set_project_metadata"):
			store.set_project_metadata(FORGE_THEME.SECTION, PASSTHROUGH_KEY, on)
		elif store.has_method("set_value"):
			store.set_value(FORGE_THEME.SECTION, PASSTHROUGH_KEY, on)
	_passthrough_scale_noted = false
	sync_passthrough()
	var blocker := passthrough_blocker()
	if on and blocker != "":
		_flash(blocker)


## Why Passthrough can't show the part now ("" when it can): it needs a part inside an open 3D scene.
func passthrough_blocker() -> String:
	if part == null or not is_instance_valid(part) or not part.is_inside_tree():
		return S_PASSTHROUGH_NO_PART
	var root := _passthrough_root()
	if not (root is Node3D) or not root.is_inside_tree() or (root != part and not root.is_ancestor_of(part)):
		return S_PASSTHROUGH_NO_SCENE
	if (root as Node3D).get_world_3d() == null:
		return S_PASSTHROUGH_NO_SCENE
	return ""


## Shows the part in its scene when Passthrough is on, the tab is shown and the part is in an open
## 3D scene; otherwise the view's own world. Called whenever one of those may have changed.
## moved_only: only the part moved, so the scene's lights are as they were (not looked for again).
func sync_passthrough(moved_only := false) -> void:
	if viewport == null:
		return
	var blocker := passthrough_blocker()
	if passthrough and blocker == "" and is_visible_in_tree():
		var root := _passthrough_root() as Node3D
		var world := root.get_world_3d()
		var was_on: bool = viewport.passthrough_on()
		if not (moved_only and was_on):
			_passthrough_lit = _scene_lit(world)
		viewport.set_passthrough(world, part.global_transform, _passthrough_hidden(), _passthrough_lit)
		_passthrough_transform = part.global_transform
		if not was_on:
			var tree := part.get_tree()
			if not tree.node_added.is_connected(_on_passthrough_node_added):
				tree.node_added.connect(_on_passthrough_node_added)
		var scale: Vector3 = part.global_transform.basis.get_scale()
		if not _passthrough_scale_noted and not scale.is_equal_approx(Vector3.ONE):
			_passthrough_scale_noted = true
			_flash(S_PASSTHROUGH_SCALE % [String.num(scale.x, 3), String.num(scale.y, 3), String.num(scale.z, 3)])
	else:
		end_passthrough()
	viewport.set_passthrough_menu(passthrough, blocker)


## Back to the view's own world (Passthrough stays on, to show again when it can).
func end_passthrough() -> void:
	if viewport != null:
		viewport.clear_passthrough()
	var tree := get_tree() if is_inside_tree() else null
	if tree != null and tree.node_added.is_connected(_on_passthrough_node_added):
		tree.node_added.disconnect(_on_passthrough_node_added)


## The part's own drawn nodes in the scene: the view's bodies show in their place.
func _passthrough_hidden() -> Array:
	return part.find_children("*", "VisualInstance3D", true, false)


## Whether the scene world has a light of its own (or the editor's preview sun) outside the view.
func _scene_lit(world: World3D) -> bool:
	for light in get_tree().root.find_children("*", "Light3D", true, false):
		if viewport.is_ancestor_of(light) or not (light as Light3D).is_visible_in_tree():
			continue
		if (light as Light3D).get_world_3d() == world:
			return true
	return false


func _passthrough_root() -> Node:
	if passthrough_scene_root != null:
		return passthrough_scene_root if is_instance_valid(passthrough_scene_root) else null
	if Engine.is_editor_hint():
		return EditorInterface.get_edited_scene_root()
	return null


func _passthrough_store() -> Variant:
	return passthrough_store if passthrough_store != null else FORGE_THEME.default_store()


func _read_passthrough() -> bool:
	var store: Variant = _passthrough_store()
	var saved: Variant = false
	if store is Dictionary:
		saved = (store as Dictionary).get(PASSTHROUGH_KEY, false)
	elif store is Object and is_instance_valid(store):
		if store.has_method("get_project_metadata"):
			saved = store.get_project_metadata(FORGE_THEME.SECTION, PASSTHROUGH_KEY, false)
		elif store.has_method("get_value"):
			saved = store.get_value(FORGE_THEME.SECTION, PASSTHROUGH_KEY, false)
	return saved is bool and saved


## A node came into the tree while Passthrough is on: if it is one of the part's (a body baked
## again), it is hidden once it is in place.
func _on_passthrough_node_added(node: Node) -> void:
	if _passthrough_hide_queued or not (node is VisualInstance3D) or part == null or not is_instance_valid(part) or not part.is_ancestor_of(node):
		return
	_passthrough_hide_queued = true
	_rehide_passthrough.call_deferred()


func _rehide_passthrough() -> void:
	_passthrough_hide_queued = false
	if viewport != null and viewport.passthrough_on() and part != null and is_instance_valid(part) and part.is_inside_tree():
		viewport.set_passthrough_hidden(_passthrough_hidden())


## The part was moved (the Inspector stays open beside the Forge tab): the view follows it.
func _follow_passthrough_part() -> void:
	if viewport == null or not viewport.passthrough_on():
		return
	if part == null or not is_instance_valid(part) or not part.is_inside_tree():
		sync_passthrough()
		return
	if not part.global_transform.is_equal_approx(_passthrough_transform):
		sync_passthrough(true)


func _color_status() -> void:
	if theme_colors.is_empty():
		return
	var key: String = {"info": "info_text", "error": "error_text"}.get(_status_kind, "status_text")
	_status.add_theme_color_override("font_color", theme_colors[key])


# --- Status ----------------------------------------------------------------------------------

func _flash(text: String) -> void:
	last_message = text
	message_shown.emit(text)
	_status.text = text
	_fit_status()
	_status_kind = "info"
	_color_status()
	_status_timer.start(3.0)


func flash(text: String) -> void:
	_flash(text)


## Gives the status line the view's width, less the room the view cube takes on the right, and
## the height its wrapped text needs (a label outside a container draws only the lines that fit).
func _fit_status() -> void:
	if _status == null or viewport == null:
		return
	var width := maxf(viewport.size.x - STATUS_RIGHT_MARGIN - _status.position.x, 160.0)
	if not is_equal_approx(_status.custom_minimum_size.x, width):
		_status.custom_minimum_size.x = width
	_status.reset_size()


func place_panel() -> void:
	_place_panel()


func nice_size(meters: float) -> float:
	return _nice_size(meters)


func _update_status() -> void:
	if not _status_timer.is_stopped():
		return
	var lines := PackedStringArray()
	if kernel == null:
		lines.append("⚠ The Holo Forge kernel is not loaded (addons/holo_forge/bin).")
	for feature_id in result.get("errors", {}):
		var feature: Resource = doc.find_feature(feature_id) if doc != null else null
		if _is_mesh_tool(command) and command.feature != null and str(feature_id) == str(command.feature.id) and last_mesh_limit < MESH_FEATURE.OK_SECONDS and command.is_time_refusal(str(result.errors[feature_id])):
			# The open Mesh tool's preview was skipped for time: its stat row says so, and it is
			# no error (and no advice to change a value) until OK has tried with the full time.
			continue
		lines.append("⚠ %s: %s" % [feature.label if feature != null else feature_id, result.errors[feature_id]])
	for note in appearance_notes:
		lines.append(note)
	var waiting := _waiting_features() if doc != null else {}
	if not waiting.is_empty():
		var left_out: int = (waiting.ids as Array).size()
		if str(waiting.get("stopped", "")) != "":
			lines.append(str(waiting.stopped))
		else:
			lines.append("Preview of %s: the bodies show as it leaves them. The %s after it %s worked out again on OK or Cancel." % [waiting.label, counted(left_out, "feature"), "is" if left_out == 1 else "are"])
	if form_editor != null and form_editor.active and not form_editor.selection.is_empty():
		lines.append("%d cage element%s selected" % [form_editor.selection.size(), "" if form_editor.selection.size() == 1 else "s"])
	elif mesh_selection != null and not mesh_selection.is_empty():
		var triangles: int = mesh_selection.count()
		var text := "%s triangle%s selected" % [command_count(triangles), "" if triangles == 1 else "s"]
		if mesh_selection.mode == MESH_SELECTION.GROUPS:
			var groups := 0
			var shapes := mesh_shapes()
			for body_id in mesh_selection.bodies():
				groups += mesh_selection.groups_of(body_id, shapes.get(body_id)).size()
			text = "%s selected (%s)" % [counted(groups, "face group"), counted(triangles, "triangle")]
		lines.append(text + (", %d more" % selection.size() if not selection.is_empty() else ""))
	elif not selection.is_empty():
		lines.append("%d selected" % selection.size())
	# (Only when the assembly moves something: otherwise both views are the same.)
	if modelled_view() and viewport.has_poses():
		lines.append(ASSEMBLY_DATA.S_MODELLED_VIEW)
	_status.text = "\n".join(lines)
	_fit_status()
	_status_kind = "error" if lines.size() > 0 and lines[0].begins_with("⚠") else "status"
	_color_status()


## Rounds a length to 1, 2 or 5 times a power of ten (for default sizes).
static func _nice_size(meters: float) -> float:
	var exponent := floorf(log(maxf(meters, 1e-6)) / log(10.0))
	var base := pow(10.0, exponent)
	var mantissa := meters / base
	var nice := 1.0 if mantissa < 1.5 else (2.0 if mantissa < 3.5 else (5.0 if mantissa < 7.5 else 10.0))
	return nice * base
