@tool
extends RefCounted
## Insert features: "import" (STEP/IGES/BREP/STL bodies), "mesh_import" (STL/OBJ/3MF/GLB meshes
## as faceted bodies), "derive" (bodies from another saved Holo Forge design) and "fastener"
## (ISO metric bolts, nuts and washers). All are Create features: the result goes through the
## operation (New Body by default).
##
## import: options path, data (BRep bytes captured when inserted, so the design works without the
## file), face_names (the faces' names then), linked (re-read the file on rebuild when it
## exists; its faces take the kept names by geometry, so a revised file keeps references on the
## faces it still has), split (each solid becomes its own body), transform, operation, body_id.
## mesh_import: options path, positions and indices (stored in file units, Godot's clockwise
## winding), units (mm | cm | m | in | ft | um), linked, split (each separate piece of the mesh
## becomes its own body), transform, operation, body_id. Its solids are kept between rebuilds
## while the triangles and their placement stay the same (_mesh_cache).
## mesh_import with options kind "mesh" (a missing kind is "solid": the faceted body above, as in
## every older design) makes a mesh body instead (core/mesh/mesh_body.gd): options path, units,
## linked, split, transform, body_id, and, when not linked, mesh (a MeshBlob: the file's triangles
## in meters, read with the unit in mesh_units). A linked one reads its file on every rebuild.
## No positions or indices are stored. The mesh is kept between rebuilds by its content
## (core/features/mesh.gd's cache). It always comes in as a new body.
## The kind can be switched on a feature as it is: a mesh body is then made from the stored
## positions and indices, and a faceted solid from the stored blob (up to MAX_TRIANGLES).
## derive: options path (a saved .tres design, or a scene whose first CadPart holds the design),
## bodies (source body ids; empty = all), body_map (source body id -> this design's body id),
## transform, operation, body_id. Derived faces are named "<derive id>:<source body id>:<source
## name>", apart from this design's own names. The rebuilt source is cached until it, a design it
## derives or a file it links changes. A mesh body of the source derives as a mesh body (its face
## groups keep their names), and only as a body of its own: Join, Cut and Intersect refuse it.
## import, mesh_import and derive also take the optional inputs x, y, z (an offset) and rx, ry,
## rz (angles, as Move/Copy turns): after options.transform the result turns about its middle and
## moves by the offset. Without these inputs only the transform places it (older designs).
## change_source() points one of them at another file (the timeline's edit panel uses it).
## fastener: options kind (hex_bolt | socket_bolt | hex_nut | washer), size ("M6"), position,
## axis, angle (turn about the axis; an "angle" input wins), operation, body_id; input length
## (bolts). A bolt's head sits
## on the position with its shank running along the axis; a nut or washer sits on the position
## and rises along the axis. Threads are cosmetic: they are noted in ctx.threads. Placed on
## geometry (options place: [a face, edge or point reference], follow: true) it finds that again
## on every rebuild and moves with it: see fastener_placement(); direction "auto" (with flip)
## then takes the axis from the face too. A face reference may carry "at": the position its sig
## was taken at (add_fastener sets it); see place_on().
##
## The add_* helpers make a ready feature (New Body, with its body registered) for the UI and
## return {"feature": Resource or null, "error": String, ...}.

const UTIL := preload("res://addons/holo_forge/core/features/util.gd")
const OPERATIONS := preload("res://addons/holo_forge/core/operations.gd")
const MESH_IMPORT := preload("res://addons/holo_forge/core/import/mesh_import.gd")
## Loaded when needed: regen.gd preloads this file.
const REGEN_PATH := "res://addons/holo_forge/core/regen.gd"
const FASTENER_TABLE := "res://addons/holo_forge/data/fastener_tables.json"
const REFERENCES := preload("res://addons/holo_forge/core/references.gd")
const MESH := preload("res://addons/holo_forge/core/features/mesh.gd")
const MESH_BODY := preload("res://addons/holo_forge/core/mesh/mesh_body.gd")
const MESH_BLOB := preload("res://addons/holo_forge/core/mesh/mesh_blob.gd")
const RESOURCE_FILE := preload("res://addons/holo_forge/core/resource_file_check.gd")
## Insert Mesh body types (options.kind; a feature without the key is KIND_SOLID).
const KIND_SOLID := "solid"
const KIND_MESH := "mesh"
const IMPORT_EXTENSIONS := ["step", "stp", "iges", "igs", "brep", "stl"]
const MAX_TRIANGLES := 60000
const PROFILE_DEFLECTION := 0.0002
const LOOP := "Derive loop"
const BOLTS := ["hex_bolt", "socket_bolt"]
## A Z-up file turned so its up is Godot's +Y (Insert Mesh's "The File Is Z-Up").
const Z_UP := Transform3D(Basis(Vector3.RIGHT, -PI / 2.0), Vector3.ZERO)
## The placement inputs: an offset, then angles.
const OFFSET_KEYS := ["x", "y", "z"]
const ANGLE_KEYS := ["rx", "ry", "rz"]
## A re-read import pairs at most this many (new face, old face) leftovers by closeness.
const MATCH_PAIRS := 250000
## Insert Mesh results kept at most (one per feature).
const MESH_CACHE_SIZE := 16
const MESH_BOUNDS_SIZE := 64
## Meters: a fastener's spot this far beside its face (not just above or below it) is off the face.
const OFF_FACE := 1e-6

static var _fasteners := {}
## Saved designs already rebuilt for Derive: path -> {"bodies", "errors", "stamps"}.
static var _derive_cache := {}
## The designs being rebuilt through Derive right now, outermost first (finds loops).
static var _deriving: Array[String] = []
## File stamps collected by the Derive rebuilds in progress (a cache entry is stale when any
## file it read, a design or a linked import's file, changed).
static var _recorders: Array[Dictionary] = []
## Insert Mesh solids kept between rebuilds, as meshing tens of thousands of triangles into faces
## takes seconds: feature instance id -> {"owner": WeakRef to the feature, "positions",
## "indices", "xform", "tag", "shapes", "whole", "open"; for a linked file also "path", "stamp",
## "file_positions", "file_indices"}. A rebuild with the same triangles and placement reuses
## the same shapes.
static var _mesh_cache := {}
## The bounds of mesh-body inserts' unplaced meshes by what they come from (a blob's digest, a
## file's stamp): the placement turns about their middle, and a rebuild shouldn't decode the mesh
## again just to find it. At most MESH_BOUNDS_SIZE, oldest first out.
static var _mesh_body_bounds := {}


static func build(feature: Resource, ctx: Dictionary) -> String:
	match feature.type:
		"import":
			return _import(feature, ctx)
		"mesh_import":
			return _mesh_import(feature, ctx)
		"derive":
			return _derive(feature, ctx)
		"fastener":
			return _fastener(feature, ctx)
	return "Unknown feature '%s'" % feature.type


static func _warn(ctx: Dictionary, feature: Resource, text: String) -> void:
	if ctx.has("warnings"):
		ctx.warnings[feature.id] = text


## The shape moved by placement(), or null after fail(). box: the bounds the turn is about
## (before options.transform; the shape's own when not given).
static func _placed(r: UTIL.Reader, shape: RefCounted, what: String, box: Variant = null) -> RefCounted:
	var around := AABB()
	if has_offset(r):
		around = box if box is AABB else shape.bbox()
	var xform := placement(r, around)
	if not r.ok():
		return null
	if xform.is_equal_approx(Transform3D.IDENTITY):
		return shape
	return r.checked(r.kernel.transform_shape(shape, xform, r.feature.id), what)


## True when the feature has placement inputs (x, y, z, rx, ry, rz).
static func has_offset(r: UTIL.Reader) -> bool:
	return (OFFSET_KEYS + ANGLE_KEYS).any(func(key: String) -> bool: return r.has_input(key))


## Where an import, mesh or derive goes: options.transform, then turned by the angle inputs about
## the middle of box (box: what is placed, before the transform) and moved by the offset inputs.
## A bad input fails the reader.
static func placement(r: UTIL.Reader, box: AABB) -> Transform3D:
	var base: Transform3D = r.opt("transform", Transform3D.IDENTITY)
	if not has_offset(r):
		return base
	var turn := Basis.from_euler(Vector3(r.num("rx", 0.0), r.num("ry", 0.0), r.num("rz", 0.0)))
	var offset := Vector3(r.num("x", 0.0), r.num("y", 0.0), r.num("z", 0.0))
	var pivot := (base * box).get_center()
	return Transform3D(turn, pivot - turn * pivot + offset) * base


# --- Import (STEP / IGES / BREP / STL) -------------------------------------------------------

static func _import(feature: Resource, ctx: Dictionary) -> String:
	var r := UTIL.Reader.new(feature, ctx)
	var shape := _imported_shape(r)
	if shape == null:
		return r.error
	shape = _placed(r, shape, "Import")
	if shape == null:
		return r.error
	if shape.solid_count() > 1:
		return _finish_pieces(r, shape.solids(), shape, "Import")
	return UTIL.finish(r, shape, "Import")


## Ends an import made of several pieces (whole: all of them as one shape). With split and an
## operation that makes a body, each piece becomes its own body: the first keeps the feature's
## body id, the others are its copies. Otherwise the whole goes through the operation.
static func _finish_pieces(r: UTIL.Reader, pieces: Array, whole: RefCounted, what: String) -> String:
	var op := str(r.opt("operation", OPERATIONS.NEW_BODY))
	if pieces.size() < 2 or not bool(r.opt("split", false)) or not OPERATIONS.creates_body(op):
		return UTIL.finish(r, whole, what)
	var error := UTIL.finish(r, pieces[0], what)
	if error != "":
		return error
	var body_id := str(r.opt("body_id", ""))
	for k in range(1, pieces.size()):
		var id := UTIL.derived_body_id(body_id, r.feature.id, k + 1)
		r.ctx.bodies[id] = {"id": id, "shape": pieces[k], "feature": r.feature.id}
	# Patterns and mirrors of this feature replay every piece, not just the first.
	if r.ctx.has("tools"):
		r.ctx.tools[r.feature.id] = {"shape": whole, "operation": op}
	return ""


## The file read again (linked) or the copy kept in the design, with the faces' saved names. A
## re-read file's faces take the kept copy's names by their geometry (match_face_names), so a
## revised file (a bore added) leaves what was built on its other faces where it was.
static func _imported_shape(r: UTIL.Reader) -> RefCounted:
	var path := str(r.opt("path", ""))
	var kept := _kept_copy(r.feature.options, r.feature.id)
	if bool(r.opt("linked", false)) and path != "":
		_record_file(path)
		if FileAccess.file_exists(path):
			var shape: RefCounted = r.kernel.import_file(path, r.feature.id)
			if shape != null and not shape.is_null():
				if kept.has("shape"):
					match_face_names(shape, kept.shape, r.feature.id)
				return shape
			_warn(r.ctx, r.feature, "%s couldn't be read again (%s); the copy kept in the design was used" % [path.get_file(), r.kernel.get_last_error()])
		else:
			_warn(r.ctx, r.feature, "The linked file %s is missing; the copy kept in the design was used" % path.get_file())
	if kept.has("error"):
		r.fail(str(kept.error))
		return null
	return kept.shape


## The copy of the file an import keeps (options data), with the names its faces had when it was
## read (options face_names): {"shape"} or {"error"}.
static func _kept_copy(options: Dictionary, feature_id: String) -> Dictionary:
	var path := str(options.get("path", ""))
	var data: PackedByteArray = options.get("data", PackedByteArray())
	if data.is_empty():
		return {"error": "The design keeps no copy of %s" % (path.get_file() if path != "" else "the imported file")}
	var shape: RefCounted = ClassDB.instantiate("CadShape")
	if not shape.load_brep_bytes(data):
		return {"error": "The copy of %s kept in the design couldn't be read" % path.get_file()}
	# A stored shape has no names; give back the ones the file's faces had when inserted.
	var names: PackedStringArray = options.get("face_names", PackedStringArray())
	if names.size() != shape.face_count():
		names = PackedStringArray()
		for k in shape.face_count():
			names.append("%s:f#%d" % [feature_id, k])
	shape.set_face_names(names)
	shape.name_edges_from_faces()
	return {"shape": shape}


## Names the faces of a freshly read shape after the faces of kept (the same file as it was read
## before, or the file it replaces), pairing them by geometry rather than order: first faces with
## the same type, centre, normal and area, then for what is left the closest face of the same type
## and facing (within a quarter of the part's size; a face that gained a hole moves its centre a
## little). Faces kept has no partner for get names kept never used, so a file that gained or lost
## a face keeps every other face's name. Edges are named from the faces again.
static func match_face_names(shape: RefCounted, kept: RefCounted, tag: String) -> void:
	var old_names: PackedStringArray = kept.get_face_names()
	var old_count: int = kept.face_count()
	var new_count: int = shape.face_count()
	if old_names.size() != old_count:
		return
	var size := maxf(maxf((kept.bbox() as AABB).size.length(), (shape.bbox() as AABB).size.length()), 1e-9)
	var old_sigs := []
	for i in old_count:
		old_sigs.append(REFERENCES.face_signature(kept, i))
	var new_sigs := []
	for i in new_count:
		new_sigs.append(REFERENCES.face_signature(shape, i))
	var names := PackedStringArray()
	names.resize(new_count)
	var matched := {}
	var taken := {}
	var exact := {}
	for o in old_count:
		var key := _face_key(old_sigs[o], size)
		if not exact.has(key):
			exact[key] = []
		(exact[key] as Array).append(o)
	for n in new_count:
		for o in exact.get(_face_key(new_sigs[n], size), []):
			if not taken.has(o):
				names[n] = old_names[o]
				matched[n] = true
				taken[o] = true
				break
	var left_new := range(new_count).filter(func(n: int) -> bool: return not matched.has(n))
	var left_old := range(old_count).filter(func(o: int) -> bool: return not taken.has(o))
	if left_new.size() * left_old.size() <= MATCH_PAIRS:
		var pairs := []
		for n in left_new:
			for o in left_old:
				var score := _face_distance(new_sigs[n], old_sigs[o], size)
				if score <= size * 0.25:
					pairs.append([score, n, o])
		pairs.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
		for pair in pairs:
			if not matched.has(pair[1]) and not taken.has(pair[2]):
				names[pair[1]] = old_names[pair[2]]
				matched[pair[1]] = true
				taken[pair[2]] = true
	var used := {}
	for name in old_names:
		used[name] = true
	var next := old_count
	for n in new_count:
		if matched.has(n):
			continue
		var name := "%s:f#%d" % [tag, next]
		while used.has(name):
			next += 1
			name = "%s:f#%d" % [tag, next]
		used[name] = true
		names[n] = name
		next += 1
	shape.set_face_names(names)
	shape.name_edges_from_faces()


## A face signature rounded to a millionth of the part's size (equal for an untouched face).
static func _face_key(sig: Dictionary, size: float) -> String:
	var grid := size * 1e-6
	var p: Vector3 = sig.get("point", Vector3.ZERO)
	var n: Vector3 = sig.get("normal", Vector3.ZERO)
	return "%s|%d,%d,%d|%d,%d,%d|%d" % [sig.get("type", ""), roundi(p.x / grid), roundi(p.y / grid), roundi(p.z / grid),
		roundi(n.x * 1e4), roundi(n.y * 1e4), roundi(n.z * 1e4), roundi(float(sig.get("area", 0.0)) / (grid * size))]


## How far apart two face signatures are (meters; INF for another type or facing).
static func _face_distance(a: Dictionary, b: Dictionary, size: float) -> float:
	if str(a.get("type", "")) != str(b.get("type", "")):
		return INF
	var na: Vector3 = a.get("normal", Vector3.ZERO)
	var nb: Vector3 = b.get("normal", Vector3.ZERO)
	if not na.is_zero_approx() and not nb.is_zero_approx() and na.dot(nb) < 0.999:
		return INF
	var area_a := float(a.get("area", 0.0))
	var area_b := float(b.get("area", 0.0))
	var area_change := absf(area_a - area_b) / maxf(maxf(area_a, area_b), 1e-30)
	return (a.get("point", Vector3.ZERO) as Vector3).distance_to(b.get("point", Vector3.ZERO)) + area_change * size * 0.1


## Inserts a STEP/IGES/BREP/STL file as a new body, keeping a copy of it in the design.
## linked: re-read the file on every rebuild while it exists. Returns {"feature", "error",
## "solids": how many solids the file holds}.
static func add_import(doc: Resource, kernel: RefCounted, path: String, linked := false) -> Dictionary:
	if kernel == null:
		kernel = load(REGEN_PATH).make_kernel()
	if kernel == null:
		return {"feature": null, "error": "The Holo Forge kernel is not loaded"}
	if not path.get_extension().to_lower() in IMPORT_EXTENSIONS:
		return {"feature": null, "error": "Holo Forge imports STEP, IGES, BREP and STL files"}
	if not FileAccess.file_exists(path):
		return {"feature": null, "error": "%s can't be found" % path.get_file()}
	# Faces are named after the feature, so name them with the id the feature is about to get.
	var tag := "f%d" % (int(doc.counters.get("feature", 0)) + 1)
	var shape: RefCounted = kernel.import_file(path, tag)
	if shape == null or shape.is_null():
		return {"feature": null, "error": "%s couldn't be read: %s" % [path.get_file(), kernel.get_last_error()]}
	var data: PackedByteArray = shape.to_brep_bytes()
	if data.is_empty():
		return {"feature": null, "error": "%s couldn't be stored in the design" % path.get_file()}
	var feature: Resource = doc.add_feature("import", "Import", {}, {
		"path": path, "data": data, "face_names": shape.get_face_names(), "linked": linked, "split": false,
		"transform": Transform3D.IDENTITY, "operation": OPERATIONS.NEW_BODY,
	})
	if feature.id != tag:
		var names := PackedStringArray()
		for name in shape.get_face_names():
			names.append(feature.id + name.substr(tag.length()) if name.begins_with(tag + ":") else name)
		feature.options["face_names"] = names
	var body_id: String = doc.new_body(feature.id)
	feature.options["body_id"] = body_id
	doc.bodies[body_id]["name"] = path.get_file().get_basename()
	return {"feature": feature, "error": "", "solids": shape.solid_count()}


# --- Mesh import (STL / OBJ / GLB) -----------------------------------------------------------

static func _mesh_import(feature: Resource, ctx: Dictionary) -> String:
	if mesh_kind(feature) == KIND_MESH:
		return _mesh_body_import(feature, ctx)
	var r := UTIL.Reader.new(feature, ctx)
	var positions: PackedVector3Array = r.opt("positions", PackedVector3Array())
	var indices: PackedInt32Array = r.opt("indices", PackedInt32Array())
	var path := str(r.opt("path", ""))
	var cached := _mesh_entry(feature)
	# Meters per stored unit: the file's unit, or (triangles taken from a stored blob) what turns
	# the blob's meters back into the unit it was read with.
	var stored_scale := 1.0
	if positions.is_empty() and feature.options.get("mesh") is Resource and not (bool(r.opt("linked", false)) and path != ""):
		# A mesh-body insert switched to a faceted solid: the stored mesh's triangles.
		var stored := MESH.blob_mesh(feature)
		if stored.has("error"):
			return stored.error
		if int(stored.mesh.triangle_count()) > MAX_TRIANGLES:
			return "The mesh has %d triangles; a faceted solid takes up to %d (keep it a mesh body, or reduce it first)" % [int(stored.mesh.triangle_count()), MAX_TRIANGLES]
		var arrays: Dictionary = stored.mesh.get_arrays()
		positions = arrays.positions
		indices = arrays.indices
		stored_scale = 1.0 / MESH_IMPORT.unit_scale(str(r.opt("mesh_units", r.opt("units", "mm"))))
	if bool(r.opt("linked", false)) and path != "":
		_record_file(path)
		if cached.has("file_positions") and str(cached.get("path", "")) == path and _unchanged(path, cached.get("stamp", {})):
			# The linked file is as it was: its triangles as read last time.
			positions = cached.file_positions
			indices = cached.file_indices
		else:
			var stamp := _stamp(path)
			var found := FileAccess.file_exists(path)
			var mesh := MESH_IMPORT.read_file(path, "m") if found else {"error": "missing"}
			if str(mesh.error) == "" and int(mesh.triangles) <= MAX_TRIANGLES:
				positions = mesh.positions
				indices = mesh.indices
				cached = {"path": path, "stamp": stamp, "file_positions": positions, "file_indices": indices}
			else:
				# Why the file can't be used: it holds more than a faceted solid takes, it is gone,
				# or it can't be read.
				var over := str(mesh.error) == ""
				if positions.is_empty():
					# No copy is kept in the design (a linked mesh body switched to a solid).
					if over:
						return "The linked mesh %s has %d triangles; a faceted solid takes up to %d (keep it a mesh body, or reduce it first)" % [path.get_file(), int(mesh.triangles), MAX_TRIANGLES]
					if not found:
						return "The linked mesh %s can't be found" % path.get_file()
					return "The linked mesh %s couldn't be read: %s" % [path.get_file(), str(mesh.error)]
				# The kept copy is used: what was built from it can still be reused.
				cached = cached.duplicate()
				for key in ["path", "stamp", "file_positions", "file_indices"]:
					cached.erase(key)
				if over:
					_warn(ctx, feature, "The linked mesh %s now has %d triangles (a faceted solid takes up to %d); the copy kept in the design was used" % [path.get_file(), int(mesh.triangles), MAX_TRIANGLES])
				else:
					_warn(ctx, feature, "The linked mesh %s couldn't be read again; the copy kept in the design was used" % path.get_file())
	if positions.is_empty() or indices.size() < 3:
		return "The mesh holds no triangles"
	var scale := MESH_IMPORT.unit_scale(str(r.opt("units", "mm"))) * stored_scale
	var box := AABB()
	if has_offset(r):
		box = AABB(positions[0] * scale, Vector3.ZERO)
		for p in positions:
			box = box.expand(p * scale)
	var xform := placement(r, box) * Transform3D(Basis.from_scale(Vector3.ONE * scale), Vector3.ZERO)
	if not r.ok():
		return r.error
	if cached.has("shapes") and str(cached.tag) == feature.id and (cached.xform as Transform3D) == xform \
			and (cached.positions as PackedVector3Array) == positions and (cached.indices as PackedInt32Array) == indices:
		# The same triangles in the same place as last time: the same solids.
		_store_mesh_entry(feature, cached)
		return _finish_mesh(r, cached)
	var built := _mesh_shapes(r, positions, indices, xform)
	if not built.has("shapes"):
		return r.error
	built.merge({"tag": feature.id, "xform": xform, "positions": positions, "indices": indices})
	for key in ["path", "stamp", "file_positions", "file_indices"]:
		if cached.has(key):
			built[key] = cached[key]
	_store_mesh_entry(feature, built)
	return _finish_mesh(r, built)


## Ends an Insert Mesh from its solids ({"shapes", "whole", "open"}, see _mesh_shapes).
static func _finish_mesh(r: UTIL.Reader, built: Dictionary) -> String:
	var shapes: Array = built.shapes
	var open := int(built.open)
	if open > 0:
		_warn(r.ctx, r.feature, "The mesh isn't closed, so it came in as a surface without volume" if shapes.size() == 1 \
			else "%d of the mesh's %d pieces aren't closed, so they came in as surfaces without volume" % [open, shapes.size()])
	if shapes.size() == 1:
		return UTIL.finish(r, shapes[0], "Insert Mesh")
	return _finish_pieces(r, shapes, built.whole, "Insert Mesh")


## The feature's kept Insert Mesh result ({} when there is none or it belongs to another feature).
static func _mesh_entry(feature: Resource) -> Dictionary:
	var entry: Dictionary = _mesh_cache.get(feature.get_instance_id(), {})
	if entry.is_empty() or (entry.owner as WeakRef).get_ref() != feature:
		return {}
	return entry


## Keeps a feature's Insert Mesh result (newest last), dropping those of features that are gone
## and the oldest beyond MESH_CACHE_SIZE.
static func _store_mesh_entry(feature: Resource, entry: Dictionary) -> void:
	var id := feature.get_instance_id()
	entry["owner"] = weakref(feature)
	_mesh_cache.erase(id)
	for key in _mesh_cache.keys():
		if (_mesh_cache[key].owner as WeakRef).get_ref() == null:
			_mesh_cache.erase(key)
	while _mesh_cache.size() >= MESH_CACHE_SIZE:
		_mesh_cache.erase(_mesh_cache.keys()[0])
	_mesh_cache[id] = entry


## Forgets every kept Insert Mesh result.
static func clear_mesh_cache() -> void:
	_mesh_cache.clear()
	_mesh_body_bounds.clear()


## The triangles (file units) placed by xform and made into solids: {"shapes", "whole" (all of
## them as one shape), "open": how many aren't closed}, or {} after r failed.
static func _mesh_shapes(r: UTIL.Reader, positions: PackedVector3Array, indices: PackedInt32Array, xform: Transform3D) -> Dictionary:
	var feature: Resource = r.feature
	var placed := PackedVector3Array()
	placed.resize(positions.size())
	for k in positions.size():
		placed[k] = xform * positions[k]
	if xform.basis.determinant() < 0.0:
		# A mirroring placement turns the triangles inside out; wind them back.
		var flipped := indices.duplicate()
		for t in range(0, flipped.size() - 2, 3):
			flipped[t + 1] = indices[t + 2]
			flipped[t + 2] = indices[t + 1]
		indices = flipped
	# Each separate piece becomes its own solid (one shell per solid); a mesh in one piece keeps
	# the faces' names it always had.
	var pieces := MESH_IMPORT.pieces(placed, indices)
	var shapes := []
	var open := 0
	for k in pieces.size():
		var tag: String = feature.id if k == 0 else "%s:s%d" % [feature.id, k + 1]
		var shape: RefCounted = r.kernel.mesh_to_shape(pieces[k].positions, pieces[k].indices, tag)
		if r.checked(shape, "Insert Mesh") == null:
			return {}
		open += 0 if str(shape.shape_type()) == "SOLID" else 1
		shapes.append(shape)
	if shapes.is_empty():
		r.fail("The mesh holds no triangles")
		return {}
	return {"shapes": shapes, "whole": shapes[0] if shapes.size() == 1 else r.kernel.make_compound(shapes), "open": open}


## Inserts a mesh file (STL, OBJ, 3MF, GLB/glTF) as a new faceted body. units: what one unit of
## the file is (mm, cm, m, in, ft, um; "" = the file's own: the unit a 3MF file declares, meters
## for glTF, millimeters for STL and OBJ); the triangles are kept in the design. kind: KIND_SOLID
## (a faceted B-rep body, up to MAX_TRIANGLES) or KIND_MESH (a mesh body, up to
## MESH.MAX_TRIANGLES_MESH). Returns {"feature", "error", "triangles"}, and for a mesh body
## "warning": what the reader said of a file it took with doubts ("" for a whole file).
static func add_mesh_import(doc: Resource, path: String, units := "", linked := false, kind := KIND_SOLID) -> Dictionary:
	if kind == KIND_MESH:
		return _add_mesh_body_import(doc, path, units, linked)
	var mesh := _read_mesh(path)
	if str(mesh.error) != "":
		return {"feature": null, "error": mesh.error}
	if units == "":
		units = file_units(path, mesh)
	var feature: Resource = doc.add_feature("mesh_import", "Mesh", {}, {
		"path": path, "positions": mesh.positions, "indices": mesh.indices, "units": units, "linked": linked,
		"split": false, "transform": Transform3D.IDENTITY, "operation": OPERATIONS.NEW_BODY,
	})
	var body_id: String = doc.new_body(feature.id)
	feature.options["body_id"] = body_id
	doc.bodies[body_id]["name"] = path.get_file().get_basename()
	return {"feature": feature, "error": "", "triangles": mesh.triangles}


# --- Mesh import as a mesh body --------------------------------------------------------------

## "mesh" or "solid": what an Insert Mesh feature makes (a feature without the key: "solid").
static func mesh_kind(feature: Resource) -> String:
	return KIND_MESH if str(feature.options.get("kind", KIND_SOLID)) == KIND_MESH else KIND_SOLID


## A mesh file as a CadMesh in meters: {"mesh" (null on a problem), "error", "triangles",
## "units" (the unit one file unit was read as: units, or the file's own when ""), "warning"
## (what the reader says of a file it took with doubts: one that looks cut off, or holds faces it
## left out; with the file's name; "" for a whole file)}. STL and OBJ are read by the kernel; 3MF
## and glTF by core/import/mesh_import.gd, then welded (CadMesh.welded), so corners the file split
## along seams are not read as open edges.
static func read_mesh_body(path: String, units := "") -> Dictionary:
	var failed := {"mesh": null, "error": "", "triangles": 0, "units": units, "warning": ""}
	var warning := ""
	if not MESH_BODY.available():
		failed.error = MESH_BODY.KERNEL_MISSING
		return failed
	var ext := path.get_extension().to_lower()
	if not ext in MESH_IMPORT.EXTENSIONS:
		failed.error = "Holo Forge reads STL, OBJ, 3MF, GLB and glTF meshes"
		return failed
	if not FileAccess.file_exists(path):
		failed.error = "%s can't be found" % path.get_file()
		return failed
	var mesh: RefCounted = MESH_BODY.new_mesh()
	if ext == "stl" or ext == "obj":
		if units == "":
			units = file_units(path)
		var scale := MESH_IMPORT.unit_scale(units)
		var read: bool = mesh.read_stl(path, scale) if ext == "stl" else mesh.read_obj(path, scale)
		if not read:
			failed.error = str(mesh.get_last_error())
			return failed
		# The reader's doubts about a file it still took, each with the file's name.
		var doubts := PackedStringArray()
		for line in str(mesh.get_last_warning()).split("\n", false):
			var doubt := line.strip_edges()
			if doubt != "":
				doubts.append(doubt if doubt.contains(path.get_file()) else "%s: %s" % [path.get_file(), doubt])
		warning = " ".join(doubts)
	else:
		var arrays := MESH_IMPORT.read_file(path, units if units != "" or ext == "3mf" else "m")
		if str(arrays.error) != "":
			failed.error = str(arrays.error)
			return failed
		if int(arrays.triangles) > MESH.MAX_TRIANGLES_MESH:
			failed.error = "%s has %d triangles; mesh bodies take up to %d." % [path.get_file(), int(arrays.triangles), MESH.MAX_TRIANGLES_MESH]
			return failed
		if units == "":
			units = file_units(path, arrays)
		if not mesh.set_arrays(arrays.positions, arrays.indices, PackedInt32Array(), PackedStringArray(), "godot"):
			failed.error = str(mesh.get_last_error())
			return failed
		# Corners a file split along seams read as open edges until they are welded (by exact
		# position; the face groups stay).
		var welded: RefCounted = mesh.welded()
		if welded == null or welded.is_null():
			failed.error = "%s couldn't be welded: %s" % [path.get_file(), str(mesh.get_last_error())]
			return failed
		mesh = welded
	return {"mesh": mesh, "error": "", "triangles": int(mesh.triangle_count()), "units": units, "warning": warning}


## add_mesh_import() for a mesh body: the feature keeps the triangles as a MeshBlob (in meters),
## or only the path when linked. What the reader said of the file ("warning") is given back, and
## kept with a stored mesh (options.read_warning), so the feature still carries it on later
## rebuilds, which read no file; a linked file says it again each time it is read.
static func _add_mesh_body_import(doc: Resource, path: String, units: String, linked: bool) -> Dictionary:
	var read := read_mesh_body(path, units)
	if str(read.error) != "":
		return {"feature": null, "error": read.error}
	var options := {
		"path": path, "kind": KIND_MESH, "units": str(read.units), "linked": linked, "split": false,
		"transform": Transform3D.IDENTITY, "operation": OPERATIONS.NEW_BODY,
	}
	if not linked:
		options["mesh"] = MESH_BLOB.from_mesh(read.mesh)
		options["mesh_units"] = str(read.units)
		if str(read.warning) != "":
			options["read_warning"] = str(read.warning)
	var feature: Resource = doc.add_feature("mesh_import", "Mesh", {}, options)
	var body_id: String = doc.new_body(feature.id)
	feature.options["body_id"] = body_id
	doc.bodies[body_id]["name"] = path.get_file().get_basename()
	return {"feature": feature, "error": "", "triangles": int(read.triangles), "warning": str(read.warning)}


## Insert Mesh as a mesh body. The mesh in meters comes from the stored blob, or from the file
## when linked; it is then placed (options.transform and the placement inputs). What was made is
## kept by content, so a rebuild that changes nothing gives the same CadMesh back and reads
## nothing.
static func _mesh_body_import(feature: Resource, ctx: Dictionary) -> String:
	if not MESH_BODY.available():
		return MESH_BODY.KERNEL_MISSING
	var r := UTIL.Reader.new(feature, ctx)
	var body_id := str(r.opt("body_id", ""))
	if body_id == "":
		return "The feature has no body id"
	if not OPERATIONS.creates_body(str(r.opt("operation", OPERATIONS.NEW_BODY))):
		return "A mesh body comes in as a new body (Join, Cut and Intersect need B-rep bodies)"
	var path := str(r.opt("path", ""))
	var units := str(r.opt("units", "mm"))
	var linked := bool(r.opt("linked", false)) and path != ""
	# What identifies the unplaced mesh, and a factor when the blob was read with another unit.
	var source := ""
	var factor := 1.0
	if linked:
		_record_file(path)
		if not FileAccess.file_exists(path):
			return "The linked mesh %s can't be found" % path.get_file()
		var stamp := _stamp(path)
		source = "file:%s:%d:%s:%s" % [path, int(stamp.time), str(stamp.md5), units]
	else:
		var blob: Variant = r.opt("mesh")
		var stored: PackedVector3Array = r.opt("positions", PackedVector3Array())
		if blob is Resource and (blob as Resource).get_script() == MESH_BLOB:
			source = "blob:%s" % str(blob.digest)
			var blob_units := str(r.opt("mesh_units", units))
			if blob_units != units:
				factor = MESH_IMPORT.unit_scale(units) / MESH_IMPORT.unit_scale(blob_units)
		elif not stored.is_empty():
			# A faceted insert switched to a mesh body: its stored triangles, in file units.
			source = "arrays:%d:%d:%d" % [stored.size(), hash(stored), hash(r.opt("indices", PackedInt32Array()))]
			factor = MESH_IMPORT.unit_scale(units)
		else:
			# (Its file beside the scene is gone or can't be read: the sentence names it.)
			return MESH.stored_mesh_problem(feature, "mesh")
	# The unplaced mesh's bounds (the placement inputs turn about their middle), kept by source.
	var base: RefCounted = null
	var box := AABB()
	# What the reader said of the file: kept with a stored mesh, said again by a linked file.
	var read_note := str(r.opt("read_warning", "")) if not linked else ""
	if has_offset(r):
		if not _mesh_body_bounds.has(source):
			var loaded := _mesh_body_source(feature, linked, path, units)
			if loaded.has("error"):
				return loaded.error
			base = loaded.mesh
			if linked:
				read_note = str(loaded.get("warning", ""))
			while _mesh_body_bounds.size() >= MESH_BOUNDS_SIZE:
				_mesh_body_bounds.erase(_mesh_body_bounds.keys()[0])
			_mesh_body_bounds[source] = base.bbox()
		box = _mesh_body_bounds[source]
	var scaling := Transform3D(Basis.from_scale(Vector3.ONE * factor), Vector3.ZERO)
	var xform := placement(r, scaling * box) * scaling
	if not r.ok():
		return r.error
	var split := bool(r.opt("split", false))
	var key := MESH.cache_key("mesh_import", {"xform": xform, "split": split}, [source])
	var kept := MESH.lookup(key)
	if kept.is_empty():
		if base == null:
			var loaded := _mesh_body_source(feature, linked, path, units)
			if loaded.has("error"):
				return loaded.error
			base = loaded.mesh
			if linked:
				read_note = str(loaded.get("warning", ""))
		var placed: RefCounted = base if xform.is_equal_approx(Transform3D.IDENTITY) else base.transformed(xform)
		if placed == null or placed.is_null():
			return "Insert Mesh failed: %s" % base.get_last_error()
		var pieces := [placed]
		var notes := PackedStringArray()
		if read_note != "":
			notes.append(read_note)
		var doc: Resource = ctx.get("doc")
		if split:
			# One Body per Piece: the mesh's connected pieces, each a body (a void stays with the
			# shell around it). A mesh that crosses itself splits as wrongly as it is, so it is told.
			var whole := MESH_BODY.body_name(doc, body_id)
			var crossing := MESH.crossing_note(placed, whole, minf(MESH.time_limit(ctx), MESH.SELF_INTERSECTION_SECONDS), MESH.time_limit(ctx) >= MESH.OK_SECONDS)
			if crossing != "":
				notes.append(crossing)
			var parts: Array = placed.separate({"by": "components", "time_limit": MESH.time_limit(ctx), "name": MESH.BODY_TOKEN})
			if parts.is_empty():
				return MESH.named(str(placed.get_last_error()), whole)
			pieces = parts
			# (One piece: the kernel says there was nothing to separate. That is no news for a file.)
			for line in str(placed.get_last_warning()).split("\n", false):
				if parts.size() > 1:
					notes.append(MESH.named(line.strip_edges(), whole))
		for k in pieces.size():
			var piece_id := body_id if k == 0 else UTIL.derived_body_id(body_id, feature.id, k + 1)
			notes.append_array(MESH.check_warnings(pieces[k], MESH_BODY.body_name(doc, piece_id)))
		kept = MESH.store(key, pieces, "", " ".join(notes))
	var meshes: Array = kept.meshes
	for k in meshes.size():
		var id := body_id if k == 0 else UTIL.derived_body_id(body_id, feature.id, k + 1)
		MESH.set_body(ctx, id, meshes[k], feature.id)
	if str(kept.warning) != "":
		_warn(ctx, feature, str(kept.warning))
	return ""


## The unplaced mesh of an Insert Mesh mesh body, in meters: {"mesh"} or {"error"}.
static func _mesh_body_source(feature: Resource, linked: bool, path: String, units: String) -> Dictionary:
	if not linked:
		if feature.options.get("mesh") is Resource:
			return MESH.blob_mesh(feature)
		# The triangles a faceted insert stored (file units; the caller scales them).
		var mesh: RefCounted = MESH_BODY.new_mesh()
		if not mesh.set_arrays(feature.options.get("positions", PackedVector3Array()), feature.options.get("indices", PackedInt32Array()), PackedInt32Array(), PackedStringArray(), "godot"):
			return {"error": "The stored mesh of %s can't be used: %s" % [feature.label, mesh.get_last_error()]}
		return {"mesh": mesh}
	var read := read_mesh_body(path, units)
	if str(read.error) != "":
		return {"error": "The linked mesh %s couldn't be read: %s" % [path.get_file(), read.error]}
	return {"mesh": read.mesh, "warning": str(read.warning)}


## A mesh file read in its own units (as stored in a mesh_import feature), or with "error".
static func _read_mesh(path: String) -> Dictionary:
	if not path.get_extension().to_lower() in MESH_IMPORT.EXTENSIONS:
		return {"error": "Holo Forge reads STL, OBJ, 3MF, GLB and glTF meshes"}
	var mesh := MESH_IMPORT.read_file(path, "m")
	if str(mesh.error) == "" and int(mesh.triangles) > MAX_TRIANGLES:
		mesh.error = "The mesh has %d triangles; Holo Forge takes up to %d (reduce it first)" % [mesh.triangles, MAX_TRIANGLES]
	return mesh


## The unit the mesh file at path is in by itself (file_units; a 3MF is read for the unit it
## declares), or "" when there is no such file to tell.
static func _own_units(path: String) -> String:
	if path == "":
		return ""
	if path.get_extension().to_lower() == "3mf":
		if not FileAccess.file_exists(path):
			return ""
		var mesh := MESH_IMPORT.read_file(path, "m")
		return file_units(path, mesh) if str(mesh.error) == "" else ""
	return file_units(path)


## The unit a mesh file is in by itself: the unit a 3MF file declares, meters for glTF (it is
## defined in meters), millimeters for STL and OBJ (they carry no unit; most are millimeters).
static func file_units(path: String, mesh := {}) -> String:
	if str(mesh.get("file_units", "")) != "":
		return str(mesh.file_units)
	return "m" if path.get_extension().to_lower() in ["glb", "gltf"] else "mm"


# --- Derive (bodies of another saved design) -------------------------------------------------

static func _derive(feature: Resource, ctx: Dictionary) -> String:
	var r := UTIL.Reader.new(feature, ctx)
	var source := _derived_source(clean_path(str(r.opt("path", ""))), clean_path(str(ctx.doc.resource_path)), ctx.kernel)
	if source.has("error"):
		return source.error
	var problems := 0
	for text in (source.errors as Dictionary).values():
		if str(text).begins_with(LOOP):
			return str(text)
		problems += 1
	if problems > 0:
		_warn(ctx, feature, "%s rebuilt with %d error(s)" % [str(r.opt("path", "")).get_file(), problems])
	var chosen: Array = r.opt("bodies", [])
	if chosen.is_empty():
		chosen = (source.bodies as Dictionary).keys()
	if chosen.is_empty():
		return "%s has no bodies" % str(r.opt("path", "")).get_file()
	# The bodies turn together, about the middle of all of them.
	var turns := has_offset(r)
	var box := AABB()
	for k in chosen.size():
		if not source.bodies.has(chosen[k]):
			return "%s has no body %s any more" % [str(r.opt("path", "")).get_file(), chosen[k]]
		if turns:
			var b: AABB = source.bodies[chosen[k]].shape.bbox()
			box = b if k == 0 else box.merge(b)
	var op := str(r.opt("operation", OPERATIONS.NEW_BODY))
	var shapes := []
	# The B-rep ones among them (what an operation, a pattern or a mirror works with).
	var solids := []
	for source_id in chosen:
		var source_shape: RefCounted = source.bodies[source_id].shape
		if MESH_BODY.is_mesh(source_shape):
			# A mesh body derives as a mesh body, moved by the same placement.
			if not OPERATIONS.creates_body(op):
				return MESH_BODY.GATE % str(source.bodies[source_id].get("name", source_id))
			var xform := placement(r, box)
			if not r.ok():
				return r.error
			var moved := MESH.transformed(source_shape, xform)
			if moved == null:
				return "Derive failed: %s" % source_shape.get_last_error()
			shapes.append(moved)
			continue
		var shape := _placed(r, source_shape, "Derive", box)
		if shape == null:
			return r.error
		shape = _derived_names(shape, source_shape, feature.id, str(source_id))
		shapes.append(shape)
		solids.append(shape)
	if not OPERATIONS.creates_body(op):
		return OPERATIONS.apply(ctx, feature, solids[0] if solids.size() == 1 else r.kernel.make_compound(solids))
	# Each derived body stays its own body: mapped ones keep their ids, new ones become copies.
	var body_id := str(r.opt("body_id", ""))
	var body_map: Dictionary = r.opt("body_map", {})
	var taken := {}
	for id in body_map.values():
		taken[str(id)] = true
	for k in chosen.size():
		var id := str(body_map.get(chosen[k], ""))
		if id == "":
			# A body the source gained after the insert: the feature's body id, or a copy of it.
			if body_id == "":
				return "The feature has no body id"
			id = body_id
			var n := 1
			while taken.has(id) and n < 10000:
				n += 1
				id = UTIL.derived_body_id(body_id, feature.id, n)
		taken[id] = true
		ctx.bodies[id] = MESH_BODY.entry(id, shapes[k], feature.id) if MESH_BODY.is_mesh(shapes[k]) else {"id": id, "shape": shapes[k], "feature": feature.id}
	if ctx.has("tools") and not solids.is_empty():
		ctx.tools[feature.id] = {"shape": solids[0] if solids.size() == 1 else r.kernel.make_compound(solids), "operation": op}
	return ""


## A derived body with its faces renamed under this design's derive feature: "<feature id>:<source
## body id>:<name in the source>". The source's names start with the source design's own feature
## ids ("f1:top"), which this design uses too; kept as they were, a derived face and a local face
## could share a name and swap when the parts move. shape is copied first when it is still the
## source's own (cached) shape.
static func _derived_names(shape: RefCounted, source_shape: RefCounted, feature_id: String, source_id: String) -> RefCounted:
	if shape == source_shape:
		shape = shape.copy()
	var names := PackedStringArray()
	for name in shape.get_face_names():
		names.append("%s:%s:%s" % [feature_id, source_id, name])
	shape.set_face_names(names)
	shape.name_edges_from_faces()
	return shape


## Derives every body of the saved design at path (a .tres Holo Forge document) as new bodies of
## doc, named after the source bodies. Returns {"feature", "error", "bodies": source body ids}.
static func add_derive(doc: Resource, path: String, kernel: RefCounted = null) -> Dictionary:
	if kernel == null:
		kernel = load(REGEN_PATH).make_kernel()
	if kernel == null:
		return {"feature": null, "error": "The Holo Forge kernel is not loaded"}
	path = clean_path(path)
	var source := derive_source(doc, path, kernel)
	if source.has("error"):
		return {"feature": null, "error": source.error}
	var ids: Array = (source.bodies as Dictionary).keys()
	if ids.is_empty():
		return {"feature": null, "error": "%s has no bodies" % path.get_file()}
	var feature: Resource = doc.add_feature("derive", "Derive", {}, {
		"path": path, "bodies": [], "body_map": {}, "transform": Transform3D.IDENTITY, "operation": OPERATIONS.NEW_BODY,
	})
	var body_map := {}
	for source_id in ids:
		var body_id: String = doc.new_body(feature.id)
		doc.bodies[body_id]["name"] = str(source.bodies[source_id].name)
		body_map[source_id] = body_id
	feature.options["body_map"] = body_map
	feature.options["body_id"] = body_map[ids[0]]
	return {"feature": feature, "error": "", "bodies": ids}


## The saved design at path as doc may derive it: {"bodies": {source body id: {"shape", "name"}},
## "errors", "stamps"}, or {"error"} for a missing file, doc itself, or a derive loop.
static func derive_source(doc: Resource, path: String, kernel: RefCounted) -> Dictionary:
	var source := _derived_source(clean_path(path), clean_path(str(doc.resource_path)), kernel)
	if source.has("error"):
		return source
	for text in (source.errors as Dictionary).values():
		if str(text).begins_with(LOOP):
			return {"error": str(text)}
	return source


## A design path in one spelling (res:// inside the project), so the same file always compares equal.
## A design kept inside a scene ("part.tscn::Resource_x") counts as that scene file.
static func clean_path(path: String) -> String:
	if path.strip_edges() == "":
		return ""
	return ProjectSettings.localize_path(path.strip_edges().get_slice("::", 0)).simplify_path()


## The Holo Forge design a loaded file holds: the document itself, or for a scene the document of
## its first node that has one (a CadPart); null when there is none.
static func design_in(loaded: Resource) -> Resource:
	if not loaded is PackedScene:
		return loaded
	var root: Node = (loaded as PackedScene).instantiate(PackedScene.GEN_EDIT_STATE_DISABLED)
	if root == null:
		return null
	var found: Resource = null
	for node in [root] + root.find_children("*", "", true, false):
		var doc: Variant = node.get("document")
		if doc is Resource and "features" in doc and (doc as Resource).has_method("active_count"):
			found = doc
			break
	root.free()
	return found


## The saved design at path rebuilt for a design at own ("" when unsaved), refusing a design
## that derives from itself or from a design deriving from it. {"bodies", "errors"} or {"error"}.
static func _derived_source(path: String, own: String, kernel: RefCounted) -> Dictionary:
	if path == "":
		return {"error": "Pick a saved Holo Forge design to derive from"}
	var chain: Array[String] = _deriving.duplicate()
	if own != "" and (chain.is_empty() or chain.back() != own):
		chain.append(own)
	if not chain.is_empty() and chain.back() == path:
		return {"error": "A design can't derive from itself"}
	if chain.has(path):
		var names := PackedStringArray()
		for p in chain:
			names.append(p.get_file())
		names.append(path.get_file())
		return {"error": "%s: %s" % [LOOP, " -> ".join(names)]}
	return source_bodies(path, kernel, chain)


## A saved design's bodies: {"bodies": {source body id: {"shape", "name"}}, "errors": {feature id:
## text}, "stamps"} or {"error"}. Rebuilt once and reused until the file (or a design it derives
## from) is saved again. chain: the designs deriving it, outermost first.
static func source_bodies(path: String, kernel: RefCounted, chain: Array[String] = []) -> Dictionary:
	var cached: Dictionary = _derive_cache.get(path, {})
	# An entry that read a design of the chain was built outside this loop: rebuild to find it.
	var looped := chain.any(func(p: String) -> bool: return (cached.get("stamps", {}) as Dictionary).has(p))
	if not cached.is_empty() and not looped and _fresh(cached.stamps):
		_record(cached.stamps)
		return cached
	if not FileAccess.file_exists(path):
		return {"error": "%s can't be found" % path.get_file()}
	# Stamped before it is read, so a save made while it is read counts as a change.
	var stamps := {path: _stamp(path)}
	# (A binary file cut short or damaged can crash Godot's loader itself, so it is checked first.)
	if not RESOURCE_FILE.safe_to_load(path):
		return {"error": "%s is damaged (cut short?) and can't be read" % path.get_file()}
	var loaded: Resource = design_in(ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE))
	if loaded == null or not ("features" in loaded) or not loaded.has_method("active_count"):
		return {"error": "%s isn't a Holo Forge design" % path.get_file()}
	var outer := _deriving
	_deriving = chain.duplicate()
	_deriving.append(path)
	_recorders.append(stamps)
	var result: Dictionary = load(REGEN_PATH).rebuild(loaded, kernel)
	_recorders.pop_back()
	_deriving = outer
	_record(stamps)
	var bodies := {}
	for id in result.bodies:
		bodies[id] = {"shape": result.bodies[id].shape, "name": loaded.body_name(id)}
	var entry := {"bodies": bodies, "errors": result.errors, "stamps": stamps}
	# A loop depends on who is deriving, so such a result isn't kept.
	if not (result.errors as Dictionary).values().any(func(text) -> bool: return str(text).begins_with(LOOP)):
		_derive_cache[path] = entry
	return entry


## Forgets every rebuilt source design (they are rebuilt on next use).
static func clear_derive_cache() -> void:
	_derive_cache.clear()


## True while every file a cache entry read is as it was then.
static func _fresh(stamps: Dictionary) -> bool:
	for p in stamps:
		if not _unchanged(p, stamps[p]):
			return false
	return true


## A file's stamp: {"time": its modified time (-1 when the file is missing), "size": its length
## in bytes (-1 when missing), "md5": its content hash ("" when missing)}. The time alone does not
## tell a change: file times have whole seconds, and a file copied over another can keep the old
## time. So the size and the content count too, whatever the file's age.
static func _stamp(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"time": -1, "size": -1, "md5": ""}
	return {"time": FileAccess.get_modified_time(path), "size": FileAccess.get_size(path), "md5": FileAccess.get_md5(path)}


## True when the file at path still matches stamp (from _stamp): the same time, size and content.
## A stamp without a size or a content hash (made before they were kept) never matches, so the
## file is read once more.
static func _unchanged(path: String, stamp: Variant) -> bool:
	if not stamp is Dictionary or not (stamp as Dictionary).has("time") or not (stamp as Dictionary).has("size") or str((stamp as Dictionary).get("md5", "")) == "":
		return stamp is Dictionary and int((stamp as Dictionary).get("time", 0)) == -1 and (stamp as Dictionary).has("size") and not FileAccess.file_exists(path)
	if not FileAccess.file_exists(path):
		return false
	if FileAccess.get_modified_time(path) != int(stamp.time) or FileAccess.get_size(path) != int(stamp.size):
		return false
	return FileAccess.get_md5(path) == str(stamp.md5)


static func _record(stamps: Dictionary) -> void:
	for recorder in _recorders:
		recorder.merge(stamps)


## Notes a file a feature reads (a linked import's) in the Derive rebuilds in progress, so their
## cache entries go stale when it changes.
static func _record_file(path: String) -> void:
	if not _recorders.is_empty():
		_record({path: _stamp(path)})


# --- Another file for an insert --------------------------------------------------------------

## Points an Import, Insert Mesh or Derive feature at another file (its edit panel does this).
## The file is read first: import and mesh keep a copy of it, so the design works without it;
## derive checks that it is a design this one may use. Nothing changes when it can't be read.
## A body still named after the old file takes the new one's name. Returns {"error": "" or why,
## "note": a line for the panel}; a mesh's "units" follow the new file when it says what they are
## (3MF, glTF) or when they were only the old file's own; a derive's source bodies take over the feature's bodies in order (what was built
## on them carries on), extra ones become new bodies, left-over ones go, and every body comes in.
static func change_source(doc: Resource, feature: Resource, path: String, kernel: RefCounted = null) -> Dictionary:
	path = path.strip_edges()
	if path == "":
		return {"error": "Choose a file"}
	if kernel == null and feature.type in ["import", "derive"]:
		kernel = load(REGEN_PATH).make_kernel()
		if kernel == null:
			return {"error": "The Holo Forge kernel is not loaded"}
	var old_path := str(feature.options.get("path", ""))
	match feature.type:
		"import":
			if not path.get_extension().to_lower() in IMPORT_EXTENSIONS:
				return {"error": "Holo Forge imports STEP, IGES, BREP and STL files"}
			if not FileAccess.file_exists(path):
				return {"error": "%s can't be found" % path.get_file()}
			var shape: RefCounted = kernel.import_file(path, feature.id)
			if shape == null or shape.is_null():
				return {"error": "%s couldn't be read: %s" % [path.get_file(), kernel.get_last_error()]}
			var data: PackedByteArray = shape.to_brep_bytes()
			if data.is_empty():
				return {"error": "%s couldn't be stored in the design" % path.get_file()}
			# The new file's faces take the names of the old one's faces where they are the same
			# faces, so what was built on them carries on (by order they would swap at random).
			var kept := _kept_copy(feature.options, feature.id)
			if kept.has("shape"):
				match_face_names(shape, kept.shape, feature.id)
			feature.options["data"] = data
			feature.options["face_names"] = shape.get_face_names()
			feature.options["path"] = path
			_rename_file_body(doc, feature, old_path, path)
			return {"error": "", "note": "%s: %d solid(s)" % [path.get_file(), shape.solid_count()]}
		"mesh_import":
			if mesh_kind(feature) == KIND_MESH:
				return _change_mesh_body(doc, feature, path)
			var mesh := _read_mesh(path)
			if str(mesh.error) != "":
				return {"error": str(mesh.error)}
			# Units the old file gave by itself (its format's, or a 3MF's declared unit) were never
			# the user's choice, so they follow the new file, as a fresh insert's "From the File" does.
			var from_old_file := str(feature.options.get("units", "mm")) == _own_units(old_path)
			feature.options["positions"] = mesh.positions
			feature.options["indices"] = mesh.indices
			feature.options["path"] = path
			if from_old_file or str(mesh.get("file_units", "")) != "" or path.get_extension().to_lower() in ["glb", "gltf"]:
				feature.options["units"] = file_units(path, mesh)
			_rename_file_body(doc, feature, old_path, path)
			return {"error": "", "note": "%s: %d triangles" % [path.get_file(), int(mesh.triangles)], "units": str(feature.options.get("units", "mm"))}
		"derive":
			return _change_derive(doc, feature, clean_path(path), kernel)
	return {"error": "%s doesn't come from a file" % feature.label}


## change_source() for an Insert Mesh mesh body: the new file's triangles replace the stored blob
## (a linked one only takes the path). Units follow the new file as for a faceted mesh.
static func _change_mesh_body(doc: Resource, feature: Resource, path: String) -> Dictionary:
	var old_path := str(feature.options.get("path", ""))
	var from_old_file := str(feature.options.get("units", "mm")) == _own_units(old_path)
	var keeps_units := not from_old_file and not path.get_extension().to_lower() in ["3mf", "glb", "gltf"]
	var read := read_mesh_body(path, str(feature.options.get("units", "mm")) if keeps_units else "")
	if str(read.error) != "":
		return {"error": str(read.error)}
	feature.options["path"] = path
	feature.options["units"] = str(read.units)
	if bool(feature.options.get("linked", false)):
		feature.options.erase("mesh")
		feature.options.erase("mesh_units")
	else:
		feature.options["mesh"] = MESH_BLOB.from_mesh(read.mesh)
		feature.options["mesh_units"] = str(read.units)
	_rename_file_body(doc, feature, old_path, path)
	return {"error": "", "note": "%s: %d triangles" % [path.get_file(), int(read.triangles)], "units": str(read.units)}


static func _change_derive(doc: Resource, feature: Resource, path: String, kernel: RefCounted) -> Dictionary:
	var source := derive_source(doc, path, kernel)
	if source.has("error"):
		return {"error": str(source.error)}
	var ids: Array = (source.bodies as Dictionary).keys()
	if ids.is_empty():
		return {"error": "%s has no bodies" % path.get_file()}
	var old_map: Dictionary = feature.options.get("body_map", {})
	# The bodies this feature made: its body id first, then the rest of the old map.
	var owned: Array[String] = []
	for id in [str(feature.options.get("body_id", ""))] + old_map.values():
		if not owned.has(str(id)) and str((doc.bodies.get(str(id), {}) as Dictionary).get("feature", "")) == feature.id:
			owned.append(str(id))
	# Bodies the user renamed keep their names; the others take the new source's.
	var old_names := {}
	var old_path := clean_path(str(feature.options.get("path", "")))
	var old_source := derive_source(doc, old_path, kernel) if old_path != "" and old_path != path else {}
	for source_id in old_map:
		if (old_source.get("bodies", {}) as Dictionary).has(source_id):
			old_names[str(old_map[source_id])] = str(old_source.bodies[source_id].name)
	# A source body with the same id as before keeps its body (a moved copy of the same design);
	# the others take the free bodies in order, then new ones.
	var body_map := {}
	var free := owned.duplicate()
	for source_id in ids:
		var kept := str(old_map.get(source_id, ""))
		if free.has(kept):
			body_map[source_id] = kept
			free.erase(kept)
	var component := str(feature.options.get("component_id", ""))
	for source_id in ids:
		if body_map.has(source_id):
			continue
		var id: String = free.pop_front() if not free.is_empty() else ""
		if id == "":
			id = doc.new_body(feature.id)
			if component != "" and doc.components.has(component):
				doc.bodies[id]["component"] = component
		body_map[source_id] = id
	for source_id in ids:
		var id := str(body_map[source_id])
		if not old_names.has(id) or str(doc.bodies[id].get("name", "")) == str(old_names[id]):
			doc.bodies[id]["name"] = str(source.bodies[source_id].name)
	for id in free:
		doc.bodies.erase(id)
	feature.options["body_map"] = body_map
	if not body_map.values().has(str(feature.options.get("body_id", ""))):
		feature.options["body_id"] = body_map[ids[0]]
	feature.options["bodies"] = []
	feature.options["path"] = path
	return {"error": "", "note": "%s: %d body(ies)" % [path.get_file(), ids.size()], "bodies": ids}


## The feature's body takes the new file's name while it still has the old file's.
static func _rename_file_body(doc: Resource, feature: Resource, old_path: String, path: String) -> void:
	var body_id := str(feature.options.get("body_id", ""))
	if doc.bodies.has(body_id) and str(doc.bodies[body_id].get("name", "")) == old_path.get_file().get_basename():
		doc.bodies[body_id]["name"] = path.get_file().get_basename()


# --- Fasteners -------------------------------------------------------------------------------

## {kind: {"label", "standard", "sizes": {name: {...}}}} with lengths in millimeters, as stored.
static func fastener_table() -> Dictionary:
	if _fasteners.is_empty():
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(FASTENER_TABLE))
		_fasteners = parsed.get("kinds", {}) if parsed is Dictionary else {}
	return _fasteners


static func fastener_kinds() -> Array:
	return fastener_table().keys()


static func fastener_sizes(kind: String) -> Array:
	return ((fastener_table().get(kind, {}) as Dictionary).get("sizes", {}) as Dictionary).keys()


## One size with every length in meters: {"kind", "size", "label", "standard", "d", "pitch", and
## the kind's own dimensions (s, k, dk, t, b, m, hole, d1, d2, h), "lengths": [meters],
## "default_length"}; {} for an unknown kind or size.
static func fastener_size(kind: String, size: String) -> Dictionary:
	var entry: Dictionary = fastener_table().get(kind, {})
	var spec: Dictionary = (entry.get("sizes", {}) as Dictionary).get(size, {})
	if spec.is_empty():
		return {}
	var result := {"kind": kind, "size": size, "label": str(entry.get("label", kind)), "standard": str(entry.get("standard", ""))}
	for key in spec:
		if spec[key] is Array:
			result[key] = (spec[key] as Array).map(func(v) -> float: return float(v) * 0.001)
		else:
			result[key] = float(spec[key]) * 0.001
	return result


static func _fastener(feature: Resource, ctx: Dictionary) -> String:
	var r := UTIL.Reader.new(feature, ctx)
	var kind := str(r.opt("kind", "hex_bolt"))
	var size := str(r.opt("size", "M6"))
	var spec := fastener_size(kind, size)
	if spec.is_empty():
		return "There is no %s %s" % [size, kind.replace("_", " ")]
	var placed := fastener_placement(feature, ctx)
	if str(placed.warning) != "":
		_warn(ctx, feature, str(placed.warning))
	var axis: Vector3 = placed.axis
	if axis.length() < 1e-9:
		return "The fastener's axis has no direction"
	var length := r.num("length", spec.get("default_length", 0.01), "positive") if kind in BOLTS else 0.0
	# The turn is an input (a model parameter) when Insert Fastener made it, else an option.
	var angle := r.num("angle", float(r.opt("angle", 0.0)))
	if not r.ok():
		return r.error
	var position: Vector3 = placed.position
	var shape := fastener_shape(r.kernel, spec, position, axis, length, angle, feature.id)
	if shape != null and ctx.has("threads"):
		var n := axis.normalized()
		var key := "%s:%s" % [feature.id, str(r.opt("body_id", ""))]
		if kind in BOLTS:
			# ISO 4017 bolts are threaded all the way; socket screws for their b length.
			var threaded := minf(float(spec.get("b", length)), length)
			ctx.threads[key] = {"origin": position + n * (length - threaded), "axis": n, "radius": spec.d * 0.5, "major": spec.d,
				"pitch": spec.pitch, "length": threaded, "size": size, "internal": false}
		elif kind == "hex_nut":
			ctx.threads[key] = {"origin": position, "axis": n, "radius": spec.hole * 0.5, "major": spec.d,
				"pitch": spec.pitch, "length": spec.m, "size": size, "internal": true}
	return UTIL.finish(r, shape, spec.label)


## Where a fastener sits in a rebuild (ctx: the bodies so far): {"position", "axis", "followed":
## true when it was found on its geometry, "warning": "" or a note}. Placed on geometry
## (options place and follow) it finds the face, edge or point again: on a face see place_on()
## (it keeps its spot while the face grows or shrinks around it, and rides along when the face
## moves or turns), on a round edge at its center, on a point there. With direction "auto" the
## axis comes from the face's normal: bolts go into it, nuts and washers stand on it (flip turns
## it round). When the geometry can't be found it stays at options.position along options.axis,
## with a warning; a spot that ended up off its face is put on the face's edge, with a warning.
## Fasteners without follow (older designs, or placed by coordinates) use those two as they are.
static func fastener_placement(feature: Resource, ctx: Dictionary) -> Dictionary:
	var out := {"position": feature.options.get("position", Vector3.ZERO), "axis": feature.options.get("axis", Vector3.DOWN),
		"followed": false, "warning": ""}
	var place: Array = feature.options.get("place", [])
	if not bool(feature.options.get("follow", false)) or place.is_empty() or not place[0] is Dictionary:
		return out
	var found := place_on(place[0], ctx, out.position)
	if found.has("error"):
		out.warning = "%s, so the fastener stays where it was placed" % str(found.error)
		return out
	out.position = found.position
	out.followed = true
	if bool(found.get("repaired", false)):
		out.warning = "The geometry the fastener sits on was found again by shape; check the result"
	elif bool(found.get("off_face", false)):
		out.warning = "The fastener's spot is off the face it sits on now, so it was put on the face's edge; check the result"
	var normal: Vector3 = found.normal
	if str(feature.options.get("direction", "")) == "auto" and normal.length() > 1e-9:
		var n := normal.normalized()
		var axis := -n if str(feature.options.get("kind", "")) in BOLTS else n
		out.axis = -axis if bool(feature.options.get("flip", false)) else axis
	return out


## Where a fastener goes on a picked reference: {"position", "normal" (outward; zero when the
## pick has none), "repaired", "off_face" (faces: its spot was off the face, so the face's nearest
## point, on its edge, was taken)} or {"error"}. On a face it lands on the face's nearest point
## to its spot (also on a curved face, and just along the normal when the face only moved that
## way). The spot is near, carried along with the face when the reference is anchored there: its
## "at" is near, the spot on the face when its sig was taken. Then, while the face kept its area
## (moved or turned whole), the spot moves and turns with the face's middle; when the face grew,
## shrank or got a hole the spot stays, unless it is off the face now, then it moves with the
## middle too. A reference without "at" (a fresh pick, older designs) or whose spot was moved
## since (near isn't its "at") takes near as it is. A round edge gives its center (a straight one
## its middle) with the flat face beside it as the normal (a hole's rim says which way is out); a
## point itself.
static func place_on(ref: Dictionary, ctx: Dictionary, near: Vector3) -> Dictionary:
	match str(ref.get("kind", "")):
		"face":
			var found := REFERENCES.face(ref, ctx)
			if found.has("error"):
				return found
			var shape: RefCounted = found.shape
			var face: RefCounted = shape.face_shape(found.index)
			var sig: Dictionary = ref.get("sig", {})
			var info: Dictionary = shape.face_info(found.index)
			var carried := near
			var whole := false
			var anchored := ref.get("at") is Vector3 and (ref.at as Vector3).distance_to(near) <= 1e-9
			if anchored and sig.has("point") and info.has("point") and str(sig.get("type", "")) == str(info.get("type", "")):
				# The spot as an offset from the face's middle, turned as the face turned.
				var offset: Vector3 = near - (sig.point as Vector3)
				var was: Vector3 = sig.get("normal", Vector3.ZERO)
				var now: Vector3 = info.get("normal", Vector3.ZERO)
				if not was.is_zero_approx() and not now.is_zero_approx():
					var turn := was.normalized().dot(now.normalized())
					if turn < 1.0 - 1e-9 and turn > -1.0 + 1e-6:
						offset = Quaternion(was.normalized(), now.normalized()) * offset
				carried = (info.point as Vector3) + offset
				var area := float(sig.get("area", 0.0))
				whole = area > 0.0 and absf(float(info.get("area", 0.0)) - area) <= area * 1e-6
			var spot := _nearest_on_face(ctx.kernel, face, carried if whole else near)
			if not whole and bool(spot.off) and carried != near:
				var moved := _nearest_on_face(ctx.kernel, face, carried)
				if float(moved.gap) < float(spot.gap):
					spot = moved
			return {"position": spot.point, "normal": shape.face_normal_at(found.index, spot.point), "repaired": found.repaired, "off_face": spot.off}
		"edge":
			var found := REFERENCES.edge(ref, ctx)
			if found.has("error"):
				return found
			var info: Dictionary = found.shape.edge_info(found.index)
			var normal := Vector3.ZERO
			for f in info.get("faces", PackedInt32Array()):
				var face: Dictionary = found.shape.face_info(int(f))
				if face.get("planar", false):
					normal = face.normal
					break
			if normal == Vector3.ZERO and info.has("axis"):
				normal = info.axis
			return {"position": info.get("center", info.midpoint), "normal": normal, "repaired": found.repaired}
	var p := REFERENCES.point(ref, ctx)
	if p.has("error"):
		return p
	return {"position": p.point, "normal": Vector3.ZERO, "repaired": false}


## The point of face (a one-face shape) nearest p: {"point", "off": p lies beside the face (past
## its edge) rather than just above or below it, "gap": how far beside, in meters}.
static func _nearest_on_face(kernel: RefCounted, face: RefCounted, p: Vector3) -> Dictionary:
	var point := p
	var closest: Dictionary = kernel.closest_points(face, kernel.make_vertex(p))
	if closest.has("a"):
		point = closest.a
	var d := point - p
	var normal: Vector3 = face.face_normal_at(0, point)
	var gap := 0.0
	if not normal.is_zero_approx():
		normal = normal.normalized()
		gap = (d - normal * d.dot(normal)).length()
	return {"point": point, "off": gap > OFF_FACE, "gap": gap}


## The fastener's solid (null when the kernel fails; see get_last_error). spec from
## fastener_size(); length (meters) for bolts; angle turns the hexagons about the axis.
static func fastener_shape(kernel: RefCounted, spec: Dictionary, position: Vector3, axis: Vector3, length: float, angle: float, tag: String) -> RefCounted:
	var n := axis.normalized()
	var x := _perpendicular(n).rotated(n, angle)
	match str(spec.kind):
		"hex_bolt":
			var head := _hex_prism(kernel, position, -n, x, spec.s, spec.k, tag)
			var shank: RefCounted = kernel.make_cylinder(spec.d * 0.5, length, position, n, tag)
			return _combine(kernel, head, shank, 0, tag)
		"socket_bolt":
			var head: RefCounted = kernel.make_cylinder(spec.dk * 0.5, spec.k, position, -n, tag)
			# The socket's tool starts above the head so the cut is clean.
			var margin: float = spec.t * 0.25
			var socket := _hex_prism(kernel, position - n * (spec.k + margin), n, x, spec.s, spec.t + margin, tag)
			head = _combine(kernel, head, socket, 1, tag)
			var shank: RefCounted = kernel.make_cylinder(spec.d * 0.5, length, position, n, tag)
			return _combine(kernel, head, shank, 0, tag)
		"hex_nut":
			var body := _hex_prism(kernel, position, n, x, spec.s, spec.m, tag)
			var margin: float = spec.m * 0.25
			var bore: RefCounted = kernel.make_cylinder(spec.hole * 0.5, spec.m + margin * 2.0, position - n * margin, n, tag)
			return _combine(kernel, body, bore, 1, tag)
		"washer":
			var disc: RefCounted = kernel.make_cylinder(spec.d2 * 0.5, spec.h, position, n, tag)
			var margin: float = spec.h * 0.25
			var bore: RefCounted = kernel.make_cylinder(spec.d1 * 0.5, spec.h + margin * 2.0, position - n * margin, n, tag)
			return _combine(kernel, disc, bore, 1, tag)
	return null


static func _combine(kernel: RefCounted, a: RefCounted, b: RefCounted, op: int, tag: String) -> RefCounted:
	if a == null or b == null or a.is_null() or b.is_null():
		return null
	return kernel.boolean(a, b, op, tag)


## A hexagonal prism: across_flats wide (flats facing x), rising height along normal from origin.
static func _hex_prism(kernel: RefCounted, origin: Vector3, normal: Vector3, x: Vector3, across_flats: float, height: float, tag: String) -> RefCounted:
	var corner := across_flats / sqrt(3.0)
	var points := PackedVector2Array()
	for k in 6:
		var a := PI / 6.0 + k * PI / 3.0
		points.append(Vector2(cos(a), sin(a)) * corner)
	var plane := Transform3D(Basis(x, normal.cross(x), normal), origin)
	var regions: Array = kernel.sketch_regions([{"type": "polyline", "points": points, "closed": true}], plane, PROFILE_DEFLECTION)
	if regions.is_empty():
		return null
	return kernel.extrude(regions[0].face, {"direction": normal, "distance": height, "tag": tag})


## A unit vector square to n (world X or Z projected onto n's plane).
static func _perpendicular(n: Vector3) -> Vector3:
	var reference := Vector3.RIGHT if absf(n.dot(Vector3.RIGHT)) < 0.9 else Vector3.BACK
	return (reference - n * reference.dot(n)).normalized()


## Inserts a fastener as a new body. kind: hex_bolt | socket_bolt | hex_nut | washer; size: "M3"
## to "M12"; axis: the shank's direction (default down); length_expression: a bolt's length
## ("" uses the size's default); on: a face, edge or point reference to place it on (it then
## follows that geometry, sitting on it near position with its axis from the face; axis is kept
## for when the geometry is lost). Returns {"feature", "error"}.
static func add_fastener(doc: Resource, kind: String, size: String, position: Vector3, axis := Vector3.DOWN, length_expression := "", on := {}) -> Dictionary:
	var spec := fastener_size(kind, size)
	if spec.is_empty():
		return {"feature": null, "error": "There is no %s %s" % [size, kind.replace("_", " ")]}
	var inputs := {}
	if kind in BOLTS:
		var stored: Dictionary = fastener_table()[kind].sizes[size]
		var expression := length_expression if length_expression.strip_edges() != "" else "%s mm" % String.num(float(stored.get("default_length", 10)))
		inputs["length"] = doc.make_input(expression, "length")
	var feature: Resource = doc.add_feature("fastener", "Fastener", inputs, {
		"kind": kind, "size": size, "position": position, "axis": axis, "angle": 0.0, "operation": OPERATIONS.NEW_BODY,
	})
	if not on.is_empty():
		# Anchored at position: on's sig is the face as it was there, so the spot rides along.
		var anchored: Dictionary = on.duplicate(true)
		anchored["at"] = position
		feature.options.merge({"place": [anchored], "follow": true, "direction": "auto", "flip": false, "base_axis": axis})
	var body_id: String = doc.new_body(feature.id)
	feature.options["body_id"] = body_id
	doc.bodies[body_id]["name"] = "%s %s" % [size, spec.label]
	return {"feature": feature, "error": ""}
