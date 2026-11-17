@tool
extends "res://addons/holo_forge/ui/floating_panel.gd"
## The Motion Study panel (spec 3.10, C6), floating over the Forge view.
##
## Top: the study (dropdown), New Study, Delete Study; Length (s), Frame Rate and Contact. Then the
## tracks: one per joint DOF with keys, drawn as diamonds on a time ruler with the playhead (click
## or drag on the ruler to scrub; click a key to select it, drag it to move it in time, Delete
## removes it). Add Key puts a key on the chosen track at the playhead with the value typed (empty:
## the DOF's value there). Footer: Play / Pause, Loop, the time and the status line (stops, clamps,
## warnings).
##
## Every edit is one undo step named after the study (workspace.change()). The frames are worked out
## up front after each change (core/assembly/motion.gd study_frames(), bounded by its 20 s);
## playing and scrubbing only show them (view-only). Closing the panel puts the stored poses back.

const DATA := preload("res://addons/holo_forge/core/assembly/assembly_data.gd")
const MOTION := preload("res://addons/holo_forge/core/assembly/motion.gd")
const JOINT_MATH := preload("res://addons/holo_forge/core/assembly/joint_math.gd")
const UI := preload("res://addons/holo_forge/ui/assembly_ui.gd")
const UNITS := preload("res://addons/holo_forge/core/units.gd")
const FINITE := preload("res://addons/holo_forge/tools/assemble_finite.gd")

## Track view sizes (pixels at 100%).
const RULER_PX := 20.0
const TRACK_PX := 20.0
const LABEL_PX := 110.0
const KEY_PX := 5.0
const TRACK_COLOR := Color(1, 1, 1, 0.06)
const KEY_COLOR := Color("#22b8cc")
const KEY_SELECTED := Color("#d14fc0")
const PLAYHEAD_COLOR := Color("#d14fc0")
## The contact stop's mark and sentence (assembly_contact), and the warnings' colour.
const STOP_COLOR := Color("#ff5d8f")
const NOTE_COLOR := Color(1.0, 0.82, 0.3)

## The Forge workspace (ui/forge_workspace.gd).
var workspace: Control
## The study shown ("" for none).
var study_id := ""
## The precomputed frames of the study (C6), and what study_frames() said with them.
var frames: Array = []
var frames_info := {}
## The playhead (seconds).
var time := 0.0
var playing := false
var looping := false
## The selected key: {"joint", "dof", "time"} ({} for none).
var selected_key := {}
## Why the last key from code was refused (a time or value that is not finite), shown until the
## next edit.
var _key_note := ""

var _study_menu: OptionButton
var _length: SpinBox
var _fps: SpinBox
var _contact: CheckBox
var _tracks: Control
var _track_menu: OptionButton
var _value: LineEdit
var _play: Button
var _loop: CheckBox
var _time_label: Label
var _status: Label
var _syncing := false
var _key_drag := {}


func _init(p_workspace: Control = null) -> void:
	super()
	workspace = p_workspace
	title = "Motion Study"
	min_content_size = Vector2(420, 160)
	var top := HBoxContainer.new()
	_study_menu = OptionButton.new()
	_study_menu.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_study_menu.item_selected.connect(func(index: int) -> void:
		study_id = str(_study_menu.get_item_metadata(index))
		selected_key = {}
		refresh())
	top.add_child(_study_menu)
	top.add_child(_button("New Study", "Adds a study (5 s, 30 frames per second).", new_study))
	top.add_child(_button("Delete Study", "Deletes the shown study.", delete_study))
	content.add_child(top)

	var settings := HBoxContainer.new()
	settings.add_child(_label("Length"))
	_length = _spin(MOTION.STUDY_LENGTH_MIN, MOTION.STUDY_LENGTH_MAX, 0.1, " s")
	_length.value_changed.connect(func(value: float) -> void: _set_field("length", value))
	settings.add_child(_length)
	settings.add_child(_label("Frame Rate"))
	_fps = _spin(MOTION.STUDY_FPS_MIN, MOTION.STUDY_FPS_MAX, 1.0, " fps")
	_fps.value_changed.connect(func(value: float) -> void: _set_field("fps", int(value)))
	settings.add_child(_fps)
	_contact = CheckBox.new()
	_contact.text = "Contact"
	_contact.tooltip_text = "Checks the contact sets along the study: it stops where their bodies touch, and every later frame holds there."
	_contact.toggled.connect(func(on: bool) -> void: _set_field("contact", on))
	settings.add_child(_contact)
	content.add_child(settings)

	_tracks = Control.new()
	_tracks.custom_minimum_size = Vector2(400, RULER_PX + TRACK_PX)
	_tracks.focus_mode = Control.FOCUS_CLICK
	_tracks.mouse_filter = Control.MOUSE_FILTER_STOP
	_tracks.draw.connect(_draw_tracks)
	_tracks.gui_input.connect(_tracks_input)
	content.add_child(_tracks)

	var keys := HBoxContainer.new()
	_track_menu = OptionButton.new()
	_track_menu.tooltip_text = "The joint motion a new key goes on (Add track)."
	_track_menu.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	keys.add_child(_track_menu)
	_value = LineEdit.new()
	_value.placeholder_text = "value"
	_value.tooltip_text = "The key's value; empty takes the motion's value at the playhead."
	_value.custom_minimum_size = Vector2(90, 0)
	_value.text_submitted.connect(func(_text: String) -> void: _add_key_here())
	keys.add_child(_value)
	keys.add_child(_button("Add Key", "Adds a key on the chosen track at the playhead.", _add_key_here))
	content.add_child(keys)

	var bar := HBoxContainer.new()
	_play = _button("Play", "Plays the worked-out frames (view-only).", toggle_play)
	bar.add_child(_play)
	_loop = CheckBox.new()
	_loop.text = "Loop"
	_loop.toggled.connect(func(on: bool) -> void: looping = on)
	bar.add_child(_loop)
	_time_label = Label.new()
	bar.add_child(_time_label)
	footer.add_child(bar)
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(380, 0)
	_status.add_theme_font_size_override("font_size", 12)
	footer.add_child(_status)
	set_process(false)


static func _label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	return label


static func _button(text: String, tip: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.tooltip_text = tip
	button.pressed.connect(action)
	return button


static func _spin(low: float, high: float, step: float, suffix: String) -> SpinBox:
	var spin := SpinBox.new()
	spin.min_value = low
	spin.max_value = high
	spin.step = step
	spin.suffix = suffix
	spin.custom_minimum_size = Vector2(84, 0)
	return spin


# --- The study ---------------------------------------------------------------------------------

func _assembly() -> Dictionary:
	var doc: Resource = workspace.doc if workspace != null else null
	return DATA.normalized(doc.assembly if doc != null and doc.assembly is Dictionary else {})


## The shown study's stored entry ({} for none).
func study() -> Dictionary:
	for entry in _assembly().studies:
		if entry is Dictionary and str(entry.get("id", "")) == study_id:
			return entry
	return {}


## Opens the panel on the first study (or none).
func open() -> void:
	visible = true
	refresh()


## Closes the panel: playback stops and the stored poses show again.
func close() -> void:
	playing = false
	set_process(false)
	visible = false
	if workspace != null and workspace.assembly_display != null:
		workspace.assembly_display.apply(workspace.viewport, workspace.assembly_solve)
		workspace.assembly_display.refresh(workspace.viewport, workspace.doc, workspace.assembly_solve)


## Works the frames out again (after any change to the document) and shows the playhead's frame.
func refresh() -> void:
	if not visible or workspace == null or workspace.doc == null:
		return
	var assembly := _assembly()
	if study().is_empty():
		study_id = str(assembly.studies[0].id) if not (assembly.studies as Array).is_empty() else ""
	_sync_controls(assembly)
	frames = []
	frames_info = {}
	if study_id != "":
		# A number that is not finite in what the study solves (its keys, the joints, links...) is
		# named instead of played (tools/assemble_finite.gd).
		var bad := FINITE.stored_sentence(assembly, workspace.doc, "", [study_id])
		if bad != "":
			frames_info = {"frames": [], "stopped_at": -1.0, "sentence": bad, "warnings": PackedStringArray()}
		else:
			frames_info = MOTION.study_frames(workspace.doc, workspace.result, workspace.kernel, study_id)
		frames = frames_info.get("frames", [])
	_status.text = status_text()
	# A stop, a timeout or a refusal (no frames) in the stop colour; warnings alone in amber.
	var stopped := float(frames_info.get("stopped_at", -1.0)) >= 0.0 or (study_id != "" and frames.is_empty() and str(frames_info.get("sentence", "")) != "")
	_status.modulate = STOP_COLOR if stopped else (NOTE_COLOR if not (frames_info.get("warnings", PackedStringArray()) as PackedStringArray).is_empty() else Color.WHITE)
	seek(time)


## The status line: the study's stop sentence (S-STUDY-STOP, S-CONTACT-TIMEOUT), its refusal
## (S-STUDY-TOO-SLOW, S-CONTACT-STEPS, S-CONTACT-TOO-SLOW) and its warnings (contact's, clamped
## keys, keys on followers).
func status_text() -> String:
	if study_id == "":
		return "No study yet: New Study makes one." if _key_note == "" else _key_note
	var lines := PackedStringArray()
	if _key_note != "":
		lines.append(_key_note)
	if str(frames_info.get("sentence", "")) != "":
		lines.append(str(frames_info.sentence))
	for warning in frames_info.get("warnings", PackedStringArray()):
		if not lines.has(str(warning)):
			lines.append(str(warning))
	if lines.is_empty() and bool(study().get("contact", false)):
		lines.append("Contact checked: nothing touches.")
	return "\n".join(lines)


## The time the study stops at for contact (-1 when it plays through).
func stopped_at() -> float:
	return float(frames_info.get("stopped_at", -1.0))


func _sync_controls(assembly: Dictionary) -> void:
	_syncing = true
	_study_menu.clear()
	for entry in assembly.studies:
		if entry is Dictionary:
			_study_menu.add_item(str(entry.get("name", entry.id)))
			_study_menu.set_item_metadata(_study_menu.item_count - 1, str(entry.id))
			if str(entry.id) == study_id:
				_study_menu.select(_study_menu.item_count - 1)
	var shown := study()
	_length.editable = not shown.is_empty()
	_fps.editable = not shown.is_empty()
	_contact.disabled = shown.is_empty()
	_length.value = float(shown.get("length", DATA.STUDY_DEFAULT.length))
	_fps.value = float(shown.get("fps", DATA.STUDY_DEFAULT.fps))
	_contact.set_pressed_no_signal(bool(shown.get("contact", false)))
	_track_menu.clear()
	for joint in assembly.joints:
		if not (joint is Dictionary):
			continue
		var names := DATA.dof_names(str(joint.get("type", "")))
		for i in names.size():
			if MOTION.study_key_refusal(assembly, str(joint.id), i) != "":
				continue
			var label := str(joint.get("name", joint.id))
			if names.size() > 1:
				label += " " + str(UI.DOF_LABELS.get(names[i], names[i]))
			_track_menu.add_item(label)
			_track_menu.set_item_metadata(_track_menu.item_count - 1, "%s|%d" % [str(joint.id), i])
	_tracks.custom_minimum_size.y = RULER_PX + TRACK_PX * maxf(_track_rows().size(), 1)
	_tracks.queue_redraw()
	_syncing = false


## One undo step named after the study: mutate gets the normalized assembly and the study entry
## (a copy the step stores). The workspace calls refresh() when the assembly has changed.
func _edit(mutate: Callable) -> void:
	if workspace == null or workspace.doc == null or study_id == "":
		return
	var name := str(study().get("name", study_id))
	var id := study_id
	_key_note = ""
	workspace.change(name, func() -> void:
		var assembly: Dictionary = DATA.normalized(workspace.doc.assembly)
		for entry in assembly.studies:
			if entry is Dictionary and str(entry.get("id", "")) == id:
				mutate.call(assembly, entry)
		workspace.doc.assembly = assembly)


func _set_field(key: String, value: Variant) -> void:
	if _syncing or study().is_empty() or study().get(key) == value:
		return
	_edit(func(_assembly_now: Dictionary, entry: Dictionary) -> void: entry[key] = value)


## Adds a study (one undo step named after it) and shows it.
func new_study() -> void:
	if workspace == null or workspace.doc == null:
		return
	var assembly := _assembly()
	var refused := DATA.edit_refusal(assembly)
	if refused != "":
		workspace.flash(refused)
		return
	var id := DATA.new_id(assembly, "study")
	var entry := DATA.STUDY_DEFAULT.duplicate(true)
	entry["id"] = id
	entry["name"] = DATA.name_for("study", id)
	study_id = id
	time = 0.0
	workspace.change(str(entry.name), func() -> void:
		var now: Dictionary = DATA.normalized(workspace.doc.assembly)
		DATA.new_id(now, "study")
		(now.studies as Array).append(entry)
		workspace.doc.assembly = now)


## Deletes the shown study ("Delete <Study>").
func delete_study() -> void:
	if study_id == "" or workspace == null:
		return
	var id := study_id
	var name := str(study().get("name", id))
	study_id = ""
	workspace.change("Delete %s" % name, func() -> void:
		var now: Dictionary = DATA.normalized(workspace.doc.assembly)
		now["studies"] = (now.studies as Array).filter(func(entry: Variant) -> bool: return not (entry is Dictionary and str(entry.get("id", "")) == id))
		workspace.doc.assembly = now)


## Puts a key on (joint_id, dof) at time t (seconds) with value (base units); a key already there
## takes the value. A key on a follower is refused (S-STUDY-FOLLOWER), and so is a time or value
## that is not a finite number (assemble_finite.gd S_KEY).
func add_key(joint_id: String, dof: int, t: float, value: float) -> void:
	var refused := ""
	if not is_finite(t):
		refused = FINITE.key_sentence("time", t)
	elif not is_finite(value):
		refused = FINITE.key_sentence("value", value)
	if refused != "":
		if workspace != null:
			workspace.flash(refused)
		_key_note = refused
		_status.text = status_text()
		_status.modulate = STOP_COLOR
		return
	if study_id == "":
		new_study()
	refused = MOTION.study_key_refusal(_assembly(), joint_id, dof)
	if refused != "":
		workspace.flash(refused)
		_status.text = refused
		return
	var at := clampf(t, 0.0, float(study().get("length", 5.0)))
	_edit(func(_assembly_now: Dictionary, entry: Dictionary) -> void:
		var keys: Array = entry.get("keys", [])
		for key in keys:
			if key is Dictionary and str(key.get("joint", "")) == joint_id and int(key.get("dof", 0)) == dof and float(key.get("time", 0.0)) == at:
				key["value"] = value
				return
		keys.append({"joint": joint_id, "dof": dof, "time": at, "value": value})
		entry["keys"] = keys)


## Removes the key at (joint_id, dof, t).
func remove_key(joint_id: String, dof: int, t: float) -> void:
	_edit(func(_assembly_now: Dictionary, entry: Dictionary) -> void:
		entry["keys"] = (entry.get("keys", []) as Array).filter(func(key: Variant) -> bool:
			return not (key is Dictionary and str(key.get("joint", "")) == joint_id and int(key.get("dof", 0)) == dof and float(key.get("time", 0.0)) == t)))
	selected_key = {}


## Moves the key at (joint_id, dof, from_t) to to_t. A move onto another key of the same DOF is
## refused (S-STUDY-KEY-TWICE: a motion cannot jump), and so is a time that is not finite.
func move_key(joint_id: String, dof: int, from_t: float, to_t: float) -> void:
	if not is_finite(to_t):
		_key_note = FINITE.key_sentence("time", to_t)
		_status.text = status_text()
		return
	var shown := study()
	var at := clampf(to_t, 0.0, float(shown.get("length", 5.0)))
	if at == from_t:
		return
	for key in shown.get("keys", []):
		if key is Dictionary and str(key.get("joint", "")) == joint_id and int(key.get("dof", 0)) == dof and float(key.get("time", 0.0)) == at:
			# (The sentence as MOTION.study_refusal() words it for the study with the key moved.)
			var moved: Dictionary = shown.duplicate(true)
			for other in moved.get("keys", []):
				if other is Dictionary and str(other.get("joint", "")) == joint_id and int(other.get("dof", 0)) == dof and float(other.get("time", 0.0)) == from_t:
					other["time"] = at
					break
			var refused := MOTION.study_refusal(_assembly(), moved, str(workspace.doc.units) if workspace != null and workspace.doc != null else "mm")
			if refused == "":
				refused = DATA.fill(DATA.S_STUDY_KEY_TWICE, {"Joint": str(_joint_entry(joint_id).get("name", joint_id)), "time": "%s s" % String.num(snappedf(at, 0.01)), "Study": str(shown.get("name", study_id))})
			if workspace != null:
				workspace.flash(refused)
			_key_note = refused
			_status.text = status_text()
			_status.modulate = STOP_COLOR
			return
	_edit(func(_assembly_now: Dictionary, entry: Dictionary) -> void:
		for key in entry.get("keys", []):
			if key is Dictionary and str(key.get("joint", "")) == joint_id and int(key.get("dof", 0)) == dof and float(key.get("time", 0.0)) == from_t:
				key["time"] = at
				return)
	selected_key = {"joint": joint_id, "dof": dof, "time": at}


func _add_key_here() -> void:
	if _track_menu.item_count == 0:
		_status.text = "There is no joint motion to key. Make a joint first."
		return
	var node := str(_track_menu.get_item_metadata(maxi(_track_menu.selected, 0))).split("|")
	var joint_id := node[0]
	var dof := int(node[1])
	var kind := UI.dof_kind(str(DATA.dof_names(_joint_type(joint_id))[dof]))
	var value := _value_at(joint_id, dof)
	if _value.text.strip_edges() != "":
		var r := UNITS.evaluate(_value.text, kind, str(workspace.doc.units), {})
		if not r.ok:
			_status.text = "Value: %s" % str(r.get("error", "not a value"))
			return
		value = float(r.value)
	add_key(joint_id, dof, time, value)


func _joint_type(joint_id: String) -> String:
	return str(_joint_entry(joint_id).get("type", ""))


## The stored joint entry with this id ({} when there is none).
func _joint_entry(joint_id: String) -> Dictionary:
	for joint in _assembly().joints:
		if joint is Dictionary and str(joint.get("id", "")) == joint_id:
			return joint
	return {}


## A DOF's value at the playhead (the frame's), else its stored value.
func _value_at(joint_id: String, dof: int) -> float:
	var frame := _frame_at(time)
	var values: Variant = (frame.get("values", {}) as Dictionary).get(joint_id) if not frame.is_empty() else null
	if values is PackedFloat64Array and dof < (values as PackedFloat64Array).size():
		return values[dof]
	for joint in _assembly().joints:
		if joint is Dictionary and str(joint.get("id", "")) == joint_id:
			return JOINT_MATH.joint_values(joint)[dof] if dof < (joint.dofs as Array).size() else 0.0
	return 0.0


# --- Playback ----------------------------------------------------------------------------------

func _frame_at(t: float) -> Dictionary:
	if frames.is_empty():
		return {}
	var fps := clampi(int(study().get("fps", 30)), MOTION.STUDY_FPS_MIN, MOTION.STUDY_FPS_MAX)
	return frames[clampi(roundi(t * fps), 0, frames.size() - 1)]


## Moves the playhead to t (seconds) and shows that frame's poses (view-only).
func seek(t: float) -> void:
	var length := float(study().get("length", 0.0))
	time = clampf(t, 0.0, length) if length > 0.0 else 0.0
	_time_label.text = "%.2f s / %.2f s" % [time, length]
	var frame := _frame_at(time)
	if not frame.is_empty() and workspace != null and workspace.assembly_display != null:
		workspace.assembly_display.apply(workspace.viewport, {"body_poses": frame.get("body_poses", {}), "poses": frame.get("poses", {})})
	_tracks.queue_redraw()


func toggle_play() -> void:
	playing = not playing and not frames.is_empty()
	if playing and time >= float(study().get("length", 0.0)):
		time = 0.0
	_play.text = "Pause" if playing else "Play"
	set_process(playing)


func _process(delta: float) -> void:
	if not playing or not visible:
		return
	var length := float(study().get("length", 0.0))
	var next := time + delta
	if next >= length:
		if looping:
			next = 0.0
		else:
			next = length
			playing = false
			_play.text = "Play"
			set_process(false)
	# Passing the contact stop says it in the status line too (the motion holds from there).
	var stop := stopped_at()
	if stop >= 0.0 and time < stop and next >= stop and workspace != null:
		workspace.flash(str(frames_info.get("sentence", "")))
	seek(next)


# --- Tracks ------------------------------------------------------------------------------------

## The tracks shown: every (joint, DOF) with keys, as [{"joint", "dof", "label", "keys": [[t, v]]}].
func _track_rows() -> Array:
	var rows := {}
	var order := []
	var assembly := _assembly()
	for key in study().get("keys", []):
		if not (key is Dictionary):
			continue
		var node := "%s|%d" % [str(key.get("joint", "")), int(key.get("dof", 0))]
		if not rows.has(node):
			var joint := {}
			for entry in assembly.joints:
				if entry is Dictionary and str(entry.get("id", "")) == str(key.get("joint", "")):
					joint = entry
			var names := DATA.dof_names(str(joint.get("type", "")))
			var label := str(joint.get("name", key.get("joint", "")))
			var dof := int(key.get("dof", 0))
			if names.size() > 1 and dof < names.size():
				label += " " + str(UI.DOF_LABELS.get(names[dof], names[dof]))
			rows[node] = {"joint": str(key.get("joint", "")), "dof": dof, "label": label, "marks": []}
			order.append(node)
		rows[node]["marks"].append([float(key.get("time", 0.0)), float(key.get("value", 0.0))])
	var out := []
	for node in order:
		out.append(rows[node])
	return out


func _x_of(t: float) -> float:
	var length := maxf(float(study().get("length", 5.0)), 0.001)
	return LABEL_PX + (_tracks.size.x - LABEL_PX - KEY_PX * 2.0) * (t / length) + KEY_PX


func _t_of(x: float) -> float:
	var length := maxf(float(study().get("length", 5.0)), 0.001)
	return clampf((x - LABEL_PX - KEY_PX) / maxf(_tracks.size.x - LABEL_PX - KEY_PX * 2.0, 1.0) * length, 0.0, length)


func _draw_tracks() -> void:
	var font := _tracks.get_theme_font("font", "Label")
	var font_size := 11
	# (The ink follows the theme's label colour, so the ruler and names read on light and dark.)
	var ink := Color(_tracks.get_theme_color("font_color", "Label"), 0.85)
	var length := float(study().get("length", 0.0))
	# The ruler: a tick each second.
	_tracks.draw_line(Vector2(LABEL_PX, RULER_PX - 1.0), Vector2(_tracks.size.x, RULER_PX - 1.0), Color(ink, 0.4))
	for s in int(floor(length)) + 1:
		var x := _x_of(float(s))
		_tracks.draw_line(Vector2(x, RULER_PX - 6.0), Vector2(x, RULER_PX - 1.0), Color(ink, 0.6))
		if font != null:
			_tracks.draw_string(font, Vector2(x + 2.0, RULER_PX - 7.0), "%d s" % s, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(ink, 0.7))
	var rows := _track_rows()
	for i in rows.size():
		var top := RULER_PX + TRACK_PX * i
		var row: Dictionary = rows[i]
		if i % 2 == 0:
			_tracks.draw_rect(Rect2(0.0, top, _tracks.size.x, TRACK_PX), Color(ink, TRACK_COLOR.a))
		if font != null:
			_tracks.draw_string(font, Vector2(4.0, top + TRACK_PX - 6.0), str(row.label), HORIZONTAL_ALIGNMENT_LEFT, LABEL_PX - 8.0, font_size, ink)
		for key: Array in row["marks"]:
			var c := Vector2(_x_of(float(key[0])), top + TRACK_PX * 0.5)
			var chosen: bool = str(selected_key.get("joint", "")) == str(row.joint) and int(selected_key.get("dof", -1)) == int(row.dof) and float(selected_key.get("time", -1.0)) == float(key[0])
			var diamond := PackedVector2Array([c + Vector2(0, -KEY_PX), c + Vector2(KEY_PX, 0), c + Vector2(0, KEY_PX), c + Vector2(-KEY_PX, 0)])
			_tracks.draw_colored_polygon(diamond, KEY_SELECTED if chosen else KEY_COLOR)
	# The contact stop: a mark at its time and the held part of the tracks shaded after it.
	var stop := stopped_at()
	if length > 0.0 and stop >= 0.0:
		var sx := _x_of(stop)
		_tracks.draw_rect(Rect2(sx, RULER_PX, maxf(_tracks.size.x - sx, 0.0), _tracks.size.y - RULER_PX), Color(STOP_COLOR, 0.12))
		_tracks.draw_line(Vector2(sx, 0.0), Vector2(sx, _tracks.size.y), STOP_COLOR, 2.0)
		if font != null:
			_tracks.draw_string(font, Vector2(sx + 3.0, RULER_PX + 11.0), "stop", HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, STOP_COLOR)
	if length > 0.0:
		var x := _x_of(time)
		_tracks.draw_line(Vector2(x, 0.0), Vector2(x, _tracks.size.y), PLAYHEAD_COLOR, 1.5)


## The key under a point ({"joint", "dof", "time"}, or {}).
func _key_at(at: Vector2) -> Dictionary:
	var rows := _track_rows()
	var i := int(floor((at.y - RULER_PX) / TRACK_PX))
	if at.y < RULER_PX or i < 0 or i >= rows.size():
		return {}
	for key: Array in rows[i]["marks"]:
		if absf(_x_of(float(key[0])) - at.x) <= KEY_PX + 2.0:
			return {"joint": str(rows[i].joint), "dof": int(rows[i].dof), "time": float(key[0])}
	return {}


func _tracks_input(event: InputEvent) -> void:
	var button := event as InputEventMouseButton
	if button != null and button.button_index == MOUSE_BUTTON_LEFT:
		if button.pressed:
			var key := _key_at(button.position)
			selected_key = key
			_key_drag = {"key": key, "scrub": key.is_empty()}
			if key.is_empty():
				seek(_t_of(button.position.x))
			_tracks.queue_redraw()
		else:
			if not (_key_drag.get("key", {}) as Dictionary).is_empty():
				var key: Dictionary = _key_drag.key
				move_key(str(key.joint), int(key.dof), float(key.time), snappedf(_t_of(button.position.x), 0.01))
			_key_drag = {}
		_tracks.accept_event()
		return
	var motion := event as InputEventMouseMotion
	if motion != null and bool(_key_drag.get("scrub", false)):
		seek(_t_of(motion.position.x))
		_tracks.accept_event()
		return
	var key_event := event as InputEventKey
	if key_event != null and key_event.pressed and key_event.keycode in [KEY_DELETE, KEY_BACKSPACE] and not selected_key.is_empty():
		remove_key(str(selected_key.joint), int(selected_key.dof), float(selected_key.time))
		_tracks.accept_event()
