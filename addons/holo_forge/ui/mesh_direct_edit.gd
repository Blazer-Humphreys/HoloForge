@tool
extends RefCounted
## Direct Edit (Mesh > Modify): an editor tool that changes one mesh body's triangles by hand,
## outside the timeline, and keeps the result as one snapshot feature.
##
## It works on a copy of the body's mesh (`working`, a CadMesh; every step makes a new one), shown
## in place of the body while the tool is open. The triangles to work on are the Mesh selection
## (ui/mesh_selection.gd, switched to Triangles while the tool is open). The small panel over the
## view has:
##   Delete      takes the selected triangles out
##   Fill Holes  closes the holes Delete made (a minimal fill; holes the body had before stay)
##   Flip        turns the selected triangles' normals round
##   Extract     moves the selected triangles into a new body
##   Move        shows three arrows on the selection: dragging one moves the selected triangles'
##               vertices along it (vertices shared with their neighbours move too)
##   Done        writes one feature, one undo step "Forge: Mesh: Direct Edit"; Cancel writes nothing
## Each button applies at once and is one step on the tool's own undo stack: Ctrl+Z takes the
## last step back while the tool is open (Enter is Done, Escape is Cancel, Delete is Delete).
##
## What Done stores (add_snapshot(); the mesh feature handler builds from it):
##   type "mesh", options.method "direct_edit"
##   options.bodies        [{"kind": "body", "body": id}]: the edited body
##   options.mesh          a MeshBlob of the result (meters, part space): the body becomes this
##   options.input_digest  CadMesh.digest() of the body's mesh when the tool opened; a rebuild
##                         whose incoming body has another digest lost an earlier change (the
##                         handler warns)
##   options.steps         the steps taken, in order: "delete", "fill", "flip", "extract", "move"
##   options.outputs       the ids of the bodies Extract made (registered in the document)
##   options["extract_<k>"]  a MeshBlob per output k (the extracted triangles as their own mesh)
## Delete with a triangle selection outside the tool (the Delete action) stores the same with
## steps ["delete"], as one undo step "Forge: Mesh: Delete Triangles".

const MESH_BODY := preload("res://addons/holo_forge/core/mesh/mesh_body.gd")
const MESH_BLOB := preload("res://addons/holo_forge/core/mesh/mesh_blob.gd")
const MESH_SELECTION := preload("res://addons/holo_forge/ui/mesh_selection.gd")
const TESSELLATE := preload("res://addons/holo_forge/core/tessellate.gd")
const FLOATING_PANEL := preload("res://addons/holo_forge/ui/floating_panel.gd")

const METHOD := "direct_edit"
const UNDO_NAME := "Mesh: Direct Edit"
const DELETE_UNDO_NAME := "Mesh: Delete Triangles"
const BUTTONS := [
	["delete", "Delete", "Take the selected triangles out (Delete)"],
	["fill", "Fill Holes", "Close the holes Delete made"],
	["flip", "Flip", "Turn the selected triangles' normals round"],
	["extract", "Extract", "Move the selected triangles into a new body"],
	["move", "Move", "Drag an arrow to move the selected triangles' vertices"],
]
const SELECT_FIRST := "Select triangles first (click, or drag a window over them)."
const AXES := {"x": Vector3.RIGHT, "y": Vector3.UP, "z": Vector3.BACK}

var workspace: Object
var viewport: Control
var active := false
## The body being edited and its mesh as it stands (a CadMesh; null when the tool is closed).
var body_id := ""
var working: RefCounted
## The steps taken so far, in order.
var steps := PackedStringArray()
## The meshes Extract took out so far (CadMesh), in order.
var extracted := []
var panel: FLOATING_PANEL

var _input_digest := ""
var _mode_before := MESH_SELECTION.GROUPS
## Undo stack: [{"mesh", "steps", "extracted", "made_points"}] before each step.
var _undo := []
## Points on the edges of the holes Delete made (so Fill Holes closes those and no others).
var _made_points := {}
var _buttons := {}
var _info: Label
var _moving := false
## The move in progress: the arrow dragged and how far (meters), shown as a ghost until released.
var _move_axis := ""
var _move_amount := 0.0
var _ghost: MeshInstance3D
var _tess := {}


func _init(p_workspace: Object, p_viewport: Control) -> void:
	workspace = p_workspace
	viewport = p_viewport


## Opens the tool on a mesh body. Returns "" or why it can't.
func begin(p_body_id: String) -> String:
	if active:
		done()
	var found: Dictionary = (workspace.result.get("bodies", {}) as Dictionary).get(p_body_id, {})
	if not MESH_BODY.is_mesh(found):
		return "Direct Edit works on mesh bodies. Select one first."
	body_id = p_body_id
	working = found.shape
	_input_digest = str(working.digest())
	steps = PackedStringArray()
	extracted = []
	_undo = []
	_made_points = {}
	_moving = false
	active = true
	var selection: RefCounted = workspace.mesh_selection
	_mode_before = selection.mode
	# Only this body's triangles can be worked on.
	for other in selection.bodies():
		if other != body_id:
			selection.set_triangles(other, PackedInt32Array(), null)
	selection.set_mode(MESH_SELECTION.TRIANGLES, workspace.mesh_shapes())
	_make_panel()
	panel.visible = true
	panel.place(Vector2(10, 44))
	refresh()
	return ""


## Done: the edit becomes one feature (one undo step); nothing is written when no step was taken.
func done() -> void:
	if not active:
		return
	var id := body_id
	var result_mesh := working
	var taken := steps.duplicate()
	var pieces := extracted.duplicate()
	var digest := _input_digest
	_close()
	if taken.is_empty():
		workspace.refresh_bodies()
		return
	var doc_holder: Object = workspace
	workspace.change(UNDO_NAME, func() -> void:
		add_snapshot(doc_holder.doc, id, result_mesh, digest, taken, pieces))
	workspace.flash("Direct Edit kept %d step%s as one feature." % [taken.size(), "" if taken.size() == 1 else "s"])


## Cancel: the body stays as it was.
func cancel() -> void:
	if not active:
		return
	_close()
	workspace.refresh_bodies()


## Adds the snapshot feature of an edited body to doc (call it inside one document change).
## pieces: the CadMesh of each extracted part. Returns the feature, or null when a mesh that has
## triangles can't be stored (nothing is added then). A result with no triangle left is written as
## "emptied": true with no "mesh" key (a "mesh" key that is missing without it is an error of the
## feature: core/features/mesh.gd); an extracted part with no triangles is left out.
static func add_snapshot(doc: Resource, edited_body: String, mesh: RefCounted, input_digest: String, taken: PackedStringArray, pieces: Array = []) -> Resource:
	var blob: Resource = MESH_BLOB.from_mesh(mesh)
	var emptied: bool = mesh != null and bool(mesh.is_null())
	if blob == null and not emptied:
		return null
	# Every extracted part is stored before anything is added: one that can't be would otherwise
	# leave a feature without it.
	var stored := []
	for part in pieces:
		if part == null or bool((part as RefCounted).is_null()):
			continue
		var piece_blob: Resource = MESH_BLOB.from_mesh(part)
		if piece_blob == null:
			return null
		stored.append(piece_blob)
	var options := {
		"method": METHOD, "bodies": [{"kind": "body", "body": edited_body}], "input_digest": input_digest,
		"steps": taken.duplicate(), "outputs": [],
	}
	if blob != null:
		options["mesh"] = blob
	else:
		options["emptied"] = true
	var feature: Resource = doc.add_feature("mesh", "DirectEdit", {}, options)
	var outputs := []
	for piece in stored:
		var made: String = doc.new_body(feature.id)
		doc.bodies[made]["name"] = "%s (extract %d)" % [MESH_BODY.body_name(doc, edited_body), outputs.size() + 1]
		feature.options["extract_%d" % outputs.size()] = piece
		outputs.append(made)
	feature.options["outputs"] = outputs
	return feature


## Shows the working mesh in place of the body (after a step, or when the design was rebuilt
## under the tool). The tool closes when its body is gone.
func refresh() -> void:
	if not active:
		return
	var bodies: Dictionary = workspace.result.get("bodies", {})
	if not bodies.has(body_id):
		_close()
		return
	_tess = TESSELLATE.tessellate(working) if working != null and not working.is_null() else {}
	workspace.show_bodies_with({body_id: {"tess": _tess, "shape": working}})
	_update_panel()
	_update_handles()


## The view's tessellation of the working mesh.
func tessellation() -> Dictionary:
	return _tess


# --- Steps -----------------------------------------------------------------------------------

## A panel button, or its key: "delete", "fill", "flip", "extract", "move", "done", "cancel".
## Returns "" or why nothing happened (also shown in the status line).
func press(key: String) -> String:
	if not active:
		return ""
	var why := ""
	match key:
		"delete":
			why = _delete()
		"fill":
			why = _fill()
		"flip":
			why = _flip()
		"extract":
			why = _extract()
		"move":
			why = _toggle_move()
		"done":
			done()
		"cancel":
			cancel()
	if why != "":
		workspace.flash(why)
	return why


## Takes the last step back. Returns false when there is none.
func undo() -> bool:
	if not active or _undo.is_empty():
		return false
	var before: Dictionary = _undo.pop_back()
	working = before.mesh
	steps = before.steps
	extracted = before.extracted
	_made_points = before.made_points
	workspace.mesh_selection.set_triangles(body_id, PackedInt32Array(), null)
	refresh()
	workspace.flash("Direct Edit: took the last step back (%d left)." % _undo.size())
	return true


## Keys while the tool is open: Ctrl+Z, Enter, Escape, Delete. True when the key was used.
func handle_key(event: InputEventKey) -> bool:
	if not active or not event.pressed or event.echo:
		return false
	if (event.ctrl_pressed or event.meta_pressed) and not event.shift_pressed and event.keycode == KEY_Z:
		if not undo():
			workspace.flash("Direct Edit has no step to take back.")
		return true
	if event.ctrl_pressed or event.alt_pressed or event.meta_pressed:
		return false
	match event.keycode:
		KEY_ENTER, KEY_KP_ENTER:
			done()
			return true
		KEY_ESCAPE:
			if _moving:
				_toggle_move()
			else:
				cancel()
			return true
		KEY_DELETE, KEY_BACKSPACE:
			press("delete")
			return true
	return false


## A Move arrow is being dragged (the view's manipulator_changed): shows the selection moved.
func on_handle(handle: Dictionary, value: Variant) -> void:
	if not active or not _moving or not AXES.has(str(handle.get("key", ""))):
		return
	_move_axis = str(handle.key)
	_move_amount = float(value)
	_show_ghost()
	_update_handles()


## The drag ended: the move becomes a step.
func on_handle_released(_handle: Dictionary) -> void:
	if not active or not _moving or _move_axis == "":
		return
	var offset: Vector3 = AXES[_move_axis] * _move_amount
	_move_axis = ""
	_move_amount = 0.0
	_hide_ghost()
	if offset.length() > 1e-12:
		var why := move_selection(offset)
		if why != "":
			workspace.flash(why)
	_update_handles()


## Moves the selected triangles' vertices by offset (one step). Returns "" or why not.
func move_selection(offset: Vector3) -> String:
	var selected := _selected()
	if selected.is_empty():
		return SELECT_FIRST
	var arrays: Dictionary = working.get_arrays()
	var positions: PackedVector3Array = arrays.positions
	var indices: PackedInt32Array = arrays.indices
	var moved := {}
	for t in selected:
		for k in 3:
			moved[indices[t * 3 + k]] = true
	for v in moved:
		positions[v] += offset
	var next: RefCounted = MESH_BODY.new_mesh()
	if next == null or not next.set_arrays(positions, indices, arrays.groups, arrays.group_names, "godot"):
		return "The triangles could not be moved: %s" % (str(next.get_last_error()) if next != null else MESH_BODY.KERNEL_MISSING)
	_step("move", next)
	# The same triangles stay selected (their indices did not change).
	workspace.mesh_selection.set_triangles(body_id, selected, working)
	refresh()
	return ""


func _delete() -> String:
	var selected := _selected()
	if selected.is_empty():
		return SELECT_FIRST
	if selected.size() >= int(working.triangle_count()):
		return "That would delete the whole body. Use Delete on the body instead."
	var before_points := _boundary_points(working)
	var next: RefCounted = working.delete_triangles(selected)
	if next == null:
		return str(working.get_last_error())
	_step("delete", next)
	# The edges of the new holes: every open-edge point that was not one before.
	for point in _boundary_points(next):
		if not before_points.has(point):
			_made_points[point] = true
	workspace.mesh_selection.set_triangles(body_id, PackedInt32Array(), null)
	refresh()
	return ""


func _fill() -> String:
	var loops := PackedInt32Array()
	for loop in working.boundary_loops():
		for point in (loop.points as PackedVector3Array):
			if _made_points.has(point):
				loops.append(int(loop.id))
				break
	if loops.is_empty():
		return "There are no holes made by Delete to fill."
	var next: RefCounted = working.close_holes({"fill": "minimal", "loops": loops})
	if next == null:
		return str(working.get_last_error())
	_step("fill", next)
	_made_points = {}
	workspace.mesh_selection.set_triangles(body_id, PackedInt32Array(), null)
	refresh()
	return ""


func _flip() -> String:
	var selected := _selected()
	if selected.is_empty():
		return SELECT_FIRST
	var next: RefCounted = working.reverse({"mode": "selection", "triangles": selected})
	if next == null:
		return str(working.get_last_error())
	_step("flip", next)
	workspace.mesh_selection.set_triangles(body_id, selected, working)
	refresh()
	return ""


func _extract() -> String:
	var selected := _selected()
	if selected.is_empty():
		return SELECT_FIRST
	var count := int(working.triangle_count())
	if selected.size() >= count:
		return "Every triangle is selected: there would be nothing left of the body."
	var chosen := {}
	for t in selected:
		chosen[t] = true
	var others := PackedInt32Array()
	for t in count:
		if not chosen.has(t):
			others.append(t)
	var piece: RefCounted = working.delete_triangles(others)
	if piece == null:
		return str(working.get_last_error())
	var rest: RefCounted = working.delete_triangles(selected)
	if rest == null:
		return str(working.get_last_error())
	_step("extract", rest)
	extracted = extracted.duplicate()
	extracted.append(piece)
	workspace.mesh_selection.set_triangles(body_id, PackedInt32Array(), null)
	refresh()
	return ""


func _toggle_move() -> String:
	if not _moving and _selected().is_empty():
		return SELECT_FIRST
	_moving = not _moving
	_move_axis = ""
	_move_amount = 0.0
	_hide_ghost()
	_update_panel()
	_update_handles()
	return ""


## Puts the mesh before a step on the undo stack and makes next the working mesh.
func _step(name: String, next: RefCounted) -> void:
	_undo.append({"mesh": working, "steps": steps.duplicate(), "extracted": extracted.duplicate(), "made_points": _made_points.duplicate()})
	working = next
	steps = steps.duplicate()
	steps.append(name)


func _selected() -> PackedInt32Array:
	return workspace.mesh_selection.triangles_of(body_id)


static func _boundary_points(mesh: RefCounted) -> Dictionary:
	var points := {}
	for loop in mesh.boundary_loops():
		for point in (loop.points as PackedVector3Array):
			points[point] = true
	return points


# --- Panel and handles -----------------------------------------------------------------------

func _make_panel() -> void:
	if panel != null and is_instance_valid(panel):
		return
	panel = FLOATING_PANEL.new()
	panel.title = "DIRECT EDIT"
	panel.min_content_size = Vector2(150, 40)
	viewport.add_child(panel)
	for spec in BUTTONS:
		var button := Button.new()
		button.text = spec[1]
		button.tooltip_text = spec[2]
		button.focus_mode = Control.FOCUS_NONE
		button.toggle_mode = spec[0] == "move"
		button.pressed.connect(press.bind(spec[0]))
		panel.content.add_child(button)
		_buttons[spec[0]] = button
	_info = Label.new()
	_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_info.custom_minimum_size = Vector2(150, 0)
	_info.add_theme_font_size_override("font_size", 12)
	panel.content.add_child(_info)
	var row := HBoxContainer.new()
	for spec in [["done", "Done", "Keep the edit as one feature (Enter)"], ["cancel", "Cancel", "Leave the body as it was (Esc)"]]:
		var button := Button.new()
		button.text = spec[1]
		button.tooltip_text = spec[2]
		button.focus_mode = Control.FOCUS_NONE
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.pressed.connect(press.bind(spec[0]))
		row.add_child(button)
		_buttons[spec[0]] = button
	panel.footer.add_child(row)
	apply_theme(workspace.theme_colors)


## The panel's buttons by key (for tests).
func buttons() -> Dictionary:
	return _buttons


func apply_theme(colors: Dictionary) -> void:
	if panel != null and is_instance_valid(panel) and colors.has("panel_style"):
		panel.apply_style(colors.panel_style)
		if _info != null:
			_info.add_theme_color_override("font_color", (colors.panel_style as Dictionary).get("title_text", Color.WHITE))


func _update_panel() -> void:
	if panel == null or not is_instance_valid(panel) or working == null:
		return
	var selected := _selected().size()
	var lines := PackedStringArray()
	lines.append("%s: %s" % [workspace.doc.body_name(body_id) if workspace.doc != null else body_id, workspace.counted(int(working.triangle_count()), "triangle")])
	lines.append("%d selected" % selected)
	if not steps.is_empty():
		lines.append("%d step%s (Ctrl+Z takes one back)" % [steps.size(), "" if steps.size() == 1 else "s"])
	_info.text = "\n".join(lines)
	(_buttons.move as Button).set_pressed_no_signal(_moving)
	(_buttons.fill as Button).disabled = _made_points.is_empty()


## The Mesh selection changed while the tool is open.
func on_selection_changed() -> void:
	if not active:
		return
	if _moving and _selected().is_empty():
		_moving = false
	_update_panel()
	_update_handles()


func _update_handles() -> void:
	var handles: Array[Dictionary] = []
	if active and _moving:
		# The three arrows start at the middle of the selection, where it is shown now (during a
		# drag: moved along the dragged arrow).
		var center := _selection_center()
		if _move_axis != "":
			center += AXES[_move_axis] * _move_amount
		for key in AXES:
			var along: float = _move_amount if key == _move_axis else 0.0
			handles.append({"type": "arrow", "key": key, "origin": center, "direction": AXES[key],
				"factor": 1.0, "base": along, "min": -1e9})
	viewport.set_handles(handles)


## The middle of the selected triangles (of their corners), on the working mesh.
func _selection_center() -> Vector3:
	var selected := _selected()
	var indices: PackedInt32Array = _tess.get("indices", PackedInt32Array())
	var positions: PackedVector3Array = _tess.get("positions", PackedVector3Array())
	if selected.is_empty() or indices.is_empty():
		return (working.bbox() as AABB).get_center() if working != null else Vector3.ZERO
	var box := AABB(positions[indices[selected[0] * 3]], Vector3.ZERO)
	for t in selected:
		if t * 3 + 2 < indices.size():
			for k in 3:
				box = box.expand(positions[indices[t * 3 + k]])
	return box.get_center()


func _show_ghost() -> void:
	if _ghost == null or not is_instance_valid(_ghost):
		_ghost = MeshInstance3D.new()
		_ghost.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		viewport.camera().get_parent().add_child(_ghost)
	_ghost.mesh = viewport.mesh_display.selection_mesh(_tess, _selected())
	_ghost.material_override = viewport.mesh_display.materials.preview
	_ghost.position = AXES[_move_axis] * _move_amount if _move_axis != "" else Vector3.ZERO
	_ghost.visible = true


func _hide_ghost() -> void:
	if _ghost != null and is_instance_valid(_ghost):
		_ghost.visible = false


func _close() -> void:
	active = false
	_moving = false
	_hide_ghost()
	if _ghost != null and is_instance_valid(_ghost):
		_ghost.queue_free()
	_ghost = null
	var none: Array[Dictionary] = []
	viewport.set_handles(none)
	if panel != null and is_instance_valid(panel):
		panel.visible = false
	var selection: RefCounted = workspace.mesh_selection
	selection.set_triangles(body_id, PackedInt32Array(), null)
	working = null
	_undo = []
	_tess = {}
	body_id = ""
	selection.set_mode(_mode_before, workspace.mesh_shapes())
