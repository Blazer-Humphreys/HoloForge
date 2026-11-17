@tool
extends Node
## Insert and export in the Forge tab: the file dialogs and option prompts of Insert SVG / DXF /
## Mesh / STEP-IGES / Derive / Component and of Export STEP / IGES / STL, Export Components,
## Export Body Meshes and Save Board Model Version, plus the document changes they make (each
## insert is one undo step; a failed one changes nothing, not even an open command or sketch).
## The dialogs only call the functions below that take a path, so tests call those directly.
##
## Export Components and Export Body Meshes never replace a file silently: a file already in the
## folder is replaced only after Replace is confirmed, and a Holo Forge design (a scene holding a
## Forge part, a saved design) or a scene open in the editor never is.

const INSERT := preload("res://addons/holo_forge/core/features/insert.gd")
const SVG_IMPORT := preload("res://addons/holo_forge/core/import/svg_import.gd")
const DXF_IMPORT := preload("res://addons/holo_forge/core/import/dxf_import.gd")
const EXPORT := preload("res://addons/holo_forge/core/export.gd")
const OPERATIONS := preload("res://addons/holo_forge/core/operations.gd")
const DOCUMENT := preload("res://addons/holo_forge/core/document.gd")
const SKETCH_DATA := preload("res://addons/holo_forge/core/sketch/sketch_data.gd")
const APPEARANCE := preload("res://addons/holo_forge/core/appearance.gd")
## Scripts whose presence in a file's dependencies marks a Holo Forge design (never overwritten).
const DESIGN_SCRIPTS := ["holo_forge/nodes/cad_part.gd", "holo_forge/core/document.gd"]
const DESIGN_EXTENSIONS := ["tscn", "scn", "tres", "res"]

const SVG_UNITS := [["", "From the File"], ["px", "Pixels (96 per inch)"], ["mm", "Millimeters"], ["cm", "Centimeters"],
	["m", "Meters"], ["in", "Inches"], ["pt", "Points"]]
const DXF_UNITS := [["", "From the File"], ["mm", "Millimeters"], ["cm", "Centimeters"], ["m", "Meters"], ["in", "Inches"], ["ft", "Feet"]]
const MESH_UNITS := [["", "From the File (3MF's unit; STL/OBJ mm, glTF m)"], ["mm", "Millimeters"], ["cm", "Centimeters"], ["m", "Meters"],
	["in", "Inches"], ["ft", "Feet"], ["um", "Microns"]]
const DESIGN_FILTERS := [["*.tres, *.res", "Holo Forge Designs"], ["*.tscn, *.scn", "Scenes with a Forge Part"]]
const IMAGE_FILTERS := [["*.png, *.jpg, *.jpeg, *.webp, *.bmp, *.tga, *.svg", "Images"]]
## Export STL also offers OBJ and 3MF, which hold mesh bodies only (their very triangles).
const CAD_EXPORTS := {
	"export_step": ["Export STEP", [["*.step, *.stp", "STEP"]], "step"],
	"export_iges": ["Export IGES", [["*.iges, *.igs", "IGES"]], "iges"],
	"export_stl": ["Export STL", [["*.stl", "STL (millimeters)"], ["*.obj", "OBJ (mesh bodies, millimeters)"], ["*.3mf", "3MF (mesh bodies, millimeters)"]], "stl"],
}
## The toolbar actions run() handles. "insert_mesh_body" is Mesh > Create > Insert Mesh: the
## file comes in as a mesh body.
const ACTIONS := ["insert_svg", "insert_dxf", "insert_mesh", "insert_mesh_body", "insert_step", "insert_derive", "insert_component",
	"export_step", "export_iges", "export_stl", "export_components", "export_body_meshes", "save_board_model"]
## Insert Mesh's Body Type choices (core/features/insert.gd KIND_MESH, KIND_SOLID).
const MESH_KINDS := [[INSERT.KIND_MESH, "Mesh Body"], [INSERT.KIND_SOLID, "Solid (faceted)"]]
const MESH_WORKSPACE := "Mesh"
## Formats offered by Save Board Model Version: [format, label, ticked by default].
const BOARD_CHOICES := [["glb", "glTF Binary (.glb)", true], ["tscn", "Godot Scene (.tscn)", false], ["tres", "Editable Design (.tres)", true],
	["step", "STEP", true], ["iges", "IGES", false], ["stl", "STL", false], ["brep", "BREP", false]]
## A Z-up file turned so its up is Godot's +Y.
const Z_UP := Transform3D(Basis(Vector3.RIGHT, -PI / 2.0), Vector3.ZERO)

## The Forge workspace (ui/forge_workspace.gd).
var workspace: Object

var _file_dialog: Node
## A mesh file up to this size is read once before the Insert Mesh prompt opens, for the reader's
## warning (reader_warning()); a larger one is read only by the insert.
const PREREAD_BYTES := 96 * 1024 * 1024
var _file_callback: Callable
var _options: ConfirmationDialog
var _options_box: VBoxContainer
var _options_editors := {}
## "list" rows' messages for an empty pick, by key.
var _options_empty_errors := {}
var _options_error: Label
var _options_callback: Callable
var _confirm: ConfirmationDialog
var _confirm_callback: Callable


func _init(p_workspace: Object = null) -> void:
	name = "ForgeFiles"
	workspace = p_workspace


## Runs an Insert or Export toolbar action. Returns false for actions that aren't these.
func run(action: String) -> bool:
	if not ACTIONS.has(action):
		return false
	# Without a Forge part nothing can be inserted or exported: say so before any dialog opens.
	if workspace.doc == null:
		_refuse("Select or add a Forge part first.")
		return true
	# Exports and saves see only accepted work: an open command's preview is dropped first (as
	# Insert does), and an open sketch is finished.
	if action.begins_with("export_") or action == "save_board_model":
		_close_edits()
	match action:
		"insert_svg":
			choose_file("Insert SVG", [["*.svg", "SVG Drawings"]], _svg_chosen)
		"insert_dxf":
			choose_file("Insert DXF", [["*.dxf", "DXF Drawings (ASCII)"]], _dxf_chosen)
		"insert_mesh", "insert_mesh_body":
			# From the Mesh workspace (its Create group, or its Insert group) the file comes in as a
			# mesh body unless the prompt says otherwise; elsewhere as a faceted solid, as before.
			var as_mesh: bool = action == "insert_mesh_body" or str(workspace.workspace) == MESH_WORKSPACE
			choose_file("Insert Mesh", [["*.stl, *.obj, *.3mf, *.glb, *.gltf", "Meshes"]], _mesh_chosen.bind(INSERT.KIND_MESH if as_mesh else INSERT.KIND_SOLID))
		"insert_step":
			choose_file("Insert STEP/IGES", [["*.step, *.stp, *.iges, *.igs, *.brep", "CAD Files"]], _cad_chosen)
		"insert_derive":
			choose_file("Insert Derive", DESIGN_FILTERS, func(path: String) -> void: insert_derive(path, false))
		"insert_component":
			choose_file("Insert Component", DESIGN_FILTERS, func(path: String) -> void: insert_derive(path, true))
		"export_step", "export_iges", "export_stl":
			var spec: Array = CAD_EXPORTS[action]
			choose_file(spec[0], spec[1], func(path: String) -> void: export_cad(path), "save", "%s.%s" % [_part_name(), spec[2]])
		"export_components":
			choose_file("Export Components (choose a folder)", [], _components_folder, "folder")
		"export_body_meshes":
			choose_file("Export Body Meshes (choose a folder)", [], func(folder: String) -> void: export_body_meshes(folder), "folder")
		"save_board_model":
			var rows := [{"key": "name", "label": "Board Model Name", "type": "text", "default": _part_name()}]
			for choice in BOARD_CHOICES:
				rows.append({"key": choice[0], "label": choice[1], "type": "bool", "default": choice[2]})
			ask_options("Save Board Model Version", rows, _board_model_chosen)
		_:
			return false
	return true


# --- Dialogs ---------------------------------------------------------------------------------

## Asks for a file (mode "open" or "save") or a folder ("folder"), then calls callback(path) with
## the path inside the project as res:// when it is there. filters: [[patterns, description]].
func choose_file(title: String, filters: Array, callback: Callable, mode := "open", file_name := "") -> void:
	_file_callback = callback
	if not Engine.is_editor_hint():
		return
	if _file_dialog == null:
		var created := EditorFileDialog.new()
		created.access = EditorFileDialog.ACCESS_FILESYSTEM
		created.file_selected.connect(_file_chosen)
		created.dir_selected.connect(_file_chosen)
		add_child(created)
		_file_dialog = created
	var dialog := _file_dialog as EditorFileDialog
	dialog.file_mode = {"save": EditorFileDialog.FILE_MODE_SAVE_FILE, "folder": EditorFileDialog.FILE_MODE_OPEN_DIR}.get(mode, EditorFileDialog.FILE_MODE_OPEN_FILE)
	# (After the mode: setting the mode puts the dialog's own "Open a File" title back.)
	dialog.title = title
	dialog.clear_filters()
	for filter in filters:
		dialog.add_filter(filter[0], filter[1])
	if file_name != "":
		dialog.current_file = file_name
	dialog.popup_file_dialog()


## Asks for an image file (Canvas, Decal) and calls callback(path).
func choose_image(callback: Callable) -> void:
	choose_file("Choose Image", IMAGE_FILTERS, callback)


func _file_chosen(path: String) -> void:
	var callback := _file_callback
	_file_callback = Callable()
	if callback.is_valid():
		callback.call(ProjectSettings.localize_path(path))


## A small options prompt; callback(values) runs on OK. Rows: {"key", "label", "type": "enum"
## (with "options": [[value, label]]) | "bool" | "text" | "list" (with "items", all picked at
## first; the value is the picked items, empty when all of them are, and OK with none picked
## says "empty_error" and keeps the prompt open), "default"}.
func ask_options(title: String, rows: Array, callback: Callable) -> void:
	if _options == null:
		_options = ConfirmationDialog.new()
		# OK closes the prompt only when the values are complete (see _options_confirmed).
		_options.dialog_hide_on_ok = false
		_options_box = VBoxContainer.new()
		_options.add_child(_options_box)
		_options.confirmed.connect(_options_confirmed)
		add_child(_options)
	_options.title = title
	_options_callback = callback
	for child in _options_box.get_children():
		_options_box.remove_child(child)
		child.queue_free()
	_options_editors.clear()
	_options_empty_errors.clear()
	for row in rows:
		if str(row.type) == "info":
			# A note above the choices (a file's warning): the whole width, wrapped.
			var note := Label.new()
			note.name = "Note_%s" % str(row.key)
			note.text = str(row.get("text", ""))
			note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			note.custom_minimum_size = Vector2(400, 0)
			note.add_theme_color_override("font_color", Color(1.0, 0.78, 0.35))
			_options_box.add_child(note)
			continue
		var line := HBoxContainer.new()
		var label := Label.new()
		label.text = str(row.label)
		label.custom_minimum_size = Vector2(170, 0)
		line.add_child(label)
		var editor: Control
		match str(row.type):
			"enum":
				var option := OptionButton.new()
				for i in (row.options as Array).size():
					option.add_item(str(row.options[i][1]))
					option.set_item_metadata(i, row.options[i][0])
				editor = option
			"bool":
				var check := CheckBox.new()
				check.button_pressed = bool(row.get("default", false))
				editor = check
			"text":
				var edit := LineEdit.new()
				edit.text = str(row.get("default", ""))
				editor = edit
			"list":
				var list := ItemList.new()
				list.select_mode = ItemList.SELECT_MULTI
				list.custom_minimum_size = Vector2(0, 110)
				for item in row.get("items", []):
					list.add_item(str(item))
				for i in list.item_count:
					list.select(i, false)
				editor = list
				_options_empty_errors[str(row.key)] = str(row.get("empty_error", "Pick at least one of the %s." % str(row.label).to_lower()))
		editor.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		line.add_child(editor)
		_options_box.add_child(line)
		_options_editors[str(row.key)] = editor
	_options_error = Label.new()
	_options_error.name = "Problem"
	_options_error.add_theme_color_override("font_color", Color(1.0, 0.45, 0.4))
	_options_error.visible = false
	_options_box.add_child(_options_error)
	_options.reset_size()
	_options.popup_centered(Vector2i(420, 0))


## OK in the options prompt: the values go to the callback and the prompt closes, unless a list
## has nothing picked (that would mean "none", which nothing can import): then the prompt stays
## open and says so.
func _options_confirmed() -> void:
	var values := {}
	for key in _options_editors:
		var editor: Control = _options_editors[key]
		if editor is OptionButton:
			values[key] = (editor as OptionButton).get_item_metadata(maxi((editor as OptionButton).selected, 0))
		elif editor is CheckBox:
			values[key] = (editor as CheckBox).button_pressed
		elif editor is LineEdit:
			values[key] = (editor as LineEdit).text.strip_edges()
		elif editor is ItemList:
			var list := editor as ItemList
			var picked := PackedStringArray()
			for i in list.get_selected_items():
				picked.append(list.get_item_text(i))
			if picked.is_empty() and list.item_count > 0:
				var problem := str(_options_empty_errors.get(key, "Pick at least one item."))
				if _options_error != null:
					_options_error.text = problem
					_options_error.visible = true
				workspace.flash(problem)
				return
			# Every layer picked means all of them (layers added to the file later come too).
			values[key] = picked if picked.size() < list.item_count else PackedStringArray()
	if _options != null:
		_options.hide()
	var callback := _options_callback
	_options_callback = Callable()
	if callback.is_valid():
		callback.call(values)


## A yes/no question: callback() runs when the ok_text button is pressed (also shown in the
## status line, so the question is seen without the editor's dialogs).
func confirm(title: String, text: String, callback: Callable, ok_text := "OK") -> void:
	if _confirm == null:
		_confirm = ConfirmationDialog.new()
		_confirm.confirmed.connect(_confirm_accepted)
		add_child(_confirm)
	_confirm.title = title
	_confirm.dialog_text = text
	_confirm.ok_button_text = ok_text
	_confirm_callback = callback
	_confirm.reset_size()
	_confirm.popup_centered(Vector2i(460, 0))


func _confirm_accepted() -> void:
	var callback := _confirm_callback
	_confirm_callback = Callable()
	if callback.is_valid():
		callback.call()


func _svg_chosen(path: String) -> void:
	ask_options("Insert SVG", [{"key": "units", "label": "One Drawing Unit Is", "type": "enum", "options": SVG_UNITS}],
		func(o: Dictionary) -> void: begin_sketch_file(path, _sketch_options(o)))


func _dxf_chosen(path: String) -> void:
	var layers := DXF_IMPORT.layers(FileAccess.get_file_as_string(path))
	ask_options("Insert DXF", [
		{"key": "layers", "label": "Layers", "type": "list", "items": layers, "empty_error": "Pick at least one layer."},
		{"key": "one_sketch_per_layer", "label": "One Sketch per Layer", "type": "bool"},
		{"key": "units", "label": "One Drawing Unit Is", "type": "enum", "options": DXF_UNITS},
	], func(o: Dictionary) -> void: begin_sketch_file(path, _sketch_options(o)))


## The prompt after a mesh file is chosen. kind: the Body Type it starts on (its first choice).
func _mesh_chosen(path: String, kind := INSERT.KIND_SOLID) -> void:
	var kinds := MESH_KINDS.duplicate()
	if kind != INSERT.KIND_MESH:
		kinds.reverse()
	var rows := [
		{"key": "kind", "label": "Body Type", "type": "enum", "options": kinds},
		{"key": "units", "label": "One File Unit Is", "type": "enum", "options": MESH_UNITS},
		{"key": "z_up", "label": "The File Is Z-Up", "type": "bool"},
	]
	# What the reader says of a file it takes with doubts (one that looks cut off, or holds faces
	# it leaves out) is shown before the insert, not only after it.
	var doubts := reader_warning(path)
	if doubts != "":
		rows.push_front({"key": "warning", "type": "info", "text": doubts})
	ask_options("Insert Mesh", rows, func(o: Dictionary) -> void: insert_mesh(path, str(o.get("units", "")), bool(o.get("z_up", false)), str(o.get("kind", kind))))


## What the mesh reader says of a file it takes with doubts ("" for a whole file, for one that
## can't be read at all, whose error the insert gives, and for a file over PREREAD_BYTES, which
## is not read twice: its warning comes with the insert).
func reader_warning(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() > PREREAD_BYTES:
		return ""
	file.close()
	return str(INSERT.read_mesh_body(path).get("warning", ""))


func _cad_chosen(path: String) -> void:
	ask_options("Insert STEP/IGES", [
		{"key": "linked", "label": "Linked (read the file again on every rebuild)", "type": "bool"},
		{"key": "split", "label": "One Body per Solid", "type": "bool"},
	], func(o: Dictionary) -> void: insert_cad_file(path, bool(o.get("linked", false)), bool(o.get("split", false))))


func _components_folder(folder: String) -> void:
	ask_options("Export Components", [{"key": "format", "label": "Format", "type": "enum", "options": [["tscn", "Godot Scene (.tscn)"], ["glb", "glTF Binary (.glb)"]]}],
		func(o: Dictionary) -> void: export_components(folder, str(o.get("format", "tscn"))))


func _board_model_chosen(o: Dictionary) -> void:
	var formats := []
	for choice in BOARD_CHOICES:
		if bool(o.get(choice[0], false)):
			formats.append(choice[0])
	save_board_model(str(o.get("name", "")), formats)


static func _sketch_options(o: Dictionary) -> Dictionary:
	var options := o.duplicate()
	if str(options.get("units", "")) == "":
		options.erase("units")
	return options


# --- Insert ----------------------------------------------------------------------------------

## Insert SVG / DXF after the file and options are chosen: inside a sketch the drawing goes on
## that sketch's plane; otherwise the next click on an origin plane or flat face picks the plane.
## A file that can't be found or has nothing to draw is refused before the open sketch, command
## or view changes.
func begin_sketch_file(path: String, options := {}) -> void:
	if workspace.doc == null:
		_refuse("Select or add a Forge part first.")
		return
	var editor: RefCounted = workspace.sketch_editor
	if editor.active:
		var sketch: Resource = workspace.doc.find_feature(editor.feature_id)
		if sketch != null:
			# _insert tries the drawing on a copy first: the sketch closes only once it is in.
			insert_sketch_file(path, sketch.options.plane, str(sketch.options.get("plane_ref", "")), options)
			return
	# Read before the plane pick, which would otherwise end an open command for nothing.
	var problem := _sketch_file_problem(path, options)
	if problem != "":
		workspace.flash("Insert %s: %s" % [path.get_extension().to_upper(), problem])
		return
	workspace.start_plane_pick(func(frame: Dictionary, plane_ref: String) -> void: insert_sketch_file(path, frame, plane_ref, options),
		"Insert %s: click an origin plane or a flat face for the drawing (Esc to cancel)." % path.get_extension().to_upper())


## Why an SVG or DXF file can't be inserted ("" when it can): the wrong kind of file, a missing
## one, or a drawing with nothing to import (read into a scratch design, so nothing changes).
func _sketch_file_problem(path: String, options: Dictionary) -> String:
	var ext := path.get_extension().to_lower()
	if not ext in ["svg", "dxf"]:
		return "Insert SVG and Insert DXF read .svg and .dxf files."
	if not FileAccess.file_exists(path):
		return "%s can't be found." % path.get_file()
	var scratch: Resource = DOCUMENT.new()
	scratch.units = workspace.doc.units
	var made := _read_sketch_file(path, FileAccess.get_file_as_string(path), scratch, SKETCH_DATA.ORIGIN_PLANES.xy, "xy", options)
	return str(made.get("error", "")) if made.get("feature") == null else ""


## An SVG or DXF drawing as fixed sketch geometry on a plane (frame {"origin", "x", "y"}).
## options: as SVG_IMPORT / DXF_IMPORT.to_sketch (units, layers, one_sketch_per_layer, ...).
## Returns their result ({"feature", "features" (DXF), "curves", "warnings"}), or with "error".
func insert_sketch_file(path: String, frame: Dictionary, plane_ref: String, options := {}) -> Dictionary:
	var ext := path.get_extension().to_lower()
	if not ext in ["svg", "dxf"]:
		return _refuse("Insert SVG and Insert DXF read .svg and .dxf files.")
	if not FileAccess.file_exists(path):
		return _refuse("%s can't be found." % path.get_file())
	var text := FileAccess.get_file_as_string(path)
	var made := _insert("Insert " + ext.to_upper(), func(doc: Resource) -> Dictionary:
		return _read_sketch_file(path, text, doc, frame, plane_ref, options))
	if made.get("feature") != null:
		var warnings := PackedStringArray(made.get("warnings", []))
		workspace.flash("Inserted %d curve(s) from %s into %d sketch(es)%s" % [int(made.curves), path.get_file(),
			(made.get("features", [made.feature]) as Array).size(), (": " + "; ".join(warnings)) if not warnings.is_empty() else "."])
	return made


## The drawing in text (from the .svg or .dxf file at path) added to doc as sketch features:
## SVG_IMPORT / DXF_IMPORT.to_sketch's result, with "error" when nothing could be drawn.
static func _read_sketch_file(path: String, text: String, doc: Resource, frame: Dictionary, plane_ref: String, options: Dictionary) -> Dictionary:
	var out: Dictionary = SVG_IMPORT.to_sketch(text, doc, frame, plane_ref, options) if path.get_extension().to_lower() == "svg" \
		else DXF_IMPORT.to_sketch(text, doc, frame, plane_ref, options)
	if out.get("feature") == null:
		var warnings: Array = out.get("warnings", [])
		out["error"] = str(warnings[0]) if not warnings.is_empty() else "%s has nothing to draw" % path.get_file()
	else:
		for feature in out.get("features", [out.feature]):
			feature.options["source_file"] = path
	return out


## A mesh file (STL, OBJ, 3MF, GLB/glTF) as a faceted body (kind INSERT.KIND_SOLID) or a mesh
## body (INSERT.KIND_MESH: triangles and face groups, for the Mesh workspace). units: one file unit
## ("" = the file's own: a 3MF file's unit, else the format's); z_up turns a Z-up file upright.
func insert_mesh(path: String, units := "", z_up := false, kind := INSERT.KIND_SOLID) -> Dictionary:
	# (A mesh body's insert is a Mesh tool's step: its undo step is named "Forge: Mesh: Insert Mesh" in the history.)
	var made := _insert("Mesh: Insert Mesh" if kind == INSERT.KIND_MESH else "Insert Mesh", func(doc: Resource) -> Dictionary:
		var out := INSERT.add_mesh_import(doc, path, units, false, kind)
		if out.get("feature") != null and z_up:
			out.feature.options["transform"] = Z_UP
		return out)
	if made.get("feature") != null:
		# What the reader or the feature warns of (a file that looks cut off, open edges) is said
		# with the insert, not only kept on the feature.
		var warning := str((workspace.result.get("warnings", {}) as Dictionary).get(made.feature.id, ""))
		# (The reader's own warning, when the feature's does not carry it already.)
		var read := str(made.get("warning", ""))
		if read != "" and not warning.contains(read):
			warning = read if warning == "" else "%s %s" % [read, warning]
		workspace.flash("Inserted %s as a %s (%s).%s" % [path.get_file(), "mesh body" if kind == INSERT.KIND_MESH else "faceted solid",
			workspace.counted(int(made.get("triangles", 0)), "triangle"), (" " + warning) if warning != "" else ""])
	return made


## A STEP, IGES or BREP file (STL too) as a body, keeping a copy in the design. linked: read the
## file again on every rebuild while it exists; split: one body per solid.
func insert_cad_file(path: String, linked := false, split := false) -> Dictionary:
	var made := _insert("Insert " + path.get_extension().to_upper(), func(doc: Resource) -> Dictionary:
		var out := INSERT.add_import(doc, workspace.kernel, path, linked)
		if out.get("feature") != null:
			out.feature.options["split"] = split
		return out)
	if made.get("feature") != null:
		workspace.flash("Inserted %s (%d solid(s))." % [path.get_file(), int(made.get("solids", 0))])
	return made


## Derives every body of another saved design (a .tres, or a scene whose first Forge part holds
## the design). as_component: Insert Component, which puts them in a new component named after
## the file.
func insert_derive(path: String, as_component := false) -> Dictionary:
	var made := _insert("Insert Component" if as_component else "Insert Derive", func(doc: Resource) -> Dictionary:
		# The design's own file and derive loops are checked against the design itself: the trial
		# copy _insert may hand over has no file of its own.
		if workspace.kernel != null and doc != workspace.doc:
			var source := INSERT.derive_source(workspace.doc, path, workspace.kernel)
			if source.has("error"):
				return {"feature": null, "error": str(source.error)}
		var out := INSERT.add_derive(doc, path, workspace.kernel)
		if out.get("feature") != null and as_component:
			_make_component(doc, out.feature, path.get_file().get_basename())
		return out)
	if made.get("feature") != null:
		workspace.flash("Inserted %d body(ies) from %s." % [(made.get("bodies", []) as Array).size(), path.get_file()])
	return made


## Moves a derive's bodies into a new component of their own (removed with the feature).
static func _make_component(doc: Resource, feature: Resource, component_name: String) -> void:
	var component_id: String = doc.new_component(feature.id)
	doc.components[component_id]["name"] = component_name
	feature.options["operation"] = OPERATIONS.NEW_COMPONENT
	feature.options["component_id"] = component_id
	for body_id in (feature.options.get("body_map", {}) as Dictionary).values():
		if doc.bodies.has(body_id):
			doc.bodies[body_id]["component"] = component_id


## Runs make(doc) -> {"feature", "error", ...} as one undo step. A failure changes nothing and is
## shown in the status line. An open command is cancelled (its preview was never accepted) and
## an open sketch finished, but only once the insert is known to work: while either is open,
## make runs on a copy of the design first, so a file that can't be read leaves them as they
## are (the file is then read twice).
func _insert(action_name: String, make: Callable) -> Dictionary:
	var doc: Resource = workspace.doc
	if doc == null:
		return _refuse("Select or add a Forge part first.")
	if workspace.command != null or workspace.sketch_editor.active:
		var trial: Resource = DOCUMENT.new()
		trial.restore(doc.snapshot())
		var tried: Dictionary = make.call(trial)
		if tried.get("feature") == null:
			workspace.flash("%s: %s" % [action_name, str(tried.get("error", "nothing was inserted"))])
			return tried
		_close_edits()
	var before: Dictionary = doc.snapshot()
	var made: Dictionary = make.call(doc)
	if made.get("feature") == null:
		doc.restore(before)
		workspace.flash("%s: %s" % [action_name, str(made.get("error", "nothing was inserted"))])
		return made
	workspace.commit_change(action_name, before)
	return made


func _refuse(text: String) -> Dictionary:
	workspace.flash(text)
	return {"feature": null, "error": text}


## Cancels an open command (its preview was never accepted) and finishes an open sketch, so the
## document, result and baked part hold only accepted features.
func _close_edits() -> void:
	if workspace.command != null:
		workspace.cancel_command()
	if workspace.sketch_editor.active:
		workspace.sketch_editor.end()


# --- Export ----------------------------------------------------------------------------------

## Writes bodies to a STEP, IGES, STL (millimeters), BREP, OBJ or 3MF file: body_ids, else the
## bodies and components picked in the view (a leftover face, edge or point pick doesn't narrow
## the file), else every body. STEP, IGES and BREP hold B-rep bodies only and OBJ and 3MF mesh
## bodies only: the others are left out, and the status line names them. Returns "" or the
## problem (also shown) when no file was written.
func export_cad(path: String, body_ids: Array = []) -> String:
	return str(export_cad_report(path, body_ids).error)


## export_cad() with what happened: {"error", "written": the body ids in the file, "skipped": the
## body ids the format can't hold, "hidden": the hidden bodies left out when every body is
## exported, "note": the sentences naming both} (EXPORT.export_cad_report). The note is said with
## the export's message.
func export_cad_report(path: String, body_ids: Array = []) -> Dictionary:
	_close_edits()
	var ids := body_ids.duplicate()
	if ids.is_empty():
		ids = _picked_bodies()
	var report := EXPORT.export_cad_report(workspace.kernel, workspace.result, ids, path, workspace.doc)
	if str(report.error) == "":
		_rescan(path)
		var count := (report.written as Array).size()
		var note := str(report.get("note", ""))
		workspace.flash("Exported %d body(ies) to %s.%s" % [count, path.get_file(), (" " + note) if note != "" else ""])
	else:
		workspace.flash(str(report.error))
	return report


## The bodies of the view selection's body picks and of its component picks (nested components
## too), in the result's order.
func _picked_bodies() -> Array:
	var ids := []
	var doc: Resource = workspace.doc
	for body_id in (workspace.result.get("bodies", {}) as Dictionary):
		for pick in workspace.selection:
			var kind := str(pick.get("kind", ""))
			if (kind == "body" and str(pick.get("body", "")) == str(body_id)) or (kind == "component" and doc != null
					and APPEARANCE.reaches(doc, str(body_id), APPEARANCE.component_target(str(pick.get("component", ""))))):
				ids.append(body_id)
				break
	return ids


## Every component of the baked part (and its top-level bodies) as its own scene in folder:
## format "tscn" or "glb". Files already in the folder are replaced only when replace names
## them (Replace in the question this asks, which exports again); a Holo Forge design or a scene
## open in the editor never is (see _may_write). Returns the written paths ([] when it asked or
## refused).
func export_components(folder: String, format := "tscn", replace := PackedStringArray()) -> Array:
	if workspace.part == null:
		_refuse("Select or add a Forge part first.")
		return []
	_close_edits()
	if not _may_write("Export Components", folder, _component_files(format), replace,
			func(approved: PackedStringArray) -> void: export_components(folder, format, approved)):
		return []
	var paths := EXPORT.export_components(workspace.part, folder, format)
	_rescan(folder)
	var expected: int = (workspace.part.component_nodes() as Dictionary).size()
	if workspace.part.get_children().any(func(child: Node) -> bool: return child.has_meta(EXPORT.BODY_META)):
		expected += 1
	var caveat := glb_decal_note(workspace.part) if format.to_lower().trim_prefix(".") == "glb" else ""
	workspace.flash("Exported %d scene(s) to %s%s%s." % [paths.size(), folder, _failed_note(expected - paths.size()), caveat])
	return paths


## Every baked body's mesh as its own .res in folder, replacing files there only as Export
## Components does. Returns the written paths ([] when it asked or refused).
func export_body_meshes(folder: String, replace := PackedStringArray()) -> Array:
	if workspace.part == null:
		_refuse("Select or add a Forge part first.")
		return []
	_close_edits()
	if not _may_write("Export Body Meshes", folder, _body_mesh_files(), replace,
			func(approved: PackedStringArray) -> void: export_body_meshes(folder, approved)):
		return []
	var paths := EXPORT.export_body_meshes(workspace.part, folder)
	_rescan(folder)
	var expected := 0
	for node in (workspace.part.body_nodes() as Dictionary).values():
		if (node as MeshInstance3D).mesh != null:
			expected += 1
	workspace.flash("Exported %d body mesh(es) to %s%s." % [paths.size(), folder, _failed_note(expected - paths.size())])
	return paths


## The file names EXPORT.export_components gives the part's scenes, in its order: the top-level
## bodies' scene (named after the part) when the part has bodies of its own, then a scene per
## component.
func _component_files(format: String) -> PackedStringArray:
	var files := PackedStringArray()
	var part: Node3D = workspace.part
	format = format.to_lower().trim_prefix(".")
	if not EXPORT.SCENE_FORMATS.has(format):
		return files
	var used := {}
	for child in part.get_children():
		if child.has_meta(EXPORT.BODY_META):
			files.append(EXPORT._unique_file(EXPORT._file_stem(str(part.name)), format, used))
			break
	for node in part.component_nodes().values():
		files.append(EXPORT._unique_file(str(node.name), format, used))
	return files


## The file names EXPORT.export_body_meshes gives the baked bodies' meshes, in its order.
func _body_mesh_files() -> PackedStringArray:
	var files := PackedStringArray()
	var used := {}
	for body in workspace.part.body_nodes().values():
		if (body as MeshInstance3D).mesh != null:
			files.append(EXPORT._unique_file(str(body.name), "res", used))
	return files


## Before an export writes files (names) into folder: true when it may. Names are compared
## without case (Windows replaces Board.tscn with board.tscn). A file there that holds a Holo
## Forge design, or a scene open in the editor, refuses the export; other files already there
## make it ask first, unless replace already names them all: Replace calls retry(those names).
func _may_write(action_name: String, folder: String, files: PackedStringArray, replace: PackedStringArray, retry: Callable) -> bool:
	# Every file there by its lower-case name (a case-sensitive file system can hold several).
	var existing := {}
	var dir := DirAccess.open(folder)
	if dir != null:
		for file in dir.get_files():
			# Packed arrays are values: change a local copy and store it back.
			var same: PackedStringArray = existing.get(file.to_lower(), PackedStringArray())
			same.append(file)
			existing[file.to_lower()] = same
	var clashes := PackedStringArray()
	for file in files:
		for found in existing.get(file.to_lower(), PackedStringArray()):
			if not clashes.has(found):
				clashes.append(found)
	if clashes.is_empty():
		return true
	for file in clashes:
		var path := folder.path_join(file)
		var why := "holds a Holo Forge design" if _is_design(path) else ("is open in the editor" if _is_open_scene(path) else "")
		if why != "":
			_refuse("%s would replace %s, which %s; choose another folder." % [action_name, file, why])
			return false
	var approved := {}
	for file in replace:
		approved[file.to_lower()] = true
	var unapproved := Array(clashes).filter(func(file: String) -> bool: return not approved.has(file.to_lower()))
	if unapproved.is_empty():
		return true
	var shown := ", ".join(PackedStringArray(clashes.slice(0, 6))) + (", ..." if clashes.size() > 6 else "")
	workspace.flash("%s: %d file(s) are already in %s (%s); confirm to replace them." % [action_name, clashes.size(), folder, shown])
	confirm(action_name, "%d file(s) with these names are already in\n%s:\n%s\n\nReplace them?" % [clashes.size(), folder, shown],
		func() -> void: retry.call(clashes), "Replace")
	return false


## True when the file at path holds a Holo Forge design: a scene with a Forge part, or a saved
## design (a CadDocument).
static func _is_design(path: String) -> bool:
	if not path.get_extension().to_lower() in DESIGN_EXTENSIONS:
		return false
	for dependency in ResourceLoader.get_dependencies(path):
		for script in DESIGN_SCRIPTS:
			if str(dependency).contains(script):
				return true
	return false


## True when path is a scene open in the editor (always false outside the editor).
static func _is_open_scene(path: String) -> bool:
	if not Engine.is_editor_hint():
		return false
	var target := ProjectSettings.globalize_path(path).simplify_path().to_lower()
	for open in EditorInterface.get_open_scenes():
		if ProjectSettings.globalize_path(open).simplify_path().to_lower() == target:
			return true
	return false


## Saves the next version of a board model (core/export.gd board_model_export): into the
## project's board models folder (core/export.gd board_models_root()) unless root says
## otherwise, never overwriting one.
## Returns {"paths", "version", "error"}.
func save_board_model(base_name: String, formats: Array = ["glb", "step", "tres"], root := "") -> Dictionary:
	if workspace.part == null:
		return {"paths": [], "version": 0, "error": _refuse("Select or add a Forge part first.").error}
	_close_edits()
	var out := EXPORT.board_model_export(workspace.part, workspace.kernel, workspace.result, base_name, formats, root)
	if (out.paths as Array).is_empty():
		workspace.flash("Save Board Model Version: %s" % out.error)
	else:
		var saved := "Saved %s version %d (%d file(s)) in %s" % [str(out.paths[0]).get_file().get_basename().rsplit("_v", true, 1)[0],
			int(out.version), (out.paths as Array).size(), str(out.paths[0]).get_base_dir()]
		workspace.flash(saved + (" (%s)" % out.error if str(out.error) != "" else "."))
		_rescan(str(out.paths[0]))
	return out


## What a .glb of node lacks (glTF can't hold decals): "; glTF can't hold decals, so Logo was left
## out", or "".
static func glb_decal_note(node: Node) -> String:
	var lost := EXPORT.decal_names(node)
	if lost.is_empty():
		return ""
	return "; glTF can't hold decals, so %s %s left out" % [", ".join(lost), "was" if lost.size() == 1 else "were"]


## " (N could not be written; the Output panel says why)" when N > 0, else "".
static func _failed_note(failed: int) -> String:
	return " (%d could not be written; the Output panel says why)" % failed if failed > 0 else ""


func _part_name() -> String:
	return str(workspace.part.name) if workspace != null and workspace.part != null else "Part"


## Lets the FileSystem dock see files written inside the project.
static func _rescan(path: String) -> void:
	if Engine.is_editor_hint() and path.begins_with("res://"):
		EditorInterface.get_resource_filesystem().scan()
