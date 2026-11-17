@tool
extends RefCounted
## Gets Holo Forge designs out of the Forge: CAD exchange files (STEP, IGES, STL, BREP) from the
## kernel, every baked body as its own mesh .res, every component as its own scene (.tscn or
## .glb), and versioned board-model saves.
##
## Board models follow AGENTS.md: they go to the Updated board models folder (outside the
## project) as <name>/<name>_v<NNN>.<ext>, never overwriting a revision, and each save adds one
## provenance record per written file to that folder's board_models_manifest.json, in the
## manifest's own per-file style. Copies for the game go to assets/board_models only when
## integration is asked for, so nothing here writes there.
##
## Exported .tscn files hold their own geometry: a mesh the scene keeps in a file of its own (the
## <scene>_forge/*.res files CadPart writes on every scene save) is embedded, because the next bake
## and save rewrites that file and would otherwise change every scene exported earlier.
## glTF has no decals, so a .glb leaves them out and says so.
##
## Mesh bodies (core/mesh/mesh_body.gd) in export_cad: STL, OBJ and 3MF hold their very triangles
## (CadMesh.get_arrays, in millimeters), not a new tessellation; STEP, IGES and BREP can't hold
## them, so they are left out and named (the other bodies still export). OBJ and 3MF hold mesh
## bodies only. export_cad_report() says which bodies were written and which were left out.
## With no bodies picked and the design given, hidden bodies are left out and named (a mesh body
## that Convert Mesh turned into a solid stays in the design, hidden, under the solid).
##
## Assemblies (Phase 8, spec C8.6): with the design given, export_cad writes every body where the
## assembly places it (the posed view), moved in doubles (kernel.transform_shape64 /
## CadMesh.transformed64; the float32 kernel.transform_shape / MESH.transformed only with a native
## build that lacks them, _posed_shape), and
## its report says so (S-EXPORT-POSED). Without an assembly (or with every pose at identity) the
## files are byte for byte what they were. Scene exports (.glb) carry the posed nodes but no
## joints (a .tscn keeps them: it is a working Godot scene).

const DOCUMENT := preload("res://addons/holo_forge/core/document.gd")
const REGEN := preload("res://addons/holo_forge/core/regen.gd")
const MESH_BODY := preload("res://addons/holo_forge/core/mesh/mesh_body.gd")
const MESH_BLOB := preload("res://addons/holo_forge/core/mesh/mesh_blob.gd")
const MESH := preload("res://addons/holo_forge/core/features/mesh.gd")
const SOLVER := preload("res://addons/holo_forge/core/assembly/solver.gd")
const XFORM := preload("res://addons/holo_forge/core/assembly/xform64.gd")
const ASSEMBLY_DATA := preload("res://addons/holo_forge/core/assembly/assembly_data.gd")

## The project setting naming the folder that Save Board Model Version saves into (an absolute
## folder or a res:// one; see that folder's README.md and manifest). Empty: nothing is saved, and
## the error says where to set it (Project Settings > Holo Forge > Export).
const BOARD_MODELS_SETTING := "holo_forge/export/board_models_folder"
const S_NO_BOARD_FOLDER := "No board models folder is set. Set one in Project Settings > Holo Forge > Export > Board Models Folder."
const MANIFEST_NAME := "board_models_manifest.json"
## Used when a board-model root has no manifest yet (the same wording as the real one).
const MANIFEST_POLICY := "Save future updated board models here. Keep versioned revisions. Godot runtime exports remain in assets/board_models."
## Kernel formats: STEP, IGES and STL are written in millimeters, BREP in meters.
const CAD_FORMATS := ["step", "stp", "iges", "igs", "stl", "brep"]
## Formats export_cad writes for mesh bodies only (a B-rep body is left out of them and named).
const MESH_ONLY_FORMATS := ["obj", "3mf"]
## Millimeters per meter: STL, OBJ and 3MF are written in millimeters.
const MESH_FILE_SCALE := 1000.0
const B_REP_ONLY := "%s is a B-rep body; OBJ and 3MF hold mesh bodies only. Tessellate it first, or export STEP/IGES/STL."
const SCENE_FORMATS := ["tscn", "glb"]
## "tres" is a copy of the CadDocument: the editable source.
const BOARD_FORMATS := ["glb", "tscn", "tres", "step", "stp", "iges", "igs", "stl", "brep"]
## Metadata CadPart puts on baked nodes (as in nodes/cad_part.gd; not preloaded, so the part can
## preload this file).
const BODY_META := "holo_forge_body"
const COMPONENT_META := "holo_forge_component"
const DECAL_META := "holo_forge_decal"
const BAKE_META := "holo_forge_bake"
## Metadata of the RigidBody3D bake (nodes/cad_part.gd, core/assembly/bake_joints.gd).
const GROUND_META := "holo_forge_ground"
const SHAPE_META := "holo_forge_shape"
const JOINTS_META := "holo_forge_joints"
const JOINT_META := "holo_forge_joint"
## A body pose this close to identity (m, rad) is written where it was modelled (C8.6).
const IDENTITY_TOLERANCE := 1e-12
## Windows device names (lower case): no file or folder can have one as its name before the first
## dot, whatever the extension.
const RESERVED_NAMES := ["con", "prn", "aux", "nul", "conin$", "conout$",
	"com0", "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8", "com9", "com¹", "com²", "com³",
	"lpt0", "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9", "lpt¹", "lpt²", "lpt³"]
## The folder (inside a board's folder) a board-model save writes into before moving the files in.
const STAGING_PREFIX := ".holo_forge_saving_"


## Writes bodies of a regen result to one CAD exchange file, picked by the path's extension:
## .step/.stp/.iges/.igs/.stl (millimeters) or .brep (meters); .obj and .3mf (millimeters) for mesh
## bodies. body_ids picks the bodies (empty: all of them). Returns "" on success, otherwise the
## problem. A file written without some of the bodies (mesh bodies can't go into STEP, IGES or
## BREP; B-rep bodies can't go into OBJ or 3MF) is a problem too: the text names them and says
## what was written (export_cad_report() gives the lists). doc: for the bodies' names in that text
## (their ids without it).
static func export_cad(kernel: RefCounted, result: Dictionary, body_ids: Array, path: String, doc: Resource = null) -> String:
	var report := export_cad_report(kernel, result, body_ids, path, doc)
	return str(report.error) if str(report.error) != "" else str(report.note)


## export_cad() with the lists: {"error": "" or why no file was written, "written": the body ids
## in the file, "skipped": the body ids the format can't hold, "hidden": the hidden body ids left
## out, "note": "" or the sentences naming the skipped and the hidden bodies}.
## Hidden bodies: with body_ids empty (every body) and doc given, the bodies doc.body_visible()
## hides are left out, unless include_hidden; picked bodies are exported whether hidden or not.
static func export_cad_report(kernel: RefCounted, result: Dictionary, body_ids: Array, path: String, doc: Resource = null, include_hidden := false) -> Dictionary:
	var out := {"error": "", "written": [], "skipped": [], "hidden": [], "note": ""}
	if kernel == null:
		out.error = "The Holo Forge kernel is not loaded"
		return out
	var ext := path.get_extension().to_lower()
	if not CAD_FORMATS.has(ext) and not MESH_ONLY_FORMATS.has(ext):
		out.error = "Holo Forge can't export .%s files (use STEP, IGES, STL or BREP; OBJ and 3MF for mesh bodies)" % ext
		return out
	if _is_reserved(path.get_file()):
		out.error = "%s is a Windows device name, so no file can be called %s; choose another name" % [
			path.get_file().get_slice(".", 0), path.get_file()]
		return out
	var bodies: Dictionary = result.get("bodies", {})
	var ids: Array = body_ids if not body_ids.is_empty() else bodies.keys()
	var hidden := []
	if body_ids.is_empty() and doc != null and not include_hidden:
		# Nothing picked: what the view shows. Hidden bodies stay out, and are named below.
		var shown := []
		for body_id in ids:
			if doc.body_visible(str(body_id)):
				shown.append(body_id)
			else:
				hidden.append(str(body_id))
		if shown.is_empty() and not hidden.is_empty():
			out.hidden = hidden
			out.error = "Every body is hidden, so nothing was exported. Show the bodies to export, or pick them."
			return out
		ids = shown
	out.hidden = hidden
	# Where the assembly places the bodies (C8.6); the result's own bodies without one.
	var posed := posed_bodies(kernel, result, ids, doc)
	if str(posed.error) != "":
		out.error = str(posed.error)
		return out
	bodies = posed.bodies
	var shapes := []
	var meshes := []
	var breps := []
	for body_id in ids:
		var body: Dictionary = bodies.get(str(body_id), {})
		var shape: RefCounted = body.get("shape")
		if shape == null or shape.is_null():
			out.error = "Body %s is not in the design" % body_id
			return out
		shapes.append(shape)
		if MESH_BODY.is_mesh(body):
			meshes.append(str(body_id))
		else:
			breps.append(str(body_id))
	if shapes.is_empty():
		out.error = "There are no bodies to export"
		return out
	# Which bodies the format can hold.
	var written: Array = ids.map(func(id: Variant) -> String: return str(id))
	var skipped := []
	var notes := PackedStringArray()
	if MESH_ONLY_FORMATS.has(ext):
		written = meshes
		skipped = breps
		for body_id in skipped:
			notes.append(B_REP_ONLY % MESH_BODY.body_name(doc, body_id))
		if written.is_empty():
			out.error = "Holo Forge can't export B-rep bodies as .%s (use STEP, IGES, STL or BREP, or Tessellate them first)" % ext
			return out
	elif ext != "stl":
		written = breps
		skipped = meshes
		for body_id in skipped:
			notes.append(MESH_BODY.EXPORT_GATE % MESH_BODY.body_name(doc, body_id))
		if written.is_empty():
			out.error = " ".join(notes)
			out.skipped = skipped
			return out
	var error := _make_folder(path.get_base_dir())
	if error != "":
		out.error = error
		return out
	var mesh_parts := []
	for body_id in written:
		if meshes.has(body_id):
			mesh_parts.append(_mesh_part(bodies[body_id].shape, MESH_BODY.body_name(doc, body_id)))
	if mesh_parts.is_empty():
		# B-rep bodies only: the kernel writes the file, as ever.
		var brep_shapes := written.map(func(id: String) -> RefCounted: return bodies[id].shape)
		if not kernel.export_file(brep_shapes, ProjectSettings.globalize_path(path)):
			var reason: String = kernel.get_last_error()
			out.error = "Exporting %s failed%s" % [path.get_file(), (": " + reason) if reason != "" else ""]
			return out
	else:
		match ext:
			"stl":
				var solid_shapes := []
				for body_id in written:
					if breps.has(body_id):
						solid_shapes.append(bodies[body_id].shape)
				error = _write_stl(kernel, solid_shapes, mesh_parts, path)
			"obj":
				error = _write_obj(mesh_parts, path)
			"3mf":
				error = _write_3mf(mesh_parts, path)
		if error != "":
			out.error = error
			return out
	if not FileAccess.file_exists(path):
		out.error = "Exporting %s wrote no file" % path.get_file()
		return out
	out.written = written
	out.skipped = skipped
	if not skipped.is_empty():
		notes.append("The other %d bod%s exported to %s." % [written.size(), "y was" if written.size() == 1 else "ies were", path.get_file()])
	if not hidden.is_empty():
		var names := PackedStringArray()
		for body_id in hidden:
			names.append(MESH_BODY.body_name(doc, body_id))
		notes.append("Hidden bod%s left out: %s (pick a hidden body to export it)." % ["y" if hidden.size() == 1 else "ies", ", ".join(names)])
	if bool(posed.posed):
		notes.append(ASSEMBLY_DATA.S_EXPORT_POSED)
	out.note = " ".join(notes)
	return out


## The bodies of result with those of ids moved where doc's assembly places them (C8.6):
## {"bodies": result.bodies with each moved body's entry a copy holding the moved shape, "posed":
## true when any body of ids moved, "error": "" or why a body could not be moved}. Without doc or
## an assembly, or with every pose at identity, "bodies" is result.bodies itself.
static func posed_bodies(kernel: RefCounted, result: Dictionary, ids: Array, doc: Resource) -> Dictionary:
	var bodies: Dictionary = result.get("bodies", {})
	var out := {"bodies": bodies, "posed": false, "error": ""}
	var assembly: Variant = doc.get("assembly") if doc != null else null
	if not (assembly is Dictionary) or (assembly as Dictionary).is_empty():
		return out
	var body_poses: Dictionary = SOLVER.solve(doc, result, kernel).body_poses
	var moved := {}
	for body_id in ids:
		var pose: Variant = body_poses.get(str(body_id))
		# (A pose within rounding of identity, as an as-built joint at 0 gives, is no move.)
		if not (pose is PackedFloat64Array) or (XFORM.distance(pose, XFORM.identity()) <= IDENTITY_TOLERANCE
				and XFORM.angle_between(pose, XFORM.identity()) <= IDENTITY_TOLERANCE):
			continue
		var body: Dictionary = bodies.get(str(body_id), {})
		var shape: RefCounted = body.get("shape")
		if shape == null:
			continue
		var mesh := MESH_BODY.is_mesh(body)
		var placed := _posed_shape(kernel, shape, mesh, pose)
		if placed == null or placed.is_null():
			# (A mesh says why on itself, the B-rep kernel on the kernel.)
			var teller: Object = shape if mesh else kernel
			var why := str(teller.call("get_last_error")) if teller != null and teller.has_method("get_last_error") else ""
			out.error = "%s could not be moved where the assembly places it%s" % [MESH_BODY.body_name(doc, str(body_id)), (": " + why) if why != "" else ""]
			return out
		var entry := body.duplicate()
		entry["shape"] = placed
		moved[str(body_id)] = entry
	if moved.is_empty():
		return out
	var all := bodies.duplicate()
	all.merge(moved, true)
	out.bodies = all
	out.posed = true
	return out


## shape (a B-rep CadShape, or a CadMesh when mesh) moved by pose (xform64) for a posed export, in
## doubles (fix round 1, B4: STEP, IGES and BREP are double formats, and a float32 Transform3D is
## millimetres off 100 km out): CadKernel.transform_shape64 / CadMesh.transformed64 take the 12
## doubles as they are. A native build without them moves through the float32 Transform3D as
## before. Null (or a null shape) when the kernel refuses.
static func _posed_shape(kernel: RefCounted, shape: RefCounted, mesh: bool, pose: PackedFloat64Array) -> RefCounted:
	if mesh:
		if shape.has_method("transformed64"):
			return shape.call("transformed64", pose)
		return MESH.transformed(shape, XFORM.to_transform(pose))
	if kernel == null:
		return null
	if kernel.has_method("transform_shape64"):
		return kernel.call("transform_shape64", shape, pose, "posed")
	return kernel.transform_shape(shape, XFORM.to_transform(pose), "posed")


## A mesh body's triangles for a mesh file: {"name", "positions" (millimeters), "indices" (Godot's
## clockwise winding), "groups", "group_names"}.
static func _mesh_part(mesh: RefCounted, name: String) -> Dictionary:
	var arrays: Dictionary = mesh.get_arrays()
	var positions: PackedVector3Array = arrays.positions
	return {
		"name": name, "positions": Transform3D(Basis.from_scale(Vector3.ONE * MESH_FILE_SCALE), Vector3.ZERO) * positions,
		"indices": arrays.indices, "groups": arrays.get("groups", PackedInt32Array()), "group_names": arrays.get("group_names", PackedStringArray()),
	}


## One binary STL (millimeters) of mesh bodies' own triangles and, when there are any, the
## kernel's STL of the B-rep bodies (written to a file beside it first, read back and added).
## STL lists corners counter-clockwise seen from outside. Returns "" or the problem.
static func _write_stl(kernel: RefCounted, brep_shapes: Array, parts: Array, path: String) -> String:
	var all := parts.duplicate()
	if not brep_shapes.is_empty():
		var beside := path.get_basename() + ".holo_forge_brep_part.stl"
		if not kernel.export_file(brep_shapes, ProjectSettings.globalize_path(beside)):
			var reason: String = kernel.get_last_error()
			return "Exporting %s failed%s" % [path.get_file(), (": " + reason) if reason != "" else ""]
		var read: RefCounted = MESH_BODY.new_mesh()
		var ok: bool = read != null and read.read_stl(beside, 1.0)
		DirAccess.remove_absolute(ProjectSettings.globalize_path(beside))
		if not ok:
			return "Exporting %s failed: the B-rep bodies' triangles could not be added (%s)" % [path.get_file(), read.get_last_error() if read != null else MESH_BODY.KERNEL_MISSING]
		var arrays: Dictionary = read.get_arrays()
		all.push_front({"name": "solids", "positions": arrays.positions, "indices": arrays.indices})
	var count := 0
	for part in all:
		count += int((part.indices as PackedInt32Array).size() / 3.0)
	var data := PackedByteArray()
	data.resize(84 + 50 * count)
	var header := "Holo Forge STL (millimeters)".to_ascii_buffer()
	for i in header.size():
		data[i] = header[i]
	data.encode_u32(80, count)
	var at := 84
	for part in all:
		var positions: PackedVector3Array = part.positions
		var indices: PackedInt32Array = part.indices
		for t in range(0, indices.size() - 2, 3):
			# Counter-clockwise: Godot's order with the last two corners swapped.
			var a := positions[indices[t]]
			var b := positions[indices[t + 2]]
			var c := positions[indices[t + 1]]
			var n := (b - a).cross(c - a).normalized()
			data.encode_float(at, n.x)
			data.encode_float(at + 4, n.y)
			data.encode_float(at + 8, n.z)
			data.encode_float(at + 12, a.x)
			data.encode_float(at + 16, a.y)
			data.encode_float(at + 20, a.z)
			data.encode_float(at + 24, b.x)
			data.encode_float(at + 28, b.y)
			data.encode_float(at + 32, b.z)
			data.encode_float(at + 36, c.x)
			data.encode_float(at + 40, c.y)
			data.encode_float(at + 44, c.z)
			at += 50
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return "Could not write %s (%s)" % [path.get_file(), error_string(FileAccess.get_open_error())]
	file.store_buffer(data)
	file.close()
	return ""


## An OBJ file (millimeters) of mesh bodies: an object per body, a group per face group, corners
## counter-clockwise. Returns "" or the problem.
static func _write_obj(parts: Array, path: String) -> String:
	var lines := PackedStringArray(["# Holo Forge OBJ (millimeters)"])
	var offset := 1
	for part in parts:
		var positions: PackedVector3Array = part.positions
		var indices: PackedInt32Array = part.indices
		var groups: PackedInt32Array = part.groups
		var names: PackedStringArray = part.group_names
		lines.append("o %s" % _obj_name(str(part.name)))
		for p in positions:
			lines.append("v %s %s %s" % [String.num(p.x, 6), String.num(p.y, 6), String.num(p.z, 6)])
		# Each group's triangles together, so a reader sees every group once.
		var by_group := {}
		var triangles := int(indices.size() / 3.0)
		for t in triangles:
			var g := groups[t] if t < groups.size() else 0
			# (Arrays are shared references; a packed array in a dictionary would be changed as a copy.)
			if not by_group.has(g):
				by_group[g] = []
			(by_group[g] as Array).append(t)
		var order: Array = by_group.keys()
		order.sort()
		for g in order:
			lines.append("g %s" % _obj_name(str(names[g]) if g >= 0 and g < names.size() else "g%d" % g))
			for t in by_group[g]:
				lines.append("f %d %d %d" % [indices[t * 3] + offset, indices[t * 3 + 2] + offset, indices[t * 3 + 1] + offset])
		offset += positions.size()
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return "Could not write %s (%s)" % [path.get_file(), error_string(FileAccess.get_open_error())]
	file.store_string("\n".join(lines) + "\n")
	file.close()
	return ""


## A name as one OBJ word.
static func _obj_name(text: String) -> String:
	var clean := text.strip_edges().replace(" ", "_").replace("\t", "_").replace("\n", "_").replace("\r", "_")
	return clean if clean != "" else "mesh"


## A 3MF package (millimeters) of mesh bodies: one object per body, each a build item, corners
## counter-clockwise. Returns "" or the problem.
static func _write_3mf(parts: Array, path: String) -> String:
	var model := PackedStringArray([
		"<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
		"<model unit=\"millimeter\" xml:lang=\"en-US\" xmlns=\"http://schemas.microsoft.com/3dmanufacturing/core/2015/02\">",
		" <metadata name=\"Application\">Holo Forge</metadata>",
		" <resources>",
	])
	for k in parts.size():
		var part: Dictionary = parts[k]
		var positions: PackedVector3Array = part.positions
		var indices: PackedInt32Array = part.indices
		model.append("  <object id=\"%d\" type=\"model\" name=\"%s\">" % [k + 1, str(part.name).xml_escape(true)])
		model.append("   <mesh>")
		model.append("    <vertices>")
		for p in positions:
			model.append("     <vertex x=\"%s\" y=\"%s\" z=\"%s\"/>" % [String.num(p.x, 6), String.num(p.y, 6), String.num(p.z, 6)])
		model.append("    </vertices>")
		model.append("    <triangles>")
		for t in range(0, indices.size() - 2, 3):
			model.append("     <triangle v1=\"%d\" v2=\"%d\" v3=\"%d\"/>" % [indices[t], indices[t + 2], indices[t + 1]])
		model.append("    </triangles>")
		model.append("   </mesh>")
		model.append("  </object>")
	model.append(" </resources>")
	model.append(" <build>")
	for k in parts.size():
		model.append("  <item objectid=\"%d\"/>" % (k + 1))
	model.append(" </build>")
	model.append("</model>")
	var files := {
		"[Content_Types].xml": "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">\n <Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>\n <Default Extension=\"model\" ContentType=\"application/vnd.ms-package.3dmanufacturing-3dmodel+xml\"/>\n</Types>\n",
		"_rels/.rels": "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\n <Relationship Target=\"/3D/3dmodel.model\" Id=\"rel0\" Type=\"http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel\"/>\n</Relationships>\n",
		"3D/3dmodel.model": "\n".join(model) + "\n",
	}
	var zip := ZIPPacker.new()
	var opened := zip.open(ProjectSettings.globalize_path(path))
	if opened != OK:
		return "Could not write %s (%s)" % [path.get_file(), error_string(opened)]
	for name in files:
		var failed := zip.start_file(name)
		if failed == OK:
			failed = zip.write_file(str(files[name]).to_utf8_buffer())
		if failed == OK:
			failed = zip.close_file()
		if failed != OK:
			zip.close()
			return "Could not write %s (%s)" % [path.get_file(), error_string(failed)]
	zip.close()
	return ""


## Saves each baked body's mesh as its own compressed .res in folder, named after the body node
## ("Deck.res"). Returns the written paths in tree order.
static func export_body_meshes(part: Node3D, folder: String) -> Array:
	var written := []
	var error := _make_folder(folder)
	if error != "":
		push_error("Holo Forge: " + error)
		return written
	var used := {}
	var nodes: Dictionary = part.body_nodes()
	for body_id in nodes:
		var body: MeshInstance3D = nodes[body_id]
		if body.mesh == null:
			continue
		var path := folder.path_join(_unique_file(str(body.name), "res", used))
		var saved := ResourceSaver.save(body.mesh, path, ResourceSaver.FLAG_COMPRESS)
		if saved == OK:
			written.append(path)
		else:
			push_error("Holo Forge: saving %s failed (%s)." % [path, error_string(saved)])
	return written


## Saves every component (part.component_nodes(), nested components included in their parent's
## scene too) and the top level (the bodies directly under the part, as a scene named after the
## part) as its own scene: format "tscn" (a PackedScene holding its own meshes) or "glb" (without
## decals, which glTF can't hold; a warning names them). The copies are plain nodes (no Forge
## metadata), so an exported scene can be used anywhere, even under a CadPart.
## Returns the written paths, top level first.
static func export_components(part: Node3D, folder: String, format := "tscn") -> Array:
	var written := []
	format = format.to_lower().trim_prefix(".")
	if not SCENE_FORMATS.has(format):
		push_error("Holo Forge: components export as .tscn or .glb, not .%s." % format)
		return written
	var error := _make_folder(folder)
	if error != "":
		push_error("Holo Forge: " + error)
		return written
	var used := {}
	var top := Node3D.new()
	top.name = _file_stem(str(part.name))
	for child in part.get_children():
		if child.has_meta(BODY_META):
			top.add_child(_plain_copy(child))
		elif child.has_meta(GROUND_META):
			# (RigidBody3D bake: the ground bodies sit under the Ground StaticBody3D.)
			for inner in child.get_children():
				if inner.has_meta(BODY_META):
					top.add_child(_plain_copy(inner))
	if top.get_child_count() > 0:
		var path := _write_scene(top, folder.path_join(_unique_file(str(top.name), format, used)), format)
		if path != "":
			written.append(path)
	else:
		top.free()
	var components: Dictionary = part.component_nodes()
	for component_id in components:
		var node: Node3D = components[component_id]
		var copy := _plain_copy(node) as Node3D
		# Keep where the component sits in the part, so exports placed together reassemble it.
		copy.transform = _transform_in(part, node)
		var path := _write_scene(copy, folder.path_join(_unique_file(str(node.name), format, used)), format)
		if path != "":
			written.append(path)
	return written


## Writes the whole baked part to path, picked by its extension: .glb/.gltf or .tscn. Every child
## of the part goes in as a plain copy under a Node3D named root_name (or after the part); a .tscn
## holds its own meshes, and a .glb leaves decals out (glTF can't hold them) with a warning.
## Returns {"path": the path ("" when writing failed), "decals_left_out": the names of the decals
## a .glb left out}.
static func export_part_scene(part: Node3D, path: String, root_name := "") -> Dictionary:
	var out := {"path": "", "decals_left_out": PackedStringArray()}
	var format := path.get_extension().to_lower()
	if not format in ["glb", "gltf", "tscn"]:
		push_error("Holo Forge: a part exports as .glb, .gltf or .tscn, not .%s." % format)
		return out
	var scene_root := Node3D.new()
	scene_root.name = root_name if root_name != "" else str(part.name)
	for child in part.get_children():
		# glTF has no joints: the Joints node stays out of a .glb (C8.4).
		if format != "tscn" and child.has_meta(JOINTS_META):
			continue
		scene_root.add_child(_plain_copy(child))
	if format != "tscn":
		out.decals_left_out = decal_names(scene_root)
	out.path = _write_scene(scene_root, path, format)
	return out


## The names of the Decal nodes under node (itself included), in tree order: what a .glb of it
## leaves out.
static func decal_names(node: Node) -> PackedStringArray:
	var names := PackedStringArray()
	if node is Decal:
		names.append(str(node.name))
	for decal in node.find_children("*", "Decal", true, false):
		names.append(str(decal.name))
	return names


## The next free revision number for base_name in folder: one more than the highest
## <base_name>_v<N>.<ext> file or <base_name>_v<N> folder there (1 when there is none).
static func next_version(folder: String, base_name: String) -> int:
	var highest := 0
	var dir := DirAccess.open(folder)
	if dir == null:
		return 1
	var names: Array = Array(dir.get_files()) + Array(dir.get_directories())
	var prefix := base_name.to_lower() + "_v"
	for entry in names:
		var name := str(entry).to_lower()
		if not name.begins_with(prefix):
			continue
		var rest := name.substr(prefix.length())
		var digits := ""
		for c in rest:
			if c < "0" or c > "9":
				break
			digits += c
		# "<base>_v2.glb" or a "<base>_v2" folder, not "<base>_v2_old.glb".
		if digits == "" or (rest.length() > digits.length() and rest[digits.length()] != "."):
			continue
		highest = maxi(highest, digits.to_int())
	return highest + 1


## The board models folder the project names (BOARD_MODELS_SETTING; "" when none is set).
static func board_models_root() -> String:
	return str(ProjectSettings.get_setting(BOARD_MODELS_SETTING, "")).strip_edges()


## Saves a versioned board model into root/<base_name>/ as <base_name>_v<NNN>.<format> for each
## format, at the next free NNN (never overwriting an earlier revision, and continuing any
## <base_name>_vN files already in root), then appends one provenance record per written file to
## root/board_models_manifest.json (created when missing). Formats: "glb" and "tscn" (the baked
## part, every body its own node; the .tscn holds its own meshes, the .glb has no decals),
## "tres" (a copy of the CadDocument, the editable source), and "step", "stp", "iges", "igs",
## "stl", "brep" (every body, through export_cad). An empty result is rebuilt from the part's
## document when a CAD format needs it. A revision is saved whole or not at all: the files are
## written to a staging folder and moved in only when every one of them was written, so a failed
## save leaves no partial revision and doesn't use up its version number.
## Returns {"paths": Array of written paths, "version": int (0 when no revision was saved),
## "error": String ("" when every format was written in full and the manifest updated; otherwise
## what failed, or what a saved revision lacks, such as the decals a .glb left out)}.
static func board_model_export(part: Node3D, kernel: RefCounted, result: Dictionary, base_name: String,
		formats: Array = ["glb", "step", "tres"], root := "") -> Dictionary:
	var out := {"paths": [], "version": 0, "error": ""}
	if root == "":
		root = board_models_root()
	if root == "":
		out.error = S_NO_BOARD_FOLDER
		return out
	var base := _file_stem(base_name, "")
	if base == "":
		base = _file_stem(str(part.name), "")
	var wanted: Array[String] = []
	for format in formats:
		var f := str(format).to_lower().trim_prefix(".")
		if not BOARD_FORMATS.has(f):
			out.error = "Board models can't be saved as .%s (use %s)" % [f, ", ".join(BOARD_FORMATS)]
			return out
		if not wanted.has(f):
			wanted.append(f)
	if base == "" or wanted.is_empty():
		out.error = "A board model needs a name and at least one format"
		return out
	var doc: Resource = part.get("document")
	var needs_cad := wanted.any(func(f: String) -> bool: return CAD_FORMATS.has(f))
	if needs_cad and (result.get("bodies", {}) as Dictionary).is_empty() and kernel != null and doc != null:
		result = REGEN.rebuild(doc, kernel)
	# Check everything before writing, so a bad request leaves no half-made revision.
	if needs_cad and kernel == null:
		out.error = "The Holo Forge kernel is not loaded, so CAD formats can't be written"
		return out
	if needs_cad and (result.get("bodies", {}) as Dictionary).is_empty():
		out.error = "The design has no bodies to save as CAD"
		return out
	if wanted.has("tres") and doc == null:
		out.error = "The part has no document to save"
		return out
	if (wanted.has("glb") or wanted.has("tscn")) and (part.body_nodes() as Dictionary).is_empty():
		out.error = "The part has no baked bodies; bake it first"
		return out

	var folder := root.path_join(base)
	var new_folder := not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(folder))
	var error := _make_folder(folder)
	if error != "":
		out.error = error
		return out
	var version := maxi(next_version(folder, base), next_version(root, base))
	while wanted.any(func(f: String) -> bool: return FileAccess.file_exists(folder.path_join("%s_v%03d.%s" % [base, version, f]))):
		version += 1

	var staging := folder.path_join("%s%d" % [STAGING_PREFIX, Time.get_ticks_usec()])
	var problem := _make_folder(staging)
	var staged: Array[String] = []
	# File name -> what it lacks.
	var notes := {}
	for f in wanted:
		if problem != "":
			break
		var file := "%s_v%03d.%s" % [base, version, f]
		var path := staging.path_join(file)
		if CAD_FORMATS.has(f):
			# Bodies the format can't hold (mesh bodies in STEP, IGES, BREP) are noted, not fatal.
			# (A board model holds every body, hidden ones too, as its .glb does.)
			var report := export_cad_report(kernel, result, [], path, doc, true)
			problem = str(report.error)
			if problem == "" and str(report.note) != "":
				notes[file] = str(report.note)
		elif f == "tres":
			var copy: Resource = DOCUMENT.new()
			copy.restore(doc.snapshot())
			# The editable source holds its own stored meshes, not links into the project.
			_embed_stored_meshes(copy)
			var saved := ResourceSaver.save(copy, path)
			if saved != OK:
				problem = "Saving %s failed (%s)" % [file, error_string(saved)]
		else:
			var written := export_part_scene(part, path, base)
			var lost: PackedStringArray = written.decals_left_out
			if str(written.path) == "":
				problem = "Writing %s failed" % file
			elif not lost.is_empty():
				notes[file] = _decal_note(lost)
		if problem == "":
			staged.append(file)
	var moved := []
	if problem == "":
		for file in staged:
			var target := folder.path_join(file)
			var renamed := DirAccess.rename_absolute(ProjectSettings.globalize_path(staging.path_join(file)), ProjectSettings.globalize_path(target))
			if renamed != OK:
				problem = "Moving %s into %s failed (%s)" % [file, folder, error_string(renamed)]
				break
			moved.append(target)
	if problem != "":
		for path in moved:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	_remove_folder(staging)
	if problem != "":
		if new_folder:
			# Only goes when empty (nothing else was ever in it).
			DirAccess.remove_absolute(ProjectSettings.globalize_path(folder))
		out.error = "%s, so no revision was saved" % problem
		return out
	out.version = version
	out.paths = moved

	var body_count := (result.get("bodies", {}) as Dictionary).size()
	if body_count == 0:
		body_count = (part.body_nodes() as Dictionary).size()
	var source := _source_info(part, folder.path_join("%s_v%03d.tres" % [base, version]) if wanted.has("tres") else "")
	var created := Time.get_datetime_string_from_system(false, true)
	var records := []
	for path in moved:
		var record := _file_record(path, str(source.source))
		record.merge({"revision": "%s_v%03d" % [base, version], "version": version, "created": created, "tool": "Holo Forge",
			"bodies": body_count})
		if str(source.part) != "":
			record["source_part"] = source.part
		if notes.has(path.get_file()):
			record["note"] = notes[path.get_file()]
		records.append(record)
	var warnings := PackedStringArray()
	for file in notes:
		warnings.append("%s: %s" % [file, notes[file]])
	var manifest_error := append_manifest_records(root, records)
	if manifest_error != "":
		warnings.append(manifest_error)
	out.error = "; ".join(warnings)
	return out


## Appends records to root/board_models_manifest.json (created when missing), one per file in the
## manifest's per-file style. The records go in as text at the end of its top-level "files" list,
## in the file's own indentation and line endings, so everything already in it (other tools'
## entries, key order, numbers) stays byte for byte. A manifest that can't be read is left alone
## (and reported).
static func append_manifest_records(root: String, records: Array) -> String:
	var path := root.path_join(MANIFEST_NAME)
	var text := ""
	if FileAccess.file_exists(path):
		var bytes := FileAccess.get_file_as_bytes(path)
		var bom := bytes.size() >= 3 and bytes[0] == 0xEF and bytes[1] == 0xBB and bytes[2] == 0xBF
		text = _with_records(bytes.slice(3 if bom else 0).get_string_from_utf8(), records)
		if text == "":
			return "%s could not be read, so it was left unchanged" % path.get_file()
		if bom:
			text = String.chr(0xFEFF) + text
	else:
		var manifest := {
			"created": Time.get_date_string_from_system(), "updated_board_models_directory": _system_path(root),
			"policy": MANIFEST_POLICY, "files": records,
		}
		text = JSON.stringify(manifest, "  ", false, true) + "\n"
		if OS.get_name() == "Windows":
			text = text.replace("\n", "\r\n")
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return "Could not write %s (%s)" % [path.get_file(), error_string(FileAccess.get_open_error())]
	file.store_string(text)
	file.close()
	return ""


# --- Helpers ---------------------------------------------------------------------------------


## A copy of a baked node and its children with the Forge metadata removed.
static func _plain_copy(node: Node) -> Node:
	var copy := node.duplicate()
	_strip(copy)
	return copy


static func _strip(node: Node) -> void:
	for key in [BODY_META, COMPONENT_META, DECAL_META, BAKE_META, GROUND_META, SHAPE_META, JOINTS_META, JOINT_META]:
		if node.has_meta(key):
			node.remove_meta(key)
	for child in node.get_children():
		_strip(child)


static func _own(node: Node, scene_root: Node) -> void:
	for child in node.get_children():
		child.owner = scene_root
		if child.scene_file_path == "":
			_own(child, scene_root)


## Packs scene_root into path (.tscn, holding its own meshes) or writes it as glTF (.glb/.gltf,
## without decals), then frees it. Every node is owned by scene_root first (instanced scenes
## inside stay instances). Returns the path, or "" when writing failed.
static func _write_scene(scene_root: Node, path: String, format: String) -> String:
	_own(scene_root, scene_root)
	var error := OK
	if format == "glb" or format == "gltf":
		# glTF has no decals: they would turn into empty nodes, so they are left out (and named).
		var lost := decal_names(scene_root)
		for decal in scene_root.find_children("*", "Decal", true, false):
			# A decal inside another one went with it.
			if is_instance_valid(decal):
				decal.get_parent().remove_child(decal)
				decal.free()
		if not lost.is_empty():
			push_warning("Holo Forge: %s: %s." % [path.get_file(), _decal_note(lost)])
		var gltf := GLTFDocument.new()
		# Hidden bodies stay in the file marked hidden, as an optional extension: the default
		# makes it required, and importers without it (other tools) then refuse the whole file.
		gltf.visibility_mode = GLTFDocument.VISIBILITY_MODE_INCLUDE_OPTIONAL
		var state := GLTFState.new()
		error = gltf.append_from_scene(scene_root, state)
		if error == OK:
			error = gltf.write_to_filesystem(state, path)
	else:
		_embed_geometry(scene_root)
		var packed := PackedScene.new()
		error = packed.pack(scene_root)
		if error == OK:
			error = ResourceSaver.save(packed, path)
	scene_root.free()
	if error != OK:
		push_error("Holo Forge: writing %s failed (%s)." % [path, error_string(error)])
		return ""
	return path


## Gives every mesh and collision shape kept in a file of its own (a scene's <scene>_forge/*.res
## meshes) a file-less copy, so a packed scene holds its own geometry instead of linking to a
## file the next bake and save rewrites. Only the copy's nodes change; instanced scenes inside
## are left as they are.
static func _embed_geometry(node: Node) -> void:
	if node is MeshInstance3D:
		var mesh_node := node as MeshInstance3D
		if _in_own_file(mesh_node.mesh):
			mesh_node.mesh = mesh_node.mesh.duplicate() as Mesh
	elif node is CollisionShape3D:
		var shape_node := node as CollisionShape3D
		if _in_own_file(shape_node.shape):
			shape_node.shape = shape_node.shape.duplicate() as Shape3D
	for child in node.get_children():
		if child.scene_file_path == "":
			_embed_geometry(child)


## Gives every stored mesh of a design copy (a MeshBlob in a feature's options) that is kept in a
## file of its own (CadPart.externalize_mesh_blobs) a file-less copy, so the design saved from it
## holds its meshes itself. Only the copy's features change: the blobs themselves never do.
static func _embed_stored_meshes(doc: Resource) -> void:
	for feature in doc.features:
		for key in feature.options:
			var value: Variant = feature.options[key]
			if value is Resource and (value as Resource).get_script() == MESH_BLOB and _in_own_file(value):
				# (A stand-in for a file that is gone holds nothing to take along.)
				feature.options[key] = (value as Resource).duplicate() if str(value.missing_file()) == "" else null


static func _in_own_file(resource: Resource) -> bool:
	return resource != null and resource.resource_path != "" and not resource.resource_path.contains("::")


## What a .glb lacks when decals were left out of it.
static func _decal_note(names: PackedStringArray) -> String:
	return "glTF can't hold decals, so %s %s left out" % [", ".join(names), "was" if names.size() == 1 else "were"]


## node's transform relative to the part (components are nested Node3Ds).
static func _transform_in(part: Node, node: Node3D) -> Transform3D:
	var t := node.transform
	var parent := node.get_parent()
	while parent != null and parent != part:
		if parent is Node3D:
			t = (parent as Node3D).transform * t
		parent = parent.get_parent()
	return t


## The manifest record of one written file, in the manifest's per-file style (file, source,
## destination, bytes, sha256, verified). "verified" means the file was read back from disk to get
## its size and hash.
static func _file_record(path: String, source: String) -> Dictionary:
	var bytes := 0
	var file := FileAccess.open(path, FileAccess.READ)
	if file != null:
		bytes = file.get_length()
		file.close()
	var sha := FileAccess.get_sha256(path).to_upper()
	return {
		"file": path.get_file(), "source": source, "destination": _system_path(path), "bytes": bytes, "sha256": sha,
		"verified": bytes > 0 and sha != "",
	}


## Where the design came from, as a file path: {"source": its saved document, else the scene the
## part sits in (then "part" is the part's node path in it), else the part's own scene, else (a
## design never saved) revision_tres, the editable copy saved with the revision ("" without one);
## "part": String}.
static func _source_info(part: Node, revision_tres := "") -> Dictionary:
	var doc: Resource = part.get("document")
	if doc != null and doc.resource_path != "" and not doc.resource_path.contains("::"):
		return {"source": _system_path(doc.resource_path), "part": ""}
	var scene_root := part.owner
	if scene_root != null and scene_root.scene_file_path != "":
		return {"source": _system_path(scene_root.scene_file_path), "part": str(scene_root.get_path_to(part))}
	if part.scene_file_path != "":
		return {"source": _system_path(part.scene_file_path), "part": ""}
	return {"source": _system_path(revision_tres) if revision_tres != "" else "", "part": ""}


## An absolute path in the system's own style (backslashes on Windows, like the manifest).
static func _system_path(path: String) -> String:
	var system := ProjectSettings.globalize_path(path)
	return system.replace("/", "\\") if OS.get_name() == "Windows" else system


static func _make_folder(folder: String) -> String:
	var system := ProjectSettings.globalize_path(folder)
	if not DirAccess.dir_exists_absolute(system):
		DirAccess.make_dir_recursive_absolute(system)
	if not DirAccess.dir_exists_absolute(system):
		return "Could not create the folder %s" % folder
	return ""


## Deletes a folder this file made (a board-model staging folder) with everything in it.
static func _remove_folder(folder: String) -> void:
	var system := ProjectSettings.globalize_path(folder)
	var dir := DirAccess.open(system)
	if dir == null:
		return
	for file in dir.get_files():
		DirAccess.remove_absolute(system.path_join(file))
	for sub in dir.get_directories():
		_remove_folder(system.path_join(sub))
	DirAccess.remove_absolute(system)


static func _file_stem(text: String, fallback := "Body") -> String:
	# Windows drops trailing dots and spaces, and a "." or ".." name would step out of the folder.
	var clean := text.strip_edges().validate_filename().rstrip(". ")
	if clean == "":
		return fallback
	# A device name (CON, aux, Nul.v2, COM1, ...) can't be a file or folder: "CON_", "Nul_.v2".
	if _is_reserved(clean):
		var dot := clean.find(".")
		clean = clean + "_" if dot < 0 else clean.insert(dot, "_")
	return clean


## Whether Windows treats a file or folder name as a device: its part before the first dot (any
## case, spaces around it ignored) is one of RESERVED_NAMES.
static func _is_reserved(file: String) -> bool:
	return RESERVED_NAMES.has(file.get_slice(".", 0).strip_edges().to_lower())


## "<stem>.<ext>", with _2, _3, ... added when another file of this export already has the name.
static func _unique_file(name: String, ext: String, used: Dictionary) -> String:
	var stem := _file_stem(name)
	var candidate := stem
	var n := 1
	while used.has(candidate.to_lower()):
		n += 1
		candidate = "%s_%d" % [stem, n]
	used[candidate.to_lower()] = true
	return "%s.%s" % [candidate, ext]


# --- Manifest text ---------------------------------------------------------------------------


## text (a manifest) with records added at the end of its top-level "files" array, written in the
## file's own indentation and line endings with full-precision numbers; "" when text isn't a
## manifest (not JSON, or no top-level "files" array).
static func _with_records(text: String, records: Array) -> String:
	var parsed: Variant = JSON.parse_string(text)
	if not parsed is Dictionary or not (parsed as Dictionary).get("files") is Array:
		return ""
	var before := ((parsed as Dictionary).files as Array).size()
	var span := _files_span(text)
	if span.is_empty():
		return ""
	var open := span[0]
	var close := span[1]
	var nl := "\r\n" if text.contains("\r\n") else "\n"
	var pretty := text.contains("\n")
	# The "files" key sits one indent in, so its line's indent is the file's indent unit.
	var key_indent := _line_indent(text, open)
	var unit := key_indent if key_indent != "" else "  "
	var last := _skip_space_back(text, close - 1)
	var empty := last == open
	var item_indent := key_indent + unit
	if not empty:
		var first := _skip_space(text, open + 1)
		if _starts_line(text, first):
			item_indent = _line_indent(text, first)
	var pieces := PackedStringArray()
	for record in records:
		if pretty:
			var lines := JSON.stringify(record, unit, false, true).split("\n")
			pieces.append(item_indent + (nl + item_indent).join(lines))
		else:
			pieces.append(JSON.stringify(record, "", false, true))
	var separator := ("," + nl) if pretty else ","
	var joined := separator.join(pieces)
	var updated := ""
	if empty:
		var body := (nl + joined + nl + key_indent) if pretty else joined
		updated = text.substr(0, open + 1) + body + text.substr(close)
	else:
		updated = text.substr(0, last + 1) + separator + joined + text.substr(last + 1)
	# Only write what reads back as the same manifest plus the records.
	var check: Variant = JSON.parse_string(updated)
	if not check is Dictionary or not (check as Dictionary).get("files") is Array \
			or ((check as Dictionary).files as Array).size() != before + records.size():
		return ""
	return updated


## Where the top-level "files" array of a JSON object text is: [index of its "[", index of its
## "]"], or empty when there is none.
static func _files_span(text: String) -> PackedInt32Array:
	var n := text.length()
	var depth := 0
	var open := -1
	var i := 0
	while i < n:
		var c := text.unicode_at(i)
		if c == 34: # "
			var end := _string_end(text, i)
			if end < 0:
				return PackedInt32Array()
			if depth == 1 and open < 0 and text.substr(i + 1, end - i - 1) == "files":
				var colon := _skip_space(text, end + 1)
				if colon < n and text.unicode_at(colon) == 58: # :
					var value := _skip_space(text, colon + 1)
					if value < n and text.unicode_at(value) == 91: # [
						open = value
						i = value
						continue
			i = end + 1
			continue
		if c == 123 or c == 91: # { [
			depth += 1
		elif c == 125 or c == 93: # } ]
			depth -= 1
			if c == 93 and open >= 0 and depth == 1:
				return PackedInt32Array([open, i])
		i += 1
	return PackedInt32Array()


## The index of the quote that ends the JSON string starting at text[start], or -1.
static func _string_end(text: String, start: int) -> int:
	var i := start + 1
	while i < text.length():
		var c := text.unicode_at(i)
		if c == 92: # backslash: skip the escaped character
			i += 2
			continue
		if c == 34:
			return i
		i += 1
	return -1


static func _is_space(c: int) -> bool:
	return c == 32 or c == 9 or c == 10 or c == 13


## The first index from i on that isn't JSON whitespace.
static func _skip_space(text: String, i: int) -> int:
	while i < text.length() and _is_space(text.unicode_at(i)):
		i += 1
	return i


## The last index from i back that isn't JSON whitespace (-1 when there is none).
static func _skip_space_back(text: String, i: int) -> int:
	while i >= 0 and _is_space(text.unicode_at(i)):
		i -= 1
	return i


## The index where the line holding text[index] starts.
static func _line_start(text: String, index: int) -> int:
	var i := index - 1
	while i >= 0 and text.unicode_at(i) != 10:
		i -= 1
	return i + 1


## The spaces and tabs the line holding text[index] starts with.
static func _line_indent(text: String, index: int) -> String:
	var start := _line_start(text, index)
	var i := start
	while i < text.length() and (text.unicode_at(i) == 32 or text.unicode_at(i) == 9):
		i += 1
	return text.substr(start, i - start)


## Whether only spaces and tabs come before text[index] on its line.
static func _starts_line(text: String, index: int) -> bool:
	return _line_start(text, index) + _line_indent(text, index).length() == index
