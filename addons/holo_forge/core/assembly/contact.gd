@tool
extends RefCounted
## Contact (Holo Forge Phase 8, contracts C5.2-C5.5): a motion is swept through samples, and every
## pair of bodies in an enabled contact set is checked with CadMesh.overlap (C5.1) until two of
## them interfere; bisection then finds the last clear value. Nothing here writes the document.
##
## Contact meshes (C5.2): a mesh body is its own CadMesh; a B-rep body is tessellated at the High
## preset (MESH.tessellated, kept by the mesh cache, and here by the shape) and deviates from its
## surface by dev: 0 when every face is flat, else the preset's D / 5000 (D: its box diagonal). A body
## that can't be tessellated, or that overlap() refuses (open, inside out), takes no part
## (S-CONTACT-SKIPPED).
##
## Measured rates (Stage 3): overlap() on round parts in close contact (a pin turning in a tight
## hole) costs several times what mesh_budget.h's rates predict. Every full overlap() call of a sweep
## whose Manifolds were already built is timed; a pair's least time is remembered (by its two
## meshes) and used up front by the next sweep of those meshes when it is above the rate. After the
## first MEASURE_SAMPLES samples a sweep estimates its rest again from what it measured, and is refused
## then (S-CONTACT-TOO-SLOW, nothing moved) when that is over the budget: at most MEASURE_SAMPLES
## samples' work is spent before such a refusal.
##
## Interference (C5.3): thickness > tol_eff, tol_eff = tolerance + dev_a + dev_b. An overlap()
## that timed out is checked first (it says nothing about the overlap). A pose overlap() cannot
## check (its "self_crossing": a mesh that crosses itself where the bodies meet, or any refusal or
## measurement error partway through) is not known to be clear: the motion stops at the last value
## checked clear (bisected toward it) with S-CONTACT-UNCHECKED, which names the mesh and gives
## overlap()'s repair sentence. At the start, a self-crossing pair stops the motion where it is; a
## body overlap() refuses whatever the pose (open, inside out) takes no part (S-CONTACT-SKIPPED).
##
## Sampling (fix round 1, B1): the first look at the motion is cut at the caller's "split_times"
## (Motion Study keys, Play track turns: each is sampled) and so that no unit turns more than
## TURN_MAX between two of its points, from the analytic turn ("turn_between", else "turn" spread
## evenly); with neither, COARSE_MAX even intervals. Intervals are weighed from consecutive
## points of that look, so a motion that goes out and back, or turns past 180°, is seen. A look
## of more than STEP_MAX points is refused up front (S-CONTACT-STEPS). Golden-ratio points join the
## even ones so a motion that repeats with the even spacing (whole turns) is not read as still.
##
## Thin bodies (fix round 1, B2; fix round 2, SB2 / N4): a body is thin when its box, its width
## across any flat face group's normal, or its least local thickness is under 2 · Step
## (S-CONTACT-THIN with that thickness). Local thickness: rays from triangle centroids into the
## material along their normals, to where they leave it. Every triangle is looked at up to
## THIN_RAYS; above that, THIN_RAYS of them, with rays in every connected piece and face group
## first (fix round 3), and a sweep that finds no thin part says how many it looked at
## (S-CONTACT-THIN-SAMPLED). A solid cube or ball is not thin. The average
## thickness 2 · volume / area (S-CONTACT-THIN-AVERAGE, under Step) is used only for a mesh no ray
## could measure and with no flat group. Thinness is looked at only for a sweep that will run (after
## the up-front estimate).
##
## Turning (fix round 2, SB1 / N3): every mark interval of the first look that is cut for turning
## has its first cut point looked at with the marks, so whole turns between marks are seen moving.
## A step count set by turning alone is refused with S-CONTACT-TURNS (Step does not change it).
##
## Bounds (C5.5): one budget of seconds per sweep, estimated up front from the rates of
## mesh_budget.h (copied below) and the measured cost of one path() call; over it the sweep is
## refused (S-CONTACT-TOO-SLOW) before any overlap work. A sweep that runs past its deadline stops
## at the last sample it checked clear (S-CONTACT-TIMEOUT). A shorter run deadline (a drag event's,
## or the test seam debug_budget_seconds) ends the run sooner without changing the estimate.
##
## Cache memory (10.2 N #6): overlap() keeps each mesh's Manifold on the mesh, and the Mesh
## workspace's cache counts it only when that entry is stored again. contact.gd does not re-store
## entries to recount them: contact meshes are the few bodies of contact sets, and their Manifolds go
## with the meshes when the mesh cache (or a rebuild) drops them.

const XFORM := preload("res://addons/holo_forge/core/assembly/xform64.gd")
const DATA := preload("res://addons/holo_forge/core/assembly/assembly_data.gd")
const JOINT_MATH := preload("res://addons/holo_forge/core/assembly/joint_math.gd")
const MESH := preload("res://addons/holo_forge/core/features/mesh.gd")
const MESH_BODY := preload("res://addons/holo_forge/core/mesh/mesh_body.gd")

## Seconds a sweep may take when the caller gives none (motion.gd passes CONTACT_SECONDS).
const DEFAULT_SECONDS := 5.0
## The most samples a sweep may take (C5.4).
const STEP_MAX := 2000
## No unit turns more than this between samples (5°, in radians).
const TURN_MAX := 0.08726646259971647
## Bisection halvings at most (C5.4).
const HALVINGS := 24
## overlap() rates from mesh_budget.h (team N, N8): microseconds per call, per triangle of the
## pair with both Manifolds cached, and per triangle to build a Manifold the first time.
const RATE_CALL_US := 300.0
const RATE_TRIANGLE_US := 0.5
const RATE_BUILD_US := 1.4
## Microseconds an overlap() costs when its box test answers (estimated for samples where the
## pair's boxes, swept over the interval, don't meet).
const RATE_EARLY_US := 20.0
## Samples after which a sweep estimates its rest again from its measured overlap() times.
const MEASURE_SAMPLES := 3
## The motion is first looked at in COARSE_MIN even intervals when its turning is known (options
## "turn" or "turn_between"; each then cut so no unit turns more than TURN_MAX in one), else in
## COARSE_MAX.
const COARSE_MIN := 8
const COARSE_MAX := 64
## Points at k · GOLDEN (mod 1) of the motion, k = 1..GOLDEN_POINTS, join the first look's even
## ones (a motion periodic in the even spacing still differs at them).
const GOLDEN := 0.6180339887498949
const GOLDEN_POINTS := 7
## Triangles the thin check may copy (it measures a body's width across up to this many / its
## triangle count of its flat groups' normals, at least 4).
const THIN_TRIANGLES := 2000000
## Rays the local thickness check casts at most (one per triangle when a mesh has fewer).
const THIN_RAYS := 20000
## Rays the local thickness check casts at least in each connected piece and face group of a mesh
## with more than THIN_RAYS triangles (fewer each when there are very many of them).
const RAYS_PER_REGION := 4
## Contact meshes kept by B-rep shape.
const CACHE_ENTRIES := 64
## overlap() takes at least this long a time limit (it clamps shorter ones up).
const LEAST_LIMIT := 0.05
## Bodies so far from the origin that float positions step by more than tol_eff (10.2 N #4).
const S_CONTACT_FAR := "<BodyA> and <BodyB> lie so far from the origin that contact between them is measured no finer than <step>."

## Test seam (5.6 #9): when above 0, every sweep's run ends this many seconds after it starts
## (the up-front estimate still uses the real budget).
static var debug_budget_seconds := 0.0
## Contact meshes of B-rep bodies: {shape instance id: {"shape": WeakRef, "mesh", "dev", "error"}}.
static var _meshes := {}
## Meshes whose Manifold overlap() has built: {mesh instance id: WeakRef}.
static var _built := {}
## Measured overlap() times of mesh pairs: {"<id>|<id>" (mesh instance ids, smaller first):
## {"a": WeakRef, "b": WeakRef, "us": the least full call measured}}; at most CACHE_ENTRIES.
static var _rates := {}
## Least local thickness of contact meshes: {mesh instance id: {"mesh": WeakRef, "t": m}}.
static var _thickness := {}


## The contact mesh of a body (C5.2): {"mesh": CadMesh or null, "dev": m, "error": the
## S-CONTACT-SKIPPED sentence or ""}.
static func contact_mesh(doc: Resource, result: Dictionary, body_id: String) -> Dictionary:
	var body: Dictionary = (result.get("bodies", {}) as Dictionary).get(body_id, {})
	var shape: Variant = body.get("shape")
	var name := MESH_BODY.body_name(doc, body_id)
	if shape == null or (shape as RefCounted).is_null():
		return {"mesh": null, "dev": 0.0, "error": DATA.fill(DATA.S_CONTACT_SKIPPED, {"Body": name, "reason": "it has no shape"})}
	if MESH_BODY.is_mesh(shape):
		return {"mesh": shape, "dev": 0.0, "error": ""}
	var key := (shape as Object).get_instance_id()
	var kept: Dictionary = _meshes.get(key, {})
	if not kept.is_empty() and (kept.shape as WeakRef).get_ref() == shape:
		return {"mesh": kept.mesh, "dev": kept.dev, "error": DATA.fill(DATA.S_CONTACT_SKIPPED, {"Body": name, "reason": kept.reason}) if str(kept.reason) != "" else ""}
	var made := MESH.tessellated(shape, "high", MESH.OK_SECONDS)
	var entry := {"shape": weakref(shape), "mesh": null, "dev": 0.0, "reason": ""}
	if made.has("error"):
		entry.reason = "it could not be tessellated (%s)" % str(made.error).trim_suffix(".")
	else:
		entry.mesh = made.mesh
		if _has_round_group(made.mesh):
			entry.dev = ((shape as RefCounted).bbox() as AABB).size.length() * float(MESH.TESSELLATE_PRESETS.high[0])
	if _meshes.size() >= CACHE_ENTRIES:
		_meshes.erase(_meshes.keys()[0])
	_meshes[key] = entry
	return {"mesh": entry.mesh, "dev": entry.dev, "error": DATA.fill(DATA.S_CONTACT_SKIPPED, {"Body": name, "reason": entry.reason}) if str(entry.reason) != "" else ""}


## Forgets the contact meshes kept here, what overlap() has built and the measured rates.
static func clear_cache() -> void:
	_meshes.clear()
	_built.clear()
	_rates.clear()
	_thickness.clear()


## Forgets only the measured overlap() times (the meshes stay built).
static func clear_rates() -> void:
	_rates.clear()


## The least full overlap() time measured for two meshes, in microseconds (0 when none was).
static func measured_us(mesh_a: RefCounted, mesh_b: RefCounted) -> float:
	return _Check.measured_in(_rates, mesh_a, mesh_b)


## The body ids a contact set member stands for: a body, or every body of a component and of the
## components nested in it (in the order of result's bodies).
static func member_bodies(doc: Resource, result: Dictionary, member: Variant) -> Array:
	var out := []
	if not (member is Dictionary):
		return out
	var bodies: Dictionary = result.get("bodies", {})
	if (member as Dictionary).has("body"):
		var id := str(member.body)
		if bodies.has(id):
			out.append(id)
		return out
	var component := str((member as Dictionary).get("component", ""))
	if component == "" or doc == null:
		return out
	for id in bodies:
		var at := str((doc.bodies.get(id, {}) as Dictionary).get("component", ""))
		var guard := 0
		while at != "" and at != component and guard < 1000:
			at = str((doc.components.get(at, {}) as Dictionary).get("parent", ""))
			guard += 1
		if at == component:
			out.append(str(id))
	return out


## The pairs of bodies in the enabled contact sets of assembly (normalized): [{"a", "b", "set"
## (id), "set_name"}], a pair in two sets once, with the first; [] when no enabled set has two bodies.
static func contact_pairs(doc: Resource, result: Dictionary, assembly: Dictionary) -> Array:
	var pairs := []
	var seen := {}
	for entry in assembly.get("contact_sets", []):
		if not (entry is Dictionary) or not bool(entry.get("enabled", true)):
			continue
		var ids := []
		for member in entry.get("members", []):
			for id in member_bodies(doc, result, member):
				if not ids.has(id):
					ids.append(id)
		for i in ids.size():
			for j in range(i + 1, ids.size()):
				var key := "%s|%s" % ([ids[i], ids[j]] if str(ids[i]) < str(ids[j]) else [ids[j], ids[i]])
				if seen.has(key):
					continue
				seen[key] = true
				pairs.append({"a": str(ids[i]), "b": str(ids[j]), "set": str(entry.get("id", "")), "set_name": str(entry.get("name", entry.get("id", "")))})
	return pairs


## A sweep result before any work: nothing checked, reached = v.
static func empty_result(v: float) -> Dictionary:
	return {
		"reached": v, "stopped": false, "pair": [], "set": "", "point": PackedFloat64Array(), "sentence": "", "timed_out": false,
		"checked_pairs": 0, "steps": 0, "ms": 0.0, "warnings": PackedStringArray(), "refused": false, "estimate": 0.0,
		"estimate_again": 0.0,
	}


## Sweeps a motion from v0 to v1 for contact (C5.4). path(v) -> {body id: xform64} gives the body
## poses at v (a drive or a study parameterization; a body it leaves out stays where it is
## modelled). Returns empty_result()'s keys: "reached" (v1, or the last clear value), "stopped",
## "pair" [body_a, body_b] and "set" (id) of the stop, "point" (world, PackedFloat64Array 3: the
## middle of the overlap found just past the stop), "sentence" (S-CONTACT-STOP, S-STUDY-STOP,
## S-CONTACT-TIMEOUT, or the refusal), "timed_out", "checked_pairs", "steps" (samples taken),
## "ms", "warnings" (S-CONTACT-NO-SETS, -START, -THIN, -DEV, -SKIPPED), "refused" (S-CONTACT-STEPS,
## S-CONTACT-TOO-SLOW, or S-CONTACT-TIME-USED when a deadline already used up cut the first look
## short: nothing moved, reached = v0), "estimate" (s, up front), "estimate_again"
## (s, the whole sweep estimated again after MEASURE_SAMPLES samples; 0 when it was not).
## options: "assembly" (normalized; else doc.assembly), "seconds" (the budget, DEFAULT_SECONDS),
## "deadline_seconds" (a shorter run deadline, e.g. a drag event's), "deadline_usec" (an absolute
## Time.get_ticks_usec deadline shared with the caller), "limit_seconds" (the caller's whole contact
## time, named by S-CONTACT-TIME-USED; else "seconds"), "format" (Callable(v) -> String for the
## sentences), "study" (true: S-STUDY-STOP), "turn" (radians: the most any unit turns over the
## sweep, taken as spread evenly over it), "turn_between" (Callable(a, b) -> radians: the most any
## unit turns from a to b; used instead of "turn"), "split_times" (values of v, e.g. Motion Study
## keys or Play track key times: the first look is cut there and each one is sampled; values
## outside (v0, v1), repeats and non-finite values are ignored).
static func sweep(doc: Resource, result: Dictionary, kernel: RefCounted, path: Callable, v0: float, v1: float, options := {}) -> Dictionary:
	var started := Time.get_ticks_usec()
	var out := empty_result(v1)
	var assembly: Dictionary = options.get("assembly", {})
	if assembly.is_empty():
		assembly = DATA.normalized(doc.assembly if doc.assembly is Dictionary else {})
	var settings: Dictionary = assembly.get("contact", DATA.CONTACT_DEFAULT)
	var tolerance := float(settings.get("tolerance", DATA.CONTACT_DEFAULT.tolerance))
	var step := maxf(float(settings.get("step", DATA.CONTACT_DEFAULT.step)), 1e-9)
	var precision := maxf(float(settings.get("precision", DATA.CONTACT_DEFAULT.precision)), 1e-12)
	var units := str(doc.units) if doc != null else "mm"
	var format: Callable = options.get("format", func(v: float) -> String: return String.num(v))
	var budget := float(options.get("seconds", DEFAULT_SECONDS))
	var finish := func() -> Dictionary:
		out["ms"] = float(Time.get_ticks_usec() - started) / 1000.0
		return out
	# 1. Pairs from the enabled sets (a pair in two sets counts once, with the first).
	var pairs := contact_pairs(doc, result, assembly)
	if pairs.is_empty():
		out.warnings.append(DATA.S_CONTACT_NO_SETS)
		return finish.call()
	# A stored setting that is not finite (a hand edit) checks nothing it could vouch for.
	var bad_setting := DATA.contact_not_finite(settings)
	if bad_setting != "":
		out["refused"] = true
		out["reached"] = v0
		out["sentence"] = bad_setting
		return finish.call()
	if v0 == v1:
		out["reached"] = v1
		return finish.call()
	# 2. Contact meshes; a body without one takes no part.
	var meshes := {}
	var kept_pairs := []
	for pair: Dictionary in pairs:
		var usable := true
		for id: String in [pair.a, pair.b]:
			if not meshes.has(id):
				meshes[id] = contact_mesh(doc, result, id)
				if str(meshes[id].error) != "" and not out.warnings.has(meshes[id].error):
					out.warnings.append(meshes[id].error)
			usable = usable and meshes[id].mesh != null
		if usable:
			kept_pairs.append(pair)
	pairs = kept_pairs
	# 3. A first look at the motion: marks (v0, even and golden-ratio points, the split values, v1),
	# each mark interval cut so no unit turns more than TURN_MAX in one piece.
	var turn := absf(float(options.get("turn", 0.0)))
	var turn_between: Callable = options.get("turn_between", Callable())
	var turn_known := options.has("turn") or turn_between.is_valid()
	var marks := _marks(v0, v1, COARSE_MIN if turn_known else COARSE_MAX, options.get("split_times", []))
	# The look's own deadline (N-B, fix round 3): the budget, or the caller's shared deadline.
	var look_deadline := started + int(budget * 1e6)
	if options.has("deadline_usec"):
		look_deadline = mini(look_deadline, int(options.deadline_usec))
	# The caller's whole contact time, for a look its deadline cuts short (fix round 4).
	var limit := float(options.get("limit_seconds", budget))
	if not is_finite(limit) or limit < budget:
		limit = budget
	var cuts := PackedInt32Array()
	var mark_turn := PackedFloat64Array()
	var coarse := 0
	for m in range(1, marks.size()):
		if Time.get_ticks_usec() >= look_deadline:
			return _look_too_slow(out, started, float(m) / float(marks.size()), marks.size(), pairs.size(), v0, limit, finish)
		var p := float(marks[m - 1][0])
		var q := float(marks[m][0])
		var seg := turn * absf(q - p) / absf(v1 - v0)
		if turn_between.is_valid():
			var given := float(turn_between.call(p, q))
			if is_finite(given):
				seg = absf(given)
		mark_turn.append(seg)
		var n := maxi(1, int(ceil(minf(seg / TURN_MAX, 4.0 * float(STEP_MAX)) - 1e-9)))
		cuts.append(n)
		coarse += n
	# The marks' poses first, with each cut mark interval's first cut point (each path() call
	# timed; SB1): a unit that turns whole turns between two marks has turned at most TURN_MAX at
	# its interval's first cut, so it is seen moving there. They are worked out in order, under
	# the look's deadline (N-B); when the look is refused anyway (over STEP_MAX points, or over the
	# budget) they stop at the first movement seen.
	var path_started := Time.get_ticks_usec()
	var first_poses: Dictionary = path.call(v0)
	var mark_poses := [first_poses]
	var first_cut := {}
	var moves := false
	var before := first_poses
	var calls := 1
	var path_s := float(Time.get_ticks_usec() - path_started) / 1e6
	var look_s := path_s * float(2 * coarse)
	for m in range(1, marks.size()):
		# (Moving and refused anyway: over STEP_MAX points, or the look alone over the budget.)
		if moves and (coarse > STEP_MAX or look_s > budget):
			break
		if Time.get_ticks_usec() >= look_deadline:
			return _look_too_slow(out, started, float(m) / float(marks.size()), coarse, pairs.size(), v0, limit, finish)
		var points := []
		if cuts[m - 1] > 1:
			var p := float(marks[m - 1][0])
			first_cut[m] = path.call(p + (float(marks[m][0]) - p) / float(cuts[m - 1]))
			points.append(first_cut[m])
		mark_poses.append(path.call(float(marks[m][0])))
		points.append(mark_poses[m])
		calls += points.size()
		for poses: Dictionary in points:
			if not moves and not _moving(pairs, [before, poses]).is_empty():
				moves = true
			before = poses
		path_s = float(Time.get_ticks_usec() - path_started) / 1e6 / float(calls)
		look_s = path_s * float(2 * coarse)
	if coarse > STEP_MAX:
		# Too many points to look at all of them: a motion seen moving there is refused; one that
		# moves no pair at any mark or first cut is taken as moving none.
		if not moves:
			out["reached"] = v1
			return finish.call()
		out["refused"] = true
		out["reached"] = v0
		out["sentence"] = _steps_sentence(coarse, _sum(mark_turn), _sum(mark_turn) > 0.0)
		return finish.call()
	# The look costs a path() call per point, and the samples at least as many again.
	if look_s > budget or mark_poses.size() < marks.size():
		if not moves:
			out["reached"] = v1
			return finish.call()
		out["refused"] = true
		out["reached"] = v0
		out["estimate"] = look_s
		out["sentence"] = DATA.fill(DATA.S_CONTACT_TOO_SLOW, {"s": _seconds(look_s), "n": _thousands(coarse), "p": str(pairs.size())})
		return finish.call()
	var coarse_v := PackedFloat64Array([v0])
	var coarse_poses := [mark_poses[0]]
	var coarse_turn := PackedFloat64Array()
	var is_split := [false]
	for m in range(1, marks.size()):
		var p := float(marks[m - 1][0])
		var q := float(marks[m][0])
		var n := cuts[m - 1]
		for i in range(1, n + 1):
			if i == n:
				coarse_v.append(q)
				coarse_poses.append(mark_poses[m])
				is_split.append(bool(marks[m][1]))
			else:
				var v := p + (q - p) * (float(i) / float(n))
				coarse_v.append(v)
				if i > 1 and Time.get_ticks_usec() >= look_deadline:
					return _look_too_slow(out, started, float(coarse_v.size()) / float(coarse + 1), coarse, pairs.size(), v0, limit, finish)
				coarse_poses.append(first_cut[m] if i == 1 else path.call(v))
				is_split.append(false)
			coarse_turn.append(float(mark_turn[m - 1]) / float(n))
	# Only pairs whose relative pose changes between two points of the look.
	pairs = _moving(pairs, coarse_poses)
	if pairs.is_empty():
		out["reached"] = v1
		return finish.call()
	# The bodies in play: their contact meshes' box corners (modelled), dev and thinness.
	var corners := {}
	var most_dev := 0.0
	var most_tol := 0.0
	for pair: Dictionary in pairs:
		var tol_eff := tolerance + float(meshes[pair.a].dev) + float(meshes[pair.b].dev)
		pair["tol"] = tol_eff
		if float(meshes[pair.a].dev) > 0.0 or float(meshes[pair.b].dev) > 0.0:
			most_dev = maxf(most_dev, maxf(float(meshes[pair.a].dev), float(meshes[pair.b].dev)))
			most_tol = maxf(most_tol, tol_eff)
		for id: String in [pair.a, pair.b]:
			if corners.has(id):
				continue
			var box: AABB = (meshes[id].mesh as RefCounted).bbox()
			corners[id] = _corners(box)
	if most_dev > 0.0:
		out.warnings.append(DATA.fill(DATA.S_CONTACT_DEV, {"dev": JOINT_MATH.format_length(most_dev, units), "tol": JOINT_MATH.format_length(most_tol, units)}))
	# 4. Samples: each interval of the look weighs its farthest corner travel (as an arc) in steps
	# and its largest turn (measured, or the analytic one when larger) in TURN_MAX; samples fall
	# evenly on the summed weight, and every split point of the look is a sample too.
	var weights := PackedFloat64Array()
	var travels := PackedFloat64Array()
	var total := 0.0
	var turn_weight := 0.0
	var turned_all := 0.0
	for k in coarse:
		var travel := 0.0
		var turned := float(coarse_turn[k])
		for id in corners:
			var p0: PackedFloat64Array = (coarse_poses[k] as Dictionary).get(id, XFORM.identity())
			var p1: PackedFloat64Array = (coarse_poses[k + 1] as Dictionary).get(id, XFORM.identity())
			travel = maxf(travel, _corner_travel(corners[id], p0, p1))
			turned = maxf(turned, XFORM.angle_between(p0, p1))
		var bent := minf(turned, PI)
		var arc := bent / (2.0 * sin(bent * 0.5)) if bent > 1e-9 else 1.0
		var weight := maxf(travel * arc / step, turned / TURN_MAX)
		turn_weight += turned / TURN_MAX
		turned_all += turned
		weights.append(weight)
		travels.append(travel * arc)
		total += weight
	var count := maxi(int(ceil(total - 1e-9)), 1)
	# The split points: their summed weight and value.
	var split_at := PackedFloat64Array()
	var split_v := PackedFloat64Array()
	var summed := 0.0
	for k in coarse:
		summed += float(weights[k])
		if k + 1 < coarse and bool(is_split[k + 1]):
			split_at.append(summed)
			split_v.append(coarse_v[k + 1])
	if count + split_v.size() > STEP_MAX:
		out["refused"] = true
		out["reached"] = v0
		# (N3: when the turning alone is over the most, a larger Step would not help.)
		out["sentence"] = _steps_sentence(count + split_v.size(), turned_all, int(ceil(turn_weight - 1e-9)) + split_v.size() > STEP_MAX)
		return finish.call()
	# 5. The estimate: every sample's path() call and overlap() calls (the full rate where the
	# pair's swept boxes meet, the box test's elsewhere), the start check, the bisection and the
	# Manifolds not yet built. A pair's full rate is the larger of mesh_budget.h's and the time
	# measured for its meshes by an earlier sweep.
	var estimate_us := 0.0
	var full_sum := 0.0
	for pair: Dictionary in pairs:
		var rated := RATE_CALL_US + RATE_TRIANGLE_US * float(int(meshes[pair.a].mesh.triangle_count()) + int(meshes[pair.b].mesh.triangle_count()))
		pair["full"] = maxf(rated, measured_us(meshes[pair.a].mesh, meshes[pair.b].mesh))
		pair["measured"] = 0.0
		# (An Array: a packed array read from a Dictionary is a copy.)
		pair["meets"] = []
		full_sum += float(pair.full)
	var samples_at := PackedFloat64Array()
	for k in coarse:
		var samples := float(weights[k]) / total * float(count) if total > 0.0 else 0.0
		samples_at.append(samples)
		var per := path_s * 1e6
		for pair: Dictionary in pairs:
			var meets := _swept_boxes_meet(corners, coarse_poses[k], coarse_poses[k + 1], pair, float(travels[k]))
			(pair.meets as Array).append(meets)
			per += float(pair.full) if meets else RATE_EARLY_US
		estimate_us += samples * per
	estimate_us += float(split_v.size()) * (path_s * 1e6 + full_sum)
	estimate_us += full_sum + float(HALVINGS) * (path_s * 1e6 + full_sum)
	for id in meshes:
		var mesh: RefCounted = meshes[id].mesh
		if mesh != null and not _is_built(mesh):
			estimate_us += RATE_BUILD_US * float(int(mesh.triangle_count()))
	var estimate := estimate_us / 1e6 + float(Time.get_ticks_usec() - started) / 1e6
	out["estimate"] = estimate
	if estimate > budget:
		out["refused"] = true
		out["reached"] = v0
		out["sentence"] = DATA.fill(DATA.S_CONTACT_TOO_SLOW, {"s": _seconds(estimate), "n": _thousands(count + split_v.size()), "p": str(pairs.size())})
		return finish.call()
	# Thin bodies (looked at only for a sweep that runs: the rays cost time on big meshes).
	for id in corners:
		var thin := thinness(meshes[id].mesh, step)
		if not thin.is_empty():
			out.warnings.append(DATA.fill(DATA.S_CONTACT_THIN_AVERAGE if bool(thin.average) else DATA.S_CONTACT_THIN, {
				"Body": MESH_BODY.body_name(doc, id), "t": JOINT_MATH.format_length(float(thin.t), units), "step": JOINT_MATH.format_length(step, units),
			}))
		else:
			# (Not every triangle was looked at: say so, fix round 3.)
			var coverage := thickness_coverage(meshes[id].mesh)
			if int(coverage.rays) > 0 and int(coverage.rays) < int(coverage.triangles):
				out.warnings.append(DATA.fill(DATA.S_CONTACT_THIN_SAMPLED, {
					"Body": MESH_BODY.body_name(doc, id), "rays": _thousands(int(coverage.rays)), "n": _thousands(int(coverage.triangles)),
					"step": JOINT_MATH.format_length(step, units),
				}))
	# The run's deadline: the budget, or a shorter one.
	var run_s := budget
	if debug_budget_seconds > 0.0:
		run_s = debug_budget_seconds
	elif float(options.get("deadline_seconds", 0.0)) > 0.0:
		run_s = minf(run_s, float(options.deadline_seconds))
	var deadline := started + int(run_s * 1e6)
	if options.has("deadline_usec"):
		deadline = mini(deadline, int(options.deadline_usec))
	_prune_built()
	var check := _Check.new()
	check.meshes = meshes
	check.built = _built
	check.rates = _rates
	check.deadline = deadline
	check.doc = doc
	check.format = format
	# 6. The start: pairs already interfering are left out.
	var active := []
	var start_poses: Dictionary = coarse_poses[0]
	for pair: Dictionary in pairs:
		var found := check.overlap(pair, start_poses)
		if bool(found.timed_out):
			return _timeout(out, v0, format, finish)
		if _Check.crosses_itself(found):
			# (Where the bodies meet, a mesh crosses itself: nothing here is known to be clear.)
			return _unchecked_stop(out, check, pair, found, v0, start_poses, finish)
		if str(found.error) != "":
			out.warnings.append(_refused_sentence(doc, pair, found))
			continue
		_far_warning(out, doc, pair, found, float(pair.tol), units)
		if bool(found.hit):
			out.warnings.append(DATA.fill(DATA.S_CONTACT_START, {"BodyA": MESH_BODY.body_name(doc, pair.a), "BodyB": MESH_BODY.body_name(doc, pair.b)}))
			continue
		active.append(pair)
	out["checked_pairs"] = active.size()
	if active.is_empty():
		out["reached"] = v1
		return finish.call()
	check.pairs = active
	# 7. The samples in order; the first that interferes is bisected against the last clear one.
	var clear_v := v0
	var clear_poses := start_poses
	var done := 0.0
	var k := 0
	var into := 0.0
	var j := 1
	var s := 0
	var taken := 0
	while j <= count or s < split_v.size():
		# The next sample: the split point before summed weight j · total / count, or that one
		# (inside interval k).
		var regular := float(j) * total / float(count) if j <= count else INF
		var at_weight := 0.0
		var v := 0.0
		if s < split_v.size() and split_at[s] < regular:
			at_weight = split_at[s]
			v = split_v[s]
			s += 1
		else:
			at_weight = regular
			while k < coarse - 1 and done + float(weights[k]) < at_weight:
				done += float(weights[k])
				k += 1
			into = clampf((at_weight - done) / float(weights[k]), 0.0, 1.0) if float(weights[k]) > 0.0 else 1.0
			v = v1 if j == count else coarse_v[k] + (coarse_v[k + 1] - coarse_v[k]) * into
			j += 1
			if s < split_v.size() and split_v[s] == v:
				s += 1
		if Time.get_ticks_usec() >= deadline:
			return _timeout(out, clear_v, format, finish)
		var poses: Dictionary = path.call(v)
		out["steps"] = int(out.steps) + 1
		taken += 1
		var hit := check.first_hit(poses, v)
		if bool(hit.get("timed_out", false)):
			return _timeout(out, clear_v, format, finish)
		if hit.has("pair") or hit.has("failed"):
			return _bisect(out, check, path, corners, clear_v, clear_poses, v, poses, hit, precision, doc, format, options, finish)
		clear_v = v
		clear_poses = poses
		if taken == MEASURE_SAMPLES and (j <= count or s < split_v.size()):
			# The rest again, from the overlap() times measured so far (a pair measured above its
			# rate takes the measured time); over the budget it is refused now.
			var again := _estimate_rest(active, weights, samples_at, at_weight, path_s, started, split_at)
			out["estimate_again"] = again
			if again > budget:
				out["refused"] = true
				out["reached"] = v0
				out["sentence"] = DATA.fill(DATA.S_CONTACT_TOO_SLOW, {"s": _seconds(again), "n": _thousands(count + split_v.size()), "p": str(pairs.size())})
				return finish.call()
	out["reached"] = v1
	return finish.call()


## Seconds a sweep will have taken: what it took so far (since started, Time.get_ticks_usec) plus
## the samples past summed weight at_weight and the bisection, each active pair's full overlap() at
## the larger of its rate and its measured time (pair "full", "measured", "meets" per interval);
## the split points past at_weight (split_at: their summed weights) cost a full sample each.
static func _estimate_rest(active: Array, weights: PackedFloat64Array, samples_at: PackedFloat64Array, at_weight: float, path_s: float, started: int,
		split_at := PackedFloat64Array()) -> float:
	var full_sum := 0.0
	for pair: Dictionary in active:
		full_sum += maxf(float(pair.full), float(pair.measured))
	var rest_us := 0.0
	for w in split_at:
		if w > at_weight:
			rest_us += path_s * 1e6 + full_sum
	var end := 0.0
	for k in weights.size():
		var w := float(weights[k])
		end += w
		var left := clampf((end - at_weight) / w, 0.0, 1.0) if w > 0.0 else 0.0
		if left <= 0.0:
			continue
		var per := path_s * 1e6
		for pair: Dictionary in active:
			per += maxf(float(pair.full), float(pair.measured)) if bool((pair.meets as Array)[k]) else RATE_EARLY_US
		rest_us += float(samples_at[k]) * left * per
	rest_us += float(HALVINGS) * (path_s * 1e6 + full_sum)
	return float(Time.get_ticks_usec() - started) / 1e6 + rest_us / 1e6


## Bisects between lo (clear) and hi (interfering, hit) until the farthest corner moves no more
## than precision between them, at most HALVINGS times; the stop is the last clear value.
static func _bisect(out: Dictionary, check: _Check, path: Callable, corners: Dictionary, lo: float, lo_poses: Dictionary, hi: float, hi_poses: Dictionary,
		hit: Dictionary, precision: float, doc: Resource, format: Callable, options: Dictionary, finish: Callable) -> Dictionary:
	for h in HALVINGS:
		var travel := 0.0
		for id in corners:
			travel = maxf(travel, _corner_travel(corners[id], lo_poses.get(id, XFORM.identity()), hi_poses.get(id, XFORM.identity())))
		if travel <= precision:
			break
		if Time.get_ticks_usec() >= check.deadline:
			return _timeout(out, lo, format, finish)
		var mid := lo + (hi - lo) * 0.5
		if mid == lo or mid == hi:
			break
		var poses: Dictionary = path.call(mid)
		var found := check.first_hit(poses, mid)
		if bool(found.get("timed_out", false)):
			return _timeout(out, lo, format, finish)
		if found.has("pair") or found.has("failed"):
			hi = mid
			hi_poses = poses
			hit = found
		else:
			lo = mid
			lo_poses = poses
	if hit.has("failed"):
		return _unchecked_stop(out, check, hit.failed, hit.found, lo, hi_poses, finish)
	var pair: Dictionary = hit.pair
	out["reached"] = lo
	out["stopped"] = true
	out["pair"] = [pair.a, pair.b]
	out["set"] = pair.set
	var pose_a: PackedFloat64Array = hi_poses.get(pair.a, XFORM.identity())
	out["point"] = XFORM.apply(pose_a, hit.point)
	var names := {"BodyA": MESH_BODY.body_name(doc, pair.a), "BodyB": MESH_BODY.body_name(doc, pair.b), "Set": pair.set_name}
	if bool(options.get("study", false)):
		names["time"] = format.call(lo)
		out["sentence"] = DATA.fill(DATA.S_STUDY_STOP, names)
	else:
		names["value"] = format.call(lo)
		out["sentence"] = DATA.fill(DATA.S_CONTACT_STOP, names)
	return finish.call()


## A stop at the last value checked clear (clear_v) before a pose overlap() could not check
## (S-CONTACT-UNCHECKED, naming the pair, the mesh and overlap()'s repair sentence).
static func _unchecked_stop(out: Dictionary, check: _Check, pair: Dictionary, found: Dictionary, clear_v: float, poses: Dictionary, finish: Callable) -> Dictionary:
	out["reached"] = clear_v
	out["stopped"] = true
	out["pair"] = [pair.a, pair.b]
	out["set"] = pair.set
	var at: Variant = found.get("point")
	if at is PackedFloat64Array and (at as PackedFloat64Array).size() == 3:
		out["point"] = XFORM.apply(poses.get(pair.a, XFORM.identity()), at)
	out["sentence"] = check.unchecked_sentence(pair, found, clear_v)
	return finish.call()


static func _timeout(out: Dictionary, clear_v: float, format: Callable, finish: Callable) -> Dictionary:
	out["reached"] = clear_v
	out["stopped"] = true
	out["timed_out"] = true
	out["sentence"] = DATA.fill(DATA.S_CONTACT_TIMEOUT, {"value": format.call(clear_v)})
	return finish.call()


## The sentence for a pair overlap() refused (S-CONTACT-SKIPPED for the refused body).
static func _refused_sentence(doc: Resource, pair: Dictionary, found: Dictionary) -> String:
	var side := str(found.get("refused", "this"))
	var id: String = pair.b if side == "other" else pair.a
	var name := MESH_BODY.body_name(doc, id)
	var reason := str(found.error).trim_suffix(".")
	if _Check.crosses_itself(found):
		reason = "its mesh crosses itself"
	# ("Contact needs closed bodies: the mesh is open." names no body: say which.)
	return DATA.fill(DATA.S_CONTACT_SKIPPED, {"Body": name, "reason": reason.substr(0, 1).to_lower() + reason.substr(1)})


## Warns once per pair when the bodies' float positions step by more than tol_eff (10.2 N #4).
static func _far_warning(out: Dictionary, doc: Resource, pair: Dictionary, found: Dictionary, tol_eff: float, units: String) -> void:
	var float_step := float(found.get("step", 0.0))
	if float_step > tol_eff:
		out.warnings.append(S_CONTACT_FAR.replace("<BodyA>", MESH_BODY.body_name(doc, pair.a)).replace("<BodyB>", MESH_BODY.body_name(doc, pair.b))
			.replace("<step>", JOINT_MATH.format_length(float_step, units)))


## The first look's marks from v0 to v1, in order along the motion: [v, split] each, v0 first and
## v1 last, with the even points (even intervals), the golden-ratio points and the split values
## strictly between (split true: a value to be sampled). Equal values are kept once.
static func _marks(v0: float, v1: float, even: int, splits: Variant) -> Array:
	var inner := []
	for k in range(1, even):
		inner.append([v0 + (v1 - v0) * (float(k) / float(even)), false])
	for k in range(1, GOLDEN_POINTS + 1):
		inner.append([v0 + (v1 - v0) * fposmod(float(k) * GOLDEN, 1.0), false])
	var low := minf(v0, v1)
	var high := maxf(v0, v1)
	if splits is Array or splits is PackedFloat64Array or splits is PackedFloat32Array:
		for t in splits:
			var value := float(t)
			if is_finite(value) and value > low and value < high:
				inner.append([value, true])
	var rising := v1 > v0
	inner.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]) if rising else float(a[0]) > float(b[0]))
	var out := [[v0, false]]
	for mark: Array in inner:
		var last: Array = out[out.size() - 1]
		if float(mark[0]) == float(last[0]):
			last[1] = bool(last[1]) or bool(mark[1])
			continue
		if (rising and float(mark[0]) >= v1) or (not rising and float(mark[0]) <= v1):
			continue
		out.append(mark)
	out.append([v1, false])
	return out


## The pairs whose relative pose changes between two consecutive entries of poses_list.
static func _moving(pairs: Array, poses_list: Array) -> Array:
	var out := []
	for pair: Dictionary in pairs:
		var before := _relative(poses_list[0], pair.a, pair.b)
		for k in range(1, poses_list.size()):
			var now := _relative(poses_list[k], pair.a, pair.b)
			if XFORM.distance(before, now) > 1e-12 or XFORM.angle_between(before, now) > 1e-12:
				out.append(pair)
				break
			before = now
	return out


## How thin a contact mesh is against a contact step (B2, SB2): {"t": the thickness, "average":
## false} when its box, its width across a flat face group's normal, or its least local thickness
## (local_thickness()) is under 2 · step; {"t": 2 · volume / area, "average": true} only for a mesh
## no ray could measure, with no flat group, whose average thickness is under step; else {}.
## Widths are measured on copies turned to each normal (at most THIN_TRIANGLES triangles copied, at
## least 4 normals), and only when the average thickness (never more than the least width) is
## under 2 · step.
static func thinness(mesh: RefCounted, step: float) -> Dictionary:
	var box: AABB = mesh.bbox()
	var least := minf(box.size.x, minf(box.size.y, box.size.z))
	if least < 2.0 * step:
		return {"t": least, "average": false}
	var volume := float(mesh.volume()) if mesh.has_method("volume") else 0.0
	var area := float(mesh.area()) if mesh.has_method("area") else 0.0
	var average := 2.0 * volume / area if volume > 0.0 and area > 0.0 and is_finite(volume) and is_finite(area) else INF
	var normals: Array[Vector3] = []
	var most := maxi(4, int(float(THIN_TRIANGLES) / maxf(1.0, float(int(mesh.triangle_count())))))
	for i in (int(mesh.face_count()) if average < 2.0 * step else 0):
		if normals.size() >= most:
			break
		var info: Dictionary = mesh.face_info(i)
		if not bool(info.get("planar", false)) or not (info.get("normal") is Vector3):
			continue
		var n: Vector3 = (info.normal as Vector3).normalized()
		if not n.is_finite() or n.length_squared() < 0.5:
			continue
		var known := false
		for other in normals:
			if absf(other.dot(n)) > 1.0 - 1e-9:
				known = true
				break
		if not known:
			normals.append(n)
	var width := INF
	for n in normals:
		var side := n.cross(Vector3.RIGHT if absf(n.x) < 0.9 else Vector3.UP).normalized()
		var turned := Basis(side, n.cross(side), n).transposed()
		var copy: RefCounted = mesh.transformed(Transform3D(turned, Vector3.ZERO))
		if copy == null or copy.is_null():
			continue
		var size: Vector3 = (copy.bbox() as AABB).size
		width = minf(width, minf(size.x, minf(size.y, size.z)))
	if width < 2.0 * step:
		return {"t": width, "average": false}
	# Local thickness (fix round 2, SB2 / N4): rays from triangles into the material.
	var local := local_thickness(mesh)
	if local >= 0.0:
		return {"t": local, "average": false} if local < 2.0 * step else {}
	# (No rays could be cast: the average, when no flat group was measured either.)
	if normals.is_empty() and average < step:
		return {"t": average, "average": true}
	return {}


## The least local thickness of a contact mesh (m), or -1 when no ray could measure it: from the
## centroids of triangles, a ray into the material along the triangle's normal to where it leaves
## (an exit hit, its normal along the ray). Every triangle when there are at most THIN_RAYS. Above
## that (fix round 3, SB2), THIN_RAYS of them: first up to RAYS_PER_REGION in each separately
## connected piece and in each face group (by area within it; fewer each when there are very many
## pieces and groups, at most half the rays in all), then the rest by area over the whole mesh,
## along a golden-ratio sequence. A thin part that is a piece or a face group of its own is then
## always looked at; one inside a big piece and group may be missed, and thickness_coverage() says
## how many triangles were looked at. Kept by mesh (it does not depend on Step).
static func local_thickness(mesh: RefCounted) -> float:
	return float(_thickness_entry(mesh).t)


## How much of a contact mesh local_thickness() looked at: {"rays": triangles a ray was cast from,
## "triangles": its triangle count}.
static func thickness_coverage(mesh: RefCounted) -> Dictionary:
	var entry := _thickness_entry(mesh)
	return {"rays": int(entry.rays), "triangles": int(entry.triangles)}


static func _thickness_entry(mesh: RefCounted) -> Dictionary:
	var key := mesh.get_instance_id()
	var kept: Dictionary = _thickness.get(key, {})
	if not kept.is_empty() and (kept.mesh as WeakRef).get_ref() == mesh:
		return kept
	var measured := _measure_thickness(mesh)
	if _thickness.size() >= CACHE_ENTRIES:
		_thickness.erase(_thickness.keys()[0])
	measured["mesh"] = weakref(mesh)
	_thickness[key] = measured
	return measured


## {"t": local_thickness(), "rays", "triangles"} measured.
static func _measure_thickness(mesh: RefCounted) -> Dictionary:
	var none := {"t": -1.0, "rays": 0, "triangles": int(mesh.triangle_count()) if mesh.has_method("triangle_count") else 0}
	if not mesh.has_method("ray_hit") or not mesh.has_method("get_arrays"):
		return none
	var arrays: Variant = mesh.get_arrays()
	if not (arrays is Dictionary):
		return none
	var positions := PackedVector3Array((arrays as Dictionary).get("positions", PackedVector3Array()))
	var indices := PackedInt32Array((arrays as Dictionary).get("indices", PackedInt32Array()))
	var triangles := indices.size() / 3
	none.triangles = triangles
	if triangles == 0:
		return none
	var box: AABB = mesh.bbox()
	var reach := box.size.length() * 2.0 + 1e-9
	var inset := maxf(box.size.length() * 1e-6, 1e-9)
	var picks := PackedInt32Array()
	if triangles <= THIN_RAYS:
		picks.resize(triangles)
		for i in triangles:
			picks[i] = i
	else:
		picks = _region_picks(mesh, arrays, positions, indices, triangles)
	var least := INF
	for i in picks:
		var a := positions[indices[3 * i]]
		var b := positions[indices[3 * i + 1]]
		var c := positions[indices[3 * i + 2]]
		var n := (b - a).cross(c - a)
		if not (n.length_squared() > 0.0) or not n.is_finite():
			continue
		n = n.normalized()
		var centroid := (a + b + c) / 3.0
		for d: Vector3 in [-n, n]:
			var hit: Dictionary = mesh.ray_hit(centroid + d * inset, d, reach)
			if bool(hit.get("hit", false)) and hit.get("normal") is Vector3 and (hit.normal as Vector3).dot(d) > 0.0:
				least = minf(least, float(hit.distance) + inset)
				break
	return {"t": least if is_finite(least) else -1.0, "rays": picks.size(), "triangles": triangles}


## THIN_RAYS distinct triangles of a big mesh (see local_thickness()): RAYS_PER_REGION by area in
## each connected piece (CadMesh.connected) and each face group ("groups" of get_arrays), then the
## rest by area over the whole mesh.
static func _region_picks(mesh: RefCounted, arrays: Dictionary, positions: PackedVector3Array, indices: PackedInt32Array, triangles: int) -> PackedInt32Array:
	var areas := PackedFloat64Array()
	areas.resize(triangles)
	var summed := PackedFloat64Array()
	summed.resize(triangles)
	var total := 0.0
	for i in triangles:
		var a := positions[indices[3 * i]]
		areas[i] = 0.5 * (positions[indices[3 * i + 1]] - a).cross(positions[indices[3 * i + 2]] - a).length()
		total += areas[i]
		summed[i] = total
	# The regions: connected pieces, then face groups.
	var regions: Array[PackedInt32Array] = []
	if mesh.has_method("connected"):
		var seen := PackedByteArray()
		seen.resize(triangles)
		for i in triangles:
			if seen[i] != 0:
				continue
			var piece: PackedInt32Array = mesh.connected(PackedInt32Array([i]), 180.0)
			if piece.is_empty():
				piece = PackedInt32Array([i])
			for t in piece:
				if t >= 0 and t < triangles:
					seen[t] = 1
			seen[i] = 1
			regions.append(piece)
			if regions.size() > THIN_RAYS:
				break
	var groups: Variant = arrays.get("groups")
	if (groups is PackedInt32Array or groups is Array) and groups.size() == triangles:
		var by_group := {}
		for i in triangles:
			var g := int(groups[i])
			if not by_group.has(g):
				by_group[g] = PackedInt32Array()
			(by_group[g] as PackedInt32Array).append(i)
		if by_group.size() > 1:
			for g in by_group:
				regions.append(by_group[g])
	var chosen := PackedByteArray()
	chosen.resize(triangles)
	var picks := PackedInt32Array()
	var per := RAYS_PER_REGION
	if not regions.is_empty():
		per = clampi(int(THIN_RAYS / 2 / regions.size()), 1, RAYS_PER_REGION)
	for region in regions:
		if picks.size() >= THIN_RAYS / 2:
			break
		if region.size() <= per:
			for t in region:
				if chosen[t] == 0:
					chosen[t] = 1
					picks.append(t)
			continue
		var own := PackedFloat64Array()
		own.resize(region.size())
		var sum := 0.0
		for k in region.size():
			sum += areas[region[k]]
			own[k] = sum
		for k in per:
			var at := mini(own.bsearch(fposmod((float(k) + 0.5) * GOLDEN, 1.0) * sum), region.size() - 1)
			var t := region[at]
			if chosen[t] == 0:
				chosen[t] = 1
				picks.append(t)
	var next := 0
	while picks.size() < THIN_RAYS and next < 4 * THIN_RAYS:
		var t := mini(summed.bsearch(fposmod((float(next) + 0.5) * GOLDEN, 1.0) * total), triangles - 1)
		next += 1
		if chosen[t] == 0:
			chosen[t] = 1
			picks.append(t)
	return picks


## The 8 corners of a box as xform64 points.
static func _corners(box: AABB) -> Array:
	var out := []
	for i in 8:
		var p := box.get_endpoint(i)
		out.append(PackedFloat64Array([p.x, p.y, p.z]))
	return out


## The farthest any of the corners moves from pose p0 to pose p1.
static func _corner_travel(corners: Array, p0: PackedFloat64Array, p1: PackedFloat64Array) -> float:
	var most := 0.0
	for c: PackedFloat64Array in corners:
		var a := XFORM.apply(p0, c)
		var b := XFORM.apply(p1, c)
		var dx := b[0] - a[0]
		var dy := b[1] - a[1]
		var dz := b[2] - a[2]
		most = maxf(most, sqrt(dx * dx + dy * dy + dz * dz))
	return most


## b's pose seen from a: inverse(P_a) · P_b (identity for a body path() leaves out).
static func _relative(poses: Dictionary, a: String, b: String) -> PackedFloat64Array:
	return XFORM.compose(XFORM.inverse(poses.get(a, XFORM.identity())), poses.get(b, XFORM.identity()))


## True when the two bodies' world boxes over an interval (both ends, grown by its travel) meet.
static func _swept_boxes_meet(corners: Dictionary, poses_0: Dictionary, poses_1: Dictionary, pair: Dictionary, travel: float) -> bool:
	var boxes := []
	for id: String in [pair.a, pair.b]:
		var low := PackedFloat64Array([INF, INF, INF])
		var high := PackedFloat64Array([-INF, -INF, -INF])
		for poses: Dictionary in [poses_0, poses_1]:
			var pose: PackedFloat64Array = poses.get(id, XFORM.identity())
			for c: PackedFloat64Array in corners[id]:
				var p := XFORM.apply(pose, c)
				for axis in 3:
					low[axis] = minf(low[axis], p[axis])
					high[axis] = maxf(high[axis], p[axis])
		boxes.append([low, high])
	for axis in 3:
		if boxes[0][0][axis] - travel > boxes[1][1][axis] + travel or boxes[1][0][axis] - travel > boxes[0][1][axis] + travel:
			return false
	return true


static func _is_built(mesh: RefCounted) -> bool:
	var kept: WeakRef = _built.get(mesh.get_instance_id())
	return kept != null and kept.get_ref() == mesh


## Forgets built meshes that are gone (when there are many).
static func _prune_built() -> void:
	if _built.size() <= 4 * CACHE_ENTRIES:
		return
	for id in _built.keys():
		if (_built[id] as WeakRef).get_ref() == null:
			_built.erase(id)


## True when a mesh has a face group that is not flat (a tessellated round face).
static func _has_round_group(mesh: RefCounted) -> bool:
	var count := int(mesh.face_count())
	for i in count:
		if not bool(mesh.face_info(i).get("planar", false)):
			return true
	return false


## The refusal of a first look that reached its deadline before it was made (N-B, fix round 3),
## nothing moved (reached = v0), "estimate" the time it would have taken (the time so far over the
## share done). S-CONTACT-TOO-SLOW with that time when it is over limit (the caller's whole contact
## time, "limit_seconds", else the sweep's "seconds"); else the deadline, not the look, is the
## reason (fix round 4: one already passed, or the time left was used up before the look could be
## made), and the sentence is S-CONTACT-TIME-USED with limit.
static func _look_too_slow(out: Dictionary, started: int, done: float, n: int, p: int, v0: float, limit: float, finish: Callable) -> Dictionary:
	var spent := float(Time.get_ticks_usec() - started) / 1e6
	var whole := spent / clampf(done, 1e-6, 1.0)
	out["refused"] = true
	out["reached"] = v0
	out["estimate"] = whole
	if whole > limit:
		out["sentence"] = DATA.fill(DATA.S_CONTACT_TOO_SLOW, {"s": _seconds(whole), "n": _thousands(n), "p": str(p)})
	else:
		out["sentence"] = DATA.fill(DATA.S_CONTACT_TIME_USED, {"budget": _seconds(limit)})
	return finish.call()


## The refusal of a motion of n steps: S-CONTACT-TURNS (turned radians in all) when its turning
## alone sets the count (N3: Step does not change it), else S-CONTACT-STEPS.
static func _steps_sentence(n: int, turned: float, by_turning: bool) -> String:
	if not by_turning:
		return DATA.fill(DATA.S_CONTACT_STEPS, {"n": _thousands(n)})
	var text := ""
	if turned >= TAU:
		var turns := turned / TAU
		text = String.num(turns, 1 if turns < 100.0 else 0)
		if text.contains("."):
			text = text.rstrip("0").rstrip(".")
		text += " turn" if text == "1" else " turns"
	else:
		text = String.num(rad_to_deg(turned), 1)
		if text.contains("."):
			text = text.rstrip("0").rstrip(".")
		text += "°"
	return DATA.fill(DATA.S_CONTACT_TURNS, {"turns": text, "n": _thousands(n)})


## The sum of a packed array.
static func _sum(values: PackedFloat64Array) -> float:
	var total := 0.0
	for value in values:
		total += value
	return total


## A whole number with thousands separators ("10,000").
static func _thousands(n: int) -> String:
	var text := str(absi(n))
	var out := ""
	while text.length() > 3:
		out = "," + text.substr(text.length() - 3) + out
		text = text.substr(0, text.length() - 3)
	return ("-" if n < 0 else "") + text + out


## Seconds for a sentence: "20 s", "7.5 s", "0.31 s".
static func _seconds(value: float) -> String:
	var text := ""
	if value >= 10.0:
		text = str(roundi(value))
	else:
		text = String.num(value, 1 if value >= 1.0 else 2)
		if text.contains("."):
			text = text.rstrip("0").rstrip(".")
	return text + " s"


## The overlap checks of one sweep: the pairs, their contact meshes and tol_eff, one deadline.
class _Check:
	extends RefCounted
	var meshes: Dictionary
	## The meshes overlap() has built (contact.gd's _built).
	var built: Dictionary
	## The measured overlap() times (contact.gd's _rates).
	var rates: Dictionary
	var pairs: Array
	var deadline: int
	## For S-CONTACT-UNCHECKED: the document (body names) and Callable(v) -> String.
	var doc: Resource
	var format: Callable

	## The least full overlap() time in rates for two meshes, µs (0 when none was measured).
	static func measured_in(table: Dictionary, mesh_a: RefCounted, mesh_b: RefCounted) -> float:
		var entry: Dictionary = table.get(rate_key(mesh_a, mesh_b), {})
		if entry.is_empty():
			return 0.0
		var a: Object = (entry.a as WeakRef).get_ref()
		var b: Object = (entry.b as WeakRef).get_ref()
		if not ((a == mesh_a and b == mesh_b) or (a == mesh_b and b == mesh_a)):
			return 0.0
		return float(entry.us)

	## A mesh pair's key in rates: the two instance ids, smaller first.
	static func rate_key(mesh_a: RefCounted, mesh_b: RefCounted) -> String:
		var ia := mesh_a.get_instance_id()
		var ib := mesh_b.get_instance_id()
		return "%d|%d" % ([ia, ib] if ia < ib else [ib, ia])

	## Remembers a full overlap() time of two meshes in rates (the least one is kept; at most
	## CACHE_ENTRIES pairs, the oldest dropped).
	func _note_rate(mesh_a: RefCounted, mesh_b: RefCounted, us: float) -> void:
		var known := measured_in(rates, mesh_a, mesh_b)
		if known > 0.0 and known <= us:
			return
		var key := rate_key(mesh_a, mesh_b)
		if not rates.has(key) and rates.size() >= CACHE_ENTRIES:
			rates.erase(rates.keys()[0])
		rates[key] = {"a": weakref(mesh_a), "b": weakref(mesh_b), "us": us}

	func _was_built(mesh: RefCounted) -> bool:
		var kept: WeakRef = built.get(mesh.get_instance_id())
		return kept != null and kept.get_ref() == mesh

	## overlap() of a pair at poses: its result plus "hit" (thickness > tol_eff). timed_out is
	## checked first: a timed-out call says nothing about the overlap. A full call (no box-test
	## answer) with both Manifolds already built is timed: the pair's least time goes in its
	## "measured" (µs) and is remembered for its meshes (contact.gd _note_rate).
	func overlap(pair: Dictionary, poses: Dictionary) -> Dictionary:
		var mesh_a: RefCounted = meshes[pair.a].mesh
		var mesh_b: RefCounted = meshes[pair.b].mesh
		var pose_a: PackedFloat64Array = poses.get(pair.a, XFORM.identity())
		var pose_b: PackedFloat64Array = poses.get(pair.b, XFORM.identity())
		var left := float(deadline - Time.get_ticks_usec()) / 1e6
		var was_built := _was_built(mesh_a) and _was_built(mesh_b)
		var call_started := Time.get_ticks_usec()
		var found: Dictionary = mesh_a.overlap(mesh_b, XFORM.compose(XFORM.inverse(pose_a), pose_b), {"time_limit": maxf(left, LEAST_LIMIT)})
		var spent := float(Time.get_ticks_usec() - call_started)
		if bool(found.get("timed_out", false)):
			found["hit"] = false
			return found
		if str(found.get("error", "")) == "" and not bool(found.get("early_out", false)):
			built[mesh_a.get_instance_id()] = weakref(mesh_a)
			built[mesh_b.get_instance_id()] = weakref(mesh_b)
			if was_built:
				var known := float(pair.get("measured", 0.0))
				if known <= 0.0 or spent < known:
					pair["measured"] = spent
					_note_rate(mesh_a, mesh_b, spent)
		found["hit"] = str(found.get("error", "")) == "" and bool(found.get("overlap", false)) and float(found.get("thickness", 0.0)) > float(pair.tol)
		return found

	## The first pair that interferes at poses: {"pair", "point" (in the pair's a space)}; else,
	## when overlap() could not check a pair there (a mesh that crosses itself, any refusal or
	## measurement error), {"failed": that pair, "found": its result, "point"}: that pose is not
	## known to be clear, so the sweep stops before it; else {"timed_out": true}, or {} when all
	## are clear.
	func first_hit(poses: Dictionary, _v := 0.0) -> Dictionary:
		var failed := {}
		for pair: Dictionary in pairs:
			var found := overlap(pair, poses)
			if bool(found.get("timed_out", false)):
				return {"timed_out": true}
			if str(found.get("error", "")) != "" or crosses_itself(found):
				if failed.is_empty():
					failed = {"failed": pair, "found": found, "point": found.get("point", PackedFloat64Array([0.0, 0.0, 0.0]))}
				continue
			if bool(found.hit):
				return {"pair": pair, "point": found.get("point", PackedFloat64Array([0.0, 0.0, 0.0]))}
		return failed

	## The sentence for a stop before a pose overlap() could not check (S-CONTACT-UNCHECKED): the
	## pair, the body overlap() refused and its own sentence (which names the mesh problem and the
	## repair; "This is a Holo Forge fault" tails are left out: the fault is in the mesh).
	func unchecked_sentence(pair: Dictionary, found: Dictionary, at: float) -> String:
		var side := str(found.get("refused", "this"))
		var reason := str(found.get("error", "")).strip_edges()
		var cut := reason.find(" This is a Holo Forge fault")
		if cut >= 0:
			reason = reason.substr(0, cut)
		if reason == "":
			reason = "Its mesh crosses itself." if crosses_itself(found) else "overlap() gave no answer."
		return DATA.fill(DATA.S_CONTACT_UNCHECKED, {
			"BodyA": MESH_BODY.body_name(doc, pair.a), "BodyB": MESH_BODY.body_name(doc, pair.b),
			"Body": MESH_BODY.body_name(doc, pair.b if side == "other" else pair.a),
			"value": format.call(at) if format.is_valid() else String.num(at), "reason": reason,
		})

	## True when an overlap() result says a mesh crosses itself (its "self_crossing", from team N).
	static func crosses_itself(found: Dictionary) -> bool:
		var crossing: Variant = found.get("self_crossing", false)
		return (crossing is bool and crossing) or (crossing is int and crossing != 0) or (crossing is String and crossing != "")
