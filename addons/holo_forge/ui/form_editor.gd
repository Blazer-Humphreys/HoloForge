@tool
extends RefCounted
## The Form environment (contract C6): a contextual mode of the Forge tab for sculpting smooth
## freeform bodies by pushing and pulling a coarse control cage.
##
## begin(feature) opens a form feature (the timeline stops after it, nothing is converted while
## it is open); end() (Finish Form) converts every cage through the rebuild and returns to the
## user's workspace. In between the editor owns the cage selection, picking, one native CadSubD per
## body (the limit surface's tessellation, ray hits, visibility), the display meshes
## (ui/form_display.gd), the Edit Form gizmo (ui/form_gizmo.gd) and the tool engine that runs the
## registry's tools (ui/form_tools.gd, contract C7) with live previews on scratch cages. Every
## tool's OK, every gizmo drag release and every typed transform is one undo step; display modes are
## view-only steps. Selection is editor state, never stored in the document.

const CAGE := preload("res://addons/holo_forge/core/form/cage.gd")
const FORM_OPS := preload("res://addons/holo_forge/core/form/form_ops.gd")
const FORM := preload("res://addons/holo_forge/core/features/form.gd")
const FORM_TOOLS := preload("res://addons/holo_forge/ui/form_tools.gd")
const FORM_GIZMO := preload("res://addons/holo_forge/ui/form_gizmo.gd")
const FORM_DISPLAY := preload("res://addons/holo_forge/ui/form_display.gd")
const PICKING := preload("res://addons/holo_forge/core/picking.gd")
const UNITS := preload("res://addons/holo_forge/core/units.gd")
const MANIPULATOR := preload("res://addons/holo_forge/core/manipulator_math.gd")
const FLOATING_PANEL := preload("res://addons/holo_forge/ui/floating_panel.gd")
const FORGE_THEME := preload("res://addons/holo_forge/ui/forge_theme.gd")

## Screen distance (pixels) within which a vertex or edge is picked.
const PICK_RADIUS_PX := 7.0
## A press becomes a drag once the mouse is this far (pixels) from it.
const DRAG_START_PX := 5.0
## Count handles change their count by one per this many pixels dragged.
const COUNT_PX := 20.0
const ENTER_MESSAGE := "Form: select cage faces, edges or vertices. Finish Form converts the bodies. Measure and analyses see form bodies only after Finish."
const NO_SELECTION := "Select cage faces, edges or vertices to edit."
const OPEN_FIRST := "Open a form first: Create Form (Solid > Create) or double-click a Form in the timeline."
const DISPLAY_LABELS := {"box": "Box", "frame": "Control Frame", "smooth": "Smooth"}
## What the interactive Finish Form shows while the bodies convert.
const CONVERTING_MESSAGE := "Converting form bodies..."
## Frames the interactive Finish Form waits after showing CONVERTING_MESSAGE before converting, so
## the message is drawn before the (synchronous, slow) rebuild.
const FINISH_DELAY_FRAMES := 2
## The gap (pixels at 100% scale) the command panel keeps from the gizmo and the view's edges.
const PANEL_GAP := 10.0
## The shortest the command panel is made when it goes under the gizmo (its rows scroll).
const PANEL_MIN_HEIGHT := 160.0

var workspace: Object
var viewport: Control
var active := false
## True while a workspace command (Measure, a construction plane, a sketch) runs over the form:
## the meshes stay, the mouse goes to the command until resume().
var suspended := false
var feature: Resource
var feature_id := ""
## [{"kind": "vertex"|"edge"|"face"|"body", "body": id, "index": int, "pair": Vector2i (edges)}]
var selection: Array[Dictionary] = []
var hover := {}
## The running tool's id ("" for none; "edit_form" while the gizmo is up).
var tool := ""
var tool_values := {}
var tool_picks := {}
## A tool's own working state (a primitive's plane and clicks).
var tool_state := {}
## "fine" (auto rate, approx level 4) or "draft" (half the rate, approx level 2).
var display_quality := "fine"
## Editor scale override (tests); 0 = the editor's own (pick radii, drag thresholds, the gizmo and
## overlay line widths all scale with it).
var ui_scale := 0.0
var show_symmetry := true
## The palette ("FORM"): display modes, display and conversion quality, symmetry, Finish Form.
var palette: FLOATING_PANEL
var theme_colors := FORGE_THEME.palette("dark")
var gizmo := FORM_GIZMO.new()
var display := FORM_DISPLAY.new()
## The last drag frame's cost in milliseconds (handle_mouse motion through the mesh update).
var last_drag_ms := 0.0
## How many times the display meshes were rebuilt (for tests).
var display_build_count := 0

## body id -> {"subd", "cage", "topo", "topo_hash", "content_hash", "nV", "tess", "error",
## "version", "bounds", "diag", ...} for the stored (effective) cages.
var _subd := {}
## body id -> scratch cage shown instead of the stored one while a tool previews ("__new<k>" for
## bodies the tool would add).
var _preview := {}
## The same entries as _subd for the preview cages.
var _preview_entries := {}
## Stored bodies the previewed tool would remove (left out of the view while it previews).
var _preview_hidden := {}
var _drag := {}
var _prev_selection: Array[Dictionary] = []
var _partners: Array[Dictionary] = []
## body id -> soft-modification weights shown (Edit Form with Soft Modification on).
var _soft := {}
var _value_errors := {}
var _last_preview_error := ""
var _overlay_cache := {}
var _overlay_valid := false
var _mesh_entries := {}
var _palette_buttons := {}
var _palette_quality: OptionButton
var _palette_conversion: OptionButton
var _palette_symmetry: CheckBox
var _finish_button: Button
var _handles: Array = []
## The select-through setting from before a tool that forces it on ("select_through" in its
## spec) started; null while no tool forces it.
var _restore_select_through: Variant = null
var _version := 0
var _drag_hover_handle := ""
## The form an interactive Finish Form converts a few frames from now ("" for none).
var _finish_pending := ""
## A deferred command-panel check is queued (see _queue_panel_check): "home" places the panel
## from its own spot, "keep" only moves it off the gizmo; "" for none.
var _panel_check := ""


func _init(p_workspace: Object, p_viewport: Control) -> void:
	workspace = p_workspace
	viewport = p_viewport
	_build_palette()
	if viewport.has_signal("camera_changed"):
		viewport.camera_changed.connect(_on_camera_changed)
	# The pointer leaving the view clears the hover (the view clears its own the same way).
	var overlay: Variant = viewport.get("_overlay")
	if overlay is Control:
		(overlay as Control).mouse_exited.connect(_on_mouse_exited)


func _ui_scale() -> float:
	if ui_scale > 0.0:
		return ui_scale
	return EditorInterface.get_editor_scale() if Engine.is_editor_hint() else 1.0


## The running tool's title ("" when none).
func tool_title() -> String:
	return str(FORM_TOOLS.spec(tool).get("title", tool)) if tool != "" else ""


func _on_mouse_exited() -> void:
	if not active or hover.is_empty() and _drag_hover_handle == "":
		return
	hover = {}
	_drag_hover_handle = ""
	_refresh_meshes()
	viewport.redraw_overlay()


# --- Enter, leave, refresh -------------------------------------------------------------------

## Opens a form feature in the Form environment.
func begin(f: Resource) -> void:
	var doc: Resource = workspace.doc
	if doc == null or f == null:
		return
	if doc.feature_index(f.id) >= doc.active_count():
		workspace.flash("Move the timeline marker past %s to edit it." % f.label)
		return
	if active and feature_id == f.id:
		return
	if active:
		end_without_recompute()
	# An interactive Finish still waiting to convert: this begin rebuilds the preview instead.
	_finish_pending = ""
	if workspace.sketch_editor != null and workspace.sketch_editor.active:
		workspace.sketch_editor.end()
	active = true
	suspended = false
	gizmo.px = _ui_scale()
	feature = f
	feature_id = f.id
	selection.clear()
	hover = {}
	_drag = {}
	workspace.form_preview = f.id
	var forms: Dictionary = workspace.result.get("forms", {})
	if not bool((forms.get(f.id, {}) as Dictionary).get("preview", false)):
		workspace.recompute()
	if not active:
		return
	viewport.mouse_handler = handle_mouse
	workspace.toolbar.set_workspace("Form", true)
	palette.visible = true
	_sync_palette()
	refresh(workspace.result)
	workspace.flash(ENTER_MESSAGE)


## Finish Form: ends any tool, commits a drag, leaves the environment and rebuilds without the
## preview, which converts every cage body and bakes. No undo step.
func end() -> void:
	if not active:
		return
	var fid := feature_id
	_leave()
	workspace.form_preview = ""
	workspace.flash(CONVERTING_MESSAGE)
	workspace.recompute()
	workspace.flash(finish_message(fid))


## The interactive Finish Form (the palette's FINISH FORM button, the toolbar's Finish Form, the
## marking menu): like end(), but it shows CONVERTING_MESSAGE and converts FINISH_DELAY_FRAMES
## frames later, so the message is drawn before the slow rebuild. end() stays synchronous for the
## workspace's own callers (another tool, another feature, Create Form) and the tests.
func finish() -> void:
	if not active:
		return
	var fid := feature_id
	_leave()
	workspace.form_preview = ""
	workspace.flash(CONVERTING_MESSAGE)
	_finish_pending = fid
	var tree: SceneTree = viewport.get_tree() if viewport != null and viewport.is_inside_tree() else null
	if tree != null:
		for i in FINISH_DELAY_FRAMES:
			await tree.process_frame
	_finish_conversion(fid)


## The deferred half of finish(): the rebuild and the finish message, unless a form was opened
## meanwhile (its begin() rebuilt the preview itself).
func _finish_conversion(fid: String) -> void:
	if _finish_pending != fid or not is_instance_valid(workspace):
		return
	_finish_pending = ""
	if active or str(workspace.form_preview) != "":
		return
	workspace.recompute()
	workspace.flash(finish_message(fid))


## True between an interactive Finish Form and its conversion.
func is_finishing() -> bool:
	return _finish_pending != ""


## Leaves the environment without the rebuild (the part changes, or the form is gone).
func end_without_recompute() -> void:
	if not active:
		return
	_leave()
	workspace.form_preview = ""


func _leave() -> void:
	_close_command()
	cancel_tool()
	_commit_drag()
	viewport.set_form_meshes([])
	_mesh_entries.clear()
	viewport.mouse_handler = Callable()
	palette.visible = false
	active = false
	suspended = false
	selection.clear()
	hover = {}
	_partners.clear()
	_soft.clear()
	_subd.clear()
	_preview.clear()
	_preview_entries.clear()
	gizmo.visible = false
	workspace.toolbar.set_workspace(workspace.workspace)
	feature = null
	feature_id = ""
	viewport.redraw_overlay()


## What Finish Form says after the conversion.
func finish_message(fid: String) -> String:
	var summary: Dictionary = workspace.result.get("forms", {}).get(fid, {})
	var f: Resource = workspace.doc.find_feature(fid) if workspace.doc != null else null
	if f == null:
		return "Form finished."
	var bodies: Array = summary.get("bodies", FORM.body_ids(f))
	var errors: Dictionary = summary.get("errors", {})
	if not errors.is_empty():
		var names := PackedStringArray()
		for body_id in errors:
			names.append("%s (%s)" % [workspace.doc.body_name(body_id), errors[body_id]])
		return "Form finished with errors: %s. Repair Body can fix most cage problems." % ", ".join(names)
	var converted := bodies.size() + (f.options.get("breps", {}) as Dictionary).size()
	if converted == 0:
		return "Form finished (empty)"
	var text := "Form finished: %d bod%s converted" % [converted, "y" if converted == 1 else "ies"]
	# Conversion warnings (flat or folded cages, self-intersections) name the body.
	var warning := str((workspace.result.get("warnings", {}) as Dictionary).get(fid, ""))
	if warning != "" and not warning.ends_with("converted by sewing (slower path)"):
		text += ". Check: %s. Repair Body can fix most cage problems." % warning
	return text


## A workspace command opens over the form: a drag is committed, hover clears, the meshes stay.
func suspend() -> void:
	if not active or suspended:
		return
	_commit_drag()
	suspended = true
	hover = {}
	if viewport.mouse_handler == Callable(self, "handle_mouse"):
		viewport.mouse_handler = Callable()
	_refresh_meshes()
	viewport.redraw_overlay()


## The command over the form closed: the form takes the mouse back (and its tool its panel).
func resume() -> void:
	if not active:
		return
	suspended = false
	viewport.mouse_handler = handle_mouse
	workspace.toolbar.set_workspace("Form", true)
	if tool != "":
		_show_tool_panel()
	viewport.redraw_overlay()


func _close_command() -> void:
	if suspended and workspace.command != null:
		workspace.cancel_command()


## After every rebuild: finds the feature again, syncs each body's CadSubD with its cage (new body:
## a new instance; topology changed: set_cage; positions changed: set_positions), drops elements
## that are gone from the selection and redraws.
func refresh(_result: Dictionary) -> void:
	if not active:
		return
	var doc: Resource = workspace.doc
	feature = doc.find_feature(feature_id) if doc != null else null
	if feature == null or feature.type != "form":
		end_without_recompute()
		# The form went (an undo): show the rebuild with its bake.
		workspace._queue_recompute()
		return
	var ctx := _links_ctx()
	var bodies: Dictionary = feature.options.get("bodies", {})
	for body_id in bodies:
		_sync_entry(_subd, str(body_id), FORM.effective_cage(bodies[body_id], ctx))
	for body_id in _subd.keys():
		if not bodies.has(body_id):
			_subd.erase(body_id)
	_prune_selection()
	if tool != "" and tool != "edit_form":
		_sync_picks()
		_update_preview()
	_update_partners()
	_update_gizmo()
	_update_soft()
	_overlay_valid = false
	_refresh_meshes()
	# Undo and redo can change the conversion quality and display modes the palette shows.
	_sync_palette()
	viewport.redraw_overlay()


## Display-mode change only: rebuilds the meshes without touching the CadSubD caches.
func refresh_view() -> void:
	if not active:
		return
	feature = workspace.doc.find_feature(feature_id)
	if feature == null:
		return
	_overlay_valid = false
	_mesh_entries.clear()
	_refresh_meshes()
	_sync_palette()
	viewport.redraw_overlay()


## The cage body ids of the open form.
func body_ids() -> Array:
	return FORM.body_ids(feature) if active else []


## The stored cage of a body ({} when none).
func cage_of(body_id: String) -> Dictionary:
	if feature == null:
		return {}
	return (feature.options.get("bodies", {}) as Dictionary).get(body_id, {})


## The CadSubD of a body (null without the kernel or for unknown bodies).
func subd_of(body_id: String) -> RefCounted:
	var entry: Dictionary = _subd.get(body_id, {})
	return entry.get("subd")


## A body's tessellation as last made ({} when none).
func tess_of(body_id: String) -> Dictionary:
	return (_subd.get(body_id, {}) as Dictionary).get("tess", {})


## The body's display mode.
func display_mode(body_id: String) -> String:
	return FORM.display_mode(feature, body_id)


func units() -> String:
	return workspace.doc.units if workspace.doc != null else "mm"


func _links_ctx() -> Dictionary:
	var result: Dictionary = workspace.result
	return {"doc": workspace.doc, "kernel": workspace.kernel, "result": result, "bodies": result.get("bodies", {}),
		"values": result.get("values", {}), "sketches": result.get("sketches", {}), "construction": result.get("construction", {})}


## Brings an entry of store (_subd or _preview_entries) in step with a cage.
func _sync_entry(store: Dictionary, body_id: String, cage: Dictionary, drag := false) -> Dictionary:
	var entry: Dictionary = store.get(body_id, {})
	if entry.is_empty():
		entry = {"subd": ClassDB.instantiate("CadSubD") if ClassDB.class_exists("CadSubD") else null, "topo_hash": 0, "content_hash": 0,
			"nV": -1, "tess": {}, "error": "", "version": 0, "cage": {}}
		store[body_id] = entry
	var topo_hash := CAGE.topology_hash(cage)
	var content := CAGE.content_hash(cage)
	var n := CAGE.vertex_count(cage)
	var changed := false
	var topology_changed: bool = int(entry.topo_hash) != topo_hash or int(entry.nV) != n or entry.get("topo") == null
	if topology_changed:
		entry.topo = CAGE.topology(cage)
		entry.topo_hash = topo_hash
		entry.nV = n
		entry.erase("box")
		entry.erase("seg_index")
		changed = true
		var subd: RefCounted = entry.subd
		if subd != null:
			if subd.set_cage(cage):
				entry.error = ""
			else:
				entry.error = str(subd.get_last_error())
	elif int(entry.content_hash) != content or bool(entry.get("drag_rate", false)) != drag:
		changed = true
		entry.erase("box")
		var subd: RefCounted = entry.subd
		if subd != null and str(entry.error) == "":
			subd.set_positions(cage.positions)
	entry.cage = cage
	entry.content_hash = content
	if changed or not bool(entry.get("tessellated", false)):
		_tessellate(entry, drag)
		entry.version = int(entry.version) + 1
		_version += 1
		var box := CAGE.bounds(cage)
		entry.bounds = box
		entry.diag = maxf(box.size.length(), 1e-9)
		entry.erase("points_v3")
		_forget_screen(entry)
		if not drag:
			# Build the picking hierarchy now, with the rebuild the edit already costs, so the
			# first hover after a drag release or a tool doesn't stall.
			var subd: RefCounted = entry.subd
			if subd != null and str(entry.error) == "" and not (entry.tess as Dictionary).is_empty():
				subd.visible(PackedVector3Array(), Vector3.ZERO)
	return entry


## Tessellates an entry's cage (drag: the drag rate, half the full one).
func _tessellate(entry: Dictionary, drag := false, weights := PackedFloat32Array()) -> void:
	var subd: RefCounted = entry.subd
	entry.tessellated = true
	entry.drag_rate = drag
	if subd == null or str(entry.error) != "":
		entry.tess = {}
		return
	var nf := maxi(1, CAGE.face_count(entry.cage))
	var rate := clampi(int(floor(sqrt(150000.0 / nf))), 2, 12)
	var level := 4
	if display_quality == "draft":
		rate = maxi(2, rate / 2)
		level = 2
	if drag:
		rate = maxi(2, rate / 2)
	var options := {"rate": rate, "approx_level": level}
	if weights.size() == CAGE.vertex_count(entry.cage):
		options["weights"] = weights
	entry.tess = subd.tessellate(options)
	entry.rate = rate
	entry.erase("seg_index")


# --- Display ---------------------------------------------------------------------------------

## The bodies drawn now: [{"id", "entry", "mode", "preview": bool}] (hidden bodies left out).
func _shown_bodies() -> Array:
	var out := []
	if feature == null:
		return out
	var doc: Resource = workspace.doc
	for body_id in FORM.body_ids(feature):
		var id := str(body_id)
		if not doc.body_visible(id) or _preview_hidden.has(id):
			continue
		if _preview.has(id) and _preview_entries.has(id):
			out.append({"id": id, "entry": _preview_entries[id], "mode": display_mode(id), "preview": true})
		elif _subd.has(id):
			out.append({"id": id, "entry": _subd[id], "mode": display_mode(id), "preview": false})
	for id in _preview:
		if str(id).begins_with("__new") and _preview_entries.has(id):
			out.append({"id": str(id), "entry": _preview_entries[id], "mode": "smooth", "preview": true})
	return out


## Rebuilds the mesh entries (cached per body until its geometry, mode or highlights change) and
## hands them to the view.
func _refresh_meshes() -> void:
	if not active:
		viewport.set_form_meshes([])
		return
	var entries := []
	for shown in _shown_bodies():
		entries.append_array(_body_meshes(shown))
	viewport.set_form_meshes(entries)


## One body's mesh entries.
func _body_meshes(shown: Dictionary) -> Array:
	var id: String = shown.id
	var entry: Dictionary = shown.entry
	var mode: String = shown.mode
	var cage: Dictionary = entry.cage
	var tess: Dictionary = entry.tess
	var has_surface := not tess.is_empty()
	if not has_surface:
		mode = "box"
	var open := not (entry.topo as CAGE.Topo).is_closed() if entry.get("topo") != null else false
	var soft: PackedFloat32Array = _soft.get(id, PackedFloat32Array()) if not shown.preview else PackedFloat32Array()
	var points_on := bool(viewport.filters.get("vertex", true))
	var geo_key := "%s|%d|%s|%d|%s|%s|%s" % [mode, int(entry.version), str(open), soft.size(), str(points_on), str(show_symmetry), _sym_key(cage)]
	var cached: Dictionary = _mesh_entries.get(id, {})
	var geo: Array
	if cached.get("geo_key", "") == geo_key and is_same(cached.get("entry"), entry):
		geo = cached.geo
	else:
		display_build_count += 1
		geo = _geometry_meshes(id, entry, mode, open, soft, points_on)
		cached = {"geo_key": geo_key, "geo": geo, "entry": entry}
		_mesh_entries[id] = cached
	var highlight := _highlight_meshes(id, entry, mode)
	return geo + highlight


func _sym_key(cage: Dictionary) -> String:
	var sym: Array = cage.get("symmetry", [])
	var frozen: PackedInt32Array = cage.get("frozen", PackedInt32Array())
	var iso: PackedInt32Array = cage.get("sym_isolated", PackedInt32Array())
	return "%d:%d:%d:%d" % [sym.size(), hash(frozen), hash(iso), hash(str(sym.map(func(e: Dictionary) -> String: return str(e.get("origin")) + str(e.get("normal", e.get("axis"))))))]


func _geometry_meshes(id: String, entry: Dictionary, mode: String, open: bool, soft: PackedFloat32Array, points_on: bool) -> Array:
	var m: Dictionary = display.materials
	var cage: Dictionary = entry.cage
	var topo: CAGE.Topo = entry.topo
	var tess: Dictionary = entry.tess
	var out := []
	var soft_on := soft.size() == CAGE.vertex_count(cage)
	if mode == "box":
		out.append({"key": id + "/box", "mesh": _box_mesh(entry), "material": m.box_open if open else m.box})
	else:
		var colors := PackedColorArray()
		if soft_on and (tess.get("weights", PackedFloat32Array()) as PackedFloat32Array).size() == (tess.positions as PackedVector3Array).size():
			var w: PackedFloat32Array = tess.weights
			var key := "%d|%d|%s" % [hash(w), w.size(), str(theme_colors.form_surface)]
			var cached: Dictionary = entry.get("soft_colors", {})
			if cached.get("key", "") != key:
				var made := PackedColorArray()
				made.resize(w.size())
				for i in w.size():
					made[i] = display.soft_color(w[i], theme_colors.form_surface)
				cached = {"key": key, "colors": made}
				entry.soft_colors = cached
			colors = cached.colors
		var material: Material = m.surface_open if open else m.surface
		if not colors.is_empty():
			material = m.surface_soft_open if open else m.surface_soft
		out.append({"key": id + "/surface", "mesh": FORM_DISPLAY.surface_mesh(tess, colors), "material": material})
	if mode == "box" or mode == "frame":
		var lines := FORM_DISPLAY.cage_lines_mesh(cage, topo.edges.slice(0, topo.nE * 2))
		out.append({"key": id + "/lines", "mesh": lines, "material": m.line})
		out.append({"key": id + "/hidden", "mesh": lines, "material": m.hidden_line})
	if mode == "frame" and points_on:
		var pts := _points_v3(entry, "frame")
		var colors := PackedColorArray()
		if soft_on:
			colors.resize(pts.size())
			for v in pts.size():
				colors[v] = display.soft_color(soft[v], theme_colors.form_point)
		out.append({"key": id + "/points", "mesh": FORM_DISPLAY.points_mesh(pts, colors), "material": m.soft_points if soft_on else m.points})
	if mode == "smooth" and not tess.is_empty():
		out.append({"key": id + "/limit", "mesh": FORM_DISPLAY.lines_mesh(tess.get("edge_points", PackedVector3Array())), "material": m.limit_line})
	# Frozen and isolated faces.
	var frozen_faces := _frozen_faces(cage, topo)
	if not frozen_faces.is_empty():
		out.append({"key": id + "/frozen", "mesh": FORM_DISPLAY.faces_index_mesh(_face_tess(entry, mode), frozen_faces, _face_runs(entry, mode)), "material": m.frozen_face})
	var isolated := _isolated_faces(cage, topo)
	if not isolated.is_empty():
		out.append({"key": id + "/isolated", "mesh": FORM_DISPLAY.faces_index_mesh(_face_tess(entry, mode), isolated, _face_runs(entry, mode)), "material": m.isolated_face})
	if tool == "crease" or tool == "uncrease":
		var fade := _crease_fade_faces(cage, topo)
		if not fade.is_empty():
			out.append({"key": id + "/fade", "mesh": FORM_DISPLAY.faces_index_mesh(_face_tess(entry, mode), fade, _face_runs(entry, mode)), "material": m.warning_face})
	if show_symmetry:
		var k := 0
		var j := 0
		for sym in cage.get("symmetry", []):
			if str(sym.get("type", "")) != "mirror":
				# Circular: the axis through the body (its sector borders are seams on the overlay).
				var ao: PackedFloat64Array = sym.get("origin", PackedFloat64Array([0, 0, 0]))
				var ax: PackedFloat64Array = sym.get("axis", PackedFloat64Array([0, 0, 1]))
				out.append({"key": "%s/axis%d" % [id, j], "mesh": FORM_DISPLAY.axis_mesh(Vector3(ao[0], ao[1], ao[2]), Vector3(ax[0], ax[1], ax[2]), entry.bounds), "material": m.symmetry_axis})
				j += 1
				continue
			var o: PackedFloat64Array = sym.origin
			var n: PackedFloat64Array = sym.normal
			out.append({"key": "%s/plane%d" % [id, k], "mesh": FORM_DISPLAY.plane_mesh(Vector3(o[0], o[1], o[2]), Vector3(n[0], n[1], n[2]), entry.bounds), "material": m.symmetry_plane})
			k += 1
	return out


## Selected and hovered faces: meshes over the body's own tessellation vertices (only an index list
## of the faces' triangle runs is built), each cached per selection, mode and geometry version.
## A hover change then rebuilds nothing but the hover mesh, and a drag frame with a whole body
## selected hands over the tessellation's arrays instead of copying every triangle in GDScript.
func _highlight_meshes(id: String, entry: Dictionary, mode: String) -> Array:
	var out := []
	var m: Dictionary = display.materials
	var selected := {}
	var whole := false
	for item in selection:
		if item.body != id:
			continue
		if item.kind == "face":
			selected[int(item.index)] = true
		elif item.kind == "body":
			whole = true
	var face_tess := _face_tess(entry, mode)
	var nf := CAGE.face_count(entry.cage)
	if not whole and nf > 0 and selected.size() >= nf:
		whole = true
	if whole or not selected.is_empty():
		out.append({"key": id + "/select", "mesh": _highlight_mesh(entry, mode, face_tess, "select", selected, whole), "material": m.select_face})
	if not hover.is_empty() and hover.get("body", "") == id and str(hover.kind) in ["face", "body"]:
		var hovered := {}
		if hover.kind == "face":
			hovered[int(hover.index)] = true
		out.append({"key": id + "/hover", "mesh": _highlight_mesh(entry, mode, face_tess, "hover", hovered, hover.kind == "body"), "material": m.hover_face})
	return out


func _highlight_mesh(entry: Dictionary, mode: String, tess: Dictionary, slot: String, faces: Dictionary, whole: bool) -> ArrayMesh:
	var which := "all" if whole else str(faces.keys())
	var key := "%s|%s|%d|%d" % [mode, which, int(entry.version), (tess.get("positions", PackedVector3Array()) as PackedVector3Array).size()]
	var cached: Dictionary = entry.get("hl_" + slot, {})
	if cached.get("key", "") == key:
		return cached.mesh
	var mesh := FORM_DISPLAY.faces_index_mesh(tess, faces, _face_runs(entry, mode), whole)
	entry["hl_" + slot] = {"key": key, "mesh": mesh}
	return mesh


## face id -> Vector2i(first triangle, count) of _face_tess(entry, mode), cached while the
## tessellation's layout stays (a drag keeps it: same topology and rate).
func _face_runs(entry: Dictionary, mode: String) -> Dictionary:
	var tess := _face_tess(entry, mode)
	var box: bool = is_same(tess, entry.get("box"))
	var slot := "runs_box" if box else "runs_tess"
	var key := "%d|%d|%d" % [int(entry.topo_hash), int(entry.get("rate", 0)) if not box else -1, (tess.get("face_ids", PackedInt32Array()) as PackedInt32Array).size()]
	var cached: Dictionary = entry.get(slot, {})
	if cached.get("key", "") != key:
		cached = {"key": key, "runs": FORM_DISPLAY.face_runs(tess)}
		entry[slot] = cached
	return cached.runs


## face id -> triangles of _face_tess(entry, mode), cached while the tessellation's layout stays
## (a drag keeps it: same topology and rate).
func _face_tris(entry: Dictionary, mode: String) -> Dictionary:
	var tess := _face_tess(entry, mode)
	var box: bool = is_same(tess, entry.get("box"))
	var slot := "tris_box" if box else "tris_tess"
	var key := "%d|%d|%d" % [int(entry.topo_hash), int(entry.get("rate", 0)) if not box else -1, (tess.get("face_ids", PackedInt32Array()) as PackedInt32Array).size()]
	var cached: Dictionary = entry.get(slot, {})
	if cached.get("key", "") != key:
		cached = {"key": key, "tris": FORM_DISPLAY.face_triangles(tess)}
		entry[slot] = cached
	return cached.tris


## The triangles faces are drawn with in a mode: the limit tessellation, or the cage fans in Box.
func _face_tess(entry: Dictionary, mode: String) -> Dictionary:
	if mode == "box" or (entry.tess as Dictionary).is_empty():
		if not entry.has("box"):
			entry.box = FORM_DISPLAY.cage_faces(entry.cage)
		return entry.box
	return entry.tess


func _box_mesh(entry: Dictionary) -> ArrayMesh:
	var faces := _face_tess(entry, "box")
	return FORM_DISPLAY.surface_mesh(faces)


## Faces whose vertices are all frozen.
func _frozen_faces(cage: Dictionary, topo: CAGE.Topo) -> Dictionary:
	var frozen: PackedInt32Array = cage.get("frozen", PackedInt32Array())
	var out := {}
	if frozen.is_empty():
		return out
	var mark := {}
	for v in frozen:
		mark[v] = true
	for f in topo.nF:
		var all := true
		for h in range(topo.face_offsets[f], topo.face_offsets[f + 1]):
			if not mark.has(topo.face_indices[h]):
				all = false
				break
		if all:
			out[f] = true
	return out


## Faces touching a vertex left out of symmetry.
func _isolated_faces(cage: Dictionary, topo: CAGE.Topo) -> Dictionary:
	var iso: PackedInt32Array = cage.get("sym_isolated", PackedInt32Array())
	var out := {}
	if iso.is_empty():
		return out
	for v in iso:
		if v < topo.nV:
			for f in topo.vertex_faces(v):
				out[f] = true
	return out


## Faces around extraordinary vertices that touch a creased (or picked) edge: where a crease
## fades out over a short distance.
func _crease_fade_faces(cage: Dictionary, topo: CAGE.Topo) -> Dictionary:
	var out := {}
	var pairs: PackedInt32Array = cage.get("crease_edges", PackedInt32Array()).duplicate()
	for item in tool_picks.get("elements", []):
		if item.kind == "edge":
			pairs.append(item.pair.x)
			pairs.append(item.pair.y)
	for i in pairs.size() / 2:
		for v in [pairs[2 * i], pairs[2 * i + 1]]:
			if v < topo.nV and not topo.is_regular(v) and not topo.is_boundary_vertex(v):
				for f in topo.vertex_faces(v):
					out[f] = true
	return out


## The points a body is picked and drawn by: cage positions (Box, Control Frame) or limit points.
func _points_v3(entry: Dictionary, mode: String) -> PackedVector3Array:
	if mode == "smooth" and not (entry.tess as Dictionary).is_empty():
		return entry.tess.get("vertices", PackedVector3Array())
	if not entry.has("points_v3"):
		entry.points_v3 = FORM_DISPLAY.positions_v3(entry.cage)
	return entry.points_v3


# --- Drawing ---------------------------------------------------------------------------------

func _on_camera_changed() -> void:
	_overlay_valid = false
	_queue_panel_check(false)
	for id in _subd:
		_forget_screen(_subd[id])
	for id in _preview_entries:
		_forget_screen(_preview_entries[id])


## Overlay drawing (forge_viewport's draw handler, through the workspace): seams, creases,
## boundaries, frozen elements (cached on screen per camera change), then hover, selection,
## partners, tool previews and handles, the soft-modification radius and the gizmo.
func draw(overlay: Control) -> void:
	if not active:
		return
	var c := theme_colors
	if not _overlay_valid:
		_build_overlay_cache()
	for item in _overlay_cache.get("lines", []):
		_draw_cached(overlay, item)
	for item in _overlay_cache.get("dots", []):
		overlay.draw_circle(item.at, float(item.radius) * _ui_scale(), item.color)
	for item in _overlay_cache.get("diamonds", []):
		var at: Vector2 = item.at
		var r := 3.5 * _ui_scale()
		overlay.draw_colored_polygon(PackedVector2Array([at + Vector2(0, -r), at + Vector2(r, 0), at + Vector2(0, r), at + Vector2(-r, 0)]), item.color)
	if suspended:
		return
	# Hover.
	if not hover.is_empty() and not _is_selected(hover):
		match str(hover.kind):
			"edge":
				_draw_edge(overlay, hover, c.form_hover_line, 3.0)
			"vertex":
				var at := _vertex_screen(hover)
				if at.is_finite():
					overlay.draw_arc(at, 4.5 * _ui_scale(), 0.0, TAU, 20, c.form_hover_line, 2.0 * _ui_scale(), true)
	# Partners, then the selection (hidden parts faint).
	for item in _overlay_cache.get("sel_lines", []):
		_draw_cached(overlay, item)
	for item in _overlay_cache.get("sel_dots", []):
		overlay.draw_circle(item.at, 3.5 * _ui_scale(), item.color)
		if bool(item.outline):
			overlay.draw_arc(item.at, 3.5 * _ui_scale(), 0.0, TAU, 16, Color(c.handle_fill, item.color.a), _ui_scale(), true)
	_draw_tool(overlay)
	_draw_soft_radius(overlay)
	var active_handle := str(_drag.get("handle", "")) if str(_drag.get("type", "")) == "gizmo" else _hovered_handle()
	gizmo.px = _ui_scale()
	gizmo.draw(overlay, viewport, c, active_handle)
	_draw_region(overlay)


func _draw_cached(overlay: Control, item: Dictionary) -> void:
	var points: PackedVector2Array = item.points
	if points.size() < 2:
		return
	overlay.draw_multiline(points, item.color, float(item.width) * _ui_scale(), true)


func _draw_item(overlay: Control, item: Dictionary, color: Color) -> void:
	match str(item.kind):
		"edge":
			_draw_edge(overlay, item, color, 3.0)
		"vertex":
			var at := _vertex_screen(item)
			if at.is_finite():
				overlay.draw_circle(at, 3.5 * _ui_scale(), color)
				overlay.draw_arc(at, 3.5 * _ui_scale(), 0.0, TAU, 16, theme_colors.handle_fill, _ui_scale(), true)


func _draw_edge(overlay: Control, item: Dictionary, color: Color, width: float) -> void:
	var line := _edge_polyline(str(item.body), int(item.get("index", -1)), item.get("pair", Vector2i(-1, -1)))
	var screen := PackedVector2Array()
	for p in line:
		var q: Vector2 = viewport.project(p)
		if not q.is_finite():
			return
		screen.append(q)
	if screen.size() > 1:
		overlay.draw_polyline(screen, color, width * _ui_scale(), true)


func _vertex_screen(item: Dictionary) -> Vector2:
	var shown := _shown_entry(str(item.body))
	if shown.is_empty():
		return Vector2(INF, INF)
	var pts := _points_v3(shown.entry, shown.mode)
	var v := int(item.index)
	return viewport.project(pts[v]) if v >= 0 and v < pts.size() else Vector2(INF, INF)


## The entry a body is drawn from now and its mode ({} when not shown).
func _shown_entry(body_id: String) -> Dictionary:
	var entry: Dictionary = _preview_entries.get(body_id, {}) if _preview.has(body_id) else _subd.get(body_id, {})
	if entry.is_empty():
		return {}
	var mode := display_mode(body_id)
	if (entry.tess as Dictionary).is_empty():
		mode = "box"
	return {"entry": entry, "mode": mode}


## The 3D polyline of a cage edge as drawn: its cage segment (Box, Control Frame) or its limit
## curve (Smooth).
func _edge_polyline(body_id: String, e: int, pair: Vector2i) -> PackedVector3Array:
	var shown := _shown_entry(body_id)
	if shown.is_empty():
		return PackedVector3Array()
	var entry: Dictionary = shown.entry
	var topo: CAGE.Topo = entry.topo
	if pair.x >= 0:
		e = topo.edge_index(pair.x, pair.y)
	if e < 0 or e >= topo.nE:
		return PackedVector3Array()
	if shown.mode == "smooth":
		var segs := _segments_of(entry, e)
		var points: PackedVector3Array = entry.tess.get("edge_points", PackedVector3Array())
		var line := PackedVector3Array()
		for s in segs:
			if line.is_empty():
				line.append(points[2 * s])
			line.append(points[2 * s + 1])
		if not line.is_empty():
			return line
	var pts := _points_v3(entry, "frame")
	var ab := topo.edge_vertices(e)
	return PackedVector3Array([pts[ab.x], pts[ab.y]])


## The tessellation's segment indices along cage edge e, in order.
func _segments_of(entry: Dictionary, e: int) -> PackedInt32Array:
	if not entry.has("seg_index"):
		# Segments come in runs per edge: one dictionary write per run.
		var index := {}
		var ids: PackedInt32Array = entry.tess.get("edge_ids", PackedInt32Array())
		var start := 0
		while start < ids.size():
			var id := ids[start]
			var end := start + 1
			while end < ids.size() and ids[end] == id:
				end += 1
			var list: PackedInt32Array = index.get(id, PackedInt32Array())
			for s in range(start, end):
				list.append(s)
			index[id] = list
			start = end
		entry.seg_index = index
	return (entry.seg_index as Dictionary).get(e, PackedInt32Array())


## Screen polylines of seams, creases, boundaries and frozen elements for the current camera,
## hidden parts drawn faint.
func _build_overlay_cache() -> void:
	_overlay_valid = true
	var lines := []
	var dots := []
	var diamonds := []
	var c := theme_colors
	var groups := {"seam": [], "crease": [], "boundary": [], "frozen": [], "buffer": []}
	for shown in _shown_bodies():
		var id: String = shown.id
		var entry: Dictionary = shown.entry
		var cage: Dictionary = entry.cage
		var topo: CAGE.Topo = entry.topo
		if topo == null:
			continue
		var crease := CAGE.crease_map(cage)
		var frozen := {}
		for v in cage.get("frozen", PackedInt32Array()):
			frozen[v] = true
		var seam_edges := _seam_edges(cage, topo) if show_symmetry else {}
		for e in topo.nE:
			var ab := topo.edge_vertices(e)
			var kind := ""
			if frozen.has(ab.x) and frozen.has(ab.y):
				kind = "frozen"
			elif crease.has(CAGE.edge_key(ab.x, ab.y)):
				kind = "crease"
			elif topo.is_boundary_edge(e):
				kind = "boundary"
			elif seam_edges.has(e):
				kind = "seam"
			if kind != "":
				(groups[kind] as Array).append([id, e])
		if not frozen.is_empty():
			var locked := CAGE.locked_vertices(cage)
			for v in locked.size():
				if locked[v] and not frozen.has(v):
					(groups.buffer as Array).append([id, v])
		var corner_list: PackedInt32Array = cage.get("corners", PackedInt32Array())
		if not corner_list.is_empty():
			var pts3 := _points_v3(entry, shown.mode)
			var probe := PackedVector3Array()
			for v in corner_list:
				probe.append(pts3[v] if v < pts3.size() else Vector3.ZERO)
			var seen := _visibility(id, probe)
			for i in corner_list.size():
				var at := _vertex_screen({"body": id, "index": corner_list[i]})
				if at.is_finite():
					# Behind the surface: faint, as hidden crease lines are.
					var hidden := not seen.is_empty() and seen[i] == 0
					diamonds.append({"at": at, "color": Color(c.form_crease, c.form_crease.a * 0.3) if hidden else c.form_crease})
	var styles := {"seam": [c.form_symmetry_line, 2.0], "crease": [c.form_crease, 2.5], "boundary": [c.form_boundary, 2.0], "frozen": [c.form_frozen, 2.0]}
	for kind in ["seam", "crease", "boundary", "frozen"]:
		var visible_points := PackedVector2Array()
		var hidden_points := PackedVector2Array()
		# One visibility query per body for all of this kind's points.
		var polylines := []
		var by_body := {}
		for pair in groups[kind]:
			var line := _edge_polyline(pair[0], pair[1], Vector2i(-1, -1))
			if not by_body.has(pair[0]):
				by_body[pair[0]] = PackedVector3Array()
			var all: PackedVector3Array = by_body[pair[0]]
			polylines.append([pair[0], line, all.size()])
			all.append_array(line)
			by_body[pair[0]] = all
		var flags_by_body := {}
		for body_id in by_body:
			flags_by_body[body_id] = _visibility(body_id, by_body[body_id])
		for entry_line in polylines:
			var line: PackedVector3Array = entry_line[1]
			var all_flags: PackedByteArray = flags_by_body.get(entry_line[0], PackedByteArray())
			var flags := all_flags.slice(entry_line[2], entry_line[2] + line.size()) if not all_flags.is_empty() else PackedByteArray()
			for i in line.size() - 1:
				var a: Vector2 = viewport.project(line[i])
				var b: Vector2 = viewport.project(line[i + 1])
				if not (a.is_finite() and b.is_finite()):
					continue
				var shown_segment := flags.is_empty() or (flags[i] != 0 and flags[i + 1] != 0)
				if shown_segment:
					visible_points.append(a)
					visible_points.append(b)
				else:
					hidden_points.append(a)
					hidden_points.append(b)
		var color: Color = styles[kind][0]
		lines.append({"points": hidden_points, "color": Color(color, color.a * 0.3), "width": 1.5})
		lines.append({"points": visible_points, "color": color, "width": styles[kind][1]})
	var buffer_by_body := {}
	for pair in groups.buffer:
		if not buffer_by_body.has(pair[0]):
			buffer_by_body[pair[0]] = []
		(buffer_by_body[pair[0]] as Array).append(pair[1])
	for body_id in buffer_by_body:
		var shown_body := _shown_entry(str(body_id))
		var verts: Array = buffer_by_body[body_id]
		var pts3: PackedVector3Array = _points_v3(shown_body.entry, shown_body.mode) if not shown_body.is_empty() else PackedVector3Array()
		var probe := PackedVector3Array()
		for v in verts:
			probe.append(pts3[v] if v < pts3.size() else Vector3.ZERO)
		var seen := _visibility(str(body_id), probe)
		for i in verts.size():
			var at := _vertex_screen({"body": body_id, "index": verts[i]})
			if at.is_finite():
				var hidden := not seen.is_empty() and seen[i] == 0
				dots.append({"at": at, "radius": 2.0, "color": Color(c.form_frozen_buffer, 0.3) if hidden else c.form_frozen_buffer})
	var sel_lines := []
	var sel_dots := []
	for spec in [[_partners, c.form_partner], [selection, c.form_select_line]]:
		_selection_overlay(spec[0], spec[1], sel_lines, sel_dots)
	_overlay_cache = {"lines": lines, "dots": dots, "diamonds": diamonds, "sel_lines": sel_lines, "sel_dots": sel_dots}


## Screen geometry of selected (or partner) edges and vertices, parts hidden behind the surface
## faint.
func _selection_overlay(items: Array, color: Color, lines: Array, dots: Array) -> void:
	var edges_by_body := {}
	var verts_by_body := {}
	for item in items:
		if item.kind == "edge":
			if not edges_by_body.has(item.body):
				edges_by_body[item.body] = []
			(edges_by_body[item.body] as Array).append(item)
		elif item.kind == "vertex":
			if not verts_by_body.has(item.body):
				verts_by_body[item.body] = []
			(verts_by_body[item.body] as Array).append(item)
	var shown := PackedVector2Array()
	var hidden := PackedVector2Array()
	for body_id in edges_by_body:
		var all := PackedVector3Array()
		var spans := []
		for item in edges_by_body[body_id]:
			var line := _edge_polyline(str(body_id), int(item.get("index", -1)), item.get("pair", Vector2i(-1, -1)))
			spans.append([all.size(), line.size()])
			all.append_array(line)
		var flags := _visibility(str(body_id), all)
		for span in spans:
			for i in range(span[0], span[0] + span[1] - 1):
				var a: Vector2 = viewport.project(all[i])
				var b: Vector2 = viewport.project(all[i + 1])
				if not (a.is_finite() and b.is_finite()):
					continue
				if flags.is_empty() or (flags[i] != 0 and flags[i + 1] != 0):
					shown.append(a)
					shown.append(b)
				else:
					hidden.append(a)
					hidden.append(b)
	lines.append({"points": hidden, "color": Color(color, color.a * 0.35), "width": 2.0})
	lines.append({"points": shown, "color": color, "width": 3.0})
	for body_id in verts_by_body:
		var entry := _shown_entry(str(body_id))
		if entry.is_empty():
			continue
		var pts := _points_v3(entry.entry, entry.mode)
		var world := PackedVector3Array()
		for item in verts_by_body[body_id]:
			var v := int(item.index)
			if v >= 0 and v < pts.size():
				world.append(pts[v])
		var flags := _visibility(str(body_id), world)
		for i in world.size():
			var at: Vector2 = viewport.project(world[i])
			if at.is_finite():
				var seen := flags.is_empty() or flags[i] != 0
				dots.append({"at": at, "color": color if seen else Color(color, color.a * 0.35), "outline": seen})


## Edges on a mirror plane (both ends map to themselves) and circular sector borders.
func _seam_edges(cage: Dictionary, topo: CAGE.Topo) -> Dictionary:
	var out := {}
	for sym in cage.get("symmetry", []):
		var m: PackedInt32Array = sym.get("map", PackedInt32Array())
		if m.size() != topo.nV:
			continue
		if str(sym.get("type", "")) == "mirror":
			for e in topo.nE:
				var ab := topo.edge_vertices(e)
				if m[ab.x] == ab.x and m[ab.y] == ab.y:
					out[e] = true
		else:
			# Circular: the sector borders, the half-planes through the axis at the angles of
			# one vertex's orbit (edges with both ends on one border, or on the axis).
			var sector := _sector_of_vertices(cage, sym)
			for e in topo.nE:
				var ab := topo.edge_vertices(e)
				var ka: int = sector[ab.x]
				var kb: int = sector[ab.y]
				if ka == -2 or kb == -2:
					continue
				if ka == kb or ka == -1 or kb == -1:
					if not (ka == -1 and kb == -1):
						out[e] = true
	return out


## Per vertex of a circular entry: the sector border it lies on (0..count-1), -1 on the axis, -2
## off every border.
func _sector_of_vertices(cage: Dictionary, sym: Dictionary) -> PackedInt32Array:
	var p: PackedFloat64Array = cage.positions
	var nV := p.size() / 3
	var out := PackedInt32Array()
	out.resize(nV)
	out.fill(-2)
	var o: PackedFloat64Array = sym.get("origin", PackedFloat64Array([0, 0, 0]))
	var a := Vector3(sym.get("axis", PackedFloat64Array([0, 0, 1]))[0], sym.get("axis", PackedFloat64Array([0, 0, 1]))[1], sym.get("axis", PackedFloat64Array([0, 0, 1]))[2]).normalized()
	var step := float(sym.get("step", TAU / maxi(2, int(sym.get("count", 2)))))
	var tol := 1e-6 * maxf(CAGE.diagonal(cage), 1e-12)
	var e1 := Vector3.ZERO
	for v in nV:
		var d := Vector3(p[3 * v] - o[0], p[3 * v + 1] - o[1], p[3 * v + 2] - o[2])
		d -= a * d.dot(a)
		if d.length() > tol:
			e1 = d.normalized()
			break
	if e1 == Vector3.ZERO:
		return out
	var e2 := a.cross(e1)
	for v in nV:
		var d := Vector3(p[3 * v] - o[0], p[3 * v + 1] - o[1], p[3 * v + 2] - o[2])
		d -= a * d.dot(a)
		if d.length() <= tol:
			out[v] = -1
			continue
		var ang := atan2(d.dot(e2), d.dot(e1))
		var k := roundi(ang / step)
		if absf(ang - k * step) <= 1e-5:
			out[v] = posmod(k, maxi(1, roundi(TAU / step)))
	return out


## 1 per point on the cage (a vertex or a marker at one) seen from the camera past the cage
## polygons, whatever the display mode (empty: all visible, select-through, or no kernel).
func cage_point_visibility(body_id: String, points: PackedVector3Array) -> PackedByteArray:
	if points.is_empty():
		return PackedByteArray()
	var shown := _shown_entry(body_id)
	if shown.is_empty() or shown.entry.subd == null or str(shown.entry.error) != "":
		return PackedByteArray()
	return _visible(shown.entry, "box", points)


## 1 per point of line when visible from the camera (empty: all visible, or no kernel).
func _visibility(body_id: String, line: PackedVector3Array) -> PackedByteArray:
	if viewport.select_through or line.is_empty():
		return PackedByteArray()
	var shown := _shown_entry(body_id)
	if shown.is_empty() or shown.entry.subd == null or str(shown.entry.error) != "":
		return PackedByteArray()
	return _visible(shown.entry, shown.mode, line)


func _visible(entry: Dictionary, mode: String, points: PackedVector3Array) -> PackedByteArray:
	var subd: RefCounted = entry.subd
	if subd == null or str(entry.error) != "":
		var all := PackedByteArray()
		all.resize(points.size())
		all.fill(1)
		return all
	var view_dir: Vector3 = -viewport.camera_basis().z if viewport.ortho else Vector3.ZERO
	var tolerance := maxf(float(entry.diag) * 2e-3, 1e-7)
	return subd.visible(points, viewport.camera_position(), view_dir, tolerance, 0 if mode == "smooth" else 1)


func _draw_tool(overlay: Control) -> void:
	if tool == "":
		return
	var c := theme_colors
	var spec := FORM_TOOLS.spec(tool)
	if bool(spec.get("interact", false)):
		FORM_TOOLS.hook("draw", tool, [self, overlay])
	# A primitive's placement: the picked frame at the centre.
	var placement: Array = tool_picks.get("placement", [])
	if not placement.is_empty():
		var p: Dictionary = placement[0]
		var o: Vector2 = viewport.project(p.origin)
		if o.is_finite():
			var wpp := 1.0 / maxf(float(viewport.pixels_per_meter_at(p.origin)), 1e-12)
			for spec_axis in [[p.x, c.axis_x], [p.y, c.axis_y]]:
				var q: Vector2 = viewport.project(p.origin + (spec_axis[0] as Vector3) * 18.0 * wpp)
				if q.is_finite():
					overlay.draw_line(o, q, spec_axis[1], 1.5, true)
			overlay.draw_circle(o, 3.0, c.form_preview)
	for handle in _handles:
		var shape := _handle_shape(handle)
		if shape.is_empty():
			continue
		var lit: bool = str(_drag.get("type", "")) == "tool_handle" and _drag.handle.key == handle.key
		var color: Color = c.handle if lit else Color(c.form_preview, 0.95)
		match str(handle.type):
			"arrow":
				var from: Vector2 = shape.from
				var to: Vector2 = shape.to
				var dir := (to - from).normalized()
				var side := Vector2(-dir.y, dir.x)
				overlay.draw_line(from, to, color, 2.2, true)
				overlay.draw_colored_polygon(PackedVector2Array([to + dir * 10.0, to + side * 5.0, to - side * 5.0]), color)
				overlay.draw_circle(from, 3.0, color)
			"count":
				var at: Vector2 = shape.at
				var dir: Vector2 = shape.dir
				var side := Vector2(-dir.y, dir.x)
				for s in [1.0, -1.0]:
					var tip: Vector2 = at + dir * 13.0 * s
					overlay.draw_colored_polygon(PackedVector2Array([tip, tip - dir * 7.0 * s + side * 4.5, tip - dir * 7.0 * s - side * 4.5]), color)
				overlay.draw_line(at - dir * 6.0, at + dir * 6.0, color, 2.0, true)
				var font := overlay.get_theme_default_font()
				var text := str(tool_values.get(handle.key, ""))
				overlay.draw_string(font, at + side * 9.0 + Vector2(-4, 4), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, color)
			"slider":
				var px := _ui_scale()
				overlay.draw_dashed_line(shape.from, shape.to, Color(c.form_preview, 0.8), 2.0 * px, 6.0 * px)
				overlay.draw_circle(shape.at, 6.0 * px, c.handle if lit else c.form_preview)
				overlay.draw_arc(shape.at, 6.0 * px, 0.0, TAU, 20, c.handle_fill, 1.0 * px, true)


func _draw_soft_radius(overlay: Control) -> void:
	if tool != "edit_form" or not bool(tool_values.get("soft", false)) or not gizmo.visible:
		return
	if str(tool_values.get("extent", "distance")) != "distance":
		return
	var r := float(evaluated_values().get("distance", 0.0))
	if r <= 0.0:
		return
	var at: Vector2 = viewport.project(gizmo.pivot)
	if not at.is_finite():
		return
	var px := r * float(viewport.pixels_per_meter_at(gizmo.pivot))
	overlay.draw_arc(at, px, 0.0, TAU, 64, Color(theme_colors.form_soft_high, 0.6), 1.5, true)


func _draw_region(overlay: Control) -> void:
	if str(_drag.get("type", "")) != "region":
		return
	var c := theme_colors
	if viewport.select_mode == "freeform":
		var points: PackedVector2Array = _drag.get("points", PackedVector2Array())
		if points.size() > 1:
			var closed := points.duplicate()
			closed.append(points[0])
			overlay.draw_polyline(closed, c.window_box, 1.5, true)
		return
	var start: Vector2 = _drag.start
	var end: Vector2 = _drag.get("end", start)
	var rect := Rect2(start, end - start).abs()
	var crossing := end.x < start.x
	var color: Color = c.crossing_box if crossing else c.window_box
	overlay.draw_rect(rect, Color(color, 0.12), true)
	if crossing:
		for edge in [[rect.position, rect.position + Vector2(rect.size.x, 0)], [rect.position + Vector2(rect.size.x, 0), rect.end],
				[rect.end, rect.position + Vector2(0, rect.size.y)], [rect.position + Vector2(0, rect.size.y), rect.position]]:
			overlay.draw_dashed_line(edge[0], edge[1], color, 1.5, 6.0)
	else:
		overlay.draw_rect(rect, color, false, 1.5)


# --- Picking ---------------------------------------------------------------------------------

## The cage element under a screen position, honouring the view's filters and priority: {"kind",
## "body", "index", "pair"} or {}.
func pick_at(screen: Vector2, kinds := []) -> Dictionary:
	var filters: Dictionary = viewport.filters
	var found := {}
	var face := _face_hit(screen)
	if not face.is_empty():
		found["face"] = {"kind": "face", "body": face.body, "index": int(face.face), "pair": Vector2i(-1, -1), "point": face.point}
		found["body"] = {"kind": "body", "body": face.body, "index": -1, "pair": Vector2i(-1, -1), "point": face.point}
	if filters.get("vertex", true):
		var vertex := _nearest_vertex(screen)
		if not vertex.is_empty():
			found["vertex"] = vertex
	if filters.get("edge", true):
		var edge := _nearest_edge(screen, face)
		if not edge.is_empty():
			found["edge"] = edge
	for kind in PICKING.PRIORITY_ORDER.get(viewport.priority, PICKING.PRIORITY_ORDER.default):
		if found.has(kind) and filters.get(kind, true) and (kinds.is_empty() or kinds.has(kind)):
			return found[kind]
	return {}


## The nearest face under the ray over the shown bodies: {"body", "face", "point", "distance"} or {}.
func _face_hit(screen: Vector2) -> Dictionary:
	var ray: Array = viewport.ray_from(screen)
	var best := {}
	for shown in _shown_bodies():
		if shown.preview and str(shown.id).begins_with("__new"):
			continue
		var entry: Dictionary = _subd.get(shown.id, {})
		if entry.is_empty():
			continue
		var mode := display_mode(shown.id)
		var hit := {}
		var subd: RefCounted = entry.subd
		if subd != null and str(entry.error) == "" and not (entry.tess as Dictionary).is_empty():
			var r: Dictionary = subd.ray_hit(ray[0], ray[1], 0 if mode == "smooth" else 1)
			if bool(r.get("hit", false)):
				hit = {"body": shown.id, "face": int(r.face), "point": r.point, "distance": float(r.distance)}
		else:
			hit = _ray_cage(shown.id, entry, ray[0], ray[1])
		if not hit.is_empty() and (best.is_empty() or float(hit.distance) < float(best.distance)):
			best = hit
	return best


## A ray against the cage polygons in GDScript (no kernel).
func _ray_cage(body_id: String, entry: Dictionary, from: Vector3, dir: Vector3) -> Dictionary:
	var faces := _face_tess(entry, "box")
	var positions: PackedVector3Array = faces.positions
	var indices: PackedInt32Array = faces.indices
	var ids: PackedInt32Array = faces.face_ids
	var best := {}
	for t in ids.size():
		var hit: Variant = Geometry3D.ray_intersects_triangle(from, dir, positions[indices[3 * t]], positions[indices[3 * t + 1]], positions[indices[3 * t + 2]])
		if hit != null:
			var d := from.distance_to(hit)
			if best.is_empty() or d < float(best.distance):
				best = {"body": body_id, "face": ids[t], "point": hit, "distance": d}
	return best


## Projected display points of a body for the current camera (cached until the camera moves).
func _screen_points(_body_id: String, entry: Dictionary, mode: String) -> PackedVector2Array:
	var slot := "screen_smooth" if mode == "smooth" else "screen_cage"
	var key := "%d" % int(entry.version)
	var cached: Dictionary = entry.get(slot, {})
	if cached.get("key", "") == key:
		return cached.points
	var pts := _points_v3(entry, mode)
	var out := PackedVector2Array()
	out.resize(pts.size())
	for i in pts.size():
		out[i] = viewport.project(pts[i])
	entry[slot] = {"key": key, "points": out}
	return out


## Forgets an entry's projected points (the camera or the geometry moved).
static func _forget_screen(entry: Dictionary) -> void:
	entry.erase("screen_smooth")
	entry.erase("screen_cage")
	entry.erase("grid_smooth")
	entry.erase("grid_cage")


## Screen cell size (pixels) of the edge grid.
const EDGE_CELL_PX := 24.0


## The edges near a screen position, from a grid of the edges' screen boxes built once per camera
## and geometry (an edge's box: its ends as drawn, grown by the pick radius and, for limit curves,
## by a third of its length for the curve's bulge).
func _edges_near(body_id: String, entry: Dictionary, mode: String, at: Vector2) -> Array:
	var slot := "grid_smooth" if mode == "smooth" else "grid_cage"
	var key := "%d" % int(entry.version)
	var cached: Dictionary = entry.get(slot, {})
	if cached.get("key", "") != key:
		var topo: CAGE.Topo = entry.topo
		var pts := _screen_points(body_id, entry, mode)
		var grid := {}
		var big := []
		var smooth := mode == "smooth"
		for e in topo.nE:
			var ab := topo.edge_vertices(e)
			var a := pts[ab.x]
			var b := pts[ab.y]
			if not (a.is_finite() and b.is_finite()):
				continue
			var margin := (PICK_RADIUS_PX * _ui_scale()) + (0.35 * a.distance_to(b) if smooth else 0.0)
			var lo := ((a.min(b) - Vector2(margin, margin)) / (EDGE_CELL_PX * _ui_scale())).floor()
			var hi := ((a.max(b) + Vector2(margin, margin)) / (EDGE_CELL_PX * _ui_scale())).floor()
			if (hi.x - lo.x + 1.0) * (hi.y - lo.y + 1.0) > 64.0:
				big.append(e)
				continue
			for cx in range(int(lo.x), int(hi.x) + 1):
				for cy in range(int(lo.y), int(hi.y) + 1):
					var cell := Vector2i(cx, cy)
					if not grid.has(cell):
						grid[cell] = []
					(grid[cell] as Array).append(e)
		cached = {"key": key, "grid": grid, "big": big}
		entry[slot] = cached
	var cell := Vector2i(floori(at.x / (EDGE_CELL_PX * _ui_scale())), floori(at.y / (EDGE_CELL_PX * _ui_scale())))
	return (cached.grid as Dictionary).get(cell, []) + (cached.big as Array)


func _nearest_vertex(screen: Vector2) -> Dictionary:
	var candidates := []
	for shown in _shown_bodies():
		if shown.preview:
			continue
		var entry: Dictionary = shown.entry
		var pts := _screen_points(shown.id, entry, shown.mode)
		for v in pts.size():
			var d := pts[v].distance_to(screen)
			if d <= (PICK_RADIUS_PX * _ui_scale()):
				candidates.append([d, shown.id, v, entry, shown.mode])
	if candidates.is_empty():
		return {}
	candidates.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	for cand in candidates:
		var entry: Dictionary = cand[3]
		var p := _points_v3(entry, cand[4])[cand[2]]
		if viewport.select_through or _visible(entry, cand[4], PackedVector3Array([p]))[0] != 0:
			return {"kind": "vertex", "body": cand[1], "index": cand[2], "pair": Vector2i(-1, -1), "point": p}
	return {}


func _nearest_edge(screen: Vector2, face: Dictionary) -> Dictionary:
	var candidates := []
	for shown in _shown_bodies():
		if shown.preview:
			continue
		var id: String = shown.id
		var entry: Dictionary = shown.entry
		var topo: CAGE.Topo = entry.topo
		var edges := PackedInt32Array()
		if not face.is_empty() and face.body == id:
			# Around the face under the cursor: its edges and those of the faces around it.
			var seen := {}
			for h in range(topo.face_offsets[face.face], topo.face_offsets[face.face + 1]):
				for f in topo.vertex_faces(topo.face_indices[h]):
					for e in topo.face_edges(f):
						if not seen.has(e):
							seen[e] = true
							edges.append(e)
		else:
			# Off the surface (near a silhouette or a free edge): the edges whose screen box holds it.
			edges = PackedInt32Array(_edges_near(id, entry, shown.mode, screen))
		var pts := _screen_points(id, entry, "frame")
		var p3 := _points_v3(entry, "frame")
		for e in edges:
			var ab := topo.edge_vertices(e)
			if shown.mode == "smooth":
				var line := _edge_polyline(id, e, Vector2i(-1, -1))
				var best_d := INF
				var best_p := Vector3.ZERO
				for i in line.size() - 1:
					var a: Vector2 = viewport.project(line[i])
					var b: Vector2 = viewport.project(line[i + 1])
					if not (a.is_finite() and b.is_finite()):
						continue
					var q := Geometry2D.get_closest_point_to_segment(screen, a, b)
					var d := q.distance_to(screen)
					if d < best_d:
						best_d = d
						best_p = line[i].lerp(line[i + 1], (q - a).length() / maxf((b - a).length(), 1e-9))
				if best_d <= (PICK_RADIUS_PX * _ui_scale()):
					candidates.append([best_d, id, e, ab, best_p, entry, shown.mode])
			else:
				var a := pts[ab.x]
				var b := pts[ab.y]
				if not (a.is_finite() and b.is_finite()):
					continue
				var r := (PICK_RADIUS_PX * _ui_scale())
				if minf(a.x, b.x) - r > screen.x or maxf(a.x, b.x) + r < screen.x or minf(a.y, b.y) - r > screen.y or maxf(a.y, b.y) + r < screen.y:
					continue
				var q := Geometry2D.get_closest_point_to_segment(screen, a, b)
				var d := q.distance_to(screen)
				if d <= r:
					var t := (q - a).length() / maxf((b - a).length(), 1e-9)
					candidates.append([d, id, e, ab, p3[ab.x].lerp(p3[ab.y], t), entry, shown.mode])
	if candidates.is_empty():
		return {}
	candidates.sort_custom(func(x: Array, y: Array) -> bool: return x[0] < y[0])
	for cand in candidates:
		if viewport.select_through or _visible(cand[5], cand[6], PackedVector3Array([cand[4]]))[0] != 0:
			var ab: Vector2i = cand[3]
			return {"kind": "edge", "body": cand[1], "index": cand[2], "pair": Vector2i(ab.x, ab.y), "point": cand[4]}
	return {}


# --- Mouse -----------------------------------------------------------------------------------

## Takes every left press, release and motion while the form is open (the view does no body
## picking of its own); middle, right and wheel go to the view (navigation, marking menu).
func handle_mouse(event: InputEvent) -> bool:
	if not active or suspended:
		return false
	var button := event as InputEventMouseButton
	if button != null and button.button_index != MOUSE_BUTTON_LEFT:
		return false
	var mouse := event as InputEventMouse
	if mouse == null:
		return false
	# A drag in progress takes everything until its release.
	if not _drag.is_empty():
		if event is InputEventMouseMotion:
			_drag_motion(event as InputEventMouseMotion)
		elif button != null and not button.pressed:
			_drag_release(button)
		return true
	if button != null and button.pressed:
		return _press(button)
	if button != null:
		return true
	# A plain move: the tool's own clicks, then a model pick slot's hover, then cage hover.
	if tool != "" and bool(FORM_TOOLS.spec(tool).get("interact", false)):
		if FORM_TOOLS.hook("handle_mouse", tool, [self, event], false):
			viewport.redraw_overlay()
			return true
	if _model_slot_active():
		workspace.picker.handle_mouse(event)
		if not (workspace.picker.hover as Dictionary).is_empty():
			if not hover.is_empty():
				hover = {}
				_refresh_meshes()
			viewport.redraw_overlay()
			return true
	_update_hover(mouse.position)
	return true


## True while the running tool's panel has a model pick slot active (a profile, curve, edge, axis
## or point field): view clicks then pick model geometry through the workspace's picker, and the
## picks land in that field (so the tool reads them from its values).
func _model_slot_active() -> bool:
	if tool == "" or workspace.panel == null or workspace.get("picker") == null:
		return false
	if str(workspace.panel.active_selection_key) == "":
		return false
	return str((workspace.panel.active_field() as Dictionary).get("type", "")) == "selection"


## The kinds the running tool's active model pick slot takes ([] when none is active).
func model_kinds() -> Array:
	if not _model_slot_active():
		return []
	var filter: Variant = (workspace.panel.active_field() as Dictionary).get("filter", [])
	return [filter] if filter is String else (filter as Array)


## The model references the running tool's pick slots hold (for the workspace's highlights).
func model_refs() -> Array:
	var refs := []
	if tool == "":
		return refs
	for field in FORM_TOOLS.spec(tool).get("fields", []):
		if str(field.get("type", "")) == "selection":
			for item in tool_values.get(field.key, []):
				refs.append(item)
	return refs


func _press(event: InputEventMouseButton) -> bool:
	var at := event.position
	# Tool handles (distance arrows, counts) first, then the tool's own clicks, then the gizmo.
	var handle := _handle_at(at)
	if not handle.is_empty():
		_begin_tool_handle(handle, at)
		return true
	if tool != "" and bool(FORM_TOOLS.spec(tool).get("interact", false)):
		if FORM_TOOLS.hook("handle_mouse", tool, [self, event], false):
			_drag = {"type": "tool_click"}
			viewport.redraw_overlay()
			return true
	# A model pick slot (profile, curve, axis...) takes a click on what it can pick through the
	# workspace's picker; a click on nothing it takes falls through to the cage (tools that pick
	# both, like Flatten's vertices and plane).
	if _model_slot_active() and not (workspace.picker.pick(at) as Dictionary).is_empty():
		workspace.picker.handle_mouse(event)
		_drag = {"type": "consumed"}
		viewport.redraw_overlay()
		return true
	var gizmo_handle := gizmo.hit(viewport, at) if tool == "edit_form" else ""
	if gizmo_handle != "":
		_begin_gizmo(gizmo_handle, event)
		return true
	var pick := pick_at(at)
	if event.double_click:
		_double_click(pick, event.shift_pressed)
		_drag = {"type": "consumed"}
		return true
	_drag = {"type": "pending", "start": at, "pick": pick, "shift": event.shift_pressed, "ctrl": event.ctrl_pressed or event.meta_pressed,
		"alt": event.alt_pressed}
	return true


func _drag_motion(event: InputEventMouseMotion) -> void:
	match str(_drag.type):
		"pending":
			if event.position.distance_to(_drag.start) <= (DRAG_START_PX * _ui_scale()):
				return
			var pick: Dictionary = _drag.pick
			if tool == "edit_form" and not pick.is_empty() and _is_selected(pick):
				var start: Vector2 = _drag.start
				var press := InputEventMouseButton.new()
				press.position = start
				press.alt_pressed = bool(_drag.alt)
				press.ctrl_pressed = bool(_drag.ctrl)
				_drag = {}
				_begin_gizmo("free", press)
				_drag_motion(event)
				return
			if viewport.select_mode == "paint":
				_drag = {"type": "paint", "start": _drag.start, "shift": _drag.shift}
				if not (bool(_drag.shift)):
					selection.clear()
				_paint(event.position)
				return
			_drag = {"type": "region", "start": _drag.start, "end": event.position, "points": PackedVector2Array([_drag.start, event.position]),
				"additive": bool(_drag.shift) or bool(_drag.ctrl)}
			viewport.redraw_overlay()
		"region":
			_drag.end = event.position
			var points: PackedVector2Array = _drag.points
			points.append(event.position)
			_drag.points = points
			viewport.redraw_overlay()
		"paint":
			_paint(event.position)
		"gizmo":
			_gizmo_motion(event)
		"tool_handle":
			_tool_handle_motion(event.position)
		"tool_click":
			if tool != "":
				FORM_TOOLS.hook("handle_mouse", tool, [self, event], false)
				viewport.redraw_overlay()


func _drag_release(event: InputEventMouseButton) -> void:
	var drag := _drag
	_drag = {}
	match str(drag.type):
		"pending":
			_click(drag.pick, bool(drag.shift), bool(drag.ctrl))
		"region":
			var outline: PackedVector2Array = drag.points
			if viewport.select_mode == "freeform":
				_region_select(outline, outline.size() > 1 and outline[outline.size() - 1].x < outline[0].x, bool(drag.additive), true)
			else:
				var rect := Rect2(drag.start, event.position - (drag.start as Vector2))
				_region_select(PackedVector2Array([rect.position, rect.end]), event.position.x < (drag.start as Vector2).x, bool(drag.additive), false)
		"paint":
			_selection_changed()
		"gizmo":
			_gizmo_release(drag)
		"tool_handle":
			_update_handles()
		"tool_click":
			if tool != "":
				FORM_TOOLS.hook("handle_mouse", tool, [self, event], false)
				_update_handles()
	viewport.redraw_overlay()


func _update_hover(at: Vector2) -> void:
	var handle := gizmo.hit(viewport, at) if tool == "edit_form" else ""
	var new_hover := {} if handle != "" else pick_at(at, _slot_kinds())
	if _item_key(new_hover) != _item_key(hover):
		hover = new_hover
		_refresh_meshes()
	_drag_hover_handle = handle
	viewport.redraw_overlay()


func _hovered_handle() -> String:
	return _drag_hover_handle


## The kinds the running tool's first pick slot takes ([] for any).
func _slot_kinds() -> Array:
	if tool == "" or tool == "edit_form":
		return []
	var picks: Array = FORM_TOOLS.spec(tool).get("picks", [])
	if picks.is_empty():
		return []
	var kinds: Array = (picks[0] as Dictionary).get("kinds", [])
	# A body slot takes a click on any of the body's elements.
	if kinds.has("body"):
		return []
	return kinds


func _click(pick: Dictionary, shift: bool, ctrl: bool) -> void:
	_prev_selection = selection.duplicate()
	var item := _for_slot(pick)
	if item.is_empty():
		if not shift and not ctrl:
			selection.clear()
	elif shift or ctrl:
		var at := _selection_index(item)
		if at >= 0:
			selection.remove_at(at)
		else:
			selection.append(item)
	else:
		selection = [item]
	_selection_changed()


## A pick as the running tool's slot wants it (a body slot turns elements into their body).
func _for_slot(pick: Dictionary) -> Dictionary:
	if pick.is_empty():
		return {}
	var item := _clean(pick)
	if tool != "" and tool != "edit_form":
		var picks: Array = FORM_TOOLS.spec(tool).get("picks", [])
		if not picks.is_empty() and (picks[0].get("kinds", []) as Array) == ["body"]:
			return {"kind": "body", "body": item.body, "index": -1, "pair": Vector2i(-1, -1)}
	return item


static func _clean(pick: Dictionary) -> Dictionary:
	return {"kind": str(pick.kind), "body": str(pick.body), "index": int(pick.get("index", -1)), "pair": pick.get("pair", Vector2i(-1, -1))}


func _double_click(pick: Dictionary, shift: bool) -> void:
	if pick.is_empty():
		return
	var item := _clean(pick)
	var entry: Dictionary = _subd.get(item.body, {})
	if entry.is_empty():
		return
	var topo: CAGE.Topo = entry.topo
	var previous := _prev_selection.filter(func(s: Dictionary) -> bool: return s.body == item.body and s.kind == item.kind and _item_key(s) != _item_key(item))
	match item.kind:
		"edge":
			if shift and not previous.is_empty():
				_range_to(previous.back(), item, topo)
				return
			var loop := topo.edge_loop(int(item.index))
			var items: Array[Dictionary] = []
			for e in loop:
				items.append(_edge_item(item.body, topo, e))
			if shift:
				_add_items(items)
			else:
				selection = items
		"face":
			if shift and not previous.is_empty():
				_range_to(previous.back(), item, topo)
				return
			if previous.size() == 1 and _faces_adjacent(topo, int(previous[0].index), int(item.index)):
				var loop := topo.face_loop(int(previous[0].index), int(item.index))
				var items: Array[Dictionary] = []
				for f in loop:
					items.append({"kind": "face", "body": item.body, "index": f, "pair": Vector2i(-1, -1)})
				selection = items
			else:
				selection = [{"kind": "body", "body": item.body, "index": -1, "pair": Vector2i(-1, -1)}]
		"vertex":
			if shift and not previous.is_empty():
				var a := int(previous.back().index)
				var b := int(item.index)
				if topo.edge_index(a, b) >= 0:
					var items: Array[Dictionary] = []
					for v in topo.vertex_loop(a, b):
						items.append({"kind": "vertex", "body": item.body, "index": v, "pair": Vector2i(-1, -1)})
					_add_items(items)
				else:
					_range_to(previous.back(), item, topo)
				return
			selection = [item]
		"body":
			selection = [item]
	_selection_changed()


func _range_to(from: Dictionary, to: Dictionary, topo: CAGE.Topo) -> void:
	var kind: String = to.kind
	var found := topo.range_select(kind, int(from.index), int(to.index))
	if found.is_empty():
		workspace.flash("Those two aren't on one loop or ring.")
		return
	var items: Array[Dictionary] = []
	for x in found:
		items.append(_edge_item(to.body, topo, x) if kind == "edge" else {"kind": kind, "body": to.body, "index": x, "pair": Vector2i(-1, -1)})
	_add_items(items)
	_selection_changed()


static func _faces_adjacent(topo: CAGE.Topo, a: int, b: int) -> bool:
	return a != b and topo.face_neighbors(a).has(b)


static func _edge_item(body_id: String, topo: CAGE.Topo, e: int) -> Dictionary:
	var ab := topo.edge_vertices(e)
	return {"kind": "edge", "body": body_id, "index": e, "pair": Vector2i(ab.x, ab.y)}


func _add_items(items: Array) -> void:
	for item in items:
		if _selection_index(item) < 0:
			selection.append(item)


func _paint(at: Vector2) -> void:
	var item := _for_slot(pick_at(at, _slot_kinds()))
	if not item.is_empty() and _selection_index(item) < 0:
		selection.append(item)
		viewport.redraw_overlay()


## Window (rect: two corners) or freeform (outline) selection: left to right takes items wholly
## inside, right to left any item reaching in. Hidden items are left out unless select-through.
func _region_select(shape: PackedVector2Array, crossing: bool, additive: bool, lasso: bool) -> void:
	var rect := Rect2(shape[0], shape[1] - shape[0]).abs() if not lasso and shape.size() >= 2 else Rect2()
	if not lasso and rect.size.length() < 4.0:
		if not additive:
			selection.clear()
		_selection_changed()
		return
	var inside := func(p: Vector2) -> bool:
		if not p.is_finite():
			return false
		return Geometry2D.is_point_in_polygon(p, shape) if lasso else rect.has_point(p)
	# The region's outline, for "crosses the region" tests (right to left takes any item crossed).
	var outline := shape if lasso else PackedVector2Array([rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)])
	var crosses := func(a: Vector2, b: Vector2) -> bool:
		if not a.is_finite() or not b.is_finite():
			return false
		for i in outline.size():
			if Geometry2D.segment_intersects_segment(a, b, outline[i], outline[(i + 1) % outline.size()]) != null:
				return true
		return false
	var kind := _region_kind()
	if not additive:
		selection.clear()
	for shown in _shown_bodies():
		if shown.preview:
			continue
		var id: String = shown.id
		var entry: Dictionary = shown.entry
		var topo: CAGE.Topo = entry.topo
		var pts := _screen_points(id, entry, shown.mode)
		match kind:
			"vertex":
				var flags := PackedByteArray()
				if not viewport.select_through:
					flags = _visible(entry, shown.mode, _points_v3(entry, shown.mode))
				for v in pts.size():
					if inside.call(pts[v]) and (flags.is_empty() or flags[v] != 0):
						_add_items([{"kind": "vertex", "body": id, "index": v, "pair": Vector2i(-1, -1)}])
			"edge":
				# An edge is seen when its midpoint is (an edge behind the body is not taken
				# because one of its ends shows on the silhouette).
				var flags := PackedByteArray()
				if not viewport.select_through:
					flags = _visible(entry, shown.mode, _edge_mid_points(entry, shown.mode))
				for e in topo.nE:
					if not flags.is_empty() and flags[e] == 0:
						continue
					var ab := topo.edge_vertices(e)
					var a: bool = inside.call(pts[ab.x])
					var b: bool = inside.call(pts[ab.y])
					if (a and b) or (crossing and (a or b or crosses.call(pts[ab.x], pts[ab.y]))):
						_add_items([_edge_item(id, topo, e)])
			"face":
				# A face is seen when its centre is: back faces along the silhouette are left
				# out unless select-through is on.
				var flags := PackedByteArray()
				if not viewport.select_through:
					flags = _visible(entry, shown.mode, _face_centre_points(entry, shown.mode))
				for f in topo.nF:
					if not flags.is_empty() and flags[f] == 0:
						continue
					var count := 0
					var s := topo.face_offsets[f]
					var n := topo.face_offsets[f + 1] - s
					var polygon := PackedVector2Array()
					for h in range(s, s + n):
						var v := topo.face_indices[h]
						polygon.append(pts[v])
						if inside.call(pts[v]):
							count += 1
					var take := count == n
					if crossing and not take:
						take = count > 0
						for k in n:
							if take:
								break
							take = crosses.call(polygon[k], polygon[(k + 1) % n])
						# A region drawn inside the face.
						if not take and outline[0].is_finite():
							take = Geometry2D.is_point_in_polygon(outline[0], polygon)
					if take:
						_add_items([{"kind": "face", "body": id, "index": f, "pair": Vector2i(-1, -1)}])
			_:
				var count := 0
				for v in pts.size():
					if inside.call(pts[v]):
						count += 1
				if count > 0 and (crossing or count == pts.size()):
					_add_items([{"kind": "body", "body": id, "index": -1, "pair": Vector2i(-1, -1)}])
	_selection_changed()


## One point per face where its visibility is tested: the limit surface at the face centre
## (Smooth), else a point on the cage polygon's first fan triangle (the polygons Box and Control
## Frame pick against).
func _face_centre_points(entry: Dictionary, mode: String) -> PackedVector3Array:
	var topo: CAGE.Topo = entry.topo
	var cage: Dictionary = entry.cage
	var out := PackedVector3Array()
	out.resize(topo.nF)
	var subd: RefCounted = entry.get("subd")
	if mode == "smooth" and subd != null and str(entry.error) == "" and not (entry.tess as Dictionary).is_empty():
		var faces := PackedInt32Array()
		var uvs := PackedVector2Array()
		for f in topo.nF:
			faces.append(f)
			uvs.append(Vector2(0.5, 0.5) if topo.face_size(f) == 4 else subd.subface_uv(f, 0, 1.0, 1.0))
		var r: Dictionary = subd.evaluate(faces, uvs)
		var p: PackedFloat64Array = r.get("positions", PackedFloat64Array())
		if p.size() == 3 * topo.nF:
			for f in topo.nF:
				out[f] = Vector3(p[3 * f], p[3 * f + 1], p[3 * f + 2])
			return out
	for f in topo.nF:
		var s := topo.face_offsets[f]
		out[f] = (CAGE.position(cage, topo.face_indices[s]) + CAGE.position(cage, topo.face_indices[s + 1]) + CAGE.position(cage, topo.face_indices[s + 2])) / 3.0
	return out


## One point per edge where its visibility is tested: the limit curve's midpoint (Smooth), else
## the cage edge's midpoint.
func _edge_mid_points(entry: Dictionary, mode: String) -> PackedVector3Array:
	var topo: CAGE.Topo = entry.topo
	var cage: Dictionary = entry.cage
	var out := PackedVector3Array()
	out.resize(topo.nE)
	var subd: RefCounted = entry.get("subd")
	if mode == "smooth" and subd != null and str(entry.error) == "" and not (entry.tess as Dictionary).is_empty():
		var faces := PackedInt32Array()
		var uvs := PackedVector2Array()
		const SIDE_MID := [Vector2(0.5, 0.0), Vector2(1.0, 0.5), Vector2(0.5, 1.0), Vector2(0.0, 0.5)]
		for e in topo.nE:
			var h := topo.edge_he[e]
			var f := topo.he_face[h]
			var k := h - topo.face_offsets[f]
			faces.append(f)
			uvs.append(SIDE_MID[k] if topo.face_size(f) == 4 else subd.subface_uv(f, k, 1.0, 0.0))
		var r: Dictionary = subd.evaluate(faces, uvs)
		var p: PackedFloat64Array = r.get("positions", PackedFloat64Array())
		if p.size() == 3 * topo.nE:
			for e in topo.nE:
				out[e] = Vector3(p[3 * e], p[3 * e + 1], p[3 * e + 2])
			return out
	for e in topo.nE:
		var ab := topo.edge_vertices(e)
		out[e] = (CAGE.position(cage, ab.x) + CAGE.position(cage, ab.y)) * 0.5
	return out


## The kind a region selection takes: the first enabled kind in the view's priority order.
func _region_kind() -> String:
	var kinds := _slot_kinds()
	for kind in PICKING.PRIORITY_ORDER.get(viewport.priority, PICKING.PRIORITY_ORDER.default):
		if viewport.filters.get(kind, true) and (kinds.is_empty() or kinds.has(kind)):
			return kind
	return "face"


# --- Selection -------------------------------------------------------------------------------

func _item_key(item: Dictionary) -> String:
	if item.is_empty():
		return ""
	if str(item.kind) == "edge":
		var pair: Vector2i = item.get("pair", Vector2i(-1, -1))
		return "edge:%s:%d-%d" % [item.body, mini(pair.x, pair.y), maxi(pair.x, pair.y)]
	return "%s:%s:%d" % [item.kind, item.body, int(item.get("index", -1))]


func _selection_index(item: Dictionary) -> int:
	var key := _item_key(item)
	for i in selection.size():
		if _item_key(selection[i]) == key:
			return i
	return -1


func _is_selected(item: Dictionary) -> bool:
	if item.is_empty():
		return false
	if _selection_index(item) >= 0:
		return true
	# An element of a selected body counts as selected (it drags the body).
	for s in selection:
		if s.kind == "body" and s.body == item.get("body", ""):
			return true
	return false


## Drops selected elements that no longer exist (edges are found again by their vertex pairs).
func _prune_selection() -> void:
	var kept: Array[Dictionary] = []
	for item in selection:
		var entry: Dictionary = _subd.get(item.body, {})
		if entry.is_empty():
			continue
		var topo: CAGE.Topo = entry.topo
		match str(item.kind):
			"vertex":
				if int(item.index) < topo.nV:
					kept.append(item)
			"face":
				if int(item.index) < topo.nF:
					kept.append(item)
			"edge":
				var e := topo.edge_index(item.pair.x, item.pair.y)
				if e >= 0:
					item.index = e
					kept.append(item)
			"body":
				kept.append(item)
	selection = kept
	if not hover.is_empty() and not _subd.has(str(hover.get("body", ""))):
		hover = {}


func _selection_changed() -> void:
	_overlay_valid = false
	if tool != "" and tool != "edit_form":
		_sync_picks()
		_update_preview()
		# Handles that follow the picks (Insert Edge's slider on the picked edge's rail).
		_update_handles()
	_update_partners()
	_update_soft()
	_update_gizmo()
	_refresh_meshes()
	viewport.redraw_overlay()
	workspace._update_status()
	workspace.selection_updated.emit()


## The selection as form_ops selections per body: {body id: {"vertices", "edges", "faces", "body"}}.
func selection_by_body(items: Array = []) -> Dictionary:
	return FORM_TOOLS.by_body(selection if items.is_empty() else items)


## The vertices a selection moves, per body (a body selection moves all of them).
func _selected_vertices() -> Dictionary:
	var out := {}
	var groups := selection_by_body()
	for body_id in groups:
		var cage := cage_of(body_id)
		if cage.is_empty():
			continue
		out[body_id] = FORM_OPS._sel_vertices_ordered(cage, groups[body_id])
	return out


func _update_partners() -> void:
	_partners.clear()
	var groups := selection_by_body()
	for body_id in groups:
		var cage := cage_of(body_id)
		if cage.is_empty() or (cage.get("symmetry", []) as Array).is_empty():
			continue
		var sel: Dictionary = groups[body_id]
		var ps := FORM_OPS.partner_selection(cage, sel)
		var mine := {}
		for item in selection:
			mine[_item_key(item)] = true
		var entry: Dictionary = _subd.get(body_id, {})
		var topo: CAGE.Topo = entry.get("topo")
		for v in ps.get("vertices", PackedInt32Array()):
			var item := {"kind": "vertex", "body": body_id, "index": v, "pair": Vector2i(-1, -1)}
			if not mine.has(_item_key(item)):
				_partners.append(item)
		var pairs: PackedInt32Array = ps.get("edges", PackedInt32Array())
		for i in pairs.size() / 2:
			var item := {"kind": "edge", "body": body_id, "index": topo.edge_index(pairs[2 * i], pairs[2 * i + 1]) if topo != null else -1,
				"pair": Vector2i(pairs[2 * i], pairs[2 * i + 1])}
			if not mine.has(_item_key(item)):
				_partners.append(item)


func select_all() -> void:
	selection.clear()
	var kind := "face" if viewport.filters.get("face", true) else ("vertex" if viewport.filters.get("vertex", true) else ("edge" if viewport.filters.get("edge", true) else "body"))
	for shown in _shown_bodies():
		if shown.preview:
			continue
		var id: String = shown.id
		var topo: CAGE.Topo = shown.entry.topo
		match kind:
			"face":
				for f in topo.nF:
					selection.append({"kind": "face", "body": id, "index": f, "pair": Vector2i(-1, -1)})
			"vertex":
				for v in topo.nV:
					selection.append({"kind": "vertex", "body": id, "index": v, "pair": Vector2i(-1, -1)})
			"edge":
				for e in topo.nE:
					selection.append(_edge_item(id, topo, e))
			_:
				selection.append({"kind": "body", "body": id, "index": -1, "pair": Vector2i(-1, -1)})
	_selection_changed()


func clear_selection() -> void:
	selection.clear()
	_selection_changed()


func invert_selection() -> void:
	if selection.is_empty():
		select_all()
		return
	var out: Array[Dictionary] = []
	var by_kind := {}
	for item in selection:
		var key := "%s|%s" % [item.body, item.kind]
		if not by_kind.has(key):
			by_kind[key] = PackedInt32Array()
		var list: PackedInt32Array = by_kind[key]
		list.append(int(item.index))
		by_kind[key] = list
	for key in by_kind:
		var parts: PackedStringArray = str(key).split("|")
		var body_id := parts[0]
		var kind := parts[1]
		var entry: Dictionary = _subd.get(body_id, {})
		if entry.is_empty():
			continue
		var topo: CAGE.Topo = entry.topo
		if kind == "body":
			# Invert works within a body's elements; another body of the form takes the place
			# of a selected one.
			for other in body_ids():
				if str(other) != body_id and not _selection_has_body(str(other)):
					out.append({"kind": "body", "body": str(other), "index": -1, "pair": Vector2i(-1, -1)})
			continue
		for x in topo.invert(kind, by_kind[key]):
			out.append(_edge_item(body_id, topo, x) if kind == "edge" else {"kind": kind, "body": body_id, "index": x, "pair": Vector2i(-1, -1)})
	if out.is_empty():
		workspace.flash("Inverting would leave nothing selected (a whole body is selected, or everything of that kind).")
		return
	selection = out
	_selection_changed()


func _selection_has_body(body_id: String) -> bool:
	for item in selection:
		if item.kind == "body" and item.body == body_id:
			return true
	return false


## Selection helpers (Form > Select, keys and the Edit Form panel): "loop", "loop_grow", "ring",
## "ring_grow", "ring_shrink", "grow", "shrink", "range", "invert", "feature". No undo step.
func select_helper(kind: String) -> void:
	if kind == "invert":
		invert_selection()
		return
	if selection.is_empty():
		workspace.flash("Select cage elements first.")
		return
	var out: Array[Dictionary] = []
	var groups := {}
	var why := ""
	for item in selection:
		var key := "%s|%s" % [item.body, item.kind]
		if not groups.has(key):
			groups[key] = []
		(groups[key] as Array).append(item)
	for key in groups:
		var items: Array = groups[key]
		var body_id: String = items[0].body
		var k: String = items[0].kind
		var entry: Dictionary = _subd.get(body_id, {})
		if entry.is_empty() or k == "body":
			out.append_array(items)
			continue
		var topo: CAGE.Topo = entry.topo
		var ids := PackedInt32Array()
		for item in items:
			ids.append(int(item.index))
		var result := PackedInt32Array()
		match kind:
			"loop":
				if k == "edge":
					for e in ids:
						result.append_array(topo.edge_loop(e))
				elif k == "vertex" and ids.size() >= 2:
					result = topo.vertex_loop(ids[ids.size() - 2], ids[ids.size() - 1])
				elif k == "face" and ids.size() >= 2:
					result = topo.face_loop(ids[ids.size() - 2], ids[ids.size() - 1])
				else:
					result = ids
			"loop_grow":
				result = topo.loop_grow(ids) if k == "edge" else ids
			"ring":
				if k == "edge":
					for e in ids:
						result.append_array(topo.edge_ring(e))
				else:
					result = ids
			"ring_grow":
				result = topo.ring_grow(ids) if k == "edge" else ids
			"ring_shrink":
				result = topo.ring_shrink(ids) if k == "edge" else ids
			"grow":
				result = topo.grow(k, ids)
			"shrink":
				result = topo.shrink(k, ids)
			"range":
				result = ids.duplicate()
				if ids.size() >= 2:
					result.append_array(topo.range_select(k, ids[ids.size() - 2], ids[ids.size() - 1]))
			"feature":
				if k == "face":
					for f in ids:
						result.append_array(topo.feature_faces(f, cage_of(body_id)))
				else:
					result = ids
		if result.is_empty():
			# Nothing to take: the selection stays and the flash says what the helper needs.
			out.append_array(items)
			if why == "":
				why = _helper_needs(kind, k)
			continue
		var seen := {}
		for x in result:
			if seen.has(x):
				continue
			seen[x] = true
			out.append(_edge_item(body_id, topo, x) if k == "edge" else {"kind": k, "body": body_id, "index": x, "pair": Vector2i(-1, -1)})
	selection = out
	if why != "":
		workspace.flash(why)
	_selection_changed()


## What a selection helper needs when it found nothing to take.
static func _helper_needs(kind: String, element: String) -> String:
	match kind:
		"loop":
			if element == "face":
				return "Pick two neighbouring faces for a face loop."
			if element == "vertex":
				return "Pick two neighbouring vertices for a vertex loop."
			return "No loop runs through that selection."
		"feature":
			return "No closed loop of faces runs through that face (feature selection needs a band around a strut or a hole)."
		"range":
			return "Those two aren't on one loop or ring."
		"shrink":
			return "Shrinking would leave nothing selected."
	return "That selection helper found nothing to add here."


# --- Keys ------------------------------------------------------------------------------------

## Keys while the form is open (called before the workspace's Ctrl/Alt guard). True when used.
func handle_key(event: InputEventKey) -> bool:
	if not active or suspended:
		return false
	var alt := event.alt_pressed
	if alt and not event.ctrl_pressed:
		match event.keycode:
			KEY_1:
				set_display("box")
				return true
			KEY_2:
				set_display("frame")
				return true
			KEY_3:
				set_display("smooth")
				return true
			KEY_P:
				select_helper("loop")
				return true
			KEY_O:
				select_helper("loop_grow")
				return true
			KEY_L:
				select_helper("ring")
				return true
			KEY_K:
				select_helper("ring_grow")
				return true
			KEY_J:
				select_helper("ring_shrink")
				return true
			KEY_M:
				select_helper("range")
				return true
			KEY_N:
				select_helper("invert")
				return true
			KEY_H:
				select_helper("feature")
				return true
		return false
	if event.shift_pressed and not event.ctrl_pressed and event.keycode in [KEY_UP, KEY_DOWN]:
		select_helper("grow" if event.keycode == KEY_UP else "shrink")
		return true
	if event.ctrl_pressed and event.keycode == KEY_A and not event.shift_pressed:
		select_all()
		return true
	if event.ctrl_pressed or event.meta_pressed:
		return false
	match event.keycode:
		KEY_DELETE, KEY_BACKSPACE:
			delete_selection()
			return true
		KEY_ENTER, KEY_KP_ENTER:
			if tool != "":
				tool_ok()
				return true
			return false
		KEY_ESCAPE:
			if viewport.nav_mode != 0:
				return false
			if workspace.marking_menu.visible:
				return false
			if not _drag.is_empty():
				_cancel_drag()
			elif tool != "":
				cancel_tool()
			elif not selection.is_empty():
				clear_selection()
			else:
				return false
			return true
	return false


## Marking-menu entries while the form is open.
func context_entries(_at := Vector2.INF) -> Array[Dictionary]:
	var has := not selection.is_empty()
	var entries: Array[Dictionary] = []
	for spec in [["Edit Form", "edit_form"], ["Insert Edge", "insert_edge"], ["Subdivide", "subdivide"], ["Crease", "crease"], ["UnCrease", "uncrease"]]:
		var id: String = spec[1]
		var wired := FORM_TOOLS.has_tool(id)
		entries.append({"label": spec[0], "enabled": wired, "tooltip": "" if wired else "%s isn't wired yet." % spec[0],
			"action": func() -> void: start_tool(id)})
	for mode in ["box", "frame", "smooth"]:
		var m: String = mode
		entries.append({"label": "Display %s" % DISPLAY_LABELS[m], "action": func() -> void: set_display(m)})
	if has:
		entries.append({"label": "Delete", "action": func() -> void: delete_selection()})
	entries.append({"label": "Finish Form", "action": finish})
	return entries


# --- Display modes and palette ----------------------------------------------------------------

## Sets the display mode of the selection's bodies (every body when nothing is selected): one
## view-only undo step "Form: Display Mode" (no rebuild).
func set_display(mode: String, bodies: Array = []) -> void:
	if not active or not mode in FORM.DISPLAY_MODES:
		return
	var targets := bodies.duplicate()
	if targets.is_empty():
		for item in selection:
			if not targets.has(item.body):
				targets.append(item.body)
	if targets.is_empty():
		targets = body_ids()
	if targets.is_empty():
		workspace.flash("The form has no bodies yet.")
		return
	var fid := feature_id
	var changed := false
	for body_id in targets:
		if display_mode(body_id) != mode:
			changed = true
	if not changed:
		_sync_palette()
		return
	workspace.change("Form: Display Mode", func() -> void:
		var f: Resource = workspace.doc.find_feature(fid)
		if f == null:
			return
		if not f.options.has("display"):
			f.options["display"] = {}
		for body_id in targets:
			f.options.display[body_id] = mode)
	workspace.flash("%s display" % DISPLAY_LABELS[mode])


func set_display_quality(quality: String) -> void:
	display_quality = "draft" if quality == "draft" else "fine"
	for id in _subd:
		var entry: Dictionary = _subd[id]
		_tessellate(entry)
		entry.version = int(entry.version) + 1
		_forget_screen(entry)
	_mesh_entries.clear()
	_overlay_valid = false
	_refresh_meshes()
	viewport.redraw_overlay()


## Conversion quality of the form ("draft" L4, "standard" L6, "high" L8): one undo step.
func set_conversion_quality(quality: String) -> void:
	if feature == null or not FORM.QUALITY_LEVELS.has(quality) or str(feature.options.get("quality", "standard")) == quality:
		return
	var fid := feature_id
	workspace.change("Form: Conversion Quality", func() -> void:
		var f: Resource = workspace.doc.find_feature(fid)
		if f != null:
			f.options["quality"] = quality)


func _build_palette() -> void:
	palette = FLOATING_PANEL.new()
	palette.visible = false
	palette.title = "FORM"
	palette.min_content_size = Vector2(170, 64)
	palette.place(Vector2(10, 40))
	var box: VBoxContainer = palette.content
	var display_label := Label.new()
	display_label.text = "Display"
	box.add_child(display_label)
	var modes := HFlowContainer.new()
	for spec in [["box", "Box", "Cage only, flat (Alt+1)"], ["frame", "Frame", "Smooth surface with the cage around it (Alt+2)"], ["smooth", "Smooth", "Smooth surface only (Alt+3)"]]:
		var button := Button.new()
		button.text = spec[1]
		button.toggle_mode = true
		button.tooltip_text = spec[2] + ": the selected bodies, or all"
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var mode: String = spec[0]
		button.pressed.connect(func() -> void:
			set_display(mode)
			_sync_palette())
		modes.add_child(button)
		_palette_buttons[mode] = button
	box.add_child(modes)
	var quality_row := HBoxContainer.new()
	var quality_label := Label.new()
	quality_label.text = "Display quality"
	quality_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	quality_row.add_child(quality_label)
	_palette_quality = OptionButton.new()
	_palette_quality.add_item("Fine")
	_palette_quality.set_item_metadata(0, "fine")
	_palette_quality.add_item("Draft")
	_palette_quality.set_item_metadata(1, "draft")
	_palette_quality.tooltip_text = "Draft draws the smooth surface coarser, for big cages"
	_palette_quality.item_selected.connect(func(index: int) -> void: set_display_quality(str(_palette_quality.get_item_metadata(index))))
	quality_row.add_child(_palette_quality)
	box.add_child(quality_row)
	_palette_symmetry = CheckBox.new()
	_palette_symmetry.text = "Show symmetry"
	_palette_symmetry.button_pressed = true
	_palette_symmetry.tooltip_text = "Mirror planes and seams"
	_palette_symmetry.toggled.connect(func(on: bool) -> void:
		show_symmetry = on
		_mesh_entries.clear()
		_overlay_valid = false
		_refresh_meshes()
		viewport.redraw_overlay())
	box.add_child(_palette_symmetry)
	var conversion_row := HBoxContainer.new()
	var conversion_label := Label.new()
	conversion_label.text = "Conversion"
	conversion_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	conversion_row.add_child(conversion_label)
	_palette_conversion = OptionButton.new()
	for spec in [["draft", "Draft"], ["standard", "Standard"], ["high", "High"]]:
		_palette_conversion.add_item(spec[1])
		_palette_conversion.set_item_metadata(_palette_conversion.item_count - 1, spec[0])
	_palette_conversion.tooltip_text = "How closely Finish Form's exact surfaces follow the smooth surface"
	_palette_conversion.item_selected.connect(func(index: int) -> void: set_conversion_quality(str(_palette_conversion.get_item_metadata(index))))
	conversion_row.add_child(_palette_conversion)
	box.add_child(conversion_row)
	_finish_button = Button.new()
	_finish_button.text = "FINISH FORM"
	_finish_button.tooltip_text = "Convert the form's bodies and return to the workspace"
	_finish_button.pressed.connect(finish)
	palette.footer.add_child(_finish_button)
	for button in palette.find_children("*", "BaseButton", true, false):
		(button as BaseButton).focus_mode = Control.FOCUS_NONE
	viewport.add_child(palette)
	var command_panel: Variant = workspace.get("panel")
	if command_panel is Control and (command_panel as Control).get_parent() == viewport:
		viewport.move_child(palette, (command_panel as Control).get_index())
	palette.set_store(FLOATING_PANEL.default_store(), "form_palette")
	_style_finish()


## The palette's toggles show the display mode of the selection's bodies (or the first body).
func _sync_palette() -> void:
	if palette == null:
		return
	var body := ""
	for item in selection:
		body = item.body
		break
	if body == "" and not body_ids().is_empty():
		body = str(body_ids()[0])
	var mode := display_mode(body) if body != "" else ""
	for key in _palette_buttons:
		(_palette_buttons[key] as Button).set_pressed_no_signal(key == mode)
	_palette_quality.select(1 if display_quality == "draft" else 0)
	var quality := str(feature.options.get("quality", "standard")) if feature != null else "standard"
	for i in _palette_conversion.item_count:
		if str(_palette_conversion.get_item_metadata(i)) == quality:
			_palette_conversion.select(i)


func _style_finish() -> void:
	var green := Color("#3fb26a")
	for state in ["normal", "hover", "pressed", "focus", "hover_pressed"]:
		var style := StyleBoxFlat.new()
		style.bg_color = green.lightened(0.12) if state == "hover" else (green.darkened(0.15) if state in ["pressed", "hover_pressed"] else green)
		style.set_corner_radius_all(4)
		style.content_margin_left = 10
		style.content_margin_right = 10
		style.content_margin_top = 5
		style.content_margin_bottom = 5
		_finish_button.add_theme_stylebox_override(state, style)
	for state in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_hover_pressed_color"]:
		_finish_button.add_theme_color_override(state, Color.WHITE)


## Colours from a palette (forge_theme.gd): the materials, the overlay, the palette.
func apply_theme(colors: Dictionary) -> void:
	theme_colors = colors.duplicate(true)
	display.apply_theme(theme_colors)
	palette.apply_style(theme_colors.get("panel_style", {}))
	_style_finish()
	_mesh_entries.clear()
	_overlay_valid = false
	if active:
		_refresh_meshes()
	viewport.redraw_overlay()


# --- Delete ------------------------------------------------------------------------------------

## Deletes the selection: faces, dissolved edges and vertices (partners too), whole bodies. One
## undo step "Form: Delete". True when the form took the key.
func delete_selection() -> bool:
	if not active:
		return false
	if selection.is_empty():
		workspace.flash("Select cage faces, edges, vertices or bodies to delete.")
		return true
	var groups := selection_by_body()
	var cages := {}
	var removed := []
	for body_id in groups:
		var sel: Dictionary = groups[body_id]
		if bool(sel.body):
			removed.append(body_id)
			continue
		var r := FORM_OPS.delete_elements(cage_of(body_id), sel, {})
		if not r.ok:
			workspace.flash(str(r.error))
			return true
		cages[body_id] = r.cage
	var fid := feature_id
	selection.clear()
	hover = {}
	workspace.change("Form: Delete", func() -> void:
		apply_result(fid, {"ok": true, "cages": cages, "removed_bodies": removed}, []))
	return true


## Writes a tool result into the form feature of the document (inside a change()).
func apply_result(fid: String, r: Dictionary, new_ids: Array) -> void:
	var doc: Resource = workspace.doc
	var f: Resource = doc.find_feature(fid)
	if f == null:
		return
	if not f.options.has("bodies"):
		f.options["bodies"] = {}
	if not f.options.has("display"):
		f.options["display"] = {}
	if not f.options.has("breps"):
		f.options["breps"] = {}
	var bodies: Dictionary = f.options.bodies
	for body_id in r.get("cages", {}):
		if bodies.has(body_id):
			bodies[body_id] = r.cages[body_id]
	for cage in r.get("new_bodies", []):
		var id: String = doc.new_body(fid)
		bodies[id] = cage
		new_ids.append(id)
	for body_id in r.get("removed_bodies", []):
		bodies.erase(body_id)
		(f.options.display as Dictionary).erase(body_id)
		doc.bodies.erase(body_id)
	var notes: Dictionary = r.get("brep_notes", {})
	for body_id in r.get("breps", {}):
		bodies.erase(body_id)
		f.options.breps[body_id] = r.breps[body_id]
		if not f.options.has("brep_notes"):
			f.options["brep_notes"] = {}
		if (notes.get(body_id, PackedStringArray()) as PackedStringArray).is_empty():
			(f.options.brep_notes as Dictionary).erase(body_id)
		else:
			f.options.brep_notes[body_id] = notes[body_id]
		if not doc.bodies.has(body_id):
			doc.bodies[body_id] = {"name": body_id, "visible": true, "locked": false, "feature": fid, "component": doc.active_component}
	for body_id in r.get("display", {}):
		f.options.display[body_id] = r.display[body_id]


# --- Tools (contract C7) ---------------------------------------------------------------------

## Starts a registry tool: pre-fills its first pick from the selection, shows its panel, asks for
## a placement plane (primitives) and previews.
func start_tool(id: String) -> void:
	if not active:
		workspace.flash(OPEN_FIRST)
		return
	var spec := FORM_TOOLS.spec(id)
	if spec.is_empty():
		workspace.flash("%s isn't wired yet." % id.capitalize())
		return
	if bool(spec.get("native", false)) and not ClassDB.class_exists("CadSubD"):
		workspace.flash("%s needs the Holo Forge kernel." % str(spec.title))
		return
	if suspended:
		_close_command()
		resume()
	cancel_tool()
	tool = id
	tool_state = {}
	tool_picks = {}
	if bool(spec.get("select_through", false)):
		# (Weld Vertices) Window and click selection take hidden vertices while the tool runs.
		_restore_select_through = viewport.select_through
		viewport.select_through = true
	var size_m: float = workspace.nice_size(viewport.distance * 0.25)
	tool_values = FORM_TOOLS.defaults(id, units(), size_m, _edge_default())
	if bool(spec.get("uses_selection", false)):
		_sync_picks()
	_show_tool_panel()
	if bool(spec.get("plane", false)):
		workspace.start_plane_pick(_on_tool_plane, "%s: pick a plane or flat face (OK places it on the XY plane)." % spec.title)
	else:
		workspace.flash(_tool_hint())
	if id == "edit_form" and selection.is_empty():
		workspace.flash(NO_SELECTION)
	_update_preview()
	_update_soft()
	_update_gizmo()
	_update_handles()
	_refresh_meshes()
	viewport.redraw_overlay()


func _tool_hint() -> String:
	var spec := FORM_TOOLS.spec(tool)
	var picks: Array = spec.get("picks", [])
	if tool == "edit_form":
		return "Edit Form: drag the gizmo; Alt-drag extrudes faces or extends open edges."
	if str(spec.get("hint", "")) != "":
		return str(spec.hint)
	if picks.is_empty():
		return "%s: set the options, then OK." % spec.title
	var first: Dictionary = picks[0]
	return "%s: pick %s, then OK." % [spec.title, str(first.get("label", "cage elements")).to_lower()]


## Twice the mean length of the edges touching the selection (Edit Form's soft distance).
func _edge_default() -> float:
	var total := 0.0
	var count := 0
	var verts := _selected_vertices()
	for body_id in verts:
		var entry: Dictionary = _subd.get(body_id, {})
		if entry.is_empty():
			continue
		var topo: CAGE.Topo = entry.topo
		var cage: Dictionary = entry.cage
		for v in verts[body_id]:
			for w in topo.vertex_neighbors(v):
				total += CAGE.position(cage, v).distance_to(CAGE.position(cage, w))
				count += 1
	return 2.0 * total / count if count > 0 else 0.0


func _show_tool_panel() -> void:
	var spec := FORM_TOOLS.spec(tool)
	var fields: Array[Dictionary] = []
	for field in spec.get("fields", []):
		var f: Dictionary = (field as Dictionary).duplicate(true)
		if str(f.get("options", "")) == "bodies":
			var options := [["new", "New Body"]]
			for body_id in body_ids():
				options.append([str(body_id), workspace.doc.body_name(str(body_id))])
			f.options = options
		fields.append(f)
	for pick in spec.get("picks", []):
		fields.push_front({"key": "pick_" + str(pick.key), "type": "info", "text": ""})
	workspace.panel.setup(str(spec.title), fields, tool_values, units())
	workspace.panel.set_ok_text("OK")
	workspace.panel.set_hints({})
	workspace.panel.visible = true
	workspace.place_panel()
	_update_pick_info()


## Sets an info row's text (and its tooltip).
func set_panel_info(key: String, text: String) -> void:
	workspace.panel.set_info(key, text)
	var editors: Variant = workspace.panel.get("_editors")
	if editors is Dictionary and (editors as Dictionary).get(key) is Label:
		((editors as Dictionary)[key] as Label).tooltip_text = text


func _update_pick_info() -> void:
	if tool == "":
		return
	for pick in FORM_TOOLS.spec(tool).get("picks", []):
		var items: Array = tool_picks.get(pick.key, [])
		var label := str(pick.get("label", pick.key))
		var text := "%s: %d selected" % [label, items.size()] if not items.is_empty() else ("%s: pick in the view" % label if bool(pick.get("required", false)) else "%s: none picked (all)" % label)
		workspace.panel.set_info("pick_" + str(pick.key), text)


## The tool's picks from the selection: its first slot takes the selected elements of its kinds
## (a body slot takes the selection's bodies).
func _sync_picks() -> void:
	if tool == "":
		return
	var picks: Array = FORM_TOOLS.spec(tool).get("picks", [])
	if picks.is_empty():
		return
	var slot: Dictionary = picks[0]
	var kinds: Array = slot.get("kinds", [])
	var items := []
	var bodies := {}
	for item in selection:
		if kinds.has(item.kind):
			items.append(item.duplicate())
		elif kinds.has("body") and not bodies.has(item.body):
			bodies[item.body] = true
			items.append({"kind": "body", "body": item.body, "index": -1, "pair": Vector2i(-1, -1)})
	tool_picks[slot.key] = items
	_update_pick_info()


## The panel values evaluated: expressions in meters, radians or plain numbers; enums and checks as
## they are. Expressions that don't evaluate are left out (their errors in _value_errors).
func evaluated_values() -> Dictionary:
	var out := {}
	_value_errors.clear()
	var spec := FORM_TOOLS.spec(tool)
	var params := _parameter_values()
	var kinds := {}
	for field in spec.get("fields", []):
		if str(field.get("type", "")) == "expression":
			kinds[field.key] = str(field.get("kind", "length"))
	for key in tool_values:
		if kinds.has(key):
			var r := UNITS.evaluate(str(tool_values[key]), kinds[key], units(), params)
			if r.get("ok", false):
				out[key] = float(r.value)
			else:
				_value_errors[key] = str(r.get("error", "Can't read this"))
		else:
			out[key] = tool_values[key]
	return out


func _parameter_values() -> Dictionary:
	var known := {}
	var values: Dictionary = workspace.result.get("values", {})
	for name in values:
		if values[name].get("ok", false):
			known[name] = values[name]
	return known


## Panel edits (the workspace forwards them while no command runs).
func on_panel_values(values: Dictionary) -> void:
	if tool == "":
		return
	tool_values = values.duplicate(true)
	# A tool may follow up on what changed (a face count that suits the picked profile).
	var follow: Variant = FORM_TOOLS.hook("values", tool, [self, tool_values], {})
	if follow is Dictionary and not (follow as Dictionary).is_empty():
		for key in follow:
			tool_values[key] = follow[key]
		workspace.panel.set_values(tool_values)
	# Fields that show or hide change the panel's size: place it again.
	workspace.call_deferred("place_panel")
	if tool == "edit_form":
		_update_soft()
		_update_gizmo()
		_refresh_meshes()
		viewport.redraw_overlay()
		return
	_update_preview()
	_update_handles()
	_refresh_meshes()
	viewport.redraw_overlay()


## Values set by the view (a primitive's clicks, a handle drag), shown in the panel as if typed.
func set_tool_values(values: Dictionary) -> void:
	if tool == "":
		return
	for key in values:
		tool_values[key] = values[key]
	workspace.panel.set_values(tool_values)
	_update_preview()
	_update_handles()
	_refresh_meshes()
	viewport.redraw_overlay()


## A primitive's placement: centre and plane axes (the frame its cage is built in).
func set_placement(origin: Vector3, x: Vector3, y: Vector3, normal: Vector3) -> void:
	tool_picks["placement"] = [{"origin": origin, "x": x, "y": y, "normal": normal}]


func _on_tool_plane(frame: Dictionary, _ref: String) -> void:
	if tool == "":
		return
	var x: Vector3 = (frame.get("x", Vector3.RIGHT) as Vector3).normalized()
	var y: Vector3 = (frame.get("y", Vector3.UP) as Vector3).normalized()
	tool_state["plane"] = {"origin": frame.get("origin", Vector3.ZERO), "x": x, "y": y}
	set_placement(frame.get("origin", Vector3.ZERO), x, y, x.cross(y).normalized())
	_update_preview()
	_update_handles()
	_refresh_meshes()
	workspace.flash("%s: click the centre, then drag out the size (or type the sizes and OK)." % str(FORM_TOOLS.spec(tool).title))


func _tool_ctx() -> Dictionary:
	var cages := {}
	if feature != null:
		cages = (feature.options.get("bodies", {}) as Dictionary).duplicate()
	return {"feature": feature, "doc": workspace.doc, "cages": cages, "subd": Callable(self, "subd_of"), "kernel": workspace.kernel,
		"result": workspace.result, "values": evaluated_values(), "editor": self}


## Runs the tool on scratch copies and shows the result instead of the stored cages.
func _update_preview() -> void:
	_preview.clear()
	_preview_hidden.clear()
	if tool == "" or tool == "edit_form" or tool == "display_mode":
		_sync_preview_entries()
		return
	var spec := FORM_TOOLS.spec(tool)
	if not bool(spec.get("preview", false)):
		_sync_preview_entries()
		return
	var ctx := _tool_ctx()
	var values: Dictionary = ctx.values
	var hints := {}
	for key in _value_errors:
		hints[key] = {"ok": false, "text": _value_errors[key]}
	var r := FORM_TOOLS.run(tool, ctx, tool_picks, values) if _value_errors.is_empty() else FORM_TOOLS.failure("")
	# Panel text the tool reports (info.panel: info field key -> text), also when it can't run.
	var panel_text: Variant = (r.info as Dictionary).get("panel", {})
	if panel_text is Dictionary:
		for key in panel_text:
			set_panel_info(str(key), str(panel_text[key]))
	if r.ok:
		for body_id in r.cages:
			_preview[body_id] = r.cages[body_id]
		var k := 0
		for cage in r.new_bodies:
			_preview["__new%d" % k] = cage
			k += 1
		# Bodies the tool would remove (a Face joining two bodies merges them) leave the preview.
		for body_id in r.get("removed_bodies", []):
			_preview_hidden[str(body_id)] = true
		if _last_preview_error != "" and _last_preview_error != FORM_OPS.NOTHING:
			# The reason it couldn't run is gone: say so instead of leaving the old message up.
			workspace.flash("%s: previewed; adjust the values, then OK." % str(spec.title))
		_last_preview_error = ""
	else:
		var error := str(r.error)
		if error != "" and error != _last_preview_error and error != FORM_OPS.NOTHING:
			workspace.flash(error)
		_last_preview_error = error
		# OK greys out while the tool can't run (its first size field carries the reason).
		if error != "" and error != FORM_OPS.NOTHING:
			for field in spec.get("fields", []):
				if str(field.get("type", "")) == "expression":
					hints[field.key] = {"ok": false, "text": error}
					break
	workspace.panel.set_hints(hints)
	# Tools with no expression field to carry the reason (Fill Hole, Weld, Pull...) grey OK too,
	# with the reason as its tooltip.
	var ok_button: Variant = workspace.panel.get("_ok")
	if ok_button is Button:
		var failed: bool = not bool(r.ok) and str(r.error) != "" and str(r.error) != FORM_OPS.NOTHING
		if failed:
			(ok_button as Button).disabled = true
		(ok_button as Button).tooltip_text = str(r.error) if failed else ""
	_sync_preview_entries()


func _sync_preview_entries() -> void:
	for id in _preview_entries.keys():
		if not _preview.has(id):
			_preview_entries.erase(id)
	for id in _preview:
		_sync_entry(_preview_entries, str(id), _preview[id])
	_overlay_valid = false


## OK: runs the tool on the real cages as one undo step "Form: <Title>".
func tool_ok() -> void:
	if tool == "":
		return
	if tool == "edit_form":
		_edit_form_ok()
		return
	if workspace.is_picking_plane():
		workspace._end_plane_pick()
	var spec := FORM_TOOLS.spec(tool)
	var ctx := _tool_ctx()
	if not _value_errors.is_empty():
		workspace.flash("Fix the highlighted values first.")
		return
	var r := FORM_TOOLS.run(tool, ctx, tool_picks, ctx.values)
	if not r.ok:
		workspace.flash(str(r.error) if str(r.error) != "" else "%s can't be applied." % spec.title)
		return
	var id := tool
	var title := str(spec.title)
	var fid := feature_id
	cancel_tool()
	var new_ids := []
	workspace.change("Form: " + title, func() -> void: apply_result(fid, r, new_ids))
	# (The tool's prompt would otherwise stay on the status line after it closed.)
	if (r.warnings as PackedStringArray).is_empty():
		workspace.flash("%s applied." % title)
	for w in r.warnings:
		workspace.flash(str(w))
	var picked: Array = r.get("selection", [])
	if not picked.is_empty():
		selection.clear()
		for item in picked:
			if item is Dictionary:
				selection.append(item)
		_prune_selection()
		_selection_changed()
	if bool(spec.get("repeat", false)):
		start_tool(id)


## Closes the tool: nothing changes in the document.
func cancel_tool() -> void:
	if tool == "":
		return
	if workspace.is_picking_plane():
		workspace._end_plane_pick()
	if str(_drag.get("type", "")) in ["tool_handle", "tool_click"]:
		_drag = {}
	var had_model_slots := not model_refs().is_empty() or not model_kinds().is_empty()
	if _restore_select_through != null:
		# Back to the setting from before the tool (unless it was switched off meanwhile).
		if viewport.select_through:
			viewport.select_through = bool(_restore_select_through)
		_restore_select_through = null
	tool = ""
	tool_values = {}
	tool_picks = {}
	tool_state = {}
	_handles = []
	_preview.clear()
	_preview_hidden.clear()
	_sync_preview_entries()
	if had_model_slots and workspace.get("picker") != null:
		# The picker's profile shading and the picked references' highlights go with the tool.
		workspace.picker.hover = {}
		workspace.picker.update_display()
		workspace._update_highlights()
	_value_errors.clear()
	_last_preview_error = ""
	if not suspended:
		workspace.panel.visible = false
		workspace.panel.set_ok_text("OK")
	_soft.clear()
	_update_gizmo()
	_mesh_entries.clear()
	_refresh_meshes()
	viewport.redraw_overlay()


## A panel button: Edit Form's selection helpers here, the rest to the running tool.
func on_button(key: String) -> void:
	match key:
		"sel_loop":
			select_helper("loop")
		"sel_ring":
			select_helper("ring")
		"sel_grow":
			select_helper("grow")
		"sel_shrink":
			select_helper("shrink")
		_:
			if key == "all" and tool == "unfreeze":
				# Unfreeze's All: everything of every body, applied at once.
				tool_values["all"] = true
				tool_ok()
			elif tool != "":
				# Every other button goes to the tool: button_<id>(editor, key) (Pipe's Add
				# Section, Face's Pick Plane, Erase and Fill's Feature, Match's Alternate...).
				FORM_TOOLS.hook("button", tool, [self, key])


## Runs the tool's preview again and redraws (after a tool's own clicks changed its picks).
func update_tool() -> void:
	if tool == "":
		return
	_update_preview()
	_update_handles()
	_refresh_meshes()
	viewport.redraw_overlay()


# --- Tool handles (distance arrows, counts and sliders) ----------------------------------------

func _update_handles() -> void:
	_handles = []
	if tool == "" or not bool(FORM_TOOLS.spec(tool).get("handles", false)):
		return
	# Primitives draw theirs once placed; other tools (Extrude's distance) whenever they offer some.
	if bool(FORM_TOOLS.spec(tool).get("plane", false)) and (tool_picks.get("placement", []) as Array).is_empty():
		return
	# While a primitive waits for its clicks its handles would take them: they come once the clicks
	# are done.
	var needed := int(FORM_TOOLS.spec(tool).get("clicks", 0))
	var made := (tool_state.get("clicks", []) as Array).size()
	if made < needed:
		return
	var list: Variant = FORM_TOOLS.hook("handles", tool, [self, tool_values], [])
	if list is Array:
		_handles = list


func _handle_shape(handle: Dictionary) -> Dictionary:
	var origin: Vector3 = handle.origin
	if str(handle.type) == "slider":
		# The track from min to max and the knob at the value.
		var d: Vector3 = handle.direction
		var a: Vector2 = viewport.project(origin + d * float(handle.get("min", 0.0)))
		var b: Vector2 = viewport.project(origin + d * float(handle.get("max", 1.0)))
		var k: Vector2 = viewport.project(origin + d * _slider_value(handle))
		if not (a.is_finite() and b.is_finite() and k.is_finite()):
			return {}
		return {"from": a, "to": b, "at": k}
	var dir: Vector3 = (handle.direction as Vector3).normalized()
	var from: Vector2 = viewport.project(origin)
	var wpp := 1.0 / maxf(float(viewport.pixels_per_meter_at(origin)), 1e-12)
	var to: Vector2 = viewport.project(origin + dir * 40.0 * wpp)
	if not (from.is_finite() and to.is_finite()) or from.distance_to(to) < 4.0:
		return {}
	if str(handle.type) == "count":
		return {"at": from, "dir": (to - from).normalized()}
	return {"from": from, "to": to}


## The tool handle a press at at takes. Knobs (face counts, slider knobs) come first, the nearest
## within reach: a knob is a small target and can sit on an arrow's shaft (a Box's Length Faces
## and Height Faces knobs beside its Width and Length arrows), which is still taken along the rest
## of its length. Then arrows in list order.
func _handle_at(at: Vector2) -> Dictionary:
	var knob := {}
	var knob_distance := INF
	for handle in _handles:
		if str(handle.type) == "arrow":
			continue
		var shape := _handle_shape(handle)
		if shape.is_empty():
			continue
		var d := (shape.at as Vector2).distance_to(at)
		if d <= (9.0 if str(handle.type) == "slider" else 12.0) * _ui_scale() and d < knob_distance:
			knob = handle
			knob_distance = d
	if not knob.is_empty():
		return knob
	for handle in _handles:
		if str(handle.type) != "arrow":
			continue
		var shape := _handle_shape(handle)
		if shape.is_empty():
			continue
		if Geometry2D.get_closest_point_to_segment(at, shape.from, shape.to).distance_to(at) <= 8.0 * _ui_scale():
			return handle
	return {}


## A slider handle's value: its field read as a number, within the slider's min and max.
func _slider_value(handle: Dictionary) -> float:
	var r := UNITS.evaluate(str(tool_values.get(handle.key, "0")), UNITS.KIND_NUMBER, units(), _parameter_values())
	var value := float(r.value) if bool(r.get("ok", false)) else 0.0
	return clampf(value, float(handle.get("min", 0.0)), float(handle.get("max", 1.0)))


func _begin_tool_handle(handle: Dictionary, at: Vector2) -> void:
	var ray: Array = viewport.ray_from(at)
	var values := evaluated_values()
	var base := _slider_value(handle) if str(handle.type) == "slider" else float(values.get(handle.key, 0.0))
	_drag = {"type": "tool_handle", "handle": handle, "start": at, "base": base,
		"t0": MANIPULATOR.closest_on_line(handle.origin, handle.direction, ray[0], ray[1])}
	viewport.redraw_overlay()


func _tool_handle_motion(at: Vector2) -> void:
	var handle: Dictionary = _drag.handle
	if str(handle.type) == "count":
		var shape := _handle_shape(handle)
		var dir: Vector2 = shape.get("dir", Vector2.RIGHT)
		var steps := roundi((at - (_drag.start as Vector2)).dot(dir) / (COUNT_PX * _ui_scale()))
		var count := clampi(int(_drag.base) + steps, 1, 64)
		set_tool_values({handle.key: str(count)})
		return
	var ray: Array = viewport.ray_from(at)
	var t := MANIPULATOR.closest_on_line(handle.origin, handle.direction, ray[0], ray[1])
	if is_nan(t) or is_nan(float(_drag.t0)):
		return
	if str(handle.type) == "slider":
		# The knob follows the drag along its segment: the value is the fraction of direction.
		var span := (handle.direction as Vector3).length()
		if span <= 0.0:
			return
		var fraction := clampf(float(_drag.base) + (t - float(_drag.t0)) / span, float(handle.get("min", 0.0)), float(handle.get("max", 1.0)))
		set_tool_values({handle.key: "%.3f" % fraction})
		return
	var value := float(_drag.base) + (t - float(_drag.t0)) * float(handle.get("factor", 1.0))
	if str(handle.get("kind", "length")) == "number":
		value = clampf(value, float(handle.get("min", -INF)), float(handle.get("max", INF)))
		set_tool_values({handle.key: "%.4g" % value})
		return
	value = clampf(value, float(handle.get("min", 1e-6)), float(handle.get("max", INF)))
	var snap: float = viewport.snap_step
	if snap > 0.0:
		value = maxf(snappedf(value, snap), snap)
	set_tool_values({handle.key: UNITS.format_value(value, UNITS.KIND_LENGTH, units())})


# --- Edit Form ---------------------------------------------------------------------------------

## Places the gizmo at the selection (Edit Form only).
func _update_gizmo() -> void:
	gizmo.visible = false
	if not active or tool != "edit_form" or selection.is_empty() or suspended:
		return
	var verts := _selected_vertices()
	var sum := Vector3.ZERO
	var count := 0
	for body_id in verts:
		var cage := cage_of(body_id)
		for v in verts[body_id]:
			sum += CAGE.position(cage, v)
			count += 1
	if count == 0:
		return
	gizmo.pivot = sum / count
	gizmo.basis = _frame_basis(verts)
	gizmo.mode = str(tool_values.get("transform_mode", "multi"))
	gizmo.visible = true
	_queue_panel_check(true)


# --- The command panel and the gizmo ---------------------------------------------------------

## Checks the command panel against the gizmo once, at the end of the frame. home (the gizmo
## changed: the selection, the mode or the frame) places the panel again from its own spot;
## otherwise (the camera moved) the panel only moves when the gizmo is under it, so it doesn't
## jump about while the view turns.
func _queue_panel_check(home: bool) -> void:
	if not active or tool != "edit_form":
		return
	if _panel_check == "":
		call_deferred("_run_panel_check")
	if home:
		_panel_check = "home"
	elif _panel_check == "":
		_panel_check = "keep"


func _run_panel_check() -> void:
	var home := _panel_check == "home"
	_panel_check = ""
	if not is_instance_valid(workspace):
		return
	if home:
		# Puts the panel at its own spot, then calls keep_panel_clear(true).
		workspace.place_panel()
	else:
		keep_panel_clear(false)


## Moves the Edit Form command panel off the gizmo's screen rectangle (the workspace's
## _place_panel calls it with from_home after putting the panel at its own spot, top right under
## the view cube). Nothing moves during a drag. The command panel has no drag of its own, so
## there is no place of the user's to keep.
func keep_panel_clear(_from_home := false) -> void:
	var panel: Variant = workspace.get("panel")
	if not active or tool != "edit_form" or not panel is Control or not _drag.is_empty():
		return
	var control := panel as Control
	if not control.visible:
		return
	var spot := panel_spot(control, gizmo.screen_rect(viewport))
	if spot.is_empty():
		return
	if float(spot.max_height) != float(control.get("max_height")):
		control.set("max_height", float(spot.max_height))
		control.reset_size()
	control.position = spot.position


## Where the command panel goes so it doesn't cover the gizmo: {"position", "max_height"}, or {}
## when it can stay where it is. Tried in order: the view's left side, away from the selection
## (which sits on the right when the panel covers it), beside the palette when that's in the way,
## or under it; the right side under the gizmo (shorter, its rows scroll); just left of the
## gizmo. A place must fit in the view and keep off the palette. When every place still overlaps
## the gizmo, the one covering the least of it (if less than now).
func panel_spot(panel: Control, gizmo_rect: Rect2) -> Dictionary:
	if not gizmo_rect.has_area():
		return {}
	var s := _ui_scale()
	var gap := PANEL_GAP * s
	var view: Vector2 = viewport.size
	var size: Vector2 = panel.size
	var top: float = panel.position.y
	var max_height := float(panel.get("max_height"))
	var here := Rect2(panel.position, size)
	if not here.intersects(gizmo_rect):
		return {}
	var blocked := gizmo_rect.grow(gap)
	var palette_rect := Rect2()
	if palette != null and palette.visible and palette.get_parent() == viewport:
		palette_rect = Rect2(palette.position, palette.size).grow(gap)
	var candidates: Array[Dictionary] = []
	if palette_rect.has_area() and Rect2(Vector2(gap, top), size).intersects(palette_rect):
		candidates.append({"position": Vector2(palette_rect.end.x, top), "max_height": max_height})
		var below := palette_rect.end.y
		candidates.append({"position": Vector2(gap, below), "max_height": maxf(view.y - below - gap, 1.0)})
	else:
		candidates.append({"position": Vector2(gap, top), "max_height": max_height})
	var under := blocked.end.y
	candidates.append({"position": Vector2(here.position.x, under), "max_height": maxf(view.y - under - gap, 1.0)})
	candidates.append({"position": Vector2(blocked.position.x - size.x, top), "max_height": max_height})
	var best := {}
	var best_cover := INF
	for spot in candidates:
		var at: Vector2 = spot.position
		var limit := float(spot.max_height)
		var tall := minf(size.y, limit) if limit > 0.0 else size.y
		# Too short to use (it would only show a row or two).
		if tall < size.y and limit < PANEL_MIN_HEIGHT * s:
			continue
		if at.x < gap - 0.5 or at.x + size.x > view.x - gap + 0.5 or at.y + tall > view.y - gap + 0.5:
			continue
		var rect := Rect2(at, Vector2(size.x, tall))
		if palette_rect.has_area() and rect.intersects(palette_rect):
			continue
		var cover := rect.intersection(gizmo_rect).get_area() if rect.intersects(gizmo_rect) else 0.0
		if cover == 0.0:
			return spot
		if cover < best_cover:
			best_cover = cover
			best = spot
	if not best.is_empty() and best_cover < here.intersection(gizmo_rect).get_area():
		return best
	return {}


## The gizmo's frame in the chosen coordinate space.
func _frame_basis(verts: Dictionary) -> Basis:
	match str(tool_values.get("space", "world")):
		"view":
			return viewport.camera_basis().orthonormalized()
		"selection", "local":
			var z := Vector3.ZERO
			var points := PackedFloat64Array()
			var faces := selection_by_body()
			for body_id in verts:
				var entry: Dictionary = _subd.get(body_id, {})
				if entry.is_empty():
					continue
				var topo: CAGE.Topo = entry.topo
				var cage: Dictionary = entry.cage
				var listed: PackedInt32Array = (faces.get(body_id, {}) as Dictionary).get("faces", PackedInt32Array())
				if not listed.is_empty():
					for f in listed:
						z += topo.face_area_vector(cage, f)
				else:
					for v in verts[body_id]:
						z += topo.vertex_normal(cage, v)
				for v in verts[body_id]:
					points.append_array(CAGE.position_d(cage, v))
				if str(tool_values.get("space", "world")) == "local":
					break
			if z.length() < 1e-12:
				z = Vector3.UP
			z = z.normalized()
			var x := Vector3.RIGHT
			if points.size() >= 6:
				var line := FORM_OPS.best_fit_line(points)
				var d: PackedFloat64Array = line.direction
				x = Vector3(d[0], d[1], d[2])
			x = x - z * x.dot(z)
			if x.length() < 1e-6:
				x = z.cross(Vector3.RIGHT if absf(z.x) < 0.9 else Vector3.FORWARD)
			x = x.normalized()
			return Basis(x, z.cross(x), z)
	return Basis.IDENTITY


## Soft-modification options. The Rectangular extent is measured in the selection's own frame
## (Z = its normal, X / Y in its plane), whatever coordinate space the gizmo shows, so soft_weights
## gets no "frame" and works it out from each body's selected vertices.
func _soft_opts(values: Dictionary, _body_id := "") -> Dictionary:
	return {"extent": str(values.get("extent", "distance")), "distance": float(values.get("distance", 0.0)), "faces": int(values.get("faces", 2)),
		"u_faces": float(values.get("u_faces", 2.0)), "v_faces": float(values.get("v_faces", 2.0)), "transition": str(values.get("transition", "smooth")),
		"weight": clampf(float(values.get("weight", 1.0)), 0.0, 1.0)}


## Soft-modification weights of the selection, and the surface coloured by them (made symmetric:
## a partner shows the weight its mirrored drag moves it by).
func _update_soft() -> void:
	var had := not _soft.is_empty()
	_soft.clear()
	if tool == "edit_form" and bool(tool_values.get("soft", false)) and not selection.is_empty():
		var values := evaluated_values()
		var verts := _selected_vertices()
		for body_id in verts:
			var entry: Dictionary = _subd.get(body_id, {})
			if entry.is_empty():
				continue
			var w := FORM_OPS.soft_weights(entry.cage, entry.topo, verts[body_id], _soft_opts(values, body_id))
			w = FORM_OPS.symmetric_weights(entry.cage, w)
			_soft[body_id] = w
			_tessellate(entry, false, w)
			entry.version = int(entry.version) + 1
	elif had:
		for body_id in _subd:
			var entry: Dictionary = _subd[body_id]
			if (entry.tess as Dictionary).has("weights"):
				_tessellate(entry)
				entry.version = int(entry.version) + 1


func _begin_gizmo(handle: String, event: InputEventMouseButton) -> void:
	var verts := _selected_vertices()
	if verts.is_empty():
		workspace.flash(NO_SELECTION)
		return
	var any_free := false
	var held := 0
	var groups := selection_by_body()
	for body_id in verts:
		var cage := cage_of(body_id)
		# Under symmetry the partners of frozen vertices stay too (FORM_OPS.locked_set).
		var locked := FORM_OPS.locked_set(cage)
		var own := CAGE.locked_vertices(cage)
		var symmetric := not (cage.get("symmetry", []) as Array).is_empty()
		if symmetric and bool((groups.get(body_id, {}) as Dictionary).get("body", false)) and locked.has(1):
			workspace.flash(FORM_OPS.SYMMETRIC_FROZEN_BODY)
			return
		for v in verts[body_id]:
			if not locked[v]:
				any_free = true
			elif not own[v]:
				held += 1
	if not any_free:
		workspace.flash("Those vertices are frozen." if held == 0 else FORM_OPS.FROZEN_PARTNERS)
		return
	if tool == "edit_form":
		var bad := FORM_TOOLS.range_error(tool, evaluated_values(), units())
		if bad != "":
			workspace.flash(bad)
			return
	if held > 0:
		workspace.flash("%d selected vertices stay where they are: their symmetry partners are frozen." % held)
	_update_gizmo()
	if not gizmo.visible:
		gizmo.pivot = Vector3.ZERO
		gizmo.basis = Basis.IDENTITY
	_drag = {"type": "gizmo", "handle": handle, "state": gizmo.begin_drag(handle, viewport, event.position), "before": workspace.doc.snapshot(),
		"start": event.position, "alt": event.alt_pressed, "ctrl": event.ctrl_pressed, "moved": false, "extruded": false}
	_prepare_drag_bodies()


## The drag's starting cages, moving vertices and weights per body (again after an Alt extrude).
func _prepare_drag_bodies() -> void:
	var verts := _selected_vertices()
	var values := evaluated_values()
	var soft := bool(values.get("soft", false))
	var bodies := {}
	var local := str(tool_values.get("space", "world")) == "local"
	for body_id in verts:
		var cage := cage_of(body_id)
		var locked := FORM_OPS.locked_set(cage)
		var entry: Dictionary = _subd.get(body_id, {})
		var moving := PackedInt32Array()
		var weights := PackedFloat32Array()
		var rank := PackedFloat32Array()
		var nV := CAGE.vertex_count(cage)
		# The selection first: it drives its symmetry orbits (carry_symmetry), the soft field after.
		var listed := PackedByteArray()
		listed.resize(nV)
		for v in verts[body_id]:
			if not locked[v] and not listed[v]:
				listed[v] = 1
				moving.append(v)
				weights.append(1.0)
		if soft and not entry.is_empty():
			var w := FORM_OPS.soft_weights(cage, entry.topo, verts[body_id], _soft_opts(values, body_id))
			for v in w.size():
				if w[v] > 0.0 and not locked[v] and not listed[v]:
					moving.append(v)
					weights.append(w[v])
			rank = w
			_soft[body_id] = FORM_OPS.symmetric_weights(cage, w)
		var whole := not local and moving.size() == nV
		for x in weights:
			whole = whole and x == 1.0
		if not soft:
			weights = PackedFloat32Array()
		bodies[body_id] = {"cage": CAGE.copy(cage), "verts": moving, "weights": weights, "rank": rank, "whole": whole,
			"pivots": _local_pivots(body_id, cage, moving)}
	_drag["bodies"] = bodies


## Local Per Entity: each moving vertex's entity frame {"pivot", "basis"} (by its selected faces,
## edges or itself); empty in the other spaces.
func _local_pivots(body_id: String, cage: Dictionary, moving: PackedInt32Array) -> Dictionary:
	if str(tool_values.get("space", "world")) != "local":
		return {}
	var entry: Dictionary = _subd.get(body_id, {})
	if entry.is_empty():
		return {}
	var topo: CAGE.Topo = entry.topo
	var sel: Dictionary = selection_by_body().get(body_id, {})
	var frames := {}
	var add := func(verts: PackedInt32Array, normal: Vector3) -> void:
		var center := Vector3.ZERO
		for v in verts:
			center += CAGE.position(cage, v)
		center /= maxi(verts.size(), 1)
		var z := normal.normalized() if normal.length() > 1e-12 else Vector3.UP
		var x := z.cross(Vector3.UP if absf(z.y) < 0.9 else Vector3.RIGHT).normalized()
		var frame := {"pivot": center, "basis": Basis(x, z.cross(x), z)}
		for v in verts:
			if not frames.has(v):
				frames[v] = []
			(frames[v] as Array).append(frame)
	for f in sel.get("faces", PackedInt32Array()):
		add.call(topo.face_verts(f), topo.face_area_vector(cage, f))
	var pairs: PackedInt32Array = sel.get("edges", PackedInt32Array())
	for i in pairs.size() / 2:
		var a := pairs[2 * i]
		var b := pairs[2 * i + 1]
		add.call(PackedInt32Array([a, b]), topo.vertex_normal(cage, a) + topo.vertex_normal(cage, b))
	for v in sel.get("vertices", PackedInt32Array()):
		add.call(PackedInt32Array([v]), topo.vertex_normal(cage, v))
	if bool(sel.get("body", false)):
		for v in moving:
			add.call(PackedInt32Array([v]), topo.vertex_normal(cage, v))
	return frames


func _gizmo_motion(event: InputEventMouseMotion) -> void:
	var started := Time.get_ticks_usec()
	if not bool(_drag.moved):
		if event.position.distance_to(_drag.start) <= (DRAG_START_PX * _ui_scale()):
			return
		_drag.moved = true
		if bool(_drag.alt) and not bool(_drag.extruded) and FORM_GIZMO.ALT_HANDLES.has(str(_drag.handle)):
			if not _alt_extrude(bool(_drag.ctrl)):
				_drag.alt = false
	var xf := gizmo.drag_xf(_drag.state, viewport, event.position, event.shift_pressed, float(viewport.snap_step))
	_apply_drag(xf)
	last_drag_ms = (Time.get_ticks_usec() - started) / 1000.0


## Moves the drag's vertices by xf from their drag-start positions, mirrors them to their
## symmetry partners, writes the document cages in place and redraws at the drag rate.
func _apply_drag(xf: PackedFloat64Array) -> void:
	var bodies: Dictionary = _drag.get("bodies", {})
	var local := str(tool_values.get("space", "world")) == "local"
	for body_id in bodies:
		var info: Dictionary = bodies[body_id]
		var start: Dictionary = info.cage
		var r: Dictionary
		if local and not (info.pivots as Dictionary).is_empty():
			r = _local_transform(start, info, xf)
		else:
			r = FORM_OPS.transform_vertices(start, info.verts, info.weights, xf)
		var out: Dictionary = r.cage
		if not (out.get("symmetry", []) as Array).is_empty():
			var s := FORM_OPS.carry_symmetry(start, out, info.verts, info.get("rank", PackedFloat32Array()), xf if bool(info.get("whole", false)) else PackedFloat64Array())
			if not s.ok:
				# A move that would break the symmetry (a skewing scale of a whole symmetric body)
				# leaves the body where it was; said once per drag.
				out = start
				if not bool(_drag.get("refused", false)):
					_drag["refused"] = true
					workspace.flash(str(s.error))
			else:
				out = s.cage
		var stored := cage_of(body_id)
		if stored.is_empty():
			continue
		stored.positions = out.positions
		if out.has("symmetry"):
			stored.symmetry = (out.symmetry as Array).duplicate(true)
		_drag_redraw(body_id, stored)
	_overlay_valid = false
	_update_gizmo_during_drag(xf)
	viewport.redraw_overlay()


## Local Per Entity: each entity's frame takes the gizmo's transform as its own (shared vertices
## average their moves).
func _local_transform(start: Dictionary, info: Dictionary, xf: PackedFloat64Array) -> Dictionary:
	var gb := gizmo.basis.orthonormalized()
	var pg := gizmo.pivot
	var lin := Basis(Vector3(xf[0], xf[3], xf[6]), Vector3(xf[1], xf[4], xf[7]), Vector3(xf[2], xf[5], xf[8]))
	var moved_pivot := FORM_OPS.xf_apply(xf, pg.x, pg.y, pg.z)
	var t := Vector3(moved_pivot[0], moved_pivot[1], moved_pivot[2]) - pg
	var lin_local := gb.transposed() * lin * gb
	var t_local := gb.transposed() * t
	var p: PackedFloat64Array = start.positions
	var np := p.duplicate()
	var moved := PackedInt32Array()
	var frames: Dictionary = info.pivots
	for v in info.verts:
		var list: Array = frames.get(v, [])
		if list.is_empty():
			continue
		var acc := Vector3.ZERO
		var pos := Vector3(p[3 * v], p[3 * v + 1], p[3 * v + 2])
		for frame in list:
			var be: Basis = frame.basis
			var pe: Vector3 = frame.pivot
			acc += (be * lin_local * be.transposed()) * (pos - pe) + pe + be * t_local
		acc /= list.size()
		np[3 * v] = acc.x
		np[3 * v + 1] = acc.y
		np[3 * v + 2] = acc.z
		moved.append(v)
	var out := CAGE.copy(start)
	out.positions = np
	return {"cage": out, "info": {"moved": moved}}


func _update_gizmo_during_drag(xf: PackedFloat64Array) -> void:
	var state: Dictionary = _drag.state
	var p: Vector3 = state.pivot
	var q := FORM_OPS.xf_apply(xf, p.x, p.y, p.z)
	gizmo.pivot = Vector3(q[0], q[1], q[2])


## One body during a drag: new positions into its CadSubD, a drag-rate tessellation, its meshes.
func _drag_redraw(body_id: String, cage: Dictionary) -> void:
	var entry: Dictionary = _subd.get(body_id, {})
	if entry.is_empty():
		return
	var subd: RefCounted = entry.subd
	if subd != null and str(entry.error) == "":
		subd.set_positions(cage.positions)
	entry.cage = cage
	entry.content_hash = CAGE.content_hash(cage)
	entry.erase("box")
	entry.erase("points_v3")
	_forget_screen(entry)
	_tessellate(entry, true, _soft.get(body_id, PackedFloat32Array()))
	entry.version = int(entry.version) + 1
	var shown := {"id": body_id, "entry": entry, "mode": display_mode(body_id), "preview": false}
	for mesh_entry in _body_meshes(shown):
		viewport.update_form_mesh(str(mesh_entry.key), mesh_entry.mesh)


## Alt-drag: extrudes the selected faces, or extends the selected open boundary edges (Ctrl keeps
## the creases), then the drag carries on with the new vertices. False when neither applies.
func _alt_extrude(keep_creases: bool) -> bool:
	var groups := selection_by_body()
	var done := false
	var new_selection: Array[Dictionary] = []
	for body_id in groups:
		var sel: Dictionary = groups[body_id]
		var cage := cage_of(body_id)
		var faces: PackedInt32Array = sel.faces
		var pairs: PackedInt32Array = sel.edges
		var r := {}
		if not faces.is_empty():
			r = FORM_OPS.extrude_region(cage, {"faces": faces}, {"keep_creases": keep_creases})
			if r.ok:
				for f in (r.selection as Dictionary).get("faces", faces):
					new_selection.append({"kind": "face", "body": body_id, "index": f, "pair": Vector2i(-1, -1)})
		elif not pairs.is_empty():
			var entry: Dictionary = _subd.get(body_id, {})
			var topo: CAGE.Topo = entry.topo
			var boundary := true
			for i in pairs.size() / 2:
				var e := topo.edge_index(pairs[2 * i], pairs[2 * i + 1])
				if e < 0 or not topo.is_boundary_edge(e):
					boundary = false
			if not boundary:
				continue
			r = FORM_OPS.extend_edges(cage, {"edges": pairs}, {"keep_creases": keep_creases})
			if r.ok:
				var chain: PackedInt32Array = (r.selection as Dictionary).get("edges", PackedInt32Array())
				for i in chain.size() / 2:
					new_selection.append({"kind": "edge", "body": body_id, "index": -1, "pair": Vector2i(chain[2 * i], chain[2 * i + 1])})
		else:
			continue
		if not r.ok:
			workspace.flash(str(r.error))
			continue
		(feature.options.bodies as Dictionary)[body_id] = r.cage
		_sync_entry(_subd, body_id, r.cage, true)
		done = true
	if not done:
		return false
	selection = new_selection
	_prune_selection()
	_drag.extruded = true
	_prepare_drag_bodies()
	_mesh_entries.clear()
	_refresh_meshes()
	return true


func _gizmo_release(drag: Dictionary) -> void:
	if not bool(drag.moved):
		_update_gizmo()
		return
	workspace.commit_change("Form: Edit Form", drag.before)


## Ends a drag in progress (keeping what it did: a step for a moved gizmo drag).
func _commit_drag() -> void:
	if _drag.is_empty():
		return
	var drag := _drag
	_drag = {}
	if str(drag.get("type", "")) == "gizmo" and bool(drag.get("moved", false)):
		workspace.commit_change("Form: Edit Form", drag.before)


## Escape during a drag: puts the cages back where the drag started.
func _cancel_drag() -> void:
	var drag := _drag
	_drag = {}
	if str(drag.get("type", "")) == "gizmo" and bool(drag.get("moved", false)):
		workspace.doc.restore(drag.before)
		workspace.recompute()
	viewport.redraw_overlay()


## Edit Form's OK: the typed transform as one step about the pivot, then the fields back to neutral;
## with neutral fields OK closes the tool.
func _edit_form_ok() -> void:
	var values := evaluated_values()
	if not _value_errors.is_empty():
		workspace.flash("Fix the highlighted values first.")
		return
	# Soft-modification values and scale factors out of range are refused with a sentence, as
	# other tools' are (a scale factor of 0 or less too: SCALE_RANGE starts at 0.01).
	var bad := FORM_TOOLS.range_error("edit_form", values, units())
	if bad != "":
		workspace.flash(bad)
		return
	if selection.is_empty():
		cancel_tool()
		return
	_update_gizmo()
	var xf := FORM_GIZMO.numeric_xf(gizmo.pivot, gizmo.basis, values)
	if FORM_GIZMO.is_identity(xf):
		cancel_tool()
		return
	var groups := selection_by_body()
	var cages := {}
	var notes := PackedStringArray()
	var soft := bool(values.get("soft", false))
	var local := str(tool_values.get("space", "world")) == "local"
	var verts_by_body := _selected_vertices()
	for body_id in groups:
		var cage := cage_of(body_id)
		if local:
			# Local Per Entity: each face, edge or vertex moves in its own frame about its own
			# centre, exactly as a drag of the same size does.
			var locked := FORM_OPS.locked_set(cage)
			var moving := PackedInt32Array()
			for v in verts_by_body.get(body_id, PackedInt32Array()):
				if not locked[v]:
					moving.append(v)
			if moving.is_empty():
				workspace.flash("Those vertices are frozen.")
				return
			var info := {"verts": moving, "pivots": _local_pivots(body_id, cage, moving)}
			var lr := _local_transform(cage, info, xf)
			var cr := FORM_OPS.carry_symmetry(cage, lr.cage, moving)
			if not cr.ok:
				workspace.flash(str(cr.error))
				return
			cages[body_id] = cr.cage
			continue
		var opts := {"xf": xf, "pivot": Vector3.ZERO}
		if soft:
			var entry: Dictionary = _subd.get(body_id, {})
			opts["weights"] = FORM_OPS.soft_weights(cage, entry.get("topo"), FORM_OPS._sel_vertices(cage, groups[body_id]), _soft_opts(values, body_id))
		var r := FORM_OPS.edit_transform(cage, groups[body_id], opts)
		if not r.ok:
			workspace.flash(str(r.error))
			return
		cages[body_id] = r.cage
		notes.append_array(r.get("warnings", PackedStringArray()))
	var fid := feature_id
	workspace.change("Form: Edit Form", func() -> void: apply_result(fid, {"ok": true, "cages": cages}, []))
	for note in notes:
		workspace.flash(str(note))
	var neutral := FORM_TOOLS.defaults("edit_form", units(), 0.0)
	for key in ["x_distance", "y_distance", "z_distance", "x_angle", "y_angle", "z_angle", "x_scale", "y_scale", "z_scale", "xy_scale",
			"yz_scale", "zx_scale", "uniform_scale"]:
		tool_values[key] = neutral[key]
	workspace.panel.set_values(tool_values)
	_update_gizmo()
	viewport.redraw_overlay()
