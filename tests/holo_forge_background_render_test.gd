extends SceneTree
## The Forge view's background gradient draws in every renderer: with the grid, origin and bodies
## hidden, the rendered view's top row is the palette's view_top, its bottom row view_bottom and its
## middle row halfway between, in the dark and the light palette, and again after the view changes
## height. (It used SCREEN_UV, which the Compatibility renderer lacks in sky shaders: the view drew
## black with a stripe of noise along the top.)
##
## Needs a window (headless runs draw nothing). Run it in both renderers:
## godot --path . --rendering-method forward_plus --script res://tests/holo_forge_background_render_test.gd
## godot --path . --rendering-method gl_compatibility --script res://tests/holo_forge_background_render_test.gd

const WORKSPACE := preload("res://addons/holo_forge/ui/forge_workspace.gd")
const THEME := preload("res://addons/holo_forge/ui/forge_theme.gd")
## Debanding dithers the gradient by about one step either way.
const TOLERANCE := 4.0 / 255.0

var failures: Array[String] = []
var ws: Control


func _init() -> void:
	call_deferred("run")


func run() -> void:
	create_timer(120.0).timeout.connect(func() -> void:
		print("FAIL holo_forge_background_render: timed out ", failures)
		quit(1))
	var method := RenderingServer.get_current_rendering_method()
	if DisplayServer.get_name() == "headless":
		print("FAIL holo_forge_background_render: needs a window (headless runs draw nothing)")
		quit(1)
		return
	root.size = Vector2i(1200, 800)
	ws = WORKSPACE.new()
	root.add_child(ws)
	ws.size = Vector2(1200, 800)
	for i in 3:
		await process_frame
	var view = ws.viewport
	for node in [view._grid, view._origin_root, view._bodies_root]:
		(node as Node3D).visible = false
	for mode in ["dark", "light"]:
		ws.set_theme_mode(mode)
		await _check(mode, THEME.palette(mode), method)
	# A shorter view: the gradient still spans it top to bottom.
	ws.size = Vector2(1200, 560)
	await _check("dark, after a resize", THEME.palette("dark"), method, true)
	print(("PASS holo_forge_background_render (%s): the background gradient runs from view_top to view_bottom in the dark and light palettes, also after a resize." % method) \
		if failures.is_empty() else "FAIL holo_forge_background_render (%s)" % method)
	quit(0 if failures.is_empty() else 1)


func _check(label: String, palette: Dictionary, method: String, set_dark := false) -> void:
	if set_dark:
		ws.set_theme_mode("dark")
	for i in 6:
		await process_frame
	await RenderingServer.frame_post_draw
	var image: Image = ws.viewport._viewport.get_texture().get_image()
	var h := image.get_height()
	var top: Color = palette.view_top
	var bottom: Color = palette.view_bottom
	# Forward+ blends in linear light, Compatibility in sRGB: the middle row differs a little.
	var t := (h / 2 + 0.5) / h
	var middle := top.srgb_to_linear().lerp(bottom.srgb_to_linear(), t).linear_to_srgb() if method == "forward_plus" else top.lerp(bottom, t)
	var rows := {"top": [0, top], "middle": [h / 2, middle], "bottom": [h - 1, bottom]}
	for name in rows:
		var got := _row_color(image, rows[name][0])
		var want: Color = rows[name][1]
		_expect(_close(got, want), "%s (%s): the %s row should be %s, got %s." % [label, method, name, want, got])


## The row's average colour.
func _row_color(image: Image, y: int) -> Color:
	var sum := Color(0, 0, 0, 0)
	var w := image.get_width()
	for x in w:
		sum += image.get_pixel(x, y)
	return sum / float(w)


func _close(a: Color, b: Color) -> bool:
	return absf(a.r - b.r) <= TOLERANCE and absf(a.g - b.g) <= TOLERANCE and absf(a.b - b.b) <= TOLERANCE


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		print("  ", message)
