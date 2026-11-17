@tool
extends RefCounted
## Cage builders for the Form tools that start from curves (Stage 3, team M1): Extrude, Revolve,
## Sweep, Loft and Pipe.
##
## Curves come from picked references: a sketch profile gives its region's outer loop, sketch
## curves and model edges give themselves, sketch and origin points give loft tips. Every curve is
## an exact edge of a CadShape; gather() collects them, make_chains() joins them end to end
## (refusing branches), and resample() puts points on a chain by equal arc length ("uniform") or
## by equal steps of the integral of 1 + (L / 2 pi) |curvature| ("curvature"), always with a point
## on every sharp corner (a tangent break above CORNER_DEG).
##
## The builders turn those points into cages through grid(): rows of points (a profile copied
## along a direction, round an axis, along a path, between sections, round a pipe's path) joined
## by quads, rows that are one point (a pole) by triangles. Each returns {"ok", "error", "cage",
## "warnings", "fit": PackedInt32Array}: "fit" lists the vertices built on the curves, whose limit
## points fit_cage() can then put exactly onto their built positions ("Fit surface to curves").
## Faces are counter-clockwise seen from outside (away from the profile's middle, the axis or the
## path); creases mark the edges built from sharp corners when asked.
##
## Pure: no editor. The native kernel is reached only through the CadShapes the references
## resolve to (edge_info, edge_point_at_length) and, in fit_cage(), a CadSubD made with
## ClassDB.instantiate (skipped when the class isn't registered).

const CAGE := preload("res://addons/holo_forge/core/form/cage.gd")
const FORM_OPS := preload("res://addons/holo_forge/core/form/form_ops.gd")
const REFERENCES := preload("res://addons/holo_forge/core/references.gd")

## A tangent break above this many degrees is a sharp corner: it always gets a vertex.
const CORNER_DEG := 10.0
const BRANCHING := "Branching pipes aren't supported yet; make one pipe per branch and Bridge them"
const BRANCHING_CURVES := "The picked curves branch; pick one chain of connected curves"
## Point kinds a loft section may be (a tip).
const POINT_KINDS := ["sketch_point", "origin", "construct", "vertex"]


# ---------------------------------------------------------------------------------------------
# Curves from references
# ---------------------------------------------------------------------------------------------

## The curves and points of picked references, in pick order: {"pieces": [piece], "points":
## [{"point": Vector3, "order": int}], "warnings", "error", "holes"}. A piece is one exact edge:
## {"shape", "index", "length", "start", "end", "order" (its pick's index), "plane":
## Transform3D or null, "closed"}. ctx: what core/references.gd resolves against ("doc",
## "kernel", "sketches", "bodies", "construction").
static func gather(refs: Array, ctx: Dictionary) -> Dictionary:
	var out := {"pieces": [], "points": [], "warnings": PackedStringArray(), "error": "", "holes": 0}
	for i in refs.size():
		var ref: Variant = refs[i]
		if not ref is Dictionary:
			continue
		var kind := str((ref as Dictionary).get("kind", ""))
		match kind:
			"profile":
				var p := REFERENCES.profile(ref, ctx)
				if p.has("error"):
					out.error = str(p.error)
					return out
				var loop := _outer_loop(p.face, p.plane, i)
				if (loop.pieces as Array).is_empty():
					out.error = "The profile has no edges to follow"
					return out
				(out.pieces as Array).append_array(loop.pieces)
				out.holes = int(out.holes) + int(loop.holes)
			"sketch_curve":
				var groups := REFERENCES.curve_edges([ref], ctx)
				for group in groups:
					if (group as Dictionary).has("error"):
						out.error = str(group.error)
						return out
					var shape: RefCounted = group.edges
					var plane: Transform3D = group.plane
					for e in shape.edge_count():
						var piece := _piece(shape, e, i, plane)
						if not piece.is_empty():
							(out.pieces as Array).append(piece)
			"edge":
				var found := REFERENCES.edge(ref, ctx)
				if found.has("error"):
					out.error = str(found.error)
					return out
				var piece := _piece(found.shape, int(found.index), i, null)
				if not piece.is_empty():
					(out.pieces as Array).append(piece)
			_:
				if kind in POINT_KINDS:
					var pt := REFERENCES.point(ref, ctx)
					if pt.has("error"):
						out.error = str(pt.error)
						return out
					(out.points as Array).append({"point": pt.point, "order": i})
	if int(out.holes) > 0:
		out.warnings.append("Holes inside a profile are left out (only its outer loop is used)")
	return out


## One exact edge as a piece ({} for a degenerate edge).
static func _piece(shape: RefCounted, index: int, order: int, plane: Variant) -> Dictionary:
	var info: Dictionary = shape.edge_info(index)
	if info.is_empty() or str(info.get("type", "")) == "degenerate" or float(info.get("length", 0.0)) <= 1e-12:
		return {}
	return {"shape": shape, "index": index, "length": float(info.length), "start": info.start, "end": info.end, "order": order,
		"plane": plane, "closed": bool(info.get("closed", false))}


## A profile region's outer loop: {"pieces", "holes": how many other loops it has}.
static func _outer_loop(face: RefCounted, plane: Transform3D, order: int) -> Dictionary:
	var pieces := []
	for e in face.edge_count():
		var piece := _piece(face, e, order, plane)
		if not piece.is_empty():
			pieces.append(piece)
	var size := 0.0
	for p in pieces:
		size = maxf(size, float(p.length))
	var made := make_chains(pieces, maxf(size * 1e-7, 1e-9))
	var best: Dictionary = {}
	var best_area := -1.0
	var loops := 0
	for chain in made.chains:
		if not bool(chain.closed):
			continue
		loops += 1
		var area := absf(_chain_area(chain, plane))
		if area > best_area:
			best_area = area
			best = chain
	if best.is_empty():
		return {"pieces": [], "holes": 0}
	var out := []
	for piece in best.pieces:
		var copy: Dictionary = (piece as Dictionary).duplicate()
		copy.erase("reversed")
		# Kept in loop order (the walk's direction): make_chains walks them the same way again.
		if bool(piece.get("reversed", false)):
			var s: Vector3 = copy.start
			copy.start = copy.end
			copy.end = s
			copy["flipped"] = not bool(copy.get("flipped", false))
		out.append(copy)
	return {"pieces": out, "holes": maxi(loops - 1, 0)}


## The signed area a closed chain encloses, measured in a plane's XY.
static func _chain_area(chain: Dictionary, plane: Transform3D) -> float:
	var pts := PackedVector2Array()
	var inv := plane.affine_inverse()
	for piece in chain.pieces:
		for q in 8:
			var at := float(piece.length) * q / 8.0
			var p: Vector3 = inv * (_piece_eval(piece, at, bool(piece.get("reversed", false))).point as Vector3)
			pts.append(Vector2(p.x, p.y))
	var area := 0.0
	for i in pts.size():
		var a := pts[i]
		var b := pts[(i + 1) % pts.size()]
		area += a.x * b.y - a.y * b.x
	return area * 0.5


## A piece's point and tangent at arc length s from its start (reversed: from its end), along
## the chain's direction. A piece "flipped" by _outer_loop already runs reversed.
static func _piece_eval(piece: Dictionary, s: float, reversed: bool) -> Dictionary:
	var length := float(piece.length)
	var f := clampf(s / length, 0.0, 1.0) if length > 0.0 else 0.0
	var backwards := reversed != bool(piece.get("flipped", false))
	if backwards:
		f = 1.0 - f
	var shape: RefCounted = piece.shape
	var r: Dictionary = shape.edge_point_at_length(int(piece.index), f)
	if r.is_empty():
		return {"point": piece.start, "tangent": Vector3.ZERO}
	var t: Vector3 = r.get("tangent", Vector3.ZERO)
	return {"point": r.point, "tangent": -t if backwards else t}


## Joins pieces end to end (ends within tol meet): {"chains": [chain], "branching": bool}. A chain:
## {"pieces" (each with "reversed": walked end to start), "closed", "length", "starts":
## PackedFloat64Array (arc length where each piece starts, plus the total), "order" (its first
## pick), "plane": the pieces' common sketch plane or null}. Open chains come first, then loops.
static func make_chains(pieces: Array, tol: float) -> Dictionary:
	var nodes: Array[Vector3] = []
	var ends := []
	for piece in pieces:
		ends.append([_node(nodes, piece.start, tol), _node(nodes, piece.end, tol)])
	var degree := PackedInt32Array()
	degree.resize(nodes.size())
	var at := {}
	for i in ends.size():
		for k in 2:
			var n: int = ends[i][k]
			degree[n] += 1
			if not at.has(n):
				at[n] = []
			if not (at[n] as Array).has(i):
				(at[n] as Array).append(i)
	for d in degree:
		if d > 2:
			return {"chains": [], "branching": true}
	var used := PackedByteArray()
	used.resize(pieces.size())
	var chains := []
	for n in nodes.size():
		if degree[n] == 1:
			var chain := _walk(n, pieces, ends, at, used)
			if not (chain.pieces as Array).is_empty():
				chains.append(chain)
	for i in pieces.size():
		if used[i] == 0:
			var chain := _walk(int(ends[i][0]), pieces, ends, at, used)
			if not (chain.pieces as Array).is_empty():
				chains.append(chain)
	return {"chains": chains, "branching": false}


static func _node(nodes: Array[Vector3], p: Vector3, tol: float) -> int:
	for i in nodes.size():
		if nodes[i].distance_to(p) <= tol:
			return i
	nodes.append(p)
	return nodes.size() - 1


static func _walk(start: int, pieces: Array, ends: Array, at: Dictionary, used: PackedByteArray) -> Dictionary:
	var chain_pieces := []
	var n := start
	while true:
		var next := -1
		for i in at.get(n, []):
			if used[i] == 0:
				next = i
				break
		if next < 0:
			break
		used[next] = 1
		var reversed: bool = int(ends[next][0]) != n
		var piece: Dictionary = (pieces[next] as Dictionary).duplicate()
		piece["reversed"] = reversed
		chain_pieces.append(piece)
		n = int(ends[next][0]) if reversed else int(ends[next][1])
		if n == start:
			break
	var starts := PackedFloat64Array()
	var total := 0.0
	var order := 1 << 30
	var plane: Variant = null
	var same_plane := true
	for piece in chain_pieces:
		starts.append(total)
		total += float(piece.length)
		order = mini(order, int(piece.order))
		if piece.plane == null:
			same_plane = false
		elif plane == null:
			plane = piece.plane
		elif not (plane as Transform3D).is_equal_approx(piece.plane):
			same_plane = false
	starts.append(total)
	return {"pieces": chain_pieces, "closed": n == start and not chain_pieces.is_empty(), "length": total, "starts": starts, "order": order,
		"plane": plane if same_plane else null}


## The chains of the picked curves, in pick order: {"chains", "points", "warnings", "error",
## "branching"} (tol: how far apart two curve ends may be and still join; 0: a millionth of the
## curves' size).
static func chains_of(refs: Array, ctx: Dictionary, tol := 0.0) -> Dictionary:
	var g := gather(refs, ctx)
	if str(g.error) != "":
		return {"chains": [], "points": [], "warnings": g.warnings, "error": g.error, "branching": false}
	var size := 0.0
	for p in g.pieces:
		size += float(p.length)
	var made := make_chains(g.pieces, tol if tol > 0.0 else maxf(size * 1e-6, 1e-9))
	if bool(made.branching):
		return {"chains": [], "points": g.points, "warnings": g.warnings, "error": BRANCHING_CURVES, "branching": true}
	var chains: Array = made.chains
	chains.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.order) < int(b.order))
	return {"chains": chains, "points": g.points, "warnings": g.warnings, "error": "", "branching": false}


## A chain's point and tangent at arc length s (wrapping round a closed chain).
static func chain_point(chain: Dictionary, s: float) -> Dictionary:
	var length := float(chain.length)
	if bool(chain.closed) and length > 0.0:
		s = fposmod(s, length)
	s = clampf(s, 0.0, length)
	var starts: PackedFloat64Array = chain.starts
	var pieces: Array = chain.pieces
	var j := pieces.size() - 1
	for k in pieces.size():
		if s < starts[k + 1]:
			j = k
			break
	var piece: Dictionary = pieces[j]
	return _piece_eval(piece, s - starts[j], bool(piece.reversed))


## The best-fit plane of a chain: {"plane": Transform3D (Z its normal), "planar": bool}. A
## chain of one sketch's curves keeps that sketch's plane.
static func chain_plane(chain: Dictionary) -> Dictionary:
	if chain.plane != null:
		return {"plane": chain.plane, "planar": true}
	var pts := PackedVector3Array()
	for q in 48:
		pts.append(chain_point(chain, float(chain.length) * q / (48.0 if bool(chain.closed) else 47.0)).point)
	var fit := FORM_OPS.best_fit_plane(pts)
	var o: PackedFloat64Array = fit.origin
	var nd: PackedFloat64Array = fit.normal
	var origin := Vector3(o[0], o[1], o[2])
	var n := Vector3(nd[0], nd[1], nd[2]).normalized()
	var size := 0.0
	var worst := 0.0
	for p in pts:
		size = maxf(size, p.distance_to(origin))
		worst = maxf(worst, absf((p - origin).dot(n)))
	var x := (pts[1] - pts[0])
	x = (x - n * x.dot(n)).normalized() if (x - n * x.dot(n)).length() > 1e-12 else n.cross(Vector3.UP if absf(n.y) < 0.9 else Vector3.RIGHT).normalized()
	return {"plane": Transform3D(Basis(x, n.cross(x), n), origin), "planar": worst <= maxf(size, 1e-9) * 1e-6}


# ---------------------------------------------------------------------------------------------
# Resampling
# ---------------------------------------------------------------------------------------------

## Points along a chain with segments faces between them (closed: segments points, open:
## segments + 1), a point on every sharp corner. opts: "spacing" "uniform" | "curvature", "from" /
## "to" (an arc-length range: a partial chain, always open), "per_piece" (PackedInt32Array:
## segments per piece, Pipe's density; every piece end gets a point). Returns {"points",
## "t_in", "t_out" (tangents arriving and leaving: they differ on corners), "corners"
## (PackedByteArray), "s" (arc length of each point), "closed", "segments", "raised" (more
## segments than asked, to keep the corners)}.
static func resample(chain: Dictionary, segments: int, opts := {}) -> Dictionary:
	var length := float(chain.length)
	var pieces: Array = chain.pieces
	var starts: PackedFloat64Array = chain.starts
	var n := pieces.size()
	var from := clampf(float(opts.get("from", 0.0)), 0.0, length)
	var to := clampf(float(opts.get("to", length)), from, length)
	var partial := from > length * 1e-9 or to < length * (1.0 - 1e-9)
	var closed := bool(chain.closed) and not partial
	var curvature := str(opts.get("spacing", "uniform")) == "curvature"
	var per_piece: PackedInt32Array = opts.get("per_piece", PackedInt32Array())
	var corner_rad := deg_to_rad(float(opts.get("corner_deg", CORNER_DEG)))
	# Junctions between pieces (and the closing one of a loop) with their tangent break.
	var junctions := {}
	var count := n if bool(chain.closed) else n - 1
	for j in count:
		var a: Dictionary = pieces[j]
		var b: Dictionary = pieces[(j + 1) % n]
		var t_in: Vector3 = _piece_eval(a, float(a.length), bool(a.reversed)).tangent
		var t_out: Vector3 = _piece_eval(b, 0.0, bool(b.reversed)).tangent
		var angle := t_in.angle_to(t_out) if t_in.length() > 1e-9 and t_out.length() > 1e-9 else 0.0
		var s := starts[j + 1] if j + 1 < n else 0.0
		junctions[j + 1 if j + 1 < n else 0] = {"s": s, "corner": angle > corner_rad, "t_in": t_in, "t_out": t_out}
	# Break points (always points): corners, the ends of an open range, every piece end for Pipe.
	var breaks := []
	var whole_pieces := per_piece.size() == n and not partial
	if whole_pieces:
		for j in n:
			breaks.append({"s": starts[j], "corner": bool(junctions.get(j, {}).get("corner", false)), "junction": j})
		if not closed:
			breaks.append({"s": length, "corner": false, "junction": -1})
	else:
		if not closed:
			breaks.append({"s": from, "corner": false, "junction": 0 if from <= length * 1e-9 else -1})
		var keys := junctions.keys()
		keys.sort()
		for j in keys:
			var jn: Dictionary = junctions[j]
			if not bool(jn.corner):
				continue
			var s := float(jn.s)
			if closed or (s > from + length * 1e-9 and s < to - length * 1e-9):
				breaks.append({"s": s, "corner": true, "junction": j})
		if closed and breaks.is_empty():
			breaks.append({"s": 0.0, "corner": false, "junction": 0})
		if not closed:
			breaks.append({"s": to, "corner": false, "junction": n if to >= length * (1.0 - 1e-9) else -1})
		breaks.sort_custom(func(x: Dictionary, y: Dictionary) -> bool: return float(x.s) < float(y.s))
	# Spans between breaks (a loop's last one wraps to its first).
	var spans := []
	var span_count := breaks.size() if closed else breaks.size() - 1
	for i in span_count:
		var a := float(breaks[i].s)
		var b := float(breaks[(i + 1) % breaks.size()].s)
		if closed and i == breaks.size() - 1:
			b += length
		spans.append({"a": a, "b": b})
	if spans.is_empty():
		return {"points": PackedVector3Array(), "t_in": PackedVector3Array(), "t_out": PackedVector3Array(), "corners": PackedByteArray(),
			"s": PackedFloat64Array(), "closed": closed, "segments": 0, "raised": false}
	# Each span's weight: its length, plus (L / 2 pi) times how much it turns for curvature spacing.
	var tables := []
	var weights := PackedFloat64Array()
	for span in spans:
		var table := _span_table(chain, float(span.a), float(span.b), length, curvature)
		tables.append(table)
		var w: PackedFloat64Array = table.w
		weights.append(w[w.size() - 1])
	var counts := PackedInt32Array()
	var raised := false
	if whole_pieces:
		for j in spans.size():
			counts.append(maxi(1, per_piece[j]))
	else:
		var total := segments
		if total < spans.size():
			total = spans.size()
			raised = true
		counts = _allocate(weights, total)
	var points := PackedVector3Array()
	var t_in := PackedVector3Array()
	var t_out := PackedVector3Array()
	var corners := PackedByteArray()
	var arc := PackedFloat64Array()
	var total_segments := 0
	for i in spans.size():
		var c := counts[i]
		total_segments += c
		var table: Dictionary = tables[i]
		var w: PackedFloat64Array = table.w
		var ss: PackedFloat64Array = table.s
		for q in c:
			var s := float(spans[i].a)
			if q > 0:
				s = _invert(ss, w, w[w.size() - 1] * q / c)
			var br: Dictionary = breaks[i] if q == 0 else {}
			_emit(chain, s, br, junctions, points, t_in, t_out, corners, arc)
	if not closed:
		_emit(chain, float(breaks[breaks.size() - 1].s), breaks[breaks.size() - 1], junctions, points, t_in, t_out, corners, arc)
	return {"points": points, "t_in": t_in, "t_out": t_out, "corners": corners, "s": arc, "closed": closed, "segments": total_segments,
		"raised": raised}


## One resampled point at arc length s (br: the break it sits on, {} when none).
static func _emit(chain: Dictionary, s: float, br: Dictionary, junctions: Dictionary, points: PackedVector3Array, t_in: PackedVector3Array,
		t_out: PackedVector3Array, corners: PackedByteArray, arc: PackedFloat64Array) -> void:
	var length := float(chain.length)
	var at := chain_point(chain, s)
	var tin: Vector3 = at.tangent
	var tout: Vector3 = at.tangent
	var corner := false
	if not br.is_empty() and junctions.has(int(br.get("junction", -1))):
		var jn: Dictionary = junctions[int(br.junction)]
		tin = jn.t_in
		tout = jn.t_out
		corner = bool(br.corner)
	elif not br.is_empty() and float(br.s) >= length * (1.0 - 1e-9) and not bool(chain.closed):
		# The open end: the last piece's end tangent.
		var last: Dictionary = (chain.pieces as Array).back()
		tin = _piece_eval(last, float(last.length), bool(last.reversed)).tangent
		tout = tin
	points.append(at.point)
	t_in.append(tin.normalized())
	t_out.append(tout.normalized())
	corners.append(1 if corner else 0)
	arc.append(fposmod(s, length) if bool(chain.closed) and length > 0.0 else s)


## A span's cumulative weight table: {"s": arc lengths, "w": weights from the span's start}.
static func _span_table(chain: Dictionary, a: float, b: float, length: float, curvature: bool) -> Dictionary:
	if not curvature:
		return {"s": PackedFloat64Array([a, b]), "w": PackedFloat64Array([0.0, b - a])}
	var steps := clampi(ceili((b - a) / maxf(length, 1e-12) * 160.0), 8, 160)
	var ss := PackedFloat64Array()
	var ww := PackedFloat64Array()
	var inset := (b - a) * 1e-6
	var previous := Vector3.ZERO
	var w := 0.0
	var scale := length / TAU
	for q in steps + 1:
		var s := lerpf(a + inset, b - inset, float(q) / steps)
		var t: Vector3 = chain_point(chain, s).tangent
		if q > 0:
			w += (s - ss[q - 1])
			if previous.length() > 1e-9 and t.length() > 1e-9:
				w += scale * previous.angle_to(t)
		ss.append(s)
		ww.append(w)
		previous = t
	ss[0] = a
	ss[steps] = b
	return {"s": ss, "w": ww}


## The arc length where a span's weight reaches target (linear between table entries).
static func _invert(ss: PackedFloat64Array, ww: PackedFloat64Array, target: float) -> float:
	for q in range(1, ww.size()):
		if ww[q] >= target:
			var span := ww[q] - ww[q - 1]
			var f := (target - ww[q - 1]) / span if span > 0.0 else 0.0
			return lerpf(ss[q - 1], ss[q], f)
	return ss[ss.size() - 1]


## total split into one count per weight (each at least 1), by largest remainders.
static func _allocate(weights: PackedFloat64Array, total: int) -> PackedInt32Array:
	var n := weights.size()
	var sum := 0.0
	for w in weights:
		sum += maxf(w, 0.0)
	var counts := PackedInt32Array()
	counts.resize(n)
	var ideal := PackedFloat64Array()
	ideal.resize(n)
	var given := 0
	for i in n:
		ideal[i] = total * (maxf(weights[i], 0.0) / sum if sum > 0.0 else 1.0 / n)
		counts[i] = maxi(1, floori(ideal[i]))
		given += counts[i]
	while given < total:
		var best := 0
		for i in n:
			if ideal[i] - counts[i] > ideal[best] - counts[best]:
				best = i
		counts[best] += 1
		given += 1
	while given > total:
		var best := -1
		for i in n:
			if counts[i] > 1 and (best < 0 or ideal[i] - counts[i] < ideal[best] - counts[best]):
				best = i
		if best < 0:
			break
		counts[best] -= 1
		given -= 1
	return counts


# ---------------------------------------------------------------------------------------------
# Frames along paths
# ---------------------------------------------------------------------------------------------

## The tangent a frame takes at each resampled point: the bisector on a corner.
static func frame_tangents(samples: Dictionary) -> PackedVector3Array:
	var out := PackedVector3Array()
	var t_in: PackedVector3Array = samples.t_in
	var t_out: PackedVector3Array = samples.t_out
	for i in t_in.size():
		var t := t_in[i] + t_out[i]
		out.append(t.normalized() if t.length() > 1e-9 else t_out[i])
	return out


## Rotation-minimizing frames (the double-reflection method) at points with tangents, starting
## from r0 (made square to the first tangent): [Basis (x = r, y = t x r... see below)] as Basis
## columns (r, s, t) with s = t x r. closed: the twist one lap leaves is spread along the path so
## the frames close.
static func rmf(points: PackedVector3Array, tangents: PackedVector3Array, r0: Vector3, closed: bool) -> Array:
	var n := points.size()
	var frames := []
	if n == 0:
		return frames
	var t0 := tangents[0].normalized()
	var r := (r0 - t0 * r0.dot(t0))
	if r.length() < 1e-9:
		r = _perpendicular(t0)
	r = r.normalized()
	var rs: Array[Vector3] = [r]
	var limit := n if closed else n - 1
	for i in limit:
		var x0 := points[i]
		var x1 := points[(i + 1) % n]
		var ti := tangents[i].normalized()
		var tj := tangents[(i + 1) % n].normalized()
		var ri: Vector3 = rs[i]
		var v1 := x1 - x0
		var c1 := v1.dot(v1)
		var rl := ri
		var tl := ti
		if c1 > 1e-24:
			rl = ri - v1 * (2.0 / c1 * v1.dot(ri))
			tl = ti - v1 * (2.0 / c1 * v1.dot(ti))
		var v2 := tj - tl
		var c2 := v2.dot(v2)
		var rn := rl - v2 * (2.0 / c2 * v2.dot(rl)) if c2 > 1e-24 else rl
		rn = (rn - tj * rn.dot(tj))
		rn = rn.normalized() if rn.length() > 1e-9 else _perpendicular(tj)
		rs.append(rn)
	if closed and n > 1:
		# rs[n] is the first point's frame after one lap: undo its twist gradually.
		var back: Vector3 = rs[n]
		var phi := atan2(t0.dot(back.cross(rs[0])), back.dot(rs[0]))
		var total := 0.0
		var lengths := PackedFloat64Array([0.0])
		for i in n:
			total += points[i].distance_to(points[(i + 1) % n])
			lengths.append(total)
		for i in n:
			var t := tangents[i].normalized()
			rs[i] = (rs[i] as Vector3).rotated(t, phi * lengths[i] / maxf(total, 1e-30)).normalized()
		rs.resize(n)
	for i in n:
		var t := tangents[i].normalized()
		var rr: Vector3 = rs[i]
		frames.append(Basis(rr, t.cross(rr), t))
	return frames


static func _perpendicular(t: Vector3) -> Vector3:
	var helper := Vector3.UP if absf(t.normalized().y) < 0.9 else Vector3.RIGHT
	return t.cross(helper).normalized()


## On a corner of a path, points of a section square to the bisector stretched across the
## bend so the section meets both legs (a mitre): factor 1 / cos(half the turn) along the bend.
static func _mitre(point: Vector3, center: Vector3, t_in: Vector3, t_out: Vector3) -> Vector3:
	var turn := t_in.angle_to(t_out)
	if turn < 1e-6 or turn > PI - 1e-3:
		return point
	var bend := (t_out - t_in).normalized()
	var d := point - center
	return point + bend * d.dot(bend) * (1.0 / cos(turn * 0.5) - 1.0)


# ---------------------------------------------------------------------------------------------
# The grid every builder makes
# ---------------------------------------------------------------------------------------------

## A cage from rows of points (each row a PackedFloat64Array of xyz doubles, the same count in
## every row): quads between neighbouring rows and columns, rows_closed / cols_closed wrap
## round. poles: per row, 1 = the row is one vertex (its first point) and its faces are
## triangles. Faces go (u, v), (u, v + 1), (u + 1, v + 1), (u + 1, v). Returns {"cage", "ids":
## Array of PackedInt32Array (the vertex of each row and column)}.
static func grid(rows: Array, rows_closed: bool, cols_closed: bool, poles := PackedByteArray()) -> Dictionary:
	var nu := rows.size()
	var nv := (rows[0] as PackedFloat64Array).size() / 3 if nu > 0 else 0
	var pos := PackedFloat64Array()
	var ids := []
	for u in nu:
		var row: PackedFloat64Array = rows[u]
		var line := PackedInt32Array()
		line.resize(nv)
		if u < poles.size() and poles[u] == 1:
			var id := pos.size() / 3
			pos.append(row[0])
			pos.append(row[1])
			pos.append(row[2])
			line.fill(id)
		else:
			for v in nv:
				line[v] = pos.size() / 3
				pos.append(row[3 * v])
				pos.append(row[3 * v + 1])
				pos.append(row[3 * v + 2])
		ids.append(line)
	var counts := PackedInt32Array()
	var idx := PackedInt32Array()
	var us := nu if rows_closed else nu - 1
	var vs := nv if cols_closed else nv - 1
	for u in us:
		var u1 := (u + 1) % nu
		for v in vs:
			var v1 := (v + 1) % nv
			var ring := [ids[u][v], ids[u][v1], ids[u1][v1], ids[u1][v]]
			var face := PackedInt32Array()
			for k in 4:
				if face.is_empty() or face[face.size() - 1] != ring[k]:
					face.append(ring[k])
			if face.size() > 1 and face[0] == face[face.size() - 1]:
				face.remove_at(face.size() - 1)
			if face.size() < 3:
				continue
			counts.append(face.size())
			idx.append_array(face)
	return {"cage": CAGE.make(pos, counts, idx), "ids": ids}


## Points as a row of doubles.
static func row_of(points: PackedVector3Array) -> PackedFloat64Array:
	var row := PackedFloat64Array()
	row.resize(points.size() * 3)
	for i in points.size():
		row[3 * i] = points[i].x
		row[3 * i + 1] = points[i].y
		row[3 * i + 2] = points[i].z
	return row


## Turns every face over when the faces mostly face toward their reference points (refs: one per
## face, a point inside what the face bounds: its ring's middle, the axis, the path). A closed
## cage is turned so its volume is positive instead. Faces that don't decide (a flat sheet) keep
## their order.
static func orient_outward(c: Dictionary, refs: PackedVector3Array) -> Dictionary:
	var topo := CAGE.topology(c)
	if topo.nF == 0:
		return c
	var all := PackedInt32Array()
	for f in topo.nF:
		all.append(f)
	if topo.is_closed():
		return CAGE.flip_faces(c, all).cage if CAGE.signed_volume(c) < 0.0 else c
	var flux := 0.0
	var scale := 0.0
	var diag := maxf(CAGE.bounds(c).size.length(), 1e-12)
	for f in topo.nF:
		var area := topo.face_area_vector(c, f)
		var centre := Vector3.ZERO
		var verts := CAGE.face_vertices(c, f)
		for v in verts:
			centre += CAGE.position(c, v)
		centre /= verts.size()
		var ref := refs[f] if f < refs.size() else centre
		flux += area.dot(centre - ref)
		scale += area.length() * diag
	if flux < -1e-9 * scale:
		return CAGE.flip_faces(c, all).cage
	return c


## The middle of each face's first row (its reference for orient_outward), from row centres.
static func face_refs(c: Dictionary, ids: Array, centres: PackedVector3Array) -> PackedVector3Array:
	var row_of_vertex := {}
	for u in ids.size():
		for v in (ids[u] as PackedInt32Array):
			if not row_of_vertex.has(v):
				row_of_vertex[v] = u
	var out := PackedVector3Array()
	for f in CAGE.face_count(c):
		var lo := 1 << 30
		var hi := -1
		for v in CAGE.face_vertices(c, f):
			var u: int = row_of_vertex.get(v, 0)
			lo = mini(lo, u)
			hi = maxi(hi, u)
		# A face between the last and first row of a closed grid: the last row's centre.
		var u0 := hi if hi - lo > 1 else lo
		var u1 := lo if hi - lo > 1 else hi
		out.append((centres[u0] + centres[u1]) * 0.5)
	return out


## Creases along the given vertex pairs (Vector2i), at the infinitely sharp weight.
static func add_creases(c: Dictionary, pairs: Array) -> void:
	if pairs.is_empty():
		return
	var m := CAGE.crease_map(c)
	for pair in pairs:
		var p: Vector2i = pair
		if p.x != p.y:
			m[CAGE.edge_key(p.x, p.y)] = CAGE.SHARP
	CAGE._store_creases(c, m)


static func _fail(message: String) -> Dictionary:
	return {"ok": false, "error": message, "cage": {}, "warnings": PackedStringArray(), "fit": PackedInt32Array()}


static func _built(cage: Dictionary, fit: PackedInt32Array, warnings: PackedStringArray) -> Dictionary:
	var problems := CAGE.validate(cage)
	if not problems.is_empty():
		return _fail("The cage came out invalid: %s" % problems[0])
	return {"ok": true, "error": "", "cage": cage, "warnings": warnings, "fit": fit}


static func _all_vertices(c: Dictionary) -> PackedInt32Array:
	var out := PackedInt32Array()
	for v in CAGE.vertex_count(c):
		out.append(v)
	return out


static func _centroid(points: PackedVector3Array) -> Vector3:
	var c := Vector3.ZERO
	for p in points:
		c += p
	return c / maxi(points.size(), 1)


static func _size(points: PackedVector3Array) -> float:
	var box := AABB(points[0], Vector3.ZERO) if not points.is_empty() else AABB()
	for p in points:
		box = box.expand(p)
	return maxf(box.size.length(), 1e-9)


# ---------------------------------------------------------------------------------------------
# Extrude
# ---------------------------------------------------------------------------------------------

## A profile's points stepped along normal. opts: "distance", "direction" "one_side" |
## "two_sides" | "symmetric" (the whole distance centred on the profile), "distance2" (two sides),
## "taper" (radians; positive narrows away from the profile), "front_faces" (faces along each
## side), "keep_creases". The ends stay open.
static func extrude(samples: Dictionary, normal: Vector3, opts: Dictionary) -> Dictionary:
	var pts: PackedVector3Array = samples.points
	var closed := bool(samples.closed)
	if pts.size() < (3 if closed else 2):
		return _fail("The profile needs more points")
	var n := normal.normalized()
	var d := float(opts.get("distance", 0.0))
	var m := maxi(1, int(opts.get("front_faces", 1)))
	var heights := PackedFloat64Array()
	match str(opts.get("direction", "one_side")):
		"symmetric":
			for i in 2 * m + 1:
				heights.append(-0.5 * d + d * i / (2.0 * m))
		"two_sides":
			var d2 := float(opts.get("distance2", 0.0))
			if absf(d2) <= 1e-12:
				return _fail("Distance 2 can't be zero")
			for i in m:
				heights.append(-d2 + d2 * i / m)
			for i in m + 1:
				heights.append(d * i / m)
		_:
			for i in m + 1:
				heights.append(d * i / m)
	if absf(d) <= 1e-12:
		return _fail("The distance can't be zero")
	# Where taper moves each point: outward in the profile's plane (a mitre on corners).
	var sign := 1.0
	if closed:
		var area := 0.0
		for j in pts.size():
			area += pts[j].cross(pts[(j + 1) % pts.size()]).dot(n)
		sign = 1.0 if area >= 0.0 else -1.0
	var out_dirs := PackedVector3Array()
	var t_in: PackedVector3Array = samples.t_in
	var t_out: PackedVector3Array = samples.t_out
	var corners: PackedByteArray = samples.corners
	for j in pts.size():
		var a := (t_in[j] - n * t_in[j].dot(n)).normalized().cross(n) * sign
		var b := (t_out[j] - n * t_out[j].dot(n)).normalized().cross(n) * sign
		var o := (a + b) / maxf(1.0 + a.dot(b), 1e-6) if corners[j] == 1 else b
		out_dirs.append(o)
	var taper := tan(float(opts.get("taper", 0.0)))
	var rows := []
	var centres := PackedVector3Array()
	var middle := _centroid(pts)
	for h in heights:
		var row := PackedVector3Array()
		for j in pts.size():
			row.append(pts[j] + n * h - out_dirs[j] * (taper * absf(h)))
		rows.append(row_of(row))
		centres.append(middle + n * h)
	if taper != 0.0 and closed:
		# A taper that turns a ring inside out (it passes the profile's middle) can't be built.
		var last: PackedFloat64Array = rows[0] if absf(heights[0]) > absf(heights[heights.size() - 1]) else rows[rows.size() - 1]
		var area := 0.0
		var k := pts.size()
		for j in k:
			var p := Vector3(last[3 * j], last[3 * j + 1], last[3 * j + 2])
			var q := Vector3(last[3 * ((j + 1) % k)], last[3 * ((j + 1) % k) + 1], last[3 * ((j + 1) % k) + 2])
			area += p.cross(q).dot(n)
		if area * sign <= 0.0:
			return _fail("The taper is too steep for this profile")
	var g := grid(rows, false, closed)
	var cage: Dictionary = g.cage
	if bool(opts.get("keep_creases", true)):
		var pairs := []
		for j in pts.size():
			if corners[j] == 1:
				for u in heights.size() - 1:
					pairs.append(Vector2i(g.ids[u][j], g.ids[u + 1][j]))
		add_creases(cage, pairs)
	cage = orient_outward(cage, face_refs(cage, g.ids, centres))
	return _built(cage, _all_vertices(cage), PackedStringArray())


# ---------------------------------------------------------------------------------------------
# Revolve
# ---------------------------------------------------------------------------------------------

## A profile's points turned round an axis. opts: "type" "full" | "angle", "angle" (radians),
## "direction" "one_side" | "two_sides" | "symmetric", "angle2", "around" (faces round the axis),
## "weld" (profile points on the axis become one pole each; their faces triangles),
## "keep_creases" (rings through sharp profile corners creased). A closed profile with a stretch
## along the axis opens there (the stretch would sweep nothing).
static func revolve(samples: Dictionary, axis_origin: Vector3, axis_dir: Vector3, opts: Dictionary) -> Dictionary:
	var pts: PackedVector3Array = samples.points
	var corners: PackedByteArray = samples.corners
	var closed := bool(samples.closed)
	var a := axis_dir.normalized()
	if a.length() < 0.5:
		return _fail("Pick an axis to revolve around")
	var size := _size(pts)
	var tol := size * 1e-6
	var on_axis := PackedByteArray()
	var any_on := false
	for p in pts:
		var rel := p - axis_origin
		var off := (rel - a * rel.dot(a)).length() <= tol
		on_axis.append(1 if off else 0)
		any_on = any_on or off
	var weld := bool(opts.get("weld", true))
	var warnings := PackedStringArray()
	var order := PackedInt32Array()
	for j in pts.size():
		order.append(j)
	if weld and any_on:
		if closed:
			# Runs of points on the axis round the loop: one stretch may lie on the axis.
			var runs := []
			var k := pts.size()
			var startj := -1
			for j in k:
				if on_axis[j] == 1 and on_axis[(j - 1 + k) % k] == 0:
					startj = j
					var length := 0
					while on_axis[(startj + length) % k] == 1 and length < k:
						length += 1
					runs.append([startj, length])
			if runs.size() != 1 or int(runs[0][1]) < 2:
				return _fail("The profile touches the axis at a point; make it meet the axis along a line or move it off the axis")
			var first: int = runs[0][0]
			var length: int = runs[0][1]
			# Open from the stretch's last point round to its first.
			order.clear()
			for q in k - length + 2:
				order.append((first + length - 1 + q) % k)
			closed = false
		else:
			for j in range(1, pts.size() - 1):
				if on_axis[j] == 1:
					return _fail("The profile touches the axis between its ends; split it there")
	elif any_on:
		warnings.append("Profile points on the axis are kept apart (Weld is off)")
	var around := maxi(3 if str(opts.get("type", "full")) == "full" else 1, int(opts.get("around", 8)))
	var angles := PackedFloat64Array()
	var full := str(opts.get("type", "full")) == "full"
	if full:
		for v in around:
			angles.append(TAU * v / around)
	else:
		var angle := float(opts.get("angle", PI * 0.5))
		match str(opts.get("direction", "one_side")):
			"symmetric":
				for v in around + 1:
					angles.append(-0.5 * angle + angle * v / around)
			"two_sides":
				var angle2 := float(opts.get("angle2", PI * 0.5))
				var total := absf(angle) + absf(angle2)
				if total <= 1e-9:
					return _fail("The angles can't both be zero")
				var n1 := clampi(roundi(around * absf(angle) / total), 1, maxi(around - 1, 1))
				var n2 := maxi(around - n1, 1)
				for v in n2:
					angles.append(-angle2 + angle2 * v / n2)
				for v in n1 + 1:
					angles.append(angle * v / n1)
			_:
				for v in around + 1:
					angles.append(angle * v / around)
		if absf(angles[angles.size() - 1] - angles[0]) >= TAU - 1e-9:
			return _fail("Use the Full type for a whole turn")
		if absf(angles[angles.size() - 1] - angles[0]) <= 1e-9:
			return _fail("The angle can't be zero")
	var od := PackedFloat64Array([axis_origin.x, axis_origin.y, axis_origin.z])
	var ad := FORM_OPS.unit_d(PackedFloat64Array([a.x, a.y, a.z]))
	var rows := []
	var poles := PackedByteArray()
	var centres := PackedVector3Array()
	var row_corners := PackedByteArray()
	for j in order:
		var p := pts[j]
		var pd := PackedFloat64Array([p.x, p.y, p.z])
		var row := PackedFloat64Array()
		if weld and on_axis[j] == 1:
			# The pole: the point dropped exactly onto the axis.
			var t := (pd[0] - od[0]) * ad[0] + (pd[1] - od[1]) * ad[1] + (pd[2] - od[2]) * ad[2]
			for v in angles.size():
				row.append_array(PackedFloat64Array([od[0] + ad[0] * t, od[1] + ad[1] * t, od[2] + ad[2] * t]))
			poles.append(1)
		else:
			for theta in angles:
				row.append_array(FORM_OPS.rotate_d(pd, od, ad, theta))
			poles.append(0)
		rows.append(row)
		var rel := p - axis_origin
		centres.append(axis_origin + a * rel.dot(a))
		row_corners.append(corners[j])
	var g := grid(rows, closed, full, poles)
	var cage: Dictionary = g.cage
	if bool(opts.get("keep_creases", true)):
		var pairs := []
		var cols := angles.size()
		for u in rows.size():
			if row_corners[u] == 1 and poles[u] == 0:
				for v in (cols if full else cols - 1):
					pairs.append(Vector2i(g.ids[u][v], g.ids[u][(v + 1) % cols]))
		add_creases(cage, pairs)
	# Faces point away from the axis (each face's reference: the axis point level with it).
	var refs := PackedVector3Array()
	for f in CAGE.face_count(cage):
		var centre := Vector3.ZERO
		var verts := CAGE.face_vertices(cage, f)
		for v in verts:
			centre += CAGE.position(cage, v)
		centre /= verts.size()
		refs.append(axis_origin + a * (centre - axis_origin).dot(a))
	cage = orient_outward(cage, refs)
	return _built(cage, _all_vertices(cage), warnings)


# ---------------------------------------------------------------------------------------------
# Sweep
# ---------------------------------------------------------------------------------------------

## A profile's points carried along a path's points. opts: "orientation" "perpendicular" (the
## profile turns with the path's rotation-minimizing frames, from the profile's plane) |
## "parallel" (it only moves), "profile_plane" (Transform3D or null), "keep_creases" (edges
## along the path from sharp profile corners, and rings on sharp path corners, creased). A closed
## path closes the surface along it.
static func sweep(profile: Dictionary, path: Dictionary, opts: Dictionary) -> Dictionary:
	var pts: PackedVector3Array = profile.points
	var cs: PackedVector3Array = path.points
	if pts.size() < 2 or cs.size() < 2:
		return _fail("The profile and the path need more points")
	var path_closed := bool(path.closed)
	var tangents := frame_tangents(path)
	var perpendicular := str(opts.get("orientation", "perpendicular")) == "perpendicular"
	var t0 := tangents[0]
	var r0 := _perpendicular(t0)
	var plane: Variant = opts.get("profile_plane")
	if plane is Transform3D:
		var px: Vector3 = (plane as Transform3D).basis.x
		var py: Vector3 = (plane as Transform3D).basis.y
		r0 = px if (px - t0 * px.dot(t0)).length() > 0.2 else py
	var frames := rmf(cs, tangents, r0, path_closed)
	var first: Basis = frames[0]
	var inverse := first.transposed()
	var rows := []
	var centres := PackedVector3Array()
	var t_in: PackedVector3Array = path.t_in
	var t_out: PackedVector3Array = path.t_out
	var path_corners: PackedByteArray = path.corners
	for i in cs.size():
		var row := PackedVector3Array()
		var turn: Basis = (frames[i] as Basis) * inverse
		for p in pts:
			var q: Vector3
			if perpendicular:
				q = cs[i] + turn * (p - cs[0])
				if path_corners[i] == 1:
					q = _mitre(q, cs[i], t_in[i], t_out[i])
			else:
				q = p + (cs[i] - cs[0])
			row.append(q)
		rows.append(row_of(row))
		# Faces point away from the ring's middle (a closed profile) or from the path (an open one).
		centres.append(_centroid(row) if bool(profile.closed) else cs[i])
	var g := grid(rows, path_closed, bool(profile.closed))
	var cage: Dictionary = g.cage
	if bool(opts.get("keep_creases", true)):
		var pairs := []
		var k := pts.size()
		var corners: PackedByteArray = profile.corners
		var along := cs.size() if path_closed else cs.size() - 1
		for j in k:
			if corners[j] == 1:
				for u in along:
					pairs.append(Vector2i(g.ids[u][j], g.ids[(u + 1) % cs.size()][j]))
		for u in cs.size():
			if path_corners[u] == 1:
				for j in (k if bool(profile.closed) else k - 1):
					pairs.append(Vector2i(g.ids[u][j], g.ids[u][(j + 1) % k]))
		add_creases(cage, pairs)
	cage = orient_outward(cage, face_refs(cage, g.ids, centres))
	return _built(cage, _all_vertices(cage), PackedStringArray())


# ---------------------------------------------------------------------------------------------
# Loft
# ---------------------------------------------------------------------------------------------

## A surface through sections in order. sections: [{"points": PackedVector3Array (resampled to
## the same count), "closed", "point": bool (a tip: one point), "normal": Vector3 (its plane's
## normal, or zero)}]. opts: "closed" (the loft returns to its first section), "length_faces"
## (faces between two sections), "start" / "end" {"type": "free" | "direction" | "tip", "angle",
## "weight"}, "rails": [dense rail samples {"points", "s"}] the surface follows between sections,
## "centerline": dense centerline samples the in-between sections turn along. Hermite curves
## (Catmull-Rom tangents, natural free ends) join corresponding points. "fit" gets the section
## rows (the in-between rows stay free).
static func loft(sections: Array, opts: Dictionary) -> Dictionary:
	var count := sections.size()
	if count < 2:
		return _fail("Pick two or more profiles, in order")
	var loop := bool(opts.get("closed", false))
	var m := maxi(1, int(opts.get("length_faces", 2)))
	var k := -1
	var closed_sections := -1
	for s in count:
		var sec: Dictionary = sections[s]
		if bool(sec.get("point", false)):
			if (s != 0 and s != count - 1) or loop:
				return _fail("Only the first and last profiles of an open loft can be points")
			continue
		var n := (sec.points as PackedVector3Array).size()
		if k < 0:
			k = n
			closed_sections = 1 if bool(sec.closed) else 0
		elif n != k:
			return _fail("The profiles came out with different point counts")
		elif (1 if bool(sec.closed) else 0) != closed_sections:
			return _fail("Loft profiles must be all closed or all open")
	if k < 0:
		return _fail("A loft needs at least one curve profile")
	var closed_rows := closed_sections == 1
	# Section points (tips repeated), aligned to the previous section with the least twist.
	var P := []
	for s in count:
		var sec: Dictionary = sections[s]
		var pts := PackedVector3Array()
		if bool(sec.get("point", false)):
			var tip: Vector3 = (sec.points as PackedVector3Array)[0]
			for j in k:
				pts.append(tip)
		else:
			pts = (sec.points as PackedVector3Array).duplicate()
			var prev := -1
			for q in range(s - 1, -1, -1):
				if not bool((sections[q] as Dictionary).get("point", false)):
					prev = q
					break
			if prev >= 0:
				pts = _align(P[prev], pts, closed_rows)
		P.append(pts)
	var centres := PackedVector3Array()
	for s in count:
		centres.append(_centroid(P[s]))
	# Tangents per section and column.
	var T := []
	for s in count:
		var row := PackedVector3Array()
		row.resize(k)
		T.append(row)
	for j in k:
		var col := PackedVector3Array()
		for s in count:
			col.append((P[s] as PackedVector3Array)[j])
		var tans := _hermite_tangents(col, loop)
		for s in count:
			(T[s] as PackedVector3Array)[j] = tans[s]
	if not loop:
		_end_condition(P, T, centres, sections, opts.get("start", {}), 0, 1)
		_end_condition(P, T, centres, sections, opts.get("end", {}), count - 1, count - 2)
	# Rows: m per span, then the last section.
	var spans := count if loop else count - 1
	var rows := []
	var row_section := PackedInt32Array()
	var row_param := PackedFloat64Array()
	var poles := PackedByteArray()
	for s in spans:
		var s1 := (s + 1) % count
		for q in m:
			var u := float(q) / m
			var row := PackedVector3Array()
			for j in k:
				row.append(_hermite((P[s] as PackedVector3Array)[j], (T[s] as PackedVector3Array)[j], (P[s1] as PackedVector3Array)[j], (T[s1] as PackedVector3Array)[j], u))
			rows.append(row)
			row_section.append(s if q == 0 else -1)
			row_param.append(s + u)
			poles.append(1 if q == 0 and bool((sections[s] as Dictionary).get("point", false)) else 0)
	if not loop:
		rows.append((P[count - 1] as PackedVector3Array).duplicate())
		row_section.append(count - 1)
		row_param.append(count - 1)
		poles.append(1 if bool((sections[count - 1] as Dictionary).get("point", false)) else 0)
	var centerline: Dictionary = opts.get("centerline", {})
	if not centerline.is_empty():
		rows = _follow_centerline(rows, row_section, row_param, P, T, centres, centerline, loop, m)
	for rail in opts.get("rails", []):
		_follow_rail(rows, row_section, row_param, P, rail, closed_rows, count, loop)
	var drows := []
	var row_centres := PackedVector3Array()
	for row in rows:
		drows.append(row_of(row))
		row_centres.append(_centroid(row))
	var g := grid(drows, loop, closed_rows, poles)
	var cage: Dictionary = g.cage
	var fit := PackedInt32Array()
	for u in rows.size():
		if row_section[u] >= 0:
			for v in (g.ids[u] as PackedInt32Array):
				if not fit.has(v):
					fit.append(v)
	cage = orient_outward(cage, face_refs(cage, g.ids, row_centres))
	return _built(cage, fit, PackedStringArray())


## pts reordered to follow ref with the least twist: a closed section rotated (and turned round
## when it runs the other way), an open one turned round when its ends are swapped.
static func _align(ref: PackedVector3Array, pts: PackedVector3Array, closed: bool) -> PackedVector3Array:
	var k := pts.size()
	var cr := _centroid(ref)
	var cp := _centroid(pts)
	var best := pts
	var best_cost := INF
	for flip in 2:
		var cand := pts.duplicate()
		if flip == 1:
			cand.reverse()
		var shifts := k if closed else 1
		for shift in shifts:
			var cost := 0.0
			for j in k:
				cost += ((cand[(j + shift) % k] - cp) - (ref[j] - cr)).length_squared()
			if cost < best_cost - 1e-18:
				best_cost = cost
				var out := PackedVector3Array()
				for j in k:
					out.append(cand[(j + shift) % k])
				best = out
	return best


## Catmull-Rom tangents through points at parameters 0, 1, 2...; natural (free) open ends.
static func _hermite_tangents(col: PackedVector3Array, loop: bool) -> PackedVector3Array:
	var n := col.size()
	var out := PackedVector3Array()
	out.resize(n)
	if n == 2 and not loop:
		out[0] = col[1] - col[0]
		out[1] = col[1] - col[0]
		return out
	for s in n:
		if loop:
			out[s] = (col[(s + 1) % n] - col[(s - 1 + n) % n]) * 0.5
		elif s > 0 and s < n - 1:
			out[s] = (col[s + 1] - col[s - 1]) * 0.5
	if not loop:
		out[0] = (col[1] - col[0]) * 1.5 - out[1] * 0.5
		out[n - 1] = (col[n - 1] - col[n - 2]) * 1.5 - out[n - 2] * 0.5
	return out


static func _hermite(p0: Vector3, t0: Vector3, p1: Vector3, t1: Vector3, u: float) -> Vector3:
	var u2 := u * u
	var u3 := u2 * u
	return p0 * (2.0 * u3 - 3.0 * u2 + 1.0) + t0 * (u3 - 2.0 * u2 + u) + p1 * (-2.0 * u3 + 3.0 * u2) + t1 * (u3 - u2)


## An end's tangents: "direction" leaves the profile at "angle" from its plane's normal (tilted
## outward), "weight" times the distance to the next section; "tip" (a point profile) leaves the
## tip square to the loft's axis, rounding it.
static func _end_condition(P: Array, T: Array, centres: PackedVector3Array, sections: Array, cond: Dictionary, s: int, other: int) -> void:
	var kind := str(cond.get("type", "free"))
	if kind == "free":
		return
	var weight := float(cond.get("weight", 1.0))
	var span := centres[s].distance_to(centres[other])
	var along := (centres[other] - centres[s]).normalized() * (1.0 if s == 0 else -1.0)
	var pts: PackedVector3Array = P[s]
	var tans: PackedVector3Array = T[s]
	var sec: Dictionary = sections[s]
	if kind == "tip" and bool(sec.get("point", false)):
		var next: PackedVector3Array = P[other]
		for j in pts.size():
			var radial := next[j] - centres[other]
			radial = radial - along * radial.dot(along)
			tans[j] = radial.normalized() * radial.length() * 2.0 * weight * (1.0 if s == 0 else -1.0)
		T[s] = tans
		return
	if kind != "direction" or bool(sec.get("point", false)):
		return
	var normal: Vector3 = sec.get("normal", Vector3.ZERO)
	if normal.length() < 1e-9:
		normal = along
	normal = normal.normalized()
	if normal.dot(along) < 0.0:
		normal = -normal
	var angle := float(cond.get("angle", 0.0))
	for j in pts.size():
		var radial := pts[j] - centres[s]
		radial = (radial - normal * radial.dot(normal)).normalized()
		var d := normal * cos(angle) + radial * sin(angle)
		tans[j] = d * span * weight
	T[s] = tans


## The in-between rows turned along a centerline: each section's points measured in the
## centerline's frame at its nearest point, blended there, and put back in the frame between.
static func _follow_centerline(rows: Array, row_section: PackedInt32Array, row_param: PackedFloat64Array, P: Array, T: Array,
		centres: PackedVector3Array, line: Dictionary, loop: bool, m: int) -> Array:
	var cps: PackedVector3Array = line.points
	var css: PackedFloat64Array = line.s
	var frames: Array = line.frames
	var count := P.size()
	var at := PackedFloat64Array()
	var local := []
	for s in count:
		var u := _nearest_on(cps, css, centres[s])
		at.append(u)
		var f := _frame_at(cps, css, frames, u)
		var basis: Basis = f.basis
		var origin: Vector3 = f.origin
		var pts := PackedVector3Array()
		for p in (P[s] as PackedVector3Array):
			pts.append(basis.transposed() * (p - origin))
		local.append(pts)
	var out := []
	for r in rows.size():
		if row_section[r] >= 0:
			out.append(rows[r])
			continue
		var s := floori(row_param[r])
		var s1 := (s + 1) % count
		var u := row_param[r] - s
		var where := lerpf(at[s], at[s1] if (s1 != 0 or not loop) else at[s1] + float(css[css.size() - 1]), u)
		var f := _frame_at(cps, css, frames, where)
		var basis: Basis = f.basis
		var origin: Vector3 = f.origin
		var k := (local[s] as PackedVector3Array).size()
		var row := PackedVector3Array()
		for j in k:
			var a: Vector3 = (local[s] as PackedVector3Array)[j]
			var b: Vector3 = (local[s1] as PackedVector3Array)[j]
			var ta := (b - (local[(s - 1 + count) % count] as PackedVector3Array)[j]) * 0.5 if (s > 0 or loop) else b - a
			var tb := ((local[(s1 + 1) % count] as PackedVector3Array)[j] - a) * 0.5 if (s1 < count - 1 or loop) else b - a
			row.append(origin + basis * _hermite(a, ta, b, tb, u))
		out.append(row)
	return out


## Moves the in-between rows so they pass through a rail (its nearest column follows it; the
## others share the move, more the nearer they are).
static func _follow_rail(rows: Array, row_section: PackedInt32Array, row_param: PackedFloat64Array, P: Array, rail: Dictionary,
		closed_rows: bool, count: int, loop: bool) -> void:
	var rps: PackedVector3Array = rail.points
	var rss: PackedFloat64Array = rail.s
	if rps.size() < 2:
		return
	var cols := (P[0] as PackedVector3Array).size()
	# The column the rail runs along: the one nearest it at the first section.
	var best_j := 0
	var best_d := INF
	for j in cols:
		var d := _distance_to_polyline(rps, (P[0] as PackedVector3Array)[j])
		if d < best_d:
			best_d = d
			best_j = j
	var u_at := PackedFloat64Array()
	for s in count:
		u_at.append(_nearest_on(rps, rss, (P[s] as PackedVector3Array)[best_j]))
	for r in rows.size():
		if row_section[r] >= 0:
			continue
		var s := floori(row_param[r])
		var s1 := (s + 1) % count
		var t := row_param[r] - s
		var where := lerpf(u_at[s], u_at[s1], t)
		var target := _point_on(rps, rss, where)
		var row: PackedVector3Array = rows[r]
		var delta := target - row[best_j]
		for j in cols:
			var dj := absi(j - best_j)
			if closed_rows:
				dj = mini(dj, cols - dj)
			var w := 1.0 / (1.0 + float(dj * dj) / maxf(float(cols * cols) / 16.0, 1.0))
			row[j] = row[j] + delta * w
		rows[r] = row


static func _distance_to_polyline(pts: PackedVector3Array, p: Vector3) -> float:
	var best := INF
	for i in pts.size() - 1:
		best = minf(best, Geometry3D.get_closest_point_to_segment(p, pts[i], pts[i + 1]).distance_to(p))
	return best


## The arc length of a polyline's point nearest p.
static func _nearest_on(pts: PackedVector3Array, ss: PackedFloat64Array, p: Vector3) -> float:
	var best := INF
	var best_s := 0.0
	for i in pts.size() - 1:
		var q := Geometry3D.get_closest_point_to_segment(p, pts[i], pts[i + 1])
		var d := q.distance_to(p)
		if d < best:
			best = d
			var seg := pts[i].distance_to(pts[i + 1])
			best_s = lerpf(ss[i], ss[i + 1], q.distance_to(pts[i]) / seg if seg > 0.0 else 0.0)
	return best_s


static func _point_on(pts: PackedVector3Array, ss: PackedFloat64Array, s: float) -> Vector3:
	for i in pts.size() - 1:
		if s <= ss[i + 1] or i == pts.size() - 2:
			var span := ss[i + 1] - ss[i]
			return pts[i].lerp(pts[i + 1], clampf((s - ss[i]) / span, 0.0, 1.0) if span > 0.0 else 0.0)
	return pts[pts.size() - 1]


static func _frame_at(pts: PackedVector3Array, ss: PackedFloat64Array, frames: Array, s: float) -> Dictionary:
	var total := ss[ss.size() - 1]
	if s > total and total > 0.0:
		s = fposmod(s, total)
	for i in pts.size() - 1:
		if s <= ss[i + 1] or i == pts.size() - 2:
			var span := ss[i + 1] - ss[i]
			var f := clampf((s - ss[i]) / span, 0.0, 1.0) if span > 0.0 else 0.0
			var a: Basis = frames[i]
			var b: Basis = frames[i + 1]
			var t := a.z.lerp(b.z, f).normalized()
			var r := a.x.lerp(b.x, f)
			r = (r - t * r.dot(t)).normalized()
			return {"origin": pts[i].lerp(pts[i + 1], f), "basis": Basis(r, t.cross(r), t)}
	return {"origin": pts[0], "basis": frames[0]}


## Dense samples of a guide curve with arc lengths and rotation-minimizing frames (Loft rails
## and centerlines): {"points", "s", "frames"}.
static func guide(chain: Dictionary, count := 96) -> Dictionary:
	var samples := resample(chain, count, {})
	var tangents := frame_tangents(samples)
	var pts: PackedVector3Array = samples.points
	var ss: PackedFloat64Array = samples.s
	if bool(samples.closed) and pts.size() > 0:
		pts.append(pts[0])
		ss.append(float(chain.length))
		tangents.append(tangents[0])
	var frames := rmf(pts, tangents, _perpendicular(tangents[0]) if not tangents.is_empty() else Vector3.RIGHT, false)
	return {"points": pts, "s": ss, "frames": frames}


# ---------------------------------------------------------------------------------------------
# Pipe
# ---------------------------------------------------------------------------------------------

## A tube round a path's points. opts: "diameter", "around", "start_end" / "end_end" "open" |
## "square" (an n-gon cap, its rim creased) | "spike" (a point half a diameter beyond the end),
## "stations": [{"position" 0..1, "diameter", "angle" (twist, radians)}] (cubic between them; the
## path's ends take the global diameter and no twist unless a station sits there), "normal"
## (the path's plane normal: rings start there, so a flat path's tube is symmetric about its
## plane). A closed path makes a closed ring of tube (its ends ignored).
static func pipe(path: Dictionary, opts: Dictionary) -> Dictionary:
	var cs: PackedVector3Array = path.points
	if cs.size() < 2:
		return _fail("The path needs more points")
	var closed := bool(path.closed)
	var n := maxi(3, int(opts.get("around", 8)))
	var d0 := float(opts.get("diameter", 0.0))
	if d0 <= 0.0:
		return _fail("The diameter must be greater than zero")
	var ss: PackedFloat64Array = path.s
	# Stations sit at fractions of the path's length (a closed path's last point isn't its end).
	var length := float(opts.get("length", 0.0))
	if length <= 0.0:
		length = ss[ss.size() - 1]
	length = maxf(length, 1e-12)
	var stations := _stations(opts.get("stations", []), d0, closed)
	var tangents := frame_tangents(path)
	var normal: Vector3 = opts.get("normal", Vector3.ZERO)
	var r0 := normal if normal.length() > 1e-9 and absf(normal.normalized().dot(tangents[0])) < 0.99 else _perpendicular(tangents[0])
	var frames := rmf(cs, tangents, r0, closed)
	var t_in: PackedVector3Array = path.t_in
	var t_out: PackedVector3Array = path.t_out
	var corners: PackedByteArray = path.corners
	var rows := []
	var centres := PackedVector3Array()
	var poles := PackedByteArray()
	var start_end := "open" if closed else str(opts.get("start_end", "open"))
	var end_end := "open" if closed else str(opts.get("end_end", "open"))
	var diameters := PackedFloat64Array()
	for i in cs.size():
		var x := ss[i] / length
		var dia := _station_value(stations, x, "diameter")
		if dia <= 0.0:
			return _fail("A section's diameter must be greater than zero")
		diameters.append(dia)
		var twist := _station_value(stations, x, "angle")
		var f: Basis = frames[i]
		var row := PackedVector3Array()
		for j in n:
			var theta := TAU * j / n + twist
			var q := cs[i] + (f.x * cos(theta) + f.y * sin(theta)) * (dia * 0.5)
			if corners[i] == 1:
				q = _mitre(q, cs[i], t_in[i], t_out[i])
			row.append(q)
		rows.append(row_of(row))
		centres.append(cs[i])
		poles.append(0)
	if start_end == "spike":
		var tip := cs[0] - t_out[0] * (diameters[0] * 0.5)
		rows.push_front(row_of(_repeat(tip, n)))
		centres.insert(0, tip)
		poles.insert(0, 1)
	if end_end == "spike":
		var last := cs.size() - 1
		var tip := cs[last] + t_in[last] * (diameters[last] * 0.5)
		rows.append(row_of(_repeat(tip, n)))
		centres.append(tip)
		poles.append(1)
	var g := grid(rows, closed, true, poles)
	var cage: Dictionary = g.cage
	cage = orient_outward(cage, face_refs(cage, g.ids, centres))
	var rims := []
	if start_end == "square":
		rims.append(g.ids[0])
	if end_end == "square":
		rims.append(g.ids[rows.size() - 1])
	if not rims.is_empty():
		cage = _cap(cage, rims)
	return _built(cage, _all_vertices(cage), PackedStringArray())


static func _repeat(p: Vector3, n: int) -> PackedVector3Array:
	var out := PackedVector3Array()
	for j in n:
		out.append(p)
	return out


## Closes ring rims with one n-gon each (turned to agree with the tube), their rim edges creased.
static func _cap(c: Dictionary, rims: Array) -> Dictionary:
	var topo := CAGE.topology(c)
	var out := CAGE.copy(c)
	var counts: PackedInt32Array = out.face_counts
	var idx: PackedInt32Array = out.face_indices
	var pairs := []
	for rim in rims:
		var ring: PackedInt32Array = (rim as PackedInt32Array).duplicate()
		var n := ring.size()
		# The tube's face along the rim runs ring[0] -> ring[1] or the other way; the cap the other.
		var h := topo.half_edge(ring[0], ring[1])
		if h >= 0:
			ring.reverse()
		counts.append(n)
		idx.append_array(ring)
		for j in n:
			pairs.append(Vector2i(ring[j], ring[(j + 1) % n]))
	out.face_counts = counts
	out.face_indices = idx
	add_creases(out, pairs)
	return out


## Pipe stations sorted by position, with the path's ends at the global diameter and no twist
## unless a station is there.
static func _stations(list: Array, d0: float, closed: bool) -> Array:
	var out := []
	for st in list:
		if st is Dictionary:
			out.append({"position": clampf(float(st.get("position", 0.0)), 0.0, 1.0), "diameter": float(st.get("diameter", d0)), "angle": float(st.get("angle", 0.0))})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.position) < float(b.position))
	if out.is_empty() or float(out[0].position) > 1e-9:
		out.push_front({"position": 0.0, "diameter": d0, "angle": 0.0})
	if float(out[out.size() - 1].position) < 1.0 - 1e-9:
		var last: Dictionary = {"position": 1.0, "diameter": d0, "angle": 0.0}
		if closed:
			last.diameter = float(out[0].diameter)
			last.angle = float(out[0].angle)
		out.append(last)
	return out


## A station value at x (0..1) by cubic Hermite with finite-difference slopes.
static func _station_value(stations: Array, x: float, key: String) -> float:
	var n := stations.size()
	if n == 1:
		return float(stations[0][key])
	var i := 0
	while i < n - 2 and x > float(stations[i + 1].position):
		i += 1
	var x0 := float(stations[i].position)
	var x1 := float(stations[i + 1].position)
	var y0 := float(stations[i][key])
	var y1 := float(stations[i + 1][key])
	var h := x1 - x0
	if h <= 1e-12:
		return y1
	var m0 := _slope(stations, i, key)
	var m1 := _slope(stations, i + 1, key)
	var u := clampf((x - x0) / h, 0.0, 1.0)
	var u2 := u * u
	var u3 := u2 * u
	return y0 * (2.0 * u3 - 3.0 * u2 + 1.0) + m0 * h * (u3 - 2.0 * u2 + u) + y1 * (-2.0 * u3 + 3.0 * u2) + m1 * h * (u3 - u2)


static func _slope(stations: Array, i: int, key: String) -> float:
	var n := stations.size()
	var a := maxi(i - 1, 0)
	var b := mini(i + 1, n - 1)
	var dx := float(stations[b].position) - float(stations[a].position)
	return (float(stations[b][key]) - float(stations[a][key])) / dx if dx > 1e-12 else 0.0


# ---------------------------------------------------------------------------------------------
# Fit surface to curves
# ---------------------------------------------------------------------------------------------

## Moves the cage so the limit surface passes exactly through the built positions of verts (the
## vertices made on the curves; every vertex may move, the rest as little as they can):
## {"cage", "fitted": bool, "warning", "error"}. Without the native kernel the cage comes back as
## it was (fitted false).
static func fit_cage(c: Dictionary, verts: PackedInt32Array) -> Dictionary:
	if verts.is_empty() or not ClassDB.class_exists("CadSubD"):
		return {"cage": c, "fitted": false, "warning": "", "error": ""}
	var subd: RefCounted = ClassDB.instantiate("CadSubD")
	if not subd.set_cage(c):
		return {"cage": c, "fitted": false, "warning": "", "error": str(subd.get_last_error())}
	var counts: PackedInt32Array = c.face_counts
	var idx: PackedInt32Array = c.face_indices
	var first_face := {}
	var o := 0
	for f in counts.size():
		for k in counts[f]:
			var v := idx[o + k]
			if not first_face.has(v):
				first_face[v] = Vector2i(f, k)
		o += counts[f]
	var corner_uv := [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]
	var faces := PackedInt32Array()
	var uvs := PackedVector2Array()
	var targets := PackedFloat64Array()
	var p: PackedFloat64Array = c.positions
	for v in verts:
		if not first_face.has(v):
			continue
		var fk: Vector2i = first_face[v]
		faces.append(fk.x)
		uvs.append(corner_uv[fk.y] if counts[fk.x] == 4 else subd.subface_uv(fk.x, fk.y, 0.0, 0.0))
		targets.append(p[3 * v])
		targets.append(p[3 * v + 1])
		targets.append(p[3 * v + 2])
	var moved: PackedFloat64Array = subd.fit(faces, uvs, targets, PackedInt32Array(), 1e-6)
	if moved.size() != p.size():
		return {"cage": c, "fitted": false, "warning": "", "error": "Fit to curves failed: %s" % subd.get_last_error()}
	for x in moved:
		if not is_finite(x):
			return {"cage": c, "fitted": false, "warning": "", "error": "Fit to curves failed (no finite solution)"}
	var out := CAGE.copy(c)
	out.positions = moved
	return {"cage": out, "fitted": true, "warning": str(subd.get_last_warning()), "error": ""}
