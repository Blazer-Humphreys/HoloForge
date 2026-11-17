@tool
extends RefCounted
## The Form tools as pure functions on cages, plus the double-precision geometry and the
## symmetry they share. No editor, no native kernel: the tools that need the kernel live in
## form_fit.gd with the same signature plus the CadSubD.
##
## Every tool is tool(c, sel, opts) -> {"ok", "cage", "selection", "warnings", "error", "info"}.
## sel = {"vertices": PackedInt32Array, "edges": PackedInt32Array (vertex pairs),
## "faces": PackedInt32Array}; tools with two picks read side two from "edges2" / "faces2";
## "body": true (or nothing selected, for body tools) means the whole cage. Every tool refuses
## selections it can't use with a sentence the editor can flash, never moves or rebuilds frozen
## geometry (the locked set, CAGE.locked_vertices), carries symmetry (partners follow; topology
## edits happen on both sides and the maps are rebuilt), and in debug builds fails when its
## result breaks a cage invariant. The input cage is never changed.
##
## Transforms are 12 doubles: a row-major 3x3 matrix then the translation.

const CAGE := preload("res://addons/holo_forge/core/form/cage.gd")

const BROKEN_PARTNERS := "Symmetry is broken here; some partners were skipped"
const NOTHING := "Nothing to change"


# ---------------------------------------------------------------------------------------------
# Geometry helpers (doubles)
# ---------------------------------------------------------------------------------------------

static func xf_identity() -> PackedFloat64Array:
	return PackedFloat64Array([1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0])


static func xf_from(basis: Basis, origin: Vector3) -> PackedFloat64Array:
	return PackedFloat64Array([basis.x.x, basis.y.x, basis.z.x, basis.x.y, basis.y.y, basis.z.y, basis.x.z, basis.y.z, basis.z.z, origin.x, origin.y, origin.z])


static func xf_translation(x: float, y: float, z: float) -> PackedFloat64Array:
	return PackedFloat64Array([1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, x, y, z])


## a after b.
static func xf_compose(a: PackedFloat64Array, b: PackedFloat64Array) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	out.resize(12)
	for r in 3:
		for c in 3:
			out[3 * r + c] = a[3 * r] * b[c] + a[3 * r + 1] * b[3 + c] + a[3 * r + 2] * b[6 + c]
		out[9 + r] = a[3 * r] * b[9] + a[3 * r + 1] * b[10] + a[3 * r + 2] * b[11] + a[9 + r]
	return out


static func xf_apply(xf: PackedFloat64Array, x: float, y: float, z: float) -> PackedFloat64Array:
	return PackedFloat64Array([
		xf[0] * x + xf[1] * y + xf[2] * z + xf[9],
		xf[3] * x + xf[4] * y + xf[5] * z + xf[10],
		xf[6] * x + xf[7] * y + xf[8] * z + xf[11]])


## The inverse of a rigid transform (orthonormal matrix: transpose).
static func xf_inverse_rigid(xf: PackedFloat64Array) -> PackedFloat64Array:
	var out := PackedFloat64Array([xf[0], xf[3], xf[6], xf[1], xf[4], xf[7], xf[2], xf[5], xf[8], 0.0, 0.0, 0.0])
	for r in 3:
		out[9 + r] = -(out[3 * r] * xf[9] + out[3 * r + 1] * xf[10] + out[3 * r + 2] * xf[11])
	return out


## xf applied about pivot: p -> xf(p - pivot) + pivot.
static func xf_about(xf: PackedFloat64Array, px: float, py: float, pz: float) -> PackedFloat64Array:
	return xf_compose(xf_translation(px, py, pz), xf_compose(xf, xf_translation(-px, -py, -pz)))


static func unit_d(v: PackedFloat64Array) -> PackedFloat64Array:
	var l := sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2])
	if l == 0.0:
		return PackedFloat64Array([0.0, 0.0, 1.0])
	if l == 1.0:
		return PackedFloat64Array([v[0], v[1], v[2]])
	return PackedFloat64Array([v[0] / l, v[1] / l, v[2] / l])


static func _d3(v) -> PackedFloat64Array:
	if v is Vector3:
		return PackedFloat64Array([v.x, v.y, v.z])
	if v is PackedFloat64Array or v is PackedFloat32Array or v is Array:
		return PackedFloat64Array([float(v[0]), float(v[1]), float(v[2])])
	return PackedFloat64Array([0.0, 0.0, 0.0])


## p reflected through the plane (origin, normal).
static func reflect_d(p: PackedFloat64Array, origin: PackedFloat64Array, normal: PackedFloat64Array) -> PackedFloat64Array:
	var n := unit_d(normal)
	var d := (p[0] - origin[0]) * n[0] + (p[1] - origin[1]) * n[1] + (p[2] - origin[2]) * n[2]
	return PackedFloat64Array([p[0] - 2.0 * d * n[0], p[1] - 2.0 * d * n[1], p[2] - 2.0 * d * n[2]])


## p rotated by angle (radians, right-handed) about the axis through origin (Rodrigues).
static func rotate_d(p: PackedFloat64Array, origin: PackedFloat64Array, axis: PackedFloat64Array, angle: float) -> PackedFloat64Array:
	var k := unit_d(axis)
	var vx := p[0] - origin[0]
	var vy := p[1] - origin[1]
	var vz := p[2] - origin[2]
	var c := cos(angle)
	var s := sin(angle)
	var kd := k[0] * vx + k[1] * vy + k[2] * vz
	var cx := k[1] * vz - k[2] * vy
	var cy := k[2] * vx - k[0] * vz
	var cz := k[0] * vy - k[1] * vx
	return PackedFloat64Array([
		vx * c + cx * s + k[0] * kd * (1.0 - c) + origin[0],
		vy * c + cy * s + k[1] * kd * (1.0 - c) + origin[1],
		vz * c + cz * s + k[2] * kd * (1.0 - c) + origin[2]])


static func mirror_xf(origin: PackedFloat64Array, normal: PackedFloat64Array) -> PackedFloat64Array:
	var n := unit_d(normal)
	var d := origin[0] * n[0] + origin[1] * n[1] + origin[2] * n[2]
	var out := PackedFloat64Array()
	out.resize(12)
	for r in 3:
		for c in 3:
			out[3 * r + c] = (1.0 if r == c else 0.0) - 2.0 * n[r] * n[c]
		out[9 + r] = 2.0 * d * n[r]
	return out


static func rotation_xf(origin: PackedFloat64Array, axis: PackedFloat64Array, angle: float) -> PackedFloat64Array:
	var k := unit_d(axis)
	var c := cos(angle)
	var s := sin(angle)
	var t := 1.0 - c
	var m := PackedFloat64Array([
		c + k[0] * k[0] * t, k[0] * k[1] * t - k[2] * s, k[0] * k[2] * t + k[1] * s,
		k[1] * k[0] * t + k[2] * s, c + k[1] * k[1] * t, k[1] * k[2] * t - k[0] * s,
		k[2] * k[0] * t - k[1] * s, k[2] * k[1] * t + k[0] * s, c + k[2] * k[2] * t,
		0.0, 0.0, 0.0])
	for r in 3:
		m[9 + r] = origin[r] - (m[3 * r] * origin[0] + m[3 * r + 1] * origin[1] + m[3 * r + 2] * origin[2])
	return m


## Moves verts: p' = p + w (xf(p - pivot) + pivot - p). weights: one per entry of verts, or one
## per cage vertex, or empty (all 1). pivots: 3 doubles per entry of verts (Local Per Entity), or
## empty when xf is already about the pivot. Only vertices with w > 0 are written; w == 1 writes
## xf(p) itself. Returns the tool result shape with info.moved.
static func transform_vertices(c: Dictionary, verts: PackedInt32Array, weights: PackedFloat32Array, xf: PackedFloat64Array, pivots := PackedFloat64Array()) -> Dictionary:
	var nV := CAGE.vertex_count(c)
	var p: PackedFloat64Array = c.positions
	var np := p.duplicate()
	var moved := PackedInt32Array()
	var per_vertex := weights.size() == nV and weights.size() != verts.size()
	for i in verts.size():
		var v := verts[i]
		if v < 0 or v >= nV:
			continue
		var w := 1.0
		if per_vertex:
			w = weights[v]
		elif weights.size() == verts.size():
			w = weights[i]
		if w <= 0.0:
			continue
		var x := p[3 * v]
		var y := p[3 * v + 1]
		var z := p[3 * v + 2]
		var q: PackedFloat64Array
		if pivots.size() >= 3 * (i + 1):
			var px := pivots[3 * i]
			var py := pivots[3 * i + 1]
			var pz := pivots[3 * i + 2]
			q = xf_apply(xf, x - px, y - py, z - pz)
			q[0] += px
			q[1] += py
			q[2] += pz
		else:
			q = xf_apply(xf, x, y, z)
		if w != 1.0:
			q[0] = x + w * (q[0] - x)
			q[1] = y + w * (q[1] - y)
			q[2] = z + w * (q[2] - z)
		if q[0] == x and q[1] == y and q[2] == z:
			continue
		np[3 * v] = q[0]
		np[3 * v + 1] = q[1]
		np[3 * v + 2] = q[2]
		moved.append(v)
	var out := CAGE.copy(c)
	out.positions = np
	return _done(out, {}, PackedStringArray(), {"moved": moved})


## Soft-modification weights for every cage vertex (selected = 1, locked = 0). opts:
## "extent" "distance" | "faces" | "rectangular"; "distance" R (meters); "faces" N;
## "u_faces" / "v_faces" (rectangular, times the mean edge); "frame" Basis whose X / Y measure
## the rectangle (default: selection frame); "transition" "smooth" | "linear" | "bulge";
## "weight" 0..1. w = weight * f(t), 0 for t >= 1, where Smooth f = 1 - (3t^2 - 2t^3),
## Linear 1 - t, Bulge 1 - t^2.
static func soft_weights(c: Dictionary, topo, selected: PackedInt32Array, opts: Dictionary) -> PackedFloat32Array:
	var t: CAGE.Topo = topo if topo != null else CAGE.topology(c)
	var nV := CAGE.vertex_count(c)
	var out := PackedFloat32Array()
	out.resize(nV)
	var p: PackedFloat64Array = c.positions
	var extent := str(opts.get("extent", "distance")).to_lower()
	var transition := str(opts.get("transition", "smooth")).to_lower()
	var weight := float(opts.get("weight", 1.0))
	var sel := PackedByteArray()
	sel.resize(nV)
	for v in selected:
		if v >= 0 and v < nV:
			sel[v] = 1
	var tvals := PackedFloat64Array()
	tvals.resize(nV)
	tvals.fill(INF)
	if extent.begins_with("face"):
		var n := maxi(0, int(opts.get("faces", 2)))
		var dist := _face_ring_distance(t, selected)
		for v in nV:
			if dist[v] >= 0:
				tvals[v] = float(dist[v]) / (n + 1)
	elif extent.begins_with("rect"):
		var mean := CAGE.mean_edge_length(c, t)
		var ru := maxf(1e-300, float(opts.get("u_faces", 2)) * mean)
		var rv := maxf(1e-300, float(opts.get("v_faces", 2)) * mean)
		var frame: Basis = opts.get("frame", _selection_basis(c, t, selected))
		var ux := frame.x.normalized()
		var vy := frame.y.normalized()
		# The rectangle is measured in the selection's plane, so the far side of a closed body
		# lines up with it too: only vertices within the rectangle's face count over the
		# surface can be reached.
		var reach := ceili(maxf(float(opts.get("u_faces", 2)), float(opts.get("v_faces", 2)))) + 1
		var rings := _face_ring_distance(t, selected)
		for v in nV:
			if rings[v] < 0 or rings[v] > reach:
				continue
			var best := INF
			for s in selected:
				var dx := p[3 * v] - p[3 * s]
				var dy := p[3 * v + 1] - p[3 * s + 1]
				var dz := p[3 * v + 2] - p[3 * s + 2]
				var du := absf(dx * ux.x + dy * ux.y + dz * ux.z) / ru
				var dv := absf(dx * vy.x + dy * vy.y + dz * vy.z) / rv
				best = minf(best, maxf(du, dv))
			tvals[v] = best
	else:
		var r := float(opts.get("distance", 0.0))
		if r <= 0.0:
			r = 2.0 * CAGE.mean_edge_length(c, t)
		var cell := maxf(r, 1e-300)
		var grid := {}
		for s in selected:
			var key := Vector3i(floori(p[3 * s] / cell), floori(p[3 * s + 1] / cell), floori(p[3 * s + 2] / cell))
			if not grid.has(key):
				grid[key] = []
			(grid[key] as Array).append(s)
		for v in nV:
			var kx := floori(p[3 * v] / cell)
			var ky := floori(p[3 * v + 1] / cell)
			var kz := floori(p[3 * v + 2] / cell)
			var best := INF
			for dx in range(-1, 2):
				for dy in range(-1, 2):
					for dz in range(-1, 2):
						var key := Vector3i(kx + dx, ky + dy, kz + dz)
						if not grid.has(key):
							continue
						for s in grid[key]:
							var d := sqrt(pow(p[3 * v] - p[3 * s], 2) + pow(p[3 * v + 1] - p[3 * s + 1], 2) + pow(p[3 * v + 2] - p[3 * s + 2], 2))
							best = minf(best, d)
			tvals[v] = best / r
	var locked := locked_set(c)
	for v in nV:
		if locked[v]:
			out[v] = 0.0
			continue
		if sel[v]:
			out[v] = 1.0
			continue
		var x := tvals[v]
		if x >= 1.0:
			out[v] = 0.0
			continue
		var f := 1.0 - x
		if transition == "smooth":
			f = 1.0 - (3.0 * x * x - 2.0 * x * x * x)
		elif transition == "bulge":
			f = 1.0 - x * x
		out[v] = weight * f
	return out


## Soft weights made symmetric: every member of a symmetry orbit gets the orbit's largest weight
## (what the mirrored or rotated drag moves it by). For display; drags rank by the raw weights.
static func symmetric_weights(c: Dictionary, w: PackedFloat32Array) -> PackedFloat32Array:
	var ctx := _sym_ctx(c)
	if (ctx.maps as Array).is_empty() or w.size() != int(ctx.nV):
		return w
	var out := w.duplicate()
	var done := PackedByteArray()
	done.resize(w.size())
	var iso: PackedByteArray = ctx.iso
	for v in w.size():
		if done[v] or iso[v] or w[v] <= 0.0:
			continue
		var orb := _orbit_ctx(ctx, v)
		var best := 0.0
		for u in orb:
			done[u] = 1
			best = maxf(best, w[u])
		for u in orb:
			if not iso[u]:
				out[u] = best
	return out


## BFS steps from the selected vertices over "shares a face" (-1 when unreached).
static func _face_ring_distance(t: CAGE.Topo, selected: PackedInt32Array) -> PackedInt32Array:
	var dist := PackedInt32Array()
	dist.resize(t.nV)
	dist.fill(-1)
	var queue := PackedInt32Array()
	for v in selected:
		if v >= 0 and v < t.nV and dist[v] < 0:
			dist[v] = 0
			queue.append(v)
	var qi := 0
	while qi < queue.size():
		var v := queue[qi]
		qi += 1
		for f in t.vertex_all_faces(v):
			for h in range(t.face_offsets[f], t.face_offsets[f + 1]):
				var w := t.face_indices[h]
				if dist[w] < 0:
					dist[w] = dist[v] + 1
					queue.append(w)
	return dist


## The selection frame: Z = mean normal at the vertices, X = their principal direction in the Z
## plane, Y = Z x X.
static func _selection_basis(c: Dictionary, t: CAGE.Topo, verts: PackedInt32Array) -> Basis:
	var z := Vector3.ZERO
	for v in verts:
		z += t.vertex_normal(c, v)
	if z.length() < 1e-12:
		z = Vector3.UP
	z = z.normalized()
	var pts := PackedFloat64Array()
	for v in verts:
		pts.append_array(CAGE.position_d(c, v))
	var line := best_fit_line(pts)
	var dir := _v3(line.direction)
	var x := dir - z * dir.dot(z)
	if x.length() < 1e-9:
		x = z.cross(Vector3.RIGHT if absf(z.x) < 0.9 else Vector3.FORWARD)
	x = x.normalized()
	return Basis(x, z.cross(x), z)


static func _v3(d: PackedFloat64Array) -> Vector3:
	return Vector3(d[0], d[1], d[2])


## {"origin", "normal"} (PackedFloat64Array(3) each): the plane through the centroid whose
## normal is the direction of least spread. points: PackedFloat64Array (xyz) or PackedVector3Array.
static func best_fit_plane(points) -> Dictionary:
	var pca := _pca(points)
	return {"origin": pca.centroid, "normal": pca.vectors[0]}


## {"origin", "direction"}: the line through the centroid along the direction of most spread.
static func best_fit_line(points) -> Dictionary:
	var pca := _pca(points)
	return {"origin": pca.centroid, "direction": pca.vectors[2]}


static func _pca(points) -> Dictionary:
	var pts := PackedFloat64Array()
	if points is PackedVector3Array:
		for q in points:
			pts.append(q.x)
			pts.append(q.y)
			pts.append(q.z)
	else:
		pts = PackedFloat64Array(points)
	var n := pts.size() / 3
	var cx := 0.0
	var cy := 0.0
	var cz := 0.0
	for i in n:
		cx += pts[3 * i]
		cy += pts[3 * i + 1]
		cz += pts[3 * i + 2]
	if n > 0:
		cx /= n
		cy /= n
		cz /= n
	var m := [[0.0, 0.0, 0.0], [0.0, 0.0, 0.0], [0.0, 0.0, 0.0]]
	for i in n:
		var d := [pts[3 * i] - cx, pts[3 * i + 1] - cy, pts[3 * i + 2] - cz]
		for r in 3:
			for k in 3:
				m[r][k] += d[r] * d[k]
	var eig := eigen_sym3(m)
	return {"centroid": PackedFloat64Array([cx, cy, cz]), "values": eig.values, "vectors": eig.vectors}


## Eigen-decomposition of a symmetric 3x3 matrix (Array of 3 rows) by Jacobi rotations, in
## doubles: {"values": [ascending], "vectors": [PackedFloat64Array(3) unit, matching]}.
static func eigen_sym3(m: Array) -> Dictionary:
	var a := [[float(m[0][0]), float(m[0][1]), float(m[0][2])], [float(m[1][0]), float(m[1][1]), float(m[1][2])], [float(m[2][0]), float(m[2][1]), float(m[2][2])]]
	var v := [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]]
	for sweep in 60:
		var off := absf(a[0][1]) + absf(a[0][2]) + absf(a[1][2])
		var scale := absf(a[0][0]) + absf(a[1][1]) + absf(a[2][2])
		if off <= 1e-300 or off <= 1e-17 * scale:
			break
		for pq in [[0, 1], [0, 2], [1, 2]]:
			var pi: int = pq[0]
			var qi: int = pq[1]
			if a[pi][qi] == 0.0:
				continue
			var theta: float = (a[qi][qi] - a[pi][pi]) / (2.0 * a[pi][qi])
			var t := signf(theta) / (absf(theta) + sqrt(theta * theta + 1.0))
			if theta == 0.0:
				t = 1.0
			var cs := 1.0 / sqrt(t * t + 1.0)
			var sn := t * cs
			for k in 3:
				var akp: float = a[k][pi]
				var akq: float = a[k][qi]
				a[k][pi] = cs * akp - sn * akq
				a[k][qi] = sn * akp + cs * akq
			for k in 3:
				var apk: float = a[pi][k]
				var aqk: float = a[qi][k]
				a[pi][k] = cs * apk - sn * aqk
				a[qi][k] = sn * apk + cs * aqk
			for k in 3:
				var vkp: float = v[k][pi]
				var vkq: float = v[k][qi]
				v[k][pi] = cs * vkp - sn * vkq
				v[k][qi] = sn * vkp + cs * vkq
	var order := [0, 1, 2]
	order.sort_custom(func(x, y) -> bool: return a[x][x] < a[y][y])
	var values := []
	var vectors := []
	for i in order:
		values.append(a[i][i])
		vectors.append(unit_d(PackedFloat64Array([v[0][i], v[1][i], v[2][i]])))
	return {"values": values, "vectors": vectors}


# ---------------------------------------------------------------------------------------------
# Symmetry
# ---------------------------------------------------------------------------------------------

## Generators of the symmetry group: each mirror map, each circular map and its inverse.
static func _sym_ctx(c: Dictionary) -> Dictionary:
	var nV := CAGE.vertex_count(c)
	var maps: Array = []
	var xfs: Array = []
	var ends: Array = []
	var fixed: Array = []   # per entry: {"type", "origin", "dir", "map"}
	for entry in c.get("symmetry", []):
		var m: PackedInt32Array = entry.get("map", PackedInt32Array())
		if m.size() != nV:
			continue
		var o := _d3(entry.get("origin", PackedFloat64Array([0, 0, 0])))
		if str(entry.get("type", "")) == "mirror":
			var n := unit_d(_d3(entry.get("normal", PackedFloat64Array([1, 0, 0]))))
			maps.append(m)
			xfs.append(mirror_xf(o, n))
			ends.append(false)
			fixed.append({"type": "mirror", "origin": o, "dir": n, "map": m})
		else:
			var ax := unit_d(_d3(entry.get("axis", PackedFloat64Array([0, 0, 1]))))
			var step := float(entry.get("step", TAU / maxi(2, int(entry.get("count", 2)))))
			var open := bool(entry.get("open", false))
			var inv := PackedInt32Array()
			inv.resize(nV)
			inv.fill(-1)
			for v in nV:
				if m[v] >= 0:
					inv[m[v]] = v
			maps.append(m)
			xfs.append(rotation_xf(o, ax, step))
			ends.append(open)
			maps.append(inv)
			xfs.append(rotation_xf(o, ax, -step))
			ends.append(open)
			fixed.append({"type": "circular", "origin": o, "dir": ax, "map": m})
	var iso := PackedByteArray()
	iso.resize(nV)
	for v in (c.get("sym_isolated", PackedInt32Array()) as PackedInt32Array):
		if v >= 0 and v < nV:
			iso[v] = 1
	return {"maps": maps, "xfs": xfs, "ends": ends, "fixed": fixed, "iso": iso, "nV": nV}


static func _orbit_ctx(ctx: Dictionary, v: int) -> Dictionary:
	return _orbit_full(ctx, v).orbit


## v's orbit {w: xf taking v's position to w's} and v's stabilizer: the transforms of the group
## that take v to itself (other than the identity), found where two paths reach one member with
## different transforms. With combined entries (a mirror and a circular pattern, two mirrors)
## a vertex can be fixed by an element no single entry is, such as the mirror across the plane
## between a mirror and a half turn: its moves must stay on that element's fixed set too.
## {"orbit": {w: xf}, "stab": [xf]}.
static func _orbit_full(ctx: Dictionary, v: int) -> Dictionary:
	var out := {v: xf_identity()}
	var stab: Array = []
	var iso: PackedByteArray = ctx.iso
	if iso[v]:
		return {"orbit": out, "stab": stab}
	var maps: Array = ctx.maps
	var xfs: Array = ctx.xfs
	var queue := PackedInt32Array([v])
	var qi := 0
	while qi < queue.size():
		var u := queue[qi]
		qi += 1
		var xu: PackedFloat64Array = out[u]
		for g in maps.size():
			var m: PackedInt32Array = maps[g]
			var w := m[u]
			if w < 0 or iso[w]:
				continue
			var t := xf_compose(xfs[g], xu)
			if out.has(w):
				# A second way to w: (first way)^-1 after this one takes v to itself.
				if not _xf_near(t, out[w]):
					var e := xf_compose(xf_inverse_rigid(out[w]), t)
					var known := false
					for k in stab:
						if _xf_near(k, e):
							known = true
							break
					if not known:
						stab.append(e)
				continue
			out[w] = t
			queue.append(w)
	return {"orbit": out, "stab": stab}


## Whether two transforms agree (to rounding at the sizes cages have).
static func _xf_near(a: PackedFloat64Array, b: PackedFloat64Array) -> bool:
	for i in 9:
		if absf(a[i] - b[i]) > 1e-9:
			return false
	for i in range(9, 12):
		if absf(a[i] - b[i]) > 1e-9 * (1.0 + absf(a[i]) + absf(b[i])):
			return false
	return true


## q moved onto the set the stabilizer elements stab (and everything they generate) keep fixed:
## the mean of q's images under that finite group, which every element of it maps to itself.
static func _stab_fix(stab: Array, q: PackedFloat64Array) -> PackedFloat64Array:
	if stab.is_empty():
		return q
	var group: Array = [xf_identity()]
	var i := 0
	# (Bounded: entries at an angle that isn't a whole fraction of a turn generate no finite group.)
	while i < group.size() and group.size() < 256:
		var a: PackedFloat64Array = group[i]
		i += 1
		for s in stab:
			var b := xf_compose(s, a)
			var dup := false
			for e in group:
				if _xf_near(e, b):
					dup = true
					break
			if not dup:
				group.append(b)
	var x := 0.0
	var y := 0.0
	var z := 0.0
	for e in group:
		var r := xf_apply(e, q[0], q[1], q[2])
		x += r[0]
		y += r[1]
		z += r[2]
	var n := float(group.size())
	return PackedFloat64Array([x / n, y / n, z / n])


## The vertices a symmetric edit must leave where they are: the locked set (CAGE.locked_vertices,
## frozen faces and their buffer) and, under symmetry, every partner of a locked vertex, since a
## partner that moved while its frozen image stayed would leave the body asymmetric.
static func locked_set(c: Dictionary) -> PackedByteArray:
	var locked := CAGE.locked_vertices(c)
	if not _has_symmetry(c):
		return locked
	var out := locked.duplicate()
	var any := false
	for v in locked.size():
		if locked[v]:
			any = true
			break
	if not any:
		return out
	var ctx := _sym_ctx(c)
	var done := PackedByteArray()
	done.resize(locked.size())
	for v in locked.size():
		if not locked[v] or done[v]:
			continue
		for w in _orbit_ctx(ctx, v):
			done[w] = 1
			out[w] = 1
	return out


## {w: xf} for every vertex w in v's symmetry orbit, xf taking v's position to w's (12 doubles).
## Isolated vertices have no orbit beyond themselves.
static func orbit(c: Dictionary, v: int) -> Dictionary:
	return _orbit_ctx(_sym_ctx(c), v)


## Every image of a vertex tuple under the symmetry group (the tuple itself first), and whether
## some partner was missing. Images with an isolated or missing vertex are skipped.
static func _images(ctx: Dictionary, tuple: PackedInt32Array) -> Dictionary:
	var out: Array = [tuple]
	var iso: PackedByteArray = ctx.iso
	var broken := false
	for x in tuple:
		if x < 0 or x >= iso.size() or iso[x]:
			return {"images": out, "broken": false}
	var maps: Array = ctx.maps
	var ends: Array = ctx.ends
	var seen := {str(tuple): true}
	var qi := 0
	while qi < out.size():
		var t: PackedInt32Array = out[qi]
		qi += 1
		for g in maps.size():
			var m: PackedInt32Array = maps[g]
			var img := PackedInt32Array()
			img.resize(t.size())
			var ok := true
			for i in t.size():
				var w := m[t[i]]
				if w < 0 or iso[w]:
					if w < 0 and not ends[g]:
						broken = true
					ok = false
					break
				img[i] = w
			if not ok:
				continue
			var key := str(img)
			if seen.has(key):
				continue
			seen[key] = true
			out.append(img)
	return {"images": out, "broken": broken}


## sel united with the symmetry partners of each element (all entries, repeatedly). An edge maps
## to the edge between its mapped ends, a face to the face with its mapped vertices; elements
## whose partner doesn't exist are left alone with a warning. Returns a selection dictionary
## with an extra "warnings" key.
static func partner_selection(c: Dictionary, sel: Dictionary) -> Dictionary:
	return _partners(c, sel, null)


static func _partners(c: Dictionary, sel: Dictionary, given) -> Dictionary:
	var verts := _list(sel, "vertices")
	var pairs := _list(sel, "edges")
	var faces := _list(sel, "faces")
	var out := {"vertices": verts.duplicate(), "edges": pairs.duplicate(), "faces": faces.duplicate(), "warnings": PackedStringArray()}
	var ctx := _sym_ctx(c)
	if (ctx.maps as Array).is_empty():
		return out
	var broken := false
	var vset := {}
	var vout := PackedInt32Array()
	for v in verts:
		var r := _images(ctx, PackedInt32Array([v]))
		broken = broken or r.broken
		for img in r.images:
			if not vset.has(img[0]):
				vset[img[0]] = true
				vout.append(img[0])
	var topo: CAGE.Topo = given
	var eset := {}
	var eout := PackedInt32Array()
	if topo == null and (not pairs.is_empty() or not faces.is_empty()):
		topo = CAGE.topology(c)
	for i in pairs.size() / 2:
		var r := _images(ctx, PackedInt32Array([pairs[2 * i], pairs[2 * i + 1]]))
		broken = broken or r.broken
		for img in r.images:
			if topo.edge_index(img[0], img[1]) < 0:
				broken = true
				continue
			var key := CAGE.edge_key(img[0], img[1])
			if not eset.has(key):
				eset[key] = true
				eout.append(mini(img[0], img[1]))
				eout.append(maxi(img[0], img[1]))
	var fset := {}
	var fout := PackedInt32Array()
	for f in faces:
		if f < 0 or f >= topo.nF:
			continue
		var r := _images(ctx, topo.face_verts(f))
		broken = broken or r.broken
		for img in r.images:
			var g := topo.face_by_vertices(img)
			if g < 0:
				broken = true
				continue
			if not fset.has(g):
				fset[g] = true
				fout.append(g)
	out.vertices = vout
	out.edges = eout
	out.faces = fout
	if broken:
		out.warnings.append(BROKEN_PARTNERS)
	return out


## Writes partner positions from the primary vertices: per orbit, the representative is the mean
## of the primary members' positions taken into one member's frame; every non-isolated, unlocked
## member gets its image. A vertex its own mirror partner lands on the plane, one on a circular
## axis on the axis. All in doubles; only changed vertices are written. info.moved lists them.
static func apply_symmetry(c: Dictionary, primary: PackedInt32Array) -> Dictionary:
	var ctx := _sym_ctx(c)
	var out := CAGE.copy(c)
	if (ctx.maps as Array).is_empty() or primary.is_empty():
		return _done(out, {}, PackedStringArray(), {"moved": PackedInt32Array()})
	var nV: int = ctx.nV
	var iso: PackedByteArray = ctx.iso
	var locked := CAGE.locked_vertices(c)
	var is_primary := PackedByteArray()
	is_primary.resize(nV)
	for v in primary:
		if v >= 0 and v < nV:
			is_primary[v] = 1
	var done := PackedByteArray()
	done.resize(nV)
	var p: PackedFloat64Array = c.positions
	var np := p.duplicate()
	var moved := PackedInt32Array()
	for v in primary:
		if v < 0 or v >= nV or done[v] or iso[v]:
			continue
		var full := _orbit_full(ctx, v)
		var orb: Dictionary = full.orbit
		var rx := 0.0
		var ry := 0.0
		var rz := 0.0
		var count := 0
		# An orbit with a frozen member keeps that member's place: the others take its image
		# (whatever moved them), so frozen geometry and the symmetry both hold.
		var anchor := -1
		for w in orb:
			if locked[w]:
				anchor = w
				break
		for w in orb:
			done[w] = 1
			if anchor >= 0:
				if w == anchor:
					var a := xf_apply(xf_inverse_rigid(orb[w]), p[3 * w], p[3 * w + 1], p[3 * w + 2])
					rx = a[0]
					ry = a[1]
					rz = a[2]
					count = 1
				continue
			if not is_primary[w] or locked[w]:
				continue
			var q := xf_apply(xf_inverse_rigid(orb[w]), p[3 * w], p[3 * w + 1], p[3 * w + 2])
			rx += q[0]
			ry += q[1]
			rz += q[2]
			count += 1
		if count == 0:
			continue
		if count > 1:
			rx /= count
			ry /= count
			rz /= count
		if anchor < 0:
			var fixed := _stab_fix(full.stab, PackedFloat64Array([rx, ry, rz]))
			rx = fixed[0]
			ry = fixed[1]
			rz = fixed[2]
		for w in orb:
			if locked[w] or iso[w]:
				continue
			var q := xf_apply(orb[w], rx, ry, rz)
			q = _project_fixed(ctx, w, q)
			if q[0] == np[3 * w] and q[1] == np[3 * w + 1] and q[2] == np[3 * w + 2]:
				continue
			np[3 * w] = q[0]
			np[3 * w + 1] = q[1]
			np[3 * w + 2] = q[2]
			moved.append(w)
	out.positions = np
	return _done(out, {}, PackedStringArray(), {"moved": moved})


const BREAKS_SYMMETRY := "That move would break the body's symmetry; clear it first."
const SYMMETRIC_FROZEN_BODY := "Frozen faces hold part of this symmetric body, so it can't move as a whole; unfreeze them first."
const FROZEN_PARTNERS := "Those vertices' symmetry partners are frozen, so they can't move; unfreeze the partners first."


## A move of some vertices carried to their symmetry partners (Edit Form drags and typed moves).
## start: the cage before the move; moved: start with the moving vertices moved; order: the
## moving vertices, the selection first; rank: per cage vertex, how strongly it was moved (1 for
## the selection, its soft weight otherwise; empty = all 1).
## Per orbit one member drives, the moving member with the highest rank (the earliest in order on
## ties), and every other member takes its image: the selection follows the drag exactly and its
## partners get the mirrored or rotated move (and soft field), never an average of both sides'
## moves (which would cancel a move across the plane or collapse a rotated body).
## whole_xf: the transform when it moved every vertex alike (a body selection): the symmetry
## planes and axes then move with the body; a transform that would leave them no longer a
## symmetry (a skewing scale) is refused with BREAKS_SYMMETRY.
## Returns {"ok", "cage", "error", "moved"}.
static func carry_symmetry(start: Dictionary, moved: Dictionary, order: PackedInt32Array, rank := PackedFloat32Array(), whole_xf := PackedFloat64Array()) -> Dictionary:
	var nV := CAGE.vertex_count(start)
	var p0: PackedFloat64Array = start.positions
	var p1: PackedFloat64Array = moved.positions
	if not _has_symmetry(start):
		return {"ok": true, "cage": moved, "error": "", "moved": _changed(p0, p1)}
	if whole_xf.size() == 12:
		var out := CAGE.copy(moved)
		var sym: Array = []
		var x := whole_xf
		# Normals move with the inverse transpose; axes with the matrix (flipped by a reflection,
		# which turns a +step rotation into a -step one).
		var det := x[0] * (x[4] * x[8] - x[5] * x[7]) - x[1] * (x[3] * x[8] - x[5] * x[6]) + x[2] * (x[3] * x[7] - x[4] * x[6])
		if absf(det) < 1e-300:
			return {"ok": false, "cage": CAGE.copy(start), "error": BREAKS_SYMMETRY, "moved": PackedInt32Array()}
		for entry in start.get("symmetry", []):
			var e: Dictionary = (entry as Dictionary).duplicate(true)
			var o := _d3(e.get("origin", PackedFloat64Array([0, 0, 0])))
			e.origin = xf_apply(x, o[0], o[1], o[2])
			if str(e.get("type", "")) == "mirror":
				var n := _d3(e.get("normal", PackedFloat64Array([1, 0, 0])))
				# Cofactor matrix = det * inverse transpose.
				var c0 := (x[4] * x[8] - x[5] * x[7]) * n[0] - (x[3] * x[8] - x[5] * x[6]) * n[1] + (x[3] * x[7] - x[4] * x[6]) * n[2]
				var c1 := -(x[1] * x[8] - x[2] * x[7]) * n[0] + (x[0] * x[8] - x[2] * x[6]) * n[1] - (x[0] * x[7] - x[1] * x[6]) * n[2]
				var c2 := (x[1] * x[5] - x[2] * x[4]) * n[0] - (x[0] * x[5] - x[2] * x[3]) * n[1] + (x[0] * x[4] - x[1] * x[3]) * n[2]
				e.normal = unit_d(PackedFloat64Array([c0, c1, c2]))
			else:
				var a := _d3(e.get("axis", PackedFloat64Array([0, 0, 1])))
				var la := PackedFloat64Array([x[0] * a[0] + x[1] * a[1] + x[2] * a[2], x[3] * a[0] + x[4] * a[1] + x[5] * a[2], x[6] * a[0] + x[7] * a[1] + x[8] * a[2]])
				if det < 0.0:
					la = PackedFloat64Array([-la[0], -la[1], -la[2]])
				e.axis = unit_d(la)
			sym.append(e)
		out.symmetry = sym
		if not _is_similarity(x):
			var tol := 1e-9 * maxf(CAGE.diagonal(out), 1e-300)
			for e in sym:
				var exf := _entry_xf(e)
				var m: PackedInt32Array = e.get("map", PackedInt32Array())
				if m.size() != nV:
					continue
				for v in nV:
					var w := m[v]
					if w < 0:
						continue
					var q := xf_apply(exf, p1[3 * v], p1[3 * v + 1], p1[3 * v + 2])
					if absf(q[0] - p1[3 * w]) > tol or absf(q[1] - p1[3 * w + 1]) > tol or absf(q[2] - p1[3 * w + 2]) > tol:
						return {"ok": false, "cage": CAGE.copy(start), "error": BREAKS_SYMMETRY, "moved": PackedInt32Array()}
		return {"ok": true, "cage": out, "error": "", "moved": _changed(p0, p1)}
	var ctx := _sym_ctx(start)
	var iso: PackedByteArray = ctx.iso
	var locked := CAGE.locked_vertices(start)
	var at := PackedInt32Array()
	at.resize(nV)
	at.fill(0x7FFFFFFF)
	for i in order.size():
		var v := order[i]
		if v >= 0 and v < nV and at[v] == 0x7FFFFFFF:
			at[v] = i
	var np := p1.duplicate()
	var done := PackedByteArray()
	done.resize(nV)
	var ranked := rank.size() == nV
	for v in order:
		if v < 0 or v >= nV or done[v] or iso[v]:
			continue
		var full := _orbit_full(ctx, v)
		var orb: Dictionary = full.orbit
		var driver := -1
		var best := -1.0
		# An orbit with a frozen member stays: every member keeps (or takes back) the frozen
		# member's image, as edit_transform leaves such partners out (locked_set).
		var anchor := -1
		for w in orb:
			if locked[w]:
				anchor = w
				break
		for w in orb:
			done[w] = 1
			if anchor >= 0 or at[w] == 0x7FFFFFFF or locked[w]:
				continue
			var r := rank[w] if ranked else 1.0
			if driver < 0 or r > best or (r == best and at[w] < at[driver]):
				driver = w
				best = r
		var rep: PackedFloat64Array
		if anchor >= 0:
			rep = xf_apply(xf_inverse_rigid(orb[anchor]), p0[3 * anchor], p0[3 * anchor + 1], p0[3 * anchor + 2])
		elif driver < 0:
			continue
		else:
			rep = _stab_fix(full.stab, xf_apply(xf_inverse_rigid(orb[driver]), p1[3 * driver], p1[3 * driver + 1], p1[3 * driver + 2]))
		for w in orb:
			if locked[w] or iso[w]:
				continue
			var q := _project_fixed(ctx, w, xf_apply(orb[w], rep[0], rep[1], rep[2]))
			np[3 * w] = q[0]
			np[3 * w + 1] = q[1]
			np[3 * w + 2] = q[2]
	var out := CAGE.copy(moved)
	out.positions = np
	return {"ok": true, "cage": out, "error": "", "moved": _changed(p0, np)}


## True when the 3x3 part of xf scales every direction alike (a rotation, reflection and uniform
## scale): such a transform maps a mirror plane or rotation axis onto one exactly.
static func _is_similarity(x: PackedFloat64Array) -> bool:
	var cols := [[x[0], x[3], x[6]], [x[1], x[4], x[7]], [x[2], x[5], x[8]]]
	var g := []
	var trace := 0.0
	for i in 3:
		var row := []
		for j in 3:
			var d: float = cols[i][0] * cols[j][0] + cols[i][1] * cols[j][1] + cols[i][2] * cols[j][2]
			row.append(d)
		g.append(row)
		trace += float(row[i])
	var s := trace / 3.0
	for i in 3:
		for j in 3:
			var want := s if i == j else 0.0
			if absf(float(g[i][j]) - want) > 1e-12 * maxf(s, 1e-300):
				return false
	return true


## Vertices whose positions differ between two position arrays.
static func _changed(a: PackedFloat64Array, b: PackedFloat64Array) -> PackedInt32Array:
	var out := PackedInt32Array()
	for v in mini(a.size(), b.size()) / 3:
		if a[3 * v] != b[3 * v] or a[3 * v + 1] != b[3 * v + 1] or a[3 * v + 2] != b[3 * v + 2]:
			out.append(v)
	return out


## q put back on the plane of every mirror that maps w to itself and on the axis of every
## circular entry that does.
static func _project_fixed(ctx: Dictionary, w: int, q: PackedFloat64Array) -> PackedFloat64Array:
	for fx in ctx.fixed:
		var m: PackedInt32Array = fx.map
		if m[w] != w:
			continue
		var o: PackedFloat64Array = fx.origin
		var n: PackedFloat64Array = fx.dir
		var d := (q[0] - o[0]) * n[0] + (q[1] - o[1]) * n[1] + (q[2] - o[2]) * n[2]
		if fx.type == "mirror":
			q = PackedFloat64Array([q[0] - d * n[0], q[1] - d * n[1], q[2] - d * n[2]])
		else:
			q = PackedFloat64Array([o[0] + d * n[0], o[1] + d * n[1], o[2] + d * n[2]])
	return q


## A grid of vertex positions for "which vertex is within tol of this point" queries.
class _Grid:
	extends RefCounted
	var cell := 1.0
	var cells := {}
	var p: PackedFloat64Array

	func _init(positions: PackedFloat64Array, tol: float) -> void:
		p = positions
		cell = maxf(4.0 * tol, 1e-300)
		var inv := 1.0 / cell
		for v in p.size() / 3:
			var key := _cell_key(floori(p[3 * v] * inv), floori(p[3 * v + 1] * inv), floori(p[3 * v + 2] * inv))
			var list = cells.get(key)
			if list == null:
				cells[key] = [v]
			else:
				list.append(v)

	## 21 bits per axis; cells that wrap onto one key only add candidates the distance test drops.
	static func _cell_key(ix: int, iy: int, iz: int) -> int:
		return ((ix & 0x1FFFFF) << 42) | ((iy & 0x1FFFFF) << 21) | (iz & 0x1FFFFF)

	## The vertex within tol of (x, y, z) without allocating: the vertex, -1 for none, -2 for
	## several (then near() sorts them).
	func probe(x: float, y: float, z: float, tol: float) -> int:
		var inv := 1.0 / cell
		var t2 := tol * tol
		var found := -1
		for ix in range(floori((x - tol) * inv), floori((x + tol) * inv) + 1):
			for iy in range(floori((y - tol) * inv), floori((y + tol) * inv) + 1):
				for iz in range(floori((z - tol) * inv), floori((z + tol) * inv) + 1):
					var list = cells.get(_cell_key(ix, iy, iz))
					if list == null:
						continue
					for v in list:
						var dx: float = p[3 * v] - x
						var dy: float = p[3 * v + 1] - y
						var dz: float = p[3 * v + 2] - z
						if dx * dx + dy * dy + dz * dz <= t2:
							if found >= 0:
								return -2
							found = v
		return found

	## Vertices within tol of (x, y, z), nearest first.
	func near(x: float, y: float, z: float, tol: float) -> PackedInt32Array:
		var out := PackedInt32Array()
		var dists := []
		var t2 := tol * tol
		var inv := 1.0 / cell
		for ix in range(floori((x - tol) * inv), floori((x + tol) * inv) + 1):
			for iy in range(floori((y - tol) * inv), floori((y + tol) * inv) + 1):
				for iz in range(floori((z - tol) * inv), floori((z + tol) * inv) + 1):
					var list = cells.get(_cell_key(ix, iy, iz))
					if list == null:
						continue
					for v in list:
						var dx := p[3 * v] - x
						var dy := p[3 * v + 1] - y
						var dz := p[3 * v + 2] - z
						var d2 := dx * dx + dy * dy + dz * dz
						if d2 <= t2:
							out.append(v)
							dists.append(d2)
		if out.size() > 1:
			var order := range(out.size())
			order.sort_custom(func(a, b) -> bool: return dists[a] < dists[b])
			var sorted := PackedInt32Array()
			for i in order:
				sorted.append(out[i])
			return sorted
		return out


static func default_tolerance(c: Dictionary) -> float:
	var d := CAGE.diagonal(c)
	return 1e-4 * d if d > 0.0 else 1e-9


## Rebuilds every symmetry map geometrically (after topology edits): each vertex maps to the
## vertex nearest its image, within tolerance (default 1e-4 x the bounds diagonal). Where several
## vertices sit at the image (a fresh extrusion), the one whose faces map onto its faces wins.
## Unpaired vertices get -1 and a warning "Symmetry broken at <n> vertices".
static func rebuild_symmetry(c: Dictionary, tolerance := 0.0) -> Dictionary:
	var out := CAGE.copy(c)
	var sym: Array = out.get("symmetry", [])
	if sym.is_empty():
		return _done(out, {}, PackedStringArray(), {"broken": 0})
	var tol := tolerance if tolerance > 0.0 else default_tolerance(c)
	var p: PackedFloat64Array = c.positions
	var nV := p.size() / 3
	var t2 := tol * tol
	var grid: _Grid = null
	var iso := PackedByteArray()
	iso.resize(nV)
	for v in (c.get("sym_isolated", PackedInt32Array()) as PackedInt32Array):
		if v < nV:
			iso[v] = 1
	var faces_data := {}
	var broken := 0
	# Vertices sharing their position with another (an unwelded seam, a copy not moved yet) can't
	# be told apart by position: their partners are chosen by their neighbourhoods instead, even
	# where an old entry still fits.
	var shared := _coincident_flags(p)
	for entry in sym:
		var xf := _entry_xf(entry)
		# Entries that still fit stay (cheap); only new or moved vertices are searched for.
		var old: PackedInt32Array = entry.get("map", PackedInt32Array())
		var m := PackedInt32Array()
		m.resize(nV)
		var a00 := xf[0]
		var a01 := xf[1]
		var a02 := xf[2]
		var a10 := xf[3]
		var a11 := xf[4]
		var a12 := xf[5]
		var a20 := xf[6]
		var a21 := xf[7]
		var a22 := xf[8]
		var tx := xf[9]
		var ty := xf[10]
		var tz := xf[11]
		for v in nV:
			var x := p[3 * v]
			var y := p[3 * v + 1]
			var z := p[3 * v + 2]
			var qx := a00 * x + a01 * y + a02 * z + tx
			var qy := a10 * x + a11 * y + a12 * z + ty
			var qz := a20 * x + a21 * y + a22 * z + tz
			if v < old.size():
				var w := old[v]
				if w >= 0 and w < nV and not shared[w]:
					var dx := p[3 * w] - qx
					var dy := p[3 * w + 1] - qy
					var dz := p[3 * w + 2] - qz
					if dx * dx + dy * dy + dz * dz <= t2:
						m[v] = w
						continue
			if grid == null:
				grid = _Grid.new(p, tol)
			var one := grid.probe(qx, qy, qz, tol)
			if one >= -1:
				m[v] = one
				continue
			var cands := grid.near(qx, qy, qz, tol)
			if cands.is_empty():
				m[v] = -1
			elif cands.size() == 1:
				m[v] = cands[0]
			else:
				m[v] = _best_candidate(c, faces_data, xf, v, cands, tol)
		entry.map = m
		var open := str(entry.get("type", "")) == "circular" and bool(entry.get("open", false))
		var has_pred := PackedByteArray()
		if open:
			has_pred.resize(nV)
			for v in nV:
				if m[v] >= 0:
					has_pred[m[v]] = 1
		for v in nV:
			if m[v] < 0 and not iso[v] and (not open or not has_pred[v]):
				broken += 1
	out.symmetry = sym
	var warnings := PackedStringArray()
	if broken > 0:
		warnings.append("Symmetry broken at %d vertices" % broken)
	return _done(out, {}, warnings, {"broken": broken})


static func _entry_xf(entry: Dictionary) -> PackedFloat64Array:
	var o := _d3(entry.get("origin", PackedFloat64Array([0, 0, 0])))
	if str(entry.get("type", "")) == "mirror":
		return mirror_xf(o, _d3(entry.get("normal", PackedFloat64Array([1, 0, 0]))))
	var step := float(entry.get("step", TAU / maxi(2, int(entry.get("count", 2)))))
	return rotation_xf(o, _d3(entry.get("axis", PackedFloat64Array([0, 0, 1]))), step)


## 1 for every vertex that shares its exact position with another vertex.
static func _coincident_flags(p: PackedFloat64Array) -> PackedByteArray:
	var nV := p.size() / 3
	var out := PackedByteArray()
	out.resize(nV)
	var first := {}
	for v in nV:
		var key := Vector3(p[3 * v], p[3 * v + 1], p[3 * v + 2])
		var at: int = first.get(key, -1)
		if at < 0:
			first[key] = v
		else:
			out[v] = 1
			out[at] = 1
	return out


## Among coincident candidates, the vertex whose neighbourhood is the image of v's: the same
## valence and v's neighbours mapped onto its neighbours (this tells an unwelded seam's two sides
## apart, and a fresh copy from the rim it was copied from), then the incident face centroids.
static func _best_candidate(c: Dictionary, data: Dictionary, xf: PackedFloat64Array, v: int, cands: PackedInt32Array, tol: float) -> int:
	if not data.has("topo"):
		data.topo = CAGE.topology(c)
	var topo: CAGE.Topo = data.topo
	var p: PackedFloat64Array = c.positions
	var t2 := tol * tol
	var mine := topo.vertex_neighbors(v)
	var images := []
	for w in mine:
		images.append(xf_apply(xf, p[3 * w], p[3 * w + 1], p[3 * w + 2]))
	var best := -1
	var best_score := -1
	var ties := PackedInt32Array()
	for u in cands:
		var theirs := topo.vertex_neighbors(u)
		var used := {}
		var matched := 0
		for q in images:
			for w in theirs:
				if used.has(w):
					continue
				var dx: float = p[3 * w] - q[0]
				var dy: float = p[3 * w + 1] - q[1]
				var dz: float = p[3 * w + 2] - q[2]
				if dx * dx + dy * dy + dz * dz <= t2:
					used[w] = true
					matched += 1
					break
		var score := matched * 2 + (1 if theirs.size() == mine.size() else 0)
		if matched == mine.size() and theirs.size() == mine.size():
			score += 1000
		if score > best_score:
			best_score = score
			best = u
			ties = PackedInt32Array([u])
		elif score == best_score:
			ties.append(u)
	if ties.size() <= 1:
		return best
	return _best_by_faces(c, data, xf, v, ties, tol)


## Among coincident candidates, the vertex whose incident face centroids match v's mapped ones.
static func _best_by_faces(c: Dictionary, data: Dictionary, xf: PackedFloat64Array, v: int, cands: PackedInt32Array, tol: float) -> int:
	if not data.has("topo"):
		data.topo = CAGE.topology(c)
	if not data.has("centroids"):
		var t: CAGE.Topo = data.topo
		var cen := PackedFloat64Array()
		cen.resize(3 * t.nF)
		var p: PackedFloat64Array = c.positions
		for f in t.nF:
			var s := t.face_offsets[f]
			var n := t.face_size(f)
			for h in range(s, s + n):
				var w := t.face_indices[h]
				cen[3 * f] += p[3 * w]
				cen[3 * f + 1] += p[3 * w + 1]
				cen[3 * f + 2] += p[3 * w + 2]
			cen[3 * f] /= n
			cen[3 * f + 1] /= n
			cen[3 * f + 2] /= n
		data.centroids = cen
	var topo: CAGE.Topo = data.topo
	var centroids: PackedFloat64Array = data.centroids
	var mapped := []
	for f in topo.vertex_all_faces(v):
		mapped.append(xf_apply(xf, centroids[3 * f], centroids[3 * f + 1], centroids[3 * f + 2]))
	var best := cands[0]
	var best_score := -1
	var t2 := tol * tol
	for u in cands:
		var score := 0
		var theirs := topo.vertex_all_faces(u)
		for q in mapped:
			for g in theirs:
				var dx: float = centroids[3 * g] - q[0]
				var dy: float = centroids[3 * g + 1] - q[1]
				var dz: float = centroids[3 * g + 2] - q[2]
				if dx * dx + dy * dy + dz * dz <= t2:
					score += 1
					break
		if score > best_score:
			best_score = score
			best = u
	return best


## True when reflecting / rotating every vertex lands within tol of a vertex.
static func _maps_all(p: PackedFloat64Array, grid: _Grid, xf: PackedFloat64Array, tol: float) -> bool:
	for v in p.size() / 3:
		var q := xf_apply(xf, p[3 * v], p[3 * v + 1], p[3 * v + 2])
		if grid.probe(q[0], q[1], q[2], tol) == -1:
			return false
	return true


## Mirror planes that map every vertex within tolerance: [{"origin", "normal", "label"}], best
## first. Tried: the plane between the two hint faces' centroids, the three principal planes
## through the vertex centroid, the world YZ / XZ / XY planes through the bounds centre.
static func detect_mirror(c: Dictionary, hint_faces: PackedInt32Array, tolerance: float) -> Array:
	var tol := tolerance if tolerance > 0.0 else default_tolerance(c)
	var p: PackedFloat64Array = c.positions
	var grid := _Grid.new(p, tol)
	var cands: Array = []
	if hint_faces.size() >= 2:
		var t := CAGE.topology(c)
		var a := CAGE._centroid(p, t.face_verts(hint_faces[0]))
		var b := CAGE._centroid(p, t.face_verts(hint_faces[1]))
		if a.distance_to(b) > 0.0:
			var o := (a + b) * 0.5
			cands.append([_d3(o), unit_d(_d3(b - a)), "Between the picked faces"])
	var pca := _pca(p)
	for k in 3:
		cands.append([pca.centroid, pca.vectors[k], "Principal plane %d" % (k + 1)])
	var box := CAGE.bounds(c)
	var centre := _d3(box.get_center())
	cands.append([centre, PackedFloat64Array([1, 0, 0]), "YZ plane"])
	cands.append([centre, PackedFloat64Array([0, 1, 0]), "XZ plane"])
	cands.append([centre, PackedFloat64Array([0, 0, 1]), "XY plane"])
	var out: Array = []
	for cand in cands:
		var o: PackedFloat64Array = cand[0]
		var n := unit_d(cand[1])
		var dup := false
		for got in out:
			var gn: PackedFloat64Array = got.normal
			var go: PackedFloat64Array = got.origin
			var dot := absf(gn[0] * n[0] + gn[1] * n[1] + gn[2] * n[2])
			var off := absf((o[0] - go[0]) * gn[0] + (o[1] - go[1]) * gn[1] + (o[2] - go[2]) * gn[2])
			if dot > 1.0 - 1e-6 and off <= tol:
				dup = true
				break
		if dup:
			continue
		if _maps_all(p, grid, mirror_xf(o, n), tol):
			out.append({"origin": o, "normal": n, "label": _plane_label(n, cand[2])})
	return out


static func _plane_label(n: PackedFloat64Array, fallback: String) -> String:
	if absf(n[0]) > 1.0 - 1e-9:
		return "YZ plane"
	if absf(n[1]) > 1.0 - 1e-9:
		return "XZ plane"
	if absf(n[2]) > 1.0 - 1e-9:
		return "XY plane"
	return fallback


## Circular symmetries: [{"origin", "axis", "count", "label"}] for every axis tried (the
## principal axis with the most distinct spread through the centroid, then world X, Y, Z through
## the bounds centre) and every count 2..64 whose rotation maps every vertex within tolerance.
## label names the axis ("Z axis").
static func detect_circular(c: Dictionary, _hint_faces: PackedInt32Array, tolerance: float) -> Array:
	var tol := tolerance if tolerance > 0.0 else default_tolerance(c)
	var p: PackedFloat64Array = c.positions
	var grid := _Grid.new(p, tol)
	var pca := _pca(p)
	var vals: Array = pca.values
	var distinct := 0 if absf(vals[1] - vals[0]) > absf(vals[2] - vals[1]) else 2
	var box := CAGE.bounds(c)
	var centre := _d3(box.get_center())
	var axes: Array = [[pca.centroid, pca.vectors[distinct], "Principal axis"], [centre, PackedFloat64Array([1, 0, 0]), "X axis"], [centre, PackedFloat64Array([0, 1, 0]), "Y axis"], [centre, PackedFloat64Array([0, 0, 1]), "Z axis"]]
	var tried: Array = []
	var out: Array = []
	for ax in axes:
		var o: PackedFloat64Array = ax[0]
		var a := unit_d(ax[1])
		var label: String = ax[2]
		var dup := false
		for got in tried:
			var ga: PackedFloat64Array = got[1]
			var go: PackedFloat64Array = got[0]
			if absf(ga[0] * a[0] + ga[1] * a[1] + ga[2] * a[2]) > 1.0 - 1e-6:
				# Same line when o lies on the other axis.
				var dx := o[0] - go[0]
				var dy := o[1] - go[1]
				var dz := o[2] - go[2]
				var along := dx * ga[0] + dy * ga[1] + dz * ga[2]
				var off := sqrt(maxf(0.0, dx * dx + dy * dy + dz * dz - along * along))
				if off <= tol:
					dup = true
					break
		if dup:
			continue
		tried.append([o, a])
		if label == "Principal axis":
			label = _axis_label(a, label)
		for n in range(2, 65):
			if _maps_all(p, grid, rotation_xf(o, a, TAU / n), tol):
				out.append({"origin": o, "axis": a, "count": n, "label": label})
	return out


static func _axis_label(a: PackedFloat64Array, fallback: String) -> String:
	if absf(a[0]) > 1.0 - 1e-9:
		return "X axis"
	if absf(a[1]) > 1.0 - 1e-9:
		return "Y axis"
	if absf(a[2]) > 1.0 - 1e-9:
		return "Z axis"
	return fallback


## Makes a nearly symmetric cage exactly symmetric under entry (partners averaged; locked
## vertices stay), appends the entry and builds every map.
static func symmetrize(c: Dictionary, entry: Dictionary, tolerance: float) -> Dictionary:
	var tol := tolerance if tolerance > 0.0 else default_tolerance(c)
	var e := entry.duplicate(true)
	e.map = PackedInt32Array()
	var solo := CAGE.copy(c)
	solo.symmetry = [e]
	solo.sym_isolated = PackedInt32Array()
	solo = rebuild_symmetry(solo, tol).cage
	var all := PackedInt32Array()
	for v in CAGE.vertex_count(c):
		all.append(v)
	var snapped: Dictionary = apply_symmetry(solo, all).cage
	var out := CAGE.copy(c)
	out.positions = snapped.positions
	var sym: Array = out.symmetry
	sym.append(e)
	out.symmetry = sym
	var r := rebuild_symmetry(out, tol)
	return r


# ---------------------------------------------------------------------------------------------
# Result and selection helpers
# ---------------------------------------------------------------------------------------------

static func _list(sel: Dictionary, key: String) -> PackedInt32Array:
	var v = sel.get(key, PackedInt32Array())
	if v is PackedInt32Array:
		return v
	return PackedInt32Array(v)


static func _sel(verts := PackedInt32Array(), pairs := PackedInt32Array(), faces := PackedInt32Array()) -> Dictionary:
	return {"vertices": verts, "edges": pairs, "faces": faces}


## The success result; in debug builds a result that breaks a cage invariant is refused.
static func _done(cage: Dictionary, selection: Dictionary, warnings: PackedStringArray, info := {}) -> Dictionary:
	return {"ok": true, "cage": cage, "selection": selection if not selection.is_empty() else _sel(), "warnings": warnings, "error": "", "info": info}


static func _ok(c_in: Dictionary, cage: Dictionary, selection: Dictionary, warnings := PackedStringArray(), info := {}) -> Dictionary:
	if OS.is_debug_build():
		var problems := CAGE.validate(cage)
		if not problems.is_empty():
			return _err(c_in, "That edit would break the cage (%s)." % problems[0], info)
	return _done(cage, selection, warnings, info)


static func _err(c_in: Dictionary, message: String, info := {}) -> Dictionary:
	return {"ok": false, "cage": CAGE.copy(c_in), "selection": _sel(), "warnings": PackedStringArray(), "error": message, "info": info}


## Every vertex the selection touches (sorted, unique); the whole cage for a body selection.
static func _sel_vertices(c: Dictionary, sel: Dictionary, whole_when_empty := false) -> PackedInt32Array:
	var nV := CAGE.vertex_count(c)
	var verts := _list(sel, "vertices")
	var pairs := _list(sel, "edges")
	var faces := _list(sel, "faces")
	if bool(sel.get("body", false)) or (whole_when_empty and verts.is_empty() and pairs.is_empty() and faces.is_empty()):
		var all := PackedInt32Array()
		for v in nV:
			all.append(v)
		return all
	var mark := PackedByteArray()
	mark.resize(nV)
	for v in verts:
		if v >= 0 and v < nV:
			mark[v] = 1
	for v in pairs:
		if v >= 0 and v < nV:
			mark[v] = 1
	if not faces.is_empty():
		var offs := CAGE.face_offsets(c)
		var idx: PackedInt32Array = c.face_indices
		for f in faces:
			if f < 0 or f >= offs.size() - 1:
				continue
			for h in range(offs[f], offs[f + 1]):
				mark[idx[h]] = 1
	var out := PackedInt32Array()
	for v in nV:
		if mark[v]:
			out.append(v)
	return out


static func _has_symmetry(c: Dictionary) -> bool:
	return not (c.get("symmetry", []) as Array).is_empty()


## After a topology edit: rebuild the maps, then make the new vertices exactly symmetric.
static func _resym(cage: Dictionary, new_vertices: PackedInt32Array, warnings: PackedStringArray) -> Dictionary:
	if not _has_symmetry(cage):
		return cage
	var r := rebuild_symmetry(cage, 0.0)
	warnings.append_array(r.warnings)
	if new_vertices.is_empty():
		return r.cage
	return apply_symmetry(r.cage, new_vertices).cage


static func _any_locked(locked: PackedByteArray, verts: PackedInt32Array) -> bool:
	for v in verts:
		if v >= 0 and v < locked.size() and locked[v]:
			return true
	return false


static func _faces_locked(topo: CAGE.Topo, locked: PackedByteArray, faces) -> bool:
	for f in faces:
		if f < 0 or f >= topo.nF:
			continue
		for h in range(topo.face_offsets[f], topo.face_offsets[f + 1]):
			if locked[topo.face_indices[h]]:
				return true
	return false


static func _pairs_to_edges(topo: CAGE.Topo, pairs: PackedInt32Array) -> PackedInt32Array:
	var out := PackedInt32Array()
	for i in pairs.size() / 2:
		out.append(topo.edge_index(pairs[2 * i], pairs[2 * i + 1]))
	return out


static func _edges_to_pairs(topo: CAGE.Topo, list: PackedInt32Array) -> PackedInt32Array:
	var out := PackedInt32Array()
	for e in list:
		out.append(topo.edges[2 * e])
		out.append(topo.edges[2 * e + 1])
	return out


## The Insert Edge side rule: selected edges grouped into connected chains; each chain starts at
## its edge with the smallest (min, max) pair, oriented a -> b as its half-edge in that edge's
## lower-index face, and the direction is carried along the chain. The side face of an oriented
## edge x -> y is the face holding half-edge x -> y (y -> x when negative). Returns
## {"items": [{"edge": Vector2i(x, y), "side": face}], "skipped": n, "error"}.
static func side_items(topo: CAGE.Topo, pairs: PackedInt32Array, negative: bool) -> Dictionary:
	var list := PackedInt32Array()
	for i in pairs.size() / 2:
		var e := topo.edge_index(pairs[2 * i], pairs[2 * i + 1])
		if e < 0:
			return {"items": [], "skipped": 0, "error": "%d-%d is not an edge." % [pairs[2 * i], pairs[2 * i + 1]]}
		if not list.has(e):
			list.append(e)
	var at := {}
	for e in list:
		for v in [topo.edges[2 * e], topo.edges[2 * e + 1]]:
			if not at.has(v):
				at[v] = []
			(at[v] as Array).append(e)
	var orient := {}
	var items: Array = []
	var skipped := 0
	var done := {}
	for e0 in list:
		if done.has(e0):
			continue
		# The chain's edges.
		var comp := [e0]
		done[e0] = true
		var qi := 0
		while qi < comp.size():
			var e: int = comp[qi]
			qi += 1
			for v in [topo.edges[2 * e], topo.edges[2 * e + 1]]:
				for x in at[v]:
					if not done.has(x):
						done[x] = true
						comp.append(x)
		var start: int = comp[0]
		for e in comp:
			var a := topo.edges[2 * e]
			var b := topo.edges[2 * e + 1]
			var sa := topo.edges[2 * start]
			var sb := topo.edges[2 * start + 1]
			if a < sa or (a == sa and b < sb):
				start = e
		var faces := topo.edge_faces(start)
		var low := faces[0]
		for f in faces:
			low = mini(low, f)
		var h := topo.edge_he[start]
		if topo.he_face[h] != low:
			h = topo.edge_he2[start]
		orient[start] = Vector2i(topo.face_indices[h], topo.he_dest(h))
		var queue := [start]
		qi = 0
		while qi < queue.size():
			var e: int = queue[qi]
			qi += 1
			var o: Vector2i = orient[e]
			for x in at[o.y]:
				if not orient.has(x):
					orient[x] = Vector2i(o.y, topo._other(x, o.y))
					queue.append(x)
			for x in at[o.x]:
				if not orient.has(x):
					orient[x] = Vector2i(topo._other(x, o.x), o.x)
					queue.append(x)
		for e in comp:
			var o: Vector2i = orient[e]
			var hh := topo.half_edge(o.y, o.x) if negative else topo.half_edge(o.x, o.y)
			if hh < 0:
				skipped += 1
				continue
			items.append({"edge": o, "side": topo.he_face[hh]})
	return {"items": items, "skipped": skipped, "error": ""}


## items plus their symmetry images (the side face maps with its edge, so mirrored sides stay
## mirrored).
static func _sym_items(c: Dictionary, topo: CAGE.Topo, items: Array, warnings: PackedStringArray) -> Array:
	var ctx := _sym_ctx(c)
	if (ctx.maps as Array).is_empty():
		return items
	var out: Array = []
	var seen := {}
	var broken := false
	for item in items:
		var ev: Vector2i = item.edge
		var f: int = item.side
		var tuple := PackedInt32Array([ev.x, ev.y])
		tuple.append_array(topo.face_verts(f))
		var r := _images(ctx, tuple)
		broken = broken or r.broken
		for img in r.images:
			var e := topo.edge_index(img[0], img[1])
			var g := topo.face_by_vertices(img.slice(2))
			if e < 0 or g < 0:
				broken = true
				continue
			var key := "%d:%d" % [e, g]
			if seen.has(key):
				continue
			seen[key] = true
			out.append({"edge": Vector2i(img[0], img[1]), "side": g})
	if broken:
		warnings.append(BROKEN_PARTNERS)
	return out


## Insert items at the half-way location whose edges are opposite edges of one quad side face (a
## face its own symmetry partner, or a picked ring) would put two loops on the same rail points:
## one of them is enough, and it lies on the symmetry plane.
static func _merge_coincident_items(topo: CAGE.Topo, items: Array, both: bool) -> Array:
	var out: Array = []
	var by_face := {}
	for item in items:
		var f: int = item.side
		var ev: Vector2i = item.edge
		var sides := PackedInt32Array([f])
		if both:
			var e := topo.edge_index(ev.x, ev.y)
			if e >= 0:
				sides = topo.edge_faces(e)
		var duplicate := false
		for g in sides:
			if topo.face_size(g) != 4 or not by_face.has(g):
				continue
			for other in by_face[g]:
				var ov: Vector2i = other
				var gv := topo.face_verts(g)
				var shares := gv.has(ev.x) and gv.has(ev.y) and gv.has(ov.x) and gv.has(ov.y)
				if shares and not (ov.x == ev.x or ov.x == ev.y or ov.y == ev.x or ov.y == ev.y):
					duplicate = true
		if duplicate:
			continue
		out.append(item)
		for g in sides:
			if not by_face.has(g):
				by_face[g] = []
			(by_face[g] as Array).append(ev)
	return out


## Faces touched by inserting on items: the side faces and the faces of their rails.
static func _insert_faces(topo: CAGE.Topo, items: Array, both: bool) -> PackedInt32Array:
	var out := PackedInt32Array()
	for item in items:
		var ev: Vector2i = item.edge
		var sides := PackedInt32Array([int(item.side)])
		if both:
			var e := topo.edge_index(ev.x, ev.y)
			if e >= 0:
				sides = topo.edge_faces(e)
		for f in sides:
			out.append(f)
			var s := topo.face_offsets[f]
			var n := topo.face_size(f)
			for k in n:
				var x := topo.face_indices[s + k]
				var y := topo.face_indices[s + (k + 1) % n]
				if (x == ev.x and y == ev.y) or (x == ev.y and y == ev.x):
					var pa := topo.face_indices[s + (k - 1 + n) % n]
					var pb := topo.face_indices[s + (k + 2) % n]
					for e2 in [topo.edge_index(x, pa), topo.edge_index(y, pb)]:
						if e2 >= 0:
							out.append_array(topo.edge_faces(e2))
	return out


# ---------------------------------------------------------------------------------------------
# Modify tools
# ---------------------------------------------------------------------------------------------

## Edit Form's move: transforms the selected vertices (a body selection moves all of them).
## opts: "xf" (12 doubles) or "translate" (Vector3); "pivot" (Vector3 / 3 doubles; default the
## selection centroid) about which xf applies; "pivots" (3 doubles per vertex, Local Per Entity);
## "weights" (one per cage vertex) or "soft" (soft_weights options) for soft modification.
## Locked vertices stay; partners follow exactly.
static func edit_transform(c: Dictionary, sel: Dictionary, opts: Dictionary) -> Dictionary:
	var verts := _sel_vertices_ordered(c, sel)
	if verts.is_empty():
		return _err(c, "Select cage faces, edges or vertices to edit.")
	var locked := locked_set(c)
	var symmetric := _has_symmetry(c)
	if symmetric and bool(sel.get("body", false)):
		# A whole symmetric body moves with its planes and axes; frozen faces would hold part
		# of it back, and the rest would then move mirrored (two halves going opposite ways).
		for v in locked.size():
			if locked[v]:
				return _err(c, SYMMETRIC_FROZEN_BODY)
	var free := PackedInt32Array()
	var held := 0
	var frozen_self := CAGE.locked_vertices(c) if symmetric else locked
	for v in verts:
		if not locked[v]:
			free.append(v)
		elif not frozen_self[v]:
			held += 1
	if free.is_empty():
		return _err(c, "Those vertices are frozen." if held == 0 else FROZEN_PARTNERS)
	var hold_warnings := PackedStringArray()
	if held > 0:
		hold_warnings.append("%d selected vertices stay where they are: their symmetry partners are frozen." % held)
	var nV := CAGE.vertex_count(c)
	var xf := xf_identity()
	if opts.has("xf"):
		xf = PackedFloat64Array(opts.xf)
	elif opts.has("translate"):
		var tr := _d3(opts.translate)
		xf = xf_translation(tr[0], tr[1], tr[2])
	var pivots := PackedFloat64Array(opts.get("pivots", PackedFloat64Array()))
	if pivots.is_empty() and opts.has("xf"):
		var pv: PackedFloat64Array
		if opts.has("pivot"):
			pv = _d3(opts.pivot)
		else:
			pv = PackedFloat64Array([0.0, 0.0, 0.0])
			var p: PackedFloat64Array = c.positions
			for v in free:
				pv[0] += p[3 * v]
				pv[1] += p[3 * v + 1]
				pv[2] += p[3 * v + 2]
			pv[0] /= free.size()
			pv[1] /= free.size()
			pv[2] /= free.size()
		xf = xf_about(xf, pv[0], pv[1], pv[2])
	var list := free
	var weights := PackedFloat32Array()
	var rank := PackedFloat32Array()
	if opts.has("weights") or opts.has("soft"):
		var per_vertex := PackedFloat32Array(opts.weights) if opts.has("weights") else soft_weights(c, null, free, opts.soft)
		# The selection first (it drives its symmetry orbits), then the soft field.
		list = free.duplicate()
		var listed := PackedByteArray()
		listed.resize(nV)
		for v in free:
			listed[v] = 1
		for v in per_vertex.size():
			if per_vertex[v] > 0.0 and not locked[v] and not listed[v]:
				list.append(v)
		for v in list:
			weights.append(per_vertex[v] if v < per_vertex.size() else 1.0)
		rank = per_vertex
		for v in free:
			if v < rank.size():
				rank[v] = maxf(rank[v], 1.0)
	var use_pivots := pivots.size() == 3 * list.size()
	var r := transform_vertices(c, list, weights, xf, pivots if use_pivots else PackedFloat64Array())
	var out: Dictionary = r.cage
	var moved: PackedInt32Array = r.info.moved
	if _has_symmetry(out):
		# One transform moving every vertex alike carries the symmetry with the body.
		var whole := not use_pivots and list.size() == nV
		for w in weights:
			whole = whole and w == 1.0
		var s := carry_symmetry(c, out, list, rank, xf if whole else PackedFloat64Array())
		if not s.ok:
			return _err(c, str(s.error))
		out = s.cage
		moved = s.moved
	return _ok(c, out, sel, hold_warnings, {"moved": moved})


## Every vertex the selection touches, unique, in selection order (vertices, then edge ends,
## then face corners); the whole cage for a body selection.
static func _sel_vertices_ordered(c: Dictionary, sel: Dictionary) -> PackedInt32Array:
	var nV := CAGE.vertex_count(c)
	if bool(sel.get("body", false)):
		return _range(nV)
	var seq := PackedInt32Array()
	seq.append_array(_list(sel, "vertices"))
	seq.append_array(_list(sel, "edges"))
	var faces := _list(sel, "faces")
	if not faces.is_empty():
		var offs := CAGE.face_offsets(c)
		var idx: PackedInt32Array = c.face_indices
		for f in faces:
			if f >= 0 and f < offs.size() - 1:
				seq.append_array(idx.slice(offs[f], offs[f + 1]))
	var out := PackedInt32Array()
	var mark := PackedByteArray()
	mark.resize(nV)
	for v in seq:
		if v >= 0 and v < nV and not mark[v]:
			mark[v] = 1
			out.append(v)
	return out


## Alt-drag on faces: extrudes them (partners too). opts: "keep_creases" (Alt+Ctrl), "distance"
## (meters along the region's vertex normals; 0 leaves the copy in place for the caller to move).
## selection.faces = the moved region.
static func extrude_region(c: Dictionary, sel: Dictionary, opts: Dictionary) -> Dictionary:
	var faces := _list(sel, "faces")
	if faces.is_empty():
		return _err(c, "Pick faces to extrude.")
	var warnings := PackedStringArray()
	var topo := CAGE.topology(c)
	if _has_symmetry(c):
		var ps := _partners(c, _sel(PackedInt32Array(), PackedInt32Array(), faces), topo)
		faces = ps.faces
		warnings.append_array(ps.warnings)
	var locked := locked_set(c)
	if _faces_locked(topo, locked, faces):
		return _err(c, CAGE.FROZEN_ERROR)
	var r := CAGE.extrude_faces(c, faces, bool(opts.get("keep_creases", false)), topo)
	if r.error != "":
		return _err(c, r.error)
	var out: Dictionary = r.cage
	var region := _sel_vertices(out, _sel(PackedInt32Array(), PackedInt32Array(), faces))
	var dist := float(opts.get("distance", 0.0))
	if dist != 0.0:
		out = _move_along_normals(out, faces, region, dist)
	out = _resym(out, region, warnings)
	return _ok(c, out, _sel(PackedInt32Array(), r.new_edges, faces), warnings, {"new_vertices": r.new_vertices})


## Moves verts by dist along the mean normal of the listed faces around each.
static func _move_along_normals(c: Dictionary, faces: PackedInt32Array, verts: PackedInt32Array, dist: float) -> Dictionary:
	var t := CAGE.topology(c)
	var nV := t.nV
	var acc := PackedFloat64Array()
	acc.resize(3 * nV)
	for f in faces:
		var n := t.face_area_vector(c, f).normalized()
		for h in range(t.face_offsets[f], t.face_offsets[f + 1]):
			var v := t.face_indices[h]
			acc[3 * v] += n.x
			acc[3 * v + 1] += n.y
			acc[3 * v + 2] += n.z
	var out := CAGE.copy(c)
	var p: PackedFloat64Array = out.positions
	for v in verts:
		var l := sqrt(acc[3 * v] * acc[3 * v] + acc[3 * v + 1] * acc[3 * v + 1] + acc[3 * v + 2] * acc[3 * v + 2])
		if l == 0.0:
			continue
		for d in 3:
			p[3 * v + d] += acc[3 * v + d] / l * dist
	out.positions = p
	return out


## Alt-drag on open boundary edges: extends them by one row of quads (partners too). opts:
## "keep_creases", "distance" (meters outward in the surface; 0 leaves the copy in place).
## selection.edges = the new outer chain.
static func extend_edges(c: Dictionary, sel: Dictionary, opts: Dictionary) -> Dictionary:
	var pairs := _list(sel, "edges")
	if pairs.is_empty():
		return _err(c, "Pick open boundary edges to extend.")
	var warnings := PackedStringArray()
	if _has_symmetry(c):
		var ps := partner_selection(c, _sel(PackedInt32Array(), pairs))
		pairs = ps.edges
		warnings.append_array(ps.warnings)
	var topo := CAGE.topology(c)
	for i in pairs.size() / 2:
		var e := topo.edge_index(pairs[2 * i], pairs[2 * i + 1])
		if e < 0 or topo.edge_uses[e] != 1:
			return _err(c, "Only open boundary edges can be extended.")
	var locked := locked_set(c)
	if _any_locked(locked, pairs):
		return _err(c, CAGE.FROZEN_ERROR)
	var r := CAGE.extend_boundary(c, pairs, bool(opts.get("keep_creases", false)))
	if r.error != "":
		return _err(c, r.error)
	var out: Dictionary = r.cage
	var dist := float(opts.get("distance", 0.0))
	if dist != 0.0:
		var p: PackedFloat64Array = out.positions
		var acc := {}
		var dup: PackedInt32Array = r.dup
		for i in pairs.size() / 2:
			var e := topo.edge_index(pairs[2 * i], pairs[2 * i + 1])
			var h := topo.edge_he[e]
			var a := topo.face_indices[h]
			var b := topo.he_dest(h)
			var fn := topo.face_normal(c, topo.he_face[h])
			var d := (CAGE.position(c, b) - CAGE.position(c, a)).cross(fn).normalized()
			for v in [a, b]:
				acc[v] = (acc.get(v, Vector3.ZERO) as Vector3) + d
		for v in acc:
			var d: Vector3 = (acc[v] as Vector3).normalized() * dist
			var w := dup[v]
			p[3 * w] += d.x
			p[3 * w + 1] += d.y
			p[3 * w + 2] += d.z
		out.positions = p
	out = _resym(out, r.new_vertices, warnings)
	return _ok(c, out, _sel(PackedInt32Array(), r.new_edges), warnings, {"new_vertices": r.new_vertices})


## Insert Edge (Simple). opts: "location" -1..1 (0.5; negative = the other side), "side"
## "single" | "both", "mode" "simple" (Exact is in form_fit). selection.edges = the new edges.
static func insert_edge(c: Dictionary, sel: Dictionary, opts: Dictionary) -> Dictionary:
	var pairs := _list(sel, "edges")
	if pairs.is_empty():
		return _err(c, "Pick edges to insert next to.")
	if str(opts.get("mode", "simple")).to_lower() == "exact":
		return _err(c, "Exact inserts need the Holo Forge kernel.")
	var t := float(opts.get("location", 0.5))
	if absf(t) <= 0.0 or absf(t) >= 1.0:
		return _err(c, "The insert location must be between -1 and 1, and not 0.")
	var both := str(opts.get("side", "single")).to_lower() == "both"
	var topo := CAGE.topology(c)
	var warnings := PackedStringArray()
	var si := side_items(topo, pairs, t < 0.0)
	if si.error != "":
		return _err(c, si.error)
	if int(si.skipped) > 0:
		warnings.append("%d edges have no face on that side and were skipped" % si.skipped)
	var items: Array = si.items
	if items.is_empty():
		return _err(c, "None of those edges has a face on that side.")
	items = _sym_items(c, topo, items, warnings)
	if absf(absf(t) - 0.5) < 1e-12 and not both:
		items = _merge_coincident_items(topo, items, false)
	var locked := locked_set(c)
	if _faces_locked(topo, locked, _insert_faces(topo, items, both)):
		return _err(c, CAGE.FROZEN_ERROR)
	var r := CAGE.insert_edge_loop(c, items, absf(t), both, {"topo": topo})
	if r.error != "":
		return _err(c, r.error)
	var out := _resym(r.cage, r.new_vertices, warnings)
	return _ok(c, out, _sel(PackedInt32Array(), r.new_edges), warnings, {"new_vertices": r.new_vertices})


## Subdivide (Simple; Exact for whole components at 2 x 2). opts: "u_faces" / "v_faces"
## (2 / 2; quads), "mode" "simple" | "exact". selection.faces = the new faces.
static func subdivide(c: Dictionary, sel: Dictionary, opts: Dictionary) -> Dictionary:
	var faces := _list(sel, "faces")
	if faces.is_empty():
		return _err(c, "Pick faces to subdivide.")
	var nu := int(opts.get("u_faces", opts.get("nu", 2)))
	var nv := int(opts.get("v_faces", opts.get("nv", 2)))
	var warnings := PackedStringArray()
	var topo := CAGE.topology(c)
	var counts := {}
	if _has_symmetry(c):
		var ps := _partners(c, _sel(PackedInt32Array(), PackedInt32Array(), faces), topo)
		if nu != nv:
			counts = _partner_counts(c, topo, faces, nu, nv)
		faces = ps.faces
		warnings.append_array(ps.warnings)
	var locked := locked_set(c)
	var touched := faces.duplicate()
	for f in faces:
		touched.append_array(topo.face_neighbors(f))
	if _faces_locked(topo, locked, touched):
		return _err(c, CAGE.FROZEN_ERROR)
	var r: Dictionary
	if str(opts.get("mode", "simple")).to_lower() == "exact":
		if nu != 2 or nv != 2 or not _whole_components(topo, faces):
			return _err(c, "Exact subdivision of part of a body needs the Holo Forge kernel.")
		r = CAGE.catmull_clark_step(c, faces)
	else:
		r = CAGE.subdivide_faces(c, faces, nu, nv, topo, counts)
	if r.error != "":
		return _err(c, r.error)
	var out := _resym(r.cage, r.new_vertices, warnings)
	return _ok(c, out, _sel(PackedInt32Array(), PackedInt32Array(), r.new_faces), warnings, {"new_vertices": r.new_vertices})


## Per-face (nu, nv) for the symmetry partners of the picked quads: a partner's corner order can
## run the other way (a mirror reverses it), so it takes the counts along the image of the picked
## face's corner 0 -> 1 edge, not its own.
static func _partner_counts(c: Dictionary, topo: CAGE.Topo, faces: PackedInt32Array, nu: int, nv: int) -> Dictionary:
	var out := {}
	var ctx := _sym_ctx(c)
	for f in faces:
		if f < 0 or f >= topo.nF or topo.face_size(f) != 4:
			continue
		out[f] = Vector2i(nu, nv)
		var r := _images(ctx, topo.face_verts(f))
		for img in r.images:
			var g := topo.face_by_vertices(img)
			if g < 0 or g == f or topo.face_size(g) != 4 or out.has(g):
				continue
			var gv := topo.face_verts(g)
			var k := gv.find(img[0])
			var along_u := true
			if k >= 0:
				# The image of corner 0 -> 1 is g's edge k (forward) or k - 1 (backward).
				var forward: bool = gv[(k + 1) % 4] == int(img[1])
				var edge_slot := k if forward else (k + 3) % 4
				along_u = edge_slot % 2 == 0
			out[g] = Vector2i(nu, nv) if along_u else Vector2i(nv, nu)
	return out


static func _whole_components(topo: CAGE.Topo, faces: PackedInt32Array) -> bool:
	var comps := topo.components()
	var listed := PackedByteArray()
	listed.resize(topo.nF)
	var want := {}
	for f in faces:
		listed[f] = 1
		want[comps[f]] = true
	for f in topo.nF:
		if want.has(comps[f]) and not listed[f]:
			return false
	return true


## Insert Point (Simple): opts.points, in click order, each {"edge": Vector2i(a, b), "t": float}
## (a new vertex at t from a) or {"vertex": v}. A point sharing a face with the previous one is
## joined to it by a new edge; one that doesn't starts a new chain (with a warning).
static func insert_point(c: Dictionary, _sel_in: Dictionary, opts: Dictionary) -> Dictionary:
	var points: Array = opts.get("points", [])
	if points.is_empty():
		return _err(c, "Click points on cage edges.")
	var warnings := PackedStringArray()
	var chains: Array = [points]
	var topo := CAGE.topology(c)
	var locked := locked_set(c)
	for pt in points:
		var faces := PackedInt32Array()
		if pt.has("edge"):
			var ev: Vector2i = pt.edge
			var e := topo.edge_index(ev.x, ev.y)
			if e < 0:
				return _err(c, "%d-%d is not an edge." % [ev.x, ev.y])
			faces = topo.edge_faces(e)
		elif pt.has("vertex"):
			faces = topo.vertex_all_faces(int(pt.vertex))
		if _faces_locked(topo, locked, faces):
			return _err(c, CAGE.FROZEN_ERROR)
	if _has_symmetry(c):
		var ctx := _sym_ctx(c)
		# Each image of the whole click sequence is one more chain.
		var tuple := PackedInt32Array()
		for pt in points:
			if pt.has("edge"):
				tuple.append(pt.edge.x)
				tuple.append(pt.edge.y)
			else:
				tuple.append(int(pt.vertex))
				tuple.append(int(pt.vertex))
		var r := _images(ctx, tuple)
		if r.broken:
			warnings.append(BROKEN_PARTNERS)
		for k in range(1, (r.images as Array).size()):
			var img: PackedInt32Array = r.images[k]
			var chain: Array = []
			for i in points.size():
				var pt: Dictionary = points[i]
				if pt.has("edge"):
					chain.append({"edge": Vector2i(img[2 * i], img[2 * i + 1]), "t": float(pt.get("t", 0.5))})
				else:
					chain.append({"vertex": img[2 * i]})
			chains.append(chain)
	var out := CAGE.copy(c)
	var new_vertices := PackedInt32Array()
	var new_edges := PackedInt32Array()
	var made := {}
	var cut_points := {}
	for chain in chains:
		var prev := -1
		for pt in chain:
			var v := -1
			if pt.has("vertex"):
				v = int(pt.vertex)
			else:
				var ev: Vector2i = pt.edge
				var t := float(pt.get("t", 0.5))
				if t <= 0.0:
					v = ev.x
				elif t >= 1.0:
					v = ev.y
				else:
					var key := "%d:%d:%s" % [mini(ev.x, ev.y), maxi(ev.x, ev.y), str(t if ev.x < ev.y else 1.0 - t)]
					if made.has(key):
						v = made[key]
					else:
						# A second point on an edge already cut (a mirror partner on an edge that
						# crosses the plane, at t != 0.5) goes on the piece of it that holds it.
						var lo := mini(ev.x, ev.y)
						var hi := maxi(ev.x, ev.y)
						var at := t if ev.x < ev.y else 1.0 - t
						var edge_key := "%d:%d" % [lo, hi]
						var cuts: Array = cut_points.get(edge_key, [[0.0, lo], [1.0, hi]])
						var piece := 0
						while piece < cuts.size() - 2 and float(cuts[piece + 1][0]) < at:
							piece += 1
						var s0 := float(cuts[piece][0])
						var s1 := float(cuts[piece + 1][0])
						var r := CAGE.split_edge(out, int(cuts[piece][1]), int(cuts[piece + 1][1]), (at - s0) / (s1 - s0))
						if r.error != "":
							warnings.append("A point could not be placed on that edge (%s)" % str(r.error).trim_suffix("."))
							prev = -1
							continue
						out = r.cage
						v = r.new_vertices[0]
						made[key] = v
						cuts.insert(piece + 1, [at, v])
						cut_points[edge_key] = cuts
						new_vertices.append(v)
			if prev >= 0 and prev != v:
				var t2 := CAGE.topology(out)
				if t2.edge_index(prev, v) < 0:
					var f := _shared_face(t2, prev, v)
					if f < 0:
						warnings.append("Points must share a face")
					else:
						var r2 := CAGE.split_face(out, f, prev, v)
						if r2.error == "":
							out = r2.cage
							new_edges.append(mini(prev, v))
							new_edges.append(maxi(prev, v))
			prev = v
	out = _resym(out, new_vertices, warnings)
	return _ok(c, out, _sel(new_vertices, new_edges), warnings, {"new_vertices": new_vertices})


static func _shared_face(t: CAGE.Topo, a: int, b: int) -> int:
	for f in t.vertex_all_faces(a):
		var s := t.face_offsets[f]
		var n := t.face_size(f)
		for k in n:
			if t.face_indices[s + k] == b:
				return f
	return -1


## Fill Hole: sel.edges holds one boundary edge of the hole. opts: "mode" "reduced" | "star" |
## "collapse" ("Reduced Star" / "Fill Star" / "Collapse" accepted), "keep_creases" (true; false
## clears the rim's creases). Partner holes are filled too.
static func fill_hole(c: Dictionary, sel: Dictionary, opts: Dictionary) -> Dictionary:
	var pairs := _list(sel, "edges")
	if pairs.size() < 2:
		return _err(c, "Pick an edge of the hole to fill.")
	var mode := _fill_mode(str(opts.get("mode", "reduced")))
	var warnings := PackedStringArray()
	var sides := PackedInt32Array([pairs[0], pairs[1]])
	if _has_symmetry(c):
		var ps := partner_selection(c, _sel(PackedInt32Array(), sides))
		sides = ps.edges
		warnings.append_array(ps.warnings)
	var topo := CAGE.topology(c)
	var loops: Array = []
	var seen := {}
	for i in sides.size() / 2:
		var e := topo.edge_index(sides[2 * i], sides[2 * i + 1])
		if e < 0 or topo.edge_uses[e] != 1:
			if i == 0:
				return _err(c, "Pick an open boundary edge: it selects the hole around it.")
			continue
		var loop := topo.boundary_loop_of_edge(e)
		var key := str(CAGE.sorted_unique(loop))
		if seen.has(key):
			continue
		seen[key] = true
		loops.append(loop)
	var locked := locked_set(c)
	for loop in loops:
		if _any_locked(locked, loop):
			return _err(c, CAGE.FROZEN_ERROR)
	var out := CAGE.copy(c)
	var new_vertices := PackedInt32Array()
	var new_faces := PackedInt32Array()
	for loop in loops:
		var r := CAGE.fill_hole(out, loop, mode)
		if r.error != "":
			return _err(c, r.error)
		out = r.cage
		new_vertices.append_array(r.new_vertices)
		new_faces.append_array(r.new_faces)
		if not bool(opts.get("keep_creases", true)):
			var n := (loop as PackedInt32Array).size()
			for k in n:
				CAGE.set_crease(out, loop[k], loop[(k + 1) % n], 0.0)
	out = _resym(out, new_vertices, warnings)
	# A Reduced Star grid can't follow every symmetry of its hole (a hole that is n-fold
	# circular): its faces would have no partners and later edits would break. A pole fill is
	# symmetric whatever the hole.
	if mode == "reduced" and _faces_lacking_partners(out, new_faces) > 0:
		var alt_opts := opts.duplicate()
		alt_opts["mode"] = "collapse"
		var alt := fill_hole(c, sel, alt_opts)
		if alt.ok:
			var aw: PackedStringArray = alt.warnings
			aw.append(REDUCED_NOT_SYMMETRIC % "a pole (Collapse)")
			alt.warnings = aw
			return alt
	return _ok(c, out, _sel(PackedInt32Array(), PackedInt32Array(), new_faces), warnings, {"new_vertices": new_vertices})


const REDUCED_NOT_SYMMETRIC := "Reduced Star can't keep this hole's symmetry, so it was filled with %s instead"


## How many of the faces have a symmetry image that is not a face (no partner face).
static func _faces_lacking_partners(c: Dictionary, faces: PackedInt32Array) -> int:
	var ctx := _sym_ctx(c)
	if (ctx.maps as Array).is_empty() or faces.is_empty():
		return 0
	var topo := CAGE.topology(c)
	var lacking := 0
	for f in faces:
		if f < 0 or f >= topo.nF:
			continue
		var r := _images(ctx, topo.face_verts(f))
		for img in r.images:
			if topo.face_by_vertices(img) < 0:
				lacking += 1
				break
	return lacking


static func _fill_mode(m: String) -> String:
	var s := m.to_lower()
	if s.begins_with("fill") or s == "star":
		return "star"
	if s.begins_with("coll"):
		return "collapse"
	return "reduced"


## UnWeld Edges: cuts along the selected edges (partners too).
static func unweld(c: Dictionary, sel: Dictionary, _opts: Dictionary) -> Dictionary:
	var pairs := _list(sel, "edges")
	if pairs.is_empty():
		return _err(c, "Pick edges to cut along.")
	var warnings := PackedStringArray()
	if _has_symmetry(c):
		var ps := partner_selection(c, _sel(PackedInt32Array(), pairs))
		pairs = ps.edges
		warnings.append_array(ps.warnings)
	var locked := locked_set(c)
	if _any_locked(locked, pairs):
		return _err(c, CAGE.FROZEN_ERROR)
	var r := CAGE.unweld_edges(c, pairs)
	if r.error != "":
		return _err(c, r.error)
	if (r.new_vertices as PackedInt32Array).is_empty():
		return _err(c, "Those edges don't cut anything off; a cut has to reach the boundary or close a loop.")
	var out := _resym(r.cage, PackedInt32Array(), warnings)
	return _ok(c, out, _sel(PackedInt32Array(), pairs), warnings, {"new_vertices": r.new_vertices})


## Crease: selected edges and vertices get weight 10 (partners too). "Nothing to change" when
## they already are.
static func crease(c: Dictionary, sel: Dictionary, opts: Dictionary) -> Dictionary:
	return _set_creases(c, sel, float(opts.get("weight", CAGE.SHARP)))


static func uncrease(c: Dictionary, sel: Dictionary, _opts: Dictionary) -> Dictionary:
	return _set_creases(c, sel, 0.0)


static func _set_creases(c: Dictionary, sel: Dictionary, weight: float) -> Dictionary:
	var pairs := _list(sel, "edges")
	var verts := _list(sel, "vertices")
	if pairs.is_empty() and verts.is_empty():
		return _err(c, "Pick edges or vertices.")
	var warnings := PackedStringArray()
	if _has_symmetry(c):
		var ps := partner_selection(c, _sel(verts, pairs))
		pairs = ps.edges
		verts = ps.vertices
		warnings.append_array(ps.warnings)
	var topo := CAGE.topology(c)
	var creases := CAGE.crease_map(c)
	var corners := CAGE.corner_map(c)
	var changed := 0
	for i in pairs.size() / 2:
		var a := pairs[2 * i]
		var b := pairs[2 * i + 1]
		if topo.edge_index(a, b) < 0:
			return _err(c, "%d-%d is not an edge." % [a, b])
		var key := CAGE.edge_key(a, b)
		if weight > 0.0 and float(creases.get(key, 0.0)) != weight:
			creases[key] = weight
			changed += 1
		elif weight <= 0.0 and creases.has(key):
			creases.erase(key)
			changed += 1
	for v in verts:
		if weight > 0.0 and float(corners.get(v, 0.0)) != weight:
			corners[v] = weight
			changed += 1
		elif weight <= 0.0 and corners.has(v):
			corners.erase(v)
			changed += 1
	if changed == 0:
		return _err(c, NOTHING, {"changed": 0})
	var out := CAGE.copy(c)
	CAGE._store_creases(out, creases)
	CAGE._store_corners(out, corners)
	return _ok(c, out, sel, warnings, {"changed": changed})


## Slide Edge: opts.slide -1..1; each chain vertex moves |slide| of the way along its rail on the
## side face (the Insert Edge side rule; negative = the other side). Topology is unchanged.
static func slide_edge(c: Dictionary, sel: Dictionary, opts: Dictionary) -> Dictionary:
	var pairs := _list(sel, "edges")
	if pairs.is_empty():
		return _err(c, "Pick edges to slide.")
	var s := float(opts.get("slide", 0.0))
	if s == 0.0:
		return _ok(c, CAGE.copy(c), sel, PackedStringArray(), {"moved": PackedInt32Array()})
	var topo := CAGE.topology(c)
	var si := side_items(topo, pairs, s < 0.0)
	if si.error != "":
		return _err(c, si.error)
	var rail := {}
	for item in si.items:
		var ev: Vector2i = item.edge
		var f: int = item.side
		var st := topo.face_offsets[f]
		var n := topo.face_size(f)
		for k in n:
			var x := topo.face_indices[st + k]
			var y := topo.face_indices[st + (k + 1) % n]
			if (x == ev.x and y == ev.y) or (x == ev.y and y == ev.x):
				# The side face runs the edge x -> y; the rails leave x backwards and y forwards.
				if not rail.has(x):
					rail[x] = topo.face_indices[st + (k - 1 + n) % n]
				if not rail.has(y):
					rail[y] = topo.face_indices[st + (k + 2) % n]
				break
	var locked := locked_set(c)
	var p: PackedFloat64Array = c.positions
	var np := p.duplicate()
	var moved := PackedInt32Array()
	var a := absf(s)
	for v in rail:
		if locked[v]:
			continue
		var w: int = rail[v]
		for d in 3:
			np[3 * v + d] = p[3 * v + d] + (p[3 * w + d] - p[3 * v + d]) * a
		moved.append(v)
	var out := CAGE.copy(c)
	out.positions = np
	if _has_symmetry(out):
		out = apply_symmetry(out, moved).cage
	return _ok(c, out, sel, PackedStringArray(), {"moved": moved})


## Smooth: opts.amount 0..1 (0.5). The vertices of the picked faces, minus the region border and
## locked vertices, take 3 steps p += amount (mean(neighbours) - p). Crease and boundary vertices
## average only their two sharp neighbours; corners stay.
static func smooth(c: Dictionary, sel: Dictionary, opts: Dictionary) -> Dictionary:
	var faces := _list(sel, "faces")
	if faces.is_empty():
		return _err(c, "Pick faces to smooth.")
	var amount := clampf(float(opts.get("amount", 0.5)), 0.0, 1.0)
	var topo := CAGE.topology(c)
	var nV := topo.nV
	var picked := PackedByteArray()
	picked.resize(topo.nF)
	for f in faces:
		if f >= 0 and f < topo.nF:
			picked[f] = 1
	var inside := PackedByteArray()
	inside.resize(nV)
	var border := PackedByteArray()
	border.resize(nV)
	for f in topo.nF:
		for h in range(topo.face_offsets[f], topo.face_offsets[f + 1]):
			if picked[f]:
				inside[topo.face_indices[h]] = 1
			else:
				border[topo.face_indices[h]] = 1
	var locked := locked_set(c)
	var creases := CAGE.crease_map(c)
	var corners := CAGE.corner_map(c)
	var verts := PackedInt32Array()
	var nbrs: Array = []
	for v in nV:
		if not inside[v] or border[v] or locked[v] or corners.has(v):
			continue
		var all := topo.vertex_neighbors(v)
		var sharp := PackedInt32Array()
		for e in topo.vertex_edges(v):
			if topo.edge_uses[e] == 1 or creases.has(CAGE.edge_key(topo.edges[2 * e], topo.edges[2 * e + 1])):
				sharp.append(topo._other(e, v))
		if sharp.size() > 2:
			continue
		verts.append(v)
		nbrs.append(sharp if sharp.size() == 2 else all)
	var p: PackedFloat64Array = c.positions
	var cur := p.duplicate()
	for it in 3:
		var nxt := cur.duplicate()
		for i in verts.size():
			var v := verts[i]
			var nb: PackedInt32Array = nbrs[i]
			if nb.is_empty():
				continue
			for d in 3:
				var m := 0.0
				for w in nb:
					m += cur[3 * w + d]
				m /= nb.size()
				nxt[3 * v + d] = cur[3 * v + d] + amount * (m - cur[3 * v + d])
		cur = nxt
	if verts.is_empty() or amount <= 0.0 or cur == p:
		# Every vertex of the picked faces is on the region's border (or locked): nothing moves.
		return _err(c, NOTHING)
	var out := CAGE.copy(c)
	out.positions = cur
	if _has_symmetry(out):
		out = apply_symmetry(out, verts).cage
	return _ok(c, out, sel, PackedStringArray(), {"moved": verts})


## Cylindrify: each connected band of picked faces (grown to its feature loops when
## opts.auto_feature, default on) becomes a true cylinder: axis = least-spread direction of the
## face normals, centre = least-squares circle; each closed ring of edges across the axis gets
## evenly spaced angles at the band's mean radius, keeping axial coordinates and order.
## info.bands = [{"origin", "axis", "radius", "rings": [PackedInt32Array]}].
static func cylindrify(c: Dictionary, sel: Dictionary, opts: Dictionary) -> Dictionary:
	var faces := _list(sel, "faces")
	if faces.is_empty():
		return _err(c, "Pick faces of the band to make round.")
	var topo := CAGE.topology(c)
	var mark := {}
	for f in faces:
		if f < 0 or f >= topo.nF:
			continue
		mark[f] = true
		if bool(opts.get("auto_feature", true)):
			for g in topo.feature_faces(f):
				mark[g] = true
	var band_faces := PackedInt32Array(mark.keys())
	var p: PackedFloat64Array = c.positions
	var np := p.duplicate()
	var locked := locked_set(c)
	var bands: Array = []
	var moved := PackedInt32Array()
	for band in _face_groups(topo, band_faces):
		var info := _cylindrify_band(c, topo, band, np, locked, moved)
		if info.is_empty():
			continue
		bands.append(info)
	if bands.is_empty():
		return _err(c, "No closed ring of edges goes round those faces.")
	var out := CAGE.copy(c)
	out.positions = np
	if _has_symmetry(out):
		out = apply_symmetry(out, moved).cage
	return _ok(c, out, sel, PackedStringArray(), {"bands": bands, "moved": moved})


static func _face_groups(topo: CAGE.Topo, faces: PackedInt32Array) -> Array:
	var mark := {}
	for f in faces:
		mark[f] = -1
	var groups: Array = []
	for f0 in faces:
		if int(mark[f0]) >= 0:
			continue
		var group := PackedInt32Array([f0])
		mark[f0] = groups.size()
		var qi := 0
		while qi < group.size():
			var f := group[qi]
			qi += 1
			for g in topo.face_neighbors(f):
				if mark.has(g) and int(mark[g]) < 0:
					mark[g] = groups.size()
					group.append(g)
		groups.append(group)
	return groups


static func _cylindrify_band(c: Dictionary, topo: CAGE.Topo, band: PackedInt32Array, np: PackedFloat64Array, locked: PackedByteArray, moved: PackedInt32Array) -> Dictionary:
	var p: PackedFloat64Array = c.positions
	var m := [[0.0, 0.0, 0.0], [0.0, 0.0, 0.0], [0.0, 0.0, 0.0]]
	for f in band:
		var av := topo.face_area_vector(c, f)
		var area := av.length() * 0.5
		if area == 0.0:
			continue
		var n := av / (2.0 * area)
		var nn := [n.x, n.y, n.z]
		for r in 3:
			for k in 3:
				m[r][k] += area * nn[r] * nn[k]
	var eig := eigen_sym3(m)
	var a: PackedFloat64Array = eig.vectors[0]
	var vmark := {}
	for f in band:
		for h in range(topo.face_offsets[f], topo.face_offsets[f + 1]):
			vmark[topo.face_indices[h]] = true
	var verts := PackedInt32Array(vmark.keys())
	var cen := PackedFloat64Array([0.0, 0.0, 0.0])
	for v in verts:
		for d in 3:
			cen[d] += p[3 * v + d]
	for d in 3:
		cen[d] /= verts.size()
	var u := _perp(a)
	var w := PackedFloat64Array([a[1] * u[2] - a[2] * u[1], a[2] * u[0] - a[0] * u[2], a[0] * u[1] - a[1] * u[0]])
	# Least-squares circle (x^2 + y^2 + D x + E y + F = 0) of the vertices across the axis.
	var s := [[0.0, 0.0, 0.0], [0.0, 0.0, 0.0], [0.0, 0.0, 0.0]]
	var rhs := [0.0, 0.0, 0.0]
	for v in verts:
		var dx := p[3 * v] - cen[0]
		var dy := p[3 * v + 1] - cen[1]
		var dz := p[3 * v + 2] - cen[2]
		var x := dx * u[0] + dy * u[1] + dz * u[2]
		var y := dx * w[0] + dy * w[1] + dz * w[2]
		var row := [x, y, 1.0]
		var b := -(x * x + y * y)
		for r in 3:
			for k in 3:
				s[r][k] += row[r] * row[k]
			rhs[r] += row[r] * b
	var sol := _solve3(s, rhs)
	var ox: float = -sol[0] * 0.5
	var oy: float = -sol[1] * 0.5
	var o := PackedFloat64Array([cen[0] + ox * u[0] + oy * w[0], cen[1] + ox * u[1] + oy * w[1], cen[2] + ox * u[2] + oy * w[2]])
	# Rings: closed loops of band edges running across the axis.
	var ring_edges := {}
	var bset := {}
	for f in band:
		bset[f] = true
	for f in band:
		for h in range(topo.face_offsets[f], topo.face_offsets[f + 1]):
			var e := topo.he_edge[h]
			var va := topo.edges[2 * e]
			var vb := topo.edges[2 * e + 1]
			var dx := p[3 * vb] - p[3 * va]
			var dy := p[3 * vb + 1] - p[3 * va + 1]
			var dz := p[3 * vb + 2] - p[3 * va + 2]
			var l := sqrt(dx * dx + dy * dy + dz * dz)
			if l > 0.0 and absf(dx * a[0] + dy * a[1] + dz * a[2]) / l < 0.5:
				ring_edges[e] = true
	var at := {}
	for e in ring_edges:
		for v in [topo.edges[2 * e], topo.edges[2 * e + 1]]:
			if not at.has(v):
				at[v] = []
			(at[v] as Array).append(e)
	var rings: Array = []
	var used := {}
	for v0 in at:
		if used.has(v0) or (at[v0] as Array).size() != 2:
			continue
		var ring := PackedInt32Array([v0])
		used[v0] = true
		var prev_e: int = at[v0][0]
		var cur: int = topo._other(prev_e, v0)
		var ok := true
		var guard := topo.nV
		while cur != v0 and guard > 0:
			guard -= 1
			if used.has(cur) or not at.has(cur) or (at[cur] as Array).size() != 2:
				ok = false
				break
			used[cur] = true
			ring.append(cur)
			var nxt_e: int = at[cur][0] if at[cur][0] != prev_e else at[cur][1]
			prev_e = nxt_e
			cur = topo._other(nxt_e, cur)
		if ok and cur == v0 and ring.size() >= 3:
			rings.append(ring)
	if rings.is_empty():
		return {}
	var radius := 0.0
	var count := 0
	for ring in rings:
		for v in ring:
			var dx := p[3 * v] - o[0]
			var dy := p[3 * v + 1] - o[1]
			var dz := p[3 * v + 2] - o[2]
			var along := dx * a[0] + dy * a[1] + dz * a[2]
			radius += sqrt(maxf(0.0, dx * dx + dy * dy + dz * dz - along * along))
			count += 1
	radius /= count
	var out_rings: Array = []
	for ring0 in rings:
		var ring: PackedInt32Array = ring0
		var n := ring.size()
		var theta := PackedFloat64Array()
		for v in ring:
			var dx := p[3 * v] - o[0]
			var dy := p[3 * v + 1] - o[1]
			var dz := p[3 * v + 2] - o[2]
			theta.append(atan2(dx * w[0] + dy * w[1] + dz * w[2], dx * u[0] + dy * u[1] + dz * u[2]))
		var turn := 0.0
		for k in n:
			turn += wrapf(theta[(k + 1) % n] - theta[k], -PI, PI)
		if turn < 0.0:
			ring.reverse()
			theta.reverse()
		var sx := 0.0
		var sy := 0.0
		for k in n:
			var q := theta[k] - TAU * k / n
			sx += cos(q)
			sy += sin(q)
		var t0 := atan2(sy, sx)
		for k in n:
			var v := ring[k]
			if locked[v]:
				continue
			var dx := p[3 * v] - o[0]
			var dy := p[3 * v + 1] - o[1]
			var dz := p[3 * v + 2] - o[2]
			var hgt := dx * a[0] + dy * a[1] + dz * a[2]
			var ang := t0 + TAU * k / n
			var cs := cos(ang) * radius
			var sn := sin(ang) * radius
			for d in 3:
				np[3 * v + d] = o[d] + hgt * a[d] + cs * u[d] + sn * w[d]
			moved.append(v)
		out_rings.append(ring)
	return {"origin": o, "axis": a, "u": u, "v": w, "radius": radius, "rings": out_rings}


## A unit vector perpendicular to unit a.
static func _perp(a: PackedFloat64Array) -> PackedFloat64Array:
	var b := PackedFloat64Array([1.0, 0.0, 0.0]) if absf(a[0]) < 0.9 else PackedFloat64Array([0.0, 1.0, 0.0])
	var d := b[0] * a[0] + b[1] * a[1] + b[2] * a[2]
	return unit_d(PackedFloat64Array([b[0] - d * a[0], b[1] - d * a[1], b[2] - d * a[2]]))


## Solves a 3x3 system by Gaussian elimination with partial pivoting.
static func _solve3(m: Array, b: Array) -> Array:
	var a := [[m[0][0], m[0][1], m[0][2], b[0]], [m[1][0], m[1][1], m[1][2], b[1]], [m[2][0], m[2][1], m[2][2], b[2]]]
	for col in 3:
		var piv := col
		for r in range(col + 1, 3):
			if absf(a[r][col]) > absf(a[piv][col]):
				piv = r
		var tmp = a[col]
		a[col] = a[piv]
		a[piv] = tmp
		if absf(a[col][col]) < 1e-300:
			continue
		for r in range(col + 1, 3):
			var f: float = a[r][col] / a[col][col]
			for k in range(col, 4):
				a[r][k] -= f * a[col][k]
	var x := [0.0, 0.0, 0.0]
	for r in range(2, -1, -1):
		var s: float = a[r][3]
		for k in range(r + 1, 3):
			s -= a[r][k] * x[k]
		x[r] = s / a[r][r] if absf(a[r][r]) > 1e-300 else 0.0
	return x


## Flatten (Control Points): opts "direction" "fit" (best-fit plane of the selection, 3+
## vertices) | "plane" (opts.plane {"origin", "normal"}) | "parallel" (opts.plane's normal through
## the selection centroid); "type" "control" ("surface" is in form_fit). info.origin / normal.
static func flatten(c: Dictionary, sel: Dictionary, opts: Dictionary) -> Dictionary:
	var verts := _sel_vertices(c, sel)
	if str(opts.get("type", "control")).to_lower().begins_with("surf"):
		return _err(c, "Flattening surface points needs the Holo Forge kernel.")
	var dir := str(opts.get("direction", "fit")).to_lower()
	var pts := PackedFloat64Array()
	for v in verts:
		pts.append_array(CAGE.position_d(c, v))
	var o: PackedFloat64Array
	var n: PackedFloat64Array
	if dir.begins_with("fit"):
		if verts.size() < 3:
			return _err(c, "Pick at least three vertices to fit a plane.")
		var fit := best_fit_plane(pts)
		o = fit.origin
		n = fit.normal
	else:
		if verts.is_empty():
			return _err(c, "Pick vertices to flatten.")
		var plane: Dictionary = opts.get("plane", {})
		if plane.is_empty():
			return _err(c, "Pick a plane.")
		n = unit_d(_d3(plane.get("normal", Vector3.UP)))
		o = _d3(plane.get("origin", Vector3.ZERO))
		if dir.begins_with("par"):
			o = best_fit_plane(pts).origin
	var locked := locked_set(c)
	var p: PackedFloat64Array = c.positions
	var np := p.duplicate()
	var moved := PackedInt32Array()
	for v in verts:
		if locked[v]:
			continue
		var d := (p[3 * v] - o[0]) * n[0] + (p[3 * v + 1] - o[1]) * n[1] + (p[3 * v + 2] - o[2]) * n[2]
		for k in 3:
			np[3 * v + k] = p[3 * v + k] - d * n[k]
		moved.append(v)
	var out := CAGE.copy(c)
	out.positions = np
	if _has_symmetry(out):
		out = apply_symmetry(out, moved).cage
	return _ok(c, out, sel, PackedStringArray(), {"origin": o, "normal": n, "moved": moved})


## Straighten (Control Points): opts "direction" "fit" (best-fit line, 2+ vertices) | "line"
## (opts.line {"origin", "direction"}) | "parallel" (opts.line's direction through the centroid)
## | "two_points" (opts.points [p0, p1]). info.origin / direction.
static func straighten(c: Dictionary, sel: Dictionary, opts: Dictionary) -> Dictionary:
	var verts := _sel_vertices(c, sel)
	if str(opts.get("type", "control")).to_lower().begins_with("surf"):
		return _err(c, "Straightening surface points needs the Holo Forge kernel.")
	if verts.size() < 2:
		return _err(c, "Pick at least two vertices to straighten.")
	var dir := str(opts.get("direction", "fit")).to_lower()
	var pts := PackedFloat64Array()
	for v in verts:
		pts.append_array(CAGE.position_d(c, v))
	var o: PackedFloat64Array
	var a: PackedFloat64Array
	if dir.begins_with("fit"):
		var fit := best_fit_line(pts)
		o = fit.origin
		a = fit.direction
	elif dir.begins_with("two"):
		var two: Array = opts.get("points", [])
		if two.size() < 2:
			return _err(c, "Pick two points for the line.")
		o = _d3(two[0])
		var q := _d3(two[1])
		a = unit_d(PackedFloat64Array([q[0] - o[0], q[1] - o[1], q[2] - o[2]]))
	else:
		var line: Dictionary = opts.get("line", {})
		if line.is_empty():
			return _err(c, "Pick a line.")
		a = unit_d(_d3(line.get("direction", Vector3.RIGHT)))
		o = _d3(line.get("origin", Vector3.ZERO))
		if dir.begins_with("par"):
			o = best_fit_line(pts).origin
	var locked := locked_set(c)
	var p: PackedFloat64Array = c.positions
	var np := p.duplicate()
	var moved := PackedInt32Array()
	for v in verts:
		if locked[v]:
			continue
		var t := (p[3 * v] - o[0]) * a[0] + (p[3 * v + 1] - o[1]) * a[1] + (p[3 * v + 2] - o[2]) * a[2]
		for k in 3:
			np[3 * v + k] = o[k] + t * a[k]
		moved.append(v)
	var out := CAGE.copy(c)
	out.positions = np
	if _has_symmetry(out):
		out = apply_symmetry(out, moved).cage
	return _ok(c, out, sel, PackedStringArray(), {"origin": o, "direction": a, "moved": moved})


## Thicken the components the selection touches (all when nothing is selected). opts:
## "thickness" (meters; default max(1 mm, 5% of the bounds diagonal)), "type" "sharp" | "soft"
## | "none", "direction" "normal" | "axis" with "axis" Vector3, "flip". An open cage gets a copy
## offset behind it along the vertex normals (in front with Flip), or along +axis (-axis with
## Flip) for Direction Axis, joined by a strip per boundary
## loop (rims creased when sharp; no strip for "none"); whichever layer faces the other is
## reversed so the result faces outward. A closed cage gets an inward offset copy (outward with
## Flip) as a second component. Copies of locked vertices are not offset.
static func thicken(c: Dictionary, sel: Dictionary, opts: Dictionary) -> Dictionary:
	var topo := CAGE.topology(c)
	var nV := topo.nV
	var comps := topo.components()
	var want := {}
	var touched := _sel_vertices(c, sel, true)
	var vmark := PackedByteArray()
	vmark.resize(nV)
	for v in touched:
		vmark[v] = 1
	for f in topo.nF:
		for h in range(topo.face_offsets[f], topo.face_offsets[f + 1]):
			if vmark[topo.face_indices[h]]:
				want[comps[f]] = true
				break
	var faces := PackedInt32Array()
	for f in topo.nF:
		if want.has(comps[f]):
			faces.append(f)
	if faces.is_empty():
		return _err(c, "Pick a body to thicken.")
	var closed := true
	for f in faces:
		for h in range(topo.face_offsets[f], topo.face_offsets[f + 1]):
			if topo.he_twin[h] < 0:
				closed = false
	var thickness := float(opts.get("thickness", maxf(0.001, 0.05 * CAGE.diagonal(c))))
	var kind := str(opts.get("type", "sharp")).to_lower()
	var flip := bool(opts.get("flip", false))
	var locked := locked_set(c)
	var p: PackedFloat64Array = c.positions
	var normals := PackedFloat64Array()
	normals.resize(3 * nV)
	var use_axis := str(opts.get("direction", "normal")).to_lower() == "axis"
	var axis := Vector3(opts.get("axis", Vector3.UP)).normalized()
	for f in faces:
		var av := topo.face_area_vector(c, f)
		for h in range(topo.face_offsets[f], topo.face_offsets[f + 1]):
			var v := topo.face_indices[h]
			normals[3 * v] += av.x
			normals[3 * v + 1] += av.y
			normals[3 * v + 2] += av.z
	# The copy goes behind the surface (inward for a closed cage); Flip puts it in front. An open
	# cage reverses whichever layer faces the other, so the result faces outward either way.
	var sign := 1.0 if flip else -1.0
	var front := flip
	if use_axis:
		# Along the axis as given (Flip negates); the layer that ends up behind the other is
		# the one reversed.
		sign = -1.0 if flip else 1.0
		var mean := Vector3.ZERO
		for v in nV:
			mean += Vector3(normals[3 * v], normals[3 * v + 1], normals[3 * v + 2])
		front = (axis * sign).dot(mean) > 0.0
	var reverse_copy := not closed and not front
	var reverse_original := not closed and front
	var copy := PackedInt32Array()
	copy.resize(nV)
	copy.fill(-1)
	var np := p.duplicate()
	var new_vertices := PackedInt32Array()
	var boundary_locked := false
	for f in faces:
		for h in range(topo.face_offsets[f], topo.face_offsets[f + 1]):
			var v := topo.face_indices[h]
			if topo.he_twin[h] < 0 and (locked[v] or locked[topo.he_dest(h)]):
				boundary_locked = true
			if copy[v] >= 0:
				continue
			copy[v] = np.size() / 3
			new_vertices.append(copy[v])
			var nx := normals[3 * v]
			var ny := normals[3 * v + 1]
			var nz := normals[3 * v + 2]
			if use_axis:
				nx = axis.x
				ny = axis.y
				nz = axis.z
			var l := sqrt(nx * nx + ny * ny + nz * nz)
			var k := 0.0 if (locked[v] or l == 0.0) else sign * thickness / l
			np.append(p[3 * v] + nx * k)
			np.append(p[3 * v + 1] + ny * k)
			np.append(p[3 * v + 2] + nz * k)
	if not closed and boundary_locked:
		return _err(c, CAGE.FROZEN_ERROR)
	var out_faces := CAGE._faces_array(c)
	for f in faces:
		var poly := topo.face_verts(f)
		var cp := PackedInt32Array()
		var n := poly.size()
		if reverse_copy:
			cp.append(copy[poly[0]])
			for k in range(n - 1, 0, -1):
				cp.append(copy[poly[k]])
		else:
			for k in n:
				cp.append(copy[poly[k]])
		out_faces.append(cp)
		if reverse_original:
			var rev := PackedInt32Array([poly[0]])
			for k in range(n - 1, 0, -1):
				rev.append(poly[k])
			out_faces[f] = rev
	var creases := CAGE.crease_map(c)
	for key in creases.keys():
		var a: int = key >> 32
		var b: int = key & 0xFFFFFFFF
		if copy[a] >= 0 and copy[b] >= 0:
			creases[CAGE.edge_key(copy[a], copy[b])] = creases[key]
	var corners := CAGE.corner_map(c)
	for v in corners.keys():
		if copy[v] >= 0:
			corners[copy[v]] = corners[v]
	if not closed and kind != "none" and not kind.begins_with("no"):
		for f in faces:
			for h in range(topo.face_offsets[f], topo.face_offsets[f + 1]):
				if topo.he_twin[h] >= 0:
					continue
				var a := topo.face_indices[h]
				var b := topo.he_dest(h)
				if reverse_original:
					out_faces.append(PackedInt32Array([a, b, copy[b], copy[a]]))
				else:
					out_faces.append(PackedInt32Array([b, a, copy[a], copy[b]]))
				if kind == "sharp":
					creases[CAGE.edge_key(a, b)] = CAGE.SHARP
					creases[CAGE.edge_key(copy[a], copy[b])] = CAGE.SHARP
	var out := CAGE._assemble(c, np, out_faces, creases, corners)
	var warnings := PackedStringArray()
	out = _resym(out, new_vertices, warnings)
	return _ok(c, out, _sel(), warnings, {"new_vertices": new_vertices, "closed": closed})


## Freeze: adds the selection's vertices to frozen.
static func freeze(c: Dictionary, sel: Dictionary, _opts: Dictionary) -> Dictionary:
	var verts := _sel_vertices(c, sel)
	if verts.is_empty():
		return _err(c, "Pick faces, edges or vertices to freeze.")
	var frozen: PackedInt32Array = c.get("frozen", PackedInt32Array())
	var merged := CAGE.sorted_unique(frozen + verts)
	if merged == frozen:
		return _err(c, NOTHING, {"changed": 0})
	var out := CAGE.copy(c)
	out.frozen = merged
	return _ok(c, out, sel, PackedStringArray(), {"changed": merged.size() - frozen.size()})


## Unfreeze: removes the selection's vertices from frozen; opts.all clears it.
static func unfreeze(c: Dictionary, sel: Dictionary, opts: Dictionary) -> Dictionary:
	var frozen: PackedInt32Array = c.get("frozen", PackedInt32Array())
	var keep := PackedInt32Array()
	if not bool(opts.get("all", false)):
		var verts := _sel_vertices(c, sel)
		if verts.is_empty():
			return _err(c, "Pick faces, edges or vertices to unfreeze.")
		var drop := {}
		for v in verts:
			drop[v] = true
		for v in frozen:
			if not drop.has(v):
				keep.append(v)
	if keep.size() == frozen.size():
		return _err(c, NOTHING, {"changed": 0})
	var out := CAGE.copy(c)
	out.frozen = keep
	return _ok(c, out, sel, PackedStringArray(), {"changed": frozen.size() - keep.size()})


## Delete: faces are removed, edges dissolved (a boundary edge removes its face), vertices
## dissolved; partners too. A body selection is the editor's job (it removes the body).
static func delete_elements(c: Dictionary, sel: Dictionary, _opts: Dictionary) -> Dictionary:
	var faces := _list(sel, "faces")
	var pairs := _list(sel, "edges")
	var verts := _list(sel, "vertices")
	if faces.is_empty() and pairs.is_empty() and verts.is_empty():
		return _err(c, "Pick faces, edges or vertices to delete.")
	var warnings := PackedStringArray()
	if _has_symmetry(c):
		var ps := partner_selection(c, sel)
		faces = ps.faces
		pairs = ps.edges
		verts = ps.vertices
		warnings.append_array(ps.warnings)
	var topo := CAGE.topology(c)
	var locked := locked_set(c)
	var touched := faces.duplicate()
	for i in pairs.size() / 2:
		var e := topo.edge_index(pairs[2 * i], pairs[2 * i + 1])
		if e >= 0:
			touched.append_array(topo.edge_faces(e))
	for v in verts:
		touched.append_array(topo.vertex_all_faces(v))
	if _faces_locked(topo, locked, touched):
		return _err(c, CAGE.FROZEN_ERROR)
	var out := CAGE.copy(c)
	var vmap := PackedInt32Array()
	var nV := topo.nV
	var map_through := func(m: PackedInt32Array, list: PackedInt32Array) -> PackedInt32Array:
		if m.is_empty():
			return list
		var res := PackedInt32Array()
		for v in list:
			res.append(m[v] if v < m.size() else -1)
		return res
	if not faces.is_empty():
		var r := CAGE.delete_faces(out, faces)
		if r.error != "":
			return _err(c, r.error)
		out = r.cage
		vmap = r.vertex_map
	if not pairs.is_empty():
		var mapped: PackedInt32Array = map_through.call(vmap, pairs)
		var t2 := CAGE.topology(out)
		var keep := PackedInt32Array()
		for i in mapped.size() / 2:
			if mapped[2 * i] >= 0 and mapped[2 * i + 1] >= 0 and t2.edge_index(mapped[2 * i], mapped[2 * i + 1]) >= 0:
				keep.append(mapped[2 * i])
				keep.append(mapped[2 * i + 1])
		if not keep.is_empty():
			var r := CAGE.dissolve_edges(out, keep)
			if r.error != "":
				return _err(c, r.error)
			out = r.cage
			vmap = _chain_maps(vmap, r.vertex_map, nV)
	if not verts.is_empty():
		var mapped: PackedInt32Array = map_through.call(vmap, verts)
		var keep := PackedInt32Array()
		for v in mapped:
			if v >= 0:
				keep.append(v)
		if not keep.is_empty():
			var r := CAGE.dissolve_vertices(out, keep)
			if r.error != "":
				return _err(c, r.error)
			out = r.cage
			vmap = _chain_maps(vmap, r.vertex_map, nV)
	out = _resym(out, PackedInt32Array(), warnings)
	return _ok(c, out, _sel(), warnings, {"vertex_map": vmap})


## old -> new through two maps (an empty map is the identity).
static func _chain_maps(first: PackedInt32Array, second: PackedInt32Array, n: int) -> PackedInt32Array:
	if second.is_empty():
		return first
	if first.is_empty():
		return second
	var out := PackedInt32Array()
	out.resize(n)
	for v in n:
		var w := first[v]
		out[v] = second[w] if w >= 0 and w < second.size() else -1
	return out


# ---------------------------------------------------------------------------------------------
# Symmetry tools
# ---------------------------------------------------------------------------------------------

## Clear Symmetry: no entries and no isolated vertices. With opts.separate (default on),
## info.components holds one cage per connected component (the first keeps the body; the
## editor registers the others) and the result cage is the first.
static func clear_symmetry(c: Dictionary, _sel_in: Dictionary, opts: Dictionary) -> Dictionary:
	var out := CAGE.copy(c)
	out.symmetry = []
	out.sym_isolated = PackedInt32Array()
	var comps := split_components(out)
	if bool(opts.get("separate", true)) and comps.size() > 1:
		return _ok(c, comps[0], _sel(), PackedStringArray(), {"components": comps})
	return _ok(c, out, _sel(), PackedStringArray(), {"components": [out]})


## One cage per connected component (ordered by lowest face), each compacted.
static func split_components(c: Dictionary) -> Array:
	var topo := CAGE.topology(c)
	var n := topo.component_count()
	if n <= 1:
		return [CAGE.copy(c)]
	var comps := topo.components()
	var out: Array = []
	for k in n:
		var drop := PackedInt32Array()
		for f in topo.nF:
			if comps[f] != k:
				drop.append(f)
		out.append(CAGE.delete_faces(c, drop).cage)
	return out


## Isolate Symmetry: opts.mode "isolate" adds the selection's vertices to sym_isolated,
## "restore" removes them.
static func isolate_symmetry(c: Dictionary, sel: Dictionary, opts: Dictionary) -> Dictionary:
	var verts := _sel_vertices(c, sel)
	if verts.is_empty():
		return _err(c, "Pick faces, edges or vertices.")
	var cur: PackedInt32Array = c.get("sym_isolated", PackedInt32Array())
	var next := PackedInt32Array()
	if str(opts.get("mode", "isolate")).to_lower() == "restore":
		var drop := {}
		for v in verts:
			drop[v] = true
		for v in cur:
			if not drop.has(v):
				next.append(v)
	else:
		next = CAGE.sorted_unique(cur + verts)
	if next == cur:
		return _err(c, NOTHING, {"changed": 0})
	var out := CAGE.copy(c)
	out.sym_isolated = next
	return _ok(c, out, sel, PackedStringArray(), {"changed": absi(next.size() - cur.size())})


## Mirror - Duplicate: appends the mirror image (faces reversed) across opts.origin /
## opts.normal; with opts.weld (on) vertices within opts.tolerance (1% of the mean edge) of the
## plane snap onto it and join their images. Adds the mirror entry (welded vertices map to
## themselves); earlier entries are rebuilt and dropped (with a warning) when they no longer fit.
static func mirror_duplicate(c: Dictionary, _sel_in: Dictionary, opts: Dictionary) -> Dictionary:
	if not opts.has("normal"):
		return _err(c, "Pick a mirror plane.")
	var o := _d3(opts.get("origin", Vector3.ZERO))
	var n := unit_d(_d3(opts.normal))
	var nV := CAGE.vertex_count(c)
	var tol := float(opts.get("tolerance", 0.01 * CAGE.mean_edge_length(c)))
	var weld := bool(opts.get("weld", true))
	var src := CAGE.copy(c)
	var p: PackedFloat64Array = src.positions
	var seam := PackedInt32Array()
	if weld:
		for v in nV:
			var d := (p[3 * v] - o[0]) * n[0] + (p[3 * v + 1] - o[1]) * n[1] + (p[3 * v + 2] - o[2]) * n[2]
			if absf(d) <= tol:
				for k in 3:
					p[3 * v + k] -= d * n[k]
				seam.append(v)
		src.positions = p
	var old_sym: Array = src.symmetry
	var mirrored := CAGE.copy(src)
	mirrored.symmetry = []
	var mp := PackedFloat64Array()
	mp.resize(3 * nV)
	for v in nV:
		var q := reflect_d(PackedFloat64Array([p[3 * v], p[3 * v + 1], p[3 * v + 2]]), o, n)
		mp[3 * v] = q[0]
		mp[3 * v + 1] = q[1]
		mp[3 * v + 2] = q[2]
	for v in seam:
		for k in 3:
			mp[3 * v + k] = p[3 * v + k]
	mirrored.positions = mp
	mirrored = CAGE.flip_faces(mirrored, _range(CAGE.face_count(mirrored))).cage
	var joined: Dictionary = CAGE.append(src, mirrored).cage
	var welded := PackedInt32Array()
	for v in nV + nV:
		welded.append(v)
	if not seam.is_empty():
		var pairs: Array = []
		for v in seam:
			pairs.append(Vector2i(v, v + nV))
		var r := CAGE.weld(joined, pairs)
		if r.error != "":
			return _err(c, r.error)
		joined = r.cage
		welded = r.welded
	var nn := CAGE.vertex_count(joined)
	var m := PackedInt32Array()
	m.resize(nn)
	m.fill(-1)
	for v in nV:
		var a := welded[v]
		var b := welded[v + nV]
		m[a] = b
		m[b] = a
	var warnings := PackedStringArray()
	var entry := {"type": "mirror", "origin": o, "normal": n, "map": m}
	var info := {}
	if not old_sym.is_empty():
		var tmp := CAGE.copy(joined)
		var r := rebuild_symmetry(tmp, 0.0)
		var kept: Array = []
		for e in (r.cage.symmetry as Array):
			var em: PackedInt32Array = e.map
			if em.has(-1):
				continue
			kept.append(e)
		if kept.size() < old_sym.size():
			warnings.append("%d earlier symmetries no longer fit and were removed" % (old_sym.size() - kept.size()))
		joined.symmetry = kept
	var sym: Array = joined.symmetry
	sym.append(entry)
	joined.symmetry = sym
	info.welded = seam.size()
	return _ok(c, joined, _sel(), warnings, info)


static func _range(n: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(n)
	for i in n:
		out[i] = i
	return out


## Circular - Duplicate: opts "origin", "axis", "count" (4, 2..64), "spacing" "full" | "angle"
## with "angle" (total, radians), "weld" (on), "tolerance" (1% of the mean edge). Copies k = 1..n-1
## rotated by k x step; coincident seam vertices are welded; the entry maps each vertex to its
## counterpart in the next copy (open for a partial arc).
static func circular_duplicate(c: Dictionary, _sel_in: Dictionary, opts: Dictionary) -> Dictionary:
	if not opts.has("axis"):
		return _err(c, "Pick an axis.")
	var o := _d3(opts.get("origin", Vector3.ZERO))
	var a := unit_d(_d3(opts.axis))
	var count := clampi(int(opts.get("count", 4)), 2, 64)
	var full := str(opts.get("spacing", "full")).to_lower() == "full"
	var total := float(opts.get("angle", PI))
	var step := TAU / count if full else total / (count - 1)
	var open := not full and total < TAU - 1e-9
	var nV := CAGE.vertex_count(c)
	var tol := float(opts.get("tolerance", 0.01 * CAGE.mean_edge_length(c)))
	var src := CAGE.copy(c)
	var old_sym: Array = src.symmetry
	src.symmetry = []
	var joined := src
	var p: PackedFloat64Array = c.positions
	for k in range(1, count):
		var part := CAGE.copy(src)
		part.symmetry = []
		var pp := PackedFloat64Array()
		pp.resize(3 * nV)
		for v in nV:
			var q := rotate_d(PackedFloat64Array([p[3 * v], p[3 * v + 1], p[3 * v + 2]]), o, a, k * step)
			pp[3 * v] = q[0]
			pp[3 * v + 1] = q[1]
			pp[3 * v + 2] = q[2]
		part.positions = pp
		joined = CAGE.append(joined, part).cage
	var total_v := nV * count
	var welded := _range(total_v)
	if bool(opts.get("weld", true)):
		var jp: PackedFloat64Array = joined.positions
		var grid := _Grid.new(jp, tol)
		var pairs: Array = []
		for v in total_v:
			for w in grid.near(jp[3 * v], jp[3 * v + 1], jp[3 * v + 2], tol):
				if w > v and w / nV != v / nV:
					pairs.append(Vector2i(v, w))
		if not pairs.is_empty():
			var r := CAGE.weld(joined, pairs)
			if r.error != "":
				return _err(c, r.error)
			joined = r.cage
			welded = r.welded
	var nn := CAGE.vertex_count(joined)
	var m := PackedInt32Array()
	m.resize(nn)
	m.fill(-1)
	for k in count:
		for v in nV:
			var from := welded[k * nV + v]
			var nk := k + 1
			if nk == count:
				if open:
					continue
				nk = 0
			m[from] = welded[nk * nV + v]
	var warnings := PackedStringArray()
	var kept: Array = []
	if not old_sym.is_empty():
		var tmp := CAGE.copy(joined)
		tmp.symmetry = old_sym.duplicate(true)
		var r := rebuild_symmetry(tmp, 0.0)
		for e in (r.cage.symmetry as Array):
			if not (e.map as PackedInt32Array).has(-1):
				kept.append(e)
		if kept.size() < old_sym.size():
			warnings.append("%d earlier symmetries no longer fit and were removed" % (old_sym.size() - kept.size()))
	kept.append({"type": "circular", "origin": o, "axis": a, "count": count, "step": step, "open": open, "map": m})
	joined.symmetry = kept
	return _ok(c, joined, _sel(), warnings, {})


## Mirror - Internal: appends a mirror entry (opts "origin", "normal", "tolerance", "snap" =
## Snap Exactly, default on). Vertices on the plane are put onto it.
static func add_mirror(c: Dictionary, _sel_in: Dictionary, opts: Dictionary) -> Dictionary:
	if not opts.has("normal"):
		return _err(c, "No mirror symmetry found within the tolerance; pick a face on each side")
	var entry := {"type": "mirror", "origin": _d3(opts.get("origin", Vector3.ZERO)), "normal": unit_d(_d3(opts.normal)), "map": PackedInt32Array()}
	return _add_entry(c, entry, opts, "No mirror symmetry found within the tolerance; pick a face on each side")


## Circular - Internal: opts "origin", "axis", "count", "tolerance", "snap".
static func add_circular(c: Dictionary, _sel_in: Dictionary, opts: Dictionary) -> Dictionary:
	var count := int(opts.get("count", 0))
	if not opts.has("axis") or count < 2:
		return _err(c, "No circular symmetry found within the tolerance; pick a face")
	var entry := {"type": "circular", "origin": _d3(opts.get("origin", Vector3.ZERO)), "axis": unit_d(_d3(opts.axis)), "count": count, "step": TAU / count, "open": false, "map": PackedInt32Array()}
	return _add_entry(c, entry, opts, "No circular symmetry found within the tolerance; pick a face")


static func _add_entry(c: Dictionary, entry: Dictionary, opts: Dictionary, fail: String) -> Dictionary:
	var tol := float(opts.get("tolerance", default_tolerance(c)))
	var r: Dictionary
	if bool(opts.get("snap", true)):
		r = symmetrize(c, entry, tol)
	else:
		var out := CAGE.copy(c)
		var sym: Array = out.symmetry
		sym.append(entry.duplicate(true))
		out.symmetry = sym
		r = rebuild_symmetry(out, tol)
		if int(r.info.broken) == 0:
			var on := PackedInt32Array()
			var m: PackedInt32Array = (r.cage.symmetry as Array)[sym.size() - 1].map
			for v in m.size():
				if m[v] == v:
					on.append(v)
			r = apply_symmetry(r.cage, on)
	var added: Dictionary = (r.cage.symmetry as Array)[(r.cage.symmetry as Array).size() - 1]
	if (added.map as PackedInt32Array).has(-1) and not bool(added.get("open", false)):
		return _err(c, fail)
	return _ok(c, r.cage, _sel(), r.warnings, {})


# ---------------------------------------------------------------------------------------------
# Repair (the pure parts)
# ---------------------------------------------------------------------------------------------

## Repair Body without the self-intersection check (native, form_fit). opts: "mode" "fix" |
## "report", "tolerance" (1e-6 x the bounds diagonal), "merge_triangles". In order: degenerate
## faces, duplicate faces, coincident vertices welded, T-junctions zipped, non-manifold edges
## split, orientation, unused vertices, crease / corner / frozen cleanup, symmetry rebuilt
## (entries that no longer fit dropped), triangle pairs merged. info counts each fix and
## info.markers = [{"severity" "error" | "warning" | "info", "label", "position": Vector3}].
## Report mode returns the cage unchanged.
static func repair(c: Dictionary, _sel_in: Dictionary, opts: Dictionary) -> Dictionary:
	var info := {"degenerate": 0, "duplicate": 0, "welded": 0, "t_junctions": 0, "non_manifold": 0, "flipped": 0, "unused": 0, "creases_removed": 0, "symmetry_dropped": 0, "triangles_merged": 0}
	var markers: Array = []
	var warnings := PackedStringArray()
	var diag := CAGE.diagonal(c)
	var tol := float(opts.get("tolerance", 1e-6 * diag))
	var p: PackedFloat64Array = (c.get("positions", PackedFloat64Array()) as PackedFloat64Array).duplicate()
	if p.size() % 3 != 0:
		p.resize(p.size() - p.size() % 3)
	var nV := p.size() / 3
	var counts: PackedInt32Array = c.get("face_counts", PackedInt32Array())
	var idx: PackedInt32Array = c.get("face_indices", PackedInt32Array())
	var faces: Array = []
	var o := 0
	for f in counts.size():
		var n := counts[f]
		var poly := PackedInt32Array()
		var bad := false
		for k in n:
			var at := o + k
			if at >= idx.size() or idx[at] < 0 or idx[at] >= nV:
				bad = true
				break
			poly.append(idx[at])
		o += n
		if bad:
			info.degenerate += 1
			continue
		faces.append(poly)
	faces = _clean_faces(p, faces, diag, info, markers)
	# Coincident vertices.
	var grid := _Grid.new(p, tol)
	var parent := _range(nV)
	for v in nV:
		for w in grid.near(p[3 * v], p[3 * v + 1], p[3 * v + 2], tol):
			if w != v:
				var a := CAGE._find(parent, v)
				var b := CAGE._find(parent, w)
				if a != b:
					parent[maxi(a, b)] = mini(a, b)
					info.welded += 1
	if int(info.welded) > 0:
		for i in faces.size():
			var poly: PackedInt32Array = faces[i]
			for k in poly.size():
				poly[k] = CAGE._find(parent, poly[k])
			faces[i] = poly
		faces = _clean_faces(p, faces, diag, info, markers)
	# T-junctions: a vertex inside a boundary edge of a face it isn't in.
	faces = _zip_t_junctions(p, faces, tol, info, markers)
	# Non-manifold edges: faces past the second get their own copies of the edge's ends.
	var uses := {}
	for i in faces.size():
		var poly: PackedInt32Array = faces[i]
		for k in poly.size():
			var key := CAGE.edge_key(poly[k], poly[(k + 1) % poly.size()])
			if not uses.has(key):
				uses[key] = []
			(uses[key] as Array).append(i)
	for key in uses:
		var list: Array = uses[key]
		if list.size() <= 2:
			continue
		info.non_manifold += 1
		var a: int = key >> 32
		var b: int = key & 0xFFFFFFFF
		markers.append({"severity": "error", "label": "Non-manifold edge", "position": Vector3((p[3 * a] + p[3 * b]) * 0.5, (p[3 * a + 1] + p[3 * b + 1]) * 0.5, (p[3 * a + 2] + p[3 * b + 2]) * 0.5)})
		for j in range(2, list.size()):
			var fi: int = list[j]
			var poly: PackedInt32Array = faces[fi]
			for k in poly.size():
				if poly[k] == a or poly[k] == b:
					var src := poly[k]
					poly[k] = p.size() / 3
					p.append(p[3 * src])
					p.append(p[3 * src + 1])
					p.append(p[3 * src + 2])
			faces[fi] = poly
	var base := CAGE.copy(c)
	base.positions = p
	for key in ["corners", "corner_weights", "frozen", "sym_isolated", "crease_edges", "crease_weights"]:
		if not base.has(key):
			base[key] = CAGE.empty()[key]
	var before_creases := (c.get("crease_weights", PackedFloat32Array()) as PackedFloat32Array).size()
	var cleaned := _clean_lists(base, p.size() / 3)
	var out := CAGE._assemble(cleaned, p, faces)
	var orient := CAGE.orient_consistently(out)
	out = orient.cage
	info.flipped = (orient.flipped as PackedInt32Array).size()
	var ot := CAGE.topology(out)
	for f in orient.flipped:
		if f < ot.nF:
			markers.append({"severity": "error", "label": "Flipped face", "position": CAGE._centroid(out.positions, ot.face_verts(f))})
	if orient.error != "":
		warnings.append(orient.error)
	var comp := CAGE.compact(out)
	out = comp.cage
	info.unused = CAGE.vertex_count(cleaned) - CAGE.vertex_count(out)
	info.creases_removed = maxi(0, before_creases - (out.crease_weights as PackedFloat32Array).size())
	if _has_symmetry(out):
		var r := rebuild_symmetry(out, 0.0)
		var kept: Array = []
		for e in (r.cage.symmetry as Array):
			var em: PackedInt32Array = e.map
			if em.has(-1) and not bool(e.get("open", false)):
				info.symmetry_dropped += 1
				continue
			kept.append(e)
		out = r.cage
		out.symmetry = kept
		if int(info.symmetry_dropped) > 0:
			warnings.append("%d symmetries no longer fit and were removed" % info.symmetry_dropped)
	if bool(opts.get("merge_triangles", false)):
		var mr := CAGE.merge_triangle_pairs(out)
		out = mr.cage
		info.triangles_merged = mr.merged
	_shape_markers(out, markers)
	info.markers = markers
	if str(opts.get("mode", "fix")).to_lower() == "report":
		return _done(CAGE.copy(c), _sel(), warnings, info)
	return _ok(c, out, _sel(), warnings, info)


## Collapses repeated corners; drops faces with fewer than three distinct corners or no area,
## and duplicate faces.
static func _clean_faces(p: PackedFloat64Array, faces: Array, diag: float, info: Dictionary, markers: Array) -> Array:
	var out: Array = []
	var seen := {}
	var min_area := 1e-12 * diag * diag
	for poly0 in faces:
		var poly := PackedInt32Array()
		for v in poly0:
			if poly.is_empty() or poly[poly.size() - 1] != v:
				poly.append(v)
		while poly.size() > 1 and poly[0] == poly[poly.size() - 1]:
			poly.resize(poly.size() - 1)
		var sorted := poly.duplicate()
		sorted.sort()
		var distinct := poly.size() >= 3
		for k in range(1, sorted.size()):
			if sorted[k] == sorted[k - 1]:
				distinct = false
		var area := 0.0
		if distinct:
			var nx := 0.0
			var ny := 0.0
			var nz := 0.0
			var n := poly.size()
			for k in n:
				var a := 3 * poly[k]
				var b := 3 * poly[(k + 1) % n]
				nx += (p[a + 1] - p[b + 1]) * (p[a + 2] + p[b + 2])
				ny += (p[a + 2] - p[b + 2]) * (p[a] + p[b])
				nz += (p[a] - p[b]) * (p[a + 1] + p[b + 1])
			area = 0.5 * sqrt(nx * nx + ny * ny + nz * nz)
		if not distinct or area <= min_area:
			info.degenerate += 1
			if not (poly0 as PackedInt32Array).is_empty():
				markers.append({"severity": "error", "label": "Degenerate face", "position": CAGE._centroid(p, poly0)})
			continue
		var key := str(sorted)
		if seen.has(key):
			info.duplicate += 1
			continue
		seen[key] = true
		out.append(poly)
	return out


static func _zip_t_junctions(p: PackedFloat64Array, faces: Array, tol: float, info: Dictionary, markers: Array) -> Array:
	var uses := {}
	for poly in faces:
		var n := (poly as PackedInt32Array).size()
		for k in n:
			var key := CAGE.edge_key(poly[k], poly[(k + 1) % n])
			uses[key] = int(uses.get(key, 0)) + 1
	var bverts := {}
	for key in uses:
		if int(uses[key]) == 1:
			bverts[key >> 32] = true
			bverts[key & 0xFFFFFFFF] = true
	if bverts.is_empty():
		return faces
	var list := PackedInt32Array(bverts.keys())
	var out: Array = []
	for poly0 in faces:
		var poly: PackedInt32Array = poly0
		var n := poly.size()
		var res := PackedInt32Array()
		for k in n:
			var a := poly[k]
			var b := poly[(k + 1) % n]
			res.append(a)
			if int(uses.get(CAGE.edge_key(a, b), 0)) != 1:
				continue
			var ex := p[3 * b] - p[3 * a]
			var ey := p[3 * b + 1] - p[3 * a + 1]
			var ez := p[3 * b + 2] - p[3 * a + 2]
			var l2 := ex * ex + ey * ey + ez * ez
			if l2 <= tol * tol:
				continue
			var hits: Array = []
			for v in list:
				if v == a or v == b or poly.has(v):
					continue
				var dx := p[3 * v] - p[3 * a]
				var dy := p[3 * v + 1] - p[3 * a + 1]
				var dz := p[3 * v + 2] - p[3 * a + 2]
				var t := (dx * ex + dy * ey + dz * ez) / l2
				if t <= 1e-9 or t >= 1.0 - 1e-9:
					continue
				var qx := dx - t * ex
				var qy := dy - t * ey
				var qz := dz - t * ez
				if qx * qx + qy * qy + qz * qz <= tol * tol:
					hits.append([t, v])
			if hits.is_empty():
				continue
			hits.sort_custom(func(x, y) -> bool: return float(x[0]) < float(y[0]))
			for hit in hits:
				res.append(int(hit[1]))
				info.t_junctions += 1
				var hv: int = hit[1]
				markers.append({"severity": "warning", "label": "T-junction", "position": Vector3(p[3 * hv], p[3 * hv + 1], p[3 * hv + 2])})
		out.append(res)
	return out


## Corners, frozen and isolated lists sorted, unique and in range.
static func _clean_lists(c: Dictionary, nV: int) -> Dictionary:
	var out := CAGE.copy(c)
	for key in ["frozen", "sym_isolated"]:
		var keep := PackedInt32Array()
		for v in (out[key] as PackedInt32Array):
			if v >= 0 and v < nV:
				keep.append(v)
		out[key] = CAGE.sorted_unique(keep)
	var corners := {}
	var cv: PackedInt32Array = out.corners
	var cw: PackedFloat32Array = out.corner_weights
	for i in cv.size():
		if cv[i] >= 0 and cv[i] < nV:
			corners[cv[i]] = cw[i] if i < cw.size() and cw[i] > 0.0 else CAGE.SHARP
	CAGE._store_corners(out, corners)
	var creases := {}
	var ce: PackedInt32Array = out.crease_edges
	var cwe: PackedFloat32Array = out.crease_weights
	for i in mini(cwe.size(), ce.size() / 2):
		var a := ce[2 * i]
		var b := ce[2 * i + 1]
		if a >= 0 and b >= 0 and a < nV and b < nV and a != b and cwe[i] > 0.0:
			creases[CAGE.edge_key(a, b)] = cwe[i]
	CAGE._store_creases(out, creases)
	return out


## Warnings for star points, triangles and n-gons, and info markers for poles.
static func _shape_markers(c: Dictionary, markers: Array) -> void:
	var t := CAGE.topology(c)
	var p: PackedFloat64Array = c.positions
	for f in t.nF:
		var n := t.face_size(f)
		if n == 3:
			markers.append({"severity": "warning", "label": "Triangle", "position": CAGE._centroid(p, t.face_verts(f))})
		elif n > 4:
			markers.append({"severity": "warning", "label": "N-gon (%d)" % n, "position": CAGE._centroid(p, t.face_verts(f))})
	for v in t.nV:
		if t.is_boundary_vertex(v):
			continue
		var val := t.valence(v)
		if val == 4 or val == 0:
			continue
		var all_tri := true
		for f in t.vertex_faces(v):
			if t.face_size(f) != 3:
				all_tri = false
				break
		var pos := Vector3(p[3 * v], p[3 * v + 1], p[3 * v + 2])
		if all_tri and val >= 3:
			markers.append({"severity": "info", "label": "Pole", "position": pos})
		else:
			markers.append({"severity": "warning", "label": "Star point (valence %d)" % val, "position": pos})


# ---------------------------------------------------------------------------------------------
# Topology tools wired by Stage 3 (pure parts)
# ---------------------------------------------------------------------------------------------

## Bridge: side one = sel.faces (a region, removed) or sel.edges (a boundary chain or loop);
## side two = sel.faces2 or sel.edges2. opts: "segments" (1), "twist" (0), "flip1" / "flip2"
## (turn that side's body over first; it must be a separate body), "keep_creases" (on; off
## clears the rims' creases). Partner bridges are made too.
static func bridge(c: Dictionary, sel: Dictionary, opts: Dictionary) -> Dictionary:
	var f1 := _list(sel, "faces")
	var e1 := _list(sel, "edges")
	var f2 := _list(sel, "faces2")
	var e2 := _list(sel, "edges2")
	if (f1.is_empty() and e1.is_empty()) or (f2.is_empty() and e2.is_empty()):
		return _err(c, "Pick two sides to bridge.")
	var work := CAGE.copy(c)
	var topo := CAGE.topology(work)
	var locked := locked_set(work)
	var warnings := PackedStringArray()
	# Flip a side's body when asked.
	for k in 2:
		if not bool(opts.get("flip%d" % (k + 1), false)):
			continue
		var fs := f1 if k == 0 else f2
		var es := e1 if k == 0 else e2
		var other_fs := f2 if k == 0 else f1
		var other_es := e2 if k == 0 else e1
		var comp := _component_of(topo, fs, es)
		var other := _component_of(topo, other_fs, other_es)
		if comp < 0 or comp == other:
			return _err(c, "Flip Direction needs the sides on separate bodies.")
		work = CAGE.flip_faces(work, topo.component_faces(comp)).cage
		topo = CAGE.topology(work)
	# The pairs of sides: the picked one and its symmetry images.
	var sides: Array = [[_side_loop(topo, f1, e1), _side_loop(topo, f2, e2), f1, f2]]
	for s in sides[0].slice(0, 2):
		if (s as Dictionary).has("error"):
			return _err(c, s.error)
	for v in (sides[0][0].loop as PackedInt32Array):
		if (sides[0][1].loop as PackedInt32Array).has(v):
			return _err(c, "The two sides touch; pick sides apart from each other.")
	if _has_symmetry(work):
		var ctx := _sym_ctx(work)
		var l1: PackedInt32Array = sides[0][0].loop
		var l2: PackedInt32Array = sides[0][1].loop
		var tuple := l1 + l2
		var r := _images(ctx, tuple)
		var seen := {str(CAGE.sorted_unique(tuple)): true}
		var taken := {}
		for v in tuple:
			taken[v] = true
		if r.broken:
			warnings.append(BROKEN_PARTNERS)
		for k in range(1, (r.images as Array).size()):
			var img: PackedInt32Array = r.images[k]
			var key := str(CAGE.sorted_unique(img))
			if seen.has(key):
				continue
			seen[key] = true
			# A partner bridge touching one already made (a side next to its own mirror image)
			# would merge their holes: leave it out.
			var touches := false
			for v in img:
				if taken.has(v):
					touches = true
					break
			if touches:
				if not warnings.has(BROKEN_PARTNERS):
					warnings.append(BROKEN_PARTNERS)
				continue
			for v in img:
				taken[v] = true
			var pf1 := PackedInt32Array()
			var pf2 := PackedInt32Array()
			for f in f1:
				var g := topo.face_by_vertices(_map_tuple(ctx, img, tuple, topo.face_verts(f)))
				if g >= 0:
					pf1.append(g)
			for f in f2:
				var g := topo.face_by_vertices(_map_tuple(ctx, img, tuple, topo.face_verts(f)))
				if g >= 0:
					pf2.append(g)
			var s1: Dictionary = sides[0][0].duplicate()
			var s2: Dictionary = sides[0][1].duplicate()
			s1.loop = img.slice(0, l1.size())
			s2.loop = img.slice(l1.size())
			# The partner's tangents come from its own faces (mirrored), not the picked side's.
			for pair in [[s1, pf1], [s2, pf2]]:
				var side: Dictionary = pair[0]
				var pf: PackedInt32Array = pair[1]
				if side.has("normal") and not pf.is_empty():
					var nsum := Vector3.ZERO
					for g in pf:
						nsum += topo.face_area_vector(work, g).normalized()
					side.normal = nsum.normalized()
			sides.append([s1, s2, pf1, pf2])
	var removed := PackedInt32Array()
	for s in sides:
		removed.append_array(s[2])
		removed.append_array(s[3])
		for k in 2:
			if _any_locked(locked, s[k].loop):
				return _err(c, CAGE.FROZEN_ERROR)
	if _faces_locked(topo, locked, removed):
		return _err(c, CAGE.FROZEN_ERROR)
	var vmap := PackedInt32Array()
	if not removed.is_empty():
		var r := CAGE.delete_faces(work, CAGE.sorted_unique(removed))
		if r.error != "":
			return _err(c, r.error)
		work = r.cage
		vmap = r.vertex_map
	var new_vertices := PackedInt32Array()
	var new_faces := PackedInt32Array()
	var first_a := PackedInt32Array()
	var first_b := PackedInt32Array()
	var first_pair := Vector2i(-1, -1)
	for s in sides:
		var la := _remap_list(vmap, s[0].loop)
		var lb := _remap_list(vmap, s[1].loop)
		var bopts := {"closed": bool(s[0].closed) and bool(s[1].closed)}
		if first_pair.x >= 0:
			# Partners copy the picked bridge's alignment, so their rings mirror its rings.
			var i := first_a.find(first_pair.x)
			var j := first_b.find(first_pair.y)
			if i >= 0 and j >= 0:
				bopts.pair = Vector2i(la[i], lb[j])
		if s[0].has("normal"):
			bopts.n1 = s[0].normal
		if s[1].has("normal"):
			bopts.n2 = s[1].normal
		if bool(s[0].closed) != bool(s[1].closed):
			return _err(c, "Both sides must be loops, or both open chains.")
		var r := CAGE.bridge_loops(work, la, lb, int(opts.get("segments", 1)), int(opts.get("twist", 0)), bopts)
		if r.error != "":
			return _err(c, r.error)
		if first_pair.x < 0:
			first_pair = r.pair
			first_a = la
			first_b = lb
		work = r.cage
		new_vertices.append_array(r.new_vertices)
		new_faces.append_array(r.new_faces)
		if not bool(opts.get("keep_creases", true)):
			for loop in [la, lb]:
				var n: int = loop.size()
				for k in n:
					CAGE.set_crease(work, loop[k], loop[(k + 1) % n], 0.0)
	work = _resym(work, new_vertices, warnings)
	return _ok(c, work, _sel(PackedInt32Array(), PackedInt32Array(), new_faces), warnings, {"new_vertices": new_vertices})


## The image of `part` (a tuple of vertices found in `tuple`) in `img`.
static func _map_tuple(_ctx: Dictionary, img: PackedInt32Array, tuple: PackedInt32Array, part: PackedInt32Array) -> PackedInt32Array:
	var out := PackedInt32Array()
	for v in part:
		var i := tuple.find(v)
		out.append(img[i] if i >= 0 else -1)
	return out


static func _remap_list(vmap: PackedInt32Array, list: PackedInt32Array) -> PackedInt32Array:
	if vmap.is_empty():
		return list
	var out := PackedInt32Array()
	for v in list:
		out.append(vmap[v])
	return out


static func _component_of(topo: CAGE.Topo, faces: PackedInt32Array, pairs: PackedInt32Array) -> int:
	var comps := topo.components()
	if not faces.is_empty():
		return comps[faces[0]]
	if pairs.size() >= 2:
		var e := topo.edge_index(pairs[0], pairs[1])
		if e >= 0:
			return comps[topo.he_face[topo.edge_he[e]]]
	return -1


## A bridge side as {"loop", "closed", "normal"?} (or {"error"}): a face region's boundary
## (one loop; normal = the mean face normal) or a boundary edge chain / loop.
static func _side_loop(topo: CAGE.Topo, faces: PackedInt32Array, pairs: PackedInt32Array) -> Dictionary:
	if not faces.is_empty():
		var region := {}
		for f in faces:
			region[f] = true
		var next_of := {}
		var n_sum := Vector3.ZERO
		var pos := {"positions": topo.positions}
		for f in faces:
			n_sum += topo.face_area_vector(pos, f).normalized()
			for h in range(topo.face_offsets[f], topo.face_offsets[f + 1]):
				var t := topo.he_twin[h]
				if t >= 0 and region.has(topo.he_face[t]):
					continue
				if t < 0:
					return {"error": "A side of faces must be surrounded by other faces."}
				var a := topo.face_indices[h]
				if next_of.has(a):
					return {"error": "Each side of faces must have a single border."}
				next_of[a] = topo.he_dest(h)
		if next_of.is_empty():
			return {"error": "A side of faces must have a border."}
		var start: int = next_of.keys()[0]
		var loop := PackedInt32Array()
		var v := start
		var guard := next_of.size() + 1
		while guard > 0:
			guard -= 1
			loop.append(v)
			v = next_of[v]
			if v == start:
				break
		if loop.size() != next_of.size():
			return {"error": "Each side of faces must have a single border."}
		return {"loop": loop, "closed": true, "faces": faces, "normal": n_sum.normalized()}
	var chain := _chain_from_pairs(topo, pairs)
	if chain.is_empty():
		return {"error": "Each side must be a connected run of open boundary edges."}
	for i in pairs.size() / 2:
		var e := topo.edge_index(pairs[2 * i], pairs[2 * i + 1])
		if e < 0 or topo.edge_uses[e] != 1:
			return {"error": "Each side must be a connected run of open boundary edges."}
	return chain


## Orders vertex pairs into {"loop": vertices, "closed": bool} ({} when not one simple chain).
static func _chain_from_pairs(topo: CAGE.Topo, pairs: PackedInt32Array) -> Dictionary:
	var at := {}
	var count := pairs.size() / 2
	if count == 0:
		return {}
	for i in count:
		for v in [pairs[2 * i], pairs[2 * i + 1]]:
			if not at.has(v):
				at[v] = []
			(at[v] as Array).append(i)
	var start := pairs[0]
	for v in at:
		if (at[v] as Array).size() > 2:
			return {}
		if (at[v] as Array).size() == 1:
			start = v
	var closed := true
	for v in at:
		if (at[v] as Array).size() == 1:
			closed = false
	var used := {}
	var loop := PackedInt32Array([start])
	var cur := start
	var guard := count + 1
	while guard > 0:
		guard -= 1
		var nxt_i := -1
		for i in at[cur]:
			if not used.has(i):
				nxt_i = i
				break
		if nxt_i < 0:
			break
		used[nxt_i] = true
		var nxt := pairs[2 * nxt_i + 1] if pairs[2 * nxt_i] == cur else pairs[2 * nxt_i]
		if closed and nxt == start:
			break
		loop.append(nxt)
		cur = nxt
	if used.size() != count:
		return {}
	return {"loop": loop, "closed": closed}


## Merge Edge: group one (sel.edges, a boundary chain) moves onto group two (sel.edges2) and
## welds to it, vertex pairs taken in the direction with the smaller total distance. Group one's
## body is turned over first when the two would face opposite ways (it must be a separate body).
## opts.keep_creases (on): seam edges are creased when either side was.
static func merge_edge(c: Dictionary, sel: Dictionary, opts: Dictionary) -> Dictionary:
	var g1 := _list(sel, "edges")
	var g2 := _list(sel, "edges2")
	if g1.is_empty() or g2.is_empty():
		return _err(c, "Pick two groups of open boundary edges.")
	if g1.size() != g2.size():
		return _err(c, "Both groups need the same number of edges")
	var work := CAGE.copy(c)
	var topo := CAGE.topology(work)
	var c1 := _side_loop(topo, PackedInt32Array(), g1)
	var c2 := _side_loop(topo, PackedInt32Array(), g2)
	if c1.has("error") or c2.has("error"):
		return _err(c, "Each group must be a connected run of open boundary edges.")
	if bool(c1.closed) != bool(c2.closed):
		return _err(c, "Both groups must be loops, or both open chains.")
	var l1: PackedInt32Array = c1.loop
	var l2: PackedInt32Array = c2.loop
	# The first group moves onto the second, and the second's open boundary becomes an inner edge:
	# either changes frozen geometry (Weld Vertices refuses the same).
	var locked := locked_set(c)
	if _any_locked(locked, l1) or _any_locked(locked, l2):
		return _err(c, CAGE.FROZEN_ERROR)
	var p: PackedFloat64Array = work.positions
	var n := l1.size()
	var best := INF
	var pairing := PackedInt32Array()
	for dir in [1, -1]:
		for rot in (n if bool(c1.closed) else 1):
			var cand := PackedInt32Array()
			var total := 0.0
			for i in n:
				var j: int = ((rot + dir * i) % n + n) % n if bool(c1.closed) else (i if dir == 1 else n - 1 - i)
				cand.append(l2[j])
				total += CAGE._dist(p, l1[i], l2[j])
			if total < best - 1e-15:
				best = total
				pairing = cand
	# Orientation: welded faces must run the seam opposite ways.
	var m := (n if bool(c1.closed) else n - 1)
	var h1 := topo.half_edge(l1[0], l1[1 % n])
	var h2 := topo.half_edge(pairing[0], pairing[1 % n])
	if m > 0 and h1 >= 0 and h2 >= 0:
		var comp1 := _component_of(topo, PackedInt32Array(), PackedInt32Array([l1[0], l1[1 % n]]))
		var comp2 := _component_of(topo, PackedInt32Array(), PackedInt32Array([pairing[0], pairing[1 % n]]))
		if comp1 == comp2:
			return _err(c, "Those edges face opposite ways on one body, so they can't be merged.")
		work = CAGE.flip_faces(work, topo.component_faces(comp1)).cage
		p = work.positions
	var creases := CAGE.crease_map(work)
	var seam_crease := {}
	for i in m:
		var a := l1[i]
		var b := l1[(i + 1) % n]
		var a2 := pairing[i]
		var b2 := pairing[(i + 1) % n]
		var w := maxf(float(creases.get(CAGE.edge_key(a, b), 0.0)), float(creases.get(CAGE.edge_key(a2, b2), 0.0)))
		seam_crease[CAGE.edge_key(a2, b2)] = w
	var weld_pairs: Array = []
	for i in n:
		var v := l1[i]
		var w := pairing[i]
		for k in 3:
			p[3 * v + k] = p[3 * w + k]
		weld_pairs.append(Vector2i(w, v))
	work.positions = p
	var r := CAGE.weld(work, weld_pairs)
	if r.error != "":
		return _err(c, r.error)
	var out: Dictionary = r.cage
	var welded: PackedInt32Array = r.welded
	var keep := bool(opts.get("keep_creases", true))
	for key in seam_crease:
		var a: int = welded[key >> 32]
		var b: int = welded[key & 0xFFFFFFFF]
		var w: float = seam_crease[key]
		CAGE.set_crease(out, a, b, w if keep and w > 0.0 else 0.0)
	var warnings := PackedStringArray()
	out = _resym(out, PackedInt32Array(), warnings)
	return _ok(c, out, _sel(), warnings, {"vertex_map": welded})


## Weld Vertices: opts "mode" "vertex" (sel.vertices [first, second]: the first moves onto the
## second) | "midpoint" (both move to the middle) | "tolerance" (clusters of selected vertices,
## or all when none, within opts.tolerance merge at their average); "keep_creases" (on).
## Partners weld too. Refused when an edge would get three faces.
static func weld_vertices(c: Dictionary, sel: Dictionary, opts: Dictionary) -> Dictionary:
	var mode := str(opts.get("mode", "vertex")).to_lower()
	var verts := _list(sel, "vertices")
	var p: PackedFloat64Array = c.positions
	var np := p.duplicate()
	var nV := CAGE.vertex_count(c)
	var groups: Array = []
	if mode.begins_with("tol"):
		var tol := float(opts.get("tolerance", 0.01 * CAGE.mean_edge_length(c)))
		var pool := verts if not verts.is_empty() else _range(nV)
		var sub := PackedFloat64Array()
		for v in pool:
			sub.append_array(PackedFloat64Array([p[3 * v], p[3 * v + 1], p[3 * v + 2]]))
		var grid := _Grid.new(sub, tol)
		var parent := _range(pool.size())
		for i in pool.size():
			for j in grid.near(sub[3 * i], sub[3 * i + 1], sub[3 * i + 2], tol):
				if j != i:
					var a := CAGE._find(parent, i)
					var b := CAGE._find(parent, j)
					if a != b:
						parent[maxi(a, b)] = mini(a, b)
		var by_root := {}
		for i in pool.size():
			var r := CAGE._find(parent, i)
			if not by_root.has(r):
				by_root[r] = PackedInt32Array()
			var g: PackedInt32Array = by_root[r]
			g.append(pool[i])
			by_root[r] = g
		for r in by_root:
			if (by_root[r] as PackedInt32Array).size() > 1:
				groups.append(by_root[r])
		if groups.is_empty():
			return _err(c, "No vertices lie within the weld tolerance.")
	else:
		if verts.size() != 2:
			return _err(c, "Pick two vertices to weld.")
		groups.append(PackedInt32Array([verts[1], verts[0]]))
	var warnings := PackedStringArray()
	if _has_symmetry(c):
		var ctx := _sym_ctx(c)
		var more: Array = []
		var seen := {}
		for g in groups:
			seen[str(CAGE.sorted_unique(g))] = true
		for g in groups:
			var r := _images(ctx, g)
			if r.broken:
				warnings.append(BROKEN_PARTNERS)
			for img in r.images:
				var key := str(CAGE.sorted_unique(img))
				if not seen.has(key):
					seen[key] = true
					more.append(img)
		groups.append_array(more)
	var locked := locked_set(c)
	for g in groups:
		if _any_locked(locked, g):
			return _err(c, CAGE.FROZEN_ERROR)
	var pairs: Array = []
	for g0 in groups:
		var g: PackedInt32Array = g0
		var keep := g[0]
		if mode.begins_with("tol") or mode.begins_with("mid"):
			var x := 0.0
			var y := 0.0
			var z := 0.0
			for v in g:
				x += p[3 * v]
				y += p[3 * v + 1]
				z += p[3 * v + 2]
			np[3 * keep] = x / g.size()
			np[3 * keep + 1] = y / g.size()
			np[3 * keep + 2] = z / g.size()
		for k in range(1, g.size()):
			pairs.append(Vector2i(keep, g[k]))
	var work := CAGE.copy(c)
	work.positions = np
	var r := CAGE.weld(work, pairs)
	if r.error != "":
		return _err(c, r.error)
	var out: Dictionary = r.cage
	if int(r.misoriented) > 0:
		var o := CAGE.orient_consistently(out)
		if o.error != "":
			return _err(c, "Welding these vertices would join faces that face opposite ways.")
		out = o.cage
		warnings.append("Some faces were turned over to match")
	if not bool(opts.get("keep_creases", true)):
		var welded: PackedInt32Array = r.welded
		var moved := {}
		for pr in pairs:
			moved[welded[pr.x]] = true
		var cm := CAGE.crease_map(out)
		for key in cm.keys():
			if moved.has(key >> 32) or moved.has(key & 0xFFFFFFFF):
				cm.erase(key)
		CAGE._store_creases(out, cm)
	out = _resym(out, PackedInt32Array(), warnings)
	return _ok(c, out, _sel(), warnings, {"vertex_map": r.welded, "welded": pairs.size()})


## Erase and Fill: deletes the picked faces (partners too) and fills every hole the deletion
## made (holes that were already open stay open). opts.mode "reduced" | "star".
static func erase_and_fill(c: Dictionary, sel: Dictionary, opts: Dictionary) -> Dictionary:
	var faces := _list(sel, "faces")
	if faces.is_empty():
		return _err(c, "Pick faces to erase.")
	var warnings := PackedStringArray()
	if _has_symmetry(c):
		var ps := partner_selection(c, _sel(PackedInt32Array(), PackedInt32Array(), faces))
		faces = ps.faces
		warnings.append_array(ps.warnings)
	var topo := CAGE.topology(c)
	var locked := locked_set(c)
	if _faces_locked(topo, locked, faces):
		return _err(c, CAGE.FROZEN_ERROR)
	var old_boundary := {}
	for e in topo.nE:
		if topo.edge_uses[e] == 1:
			old_boundary[CAGE.edge_key(topo.edges[2 * e], topo.edges[2 * e + 1])] = true
	var r := CAGE.delete_faces(c, faces)
	if r.error != "":
		return _err(c, r.error)
	var out: Dictionary = r.cage
	var vmap: PackedInt32Array = r.vertex_map
	var inv := PackedInt32Array()
	inv.resize(CAGE.vertex_count(out))
	for v in vmap.size():
		if vmap[v] >= 0:
			inv[vmap[v]] = v
	if vmap.is_empty():
		for v in inv.size():
			inv[v] = v
	var t2 := CAGE.topology(out)
	var mode := _fill_mode(str(opts.get("mode", "reduced")))
	var new_vertices := PackedInt32Array()
	var new_faces := PackedInt32Array()
	for loop in t2.boundary_loops():
		var lp: PackedInt32Array = loop
		# Only holes the deletion made on its own: none of their edges was open before.
		var fresh := true
		for k in lp.size():
			var key := CAGE.edge_key(inv[lp[k]], inv[lp[(k + 1) % lp.size()]])
			if old_boundary.has(key):
				fresh = false
				break
		if not fresh:
			continue
		var fr := CAGE.fill_hole(out, lp, mode)
		if fr.error != "":
			return _err(c, fr.error)
		out = fr.cage
		new_vertices.append_array(fr.new_vertices)
		new_faces.append_array(fr.new_faces)
	out = _resym(out, new_vertices, warnings)
	if mode == "reduced" and _faces_lacking_partners(out, new_faces) > 0:
		var alt_opts := opts.duplicate()
		alt_opts["mode"] = "star"
		var alt := erase_and_fill(c, sel, alt_opts)
		if alt.ok:
			var aw: PackedStringArray = alt.warnings
			aw.append(REDUCED_NOT_SYMMETRIC % "one face (Fill Star)")
			alt.warnings = aw
			return alt
	return _ok(c, out, _sel(PackedInt32Array(), PackedInt32Array(), new_faces), warnings, {"new_vertices": new_vertices})


## Bevel Edge along loops through four-edge vertices. opts: "mode" "ratio" | "width", "ratio"
## (0.25), "width" (meters), "segments" 1..16 (1), "spacing" "uniform" | "parametric", "crown"
## 0..2 (1.0). Inserts loops A and B either side of the picked loop O at the ratio, then shapes
## the inner loops on P(u) = (1-u)^2 A + 2u(1-u) Q + u^2 B with Q = M + crown (O - M), M = (A+B)/2.
## The picked edges lose their crease.
static func bevel_edge(c: Dictionary, sel: Dictionary, opts: Dictionary) -> Dictionary:
	var pairs := _list(sel, "edges")
	if pairs.is_empty():
		return _err(c, "Pick edges to bevel.")
	var warnings := PackedStringArray()
	if _has_symmetry(c):
		var ps := partner_selection(c, _sel(PackedInt32Array(), pairs))
		pairs = ps.edges
		warnings.append_array(ps.warnings)
	var topo := CAGE.topology(c)
	var deg := {}
	for i in pairs.size() / 2:
		var e := topo.edge_index(pairs[2 * i], pairs[2 * i + 1])
		if e < 0 or topo.edge_uses[e] != 2:
			return _err(c, "Bevel works along edge loops through four-edge vertices")
		for v in [pairs[2 * i], pairs[2 * i + 1]]:
			deg[v] = int(deg.get(v, 0)) + 1
	for v in deg:
		if int(deg[v]) > 2 or (int(deg[v]) == 2 and not topo.is_regular(v)):
			return _err(c, "Bevel works along edge loops through four-edge vertices")
	var segments := clampi(int(opts.get("segments", 1)), 1, 16)
	var ratio := clampf(float(opts.get("ratio", 0.25)), 0.01, 0.99)
	var width_mode := str(opts.get("mode", "ratio")).to_lower() == "width"
	var iopts := {}
	if width_mode:
		var w := float(opts.get("width", -1.0))
		if w <= 0.0:
			var total := 0.0
			var cnt := 0
			for v in deg:
				for e in topo.vertex_edges(v):
					total += CAGE._dist(c.positions, topo.edges[2 * e], topo.edges[2 * e + 1])
					cnt += 1
			w = 0.25 * total / maxi(1, cnt)
		iopts.width = w * 0.5
	var locked := locked_set(c)
	var si := side_items(topo, pairs, false)
	if si.error != "":
		return _err(c, si.error)
	var items: Array = si.items
	if _faces_locked(topo, locked, _insert_faces(topo, items, true)):
		return _err(c, CAGE.FROZEN_ERROR)
	var r := CAGE.insert_edge_loop(c, items, ratio, true, iopts)
	if r.error != "":
		return _err(c, r.error)
	var out: Dictionary = r.cage
	# A (positive side) and B (other side) points for every chain vertex.
	var side_a := {}
	var side_b := {}
	var used: Array = r.items_used
	var rails: Array = r.item_vertices
	for k in used.size():
		var iv: PackedInt32Array = rails[k]
		if iv.size() < 2:
			continue
		var item: Dictionary = used[k]
		var ev: Vector2i = item.edge
		var f: int = item.side
		# Which end each rail point belongs to: ra is beside the face's corner that runs first.
		var st := topo.face_offsets[f]
		var n := topo.face_size(f)
		var first := ev.x
		for kk in n:
			var x := topo.face_indices[st + kk]
			var y := topo.face_indices[st + (kk + 1) % n]
			if (x == ev.x and y == ev.y) or (x == ev.y and y == ev.x):
				first = x
				break
		var second := ev.y if first == ev.x else ev.x
		var target := side_a if k < items.size() else side_b
		if not target.has(first):
			target[first] = iv[0]
		if not target.has(second):
			target[second] = iv[1]
	var chain_verts := PackedInt32Array(deg.keys())
	# Chain edges lose their creases.
	for i in pairs.size() / 2:
		CAGE.set_crease(out, pairs[2 * i], pairs[2 * i + 1], 0.0)
	var inner: Array = []   # inner loops from A to B: each {vertex: id}
	if segments == 1:
		var dr := CAGE.dissolve_edges(out, pairs)
		if dr.error != "":
			return _err(c, dr.error)
		out = dr.cage
		out = _resym(out, PackedInt32Array(), warnings)
		return _ok(c, out, _sel(), warnings, {})
	var o_loop := {}
	for v in chain_verts:
		o_loop[v] = v
	inner.append(o_loop)
	# More loops between O and B (each new one next to O), then place them all.
	var extra: Array = []
	for s in range(segments - 2):
		var t3 := CAGE.topology(out)
		var bitems: Array = []
		var toward: Dictionary = side_b if extra.is_empty() else extra[extra.size() - 1]
		for i in pairs.size() / 2:
			var a := pairs[2 * i]
			var b := pairs[2 * i + 1]
			var e := t3.edge_index(a, b)
			if e < 0:
				continue
			for g in t3.edge_faces(e):
				var verts := t3.face_verts(g)
				if toward.has(a) and verts.has(toward[a]) or toward.has(b) and verts.has(toward[b]):
					bitems.append({"edge": Vector2i(a, b), "side": g})
					break
		var r2 := CAGE.insert_edge_loop(out, bitems, 0.5, false)
		if r2.error != "":
			return _err(c, r2.error)
		var loop := {}
		var used2: Array = r2.items_used
		for k in used2.size():
			var iv: PackedInt32Array = r2.item_vertices[k]
			if iv.size() < 2:
				continue
			var item: Dictionary = used2[k]
			var ev: Vector2i = item.edge
			var g: int = item.side
			var st := t3.face_offsets[g]
			var n := t3.face_size(g)
			var first := ev.x
			for kk in n:
				var x := t3.face_indices[st + kk]
				var y := t3.face_indices[st + (kk + 1) % n]
				if (x == ev.x and y == ev.y) or (x == ev.y and y == ev.x):
					first = x
					break
			var second := ev.y if first == ev.x else ev.x
			if not loop.has(first):
				loop[first] = iv[0]
			if not loop.has(second):
				loop[second] = iv[1]
		extra.append(loop)
		out = r2.cage
	# Order from A: O, then the extra loops from the last made (nearest O) to the first.
	for k in range(extra.size() - 1, -1, -1):
		inner.append(extra[k])
	var crown := float(opts.get("crown", 1.0))
	var parametric := str(opts.get("spacing", "uniform")).to_lower().begins_with("param")
	var src: PackedFloat64Array = out.positions
	var np := src.duplicate()
	var moved := PackedInt32Array()
	for v in chain_verts:
		if not side_a.has(v) or not side_b.has(v):
			continue
		var ia: int = side_a[v]
		var ib: int = side_b[v]
		for i in inner.size():
			var loop: Dictionary = inner[i]
			if not loop.has(v):
				continue
			var id: int = loop[v]
			var k := i + 1
			var u := float(k) / segments
			if parametric:
				u = (1.0 - cos(PI * k / segments)) * 0.5
			for d in 3:
				var A := src[3 * ia + d]
				var B := src[3 * ib + d]
				var O := src[3 * v + d]
				var M := (A + B) * 0.5
				var Q := M + crown * (O - M)
				np[3 * id + d] = (1.0 - u) * (1.0 - u) * A + 2.0 * u * (1.0 - u) * Q + u * u * B
			moved.append(id)
	out.positions = np
	var new_v: PackedInt32Array = r.new_vertices
	out = _resym(out, new_v + moved, warnings)
	return _ok(c, out, _sel(), warnings, {})
