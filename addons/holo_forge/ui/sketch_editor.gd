@tool
extends RefCounted
## Sketch mode in the Forge view.
##
## Draws sketches on top of the 3D view in the view's palette (blue = can still move, black or
## white = fully defined, red = conflicting, amber = construction, purple = projected; see
## apply_theme), picks and snaps in the sketch plane,
## runs the sketch tools with live previews (each finished piece is one undo step), shows and
## edits dimensions (drafting dimensions laid out by dimension_layout.gd, over the constraint
## glyphs) and constraint glyphs, drags geometry through the solver, and shades the
## closed profiles. The geometry itself comes from sketch_builders.gd. The Sketch toolbar's
## commands (Measure, Curvature Comb, Canvas) run over the open sketch: it is suspended while
## they do and comes back with the same tool and selection.
##
## Sketch Dimension: pick one or two items, and the dimension they make follows the cursor (where
## it is pulled decides horizontal, vertical or aligned, and which of four angles); the placing
## click either asks to add it driven (when it would over-constrain the sketch) or opens the value
## box on it, prefilled with what it measures. Every value is checked first on a scratch copy of
## the document (_trial), so a value the sketch can't take is refused and nothing changes. Two
## points take a third for the angle at the middle one. While the box is open a click on another
## dimension puts its parameter name in (so do the favourite user parameters), "name = value"
## renames the parameter, and a pill under the box shows its name. A right-click while placing
## offers the dimension's choices (orientation, radius/diameter/sweep, centre/edge, diameter across
## a centerline, driven); on a placed one, edit, driven/driving, radius/diameter and delete.
## Hovering a dimension shows a tip and lights up what it measures; its text drags.
##
## Heads-up fields while drawing (HEADS_UP_TOOLS): once Line has its first point, the rubber band
## shows its length and its angle (from the chain's previous segment, or plane +X for the first one)
## as preview dimensions; a rectangle shows its width and height (the 3-point one its first edge's
## length, then its height), a circle its diameter. Typing a digit, "-" or "." opens value boxes on
## them (Tab opens them on the second field, and moves between them); Enter locks a value, which
## the rubber band then keeps while the mouse sets the rest, and the placing click (or Enter with
## every value locked) adds the shape with driving dimensions for the locked values in the same
## undo step. Esc closes the boxes and drops their locks.

const SKETCH := preload("res://addons/holo_forge/core/sketch/sketch_data.gd")
const SOLVE := preload("res://addons/holo_forge/core/sketch/sketch_solve.gd")
const B := preload("res://addons/holo_forge/core/sketch/sketch_builders.gd")
const DIM := preload("res://addons/holo_forge/core/sketch/dimension_layout.gd")
const TEXT := preload("res://addons/holo_forge/core/sketch/text_outline.gd")
const UNITS := preload("res://addons/holo_forge/core/units.gd")
const TESSELLATE := preload("res://addons/holo_forge/core/tessellate.gd")
const PICKING := preload("res://addons/holo_forge/core/picking.gd")
const CATALOG := preload("res://addons/holo_forge/tools/catalog.gd")
const PARAMETERS := preload("res://addons/holo_forge/core/parameters.gd")
const DOCUMENT := preload("res://addons/holo_forge/core/document.gd")
const VIEWPORT := preload("res://addons/holo_forge/ui/forge_viewport.gd")
const FLOATING_PANEL := preload("res://addons/holo_forge/ui/floating_panel.gd")
const FORGE_THEME := preload("res://addons/holo_forge/ui/forge_theme.gd")

const PICK_PX := 7.0
const SNAP_PX := 9.0
const GLYPHS := {
	"horizontal": "H", "vertical": "V", "parallel": "∥", "perpendicular": "⊥", "tangent": "T", "equal": "=",
	"midpoint": "M", "concentric": "◎", "collinear": "≡", "symmetric": "[]", "fix": "F", "curvature": "~", "coincident": "•",
}
## How each tool collects input: clicks (points), picks (sketch entities of a kind), fields
## (options in the panel), selection (works on the selected geometry), ok (finish with OK/Enter).
const TOOLS := {
	"line": {"clicks": -1}, "centerline": {"clicks": 2},
	"rect_2pt": {"clicks": 2}, "rect_3pt": {"clicks": 3}, "rect_center": {"clicks": 2},
	"circle_center": {"clicks": 2}, "circle_2pt": {"clicks": 2}, "circle_3pt": {"clicks": 3},
	"circle_2tan": {"picks": 2, "pick": "line", "clicks": 1, "fields": ["radius"]},
	"circle_3tan": {"picks": 3, "pick": "line", "clicks": 1},
	"arc_3pt": {"clicks": 3}, "arc_center": {"clicks": 3}, "arc_tangent": {"picks": 1, "pick": "end", "clicks": 1},
	"polygon_circumscribed": {"clicks": 2, "fields": ["sides"]}, "polygon_inscribed": {"clicks": 2, "fields": ["sides"]},
	"polygon_edge": {"clicks": 2, "fields": ["sides"]}, "ellipse": {"clicks": 3},
	"slot_cc": {"clicks": 3}, "slot_overall": {"clicks": 3}, "slot_center": {"clicks": 3},
	"slot_3pt_arc": {"clicks": 4}, "slot_center_arc": {"clicks": 4},
	"spline_fit": {"clicks": -1}, "spline_control": {"clicks": -1}, "conic": {"clicks": 3, "fields": ["rho"]},
	"point": {"clicks": 1}, "text": {"clicks": 1, "fields": ["text", "height", "bold", "italic", "font"]},
	"text_on_path": {"picks": 1, "pick": "curve", "fields": ["text", "height", "bold", "italic", "font"], "ok": true},
	"mirror": {"selection": true, "picks": 1, "pick": "line"},
	"rect_pattern": {"selection": true, "fields": ["count_a", "spacing_a", "direction", "count_b", "spacing_b"], "ok": true},
	"circ_pattern": {"selection": true, "clicks": 1, "fields": ["count", "total_angle"]},
	"fillet": {"picks": 1, "pick": "corner", "fields": ["radius"], "repeat": true},
	"chamfer_equal": {"picks": 1, "pick": "corner", "fields": ["distance"], "repeat": true},
	"chamfer_two": {"picks": 1, "pick": "corner", "fields": ["distance", "distance_b"], "repeat": true},
	"chamfer_angle": {"picks": 1, "pick": "corner", "fields": ["distance", "angle"], "repeat": true},
	"trim": {"picks": 1, "pick": "curve", "repeat": true}, "extend": {"picks": 1, "pick": "curve", "repeat": true},
	"break": {"picks": 1, "pick": "curve", "repeat": true},
	"offset": {"picks": 1, "pick": "curve", "fields": ["distance"], "ok": true},
	"blend_g1": {"picks": 2, "pick": "end"}, "blend_g2": {"picks": 2, "pick": "end"},
	"sketch_scale": {"selection": true, "clicks": 1, "fields": ["factor"]},
	"move_copy": {"selection": true, "clicks": 2, "fields": ["angle", "copy"]},
	"dimension": {"picks": 2, "pick": "any", "dimension": true},
	"project": {"picks3d": "any", "ok": true}, "intersect": {"picks3d": "body", "ok": true},
	"include3d": {"picks3d": "edge", "ok": true}, "project_surface": {"picks3d": "face", "selection": true, "ok": true},
	"intersection_curve": {"picks3d": "face", "selection": true, "ok": true},
	"isocurve": {"picks3d": "face", "fields": ["iso_direction", "iso_count"], "ok": true},
	"spun_profile": {"picks3d": "body", "picks": 1, "pick": "line", "ok": true},
}
const CONSTRAINT_PICKS := {
	"horizontal_vertical": 1, "coincident": 2, "tangent": 2, "equal": 2, "parallel": 2, "perpendicular": 2, "fix": 1,
	"midpoint": 2, "concentric": 2, "collinear": 2, "symmetric": 3, "curvature": 2,
}
const DIM_OVERRIDES := {"orientation": "", "round": "", "driven": false, "edge": false, "linear_diameter": ""}
## A drag of a dimension's text starts once the mouse is this far (pixels at UI scale 1) from the press.
const DIM_DRAG_PX := 4.0
## How far (meters) a solved point can sit from where its constraints put it.
const SOLVE_NOISE := 1e-9
## "name = value" in the value box (the name renames the dimension's parameter).
static var _name_equals := RegEx.create_from_string("^\\s*([A-Za-z_][A-Za-z0-9_]*)\\s*=\\s*(.*)$")
## A dimension's look in each state (see _dimension_state): its lines' and its text's colour keys.
const DIM_STATE_COLORS := {
	"error": ["dim_error", "dim_error"], "editing": ["dim_selected", "dim_selected"], "selected": ["dim_selected", "dim_selected"],
	"hovered": ["dim_hover", "dim_hover"], "preview": ["dim_preview", "dim_preview"], "normal": ["dim_line", "dim_text"],
}
## The heads-up dimensions in the draw log (_dim_draw_log), by field.
const HEADS_UP_IDS := {"length": -2, "angle": -3, "width": -4, "height": -5, "diameter": -6}
## The tools with heads-up fields: the fields each offers by how many points it has placed (a
## later step's fields add to the earlier ones' locked values), and what it makes (for messages).
const HEADS_UP_TOOLS := {
	"line": {"steps": {1: ["length", "angle"]}, "noun": "line"},
	"rect_2pt": {"steps": {1: ["width", "height"]}, "noun": "rectangle"},
	"rect_center": {"steps": {1: ["width", "height"]}, "noun": "rectangle"},
	"rect_3pt": {"steps": {1: ["width"], 2: ["height"]}, "noun": "rectangle"},
	"circle_center": {"steps": {1: ["diameter"]}, "noun": "circle"},
	"circle_2pt": {"steps": {1: ["diameter"]}, "noun": "circle"},
}
## Heads-up layout at UI scale 1: the length's text this far to the rubber band's left (plane-up
## for level bands), a rectangle's width and height this far outside it; the angle's arc radius,
## half the band's length kept between these; a diameter's text inside a circle at least this big
## in radius (half-way out towards the cursor), else this far outside it.
const HEADS_UP_OFFSET_PX := 24.0
const HEADS_UP_ARC_PX := [36.0, 64.0]
const HEADS_UP_INSIDE_PX := 48.0

var workspace: Object
var viewport: VIEWPORT
var active := false
## True while a command (Measure, Curvature Comb, Canvas) runs over the open sketch: the sketch
## keeps its tool, points, picks, values and selection but takes no clicks or keys until the
## command closes (suspend() / resume()).
var suspended := false
var feature_id := ""
var state := {}
var selection: Array[Dictionary] = []
var hover := {}
var show := {"grid": true, "snap": true, "slice": false, "profiles": true, "points": true, "dimensions": true, "constraints": true, "projected": true}

var tool := ""
var tool_points: Array = []
var tool_snaps: Array = []
var tool_picks: Array = []
var tool_picks3d: Array = []
var tool_values := {}
var tool_selection: Array = []
var mouse_screen := Vector2.ZERO
var mouse_plane := Vector2.ZERO
## The mouse in the sketch plane without snapping: where a dimension being placed goes.
var mouse_plane_raw := Vector2.ZERO
var mouse_snap := {}
## Answers the driven-dimension question without showing it: "ok" or "cancel" (tests); "" asks.
var driven_answer := ""

## The UI scale dimensions and their value box are drawn at: this when above 0 (tests,
## screenshots), else the editor's display scale (1 outside the editor).
var ui_scale := 0.0

var _samples := {}
## Constraint glyphs' screen rects ({"rect", "id"}), from the last draw.
var _label_rects := []
## Dimensions drawn in the last draw: {"id", "poly" (the text box, padded), "segments" (their
## lines), "text_center", "text_angle"}, for hit() and the value box.
var _dim_hits := []
## How the last draw showed each dimension: id -> {"state", "color", "text_color", "width", "text"}.
var _dim_draw_log := {}
## Screen layouts of the dimensions drawn last, by id: {"key", "layout"}; one is used again while
## the view, the dimension, its text and what it measures stay the same.
var _layout_cache := {}
## How many dimension layouts the last draw worked out afresh (the rest came from the cache).
var _layout_misses := 0
## The new dimension's text spot on screen in the last draw (where the value box goes).
var _pending_center := Vector2.INF
## The hover tip's and name pill's box, rebuilt with the theme.
var _tip_style: StyleBoxFlat
## The hover tip and the name pill the last draw showed ("" for none).
var _tip_text := ""
var _pill_text := ""
## The geometry the hovered or selected dimensions measure (tinted dim_hover in the last draw).
var _measured_highlight := {}
## Lists the favourite user parameters beside the value box (shown when there are any).
var _fav_button: Button
var _fav_menu: PopupMenu
var _profile_meshes := []
var _hover_profile := -1
var _drag := {}
var _edit: LineEdit
## The dimension editor was open when a command suspended the sketch (it opens again after).
var _edit_waiting := false
var _edit_constraint := -1
## The new dimension the value box is open on (a dimension_spec() result), {} for none.
var _pending_dimension := {}
## False while the value box's text can't be used (it shows in dim_box_invalid then).
var _edit_valid := true
## A left press the value box used (a click in the view while it was open): its release is used too.
var _swallow_release := false
## The Sketch Dimension tool's choices for the dimension being placed, cleared with its picks: an
## orientation lock ("" for automatic, "distance_x", "distance_y" or "aligned"), "radius",
## "diameter" or "sweep" for a circle or arc ("" for the usual one), driven, edge (distances to
## circles and arcs measured to their curves) and linear_diameter ("" automatic: on from a
## centerline; "on" or "off").
var _dim_overrides := DIM_OVERRIDES.duplicate()
## The linear orientation the placing preview showed last (kept near the sector boundaries).
var _dim_last_orientation := ""
## The placing preview drawn last: its dimension_spec() with "id" -1 and "driving"; {} for none.
var _preview_dimension := {}
## Asks whether to add an over-constraining dimension as driven (made on first use).
var _driven_dialog: ConfirmationDialog
## The dimension the driven question is about.
var _driven_spec := {}
var palette: FLOATING_PANEL
## The colours sketches are drawn in (forge_theme.gd's sketch_*, dim_*, glyph_* and profile keys).
var theme_colors := FORGE_THEME.palette("light")
var _palette_checks := {}
var _material_profile: StandardMaterial3D
var _material_profile_hover: StandardMaterial3D
## The heads-up value boxes by field (HEADS_UP_IDS: "length", "angle", "width", "height",
## "diameter"), the running tool's step's shown while typed in; separate from the dimension value
## box (_edit), which keeps its own lifetime.
var _heads_up := {}
## Each heads-up field's state: "typed" (its text is the user's, not the measured value), "valid",
## and "locked" with the "value", "expression" and parameter "name" Enter locked.
var _heads_up_state := {}
## The heads-up field the keyboard is in, "" while the boxes are closed.
var _heads_up_field := ""
## The heads-up dimensions' text spots on screen in the last draw, by field.
var _heads_up_centers := {}
## The segment the running line chain added last (the next one's angle is measured from it); -1
## before the first.
var _chain_line := -1
## The tool preview's scratch sketch, what the tool made on it and the points it was made from
## ({"sketch", "made", "points"}), from the last _preview() of a heads-up tool; {} otherwise.
var _last_preview := {}


func _init(p_workspace: Object, p_viewport: Control) -> void:
	workspace = p_workspace
	viewport = p_viewport as VIEWPORT
	_material_profile = _profile_material(theme_colors.profile)
	_material_profile_hover = _profile_material(theme_colors.profile_hover)
	_build_palette()
	_reset_heads_up_state()
	for field in HEADS_UP_IDS:
		var box := LineEdit.new()
		box.visible = false
		# Tab moves between the step's fields (see _on_heads_up_input), never to other controls.
		box.focus_next = NodePath(".")
		box.focus_previous = NodePath(".")
		# Enter locks the value and typing goes on in the box.
		if "keep_editing_on_text_submit" in box:
			box.set("keep_editing_on_text_submit", true)
		box.text_submitted.connect(_on_heads_up_submitted.bind(field))
		box.text_changed.connect(_on_heads_up_changed.bind(field))
		box.gui_input.connect(_on_heads_up_input.bind(field))
		box.focus_entered.connect(func() -> void:
			if _heads_up_field != "":
				_heads_up_field = field
				viewport.redraw_overlay())
		_heads_up[field] = box
	_edit = LineEdit.new()
	_edit.visible = false
	_fav_button = Button.new()
	_fav_button.text = "▾"
	_fav_button.visible = false
	_fav_button.focus_mode = Control.FOCUS_NONE
	_fav_button.tooltip_text = "Favourite parameters"
	_fav_menu = PopupMenu.new()
	_fav_button.add_child(_fav_menu)
	_fav_button.pressed.connect(_open_favorites)
	_fav_menu.id_pressed.connect(_on_favorite_chosen)
	_style_edit()
	# Tab keeps the keyboard in the box (it doesn't move on to the controls around the view).
	_edit.focus_next = NodePath(".")
	_edit.focus_previous = NodePath(".")
	_edit.text_submitted.connect(_on_edit_submitted)
	_edit.text_changed.connect(_on_edit_changed)
	_edit.gui_input.connect(_on_edit_input)
	viewport.add_child(_edit)
	viewport.add_child(_fav_button)
	for field in _heads_up:
		viewport.add_child(_heads_up[field])
	viewport.draw_handler = draw


func sketch() -> SKETCH:
	var feature: Resource = workspace.doc.find_feature(feature_id) if workspace.doc != null else null
	return SKETCH.new(feature, workspace.doc) if feature != null else null


# --- Enter, leave, refresh -------------------------------------------------------------------

func begin(feature: Resource) -> void:
	if active:
		end()
	active = true
	feature_id = feature.id
	selection.clear()
	hover = {}
	viewport.mouse_handler = handle_mouse
	viewport.set_sketch_dim(true)
	palette.visible = true
	workspace.toolbar.set_workspace("Sketch")
	look_at()
	refresh(workspace.result)
	workspace.flash("Editing %s. Finish Sketch when done." % feature.label)


func end() -> void:
	if not active:
		return
	_close_command()
	cancel_tool()
	_close_edit()
	active = false
	feature_id = ""
	selection.clear()
	hover = {}
	viewport.mouse_handler = Callable()
	viewport.set_sketch_dim(false)
	palette.visible = false
	workspace.toolbar.set_workspace(workspace.workspace)
	viewport.set_extra_meshes([])
	# Slice is for this sketch only: the bodies come back and the box is unticked.
	show.slice = false
	(_palette_checks.slice as CheckBox).set_pressed_no_signal(false)
	_set_slice(false)
	refresh(workspace.result)


## A command opens over the sketch (the workspace calls this before it takes the panel): the
## running tool stays as it is, a point being dragged is committed, hover clears and a dimension
## being typed waits, hidden, with its text.
func suspend() -> void:
	if not active or suspended:
		return
	if str(_drag.get("type", "")) == "point" and _drag.moved:
		workspace.commit_change("Drag Sketch Geometry", _drag.before)
	elif str(_drag.get("type", "")) == "dim_text" and _drag.moved:
		workspace.commit_change("Sketch: Move Dimension", _drag.before)
	_drag = {}
	# Heads-up fields close (and their locks go): the command takes the keyboard.
	_close_heads_up()
	suspended = true
	hover = {}
	_hover_profile = -1
	_update_profile_meshes()
	_edit_waiting = _edit.visible
	_edit.visible = false
	_fav_button.visible = false
	workspace.panel.set_ok_text("OK")
	viewport.redraw_overlay()


## The command over the sketch closed: the running tool gets its panel back, as it was.
func resume() -> void:
	if not suspended:
		return
	suspended = false
	if active and tool != "":
		_show_tool_panel()
	if _edit_waiting:
		_edit_waiting = false
		_edit.visible = true
		_place_favorites()
		_edit.grab_focus()
	viewport.redraw_overlay()


## Closes a command running over the sketch before the sketch itself changes or closes, so the
## command's Cancel can't put back a sketch edit that has its own undo step.
func _close_command() -> void:
	if not suspended:
		return
	if workspace.command != null:
		workspace.cancel_command()
	resume()


## Re-reads the sketch after a rebuild: solve state, sampled curves and profile shading.
func refresh(result: Dictionary) -> void:
	_samples.clear()
	_profile_meshes.clear()
	if active and workspace.doc.find_feature(feature_id) == null:
		end()
		return
	var s: SKETCH = sketch() if active else null
	state = result.get("sketches", {}).get(feature_id, {}) if active else {}
	if s != null:
		_drop_stale_dimension_edit(s)
		_sample_sketch(s, state, _samples)
		if show.profiles:
			for region in state.get("regions", []):
				var tess := TESSELLATE.tessellate(region.face)
				_profile_meshes.append({"mesh": TESSELLATE.surface_mesh(tess), "material": _material_profile, "loops": region.loops})
	_update_profile_meshes()
	viewport.redraw_overlay()


## After an undo or another change: a value box on a dimension that is gone closes, and a new
## dimension (or picks) on geometry that is gone is dropped.
func _drop_stale_dimension_edit(s: SKETCH) -> void:
	var gone := func(refs: Array) -> bool: return refs.any(func(id) -> bool: return s.entity(int(id)).is_empty())
	if _edit_constraint >= 0 and s.constraint(_edit_constraint).is_empty():
		_close_edit()
	if not _pending_dimension.is_empty() and gone.call(_pending_dimension.get("refs", [])):
		_close_edit()
		_clear_dimension_picks()
	if TOOLS.get(tool, {}).get("dimension", false) and gone.call(_pick_ids()):
		_clear_dimension_picks()


func _sample_sketch(s: SKETCH, sketch_state: Dictionary, into: Dictionary) -> void:
	var deflection: float = maxf(viewport.distance * 0.0008, 0.000005)
	var kernel: RefCounted = workspace.kernel
	for e in s.entities():
		var id := int(e.id)
		match str(e.type):
			"point":
				pass
			"text":
				var lines := []
				for outline in sketch_state.get("text", {}).get(id, []):
					var world := PackedVector3Array()
					for p in outline:
						world.append(s.to_world(p))
					world.append(world[0])
					lines.append(world)
				into[id] = lines
			"ref3d":
				into[id] = e.polylines
			_:
				var world := PackedVector3Array()
				for p in s.sample(id, kernel, deflection):
					world.append(s.to_world(p))
				into[id] = [world]


func _update_profile_meshes() -> void:
	var entries := []
	for i in _profile_meshes.size():
		var entry: Dictionary = _profile_meshes[i]
		entries.append({"mesh": entry.mesh, "material": _material_profile_hover if i == _hover_profile else _material_profile})
	viewport.set_extra_meshes(entries)


## Looks straight at the sketch plane, keeping the view centered where it was.
func look_at() -> void:
	var s := sketch()
	if s == null:
		return
	viewport.look_at_face(s.to_world(s.to_plane(viewport.target)), s.normal())


# --- Drawing ---------------------------------------------------------------------------------

func draw(overlay: Control) -> void:
	_label_rects.clear()
	_dim_hits.clear()
	_dim_draw_log.clear()
	# Sketches you aren't editing are drawn thin and grey (when shown).
	var doc: Resource = workspace.doc
	if doc != null:
		for feature in doc.features.slice(0, doc.active_count()):
			if feature.type != "sketch" or feature.id == feature_id or feature.suppressed or not feature.options.get("visible", true):
				continue
			var other := SKETCH.new(feature, doc)
			var samples := {}
			_sample_sketch(other, workspace.result.get("sketches", {}).get(feature.id, {}), samples)
			for id in samples:
				if other.entity(id).get("construction", false):
					continue
				for line in samples[id]:
					_polyline(overlay, line, theme_colors.sketch_inactive, 1.2)
	if not active:
		return
	var c := theme_colors
	var s := sketch()
	if s == null:
		return
	if show.grid:
		_draw_grid(overlay, s)
	var conflict_ids := {}
	for cid in state.get("solve", {}).get("conflicting", []):
		for r in s.constraint(int(cid)).get("refs", []):
			conflict_ids[int(r)] = true
	var free: Dictionary = state.get("solve", {}).get("free", {})
	var selected := {}
	for item in selection:
		selected[str(item.kind) + str(item.id)] = true
	_measured_highlight = _measured_geometry(s, selected) if show.dimensions else {}
	for id in _samples:
		var e: Dictionary = s.entity(id)
		if e.is_empty() or (e.get("projected", false) and not show.projected):
			continue
		var color: Color = c.sketch_defined
		if conflict_ids.has(id):
			color = c.sketch_conflict
		elif e.get("projected", false) or e.type == "ref3d":
			color = c.sketch_projected
		elif e.get("construction", false):
			color = c.sketch_construction
		elif free.has(id) or e.type == "text":
			color = c.sketch_free
		elif e.get("centerline", false):
			color = c.sketch_centerline
		var width := 1.8
		if selected.has("entity" + str(id)):
			color = c.sketch_select
			width = 3.2
		elif hover.get("kind", "") == "entity" and int(hover.get("id", -1)) == id:
			color = color.lerp(c.sketch_select, 0.6)
			width = 2.8
		elif _measured_highlight.has(id):
			# Measured by the hovered or selected dimension: tinted and a little wider, so it shows on
			# free curves (blue already) too.
			color = color.lerp(c.dim_hover, 0.6)
			width = 2.8
		for line in _samples[id]:
			# A halo under each curve keeps it apart from the face behind it.
			if e.get("construction", false) or e.get("centerline", false):
				_dashed(overlay, line, c.sketch_halo, width + 3.0)
				_dashed(overlay, line, color, width)
			else:
				_polyline(overlay, line, c.sketch_halo, width + 3.0)
				_polyline(overlay, line, color, width)
	if show.points:
		for e in s.entities():
			if e.type != "point":
				continue
			var p := viewport.project(s.to_world(s.point(int(e.id))))
			if not p.is_finite():
				continue
			var color: Color = c.sketch_point if not free.has(int(e.id)) else c.sketch_free
			if e.get("origin", false):
				overlay.draw_line(p - Vector2(6, 0), p + Vector2(6, 0), c.sketch_origin, 1.5)
				overlay.draw_line(p - Vector2(0, 6), p + Vector2(0, 6), c.sketch_origin, 1.5)
				continue
			if e.get("projected", false):
				color = c.sketch_projected
			if selected.has("entity" + str(e.id)) or (hover.get("kind", "") == "entity" and int(hover.get("id", -1)) == int(e.id)):
				color = c.sketch_select
			elif _measured_highlight.has(int(e.id)):
				color = color.lerp(c.dim_hover, 0.6)
			overlay.draw_rect(Rect2(p - Vector2(3, 3), Vector2(6, 6)), color, true)
	# Dimensions sit over the constraint glyphs.
	if show.constraints:
		_draw_glyphs(overlay, s, selected)
	if show.dimensions:
		_draw_dimensions(overlay, s, selected)
	# A command over the sketch hides the tool's rubber band (the mouse isn't the tool's then).
	if not suspended:
		_draw_tool(overlay, s)
	# Over everything: the hovered dimension's tip and the value box's name pill.
	_tip_text = ""
	_pill_text = ""
	if suspended:
		return
	if _edit.visible:
		_follow_dimension(s)
		_pill_text = _pill_name()
		if _pill_text != "":
			var under := Vector2(_edit.position.x + _edit.size.x * 0.5, _edit.position.y + _edit.size.y + 4.0 * _ui_scale())
			_draw_pill(overlay, _pill_text, under, true)
	elif show.dimensions and hover.get("kind", "") == "constraint" and _drag.is_empty() and Input.get_mouse_button_mask() == 0:
		var hovered: Dictionary = s.constraint(int(hover.id))
		if hovered.has("key"):
			_tip_text = _dimension_tooltip(hovered)
			_draw_pill(overlay, _tip_text, mouse_screen + Vector2(8.0, 16.0) * _ui_scale(), false)


func _draw_grid(overlay: Control, s: SKETCH) -> void:
	var step: float = viewport.unit_scale * pow(10.0, floorf(log(maxf(viewport.distance / 6.0, 1e-6) / viewport.unit_scale) / log(10.0)))
	var center: Vector2 = s.to_plane(viewport.target).snapped(Vector2.ONE * step * 10.0)
	var count := 30
	for i in range(-count, count + 1):
		var color: Color = theme_colors.sketch_grid_major if i % 10 == 0 else theme_colors.sketch_grid_minor
		for axis in 2:
			var a := center + (Vector2(i * step, -count * step) if axis == 0 else Vector2(-count * step, i * step))
			var b := center + (Vector2(i * step, count * step) if axis == 0 else Vector2(count * step, i * step))
			var pa := viewport.project(s.to_world(a))
			var pb := viewport.project(s.to_world(b))
			if pa.is_finite() and pb.is_finite():
				overlay.draw_line(pa, pb, color, 1.0)


## Draws every dimension of the sketch as a drafting dimension (dimension_layout.gd): its value
## (or, in error, what the geometry measures), its state's colours, and its hit areas. Every
## dimension's lines go down first and every value over them, each on its halo (dim_halo), so a
## value reads on a body's face and where other dimensions' lines cross it.
func _draw_dimensions(overlay: Control, s: SKETCH, selected: Dictionary) -> void:
	var m := _metrics()
	var font := overlay.get_theme_default_font()
	var size := int(round(float(m.font)))
	var marker := _expression_marker(overlay)
	var frame := _frame_key(s, size)
	var drawn := {}
	var texts := []
	_layout_misses = 0
	for c in s.constraints():
		if not c.has("key"):
			continue
		var id := int(c.id)
		var label := _dimension_label(s, c, marker)
		var look := "error" if label.error else _dimension_state(id, selected)
		var width := font.get_string_size(label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
		var layout := _cached_layout(s, _shown_dimension(s, c), width, font, size, m, frame)
		drawn[id] = true
		if layout.is_empty():
			continue
		var colors := _draw_dimension_lines(overlay, layout, look, m)
		_dim_draw_log[id] = {"state": look, "color": colors[0], "text_color": colors[1], "width": colors[2], "text": label.text}
		# The value box covers the text of the dimension being edited.
		if look != "editing":
			texts.append([layout.text, label.text, width, colors[1]])
		_dim_hits.append({"id": id, "poly": layout.hit_poly, "segments": layout.hit_segments, "text_center": layout.text_center,
			"text_angle": float(layout.text.angle)})
	for id in _layout_cache.keys():
		if not drawn.has(id):
			_layout_cache.erase(id)
	for job: Array in texts:
		_draw_text_rotated(overlay, font, size, job[1], job[0], job[2], job[3])


## A dimension's canvas text and whether it is in error ({"text", "error"}): its value (a driven
## one's measured value), or for a broken parameter, a conflict, or a sketch that didn't solve to
## its value, what the geometry measures.
func _dimension_label(s: SKETCH, c: Dictionary, marker: String) -> Dictionary:
	var solve: Dictionary = state.get("solve", {})
	var value := NAN
	var expression := ""
	var broken := false
	if c.get("driving", true):
		var input: Dictionary = s.feature.inputs.get(c.key, {})
		expression = str(input.get("expression", ""))
		var result: Dictionary = workspace.result.get("values", {}).get(str(input.get("name", "")), {})
		broken = not result.get("ok", false)
		if not broken:
			value = float(result.value)
	else:
		value = float(solve.get("measured", {}).get(int(c.id), NAN))
	# What the geometry measures is only worked out when it is needed.
	var error: bool = broken or (solve.get("conflicting", []) as Array).has(int(c.id))
	if not error and not bool(solve.get("ok", true)) and not is_nan(value):
		error = not _same_size(value, DIM.measure(s, c))
	if error or is_nan(value):
		value = DIM.measure(s, c)
	return {"text": DIM.canvas_text(c, value, workspace.doc.units, expression, marker), "error": error}


## Draws one dimension (a pseudo-constraint such as a preview or the new dimension the value box is
## on, with type, refs and offset) in a state of DIM_STATE_COLORS, its text too unless show_text is
## false (a value box covers it); returns its screen layout ({} when off screen).
func _draw_dimension(overlay: Control, s: SKETCH, c: Dictionary, text: String, look: String, show_text := true) -> Dictionary:
	var m := _metrics()
	var font := overlay.get_theme_default_font()
	var size := int(round(float(m.font)))
	var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	var layout := _screen_layout(s, c, width, font, size, m)
	if layout.is_empty():
		return {}
	var colors := _draw_dimension_lines(overlay, layout, look, m)
	# The value box covers the text of the dimension being edited.
	if look != "editing" and show_text:
		_draw_text_rotated(overlay, font, size, text, layout.text, width, colors[1])
	if c.has("id"):
		_dim_draw_log[int(c.id)] = {"state": look, "color": colors[0], "text_color": colors[1], "width": colors[2], "text": text}
	return layout


## Draws a dimension's lines, arcs and arrows on their halo in a state of DIM_STATE_COLORS;
## returns [line colour, text colour, line width].
func _draw_dimension_lines(overlay: Control, layout: Dictionary, look: String, m: Dictionary) -> Array:
	var keys: Array = DIM_STATE_COLORS.get(look, DIM_STATE_COLORS.normal)
	var line_color: Color = theme_colors[keys[0]]
	var text_color: Color = theme_colors[keys[1]]
	var width: float = m.line_selected if look == "selected" else m.line
	var strokes: PackedVector2Array = layout.strokes
	var halo: Color = theme_colors.dim_halo
	if halo.a > 0.0:
		var wide := width + 2.0 * _ui_scale()
		if not strokes.is_empty():
			overlay.draw_multiline(strokes, halo, wide, true)
		for line: PackedVector2Array in layout.polylines:
			overlay.draw_polyline(line, halo, wide, true)
	if not strokes.is_empty():
		overlay.draw_multiline(strokes, line_color, width, true)
	for line: PackedVector2Array in layout.polylines:
		overlay.draw_polyline(line, line_color, width, true)
	for fill: PackedVector2Array in layout.fills:
		overlay.draw_colored_polygon(fill, line_color)
	return [line_color, text_color, width]


## The pixel metrics dimensions are drawn with at the UI scale; while points are shown, extension
## lines keep clear of their markers (drawn 6 px square at any scale).
func _metrics() -> Dictionary:
	var m := DIM.metrics(_ui_scale())
	m["mark"] = 3.0 if show.points else 0.0
	return m


## What every dimension's screen layout in this draw depends on besides the dimension itself, as
## one hash: the camera, the view's size, the sketch plane, the UI scale and font size, whether
## points are shown, and the sketch's geometry.
func _frame_key(s: SKETCH, size: int) -> int:
	var camera: Camera3D = viewport._camera
	return hash([camera.global_transform, camera.projection, camera.fov, camera.size, camera.near, camera.far,
		camera.get_viewport().get_visible_rect().size, s.transform(), _ui_scale(), size, show.points, hash(s.entities())])


## A dimension's screen layout, from the cache while nothing it depends on changed (frame: a
## _frame_key(); the dimension and its text's width).
func _cached_layout(s: SKETCH, c: Dictionary, width: float, font: Font, size: int, m: Dictionary, frame: int) -> Dictionary:
	var id := int(c.id)
	var key := [frame, hash(c), width]
	var cached: Dictionary = _layout_cache.get(id, {})
	if cached.get("key", []) == key:
		return cached.layout
	_layout_misses += 1
	var layout := _screen_layout(s, c, width, font, size, m)
	_layout_cache[id] = {"key": key, "layout": layout}
	return layout


## A dimension's screen layout (dimension_layout.gd) for its text width wide in font at size, with
## what drawing it takes: "strokes" (its straight lines and arrow outlines, in pairs) and "fills"
## (its arrows' triangles).
func _screen_layout(s: SKETCH, c: Dictionary, width: float, font: Font, size: int, m: Dictionary) -> Dictionary:
	var plane := DIM.plane_layout(s, c, _dimension_anchor(s, c))
	var to_screen := func(p: Vector2) -> Vector2: return viewport.project(s.to_world(p))
	var layout := DIM.screen_layout(plane, to_screen, m, width, font.get_ascent(size), font.get_descent(size))
	if layout.is_empty():
		return layout
	var strokes := PackedVector2Array()
	for segment: Array in (layout.ext_lines as Array) + (layout.dim_lines as Array):
		strokes.append(segment[0])
		strokes.append(segment[1])
	var fills := []
	for arrow: Dictionary in layout.arrows:
		var dir: Vector2 = arrow.dir
		if not dir.is_finite() or dir.length_squared() < 1e-12:
			continue
		var tri := _arrow_points(arrow.tip, dir, m)
		fills.append(tri)
		strokes.append_array([tri[0], tri[1], tri[1], tri[2], tri[2], tri[0]])
	layout["strokes"] = strokes
	layout["fills"] = fills
	return layout


## A dimension's screen layout with its text measured in font (the view's font when null); {}
## when it is off screen.
func _layout_for(s: SKETCH, c: Dictionary, text: String, font: Font = null) -> Dictionary:
	var m := _metrics()
	if font == null:
		font = viewport.get_theme_default_font()
	var size := int(round(float(m.font)))
	return _screen_layout(s, c, font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x, font, size, m)


## The dimension as it is laid out: an angle from before rays existed in the sector _legacy_sector
## picks (the one its value is), others as they are.
func _shown_dimension(s: SKETCH, c: Dictionary) -> Dictionary:
	if c.get("type", "") != "angle" or c.has("rays") or (c.get("refs", []) as Array).size() != 2:
		return c
	var sector := _legacy_sector(s, c)
	if sector.is_empty():
		return c
	var shown := c.duplicate()
	shown["refs"] = sector.refs
	shown["rays"] = sector.rays
	return shown


## error > editing (its value box is open) > selected > hovered > normal; error is decided by the
## caller, preview by whoever draws one.
func _dimension_state(id: int, selected: Dictionary) -> String:
	if _edit.visible and _edit_constraint == id:
		return "editing"
	if selected.has("constraint" + str(id)):
		return "selected"
	if hover.get("kind", "") == "constraint" and int(hover.get("id", -1)) == id:
		return "hovered"
	return "normal"


## The marker before values set by an expression: "ƒ " where the font has the letter, else "f ".
func _expression_marker(overlay: Control) -> String:
	return "ƒ " if overlay.get_theme_default_font().has_char(0x192) else "f "


## Two sizes are the same up to 1e-6 relative (what the plane's single-precision points measure
## to; signs ignored: a horizontal distance can be stored negative).
func _same_size(target: float, geometric: float) -> bool:
	return absf(absf(target) - absf(geometric)) <= 1e-6 * maxf(absf(geometric), 1e-6)


## An arrowhead's triangle [tip, left, right] (tip pointing along dir), half its 1 px anti-aliased
## outline narrower and shorter than the arrow: filled and outlined, the arrow shows at its own
## length and width.
func _arrow_points(tip: Vector2, dir: Vector2, m: Dictionary) -> PackedVector2Array:
	var stroke := float(m.line) * 0.5
	var perp := dir.orthogonal()
	var base := tip - dir * (float(m.arrow_len) - stroke)
	var half := maxf(float(m.arrow_half) - stroke, stroke)
	return PackedVector2Array([tip, base + perp * half, base - perp * half])


## Draws text as a layout's "text" places it ({"anchor", "angle", "align", "baseline"}), on its
## halo, with its baseline start on a whole pixel so straight text stays crisp.
func _draw_text_rotated(overlay: Control, font: Font, size: int, text: String, placed: Dictionary, width: float, color: Color) -> void:
	var angle: float = placed.angle
	var origin: Vector2 = (placed.anchor as Vector2) + Vector2(DIM.text_x(str(placed.align), width), float(placed.baseline)).rotated(angle)
	overlay.draw_set_transform(origin.round(), angle, Vector2.ONE)
	var halo: Color = theme_colors.dim_halo
	if halo.a > 0.0:
		overlay.draw_string_outline(font, Vector2.ZERO, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, maxi(1, roundi(4.0 * _ui_scale())), halo)
	overlay.draw_string(font, Vector2.ZERO, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)
	overlay.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _ui_scale() -> float:
	if ui_scale > 0.0:
		return ui_scale
	return EditorInterface.get_editor_scale() if Engine.is_editor_hint() else 1.0


## Where a dimension's label hangs from: the middle of what it measures.
func _dimension_anchor(s: SKETCH, c: Dictionary) -> Vector2:
	var points := []
	for r in c.refs:
		var e: Dictionary = s.entity(int(r))
		match str(e.get("type", "")):
			"point":
				points.append(s.point(int(r)))
			"line":
				points.append((s.point(int(e.p1)) + s.point(int(e.p2))) * 0.5)
			"circle", "arc":
				points.append(s.point(int(e.c)) + Vector2(float(e.r), 0).rotated(PI * 0.25))
	var sum := Vector2.ZERO
	for p in points:
		sum += p
	return sum / maxf(points.size(), 1.0)


func _draw_glyphs(overlay: Control, s: SKETCH, selected: Dictionary) -> void:
	var font := overlay.get_theme_default_font()
	var stacks := {}
	for c in s.constraints():
		if c.has("key") or not GLYPHS.has(str(c.type)):
			continue
		if c.type == "coincident" and s.entity(int(c.refs[0])).get("type", "") == "point" and s.entity(int(c.refs[c.refs.size() - 1])).get("type", "") == "point":
			continue
		var owner_id := int(c.refs[0])
		var anchor := _dimension_anchor(s, {"refs": [owner_id]})
		var at := viewport.project(s.to_world(anchor))
		if not at.is_finite():
			continue
		var stack := int(stacks.get(owner_id, 0))
		stacks[owner_id] = stack + 1
		var rect := Rect2(at + Vector2(8 + stack * 18, 6), Vector2(16, 16))
		var is_selected := selected.has("constraint" + str(c.id))
		var conflicting: bool = (state.get("solve", {}).get("conflicting", []) as Array).has(int(c.id))
		var t := theme_colors
		overlay.draw_rect(rect, t.glyph_back_selected if is_selected else t.glyph_back, true)
		overlay.draw_rect(rect, t.sketch_conflict if conflicting else t.glyph_border, false, 1.0)
		overlay.draw_string(font, rect.position + Vector2(3, 13), GLYPHS[c.type], HORIZONTAL_ALIGNMENT_LEFT, -1, 12, t.glyph_text)
		_label_rects.append({"rect": rect, "id": int(c.id)})


func _draw_tool(overlay: Control, s: SKETCH) -> void:
	if tool == "":
		return
	var preview := _preview()
	var accent: Color = theme_colors.sketch_select
	for line in preview:
		_dashed(overlay, line, accent, 2.0)
	if show.dimensions or _heads_up_open():
		_draw_heads_up(overlay, s)
	for pick in tool_picks:
		var id := int(pick.get("curve", pick.get("id", -1)))
		for line in _samples.get(id, []):
			_polyline(overlay, line, accent, 3.2)
	var dimension: bool = TOOLS.get(tool, {}).get("dimension", false)
	if dimension:
		_draw_dimension_preview(overlay, s)
	# A dimension being placed goes where the cursor is, unsnapped: no snap ring then.
	if dimension and not tool_picks.is_empty():
		return
	if not mouse_snap.is_empty() or show.snap:
		var p := viewport.project(s.to_world(mouse_plane))
		if p.is_finite():
			overlay.draw_arc(p, 5.0, 0.0, TAU, 16, accent, 1.5)
			var glyph := str(mouse_snap.get("glyph", ""))
			if glyph != "":
				overlay.draw_string(overlay.get_theme_default_font(), p + Vector2(8, -8), glyph, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, accent)


## The Sketch Dimension tool's dimension: while its value box is open, the new dimension it is on
## (its text under the box); else, with picks, the dimension they make at the cursor, in the
## preview colours, with the value it measures.
func _draw_dimension_preview(overlay: Control, s: SKETCH) -> void:
	_preview_dimension = {}
	_pending_center = Vector2.INF
	var units: String = workspace.doc.units
	if _edit.visible:
		if not _pending_dimension.is_empty():
			var pending := _pseudo_dimension(_pending_dimension)
			var layout := _draw_dimension(overlay, s, pending, DIM.canvas_text(pending, float(pending.value), units, "", ""), "editing")
			_pending_center = layout.get("text_center", Vector2.INF)
		return
	if tool_picks.is_empty():
		return
	var spec := dimension_spec(_pick_ids(), mouse_plane_raw, _dim_overrides)
	if spec.is_empty():
		return
	_dim_last_orientation = str(spec.get("orientation", ""))
	var preview := _pseudo_dimension(spec)
	_draw_dimension(overlay, s, preview, DIM.canvas_text(preview, float(spec.value), units, "", ""), "preview")
	_preview_dimension = preview


## A dimension_spec() result drawn as a dimension: id -1, driven when the Driven choice is on.
func _pseudo_dimension(spec: Dictionary) -> Dictionary:
	var c := spec.duplicate(true)
	c["id"] = -1
	c["driving"] = not bool(_dim_overrides.get("driven", false))
	return c


## The geometry the hovered dimension and the selected ones measure: entity id -> true.
func _measured_geometry(s: SKETCH, selected: Dictionary) -> Dictionary:
	var ids := {}
	var dims := []
	if hover.get("kind", "") == "constraint":
		dims.append(int(hover.id))
	for key: String in selected:
		if key.begins_with("constraint"):
			dims.append(int(key.trim_prefix("constraint")))
	for id: int in dims:
		var c: Dictionary = s.constraint(id)
		if c.has("key"):
			for r in c.refs:
				ids[int(r)] = true
	return ids


## The hover tip of a dimension: "d3 = 40 mm", "d3 = d1 / 2  (20 mm)", "Driven: 40 mm", or for a
## parameter that fails "d3: " and why.
func _dimension_tooltip(c: Dictionary) -> String:
	var s := sketch()
	var units: String = workspace.doc.units
	var kind := str(c.get("kind", "length"))
	if not c.get("driving", true):
		var measured: Dictionary = state.get("solve", {}).get("measured", {})
		return "Driven: " + UNITS.format_value(absf(float(measured.get(int(c.id), _measured_value(s, c)))), kind, units)
	var input: Dictionary = s.feature.inputs.get(c.key, {})
	var name := str(input.get("name", ""))
	var expression := str(input.get("expression", "")).strip_edges()
	var result: Dictionary = workspace.result.get("values", {}).get(name, {})
	if not result.get("ok", false):
		return "%s: %s" % [name, str(result.get("error", "not evaluated"))]
	var value := UNITS.format_value(float(result.value), kind, units)
	if DIM.is_number(expression):
		return "%s = %s" % [name, value]
	return "%s = %s  (%s)" % [name, expression, value]


## The parameter name the dimension in the value box has or will get: one typed as "name = ...",
## else its own, else the one it had (a driven one made driving), else the next dN.
func _pill_name() -> String:
	var typed := str(_split_name(_edit.text).get("name", ""))
	if typed != "":
		return typed
	var s := sketch()
	var next := "d%d" % (int(workspace.doc.counters.get("d", 0)) + 1)
	if not _pending_dimension.is_empty():
		return next
	var c: Dictionary = s.constraint(_edit_constraint) if s != null and _edit_constraint >= 0 else {}
	if c.is_empty():
		return ""
	if c.get("driving", true):
		return str(s.feature.inputs.get(c.key, {}).get("name", ""))
	var kept := str(c.get("param_name", ""))
	return kept if kept != "" and PARAMETERS.is_valid_name(workspace.doc, kept) else next


## A pill (the tip's box, dim_tip_text): top-centred on at (centered), else its top-left at at;
## kept inside the view.
func _draw_pill(overlay: Control, text: String, at: Vector2, centered: bool) -> void:
	if _tip_style == null or text == "":
		return
	var font := overlay.get_theme_default_font()
	var size := int(round(float(DIM.METRICS.tip_font) * _ui_scale()))
	var text_size := Vector2(font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x, font.get_ascent(size) + font.get_descent(size))
	var box := text_size + Vector2(_tip_style.content_margin_left + _tip_style.content_margin_right, _tip_style.content_margin_top + _tip_style.content_margin_bottom)
	var corner := at - Vector2(box.x * 0.5, 0.0) if centered else at
	var margin := 4.0 * _ui_scale()
	corner = corner.clamp(Vector2(margin, margin), (overlay.size - box - Vector2(margin, margin)).max(Vector2(margin, margin)))
	overlay.draw_style_box(_tip_style, Rect2(corner.round(), box))
	var baseline := corner.round() + Vector2(_tip_style.content_margin_left, _tip_style.content_margin_top + font.get_ascent(size))
	overlay.draw_string(font, baseline, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, theme_colors.dim_tip_text)


func _polyline(overlay: Control, line: PackedVector3Array, color: Color, width: float) -> void:
	var screen := PackedVector2Array()
	for p in line:
		var q := viewport.project(p)
		if not q.is_finite():
			if screen.size() > 1:
				overlay.draw_polyline(screen, color, width, true)
			screen = PackedVector2Array()
			continue
		screen.append(q)
	if screen.size() > 1:
		overlay.draw_polyline(screen, color, width, true)


func _dashed(overlay: Control, line: PackedVector3Array, color: Color, width: float) -> void:
	for i in line.size() - 1:
		var a := viewport.project(line[i])
		var b := viewport.project(line[i + 1])
		if a.is_finite() and b.is_finite():
			overlay.draw_dashed_line(a, b, color, width, 6.0)


# --- Picking and snapping --------------------------------------------------------------------

## The sketch item under the mouse: {"kind": "entity"|"constraint", "id"} or {}.
## A point right under the cursor wins, then dimension text, glyphs, curves, and last the
## dimensions' own lines (so geometry under them can still be picked).
func hit(screen: Vector2) -> Dictionary:
	var s := sketch()
	if s == null:
		return {}
	var best := {}
	var best_px := PICK_PX
	for e in s.entities():
		if e.type == "point" and not e.get("origin", false) and not show.points:
			continue
		if e.type == "point":
			var p := viewport.project(s.to_world(s.point(int(e.id))))
			if p.is_finite() and p.distance_to(screen) < best_px:
				best_px = p.distance_to(screen) - 2.0
				best = {"kind": "entity", "id": int(e.id)}
	if not best.is_empty():
		return best
	# Dimensions drawn last lie on top.
	for i in range(_dim_hits.size() - 1, -1, -1):
		if Geometry2D.is_point_in_polygon(screen, _dim_hits[i].poly):
			return {"kind": "constraint", "id": int(_dim_hits[i].id)}
	for label in _label_rects:
		if (label.rect as Rect2).has_point(screen):
			return {"kind": "constraint", "id": label.id}
	best_px = PICK_PX
	for id in _samples:
		for line in _samples[id]:
			for i in (line as PackedVector3Array).size() - 1:
				var a := viewport.project(line[i])
				var b := viewport.project(line[i + 1])
				if not (a.is_finite() and b.is_finite()):
					continue
				var d := Geometry2D.get_closest_point_to_segment(screen, a, b).distance_to(screen)
				if d < best_px:
					best_px = d
					best = {"kind": "entity", "id": int(id)}
	if not best.is_empty():
		return best
	best_px = float(DIM.metrics(_ui_scale()).hit)
	for entry in _dim_hits:
		for segment: Array in entry.segments:
			var d := Geometry2D.get_closest_point_to_segment(screen, segment[0], segment[1]).distance_to(screen)
			if d < best_px:
				best_px = d
				best = {"kind": "constraint", "id": int(entry.id)}
	return best


## The mouse position in the sketch plane, snapped to points, midpoints, curves, the grid and
## the previous point's axes. Returns {"pos", "snap", "glyph"}.
func snap_at(screen: Vector2) -> Dictionary:
	var s := sketch()
	var world = viewport.plane_hit(screen, s.to_world(Vector2.ZERO), s.normal())
	if world == null:
		return {"pos": mouse_plane, "snap": {}, "glyph": ""}
	var pos: Vector2 = s.to_plane(world)
	for e in s.entities():
		if e.type != "point":
			continue
		var p := viewport.project(s.to_world(s.point(int(e.id))))
		if p.is_finite() and p.distance_to(screen) < SNAP_PX:
			return {"pos": s.point(int(e.id)), "snap": {"point": int(e.id)}, "glyph": "⊙"}
	for e in s.entities():
		if e.type == "line":
			var mid: Vector2 = (s.point(int(e.p1)) + s.point(int(e.p2))) * 0.5
			var p := viewport.project(s.to_world(mid))
			if p.is_finite() and p.distance_to(screen) < SNAP_PX:
				return {"pos": mid, "snap": {"midpoint": int(e.id)}, "glyph": "M"}
	var curve_hit := hit(screen)
	if curve_hit.get("kind", "") == "entity" and s.entity(int(curve_hit.id)).get("type", "") in ["line", "circle", "arc", "ellipse", "spline", "conic"]:
		var near: Dictionary = workspace.kernel.curve_closest_point(s.curve_of(int(curve_hit.id)), pos)
		if not near.is_empty():
			return {"pos": near.point, "snap": {"curve": int(curve_hit.id)}, "glyph": "∈"}
	var glyph := ""
	if show.snap:
		var step: float = viewport.unit_scale * pow(10.0, floorf(log(maxf(viewport.distance / 6.0, 1e-6) / viewport.unit_scale) / log(10.0)))
		pos = pos.snapped(Vector2.ONE * step * 0.5)
	if not tool_points.is_empty():
		var previous: Vector2 = tool_points[tool_points.size() - 1]
		var ppm: float = viewport.pixels_per_meter_at(world)
		if absf(pos.y - previous.y) * ppm < 6.0:
			pos.y = previous.y
			glyph = "H"
		elif absf(pos.x - previous.x) * ppm < 6.0:
			pos.x = previous.x
			glyph = "V"
	return {"pos": pos, "snap": {}, "glyph": glyph}


func _profile_at(plane: Vector2) -> int:
	var best := -1
	var best_area := INF
	var regions: Array = state.get("regions", [])
	for i in regions.size():
		var loops: Array = regions[i].loops
		if loops.is_empty() or not Geometry2D.is_point_in_polygon(plane, loops[0]):
			continue
		var in_hole := false
		for k in range(1, loops.size()):
			in_hole = in_hole or Geometry2D.is_point_in_polygon(plane, loops[k])
		if not in_hole and float(regions[i].area) < best_area:
			best_area = float(regions[i].area)
			best = i
	return best


# --- Mouse ----------------------------------------------------------------------------------

## Sketch mode's first look at left clicks and moves; returns true when it used the event.
func handle_mouse(event: InputEvent) -> bool:
	if not active or suspended:
		return false
	var mouse := event as InputEventMouse
	mouse_screen = mouse.position
	var snapped := snap_at(mouse.position)
	mouse_plane = snapped.pos
	mouse_snap = snapped.snap.duplicate()
	mouse_snap["glyph"] = snapped.glyph
	var s := sketch()
	var world: Variant = viewport.plane_hit(mouse.position, s.to_world(Vector2.ZERO), s.normal())
	mouse_plane_raw = s.to_plane(world) if world != null else mouse_plane
	var button := event as InputEventMouseButton
	# While the value box is open a press is the box's (a dimension's name goes in, anywhere else
	# accepts), and so is the release after it: no pick or placement starts under the box.
	if button != null and button.pressed and _edit.visible:
		_swallow_release = true
		_click_while_editing(button.position)
		return true
	if button != null and not button.pressed and _swallow_release:
		_swallow_release = false
		return true
	if event is InputEventMouseMotion:
		return _mouse_move(event)
	if button.pressed:
		return _mouse_press(button)
	return _mouse_release(button)


func _mouse_move(event: InputEventMouseMotion) -> bool:
	if not _drag.is_empty():
		var s := sketch()
		if _drag.type == "point":
			_drag.moved = true
			SOLVE.solve(s, workspace.result.get("values", {}), {"point": _drag.id, "target": mouse_plane})
			_samples.clear()
			_sample_sketch(s, state, _samples)
		elif _drag.type == "window":
			_drag.end = event.position
		elif _drag.type == "dim_text":
			# The text (and the whole dimension with it) follows the mouse, unsnapped; no solve.
			if not _drag.moved and event.position.distance_to(_drag.start) <= DIM_DRAG_PX * _ui_scale():
				return true
			_drag.moved = true
			var c: Dictionary = s.constraint(int(_drag.id))
			if not c.is_empty():
				c["offset"] = (mouse_plane_raw + (_drag.grab as Vector2)) - _dimension_anchor(s, c)
		viewport.redraw_overlay()
		return true
	if tool != "" and TOOLS.get(tool, {}).has("picks3d") and tool_picks.size() >= int(TOOLS[tool].get("picks", 0)):
		return false
	# Once the picks are complete every click places the dimension: nothing under the cursor lights up.
	var placing: bool = TOOLS.get(tool, {}).get("dimension", false) and _picks_complete() and not _edit.visible
	var new_hover := {} if placing or (tool != "" and not TOOLS.get(tool, {}).has("picks")) else hit(event.position)
	if tool == "" and new_hover.is_empty():
		var profile := _profile_at(mouse_plane)
		if profile != _hover_profile:
			_hover_profile = profile
			_update_profile_meshes()
	if str(new_hover) != str(hover):
		hover = new_hover
	viewport.redraw_overlay()
	return tool != "" or not hover.is_empty()


func _mouse_press(event: InputEventMouseButton) -> bool:
	if tool != "":
		if TOOLS.get(tool, {}).has("picks3d") and tool_picks.size() >= int(TOOLS[tool].get("picks", 0)):
			return false
		return true
	var target := hit(event.position)
	if target.is_empty():
		_drag = {"type": "window", "start": event.position, "end": event.position, "additive": event.shift_pressed or event.ctrl_pressed}
		return true
	if event.double_click and target.kind == "constraint":
		open_dimension_edit(int(target.id))
		return true
	_toggle_select(target, event.shift_pressed or event.ctrl_pressed)
	var s := sketch()
	var dimension: Dictionary = s.constraint(int(target.id)) if target.kind == "constraint" else {}
	if dimension.has("key"):
		# A press on a dimension selects it; dragged, it moves its text (see _mouse_move).
		var text_at := _dimension_anchor(s, dimension) + (dimension.get("offset", Vector2.ZERO) as Vector2)
		_drag = {"type": "dim_text", "id": int(dimension.id), "start": event.position, "before": workspace.doc.snapshot(),
			"grab": text_at - mouse_plane_raw, "moved": false}
		return true
	var e: Dictionary = s.entity(int(target.id)) if target.kind == "entity" else {}
	if not e.is_empty() and not e.get("projected", false):
		var point_id := int(target.id) if e.type == "point" else _nearest_point_of(s, int(target.id), mouse_plane)
		if point_id >= 0 and not s.entity(point_id).get("fixed", false):
			_drag = {"type": "point", "id": point_id, "before": workspace.doc.snapshot(), "moved": false}
	return true


func _mouse_release(event: InputEventMouseButton) -> bool:
	if tool != "":
		if TOOLS.get(tool, {}).has("picks3d") and tool_picks.size() >= int(TOOLS[tool].get("picks", 0)):
			return false
		tool_click(mouse_plane_raw if TOOLS.get(tool, {}).get("dimension", false) else mouse_plane, mouse_snap, hit(event.position))
		return true
	var drag := _drag
	_drag = {}
	match str(drag.get("type", "")):
		"point":
			# (A click on a point only selects it: no undo step.)
			if drag.moved:
				workspace.commit_change("Drag Sketch Geometry", drag.before)
		"dim_text":
			if drag.moved:
				workspace.commit_change("Sketch: Move Dimension", drag.before)
		"window":
			_window_select(Rect2(drag.start, (drag.end as Vector2) - (drag.start as Vector2)), (drag.end as Vector2).x < (drag.start as Vector2).x, drag.additive)
	viewport.redraw_overlay()
	return true


func _nearest_point_of(s: SKETCH, id: int, plane: Vector2) -> int:
	var best := -1
	var best_d := INF
	for p in s.points_of(id):
		var d: float = s.point(p).distance_to(plane)
		if d < best_d:
			best_d = d
			best = p
	return best


func _toggle_select(item: Dictionary, additive: bool) -> void:
	var index := -1
	for i in selection.size():
		if selection[i].kind == item.kind and int(selection[i].id) == int(item.id):
			index = i
	if not additive:
		selection.clear()
		if index >= 0:
			index = -1
	if index >= 0:
		selection.remove_at(index)
	else:
		selection.append({"kind": item.kind, "id": int(item.id)})
	viewport.redraw_overlay()


func _window_select(rect: Rect2, crossing: bool, additive: bool) -> void:
	rect = rect.abs()
	if rect.size.length() < 4.0:
		if not additive:
			selection.clear()
		return
	if not additive:
		selection.clear()
	for id in _samples:
		var inside := 0
		var total := 0
		for line in _samples[id]:
			for p in line:
				var q := viewport.project(p)
				total += 1
				if q.is_finite() and rect.has_point(q):
					inside += 1
		if total > 0 and ((crossing and inside > 0) or (not crossing and inside == total)):
			selection.append({"kind": "entity", "id": int(id)})
	viewport.redraw_overlay()


func selected_entities() -> Array:
	return selection.filter(func(item: Dictionary) -> bool: return item.kind == "entity").map(func(item: Dictionary) -> int: return int(item.id))


# --- Keys ------------------------------------------------------------------------------------

func handle_key(event: InputEventKey) -> bool:
	if not active:
		return false
	if suspended:
		# The command over the sketch takes Escape and Enter; Delete waits until it closes.
		return event.keycode in [KEY_DELETE, KEY_BACKSPACE]
	# While a line, rectangle or circle is being drawn a typed number opens the heads-up fields on
	# the first one (a line's length), Tab on the second (its angle).
	if _heads_up_ready():
		var typed := _value_char(event)
		if typed != "" or event.keycode == KEY_TAB:
			if _heads_up_open():
				# The view had the keyboard: the field takes it back, and the key.
				_focus_heads_up(_heads_up_field, typed == "")
				if typed != "":
					var box: LineEdit = _heads_up[_heads_up_field]
					if box.has_selection():
						box.delete_text(box.get_selection_from_column(), box.get_selection_to_column())
						box.deselect()
					box.insert_text_at_caret(typed)
					_on_heads_up_changed(box.text, _heads_up_field)
			else:
				var fields := _heads_up_fields()
				_open_heads_up(fields[0] if typed != "" or fields.size() < 2 else fields[1], typed)
			return true
	match event.keycode:
		KEY_ESCAPE:
			# In stages: the value box or the heads-up fields, then a dimension's picks, then the tool.
			if _heads_up_open():
				_hide_heads_up(_heads_up_fields())
				viewport.focus_view()
			elif _edit.visible:
				_end_edit()
			elif tool != "":
				if tool in ["line", "spline_fit", "spline_control"] and not tool_points.is_empty():
					_finish_open_tool()
				elif TOOLS.get(tool, {}).get("dimension", false) and not tool_picks.is_empty():
					_clear_dimension_picks()
					workspace.flash(_tool_hint(tool))
				else:
					cancel_tool()
			elif not selection.is_empty():
				selection.clear()
				viewport.redraw_overlay()
			else:
				return false
			return true
		KEY_ENTER, KEY_KP_ENTER:
			if _edit.visible:
				_on_edit_submitted(_edit.text)
				return true
			if _heads_up_open():
				_on_heads_up_submitted((_heads_up[_heads_up_field] as LineEdit).text, _heads_up_field)
				return true
			if tool != "":
				tool_ok()
				return true
		KEY_DELETE, KEY_BACKSPACE:
			delete_selection()
			return true
	return false


# --- Tools -----------------------------------------------------------------------------------

func start_tool(name: String) -> void:
	_close_command()
	cancel_tool()
	if name.begins_with("constraint:"):
		var kind := name.trim_prefix("constraint:")
		if selection.size() == int(CONSTRAINT_PICKS.get(kind, 0)):
			apply_constraint(kind, selected_entities())
			return
	tool = name
	tool_points.clear()
	tool_snaps.clear()
	tool_picks.clear()
	tool_picks3d.clear()
	_clear_dimension_picks()
	tool_selection = selected_entities()
	tool_values = _tool_defaults(name)
	var spec: Dictionary = TOOLS.get(name, {})
	_show_tool_panel()
	if spec.get("selection", false) and tool_selection.is_empty():
		workspace.flash("Select the sketch geometry to use, then pick again.")
	else:
		workspace.flash(_tool_hint(name))
	viewport.redraw_overlay()


## Shows the running tool's options (tools with fields or an OK step) in the command panel.
func _show_tool_panel() -> void:
	var spec: Dictionary = TOOLS.get(tool, {})
	if not (spec.has("fields") or spec.get("ok", false)):
		return
	workspace.panel.setup(_tool_title(tool), _tool_fields(tool), tool_values, workspace.doc.units)
	workspace.panel.set_ok_text("OK" if spec.get("ok", false) else "Close")
	# No hints: OK is enabled even if a command before left it greyed.
	workspace.panel.set_hints({})
	workspace.panel.visible = true
	workspace.place_panel()


## Stops the running tool; an open value box closes with it (nothing is added or changed).
func cancel_tool() -> void:
	if _edit.visible or _edit_waiting:
		_close_edit()
	_close_heads_up()
	_chain_line = -1
	if tool == "":
		return
	tool = ""
	tool_points.clear()
	tool_snaps.clear()
	tool_picks.clear()
	tool_picks3d.clear()
	_clear_dimension_picks()
	# While a command runs over the sketch the panel is the command's.
	if not suspended:
		workspace.panel.visible = false
		workspace.panel.set_ok_text("OK")
	viewport.redraw_overlay()


## The panel's OK (or Enter): finishes open tools and option-based tools.
func tool_ok() -> void:
	if tool == "":
		return
	if tool in ["line", "spline_fit", "spline_control"]:
		_finish_open_tool()
		return
	var spec: Dictionary = TOOLS.get(tool, {})
	if spec.get("ok", false) or spec.has("picks3d"):
		_commit_tool()
		return
	cancel_tool()


func on_panel_values(values: Dictionary) -> void:
	tool_values = values.duplicate(true)
	viewport.redraw_overlay()


## A click while a tool is running: a pick (entities, corners, ends) or a point.
func tool_click(plane: Vector2, snap: Dictionary, target: Dictionary) -> void:
	var spec: Dictionary = TOOLS.get(tool, {})
	var s := sketch()
	if tool.begins_with("constraint:") or spec.get("dimension", false):
		_constraint_or_dimension_click(target, plane)
		return
	if spec.get("selection", false) and tool_selection.is_empty():
		if target.get("kind", "") == "entity":
			_toggle_select(target, true)
		tool_selection = selected_entities()
		return
	var needed_picks := int(spec.get("picks", 0))
	if tool_picks.size() < needed_picks:
		var pick := _pick_for(s, str(spec.get("pick", "any")), target, plane)
		if pick.is_empty():
			workspace.flash(_tool_hint(tool))
			return
		tool_picks.append(pick)
		if spec.get("repeat", false):
			_commit_tool()
			tool_picks.clear()
			return
		if tool_picks.size() == needed_picks and int(spec.get("clicks", 0)) == 0 and not spec.get("ok", false):
			_commit_tool()
		viewport.redraw_overlay()
		return
	if _heads_up_locked():
		# Locked heads-up values place the point; a snap there no longer holds.
		plane = _heads_up_point(plane)
		snap = {}
	tool_points.append(plane)
	tool_snaps.append(snap.duplicate())
	var clicks := int(spec.get("clicks", 0))
	if tool == "line" and tool_points.size() == 2:
		# Each segment is its own undo step; the next one starts where this one ended.
		_commit_tool()
		return
	if clicks > 0 and tool_points.size() >= clicks:
		_commit_tool()
	elif HEADS_UP_TOOLS.has(tool):
		# A step before the last (a 3-point rectangle's first edge): the boxes close and the view
		# gets the keyboard back; locked values stay for the dimensions the shape gets.
		var was_open := _heads_up_open()
		_hide_heads_up([])
		if was_open:
			viewport.focus_view()
	viewport.redraw_overlay()


func _pick_for(s: SKETCH, kind: String, target: Dictionary, plane: Vector2) -> Dictionary:
	if target.get("kind", "") != "entity":
		return {}
	var id := int(target.id)
	var e: Dictionary = s.entity(id)
	match kind:
		"line":
			return {"id": id} if e.type == "line" else {}
		"curve":
			return {"id": id, "plane": plane} if e.type in ["line", "circle", "arc", "ellipse", "spline", "conic"] else {}
		"corner":
			if e.type == "point" and not B.corner_lines(s, id).is_empty():
				return {"id": id}
			if e.type == "line":
				var near := _nearest_point_of(s, id, plane)
				return {"id": near} if not B.corner_lines(s, near).is_empty() else {}
			return {}
		"end":
			var point_id := id if e.type == "point" else _nearest_point_of(s, id, plane)
			for user in s.users_of_point(point_id):
				var u: Dictionary = s.entity(user)
				if u.type == "line" or (u.type == "arc" and (int(u.s) == point_id or int(u.e) == point_id)) or u.type == "spline":
					return {"point": point_id, "curve": user}
			return {}
	return {"id": id}


func _finish_open_tool() -> void:
	if tool in ["spline_fit", "spline_control"] and tool_points.size() >= 2:
		_commit_tool()
	tool_points.clear()
	tool_snaps.clear()
	_close_heads_up()
	_chain_line = -1
	if tool == "line":
		workspace.flash("Line finished.")
	viewport.redraw_overlay()


func _commit_tool() -> void:
	var name := tool
	var points := tool_points.duplicate()
	var snaps := tool_snaps.duplicate()
	var picks := tool_picks.duplicate()
	var values := tool_values.duplicate(true)
	var selected := tool_selection.duplicate()
	var outcome := [null]
	# Locked heads-up values become driving dimensions in the shape's own step, unless the sketch
	# can't take them (checked on a scratch copy first).
	var locks := _heads_up_plan(points) if HEADS_UP_TOOLS.has(name) else {}
	var was_heads_up := _heads_up_open()
	var add_shape := func(s: SKETCH) -> Variant:
		var made: Variant = _build(s, name, points, snaps, picks, values, selected, false)
		if not locks.is_empty() and made is Array and not (made as Array).is_empty():
			_add_heads_up_dimensions(s, made, locks)
		return made
	if not locks.is_empty() and _heads_up_refused(_trial(func(sk: SKETCH) -> void: add_shape.call(sk)),
			func(sk: SKETCH) -> void: _build(sk, name, points, snaps, picks, values, selected, false)):
		locks = {}
		workspace.flash("The locked values can't be solved with the sketch's other constraints, so the %s was added without them." % str(HEADS_UP_TOOLS[name].noun))
	workspace.change("Sketch: " + _tool_title(name), func() -> void: outcome[0] = add_shape.call(sketch()))
	if outcome[0] is String:
		workspace.flash(outcome[0])
	var spec: Dictionary = TOOLS.get(name, {})
	if HEADS_UP_TOOLS.has(name):
		_close_heads_up()
		if was_heads_up:
			viewport.focus_view()
	if name == "line" and outcome[0] is Array and not (outcome[0] as Array).is_empty():
		# Chain: the next segment starts at this one's end (and measures its angle from this one).
		var s := sketch()
		_chain_line = int(outcome[0][0])
		var last: Dictionary = s.entity(_chain_line)
		tool_points = [s.point(int(last.p2))]
		tool_snaps = [{"point": int(last.p2)}]
		return
	if spec.get("repeat", false):
		return
	tool_points.clear()
	tool_snaps.clear()
	tool_picks.clear()
	tool_picks3d.clear()
	if name in ["mirror", "rect_pattern", "circ_pattern", "sketch_scale", "move_copy", "offset", "text", "text_on_path"] or spec.has("picks3d"):
		cancel_tool()


## Runs a tool's builder on a sketch (the real one, or a scratch copy for the preview).
func _build(s: SKETCH, name: String, pts: Array, snaps: Array, picks: Array, v: Dictionary, selected: Array, preview: bool) -> Variant:
	var kernel: RefCounted = workspace.kernel
	var length := func(key: String, fallback: float) -> float:
		var r := UNITS.evaluate(str(v.get(key, "")), UNITS.KIND_LENGTH, workspace.doc.units, _parameter_values())
		return float(r.value) if r.ok else fallback
	var angle := func(key: String, fallback: float) -> float:
		var r := UNITS.evaluate(str(v.get(key, "")), UNITS.KIND_ANGLE, workspace.doc.units, _parameter_values())
		return float(r.value) if r.ok else fallback
	var number := func(key: String, fallback: float) -> float:
		var r := UNITS.evaluate(str(v.get(key, "")), UNITS.KIND_NUMBER, workspace.doc.units, _parameter_values())
		return float(r.value) if r.ok else fallback
	var p := func(i: int) -> Vector2: return pts[i] if i < pts.size() else Vector2.ZERO
	match name:
		"line":
			# A locked heads-up angle sizes the line, so it gets no horizontal or vertical of its own.
			return B.line(s, p.call(0), p.call(1), snaps, false, not bool(_heads_up_state.angle.locked)) if pts.size() >= 2 else []
		"centerline":
			return B.centerline(s, p.call(0), p.call(1), snaps)
		"rect_2pt":
			return B.rectangle_2pt(s, p.call(0), p.call(1), snaps)
		"rect_3pt":
			# Before its third point the preview's rubber band is its first edge.
			if pts.size() < 3:
				return B.line(s, p.call(0), p.call(1), snaps) if preview and pts.size() == 2 else []
			return B.rectangle_3pt(s, p.call(0), p.call(1), p.call(2), snaps)
		"rect_center":
			return B.rectangle_center(s, p.call(0), p.call(1), snaps)
		"circle_center":
			return B.circle_center(s, p.call(0), p.call(1), snaps)
		"circle_2pt":
			return B.circle_2pt(s, p.call(0), p.call(1), snaps)
		"circle_3pt":
			return B.circle_3pt(s, p.call(0), p.call(1), p.call(2), snaps)
		"circle_2tan":
			return B.circle_2tan(s, int(picks[0].id), int(picks[1].id), length.call("radius", 0.005), p.call(0))
		"circle_3tan":
			return B.circle_3tan(s, picks.map(func(pick: Dictionary) -> int: return int(pick.id)), p.call(0))
		"arc_3pt":
			return B.arc_3pt(s, p.call(0), p.call(1), p.call(2), snaps)
		"arc_center":
			return B.arc_center(s, p.call(0), p.call(1), p.call(2), [snaps[0] if snaps.size() > 0 else {}, snaps[1] if snaps.size() > 1 else {}])
		"arc_tangent":
			return B.arc_tangent(s, int(picks[0].point), int(picks[0].curve), p.call(0), [snaps[0] if not snaps.is_empty() else {}])
		"polygon_circumscribed", "polygon_inscribed":
			return B.polygon(s, p.call(0), p.call(1), int(number.call("sides", 6)), name == "polygon_circumscribed", snaps)
		"polygon_edge":
			return B.polygon_edge(s, p.call(0), p.call(1), int(number.call("sides", 6)))
		"ellipse":
			return B.ellipse(s, p.call(0), p.call(1), p.call(2), snaps)
		"slot_cc":
			return B.slot_center_to_center(s, p.call(0), p.call(1), p.call(2), snaps)
		"slot_overall":
			return B.slot_overall(s, p.call(0), p.call(1), p.call(2))
		"slot_center":
			return B.slot_center_point(s, p.call(0), p.call(1), p.call(2), snaps)
		"slot_3pt_arc":
			return B.slot_3pt_arc(s, p.call(0), p.call(2), p.call(1), p.call(3))
		"slot_center_arc":
			return B.slot_arc(s, p.call(0), p.call(1), p.call(2), p.call(3))
		"spline_fit", "spline_control":
			return B.spline(s, pts, "fit" if name == "spline_fit" else "control", false, snaps)
		"conic":
			return B.conic(s, p.call(0), p.call(1), p.call(2), number.call("rho", 0.5), snaps)
		"point":
			return B.point(s, p.call(0), snaps)
		"text", "text_on_path":
			var extra := {"bold": bool(v.get("bold", false)), "italic": bool(v.get("italic", false)), "font": str(v.get("font", ""))}
			if name == "text_on_path":
				extra["path"] = int(picks[0].id)
			return B.text(s, p.call(0), str(v.get("text", "Text")), length.call("height", 0.01), extra)
		"mirror":
			return B.mirror(s, selected, int(picks[0].id))
		"rect_pattern":
			var direction := Vector2.from_angle(angle.call("direction", 0.0))
			return B.rectangular_pattern(s, selected, direction, int(number.call("count_a", 3)), length.call("spacing_a", 0.01),
				direction.orthogonal() * -1.0, int(number.call("count_b", 1)), length.call("spacing_b", 0.01))
		"circ_pattern":
			return B.circular_pattern(s, selected, p.call(0), int(number.call("count", 6)), angle.call("total_angle", TAU))
		"fillet":
			return B.fillet(s, int(picks[0].id), length.call("radius", 0.002), str(v.get("radius", "")))
		"chamfer_equal":
			return B.chamfer(s, int(picks[0].id), length.call("distance", 0.002))
		"chamfer_two":
			return B.chamfer(s, int(picks[0].id), length.call("distance", 0.002), length.call("distance_b", 0.001))
		"chamfer_angle":
			return B.chamfer(s, int(picks[0].id), length.call("distance", 0.002), -1.0, angle.call("angle", PI * 0.25))
		"trim":
			return B.trim(s, int(picks[0].id), picks[0].plane, kernel)
		"extend":
			return B.extend(s, int(picks[0].id), picks[0].plane, kernel)
		"break":
			return B.break_curve(s, int(picks[0].id), kernel)
		"offset":
			return B.offset(s, chain_of(s, int(picks[0].id)), length.call("distance", 0.002), kernel)
		"blend_g1", "blend_g2":
			return B.blend(s, int(picks[0].point), int(picks[0].curve), int(picks[1].point), int(picks[1].curve), name == "blend_g2")
		"sketch_scale":
			return B.scale(s, selected, p.call(0), number.call("factor", 2.0))
		"move_copy":
			return B.move(s, selected, p.call(1) - p.call(0), angle.call("angle", 0.0), p.call(1), bool(v.get("copy", false)))
		"project", "intersect", "include3d", "project_surface", "intersection_curve", "isocurve", "spun_profile":
			return [] if preview else _project_tool(s, name, picks, v, selected)
	return "Unknown sketch tool"


## A live preview of the running tool: its result on a scratch copy, as world polylines.
func _preview() -> Array:
	_last_preview = {}
	var spec: Dictionary = TOOLS.get(tool, {})
	if spec.has("picks3d") or tool.begins_with("constraint:") or spec.get("dimension", false) or tool in ["trim", "extend", "break", "fillet", "chamfer_equal", "chamfer_two", "chamfer_angle", "offset"]:
		return []
	if tool_picks.size() < int(spec.get("picks", 0)):
		return []
	var clicks := int(spec.get("clicks", 0))
	var pts := tool_points.duplicate()
	var snaps := tool_snaps.duplicate()
	if not _heads_up_fields().is_empty():
		# The rubber band keeps the locked heads-up values.
		pts.append(_heads_up_point(mouse_plane))
		snaps.append({} if _heads_up_locked() else mouse_snap)
	elif clicks != 0:
		pts.append(mouse_plane)
		snaps.append(mouse_snap)
	# The mouse stands in for the next click; draw once there is enough to show (a 3-point
	# rectangle's first edge from its second point).
	var enough := 2 if tool == "rect_3pt" else (clicks if clicks > 0 else 2)
	if clicks != 0 and pts.size() < enough:
		return []
	if clicks == 0 and not tool in ["rect_pattern"]:
		return []
	var real := sketch()
	if real == null:
		return []
	var scratch_feature: Resource = real.feature.copy()
	var scratch := SKETCH.new(scratch_feature, null)
	var first_new: int = scratch.options.next_id
	var made = _build(scratch, tool, pts, snaps, tool_picks, tool_values, tool_selection, true)
	if made is String:
		return []
	if HEADS_UP_TOOLS.has(tool):
		_last_preview = {"sketch": scratch, "made": made, "points": pts}
	var lines := []
	var deflection: float = maxf(viewport.distance * 0.001, 0.00001)
	for e in scratch.entities():
		if int(e.id) < first_new or e.type == "point":
			continue
		if e.type == "text":
			for outline in TEXT.outlines(e, scratch, workspace.kernel):
				var world := PackedVector3Array()
				for q in outline:
					world.append(scratch.to_world(q))
				if not world.is_empty():
					world.append(world[0])
				lines.append(world)
			continue
		var world := PackedVector3Array()
		for q in scratch.sample(int(e.id), workspace.kernel, deflection):
			world.append(scratch.to_world(q))
		lines.append(world)
	return lines


## The connected curves around a picked one (for Offset), in order end to end.
func chain_of(s: SKETCH, start: int) -> Array:
	var ends := _curve_ends(s, start)
	if ends.is_empty():
		return [start]
	var chain := [start]
	var used := {start: true}
	for direction in 2:
		var tip: int = ends[1] if direction == 0 else ends[0]
		while true:
			var next := -1
			for user in s.users_of_point(tip):
				var u: Dictionary = s.entity(user)
				if not used.has(user) and u.type in ["line", "arc", "spline"] and not u.get("construction", false):
					next = user
					break
			if next < 0:
				break
			used[next] = true
			if direction == 0:
				chain.append(next)
			else:
				chain.push_front(next)
			var next_ends := _curve_ends(s, next)
			tip = next_ends[1] if next_ends[0] == tip else next_ends[0]
	return chain


func _curve_ends(s: SKETCH, id: int) -> Array:
	var e: Dictionary = s.entity(id)
	match str(e.get("type", "")):
		"line":
			return [int(e.p1), int(e.p2)]
		"arc":
			return [int(e.s), int(e.e)]
		"spline":
			return [int(e.points[0]), int(e.points[e.points.size() - 1])]
	return []


func _tool_defaults(name: String) -> Dictionary:
	var size: float = viewport.distance * 0.05
	var length_text := UNITS.format_value(workspace.nice_size(size), UNITS.KIND_LENGTH, workspace.doc.units).split(" ")[0]
	return {
		"radius": length_text, "sides": "6", "rho": "0.5", "text": "Text", "height": length_text, "bold": false, "italic": false, "font": "",
		"count_a": "3", "spacing_a": length_text, "direction": "0", "count_b": "1", "spacing_b": length_text,
		"count": "6", "total_angle": "360", "distance": length_text, "distance_b": length_text, "angle": "45",
		"factor": "2", "copy": false, "iso_direction": "u", "iso_count": "3",
	}


func _tool_fields(name: String) -> Array[Dictionary]:
	var fields: Array[Dictionary] = []
	var defs := {
		"radius": {"label": "Radius", "type": "expression", "kind": "length"}, "sides": {"label": "Sides", "type": "expression", "kind": "number"},
		"rho": {"label": "Rho", "type": "expression", "kind": "number"}, "text": {"label": "Text", "type": "text"},
		"height": {"label": "Height", "type": "expression", "kind": "length"}, "bold": {"label": "Bold", "type": "bool"},
		"italic": {"label": "Italic", "type": "bool"}, "font": {"label": "Font (path)", "type": "text"},
		"count_a": {"label": "Quantity", "type": "expression", "kind": "number"}, "spacing_a": {"label": "Spacing", "type": "expression", "kind": "length"},
		"direction": {"label": "Direction", "type": "expression", "kind": "angle"},
		"count_b": {"label": "Quantity 2", "type": "expression", "kind": "number"}, "spacing_b": {"label": "Spacing 2", "type": "expression", "kind": "length"},
		"count": {"label": "Quantity", "type": "expression", "kind": "number"}, "total_angle": {"label": "Angle", "type": "expression", "kind": "angle"},
		"distance": {"label": "Distance", "type": "expression", "kind": "length"}, "distance_b": {"label": "Distance 2", "type": "expression", "kind": "length"},
		"angle": {"label": "Angle", "type": "expression", "kind": "angle"}, "factor": {"label": "Scale Factor", "type": "expression", "kind": "number"},
		"copy": {"label": "Create Copy", "type": "bool"},
		"iso_direction": {"label": "Direction", "type": "enum", "options": [["u", "U"], ["v", "V"]]},
		"iso_count": {"label": "Count", "type": "expression", "kind": "number"},
	}
	for key in TOOLS.get(name, {}).get("fields", []):
		var field: Dictionary = defs[key].duplicate()
		field["key"] = key
		fields.append(field)
	return fields


func _tool_title(name: String) -> String:
	for tool_info in CATALOG.all_tools():
		if tool_info.get("sketch", "") == name:
			return tool_info.name
	return name.capitalize()


func _tool_hint(name: String) -> String:
	var spec: Dictionary = TOOLS.get(name, {})
	match str(spec.get("pick", "")):
		"line":
			return "%s: pick %d line(s)%s." % [_tool_title(name), int(spec.picks), ", then click near where you want it" if int(spec.get("clicks", 0)) > 0 else ""]
		"corner":
			return "%s: pick a corner where two lines meet." % _tool_title(name)
		"end":
			return "%s: pick a curve's end point." % _tool_title(name)
		"curve":
			return "%s: pick a curve." % _tool_title(name)
	if spec.has("picks3d"):
		return "%s: pick %s in the 3D view, then OK." % [_tool_title(name), {"any": "edges, faces or bodies", "body": "a body", "edge": "edges", "face": "faces"}[spec.picks3d]]
	if name.begins_with("constraint:"):
		return "%s: pick %d item(s)." % [_tool_title(name), int(CONSTRAINT_PICKS.get(name.trim_prefix("constraint:"), 1))]
	if name == "dimension":
		return "Sketch Dimension: pick a line, circle, arc or point."
	return "%s: click to place points (Esc to stop)." % _tool_title(name)


func _parameter_values() -> Dictionary:
	var known := {}
	var values: Dictionary = workspace.result.get("values", {})
	for name in values:
		if values[name].get("ok", false):
			known[name] = values[name]
	return known


# --- Heads-up fields (Line, rectangles, circles) -----------------------------------------------

func _reset_heads_up_state() -> void:
	for field in HEADS_UP_IDS:
		_reset_heads_up_field(field)


func _reset_heads_up_field(field: String) -> void:
	_heads_up_state[field] = {"typed": false, "valid": true, "locked": false, "value": 0.0, "expression": "", "name": ""}


## The heads-up fields the running tool offers at its step (HEADS_UP_TOOLS), [] for none.
func _heads_up_fields() -> Array:
	return HEADS_UP_TOOLS.get(tool, {}).get("steps", {}).get(tool_points.size(), [])


## The heads-up fields drawn at the running tool's step: its own and the earlier steps' (whose
## values the placed points already set); [] at a step without fields.
func _heads_up_drawn() -> Array:
	var steps: Dictionary = HEADS_UP_TOOLS.get(tool, {}).get("steps", {})
	var fields := []
	if not steps.has(tool_points.size()):
		return fields
	for step in steps:
		if int(step) <= tool_points.size():
			fields.append_array(steps[step])
	return fields


## True while the heads-up boxes are open.
func _heads_up_open() -> bool:
	return _heads_up_field != ""


## True while a heads-up tool is at a step with fields (a line's, rectangle's or circle's first
## point placed) and typing can go to them.
func _heads_up_ready() -> bool:
	return active and not suspended and not _heads_up_fields().is_empty() and not _edit.visible


## True when a value of the running tool's step's heads-up fields is locked.
func _heads_up_locked() -> bool:
	return _heads_up_fields().any(func(field: String) -> bool: return bool(_heads_up_state[field].locked))


## The character a key types that starts a heads-up value: a digit, "-" or "."; "" for others.
static func _value_char(event: InputEventKey) -> String:
	if event.echo or event.ctrl_pressed or event.alt_pressed or event.meta_pressed:
		return ""
	var typed := char(event.unicode) if event.unicode > 0 else ""
	if typed == "" and not event.shift_pressed:
		if event.keycode >= KEY_0 and event.keycode <= KEY_9:
			typed = str(event.keycode - KEY_0)
		elif event.keycode >= KEY_KP_0 and event.keycode <= KEY_KP_9:
			typed = str(event.keycode - KEY_KP_0)
		elif event.keycode in [KEY_MINUS, KEY_KP_SUBTRACT]:
			typed = "-"
		elif event.keycode in [KEY_PERIOD, KEY_KP_PERIOD]:
			typed = "."
	return typed if typed.length() == 1 and "0123456789-.".contains(typed) else ""


## Opens the step's heads-up boxes on the rubber band's dimensions with the keyboard in field:
## typed starts its text (a typed digit, sign or point), else what it shows is all selected.
func _open_heads_up(field: String, typed := "") -> void:
	_heads_up_field = field
	for each in _heads_up_fields():
		var box: LineEdit = _heads_up[each]
		if not _heads_up_state[each].typed:
			box.text = _heads_up_box_text(each)
		box.visible = true
		_heads_up_colors(each)
		var at: Vector2 = _heads_up_centers.get(each, Vector2.INF)
		if at.is_finite():
			_center_box(box, at)
	if typed != "":
		var box: LineEdit = _heads_up[field]
		box.text = typed
		box.caret_column = typed.length()
		_on_heads_up_changed(typed, field)
	_focus_heads_up(field, typed == "")
	viewport.redraw_overlay()


## Gives a heads-up box the keyboard (editing), its text all selected when select.
func _focus_heads_up(field: String, select: bool) -> void:
	var box: LineEdit = _heads_up[field]
	if not box.visible:
		return
	_heads_up_field = field
	box.grab_focus()
	if box.has_method("edit"):
		box.call("edit")
	if select:
		box.select_all()
	viewport.redraw_overlay()


## The heads-up box keeps the keyboard after Enter (a deferred call: the box may give it up after
## its own Enter), all selected.
func _take_heads_up_focus(field: String) -> void:
	if _heads_up_open() and _heads_up_field == field:
		_focus_heads_up(field, true)


## Closes the heads-up boxes; typed text and locks go (the rubber band follows the mouse again).
func _close_heads_up() -> void:
	_hide_heads_up(HEADS_UP_IDS.keys())


## Hides the heads-up boxes: the drop fields' typed text and locks go; the others keep a locked
## value (a 3-point rectangle's edge length for its height step) and lose only typed text.
func _hide_heads_up(drop: Array) -> void:
	if _heads_up.is_empty():
		return
	var was_open := _heads_up_open()
	_heads_up_field = ""
	for field in _heads_up:
		if drop.has(field) or not bool(_heads_up_state[field].locked):
			_reset_heads_up_field(field)
		var box: LineEdit = _heads_up[field]
		box.visible = false
		if not bool(_heads_up_state[field].locked):
			box.text = ""
		_heads_up_colors(field)
	if was_open:
		viewport.redraw_overlay()


## What a heads-up field's text is checked as (an _edit_target() result).
func _heads_up_target(field: String) -> Dictionary:
	match field:
		"angle":
			return {"type": "angle", "kind": UNITS.KIND_ANGLE, "own": "", "refs": 2}
		"diameter":
			return {"type": "diameter", "kind": UNITS.KIND_LENGTH, "own": "", "refs": 1}
	return {"type": "length", "kind": UNITS.KIND_LENGTH, "own": "", "refs": 1}


## A heads-up box's text colour: dim_box_invalid while its text can't be used, dim_selected while
## locked, else dim_box_text; error is its tooltip.
func _heads_up_colors(field: String, error := "") -> void:
	var box: LineEdit = _heads_up.get(field)
	if box == null:
		return
	var state: Dictionary = _heads_up_state[field]
	var color: Color = theme_colors.dim_box_text
	if not state.valid:
		color = theme_colors.dim_box_invalid
	elif state.locked:
		color = theme_colors.dim_selected
	box.add_theme_color_override("font_color", color)
	box.add_theme_color_override("font_selected_color", color)
	box.tooltip_text = error


## A heads-up value as its box shows it: in the document unit (degrees), as the value box offers
## values.
func _heads_up_format(field: String, value: float) -> String:
	var kind := UNITS.KIND_ANGLE if field == "angle" else UNITS.KIND_LENGTH
	return UNITS.format_value(value, kind, workspace.doc.units, 1 if field == "angle" else 2)


## What an untyped heads-up box shows: what the rubber band's shape measures for its field.
func _heads_up_box_text(field: String) -> String:
	if _heads_up_fields().is_empty():
		return ""
	var g := _heads_up_measure(sketch(), tool_points + [_heads_up_point(mouse_plane)])
	if not g.has(field):
		return ""
	return _heads_up_format(field, float(g[field]))


## Keys in a heads-up box: Esc closes the boxes (their values unlocked) and gives the view the
## keyboard; Tab moves to the step's next field.
func _on_heads_up_input(event: InputEvent, field: String) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed:
		return
	var box: LineEdit = _heads_up[field]
	if key.keycode == KEY_ESCAPE:
		box.accept_event()
		_hide_heads_up(_heads_up_fields())
		viewport.focus_view()
	elif key.keycode == KEY_TAB:
		box.accept_event()
		var fields := _heads_up_fields()
		_focus_heads_up(fields[(fields.find(field) + 1) % fields.size()] if not fields.is_empty() else field, true)


## Typing in a heads-up box: its text is the user's now, checked as it goes (dim_box_invalid while
## it can't be used); a changed value is no longer locked until Enter locks it again.
func _on_heads_up_changed(text: String, field: String) -> void:
	var state: Dictionary = _heads_up_state[field]
	var check := _validate(text, _heads_up_target(field))
	state.typed = true
	state.locked = false
	state.valid = bool(check.ok)
	_heads_up_colors(field, str(check.error))
	viewport.redraw_overlay()


## Enter in a heads-up box locks its value (refused, the box red, when the text can't be used); with
## every value of the step locked the point is placed (the segment, shape or next step).
func _on_heads_up_submitted(text: String, field: String) -> void:
	if not _heads_up_open() or not _heads_up_ready():
		return
	var state: Dictionary = _heads_up_state[field]
	var check := _validate(text, _heads_up_target(field))
	if not check.ok:
		state.valid = false
		state.locked = false
		_heads_up_colors(field, str(check.error))
		workspace.flash(field.capitalize() + ": " + str(check.error))
		_focus_heads_up(field, true)
		_take_heads_up_focus.call_deferred(field)
		return
	state.typed = true
	state.valid = true
	state.locked = true
	state.value = float(check.value)
	state.expression = str(check.expression)
	state.name = str(check.name)
	_heads_up_colors(field)
	if _heads_up_fields().all(func(each: String) -> bool: return bool(_heads_up_state[each].locked)):
		tool_click(_heads_up_point(mouse_plane), {}, {})
		return
	_focus_heads_up(field, true)
	_take_heads_up_focus.call_deferred(field)
	viewport.redraw_overlay()


## Where the point being placed goes for the mouse at mouse, with the step's locked heads-up values:
## a line's locked length keeps its length along the mouse's direction, a locked angle its angle
## from the reference on the mouse's side, both fix it; a rectangle's locked width or height keeps
## that size on the mouse's side (a centre rectangle's corner half of it off the centre; a 3-point
## one's first edge its length along the mouse's direction, then its height that far off the edge
## on the mouse's side); a circle's locked diameter its size towards the mouse.
func _heads_up_point(mouse: Vector2) -> Vector2:
	if not _heads_up_locked():
		return mouse
	var locked := func(field: String) -> bool: return bool(_heads_up_state[field].locked)
	var size := func(field: String) -> float: return float(_heads_up_state[field].value)
	var start: Vector2 = tool_points[0]
	var d := mouse - start
	var toward := d.normalized() if d.length() > 0.0 else Vector2.RIGHT
	match tool:
		"line":
			var reference: Vector2 = _chain_reference(sketch(), start).dir
			var dir := d.normalized() if d.length() > 0.0 else reference
			if locked.call("angle"):
				var side := 1.0 if reference.cross(d) >= 0.0 else -1.0
				dir = reference.rotated(side * float(size.call("angle")))
			return start + dir * (float(size.call("length")) if locked.call("length") else d.length())
		"rect_2pt", "rect_center":
			var share := 1.0 if tool == "rect_2pt" else 0.5
			if locked.call("width"):
				d.x = _side_of(d.x) * float(size.call("width")) * share
			if locked.call("height"):
				d.y = _side_of(d.y) * float(size.call("height")) * share
			return start + d
		"rect_3pt":
			if tool_points.size() == 1:
				return start + toward * float(size.call("width"))
			var edge: Vector2 = (tool_points[1] as Vector2) - start
			var n := Vector2(-edge.y, edge.x).normalized()
			var off := (mouse - (tool_points[1] as Vector2)).dot(n)
			return mouse + n * (_side_of(off) * float(size.call("height")) - off)
		"circle_center":
			return start + toward * float(size.call("diameter")) * 0.5
		"circle_2pt":
			return start + toward * float(size.call("diameter"))
	return mouse


## The Line tool's name for _heads_up_point(): where its rubber band ends for the mouse at mouse.
func _line_end(mouse: Vector2) -> Vector2:
	return _heads_up_point(mouse)


## -1 for a negative x, else 1 (which side of a corner or edge the mouse is on).
static func _side_of(x: float) -> float:
	return -1.0 if x < 0.0 else 1.0


## What the angle of the segment being drawn from start is measured from: the chain's previous
## segment, as a ray from start back along it ({"line", "ray": +1 along its p1->p2, -1 against}),
## or, for the first segment, plane +X ({"line": -1}); "dir" is the ray's direction.
func _chain_reference(s: SKETCH, start: Vector2) -> Dictionary:
	var corner := int((tool_snaps[0] as Dictionary).get("point", -1)) if not tool_snaps.is_empty() and tool_snaps[0] is Dictionary else -1
	var e: Dictionary = s.entity(_chain_line) if s != null and _chain_line >= 0 else {}
	if e.get("type", "") == "line" and corner >= 0 and corner in [int(e.p1), int(e.p2)]:
		var away := int(e.p1) if int(e.p2) == corner else int(e.p2)
		var dir: Vector2 = s.point(away) - start
		if dir.length() > 0.0:
			return {"line": _chain_line, "ray": -1 if int(e.p2) == corner else 1, "dir": dir.normalized()}
	return {"line": -1, "ray": 1, "dir": Vector2.RIGHT}


## The heads-up dimensions of a rubber band from start to end: {"reference" (_chain_reference),
## "ccw" (the band is counter-clockwise of the reference), "length", "angle" (from the reference,
## 0..PI), "length_at" (the length's text spot: 24 px to the band's left, plane-up when level),
## "angle_at" (the angle's: on its sector's middle at the start)}; {} for a band of no length.
func _heads_up_geometry(s: SKETCH, start: Vector2, end: Vector2) -> Dictionary:
	var d := end - start
	var length := d.length()
	if s == null or length <= 0.0:
		return {}
	var ppm: float = viewport.pixels_per_meter_at(s.to_world((start + end) * 0.5))
	if not (ppm > 0.0 and is_finite(ppm)):
		return {}
	var px := _ui_scale() / ppm
	var reference := _chain_reference(s, start)
	var r: Vector2 = reference.dir
	var b := d / length
	var ccw := r.cross(b) >= 0.0
	var angle := absf(atan2(r.cross(b), r.dot(b)))
	var side := Vector2(-b.y, b.x)
	if absf(b.y) < 1e-3:
		side = Vector2(0.0, 1.0)
	var radius := clampf(length / px * 0.5, float(HEADS_UP_ARC_PX[0]), float(HEADS_UP_ARC_PX[1])) * px
	var bisector := r.rotated((angle if ccw else -angle) * 0.5)
	return {"reference": reference, "ccw": ccw, "length": length, "angle": angle,
		"length_at": (start + end) * 0.5 + side * HEADS_UP_OFFSET_PX * px, "angle_at": start + bisector * radius}


## The heads-up dimensions of the running tool's shape from its points (the placed ones, then the
## rubber band's end): each field's measured value and its text spot ("<field>_at"), and "tool".
## A line's is its _heads_up_geometry(). A rectangle's width and height go on the edges through
## its moving corner, 24 px outside (a 3-point one's on its first two edges; its first edge alone
## has its length to its left, plane-up when level, as a line's); a circle's diameter runs through
## the cursor, its text inside half-way out when the circle is big enough on screen, else 24 px
## outside it, plane-up. {} when there is nothing to measure yet.
func _heads_up_measure(s: SKETCH, pts: Array) -> Dictionary:
	if s == null or pts.size() < 2:
		return {}
	if tool == "line":
		return _heads_up_geometry(s, pts[0], pts[1])
	var a: Vector2 = pts[0]
	var b: Vector2 = pts[1]
	var ppm: float = viewport.pixels_per_meter_at(s.to_world((a + b) * 0.5))
	if not (ppm > 0.0 and is_finite(ppm)):
		return {}
	var px := _ui_scale() / ppm
	var off := HEADS_UP_OFFSET_PX * px
	var g := {"tool": tool}
	match tool:
		"rect_2pt", "rect_center":
			var center := a if tool == "rect_center" else (a + b) * 0.5
			var half := b - center
			if half == Vector2.ZERO:
				return {}
			g["width"] = absf(half.x) * 2.0
			g["height"] = absf(half.y) * 2.0
			g["width_at"] = Vector2(center.x, b.y + _side_of(half.y) * off)
			g["height_at"] = Vector2(b.x + _side_of(half.x) * off, center.y)
		"rect_3pt":
			var edge := b - a
			var length := edge.length()
			if length <= 0.0:
				return {}
			var dir := edge / length
			var n := Vector2(-dir.y, dir.x)
			g["width"] = length
			if pts.size() < 3:
				g["width_at"] = (a + b) * 0.5 + (n if absf(dir.y) >= 1e-3 else Vector2(0.0, 1.0)) * off
			else:
				var c: Vector2 = pts[2]
				var h := (c - b).dot(n)
				g["height"] = absf(h)
				g["width_at"] = (a + b) * 0.5 - n * _side_of(h) * off
				g["height_at"] = b + n * h * 0.5 + dir * off
		"circle_center", "circle_2pt":
			var center := a if tool == "circle_center" else (a + b) * 0.5
			var r := a.distance_to(b) * (1.0 if tool == "circle_center" else 0.5)
			if r <= 0.0:
				return {}
			var u := (b - a).normalized()
			g["diameter"] = 2.0 * r
			if r / px >= HEADS_UP_INSIDE_PX:
				g["diameter_at"] = center + u * r * 0.5
			else:
				var side := Vector2(-u.y, u.x)
				if side.y < 0.0 or (absf(side.y) < 1e-9 and side.x > 0.0):
					side = -side
				g["diameter_at"] = center + side * (r + off)
		_:
			return {}
	return g


## The driving dimension a heads-up field (other than a line's angle) becomes on what its tool made
## (made: the new entity ids, on the real sketch or a scratch copy), its text at the field's spot
## in g (a _heads_up_measure()): a line's length; a rectangle's width and height as horizontal and
## vertical distances along the edges through its moving corner (a 3-point one's as its first and
## second edges' lengths); a circle's diameter. {} when made hasn't what it measures.
func _heads_up_spec(sk: SKETCH, made: Array, field: String, g: Dictionary) -> Dictionary:
	var shape := str(g.get("tool", "line"))
	var entity := func(i: int) -> Dictionary: return sk.entity(int(made[i])) if i < made.size() else {}
	var spec := {}
	match field:
		"length":
			if (entity.call(0) as Dictionary).get("type", "") == "line":
				spec = {"type": "length", "refs": [int(made[0])]}
		"width", "height":
			var i := (0 if field == "width" else 1) if shape == "rect_3pt" else (2 if field == "width" else 1)
			var e: Dictionary = entity.call(i)
			if e.get("type", "") != "line":
				return {}
			if shape == "rect_3pt":
				spec = {"type": "length", "refs": [int(made[i])]}
			else:
				var axis := 0 if field == "width" else 1
				var p1 := int(e.p1)
				var p2 := int(e.p2)
				var forward: bool = sk.point(p2)[axis] >= sk.point(p1)[axis]
				spec = {"type": "distance_x" if field == "width" else "distance_y", "refs": [p1, p2] if forward else [p2, p1]}
		"diameter":
			if (entity.call(0) as Dictionary).get("type", "") == "circle":
				spec = {"type": "diameter", "refs": [int(made[0])]}
	if spec.is_empty() or not g.has(field + "_at"):
		return {}
	spec["kind"] = UNITS.KIND_LENGTH
	spec["offset"] = (g[field + "_at"] as Vector2) - _dimension_anchor(sk, spec)
	return spec


## A line's heads-up angle on its band, from its _heads_up_geometry() g: from the chain's previous
## segment (with rays), or for the first segment from plane +X: drawn (on a scratch copy) as a
## three-point angle to a scratch point on +X; added (adding) from a construction line along +X from
## its start, kept level and as long as the segment, so it adds no freedom.
func _heads_up_angle_spec(sk: SKETCH, band: int, g: Dictionary, adding: bool) -> Dictionary:
	var e: Dictionary = sk.entity(band)
	var reference: Dictionary = g.reference
	var ccw: bool = g.ccw
	var line := int(reference.line)
	var ray := int(reference.ray)
	var spec := {"type": "angle", "kind": UNITS.KIND_ANGLE}
	if line < 0 or sk.entity(line).get("type", "") != "line":
		var start: Vector2 = sk.point(int(e.p1))
		var on_x := sk.add_point(start + Vector2.RIGHT * float(g.length))
		if not adding:
			spec["refs"] = [int(e.p1), on_x, int(e.p2)] if ccw else [int(e.p1), int(e.p2), on_x]
			spec["rays"] = [1, 1]
			spec["offset"] = (g.angle_at as Vector2) - _dimension_anchor(sk, spec)
			return spec
		line = sk.add_line(int(e.p1), on_x, true)
		sk.add_constraint("horizontal", [line])
		sk.add_constraint("equal", [line, band])
		ray = 1
	spec["refs"] = [line, band] if ccw else [band, line]
	spec["rays"] = [ray, 1] if ccw else [1, ray]
	spec["offset"] = (g.angle_at as Vector2) - _dimension_anchor(sk, spec)
	return spec


## The heads-up pseudo-dimensions on a scratch sketch with what the tool made there (made), from
## its _heads_up_measure() g: field -> dimension, with ids HEADS_UP_IDS.
func _heads_up_specs(scratch: SKETCH, made: Array, g: Dictionary) -> Dictionary:
	var specs := {}
	for field in HEADS_UP_IDS:
		if not g.has(field):
			continue
		var spec := _heads_up_angle_spec(scratch, int(made[0]), g, false) if field == "angle" else _heads_up_spec(scratch, made, field, g)
		if spec.is_empty():
			continue
		spec["id"] = HEADS_UP_IDS[field]
		spec["driving"] = true
		specs[field] = spec
	return specs


## The running tool's heads-up dimensions on its rubber band (on the preview's scratch copy): what
## the shape measures for each field (or its lock), in the preview colours, or in dim_selected for
## a locked value (under its box, or with its text for an earlier step's lock); while the boxes
## are open they sit on the texts and the untyped ones show what is measured.
func _draw_heads_up(overlay: Control, s: SKETCH) -> void:
	_heads_up_centers = {}
	var drawn := _heads_up_drawn()
	if drawn.is_empty() or _last_preview.is_empty():
		return
	var made: Variant = _last_preview.made
	if not made is Array or (made as Array).is_empty():
		return
	var scratch: SKETCH = _last_preview.sketch
	var g := {}
	if tool == "line":
		var e: Dictionary = scratch.entity(int(made[0]))
		if e.get("type", "") != "line":
			return
		g = _heads_up_geometry(s, scratch.point(int(e.p1)), scratch.point(int(e.p2)))
	else:
		g = _heads_up_measure(s, _last_preview.points)
	if g.is_empty():
		return
	var specs := _heads_up_specs(scratch, made, g)
	var units: String = workspace.doc.units
	var open := _heads_up_open()
	var editable := _heads_up_fields()
	for field in drawn:
		if not specs.has(field):
			continue
		var state: Dictionary = _heads_up_state[field]
		var c: Dictionary = specs[field]
		var value: float = float(state.value) if state.locked else float(g[field])
		var boxed: bool = open and editable.has(field)
		var look := ("editing" if boxed else "selected") if state.locked else "preview"
		var layout := _draw_dimension(overlay, scratch, c, DIM.canvas_text(c, value, units, "", ""), look, not boxed)
		_heads_up_centers[field] = layout.get("text_center", Vector2.INF)
		if not boxed:
			continue
		var box: LineEdit = _heads_up[field]
		if not state.typed:
			var shown := _heads_up_format(field, float(g[field]))
			if box.text != shown:
				box.text = shown
				if box.has_focus():
					box.select_all()
		if (_heads_up_centers[field] as Vector2).is_finite():
			_center_box(box, _heads_up_centers[field])


## The locked heads-up values for a shape from points (all its points; {} when none is locked):
## the locked states by field and "geometry" (_heads_up_measure(), for where the dimensions' text
## goes: where the heads-up ones were drawn).
func _heads_up_plan(points: Array) -> Dictionary:
	var fields := []
	for step_fields: Array in (HEADS_UP_TOOLS.get(tool, {}).get("steps", {}) as Dictionary).values():
		fields.append_array(step_fields)
	var locked := fields.filter(func(field: String) -> bool: return bool(_heads_up_state[field].locked))
	if locked.is_empty() or points.size() < 2:
		return {}
	var g := _heads_up_measure(sketch(), points)
	if g.is_empty():
		return {}
	var plan := {"geometry": g}
	for field in locked:
		plan[field] = (_heads_up_state[field] as Dictionary).duplicate()
	return plan


## True when a shape's locked heads-up dimensions can't be solved with the sketch: the trial with
## them (trial) is _unsolvable() and, tried with the shape alone (build_only, a _trial() mutation),
## they add conflicts or redundancies, stop it solving or break a parameter (a centre rectangle's
## own construction is redundant once, which is not theirs to answer for).
func _heads_up_refused(trial: Dictionary, build_only: Callable) -> bool:
	if not _unsolvable(trial):
		return false
	var base := _trial(build_only)
	for key in ["conflicting", "redundant"]:
		if (trial.get(key, []) as Array).size() > (base.get(key, []) as Array).size():
			return true
	return (bool(base.get("ok", false)) and not bool(trial.get("ok", false))) or str(trial.get("param_error", "")) != ""


## Adds the driving dimensions a _heads_up_plan() locked to a new shape (made: its entity ids) on a
## sketch (the real one or a trial copy): a line's length and angle (_heads_up_angle_spec), a
## rectangle's width and height, a circle's diameter (_heads_up_spec); a "name = value" names the
## parameter.
func _add_heads_up_dimensions(sk: SKETCH, made: Array, plan: Dictionary) -> void:
	var g: Dictionary = plan.geometry
	if str(g.get("tool", "line")) == "line" and sk.entity(int(made[0])).get("type", "") != "line":
		return
	for field in HEADS_UP_IDS:
		if not plan.has(field):
			continue
		var spec := _heads_up_angle_spec(sk, int(made[0]), g, true) if field == "angle" else _heads_up_spec(sk, made, field, g)
		if spec.is_empty():
			continue
		var id := _add_dimension(sk, spec, str(plan[field].expression), true)
		if str(plan[field].name) != "":
			_rename_parameter(sk, sk.constraint(id), str(plan[field].name), false)


# --- Constraints and dimensions --------------------------------------------------------------

func _constraint_or_dimension_click(target: Dictionary, plane: Vector2) -> void:
	if TOOLS.get(tool, {}).get("dimension", false):
		_dimension_click(target, plane)
		return
	if target.get("kind", "") == "entity":
		tool_picks.append({"id": int(target.id)})
		var kind := tool.trim_prefix("constraint:")
		if tool_picks.size() >= int(CONSTRAINT_PICKS.get(kind, 1)):
			apply_constraint(kind, tool_picks.map(func(pick: Dictionary) -> int: return int(pick.id)))
			tool_picks.clear()
		viewport.redraw_overlay()


## A click with Sketch Dimension: a first pick, a second pick that pairs with it, or (on anything
## else, and always after two picks) the placing click at plane.
func _dimension_click(target: Dictionary, plane: Vector2) -> void:
	var s := sketch()
	var id := int(target.get("id", -1))
	var on_item: bool = target.get("kind", "") == "entity" and str(s.entity(id).get("type", "")) in ["point", "line", "circle", "arc"]
	if tool_picks.is_empty():
		if on_item:
			tool_picks.append({"id": id})
			_dim_last_orientation = ""
			workspace.flash("Sketch Dimension: pick a second item to measure the point from." if s.entity(id).type == "point"
				else "Sketch Dimension: pick a second item, or click where the dimension goes.")
		else:
			workspace.flash(_tool_hint("dimension"))
		viewport.redraw_overlay()
		return
	if tool_picks.size() == 1 and on_item and _pair_ok(s, int(tool_picks[0].id), id, plane):
		tool_picks.append({"id": id})
		workspace.flash("Sketch Dimension: click where the dimension goes, or pick a third point for an angle (right-click for options)."
			if _pick_ids().all(func(each: int) -> bool: return s.entity(each).get("type", "") == "point")
			else "Sketch Dimension: click where the dimension goes (right-click for options).")
		viewport.redraw_overlay()
		return
	if tool_picks.size() == 2 and on_item and not _picks_complete() and _triple_ok(s, _pick_ids() + [id]):
		# Two points and a third: the angle at the middle one.
		tool_picks.append({"id": id})
		workspace.flash("Sketch Dimension: click where the angle goes (right-click for options).")
		viewport.redraw_overlay()
		return
	_place_dimension(plane)


## True when second can be the second pick for first: another item, not one of first's own end or
## centre points (nor first one of its), and the two make a dimension together.
func _pair_ok(s: SKETCH, first: int, second: int, plane: Vector2) -> bool:
	if first == second or s.points_of(first).has(second) or s.points_of(second).has(first):
		return false
	return not dimension_spec([first, second], plane).is_empty()


## True when three picks are three different points that don't lie on one line (an angle at the
## middle one).
func _triple_ok(s: SKETCH, ids: Array) -> bool:
	if ids.size() != 3 or not ids.all(func(id: int) -> bool: return s.entity(id).get("type", "") == "point"):
		return false
	if ids[0] == ids[1] or ids[1] == ids[2] or ids[0] == ids[2]:
		return false
	var a := s.point(ids[0]) - s.point(ids[1])
	var b := s.point(ids[2]) - s.point(ids[1])
	return a.length() > 0.0 and b.length() > 0.0 and absf(a.normalized().cross(b.normalized())) > 1e-6


## True when the picks are all the Sketch Dimension tool takes: three points, or two items that
## aren't both points (two points can take a third for an angle).
func _picks_complete() -> bool:
	if tool_picks.size() >= 3:
		return true
	if tool_picks.size() < 2:
		return false
	var s := sketch()
	return s == null or not _pick_ids().all(func(id: int) -> bool: return s.entity(id).get("type", "") == "point")


## The placing click: the dimension the picks make at plane is added driven (the Driven choice,
## or when it would over-constrain the sketch and the answer is yes) or gets the value box.
func _place_dimension(plane: Vector2) -> void:
	var s := sketch()
	var ids := _pick_ids()
	if ids.size() == 1 and s.entity(ids[0]).get("type", "") == "point":
		workspace.flash("Pick a second item to measure a point from.")
		_clear_dimension_picks()
		return
	var spec := dimension_spec(ids, plane, _dim_overrides)
	if spec.is_empty():
		workspace.flash("These cut or overlap, so there is no gap to measure to their edges." if bool(_dim_overrides.edge) and not dimension_spec(ids, plane, {}).is_empty()
			else "These can't be dimensioned together.")
		_clear_dimension_picks()
		return
	_dim_last_orientation = str(spec.get("orientation", ""))
	if bool(_dim_overrides.get("driven", false)):
		_add_driven(spec)
		return
	var measured := UNITS.format_value(absf(float(spec.value)), spec.kind, workspace.doc.units, 9)
	if _over_constrains(_trial(func(sk: SKETCH) -> void: _add_dimension(sk, spec, measured, true)), true):
		_ask_driven(spec)
		return
	_pending_dimension = spec
	var layout := _layout_for(s, _pseudo_dimension(spec), DIM.canvas_text(spec, float(spec.value), workspace.doc.units, "", ""))
	_open_edit(layout.get("text_center", mouse_screen), _box_text(float(spec.value), str(spec.kind), _noise(s, spec)), -1)


## The picked items' ids.
func _pick_ids() -> Array:
	return tool_picks.map(func(pick: Dictionary) -> int: return int(pick.get("id", -1)))


## No picks, no Sketch Dimension choices: the tool starts over (it stays the tool).
func _clear_dimension_picks() -> void:
	if TOOLS.get(tool, {}).get("dimension", false):
		tool_picks.clear()
	_dim_overrides = DIM_OVERRIDES.duplicate()
	_dim_last_orientation = ""
	_preview_dimension = {}
	viewport.redraw_overlay()


## Adds a dimension from a dimension_spec() result to a sketch (the real one or a trial copy):
## its type, refs, unit kind, text place and angle rays; returns its id.
func _add_dimension(sk: SKETCH, spec: Dictionary, expression: String, driving: bool) -> int:
	var id: int = sk.add_constraint(spec.type, spec.refs, expression, spec.kind, driving)
	var c: Dictionary = sk.constraint(id)
	c["offset"] = spec.offset
	for key in ["rays", "edge"]:
		if spec.has(key):
			c[key] = (spec[key] as Array).duplicate()
	if spec.get("linear_diameter", false):
		c["linear_diameter"] = true
	return id


## Adds the dimension driven (it only measures): one undo step; the tool starts over.
func _add_driven(spec: Dictionary) -> void:
	workspace.change("Sketch: Driven Dimension", func() -> void: _add_dimension(sketch(), spec, "", false))
	_clear_dimension_picks()


## The dimension would over-constrain the sketch: asks whether to add it driven (driven_answer
## answers instead in tests). Either way the tool starts over.
func _ask_driven(spec: Dictionary) -> void:
	match driven_answer:
		"ok":
			_add_driven(spec)
			return
		"cancel":
			_clear_dimension_picks()
			return
	_driven_spec = spec
	if _driven_dialog == null:
		_driven_dialog = ConfirmationDialog.new()
		_driven_dialog.title = "Sketch Dimension"
		_driven_dialog.dialog_text = "This dimension conflicts with the sketch's existing constraints.\nAdd it as a driven dimension that only measures?"
		_driven_dialog.ok_button_text = "Add Driven"
		_driven_dialog.cancel_button_text = "Cancel"
		_driven_dialog.confirmed.connect(_on_driven_answer.bind(true))
		_driven_dialog.canceled.connect(_on_driven_answer.bind(false))
		viewport.add_child(_driven_dialog)
		_style_dialog()
	_driven_dialog.reset_size()
	_driven_dialog.popup_centered()


## The driven question answered (OK adds it driven; Cancel, Esc or closing adds nothing).
func _on_driven_answer(add: bool) -> void:
	var spec := _driven_spec
	_driven_spec = {}
	if add and active and not spec.is_empty() and not _pending_refs_gone(spec):
		_add_driven(spec)
	else:
		_clear_dimension_picks()
	viewport.focus_view()


func _pending_refs_gone(spec: Dictionary) -> bool:
	var s := sketch()
	return s == null or (spec.get("refs", []) as Array).any(func(id) -> bool: return s.entity(int(id)).is_empty())


## The dimension that fits the picked geometry and where its text goes (place, plane meters):
## {"type", "refs", "kind", "value", "offset"}, with "orientation" for linear ones ("distance_x",
## "distance_y" or "aligned"), "rays" for angles, "edge" for distances to circles' or arcs' curves
## and "linear_diameter" for twice a distance from a centerline; {} when nothing fits. Values are
## measured in double precision. overrides: _dim_overrides (an orientation lock, radius, diameter
## or sweep, edge, linear diameter).
func dimension_spec(ids: Array, place: Vector2, overrides := {}) -> Dictionary:
	var s := sketch()
	if s == null or ids.is_empty():
		return {}
	for id in ids:
		if s.entity(int(id)).is_empty():
			return {}
	var types := ids.map(func(id: int) -> String: return str(s.entity(id).get("type", "")))
	var spec := {}
	var lock := str(overrides.get("orientation", ""))
	var round := str(overrides.get("round", ""))
	var to_edge := bool(overrides.get("edge", false))
	# Two points measured across, up or along, by where the text is pulled (a line's own ends
	# measured along are its length). a and b may be circles or arcs (their centres).
	var linear := func(a: int, b: int, line: int) -> Dictionary:
		var pa := _xy(s, a)
		var pb := _xy(s, b)
		var ca := _point_of(s, a)
		var cb := _point_of(s, b)
		var orientation := DIM.linear_orientation(s.point(ca), s.point(cb), _orientation_place(s, ca, cb, place), line >= 0, lock, _dim_last_orientation)
		match orientation:
			"distance_x":
				return {"type": "distance_x", "refs": [ca, cb] if pb[0] >= pa[0] else [cb, ca], "value": absf(pb[0] - pa[0]), "orientation": orientation}
			"distance_y":
				return {"type": "distance_y", "refs": [ca, cb] if pb[1] >= pa[1] else [cb, ca], "value": absf(pb[1] - pa[1]), "orientation": orientation}
		var length := _hypot(pb[0] - pa[0], pb[1] - pa[1])
		if line >= 0:
			return {"type": "length", "refs": [line], "value": length, "orientation": "aligned"}
		return {"type": "distance", "refs": [a, b], "value": length, "orientation": "aligned"}
	if types == ["line"]:
		var e: Dictionary = s.entity(ids[0])
		spec = linear.call(int(e.p1), int(e.p2), int(ids[0]))
	elif types == ["arc"] and round == "sweep":
		var arc: Dictionary = s.entity(ids[0])
		var c := _xy(s, int(arc.c))
		var a := _xy(s, int(arc.s))
		var b := _xy(s, int(arc.e))
		var sweep := fposmod(atan2(b[1] - c[1], b[0] - c[0]) - atan2(a[1] - c[1], a[0] - c[0]), TAU)
		spec = {"type": "angle", "kind": "angle", "refs": ids, "value": sweep if sweep > 0.0 else TAU}
	elif types == ["circle"] or types == ["arc"]:
		if not round in ["radius", "diameter"]:
			round = "diameter" if types == ["circle"] else "radius"
		var r := float(s.entity(ids[0]).r)
		spec = {"type": round, "refs": ids, "value": 2.0 * r if round == "diameter" else r}
	elif types == ["point", "point", "point"]:
		spec = _three_point_angle_spec(s, ids, place)
	elif types == ["point", "point"]:
		spec = linear.call(ids[0], ids[1], -1)
	elif types.size() == 2 and types.has("point") and types.has("line"):
		var point_id: int = ids[types.find("point")]
		var line_id: int = ids[types.find("line")]
		spec = {"type": "distance", "refs": [point_id, line_id], "value": _to_line(s, _xy(s, point_id), line_id)}
	elif types == ["line", "line"]:
		var a: Dictionary = s.entity(ids[0])
		var b: Dictionary = s.entity(ids[1])
		var da: Vector2 = s.point(int(a.p2)) - s.point(int(a.p1))
		var db: Vector2 = s.point(int(b.p2)) - s.point(int(b.p1))
		if absf(da.normalized().cross(db.normalized())) < 1e-6:
			# From a centerline the second line is measured from the first.
			var order: Array = ids if not (s.entity(ids[1]).get("centerline", false) and not s.entity(ids[0]).get("centerline", false)) else [ids[1], ids[0]]
			var other: Dictionary = s.entity(order[1])
			spec = {"type": "distance", "refs": order, "value": _to_line(s, _xy(s, int(other.p1)), order[0])}
		else:
			spec = _angle_spec(s, ids, place)
	elif types.size() == 2 and types.all(func(t: String) -> bool: return t in ["point", "circle", "arc", "line"]):
		if to_edge and (types.has("circle") or types.has("arc")):
			spec = _edge_spec(s, ids, types)
		elif types.has("line"):
			var line_id: int = ids[types.find("line")]
			var other: int = ids[1 - types.find("line")]
			spec = {"type": "distance", "refs": [other, line_id], "value": _to_line(s, _xy(s, other), line_id)}
		else:
			# Centres (or a point and a centre): horizontal, vertical or aligned, as for two points.
			spec = linear.call(ids[0], ids[1], -1)
	if spec.is_empty():
		return {}
	# A distance from a centerline is a diameter across it (unless turned off).
	if spec.type == "distance" and not spec.has("edge"):
		var on_centerline := (spec.refs as Array).any(func(id: int) -> bool: return s.entity(id).get("type", "") == "line" and s.entity(id).get("centerline", false))
		if on_centerline and str(overrides.get("linear_diameter", "")) != "off":
			spec["linear_diameter"] = true
			spec["value"] = 2.0 * float(spec.value)
	spec["kind"] = spec.get("kind", "length")
	spec["offset"] = place - _dimension_anchor(s, {"refs": spec.refs})
	return spec


## A point's own id, or a circle's or arc's centre point.
func _point_of(s: SKETCH, id: int) -> int:
	var e: Dictionary = s.entity(id)
	return int(e.c) if e.get("type", "") in ["circle", "arc"] else id


## A distance measured to the curves of the circles and arcs among two items (a line, a point, or
## other circles and arcs): {} when they cut or overlap (no gap to measure).
func _edge_spec(s: SKETCH, ids: Array, types: Array) -> Dictionary:
	var flags := types.map(func(t: String) -> bool: return t in ["circle", "arc"])
	if not flags.has(true):
		return {}
	var refs := ids.duplicate()
	if types[0] == "line":
		refs = [ids[1], ids[0]]
		flags = [flags[1], flags[0]]
	var gap := DIM.edge_gap(s, refs, flags)
	if gap <= 0.0:
		return {}
	# In double precision: the centre's distance to the line, or between the centres, less radii.
	var radius := func(i: int) -> float: return float(s.entity(int(refs[i])).r) if flags[i] else 0.0
	var value := 0.0
	if s.entity(int(refs[1])).get("type", "") == "line":
		value = _to_line(s, _xy(s, int(refs[0])), int(refs[1])) - radius.call(0)
	else:
		var a := _xy(s, int(refs[0]))
		var b := _xy(s, int(refs[1]))
		var d := _hypot(b[0] - a[0], b[1] - a[1])
		var r0: float = radius.call(0)
		var r1: float = radius.call(1)
		value = d - r0 - r1 if d >= r0 and d >= r1 else maxf(r0, r1) - minf(r0, r1) - d
	return {"type": "distance", "refs": refs, "edge": flags, "value": value}


## The angle at the middle of three picked points: its sector by where the cursor is (as for two
## lines), refs [vertex, a, b] counter-clockwise, rays, the sweep in (0, PI).
func _three_point_angle_spec(s: SKETCH, ids: Array, place: Vector2) -> Dictionary:
	if not _triple_ok(s, ids):
		return {}
	var vertex := s.point(ids[1])
	var ends := [ids[0], ids[2]]
	var sector := DIM.angle_sector(vertex, s.point(ends[0]), vertex, s.point(ends[1]), place)
	if not sector.is_empty() and int(sector.order[0]) == int(sector.order[1]):
		sector = DIM.angle_sector(vertex, s.point(ends[0]), vertex, s.point(ends[1]), vertex + (place - vertex).rotated(1e-4))
	if sector.is_empty() or int(sector.order[0]) == int(sector.order[1]):
		return {}
	var refs := [ids[1], ends[int(sector.order[0])], ends[int(sector.order[1])]]
	var rays := [int(sector.rays[0]), int(sector.rays[1])]
	return {"type": "angle", "kind": "angle", "refs": refs, "rays": rays, "value": _sweep(s, refs, rays)}


## Where the cursor counts for a pair's orientation: while it is within 10 px of the pair's
## middle on screen the last orientation stays (the middle itself keeps it).
func _orientation_place(s: SKETCH, a: int, b: int, place: Vector2) -> Vector2:
	var middle := (s.point(a) + s.point(b)) * 0.5
	if _dim_last_orientation == "":
		return place
	var at := viewport.project(s.to_world(place))
	var mid := viewport.project(s.to_world(middle))
	if at.is_finite() and mid.is_finite() and at.distance_to(mid) < 10.0 * _ui_scale():
		return middle
	return place


## The angle between two lines that the cursor's sector (of the four at their crossing) asks for:
## refs counter-clockwise, rays (+1 along a line's p1->p2), the sweep in (0, PI).
func _angle_spec(s: SKETCH, ids: Array, place: Vector2) -> Dictionary:
	var a: Dictionary = s.entity(ids[0])
	var b: Dictionary = s.entity(ids[1])
	var ends := [s.point(int(a.p1)), s.point(int(a.p2)), s.point(int(b.p1)), s.point(int(b.p2))]
	var sector := DIM.angle_sector(ends[0], ends[1], ends[2], ends[3], place)
	if not sector.is_empty() and int(sector.order[0]) == int(sector.order[1]):
		# Right on a line: the sector just counter-clockwise of it.
		var vertex: Vector2 = sector.vertex
		sector = DIM.angle_sector(ends[0], ends[1], ends[2], ends[3], vertex + (place - vertex).rotated(1e-4))
	if sector.is_empty() or int(sector.order[0]) == int(sector.order[1]):
		return {}
	var refs := [ids[int(sector.order[0])], ids[int(sector.order[1])]]
	var rays := [int(sector.rays[0]), int(sector.rays[1])]
	return {"type": "angle", "kind": "angle", "refs": refs, "rays": rays, "value": _sweep(s, refs, rays)}


## The counter-clockwise sweep (double precision) from rays[0] along refs[0] to rays[1] along refs[1]
## (for three points [vertex, a, b]: along vertex->a and vertex->b).
func _sweep(s: SKETCH, refs: Array, rays: Array) -> float:
	var spokes := []
	if refs.size() == 3:
		spokes = [[int(refs[0]), int(refs[1])], [int(refs[0]), int(refs[2])]]
	else:
		for i in 2:
			var e: Dictionary = s.entity(int(refs[i]))
			spokes.append([int(e.p1), int(e.p2)])
	var angles := []
	for i in 2:
		var p1 := _xy(s, spokes[i][0])
		var p2 := _xy(s, spokes[i][1])
		angles.append(atan2((p2[1] - p1[1]) * float(rays[i]), (p2[0] - p1[0]) * float(rays[i])))
	return fposmod(float(angles[1]) - float(angles[0]), TAU)


## A point's (or a circle's or arc's centre's) coordinates in double precision: [x, y] (Vector2
## holds single precision).
func _xy(s: SKETCH, id: int) -> PackedFloat64Array:
	var e: Dictionary = s.entity(id)
	return s.point_xy(int(e.c) if e.get("type", "") in ["circle", "arc"] else id)


static func _hypot(x: float, y: float) -> float:
	return sqrt(x * x + y * y)


## The distance from p ([x, y]) to a line's infinite extension, in double precision.
func _to_line(s: SKETCH, p: PackedFloat64Array, line_id: int) -> float:
	var e: Dictionary = s.entity(line_id)
	var a := _xy(s, int(e.p1))
	var b := _xy(s, int(e.p2))
	var length := _hypot(b[0] - a[0], b[1] - a[1])
	if length <= 0.0:
		return _hypot(p[0] - a[0], p[1] - a[1])
	return absf((b[0] - a[0]) * (p[1] - a[1]) - (b[1] - a[1]) * (p[0] - a[0])) / length


func apply_constraint(kind: String, ids: Array) -> void:
	var s := sketch()
	var types := ids.map(func(id) -> String: return str(s.entity(int(id)).get("type", "")))
	var type := kind
	match kind:
		"horizontal_vertical":
			if types == ["line"]:
				var e: Dictionary = s.entity(int(ids[0]))
				var d: Vector2 = s.point(int(e.p2)) - s.point(int(e.p1))
				type = "horizontal" if absf(d.x) >= absf(d.y) else "vertical"
			elif types == ["point", "point"]:
				var d: Vector2 = s.point(int(ids[1])) - s.point(int(ids[0]))
				type = "horizontal" if absf(d.x) >= absf(d.y) else "vertical"
			else:
				workspace.flash("Horizontal/Vertical needs a line or two points.")
				return
		"fix":
			var existing: Array = s.constraints().filter(func(c: Dictionary) -> bool: return c.type == "fix" and (c.refs as Array) == ids.map(func(i) -> int: return int(i)))
			workspace.change("Sketch: Fix/UnFix", func() -> void:
				var live := sketch()
				if existing.is_empty():
					live.add_constraint("fix", ids)
				else:
					live.remove_constraint(int(existing[0].id)))
			return
		"coincident":
			if not types.has("point"):
				workspace.flash("Coincident needs a point.")
				return
			if types[0] != "point":
				ids = [ids[1], ids[0]]
	var before_ids: Array = s.constraints().map(func(c: Dictionary) -> int: return int(c.id))
	workspace.change("Sketch: " + type.capitalize(), func() -> void: sketch().add_constraint(type, ids))
	_check_new_constraint(before_ids)
	selection.clear()


## Opens the value box on an existing dimension: its expression, or for a driven one what it
## measures (Enter makes it driving at the typed value). A horizontal or vertical distance an older
## document keeps negative shows its size: the value typed keeps the point on its side (see
## _edit_mutation). Works with dimensions hidden too.
func open_dimension_edit(constraint_id: int) -> void:
	var s := sketch()
	var c: Dictionary = s.constraint(constraint_id) if s != null else {}
	if not c.has("key"):
		return
	var text := ""
	if not c.get("driving", true):
		text = _box_text(_measured_value(s, c), str(c.get("kind", "length")), _noise(s, c))
	else:
		text = s.dimension_expression(constraint_id)
		if _signed_backwards(s, c):
			var stored := _stored_value(s, c)
			text = _box_text(stored, str(c.get("kind", "length")), _noise(s, c)) if DIM.is_number(text) and not is_nan(stored) else "-(%s)" % text.strip_edges()
	var at := _dimension_center(s, c)
	_open_edit(at if at.is_finite() else viewport.size * 0.5, text, constraint_id)


## A dimension's text spot on screen: where the last draw put it, else (dimensions hidden) where its
## layout puts it; INF when it is off screen.
func _dimension_center(s: SKETCH, c: Dictionary) -> Vector2:
	for entry in _dim_hits:
		if int(entry.id) == int(c.id):
			return entry.text_center
	var label := str(_dim_draw_log.get(int(c.id), {}).get("text", ""))
	if label == "":
		label = _dimension_label(s, c, _expression_marker(viewport)).text
	var layout := _layout_for(s, _shown_dimension(s, c), label)
	return layout.get("text_center", Vector2.INF)


## A driving dimension's value as its parameter evaluates now (NAN when it doesn't).
func _stored_value(s: SKETCH, c: Dictionary) -> float:
	var input: Dictionary = s.feature.inputs.get(c.get("key", ""), {})
	var result: Dictionary = workspace.result.get("values", {}).get(str(input.get("name", "")), {})
	return float(result.value) if result.get("ok", false) else NAN


## True for a horizontal or vertical distance measured backwards: older documents kept them signed
## (negative when the second point is left of or below the first); the value box takes sizes,
## so such a one has its points swapped when it is edited. Driving ones go by their value, driven
## (and broken) ones by the geometry.
func _signed_backwards(s: SKETCH, c: Dictionary) -> bool:
	if not c.get("type", "") in ["distance_x", "distance_y"] or (c.get("refs", []) as Array).size() != 2:
		return false
	if c.get("driving", true):
		var stored := _stored_value(s, c)
		if not is_nan(stored):
			return stored < 0.0
	var a := _xy(s, int(c.refs[0]))
	var b := _xy(s, int(c.refs[1]))
	var axis := 0 if c.type == "distance_x" else 1
	return b[axis] - a[axis] < -1e-12


## What a dimension measures now (positive); an angle without rays: in the sector it is shown in.
func _measured_value(s: SKETCH, c: Dictionary) -> float:
	if c.get("type", "") == "angle" and (c.refs as Array).size() != 1:
		if c.has("rays"):
			return _sweep(s, c.refs, c.rays)
		var sector := _legacy_sector(s, c)
		if not sector.is_empty():
			return _sweep(s, sector.refs, sector.rays)
	return absf(DIM.measure(s, c))


## The sector (DIM.angle_sector) of an angle's two lines that holds its text.
func _text_sector(s: SKETCH, c: Dictionary) -> Dictionary:
	var a: Dictionary = s.entity(int(c.refs[0]))
	var b: Dictionary = s.entity(int(c.refs[1]))
	if a.get("type", "") != "line" or b.get("type", "") != "line":
		return {}
	var t := _dimension_anchor(s, c) + (c.get("offset", Vector2.ZERO) as Vector2)
	var sector := DIM.angle_sector(s.point(int(a.p1)), s.point(int(a.p2)), s.point(int(b.p1)), s.point(int(b.p2)), t)
	return {} if sector.is_empty() or int(sector.order[0]) == int(sector.order[1]) else sector


## The sector an angle from before rays existed is shown and edited in ({"refs", "rays"}; {} when
## its lines don't cross): the one that holds its text when that is the angle its value gives,
## else the one the solver holds its value in (counter-clockwise from the first line's direction to
## the second's), so the label and the arc always agree and a typed value applies to what is seen.
func _legacy_sector(s: SKETCH, c: Dictionary) -> Dictionary:
	var sector := _text_sector(s, c)
	if sector.is_empty():
		return {}
	var held := {"refs": [c.refs[int(sector.order[0])], c.refs[int(sector.order[1])]], "rays": [int(sector.rays[0]), int(sector.rays[1])]}
	var value := _stored_value(s, c) if c.get("driving", true) else NAN
	if is_nan(value) or absf(_sweep(s, held.refs, held.rays) - absf(value)) <= 1e-6:
		return held
	var own := {"refs": (c.refs as Array).duplicate(), "rays": [1, 1]}
	if absf(_sweep(s, own.refs, own.rays) - absf(value)) <= 1e-6:
		return own
	return held


## The value box's text for a measured value: the document unit (degrees for angles) to 6
## decimals, or a short one (3 decimals at most) when it is that within noise (what the geometry's
## points can be off by; see _noise), so a line drawn or solved to 30 mm offers "30 mm".
func _box_text(value: float, kind: String, noise := 0.0) -> String:
	var units: String = workspace.doc.units
	var factor: float = deg_to_rad(1.0) if kind == UNITS.KIND_ANGLE else float(UNITS.LENGTH_UNITS.get(UNITS.display_unit(kind, units), 1.0))
	var shown := absf(value) / factor
	var tolerance := noise / factor
	for decimals in 4:
		var short := snappedf(shown, pow(10.0, -decimals))
		if absf(short - shown) <= tolerance:
			shown = short
			break
	return UNITS.format_value(shown * factor, kind, units, 6)


## How far what a dimension (or dimension_spec()) measures can be off: half a float step for each
## coordinate (or radius) holding a single-precision value (clicked points, a radius worked out
## from them), and SOLVE_NOISE for each point (what the solver leaves), summed (twice for a
## diameter; over the shortest arm for an angle).
func _noise(s: SKETCH, c: Dictionary) -> float:
	var total := 0.0
	var shortest := INF
	var refs: Array = c.get("refs", [])
	for r in refs:
		var e: Dictionary = s.entity(int(r))
		if e.has("r"):
			total += _single_noise(float(e.r))
			shortest = minf(shortest, float(e.r))
		for p in s.points_of(int(r)):
			var xy := s.point_xy(p)
			total += _single_noise(xy[0]) + _single_noise(xy[1]) + SOLVE_NOISE
		if e.get("type", "") == "line":
			shortest = minf(shortest, _hypot(s.point_xy(int(e.p2))[0] - s.point_xy(int(e.p1))[0], s.point_xy(int(e.p2))[1] - s.point_xy(int(e.p1))[1]))
	if c.get("type", "") == "diameter" or c.get("linear_diameter", false):
		total *= 2.0
	if str(c.get("kind", "length")) == UNITS.KIND_ANGLE:
		if refs.size() == 3:
			for i in [1, 2]:
				var arm := _between_xy(s, int(refs[0]), int(refs[i]))
				shortest = minf(shortest, _hypot(arm[0], arm[1]))
		return total / shortest if shortest > 0.0 and shortest < INF else 0.0
	return total


## Half a single-precision step at x when x holds a single-precision value, else 0.
static func _single_noise(x: float) -> float:
	if x == 0.0 or Vector2(x, 0.0).x != x:
		return 0.0
	return pow(2.0, floorf(log(absf(x)) / log(2.0)) - 24.0)


## From point a to point b in double precision: [x, y].
func _between_xy(s: SKETCH, a: int, b: int) -> PackedFloat64Array:
	var pa := s.point_xy(a)
	var pb := s.point_xy(b)
	return PackedFloat64Array([pb[0] - pa[0], pb[1] - pa[1]])


## Opens the value box centred on a dimension's text spot (kept inside the view), all selected.
func _open_edit(at_center: Vector2, text: String, constraint_id: int) -> void:
	_edit_constraint = constraint_id
	if constraint_id >= 0:
		_pending_dimension = {}
	_edit.text = text
	_show_validity(_validate(text))
	_edit.visible = true
	_place_edit(at_center)
	_edit.grab_focus()
	_edit.select_all()
	# A press that opened it (a double-click) gives the view the keyboard after this.
	_take_focus.call_deferred(text)
	viewport.redraw_overlay()


## Centres the value box (sized to its text) on a screen point, kept inside the view; the
## favourites button stays beside it.
func _place_edit(at_center: Vector2) -> void:
	_center_box(_edit, at_center)
	_place_favorites()


## Centres a value box (sized to its text) on a screen point, kept inside the view.
func _center_box(edit: LineEdit, at_center: Vector2) -> void:
	if edit.size != edit.get_combined_minimum_size():
		edit.reset_size()
	var box := edit.get_combined_minimum_size().max(edit.size)
	var margin := 4.0 * _ui_scale()
	var lowest := Vector2(margin, margin)
	var highest := (viewport.size - box - lowest).max(lowest)
	var corner := (at_center - box * 0.5).clamp(lowest, highest)
	if corner.distance_to(edit.position) > 0.01:
		edit.position = corner


## Keeps the open value box on its dimension's text spot as the view zooms, pans or turns and as
## the box grows or shrinks with its text.
func _follow_dimension(s: SKETCH) -> void:
	var center := Vector2.INF
	if _edit_constraint >= 0:
		var c: Dictionary = s.constraint(_edit_constraint)
		if not c.is_empty():
			center = _dimension_center(s, c)
	elif not _pending_dimension.is_empty():
		center = _pending_center
	if center.is_finite():
		_place_edit(center)


## The user parameters marked favourite (the Parameters dialog's star), by name.
func _favorite_names() -> Array:
	var names := []
	for p in workspace.doc.user_parameters:
		if bool(p.get("favorite", false)) and str(p.get("name", "")) != "":
			names.append(str(p.name))
	return names


## The favourites button sits just right of the open box, shown when there are favourites.
func _place_favorites() -> void:
	_fav_button.visible = _edit.visible and not _favorite_names().is_empty()
	if not _fav_button.visible:
		return
	_fav_button.reset_size()
	var size := Vector2(_fav_button.get_combined_minimum_size().x, _edit.size.y)
	_fav_button.size = size
	_fav_button.position = Vector2(_edit.position.x + _edit.size.x + 2.0 * _ui_scale(), _edit.position.y)


func _open_favorites() -> void:
	_fav_menu.clear()
	for name in _favorite_names():
		_fav_menu.add_item(name)
	_fav_menu.reset_size()
	_fav_menu.popup(Rect2i(Vector2i(_fav_button.get_screen_position() + Vector2(0.0, _fav_button.size.y)), Vector2i.ZERO))


## A favourite chosen from the list goes into the box as a click on a dimension's does.
func _on_favorite_chosen(index: int) -> void:
	var names := _favorite_names()
	if index >= 0 and index < names.size() and _edit.visible:
		_insert_parameter(str(names[index]))


## Gives the open value box the keyboard back (after a click in the view took it); all selected
## again when it still holds selected_text ("" for none).
func _take_focus(selected_text: String) -> void:
	if not _edit.visible:
		return
	_edit.grab_focus()
	if selected_text != "" and _edit.text == selected_text:
		_edit.select_all()


func _close_edit() -> void:
	_edit.visible = false
	_fav_button.visible = false
	_edit_waiting = false
	_pending_dimension = {}
	_edit_constraint = -1
	_show_validity({"ok": true, "error": ""})
	# The dimension's own text shows again.
	viewport.redraw_overlay()


## The box is done with (its value used, Esc, or a driven dimension that stays driven): it
## closes, a new dimension's picks clear for the next one (the tool stays), and the keyboard goes
## back to the view. Esc adds or changes nothing.
func _end_edit() -> void:
	var was_new := not _pending_dimension.is_empty()
	_close_edit()
	if was_new:
		_clear_dimension_picks()
	viewport.focus_view()


## Esc in the box ends it; Tab does nothing (the keyboard stays in the box).
func _on_edit_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed:
		return
	if key.keycode == KEY_ESCAPE:
		_edit.accept_event()
		_end_edit()
	elif key.keycode == KEY_TAB:
		_edit.accept_event()


func _on_edit_changed(text: String) -> void:
	_show_validity(_validate(text))
	# The box grows with its text and stays centred on the dimension (the next draw places it); the
	# favourites button and the name pill follow.
	_place_favorites.call_deferred()
	viewport.redraw_overlay()


## Shows whether the box's text can be used: dim_box_invalid text (selected or not) with the reason
## as its tooltip.
func _show_validity(check: Dictionary) -> void:
	_edit_valid = bool(check.ok)
	var color: Color = theme_colors.dim_box_text if _edit_valid else theme_colors.dim_box_invalid
	_edit.add_theme_color_override("font_color", color)
	_edit.add_theme_color_override("font_selected_color", color)
	_edit.tooltip_text = "" if _edit_valid else str(check.get("error", ""))


## The value box's type, unit kind, own parameter name (left out of the names it may use) and how
## many items it refs.
func _edit_target() -> Dictionary:
	if not _pending_dimension.is_empty():
		return {"type": str(_pending_dimension.type), "kind": str(_pending_dimension.kind), "own": "", "refs": (_pending_dimension.refs as Array).size()}
	var s := sketch()
	var c: Dictionary = s.constraint(_edit_constraint) if s != null and _edit_constraint >= 0 else {}
	if c.is_empty():
		return {}
	var own := str(s.feature.inputs.get(c.key, {}).get("name", "")) if c.get("driving", true) else ""
	return {"type": str(c.type), "kind": str(c.get("kind", "length")), "own": own, "refs": (c.refs as Array).size()}


## "name = value" typed in the box: {"name", "expression"}, or {} for a plain value.
func _split_name(text: String) -> Dictionary:
	var found := _name_equals.search(text)
	if found == null:
		return {}
	return {"name": found.get_string(1), "expression": found.get_string(2).strip_edges()}


## Whether text can be a value for the box's dimension: {"ok", "error", "value", "expression",
## "name"}. It must evaluate (numbers, units, arithmetic, other parameters) to the dimension's unit
## kind, and sizes must be above 0, distances not below 0 and angles between 0 and 180 degrees (an
## arc's sweep below 360). "name = value" also renames the parameter: name must be free. for_target:
## what the text is for (an _edit_target() result; the value box's when empty).
func _validate(text: String, for_target := {}) -> Dictionary:
	var target := for_target if not for_target.is_empty() else _edit_target()
	var expression := text.strip_edges()
	var name := ""
	var named := _split_name(expression)
	if not named.is_empty():
		name = str(named.name)
		expression = str(named.expression)
	var refused := func(error: String) -> Dictionary: return {"ok": false, "error": error, "value": 0.0, "expression": expression, "name": name}
	if target.is_empty():
		return {"ok": true, "error": "", "value": 0.0, "expression": expression, "name": name}
	if name != "" and name != target.own and not PARAMETERS.is_valid_name(workspace.doc, name, target.own):
		return refused.call("'%s' can't be the parameter's name: another parameter, unit or function has it, or it isn't a name." % name)
	if expression == "":
		return refused.call("Type a value.")
	var names := _parameter_values()
	names.erase(target.own)
	var result := UNITS.evaluate(expression, target.kind, workspace.doc.units, names)
	if not result.ok:
		return refused.call(str(result.error))
	var value := float(result.value)
	var error := ""
	match target.type:
		"angle":
			if int(target.get("refs", 2)) == 1:
				if value <= 0.0 or value >= TAU:
					error = "An arc's sweep angle must be more than 0° and less than 360°."
			elif value <= 0.0 or value >= PI:
				error = "An angle between two lines must be more than 0° and less than 180°."
		"length", "radius", "diameter", "arc_length":
			if value <= 0.0:
				error = "A %s must be more than 0." % ("length" if target.type in ["length", "arc_length"] else target.type)
		_:
			if value < 0.0:
				error = "A distance can't be less than 0."
	return {"ok": error == "", "error": error, "value": value, "expression": expression, "name": name}


## Enter in the box: an invalid value or one the sketch can't take is refused (the box stays,
## red); otherwise it is one undo step and the sketch solves again.
func _on_edit_submitted(text: String) -> void:
	if not _edit.visible and _pending_dimension.is_empty() and _edit_constraint < 0:
		return
	var check := _validate(text)
	if not check.ok:
		_refuse_edit(text, "Dimension: " + str(check.error))
		return
	var expression := str(check.expression)
	var name := str(check.name)
	if _edit_constraint >= 0:
		_commit_edit(_edit_constraint, expression, text, name)
	elif not _pending_dimension.is_empty():
		_commit_new(_pending_dimension, expression, text, name)
	else:
		_close_edit()


## Keeps the box open with text in it, all selected, in the invalid colour, and says why.
func _refuse_edit(text: String, message: String) -> void:
	if _edit.text != text:
		_edit.text = text
	_show_validity({"ok": false, "error": message})
	workspace.flash(message)
	_edit.select_all()
	_edit.grab_focus()
	# A click in the view takes the keyboard after this; the box takes it back.
	_take_focus.call_deferred(text)


func _commit_new(spec: Dictionary, expression: String, text: String, name := "") -> void:
	var mutate := func(sk: SKETCH) -> void:
		var id := _add_dimension(sk, spec, expression, true)
		if name != "":
			_rename_parameter(sk, sk.constraint(id), name, false)
	var trial := _trial(mutate)
	if _unsolvable(trial, true):
		_refuse_edit(text, "That value can't be solved with the sketch's other constraints.")
		return
	var before_ids: Array = sketch().constraints().map(func(c: Dictionary) -> int: return int(c.id))
	workspace.change("Sketch: Dimension", func() -> void: mutate.call(sketch()))
	_check_new_constraint(before_ids, spec)
	_end_edit()


## Renames a dimension's parameter; with rewrite, every expression in the document (model and user
## parameters) that uses the old name uses the new one.
func _rename_parameter(sk: SKETCH, c: Dictionary, name: String, rewrite := true) -> void:
	var input: Dictionary = sk.feature.inputs.get(c.get("key", ""), {})
	var old := str(input.get("name", ""))
	if input.is_empty() or old == name:
		return
	input["name"] = name
	if not rewrite or old == "" or sk.doc == null:
		return
	var word := RegEx.create_from_string("\\b" + old + "\\b")
	for feature in sk.doc.features:
		for key in feature.inputs:
			var each: Dictionary = feature.inputs[key]
			if each.has("expression"):
				each["expression"] = word.sub(str(each.expression), name, true)
	for p in sk.doc.user_parameters:
		p["expression"] = word.sub(str(p.get("expression", "")), name, true)


func _commit_edit(id: int, expression: String, text: String, name := "") -> void:
	var s := sketch()
	var c: Dictionary = s.constraint(id)
	if c.is_empty():
		_close_edit()
		return
	# Its own value again (and its own name): nothing changes, so there is no undo step.
	if c.get("driving", true) and expression == s.dimension_expression(id).strip_edges() \
			and (name == "" or name == str(s.feature.inputs.get(c.key, {}).get("name", ""))):
		_end_edit()
		return
	var mutate := _edit_mutation(s, id, expression, name)
	var trial := _trial(mutate)
	if not c.get("driving", true) and _over_constrains(trial, true):
		workspace.flash("That would over-constrain the sketch, so the dimension stays driven.")
		_end_edit()
		return
	if _unsolvable(trial):
		_refuse_edit(text, "That value can't be solved with the sketch's other constraints.")
		return
	workspace.change("Sketch: Edit Dimension", func() -> void: mutate.call(sketch()))
	_end_edit()


## The change an edit makes to a sketch (the real one or a trial copy): the new expression, or a
## driven dimension made driving at it. An angle from before rays existed gets them, for the
## sector it is shown in (_legacy_sector), so the typed value is the angle you see; a horizontal or
## vertical distance an older document kept negative gets its points swapped, so the size typed
## keeps the point on its side.
func _edit_mutation(s: SKETCH, id: int, expression: String, name := "") -> Callable:
	var c: Dictionary = s.constraint(id)
	var upgrade := {}
	if c.get("type", "") == "angle" and not c.has("rays") and (c.refs as Array).size() == 2:
		upgrade = _legacy_sector(s, c)
	var swap := _signed_backwards(s, c)
	return func(sk: SKETCH) -> void:
		var live: Dictionary = sk.constraint(id)
		if live.is_empty():
			return
		if not upgrade.is_empty():
			live["refs"] = (upgrade.refs as Array).duplicate()
			live["rays"] = (upgrade.rays as Array).duplicate()
		if swap:
			live["refs"] = [live.refs[1], live.refs[0]]
		var was_driving: bool = live.get("driving", true)
		if was_driving:
			sk.feature.set_expression(live.key, expression)
		else:
			sk.set_driving(id, true, expression)
		if name != "":
			_rename_parameter(sk, live, name, was_driving)


## A click in the view while the value box is open: on another driving dimension its parameter
## name goes into the box; on a driven one there is no name to use; anywhere else the value is
## accepted when it can be (as Enter) and dropped when it can't (as Esc).
func _click_while_editing(screen: Vector2) -> void:
	var id := _dimension_at(screen)
	if id >= 0 and id == _edit_constraint:
		_take_focus.call_deferred("")
		return
	if id >= 0:
		var s := sketch()
		var c: Dictionary = s.constraint(id)
		if c.get("driving", true):
			_insert_parameter(str(s.feature.inputs.get(c.key, {}).get("name", "")))
		else:
			workspace.flash("Driven dimensions have no parameter to use.")
			_take_focus.call_deferred("")
		return
	if _validate(_edit.text).ok:
		_on_edit_submitted(_edit.text)
	else:
		_end_edit()


## The dimension whose text or lines are at a screen point (-1 for none): text first, topmost first.
func _dimension_at(screen: Vector2) -> int:
	for i in range(_dim_hits.size() - 1, -1, -1):
		if Geometry2D.is_point_in_polygon(screen, _dim_hits[i].poly):
			return int(_dim_hits[i].id)
	var best := -1
	var best_px := float(DIM.metrics(_ui_scale()).hit)
	for entry in _dim_hits:
		for segment: Array in entry.segments:
			var d := Geometry2D.get_closest_point_to_segment(screen, segment[0], segment[1]).distance_to(screen)
			if d < best_px:
				best_px = d
				best = int(entry.id)
	return best


## Puts a parameter name into the box: over the selection, else at the caret, spaced from what is
## around it (none after "(" or before ")"); the caret goes after it and typing goes on.
func _insert_parameter(name: String) -> void:
	if name == "":
		return
	var text := _edit.text
	var column := _edit.caret_column
	if _edit.has_selection():
		column = _edit.get_selection_from_column()
		text = text.substr(0, column) + text.substr(_edit.get_selection_to_column())
	var before := text.substr(0, column).rstrip(" ")
	var after := text.substr(column).lstrip(" ")
	var inserted := (" " if before != "" and not before.ends_with("(") else "") + name
	_edit.text = before + inserted + (" " if after != "" and not after.begins_with(")") else "") + after
	_edit.deselect()
	_edit.caret_column = (before + inserted).length()
	_on_edit_changed(_edit.text)
	_take_focus.call_deferred("")


## Runs mutate(sketch) on a scratch copy of the document and solves the open sketch there; the
## real document, its counters, the undo history and the selection never change. Returns the
## solve result plus {"added": [new constraint ids], "param_error": String} (a parameter of the
## sketch that fails to evaluate and didn't before).
func _trial(mutate: Callable) -> Dictionary:
	var doc: Resource = workspace.doc
	var scratch: Resource = DOCUMENT.new()
	scratch.units = doc.units
	scratch.user_parameters.assign(doc.user_parameters.duplicate(true))
	scratch.counters = doc.counters.duplicate(true)
	var feature: Resource = null
	for each in doc.features:
		if each.id == feature_id:
			feature = each.copy()
			scratch.features.append(feature)
			continue
		# Other features only lend their parameters.
		var named: Resource = each.get_script().new()
		named.id = each.id
		named.label = each.label
		named.inputs = each.inputs.duplicate(true)
		scratch.features.append(named)
	if feature == null:
		return {"ok": false, "status": 2, "conflicting": [], "redundant": [], "added": [], "param_error": ""}
	var live := SKETCH.new(feature, scratch)
	var before: Array = live.constraints().map(func(c: Dictionary) -> int: return int(c.id))
	mutate.call(live)
	var values: Dictionary = PARAMETERS.evaluate(scratch)
	var result: Dictionary = SOLVE.solve(live, values)
	result["added"] = live.constraints().map(func(c: Dictionary) -> int: return int(c.id)).filter(func(id: int) -> bool: return not before.has(id))
	result["param_error"] = ""
	var known: Dictionary = workspace.result.get("values", {})
	for c in live.constraints():
		if not (c.has("key") and c.get("driving", true)):
			continue
		var name := str(feature.inputs.get(c.key, {}).get("name", ""))
		if values.has(name) and not values[name].get("ok", false) and known.get(name, {}).get("ok", true):
			result["param_error"] = "%s: %s" % [name, values[name].get("error", "")]
	return result


## True when the trial adds a conflict or redundancy the sketch didn't have (or its new
## constraint is in one). adds_driving: the trial adds one driving dimension, which must then take
## away a degree of freedom; one that doesn't repeats the sketch (the solver doesn't report a
## dimension between fixed or projected geometry, which it can't move).
func _over_constrains(trial: Dictionary, adds_driving := false) -> bool:
	var solve: Dictionary = state.get("solve", {})
	var known := {}
	for id in (solve.get("conflicting", []) as Array) + (solve.get("redundant", []) as Array):
		known[int(id)] = true
	for id in (trial.get("conflicting", []) as Array) + (trial.get("redundant", []) as Array):
		if not known.has(int(id)) or (trial.get("added", []) as Array).has(int(id)):
			return true
	var dof_now := int(solve.get("dof", -1))
	var dof_then := int(trial.get("dof", -1))
	return adds_driving and bool(solve.get("ok", false)) and dof_now >= 0 and dof_then >= dof_now


## True when the trial's sketch can't take the change: it over-constrains, it stops a solving
## sketch from solving, or a parameter breaks.
func _unsolvable(trial: Dictionary, adds_driving := false) -> bool:
	var solved_now := bool(state.get("solve", {}).get("ok", true))
	return _over_constrains(trial, adds_driving) or (solved_now and not bool(trial.get("ok", false))) or str(trial.get("param_error", "")) != ""


## A new constraint that over-constrains the sketch: a dimension (dimension, its spec) becomes
## driven (reference), other constraints are removed again, and the user is told. Dimensions are
## trial-checked before they are added, so for them this is only a safety net.
func _check_new_constraint(before_ids: Array, dimension := {}) -> void:
	var s := sketch()
	var conflicting: Array = workspace.result.get("sketches", {}).get(feature_id, {}).get("solve", {}).get("conflicting", [])
	var redundant: Array = workspace.result.get("sketches", {}).get(feature_id, {}).get("solve", {}).get("redundant", [])
	for c in s.constraints():
		if before_ids.has(int(c.id)) or not (conflicting.has(int(c.id)) or redundant.has(int(c.id))):
			continue
		var history: UndoRedo = workspace.history()
		if history != null:
			history.undo()
		if not dimension.is_empty():
			workspace.change("Sketch: Driven Dimension", func() -> void: _add_dimension(sketch(), dimension, "", false))
			workspace.flash("That dimension would over-constrain the sketch, so it was added as a driven (reference) dimension.")
		else:
			workspace.flash("That constraint conflicts with the sketch and was not added.")
		return


## Deletes the selected geometry and constraints (dimensions take their parameters with them) in
## one step, and says which other parameters used a deleted dimension's (they now show an error).
func delete_selection() -> bool:
	if selection.is_empty():
		return false
	_close_command()
	var entities := selected_entities()
	var constraint_ids := selection.filter(func(item: Dictionary) -> bool: return item.kind == "constraint").map(func(item: Dictionary) -> int: return int(item.id))
	var s := sketch()
	entities = entities.filter(func(id: int) -> bool: return not s.entity(id).get("origin", false))
	var names := _dimension_names(s)
	workspace.change("Sketch: Delete", func() -> void:
		var live := sketch()
		for cid in constraint_ids:
			live.remove_constraint(cid)
		live.remove_entities(entities))
	selection.clear()
	var kept := _dimension_names(sketch())
	_flash_broken_users(names.filter(func(name: String) -> bool: return not kept.has(name)))
	return true


## The parameter names of the sketch's driving dimensions.
func _dimension_names(s: SKETCH) -> Array:
	var names := []
	if s == null:
		return names
	for c in s.constraints():
		if c.has("key") and c.get("driving", true):
			names.append(str(s.feature.inputs.get(c.key, {}).get("name", "")))
	return names


## After dimensions' parameters went away: "d1 was used by d2, d5; those now show an error." for
## each name another parameter's expression still uses (as a whole word).
func _flash_broken_users(names: Array) -> void:
	var messages := []
	var doc: Resource = workspace.doc
	for name: String in names:
		if name == "":
			continue
		var word := RegEx.create_from_string("\\b" + name + "\\b")
		var users := []
		for p in doc.model_parameters():
			if word.search(str(p.expression)) != null:
				users.append(str(p.name))
		for p in doc.user_parameters:
			if word.search(str(p.get("expression", ""))) != null:
				users.append(str(p.get("name", "")))
		if not users.is_empty():
			messages.append("%s was used by %s; those now show an error." % [name, ", ".join(users)])
	if not messages.is_empty():
		workspace.flash(" ".join(messages))


## The right-click menu's sketch entries, listed first ({"label", "action"}, "checked" for choices):
## while Sketch Dimension has picks, the choices for the dimension being placed; else, on a
## dimension (the one at the screen point at, the hovered one, or the one selected), what can be
## done with it.
func context_entries(at := Vector2.INF) -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	var s := sketch() if active and not suspended else null
	if s == null or _edit.visible:
		return entries
	var dimension_tool: bool = TOOLS.get(tool, {}).get("dimension", false)
	if dimension_tool and not tool_picks.is_empty():
		return _placing_entries(s)
	if tool != "" and not dimension_tool:
		return entries
	var id := _context_dimension(s, at)
	if id < 0:
		return entries
	var c: Dictionary = s.constraint(id)
	entries.append({"label": "Edit Value", "action": func() -> void: open_dimension_edit(id)})
	if c.get("driving", true):
		entries.append({"label": "Make Driven", "action": func() -> void: make_driven(id)})
	else:
		# The box opens on what it measures; Enter makes it driving at the typed value.
		entries.append({"label": "Make Driving", "action": func() -> void: open_dimension_edit(id)})
	if c.type in ["radius", "diameter"]:
		entries.append({"label": "Show as Diameter" if c.type == "radius" else "Show as Radius", "action": func() -> void: swap_round(id)})
	entries.append({"label": "Delete Dimension", "action": func() -> void: delete_dimension(id)})
	return entries


## The dimension a right-click is about: at the screen point, else the hovered one, else the one
## selected dimension; -1 for none.
func _context_dimension(s: SKETCH, at: Vector2) -> int:
	if at.is_finite():
		var under := _dimension_at(at)
		if under >= 0:
			return under
	if hover.get("kind", "") == "constraint" and s.constraint(int(hover.id)).has("key"):
		return int(hover.id)
	var dims := selection.filter(func(item: Dictionary) -> bool: return item.kind == "constraint" and s.constraint(int(item.id)).has("key"))
	return int(dims[0].id) if dims.size() == 1 else -1


## The choices for the dimension being placed: orientation (slanted lines, point and centre pairs),
## radius, diameter or sweep (one circle or arc), centre or edge (circles and arcs with another
## item), diameter across a centerline, and driven.
func _placing_entries(s: SKETCH) -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	var ids := _pick_ids()
	var types := ids.map(func(id: int) -> String: return str(s.entity(id).get("type", "")))
	var choose := func(key: String, value: Variant) -> Callable:
		return func() -> void:
			_dim_overrides[key] = value
			_dim_last_orientation = ""
			viewport.redraw_overlay()
	var slanted := false
	if types == ["line"]:
		var d: Vector2 = s.point(int(s.entity(ids[0]).p2)) - s.point(int(s.entity(ids[0]).p1))
		slanted = absf(d.y) > d.length() * 0.01 and absf(d.x) > d.length() * 0.01
	var pair := types.size() == 2 and types.all(func(t: String) -> bool: return t in ["point", "circle", "arc"])
	if slanted or (pair and not bool(_dim_overrides.edge)):
		for option in [["", "Automatic"], ["distance_x", "Horizontal"], ["distance_y", "Vertical"], ["aligned", "Aligned"]]:
			entries.append({"label": option[1], "checked": str(_dim_overrides.orientation) == option[0], "action": choose.call("orientation", option[0])})
	if types == ["circle"] or types == ["arc"]:
		var current := str(_dim_overrides.round)
		if current == "":
			current = "diameter" if types == ["circle"] else "radius"
		var options := [["radius", "Radius"], ["diameter", "Diameter"]]
		if types == ["arc"]:
			options.append(["sweep", "Sweep Angle"])
		for option in options:
			entries.append({"label": option[1], "checked": current == option[0], "action": choose.call("round", option[0])})
	if types.size() == 2 and (types.has("circle") or types.has("arc")) and types.all(func(t: String) -> bool: return t in ["point", "line", "circle", "arc"]):
		entries.append({"label": "Measure to Centre", "checked": not bool(_dim_overrides.edge), "action": choose.call("edge", false)})
		entries.append({"label": "Measure to Edge", "checked": bool(_dim_overrides.edge), "action": choose.call("edge", true)})
	if types.size() == 2 and ids.any(func(id: int) -> bool: return s.entity(id).get("centerline", false)) and not bool(_dim_overrides.edge):
		var across := str(_dim_overrides.linear_diameter) != "off"
		entries.append({"label": "Diameter", "checked": across, "action": choose.call("linear_diameter", "off" if across else "")})
	entries.append({"label": "Driven", "checked": bool(_dim_overrides.driven), "action": choose.call("driven", not bool(_dim_overrides.driven))})
	return entries


## Makes a driving dimension driven (it only measures) in one step; its parameter goes, and its
## name is kept for when it is made driving again.
func make_driven(id: int) -> void:
	var s := sketch()
	var c: Dictionary = s.constraint(id) if s != null else {}
	if not c.has("key") or not c.get("driving", true):
		return
	_close_command()
	var name := str(s.feature.inputs.get(c.key, {}).get("name", ""))
	workspace.change("Sketch: Make Driven", func() -> void:
		var live := sketch()
		if name != "":
			live.constraint(id)["param_name"] = name
		live.set_driving(id, false))
	_flash_broken_users([name])


## Shows a radius as a diameter or back in one step: a plain value is doubled or halved in its own
## unit, an expression becomes "(expression) * 2" or "/ 2"; the curve keeps its size.
func swap_round(id: int) -> void:
	var s := sketch()
	var c: Dictionary = s.constraint(id) if s != null else {}
	if not c.get("type", "") in ["radius", "diameter"]:
		return
	_close_command()
	var to := "diameter" if c.type == "radius" else "radius"
	var factor := 2.0 if to == "diameter" else 0.5
	var expression := s.dimension_expression(id) if c.get("driving", true) else ""
	var rewritten := DIM.scale_literal(expression, factor)
	if rewritten == "":
		rewritten = "(%s) %s" % [expression.strip_edges(), "* 2" if to == "diameter" else "/ 2"]
	workspace.change("Sketch: Dimension Type", func() -> void:
		var live := sketch()
		var lc: Dictionary = live.constraint(id)
		lc["type"] = to
		if lc.get("driving", true):
			live.feature.set_expression(lc.key, rewritten))


## Deletes one dimension (and its parameter) as Delete does.
func delete_dimension(id: int) -> void:
	selection.clear()
	selection.append({"kind": "constraint", "id": id})
	delete_selection()


func toggle_construction() -> void:
	var ids := selected_entities()
	if ids.is_empty():
		workspace.flash("Select sketch curves to switch to construction.")
		return
	_close_command()
	workspace.change("Sketch: Construction", func() -> void: B.toggle_construction(sketch(), ids))


func set_line_type(kind: String) -> void:
	var ids := selected_entities()
	_close_command()
	workspace.change("Sketch: Line Type", func() -> void:
		var live := sketch()
		for id in ids:
			var e: Dictionary = live.entity(id)
			if e.type in ["line", "circle", "arc", "ellipse", "spline", "conic"]:
				e["construction"] = kind != "normal"
				e["centerline"] = kind == "centerline" and e.type == "line")


## Fully Define in one step: dimensions in the document's unit, placed apart about 28 px off what
## they measure (at today's zoom), and horizontal/vertical instead of 0 dimensions. A sketch with
## nothing free (or that doesn't solve) gets nothing and no undo step.
func fully_define() -> int:
	var added := [0]
	_close_command()
	var solve: Dictionary = state.get("solve", {})
	if not bool(solve.get("ok", false)) or int(solve.get("dof", -1)) == 0:
		workspace.flash("The sketch is already fully defined." if bool(solve.get("ok", false))
			else "Fully Define needs a sketch that solves; this one doesn't.")
		return 0
	var s := sketch()
	var middle := B.sketch_middle(s)
	var ppm: float = viewport.pixels_per_meter_at(s.to_world(middle))
	var gap := 28.0 * _ui_scale() / ppm if ppm > 0.0 else 0.0
	var dimensions_before := s.constraints().filter(func(c: Dictionary) -> bool: return c.has("key")).size()
	workspace.change("Sketch: Fully Define", func() -> void:
		var live := sketch()
		var values: Dictionary = workspace.result.get("values", {})
		added[0] = B.fully_define(live, func(sk: RefCounted) -> Dictionary:
			var extra: Dictionary = PARAMETERS.evaluate(workspace.doc)
			return SOLVE.solve(sk, extra if not extra.is_empty() else values), gap, workspace.doc.units))
	var dimensions := sketch().constraints().filter(func(c: Dictionary) -> bool: return c.has("key")).size() - dimensions_before
	workspace.flash("Fully Define added %d dimension(s) and %d other constraint(s)." % [dimensions, added[0] - dimensions] if added[0] > dimensions
		else "Fully Define added %d dimension(s)." % dimensions)
	return added[0]


func explode_text() -> void:
	var s := sketch()
	var ids := selected_entities().filter(func(id: int) -> bool: return s.entity(id).get("type", "") == "text")
	if ids.is_empty():
		workspace.flash("Select a text to explode.")
		return
	_close_command()
	workspace.change("Sketch: Explode Text", func() -> void:
		var live := sketch()
		for id in ids:
			B.explode_text(live, id, TEXT.outlines(live.entity(id), live, workspace.kernel)))
	selection.clear()


# --- Project / Include -----------------------------------------------------------------------

## A 3D pick while a project tool runs (edges, faces, bodies from the view).
func add_3d_pick(pick: Dictionary) -> bool:
	if not active or suspended or tool == "" or not TOOLS.get(tool, {}).has("picks3d"):
		return false
	tool_picks3d.append(pick)
	workspace.flash("%d picked. Press OK (Enter) to finish." % tool_picks3d.size())
	return true


func _project_tool(s: SKETCH, name: String, picks: Array, v: Dictionary, selected: Array) -> Variant:
	var kernel: RefCounted = workspace.kernel
	var bodies: Dictionary = workspace.result.get("bodies", {})
	var by_body := {}
	for pick in tool_picks3d:
		var list: Array = by_body.get(pick.body, [])
		list.append(pick)
		by_body[pick.body] = list
	if by_body.is_empty():
		return "Pick something in the 3D view first"
	var made: Array[int] = []
	var plane: Transform3D = s.transform()
	var curves := []
	for id in selected:
		var curve: Dictionary = s.curve_of(int(id))
		if not curve.is_empty():
			curves.append(curve)
	for body_id in by_body:
		if not bodies.has(body_id):
			continue
		var shape: RefCounted = bodies[body_id].shape
		var edges := PackedInt32Array()
		var faces := PackedInt32Array()
		for pick in by_body[body_id]:
			match str(pick.kind):
				"edge":
					edges.append(int(pick.index))
				"face":
					faces.append(int(pick.index))
					for edge in shape.face_info(int(pick.index)).get("edges", PackedInt32Array()):
						if not edges.has(edge):
							edges.append(edge)
				"body":
					for edge in shape.edge_count():
						edges.append(edge)
		match name:
			"project":
				made.append_array(B.add_curves(s, kernel.project_edges(shape, edges, plane), true))
			"intersect":
				made.append_array(B.add_curves(s, kernel.section_curves(shape, plane), true))
			"include3d":
				var tess: Dictionary = workspace.tessellations.get(body_id, {})
				var lines := []
				for edge in edges:
					var line := PackedVector3Array()
					var points: PackedVector3Array = tess.get("edge_points", PackedVector3Array())
					var ids: PackedInt32Array = tess.get("edge_ids", PackedInt32Array())
					for k in ids.size():
						if ids[k] == edge:
							if line.is_empty():
								line.append(points[k * 2])
							line.append(points[k * 2 + 1])
					lines.append(line)
				made.append(s.add_ref3d(lines, "include:%s" % body_id))
			"project_surface":
				if curves.is_empty():
					return "Select sketch curves to project"
				made.append(s.add_ref3d(kernel.project_curves_to_faces(curves, plane, shape, faces), "surface:%s" % body_id))
			"intersection_curve":
				if curves.is_empty():
					return "Select sketch curves to intersect"
				made.append(s.add_ref3d(kernel.intersection_curves(curves, plane, shape, faces), "intersection:%s" % body_id))
			"isocurve":
				var count := maxi(int(UNITS.evaluate(str(v.get("iso_count", "3")), UNITS.KIND_NUMBER, "mm", {}).get("value", 3)), 1)
				var params := PackedFloat64Array()
				for k in count:
					params.append((k + 1.0) / (count + 1.0))
				for face in faces:
					made.append(s.add_ref3d(kernel.isocurves(shape, face, 0 if v.get("iso_direction", "u") == "u" else 1, params), "isocurve:%s" % body_id))
			"spun_profile":
				if picks.is_empty():
					return "Pick a sketch line to spin around"
				made.append_array(_spun_profile(s, int(picks[0].id), workspace.tessellations.get(body_id, {})))
	if made.is_empty():
		return str(kernel.get_last_error()) if str(kernel.get_last_error()) != "" else "Nothing was projected"
	return made


## The outline a body makes spun around a sketch line (approximated from its tessellation):
## the largest distance from the axis, sampled along it, as a fixed fit-point spline.
func _spun_profile(s: SKETCH, axis_line: int, tess: Dictionary) -> Array[int]:
	var e: Dictionary = s.entity(axis_line)
	var a: Vector3 = s.to_world(s.point(int(e.p1)))
	var b: Vector3 = s.to_world(s.point(int(e.p2)))
	var axis := (b - a).normalized()
	var side := s.normal().cross(axis).normalized()
	var bins := {}
	var lo := INF
	var hi := -INF
	for p in tess.get("positions", PackedVector3Array()):
		var t: float = (p - a).dot(axis)
		lo = minf(lo, t)
		hi = maxf(hi, t)
	if lo >= hi:
		return []
	var count := 48
	for p in tess.get("positions", PackedVector3Array()):
		var t: float = (p - a).dot(axis)
		var radial: float = ((p - a) - axis * t).length()
		var k := clampi(int((t - lo) / (hi - lo) * count), 0, count)
		bins[k] = maxf(float(bins.get(k, 0.0)), radial)
	var points := []
	for k in count + 1:
		if bins.has(k):
			var t := lo + (hi - lo) * k / count
			points.append(s.to_plane(a + axis * t + side * float(bins[k])))
	if points.size() < 2:
		return []
	var made := B.spline(s, points, "fit")
	for pid in s.points_of(made[0]):
		s.entity(pid)["fixed"] = true
		s.entity(pid)["projected"] = true
	s.entity(made[0])["projected"] = true
	return made


# --- Palette ---------------------------------------------------------------------------------

## The palette floats over the view: moved, resized and collapsed by the user, and kept that way
## across sketches and editor restarts (the editor's project metadata, holo_forge/sketch_palette).
## A theme restyles it with palette.apply_style().
func _build_palette() -> void:
	palette = FLOATING_PANEL.new()
	palette.visible = false
	palette.title = "SKETCH PALETTE"
	palette.min_content_size = Vector2(150, 64)
	palette.place(Vector2(10, 40))
	var box: VBoxContainer = palette.content
	var look := Button.new()
	look.text = "Look At"
	look.pressed.connect(look_at)
	box.add_child(look)
	# Wraps onto more rows when the palette is made narrow.
	var types := HFlowContainer.new()
	for spec in [["normal", "Normal"], ["construction", "Construction"], ["centerline", "Centerline"]]:
		var button := Button.new()
		button.text = spec[1]
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.tooltip_text = "Set the selected curves' line type"
		var kind: String = spec[0]
		button.pressed.connect(func() -> void: set_line_type(kind))
		types.add_child(button)
	box.add_child(types)
	for spec in [["grid", "Sketch Grid"], ["snap", "Snap"], ["slice", "Slice (hide bodies)"], ["profiles", "Show Profile"],
			["points", "Show Points"], ["dimensions", "Show Dimensions"], ["constraints", "Show Constraints"],
			["projected", "Show Projected Geometries"]]:
		var check := CheckBox.new()
		check.text = spec[1]
		# Cut short (whole in the tooltip) when the palette is made narrow.
		check.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		check.tooltip_text = spec[1]
		var key: String = spec[0]
		check.button_pressed = show[key]
		check.toggled.connect(func(on: bool) -> void:
			show[key] = on
			if key == "slice":
				_set_slice(on)
			refresh(workspace.result))
		box.add_child(check)
		_palette_checks[key] = check
	var sketch_3d := CheckBox.new()
	sketch_3d.text = "3D Sketch"
	sketch_3d.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	sketch_3d.disabled = true
	sketch_3d.tooltip_text = "Drawing off the sketch plane is planned for a later phase; use Include 3D Geometry for 3D references."
	box.add_child(sketch_3d)
	var define := Button.new()
	define.text = "Fully Define"
	define.pressed.connect(fully_define)
	box.add_child(define)
	# Always shown, however small the palette is made.
	var finish := Button.new()
	finish.text = "FINISH SKETCH"
	finish.pressed.connect(func() -> void: workspace.run_action("finish_sketch"))
	palette.footer.add_child(finish)
	# Clicks on the palette leave the keyboard with the view, so sketch shortcuts keep working.
	for button in palette.find_children("*", "BaseButton", true, false):
		(button as BaseButton).focus_mode = Control.FOCUS_NONE
	viewport.add_child(palette)
	# Over the view, but under the command panel and the menus that open over the view.
	var command_panel: Variant = workspace.get("panel")
	if command_panel is Control and (command_panel as Control).get_parent() == viewport:
		viewport.move_child(palette, (command_panel as Control).get_index())
	palette.set_store(FLOATING_PANEL.default_store(), "sketch_palette")


## Draws sketches, their profiles and the palette in a view palette (forge_theme.gd).
func apply_theme(colors: Dictionary) -> void:
	theme_colors = colors.duplicate(true)
	_material_profile.albedo_color = theme_colors.profile
	_material_profile_hover.albedo_color = theme_colors.profile_hover
	palette.apply_style(theme_colors.get("panel_style", {}))
	_style_edit()
	_style_dialog()
	viewport.redraw_overlay()


## The driven question takes the palette's panel, title bar, close button, text and buttons.
func _style_dialog() -> void:
	if _driven_dialog != null:
		_driven_dialog.theme = FORGE_THEME.dialog_theme("dark" if bool(theme_colors.get("dark", false)) else "light", _ui_scale())


## Styles the dimension value box in the palette's dim_box_* colours at the UI scale, and builds
## the hover tip's box (dim_tip_back).
func _style_edit() -> void:
	var scale := _ui_scale()
	var t := theme_colors
	var border := maxi(1, roundi(scale))
	var radius := roundi(2.0 * scale)
	var normal := StyleBoxFlat.new()
	normal.bg_color = t.dim_box_back
	normal.border_color = t.dim_box_frame
	normal.set_border_width_all(border)
	normal.set_corner_radius_all(radius)
	normal.content_margin_left = 6.0 * scale
	normal.content_margin_right = 6.0 * scale
	normal.content_margin_top = 2.0 * scale
	normal.content_margin_bottom = 2.0 * scale
	# The focus box is drawn over the normal one: only its frame.
	var focus := normal.duplicate() as StyleBoxFlat
	focus.draw_center = false
	focus.border_color = t.dim_box_focus
	_edit.add_theme_stylebox_override("normal", normal)
	_edit.add_theme_stylebox_override("read_only", normal)
	_edit.add_theme_stylebox_override("focus", focus)
	_edit.add_theme_color_override("font_color", t.dim_box_text if _edit_valid else t.dim_box_invalid)
	_edit.add_theme_color_override("font_selected_color", t.dim_box_text if _edit_valid else t.dim_box_invalid)
	_edit.add_theme_color_override("caret_color", t.dim_box_text)
	_edit.add_theme_color_override("selection_color", t.dim_box_selection)
	_edit.add_theme_font_size_override("font_size", int(round(13.0 * scale)))
	_edit.alignment = HORIZONTAL_ALIGNMENT_CENTER
	_edit.expand_to_text_length = true
	_edit.custom_minimum_size = Vector2(96.0 * scale, 0.0)
	# The heads-up boxes look like the value box (a little narrower: there are two on the band);
	# the one the keyboard is in has the focus frame.
	for field in _heads_up:
		var heads_up: LineEdit = _heads_up[field]
		heads_up.add_theme_stylebox_override("normal", normal)
		heads_up.add_theme_stylebox_override("read_only", normal)
		heads_up.add_theme_stylebox_override("focus", focus)
		heads_up.add_theme_color_override("caret_color", t.dim_box_text)
		heads_up.add_theme_color_override("selection_color", t.dim_box_selection)
		heads_up.add_theme_font_size_override("font_size", int(round(13.0 * scale)))
		heads_up.alignment = HORIZONTAL_ALIGNMENT_CENTER
		heads_up.expand_to_text_length = true
		heads_up.custom_minimum_size = Vector2(72.0 * scale, 0.0)
		_heads_up_colors(field)
	# The favourites button looks like the box; its frame lights up under the mouse.
	var lit := normal.duplicate() as StyleBoxFlat
	lit.border_color = t.dim_box_focus
	for state in ["normal", "disabled", "focus"]:
		_fav_button.add_theme_stylebox_override(state, normal)
	for state in ["hover", "pressed", "hover_pressed"]:
		_fav_button.add_theme_stylebox_override(state, lit)
	for state in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
		_fav_button.add_theme_color_override(state, t.dim_box_text)
	_fav_button.add_theme_font_size_override("font_size", int(round(13.0 * scale)))
	_tip_style = StyleBoxFlat.new()
	_tip_style.bg_color = t.dim_tip_back
	_tip_style.set_corner_radius_all(roundi(4.0 * scale))
	_tip_style.content_margin_left = 6.0 * scale
	_tip_style.content_margin_right = 6.0 * scale
	_tip_style.content_margin_top = 3.0 * scale
	_tip_style.content_margin_bottom = 3.0 * scale


func _set_slice(on: bool) -> void:
	for id in viewport._body_nodes:
		(viewport._body_nodes[id].holder as Node3D).visible = not on and workspace.doc != null and workspace.doc.body_visible(id)


func _profile_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.albedo_color = color
	material.render_priority = 2
	# Pulled a hair toward the camera, so a profile on a body's face doesn't fight the face for depth.
	material.use_z_clip_scale = true
	material.z_clip_scale = 0.99999
	return material
