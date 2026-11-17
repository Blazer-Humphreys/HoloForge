@tool
extends RefCounted
## The Mesh workspace's selection: triangles of mesh bodies, picked as whole face groups
## (mode "groups", the default) or one by one (mode "triangles").
##
## The selection is kept as triangles per body: {body id: PackedInt32Array, sorted, no repeats}
## (indices of the body's stored triangles, as CadMesh.tessellate() orders them). In "groups" mode
## a face group is selected when any of its triangles is, so every change there is grown to whole
## groups. Triangle indices only mean something on the mesh they were picked on: prune() drops a
## body's selection when its mesh changed (another digest) or the body is gone.
##
## Shapes are passed in by the caller (the regen result's CadMesh of a body id): the model holds
## no meshes.
##
##   set_mode("groups" | "triangles")       keeps what is selected (grown to groups in "groups")
##   click(pick, shift, ctrl, shape)        a view pick (core/picking.gd "mesh_group" /
##                                          "mesh_triangle"): plain toggles it, Shift adds, Ctrl
##                                          removes; an empty pick clears (unless Shift or Ctrl)
##   add / remove / set_triangles(body, triangles, shape)
##   select_region(body, shape, planes, crossing, remove)   CadMesh.triangles_in_frustum
##   paint(body, shape, point, radius)      CadMesh.triangles_near (the patch under the brush)
##   grow(shapes) / shrink(shapes)          one ring of edge neighbours ("groups": neighbour groups)
##   connected(shapes, angle)               flood fill across edges up to angle (180: the piece)
##   boundary(shapes)                       the triangles along the open edges that touch the
##                                          selection; with nothing selected, along every open edge
##                                          of every body in shapes
##   as_picks(shapes)                       what a tool panel stores: "mesh_group" references in
##                                          "groups" mode, one "mesh_triangles" reference per body
##                                          in "triangles" mode (core/references.gd)
##   prune(shapes) / clear() / is_empty() / count() / bodies() / triangles_of(body) /
##   groups_of(body, shape)
## shapes: {body id: CadMesh}. Every change emits `changed`.

signal changed

const GROUPS := "groups"
const TRIANGLES := "triangles"
const MODES := [GROUPS, TRIANGLES]
## Select Connected's angle, and the one that takes the whole connected piece.
const CONNECTED_ANGLE := 30.0
const WHOLE_ANGLE := 180.0
## Select Boundary looks this far (as a fraction of the body's size) around each open-edge point.
const BOUNDARY_REACH := 1e-6
## Select Boundary stops asking after this many open-edge points per body.
const BOUNDARY_POINTS := 200000

var mode := GROUPS
## What is under the cursor: {} or {"body", "triangles": PackedInt32Array} (drawn, never stored).
var hover := {}

## triangle_groups() answers: mesh digest -> each triangle's group index.
const GROUP_MAPS := 4
static var _group_maps := {}

var _triangles := {}
## The digest of each selected body's mesh when its triangles were picked.
var _digests := {}


func set_mode(value: String, shapes := {}) -> void:
	if not MODES.has(value) or value == mode:
		return
	mode = value
	if mode == GROUPS:
		for body_id in _triangles.keys():
			_triangles[body_id] = _whole_groups(_triangles[body_id], shapes.get(body_id))
	changed.emit()


func is_empty() -> bool:
	return _triangles.is_empty()


## How many triangles are selected.
func count() -> int:
	var total := 0
	for body_id in _triangles:
		total += (_triangles[body_id] as PackedInt32Array).size()
	return total


func bodies() -> Array:
	return _triangles.keys()


func triangles_of(body_id: String) -> PackedInt32Array:
	return _triangles.get(body_id, PackedInt32Array())


## The names of the face groups with a selected triangle, in group order.
func groups_of(body_id: String, shape: RefCounted) -> PackedStringArray:
	var names := PackedStringArray()
	if shape == null or not _triangles.has(body_id):
		return names
	var all: PackedStringArray = shape.get_face_names()
	for index in _group_indices(_triangles[body_id], shape):
		if index >= 0 and index < all.size():
			names.append(all[index])
	return names


func clear() -> void:
	if _triangles.is_empty() and hover.is_empty():
		return
	_triangles.clear()
	_digests.clear()
	hover = {}
	changed.emit()


## Sets what is under the cursor (a view pick, or {}): true when it changed.
func set_hover(pick: Dictionary, shape: RefCounted) -> bool:
	var next := {}
	if not pick.is_empty() and shape != null:
		var triangles := _pick_triangles(pick, shape)
		if not triangles.is_empty():
			next = {"body": str(pick.body), "triangles": triangles}
	if next.is_empty() and hover.is_empty():
		return false
	if not next.is_empty() and not hover.is_empty() and str(next.body) == str(hover.body) and next.triangles == hover.triangles:
		return false
	hover = next
	return true


## A click in the view. pick: a "mesh_group" or "mesh_triangle" pick of core/picking.gd ({} for
## a click on nothing); shape: the picked body's CadMesh.
func click(pick: Dictionary, shift: bool, ctrl: bool, shape: RefCounted) -> void:
	if pick.is_empty() or shape == null:
		if not shift and not ctrl:
			clear()
		return
	var body_id := str(pick.body)
	var triangles := _pick_triangles(pick, shape)
	if triangles.is_empty():
		return
	if ctrl:
		remove(body_id, triangles, shape)
	elif shift or not _holds(body_id, triangles):
		add(body_id, triangles, shape)
	else:
		remove(body_id, triangles, shape)


func add(body_id: String, triangles: PackedInt32Array, shape: RefCounted) -> void:
	if triangles.is_empty() or shape == null:
		return
	_take(body_id, _union(triangles_of(body_id), _in_range(triangles, shape)), shape)


func remove(body_id: String, triangles: PackedInt32Array, shape: RefCounted) -> void:
	if not _triangles.has(body_id) or triangles.is_empty():
		return
	var gone := triangles
	if mode == GROUPS and shape != null:
		gone = _whole_groups(_in_range(triangles, shape), shape)
	_take(body_id, _difference(_triangles[body_id], gone), shape, false)


func set_triangles(body_id: String, triangles: PackedInt32Array, shape: RefCounted) -> void:
	_take(body_id, _in_range(triangles, shape) if shape != null else PackedInt32Array(), shape)


## A window or freeform region: planes are the region's sides (Plane values whose normals point
## out of it, as Camera3D.get_frustum() gives them); crossing takes triangles that reach into it,
## else only those wholly inside. remove takes them out of the selection instead.
func select_region(body_id: String, shape: RefCounted, planes: Array, crossing: bool, remove_them := false) -> PackedInt32Array:
	if shape == null or planes.is_empty():
		return PackedInt32Array()
	var found: PackedInt32Array = shape.triangles_in_frustum(planes, "crossing" if crossing else "inside")
	if remove_them:
		remove(body_id, found, shape)
	else:
		add(body_id, found, shape)
	return found


## Paint selection: the patch of triangles within radius of a point on the mesh.
func paint(body_id: String, shape: RefCounted, point: Vector3, radius: float) -> void:
	if shape == null:
		return
	add(body_id, shape.triangles_near(point, maxf(radius, 0.0), true), shape)


## One ring of edge neighbours more (in "groups" mode: the groups next to the selected ones).
func grow(shapes: Dictionary) -> void:
	_each(shapes, func(triangles: PackedInt32Array, shape: RefCounted) -> PackedInt32Array:
		return shape.grow(triangles, 1))


## One ring less. In "groups" mode whole groups are selected, so a ring taken off their rim would
## be grown straight back: there the groups whose every neighbour triangle is selected stay.
func shrink(shapes: Dictionary) -> void:
	if mode == GROUPS:
		var inner_groups := func(triangles: PackedInt32Array, shape: RefCounted) -> PackedInt32Array:
			var inner: PackedInt32Array = shape.shrink(triangles, 1)
			# A group that lost a triangle touches something unselected: it goes.
			var kept := PackedInt32Array()
			var lost := {}
			for index in _group_indices(_difference(triangles, inner), shape):
				lost[index] = true
			for index in _group_indices(triangles, shape):
				if not lost.has(index):
					kept.append_array(shape.group_triangles(index))
			kept.sort()
			return kept
		_each(shapes, inner_groups, false)
		return
	_each(shapes, func(triangles: PackedInt32Array, shape: RefCounted) -> PackedInt32Array:
		return shape.shrink(triangles, 1))


## Everything reached from the selection across edges that turn by at most angle degrees.
func connected(shapes: Dictionary, angle := CONNECTED_ANGLE) -> void:
	_each(shapes, func(triangles: PackedInt32Array, shape: RefCounted) -> PackedInt32Array:
		return shape.connected(triangles, clampf(angle, 0.0, WHOLE_ANGLE)))


## The triangles along open edges: of the open loops that touch the selection, or (nothing
## selected) of every open loop of every body in shapes. Returns how many loops were taken.
func boundary(shapes: Dictionary) -> int:
	var taken := 0
	var all := _triangles.is_empty()
	var next := {}
	for body_id in (shapes.keys() if all else _triangles.keys()):
		var shape: RefCounted = shapes.get(body_id)
		if shape == null:
			continue
		var chosen := {}
		for t in triangles_of(body_id):
			chosen[t] = true
		var reach := maxf((shape.bbox() as AABB).size.length() * BOUNDARY_REACH, 1e-9)
		var found := PackedInt32Array()
		var asked := 0
		for loop in shape.boundary_loops():
			var along := PackedInt32Array()
			for point in (loop.points as PackedVector3Array):
				if asked >= BOUNDARY_POINTS:
					break
				asked += 1
				along.append_array(shape.triangles_near(point, reach, false))
			var touches := all
			if not touches:
				for t in along:
					if chosen.has(t):
						touches = true
						break
			if touches and not along.is_empty():
				found.append_array(along)
				taken += 1
		if not found.is_empty():
			next[body_id] = _unique(found)
	if taken == 0:
		return 0
	_triangles.clear()
	_digests.clear()
	for body_id in next:
		var shape: RefCounted = shapes[body_id]
		_triangles[body_id] = _whole_groups(next[body_id], shape) if mode == GROUPS else next[body_id]
		_digests[body_id] = str(shape.digest())
	changed.emit()
	return taken


## The selection as references (core/references.gd), by name and triangle numbers only. A tool
## panel does not store these: when it takes the selection over it adds a point on each pick and
## the facing there (FEATURE_COMMAND._prefill), which a face group needs to be found again after
## an earlier change renames the groups.
func as_picks(shapes: Dictionary) -> Array:
	var picks := []
	for body_id in _triangles:
		var shape: RefCounted = shapes.get(body_id)
		if shape == null:
			continue
		if mode == GROUPS:
			for name in groups_of(body_id, shape):
				picks.append({"kind": "mesh_group", "body": body_id, "group": name})
		else:
			picks.append(triangle_pick(body_id, _triangles[body_id], shape))
	return picks


## A "mesh_triangles" reference for triangles of a body's mesh.
static func triangle_pick(body_id: String, triangles: PackedInt32Array, shape: RefCounted) -> Dictionary:
	return {"kind": "mesh_triangles", "body": body_id, "triangles": triangles.duplicate(), "digest": str(shape.digest()) if shape != null else ""}


## Drops what no longer stands: bodies that are gone, or whose mesh is another one now. Returns
## true when something went.
func prune(shapes: Dictionary) -> bool:
	var dropped := false
	for body_id in _triangles.keys():
		var shape: RefCounted = shapes.get(body_id)
		if shape == null or str(shape.digest()) != str(_digests.get(body_id, "")):
			_triangles.erase(body_id)
			_digests.erase(body_id)
			dropped = true
	if not hover.is_empty() and not shapes.has(hover.get("body", "")):
		hover = {}
		dropped = true
	if dropped:
		changed.emit()
	return dropped


# --- Helpers ---------------------------------------------------------------------------------

## The triangles a view pick stands for in the current mode: its triangle, or its whole group.
func _pick_triangles(pick: Dictionary, shape: RefCounted) -> PackedInt32Array:
	var triangle := int(pick.get("triangle", -1))
	if mode == TRIANGLES and triangle >= 0:
		return PackedInt32Array([triangle]) if triangle < int(shape.triangle_count()) else PackedInt32Array()
	var group := -1
	if str(pick.get("kind", "")) == "mesh_group":
		group = int(pick.get("index", -1))
	elif pick.has("group"):
		group = int(shape.find_face(str(pick.group)))
	if group < 0 or group >= int(shape.face_count()):
		return PackedInt32Array()
	return shape.group_triangles(group)


func _holds(body_id: String, triangles: PackedInt32Array) -> bool:
	var mine := triangles_of(body_id)
	if mine.is_empty():
		return false
	# Sorted: a binary search per triangle.
	for t in triangles:
		var at := mine.bsearch(t)
		if at >= mine.size() or mine[at] != t:
			return false
	return true


## Stores a body's triangles (whole groups in "groups" mode unless as_is) and emits changed.
func _take(body_id: String, triangles: PackedInt32Array, shape: RefCounted, expand := true) -> void:
	var kept := triangles
	if mode == GROUPS and expand and shape != null:
		kept = _whole_groups(triangles, shape)
	if kept.is_empty():
		_triangles.erase(body_id)
		_digests.erase(body_id)
	else:
		_triangles[body_id] = kept
		_digests[body_id] = str(shape.digest()) if shape != null else ""
	changed.emit()


## Runs step(triangles, shape) -> triangles on every selected body.
func _each(shapes: Dictionary, step: Callable, expand := true) -> void:
	var any := false
	for body_id in _triangles.keys():
		var shape: RefCounted = shapes.get(body_id)
		if shape == null:
			continue
		var next: PackedInt32Array = step.call(_triangles[body_id], shape)
		if mode == GROUPS and expand:
			next = _whole_groups(next, shape)
		if next.is_empty():
			_triangles.erase(body_id)
			_digests.erase(body_id)
		else:
			_triangles[body_id] = next
		any = true
	if any:
		changed.emit()


## The indices of the face groups that hold any of the triangles, ascending.
static func _group_indices(triangles: PackedInt32Array, shape: RefCounted) -> PackedInt32Array:
	var found := {}
	var count := int(shape.face_count())
	if count <= 1:
		return PackedInt32Array([0]) if count == 1 and not triangles.is_empty() else PackedInt32Array()
	var group_of := triangle_groups(shape)
	for t in triangles:
		if t >= 0 and t < group_of.size():
			found[group_of[t]] = true
	var indices := PackedInt32Array(found.keys())
	indices.sort()
	return indices


## Each stored triangle's face group index (CadMesh.get_arrays "groups"), kept for the last few
## meshes asked about (by content digest), so a selection change doesn't copy the mesh again.
static func triangle_groups(shape: RefCounted) -> PackedInt32Array:
	var key := str(shape.digest())
	if _group_maps.has(key):
		return _group_maps[key]
	var groups: PackedInt32Array = (shape.get_arrays() as Dictionary).get("groups", PackedInt32Array())
	while _group_maps.size() >= GROUP_MAPS:
		_group_maps.erase(_group_maps.keys()[0])
	_group_maps[key] = groups
	return groups


## triangles grown to every triangle of the groups they lie in.
static func _whole_groups(triangles: PackedInt32Array, shape: RefCounted) -> PackedInt32Array:
	if shape == null or triangles.is_empty():
		return triangles
	var whole := PackedInt32Array()
	for index in _group_indices(triangles, shape):
		whole.append_array(shape.group_triangles(index))
	whole.sort()
	return whole


static func _in_range(triangles: PackedInt32Array, shape: RefCounted) -> PackedInt32Array:
	var count := int(shape.triangle_count())
	var kept := PackedInt32Array()
	for t in triangles:
		if t >= 0 and t < count:
			kept.append(t)
	return _unique(kept)


## Sorted, without repeats.
static func _unique(values: PackedInt32Array) -> PackedInt32Array:
	var sorted := values.duplicate()
	sorted.sort()
	var out := PackedInt32Array()
	var last := -1
	for v in sorted:
		if v != last:
			out.append(v)
			last = v
	return out


## a and b (each sorted, no repeats) merged.
static func _union(a: PackedInt32Array, b: PackedInt32Array) -> PackedInt32Array:
	if a.is_empty():
		return b
	if b.is_empty():
		return a
	var merged := a.duplicate()
	merged.append_array(b)
	return _unique(merged)


## The values of a (sorted) that are not in b.
static func _difference(a: PackedInt32Array, b: PackedInt32Array) -> PackedInt32Array:
	if a.is_empty() or b.is_empty():
		return a
	var gone := b.duplicate()
	gone.sort()
	var out := PackedInt32Array()
	for v in a:
		var at := gone.bsearch(v)
		if at >= gone.size() or gone[at] != v:
			out.append(v)
	return out
