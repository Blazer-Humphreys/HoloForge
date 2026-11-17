extends SceneTree
## The command panel's layout settles: a panel with word-wrapped info text (a measure result, a
## tool note) of many lengths, in rows that just do or just don't need the scrollbar, reaches a
## steady size within a few frames at every height of the view around its scrolling point, and
## stays there. Before the fix the rows' width changed with the vertical scrollbar, their height
## with their width and the scrollbar with their height, so at some heights (here 30 words at the
## panel's own height) the scrollbar switched on and off for ever within one frame: the deferred
## minimum-size updates flooded the message queue ("Object was deleted while awaiting a
## callback", "Message queue out of memory") and the editor stalled or crashed. Also: setup()
## takes the old rows out at once, so they never count towards the new panel's size, and
## set_info with longer text settles too.
##
## Run it in a rendering run as well as headless (it renders its frames when not headless):
## godot --path . --script res://tests/holo_forge_command_panel_layout_test.gd
## godot --headless --path . --script res://tests/holo_forge_command_panel_layout_test.gd

const COMMAND_PANEL := preload("res://addons/holo_forge/ui/command_panel.gd")
const TEXT := "Volume 12.345 cm3 area 67.89 cm2 mass 98.7 g at 7.85 g/cm3 centre of mass 12.3 45.6 7.8 mm principal moments 1.23e-6 4.56e-6 7.89e-6 kg m2 about the axes shown in the view bodies hidden behind others are measured too and the rest"
## Frames a panel gets to settle, then frames it must hold still.
const SETTLE_FRAMES := 5
const HOLD_FRAMES := 5

var failures: Array[String] = []


func _init() -> void:
	call_deferred("run")


func run() -> void:
	# Rendering runs draw every frame as fast as they can (no vsync wait).
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	root.size = Vector2i(1200, 900)
	var view := Control.new()
	view.size = Vector2(900, 800)
	root.add_child(view)
	var panel: PanelContainer = COMMAND_PANEL.new()
	view.add_child(panel)
	var rendering := DisplayServer.get_name() != "headless"
	var words := TEXT.split(" ")
	var unsettled: Array[String] = []
	var worst := 0
	var configs := 0
	for n in range(6, words.size() + 1, 3):
		var text := " ".join(words.slice(0, n))
		# The panel's own height with this text, then max_height swept across it pixel by pixel.
		panel.max_height = 0.0
		panel.setup("Measure", _fields(text), {}, "mm")
		await _frames(SETTLE_FRAMES)
		var natural := panel.size.y
		for dh in range(-20, 4):
			configs += 1
			panel.setup("Measure", _fields(text), {}, "mm")
			panel.max_height = natural + dh
			var took := await _settle(panel)
			worst = maxi(worst, took)
			if took < 0:
				unsettled.append("%d words at %.0f px" % [n, natural + dh])
	_check(unsettled.is_empty(), "the panel settles at every height (still changing: %s)" % ", ".join(unsettled.slice(0, 6)))
	_check(configs >= 200, "the sweep covered the scrolling point (%d panels)" % configs)
	# Old rows go at once: right after a new setup the rows hold only the new fields.
	panel.setup("Measure", _fields(TEXT), {}, "mm")
	var rows: VBoxContainer = panel.get("_rows")
	var short: Array[Dictionary] = [{"key": "x", "type": "info", "text": "One line."}]
	panel.setup("Short", short, {}, "mm")
	_check(rows.get_child_count() == 1, "setup() takes the old rows out at once (%d children)" % rows.get_child_count())
	# Longer text through set_info settles as well.
	panel.setup("Measure", _fields(TEXT), {}, "mm")
	panel.max_height = 0.0
	await _frames(SETTLE_FRAMES)
	panel.max_height = panel.size.y - 10.0
	await _frames(SETTLE_FRAMES)
	panel.set_info("result", TEXT + " " + TEXT)
	var took_info := await _settle(panel)
	_check(took_info >= 0, "set_info with longer text settles (took %d frames)" % took_info)
	print("PASS holo_forge_command_panel_layout: settles within %d frames for %d panels around the scrolling point (%s run), old rows leave at once, set_info settles." % [worst, configs, "rendering" if rendering else "headless"] \
		if failures.is_empty() else "FAIL holo_forge_command_panel_layout")
	quit(0 if failures.is_empty() else 1)


func _fields(text: String) -> Array[Dictionary]:
	var fields: Array[Dictionary] = [
		{"key": "a", "type": "expression", "label": "Width"},
		{"key": "result", "type": "info", "text": text},
		{"key": "c", "type": "expression", "label": "Depth"},
	]
	return fields


## Frames until the panel's size and its scrollbar stop changing (and then hold for
## HOLD_FRAMES), or -1 when they are still changing after SETTLE_FRAMES.
func _settle(panel: Control) -> int:
	var scroll: ScrollContainer = panel.get("_scroll")
	var last := ""
	var still := 0
	for frame in SETTLE_FRAMES + HOLD_FRAMES:
		await process_frame
		var state := "%s %s %s" % [panel.size, scroll.size, scroll.get_v_scroll_bar().visible]
		if state == last:
			still += 1
			if still >= HOLD_FRAMES:
				return frame - HOLD_FRAMES
		else:
			if frame >= SETTLE_FRAMES:
				return -1
			still = 0
		last = state
	return -1


func _frames(count: int) -> void:
	for i in count:
		await process_frame


func _check(ok: bool, what: String) -> void:
	if not ok:
		failures.append(what)
		print("  FAIL: ", what)
