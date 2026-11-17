@tool
extends "res://addons/holo_forge/tools/inspect_command.gd"
## Base for the Assemble commands (Holo Forge Phase 8, spec 3): Joint, As-built Joint, Joint
## Origin, Rigid Group, Drive Joints, Motion Link, Place Component and Contact Settings.
##
## They make no timeline feature. changes_document() is true, so OK is one undo step and Cancel
## puts the document back; but nothing is written while the panel is open: previews are view-only
## (a solve of a candidate assembly, shown with show_solve()). On OK the workspace calls
## apply_document(doc), which writes doc.assembly, and then records the step named action_name()
## (C1.4). end() puts the stored poses and glyphs back in the view.
##
## check() (each subclass) sets `refusal` (red in the status row; OK stays off, accept_error()
## returns it), `prompt` (what is still to pick: plain text, OK off) and `notes` (amber, OK
## allowed). An assembly saved by a newer Holo Forge refuses every tool (S-NEWER-ASSEMBLY).
##
## Snap slots (ui/assembly_ui.gd snap_slot_field) hold snap items: {"kind": "snap", "snap": a
## stored SNAP (core/assembly/snaps.gd make_snap), "body", "component", "label"}. A view pick
## reaches take_pick(); while a snap slot is active, hovering a face shows its snap candidates
## (handle_mouse()) and a click near one takes it.

const DATA := preload("res://addons/holo_forge/core/assembly/assembly_data.gd")
const XFORM := preload("res://addons/holo_forge/core/assembly/xform64.gd")
const SOLVER := preload("res://addons/holo_forge/core/assembly/solver.gd")
const SNAPS := preload("res://addons/holo_forge/core/assembly/snaps.gd")
const JOINT_MATH := preload("res://addons/holo_forge/core/assembly/joint_math.gd")
const MOTION := preload("res://addons/holo_forge/core/assembly/motion.gd")
const CONTACT := preload("res://addons/holo_forge/core/assembly/contact.gd")
const UI := preload("res://addons/holo_forge/ui/assembly_ui.gd")
const REFERENCES := preload("res://addons/holo_forge/core/references.gd")
const FINITE := preload("res://addons/holo_forge/tools/assemble_finite.gd")

## How each snap kind reads in a slot.
const KIND_LABELS := {
	"face_center": "Face Centre", "axis_mid": "Axis Middle", "axis_start": "Axis Start", "axis_end": "Axis End",
	"sphere_center": "Sphere Centre", "edge_mid": "Edge Middle", "vertex": "Vertex", "circle_center": "Circle Centre",
	"origin": "Joint Origin", "group_center": "Face Group Centre", "group_axis_mid": "Face Group Axis", "fixed": "Fixed Frame",
}
## How long Play Motion runs (C4.5).
const PLAY_SECONDS := 2.0
## A play whose legs used up the shared contact time (play_plan(); fix round 3, N-C).
const S_PLAY_OUT_OF_TIME := "Play Motion ran out of its <budget> of contact checking after <value>: checking the next part would take about <s>, more than the <left> left. The motion stopped there."
const REFUSAL_COLOR := Color(1.0, 0.45, 0.4)
const NOTE_COLOR := Color(1.0, 0.82, 0.3)

## The tool type ("assemble:joint", ...).
var type := ""
## Why OK is refused now ("" for none): shown in red.
var refusal := ""
## What is still to be picked ("" for nothing): shown plainly; OK stays off.
var prompt := ""
## Warnings that do not block OK: shown in amber.
var notes := PackedStringArray()
## The last view-only solve the command showed ({} for none).
var preview := {}
## Text a field showed for a stored double: key -> [text, value]. While the field still shows that
## text, value_of() gives the stored double itself (text keeps about 6 decimals).
var _shown := {}
## Snap candidates of the face under the cursor ({"kind", "ref", "face", "frame"}) and the one
## nearest the cursor (-1 none).
var _candidates: Array = []
var _hovered := -1
var _playing := false
## True once this update() showed a preview.
var _previewed := false
## What the last Play Motion said (its contact stop and warnings), and the values it played with:
## shown in the status row while the values are still those.
var play_notes := PackedStringArray()
var _play_values := {}


func _init(p_type := "") -> void:
	type = p_type


func changes_document() -> bool:
	return true


## Writes the command's result into doc.assembly (the workspace calls it on OK, then records the
## undo step).
func apply_document(_doc: Resource) -> void:
	pass


func accept_error() -> String:
	var newer := DATA.edit_refusal(_stored_assembly())
	if newer != "":
		return newer
	for field in fields():
		if str(field.type) == "expression" and _row_shown(field):
			var r := evaluate(str(current_values.get(field.key, "")), str(field.get("kind", "length")))
			if not r.ok:
				return "%s: %s" % [str(field.get("label", field.key)), str(r.get("error", "not a value"))]
	if refusal != "":
		return refusal
	return prompt


func update() -> void:
	refusal = ""
	prompt = ""
	notes = PackedStringArray()
	if workspace == null or workspace.doc == null:
		return
	_previewed = false
	var newer := DATA.edit_refusal(_stored_assembly())
	if newer != "":
		refusal = newer
	else:
		refusal = finite_refusal()
		if refusal == "":
			check()
	if not play_notes.is_empty():
		if current_values == _play_values:
			for note in play_notes:
				if not notes.has(note):
					notes.append(note)
		else:
			play_notes = PackedStringArray()
	if not _previewed and not preview.is_empty():
		# Nothing to preview any more (a pick taken away, a refusal): the stored poses show again.
		preview = {}
		_show_stored()
	show_status()


## Works out the preview and the refusal, prompt and notes from current_values (subclasses).
func check() -> void:
	pass


## The id of the stored entry this command edits ("" for none; Edit Joint, Place): its values come
## through the panel's fields, where the user can type over a bad one.
func editing_id() -> String:
	return ""


## A sentence about a number that is not finite (NaN, INF), "" when there is none: in the stored
## assembly the solve reads (assemble_finite.gd S_STORED; the edited entry excepted), or in a shown
## field (S_FIELD; typed text can't give one, a stored value shown there can). update() refuses
## with it instead of checking, so such a value never reaches a solve.
func finite_refusal() -> String:
	if workspace == null or workspace.doc == null:
		return ""
	var stored := FINITE.stored_sentence(_stored_assembly(), workspace.doc, editing_id())
	if stored != "":
		return stored
	for field in fields():
		if str(field.get("type", "")) != "expression" or not _row_shown(field):
			continue
		var key := str(field.get("key", ""))
		if _shown.has(key) and str(_shown[key][0]) == str(current_values.get(key, "")) and not is_finite(float(_shown[key][1])):
			return FINITE.field_sentence(str(field.get("label", key)), float(_shown[key][1]))
	return ""


## The status row's text now: the refusal, else the prompt, else the notes.
func status_text() -> String:
	if refusal != "":
		return refusal
	if prompt != "":
		return prompt
	return "\n".join(notes)


## Shows status_text() in the status row (red, plain or amber) and turns OK off while refused.
func show_status() -> void:
	var panel: Control = workspace.panel
	panel.set_info(UI.STATUS_KEY, status_text())
	var editors: Variant = panel.get("_editors")
	var label: Variant = (editors as Dictionary).get(UI.STATUS_KEY) if editors is Dictionary else null
	if label is Label:
		(label as Label).modulate = REFUSAL_COLOR if refusal != "" else (Color.WHITE if prompt != "" else NOTE_COLOR)
	if refusal != "" or prompt != "":
		panel.set_ok_enabled(false)


## Puts the stored poses and glyphs back in the view (the preview is view-only).
func end() -> void:
	_playing = false
	if workspace == null or workspace.viewport == null:
		return
	if workspace.assembly_display != null:
		workspace.assembly_display.set_candidates(workspace.viewport, [])
	_show_stored()


## The stored solve's poses and glyphs in the view, no ghost.
func _show_stored() -> void:
	var display: RefCounted = workspace.assembly_display
	if display == null:
		return
	display.show_ghost(workspace.viewport, [], {})
	display.apply(workspace.viewport, workspace.assembly_solve)
	display.refresh(workspace.viewport, workspace.doc, workspace.assembly_solve)


func on_button(key: String) -> void:
	if key == "play":
		play()


# --- The assembly ------------------------------------------------------------------------------

## The document's assembly as stored, normalized.
func _stored_assembly() -> Dictionary:
	var doc: Resource = workspace.doc if workspace != null else null
	return DATA.normalized(doc.assembly if doc != null and doc.assembly is Dictionary else {})


## A solve of the document with candidate as its assembly. View-only: the document gets its own
## assembly back before this returns.
func solve_with(candidate: Dictionary, overrides := {}) -> Dictionary:
	var doc: Resource = workspace.doc
	var held: Dictionary = doc.assembly
	doc.assembly = candidate
	var out := SOLVER.solve(doc, workspace.result, workspace.kernel, overrides)
	doc.assembly = held
	return out


## Shows a solve in the view: the holders take its poses, the glyphs are drawn for candidate (the
## assembly it was solved from; {} for the stored one).
func show_solve(solve_out: Dictionary, candidate := {}) -> void:
	preview = solve_out
	_previewed = true
	var display: RefCounted = workspace.assembly_display
	if display == null:
		return
	display.apply(workspace.viewport, solve_out)
	var doc: Resource = workspace.doc
	var held: Dictionary = doc.assembly
	if not candidate.is_empty():
		doc.assembly = candidate
	display.refresh(workspace.viewport, doc, solve_out)
	doc.assembly = held


## The ids of the bodies in a top-level unit ("" for the ground), nested components included.
func unit_bodies(unit: String) -> Array:
	var doc: Resource = workspace.doc
	var out := []
	for body_id in workspace.result.get("bodies", {}):
		var component: String = doc.body_component(str(body_id))
		if SOLVER.unit_of(doc.components, component) == unit:
			out.append(str(body_id))
	return out


## The box (part space, where the bodies show now) around a unit's bodies ("" for the ground).
func unit_box(unit: String) -> AABB:
	if workspace == null or workspace.assembly_display == null:
		return AABB()
	return workspace.assembly_display.call("_unit_box", workspace.viewport, workspace.doc, unit)


## The span a DOF's slider covers, as [low, high] in base units (doubles, spec 3.7): its limits
## where it has them; an open end goes to −360° / 360° for a turn and to ± the moving unit's box
## diagonal for a slide (at least 10 mm). An open end also reaches value (where the DOF is now),
## so the slider can always show it. [0, 0] for a DOF the joint does not have.
func dof_range(joint: Dictionary, i: int, value: float) -> PackedFloat64Array:
	var names := DATA.dof_names(str(joint.get("type", "")))
	if i < 0 or i >= names.size():
		return PackedFloat64Array([0.0, 0.0])
	var dofs: Array = joint.get("dofs", [])
	var dof: Dictionary = dofs[i] if i < dofs.size() and dofs[i] is Dictionary else DATA.DOF_DEFAULT
	var span := TAU
	if not DATA.is_rotation(str(names[i])):
		var unit := str((joint.get("a", {}) as Dictionary).get("component", ""))
		var box := unit_box(SOLVER.unit_of(workspace.doc.components, unit)) if workspace != null and workspace.doc != null else AABB()
		span = maxf(box.size.length(), 0.01)
	var on_lo := bool(dof.get("limited_min", false))
	var on_hi := bool(dof.get("limited_max", false))
	var low := float(dof.get("min", 0.0)) if on_lo else minf(-span, value)
	var high := float(dof.get("max", 0.0)) if on_hi else maxf(span, value)
	return PackedFloat64Array([low, high])


## Where a body sits now (its stored pose), or a component's when body is "" (identity for the
## ground and for anything not posed).
func pose_of(body: String, component := "") -> PackedFloat64Array:
	var solve_out: Dictionary = workspace.assembly_solve
	var pose: Variant = (solve_out.get("body_poses", {}) as Dictionary).get(body) if body != "" else (solve_out.get("poses", {}) as Dictionary).get(component)
	return PackedFloat64Array(pose) if pose is PackedFloat64Array and (pose as PackedFloat64Array).size() == 12 else XFORM.identity()


## Panel values for fields(): numbers holds values by key (base units for expressions; each
## expression's "default" otherwise); expressions are remembered, so untouched fields give back
## the exact doubles.
func values_for(numbers: Dictionary) -> Dictionary:
	var out := {}
	for field in fields():
		var key := str(field.get("key", ""))
		var given: Variant = numbers.get(key, field.get("default"))
		match str(field.get("type", "")):
			"expression":
				remember(out, key, float(given) if given != null else 0.0, str(field.get("kind", "length")))
			"selection":
				out[key] = (given as Array).duplicate(true) if given is Array else []
			"info", "button":
				pass
			"enum":
				if given == null and not (field.get("options", []) as Array).is_empty():
					given = field.options[0][0]
				out[key] = given
			_:
				if given != null:
					out[key] = given
	return out


## A component's display name ("the ground" for "").
func comp_name(component_id: String) -> String:
	return workspace.doc.component_name(component_id) if component_id != "" else "the ground"


## The stored entry of a list by id ({} when gone).
static func entry_of(assembly: Dictionary, list: String, id: String) -> Dictionary:
	for entry in assembly.get(list, []):
		if entry is Dictionary and str(entry.get("id", "")) == id:
			return entry
	return {}


# --- Fields ------------------------------------------------------------------------------------

## An expression field's value in base units: the stored double while the field still shows the
## text it was given for it (remember()), else the text evaluated; fallback when it doesn't
## evaluate, or when the value is not a finite number (finite_refusal() says so).
func value_of(values: Dictionary, key: String, kind: String, fallback := 0.0) -> float:
	var text := str(values.get(key, ""))
	var value := fallback
	if _shown.has(key) and str(_shown[key][0]) == text:
		value = float(_shown[key][1])
	else:
		var r := evaluate(text, kind)
		value = float(r.value) if r.ok else fallback
	return value if is_finite(value) else fallback


## Puts value (base units) in values[key] as text and remembers the exact double behind it.
func remember(values: Dictionary, key: String, value: float, kind: String) -> void:
	var text := UI.text(value, kind, doc_units())
	values[key] = text
	_shown[key] = [text, value]


func _row_shown(field: Dictionary) -> bool:
	var condition: Variant = field.get("visible_if", {})
	if not (condition is Dictionary):
		return true
	for other in condition:
		if not (condition[other] as Array).has(current_values.get(other)):
			return false
	return true


# --- Snap slots --------------------------------------------------------------------------------

## A slot item for a stored snap (made again on the result shown, so its frame is current).
func snap_item(snap: Dictionary) -> Dictionary:
	var kind := str(snap.get("kind", ""))
	if kind == "origin":
		return origin_item(str(snap.get("origin", "")))
	var made := snap.duplicate(true)
	if kind != SNAPS.FIXED and workspace != null:
		var extra := {}
		if snap.get("face") is Dictionary:
			extra["face"] = snap.face
		if snap.get("at_pick") is Array and (snap.at_pick as Array).size() == 3:
			extra["at"] = Vector3(float(snap.at_pick[0]), float(snap.at_pick[1]), float(snap.at_pick[2]))
		var again := SNAPS.make_snap(kind, snap.get("ref", {}) if snap.get("ref") is Dictionary else {}, workspace.result, workspace.doc, extra)
		if again.has("snap"):
			made = again.snap
	var body := str(made.get("body", ""))
	var doc: Resource = workspace.doc
	return {
		"kind": "snap", "snap": made, "body": body, "component": doc.body_component(body) if body != "" else "",
		"label": "%s: %s" % [doc.body_name(body) if body != "" else "Frame", KIND_LABELS.get(kind, kind)],
	}


## A slot item for a Joint Origin ({} when it is gone).
func origin_item(origin_id: String) -> Dictionary:
	var assembly := _stored_assembly()
	var origin := entry_of(assembly, "origins", origin_id)
	if origin.is_empty():
		return {}
	var made := SNAPS.make_snap("origin", {}, workspace.result, workspace.doc, {"origin": origin_id, "assembly": assembly})
	var snap: Dictionary = made.get("snap", {"kind": "origin", "origin": origin_id, "body": "", "ref": {}, "frame": XFORM.identity()})
	var origin_snap: Dictionary = origin.get("snap", {})
	return {
		"kind": "snap", "snap": snap, "body": str(origin_snap.get("body", "")), "component": str(origin.get("component", "")),
		"label": str(origin.get("name", origin_id)),
	}


## The snap kind a plain pick stands for: a face's centre (flat), axis middle (round) or sphere
## centre; an edge's circle centre (round) or middle; a vertex; a mesh face group's centre.
func default_kind(ref: Dictionary) -> String:
	var ctx := {"bodies": workspace.result.get("bodies", {}), "doc": workspace.doc}
	match str(ref.get("kind", "")):
		"face":
			var found := REFERENCES.face(ref, ctx)
			if found.has("error"):
				return "face_center"
			var info: Dictionary = found.shape.face_info(int(found.index))
			match str(info.get("type", "")):
				"cylinder", "cone":
					return "axis_mid"
				"sphere":
					return "sphere_center"
			return "face_center"
		"edge":
			var found := REFERENCES.edge(ref, ctx)
			if found.has("error"):
				return "edge_mid"
			var info: Dictionary = found.shape.edge_info(int(found.index))
			return "circle_center" if str(info.get("type", "")) in ["circle", "arc"] else "edge_mid"
		"vertex":
			return "vertex"
		"mesh_group":
			return "group_center"
	return ""


## A view pick (a REFERENCES reference, or a picker pick of a face, edge or vertex) for the snap
## slot key: its slot item, or {"error"}.
func take_pick(_key: String, ref: Dictionary) -> Dictionary:
	if ref.has("index") and not ref.has("name") and str(ref.get("kind", "")) in ["face", "edge", "vertex"]:
		var named := REFERENCES.from_pick(ref, workspace.result)
		if not named.is_empty():
			ref = named
	var kind := default_kind(ref)
	if kind == "":
		return {"error": "Pick a face, an edge or a vertex of a component."}
	var made := SNAPS.make_snap(kind, ref, workspace.result, workspace.doc)
	if made.has("error") and kind == "group_center":
		made = SNAPS.make_snap("group_axis_mid", ref, workspace.result, workspace.doc)
	if made.has("error"):
		return {"error": str(made.error)}
	return snap_item(made.snap)


## A snap candidate (SNAPS.candidates entry) as a slot item, or {"error"}.
func take_candidate(candidate: Dictionary) -> Dictionary:
	var made := SNAPS.make_snap(str(candidate.kind), candidate.ref, workspace.result, workspace.doc, {"face": candidate.get("face", {})})
	if made.has("error"):
		return {"error": str(made.error)}
	return snap_item(made.snap)


## The first item of a slot ({} when empty).
static func first_item(values: Dictionary, key: String) -> Dictionary:
	var list: Variant = values.get(key, [])
	if list is Array and not (list as Array).is_empty() and list[0] is Dictionary:
		return list[0]
	return {}


## The more specific snap kinds first: of two candidates on the same point, only the one listed
## earlier here is offered (a plate's face centre on its hole's centre shows as the circle centre).
const KIND_ORDER := ["circle_center", "sphere_center", "axis_mid", "axis_start", "axis_end", "group_axis_mid", "vertex", "edge_mid", "face_center", "group_center"]


## Candidates with one mark per point: where marks would lie on top of each other (they could not
## be told apart on screen), the more specific kind (KIND_ORDER) stays.
static func _distinct(candidates: Array) -> Array:
	var out := []
	for candidate in candidates:
		var frame: PackedFloat64Array = candidate.get("frame", PackedFloat64Array())
		var at := Vector3(frame[9], frame[10], frame[11]) if frame.size() == 12 else Vector3.INF
		var rank := KIND_ORDER.find(str(candidate.get("kind", "")))
		rank = KIND_ORDER.size() if rank < 0 else rank
		var kept := true
		for i in out.size():
			var other: PackedFloat64Array = out[i].get("frame", PackedFloat64Array())
			if other.size() != 12 or not at.is_finite() or Vector3(other[9], other[10], other[11]).distance_to(at) > 1e-9:
				continue
			var other_rank := KIND_ORDER.find(str(out[i].get("kind", "")))
			other_rank = KIND_ORDER.size() if other_rank < 0 else other_rank
			if rank < other_rank:
				out[i] = candidate
			kept = false
			break
		if kept:
			out.append(candidate)
	return out


## While a snap slot is active: hovering a face shows its snap candidates (the nearest one bigger),
## and a click near one takes it. Other events go on to the picker.
func handle_mouse(event: InputEvent) -> bool:
	if workspace == null or workspace.assembly_display == null:
		return false
	var field: Dictionary = workspace.panel.active_field()
	var viewport: Control = workspace.viewport
	if not bool(field.get("snap", false)):
		if not _candidates.is_empty():
			_candidates = []
			_hovered = -1
			workspace.assembly_display.set_candidates(viewport, [])
		return false
	var motion := event as InputEventMouseMotion
	if motion != null:
		var hit: Dictionary = viewport.face_hit_at(motion.position)
		_candidates = []
		if not hit.is_empty() and workspace.result.get("bodies", {}).has(str(hit.get("body", ""))):
			# (A view hit gives its face as "face", core/picking.gd ray_hit().)
			_candidates = _distinct(SNAPS.candidates(workspace.result, str(hit.body), int(hit.get("face", hit.get("index", -1))), workspace.doc))
		var marks := []
		for candidate in _candidates:
			var frame: PackedFloat64Array = candidate.frame
			marks.append({"kind": candidate.kind, "body": str(candidate.ref.get("body", hit.get("body", ""))), "at": Vector3(frame[9], frame[10], frame[11])})
		workspace.assembly_display.set_candidates(viewport, marks)
		_hovered = workspace.assembly_display.candidate_at(viewport, motion.position)
		workspace.assembly_display.set_candidates(viewport, marks, _hovered)
		return false
	var button := event as InputEventMouseButton
	if button != null and button.pressed and button.button_index == MOUSE_BUTTON_LEFT and _hovered >= 0 and _hovered < _candidates.size():
		var item := take_candidate(_candidates[_hovered])
		if item.has("error"):
			workspace.call("_flash", str(item.error))
		else:
			workspace.panel.add_selection(item)
		return true
	return false


# --- Play Motion (C4.5) ------------------------------------------------------------------------

## The joint Play Motion moves ({} for none) and the assembly it is solved in.
func play_joint() -> Dictionary:
	return {}


func play_assembly() -> Dictionary:
	return _stored_assembly()


## The motion Play Motion plays, worked out before it starts (C4.5): {"joint", "assembly",
## "tracks": per DOF the values it passes through (evenly over the play, 0..1), "split_times": the
## times of the tracks' keys (0..1), "stop": where on 0..1 it stops (1: it plays through),
## "sentence" (the contact stop's, S-CONTACT-STOP or S-CONTACT-TIMEOUT, or the refusal,
## S-CONTACT-STEPS / S-CONTACT-TOO-SLOW, or a value that is not finite), "warnings" (the sweep's:
## S-CONTACT-NO-SETS, -START, -THIN, -DEV, -SKIPPED), "point" (world; the stop's), "refused"}.
## {} when there is nothing to play.
## Every track starts and ends at the DOF's value now, so the play never jumps (and S-CONTACT-START
## is about the pose the user sees): a limited DOF goes to its max, then its min, then back (an
## open end goes the unlimited span past the value); an unlimited rotation a full turn and back,
## an unlimited slide half the moving unit's box diagonal each way and back.
## Followers move through the joint's Motion Links as in a drive (MOTION.move()).
## With contact on (Enable Contact Sets) the motion is swept first (core/assembly/contact.gd, C5),
## leg by leg between the tracks' key times (split_times: each track is straight between them, so
## a turn-around is never missed), so it stops where a drive would; each leg gets the turn between
## two times (turn_between, through links: a slide driving a turn counts that turn).
func play_plan() -> Dictionary:
	var joint := play_joint()
	if joint.is_empty() or workspace == null or workspace.doc == null:
		return {}
	var assembly := play_assembly()
	var unit := str((joint.get("a", {}) as Dictionary).get("component", ""))
	var box := unit_box(SOLVER.unit_of(workspace.doc.components, unit))
	var reach := maxf(box.size.length() * 0.5, 0.01)
	var tracks := []
	var gains := []
	var split := {0.0: true, 1.0: true}
	var names := DATA.dof_names(str(joint.get("type", "")))
	var out := {
		"joint": joint, "assembly": assembly, "tracks": tracks, "split_times": PackedFloat64Array(), "stop": 1.0, "sentence": "",
		"warnings": PackedStringArray(), "point": PackedFloat64Array(), "refused": false,
	}
	var bad := FINITE.stored_sentence(assembly, workspace.doc)
	if bad == "" and not names.is_empty():
		# What a drive would refuse (a suppressed or waiting joint, a missing component, reversed
		# limits, an empty or broken link) plays nothing either: asked with the joint's own value,
		# without contact, MOTION.drive() says so before it moves anything.
		var kept: Dictionary = workspace.doc.assembly
		workspace.doc.assembly = assembly
		var probe := MOTION.drive(workspace.doc, workspace.result, workspace.kernel, str(joint.id), 0, float(JOINT_MATH.joint_values(joint)[0]), {"contact": false})
		workspace.doc.assembly = kept
		if bool(probe.get("refused", false)) and str(probe.get("stopped_by", "")) == "":
			bad = str(probe.get("sentence", "")) if str(probe.get("sentence", "")) != "" else "This joint cannot be played now."
	if bad != "":
		out["stop"] = 0.0
		out["refused"] = true
		out["sentence"] = bad
		return out
	for i in names.size():
		var dof: Dictionary = joint.dofs[i]
		var on_lo := bool(dof.get("limited_min", false))
		var on_hi := bool(dof.get("limited_max", false))
		var rotation := DATA.is_rotation(str(names[i]))
		var span := TAU if rotation else reach
		var value := JOINT_MATH.clamp_value(dof, float(dof.get("value", 0.0)))
		var track: Array
		if not on_lo and not on_hi:
			track = [value, value + span, value] if rotation else [value, value + span, value - span, value]
		else:
			var low := float(dof.min) if on_lo else value - span
			var high := float(dof.max) if on_hi else value + span
			track = [value]
			for next in [high, low, value]:
				if float(next) != float(track[track.size() - 1]):
					track.append(next)
			if track.size() < 2:
				track.append(value)
		tracks.append(track)
		for k in track.size():
			split[float(k) / float(track.size() - 1)] = true
	var times := PackedFloat64Array(split.keys())
	times.sort()
	out["split_times"] = times
	if not bool((assembly.get("contact", {}) as Dictionary).get("enabled", false)):
		return out
	var doc: Resource = workspace.doc
	var units := doc_units()
	var held: Dictionary = doc.assembly
	doc.assembly = assembly
	# Per DOF, how far the parts in contact turn per unit of it (MOTION.turn_rate(): through the
	# DOF's link root, so a follower counts its driver's whole tree; only turns a contact pair sees).
	for i in tracks.size():
		gains.append(MOTION.turn_rate(doc, workspace.result, workspace.kernel, str(joint.id), i, assembly))
	var groups := _dof_groups(joint, tracks.size(), assembly, units)
	# (Followers move through the joint's Motion Links as a drive moves them.)
	var path := func(t: float) -> Dictionary:
		return SOLVER.solve(doc, workspace.result, workspace.kernel, _play_overrides(joint, tracks, t, assembly, units)).body_poses
	# The turn from a to b, measured on the values the play really gives the joint (_played_values():
	# a DOF that follows another of the joint takes that one's values, and its own track never
	# applies, fix round 4, NP1); DOFs of one link tree count once (each one's rate times its change
	# is the same tree's turn). Between two split times every track is straight, so the turn is the
	# change at the ends.
	var turn_between := func(a: float, b: float) -> float:
		var at_a := _played_values(joint, tracks, a, assembly, units)
		var at_b := _played_values(joint, tracks, b, assembly, units)
		var per_group := {}
		for i in tracks.size():
			var turned := absf(at_b[i] - at_a[i]) * float(gains[i])
			per_group[groups[i]] = maxf(float(per_group.get(groups[i], 0.0)), turned)
		var most := 0.0
		for group in per_group:
			most += float(per_group[group])
		return most
	var format := func(t: float) -> String: return _play_text(joint, tracks, t, units, assembly)
	# Each leg (between two split times) is swept as a drive of that leg would be, in order, until
	# one stops; the legs share one deadline. (A whole play can be far longer than any drive of it:
	# a fast follower turns through every leg.) A leg a drive would refuse refuses the play.
	var deadline := Time.get_ticks_usec() + int(MOTION.CONTACT_SECONDS * 1e6)
	var warnings := PackedStringArray()
	var swept := {}
	for k in range(1, times.size()):
		var left := float(deadline - Time.get_ticks_usec()) / 1e6
		if left <= 0.0:
			swept = {"stopped": true, "timed_out": true, "reached": times[k - 1], "sentence": DATA.fill(DATA.S_CONTACT_TIMEOUT, {"value": format.call(times[k - 1])})}
			break
		swept = CONTACT.sweep(doc, workspace.result, workspace.kernel, path, times[k - 1], times[k], {
			"assembly": assembly, "seconds": left, "deadline_usec": deadline, "turn_between": turn_between, "format": format,
		})
		for warning in swept.get("warnings", PackedStringArray()):
			if not warnings.has(warning):
				warnings.append(warning)
		# A later leg refused only because the earlier ones used the time: the play stops where the
		# checked part ended, and says so.
		var out_of_time := _out_of_time(swept, k, MOTION.CONTACT_SECONDS, left, format.call(times[k - 1]))
		if out_of_time != "":
			swept = {"stopped": true, "timed_out": true, "reached": times[k - 1], "sentence": out_of_time}
			break
		if bool(swept.get("refused", false)) or bool(swept.get("stopped", false)):
			break
	doc.assembly = held
	out["warnings"] = warnings
	if bool(swept.get("refused", false)):
		out["stop"] = 0.0
		out["refused"] = true
		out["sentence"] = str(swept.sentence)
	elif bool(swept.get("stopped", false)):
		out["stop"] = clampf(float(swept.reached), 0.0, 1.0)
		out["sentence"] = str(swept.sentence)
		out["point"] = swept.get("point", PackedFloat64Array())
	return out


## The sentence for a play leg the shared contact deadline cut short (fix round 3, N-C): a leg after
## the first (k > 1) refused for time (S-CONTACT-TOO-SLOW: its "estimate" or "estimate_again")
## although that estimate fits the play's budget was refused only because the legs before it used
## the time. "" otherwise: a true refusal (too many steps or turns, a leg too slow on its own, the
## first leg) stays as the sweep worded it.
static func _out_of_time(swept: Dictionary, k: int, budget: float, left: float, at_text: String) -> String:
	if k < 2 or not bool(swept.get("refused", false)):
		return ""
	var estimate := maxf(float(swept.get("estimate", 0.0)), float(swept.get("estimate_again", 0.0)))
	if not (estimate > 0.0) or estimate > budget:
		return ""
	return DATA.fill(S_PLAY_OUT_OF_TIME, {"budget": _seconds_text(budget), "value": at_text, "s": _seconds_text(estimate, 0.01), "left": _seconds_text(maxf(left, 0.0), 0.01)})


## Seconds as a sentence shows them ("5 s", "2.1 s"), to the given step.
static func _seconds_text(seconds: float, step := 0.1) -> String:
	var text := String.num(snappedf(seconds, step), 2 if step < 0.1 else 1)
	if text.contains("."):
		text = text.rstrip("0").rstrip(".")
	return text + " s"


## The solver overrides of a play at t (0..1): {joint id: {dof: value}}. With the play's assembly
## (normalized) every DOF is moved as MOTION.drive() moves it (MOTION.move(): through its Motion
## Links, so followers move with it, and within the link tree's limits); without one only the
## played joint is set.
static func _play_overrides(joint: Dictionary, tracks: Array, t: float, assembly := {}, units := "mm") -> Dictionary:
	var id := str(joint.id)
	if assembly.is_empty():
		var forced := {}
		for i in tracks.size():
			forced[i] = MOTION.track_value(_spread(tracks[i]), t)
		return {id: forced}
	var working: Dictionary = assembly
	var values := {}
	for i in tracks.size():
		var moved: Dictionary = MOTION.move(working, id, i, MOTION.track_value(_spread(tracks[i]), t), units)
		if str(moved.get("error", "")) != "":
			continue
		for moved_id in moved.values:
			values[moved_id] = moved.values[moved_id]
		if i < tracks.size() - 1:
			# (The next DOF moves from where this one left the joints.)
			working = working.duplicate(true)
			for moved_id in moved.values:
				var entry := entry_of(working, "joints", str(moved_id))
				var list: PackedFloat64Array = moved.values[moved_id]
				for d in mini(list.size(), (entry.get("dofs", []) as Array).size()):
					entry.dofs[d]["value"] = list[d]
	var out := {}
	for moved_id in values:
		var forced := {}
		var list: PackedFloat64Array = values[moved_id]
		for d in list.size():
			forced[d] = list[d]
		out[str(moved_id)] = forced
	return out


## The played joint's DOF values at t (0..1) as the play gives them (_play_overrides(): through
## its Motion Links, so a DOF that follows another takes that one's values; a DOF the overrides
## leave out reads its track). Without an assembly, the tracks' values.
static func _played_values(joint: Dictionary, tracks: Array, t: float, assembly := {}, units := "mm") -> PackedFloat64Array:
	var out := PackedFloat64Array()
	var forced: Dictionary = (_play_overrides(joint, tracks, t, assembly, units).get(str(joint.id), {}) if not assembly.is_empty() else {}) as Dictionary
	for i in tracks.size():
		out.append(float(forced[i]) if forced.has(i) else MOTION.track_value(_spread(tracks[i]), t))
	return out


## Which DOFs of the played joint move together (one Motion Link tree): per DOF a group number, the
## same for DOFs one of which moves the other (MOTION.move() of one by a small step, either way,
## changes the other). Without links each DOF is its own group.
static func _dof_groups(joint: Dictionary, count: int, assembly: Dictionary, units := "mm") -> PackedInt32Array:
	var groups := PackedInt32Array()
	for i in count:
		groups.append(i)
	var id := str(joint.id)
	var stored := JOINT_MATH.joint_values(entry_of(assembly, "joints", id) if not assembly.is_empty() else joint)
	for i in count:
		for step in [1e-3, -1e-3]:
			var moved: Dictionary = MOTION.move(assembly, id, i, float(stored[i]) + step, units)
			if str(moved.get("error", "")) != "" or not (moved.values as Dictionary).has(id):
				continue
			var list: PackedFloat64Array = moved.values[id]
			for j in mini(count, list.size()):
				if j != i and absf(list[j] - float(stored[j])) > 1e-12:
					# (Merge j's group into i's.)
					var from := groups[j]
					for n in count:
						if groups[n] == from:
							groups[n] = groups[i]
	return groups


## The joint's DOF values at t (0..1) of a play, as a sentence's value ("42.5°", "12 mm, 30°"):
## the values the play gives the joint (_played_values(); with the play's assembly, the moved ones).
static func _play_text(joint: Dictionary, tracks: Array, t: float, units: String, assembly := {}) -> String:
	var values := _played_values(joint, tracks, t, assembly, units)
	var parts := PackedStringArray()
	for i in tracks.size():
		parts.append(JOINT_MATH.format_dof(str(joint.get("type", "")), i, values[i], units))
	return ", ".join(parts)


## Plays the joint's motion in the view over PLAY_SECONDS (view-only), along play_plan()'s tracks:
## from the DOF's value now, a limited DOF to its max, its min and back; an unlimited rotation one
## full turn and back, an unlimited slide half the moving unit's box diagonal each way and back.
## Motion Link followers move with it, as in a drive. With contact on it stops where the sweep stopped (the
## contact point flashes) and holds there; the stop sentence and the sweep's warnings stay in the
## status row until a value changes. Then the preview shows again.
func play() -> void:
	if _playing or workspace == null or not workspace.is_inside_tree():
		return
	var plan := play_plan()
	if plan.is_empty():
		return
	var joint: Dictionary = plan.joint
	var assembly: Dictionary = plan.assembly
	var tracks: Array = plan.tracks
	var stop := float(plan.stop)
	var units := doc_units()
	play_notes = PackedStringArray()
	if str(plan.sentence) != "":
		play_notes.append(str(plan.sentence))
	for warning in plan.warnings:
		if not play_notes.has(str(warning)):
			play_notes.append(str(warning))
	_play_values = current_values.duplicate(true)
	for note in play_notes:
		if not notes.has(note):
			notes.append(note)
	show_status()
	_playing = true
	var flashed := false
	var started := Time.get_ticks_msec()
	var tree: SceneTree = workspace.get_tree()
	while _playing and workspace.command == self:
		var t := float(Time.get_ticks_msec() - started) / (PLAY_SECONDS * 1000.0)
		if t >= 1.0:
			break
		show_solve(solve_with(assembly, _play_overrides(joint, tracks, minf(t, stop), assembly, units)), assembly)
		if t >= stop and not flashed:
			flashed = true
			var point: PackedFloat64Array = plan.point
			if point.size() == 3 and workspace.assembly_display != null:
				workspace.assembly_display.flash_contact(workspace.viewport, Vector3(point[0], point[1], point[2]))
		await tree.process_frame
	_playing = false
	if workspace.command == self:
		update()


## Values spread evenly over 0..1 as a track ([[time, value]]).
static func _spread(values: Array) -> Array:
	var out := []
	for i in values.size():
		out.append([float(i) / float(maxi(values.size() - 1, 1)), float(values[i])])
	return out
