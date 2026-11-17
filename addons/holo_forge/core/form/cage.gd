@tool
extends RefCounted
## Form cages: the control meshes of the Form workspace's smooth bodies (the cage dictionary),
## their half-edge adjacency (Topo) and the low-level topology edits the Form tools are made of.
## Pure data: nothing here touches the editor or the native kernel, so it runs headless.
##
## A cage is a plain Dictionary (see empty()). Positions are meters, doubles, xyz interleaved;
## each face lists its vertices counter-clockwise seen from outside. An edge is named by its
## unordered vertex pair (min, max); edge indices are only valid for the Topo that made them.
##
## Every topology op returns {"cage", "error", "new_vertices", "new_edges" (vertex pairs),
## "new_faces", "vertex_map" (old -> new ids when ids were compacted, else empty)} and never
## changes the dictionary it was given. Creases, corners, frozen and symmetry data are carried
## through; symmetry maps get -1 for new vertices (the tools rebuild them afterwards).

## OpenSubdiv's infinitely sharp weight: what the UI writes for "creased".
const SHARP := 10.0
const FROZEN_ERROR := "That would change frozen geometry; unfreeze it first."
const _LOW := 0xFFFFFFFF


# ---------------------------------------------------------------------------------------------
# Data helpers
# ---------------------------------------------------------------------------------------------

## A cage with every key and no geometry.
static func empty() -> Dictionary:
	return {
		"version": 1,
		"positions": PackedFloat64Array(),
		"face_counts": PackedInt32Array(),
		"face_indices": PackedInt32Array(),
		"crease_edges": PackedInt32Array(),
		"crease_weights": PackedFloat32Array(),
		"corners": PackedInt32Array(),
		"corner_weights": PackedFloat32Array(),
		"frozen": PackedInt32Array(),
		"symmetry": [],
		"sym_isolated": PackedInt32Array(),
		"links": [],
	}


static func make(positions: PackedFloat64Array, face_counts: PackedInt32Array, face_indices: PackedInt32Array) -> Dictionary:
	var c := empty()
	c.positions = positions
	c.face_counts = face_counts
	c.face_indices = face_indices
	return c


## faces: an Array of Arrays or PackedInt32Arrays of vertex ids.
static func from_vectors(points: PackedVector3Array, faces: Array) -> Dictionary:
	var pos := PackedFloat64Array()
	pos.resize(points.size() * 3)
	for i in points.size():
		var p := points[i]
		pos[3 * i] = p.x
		pos[3 * i + 1] = p.y
		pos[3 * i + 2] = p.z
	var counts := PackedInt32Array()
	var idx := PackedInt32Array()
	for f in faces:
		counts.append(f.size())
		for v in f:
			idx.append(int(v))
	return make(pos, counts, idx)


static func copy(c: Dictionary) -> Dictionary:
	return c.duplicate(true)


static func vertex_count(c: Dictionary) -> int:
	return (c.positions as PackedFloat64Array).size() / 3


static func face_count(c: Dictionary) -> int:
	return (c.face_counts as PackedInt32Array).size()


## Where each face starts in face_indices (size nF + 1).
static func face_offsets(c: Dictionary) -> PackedInt32Array:
	var counts: PackedInt32Array = c.face_counts
	var out := PackedInt32Array()
	out.resize(counts.size() + 1)
	var o := 0
	for f in counts.size():
		out[f] = o
		o += counts[f]
	out[counts.size()] = o
	return out


## The vertices of face f (sums the counts before f; use a Topo for many faces).
static func face_vertices(c: Dictionary, f: int) -> PackedInt32Array:
	var counts: PackedInt32Array = c.face_counts
	var o := 0
	for i in f:
		o += counts[i]
	return (c.face_indices as PackedInt32Array).slice(o, o + counts[f])


## A float32 view of vertex v (for display and rough math; never write it back unchanged).
static func position(c: Dictionary, v: int) -> Vector3:
	var p: PackedFloat64Array = c.positions
	return Vector3(p[3 * v], p[3 * v + 1], p[3 * v + 2])


static func position_d(c: Dictionary, v: int) -> PackedFloat64Array:
	var p: PackedFloat64Array = c.positions
	return PackedFloat64Array([p[3 * v], p[3 * v + 1], p[3 * v + 2]])


static func set_position(c: Dictionary, v: int, p: Vector3) -> void:
	set_position_d(c, v, p.x, p.y, p.z)


static func set_position_d(c: Dictionary, v: int, x: float, y: float, z: float) -> void:
	var p: PackedFloat64Array = c.positions
	p[3 * v] = x
	p[3 * v + 1] = y
	p[3 * v + 2] = z
	c.positions = p


static func positions_v3(c: Dictionary) -> PackedVector3Array:
	var p: PackedFloat64Array = c.positions
	var out := PackedVector3Array()
	out.resize(p.size() / 3)
	for v in out.size():
		out[v] = Vector3(p[3 * v], p[3 * v + 1], p[3 * v + 2])
	return out


static func bounds(c: Dictionary) -> AABB:
	var p: PackedFloat64Array = c.positions
	if p.size() < 3:
		return AABB()
	var lo := [p[0], p[1], p[2]]
	var hi := [p[0], p[1], p[2]]
	for v in p.size() / 3:
		for k in 3:
			var x := p[3 * v + k]
			if x < lo[k]:
				lo[k] = x
			if x > hi[k]:
				hi[k] = x
	return AABB(Vector3(lo[0], lo[1], lo[2]), Vector3(hi[0] - lo[0], hi[1] - lo[1], hi[2] - lo[2]))


## The length of the bounds diagonal, in doubles.
static func diagonal(c: Dictionary) -> float:
	var p: PackedFloat64Array = c.positions
	if p.size() < 3:
		return 0.0
	var x0 := p[0]
	var y0 := p[1]
	var z0 := p[2]
	var x1 := x0
	var y1 := y0
	var z1 := z0
	var i := 0
	var n := p.size()
	while i < n:
		var x := p[i]
		var y := p[i + 1]
		var z := p[i + 2]
		if x < x0:
			x0 = x
		elif x > x1:
			x1 = x
		if y < y0:
			y0 = y
		elif y > y1:
			y1 = y
		if z < z0:
			z0 = z
		elif z > z1:
			z1 = z
		i += 3
	return sqrt((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0) + (z1 - z0) * (z1 - z0))


static func mean_edge_length(c: Dictionary, topo = null) -> float:
	var t: Topo = topo if topo != null else topology(c)
	if t.nE == 0:
		return 0.0
	var p: PackedFloat64Array = c.positions
	var total := 0.0
	for e in t.nE:
		var a := t.edges[2 * e]
		var b := t.edges[2 * e + 1]
		total += sqrt(pow(p[3 * a] - p[3 * b], 2) + pow(p[3 * a + 1] - p[3 * b + 1], 2) + pow(p[3 * a + 2] - p[3 * b + 2], 2))
	return total / t.nE


## What the smooth surface depends on (symmetry, frozen, display and links don't change it).
static func content_hash(c: Dictionary) -> int:
	return hash([c.positions, c.face_counts, c.face_indices, c.crease_edges, c.crease_weights, c.corners, c.corner_weights])


static func topology_hash(c: Dictionary) -> int:
	return hash([c.face_counts, c.face_indices, c.crease_edges, c.crease_weights, c.corners, c.corner_weights])


## The cage invariants broken by c, as sentences ([] when valid).
static func validate(c: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	for key in ["positions", "face_counts", "face_indices", "crease_edges", "crease_weights", "corners", "corner_weights", "frozen", "symmetry", "sym_isolated", "links"]:
		if not c.has(key):
			out.append("The cage has no '%s'." % key)
	if not out.is_empty():
		return out
	var pos: PackedFloat64Array = c.positions
	if pos.size() % 3 != 0:
		out.append("positions has %d values, not a multiple of 3." % pos.size())
		return out
	var nV := pos.size() / 3
	var counts: PackedInt32Array = c.face_counts
	var idx: PackedInt32Array = c.face_indices
	var total := 0
	for f in counts.size():
		if counts[f] < 3:
			out.append("Face %d has %d vertices." % [f, counts[f]])
		total += counts[f]
	if total != idx.size():
		out.append("face_counts add up to %d but face_indices has %d." % [total, idx.size()])
		return out
	var used := PackedByteArray()
	used.resize(nV)
	for h in idx.size():
		var v := idx[h]
		if v < 0 or v >= nV:
			out.append("Face corner %d uses vertex %d of %d." % [h, v, nV])
			return out
		used[v] = 1
	if not out.is_empty():
		return out
	var o := 0
	for f in counts.size():
		var n := counts[f]
		for i in n:
			for j in range(i + 1, n):
				if idx[o + i] == idx[o + j]:
					out.append("Face %d uses vertex %d twice." % [f, idx[o + i]])
		o += n
	var unused := 0
	for v in nV:
		if used[v] == 0:
			unused += 1
	if unused > 0:
		out.append("%d vertices are not used by any face." % unused)
	if not out.is_empty():
		return out
	var t := Topo.new(c)
	for e in t.nE:
		if t.edge_uses[e] > 2:
			out.append("Edge %d-%d has %d faces." % [t.edges[2 * e], t.edges[2 * e + 1], t.edge_uses[e]])
	for e in t.misoriented:
		out.append("The faces of edge %d-%d face opposite ways." % [t.edges[2 * e], t.edges[2 * e + 1]])
	var ce: PackedInt32Array = c.crease_edges
	var cw: PackedFloat32Array = c.crease_weights
	if ce.size() != 2 * cw.size():
		out.append("crease_edges has %d values for %d weights." % [ce.size(), cw.size()])
	else:
		var last := -1
		for i in cw.size():
			var a := ce[2 * i]
			var b := ce[2 * i + 1]
			if a >= b or a < 0 or b >= nV:
				out.append("Crease pair %d-%d is not (low, high)." % [a, b])
				continue
			var key := (a << 32) | b
			if key <= last:
				out.append("Crease pairs are not sorted at %d-%d." % [a, b])
			last = key
			if not t.edge_lookup.has(key):
				out.append("Crease %d-%d is not an edge." % [a, b])
			if cw[i] <= 0.0:
				out.append("Crease %d-%d has weight %s." % [a, b, cw[i]])
	var corners: PackedInt32Array = c.corners
	if corners.size() != (c.corner_weights as PackedFloat32Array).size():
		out.append("corners and corner_weights differ in size.")
	for key in ["corners", "frozen", "sym_isolated"]:
		var list: PackedInt32Array = c[key]
		for i in list.size():
			if list[i] < 0 or list[i] >= nV:
				out.append("%s lists vertex %d of %d." % [key, list[i], nV])
				break
			if i > 0 and list[i] <= list[i - 1]:
				out.append("%s is not sorted and unique." % key)
				break
	var sym: Array = c.symmetry
	for s in sym.size():
		var entry: Dictionary = sym[s]
		var m: PackedInt32Array = entry.get("map", PackedInt32Array())
		if m.size() != nV:
			out.append("Symmetry %d has a map of %d for %d vertices." % [s, m.size(), nV])
			continue
		for v in nV:
			if m[v] < -1 or m[v] >= nV:
				out.append("Symmetry %d maps vertex %d to %d." % [s, v, m[v]])
				break
	return out


## Drops the vertices no face uses: {"cage", "vertex_map" old -> new (-1 removed), "changed"}.
## Creases, corners, frozen, sym_isolated, symmetry maps and links are remapped.
static func compact(c: Dictionary) -> Dictionary:
	var nV := vertex_count(c)
	var used := PackedByteArray()
	used.resize(nV)
	for v in (c.face_indices as PackedInt32Array):
		used[v] = 1
	var vmap := PackedInt32Array()
	vmap.resize(nV)
	var n := 0
	for v in nV:
		if used[v]:
			vmap[v] = n
			n += 1
		else:
			vmap[v] = -1
	if n == nV:
		return {"cage": copy(c), "vertex_map": vmap, "changed": false}
	var p: PackedFloat64Array = c.positions
	var np := PackedFloat64Array()
	np.resize(3 * n)
	for v in nV:
		var w := vmap[v]
		if w >= 0:
			np[3 * w] = p[3 * v]
			np[3 * w + 1] = p[3 * v + 1]
			np[3 * w + 2] = p[3 * v + 2]
	return {"cage": remap_vertices(c, vmap, np), "vertex_map": vmap, "changed": true}


## c with every vertex id v replaced by vmap[v] (-1 = gone) and the given positions: faces,
## creases (pairs that collapse or vanish are dropped), corners, frozen, sym_isolated, symmetry
## maps and link edges. Several old ids may share one new id (welding).
static func remap_vertices(c: Dictionary, vmap: PackedInt32Array, positions: PackedFloat64Array) -> Dictionary:
	var n := positions.size() / 3
	var out := copy(c)
	out.positions = positions
	var idx: PackedInt32Array = c.face_indices
	var ni := PackedInt32Array()
	ni.resize(idx.size())
	for h in idx.size():
		ni[h] = vmap[idx[h]]
	out.face_indices = ni
	var creases := {}
	var ce: PackedInt32Array = c.crease_edges
	var cw: PackedFloat32Array = c.crease_weights
	for i in cw.size():
		var a := vmap[ce[2 * i]]
		var b := vmap[ce[2 * i + 1]]
		if a < 0 or b < 0 or a == b:
			continue
		var key := _key(a, b)
		creases[key] = maxf(cw[i], creases.get(key, 0.0))
	_store_creases(out, creases)
	var corners := {}
	var cv: PackedInt32Array = c.corners
	var cvw: PackedFloat32Array = c.corner_weights
	for i in cv.size():
		var v := vmap[cv[i]]
		if v >= 0:
			corners[v] = maxf(cvw[i] if i < cvw.size() else SHARP, corners.get(v, 0.0))
	_store_corners(out, corners)
	for key in ["frozen", "sym_isolated"]:
		var list := PackedInt32Array()
		for v in (c[key] as PackedInt32Array):
			if vmap[v] >= 0:
				list.append(vmap[v])
		out[key] = sorted_unique(list)
	var sym: Array = out.symmetry
	for entry in sym:
		var m: PackedInt32Array = entry.get("map", PackedInt32Array())
		var nm := PackedInt32Array()
		nm.resize(n)
		nm.fill(-1)
		for v in mini(m.size(), vmap.size()):
			var w := vmap[v]
			if w < 0 or m[v] < 0 or m[v] >= vmap.size():
				continue
			if nm[w] == -1:
				nm[w] = vmap[m[v]]
		entry.map = nm
	var links: Array = out.links
	for link in links:
		var le: PackedInt32Array = link.get("edges", PackedInt32Array())
		var nl := PackedInt32Array()
		for i in le.size() / 2:
			var a := vmap[le[2 * i]] if le[2 * i] < vmap.size() else -1
			var b := vmap[le[2 * i + 1]] if le[2 * i + 1] < vmap.size() else -1
			if a >= 0 and b >= 0 and a != b:
				nl.append(a)
				nl.append(b)
		link.edges = nl
	return out


## Disjoint union: {"cage", "offset"} with other's ids shifted by offset (= c's vertex count).
## other's symmetry is dropped; c's symmetry maps get -1 for the new vertices.
static func append(c: Dictionary, other: Dictionary) -> Dictionary:
	var off := vertex_count(c)
	var out := copy(c)
	var p: PackedFloat64Array = out.positions
	p.append_array(other.positions)
	out.positions = p
	var counts: PackedInt32Array = out.face_counts
	counts.append_array(other.face_counts)
	out.face_counts = counts
	var idx: PackedInt32Array = out.face_indices
	for v in (other.face_indices as PackedInt32Array):
		idx.append(v + off)
	out.face_indices = idx
	var creases := crease_map(c)
	var oce: PackedInt32Array = other.get("crease_edges", PackedInt32Array())
	var ocw: PackedFloat32Array = other.get("crease_weights", PackedFloat32Array())
	for i in ocw.size():
		creases[_key(oce[2 * i] + off, oce[2 * i + 1] + off)] = ocw[i]
	_store_creases(out, creases)
	var corners := corner_map(c)
	var ocv: PackedInt32Array = other.get("corners", PackedInt32Array())
	var ocvw: PackedFloat32Array = other.get("corner_weights", PackedFloat32Array())
	for i in ocv.size():
		corners[ocv[i] + off] = ocvw[i] if i < ocvw.size() else SHARP
	_store_corners(out, corners)
	for key in ["frozen", "sym_isolated"]:
		var list: PackedInt32Array = out[key]
		for v in (other.get(key, PackedInt32Array()) as PackedInt32Array):
			list.append(v + off)
		out[key] = sorted_unique(list)
	_extend_symmetry(out, vertex_count(out))
	var links: Array = out.links
	for link in other.get("links", []):
		var l: Dictionary = link.duplicate(true)
		var le: PackedInt32Array = l.get("edges", PackedInt32Array())
		for i in le.size():
			le[i] += off
		l.edges = le
		links.append(l)
	return {"cage": out, "offset": off}


static func is_crease(c: Dictionary, a: int, b: int) -> bool:
	return crease_weight(c, a, b) > 0.0


## The crease weight of edge (a, b) (0 when smooth), by binary search of the sorted pairs.
static func crease_weight(c: Dictionary, a: int, b: int) -> float:
	var lo_v := mini(a, b)
	var hi_v := maxi(a, b)
	var ce: PackedInt32Array = c.crease_edges
	var lo := 0
	var hi := ce.size() / 2 - 1
	while lo <= hi:
		var mid := (lo + hi) >> 1
		var x := ce[2 * mid]
		var y := ce[2 * mid + 1]
		if x == lo_v and y == hi_v:
			return (c.crease_weights as PackedFloat32Array)[mid]
		if x < lo_v or (x == lo_v and y < hi_v):
			lo = mid + 1
		else:
			hi = mid - 1
	return 0.0


## Writes the crease of edge (a, b) into c (weight 0 removes it), keeping the pairs sorted.
static func set_crease(c: Dictionary, a: int, b: int, weight: float) -> void:
	var m := crease_map(c)
	if weight <= 0.0:
		m.erase(_key(a, b))
	else:
		m[_key(a, b)] = weight
	_store_creases(c, m)


## Writes vertex v's corner (sharp vertex) weight into c (0 removes it).
static func set_corner(c: Dictionary, v: int, weight: float) -> void:
	var m := corner_map(c)
	if weight <= 0.0:
		m.erase(v)
	else:
		m[v] = weight
	_store_corners(c, m)


## The locked set (1 = locked): frozen vertices plus every vertex of a face that has one. Those
## are exactly the vertices that position the surface over frozen faces and edges.
static func locked_vertices(c: Dictionary, _topo = null) -> PackedByteArray:
	var nV := vertex_count(c)
	var out := PackedByteArray()
	out.resize(nV)
	var frozen: PackedInt32Array = c.get("frozen", PackedInt32Array())
	if frozen.is_empty():
		return out
	var fz := PackedByteArray()
	fz.resize(nV)
	for v in frozen:
		if v >= 0 and v < nV:
			fz[v] = 1
			out[v] = 1
	var counts: PackedInt32Array = c.face_counts
	var idx: PackedInt32Array = c.face_indices
	var o := 0
	for f in counts.size():
		var n := counts[f]
		var hit := false
		for k in n:
			if fz[idx[o + k]]:
				hit = true
				break
		if hit:
			for k in n:
				out[idx[o + k]] = 1
		o += n
	return out


static func topology(c: Dictionary) -> Topo:
	return Topo.new(c)


## Edge (a, b) as one int key, (min << 32) | max: the Topo.edge_lookup key.
static func edge_key(a: int, b: int) -> int:
	return _key(a, b)


## {edge key: weight} of c's creases.
static func crease_map(c: Dictionary) -> Dictionary:
	var out := {}
	var ce: PackedInt32Array = c.get("crease_edges", PackedInt32Array())
	var cw: PackedFloat32Array = c.get("crease_weights", PackedFloat32Array())
	for i in mini(cw.size(), ce.size() / 2):
		out[_key(ce[2 * i], ce[2 * i + 1])] = cw[i]
	return out


## {vertex: weight} of c's corners.
static func corner_map(c: Dictionary) -> Dictionary:
	var out := {}
	var cv: PackedInt32Array = c.get("corners", PackedInt32Array())
	var cw: PackedFloat32Array = c.get("corner_weights", PackedFloat32Array())
	for i in cv.size():
		out[cv[i]] = cw[i] if i < cw.size() else SHARP
	return out


static func sorted_unique(list: PackedInt32Array) -> PackedInt32Array:
	var s := list.duplicate()
	s.sort()
	var out := PackedInt32Array()
	for i in s.size():
		if i == 0 or s[i] != s[i - 1]:
			out.append(s[i])
	return out


# ---------------------------------------------------------------------------------------------
# Topo: half-edge adjacency
# ---------------------------------------------------------------------------------------------

## Half-edge h is corner k of face f (h = face_offsets[f] + k): it starts at face_indices[h] and
## runs to the face's next corner, so the half-edge arrays line up with face_indices. Built for
## any cage whose indices are in range; broken topology is recorded (edge_uses, misoriented)
## rather than refused, so validate() and the repairs can read it.
class Topo:
	extends RefCounted
	var nV := 0
	var nF := 0
	var nE := 0
	var face_offsets := PackedInt32Array()
	var face_indices := PackedInt32Array()
	var he_face := PackedInt32Array()
	var he_twin := PackedInt32Array()
	var he_edge := PackedInt32Array()
	var edges := PackedInt32Array()
	var edge_he := PackedInt32Array()
	var vertex_he := PackedInt32Array()
	var edge_lookup := {}
	## Per edge: how many face corners use it (1 boundary, 2 interior, more = non-manifold).
	var edge_uses := PackedInt32Array()
	## Per edge: its second half-edge whichever way it runs (-1 when none).
	var edge_he2 := PackedInt32Array()
	## Edges whose two faces run them the same way (not twinned).
	var misoriented := PackedInt32Array()
	## Edge -> PackedInt32Array of its third and later half-edges.
	var extra_he := {}
	var _vh_start := PackedInt32Array()
	var _vh_list := PackedInt32Array()
	var _comp := PackedInt32Array()
	var _ncomp := -1
	## The cage's positions when the Topo was built (for feature_faces' perimeters).
	var positions := PackedFloat64Array()

	func _init(c: Dictionary = {}) -> void:
		if not c.is_empty():
			build(c)

	func build(c: Dictionary) -> void:
		var counts: PackedInt32Array = c.face_counts
		face_indices = c.face_indices
		positions = c.positions
		var idx := face_indices
		nV = (c.positions as PackedFloat64Array).size() / 3
		nF = counts.size()
		var nH := idx.size()
		face_offsets.resize(nF + 1)
		he_face.resize(nH)
		he_twin.resize(nH)
		he_twin.fill(-1)
		he_edge.resize(nH)
		edges.resize(2 * nH)
		edge_he.resize(nH)
		edge_he2.resize(nH)
		edge_uses.resize(nH)
		vertex_he.resize(nV)
		vertex_he.fill(-1)
		var lookup := {}
		var ne := 0
		var o := 0
		for f in nF:
			var n := counts[f]
			face_offsets[f] = o
			var first := idx[o]
			var last := o + n - 1
			for h in range(o, o + n):
				he_face[h] = f
				var a := idx[h]
				var b := idx[h + 1] if h < last else first
				var key := (a << 32) | b if a < b else (b << 32) | a
				var e: int = lookup.get(key, -1)
				if e < 0:
					e = ne
					lookup[key] = e
					edges[2 * e] = key >> 32
					edges[2 * e + 1] = key & 0xFFFFFFFF
					edge_he[e] = h
					edge_he2[e] = -1
					edge_uses[e] = 1
					ne += 1
				else:
					var u := edge_uses[e]
					edge_uses[e] = u + 1
					if u == 1:
						edge_he2[e] = h
						var h0 := edge_he[e]
						if idx[h0] == a:
							misoriented.append(e)
						else:
							he_twin[h] = h0
							he_twin[h0] = h
					else:
						if not extra_he.has(e):
							extra_he[e] = PackedInt32Array()
						var extra: PackedInt32Array = extra_he[e]
						extra.append(h)
						extra_he[e] = extra
				he_edge[h] = e
				if vertex_he[a] < 0:
					vertex_he[a] = h
			o += n
		face_offsets[nF] = o
		nE = ne
		edges.resize(2 * ne)
		edge_he.resize(ne)
		edge_he2.resize(ne)
		edge_uses.resize(ne)
		edge_lookup = lookup
		for h in nH:
			if he_twin[h] < 0:
				vertex_he[idx[h]] = h

	func he_origin(h: int) -> int:
		return face_indices[h]

	func he_dest(h: int) -> int:
		return face_indices[he_next(h)]

	func he_next(h: int) -> int:
		var f := he_face[h]
		return h + 1 if h + 1 < face_offsets[f + 1] else face_offsets[f]

	func he_prev(h: int) -> int:
		var f := he_face[h]
		return h - 1 if h > face_offsets[f] else face_offsets[f + 1] - 1

	func face_size(f: int) -> int:
		return face_offsets[f + 1] - face_offsets[f]

	func face_verts(f: int) -> PackedInt32Array:
		return face_indices.slice(face_offsets[f], face_offsets[f + 1])

	## -1 when there is no such edge.
	func edge_index(a: int, b: int) -> int:
		var key := (a << 32) | b if a < b else (b << 32) | a
		return edge_lookup.get(key, -1)

	func edge_vertices(e: int) -> Vector2i:
		return Vector2i(edges[2 * e], edges[2 * e + 1])

	func edge_faces(e: int) -> PackedInt32Array:
		var out := PackedInt32Array([he_face[edge_he[e]]])
		if edge_he2[e] >= 0:
			out.append(he_face[edge_he2[e]])
		if extra_he.has(e):
			for h in (extra_he[e] as PackedInt32Array):
				out.append(he_face[h])
		return out

	## The half-edge running a -> b (-1 when no face has it).
	func half_edge(a: int, b: int) -> int:
		var e := edge_index(a, b)
		if e < 0:
			return -1
		var h := edge_he[e]
		if face_indices[h] == a:
			return h
		h = edge_he2[e]
		if h >= 0 and face_indices[h] == a:
			return h
		if extra_he.has(e):
			for x in (extra_he[e] as PackedInt32Array):
				if face_indices[x] == a:
					return x
		return -1

	func is_boundary_edge(e: int) -> bool:
		return edge_uses[e] == 1

	func is_boundary_vertex(v: int) -> bool:
		var h := vertex_he[v]
		return h >= 0 and he_twin[h] < 0

	## Outgoing half-edges of v in rotational order (counter-clockwise seen from outside). A
	## boundary vertex starts at its outgoing boundary half-edge.
	func vertex_out(v: int) -> PackedInt32Array:
		var out := PackedInt32Array()
		var h0 := vertex_he[v]
		if h0 < 0:
			return out
		var h := h0
		var guard := he_face.size()
		while guard > 0:
			guard -= 1
			out.append(h)
			var t := he_twin[he_prev(h)]
			if t < 0 or t == h0:
				break
			h = t
		return out

	func valence(v: int) -> int:
		var out := vertex_out(v)
		if out.is_empty():
			return 0
		return out.size() + (1 if he_twin[out[0]] < 0 else 0)

	func vertex_faces(v: int) -> PackedInt32Array:
		var out := vertex_out(v)
		for i in out.size():
			out[i] = he_face[out[i]]
		return out

	## Edges around v in rotational order.
	func vertex_edges(v: int) -> PackedInt32Array:
		var hs := vertex_out(v)
		var out := PackedInt32Array()
		for h in hs:
			out.append(he_edge[h])
		if not hs.is_empty() and he_twin[hs[0]] < 0:
			out.append(he_edge[he_prev(hs[hs.size() - 1])])
		return out

	func vertex_neighbors(v: int) -> PackedInt32Array:
		var hs := vertex_out(v)
		var out := PackedInt32Array()
		for h in hs:
			out.append(he_dest(h))
		if not hs.is_empty() and he_twin[hs[0]] < 0:
			out.append(face_indices[he_prev(hs[hs.size() - 1])])
		return out

	## Every outgoing half-edge of v (any order; also covers vertices where fans only touch).
	func vertex_half_edges(v: int) -> PackedInt32Array:
		_ensure_vertex_lists()
		return _vh_list.slice(_vh_start[v], _vh_start[v + 1])

	## Every face with a corner at v (any order).
	func vertex_all_faces(v: int) -> PackedInt32Array:
		var out := vertex_half_edges(v)
		for i in out.size():
			out[i] = he_face[out[i]]
		return out

	func face_edges(f: int) -> PackedInt32Array:
		return he_edge.slice(face_offsets[f], face_offsets[f + 1])

	func face_neighbors(f: int) -> PackedInt32Array:
		var out := PackedInt32Array()
		for h in range(face_offsets[f], face_offsets[f + 1]):
			for g in edge_faces(he_edge[h]):
				if g != f and not out.has(g):
					out.append(g)
		return out

	func _ensure_vertex_lists() -> void:
		if _vh_start.size() == nV + 1:
			return
		var nH := face_indices.size()
		_vh_start.resize(nV + 1)
		_vh_start.fill(0)
		for h in nH:
			_vh_start[face_indices[h] + 1] += 1
		for v in nV:
			_vh_start[v + 1] += _vh_start[v]
		var fill := _vh_start.duplicate()
		_vh_list.resize(nH)
		for h in nH:
			var v := face_indices[h]
			_vh_list[fill[v]] = h
			fill[v] += 1

	## Face -> component id (0..k-1, numbered by each component's lowest face).
	func components() -> PackedInt32Array:
		if _ncomp >= 0:
			return _comp
		_comp.resize(nF)
		_comp.fill(-1)
		var k := 0
		var stack := PackedInt32Array()
		for f0 in nF:
			if _comp[f0] >= 0:
				continue
			_comp[f0] = k
			stack.append(f0)
			while not stack.is_empty():
				var f := stack[stack.size() - 1]
				stack.resize(stack.size() - 1)
				for h in range(face_offsets[f], face_offsets[f + 1]):
					var e := he_edge[h]
					if edge_uses[e] < 2:
						continue
					for g in edge_faces(e):
						if _comp[g] < 0:
							_comp[g] = k
							stack.append(g)
			k += 1
		_ncomp = k
		return _comp

	func component_count() -> int:
		components()
		return _ncomp

	func component_faces(comp: int) -> PackedInt32Array:
		var cf := components()
		var out := PackedInt32Array()
		for f in nF:
			if cf[f] == comp:
				out.append(f)
		return out

	func component_vertices(comp: int) -> PackedInt32Array:
		var cf := components()
		var mark := PackedByteArray()
		mark.resize(nV)
		for f in nF:
			if cf[f] == comp:
				for h in range(face_offsets[f], face_offsets[f + 1]):
					mark[face_indices[h]] = 1
		var out := PackedInt32Array()
		for v in nV:
			if mark[v]:
				out.append(v)
		return out

	## The boundary half-edge that follows boundary half-edge h (leaving h's end), or -1.
	func next_boundary(h: int) -> int:
		var n := he_next(h)
		var guard := he_face.size()
		while guard > 0:
			guard -= 1
			var t := he_twin[n]
			if t < 0:
				return n if edge_uses[he_edge[n]] == 1 else -1
			n = he_next(t)
		return -1

	## Array of PackedInt32Array vertex loops, each in boundary half-edge order (the existing
	## faces run each loop edge loop[i] -> loop[i + 1]).
	func boundary_loops() -> Array:
		var loops: Array = []
		var seen := PackedByteArray()
		seen.resize(he_face.size())
		for h0 in he_face.size():
			if seen[h0] or he_twin[h0] >= 0 or edge_uses[he_edge[h0]] != 1:
				continue
			loops.append(_walk_boundary(h0, seen))
		return loops

	func _walk_boundary(h0: int, seen: PackedByteArray) -> PackedInt32Array:
		var loop := PackedInt32Array()
		var h := h0
		var guard := he_face.size()
		while guard > 0:
			guard -= 1
			if seen.size() > 0:
				seen[h] = 1
			loop.append(face_indices[h])
			h = next_boundary(h)
			if h < 0 or h == h0 or (seen.size() > 0 and seen[h]):
				break
		return loop

	func boundary_loop_of_edge(e: int) -> PackedInt32Array:
		if e < 0 or e >= nE or edge_uses[e] != 1:
			return PackedInt32Array()
		return _walk_boundary(edge_he[e], PackedByteArray())

	func is_closed() -> bool:
		for e in nE:
			if edge_uses[e] == 1:
				return false
		return true

	## Vertex pairs of the edges with three or more faces.
	func non_manifold_edges() -> PackedInt32Array:
		var out := PackedInt32Array()
		for e in nE:
			if edge_uses[e] > 2:
				out.append(edges[2 * e])
				out.append(edges[2 * e + 1])
		return out

	## The face with exactly that vertex set (any order), or -1.
	func face_by_vertices(verts: PackedInt32Array) -> int:
		if verts.is_empty() or verts[0] < 0 or verts[0] >= nV:
			return -1
		_ensure_vertex_lists()
		var want := verts.duplicate()
		want.sort()
		var v0 := verts[0]
		for i in range(_vh_start[v0], _vh_start[v0 + 1]):
			var f := he_face[_vh_list[i]]
			var s := face_offsets[f]
			var n := face_offsets[f + 1] - s
			if n != want.size():
				continue
			var have := face_indices.slice(s, s + n)
			have.sort()
			if have == want:
				return f
		return -1

	## The face's unit normal (Newell's method, so n-gons and bent quads work).
	func face_normal(c: Dictionary, f: int) -> Vector3:
		return face_area_vector(c, f).normalized()

	## Newell's vector: the face normal times twice its area, in doubles.
	func face_area_vector(c: Dictionary, f: int) -> Vector3:
		var p: PackedFloat64Array = c.positions
		var s := face_offsets[f]
		var e := face_offsets[f + 1]
		var nx := 0.0
		var ny := 0.0
		var nz := 0.0
		for h in range(s, e):
			var a := 3 * face_indices[h]
			var b := 3 * face_indices[h + 1 if h + 1 < e else s]
			nx += (p[a + 1] - p[b + 1]) * (p[a + 2] + p[b + 2])
			ny += (p[a + 2] - p[b + 2]) * (p[a] + p[b])
			nz += (p[a] - p[b]) * (p[a + 1] + p[b + 1])
		return Vector3(nx, ny, nz)

	## Area-weighted vertex normal.
	func vertex_normal(c: Dictionary, v: int) -> Vector3:
		var n := Vector3.ZERO
		for f in vertex_all_faces(v):
			n += face_area_vector(c, f)
		return n.normalized()

	# --- selection helpers -------------------------------------------------------------------

	## Interior with valence 4.
	func is_regular(v: int) -> bool:
		return not is_boundary_vertex(v) and valence(v) == 4

	func _other(e: int, v: int) -> int:
		return edges[2 * e + 1] if edges[2 * e] == v else edges[2 * e]

	## Edges of the loop through e, in order: straight through regular vertices, stopping at
	## irregular ones or when back at e. A boundary edge gives its whole boundary loop.
	func edge_loop(e: int) -> PackedInt32Array:
		if e < 0 or e >= nE:
			return PackedInt32Array()
		if edge_uses[e] == 1:
			var out := PackedInt32Array()
			var h0 := edge_he[e]
			var h := h0
			var guard := nE + 1
			while guard > 0 and h >= 0:
				guard -= 1
				out.append(he_edge[h])
				h = next_boundary(h)
				if h == h0:
					break
			return out
		var fwd := _loop_walk(e, edges[2 * e + 1])
		var res := PackedInt32Array([e])
		res.append_array(fwd.edges)
		if fwd.closed:
			return res
		var back: PackedInt32Array = _loop_walk(e, edges[2 * e]).edges
		back.reverse()
		back.append_array(res)
		return back

	func _loop_walk(e: int, v: int) -> Dictionary:
		var out := PackedInt32Array()
		var cur := e
		var guard := nE + 1
		while guard > 0:
			guard -= 1
			if is_boundary_vertex(v):
				break
			var ve := vertex_edges(v)
			if ve.size() != 4:
				break
			var i := ve.find(cur)
			if i < 0:
				break
			var nxt := ve[(i + 2) % 4]
			if nxt == e:
				return {"edges": out, "closed": true}
			if out.has(nxt) or edge_uses[nxt] != 2:
				break
			out.append(nxt)
			v = _other(nxt, v)
			cur = nxt
		return {"edges": out, "closed": false}

	## Edges of the ring through e: across quads to the opposite edge, both ways, stopping at
	## non-quads, boundaries or when back at e.
	func edge_ring(e: int) -> PackedInt32Array:
		if e < 0 or e >= nE:
			return PackedInt32Array()
		var fwd := _ring_walk(e, edge_he[e])
		var res := PackedInt32Array([e])
		res.append_array(fwd.edges)
		if fwd.closed:
			return res
		var h2 := edge_he2[e]
		if h2 < 0:
			return res
		var back: PackedInt32Array = _ring_walk(e, h2).edges
		back.reverse()
		back.append_array(res)
		return back

	func _ring_walk(e: int, h: int) -> Dictionary:
		var out := PackedInt32Array()
		var guard := nE + 1
		while guard > 0 and h >= 0:
			guard -= 1
			var f := he_face[h]
			if face_size(f) != 4:
				break
			var opp := he_next(he_next(h))
			var oe := he_edge[opp]
			if oe == e:
				return {"edges": out, "closed": true}
			if out.has(oe):
				break
			out.append(oe)
			h = he_twin[opp]
		return {"edges": out, "closed": false}

	## Faces of the loop from f_a through its neighbour f_b, crossing opposite edges of quads,
	## extended the other way from f_a too when it doesn't close. Empty when not adjacent.
	func face_loop(f_a: int, f_b: int) -> PackedInt32Array:
		var shared := -1
		for h in range(face_offsets[f_a], face_offsets[f_a + 1]):
			var t := he_twin[h]
			if t >= 0 and he_face[t] == f_b:
				shared = h
				break
		if shared < 0:
			return PackedInt32Array()
		var res := PackedInt32Array([f_a])
		var h := he_twin[shared]
		var closed := false
		var guard := nF + 1
		while guard > 0:
			guard -= 1
			var f := he_face[h]
			if f == f_a:
				closed = true
				break
			if res.has(f):
				break
			res.append(f)
			if face_size(f) != 4:
				break
			var t := he_twin[he_next(he_next(h))]
			if t < 0:
				break
			h = t
		if closed or face_size(f_a) != 4:
			return res
		var back := PackedInt32Array()
		var t0 := he_twin[he_next(he_next(shared))]
		h = t0
		guard = nF + 1
		while guard > 0 and h >= 0:
			guard -= 1
			var f := he_face[h]
			if res.has(f) or back.has(f):
				break
			back.append(f)
			if face_size(f) != 4:
				break
			h = he_twin[he_next(he_next(h))]
		back.reverse()
		back.append_array(res)
		return back

	## The vertices of edge_loop(edge(a, b)), in order with a just before b.
	func vertex_loop(a: int, b: int) -> PackedInt32Array:
		var e := edge_index(a, b)
		if e < 0:
			return PackedInt32Array()
		var chain := edge_loop(e)
		var out := chain_vertices(chain, a)
		var ia := out.find(a)
		var ib := out.find(b)
		if ia < 0 or ib < 0 or ib == ia + 1:
			return out
		var closed := chain.size() == out.size() and out.size() > 2
		if closed and ia == 0:
			# Runs the other way round: a, then the rest reversed.
			var rest := out.slice(1)
			rest.reverse()
			var res := PackedInt32Array([a])
			res.append_array(rest)
			return res
		out.reverse()
		return out

	## The vertex sequence of an ordered edge chain (a closed loop lists each vertex once);
	## prefer rotates a closed loop to start there.
	func chain_vertices(chain: PackedInt32Array, prefer := -1) -> PackedInt32Array:
		var out := PackedInt32Array()
		if chain.is_empty():
			return out
		var a := edges[2 * chain[0]]
		var b := edges[2 * chain[0] + 1]
		if chain.size() > 1:
			var e1 := chain[1]
			if edges[2 * e1] == a or edges[2 * e1 + 1] == a:
				var tmp := a
				a = b
				b = tmp
		elif prefer == b:
			var tmp := a
			a = b
			b = tmp
		out.append(a)
		out.append(b)
		var cur := b
		for i in range(1, chain.size()):
			var nxt := _other(chain[i], cur)
			out.append(nxt)
			cur = nxt
		var closed := out.size() > 3 and out[out.size() - 1] == out[0]
		if closed:
			out.resize(out.size() - 1)
			var at := out.find(prefer) if prefer >= 0 else -1
			if at > 0:
				var rot := out.slice(at)
				rot.append_array(out.slice(0, at))
				out = rot
		return out

	## Faces: add every face sharing a vertex with the set. Edges and vertices: by vertex
	## adjacency. kind: "face" | "edge" | "vertex" (plural accepted); edges are edge indices.
	func grow(kind: String, sel: PackedInt32Array) -> PackedInt32Array:
		var k := kind.substr(0, 1)
		var out := sel.duplicate()
		if k == "f":
			var mark := PackedByteArray()
			mark.resize(nF)
			var vmark := PackedByteArray()
			vmark.resize(nV)
			for f in sel:
				mark[f] = 1
				for h in range(face_offsets[f], face_offsets[f + 1]):
					vmark[face_indices[h]] = 1
			for f in nF:
				if mark[f]:
					continue
				for h in range(face_offsets[f], face_offsets[f + 1]):
					if vmark[face_indices[h]]:
						out.append(f)
						break
		elif k == "e":
			var mark := PackedByteArray()
			mark.resize(nE)
			var vmark := PackedByteArray()
			vmark.resize(nV)
			for e in sel:
				mark[e] = 1
				vmark[edges[2 * e]] = 1
				vmark[edges[2 * e + 1]] = 1
			for e in nE:
				if not mark[e] and (vmark[edges[2 * e]] or vmark[edges[2 * e + 1]]):
					out.append(e)
		else:
			var mark := PackedByteArray()
			mark.resize(nV)
			for v in sel:
				mark[v] = 1
			for v in sel:
				for w in vertex_neighbors(v):
					if not mark[w]:
						mark[w] = 1
						out.append(w)
		return out

	## Faces: drop the faces that share a vertex with an unselected face. Edges / vertices: drop
	## those touching an unselected edge / neighbour.
	func shrink(kind: String, sel: PackedInt32Array) -> PackedInt32Array:
		var k := kind.substr(0, 1)
		var out := PackedInt32Array()
		if k == "f":
			var mark := PackedByteArray()
			mark.resize(nF)
			for f in sel:
				mark[f] = 1
			var outside := PackedByteArray()
			outside.resize(nV)
			for f in nF:
				if not mark[f]:
					for h in range(face_offsets[f], face_offsets[f + 1]):
						outside[face_indices[h]] = 1
			for f in sel:
				var keep := true
				for h in range(face_offsets[f], face_offsets[f + 1]):
					if outside[face_indices[h]]:
						keep = false
						break
				if keep:
					out.append(f)
		elif k == "e":
			var mark := PackedByteArray()
			mark.resize(nE)
			for e in sel:
				mark[e] = 1
			var outside := PackedByteArray()
			outside.resize(nV)
			for e in nE:
				if not mark[e]:
					outside[edges[2 * e]] = 1
					outside[edges[2 * e + 1]] = 1
			for e in sel:
				if not outside[edges[2 * e]] and not outside[edges[2 * e + 1]]:
					out.append(e)
		else:
			var mark := PackedByteArray()
			mark.resize(nV)
			for v in sel:
				mark[v] = 1
			for v in sel:
				var keep := true
				for w in vertex_neighbors(v):
					if not mark[w]:
						keep = false
						break
				if keep:
					out.append(v)
		return out

	## The loop continuation of edge e past vertex v (-1 when the loop stops there).
	func _loop_next(e: int, v: int) -> int:
		if edge_uses[e] == 1:
			# Along the boundary: the other boundary edge at v.
			for x in vertex_edges(v):
				if x != e and edge_uses[x] == 1:
					return x
			return -1
		if is_boundary_vertex(v):
			return -1
		var ve := vertex_edges(v)
		if ve.size() != 4:
			return -1
		var i := ve.find(e)
		return ve[(i + 2) % 4] if i >= 0 else -1

	## Each selected loop grows by one edge at each open end.
	func loop_grow(sel: PackedInt32Array) -> PackedInt32Array:
		var mark := {}
		for e in sel:
			mark[e] = true
		var out := sel.duplicate()
		for e in sel:
			for v in [edges[2 * e], edges[2 * e + 1]]:
				var n := _loop_next(e, v)
				if n >= 0 and not mark.has(n):
					mark[n] = true
					out.append(n)
		return out

	## The ring neighbours of e (opposite edges across its quads).
	func ring_neighbors(e: int) -> PackedInt32Array:
		var out := PackedInt32Array()
		for h in [edge_he[e], edge_he2[e]]:
			if h < 0 or face_size(he_face[h]) != 4:
				continue
			out.append(he_edge[he_next(he_next(h))])
		return out

	func ring_grow(sel: PackedInt32Array) -> PackedInt32Array:
		var mark := {}
		for e in sel:
			mark[e] = true
		var out := sel.duplicate()
		for e in sel:
			for n in ring_neighbors(e):
				if not mark.has(n):
					mark[n] = true
					out.append(n)
		return out

	## Drops the ring ends (selected edges with fewer than two selected ring neighbours).
	func ring_shrink(sel: PackedInt32Array) -> PackedInt32Array:
		var mark := {}
		for e in sel:
			mark[e] = true
		var out := PackedInt32Array()
		for e in sel:
			var n := 0
			for x in ring_neighbors(e):
				if mark.has(x):
					n += 1
			if n >= 2:
				out.append(e)
		return out

	## The elements between a and b along the shortest loop or ring containing both (empty when
	## none does). Edges are edge indices.
	func range_select(kind: String, a: int, b: int) -> PackedInt32Array:
		var k := kind.substr(0, 1)
		var best := PackedInt32Array()
		var paths: Array = []
		if k == "e":
			paths.append(edge_loop(a))
			paths.append(edge_ring(a))
		elif k == "f":
			for g in face_neighbors(a):
				paths.append(face_loop(a, g))
		else:
			for e in vertex_edges(a):
				paths.append(chain_vertices(edge_loop(e), a))
		for path in paths:
			var p: PackedInt32Array = path
			var sub := _between(p, a, b, k)
			if not sub.is_empty() and (best.is_empty() or sub.size() < best.size()):
				best = sub
		return best

	func _between(p: PackedInt32Array, a: int, b: int, k: String) -> PackedInt32Array:
		var i := p.find(a)
		var j := p.find(b)
		if i < 0 or j < 0:
			return PackedInt32Array()
		var n := p.size()
		var closed := false
		if n > 2:
			var x := p[0]
			var y := p[n - 1]
			if k == "v":
				closed = edge_index(x, y) >= 0
			elif k == "f":
				closed = face_neighbors(x).has(y)
			else:
				var ax := edges[2 * x]
				var bx := edges[2 * x + 1]
				closed = edges[2 * y] == ax or edges[2 * y] == bx or edges[2 * y + 1] == ax or edges[2 * y + 1] == bx or ring_neighbors(x).has(y)
		var lo := mini(i, j)
		var hi := maxi(i, j)
		var direct := p.slice(lo, hi + 1)
		if not closed:
			return direct
		var around := p.slice(hi)
		around.append_array(p.slice(0, lo + 1))
		return direct if direct.size() <= around.size() else around

	func invert(kind: String, sel: PackedInt32Array) -> PackedInt32Array:
		var k := kind.substr(0, 1)
		var n := nF if k == "f" else (nE if k == "e" else nV)
		var mark := PackedByteArray()
		mark.resize(n)
		for x in sel:
			if x >= 0 and x < n:
				mark[x] = 1
		var out := PackedInt32Array()
		for x in n:
			if not mark[x]:
				out.append(x)
		return out

	## The band around a strut or hole through face f: its closed face loop with fewer faces, plus
	## each adjacent parallel closed loop whose perimeter is within 35% of the first band's.
	## Perimeters use the positions the Topo was built from, or c's when given.
	func feature_faces(f: int, c = null) -> PackedInt32Array:
		var pos: PackedFloat64Array = c.positions if c is Dictionary else positions
		if face_size(f) != 4:
			return PackedInt32Array()
		var s := face_offsets[f]
		var best := PackedInt32Array()
		var best_dir := -1
		for k in 2:
			var t := he_twin[s + k]
			if t < 0:
				continue
			var loop := face_loop(f, he_face[t])
			if loop.size() < 2 or not _face_loop_closed(loop):
				continue
			if best.is_empty() or loop.size() < best.size():
				best = loop
				best_dir = k
		if best.is_empty():
			return best
		var out := best.duplicate()
		var mark := {}
		for g in best:
			mark[g] = true
		var perimeter := _band_perimeter(pos, best)
		# Walk sideways both ways: the side edges of f are corners best_dir + 1 and + 3.
		for side in [best_dir + 1, best_dir + 3]:
			var cur_f := f
			var cur_side: int = side % 4
			var guard := nF
			while guard > 0:
				guard -= 1
				var h := face_offsets[cur_f] + cur_side
				var t := he_twin[h]
				if t < 0:
					break
				var g := he_face[t]
				if mark.has(g) or face_size(g) != 4:
					break
				var k := t - face_offsets[g]
				var cross := (k + 1) % 4
				var ct := he_twin[face_offsets[g] + cross]
				if ct < 0:
					break
				var loop := face_loop(g, he_face[ct])
				if loop.size() < 2 or not _face_loop_closed(loop):
					break
				var p := _band_perimeter(pos, loop)
				if absf(p - perimeter) > 0.35 * perimeter:
					break
				var clash := false
				for x in loop:
					if mark.has(x):
						clash = true
						break
				if clash:
					break
				for x in loop:
					mark[x] = true
					out.append(x)
				cur_f = g
				cur_side = (k + 2) % 4
		return out

	func _face_loop_closed(loop: PackedInt32Array) -> bool:
		if loop.size() < 3:
			return false
		for g in face_neighbors(loop[0]):
			if g == loop[loop.size() - 1]:
				return true
		return false

	## Half the summed length of the band's side edges (the edges the loop runs along).
	func _band_perimeter(p: PackedFloat64Array, loop: PackedInt32Array) -> float:
		var mark := {}
		for g in loop:
			mark[g] = true
		var total := 0.0
		var counted := {}
		for g in loop:
			for h in range(face_offsets[g], face_offsets[g + 1]):
				var e := he_edge[h]
				if counted.has(e):
					continue
				var crossing := false
				for x in edge_faces(e):
					if x != g and mark.has(x):
						crossing = true
				if crossing:
					continue
				counted[e] = true
				var a := 3 * edges[2 * e]
				var b := 3 * edges[2 * e + 1]
				total += sqrt(pow(p[a] - p[b], 2) + pow(p[a + 1] - p[b + 1], 2) + pow(p[a + 2] - p[b + 2], 2))
		return total * 0.5


# ---------------------------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------------------------

static func _key(a: int, b: int) -> int:
	return (a << 32) | b if a < b else (b << 32) | a


static func _store_creases(c: Dictionary, m: Dictionary) -> void:
	var keys := m.keys()
	keys.sort()
	var ce := PackedInt32Array()
	ce.resize(2 * keys.size())
	var cw := PackedFloat32Array()
	cw.resize(keys.size())
	for i in keys.size():
		var k: int = keys[i]
		ce[2 * i] = k >> 32
		ce[2 * i + 1] = k & _LOW
		cw[i] = m[k]
	c.crease_edges = ce
	c.crease_weights = cw


static func _store_corners(c: Dictionary, m: Dictionary) -> void:
	var keys := m.keys()
	keys.sort()
	var cv := PackedInt32Array()
	var cw := PackedFloat32Array()
	for k in keys:
		cv.append(k)
		cw.append(m[k])
	c.corners = cv
	c.corner_weights = cw


## Pads (with -1) or trims every symmetry map to nV entries.
static func _extend_symmetry(c: Dictionary, nV: int) -> void:
	var sym: Array = c.get("symmetry", [])
	for entry in sym:
		var m: PackedInt32Array = entry.get("map", PackedInt32Array())
		var old := m.size()
		if old == nV:
			continue
		m.resize(nV)
		for v in range(old, nV):
			m[v] = -1
		for v in nV:
			if m[v] >= nV:
				m[v] = -1
		entry.map = m


static func _faces_array(c: Dictionary) -> Array:
	var counts: PackedInt32Array = c.face_counts
	var idx: PackedInt32Array = c.face_indices
	var out := []
	out.resize(counts.size())
	var o := 0
	for f in counts.size():
		var n := counts[f]
		out[f] = idx.slice(o, o + n)
		o += n
	return out


## The op result shape.
static func _result(cage: Dictionary, extra := {}) -> Dictionary:
	var out := {"cage": cage, "error": "", "new_vertices": PackedInt32Array(), "new_edges": PackedInt32Array(), "new_faces": PackedInt32Array(), "vertex_map": PackedInt32Array()}
	for k in extra:
		out[k] = extra[k]
	return out


static func _fail(c: Dictionary, error: String) -> Dictionary:
	return _result(copy(c), {"error": error})


## A new cage made of src's extras (frozen, symmetry, isolated, links, corners) and the given
## geometry. creases: {edge key: weight} (src's when null); pairs that aren't edges of the new
## faces are dropped. Symmetry maps are padded with -1 to the new vertex count.
static func _assemble(src: Dictionary, positions: PackedFloat64Array, faces: Array, creases = null, corners = null) -> Dictionary:
	var counts := PackedInt32Array()
	counts.resize(faces.size())
	var idx := PackedInt32Array()
	for i in faces.size():
		var f: PackedInt32Array = faces[i]
		counts[i] = f.size()
		idx.append_array(f)
	return _assemble_flat(src, positions, counts, idx, creases, corners)


static func _assemble_flat(src: Dictionary, positions: PackedFloat64Array, counts: PackedInt32Array, idx: PackedInt32Array, creases = null, corners = null) -> Dictionary:
	var out := {}
	for k in src:
		var v = src[k]
		out[k] = v.duplicate(true) if (v is Array or v is Dictionary) else v
	for k in empty():
		if not out.has(k):
			out[k] = empty()[k]
	out.positions = positions
	out.face_counts = counts
	out.face_indices = idx
	var nV := positions.size() / 3
	var cm: Dictionary = corners if corners != null else corner_map(src)
	var cm2 := {}
	for v in cm:
		if v < nV:
			cm2[v] = cm[v]
	_store_corners(out, cm2)
	for key in ["frozen", "sym_isolated"]:
		var list := PackedInt32Array()
		for v in (out[key] as PackedInt32Array):
			if v < nV:
				list.append(v)
		out[key] = list
	_extend_symmetry(out, nV)
	var m: Dictionary = creases if creases != null else crease_map(src)
	if not m.is_empty():
		m = _existing_edges(m, counts, idx, nV)
	_store_creases(out, m)
	return out


## The entries of m (edge key -> weight) that are edges of the faces.
static func _existing_edges(m: Dictionary, counts: PackedInt32Array, idx: PackedInt32Array, nV: int) -> Dictionary:
	var mark := PackedByteArray()
	mark.resize(nV)
	for k in m:
		var a: int = k >> 32
		var b: int = k & _LOW
		if a < nV and b < nV:
			mark[a] = 1
			mark[b] = 1
	var out := {}
	var o := 0
	for f in counts.size():
		var n := counts[f]
		for i in n:
			var a := idx[o + i]
			var b := idx[o + (i + 1) % n]
			if mark[a] and mark[b]:
				var key := _key(a, b)
				if m.has(key):
					out[key] = m[key]
		o += n
	return out


## Creases for a cage whose vertices come from older ones (origin[new] = old): every new edge
## whose ends come from a creased pair gets its weight.
static func _creases_by_origin(old: Dictionary, counts: PackedInt32Array, idx: PackedInt32Array, origin: PackedInt32Array) -> Dictionary:
	var out := {}
	if old.is_empty():
		return out
	var o := 0
	for f in counts.size():
		var n := counts[f]
		for i in n:
			var a := idx[o + i]
			var b := idx[o + (i + 1) % n]
			var key := _key(origin[a], origin[b])
			if origin[a] != origin[b] and old.has(key):
				out[_key(a, b)] = old[key]
		o += n
	return out


static func _lerp_point(p: PackedFloat64Array, a: int, b: int, t: float, out: PackedFloat64Array) -> void:
	out.append(p[3 * a] + (p[3 * b] - p[3 * a]) * t)
	out.append(p[3 * a + 1] + (p[3 * b + 1] - p[3 * a + 1]) * t)
	out.append(p[3 * a + 2] + (p[3 * b + 2] - p[3 * a + 2]) * t)


static func _dist(p: PackedFloat64Array, a: int, b: int) -> float:
	return sqrt(pow(p[3 * a] - p[3 * b], 2) + pow(p[3 * a + 1] - p[3 * b + 1], 2) + pow(p[3 * a + 2] - p[3 * b + 2], 2))


## Cuts polygon poly along the chord x-y (both vertices of it): two polygons, or [] when the
## chord isn't inside it.
static func _cut(poly: PackedInt32Array, x: int, y: int) -> Array:
	var i := poly.find(x)
	var j := poly.find(y)
	var n := poly.size()
	if i < 0 or j < 0 or i == j or (i + 1) % n == j or (j + 1) % n == i:
		return []
	var a := PackedInt32Array()
	var k := i
	while true:
		a.append(poly[k])
		if k == j:
			break
		k = (k + 1) % n
	var b := PackedInt32Array()
	k = j
	while true:
		b.append(poly[k])
		if k == i:
			break
		k = (k + 1) % n
	return [a, b]


# ---------------------------------------------------------------------------------------------
# Low-level topology ops
# ---------------------------------------------------------------------------------------------

## Removes faces, then the vertices no face uses.
static func delete_faces(c: Dictionary, faces: PackedInt32Array) -> Dictionary:
	var nF := face_count(c)
	var drop := PackedByteArray()
	drop.resize(nF)
	for f in faces:
		if f < 0 or f >= nF:
			return _fail(c, "Face %d doesn't exist." % f)
		drop[f] = 1
	var counts: PackedInt32Array = c.face_counts
	var idx: PackedInt32Array = c.face_indices
	var nc := PackedInt32Array()
	var ni := PackedInt32Array()
	var o := 0
	for f in nF:
		var n := counts[f]
		if not drop[f]:
			nc.append(n)
			ni.append_array(idx.slice(o, o + n))
		o += n
	var comp := compact(_assemble_flat(c, c.positions, nc, ni))
	return _result(comp.cage, {"vertex_map": comp.vertex_map if comp.changed else PackedInt32Array()})


## Interior edges merge their two faces into one polygon; boundary edges delete their face.
## Vertices left with two edges inside a merged face are dissolved too. Refused when the merge
## would leave a face touching itself or two faces joined along separate runs of edges.
static func dissolve_edges(c: Dictionary, pairs: PackedInt32Array) -> Dictionary:
	var t := Topo.new(c)
	var removed := PackedByteArray()
	removed.resize(t.nE)
	var deleted := PackedByteArray()
	deleted.resize(t.nF)
	for i in pairs.size() / 2:
		var e := t.edge_index(pairs[2 * i], pairs[2 * i + 1])
		if e < 0:
			return _fail(c, "%d-%d is not an edge." % [pairs[2 * i], pairs[2 * i + 1]])
		if t.edge_uses[e] == 1:
			deleted[t.he_face[t.edge_he[e]]] = 1
		elif t.edge_uses[e] == 2:
			removed[e] = 1
		else:
			return _fail(c, "Edge %d-%d has more than two faces." % [pairs[2 * i], pairs[2 * i + 1]])
	return _merge_faces(c, t, removed, deleted, PackedByteArray(), true)


## A valence-2 vertex leaves both its faces; any other vertex merges its faces into one polygon
## (its ring of neighbours must be a simple loop, or a simple path on the boundary).
static func dissolve_vertices(c: Dictionary, verts: PackedInt32Array) -> Dictionary:
	var t := Topo.new(c)
	var removed := PackedByteArray()
	removed.resize(t.nE)
	var drop := PackedByteArray()
	drop.resize(t.nV)
	for v in verts:
		if v < 0 or v >= t.nV:
			return _fail(c, "Vertex %d doesn't exist." % v)
		drop[v] = 1
		if t.valence(v) <= 2:
			continue
		for e in t.vertex_edges(v):
			if t.edge_uses[e] == 2:
				removed[e] = 1
	return _merge_faces(c, t, removed, PackedByteArray(), drop, false)


## The shared engine of the dissolves: merges the faces joined by removed edges, deletes the
## groups holding a deleted face, takes drop vertices out of their polygons, then (cleanup)
## dissolves interior valence-2 vertices left on merged polygons, and compacts.
static func _merge_faces(c: Dictionary, t: Topo, removed: PackedByteArray, deleted: PackedByteArray, drop: PackedByteArray, cleanup: bool) -> Dictionary:
	var nF := t.nF
	var parent := PackedInt32Array()
	parent.resize(nF)
	for f in nF:
		parent[f] = f
	for e in removed.size():
		if not removed[e]:
			continue
		var a := _find(parent, t.he_face[t.edge_he[e]])
		var b := _find(parent, t.he_face[t.edge_he2[e]])
		if a != b:
			parent[maxi(a, b)] = mini(a, b)
	# Union by lowest index: each group's root is its lowest face.
	var root := PackedInt32Array()
	root.resize(nF)
	var gsize := PackedInt32Array()
	gsize.resize(nF)
	for f in nF:
		root[f] = _find(parent, f)
		gsize[root[f]] += 1
	var groups := {}
	for f in nF:
		var r := root[f]
		if gsize[r] > 1:
			if not groups.has(r):
				groups[r] = PackedInt32Array()
			var g: PackedInt32Array = groups[r]
			g.append(f)
			groups[r] = g
	var group_deleted := {}
	if not deleted.is_empty():
		for f in nF:
			if deleted[f]:
				group_deleted[_find(parent, f)] = true
	var faces := []
	var merged_index := PackedInt32Array()
	for f in nF:
		var r := _find(parent, f)
		if group_deleted.has(r):
			continue
		if not groups.has(r):
			faces.append(t.face_verts(f))
			continue
		if r != f:
			continue
		# Chain the group's remaining half-edges into one loop.
		var gfaces: PackedInt32Array = groups[r]
		var next_of := {}
		var count := 0
		for g in gfaces:
			for h in range(t.face_offsets[g], t.face_offsets[g + 1]):
				if removed[t.he_edge[h]]:
					continue
				var a := t.face_indices[h]
				if next_of.has(a):
					return _fail(c, "Dissolving that would make a face that touches itself.")
				next_of[a] = t.he_dest(h)
				count += 1
		if count == 0:
			continue
		var start: int = next_of.keys()[0]
		var poly := PackedInt32Array()
		var v := start
		var guard := count + 1
		while guard > 0:
			guard -= 1
			poly.append(v)
			if not next_of.has(v):
				return _fail(c, "Dissolving that would leave an open face.")
			v = next_of[v]
			if v == start:
				break
		if poly.size() != count:
			return _fail(c, "Dissolving that would make a face with a hole in it.")
		merged_index.append(faces.size())
		faces.append(poly)
	if not drop.is_empty():
		for i in faces.size():
			var poly: PackedInt32Array = faces[i]
			var kept := PackedInt32Array()
			for v in poly:
				if not drop[v]:
					kept.append(v)
			if kept.size() != poly.size():
				if kept.size() < 3:
					return _fail(c, "Dissolving that would leave a face with fewer than three corners.")
				faces[i] = kept
	var mid := _assemble(c, c.positions, faces)
	if cleanup and not merged_index.is_empty():
		var t2 := Topo.new(mid)
		var on_merged := PackedByteArray()
		on_merged.resize(t2.nV)
		for i in merged_index:
			for v in (faces[i] as PackedInt32Array):
				on_merged[v] = 1
		var drop2 := PackedByteArray()
		drop2.resize(t2.nV)
		var any := false
		for v in t2.nV:
			if on_merged[v] and not t2.is_boundary_vertex(v) and t2.valence(v) == 2:
				drop2[v] = 1
				any = true
		if any:
			var creases := crease_map(mid)
			for i in faces.size():
				var poly: PackedInt32Array = faces[i]
				var kept := PackedInt32Array()
				for v in poly:
					if not drop2[v]:
						kept.append(v)
				if kept.size() >= 3:
					faces[i] = kept
				else:
					# Keep the vertex rather than collapse the face.
					for v in poly:
						drop2[v] = 0
			# A crease through a dissolved vertex continues on the joined edge.
			for v in t2.nV:
				if not drop2[v]:
					continue
				var nb := t2.vertex_neighbors(v)
				if nb.size() == 2 and creases.has(_key(v, nb[0])) and creases.has(_key(v, nb[1])):
					creases[_key(nb[0], nb[1])] = maxf(creases[_key(v, nb[0])], creases[_key(v, nb[1])])
			mid = _assemble(c, c.positions, faces, creases)
	# Two faces may share only one run of edges.
	var t3 := Topo.new(mid)
	for i in merged_index:
		if i >= t3.nF:
			continue
		var runs := {}
		var s := t3.face_offsets[i]
		var n := t3.face_size(i)
		var prev_g := -2
		var first_g := -2
		for k in n:
			var tw := t3.he_twin[s + k]
			var g := t3.he_face[tw] if tw >= 0 else -1
			if k == 0:
				first_g = g
			if g >= 0 and g != prev_g:
				runs[g] = int(runs.get(g, 0)) + 1
			prev_g = g
		if n > 1 and prev_g == first_g and first_g >= 0 and int(runs.get(first_g, 0)) > 1:
			runs[first_g] = int(runs[first_g]) - 1
		for g in runs:
			if int(runs[g]) > 1:
				return _fail(c, "Dissolving that would join two faces along separate edges.")
	var comp := compact(mid)
	return _result(comp.cage, {"vertex_map": comp.vertex_map if comp.changed else PackedInt32Array(), "new_faces": merged_index})


static func _find(parent: PackedInt32Array, x: int) -> int:
	var r := x
	while parent[r] != r:
		r = parent[r]
	while parent[x] != r:
		var nx := parent[x]
		parent[x] = r
		x = nx
	return r


## A new vertex at lerp(a, b, t) (doubles) inserted into both faces of edge (a, b). A crease on
## (a, b) is copied to both halves.
static func split_edge(c: Dictionary, a: int, b: int, t: float) -> Dictionary:
	var topo := Topo.new(c)
	var e := topo.edge_index(a, b)
	if e < 0:
		return _fail(c, "%d-%d is not an edge." % [a, b])
	var p: PackedFloat64Array = c.positions
	var np := p.duplicate()
	var m := topo.nV
	_lerp_point(p, a, b, t, np)
	var faces := _faces_array(c)
	for f in topo.edge_faces(e):
		var poly: PackedInt32Array = faces[f]
		var n := poly.size()
		for k in n:
			var x := poly[k]
			var y := poly[(k + 1) % n]
			if (x == a and y == b) or (x == b and y == a):
				poly.insert(k + 1, m)
				break
		faces[f] = poly
	var creases := crease_map(c)
	var w: float = creases.get(_key(a, b), 0.0)
	if w > 0.0:
		creases.erase(_key(a, b))
		creases[_key(a, m)] = w
		creases[_key(m, b)] = w
	var out := _assemble(c, np, faces, creases)
	return _result(out, {"new_vertices": PackedInt32Array([m]), "new_edges": PackedInt32Array([mini(a, m), maxi(a, m), mini(m, b), maxi(m, b)])})


## Connects two non-adjacent vertices of face f with a new edge, splitting f in two.
static func split_face(c: Dictionary, f: int, va: int, vb: int) -> Dictionary:
	var faces := _faces_array(c)
	if f < 0 or f >= faces.size():
		return _fail(c, "Face %d doesn't exist." % f)
	var poly: PackedInt32Array = faces[f]
	var parts := _cut(poly, va, vb)
	if parts.is_empty():
		return _fail(c, "Pick two corners of the face that aren't already joined by an edge.")
	var topo := Topo.new(c)
	if topo.edge_index(va, vb) >= 0:
		return _fail(c, "Those corners are already joined by an edge.")
	faces[f] = parts[0]
	faces.append(parts[1])
	var out := _assemble(c, c.positions, faces)
	return _result(out, {"new_edges": PackedInt32Array([mini(va, vb), maxi(va, vb)]), "new_faces": PackedInt32Array([f, faces.size() - 1])})


## Simple Insert Edge. items: [{"edge": Vector2i(a, b), "side": face}]. In each side face F, with
## the edge at corners i (a) and i + 1 (b), the rails (a, F[i-1]) and (b, F[i+2]) get points at
## t from a and b, and F splits into the quad (a, b, r_b, r_a) and the rest. Rails shared by
## consecutive faces share their point; a rail's other face gains the point (becoming an n-gon).
## both: the faces on the other side of each edge too. opts.width: rail points at that distance
## (t per rail, clamped to 0.01..0.99) instead of t. A creased rail stays creased on both halves.
## Extra result key "item_vertices": Array of PackedInt32Array([r_a, r_b]) per item used.
static func insert_edge_loop(c: Dictionary, items: Array, t: float, both: bool, opts := {}) -> Dictionary:
	var width := float(opts.get("width", -1.0))
	if width <= 0.0 and (t <= 0.0 or t >= 1.0):
		return _fail(c, "The insert location must be between 0 and 1.")
	var given = opts.get("topo")
	var topo: Topo = given if given is Topo else Topo.new(c)
	var p: PackedFloat64Array = c.positions
	var np := p.duplicate()
	var nV := topo.nV
	var used: Array = []
	for item in items:
		used.append(item)
	if both:
		for item in items:
			var ev: Vector2i = item.edge
			var e := topo.edge_index(ev.x, ev.y)
			if e < 0:
				continue
			for g in topo.edge_faces(e):
				if g != int(item.side):
					used.append({"edge": ev, "side": g})
	var points := {}      # edge key -> Array of [param from the low end, vertex]
	var chords := {}      # face -> Array of [r_a, r_b]
	var item_vertices: Array = []
	var new_vertices := PackedInt32Array()
	var new_edges := PackedInt32Array()
	var seen_items := {}
	for item in used:
		var ev: Vector2i = item.edge
		var f := int(item.side)
		if f < 0 or f >= topo.nF:
			item_vertices.append(PackedInt32Array())
			continue
		var ikey := "%d:%d:%d" % [mini(ev.x, ev.y), maxi(ev.x, ev.y), f]
		if seen_items.has(ikey):
			item_vertices.append(PackedInt32Array())
			continue
		seen_items[ikey] = true
		var s := topo.face_offsets[f]
		var n := topo.face_size(f)
		var i := -1
		for k in n:
			var x := topo.face_indices[s + k]
			var y := topo.face_indices[s + (k + 1) % n]
			if (x == ev.x and y == ev.y) or (x == ev.y and y == ev.x):
				i = k
				break
		if i < 0:
			return _fail(c, "Edge %d-%d is not on face %d." % [ev.x, ev.y, f])
		var a := topo.face_indices[s + i]
		var b := topo.face_indices[s + (i + 1) % n]
		var pa := topo.face_indices[s + (i - 1 + n) % n]
		var pb := topo.face_indices[s + (i + 2) % n]
		var ra := _rail_point(p, np, points, a, pa, t, width, new_vertices)
		var rb := _rail_point(p, np, points, b, pb, t, width, new_vertices)
		if ra < 0 or rb < 0:
			return _fail(c, "Two inserts meet on one edge at different places.")
		if not chords.has(f):
			chords[f] = []
		(chords[f] as Array).append([ra, rb])
		item_vertices.append(PackedInt32Array([ra, rb]))
		new_edges.append(mini(ra, rb))
		new_edges.append(maxi(ra, rb))
	if chords.is_empty():
		return _fail(c, "There was no face to insert into.")
	var faces := []
	var new_faces := PackedInt32Array()
	var touched := _touched_faces(topo, points)
	for f in topo.nF:
		var poly := _expand_face(topo, f, points) if touched[f] else topo.face_verts(f)
		if not chords.has(f):
			faces.append(poly)
			continue
		var pieces: Array = [poly]
		for chord in chords[f]:
			var done := false
			for j in pieces.size():
				var parts := _cut(pieces[j], chord[0], chord[1])
				if parts.is_empty():
					continue
				pieces[j] = parts[0]
				pieces.append(parts[1])
				done = true
				break
			if not done:
				return _fail(c, "The inserted edges cross inside face %d." % f)
		for piece in pieces:
			new_faces.append(faces.size())
			faces.append(piece)
	var creases := crease_map(c)
	for key in points:
		var w: float = creases.get(key, 0.0)
		if w <= 0.0:
			continue
		var lo: int = key >> 32
		var hi: int = key & _LOW
		var chain := PackedInt32Array([lo])
		for entry in _sorted_points(points[key]):
			chain.append(entry[1])
		chain.append(hi)
		creases.erase(key)
		for j in chain.size() - 1:
			creases[_key(chain[j], chain[j + 1])] = w
	var out := _assemble(c, np, faces, creases)
	return _result(out, {"new_vertices": new_vertices, "new_edges": new_edges, "new_faces": new_faces, "item_vertices": item_vertices, "items_used": used})


## The vertex at t along rail from -> to (an existing one at the same place is reused; a rail
## may hold several points, which go into its faces in order).
static func _rail_point(p: PackedFloat64Array, np: PackedFloat64Array, points: Dictionary, from: int, to: int, t: float, width: float, new_vertices: PackedInt32Array) -> int:
	var tt := t
	if width > 0.0:
		var length := _dist(p, from, to)
		tt = clampf(width / maxf(length, 1e-300), 0.01, 0.99)
	var key := _key(from, to)
	var param := tt if from < to else 1.0 - tt
	if points.has(key):
		for entry in points[key]:
			if absf(float(entry[0]) - param) < 1e-12:
				return int(entry[1])
	var v := np.size() / 3
	_lerp_point(p, from, to, tt, np)
	if not points.has(key):
		points[key] = []
	(points[key] as Array).append([param, v])
	new_vertices.append(v)
	return v


static func _sorted_points(list: Array) -> Array:
	var s := list.duplicate()
	s.sort_custom(func(x, y) -> bool: return float(x[0]) < float(y[0]))
	return s


## 1 for every face with an edge that has points on it.
static func _touched_faces(topo: Topo, points: Dictionary) -> PackedByteArray:
	var mark := PackedByteArray()
	mark.resize(topo.nF)
	for key in points:
		var e: int = topo.edge_lookup.get(key, -1)
		if e < 0:
			continue
		for g in topo.edge_faces(e):
			mark[g] = 1
	return mark


## Face f's loop with the points on its edges inserted in order.
static func _expand_face(topo: Topo, f: int, points: Dictionary) -> PackedInt32Array:
	var s := topo.face_offsets[f]
	var n := topo.face_size(f)
	var out := PackedInt32Array()
	for k in n:
		var a := topo.face_indices[s + k]
		var b := topo.face_indices[s + (k + 1) % n]
		out.append(a)
		var key := _key(a, b)
		if points.has(key):
			var sp := _sorted_points(points[key])
			if a > b:
				sp.reverse()
			for entry in sp:
				out.append(int(entry[1]))
	return out


## Quads become nu x nv grids (u along corner 0 -> 1), bilinear in doubles; other faces become n
## quads around their centroid through edge midpoints. Edges between two picked faces are split
## alike; an edge shared with an unpicked face puts its new points into that face.
## counts: optional per-face Vector2i(nu, nv) overrides (a mirrored partner face, whose corners run
## the other way, takes the counts swapped so it splits like its partner).
static func subdivide_faces(c: Dictionary, faces: PackedInt32Array, nu: int, nv: int, topo = null, counts := {}) -> Dictionary:
	return _subdivide(c, faces, nu, nv, false, topo, counts)


## Every listed face becomes n quads (centroid + edge midpoints); unlisted neighbours gain the
## midpoints (none do when whole components are listed).
static func split_to_quads(c: Dictionary, faces: PackedInt32Array) -> Dictionary:
	return _subdivide(c, faces, 2, 2, true)


static func _subdivide(c: Dictionary, faces: PackedInt32Array, nu: int, nv: int, all_ngon: bool, given = null, counts := {}) -> Dictionary:
	if nu < 1 or nv < 1:
		return _fail(c, "Face counts must be at least 1.")
	var topo: Topo = given if given is Topo else Topo.new(c)
	var picked := PackedByteArray()
	picked.resize(topo.nF)
	for f in faces:
		if f < 0 or f >= topo.nF:
			return _fail(c, "Face %d doesn't exist." % f)
		picked[f] = 1
	var div := PackedInt32Array()
	div.resize(topo.nE)
	for f in topo.nF:
		if not picked[f]:
			continue
		var s := topo.face_offsets[f]
		var n := topo.face_size(f)
		var quad := n == 4 and not all_ngon
		var fc: Vector2i = counts.get(f, Vector2i(nu, nv))
		for k in n:
			var want := (fc.x if k % 2 == 0 else fc.y) if quad else 2
			var e := topo.he_edge[s + k]
			if div[e] != 0 and div[e] != want:
				return _fail(c, "Those faces can't all be split %d x %d; use equal counts." % [nu, nv])
			div[e] = want
	var p: PackedFloat64Array = c.positions
	var np := p.duplicate()
	var points := {}
	var new_vertices := PackedInt32Array()
	for e in topo.nE:
		var k := div[e]
		if k < 2:
			continue
		var a := topo.edges[2 * e]
		var b := topo.edges[2 * e + 1]
		var list := []
		for j in range(1, k):
			var v := np.size() / 3
			_lerp_point(p, a, b, float(j) / k, np)
			list.append([float(j) / k, v])
			new_vertices.append(v)
		points[_key(a, b)] = list
	var out_faces := []
	var new_faces := PackedInt32Array()
	var touched := _touched_faces(topo, points)
	for f in topo.nF:
		if not picked[f]:
			out_faces.append(_expand_face(topo, f, points) if touched[f] else topo.face_verts(f))
			continue
		var s := topo.face_offsets[f]
		var n := topo.face_size(f)
		var corners := topo.face_indices.slice(s, s + n)
		if n == 4 and not all_ngon:
			# Grid G(i, j), i along corner 0 -> 1 (nu), j along corner 0 -> 3 (nv).
			var fc: Vector2i = counts.get(f, Vector2i(nu, nv))
			var fnu := fc.x
			var fnv := fc.y
			var g := PackedInt32Array()
			g.resize((fnu + 1) * (fnv + 1))
			var side0 := _edge_run(topo, points, corners[0], corners[1])
			var side1 := _edge_run(topo, points, corners[1], corners[2])
			var side2 := _edge_run(topo, points, corners[3], corners[2])
			var side3 := _edge_run(topo, points, corners[0], corners[3])
			for i in fnu + 1:
				g[i] = side0[i]
				g[fnv * (fnu + 1) + i] = side2[i]
			for j in fnv + 1:
				g[j * (fnu + 1)] = side3[j]
				g[j * (fnu + 1) + fnu] = side1[j]
			for j in range(1, fnv):
				for i in range(1, fnu):
					var u := float(i) / fnu
					var w := float(j) / fnv
					var v := np.size() / 3
					for d in 3:
						var x := (1.0 - u) * (1.0 - w) * p[3 * corners[0] + d] + u * (1.0 - w) * p[3 * corners[1] + d] + u * w * p[3 * corners[2] + d] + (1.0 - u) * w * p[3 * corners[3] + d]
						np.append(x)
					g[j * (fnu + 1) + i] = v
					new_vertices.append(v)
			for j in fnv:
				for i in fnu:
					new_faces.append(out_faces.size())
					out_faces.append(PackedInt32Array([g[j * (fnu + 1) + i], g[j * (fnu + 1) + i + 1], g[(j + 1) * (fnu + 1) + i + 1], g[(j + 1) * (fnu + 1) + i]]))
		else:
			var centre := np.size() / 3
			for d in 3:
				var sum := 0.0
				for v in corners:
					sum += p[3 * v + d]
				np.append(sum / n)
			new_vertices.append(centre)
			for k in n:
				var a := corners[k]
				var mk := _edge_run(topo, points, a, corners[(k + 1) % n])[1]
				var run_prev := _edge_run(topo, points, corners[(k - 1 + n) % n], a)
				var mp := run_prev[run_prev.size() - 2]
				new_faces.append(out_faces.size())
				out_faces.append(PackedInt32Array([a, mk, centre, mp]))
	var creases := crease_map(c)
	for key in points:
		var w: float = creases.get(key, 0.0)
		if w <= 0.0:
			continue
		var chain := PackedInt32Array([key >> 32])
		for entry in points[key]:
			chain.append(entry[1])
		chain.append(key & _LOW)
		creases.erase(key)
		for j in chain.size() - 1:
			creases[_key(chain[j], chain[j + 1])] = w
	var out := _assemble(c, np, out_faces, creases)
	return _result(out, {"new_vertices": new_vertices, "new_faces": new_faces})


## The vertices along edge a -> b including both ends.
static func _edge_run(_topo: Topo, points: Dictionary, a: int, b: int) -> PackedInt32Array:
	var out := PackedInt32Array([a])
	var key := _key(a, b)
	if points.has(key):
		var list: Array = points[key]
		if a < b:
			for entry in list:
				out.append(entry[1])
		else:
			for j in range(list.size() - 1, -1, -1):
				out.append(list[j][1])
	out.append(b)
	return out


## One Catmull-Clark step with OpenSubdiv's infinitely sharp rules. Vertex v keeps id v (moved),
## then come the edge points (canonical edge order) and the face points. faces: limit the step to
## those faces' components (empty = the whole cage). Creases go to both halves (weight kept),
## corners stay corners, symmetry maps get -1 for the new vertices.
static func catmull_clark_step(c: Dictionary, faces := PackedInt32Array()) -> Dictionary:
	var topo := Topo.new(c)
	var nV := topo.nV
	var nF := topo.nF
	var doing := PackedByteArray()
	doing.resize(nF)
	if faces.is_empty():
		doing.fill(1)
	else:
		var comps := topo.components()
		var want := {}
		for f in faces:
			if f < 0 or f >= nF:
				return _fail(c, "Face %d doesn't exist." % f)
			want[comps[f]] = true
		var listed := PackedByteArray()
		listed.resize(nF)
		for f in faces:
			listed[f] = 1
		for f in nF:
			if want.has(comps[f]):
				doing[f] = 1
				if not listed[f]:
					return _fail(c, "An exact step needs every face of the body part.")
	var p: PackedFloat64Array = c.positions
	var creases := crease_map(c)
	var corner := corner_map(c)
	# Face points.
	var fp := PackedFloat64Array()
	fp.resize(3 * nF)
	var face_id := PackedInt32Array()
	face_id.resize(nF)
	face_id.fill(-1)
	# Edges in play and their points.
	var edge_id := PackedInt32Array()
	edge_id.resize(topo.nE)
	edge_id.fill(-1)
	var ne := 0
	for e in topo.nE:
		if doing[topo.he_face[topo.edge_he[e]]]:
			edge_id[e] = nV + ne
			ne += 1
	var nf := 0
	for f in nF:
		if not doing[f]:
			continue
		face_id[f] = nV + ne + nf
		nf += 1
		var s := topo.face_offsets[f]
		var n := topo.face_size(f)
		var x := 0.0
		var y := 0.0
		var z := 0.0
		for h in range(s, s + n):
			var v := 3 * topo.face_indices[h]
			x += p[v]
			y += p[v + 1]
			z += p[v + 2]
		fp[3 * f] = x / n
		fp[3 * f + 1] = y / n
		fp[3 * f + 2] = z / n
	var np := p.duplicate()
	np.resize(3 * (nV + ne + nf))
	var sharp_edge := PackedByteArray()
	sharp_edge.resize(topo.nE)
	for e in topo.nE:
		var id := edge_id[e]
		if id < 0:
			continue
		var a := 3 * topo.edges[2 * e]
		var b := 3 * topo.edges[2 * e + 1]
		var sharp := topo.edge_uses[e] != 2 or creases.has(_key(topo.edges[2 * e], topo.edges[2 * e + 1]))
		sharp_edge[e] = 1 if sharp else 0
		if sharp:
			for d in 3:
				np[3 * id + d] = (p[a + d] + p[b + d]) * 0.5
		else:
			var f0 := 3 * topo.he_face[topo.edge_he[e]]
			var f1 := 3 * topo.he_face[topo.edge_he2[e]]
			for d in 3:
				np[3 * id + d] = (p[a + d] + p[b + d] + fp[f0 + d] + fp[f1 + d]) * 0.25
	for f in nF:
		var id := face_id[f]
		if id >= 0:
			np[3 * id] = fp[3 * f]
			np[3 * id + 1] = fp[3 * f + 1]
			np[3 * id + 2] = fp[3 * f + 2]
	# Vertex points: accumulate around each vertex.
	var fsum := PackedFloat64Array()
	fsum.resize(3 * nV)
	var fcount := PackedInt32Array()
	fcount.resize(nV)
	for f in nF:
		if not doing[f]:
			continue
		for h in range(topo.face_offsets[f], topo.face_offsets[f + 1]):
			var v := topo.face_indices[h]
			fcount[v] += 1
			for d in 3:
				fsum[3 * v + d] += fp[3 * f + d]
	var rsum := PackedFloat64Array()
	rsum.resize(3 * nV)
	var valence := PackedInt32Array()
	valence.resize(nV)
	var nsharp := PackedInt32Array()
	nsharp.resize(nV)
	var ssum := PackedFloat64Array()
	ssum.resize(3 * nV)
	var boundary := PackedByteArray()
	boundary.resize(nV)
	for e in topo.nE:
		if edge_id[e] < 0:
			continue
		var a := topo.edges[2 * e]
		var b := topo.edges[2 * e + 1]
		valence[a] += 1
		valence[b] += 1
		if topo.edge_uses[e] == 1:
			boundary[a] = 1
			boundary[b] = 1
		for d in 3:
			var mid := (p[3 * a + d] + p[3 * b + d]) * 0.5
			rsum[3 * a + d] += mid
			rsum[3 * b + d] += mid
		if sharp_edge[e]:
			nsharp[a] += 1
			nsharp[b] += 1
			for d in 3:
				ssum[3 * a + d] += p[3 * b + d]
				ssum[3 * b + d] += p[3 * a + d]
	for v in nV:
		var n := valence[v]
		if n == 0:
			continue
		if corner.has(v) or nsharp[v] >= 3 or (boundary[v] and n == 2):
			continue
		if nsharp[v] == 2:
			for d in 3:
				np[3 * v + d] = (ssum[3 * v + d] + 6.0 * p[3 * v + d]) * 0.125
			continue
		for d in 3:
			var fa := fsum[3 * v + d] / fcount[v]
			var ra := rsum[3 * v + d] / n
			np[3 * v + d] = (fa + 2.0 * ra + (n - 3) * p[3 * v + d]) / n
	# Topology.
	var out_faces := []
	var new_creases := {}
	for key in creases:
		var a: int = key >> 32
		var b: int = key & _LOW
		var e := topo.edge_index(a, b)
		if e < 0:
			continue
		if edge_id[e] < 0:
			new_creases[key] = creases[key]
			continue
		new_creases[_key(a, edge_id[e])] = creases[key]
		new_creases[_key(edge_id[e], b)] = creases[key]
	for f in nF:
		var s := topo.face_offsets[f]
		var n := topo.face_size(f)
		if not doing[f]:
			out_faces.append(topo.face_indices.slice(s, s + n))
			continue
		for k in n:
			var h := s + k
			var hp := s + (k - 1 + n) % n
			out_faces.append(PackedInt32Array([topo.face_indices[h], edge_id[topo.he_edge[h]], face_id[f], edge_id[topo.he_edge[hp]]]))
	var out := _assemble(c, np, out_faces, new_creases)
	var nvs := PackedInt32Array()
	for v in range(nV, nV + ne + nf):
		nvs.append(v)
	return _result(out, {"new_vertices": nvs})


## Extrudes a face region: its boundary vertices are duplicated (same place) and the region
## faces move onto the copies; one side quad joins each region-boundary edge to its copy.
## Interior region vertices are reused. new_faces = the region faces (indices unchanged),
## new_edges = the region's new boundary edges. keep_creases: the copied rim keeps the rim's
## creases (the original rim always keeps them).
static func extrude_faces(c: Dictionary, faces: PackedInt32Array, keep_creases := false, given = null) -> Dictionary:
	var topo: Topo = given if given is Topo else Topo.new(c)
	if faces.is_empty():
		return _fail(c, "Pick faces to extrude.")
	var region := PackedByteArray()
	region.resize(topo.nF)
	for f in faces:
		if f < 0 or f >= topo.nF:
			return _fail(c, "Face %d doesn't exist." % f)
		region[f] = 1
	var p: PackedFloat64Array = c.positions
	var np := p.duplicate()
	var dup := PackedInt32Array()
	dup.resize(topo.nV)
	dup.fill(-1)
	var rim := PackedInt32Array()
	for f in topo.nF:
		if not region[f]:
			continue
		for h in range(topo.face_offsets[f], topo.face_offsets[f + 1]):
			var t := topo.he_twin[h]
			if t >= 0 and region[topo.he_face[t]]:
				continue
			rim.append(h)
	var new_vertices := PackedInt32Array()
	for h in rim:
		for v in [topo.face_indices[h], topo.he_dest(h)]:
			if dup[v] < 0:
				dup[v] = np.size() / 3
				np.append(p[3 * v])
				np.append(p[3 * v + 1])
				np.append(p[3 * v + 2])
				new_vertices.append(dup[v])
	var out_faces := _faces_array(c)
	for f in topo.nF:
		if not region[f]:
			continue
		var poly: PackedInt32Array = out_faces[f]
		for k in poly.size():
			if dup[poly[k]] >= 0:
				poly[k] = dup[poly[k]]
		out_faces[f] = poly
	var new_edges := PackedInt32Array()
	for h in rim:
		var a := topo.face_indices[h]
		var b := topo.he_dest(h)
		out_faces.append(PackedInt32Array([a, b, dup[b], dup[a]]))
		new_edges.append(mini(dup[a], dup[b]))
		new_edges.append(maxi(dup[a], dup[b]))
	var creases := crease_map(c)
	var nc := {}
	for key in creases:
		var a: int = key >> 32
		var b: int = key & _LOW
		var e := topo.edge_index(a, b)
		if e < 0:
			continue
		var in_region := 0
		for g in topo.edge_faces(e):
			if region[g]:
				in_region += 1
		var uses := topo.edge_uses[e]
		if in_region == 0:
			nc[key] = creases[key]
		elif in_region == uses:
			# Inside the region (or on its open border): it moves with the region.
			var a2 := dup[a] if dup[a] >= 0 else a
			var b2 := dup[b] if dup[b] >= 0 else b
			nc[_key(a2, b2)] = creases[key]
			if uses == 1:
				nc[key] = creases[key]
		else:
			nc[key] = creases[key]
			if keep_creases:
				nc[_key(dup[a], dup[b])] = creases[key]
	var corners := corner_map(c)
	if keep_creases:
		for v in corners.keys():
			if dup[v] >= 0:
				corners[dup[v]] = corners[v]
	var out := _assemble(c, np, out_faces, nc, corners)
	return _result(out, {"new_vertices": new_vertices, "new_edges": new_edges, "new_faces": faces.duplicate(), "dup": dup})


## Extends open boundary edges: each chain vertex is duplicated (same place) and one quad per
## edge is added beyond the boundary. new_edges = the new outer chain.
static func extend_boundary(c: Dictionary, pairs: PackedInt32Array, keep_creases := false) -> Dictionary:
	var topo := Topo.new(c)
	if pairs.is_empty():
		return _fail(c, "Pick open boundary edges to extend.")
	var p: PackedFloat64Array = c.positions
	var np := p.duplicate()
	var dup := PackedInt32Array()
	dup.resize(topo.nV)
	dup.fill(-1)
	var hes := PackedInt32Array()
	for i in pairs.size() / 2:
		var e := topo.edge_index(pairs[2 * i], pairs[2 * i + 1])
		if e < 0 or topo.edge_uses[e] != 1:
			return _fail(c, "Only open boundary edges can be extended.")
		hes.append(topo.edge_he[e])
	var new_vertices := PackedInt32Array()
	for h in hes:
		for v in [topo.face_indices[h], topo.he_dest(h)]:
			if dup[v] < 0:
				dup[v] = np.size() / 3
				np.append(p[3 * v])
				np.append(p[3 * v + 1])
				np.append(p[3 * v + 2])
				new_vertices.append(dup[v])
	var faces := _faces_array(c)
	var new_edges := PackedInt32Array()
	var new_faces := PackedInt32Array()
	var creases := crease_map(c)
	for h in hes:
		var a := topo.face_indices[h]
		var b := topo.he_dest(h)
		new_faces.append(faces.size())
		faces.append(PackedInt32Array([b, a, dup[a], dup[b]]))
		new_edges.append(mini(dup[a], dup[b]))
		new_edges.append(maxi(dup[a], dup[b]))
		if keep_creases and creases.has(_key(a, b)):
			creases[_key(dup[a], dup[b])] = creases[_key(a, b)]
	var corners := corner_map(c)
	if keep_creases:
		for v in corners.keys():
			if dup[v] >= 0:
				corners[dup[v]] = corners[v]
	var out := _assemble(c, np, faces, creases, corners)
	return _result(out, {"new_vertices": new_vertices, "new_edges": new_edges, "new_faces": new_faces, "dup": dup})


## Fills the hole bounded by a boundary vertex loop (either direction). mode:
## "star" (Fill Star): one n-gon; "collapse": a pole at the centroid with n triangles;
## "reduced" (Reduced Star): a triangle or quad for n = 3 or 4; for even n a Coons-patch grid
## a x b with a = floor(n / 4), b = n / 2 - a, its corners where the rim turns most; for odd n,
## the shortest rim edge gets a point g inside the hole (its midpoint moved a quarter of the way
## to the centroid) closed by one triangle, and the remaining even loop of n + 1 is gridded.
static func fill_hole(c: Dictionary, loop: PackedInt32Array, mode: String) -> Dictionary:
	var n := loop.size()
	if n < 3:
		return _fail(c, "A hole needs at least three edges.")
	var topo := Topo.new(c)
	for i in n:
		var e := topo.edge_index(loop[i], loop[(i + 1) % n])
		if e < 0 or topo.edge_uses[e] != 1:
			return _fail(c, "That is not an open boundary loop.")
	# Fill faces run the loop against the existing faces.
	var fill := loop.duplicate()
	if topo.half_edge(loop[0], loop[1]) >= 0:
		fill.reverse()
	var p: PackedFloat64Array = c.positions
	var np := p.duplicate()
	var faces := _faces_array(c)
	var new_faces := PackedInt32Array()
	var new_vertices := PackedInt32Array()
	var m := mode.to_lower()
	if m.begins_with("fill") or m == "star":
		new_faces.append(faces.size())
		faces.append(fill)
	elif m == "collapse":
		var pole := np.size() / 3
		for d in 3:
			var s := 0.0
			for v in fill:
				s += p[3 * v + d]
			np.append(s / n)
		new_vertices.append(pole)
		for k in n:
			new_faces.append(faces.size())
			faces.append(PackedInt32Array([fill[k], fill[(k + 1) % n], pole]))
	else:
		if n == 3 or n == 4:
			new_faces.append(faces.size())
			faces.append(fill)
		else:
			var ring := fill
			if n % 2 == 1:
				# The shortest rim edge gets a point inside the hole and one triangle.
				var j := 0
				var best := INF
				for k in n:
					var d := _dist(p, fill[k], fill[(k + 1) % n])
					if d < best:
						best = d
						j = k
				var cx := 0.0
				var cy := 0.0
				var cz := 0.0
				for v in fill:
					cx += p[3 * v]
					cy += p[3 * v + 1]
					cz += p[3 * v + 2]
				cx /= n
				cy /= n
				cz /= n
				var va := fill[j]
				var vb := fill[(j + 1) % n]
				var g := np.size() / 3
				var mx := (p[3 * va] + p[3 * vb]) * 0.5
				var my := (p[3 * va + 1] + p[3 * vb + 1]) * 0.5
				var mz := (p[3 * va + 2] + p[3 * vb + 2]) * 0.5
				np.append(mx + (cx - mx) * 0.25)
				np.append(my + (cy - my) * 0.25)
				np.append(mz + (cz - mz) * 0.25)
				new_vertices.append(g)
				new_faces.append(faces.size())
				faces.append(PackedInt32Array([va, vb, g]))
				ring = PackedInt32Array()
				for k in n:
					ring.append(fill[(j + 1 + k) % n])
				ring.append(g)
			var grid := _coons_fill(np, ring, new_vertices)
			for poly in grid:
				new_faces.append(faces.size())
				faces.append(poly)
	var out := _assemble(c, np, faces)
	return _result(out, {"new_vertices": new_vertices, "new_faces": new_faces})


## Grids an even loop (fill direction) with a Coons patch; appends interior points to np.
static func _coons_fill(np: PackedFloat64Array, ring: PackedInt32Array, new_vertices: PackedInt32Array) -> Array:
	var n := ring.size()
	var a := n / 4
	var b := n / 2 - a
	# Corners where the rim turns most (summed over the four corners).
	var turn := PackedFloat64Array()
	turn.resize(n)
	for k in n:
		var v0 := ring[(k - 1 + n) % n]
		var v1 := ring[k]
		var v2 := ring[(k + 1) % n]
		var ux := np[3 * v1] - np[3 * v0]
		var uy := np[3 * v1 + 1] - np[3 * v0 + 1]
		var uz := np[3 * v1 + 2] - np[3 * v0 + 2]
		var wx := np[3 * v2] - np[3 * v1]
		var wy := np[3 * v2 + 1] - np[3 * v1 + 1]
		var wz := np[3 * v2 + 2] - np[3 * v1 + 2]
		var lu := sqrt(ux * ux + uy * uy + uz * uz)
		var lw := sqrt(wx * wx + wy * wy + wz * wz)
		var cosv := (ux * wx + uy * wy + uz * wz) / maxf(lu * lw, 1e-300)
		turn[k] = acos(clampf(cosv, -1.0, 1.0))
	var best_r := 0
	var best_s := -INF
	for r in n:
		var s := turn[r] + turn[(r + a) % n] + turn[(r + a + b) % n] + turn[(r + 2 * a + b) % n]
		if s > best_s + 1e-9:
			best_s = s
			best_r = r
	var c0 := best_r
	var cols := a + 1
	var g := PackedInt32Array()
	g.resize((a + 1) * (b + 1))
	for i in a + 1:
		g[i] = ring[(c0 + i) % n]
		g[b * cols + i] = ring[(c0 + a + b + (a - i)) % n]
	for j in b + 1:
		g[j * cols + a] = ring[(c0 + a + j) % n]
		g[j * cols] = ring[(c0 + 2 * a + b + (b - j)) % n]
	for j in range(1, b):
		for i in range(1, a):
			var u := float(i) / a
			var w := float(j) / b
			var v := np.size() / 3
			for d in 3:
				var bottom := np[3 * g[i] + d]
				var top := np[3 * g[b * cols + i] + d]
				var left := np[3 * g[j * cols] + d]
				var right := np[3 * g[j * cols + a] + d]
				var c00 := np[3 * g[0] + d]
				var c10 := np[3 * g[a] + d]
				var c01 := np[3 * g[b * cols] + d]
				var c11 := np[3 * g[b * cols + a] + d]
				var x := (1.0 - w) * bottom + w * top + (1.0 - u) * left + u * right \
					- ((1.0 - u) * (1.0 - w) * c00 + u * (1.0 - w) * c10 + (1.0 - u) * w * c01 + u * w * c11)
				np.append(x)
			g[j * cols + i] = v
			new_vertices.append(v)
	var out := []
	for j in b:
		for i in a:
			out.append(PackedInt32Array([g[j * cols + i], g[j * cols + i + 1], g[(j + 1) * cols + i + 1], g[(j + 1) * cols + i]]))
	return out


## Bridges two boundary loops (or open chains with closed = false) with segments rows of faces.
## Counts must be equal or one a whole multiple k of the other (the faces touching the sparse
## side are then (k + 3)-gons). Loop two runs against loop one; its start is the vertex nearest
## loop one's start, plus twist steps; opts.pair = Vector2i(vertex of loop one, vertex of loop two)
## pairs those two instead (how symmetry partners copy an alignment). Rings between follow a cubic
## Hermite curve leaving each side along its outward direction (opts.n1 / opts.n2 override,
## Vector3). Extra result key "pair": the vertices that were paired, in that form.
static func bridge_loops(c: Dictionary, loop_a: PackedInt32Array, loop_b: PackedInt32Array, segments: int, twist: int, opts := {}) -> Dictionary:
	var closed := bool(opts.get("closed", true))
	var topo := Topo.new(c)
	var seg := maxi(1, segments)
	var A := _boundary_order(topo, loop_a, closed)
	var B := _boundary_order(topo, loop_b, closed)
	if A.is_empty() or B.is_empty():
		return _fail(c, "Each side must be an open boundary chain or loop.")
	for v in A:
		if B.has(v):
			return _fail(c, "The two sides share a vertex.")
	var na := A.size() if closed else A.size() - 1
	var nb := B.size() if closed else B.size() - 1
	var dense := A
	var sparse := B
	var nd := na
	var ns := nb
	var dense_is_a := true
	if nb > na:
		dense = B
		sparse = A
		nd = nb
		ns = na
		dense_is_a = false
	if ns < 1 or nd % ns != 0:
		return _fail(c, "The sides need the same number of edges, or one a multiple of the other.")
	var k := nd / ns
	var p: PackedFloat64Array = c.positions
	var np := p.duplicate()
	# Sparse vertex paired with dense position i * k: index s - i (against).
	var s := 0
	var pair = opts.get("pair")
	if closed and pair is Vector2i:
		var dv: int = pair.x if dense_is_a else pair.y
		var sv: int = pair.y if dense_is_a else pair.x
		var di := dense.find(dv)
		var si := sparse.find(sv)
		if di < 0 or si < 0:
			return _fail(c, "That bridge alignment doesn't fit the sides.")
		if di > 0:
			var rot := dense.slice(di)
			rot.append_array(dense.slice(0, di))
			dense = rot
		s = si
	elif closed:
		var best := INF
		for j in sparse.size():
			var d := _dist(p, dense[0], sparse[j])
			if d < best:
				best = d
				s = j
		s = (s + twist) % ns
		if s < 0:
			s += ns
	else:
		s = ns
	var sp := func(i: int) -> int:
		var j := s - i
		if closed:
			j = ((j % ns) + ns) % ns
		return sparse[j]
	var n1: Vector3 = opts.get("n1", _outward(c, topo, A, closed))
	var n2: Vector3 = opts.get("n2", _outward(c, topo, B, closed))
	if not dense_is_a:
		var tmp := n1
		n1 = n2
		n2 = tmp
	var cd := _centroid(p, dense)
	var cs := _centroid(p, sparse)
	var dist := cd.distance_to(cs)
	var faces := _faces_array(c)
	var new_faces := PackedInt32Array()
	var new_vertices := PackedInt32Array()
	var count := dense.size()
	# Target on the sparse side for each dense index.
	var targets := PackedFloat64Array()
	targets.resize(3 * count)
	for i in count:
		var j0 := i / k
		var f := float(i % k) / k
		var s0: int = sp.call(j0)
		var s1: int = sp.call(j0 + 1) if (closed or j0 + 1 <= ns) else s0
		for d in 3:
			targets[3 * i + d] = p[3 * s0 + d] + (p[3 * s1 + d] - p[3 * s0 + d]) * f
	var rings: Array = [dense]
	for r in range(1, seg):
		var t := float(r) / seg
		var h00 := 2.0 * t * t * t - 3.0 * t * t + 1.0
		var h10 := t * t * t - 2.0 * t * t + t
		var h01 := -2.0 * t * t * t + 3.0 * t * t
		var h11 := t * t * t - t * t
		var ring := PackedInt32Array()
		for i in count:
			var v := np.size() / 3
			var t1 := [n1.x * dist, n1.y * dist, n1.z * dist]
			var t2 := [-n2.x * dist, -n2.y * dist, -n2.z * dist]
			for d in 3:
				np.append(h00 * p[3 * dense[i] + d] + h10 * t1[d] + h01 * targets[3 * i + d] + h11 * t2[d])
			ring.append(v)
			new_vertices.append(v)
		rings.append(ring)
	var edges_d := nd
	for r in range(0, seg - 1):
		var r0: PackedInt32Array = rings[r]
		var r1: PackedInt32Array = rings[r + 1]
		for i in edges_d:
			var i1 := (i + 1) % count
			new_faces.append(faces.size())
			faces.append(PackedInt32Array([r0[i1], r0[i], r1[i], r1[i1]]))
	var last: PackedInt32Array = rings[rings.size() - 1]
	for j in ns:
		var poly := PackedInt32Array()
		for i in range(j * k + k, j * k - 1, -1):
			poly.append(last[i % count])
		poly.append(sp.call(j))
		poly.append(sp.call(j + 1))
		new_faces.append(faces.size())
		faces.append(poly)
	var out := _assemble(c, np, faces)
	var used_pair := Vector2i(dense[0], sp.call(0)) if dense_is_a else Vector2i(sp.call(0), dense[0])
	return _result(out, {"new_vertices": new_vertices, "new_faces": new_faces, "pair": used_pair})


## The loop (or chain) in boundary half-edge order, or [] when it isn't one.
static func _boundary_order(topo: Topo, loop: PackedInt32Array, closed: bool) -> PackedInt32Array:
	var n := loop.size()
	if n < 2:
		return PackedInt32Array()
	var m := n if closed else n - 1
	var forward := true
	var backward := true
	for i in m:
		var a := loop[i]
		var b := loop[(i + 1) % n]
		var e := topo.edge_index(a, b)
		if e < 0 or topo.edge_uses[e] != 1:
			return PackedInt32Array()
		var h := topo.edge_he[e]
		if topo.face_indices[h] == a:
			backward = false
		else:
			forward = false
	if forward:
		return loop.duplicate()
	if backward:
		var r := loop.duplicate()
		r.reverse()
		if closed:
			# Keep the same start vertex.
			var rot := PackedInt32Array([r[n - 1]])
			rot.append_array(r.slice(0, n - 1))
			return rot
		return r
	return PackedInt32Array()


## The mean in-surface direction leaving the faces along a boundary chain.
static func _outward(c: Dictionary, topo: Topo, loop: PackedInt32Array, closed: bool) -> Vector3:
	var p: PackedFloat64Array = c.positions
	var n := loop.size()
	var sum := Vector3.ZERO
	for i in (n if closed else n - 1):
		var a := loop[i]
		var b := loop[(i + 1) % n]
		var h := topo.half_edge(a, b)
		if h < 0:
			continue
		var fn := topo.face_area_vector(c, topo.he_face[h]).normalized()
		var d := Vector3(p[3 * b] - p[3 * a], p[3 * b + 1] - p[3 * a + 1], p[3 * b + 2] - p[3 * a + 2])
		sum += d.cross(fn).normalized()
	return sum.normalized()


static func _centroid(p: PackedFloat64Array, verts: PackedInt32Array) -> Vector3:
	var x := 0.0
	var y := 0.0
	var z := 0.0
	for v in verts:
		x += p[3 * v]
		y += p[3 * v + 1]
		z += p[3 * v + 2]
	var n := maxf(1.0, verts.size())
	return Vector3(x / n, y / n, z / n)


## Merges vertices: pairs is [Vector2i(keep, remove)], the second merging into the first (which
## keeps its position). Faces left with fewer than three corners go; duplicate faces go (both
## when they face opposite ways, as a wall between two welded bodies). Refused when an edge would
## get three faces. Extra result key "welded": old -> new id for every old vertex.
static func weld(c: Dictionary, pairs: Array) -> Dictionary:
	var nV := vertex_count(c)
	var parent := PackedInt32Array()
	parent.resize(nV)
	for v in nV:
		parent[v] = v
	for pr in pairs:
		var keep: int = pr.x
		var rem: int = pr.y
		if keep < 0 or rem < 0 or keep >= nV or rem >= nV:
			return _fail(c, "Vertex pair %s doesn't exist." % pr)
		var rk := _find(parent, keep)
		var rr := _find(parent, rem)
		if rk != rr:
			parent[rr] = rk
	var rep := PackedInt32Array()
	rep.resize(nV)
	for v in nV:
		rep[v] = _find(parent, v)
	var counts: PackedInt32Array = c.face_counts
	var idx: PackedInt32Array = c.face_indices
	var faces := []
	var keys := {}
	var o := 0
	for f in counts.size():
		var n := counts[f]
		var poly := PackedInt32Array()
		for k in n:
			var v := rep[idx[o + k]]
			if poly.is_empty() or poly[poly.size() - 1] != v:
				poly.append(v)
		while poly.size() > 1 and poly[0] == poly[poly.size() - 1]:
			poly.resize(poly.size() - 1)
		o += n
		if poly.size() < 3:
			continue
		var sorted := poly.duplicate()
		sorted.sort()
		var distinct := true
		for k in range(1, sorted.size()):
			if sorted[k] == sorted[k - 1]:
				distinct = false
				break
		if not distinct:
			continue
		var sk := str(sorted)
		if keys.has(sk):
			var other: int = keys[sk]
			if other >= 0 and _same_winding(faces[other], poly):
				continue
			if other >= 0:
				faces[other] = PackedInt32Array()
				keys[sk] = -1
			continue
		keys[sk] = faces.size()
		faces.append(poly)
	var kept := []
	for poly in faces:
		if (poly as PackedInt32Array).size() >= 3:
			kept.append(poly)
	var mid := remap_vertices(c, rep, c.positions)
	var out := _assemble(mid, c.positions, kept)
	var t := Topo.new(out)
	for e in t.nE:
		if t.edge_uses[e] > 2:
			return _fail(c, "Welding these vertices would make an edge with three faces.")
	var comp := compact(out)
	var final_map := PackedInt32Array()
	final_map.resize(nV)
	for v in nV:
		final_map[v] = comp.vertex_map[rep[v]]
	return _result(comp.cage, {"vertex_map": final_map, "welded": final_map, "misoriented": t.misoriented.size()})


static func _same_winding(a: PackedInt32Array, b: PackedInt32Array) -> bool:
	var n := a.size()
	if n != b.size():
		return false
	var i := b.find(a[0])
	if i < 0:
		return false
	return b[(i + 1) % n] == a[1 % n]


## Cuts along edges: around each vertex on the cut, its faces split into fans separated by cut or
## boundary edges; every fan after the first gets a copy of the vertex. Cut edges become pairs
## of boundary edges (creases and corners are copied).
static func unweld_edges(c: Dictionary, pairs: PackedInt32Array) -> Dictionary:
	var topo := Topo.new(c)
	var cut := PackedByteArray()
	cut.resize(topo.nE)
	var verts := {}
	for i in pairs.size() / 2:
		var e := topo.edge_index(pairs[2 * i], pairs[2 * i + 1])
		if e < 0:
			return _fail(c, "%d-%d is not an edge." % [pairs[2 * i], pairs[2 * i + 1]])
		if topo.edge_uses[e] != 2:
			continue
		cut[e] = 1
		verts[pairs[2 * i]] = true
		verts[pairs[2 * i + 1]] = true
	var p: PackedFloat64Array = c.positions
	var np := p.duplicate()
	var idx: PackedInt32Array = (c.face_indices as PackedInt32Array).duplicate()
	var origin := PackedInt32Array()
	origin.resize(topo.nV)
	for v in topo.nV:
		origin[v] = v
	var new_vertices := PackedInt32Array()
	for v in verts:
		var hs := topo.vertex_out(v)
		var k := hs.size()
		if k == 0:
			continue
		# The edge between face i - 1 and face i around v is he_edge[hs[i]].
		var interior := topo.he_twin[hs[0]] >= 0
		var start := 0
		if interior:
			start = -1
			for i in k:
				if cut[topo.he_edge[hs[i]]]:
					start = i
					break
			if start < 0:
				continue
		var fan := 0
		var copies := {}
		for step in k:
			var i := (start + step) % k
			if step > 0 and cut[topo.he_edge[hs[i]]]:
				fan += 1
			if fan == 0:
				continue
			if not copies.has(fan):
				var id := np.size() / 3
				np.append(p[3 * v])
				np.append(p[3 * v + 1])
				np.append(p[3 * v + 2])
				origin.append(v)
				new_vertices.append(id)
				copies[fan] = id
			idx[hs[i]] = copies[fan]
	var counts: PackedInt32Array = c.face_counts
	var creases := _creases_by_origin(crease_map(c), counts, idx, origin)
	var corners := corner_map(c)
	for nv_ in new_vertices:
		if corners.has(origin[nv_]):
			corners[nv_] = corners[origin[nv_]]
	var out := _assemble_flat(c, np, counts, idx, creases, corners)
	var new_edges := PackedInt32Array()
	return _result(out, {"new_vertices": new_vertices, "new_edges": new_edges, "origin": origin})


## Reverses the winding of faces (corner 0 stays first).
static func flip_faces(c: Dictionary, faces: PackedInt32Array) -> Dictionary:
	var counts: PackedInt32Array = c.face_counts
	var offs := face_offsets(c)
	var idx: PackedInt32Array = (c.face_indices as PackedInt32Array).duplicate()
	for f in faces:
		if f < 0 or f >= counts.size():
			return _fail(c, "Face %d doesn't exist." % f)
		var s := offs[f]
		var n := counts[f]
		for k in range(1, n):
			idx[s + k] = (c.face_indices as PackedInt32Array)[s + n - k]
	var out := copy(c)
	out.face_indices = idx
	return _result(out, {"new_faces": faces.duplicate()})


## Greedily merges adjacent triangles into quads, best pairs first (smallest deviation of the
## quad's corners from 90 degrees), when the quad is convex, the normals differ by less than
## max_angle_deg and the shared edge isn't creased.
static func merge_triangle_pairs(c: Dictionary, max_angle_deg := 30.0) -> Dictionary:
	var topo := Topo.new(c)
	var p: PackedFloat64Array = c.positions
	var creases := crease_map(c)
	var cos_max := cos(deg_to_rad(max_angle_deg))
	var cands: Array = []
	for e in topo.nE:
		if topo.edge_uses[e] != 2 or topo.he_twin[topo.edge_he[e]] < 0:
			continue
		var h1 := topo.edge_he[e]
		var h2 := topo.he_twin[h1]
		var f1 := topo.he_face[h1]
		var f2 := topo.he_face[h2]
		if topo.face_size(f1) != 3 or topo.face_size(f2) != 3:
			continue
		if creases.has(_key(topo.edges[2 * e], topo.edges[2 * e + 1])):
			continue
		var n1 := topo.face_normal(c, f1)
		var n2 := topo.face_normal(c, f2)
		if n1.dot(n2) < cos_max:
			continue
		# T1 = (a, b, x) with a -> b; T2 = (b, a, y): quad (a, y, b, x).
		var a := topo.face_indices[h1]
		var b := topo.he_dest(h1)
		var x := topo.face_indices[topo.he_prev(h1)]
		var y := topo.face_indices[topo.he_prev(h2)]
		var quad := PackedInt32Array([a, y, b, x])
		var score := _quad_score(p, quad, (n1 + n2).normalized())
		if score < 0.0:
			continue
		cands.append([score, f1, f2, quad])
	cands.sort_custom(func(u, w) -> bool: return float(u[0]) < float(w[0]))
	var used := PackedByteArray()
	used.resize(topo.nF)
	var faces := _faces_array(c)
	var merged := 0
	for cand in cands:
		var f1: int = cand[1]
		var f2: int = cand[2]
		if used[f1] or used[f2]:
			continue
		used[f1] = 1
		used[f2] = 1
		faces[f1] = cand[3]
		faces[f2] = PackedInt32Array()
		merged += 1
	var kept := []
	var new_faces := PackedInt32Array()
	for f in faces.size():
		var poly: PackedInt32Array = faces[f]
		if poly.is_empty():
			continue
		if poly.size() == 4 and used[f]:
			new_faces.append(kept.size())
		kept.append(poly)
	var out := _assemble(c, c.positions, kept)
	return _result(out, {"new_faces": new_faces, "merged": merged})


## Sum of |corner angle - 90 deg| (radians), or -1 when the quad isn't convex about normal n.
static func _quad_score(p: PackedFloat64Array, q: PackedInt32Array, n: Vector3) -> float:
	var score := 0.0
	for k in 4:
		var v0 := q[(k + 3) % 4]
		var v1 := q[k]
		var v2 := q[(k + 1) % 4]
		var u := Vector3(p[3 * v0] - p[3 * v1], p[3 * v0 + 1] - p[3 * v1 + 1], p[3 * v0 + 2] - p[3 * v1 + 2])
		var w := Vector3(p[3 * v2] - p[3 * v1], p[3 * v2 + 1] - p[3 * v1 + 1], p[3 * v2 + 2] - p[3 * v1 + 2])
		if w.cross(u).dot(n) <= 0.0:
			return -1.0
		score += absf(u.angle_to(w) - PI * 0.5)
	return score


## Flips faces so every component agrees with its first face, then turns closed components
## outward (positive signed volume). Extra result keys: "flipped" (faces flipped), "error" set
## when a component can't be oriented (a one-sided surface).
static func orient_consistently(c: Dictionary) -> Dictionary:
	var topo := Topo.new(c)
	var nF := topo.nF
	var orient := PackedInt32Array()
	orient.resize(nF)
	var comp := PackedInt32Array()
	comp.resize(nF)
	comp.fill(-1)
	var error := ""
	var ncomp := 0
	for f0 in nF:
		if comp[f0] >= 0:
			continue
		comp[f0] = ncomp
		orient[f0] = 1
		var queue := PackedInt32Array([f0])
		var qi := 0
		while qi < queue.size():
			var f := queue[qi]
			qi += 1
			for h in range(topo.face_offsets[f], topo.face_offsets[f + 1]):
				var e := topo.he_edge[h]
				if topo.edge_uses[e] != 2:
					continue
				var other := topo.edge_he2[e] if topo.edge_he[e] == h else topo.edge_he[e]
				var g := topo.he_face[other]
				if g == f:
					continue
				var same := topo.face_indices[other] == topo.face_indices[h]
				var want := orient[f] * (-1 if same else 1)
				if comp[g] < 0:
					comp[g] = ncomp
					orient[g] = want
					queue.append(g)
				elif orient[g] != want and error == "":
					error = "Part of the body is one-sided and can't be turned to face one way."
		ncomp += 1
	var flip := PackedInt32Array()
	for f in nF:
		if orient[f] < 0:
			flip.append(f)
	var r := flip_faces(c, flip)
	var out: Dictionary = r.cage
	var t2 := Topo.new(out)
	var comps := t2.components()
	var closed := PackedByteArray()
	closed.resize(t2.component_count())
	closed.fill(1)
	for e in t2.nE:
		if t2.edge_uses[e] == 1:
			closed[comps[t2.he_face[t2.edge_he[e]]]] = 0
	var vol := PackedFloat64Array()
	vol.resize(closed.size())
	var p: PackedFloat64Array = out.positions
	for f in t2.nF:
		var s := t2.face_offsets[f]
		var n := t2.face_size(f)
		var a := 3 * t2.face_indices[s]
		for k in range(1, n - 1):
			var b := 3 * t2.face_indices[s + k]
			var d := 3 * t2.face_indices[s + k + 1]
			vol[comps[f]] += p[a] * (p[b + 1] * p[d + 2] - p[b + 2] * p[d + 1]) - p[a + 1] * (p[b] * p[d + 2] - p[b + 2] * p[d]) + p[a + 2] * (p[b] * p[d + 1] - p[b + 1] * p[d])
	var flip2 := PackedInt32Array()
	for f in t2.nF:
		if closed[comps[f]] and vol[comps[f]] < 0.0:
			flip2.append(f)
	if not flip2.is_empty():
		out = flip_faces(out, flip2).cage
	var flipped := {}
	for f in flip:
		flipped[f] = true
	for f in flip2:
		if flipped.has(f):
			flipped.erase(f)
		else:
			flipped[f] = true
	var fl := PackedInt32Array(flipped.keys())
	fl.sort()
	var res := _result(out, {"flipped": fl})
	res.error = error
	return res


## The signed volume of the closed cage polygons (fan triangles), in doubles.
static func signed_volume(c: Dictionary) -> float:
	var p: PackedFloat64Array = c.positions
	var counts: PackedInt32Array = c.face_counts
	var idx: PackedInt32Array = c.face_indices
	var vol := 0.0
	var o := 0
	for f in counts.size():
		var n := counts[f]
		var a := 3 * idx[o]
		for k in range(1, n - 1):
			var b := 3 * idx[o + k]
			var d := 3 * idx[o + k + 1]
			vol += p[a] * (p[b + 1] * p[d + 2] - p[b + 2] * p[d + 1]) - p[a + 1] * (p[b] * p[d + 2] - p[b + 2] * p[d]) + p[a + 2] * (p[b] * p[d + 1] - p[b + 1] * p[d])
		o += n
	return vol / 6.0
