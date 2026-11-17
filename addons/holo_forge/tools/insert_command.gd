@tool
extends "res://addons/holo_forge/tools/feature_command.gd"
## Edits an Import, Insert Mesh or Derive feature from the timeline (the Insert menu makes them;
## ui/forge_files.gd), from the "import", "mesh_import" and "derive" specs in feature_specs.gd:
## the file (typed, or Choose File...), the offsets and angles that place it (inputs x, y, z, rx,
## ry, rz, after the feature's own transform; core/features/insert.gd placement()), and its
## options: Linked and One Body per Solid (import); units, Z-up, Linked and One Body per Piece
## (mesh); which bodies of the source design come in (derive: one row per body).
##
## A new file is read as soon as the path names one that can be read (INSERT.change_source keeps
## its copy in the design); until then the feature stays on its old file and the Source row
## says why. Every change previews through a rebuild, and OK keeps the edit as one undo step.

const INSERT := preload("res://addons/holo_forge/core/features/insert.gd")
const REGEN_PATH := "res://addons/holo_forge/core/regen.gd"

## Derive's body rows are keyed "body:<source body id>".
const BODY_ROW := "body:"
## Panel rows the command handles itself (they aren't stored as options).
const OWN_ROWS := ["browse", "source", "z_up"]
const FILTERS := {
	"import": [["*.step, *.stp, *.iges, *.igs, *.brep, *.stl", "CAD Files"]],
	"mesh_import": [["*.stl, *.obj, *.3mf, *.glb, *.gltf", "Meshes"]],
	"derive": [["*.tres, *.res", "Holo Forge Designs"], ["*.tscn, *.scn", "Scenes with a Forge Part"]],
}

## What the Source row says: the file in use, or why a typed one can't be read.
var _note := ""
var _own_kernel: RefCounted
## The derive source's bodies ([[source body id, name], ...]) and the path they were read from.
var _bodies: Array = []
var _bodies_path := "?"


func _init(p_key := "import") -> void:
	super(p_key)


func fields() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for field in super():
		if field.key != "source":
			result.append(field)
			continue
		var info: Dictionary = field.duplicate()
		info["text"] = _note
		result.append(info)
		if key == "derive":
			for body in _source_bodies():
				result.append({"key": BODY_ROW + str(body[0]), "label": str(body[1]), "type": "bool", "default": true})
	return result


func read_values() -> Dictionary:
	_note = _describe()
	var values := super()
	if key == "mesh_import":
		values["z_up"] = _is_z_up()
	elif key == "derive":
		var chosen: Array = feature.options.get("bodies", [])
		for body in _source_bodies():
			values[BODY_ROW + str(body[0])] = chosen.is_empty() or chosen.has(body[0])
	return values


func write_values(doc: Resource, values: Dictionary) -> void:
	var rows_before := _body_rows()
	var shown := false
	var path := str(values.get("path", "")).strip_edges()
	if path != "" and not _same_path(path, str(feature.options.get("path", ""))):
		var changed := INSERT.change_source(doc, feature, path, _kernel())
		if str(changed.error) == "":
			_note = str(changed.get("note", ""))
			if changed.has("units"):
				values["units"] = changed.units
			if key == "derive":
				# Every body of the new design comes in.
				for row in rows_before:
					values.erase(row)
				for body in _source_bodies():
					values[BODY_ROW + str(body[0])] = true
			shown = true
		else:
			_note = "%s; still using %s" % [changed.error, str(feature.options.get("path", "")).get_file()]
		if workspace != null:
			workspace.panel.set_info("source", _note)
	# The path is written by change_source alone (a file that can't be read isn't taken).
	var written := values.duplicate(true)
	written["path"] = feature.options.get("path", "")
	super(doc, written)
	for row in OWN_ROWS:
		feature.options.erase(row)
	if key == "mesh_import" and bool(values.get("z_up", false)) != _is_z_up():
		feature.options["transform"] = INSERT.Z_UP if bool(values.get("z_up", false)) else Transform3D.IDENTITY
	elif key == "derive":
		shown = _write_bodies(values) or shown
	if shown and workspace != null:
		if _body_rows() != rows_before:
			# Another source design has other bodies: the panel gets their rows.
			workspace.panel.setup(title(), fields(), values, workspace.doc.units)
			workspace.place_panel()
		else:
			workspace.panel.set_values(values)


## Choose File...: the picked file goes into the File row, as if typed.
func on_button(button: String) -> void:
	if button != "browse" or workspace == null:
		return
	workspace.files.choose_file("Choose the File for %s" % feature.label, FILTERS.get(key, []), func(path: String) -> void:
		if workspace.command != self:
			return
		var values: Dictionary = workspace.command_values.duplicate(true)
		values["path"] = path
		workspace.set_command_values(values))


# --- Helpers ---------------------------------------------------------------------------------

## Derive's body rows into options.bodies (every row ticked = all bodies, also ones the source
## gains later). At least one stays ticked. Returns true when values were changed here.
func _write_bodies(values: Dictionary) -> bool:
	for k in feature.options.keys():
		if str(k).begins_with(BODY_ROW):
			feature.options.erase(k)
	var all := _source_bodies()
	if all.is_empty():
		return false
	var chosen := []
	for body in all:
		if bool(values.get(BODY_ROW + str(body[0]), true)):
			chosen.append(body[0])
	if chosen.is_empty():
		# A derive brings in something: the bodies it had stay ticked.
		var kept: Array = feature.options.get("bodies", [])
		for body in all:
			values[BODY_ROW + str(body[0])] = kept.is_empty() or kept.has(body[0])
		_note = "A derive needs at least one body"
		if workspace != null:
			workspace.panel.set_info("source", _note)
		return true
	feature.options["bodies"] = [] if chosen.size() == all.size() else chosen
	return false


## The source design's bodies as [[source body id, name], ...] (derive), read again when the
## path changes ([] when the design can't be read).
func _source_bodies() -> Array:
	if key != "derive" or feature == null:
		return []
	var path := INSERT.clean_path(str(feature.options.get("path", "")))
	if path == _bodies_path:
		return _bodies
	_bodies_path = path
	_bodies = []
	var kernel := _kernel()
	if path == "" or kernel == null:
		return _bodies
	var source := INSERT.source_bodies(path, kernel)
	for id in (source.get("bodies", {}) as Dictionary):
		_bodies.append([str(id), str(source.bodies[id].name)])
	return _bodies


func _body_rows() -> Array:
	return _source_bodies().map(func(body: Array) -> String: return BODY_ROW + str(body[0]))


func _is_z_up() -> bool:
	return (feature.options.get("transform", Transform3D.IDENTITY) as Transform3D).is_equal_approx(INSERT.Z_UP)


## Derive paths compare in one spelling (res:// inside the project); file paths as typed.
func _same_path(a: String, b: String) -> bool:
	return INSERT.clean_path(a) == INSERT.clean_path(b) if key == "derive" else a == b


## The Source row when the panel opens.
func _describe() -> String:
	var file := str(feature.options.get("path", "")).get_file()
	match key:
		"import":
			return "%s (%s)" % [file, "linked: read again on every rebuild" if bool(feature.options.get("linked", false)) else "a copy is kept in the design"]
		"mesh_import":
			return "%s: %d triangles" % [file, int((feature.options.get("indices", PackedInt32Array()) as PackedInt32Array).size() / 3.0)]
		"derive":
			return "%s: %d body(ies)" % [file, _source_bodies().size()]
	return file


func _kernel() -> RefCounted:
	if workspace != null and workspace.kernel != null:
		return workspace.kernel
	if _own_kernel == null:
		_own_kernel = load(REGEN_PATH).make_kernel()
	return _own_kernel
