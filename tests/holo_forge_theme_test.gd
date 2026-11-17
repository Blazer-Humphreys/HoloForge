extends SceneTree
## Holo Forge's dark and light appearance (ui/forge_theme.gd): both palettes hold the same keys,
## text reads at WCAG 4.5:1 or better and lines stand out on both ends of each view background;
## "editor" follows a dark and a light editor base colour; the mode is saved in the store it's
## given (a Dictionary or ConfigFile) and read back by a new workspace. Switching recolours the
## view's background, grid, origin, edges and default body colour, the view cube, the sketch
## overlay and its palette, the marking menu, the timeline, the toolbar's ink (its icons render
## again), and gives the tab's controls their own theme only where the editor's isn't as dark; it
## rebuilds nothing and leaves the part's baked meshes and materials alone. The toolbar's
## appearance button and the "Dark Mode" tool (found by search, run without a part) switch it.
## Sketch curves read on a lit face (bodies fade while a sketch is open), a selected face stands
## apart from a plain and a hovered one, a section takes the palette's colours, Slice and the
## switcher lock end with the sketch, and the tab's dialogs and readouts follow the theme.
##
## godot --headless --path . --script res://tests/holo_forge_theme_test.gd

const THEME := preload("res://addons/holo_forge/ui/forge_theme.gd")
const WORKSPACE := preload("res://addons/holo_forge/ui/forge_workspace.gd")
const CAD_PART := preload("res://addons/holo_forge/nodes/cad_part.gd")
const DOCUMENT := preload("res://addons/holo_forge/core/document.gd")
const CATALOG := preload("res://addons/holo_forge/tools/catalog.gd")
const SKETCH := preload("res://addons/holo_forge/core/sketch/sketch_data.gd")
const VIEW_CUBE := preload("res://addons/holo_forge/ui/view_cube.gd")
const ICON_DIR := "res://addons/holo_forge/icons/tools/"
const DARK_BASE := Color(0.13, 0.15, 0.18)
const LIGHT_BASE := Color(0.88, 0.89, 0.91)
## Text against its background, and lines (1.8 px and up) against the view's.
const TEXT_CONTRAST := 4.5
const LINE_CONTRAST := 2.5

var failures: Array[String] = []


func _init() -> void:
	call_deferred("run")


func run() -> void:
	create_timer(180.0).timeout.connect(func() -> void:
		print("FAIL holo_forge_theme: timed out ", failures)
		quit(1))
	root.size = Vector2i(1400, 900)
	_check_palettes()
	_check_resolve_and_store()
	_check_icons()
	await _check_workspace()
	await _check_saved_mode()
	await _check_dark_mode_tool()
	print("PASS holo_forge_theme: palettes match and read (text 4.5:1, lines 2.5:1 on both background ends), editor mode follows the base colour, saved mode round trip, sun/moon icons, live switch of view, grid, origin, cube, sketch, palette, marking menu, timeline, toolbar ink and control theme without a rebuild or a baked-material change, appearance button and Dark Mode tool" \
		if failures.is_empty() else "FAIL holo_forge_theme")
	quit(0 if failures.is_empty() else 1)


func _expect(ok: bool, detail: String) -> void:
	if not ok:
		failures.append(detail)
		push_error(detail)
		print("FAIL: ", detail)


# --- Palettes --------------------------------------------------------------------------------

func _check_palettes() -> void:
	var dark := THEME.palette("dark")
	var light := THEME.palette("light")
	_expect(dark.keys() == light.keys(), "Both palettes should hold the same keys (%s vs %s)." % [dark.size(), light.size()])
	_expect((dark.panel_style as Dictionary).keys() == (light.panel_style as Dictionary).keys(), "Both panel styles should hold the same keys.")
	_expect(bool(dark.dark) and not bool(light.dark), "The dark palette is dark and the light one isn't.")
	_expect(THEME.is_dark(dark.view_top) and THEME.is_dark(dark.view_bottom) and not THEME.is_dark(light.view_top) and not THEME.is_dark(light.view_bottom),
		"The dark view should be dark at both ends and the light one light.")
	_expect(THEME.palette("anything") == light, "An unknown palette name gives the light palette.")
	for name in ["dark", "light"]:
		var p := THEME.palette(name)
		var ends: Array = [p.view_top, p.view_bottom]
		for back: Color in ends:
			for key in ["status_text", "info_text", "error_text", "analysis_text"]:
				_contrast(name, key, p[key], back, TEXT_CONTRAST)
			for key in ["sketch_free", "sketch_defined", "sketch_construction", "sketch_centerline", "sketch_projected", "sketch_conflict",
					"sketch_select", "select_line", "edge", "window_box", "crossing_box", "handle", "axis_x", "axis_y", "axis_z"]:
				_contrast(name, key, p[key], back, LINE_CONTRAST)
			# Sketch dimensions are drawn straight on the view: lines (and the see-through preview) as
			# lines, values as text, hover, selection and errors a little lower; the hover tip on its box.
			for key in ["dim_line", "dim_preview"]:
				_contrast(name, key, p[key], back, LINE_CONTRAST)
			_contrast(name, "dim_text", p.dim_text, back, TEXT_CONTRAST)
			for key in ["dim_hover", "dim_selected", "dim_error"]:
				_contrast(name, key, p[key], back, 3.0)
			_contrast(name, "dim_tip_text on dim_tip_back", p.dim_tip_text, THEME.over(p.dim_tip_back, back), TEXT_CONTRAST)
			_contrast(name, "note_text on note_back", p.note_text, THEME.over(p.note_back, back), TEXT_CONTRAST)
			_contrast(name, "glyph_text on glyph_back", p.glyph_text, THEME.over(p.glyph_back, back), TEXT_CONTRAST)
			_contrast(name, "glyph_text on glyph_back_selected", p.glyph_text, THEME.over(p.glyph_back_selected, back), TEXT_CONTRAST)
			_contrast(name, "nav_text on nav_back", p.nav_text, THEME.over(p.nav_back, back), TEXT_CONTRAST)
			_contrast(name, "marking_text on marking_back", p.marking_text, THEME.over(p.marking_back, back), TEXT_CONTRAST)
			_contrast(name, "panel title", p.panel_style.title_text, THEME.over(p.panel_style.title, back), TEXT_CONTRAST)
		_contrast(name, "cube_text on cube_face", p.cube_text, p.cube_face, TEXT_CONTRAST)
		for key in ["chrome", "ui_panel", "ui_field", "ui_button", "ui_button_hover"]:
			_contrast(name, "ui_text on " + key, p.ui_text, p[key], TEXT_CONTRAST)
		_contrast(name, "toolbar_ink on chrome", p.toolbar_ink, p.chrome, TEXT_CONTRAST)
		for key in ["dim_box_text", "dim_box_invalid"]:
			_contrast(name, key + " on dim_box_back", p[key], p.dim_box_back, TEXT_CONTRAST)
		# Dimensions stand apart from fully defined curves and centerlines (dimension lines are thin).
		if bool(p.dark):
			for key in ["sketch_defined", "sketch_centerline"]:
				var hue := absf(p.dim_line.h - p[key].h)
				_expect(minf(hue, 1.0 - hue) > 0.1 or absf(p.dim_line.get_luminance() - p[key].get_luminance()) > 0.1,
					"%s: dimension lines should look different from %s." % [name, key])
		# Construction amber and sketch blue stay apart from each other, not just from the background.
		_expect(absf(p.sketch_free.h - p.sketch_construction.h) > 0.2, "%s: construction and free sketch curves should differ in hue." % name)
		_expect(absf(p.sketch_defined.get_luminance() - p.sketch_free.get_luminance()) > 0.1 or absf(p.sketch_defined.h - p.sketch_free.h) > 0.2,
			"%s: fully defined and free sketch curves should look different." % name)
		# Sketching on a face: free curves read on the brightest a body face gets (faded by sketch_dim
		# while a sketch is open), and every curve on the halo drawn under it, also over the hover tint.
		var face := THEME.lit(_scaled(p.body, float(p.sketch_dim)))
		_contrast(name, "sketch_free on a lit face", p.sketch_free, face, 3.0)
		for key in ["sketch_free", "sketch_defined", "sketch_construction", "sketch_projected", "sketch_conflict", "sketch_select"]:
			_contrast(name, key + " on its halo over a lit face", p[key], THEME.over(p.sketch_halo, face), LINE_CONTRAST)
			_contrast(name, key + " on its halo over a hovered lit face", p[key], THEME.over(p.sketch_halo, THEME.over(p.hover_face, face)), LINE_CONTRAST)
		# Dimensions on a face keep their minimums on their halo, over the face and over a profile on
		# it (the canvas as well, for the brightest a face can be).
		for under: Color in [face, THEME.over(p.profile, face), THEME.over(p.profile_hover, face), THEME.lit(p.body)]:
			var halo := THEME.over(p.dim_halo, under)
			for key in ["dim_line", "dim_preview"]:
				_contrast(name, key + " on its halo over a face", p[key], halo, LINE_CONTRAST)
			_contrast(name, "dim_text on its halo over a face", p.dim_text, halo, TEXT_CONTRAST)
			for key in ["dim_hover", "dim_selected", "dim_error"]:
				_contrast(name, key + " on its halo over a face", p[key], halo, 3.0)
		# A hovered dimension stands apart from free curves (most of what is being dimensioned) and
		# from a selected dimension.
		for key in ["sketch_free", "dim_selected"]:
			var a: Color = p.dim_hover
			var b: Color = p[key]
			var distance := Vector3(a.r - b.r, a.g - b.g, a.b - b.b).length()
			_expect(distance >= 0.2 or THEME.contrast(a, b) >= 1.4, "%s: dim_hover should look different from %s (%s vs %s)." % [name, key, a.to_html(false), b.to_html(false)])
		# A selected face stands apart from a plain one and from a hovered one, head-on and slanted.
		for plain: Color in [THEME.lit(p.body), p.body]:
			var selected := THEME.over(p.select_face, plain)
			_apart(name, "a selected and a plain face", selected, plain)
			_apart(name, "a selected and a hovered face", selected, THEME.over(p.hover_face, plain))
		# The floating panels hide what's behind them.
		_expect(p.panel_style.panel.a >= 0.98 and p.panel_style.title.a >= 0.98, "%s: the floating panels should be opaque (%.2f)." % [name, p.panel_style.panel.a])
		_contrast(name, "a panel check box", p.panel_style.check, p.panel_style.panel, 3.0)
	_expect(is_equal_approx(THEME.contrast(Color.BLACK, Color.WHITE), 21.0), "Black on white should be 21:1 (%.2f)." % THEME.contrast(Color.BLACK, Color.WHITE))


## Two colours tell apart: 1.4:1 or more, or clearly different in colour (distance and saturation).
func _apart(name: String, what: String, a: Color, b: Color) -> void:
	var distance := Vector3(a.r - b.r, a.g - b.g, a.b - b.b).length()
	var ok := THEME.contrast(a, b) >= 1.4 or (distance >= 0.2 and absf(a.s - b.s) >= 0.25)
	_expect(ok, "%s: %s should look different (%s vs %s, %.2f:1, distance %.2f)." % [name, what, a.to_html(false), b.to_html(false), THEME.contrast(a, b), distance])


func _scaled(color: Color, by: float) -> Color:
	return Color(color.r * by, color.g * by, color.b * by, color.a)


func _contrast(name: String, what: String, front: Color, back: Color, minimum: float) -> void:
	var ratio := THEME.contrast(front, back)
	_expect(ratio >= minimum, "%s: %s should read at %.1f:1 or better (%.2f against %s)." % [name, what, minimum, ratio, back.to_html(false)])


func _check_resolve_and_store() -> void:
	_expect(THEME.resolve("editor", DARK_BASE) == "dark" and THEME.resolve("editor", LIGHT_BASE) == "light", "Follow Editor should follow a dark and a light base colour.")
	_expect(THEME.resolve("dark", LIGHT_BASE) == "dark" and THEME.resolve("light", DARK_BASE) == "light", "Dark and Light ignore the editor.")
	_expect(THEME.resolve("editor") == "dark", "Outside the editor, Follow Editor is Godot's own dark theme.")
	_expect(THEME.control_theme("dark", DARK_BASE) == null and THEME.control_theme("light", LIGHT_BASE) == null,
		"Where the editor is as dark as the palette, the tab keeps the editor's controls.")
	var own := THEME.control_theme("light", DARK_BASE)
	_expect(own != null and own.get_color("font_color", "Button") == THEME.palette("light").ui_text and own.get_icon("checked", "CheckBox") != null
		and own.get_stylebox("panel", "PopupMenu") != null, "A light tab in a dark editor should get light controls of its own.")
	_expect(THEME.control_theme("dark", LIGHT_BASE) != null, "A dark tab in a light editor should get dark controls of its own.")
	_expect(THEME.icon_tint("light", DARK_BASE).get_luminance() < 0.5 and THEME.icon_tint("dark", LIGHT_BASE).r > 1.0 and THEME.icon_tint("dark", DARK_BASE) == Color.WHITE,
		"Editor icons should be darkened on a light tab in a dark editor, brightened the other way, and left alone otherwise.")
	var store := {}
	_expect(THEME.read_mode(store) == "editor", "An empty store means Follow Editor.")
	THEME.write_mode(store, "light")
	_expect(store.get(THEME.KEY) == "light" and THEME.read_mode(store) == "light", "A Dictionary store should keep the mode.")
	var config := ConfigFile.new()
	THEME.write_mode(config, "dark")
	_expect(config.get_value(THEME.SECTION, THEME.KEY) == "dark" and THEME.read_mode(config) == "dark", "A ConfigFile store should keep the mode under holo_forge/theme.")
	for bad in [{THEME.KEY: "neon"}, {THEME.KEY: 3}, null]:
		_expect(THEME.read_mode(bad) == "editor", "A broken saved mode (%s) should fall back to Follow Editor." % [bad])
	_expect(THEME.default_store() is ConfigFile, "Outside the editor the mode should live in memory, never in the editor's settings.")


func _check_icons() -> void:
	for file in ["dark_mode.svg", "light_mode.svg"]:
		var path: String = ICON_DIR + file
		_expect(FileAccess.file_exists(path), "%s should exist." % file)
		var text := FileAccess.get_file_as_string(path)
		_expect(text.length() < 2048 and text.contains("#dfe3ea") and text.begins_with("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"24\" height=\"24\" viewBox=\"0 0 24 24\">"),
			"%s should be a 24 px Holo icon under 2 KB drawn in the ink." % file)
		for banned in ["<text", "<image", "href", "filter", "Gradient", "class="]:
			_expect(not text.contains(banned), "%s shouldn't use %s." % [file, banned])
		var image := Image.new()
		_expect(image.load_svg_from_string(text, 1.0) == OK and image.get_width() == 24, "%s should load." % file)


# --- The workspace ---------------------------------------------------------------------------

func _check_workspace() -> void:
	var ws: Control = WORKSPACE.new()
	root.add_child(ws)
	ws.size = Vector2(1400, 900)
	await _frames(3)
	var store := {}
	ws.theme_store = store
	ws.theme_host_base = DARK_BASE
	_expect(ws.theme_mode == "editor" and ws.theme_name == "dark", "A new workspace follows the (dark) editor (%s, %s)." % [ws.theme_mode, ws.theme_name])
	if ws.kernel == null:
		_expect(false, "The native kernel should load.")
		ws.queue_free()
		return
	var part: Node3D = CAD_PART.new()
	part.document = DOCUMENT.new()
	root.add_child(part)
	ws.set_part(part)
	await process_frame
	ws.run_tool(CATALOG.find("solid.create.box"))
	ws.accept_command()
	await _frames(2)
	var bodies: Array = ws.result.get("bodies", {}).keys()
	_expect(bodies.size() == 1, "The box should be built.")
	var body_id: String = bodies[0] if bodies.size() == 1 else ""
	var feature: Resource = ws.create_sketch(SKETCH.ORIGIN_PLANES.xy, "xy")
	await _frames(2)
	_expect(feature != null and ws.sketch_editor.active, "A sketch should open.")
	ws.sketch_editor.start_tool("rect_2pt")
	ws.sketch_editor.tool_click(Vector2(-0.01, -0.01), {}, {})
	ws.sketch_editor.tool_click(Vector2(0.01, 0.01), {}, {})
	await _frames(2)
	ws.sketch_editor.cancel_tool()

	var rebuilds: int = ws.rebuild_count
	var snapshot: Dictionary = ws.doc.snapshot()
	var view_surface: MeshInstance3D = ws.viewport.body_surface(body_id)
	var baked := _baked_materials(part)
	var default_albedo: Color = CAD_PART.default_material().albedo_color
	var surface_albedo: Color = CAD_PART.surface_material().albedo_color
	_expect(not baked.is_empty(), "The part should have baked meshes.")
	var last_icon: Texture2D = ws.toolbar.icon_buttons("Create")[0].icon if not ws.toolbar.icon_buttons("Create").is_empty() else null

	for mode in ["light", "dark", "light"]:
		ws.toolbar.theme_button().get_popup().id_pressed.emit(["dark", "light", "editor"].find(mode))
		await _frames(2)
		var p := THEME.palette(mode)
		_expect(ws.theme_mode == mode and ws.theme_name == mode and store.get(THEME.KEY) == mode, "The appearance menu should switch to %s and save it (%s, %s)." % [mode, ws.theme_mode, store])
		var view: Control = ws.viewport
		_expect(view.background_colors() == [p.view_top, p.view_bottom], "%s: the view's background should be the palette's gradient (%s)." % [mode, view.background_colors()])
		_expect(view.grid_colors() == [p.grid_minor, p.grid_major], "%s: the grid should be drawn in the palette's colours." % mode)
		_expect(view.edge_material().albedo_color == p.edge and (view.surface_material() as StandardMaterial3D).albedo_color == _scaled(p.body, float(p.sketch_dim)) and view.sketch_dimmed,
			"%s: edges and the default body colour should follow the palette, faded while the sketch is open." % mode)
		_expect((view.surface_body_material() as ShaderMaterial).get_shader_parameter("front_color") == _scaled(p.surface_front, float(p.sketch_dim)), "%s: surface bodies should take the palette's tint." % mode)
		var cube: Dictionary = view.view_cube().colors()
		_expect(cube.face == p.cube_face and cube.edge == p.cube_edge and cube.text == p.cube_text and cube.hover == p.cube_hover, "%s: the view cube should follow the palette (%s)." % [mode, cube])
		_expect(ws.sketch_editor.theme_colors.sketch_free == p.sketch_free and ws.sketch_editor.theme_colors.dim_text == p.dim_text
			and ws.sketch_editor._material_profile.albedo_color == p.profile, "%s: the sketch overlay and its profiles should follow the palette." % mode)
		var value_box: LineEdit = ws.sketch_editor._edit
		_expect(value_box.get_theme_color("font_color") == p.dim_box_text and value_box.get_theme_color("selection_color") == p.dim_box_selection
			and (value_box.get_theme_stylebox("normal") as StyleBoxFlat).bg_color == p.dim_box_back
			and (value_box.get_theme_stylebox("focus") as StyleBoxFlat).border_color == p.dim_box_focus
			and ws.sketch_editor._tip_style.bg_color == p.dim_tip_back, "%s: the dimension value box and tip should follow the palette." % mode)
		_expect(ws.sketch_editor.palette.get_style().panel == p.panel_style.panel and ws.sketch_editor.palette.get_style().title_text == p.panel_style.title_text,
			"%s: the sketch palette should be restyled." % mode)
		_expect(ws.marking_menu.colors().marking_text == p.marking_text, "%s: the marking menu should follow the palette." % mode)
		_expect(ws.timeline.marker_color() == p.timeline_marker, "%s: the timeline's marker should follow the palette." % mode)
		_expect(ws.toolbar.ink_color == p.toolbar_ink, "%s: the toolbar's ink should be the palette's (%s)." % [mode, ws.toolbar.ink_color])
		var icon: Texture2D = ws.toolbar.icon_buttons("Create")[0].icon if not ws.toolbar.icon_buttons("Create").is_empty() else null
		_expect(icon != null and icon != last_icon, "%s: the toolbar's icons should render again in the new ink." % mode)
		last_icon = icon
		var controls: Theme = ws.timeline.theme
		_expect((controls != null) == (mode == "light") and ws.toolbar.theme == controls and ws.viewport.get_parent().theme == controls,
			"%s in a dark editor: the tab's controls get their own theme only when light (%s)." % [mode, controls])
		_expect(ws._status.get_theme_color("font_color") in [p.status_text, p.info_text, p.error_text], "%s: the status line should take a palette colour." % mode)
		_expect(ws.rebuild_count == rebuilds and ws.viewport.body_surface(body_id) == view_surface,
			"%s: switching should rebuild nothing (rebuilds %d -> %d, same view body %s)." % [mode, rebuilds, ws.rebuild_count, ws.viewport.body_surface(body_id) == view_surface])
		_expect(var_to_str(ws.doc.snapshot()) == var_to_str(snapshot), "%s: switching shouldn't change the document." % mode)
		_expect(_baked_materials(part) == baked and CAD_PART.default_material().albedo_color == default_albedo and CAD_PART.surface_material().albedo_color == surface_albedo,
			"%s: the baked meshes should keep their materials." % mode)
		var popup: PopupMenu = ws.toolbar.theme_button().get_popup()
		_expect(popup.is_item_checked(["dark", "light", "editor"].find(mode)) and ws.toolbar.theme_button().icon != null, "%s: the appearance menu should tick the mode." % mode)

	# Follow Editor: the palette tracks the editor's base colour.
	ws.toolbar.theme_button().get_popup().id_pressed.emit(2)
	await process_frame
	_expect(ws.theme_mode == "editor" and ws.theme_name == "dark" and ws.timeline.theme == null, "Follow Editor in a dark editor is dark with the editor's controls.")
	ws.theme_host_base = LIGHT_BASE
	await process_frame
	_expect(ws.theme_name == "light" and ws.viewport.background_colors()[0] == THEME.palette("light").view_top and ws.timeline.theme == null,
		"Follow Editor in a light editor is light, still with the editor's controls.")
	_expect(ws.toolbar.theme_button().tooltip_text.contains("following the editor"), "The appearance button should say it follows the editor.")
	ws.theme_host_base = DARK_BASE
	await process_frame

	# The view cube lights up the face under the mouse.
	ws.viewport.look_from(Vector3.BACK)
	await process_frame
	var cube: Control = ws.viewport.view_cube()
	var motion := InputEventMouseMotion.new()
	motion.position = Vector2(VIEW_CUBE.SIZE * 0.5, 22 + VIEW_CUBE.SIZE * 0.5)
	cube._gui_input(motion)
	_expect(cube.hovered_region() == Vector3(0, 0, 1), "The cube's FRONT face should light up under the mouse (%s)." % cube.hovered_region())
	cube.mouse_exited.emit()
	_expect(cube.hovered_region() == Vector3.ZERO, "Leaving the cube clears its highlight.")

	await _check_sketch_state(ws, feature, body_id)
	await _check_section_colours(ws, body_id)
	ws.set_part(null)
	part.queue_free()
	ws.queue_free()
	await _frames(2)


## Leaving a sketch: the bodies come back at full colour, Slice is unticked for the next sketch,
## and the workspace switcher (locked while sketching) works again. The tab's dialogs take the
## tab's controls.
func _check_sketch_state(ws: Control, feature: Resource, body_id: String) -> void:
	var editor: RefCounted = ws.sketch_editor
	var switcher: OptionButton = ws.toolbar.workspace_switcher()
	_expect(switcher.disabled, "The workspace switcher should be locked while a sketch is open.")
	var slice: CheckBox = editor._palette_checks.slice
	slice.button_pressed = true
	await _frames(1)
	var holder: Node3D = ws.viewport._body_nodes[body_id].holder
	_expect(editor.show.slice and not holder.visible, "Slice should hide the body.")
	ws.run_action("finish_sketch")
	await _frames(2)
	var p: Dictionary = THEME.palette(ws.theme_name)
	_expect(not slice.button_pressed and not editor.show.slice and holder.visible, "Finish Sketch should untick Slice and show the body again.")
	_expect(not ws.viewport.sketch_dimmed and (ws.viewport.surface_material() as StandardMaterial3D).albedo_color == p.body, "After the sketch the body should take its full colour again.")
	_expect(not switcher.disabled and ws.toolbar.workspace == ws.workspace, "After the sketch the switcher should work again.")
	ws.edit_feature(feature.id)
	await _frames(2)
	_expect(editor.active and not slice.button_pressed and not editor.show.slice and ws.viewport._body_nodes[body_id].holder.visible, "The next sketch should open with Slice off and the body shown.")
	ws.run_action("finish_sketch")
	await _frames(1)
	for mode in ["light", "dark"]:
		ws.set_theme_mode(mode)
		await _frames(1)
		for window: Window in [ws.parameters_dialog, ws._prompt]:
			_expect(window.theme == ws.timeline.theme, "%s: the %s dialog should take the tab's controls." % [mode, window.get_class()])
	# The readouts drawn over the view take the view's palette (no fixed near-black text).
	for file in ["mass_command.gd", "texture_map_command.gd", "measure_command.gd"]:
		var text := FileAccess.get_file_as_string("res://addons/holo_forge/tools/" + file)
		_expect(text.contains("theme_colors") and not text.contains("Color(0.1, 0.1, 0.12)"), "%s should draw its labels in the view's palette." % file)


## A Section Analysis shows the palette's body colour outside and section_inside within, and a
## theme switch recolours it without building the analysis again.
func _check_section_colours(ws: Control, body_id: String) -> void:
	ws.run_tool(CATALOG.find("solid.inspect.section_analysis"))
	ws.accept_command()
	await _frames(2)
	var builds: int = ws.analysis_build_count
	for mode in ["dark", "light", "dark"]:
		ws.set_theme_mode(mode)
		await _frames(1)
		var p: Dictionary = THEME.palette(mode)
		var material := ws.viewport.body_surface(body_id).material_override as ShaderMaterial
		_expect(material != null and material.get_shader_parameter("base_color") == p.body and material.get_shader_parameter("inside_color") == p.section_inside,
			"%s: a sectioned body should take the palette's colours (%s, %s)." % [mode, material.get_shader_parameter("base_color") if material != null else null, material.get_shader_parameter("inside_color") if material != null else null])
	_expect(ws.analysis_build_count == builds, "Switching the theme shouldn't build the section again (%d -> %d)." % [builds, ws.analysis_build_count])
	if not ws.doc.analyses.is_empty():
		ws.delete_analysis(str(ws.doc.analyses[0].id))
	await _frames(1)


func _check_saved_mode() -> void:
	for store: Variant in [{THEME.KEY: "light"}, _config("dark")]:
		var ws: Control = WORKSPACE.new()
		ws.theme_store = store
		root.add_child(ws)
		await process_frame
		var want := THEME.read_mode(store)
		_expect(ws.theme_mode == want and ws.theme_name == want and ws.viewport.background_colors()[1] == THEME.palette(want).view_bottom,
			"A workspace on a store saying %s should open in it (%s)." % [want, ws.theme_name])
		ws.queue_free()
		await process_frame


func _check_dark_mode_tool() -> void:
	var found := CATALOG.search("dark", "Solid")
	_expect(not found.is_empty() and found[0].name == "Dark Mode" and found[0].id == "utilities.display.dark_mode" and CATALOG.is_enabled(found[0]),
		"Searching \"dark\" should find the Dark Mode tool first (%s)." % [found.map(func(t: Dictionary) -> String: return t.name).slice(0, 3)])
	_expect(CATALOG.default_pins("Utilities", "Display").has("utilities.display.dark_mode"), "Dark Mode should be on the Utilities DISPLAY block.")
	var ws: Control = WORKSPACE.new()
	var store := {THEME.KEY: "dark"}
	ws.theme_store = store
	root.add_child(ws)
	await process_frame
	_expect(ws.doc == null, "No part is open.")
	ws.run_tool(found[0] if not found.is_empty() else {})
	await process_frame
	_expect(ws.theme_name == "light" and store[THEME.KEY] == "light", "Dark Mode without a part should switch dark to light (%s)." % ws.theme_name)
	ws.run_tool(found[0] if not found.is_empty() else {})
	await process_frame
	_expect(ws.theme_name == "dark" and store[THEME.KEY] == "dark" and ws.last_message.begins_with("Dark"), "Dark Mode again should switch back (%s)." % ws.last_message)
	ws.queue_free()
	await process_frame


# --- Helpers ---------------------------------------------------------------------------------

## Every material on the part's baked meshes, by node path and surface.
func _baked_materials(part: Node3D) -> Dictionary:
	var found := {}
	for node in part.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := node as MeshInstance3D
		var key := str(part.get_path_to(mesh_instance))
		found[key + ":override"] = mesh_instance.material_override
		if mesh_instance.mesh != null:
			for i in mesh_instance.mesh.get_surface_count():
				found["%s:%d" % [key, i]] = mesh_instance.mesh.surface_get_material(i)
	return found


func _config(mode: String) -> ConfigFile:
	var config := ConfigFile.new()
	config.set_value(THEME.SECTION, THEME.KEY, mode)
	return config


func _frames(count: int) -> void:
	for i in count:
		await process_frame
