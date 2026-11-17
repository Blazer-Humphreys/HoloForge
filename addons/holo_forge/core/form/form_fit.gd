@tool
extends RefCounted
## The Form tools that work on the smooth limit surface through the native kernel (CadSubD): the
## Exact inserts, the surface-point modes of Flatten / Straighten / Edit By Curve, Pull, Match and
## its associative links, Interpolate, Make Uniform, Repair Body's self-intersection check and the
## Convert directions. Edit By Curve's control-point mode (pure) lives here too, beside its
## surface mode.
##
## Same result shape as core/form/form_ops.gd: tool(c, sel, opts) -> {"ok", "cage", "selection",
## "warnings", "error", "info"}. Every tool builds its own CadSubD from the cage it is given (never
## the editor's), so a result never depends on what the view showed last. Positions stay doubles;
## only the vertices a tool moves are written. Locked vertices (CAGE.locked_vertices) never move and
## symmetry partners follow exactly (FORM_OPS.apply_symmetry).

const CAGE := preload("res://addons/holo_forge/core/form/cage.gd")
const FORM_OPS := preload("res://addons/holo_forge/core/form/form_ops.gd")
const REFERENCES := preload("res://addons/holo_forge/core/references.gd")
const MESH_IMPORT := preload("res://addons/holo_forge/core/import/mesh_import.gd")

const NEEDS_KERNEL := "This needs the Holo Forge kernel."
## Rounds of the Exact refit (sample the new limit, closest points on the old one, fit).
const REFIT_ROUNDS := 3
## Samples per side of a quad for the refit (ends included).
const SAMPLES := 5
## Pull's rounds in Surface Points mode.
const PULL_ROUNDS := 3


# --- Kernel -------------------------------------------------------------------------------------

static func available() -> bool:
	return ClassDB.class_exists("CadSubD")


## {"subd": a CadSubD holding c} or {"error"}.
static func subd_of(c: Dictionary) -> Dictionary:
	if not available():
		return {"error": NEEDS_KERNEL}
	var s: RefCounted = ClassDB.instantiate("CadSubD")
	if not s.set_cage(c):
		var why := str(s.get_last_error())
		return {"error": "The cage can't be subdivided" + (" (%s)" % why if why != "" else "")}
	return {"subd": s}


static func _err(c: Dictionary, message: String, info := {}) -> Dictionary:
	return FORM_OPS._err(c, message, info)


static func _ok(c_in: Dictionary, cage: Dictionary, sel: Dictionary, warnings := PackedStringArray(), info := {}) -> Dictionary:
	return FORM_OPS._ok(c_in, cage, sel, warnings, info)


static func _v3(p: PackedFloat64Array, v: int) -> Vector3:
	return Vector3(p[3 * v], p[3 * v + 1], p[3 * v + 2])


static func _to_v3(p: PackedFloat64Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	out.resize(p.size() / 3)
	for i in out.size():
		out[i] = Vector3(p[3 * i], p[3 * i + 1], p[3 * i + 2])
	return out


static func _dist_d(a: PackedFloat64Array, i: int, b: PackedFloat64Array, j: int) -> float:
	var dx := a[3 * i] - b[3 * j]
	var dy := a[3 * i + 1] - b[3 * j + 1]
	var dz := a[3 * i + 2] - b[3 * j + 2]
	return sqrt(dx * dx + dy * dy + dz * dz)


## The selection's vertices that may move (locked ones left out); the whole cage for a body (or,
## with whole_when_empty, an empty) selection.
static func _free_vertices(c: Dictionary, sel: Dictionary, whole_when_empty := false) -> PackedInt32Array:
	var verts := FORM_OPS._sel_vertices(c, sel, whole_when_empty)
	var locked := FORM_OPS.locked_set(c)
	var out := PackedInt32Array()
	for v in verts:
		if not locked[v]:
			out.append(v)
	return out


## Writes the listed vertices of np into a copy of c (others keep their bits), then makes the
## partners exact.
static func _write(c: Dictionary, np: PackedFloat64Array, verts: PackedInt32Array) -> Dictionary:
	var out := CAGE.copy(c)
	var p: PackedFloat64Array = out.positions
	for v in verts:
		for k in 3:
			p[3 * v + k] = np[3 * v + k]
	out.positions = p
	if FORM_OPS._has_symmetry(out):
		out = FORM_OPS.apply_symmetry(out, verts).cage
	return out


# --- Sampling and fitting ------------------------------------------------------------------------

## Limit-surface sample locations over faces: an n x n grid (ends included) per quad, an m x m grid
## per sub-face of every other face. {"faces": PackedInt32Array, "uvs": PackedVector2Array}.
static func face_samples(subd: RefCounted, c: Dictionary, faces: PackedInt32Array, n := SAMPLES) -> Dictionary:
	var counts: PackedInt32Array = c.face_counts
	var fl := PackedInt32Array()
	var uvs := PackedVector2Array()
	var m := maxi(2, (n + 2) / 2)
	for f in faces:
		if counts[f] == 4:
			for j in n:
				for i in n:
					fl.append(f)
					uvs.append(Vector2(float(i) / (n - 1), float(j) / (n - 1)))
		else:
			for k in counts[f]:
				for j in m:
					for i in m:
						fl.append(f)
						uvs.append(subd.subface_uv(f, k, float(i) / (m - 1), float(j) / (m - 1)))
	return {"faces": fl, "uvs": uvs}


## The faces whose limit the given vertices move: every face within the 2-ring of faces around
## them (a Catmull-Clark control point reaches that far).
static func support_faces(topo: CAGE.Topo, verts: PackedInt32Array) -> PackedInt32Array:
	var near := PackedByteArray()
	near.resize(topo.nV)
	for v in verts:
		near[v] = 1
		for f in topo.vertex_faces(v):
			for h in range(topo.face_offsets[f], topo.face_offsets[f + 1]):
				near[topo.face_indices[h]] = 1
	var out := PackedInt32Array()
	for f in topo.nF:
		for h in range(topo.face_offsets[f], topo.face_offsets[f + 1]):
			if near[topo.face_indices[h]]:
				out.append(f)
				break
	return out


## The Exact modes' fit. After a Simple topology edit turned old_cage into new_cage, the vertices
## near the edit (the new ones and the vertices of the faces around them; locked ones stay) are
## fitted in least squares so the new limit surface lies back on the old one: REFIT_ROUNDS rounds
## of sampling the new limit over every face those vertices move, taking the closest points on the
## old limit as targets and fitting. Partners are made exact afterwards. Returns {"cage",
## "max_deviation" (meters, over the samples), "relative" (to the old mean edge length),
## "error"}.
static func refit(old_cage: Dictionary, new_cage: Dictionary, new_vertices: PackedInt32Array, rounds := REFIT_ROUNDS, free_in := PackedInt32Array()) -> Dictionary:
	if new_vertices.is_empty() and free_in.is_empty():
		return {"cage": new_cage, "max_deviation": 0.0, "relative": 0.0, "error": ""}
	var so := subd_of(old_cage)
	if so.has("error"):
		return {"error": so.error}
	var sn := subd_of(new_cage)
	if sn.has("error"):
		return {"error": sn.error}
	var old: RefCounted = so.subd
	var subd: RefCounted = sn.subd
	var topo := CAGE.topology(new_cage)
	var locked := FORM_OPS.locked_set(new_cage)
	var mark := PackedByteArray()
	mark.resize(topo.nV)
	if free_in.is_empty():
		for v in new_vertices:
			mark[v] = 1
			for f in topo.vertex_faces(v):
				for h in range(topo.face_offsets[f], topo.face_offsets[f + 1]):
					mark[topo.face_indices[h]] = 1
	else:
		for v in free_in:
			mark[v] = 1
	var free := PackedInt32Array()
	for v in topo.nV:
		if mark[v] and not locked[v]:
			free.append(v)
	var cage := CAGE.copy(new_cage)
	if free.is_empty():
		return {"cage": cage, "max_deviation": 0.0, "relative": 0.0, "error": ""}
	var samples := face_samples(subd, cage, support_faces(topo, free))
	var fl: PackedInt32Array = samples.faces
	var uvs: PackedVector2Array = samples.uvs
	for r in rounds:
		var ev: Dictionary = subd.evaluate(fl, uvs)
		var cp: Dictionary = old.closest_points(_to_v3(ev.get("positions", PackedFloat64Array())))
		var targets: PackedFloat64Array = cp.get("positions", PackedFloat64Array())
		if targets.size() != 3 * fl.size():
			return {"error": "The old surface could not be sampled (%s)" % old.get_last_error()}
		var np: PackedFloat64Array = subd.fit(fl, uvs, targets, free)
		if np.size() != (cage.positions as PackedFloat64Array).size():
			return {"error": "The fit failed (%s)" % subd.get_last_error()}
		var p: PackedFloat64Array = cage.positions
		for v in free:
			for k in 3:
				p[3 * v + k] = np[3 * v + k]
		cage.positions = p
		subd.set_positions(p)
	if FORM_OPS._has_symmetry(cage):
		cage = FORM_OPS.apply_symmetry(cage, free).cage
		subd.set_positions(cage.positions)
	# Reported over a grid twice as fine as the fit's (the fit's own samples under-reported the
	# deviation between them: 0.0200 for a measured 0.0228).
	var fine := face_samples(subd, cage, support_faces(topo, free), 2 * SAMPLES - 1)
	var ev2: Dictionary = subd.evaluate(fine.faces, fine.uvs)
	var cp2: Dictionary = old.closest_points(_to_v3(ev2.get("positions", PackedFloat64Array())))
	var worst := 0.0
	for d in (cp2.get("distances", PackedFloat64Array()) as PackedFloat64Array):
		worst = maxf(worst, d)
	var size := maxf(CAGE.mean_edge_length(old_cage), 1e-12)
	return {"cage": cage, "max_deviation": worst, "relative": worst / size, "error": "", "free": free}


## A Simple result made Exact: the refit around its new vertices (info gains max_deviation and
## relative_deviation).
static func _exact(c: Dictionary, r: Dictionary) -> Dictionary:
	if not r.ok:
		return r
	if not available():
		return _err(c, "Exact mode needs the Holo Forge kernel.")
	var fit := refit(c, r.cage, (r.info as Dictionary).get("new_vertices", PackedInt32Array()))
	if fit.has("error") and str(fit.error) != "":
		return _err(c, str(fit.error))
	var info: Dictionary = (r.info as Dictionary).duplicate()
	info.max_deviation = fit.max_deviation
	info.relative_deviation = fit.relative
	return _ok(c, fit.cage, r.selection, r.warnings, info)


# --- Exact inserts --------------------------------------------------------------------------------

## Insert Edge; opts.mode "exact" refits the surface around the new loop (info.max_deviation).
static func insert_edge(c: Dictionary, sel: Dictionary, opts: Dictionary) -> Dictionary:
	var o := opts.duplicate()
	var exact := str(o.get("mode", "simple")).to_lower() == "exact"
	o.mode = "simple"
	var r := FORM_OPS.insert_edge(c, sel, o)
	return _exact(c, r) if exact else r


## Subdivide; opts.mode "exact": a 2 x 2 split of whole components is one Catmull-Clark step
## (exact); anything else is the Simple split refitted.
static func subdivide(c: Dictionary, sel: Dictionary, opts: Dictionary) -> Dictionary:
	var exact := str(opts.get("mode", "simple")).to_lower() == "exact"
	if not exact:
		return FORM_OPS.subdivide(c, sel, opts)
	var nu := int(opts.get("u_faces", 2))
	var nv := int(opts.get("v_faces", 2))
	var faces := FORM_OPS._list(sel, "faces")
	var topo := CAGE.topology(c)
	if not faces.is_empty() and nu == 2 and nv == 2:
		var all := faces
		if FORM_OPS._has_symmetry(c):
			all = FORM_OPS.partner_selection(c, {"faces": faces}).faces
		if FORM_OPS._whole_components(topo, all):
			var r := FORM_OPS.subdivide(c, sel, opts)
			if r.ok:
				r.info.max_deviation = 0.0
				r.info.relative_deviation = 0.0
				r.info.catmull_clark = true
			return r
	var o := opts.duplicate()
	o.mode = "simple"
	return _exact(c, FORM_OPS.subdivide(c, sel, o))


## Insert Point; opts.mode "exact" refits around the new points.
static func insert_point(c: Dictionary, sel: Dictionary, opts: Dictionary) -> Dictionary:
	var o := opts.duplicate()
	var exact := str(o.get("mode", "simple")).to_lower() == "exact"
	o.mode = "simple"
	var r := FORM_OPS.insert_point(c, sel, o)
	return _exact(c, r) if exact else r


# --- Surface points: moving limit points onto targets -----------------------------------------------

## Moves the free vertices so the limit point of each targeted vertex lands on its target (targets:
## {vertex: Vector3 or PackedFloat64Array(3)}); free vertices without a target keep their limit
## point. {"cage", "residual" (meters), "error"}.
static func solve_limit_targets(c: Dictionary, targets: Dictionary, free: PackedInt32Array) -> Dictionary:
	var s := subd_of(c)
	if s.has("error"):
		return {"error": s.error}
	var subd: RefCounted = s.subd
	var lp: PackedFloat64Array = (subd.limit_points() as Dictionary).get("positions", PackedFloat64Array())
	if lp.size() != (c.positions as PackedFloat64Array).size():
		return {"error": "The limit points could not be computed (%s)" % subd.get_last_error()}
	var t := lp.duplicate()
	for v in targets:
		var q := FORM_OPS._d3(targets[v])
		for k in 3:
			t[3 * int(v) + k] = q[k]
	# A light pull toward the current points (only singular directions need it).
	var np: PackedFloat64Array = subd.interpolate(t, free, 1e-10)
	if np.size() != t.size():
		return {"error": "The surface could not be fitted (%s)" % subd.get_last_error()}
	var out := CAGE.copy(c)
	var p: PackedFloat64Array = out.positions
	for v in free:
		for k in 3:
			p[3 * v + k] = np[3 * v + k]
	out.positions = p
	subd.set_positions(p)
	var lp2: PackedFloat64Array = (subd.limit_points() as Dictionary).get("positions", PackedFloat64Array())
	var worst := 0.0
	for v in free:
		worst = maxf(worst, _dist_d(lp2, v, t, v))
	return {"cage": out, "residual": worst, "error": ""}


## The limit points of the cage (3 doubles per vertex), or empty with the reason in r.error.
static func limit_positions(c: Dictionary) -> Dictionary:
	var s := subd_of(c)
	if s.has("error"):
		return {"error": s.error}
	var lp: PackedFloat64Array = (s.subd.limit_points() as Dictionary).get("positions", PackedFloat64Array())
	return {"positions": lp, "subd": s.subd, "error": ""}


## Flatten: opts.type "surface" puts the limit points of the vertices on the plane (fit: the plane
## of their limit points); "control" is form_ops' cage version.
static func flatten(c: Dictionary, sel: Dictionary, opts: Dictionary) -> Dictionary:
	if not str(opts.get("type", "control")).to_lower().begins_with("surf"):
		return FORM_OPS.flatten(c, sel, opts)
	var verts := FORM_OPS._sel_vertices(c, sel)
	var free := _free_vertices(c, sel)
	var dir := str(opts.get("direction", "fit")).to_lower()
	if dir.begins_with("fit") and verts.size() < 3:
		return _err(c, "Pick at least three vertices to fit a plane.")
	if verts.is_empty():
		return _err(c, "Pick vertices to flatten.")
	if free.is_empty():
		return _err(c, "Those vertices are frozen.")
	var lr := limit_positions(c)
	if str(lr.error) != "":
		return _err(c, str(lr.error))
	var lp: PackedFloat64Array = lr.positions
	var pts := PackedFloat64Array()
	for v in verts:
		pts.append_array(PackedFloat64Array([lp[3 * v], lp[3 * v + 1], lp[3 * v + 2]]))
	var o: PackedFloat64Array
	var n: PackedFloat64Array
	if dir.begins_with("fit"):
		var fit := FORM_OPS.best_fit_plane(pts)
		o = fit.origin
		n = fit.normal
	else:
		var plane: Dictionary = opts.get("plane", {})
		if plane.is_empty():
			return _err(c, "Pick a plane.")
		n = FORM_OPS.unit_d(FORM_OPS._d3(plane.get("normal", Vector3.UP)))
		o = FORM_OPS._d3(plane.get("origin", Vector3.ZERO))
		if dir.begins_with("par"):
			o = FORM_OPS.best_fit_plane(pts).origin
	var targets := {}
	for v in free:
		var d := (lp[3 * v] - o[0]) * n[0] + (lp[3 * v + 1] - o[1]) * n[1] + (lp[3 * v + 2] - o[2]) * n[2]
		targets[v] = PackedFloat64Array([lp[3 * v] - d * n[0], lp[3 * v + 1] - d * n[1], lp[3 * v + 2] - d * n[2]])
	var r := solve_limit_targets(c, targets, free)
	if str(r.get("error", "")) != "":
		return _err(c, str(r.error))
	var out := _write(c, r.cage.positions, free)
	return _ok(c, out, sel, PackedStringArray(), {"origin": o, "normal": n, "moved": free, "residual": r.residual})


## Straighten: opts.type "surface" puts the limit points on the line; "control" is form_ops'.
static func straighten(c: Dictionary, sel: Dictionary, opts: Dictionary) -> Dictionary:
	if not str(opts.get("type", "control")).to_lower().begins_with("surf"):
		return FORM_OPS.straighten(c, sel, opts)
	var verts := FORM_OPS._sel_vertices(c, sel)
	var free := _free_vertices(c, sel)
	if verts.size() < 2:
		return _err(c, "Pick at least two vertices to straighten.")
	if free.is_empty():
		return _err(c, "Those vertices are frozen.")
	var lr := limit_positions(c)
	if str(lr.error) != "":
		return _err(c, str(lr.error))
	var lp: PackedFloat64Array = lr.positions
	var pts := PackedFloat64Array()
	for v in verts:
		pts.append_array(PackedFloat64Array([lp[3 * v], lp[3 * v + 1], lp[3 * v + 2]]))
	var dir := str(opts.get("direction", "fit")).to_lower()
	var o: PackedFloat64Array
	var a: PackedFloat64Array
	if dir.begins_with("fit"):
		var fit := FORM_OPS.best_fit_line(pts)
		o = fit.origin
		a = fit.direction
	elif dir.begins_with("two"):
		var two: Array = opts.get("points", [])
		if two.size() < 2:
			return _err(c, "Pick two points for the line.")
		o = FORM_OPS._d3(two[0])
		var q := FORM_OPS._d3(two[1])
		a = FORM_OPS.unit_d(PackedFloat64Array([q[0] - o[0], q[1] - o[1], q[2] - o[2]]))
	else:
		var line: Dictionary = opts.get("line", {})
		if line.is_empty():
			return _err(c, "Pick a line.")
		a = FORM_OPS.unit_d(FORM_OPS._d3(line.get("direction", Vector3.RIGHT)))
		o = FORM_OPS._d3(line.get("origin", Vector3.ZERO))
		if dir.begins_with("par"):
			o = FORM_OPS.best_fit_line(pts).origin
	var targets := {}
	for v in free:
		var t := (lp[3 * v] - o[0]) * a[0] + (lp[3 * v + 1] - o[1]) * a[1] + (lp[3 * v + 2] - o[2]) * a[2]
		targets[v] = PackedFloat64Array([o[0] + t * a[0], o[1] + t * a[1], o[2] + t * a[2]])
	var r := solve_limit_targets(c, targets, free)
	if str(r.get("error", "")) != "":
		return _err(c, str(r.error))
	var out := _write(c, r.cage.positions, free)
	return _ok(c, out, sel, PackedStringArray(), {"origin": o, "direction": a, "moved": free, "residual": r.residual})


# --- Pull -----------------------------------------------------------------------------------------

## The nearest point on any of shapes for each point: {"positions": PackedFloat64Array,
## "distances": PackedFloat64Array (INF where nothing was found)}.
static func project_points(points: PackedVector3Array, shapes: Array) -> Dictionary:
	var best := PackedFloat64Array()
	best.resize(3 * points.size())
	var dist := PackedFloat64Array()
	dist.resize(points.size())
	dist.fill(INF)
	if not available():
		return {"positions": best, "distances": dist}
	var probe: RefCounted = ClassDB.instantiate("CadSubD")
	for shape in shapes:
		if shape == null:
			continue
		var r: Dictionary = probe.project_to_shape(shape, points)
		var pos: PackedFloat64Array = r.get("positions", PackedFloat64Array())
		var ds: PackedFloat64Array = r.get("distances", PackedFloat64Array())
		if pos.size() != 3 * points.size() or ds.size() != points.size():
			continue
		for i in points.size():
			if ds[i] < dist[i]:
				dist[i] = ds[i]
				for k in 3:
					best[3 * i + k] = pos[3 * i + k]
	return {"positions": best, "distances": dist}


## Pull: opts "shapes" (Array of CadShape targets), "type" "control" (cage points onto the
## nearest target) | "surface" (limit points onto it: PULL_ROUNDS rounds of projecting the limit
## points and interpolating). Locked vertices are skipped.
static func pull(c: Dictionary, sel: Dictionary, opts: Dictionary) -> Dictionary:
	var shapes: Array = opts.get("shapes", [])
	if shapes.is_empty():
		return _err(c, "There is no body to pull to")
	var free := _free_vertices(c, sel)
	if FORM_OPS._sel_vertices(c, sel).is_empty():
		return _err(c, "Pick cage vertices to pull.")
	if free.is_empty():
		return _err(c, "Those vertices are frozen.")
	if not available():
		return _err(c, "Pull needs the Holo Forge kernel.")
	var surface := str(opts.get("type", "control")).to_lower().begins_with("surf")
	var cage := CAGE.copy(c)
	var worst := 0.0
	if not surface:
		var pts := PackedVector3Array()
		for v in free:
			pts.append(CAGE.position(c, v))
		var pr := project_points(pts, shapes)
		var p: PackedFloat64Array = cage.positions
		var moved := PackedInt32Array()
		for i in free.size():
			if is_inf(pr.distances[i]):
				continue
			var v := free[i]
			for k in 3:
				p[3 * v + k] = pr.positions[3 * i + k]
			moved.append(v)
			worst = maxf(worst, pr.distances[i])
		if moved.is_empty():
			return _err(c, "Nothing to pull to was found near those vertices.")
		cage.positions = p
		if FORM_OPS._has_symmetry(cage):
			cage = FORM_OPS.apply_symmetry(cage, moved).cage
		return _ok(c, cage, sel, PackedStringArray(), {"moved": moved, "max_distance": worst})
	var residual := 0.0
	for round in PULL_ROUNDS:
		var lr := limit_positions(cage)
		if str(lr.error) != "":
			return _err(c, str(lr.error))
		var lp: PackedFloat64Array = lr.positions
		var pts := PackedVector3Array()
		for v in free:
			pts.append(_v3(lp, v))
		var pr := project_points(pts, shapes)
		var targets := {}
		for i in free.size():
			if not is_inf(pr.distances[i]):
				targets[free[i]] = PackedFloat64Array([pr.positions[3 * i], pr.positions[3 * i + 1], pr.positions[3 * i + 2]])
				if round == 0:
					worst = maxf(worst, pr.distances[i])
		if targets.is_empty():
			return _err(c, "Nothing to pull to was found near those vertices.")
		var r := solve_limit_targets(cage, targets, free)
		if str(r.get("error", "")) != "":
			return _err(c, str(r.error))
		cage = r.cage
		residual = r.residual
	var out := _write(c, cage.positions, free)
	return _ok(c, out, sel, PackedStringArray(), {"moved": free, "max_distance": worst, "residual": residual})


# --- Interpolate ------------------------------------------------------------------------------------

## Interpolate: opts.mode "through" (the limit passes through the current cage points; residual
## reported) | "onto" (the cage points move onto their limit points). The selection's vertices
## (all for a body or nothing) take part; locked ones stay.
static func interpolate(c: Dictionary, sel: Dictionary, opts: Dictionary) -> Dictionary:
	var free := _free_vertices(c, sel, true)
	if free.is_empty():
		return _err(c, "Those vertices are frozen.")
	var mode := str(opts.get("mode", "through")).to_lower()
	var s := subd_of(c)
	if s.has("error"):
		return _err(c, str(s.error))
	var subd: RefCounted = s.subd
	var warnings := PackedStringArray()
	var info := {"moved": free}
	var np: PackedFloat64Array
	if mode.begins_with("onto"):
		np = (subd.limit_points() as Dictionary).get("positions", PackedFloat64Array())
		if np.size() != (c.positions as PackedFloat64Array).size():
			return _err(c, "The limit points could not be computed.")
	else:
		var targets: PackedFloat64Array = c.positions
		np = subd.interpolate(targets, free)
		if np.size() != targets.size():
			return _err(c, "The cage could not be interpolated (%s)." % subd.get_last_error())
		var trial := CAGE.copy(c)
		var p: PackedFloat64Array = trial.positions
		for v in free:
			for k in 3:
				p[3 * v + k] = np[3 * v + k]
		subd.set_positions(p)
		var lp: PackedFloat64Array = (subd.limit_points() as Dictionary).get("positions", PackedFloat64Array())
		var worst := 0.0
		for v in free:
			worst = maxf(worst, _dist_d(lp, v, targets, v))
		info.residual = worst
		if worst > 1e-9 * maxf(CAGE.diagonal(c), 1e-12):
			warnings.append("The surface passes the cage points within %s m (this cage has no exact solution)" % String.num_scientific(worst))
	var out := _write(c, np, free)
	return _ok(c, out, sel, warnings, info)


# --- Make Uniform ---------------------------------------------------------------------------------

## Make Uniform: opts "quads_only" (on: every face of the picked components becomes quads),
## "even" (off: evens out the spacing, then refits the old surface), "iterations" 1..20 (5). The
## components the selection touches take part (all for a body or nothing). info.max_deviation.
static func make_uniform(c: Dictionary, sel: Dictionary, opts: Dictionary) -> Dictionary:
	var topo := CAGE.topology(c)
	var verts := FORM_OPS._sel_vertices(c, sel, true)
	var comps := topo.components()
	var want := {}
	var vmark := PackedByteArray()
	vmark.resize(topo.nV)
	for v in verts:
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
		return _err(c, "Pick a body to make uniform.")
	var locked := FORM_OPS.locked_set(c)
	var warnings := PackedStringArray()
	var cage := CAGE.copy(c)
	var info := {"split": 0, "max_deviation": 0.0}
	if bool(opts.get("quads_only", true)):
		var others := false
		for f in faces:
			if topo.face_size(f) != 4:
				others = true
				break
		if others:
			if FORM_OPS._faces_locked(topo, locked, faces):
				return _err(c, CAGE.FROZEN_ERROR)
			var r := CAGE.split_to_quads(cage, faces)
			if str(r.error) != "":
				return _err(c, str(r.error))
			cage = FORM_OPS._resym(r.cage, r.get("new_vertices", PackedInt32Array()), warnings)
			info.split = (r.get("new_faces", PackedInt32Array()) as PackedInt32Array).size()
	if bool(opts.get("even", false)):
		if not available():
			return _err(c, "Even Spacing needs the Holo Forge kernel.")
		var before := cage
		var t2 := CAGE.topology(cage)
		var lock2 := FORM_OPS.locked_set(cage)
		var creases := CAGE.crease_map(cage)
		var corners := CAGE.corner_map(cage)
		var t_old := CAGE.topology(c)
		var oc := t_old.components()
		var picked_comps := {}
		for f in faces:
			picked_comps[oc[f]] = true
		var free := PackedInt32Array()
		for v in t2.nV:
			if lock2[v] or t2.is_boundary_vertex(v) or corners.has(v):
				continue
			var sharp := false
			for e in t2.vertex_edges(v):
				if creases.has(CAGE.edge_key(t2.edges[2 * e], t2.edges[2 * e + 1])):
					sharp = true
					break
			if sharp:
				continue
			var vf := t2.vertex_faces(v)
			if vf.is_empty():
				continue
			# Only vertices of the picked components (vertex ids of the originals keep their ids).
			if v < t_old.nV:
				var of := t_old.vertex_faces(v)
				if not of.is_empty() and not picked_comps.has(oc[of[0]]):
					continue
			free.append(v)
		var iterations := clampi(int(opts.get("iterations", 5)), 1, 20)
		var p: PackedFloat64Array = (cage.positions as PackedFloat64Array).duplicate()
		for it in iterations:
			var np := p.duplicate()
			var tmp := CAGE.copy(cage)
			tmp.positions = p
			for v in free:
				var nb := t2.vertex_neighbors(v)
				if nb.is_empty():
					continue
				var m := Vector3.ZERO
				for w in nb:
					m += _v3(p, w)
				m /= nb.size()
				var pv := _v3(p, v)
				var n := t2.vertex_normal(tmp, v)
				var d := (m - pv) * 0.5
				d -= n * d.dot(n)
				np[3 * v] = p[3 * v] + d.x
				np[3 * v + 1] = p[3 * v + 1] + d.y
				np[3 * v + 2] = p[3 * v + 2] + d.z
			p = np
		var moved := CAGE.copy(cage)
		moved.positions = p
		var fit := refit(before, moved, PackedInt32Array(), 2, free)
		if str(fit.get("error", "")) != "":
			return _err(c, str(fit.error))
		cage = fit.cage
		info.max_deviation = fit.max_deviation
		info.relative_deviation = fit.relative
		info.moved = free
	if CAGE.content_hash(cage) == CAGE.content_hash(c):
		return _err(c, FORM_OPS.NOTHING)
	return _ok(c, cage, {}, warnings, info)


# --- Repair ---------------------------------------------------------------------------------------

## Repair Body: form_ops' pure repair, then the kernel's check for faces that cut through each
## other (reported, not fixed: info.self_intersections and error markers).
static func repair(c: Dictionary, sel: Dictionary, opts: Dictionary) -> Dictionary:
	var r := FORM_OPS.repair(c, sel, opts)
	if not r.ok:
		return r
	var info: Dictionary = (r.info as Dictionary).duplicate()
	info.self_intersections = 0
	if available():
		var probe: RefCounted = ClassDB.instantiate("CadSubD")
		var cage: Dictionary = r.cage if str(opts.get("mode", "fix")).to_lower() != "report" else c
		var check: Dictionary = probe.check_cage(cage, true)
		var hits: PackedInt32Array = check.get("self_intersecting_faces", PackedInt32Array())
		info.self_intersections = hits.size()
		var markers: Array = (info.get("markers", []) as Array).duplicate()
		var offs := CAGE.face_offsets(cage)
		var idx: PackedInt32Array = cage.get("face_indices", PackedInt32Array())
		for f in hits:
			if f < 0 or f + 1 >= offs.size():
				continue
			var verts := PackedInt32Array()
			for h in range(offs[f], offs[f + 1]):
				verts.append(idx[h])
			markers.append({"severity": "error", "label": "Self-intersection", "position": CAGE._centroid(cage.positions, verts)})
		info.markers = markers
		if hits.size() > 0:
			var warnings: PackedStringArray = (r.warnings as PackedStringArray).duplicate()
			warnings.append("%d faces cut through each other; move them apart (Repair doesn't fix that)" % hits.size())
			r.warnings = warnings
	r.info = info
	return r


# --- Convert ----------------------------------------------------------------------------------------

## Form to B-rep: {"shapes": Array of CadShape (one per connected component), "bytes": Array of
## PackedByteArray, "report", "error"}.
static func to_breps(c: Dictionary, isolation: int, prefix: String) -> Dictionary:
	var s := subd_of(c)
	if s.has("error"):
		return {"error": s.error}
	if CAGE.face_count(c) == 0:
		return {"error": "The cage has no faces"}
	var subd: RefCounted = s.subd
	var shapes: Array = subd.to_shapes({"isolation": isolation, "name_prefix": prefix})
	if shapes.is_empty():
		var why := str(subd.get_last_error())
		return {"error": why if why != "" else "The smooth surface could not be converted"}
	var bytes := []
	for shape in shapes:
		bytes.append(shape.to_brep_bytes())
	return {"shapes": shapes, "bytes": bytes, "report": subd.get_last_report(), "error": ""}


## Face to Form: a grid cage over a four-sided B-rep face. nu / nv <= 0 pick the counts from the
## face's sides (clamp(ceil(side / (0.15 x diagonal)), 3, 16)); with fit the limit passes through
## the face's grid samples. {"cage", "samples": PackedFloat64Array, "residual", "error"}.
static func face_to_cage(shape: RefCounted, face_index: int, nu := 0, nv := 0, fit := true) -> Dictionary:
	if not available():
		return {"error": NEEDS_KERNEL}
	var probe: RefCounted = ClassDB.instantiate("CadSubD")
	if nu <= 0 or nv <= 0:
		var coarse: Dictionary = probe.face_grid(shape, face_index, 16, 16)
		if not bool(coarse.get("ok", false)):
			return {"error": str(coarse.get("error", "That face can't become a cage"))}
		var g: PackedFloat64Array = coarse.positions
		var lu := 0.0
		var lv := 0.0
		var lo := Vector3(INF, INF, INF)
		var hi := -lo
		for j in 17:
			for i in 17:
				var q := _v3(g, j * 17 + i)
				lo = lo.min(q)
				hi = hi.max(q)
		for i in 16:
			lu += _v3(g, i).distance_to(_v3(g, i + 1))
			lv += _v3(g, i * 17).distance_to(_v3(g, (i + 1) * 17))
		var diag := maxf((hi - lo).length(), 1e-12)
		if nu <= 0:
			nu = clampi(ceili(lu / (0.15 * diag)), 3, 16)
		if nv <= 0:
			nv = clampi(ceili(lv / (0.15 * diag)), 3, 16)
	var grid: Dictionary = probe.face_grid(shape, face_index, nu, nv)
	if not bool(grid.get("ok", false)):
		return {"error": str(grid.get("error", "That face can't become a cage"))}
	var pos: PackedFloat64Array = grid.positions
	var reversed := bool(grid.get("reversed", false))
	var counts := PackedInt32Array()
	var idx := PackedInt32Array()
	for j in nv:
		for i in nu:
			var a := j * (nu + 1) + i
			var quad := PackedInt32Array([a, a + 1, a + nu + 2, a + nu + 1])
			if reversed:
				quad = PackedInt32Array([a, a + nu + 1, a + nu + 2, a + 1])
			counts.append(4)
			idx.append_array(quad)
	var cage := CAGE.make(pos.duplicate(), counts, idx)
	var residual := 0.0
	if fit:
		var s := subd_of(cage)
		if s.has("error"):
			return {"error": s.error}
		var np: PackedFloat64Array = s.subd.interpolate(pos, PackedInt32Array())
		if np.size() != pos.size():
			return {"error": "The grid could not be fitted (%s)" % s.subd.get_last_error()}
		cage.positions = np
		s.subd.set_positions(np)
		var lp: PackedFloat64Array = (s.subd.limit_points() as Dictionary).get("positions", PackedFloat64Array())
		for v in pos.size() / 3:
			residual = maxf(residual, _dist_d(lp, v, pos, v))
	return {"cage": cage, "samples": pos, "residual": residual, "nu": nu, "nv": nv, "error": ""}


## Mesh to Form: a cage from polygons (points: PackedVector3Array or PackedFloat64Array; faces:
## Array of PackedInt32Array, counter-clockwise from outside). opts "merge" (triangle pairs to quads,
## on), "tolerance" (weld distance; 0 = none). {"cage", "error", "info"}.
static func mesh_to_cage(points: Variant, faces: Array, opts := {}) -> Dictionary:
	var pos := PackedFloat64Array()
	if points is PackedVector3Array:
		for q in (points as PackedVector3Array):
			pos.append_array(PackedFloat64Array([q.x, q.y, q.z]))
	else:
		pos = PackedFloat64Array(points)
	var counts := PackedInt32Array()
	var idx := PackedInt32Array()
	var nV := pos.size() / 3
	for face in faces:
		var poly := PackedInt32Array(face)
		var clean := PackedInt32Array()
		for v in poly:
			if v >= 0 and v < nV and (clean.is_empty() or clean[clean.size() - 1] != v):
				clean.append(v)
		while clean.size() > 1 and clean[0] == clean[clean.size() - 1]:
			clean.resize(clean.size() - 1)
		if clean.size() >= 3:
			counts.append(clean.size())
			idx.append_array(clean)
	if counts.is_empty():
		return {"error": "The mesh has no faces"}
	var cage := CAGE.make(pos, counts, idx)
	var info := {"welded": 0, "merged": 0, "flipped": 0}
	var tol := float(opts.get("tolerance", 0.0))
	if tol > 0.0:
		var w := FORM_OPS.weld_vertices(cage, {}, {"mode": "tolerance", "tolerance": tol})
		if w.ok:
			cage = w.cage
			info.welded = int(w.info.get("welded", 0))
	cage = CAGE.compact(cage).cage
	var o := CAGE.orient_consistently(cage)
	if str(o.error) != "":
		return {"error": str(o.error)}
	cage = o.cage
	info.flipped = (o.flipped as PackedInt32Array).size()
	if bool(opts.get("merge", true)):
		var has_triangles := false
		for n in (cage.face_counts as PackedInt32Array):
			if n == 3:
				has_triangles = true
				break
		if has_triangles:
			var m := CAGE.merge_triangle_pairs(cage)
			cage = m.cage
			info.merged = int(m.merged)
	var problems := CAGE.validate(cage)
	if not problems.is_empty():
		return {"error": "The mesh can't become a cage (%s); try Repair Body after converting" % problems[0]}
	return {"cage": cage, "error": "", "info": info}


# --- Polylines (Match, Edit By Curve) ---------------------------------------------------------------

## An ordered polyline through a wire's edges: {"points": PackedFloat64Array, "closed": bool}
## ({"error"} when the edges don't make one chain).
static func wire_polyline(wire: RefCounted, per_edge := 48) -> Dictionary:
	if wire == null:
		return {"error": "No curve"}
	var pieces: Array = []
	var total := 0.0
	for e in wire.edge_count():
		var info: Dictionary = wire.edge_info(e)
		var steps := 1 if str(info.get("type", "")) == "line" else per_edge
		var pts := PackedVector3Array()
		for k in steps + 1:
			var r: Dictionary = wire.edge_point_at_length(e, float(k) / steps)
			if r.is_empty():
				return {"error": "The curve could not be sampled"}
			pts.append(r.point)
		total += float(info.get("length", 0.0))
		pieces.append(pts)
	if pieces.is_empty():
		return {"error": "No curve"}
	var tol := maxf(total * 1e-6, 1e-9)
	var line: PackedVector3Array = pieces.pop_front()
	var guard := pieces.size() + 1
	while not pieces.is_empty() and guard > 0:
		guard -= 1
		for i in pieces.size():
			var piece: PackedVector3Array = pieces[i]
			var head := piece[0]
			var tail := piece[piece.size() - 1]
			var done := true
			if head.distance_to(line[line.size() - 1]) <= tol:
				line.append_array(piece.slice(1))
			elif tail.distance_to(line[line.size() - 1]) <= tol:
				var rev := piece.duplicate()
				rev.reverse()
				line.append_array(rev.slice(1))
			elif tail.distance_to(line[0]) <= tol:
				var joined := piece.duplicate()
				joined.append_array(line.slice(1))
				line = joined
			elif head.distance_to(line[0]) <= tol:
				var rev := piece.duplicate()
				rev.reverse()
				rev.append_array(line.slice(1))
				line = rev
			else:
				done = false
			if done:
				pieces.remove_at(i)
				break
	if not pieces.is_empty():
		return {"error": "The curves don't make one chain"}
	var closed := line.size() > 2 and line[0].distance_to(line[line.size() - 1]) <= tol
	var out := PackedFloat64Array()
	for q in line:
		out.append_array(PackedFloat64Array([q.x, q.y, q.z]))
	return {"points": out, "closed": closed}


## A polyline resampled at count points (both ends included for open ones; closed ones start at the
## first point and leave out the repeat): "uniform" equal arc length, "curvature" equal steps of
## the integral of 1 + (L / 2 pi) |kappa| ds.
static func resample(points: PackedFloat64Array, count: int, closed: bool, spacing := "uniform") -> PackedFloat64Array:
	var n := points.size() / 3
	var measure := PackedFloat64Array()
	measure.resize(n)
	var seg := PackedFloat64Array()
	seg.resize(maxi(n - 1, 0))
	var length := 0.0
	for i in n - 1:
		seg[i] = _dist_d(points, i, points, i + 1)
		length += seg[i]
	var curvature := spacing.to_lower().begins_with("curv")
	var acc := 0.0
	for i in n - 1:
		var w := 1.0
		if curvature:
			var kappa := 0.0
			for j in [i, i + 1]:
				if j <= 0 or j >= n - 1:
					continue
				var a := _v3(points, j) - _v3(points, j - 1)
				var b := _v3(points, j + 1) - _v3(points, j)
				var ang := a.angle_to(b)
				kappa = maxf(kappa, ang / maxf(0.5 * (a.length() + b.length()), 1e-15))
			w = 1.0 + length / TAU * kappa
		acc += seg[i] * w
		measure[i + 1] = acc
	var out := PackedFloat64Array()
	var steps := count if closed else count - 1
	for k in count:
		var target := acc * float(k) / maxf(steps, 1)
		var i := 0
		while i < n - 2 and measure[i + 1] < target:
			i += 1
		var span := measure[i + 1] - measure[i]
		var t := (target - measure[i]) / span if span > 0.0 else 0.0
		t = clampf(t, 0.0, 1.0)
		for d in 3:
			out.append(points[3 * i + d] + (points[3 * (i + 1) + d] - points[3 * i + d]) * t)
	return out


## An open or closed chain of cage edges in order: {"verts": PackedInt32Array, "closed"} or {"error"}.
static func edge_chain(c: Dictionary, pairs: PackedInt32Array, topo = null) -> Dictionary:
	var t: CAGE.Topo = topo if topo != null else CAGE.topology(c)
	var chain := FORM_OPS._chain_from_pairs(t, pairs)
	if chain.is_empty():
		return {"error": "Pick one connected chain of edges with no branches"}
	for i in pairs.size() / 2:
		if t.edge_index(pairs[2 * i], pairs[2 * i + 1]) < 0:
			return {"error": "%d-%d is not an edge." % [pairs[2 * i], pairs[2 * i + 1]]}
	return {"verts": chain.loop, "closed": chain.closed}


# --- Match ---------------------------------------------------------------------------------------------

## Match: the boundary chain sel.edges takes the shape of a target curve. opts: "points" (the
## target polyline, PackedFloat64Array), "closed" (the target is a loop), "continuity" "g0" | "g1"
## | "g2", "spacing" "uniform" | "curvature", "falloff" rows 0..3 (1), "reverse" (flip the mapping),
## "normal_at" Callable(point: Vector3, away: Vector3) -> Vector3 (the target face's normal there;
## needed for G1 / G2), "link" (a link dictionary appended to cage.links: Associative).
## G0 interpolates the chain's limit onto the samples; G1 / G2 lay the first / second inner rows
## along the target face's tangent plane; falloff rows blend the move out.
static func match_chain(c: Dictionary, sel: Dictionary, opts: Dictionary) -> Dictionary:
	var pairs := FORM_OPS._list(sel, "edges")
	if pairs.is_empty():
		return _err(c, "Pick the form's open boundary edges to match.")
	var topo := CAGE.topology(c)
	for i in pairs.size() / 2:
		var e := topo.edge_index(pairs[2 * i], pairs[2 * i + 1])
		if e < 0 or not topo.is_boundary_edge(e):
			return _err(c, "Match works on open boundary edges.")
	var chain := edge_chain(c, pairs, topo)
	if chain.has("error"):
		return _err(c, str(chain.error))
	var verts: PackedInt32Array = chain.verts
	var closed: bool = chain.closed
	var target: PackedFloat64Array = opts.get("points", PackedFloat64Array())
	if target.size() < 6:
		return _err(c, "Pick the curves or edges to match to.")
	var target_closed := bool(opts.get("closed", false))
	if closed != target_closed:
		return _err(c, "A closed loop of edges matches a closed curve, an open chain an open one.")
	if not available():
		return _err(c, "Match needs the Holo Forge kernel.")
	var m := verts.size()
	var samples := resample(target, m, closed, str(opts.get("spacing", "uniform")))
	var p: PackedFloat64Array = c.positions
	# Alignment: the direction (and for loops the start) with the smaller total distance.
	var order := PackedInt32Array()
	var best := INF
	for dir in [1, -1]:
		for rot in (m if closed else 1):
			var cand := PackedInt32Array()
			var total := 0.0
			for i in m:
				var j: int = ((rot + dir * i) % m + m) % m if closed else (i if dir == 1 else m - 1 - i)
				cand.append(j)
				total += _dist_d(p, verts[i], samples, j)
			if total < best - 1e-15:
				best = total
				order = cand
	if bool(opts.get("reverse", false)):
		var flipped := PackedInt32Array()
		for i in m:
			flipped.append((m - 1 - order[i]) if not closed else ((m - order[i]) % m))
		order = flipped
	var locked := FORM_OPS.locked_set(c)
	var free := PackedInt32Array()
	var targets := {}
	for i in m:
		var v := verts[i]
		if locked[v]:
			continue
		free.append(v)
		var j := order[i]
		targets[v] = PackedFloat64Array([samples[3 * j], samples[3 * j + 1], samples[3 * j + 2]])
	if free.is_empty():
		return _err(c, "Those edges are frozen.")
	var continuity := str(opts.get("continuity", "g0")).to_lower()
	var falloff := clampi(int(opts.get("falloff", 1)), 0, 3)
	var normal_at: Callable = opts.get("normal_at", Callable())
	if continuity != "g0" and not normal_at.is_valid():
		return _err(c, "G1 and G2 need model edges with a face next to them.")
	var solved := solve_limit_targets(c, targets, free)
	if str(solved.get("error", "")) != "":
		return _err(c, str(solved.error))
	var out: Dictionary = solved.cage
	var np: PackedFloat64Array = (out.positions as PackedFloat64Array).duplicate()
	var moved := free.duplicate()
	# Columns from each chain vertex into the surface: v, its one inner neighbour, onwards.
	var on_chain := {}
	for v in verts:
		on_chain[v] = true
	var rows := 1 + (1 if continuity == "g1" else (2 if continuity == "g2" else 0)) + falloff
	var lp_out := limit_positions(out)
	var limit: PackedFloat64Array = lp_out.get("positions", PackedFloat64Array())
	for i in m:
		var v := verts[i]
		var column := PackedInt32Array([v])
		var inner := PackedInt32Array()
		for w in topo.vertex_neighbors(v):
			if not on_chain.has(w) and topo.edge_index(v, w) >= 0 and not topo.is_boundary_edge(topo.edge_index(v, w)):
				inner.append(w)
		if inner.size() != 1:
			continue
		column.append(inner[0])
		while column.size() < rows + 1:
			var a := column[column.size() - 2]
			var b := column[column.size() - 1]
			var dir := (_v3(p, b) - _v3(p, a)).normalized()
			var next := -1
			var score := 0.5
			for w in topo.vertex_neighbors(b):
				if w == a or column.has(w) or on_chain.has(w):
					continue
				var s := (_v3(p, w) - _v3(p, b)).normalized().dot(dir)
				if s > score:
					score = s
					next = w
			if next < 0:
				break
			column.append(next)
		var matched := 0
		var delta := Vector3(np[3 * v] - p[3 * v], np[3 * v + 1] - p[3 * v + 1], np[3 * v + 2] - p[3 * v + 2])
		if continuity != "g0" and column.size() > 1:
			var x := _v3(limit, v) if limit.size() == p.size() else _v3(np, v)
			var j := order[i]
			var ja := maxi(j - 1, 0)
			var jb := mini(j + 1, m - 1)
			if closed:
				ja = (j - 1 + m) % m
				jb = (j + 1) % m
			var tangent := (_v3(samples, jb) - _v3(samples, ja)).normalized()
			var d1 := _v3(p, column[1]) - _v3(p, v)
			var n: Vector3 = normal_at.call(x, -d1.normalized())
			if n.length() > 0.5 and tangent.length() > 0.5:
				var t := n.cross(tangent).normalized()
				if t.dot(d1) < 0.0:
					t = -t
				var cv := _v3(np, v)
				for k in range(1, mini(column.size(), 3 if continuity == "g2" else 2)):
					var w := column[k]
					if locked[w]:
						continue
					var dk := (_v3(p, w) - _v3(p, v)).length()
					var q := cv + t * dk
					delta = q - _v3(p, w)
					np[3 * w] = q.x
					np[3 * w + 1] = q.y
					np[3 * w + 2] = q.z
					moved.append(w)
					matched = k
		for r in falloff:
			var k := matched + 1 + r
			if k >= column.size():
				break
			var w := column[k]
			if locked[w]:
				continue
			var f := float(falloff - r) / (falloff + 1)
			np[3 * w] = p[3 * w] + delta.x * f
			np[3 * w + 1] = p[3 * w + 1] + delta.y * f
			np[3 * w + 2] = p[3 * w + 2] + delta.z * f
			moved.append(w)
	moved = CAGE.sorted_unique(moved)
	var result := _write(c, np, moved)
	var info := {"moved": moved, "residual": solved.residual, "samples": samples, "order": order}
	var link: Dictionary = opts.get("link", {})
	if not link.is_empty():
		var links: Array = (result.get("links", []) as Array).duplicate(true)
		var l := link.duplicate(true)
		var ordered := PackedInt32Array()
		for i in range(m - 1 + (1 if closed else 0)):
			ordered.append(verts[i])
			ordered.append(verts[(i + 1) % m])
		l["edges"] = ordered
		links.append(l)
		result["links"] = links
	return _ok(c, result, sel, PackedStringArray(), info)


## The polyline of target references (sketch curves, model edges) in a rebuild ctx: {"points",
## "closed", "normal_at" (for model edges: their bodies' face normals), "error"}.
static func target_polyline(refs: Array, ctx: Dictionary) -> Dictionary:
	if refs.is_empty():
		return {"error": "Pick the curves or edges to match to."}
	var found := REFERENCES.path(refs, ctx)
	if found.has("error"):
		return {"error": str(found.error)}
	var line := wire_polyline(found.wire)
	if line.has("error"):
		return line
	var shapes := []
	for ref in refs:
		if str(ref.get("kind", "")) == "edge":
			var e := REFERENCES.edge(ref, ctx)
			if not e.has("error") and not shapes.has(e.shape):
				shapes.append(e.shape)
	var out := {"points": line.points, "closed": line.closed, "error": ""}
	if not shapes.is_empty():
		var length := 0.0
		var pts: PackedFloat64Array = line.points
		for i in pts.size() / 3 - 1:
			length += _dist_d(pts, i, pts, i + 1)
		var eps := maxf(length * 1e-3, 1e-7)
		out["normal_at"] = func(point: Vector3, away: Vector3) -> Vector3:
			return _face_normal_near(shapes, point, away, eps)
	return out


## The normal of the face of shapes nearest point - away * eps (the face on the far side of the
## edge from the form), at point.
static func _face_normal_near(shapes: Array, point: Vector3, away: Vector3, eps: float) -> Vector3:
	if not available():
		return Vector3.ZERO
	var probe: RefCounted = ClassDB.instantiate("CadSubD")
	var best := INF
	var normal := Vector3.ZERO
	for shape in shapes:
		var r: Dictionary = probe.project_to_shape(shape, PackedVector3Array([point + away * eps]))
		var ds: PackedFloat64Array = r.get("distances", PackedFloat64Array())
		var fs: PackedInt32Array = r.get("faces", PackedInt32Array())
		if ds.size() == 1 and fs.size() == 1 and ds[0] < best and fs[0] >= 0:
			best = ds[0]
			normal = shape.face_normal_at(fs[0], point)
	return normal


## The cage with its associative Match links replayed against the current targets (ctx: a rebuild
## context with "bodies", "sketches", "kernel", "doc"). Links whose targets can't be found leave the
## cage as it is. The input is never changed.
## warnings (an Array, appended to) gets a sentence for every link that couldn't follow its
## targets this rebuild (a target that is gone or suppressed, a chain that no longer matches):
## the body then keeps its stored shape there, which must not pass silently.
static func apply_links(cage: Dictionary, ctx: Dictionary, warnings: Array = []) -> Dictionary:
	var links: Array = cage.get("links", [])
	if links.is_empty() or not available():
		return cage
	var out := cage
	for link in links:
		if not link is Dictionary:
			continue
		var refs: Array = link.get("targets", [])
		if refs.is_empty() and link.get("target") is Dictionary:
			refs = [link.target]
		var line := target_polyline(refs, ctx)
		if line.has("error") and str(line.error) != "":
			warnings.append("a Match link can't find its target (%s), so that edge keeps its last shape" % str(line.error).trim_suffix("."))
			continue
		var opts := {"points": line.points, "closed": line.closed, "continuity": str(link.get("continuity", "g0")),
			"spacing": str(link.get("spacing", "uniform")), "falloff": int(link.get("falloff", 1)), "reverse": bool(link.get("reverse", false))}
		if line.has("normal_at"):
			opts["normal_at"] = line.normal_at
		var pairs := link_chain(out, PackedInt32Array(link.get("edges", PackedInt32Array())))
		if pairs.is_empty():
			warnings.append("a Match link's edges were changed by a later edit, so it no longer follows its target (redo the Match)")
			continue
		var r := match_chain(out, {"edges": pairs}, opts)
		if r.ok:
			out = r.cage
		else:
			warnings.append("a Match link no longer follows its target (%s)" % str(r.error).trim_suffix("."))
	return out


## A link's stored edge pairs as edges of c now: a pair that a later edit split (Subdivide, Insert
## Edge or Insert Point across the chain) becomes the run of open boundary edges between its two
## ends. Empty when a pair can't be followed that way.
static func link_chain(c: Dictionary, pairs: PackedInt32Array) -> PackedInt32Array:
	var topo := CAGE.topology(c)
	var out := PackedInt32Array()
	for i in pairs.size() / 2:
		var a := pairs[2 * i]
		var b := pairs[2 * i + 1]
		if a < 0 or b < 0 or a >= topo.nV or b >= topo.nV:
			return PackedInt32Array()
		if topo.edge_index(a, b) >= 0:
			out.append(a)
			out.append(b)
			continue
		var path := _boundary_path(topo, a, b, 64)
		if path.size() < 2:
			return PackedInt32Array()
		for k in path.size() - 1:
			out.append(path[k])
			out.append(path[k + 1])
	return out


## The shortest run of open boundary edges from a to b (at most limit edges; empty when none).
static func _boundary_path(topo: CAGE.Topo, a: int, b: int, limit: int) -> PackedInt32Array:
	var prev := {a: -1}
	var frontier := PackedInt32Array([a])
	for step in limit:
		var next := PackedInt32Array()
		for u in frontier:
			for w in topo.vertex_neighbors(u):
				if prev.has(w):
					continue
				var e := topo.edge_index(u, w)
				if e < 0 or not topo.is_boundary_edge(e):
					continue
				prev[w] = u
				if w == b:
					var path := PackedInt32Array([b])
					var x := u
					while x >= 0:
						path.append(x)
						x = int(prev[x])
					path.reverse()
					return path
				next.append(w)
		if next.is_empty():
			break
		frontier = next
	return PackedInt32Array()


# --- Edit By Curve -------------------------------------------------------------------------------------

static func _bernstein(d: int, t: float) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	out.resize(d + 1)
	for k in d + 1:
		var binom := 1.0
		for j in k:
			binom = binom * (d - j) / (j + 1)
		out[k] = binom * pow(t, k) * pow(1.0 - t, d - k)
	return out


## The least-squares Bezier curve of a degree through points at params: control points (3 doubles
## each, degree + 1 of them).
static func bezier_fit(points: PackedFloat64Array, params: PackedFloat64Array, degree: int) -> PackedFloat64Array:
	var n := degree + 1
	var a: Array = []
	var rhs: Array = []
	for r in n:
		var row := PackedFloat64Array()
		row.resize(n)
		a.append(row)
		rhs.append(PackedFloat64Array([0.0, 0.0, 0.0]))
	for i in params.size():
		var b := _bernstein(degree, params[i])
		for r in n:
			var row: PackedFloat64Array = a[r]
			for k in n:
				row[k] += b[r] * b[k]
			a[r] = row
			var rr: PackedFloat64Array = rhs[r]
			for d in 3:
				rr[d] += b[r] * points[3 * i + d]
			rhs[r] = rr
	# Gaussian elimination with partial pivoting (n <= 8), three right-hand sides.
	for col in n:
		var piv := col
		for r in range(col + 1, n):
			if absf((a[r] as PackedFloat64Array)[col]) > absf((a[piv] as PackedFloat64Array)[col]):
				piv = r
		if piv != col:
			var tmp: PackedFloat64Array = a[col]
			a[col] = a[piv]
			a[piv] = tmp
			var tr: PackedFloat64Array = rhs[col]
			rhs[col] = rhs[piv]
			rhs[piv] = tr
		var pr: PackedFloat64Array = a[col]
		var pv := pr[col]
		if absf(pv) < 1e-300:
			continue
		for r in range(col + 1, n):
			var row: PackedFloat64Array = a[r]
			var f := row[col] / pv
			if f == 0.0:
				continue
			for k in range(col, n):
				row[k] -= f * pr[k]
			a[r] = row
			var rr: PackedFloat64Array = rhs[r]
			var rp: PackedFloat64Array = rhs[col]
			for d in 3:
				rr[d] -= f * rp[d]
			rhs[r] = rr
	var x: Array = []
	x.resize(n)
	for r in range(n - 1, -1, -1):
		var row: PackedFloat64Array = a[r]
		var acc: PackedFloat64Array = (rhs[r] as PackedFloat64Array).duplicate()
		for k in range(r + 1, n):
			var xk: PackedFloat64Array = x[k]
			for d in 3:
				acc[d] -= row[k] * xk[d]
		for d in 3:
			acc[d] = acc[d] / row[r] if absf(row[r]) > 1e-300 else 0.0
		x[r] = acc
	var out := PackedFloat64Array()
	for r in n:
		out.append_array(x[r])
	return out


## A Bezier curve's point at t (control: 3 doubles per control point).
static func bezier_point(control: PackedFloat64Array, t: float) -> Vector3:
	var d := control.size() / 3 - 1
	var b := _bernstein(d, t)
	var q := Vector3.ZERO
	for k in d + 1:
		q += _v3(control, k) * b[k]
	return q


## Edit By Curve's curve for a chain: {"verts" (chain order), "params", "control" (fitted control
## points), "degree", "plane" ({} unless planar)} or {"error"}. opts "degree" (3), "distribution"
## "uniform" | "edge_length", "planar", "points" (3 doubles per cage vertex to fit through instead
## of the cage points: the limit points in Surface Points mode).
static func chain_curve(c: Dictionary, pairs: PackedInt32Array, opts: Dictionary) -> Dictionary:
	if pairs.size() < 4:
		return {"error": "Pick an open chain of two or more edges"}
	var chain := edge_chain(c, pairs)
	if chain.has("error"):
		return {"error": "Pick an open chain of edges"}
	if bool(chain.closed):
		return {"error": "Pick an open chain of edges"}
	var verts: PackedInt32Array = chain.verts
	var p: PackedFloat64Array = opts.get("points", c.positions)
	if p.size() != (c.positions as PackedFloat64Array).size():
		p = c.positions
	var pts := PackedFloat64Array()
	for v in verts:
		pts.append_array(PackedFloat64Array([p[3 * v], p[3 * v + 1], p[3 * v + 2]]))
	var m := verts.size() - 1
	var params := PackedFloat64Array()
	params.resize(m + 1)
	if str(opts.get("distribution", "edge_length")).to_lower().begins_with("uni"):
		for i in m + 1:
			params[i] = float(i) / m
	else:
		var total := 0.0
		for i in m:
			total += _dist_d(pts, i, pts, i + 1)
		var acc := 0.0
		for i in m + 1:
			if i > 0:
				acc += _dist_d(pts, i - 1, pts, i)
			params[i] = acc / total if total > 0.0 else float(i) / m
	var plane := {}
	var fit_pts := pts
	if bool(opts.get("planar", false)) and verts.size() >= 3:
		var bf := FORM_OPS.best_fit_plane(pts)
		var o: PackedFloat64Array = bf.origin
		var n: PackedFloat64Array = bf.normal
		plane = {"origin": o, "normal": n}
		fit_pts = pts.duplicate()
		for i in m + 1:
			var d := (pts[3 * i] - o[0]) * n[0] + (pts[3 * i + 1] - o[1]) * n[1] + (pts[3 * i + 2] - o[2]) * n[2]
			for k in 3:
				fit_pts[3 * i + k] = pts[3 * i + k] - d * n[k]
	var degree := clampi(int(opts.get("degree", 3)), 1, 7)
	degree = mini(degree, m)
	return {"verts": verts, "params": params, "control": bezier_fit(fit_pts, params, degree), "degree": degree, "plane": plane}


## The edited control points: offsets (one Vector3 per control point) added, then xf (12 doubles,
## about the centroid of the selected points; empty = none) applied to the selected ones (all when
## selected is empty). A planar curve keeps its moved points in the plane.
static func edited_control(control: PackedFloat64Array, offsets: Array, selected: PackedInt32Array, xf: PackedFloat64Array, plane := {}) -> PackedFloat64Array:
	var out := control.duplicate()
	var n := control.size() / 3
	for k in mini(n, offsets.size()):
		var o: Variant = offsets[k]
		if o is Vector3:
			out[3 * k] += (o as Vector3).x
			out[3 * k + 1] += (o as Vector3).y
			out[3 * k + 2] += (o as Vector3).z
	if xf.size() == 12:
		var chosen := selected
		if chosen.is_empty():
			for k in n:
				chosen.append(k)
		var cx := 0.0
		var cy := 0.0
		var cz := 0.0
		for k in chosen:
			cx += out[3 * k]
			cy += out[3 * k + 1]
			cz += out[3 * k + 2]
		cx /= chosen.size()
		cy /= chosen.size()
		cz /= chosen.size()
		var about := FORM_OPS.xf_about(xf, cx, cy, cz)
		for k in chosen:
			var q := FORM_OPS.xf_apply(about, out[3 * k], out[3 * k + 1], out[3 * k + 2])
			for d in 3:
				out[3 * k + d] = q[d]
	if not plane.is_empty():
		var o: PackedFloat64Array = plane.origin
		var nn: PackedFloat64Array = plane.normal
		for k in n:
			var d := (out[3 * k] - o[0]) * nn[0] + (out[3 * k + 1] - o[1]) * nn[1] + (out[3 * k + 2] - o[2]) * nn[2]
			for i in 3:
				out[3 * k + i] -= d * nn[i]
	return out


## Edit By Curve: sel.edges is an open chain; its least-squares Bezier curve (opts "degree",
## "distribution", "planar") is edited (opts "offsets", "selected", "xf"; see edited_control) and
## the chain follows the change of the curve: opts.fit "control" moves the cage points by the
## curve's change at their parameters, "surface" moves the limit points (the chain and its ring
## free). info.control / info.edited are the curve's control points before and after.
static func edit_by_curve(c: Dictionary, sel: Dictionary, opts: Dictionary) -> Dictionary:
	var pairs := FORM_OPS._list(sel, "edges")
	var surface := str(opts.get("fit", "control")).to_lower().begins_with("surf")
	var lp := PackedFloat64Array()
	var copts := opts.duplicate()
	if surface:
		if not available():
			return _err(c, "Surface Points needs the Holo Forge kernel.")
		var lr := limit_positions(c)
		if str(lr.error) != "":
			return _err(c, str(lr.error))
		lp = lr.positions
		copts["points"] = lp
	var curve := chain_curve(c, pairs, copts)
	if curve.has("error"):
		return _err(c, str(curve.error))
	var control: PackedFloat64Array = curve.control
	var edited := edited_control(control, opts.get("offsets", []), PackedInt32Array(opts.get("selected", PackedInt32Array())),
		PackedFloat64Array(opts.get("xf", PackedFloat64Array())), curve.plane)
	var delta := PackedFloat64Array()
	for k in control.size():
		delta.append(edited[k] - control[k])
	var verts: PackedInt32Array = curve.verts
	var params: PackedFloat64Array = curve.params
	var info := {"control": control, "edited": edited, "verts": verts, "params": params}
	var moving := false
	for x in delta:
		if x != 0.0:
			moving = true
			break
	if not moving:
		return _err(c, FORM_OPS.NOTHING, info)
	var locked := FORM_OPS.locked_set(c)
	if not surface:
		var np: PackedFloat64Array = (c.positions as PackedFloat64Array).duplicate()
		var moved := PackedInt32Array()
		for i in verts.size():
			var v := verts[i]
			if locked[v]:
				continue
			var dv := bezier_point(delta, params[i])
			np[3 * v] += dv.x
			np[3 * v + 1] += dv.y
			np[3 * v + 2] += dv.z
			moved.append(v)
		if moved.is_empty():
			return _err(c, "Those edges are frozen.")
		info.moved = moved
		return _ok(c, _write(c, np, moved), sel, PackedStringArray(), info)
	var any_free := false
	for v in verts:
		any_free = any_free or not locked[v]
	if not any_free:
		# As in Control Points mode: a chain that can't move is refused, not fitted around.
		return _err(c, "Those edges are frozen.")
	var topo := CAGE.topology(c)
	var targets := {}
	var mark := {}
	for i in verts.size():
		var v := verts[i]
		var dv := bezier_point(delta, params[i])
		targets[v] = PackedFloat64Array([lp[3 * v] + dv.x, lp[3 * v + 1] + dv.y, lp[3 * v + 2] + dv.z])
		mark[v] = true
		for w in topo.vertex_neighbors(v):
			mark[w] = true
	var free := PackedInt32Array()
	for v in mark:
		if not locked[int(v)]:
			free.append(int(v))
	free.sort()
	if free.is_empty():
		return _err(c, "Those edges are frozen.")
	var r := solve_limit_targets(c, targets, free)
	if str(r.get("error", "")) != "":
		return _err(c, str(r.error))
	info.moved = free
	info.residual = r.residual
	return _ok(c, _write(c, r.cage.positions, free), sel, PackedStringArray(), info)
