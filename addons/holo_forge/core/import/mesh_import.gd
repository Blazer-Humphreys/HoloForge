@tool
extends RefCounted
## Insert Mesh: triangle meshes from STL (ASCII and binary), OBJ, 3MF and glTF/GLB files.
##
## Every reader returns {"positions": PackedVector3Array (meters, after the units scale),
## "indices": PackedInt32Array (Godot's clockwise winding), "triangles": int, "error": String
## ("" when it worked)}; the 3MF reader adds "file_units" (the unit the file declares). Duplicate
## vertices are welded (STL repeats every corner) so a closed mesh stays closed, and triangles
## that collapse to a line are dropped. No axis is changed: a Z-up file stays Z-up (give the
## feature a transform to stand it up).

const UNITS := preload("res://addons/holo_forge/core/units.gd")

const EXTENSIONS := ["stl", "obj", "3mf", "glb", "gltf"]
## Units a mesh file may use besides the document ones.
const EXTRA_UNITS := {"um": 1e-6}
## A 3MF model's unit attribute as a unit name.
const UNITS_3MF := {"micron": "um", "millimeter": "mm", "centimeter": "cm", "inch": "in", "foot": "ft", "meter": "m"}
## The relationship type that marks a 3MF package's model part.
const MODEL_RELATIONSHIP_3MF := "/3dmodel"
## 3MF objects that aren't part of the print (supports) stay out.
const SKIPPED_3MF_TYPES := ["support", "solidsupport", "other"]
const MAX_COMPONENT_DEPTH := 32


## Meters per file unit: um, mm, cm, m, in, ft (unknown units read as meters).
static func unit_scale(units: String) -> float:
	if EXTRA_UNITS.has(units):
		return float(EXTRA_UNITS[units])
	return float(UNITS.LENGTH_UNITS.get(units, 1.0))


## Reads any supported mesh file by its extension. A 3MF file says its own unit: units "" keeps
## it, any other unit overrides it.
static func read_file(path: String, units := "m") -> Dictionary:
	match path.get_extension().to_lower():
		"stl":
			return read_stl(path, units)
		"obj":
			if not FileAccess.file_exists(path):
				return _failed("%s can't be found" % path.get_file())
			return read_obj(FileAccess.get_file_as_string(path), units)
		"3mf":
			return read_3mf(path, units)
		"glb", "gltf":
			return read_gltf(path, units)
	return _failed("Holo Forge reads STL, OBJ, 3MF, GLB and glTF meshes")


## An STL file (path) or its bytes, ASCII or binary. STL lists corners counter-clockwise.
static func read_stl(source: Variant, units := "m") -> Dictionary:
	var bytes: PackedByteArray
	if source is PackedByteArray:
		bytes = source
	else:
		if not FileAccess.file_exists(str(source)):
			return _failed("%s can't be found" % str(source).get_file())
		bytes = FileAccess.get_file_as_bytes(str(source))
	if bytes.size() < 15:
		return _failed("The STL file is empty")
	var corners := PackedVector3Array()
	# Binary: an 80-byte header, a triangle count, then 50 bytes per triangle. A binary file
	# may still start with "solid", so the size decides: exactly the count's size is binary.
	var count := bytes.decode_u32(80) if bytes.size() >= 84 else 0
	var binary := bytes.size() >= 84 and bytes.size() == 84 + count * 50
	if not binary:
		# ASCII ("vertex x y z" words). The text stops at the first zero byte, which a binary file
		# has by its triangle count at the latest, so binary data never reads as words.
		var text := bytes.get_string_from_ascii()
		var words := _words(text)
		var i := 0
		while i < words.size():
			if words[i].to_lower() == "vertex" and i + 3 < words.size():
				corners.append(Vector3(words[i + 1].to_float(), words[i + 2].to_float(), words[i + 3].to_float()))
				i += 4
			else:
				i += 1
		corners.resize(corners.size() - corners.size() % 3)
		# Not ASCII after all (it has zero bytes): binary with padding after the triangles, or a
		# count field left wrong (zero, or more than the file holds): read the whole triangles.
		var fits := floori((bytes.size() - 84) / 50.0) if bytes.size() >= 84 else 0
		if corners.is_empty() and fits > 0 and text.length() < bytes.size():
			binary = true
			count = fits if count == 0 or count > fits else count
		elif corners.is_empty():
			return _failed("The STL file has no triangles")
	if binary:
		corners.resize(count * 3)
		for t in count:
			var at := 84 + t * 50 + 12
			for k in 3:
				var o := at + k * 12
				corners[t * 3 + k] = Vector3(bytes.decode_float(o), bytes.decode_float(o + 4), bytes.decode_float(o + 8))
	var order := PackedInt32Array()
	order.resize(corners.size())
	for k in corners.size():
		order[k] = k
	return _weld(corners, order, unit_scale(units), true)


## OBJ text: "v x y z" and "f a b c ..." (polygons fanned into triangles, "a/t/n" forms and
## negative indices understood). OBJ lists corners counter-clockwise.
static func read_obj(text: String, units := "m") -> Dictionary:
	var vertices := PackedVector3Array()
	var order := PackedInt32Array()
	var bad := false
	for raw in text.split("\n"):
		var line := raw.replace("\t", " ").strip_edges()
		if line.begins_with("v "):
			var n := _words(line.substr(2))
			if n.size() >= 3:
				vertices.append(Vector3(n[0].to_float(), n[1].to_float(), n[2].to_float()))
		elif line.begins_with("f "):
			var face := PackedInt32Array()
			for token in _words(line.substr(2)):
				var index := token.get_slice("/", 0).to_int()
				# Positive indices count from 1; negative ones back from the newest vertex.
				index = index - 1 if index > 0 else vertices.size() + index
				if index < 0 or index >= vertices.size():
					bad = true
					face.clear()
					break
				face.append(index)
			for k in range(1, face.size() - 1):
				order.append_array(PackedInt32Array([face[0], face[k], face[k + 1]]))
	if order.is_empty():
		return _failed("The OBJ file has no faces" if not bad else "The OBJ file's faces point at missing vertices")
	var corners := PackedVector3Array()
	corners.resize(order.size())
	for k in order.size():
		corners[k] = vertices[order[k]]
	var straight := PackedInt32Array()
	straight.resize(order.size())
	for k in order.size():
		straight[k] = k
	return _weld(corners, straight, unit_scale(units), true)


## A mesh file's polygons as written, for Form's Mesh to Form: {"points": PackedVector3Array
## (meters, after the units scale), "faces": Array of PackedInt32Array (counter-clockwise seen from
## outside), "error"}. OBJ keeps its n-gons and quads; the other formats give their triangles (wound
## counter-clockwise again). Points are not welded here.
static func read_polygons(path: String, units := "m") -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"points": PackedVector3Array(), "faces": [], "error": "%s can't be found" % path.get_file()}
	var scale := unit_scale(units)
	if path.get_extension().to_lower() == "obj":
		var points := PackedVector3Array()
		var faces: Array = []
		for raw in FileAccess.get_file_as_string(path).split("\n"):
			var line := raw.replace("\t", " ").strip_edges()
			if line.begins_with("v "):
				var n := _words(line.substr(2))
				if n.size() >= 3:
					points.append(Vector3(n[0].to_float(), n[1].to_float(), n[2].to_float()) * scale)
			elif line.begins_with("f "):
				var face := PackedInt32Array()
				for token in _words(line.substr(2)):
					var index := token.get_slice("/", 0).to_int()
					index = index - 1 if index > 0 else points.size() + index
					if index < 0 or index >= points.size():
						face.clear()
						break
					face.append(index)
				if face.size() >= 3:
					faces.append(face)
		if faces.is_empty():
			return {"points": points, "faces": [], "error": "The OBJ file has no faces"}
		return {"points": points, "faces": faces, "error": ""}
	var mesh := read_file(path, units)
	if str(mesh.error) != "":
		return {"points": PackedVector3Array(), "faces": [], "error": mesh.error}
	var indices: PackedInt32Array = mesh.indices
	var tris: Array = []
	for t in range(0, indices.size() - 2, 3):
		# The readers give Godot's clockwise winding: swap back to counter-clockwise.
		tris.append(PackedInt32Array([indices[t], indices[t + 2], indices[t + 1]]))
	return {"points": mesh.positions, "faces": tris, "error": ""}


## A 3MF file (a zip package holding XML models) as one merged mesh. units: one file unit (""
## = the file's own: its model's unit attribute, millimeters when it has none). Every build
## item is placed with its transform, and objects made of components bring in each component's
## object with the component's transform (nested, and from other model parts of the package).
## Support objects are left out. 3MF lists corners counter-clockwise.
static func read_3mf(path: String, units := "") -> Dictionary:
	if not FileAccess.file_exists(path):
		return _failed("%s can't be found" % path.get_file())
	var zip := ZIPReader.new()
	if zip.open(path) != OK:
		return _failed("The 3MF file couldn't be opened (it isn't a zip package)")
	var package := {"zip": zip, "entries": {}, "models": {}}
	for entry in zip.get_files():
		package.entries[entry.to_lower()] = entry
	var root := _3mf_root(package)
	if root == "":
		zip.close()
		return _failed("The 3MF file holds no 3D model")
	var model := _3mf_model(package, root)
	if model.has("error"):
		zip.close()
		return _failed(str(model.error))
	var corners := PackedVector3Array()
	var order := PackedInt32Array()
	var items: Array = (model.items as Array).duplicate()
	if items.is_empty():
		# A package without a build list: every object no other object uses, where it was modelled.
		var used := {}
		for id in model.objects:
			for component in model.objects[id].components:
				if str(component.path) == "":
					used[str(component.objectid)] = true
		for id in model.objects:
			if not used.has(id):
				items.append({"objectid": id, "transform": Transform3D.IDENTITY, "path": ""})
	for item in items:
		var part := str(item.path) if str(item.path) != "" else root
		var placed_model := _3mf_model(package, part)
		var object: Dictionary = (placed_model.get("objects", {}) as Dictionary).get(str(item.objectid), {})
		if object.is_empty() or str(object.type) in SKIPPED_3MF_TYPES:
			continue
		var error := _3mf_place(package, part, str(item.objectid), item.transform, corners, order, 0)
		if error != "":
			zip.close()
			return _failed(error)
	zip.close()
	if order.is_empty():
		return _failed("The 3MF file has no printable triangles")
	var file_units: String = UNITS_3MF.get(str(model.unit).to_lower(), "mm")
	var result := _weld(corners, order, unit_scale(units if units != "" else file_units), true)
	result["file_units"] = file_units
	return result


## The package's model part: the one its relationships start from, else 3D/3dmodel.model, else
## the first .model part ("" when there is none).
static func _3mf_root(package: Dictionary) -> String:
	var rels := _3mf_part(package, "_rels/.rels")
	if not rels.is_empty():
		var parser := XMLParser.new()
		if parser.open_buffer(rels) == OK:
			while parser.read() == OK:
				if parser.get_node_type() != XMLParser.NODE_ELEMENT or _local_name(parser.get_node_name()) != "Relationship":
					continue
				var target := parser.get_named_attribute_value_safe("Target").trim_prefix("/")
				if parser.get_named_attribute_value_safe("Type").ends_with(MODEL_RELATIONSHIP_3MF) and package.entries.has(target.to_lower()):
					return target
	if package.entries.has("3d/3dmodel.model"):
		return "3D/3dmodel.model"
	for entry in package.entries:
		if str(entry).ends_with(".model"):
			return str(package.entries[entry])
	return ""


## A part's bytes (empty when the package has no such part; names compare ignoring case).
static func _3mf_part(package: Dictionary, part: String) -> PackedByteArray:
	var entry := str(package.entries.get(part.trim_prefix("/").to_lower(), ""))
	if entry == "":
		return PackedByteArray()
	return (package.zip as ZIPReader).read_file(entry)


## A model part read once per package: {"unit", "objects": {id: {"type", "vertices",
## "triangles", "components": [{"objectid", "transform", "path"}]}}, "items": [{"objectid",
## "transform", "path"}]} or {"error"}.
static func _3mf_model(package: Dictionary, part: String) -> Dictionary:
	var key := part.trim_prefix("/").to_lower()
	if package.models.has(key):
		return package.models[key]
	var bytes := _3mf_part(package, part)
	var model := {"unit": "millimeter", "objects": {}, "items": []}
	var parser := XMLParser.new()
	if bytes.is_empty() or parser.open_buffer(bytes) != OK:
		model = {"error": "The 3MF part %s can't be read" % part}
		package.models[key] = model
		return model
	var id := ""
	var type := "model"
	var vertices := PackedVector3Array()
	var triangles := PackedInt32Array()
	var components := []
	var in_object := false
	while parser.read() == OK:
		var node := parser.get_node_type()
		if node == XMLParser.NODE_ELEMENT_END:
			if _local_name(parser.get_node_name()) == "object" and in_object:
				model.objects[id] = {"type": type, "vertices": vertices, "triangles": triangles, "components": components}
				in_object = false
			continue
		if node != XMLParser.NODE_ELEMENT:
			continue
		match _local_name(parser.get_node_name()):
			"model":
				model.unit = parser.get_named_attribute_value_safe("unit") if parser.has_attribute("unit") else "millimeter"
			"object":
				id = parser.get_named_attribute_value_safe("id")
				type = parser.get_named_attribute_value_safe("type") if parser.has_attribute("type") else "model"
				vertices = PackedVector3Array()
				triangles = PackedInt32Array()
				components = []
				in_object = not parser.is_empty()
				if not in_object:
					model.objects[id] = {"type": type, "vertices": vertices, "triangles": triangles, "components": components}
			"vertex":
				vertices.append(Vector3(parser.get_named_attribute_value_safe("x").to_float(),
					parser.get_named_attribute_value_safe("y").to_float(), parser.get_named_attribute_value_safe("z").to_float()))
			"triangle":
				triangles.append(parser.get_named_attribute_value_safe("v1").to_int())
				triangles.append(parser.get_named_attribute_value_safe("v2").to_int())
				triangles.append(parser.get_named_attribute_value_safe("v3").to_int())
			"component", "item":
				var reference := _3mf_reference(parser)
				if _local_name(parser.get_node_name()) == "item":
					(model.items as Array).append(reference)
				else:
					components.append(reference)
	package.models[key] = model
	return model


## A component's or build item's {"objectid", "transform", "path" (another model part, or "")}.
static func _3mf_reference(parser: XMLParser) -> Dictionary:
	var reference := {"objectid": "", "transform": Transform3D.IDENTITY, "path": ""}
	for k in parser.get_attribute_count():
		var value := parser.get_attribute_value(k)
		match _local_name(parser.get_attribute_name(k)):
			"objectid":
				reference.objectid = value
			"transform":
				reference.transform = _3mf_transform(value)
			"path":
				reference.path = value.trim_prefix("/")
	return reference


## A 3MF transform: "m00 m01 m02 m10 m11 m12 m20 m21 m22 m30 m31 m32" applies to row vectors
## (p' = p * M, the last row moves), so each row is where one axis goes.
static func _3mf_transform(text: String) -> Transform3D:
	var n := _words(text)
	if n.size() != 12:
		return Transform3D.IDENTITY
	var m := []
	for word in n:
		m.append(word.to_float())
	return Transform3D(Basis(Vector3(m[0], m[1], m[2]), Vector3(m[3], m[4], m[5]), Vector3(m[6], m[7], m[8])), Vector3(m[9], m[10], m[11]))


## Adds an object's triangles placed by xform (and its components', each after its own
## transform) to corners/order. Returns "" or the problem.
static func _3mf_place(package: Dictionary, part: String, object_id: String, xform: Transform3D, corners: PackedVector3Array, order: PackedInt32Array, depth: int) -> String:
	if depth > MAX_COMPONENT_DEPTH:
		return "The 3MF file's components nest too deep (or refer to themselves)"
	var model := _3mf_model(package, part)
	if model.has("error"):
		return str(model.error)
	var object: Dictionary = (model.objects as Dictionary).get(object_id, {})
	if object.is_empty():
		return "The 3MF file refers to a missing object %s" % object_id
	var vertices: PackedVector3Array = object.vertices
	var triangles: PackedInt32Array = object.triangles
	var base := corners.size()
	for p in vertices:
		corners.append(xform * p)
	# A mirroring placement turns the triangles inside out; the welder's swap then winds them back.
	var mirrored := xform.basis.determinant() < 0.0
	for t in range(0, triangles.size() - 2, 3):
		var a := triangles[t]
		var b := triangles[t + 1]
		var c := triangles[t + 2]
		if a < 0 or b < 0 or c < 0 or a >= vertices.size() or b >= vertices.size() or c >= vertices.size():
			return "The 3MF file's triangles point at missing vertices"
		if mirrored:
			order.append_array(PackedInt32Array([base + a, base + c, base + b]))
		else:
			order.append_array(PackedInt32Array([base + a, base + b, base + c]))
	for component in object.components:
		var error := _3mf_place(package, str(component.path) if str(component.path) != "" else part, str(component.objectid),
			xform * (component.transform as Transform3D), corners, order, depth + 1)
		if error != "":
			return error
	return ""


## A glTF/GLB file as one merged mesh (glTF is in meters; units can override that). Node
## transforms are applied; skins and morph targets are ignored.
static func read_gltf(path: String, units := "m") -> Dictionary:
	if not FileAccess.file_exists(path):
		return _failed("%s can't be found" % path.get_file())
	var gltf := GLTFDocument.new()
	var state := GLTFState.new()
	if gltf.append_from_file(path, state) != OK:
		return _failed("The glTF file couldn't be read")
	var nodes: Array = state.get_nodes()
	var meshes: Array = state.get_meshes()
	var corners := PackedVector3Array()
	var order := PackedInt32Array()
	for n in nodes.size():
		var node: GLTFNode = nodes[n]
		if node.mesh < 0 or node.mesh >= meshes.size():
			continue
		# The node's place in the scene: its transform after every parent's.
		var xform := node.xform
		var parent := node.parent
		var guard := 0
		while parent >= 0 and parent < nodes.size() and guard < 256:
			xform = (nodes[parent] as GLTFNode).xform * xform
			parent = (nodes[parent] as GLTFNode).parent
			guard += 1
		var mesh: ImporterMesh = (meshes[node.mesh] as GLTFMesh).mesh
		if mesh == null:
			continue
		var mirrored := xform.basis.determinant() < 0.0
		for s in mesh.get_surface_count():
			if mesh.get_surface_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES:
				continue
			var arrays: Array = mesh.get_surface_arrays(s)
			var points: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX] if arrays[Mesh.ARRAY_VERTEX] != null else PackedVector3Array()
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			if indices.is_empty():
				indices.resize(points.size() - points.size() % 3)
				for k in indices.size():
					indices[k] = k
			var base := corners.size()
			for p in points:
				corners.append(xform * p)
			for t in range(0, indices.size() - 2, 3):
				# Godot's importer already winds clockwise; a mirroring node flips it back.
				if mirrored:
					order.append_array(PackedInt32Array([base + indices[t], base + indices[t + 2], base + indices[t + 1]]))
				else:
					order.append_array(PackedInt32Array([base + indices[t], base + indices[t + 1], base + indices[t + 2]]))
	if order.is_empty():
		return _failed("The glTF file has no triangle meshes")
	return _weld(corners, order, unit_scale(units), false)


## Merges vertices at the same position, drops collapsed triangles and (for counter-clockwise
## sources) swaps each triangle's last two corners to Godot's clockwise winding.
static func _weld(corners: PackedVector3Array, order: PackedInt32Array, scale: float, flip: bool) -> Dictionary:
	var positions := PackedVector3Array()
	var indices := PackedInt32Array()
	var index_of := {}
	var remap := PackedInt32Array()
	remap.resize(corners.size())
	for k in corners.size():
		var p := corners[k] * scale
		var found: int = index_of.get(p, -1)
		if found < 0:
			found = positions.size()
			index_of[p] = found
			positions.append(p)
		remap[k] = found
	for t in range(0, order.size() - 2, 3):
		var a := remap[order[t]]
		var b := remap[order[t + 1]]
		var c := remap[order[t + 2]]
		if a == b or b == c or a == c:
			continue
		if flip:
			indices.append_array(PackedInt32Array([a, c, b]))
		else:
			indices.append_array(PackedInt32Array([a, b, c]))
	if indices.is_empty():
		return _failed("The mesh has no usable triangles")
	return {"positions": positions, "indices": indices, "triangles": int(indices.size() / 3.0), "error": ""}


## The mesh's separate pieces (triangles joined through shared corners): [{"positions",
## "indices"}], each with only its own vertices. A mesh in one piece comes back as it is.
static func pieces(positions: PackedVector3Array, indices: PackedInt32Array) -> Array:
	var parent := PackedInt32Array()
	parent.resize(positions.size())
	for k in parent.size():
		parent[k] = k
	var count := indices.size() - indices.size() % 3
	for t in range(0, count, 3):
		var a := indices[t]
		while parent[a] != a:
			parent[a] = parent[parent[a]]
			a = parent[a]
		for corner in 2:
			var b := indices[t + 1 + corner]
			while parent[b] != b:
				parent[b] = parent[parent[b]]
				b = parent[b]
			if b != a:
				parent[b] = a
	# Each triangle's piece, numbered in the order the pieces first appear.
	var piece_of := {}
	var triangle_piece := PackedInt32Array()
	triangle_piece.resize(int(count / 3.0))
	for t in range(0, count, 3):
		var root := indices[t]
		while parent[root] != root:
			root = parent[root]
		if not piece_of.has(root):
			piece_of[root] = piece_of.size()
		triangle_piece[int(t / 3.0)] = int(piece_of[root])
	var piece_count := piece_of.size()
	if piece_count <= 1:
		return [{"positions": positions, "indices": indices}]
	# The triangles sorted by piece (a counting sort), so each piece is built in one run.
	var starts := PackedInt32Array()
	starts.resize(piece_count + 1)
	starts.fill(0)
	for t in triangle_piece.size():
		starts[triangle_piece[t] + 1] += 1
	for p in piece_count:
		starts[p + 1] += starts[p]
	var next := starts.duplicate()
	var sorted := PackedInt32Array()
	sorted.resize(triangle_piece.size())
	for t in triangle_piece.size():
		var p := triangle_piece[t]
		sorted[next[p]] = t
		next[p] += 1
	# A vertex belongs to one piece only, so one remap serves them all.
	var remap := PackedInt32Array()
	remap.resize(positions.size())
	remap.fill(-1)
	var result := []
	for p in piece_count:
		var own := PackedVector3Array()
		var own_indices := PackedInt32Array()
		for s in range(starts[p], starts[p + 1]):
			for k in 3:
				var index := indices[sorted[s] * 3 + k]
				if remap[index] < 0:
					remap[index] = own.size()
					own.append(positions[index])
				own_indices.append(remap[index])
		result.append({"positions": own, "indices": own_indices})
	return result


static func _failed(reason: String) -> Dictionary:
	return {"positions": PackedVector3Array(), "indices": PackedInt32Array(), "triangles": 0, "error": reason}


static func _words(text: String) -> PackedStringArray:
	return text.replace("\t", " ").replace("\r", " ").replace("\n", " ").split(" ", false)


## An XML name without its namespace prefix ("m:vertex" -> "vertex").
static func _local_name(name: String) -> String:
	var at := name.rfind(":")
	return name.substr(at + 1) if at >= 0 else name
