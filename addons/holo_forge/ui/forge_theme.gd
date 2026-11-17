@tool
extends RefCounted
## The Forge tab's appearance: a "dark" and a "light" palette holding every colour the tab draws
## (the 3D view, the sketch overlay, the view cube, the navigation bar, messages, the floating
## panels, the toolbar's ink), and the mode the user picked: "dark", "light" or "editor" (follow
## the editor: dark when its base colour is dark). The mode is kept in the editor's project
## metadata (holo_forge/theme), in memory outside the editor.
##
## Where the Forge palette is as dark as the editor's own theme the tab's buttons, lists and menus
## keep the editor's look; where it isn't, control_theme() gives them one in the palette's colours.
## The theme is the Forge view's only: baked meshes and their materials never change with it.

const SECTION := "holo_forge"
const KEY := "theme"
const MODES := ["dark", "light", "editor"]
const MODE_LABELS := {"dark": "Dark", "light": "Light", "editor": "Follow Editor"}
const DEFAULT_MODE := "editor"
## The base colour of Godot's own (dark) theme, for the "editor" mode outside the editor.
const DEFAULT_HOST_BASE := Color(0.21, 0.24, 0.29)
## A face turned to the camera shows LIT_GAIN times its linear colour plus LIT_SPECULAR (the head
## light's highlight), measured from renders of two body colours (see lit()).
const LIT_GAIN := 1.94
const LIT_SPECULAR := 0.092

const DARK := {
	"dark": true,
	# The view: a charcoal gradient fixed to the screen, a faint grid, light edges.
	"view_top": Color("#454a53"), "view_bottom": Color("#1d2025"),
	"grid_minor": Color(0.85, 0.9, 1.0, 0.05), "grid_major": Color(0.85, 0.9, 1.0, 0.13),
	"axis_x": Color(1.0, 0.4, 0.4), "axis_y": Color(0.45, 0.85, 0.48), "axis_z": Color(0.42, 0.62, 1.0),
	"plane_alpha": 0.1, "origin_point": Color(0.78, 0.81, 0.87),
	"body": Color(0.4, 0.42, 0.47), "edge": Color(0.88, 0.91, 0.96), "hidden_edge": Color(0.88, 0.91, 0.96, 0.24),
	# While a sketch is open the bodies fade to this share of their colour (lit faces would be as
	# bright as the sketch lines); a section shows its inside in section_inside.
	"sketch_dim": 0.35, "section_inside": Color(0.2, 0.21, 0.24),
	"surface_front": Color(0.86, 0.69, 0.4), "surface_back": Color(0.52, 0.44, 0.7),
	"select_face": Color(0.12, 0.45, 1.0, 0.6), "hover_face": Color(0.6, 0.8, 1.0, 0.18),
	"select_line": Color(0.36, 0.72, 1.0), "hover_line": Color(0.58, 0.84, 1.0),
	"window_box": Color(0.36, 0.72, 1.0), "crossing_box": Color(0.38, 0.86, 0.5),
	"handle": Color(0.36, 0.72, 1.0), "handle_fill": Color(0.96, 0.97, 1.0),
	"analysis_text": Color(0.92, 0.94, 0.97), "analysis_ring": Color(0.96, 0.97, 1.0),
	"status_text": Color(0.86, 0.88, 0.92), "info_text": Color(0.56, 0.78, 1.0), "error_text": Color(1.0, 0.64, 0.58),
	# Sketches.
	"sketch_free": Color(0.55, 0.78, 1.0), "sketch_defined": Color(0.93, 0.95, 0.98),
	# Drawn under every sketch curve, a little wider, so it reads on any face.
	"sketch_halo": Color(0.04, 0.05, 0.07, 0.72),
	"sketch_construction": Color(1.0, 0.67, 0.22), "sketch_centerline": Color(0.72, 0.76, 0.84),
	"sketch_projected": Color(0.8, 0.6, 1.0), "sketch_conflict": Color(1.0, 0.55, 0.5),
	"sketch_select": Color(0.42, 0.88, 1.0), "sketch_point": Color(0.93, 0.95, 0.98), "sketch_origin": Color(0.8, 0.6, 1.0),
	"sketch_inactive": Color(0.74, 0.78, 0.86, 0.6), "sketch_grid_minor": Color(0.78, 0.84, 0.94, 0.06),
	"sketch_grid_major": Color(0.78, 0.84, 0.94, 0.16),
	# Sketch dimensions: lines, extension lines, arrows and arcs in dim_line, values in dim_text, the
	# placing preview, hover, selection and errors; the hover tip and the value box over them.
	# dim_halo is drawn under their lines and around their text, so they read on a body's face and
	# other dimensions' lines don't run through their digits.
	"dim_line": Color("#b7d39a"), "dim_text": Color("#d9ecc4"), "dim_preview": Color(0.718, 0.827, 0.604, 0.55),
	"dim_hover": Color("#b8f2ff"), "dim_selected": Color("#6be0ff"), "dim_error": Color("#ff9a90"),
	"dim_halo": Color(0.04, 0.05, 0.07, 0.6),
	"dim_tip_back": Color("#0f1115", 0.94), "dim_tip_text": Color("#f2f4f7"),
	"dim_box_back": Color("#1b1d21"), "dim_box_frame": Color("#3a3d44"), "dim_box_focus": Color("#4b9cff"),
	"dim_box_text": Color("#dfe3ea"), "dim_box_selection": Color(0.30, 0.60, 1.0, 0.40), "dim_box_invalid": Color("#ff7a70"),
	# Readout labels drawn over the view (Measure, Mass Properties, Texture Map).
	"note_text": Color(0.95, 0.96, 0.98), "note_back": Color(0.1, 0.11, 0.14, 0.9),
	"glyph_text": Color(1.0, 0.86, 0.5), "glyph_back": Color(0.17, 0.15, 0.1, 0.92), "glyph_back_selected": Color(0.12, 0.3, 0.52, 0.95),
	"glyph_border": Color(1.0, 0.8, 0.36, 0.5),
	"profile": Color(0.3, 0.6, 1.0, 0.14), "profile_hover": Color(0.36, 0.66, 1.0, 0.3),
	# The Form environment: the smooth surface, Box-mode cage faces, cage lines (and their faint
	# hidden pass), cage points, selection and hover, symmetry partners, creases, open boundaries,
	# symmetry seams and planes, isolated and frozen elements, soft-modification influence, tool
	# previews, and repair errors and warnings.
	"form_surface": Color(0.47, 0.50, 0.56), "form_box_face": Color(0.36, 0.39, 0.45),
	"form_cage_line": Color(0.82, 0.86, 0.93, 0.85), "form_cage_hidden": Color(0.82, 0.86, 0.93, 0.16),
	"form_point": Color(0.92, 0.94, 0.98), "form_select_face": Color(0.12, 0.45, 1.0, 0.55),
	"form_hover_face": Color(0.60, 0.80, 1.0, 0.20), "form_select_line": Color(0.36, 0.72, 1.0),
	"form_hover_line": Color(0.58, 0.84, 1.0), "form_partner": Color(0.36, 0.72, 1.0, 0.45),
	"form_crease": Color("#ff8f40"), "form_boundary": Color("#c9a6ff"), "form_symmetry_line": Color("#3ee0b0"),
	"form_symmetry_plane": Color(0.24, 0.88, 0.69, 0.07), "form_isolated": Color(1.0, 0.35, 0.42, 0.35),
	"form_frozen": Color("#7fd8ff"), "form_frozen_buffer": Color("#3d7fb8"), "form_soft_high": Color("#ff7043"),
	"form_preview": Color("#57e389"), "form_error": Color("#ff4d4d"), "form_warning": Color("#ffd23f"),
	# Mesh bodies (the Mesh workspace): their surface, a faint triangle wire, face group borders, open
	# boundaries, selected and hovered triangles, tool previews (removed parts and fills), warnings,
	# and the eight face group colours (an Array: neighbouring groups take different ones).
	"mesh_surface": Color(0.55, 0.58, 0.63), "mesh_wire": Color(0.85, 0.88, 0.94, 0.25),
	"mesh_group_border": Color("#e6e9ef"), "mesh_boundary": Color("#ff5d8f"),
	"mesh_selected": Color(0.12, 0.45, 1.0, 0.55), "mesh_hover": Color(0.60, 0.80, 1.0, 0.25),
	"mesh_preview": Color("#57e389"), "mesh_removed": Color(1.0, 0.35, 0.42, 0.30),
	"mesh_fill": Color("#ffb347"), "mesh_warning": Color("#ffd23f"),
	"mesh_group_palette": [Color("#7aa2f7"), Color("#9ece6a"), Color("#e0af68"), Color("#bb9af7"),
		Color("#7dcfff"), Color("#f7768e"), Color("#73daca"), Color("#c0caf5")],
	# Assemblies (ui/assembly_display.gd, the browser): joint badges, axes, candidate marks and key
	# diamonds; the selected or hovered one (the selection colour, select_line); limit sectors and
	# bars (assembly_joint at alpha 0.18); loop state (the same amber as mesh_warning); unresolved
	# and error state; the ground glyph and icon tint; a contact stop; the moving unit's start ghost.
	"assembly_joint": Color("#f0a33a"), "assembly_joint_selected": Color(0.36, 0.72, 1.0),
	"assembly_limit": Color("#f0a33a", 0.18), "assembly_warning": Color("#ffd23f"),
	"assembly_unresolved": Color("#ff4d4d"), "assembly_ground": Color("#9aa4b2"),
	"assembly_contact": Color("#ff5d8f"), "assembly_ghost": Color(0.6, 0.8, 1.0, 0.25),
	# The view cube and the navigation bar.
	"cube_face": Color(0.34, 0.36, 0.41), "cube_edge": Color(0.66, 0.7, 0.78), "cube_text": Color(0.93, 0.95, 0.98),
	"cube_hover": Color(0.3, 0.65, 1.0, 0.6),
	"nav_back": Color(0.11, 0.12, 0.15, 0.86), "nav_border": Color(1, 1, 1, 0.08), "nav_text": Color(0.86, 0.88, 0.93),
	"nav_hover": Color(1, 1, 1, 0.09), "nav_pressed": Color(0.25, 0.55, 1.0, 0.38),
	# Panels over the view.
	"panel_style": {
		"panel": Color(0.13, 0.14, 0.17, 0.985), "border": Color(1, 1, 1, 0.1), "shadow": Color(0, 0, 0, 0.22),
		"title": Color(0.18, 0.19, 0.23, 1.0), "title_hover": Color(0.21, 0.22, 0.27, 1.0),
		"title_text": Color(0.8, 0.84, 0.92), "grip": Color(0.85, 0.88, 0.95, 0.55), "accent": Color(0.25, 0.55, 1.0, 0.7),
		# Check boxes on the panel: their box and its fill.
		"check": Color(0.85, 0.88, 0.95, 0.75), "field": Color(0.08, 0.09, 0.11),
	},
	"command_back": Color(0.13, 0.14, 0.17, 0.95), "command_border": Color(0.25, 0.55, 1.0, 0.8),
	"marking_ring": Color(0.3, 0.6, 1.0, 0.3), "marking_center": Color(0.1, 0.11, 0.14, 0.75),
	"marking_back": Color(0.14, 0.15, 0.18, 0.96), "marking_border": Color(1, 1, 1, 0.1),
	"marking_text": Color(0.88, 0.9, 0.94), "marking_hover": Color(0.2, 0.3, 0.45, 0.98),
	"timeline_marker": Color(0.3, 0.62, 1.0),
	# The toolbar's icons and labels, and the tab's controls where the editor's theme is light.
	"toolbar_ink": Color("#dfe3ea"),
	"chrome": Color("#2b2d31"), "ui_panel": Color("#232529"), "ui_field": Color("#1b1d21"),
	"ui_button": Color("#3a3d44"), "ui_button_hover": Color("#454951"), "ui_button_pressed": Color("#2f4a6b"),
	"ui_border": Color(1, 1, 1, 0.1), "ui_text": Color("#dfe3ea"), "ui_text_dim": Color(0.87, 0.89, 0.92, 0.42),
	"ui_accent": Color("#4b9cff"), "ui_selection": Color(0.3, 0.6, 1.0, 0.3),
}

const LIGHT := {
	"dark": false,
	"view_top": Color("#f4f6f9"), "view_bottom": Color("#cdd4de"),
	"grid_minor": Color(0.24, 0.29, 0.38, 0.11), "grid_major": Color(0.24, 0.29, 0.38, 0.3),
	"axis_x": Color(0.86, 0.2, 0.2), "axis_y": Color(0.14, 0.54, 0.2), "axis_z": Color(0.18, 0.4, 0.9),
	"plane_alpha": 0.12, "origin_point": Color(0.35, 0.37, 0.42),
	"body": Color(0.72, 0.75, 0.8), "edge": Color(0.08, 0.09, 0.11), "hidden_edge": Color(0.08, 0.09, 0.11, 0.22),
	"sketch_dim": 1.0, "section_inside": Color(0.3, 0.31, 0.35),
	"surface_front": Color(0.93, 0.76, 0.45), "surface_back": Color(0.55, 0.46, 0.7),
	# Selected faces turn a deep blue; hovered ones only take a pale tint.
	"select_face": Color(0.06, 0.33, 0.9, 0.62), "hover_face": Color(0.55, 0.8, 1.0, 0.35),
	"select_line": Color(0.1, 0.45, 0.95), "hover_line": Color(0.25, 0.58, 1.0),
	"window_box": Color(0.12, 0.48, 0.95), "crossing_box": Color(0.12, 0.58, 0.28),
	"handle": Color(0.12, 0.48, 0.95), "handle_fill": Color(1, 1, 1),
	"analysis_text": Color(0.1, 0.1, 0.12), "analysis_ring": Color(1, 1, 1),
	"status_text": Color(0.12, 0.13, 0.16), "info_text": Color(0.08, 0.27, 0.62), "error_text": Color(0.68, 0.1, 0.08),
	"sketch_free": Color(0.06, 0.3, 0.88), "sketch_defined": Color(0.05, 0.05, 0.07),
	"sketch_halo": Color(1, 1, 1, 0.55),
	"sketch_construction": Color(0.8, 0.36, 0.0), "sketch_centerline": Color(0.26, 0.29, 0.36),
	"sketch_projected": Color(0.52, 0.16, 0.74), "sketch_conflict": Color(0.84, 0.08, 0.06),
	"sketch_select": Color(0.0, 0.48, 0.96), "sketch_point": Color(0.05, 0.05, 0.07), "sketch_origin": Color(0.52, 0.16, 0.74),
	"sketch_inactive": Color(0.2, 0.22, 0.28, 0.75), "sketch_grid_minor": Color(0.25, 0.3, 0.4, 0.09),
	"sketch_grid_major": Color(0.25, 0.3, 0.4, 0.22),
	"dim_line": Color("#1b1f26"), "dim_text": Color("#3b414b"), "dim_preview": Color(0.106, 0.122, 0.149, 0.5),
	"dim_hover": Color("#0a6e8a"), "dim_selected": Color("#0a4bb8"), "dim_error": Color("#a80f0a"),
	"dim_halo": Color(1, 1, 1, 0.6),
	"dim_tip_back": Color("#2f3238", 0.94), "dim_tip_text": Color("#ffffff"),
	"dim_box_back": Color("#ffffff"), "dim_box_frame": Color("#c9ced6"), "dim_box_focus": Color("#2a74d8"),
	"dim_box_text": Color("#1f242c"), "dim_box_selection": Color(0.16, 0.45, 0.85, 0.30), "dim_box_invalid": Color("#c4160f"),
	"note_text": Color(0.05, 0.05, 0.07), "note_back": Color(1, 1, 1, 0.88),
	"glyph_text": Color(0.2, 0.15, 0.02), "glyph_back": Color(1.0, 0.95, 0.75, 0.95), "glyph_back_selected": Color(0.75, 0.88, 1.0, 0.95),
	"glyph_border": Color(0.35, 0.3, 0.1, 0.7),
	"profile": Color(0.35, 0.6, 1.0, 0.18), "profile_hover": Color(0.25, 0.5, 1.0, 0.38),
	"form_surface": Color(0.70, 0.73, 0.78), "form_box_face": Color(0.80, 0.83, 0.87),
	"form_cage_line": Color(0.12, 0.14, 0.18, 0.85), "form_cage_hidden": Color(0.12, 0.14, 0.18, 0.14),
	"form_point": Color(0.10, 0.11, 0.14), "form_select_face": Color(0.06, 0.33, 0.90, 0.55),
	"form_hover_face": Color(0.55, 0.80, 1.0, 0.32), "form_select_line": Color(0.10, 0.45, 0.95),
	"form_hover_line": Color(0.25, 0.58, 1.0), "form_partner": Color(0.10, 0.45, 0.95, 0.40),
	"form_crease": Color("#c8560f"), "form_boundary": Color("#6b3fc2"), "form_symmetry_line": Color("#0f9a74"),
	"form_symmetry_plane": Color(0.06, 0.60, 0.45, 0.08), "form_isolated": Color(0.85, 0.10, 0.18, 0.30),
	"form_frozen": Color("#1b8fc4"), "form_frozen_buffer": Color("#0d4f80"), "form_soft_high": Color("#e8501f"),
	"form_preview": Color("#13994a"), "form_error": Color("#c41616"), "form_warning": Color("#a87a00"),
	"mesh_surface": Color(0.68, 0.71, 0.76), "mesh_wire": Color(0.10, 0.12, 0.16, 0.22),
	"mesh_group_border": Color("#22262e"), "mesh_boundary": Color("#c2185b"),
	"mesh_selected": Color(0.06, 0.33, 0.90, 0.55), "mesh_hover": Color(0.55, 0.80, 1.0, 0.32),
	"mesh_preview": Color("#13994a"), "mesh_removed": Color(0.85, 0.10, 0.18, 0.25),
	"mesh_fill": Color("#c26a00"), "mesh_warning": Color("#a87a00"),
	"mesh_group_palette": [Color("#2e5cb8"), Color("#3d7a1f"), Color("#9a6a10"), Color("#6b3fc2"),
		Color("#0f7fa8"), Color("#b3263e"), Color("#1f8a70"), Color("#4a5378")],
	"assembly_joint": Color("#b86e00"), "assembly_joint_selected": Color(0.1, 0.45, 0.95),
	"assembly_limit": Color("#b86e00", 0.18), "assembly_warning": Color("#a87a00"),
	"assembly_unresolved": Color("#c41616"), "assembly_ground": Color("#5a6472"),
	"assembly_contact": Color("#c2185b"), "assembly_ghost": Color(0.1, 0.35, 0.7, 0.25),
	"cube_face": Color(0.9, 0.92, 0.95), "cube_edge": Color(0.44, 0.48, 0.56), "cube_text": Color(0.16, 0.18, 0.22),
	"cube_hover": Color(0.15, 0.5, 1.0, 0.5),
	"nav_back": Color(1, 1, 1, 0.86), "nav_border": Color(0.1, 0.14, 0.2, 0.14), "nav_text": Color(0.15, 0.17, 0.21),
	"nav_hover": Color(0.1, 0.14, 0.2, 0.08), "nav_pressed": Color(0.15, 0.48, 1.0, 0.24),
	"panel_style": {
		"panel": Color(0.975, 0.98, 0.988, 0.985), "border": Color(0.1, 0.14, 0.2, 0.14), "shadow": Color(0.05, 0.08, 0.14, 0.16),
		"title": Color(0.9, 0.915, 0.935, 1.0), "title_hover": Color(0.86, 0.88, 0.91, 1.0),
		"title_text": Color(0.2, 0.23, 0.29), "grip": Color(0.2, 0.23, 0.29, 0.6), "accent": Color(0.15, 0.48, 1.0, 0.75),
		"check": Color(0.2, 0.23, 0.29, 0.7), "field": Color(1, 1, 1),
	},
	"command_back": Color(0.975, 0.98, 0.988, 0.97), "command_border": Color(0.15, 0.48, 1.0, 0.7),
	"marking_ring": Color(0.15, 0.48, 1.0, 0.3), "marking_center": Color(0.2, 0.23, 0.29, 0.55),
	"marking_back": Color(0.985, 0.99, 0.995, 0.97), "marking_border": Color(0.1, 0.14, 0.2, 0.16),
	"marking_text": Color(0.13, 0.15, 0.19), "marking_hover": Color(0.84, 0.91, 1.0, 1.0),
	"timeline_marker": Color(0.15, 0.48, 1.0),
	"toolbar_ink": Color("#2c323c"),
	"chrome": Color("#e9ecf1"), "ui_panel": Color("#f6f7f9"), "ui_field": Color("#ffffff"),
	"ui_button": Color("#dde2e9"), "ui_button_hover": Color("#d0d7e1"), "ui_button_pressed": Color("#bcd2f0"),
	"ui_border": Color(0.1, 0.14, 0.2, 0.16), "ui_text": Color("#1f242c"), "ui_text_dim": Color(0.12, 0.14, 0.17, 0.42),
	"ui_accent": Color("#2a74d8"), "ui_selection": Color(0.16, 0.45, 0.85, 0.22),
}

## Where the mode goes outside the editor: kept in memory for the whole run.
static var _memory_store := ConfigFile.new()
static var _control_themes := {}


## A copy of a palette ("dark" or "light"; anything else gives the light one).
static func palette(name: String) -> Dictionary:
	return (DARK if name == "dark" else LIGHT).duplicate(true)


## The palette a mode shows: "dark", "light", or for "editor" the one as dark as host_base (the
## editor's base colour; the editor's own when not given).
static func resolve(mode: String, host_base: Variant = null) -> String:
	if mode == "dark" or mode == "light":
		return mode
	var base: Color = host_base if host_base is Color else host_base_color()
	return "dark" if is_dark(base) else "light"


static func is_dark(color: Color) -> bool:
	return luminance(color) < 0.2


## The editor theme's base colour (Godot's own dark one outside the editor).
static func host_base_color() -> Color:
	if Engine.is_editor_hint():
		var theme := EditorInterface.get_editor_theme()
		if theme != null and theme.has_color("base_color", "Editor"):
			return theme.get_color("base_color", "Editor")
		var base: Variant = EditorInterface.get_editor_settings().get_setting("interface/theme/base_color")
		if base is Color:
			return base
	return DEFAULT_HOST_BASE


# --- The saved mode ----------------------------------------------------------------------------

## The store the mode is saved in: the editor settings (project metadata) in the editor, memory
## elsewhere.
static func default_store() -> Object:
	if Engine.is_editor_hint():
		return EditorInterface.get_editor_settings()
	return _memory_store


## The mode saved in a store (the editor settings, a ConfigFile, or a Dictionary in tests).
static func read_mode(store: Variant) -> String:
	var saved: Variant = null
	if store is Dictionary:
		saved = (store as Dictionary).get(KEY)
	elif store is Object and is_instance_valid(store):
		if store.has_method("get_project_metadata"):
			saved = store.get_project_metadata(SECTION, KEY, DEFAULT_MODE)
		elif store.has_method("get_value"):
			saved = store.get_value(SECTION, KEY, DEFAULT_MODE)
	return saved if saved is String and MODES.has(saved) else DEFAULT_MODE


static func write_mode(store: Variant, mode: String) -> void:
	if store is Dictionary:
		(store as Dictionary)[KEY] = mode
	elif store is Object and is_instance_valid(store):
		if store.has_method("set_project_metadata"):
			store.set_project_metadata(SECTION, KEY, mode)
		elif store.has_method("set_value"):
			store.set_value(SECTION, KEY, mode)


# --- Contrast ----------------------------------------------------------------------------------

## WCAG relative luminance of an sRGB colour (alpha ignored).
static func luminance(color: Color) -> float:
	var linear := Color(color.r, color.g, color.b).srgb_to_linear()
	return 0.2126 * linear.r + 0.7152 * linear.g + 0.0722 * linear.b


## WCAG contrast ratio of two colours (1 to 21); a see-through front is laid over the back first.
static func contrast(front: Color, back: Color) -> float:
	var a := luminance(over(front, back))
	var b := luminance(back)
	return (maxf(a, b) + 0.05) / (minf(a, b) + 0.05)


## A colour laid over another by its alpha.
static func over(front: Color, back: Color) -> Color:
	var mixed := Color(back.r, back.g, back.b).lerp(Color(front.r, front.g, front.b), clampf(front.a, 0.0, 1.0))
	return Color(mixed.r, mixed.g, mixed.b, 1.0)


## How a body of this colour looks where it's brightest in the view: a face turned to the camera,
## lit by both of the view's lights (see LIT_GAIN).
static func lit(color: Color) -> Color:
	var linear := Color(color.r, color.g, color.b).srgb_to_linear()
	var bright := Color(minf(linear.r * LIT_GAIN + LIT_SPECULAR, 1.0), minf(linear.g * LIT_GAIN + LIT_SPECULAR, 1.0), minf(linear.b * LIT_GAIN + LIT_SPECULAR, 1.0))
	return bright.linear_to_srgb()


# --- Controls ----------------------------------------------------------------------------------

## How the tab's controls should be themed for a palette: null where the editor's own theme is as
## dark as the palette (its look is kept), else a theme in the palette's colours.
static func control_theme(name: String, host_base: Variant = null, scale := 1.0) -> Theme:
	var p := palette(name)
	var base: Color = host_base if host_base is Color else host_base_color()
	if bool(p.dark) == is_dark(base):
		return null
	var key := "%s@%.2f" % [name, scale]
	if not _control_themes.has(key):
		_control_themes[key] = _make_control_theme(p, scale)
	return _control_themes[key]


## A theme in a palette's colours for a dialog the tab shows over the view (the sketch's driven
## question), whatever the editor's theme is: its panel, title bar, close button, text and buttons,
## with room around the message.
static func dialog_theme(name: String, scale := 1.0) -> Theme:
	var key := "dialog:%s@%.2f" % [name, scale]
	if not _control_themes.has(key):
		var p := palette(name)
		var theme := _make_control_theme(p, scale)
		theme.set_stylebox("panel", "AcceptDialog", _flat(scale, 0, p.chrome, Color(0, 0, 0, 0), Vector2(14, 10)))
		_control_themes[key] = theme
	return _control_themes[key]


## What the editor's icons (drawn for the editor's theme) are multiplied by to read on the
## palette: as they are where the palette is as dark as the editor, darker or lighter where not.
static func icon_tint(name: String, host_base: Variant = null) -> Color:
	var base: Color = host_base if host_base is Color else host_base_color()
	var dark := name == "dark"
	if dark == is_dark(base):
		return Color.WHITE
	return Color(2.4, 2.4, 2.4) if dark else Color(0.3, 0.33, 0.38)


static func _make_control_theme(p: Dictionary, s: float) -> Theme:
	var theme := Theme.new()
	var text: Color = p.ui_text
	var dim: Color = p.ui_text_dim
	var accent: Color = p.ui_accent
	var radius := roundi(3.0 * s)
	var focus: StyleBoxFlat = _flat(s, radius, Color(0, 0, 0, 0), Color(accent, 0.6))
	focus.draw_center = false

	# Buttons and their kin.
	var button_styles := {
		"normal": _flat(s, radius, p.ui_button, p.ui_border), "hover": _flat(s, radius, p.ui_button_hover, p.ui_border),
		"pressed": _flat(s, radius, p.ui_button_pressed, Color(accent, 0.5)), "hover_pressed": _flat(s, radius, p.ui_button_pressed, Color(accent, 0.6)),
		"disabled": _flat(s, radius, Color(p.ui_button, 0.5), Color(p.ui_border, p.ui_border.a * 0.5)), "focus": focus,
	}
	for type in ["Button", "MenuButton", "OptionButton"]:
		for state in button_styles:
			theme.set_stylebox(state, type, button_styles[state])
		for state in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
			theme.set_color(state, type, text)
		theme.set_color("font_disabled_color", type, dim)
	theme.set_stylebox("normal", "MenuButton", _empty(s, Vector2(6, 3)))
	theme.set_icon("arrow", "OptionButton", _glyph("chevron_down", text, 12.0 * s))
	for type in ["CheckBox", "CheckButton"]:
		for state in ["normal", "pressed", "hover", "hover_pressed", "disabled"]:
			theme.set_stylebox(state, type, _empty(s, Vector2(4, 2)))
		theme.set_stylebox("focus", type, focus)
		for state in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
			theme.set_color(state, type, text)
		theme.set_color("font_disabled_color", type, dim)
	var checks := check_icons(Color(text, 0.6), p.ui_field, accent, dim, 16.0 * s)
	for icon in checks:
		theme.set_icon(icon, "CheckBox", checks[icon])
		theme.set_icon(icon, "PopupMenu", checks[icon])

	# Text and fields.
	theme.set_color("font_color", "Label", text)
	theme.set_color("font_shadow_color", "Label", Color(0, 0, 0, 0))
	theme.set_stylebox("normal", "LineEdit", _flat(s, radius, p.ui_field, p.ui_border, Vector2(5, 3)))
	theme.set_stylebox("focus", "LineEdit", _flat(s, radius, Color(0, 0, 0, 0), Color(accent, 0.75), Vector2(5, 3)))
	theme.set_stylebox("read_only", "LineEdit", _flat(s, radius, Color(p.ui_field, 0.6), p.ui_border, Vector2(5, 3)))
	theme.set_color("font_color", "LineEdit", text)
	theme.set_color("font_uneditable_color", "LineEdit", dim)
	theme.set_color("font_placeholder_color", "LineEdit", dim)
	theme.set_color("font_selected_color", "LineEdit", text)
	theme.set_color("caret_color", "LineEdit", text)
	theme.set_color("selection_color", "LineEdit", p.ui_selection)
	theme.set_color("clear_button_color", "LineEdit", dim)

	# Panels, lists and trees.
	var panel: StyleBoxFlat = _flat(s, radius, p.chrome, Color(0, 0, 0, 0), Vector2(4, 4))
	panel.set_corner_radius_all(0)
	theme.set_stylebox("panel", "PanelContainer", panel)
	theme.set_stylebox("panel", "Panel", panel)
	theme.set_stylebox("panel", "ScrollContainer", _empty(s, Vector2.ZERO))
	var list_panel: StyleBoxFlat = _flat(s, radius, p.ui_panel, p.ui_border, Vector2(2, 2))
	var hover: StyleBoxFlat = _flat(s, radius, Color(text, 0.07), Color(0, 0, 0, 0), Vector2(2, 2))
	var selected: StyleBoxFlat = _flat(s, radius, p.ui_selection, Color(0, 0, 0, 0), Vector2(2, 2))
	var selected_focus: StyleBoxFlat = _flat(s, radius, p.ui_selection, Color(accent, 0.55), Vector2(2, 2))
	for type in ["Tree", "ItemList"]:
		theme.set_stylebox("panel", type, list_panel)
		theme.set_stylebox("focus", type, _empty(s, Vector2.ZERO))
		theme.set_stylebox("selected", type, selected)
		theme.set_stylebox("selected_focus", type, selected_focus)
		theme.set_stylebox("cursor", type, _empty(s, Vector2.ZERO))
		theme.set_stylebox("cursor_unfocused", type, _empty(s, Vector2.ZERO))
		theme.set_stylebox("hovered", type, hover)
		theme.set_color("font_color", type, text)
		theme.set_color("font_selected_color", type, text)
		theme.set_color("font_hovered_color", type, text)
		theme.set_color("guide_color", type, Color(text, 0.08))
	theme.set_stylebox("hover", "Tree", hover)
	theme.set_stylebox("hovered", "Tree", hover)
	theme.set_stylebox("button_hover", "Tree", hover)
	theme.set_stylebox("button_pressed", "Tree", selected)
	theme.set_color("font_disabled_color", "Tree", dim)
	theme.set_color("relationship_line_color", "Tree", Color(text, 0.12))
	theme.set_color("parent_hl_line_color", "Tree", Color(text, 0.18))
	theme.set_color("children_hl_line_color", "Tree", Color(text, 0.12))
	theme.set_color("drop_position_color", "Tree", accent)
	theme.set_icon("arrow", "Tree", _glyph("chevron_down", Color(text, 0.75), 12.0 * s))
	theme.set_icon("arrow_collapsed", "Tree", _glyph("chevron_right", Color(text, 0.75), 12.0 * s))
	theme.set_icon("arrow_collapsed_mirrored", "Tree", _glyph("chevron_left", Color(text, 0.75), 12.0 * s))

	# Menus and tooltips.
	var menu_panel: StyleBoxFlat = _flat(s, radius, p.ui_panel, p.ui_border, Vector2(4, 4))
	menu_panel.shadow_color = Color(0, 0, 0, 0.18 if not p.dark else 0.35)
	menu_panel.shadow_size = roundi(6.0 * s)
	theme.set_stylebox("panel", "PopupMenu", menu_panel)
	theme.set_stylebox("hover", "PopupMenu", _flat(s, radius, p.ui_selection, Color(0, 0, 0, 0), Vector2(4, 2)))
	var separator := StyleBoxLine.new()
	separator.color = p.ui_border
	separator.thickness = maxi(1, roundi(s))
	theme.set_stylebox("separator", "PopupMenu", separator)
	theme.set_stylebox("labeled_separator_left", "PopupMenu", separator)
	theme.set_stylebox("labeled_separator_right", "PopupMenu", separator)
	theme.set_color("font_color", "PopupMenu", text)
	theme.set_color("font_hover_color", "PopupMenu", text)
	theme.set_color("font_disabled_color", "PopupMenu", dim)
	theme.set_color("font_accelerator_color", "PopupMenu", Color(text, 0.55))
	theme.set_color("font_separator_color", "PopupMenu", Color(text, 0.6))
	theme.set_icon("submenu", "PopupMenu", _glyph("chevron_right", Color(text, 0.7), 12.0 * s))
	theme.set_icon("submenu_mirrored", "PopupMenu", _glyph("chevron_left", Color(text, 0.7), 12.0 * s))
	theme.set_stylebox("panel", "PopupPanel", menu_panel)
	theme.set_stylebox("panel", "TooltipPanel", _flat(s, radius, p.ui_panel, p.ui_border, Vector2(6, 4)))
	theme.set_color("font_color", "TooltipLabel", text)

	# The tab's own dialogs (Parameters, the name prompt): their window, title bar and close button.
	var dialog: StyleBoxFlat = _flat(s, 0, p.chrome, Color(0, 0, 0, 0), Vector2(8, 8))
	theme.set_stylebox("panel", "AcceptDialog", dialog)
	var frame: StyleBoxFlat = _flat(s, radius, p.chrome, p.ui_border, Vector2.ZERO)
	frame.expand_margin_top = 28.0 * s
	frame.set_border_width_all(maxi(1, roundi(s)))
	theme.set_stylebox("embedded_border", "Window", frame)
	theme.set_stylebox("embedded_unfocused_border", "Window", frame)
	theme.set_color("title_color", "Window", text)
	theme.set_icon("close", "Window", _glyph("close", Color(text, 0.7), 16.0 * s))
	theme.set_icon("close_pressed", "Window", _glyph("close", accent, 16.0 * s))

	# Lines and scroll bars.
	for type in ["VSeparator", "HSeparator"]:
		var line := StyleBoxLine.new()
		line.color = p.ui_border
		line.thickness = maxi(1, roundi(s))
		line.vertical = type == "VSeparator"
		theme.set_stylebox("separator", type, line)
	for type in ["VScrollBar", "HScrollBar"]:
		theme.set_stylebox("scroll", type, _empty(s, Vector2(3, 3)))
		theme.set_stylebox("scroll_focus", type, _empty(s, Vector2(3, 3)))
		theme.set_stylebox("grabber", type, _flat(s, radius, Color(text, 0.22), Color(0, 0, 0, 0), Vector2(3, 3)))
		theme.set_stylebox("grabber_highlight", type, _flat(s, radius, Color(text, 0.35), Color(0, 0, 0, 0), Vector2(3, 3)))
		theme.set_stylebox("grabber_pressed", type, _flat(s, radius, Color(text, 0.45), Color(0, 0, 0, 0), Vector2(3, 3)))
	return theme


static func _flat(s: float, radius: int, color: Color, border := Color(0, 0, 0, 0), margin := Vector2(6, 3)) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = color
	box.set_corner_radius_all(radius)
	if border.a > 0.0:
		box.border_color = border
		box.set_border_width_all(maxi(1, roundi(s)))
	box.content_margin_left = margin.x * s
	box.content_margin_right = margin.x * s
	box.content_margin_top = margin.y * s
	box.content_margin_bottom = margin.y * s
	return box


static func _empty(s: float, margin := Vector2(4, 2)) -> StyleBoxEmpty:
	var box := StyleBoxEmpty.new()
	box.content_margin_left = margin.x * s
	box.content_margin_right = margin.x * s
	box.content_margin_top = margin.y * s
	box.content_margin_bottom = margin.y * s
	return box


## Check box and radio icons for a theme or a panel (CheckBox and PopupMenu icon names): box the
## empty box's line, fill its inside, accent a ticked one, dim a disabled one.
static func check_icons(box: Color, fill: Color, accent: Color, dim: Color, px: float) -> Dictionary:
	return {
		"checked": _glyph("check_on", accent, px, fill), "unchecked": _glyph("check_off", box, px, fill),
		"radio_checked": _glyph("radio_on", accent, px, fill), "radio_unchecked": _glyph("radio_off", box, px, fill),
		"checked_disabled": _glyph("check_on", Color(dim, dim.a * 0.5), px, fill), "unchecked_disabled": _glyph("check_off", dim, px, fill),
		"radio_checked_disabled": _glyph("radio_on", Color(dim, dim.a * 0.5), px, fill), "radio_unchecked_disabled": _glyph("radio_off", dim, px, fill),
	}


## Small control glyphs (check boxes, radio buttons, chevrons) drawn in the given colour.
static func _glyph(kind: String, color: Color, px: float, fill := Color(0, 0, 0, 0)) -> Texture2D:
	var c := "#" + color.to_html(false)
	var o := "%.3f" % color.a
	var f := "#" + fill.to_html(false)
	var body := ""
	match kind:
		"check_off":
			body = "<rect x=\"2.5\" y=\"2.5\" width=\"11\" height=\"11\" rx=\"2.5\" fill=\"%s\" stroke=\"%s\" stroke-opacity=\"%s\" stroke-width=\"1.3\"/>" % [f, c, o]
		"check_on":
			body = "<rect x=\"2\" y=\"2\" width=\"12\" height=\"12\" rx=\"2.5\" fill=\"%s\" fill-opacity=\"%s\"/><path d=\"M4.8 8.2 7 10.3 11.3 5.6\" fill=\"none\" stroke=\"#ffffff\" stroke-width=\"1.7\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>" % [c, o]
		"radio_off":
			body = "<circle cx=\"8\" cy=\"8\" r=\"5.5\" fill=\"%s\" stroke=\"%s\" stroke-opacity=\"%s\" stroke-width=\"1.3\"/>" % [f, c, o]
		"radio_on":
			body = "<circle cx=\"8\" cy=\"8\" r=\"6\" fill=\"%s\" fill-opacity=\"%s\"/><circle cx=\"8\" cy=\"8\" r=\"2.4\" fill=\"#ffffff\"/>" % [c, o]
		"chevron_down":
			body = "<path d=\"M4.5 6.5 8 10 11.5 6.5\" fill=\"none\" stroke=\"%s\" stroke-opacity=\"%s\" stroke-width=\"1.6\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>" % [c, o]
		"chevron_right":
			body = "<path d=\"M6.5 4.5 10 8 6.5 11.5\" fill=\"none\" stroke=\"%s\" stroke-opacity=\"%s\" stroke-width=\"1.6\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>" % [c, o]
		"chevron_left":
			body = "<path d=\"M9.5 4.5 6 8 9.5 11.5\" fill=\"none\" stroke=\"%s\" stroke-opacity=\"%s\" stroke-width=\"1.6\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>" % [c, o]
		"close":
			body = "<path d=\"M4.5 4.5 11.5 11.5M11.5 4.5 4.5 11.5\" fill=\"none\" stroke=\"%s\" stroke-opacity=\"%s\" stroke-width=\"1.6\" stroke-linecap=\"round\"/>" % [c, o]
	var svg := "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 16 16\">%s</svg>" % body
	var image := Image.new()
	if image.load_svg_from_string(svg, maxf(px, 4.0) / 16.0) != OK or image.is_empty():
		return null
	return ImageTexture.create_from_image(image)
