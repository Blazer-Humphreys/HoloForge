@tool
extends RefCounted
## The Surface workspace's own features (type "surface", options.method). Surfaces are bodies like
## any other, made of open shells (the view draws them double-sided, in their own color); the
## Modify tools they share with solids (Fillet, Thicken, Split Body, ...) are the solid features.
##
## extrude, revolve, sweep, loft, coil: the solid features' options, making walls without caps
## from profiles and from open curves (sketch curves, body edges); extrude may also take a
## direction (an axis or plane).
## patch: boundary (body edges, sketch curves, or a profile or flat face's outline, in one closed
## loop), continuity (g0 | g1: tangent to the faces of the picked body edges; sketch curves and
## outlines have none, so they build G0 with a warning; a G1 patch that turns off its faces toward
## corners where two of them meet says how far, with a warning; a stored g2 is refused, and its
## command reads it as g1), other_edges and other_continuity (body edges that take another
## continuity), points and rails (sketch curves, body edges: the patch passes through them, within
## a hundredth of its size of a sharply bent one, with a warning), stitch (sew it into the body its
## edges came from; a closed body turns solid; the patch then makes no body of its own).
## ruled: edges, ruled_type (tangent | normal | direction), direction, flip, alternate (the edge's
## other face), corner_type (rounded | mitered: how a gap where picked edges meet is filled;
## documents from before it keep mitred corners); inputs distance, angle.
## offset: faces (faces or bodies); input distance (negative goes the other way).
## trim: tool (body, face, plane, sketch curves or a profile; a surface body is cut too), remove
## (face picks on the pieces to take away, each with "at", where it was clicked; with none picked
## the surfaces the tool reaches are cut so the pieces can be clicked).
## untrim: untrim_type (all | inner | outer | loops), faces, loops (edges); input extend.
## extend: edges, extend_type (natural | tangent | perpendicular), chain (each pick takes the open
## edges running on smoothly from it; documents from before it extend only the picks); input
## distance.
## stitch: bodies, solid (closed results turn solid); input tolerance.
## unstitch: objects (faces or bodies): each face becomes a surface body of its own.
## merge: edges (or faces) between faces lying on one surface.
## reverse_normal: objects (surface bodies, or their faces).

const UTIL := preload("res://addons/holo_forge/core/features/util.gd")
const OPERATIONS := preload("res://addons/holo_forge/core/operations.gd")
const REFERENCES := preload("res://addons/holo_forge/core/references.gd")
const SKETCH_SOLID := preload("res://addons/holo_forge/core/features/sketch_solid.gd")
const POINT64 := preload("res://addons/holo_forge/core/point64.gd")
const PRIMITIVE := preload("res://addons/holo_forge/core/features/primitive.gd")

const METHODS := ["extrude", "revolve", "sweep", "loft", "coil", "patch", "ruled", "offset", "trim", "untrim", "extend",
	"stitch", "unstitch", "merge", "reverse_normal"]


static func build(feature: Resource, ctx: Dictionary) -> String:
	var method := str(feature.options.get("method", ""))
	match method:
		"extrude":
			return SKETCH_SOLID.extrude(feature, ctx, true)
		"revolve":
			return SKETCH_SOLID.revolve(feature, ctx, true)
		"sweep":
			return SKETCH_SOLID.sweep(feature, ctx, true)
		"loft":
			return SKETCH_SOLID.loft(feature, ctx, true)
	var r := UTIL.Reader.new(feature, ctx)
	match method:
		"coil":
			var shape := PRIMITIVE.coil_shape(r, POINT64.exact(feature.options, "position"), true)
			return UTIL.finish(r, shape, "Coil") if shape != null else r.error
		"patch":
			return _patch(r)
		"ruled":
			return _ruled(r)
		"offset":
			return _offset(r)
		"trim":
			return _trim(r)
		"untrim":
			return _untrim(r)
		"extend":
			return _extend(r)
		"stitch":
			return _stitch(r)
		"unstitch":
			return _unstitch(r)
		"merge":
			return _merge(r)
		"reverse_normal":
			return _reverse(r)
	return "Unknown surface feature '%s'" % method


# --- Create ----------------------------------------------------------------------------------

static func _patch(r: UTIL.Reader) -> String:
	var continuity := clampi(int(str(r.opt("continuity", "g0")).trim_prefix("g")), 0, 2)
	var other := clampi(int(str(r.opt("other_continuity", "g1")).trim_prefix("g")), 0, 2)
	var is_edge := func(p: Variant) -> bool: return p is Dictionary and p.get("kind", "") == "edge"
	var picks := r.refs("boundary")
	var other_picks: Array = r.refs("other_edges").filter(is_edge)
	var boundary := []
	# Body edges, grouped by body: G1 keeps the patch tangent to their faces; edges picked under
	# Edges With Another Continuity (in the boundary or not) take theirs.
	var edge_picks: Array = picks.filter(is_edge) + other_picks
	var groups := r.sub_shapes_from(edge_picks, "edge") if not edge_picks.is_empty() else {}
	var others: Dictionary = REFERENCES.group_by_body(other_picks, r.ctx, "edge").groups
	for body_id in groups:
		var ids: PackedInt32Array = groups[body_id].indices
		var marked: PackedInt32Array = others.get(body_id, {}).get("indices", PackedInt32Array())
		var each := PackedInt32Array()
		for e in ids:
			each.append(other if marked.has(e) else continuity)
		boundary.append({"shape": groups[body_id].shape, "edges": ids, "continuity": continuity, "edge_continuity": each})
	# Sketch curves and outlines have no face beside them to carry on: the kernel builds them G0
	# and says how many it did.
	for entry in REFERENCES.curve_edges(picks, r.ctx):
		if entry.has("error"):
			r.fail(entry.error)
		else:
			boundary.append({"shape": entry.edges, "edges": PackedInt32Array(), "continuity": continuity})
	# A profile or a flat face (the view picks flat faces as profiles): its outline.
	var areas := picks.filter(func(p: Variant) -> bool: return p is Dictionary and str(p.get("kind", "")) in ["profile", "face"])
	if not areas.is_empty():
		var found := r.profiles_of(areas)
		if not found.is_empty():
			boundary.append({"shape": found.shape, "edges": PackedInt32Array(), "continuity": continuity, "outline": true})
	var points := r.points("points")
	# Rails: curves inside the patch it runs along (body edges grouped by body, sketch curves).
	var rails := []
	var rail_picks := r.refs("rails")
	var rail_edges: Array = rail_picks.filter(is_edge)
	var rail_groups := r.sub_shapes_from(rail_edges, "edge") if not rail_edges.is_empty() else {}
	for body_id in rail_groups:
		rails.append({"shape": rail_groups[body_id].shape, "edges": rail_groups[body_id].indices})
	for entry in REFERENCES.curve_edges(rail_picks, r.ctx):
		if entry.has("error"):
			r.fail(entry.error)
		else:
			rails.append({"shape": entry.edges, "edges": PackedInt32Array()})
	if boundary.is_empty():
		r.fail("Select the edges or curves around the patch")
	if not r.ok():
		return r.error
	var face := r.checked(r.kernel.patch(boundary, points, {"tag": r.feature.id, "rails": rails}), "Patch")
	if face == null:
		return r.error
	# What the patch did otherwise than asked (G1 built G0, a rail passed near, G1 falling short of
	# tangency toward its corners): a warning.
	var note: String = r.kernel.get_last_warning()
	var error := ""
	if bool(r.opt("stitch", false)):
		# Sewn into the surface its edges came from (closing it turns it solid).
		if groups.size() != 1:
			return "Stitch needs the boundary edges of one body"
		var body_id: String = groups.keys()[0]
		error = UTIL.replace(r, body_id, r.kernel.stitch([r.ctx.bodies[body_id].shape, face], {"tolerance": _gap(r), "solid": true, "tag": r.feature.id}), "Patch")
	else:
		error = UTIL.finish(r, face, "Patch")
	if error == "" and note != "" and r.ctx.has("warnings"):
		var before := str(r.ctx.warnings.get(r.feature.id, ""))
		r.ctx.warnings[r.feature.id] = note if before == "" else before + "; " + note
	return error


static func _ruled(r: UTIL.Reader) -> String:
	var groups := r.sub_shapes("edges", "edge")
	var type := str(r.opt("ruled_type", "tangent"))
	var params := {
		"type": type, "distance": r.num("distance", null, "positive"), "angle": r.num("angle", 0.0),
		"flip": bool(r.opt("flip", false)), "alternate": bool(r.opt("alternate", false)), "tag": r.feature.id,
		"corner_type": str(r.opt("corner_type", "mitered")),
	}
	if type == "direction":
		if r.refs("direction").is_empty():
			r.fail("Select the direction (an axis or plane)")
		else:
			params.direction = SKETCH_SOLID._picked_direction(r, "direction")
	if not r.ok():
		return r.error
	var parts := []
	for body_id in groups:
		var part := r.checked(r.kernel.ruled(groups[body_id].shape, groups[body_id].indices, params), "Ruled")
		if part == null:
			return r.error
		parts.append(part)
	return UTIL.finish(r, parts[0] if parts.size() == 1 else r.kernel.make_compound(parts), "Ruled")


static func _offset(r: UTIL.Reader) -> String:
	var distance := r.num("distance")
	var groups := r.faces_or_bodies("faces")
	if r.ok() and absf(distance) < 1e-12:
		r.fail("The offset distance is zero")
	if not r.ok():
		return r.error
	var parts := []
	for body_id in groups:
		var part := r.noted(r.kernel.offset_surface(groups[body_id].shape, groups[body_id].indices, distance, r.feature.id), "Offset")
		if part == null:
			return r.error
		parts.append(part)
	return UTIL.finish(r, parts[0] if parts.size() == 1 else r.kernel.make_compound(parts), "Offset")


# --- Modify ----------------------------------------------------------------------------------

## Trim: the tool cuts the surfaces; the regions holding the picked points go. A pick is a face
## clicked on a piece: where the click hit ("at") lies on that piece (_on_piece without one). A
## surface body as the tool is cut by the surfaces it reaches too, so its own pieces can be clicked
## away as well.
static func _trim(r: UTIL.Reader) -> String:
	var tool := _cutting_tool(r, "tool")
	if not r.ok():
		return r.error
	var tool_body := str(r.ref("tool").get("body", ""))
	var mutual: bool = r.ctx.bodies.has(tool_body) and is_same(r.ctx.bodies[tool_body].shape, tool) and tool.is_surface()
	var picks_by_body := {}
	for pick in r.refs("remove"):
		var body_id := str(pick.get("body", ""))
		if not r.ctx.bodies.has(body_id):
			return "Body %s no longer exists" % r.ctx.doc.body_name(body_id)
		if not picks_by_body.has(body_id):
			picks_by_body[body_id] = []
		(picks_by_body[body_id] as Array).append(pick)
	var reached := []
	for body_id in OPERATIONS.participating(r.ctx, tool, []):
		if body_id != tool_body and r.ctx.bodies[body_id].shape.is_surface():
			reached.append(body_id)
	var points_by_body := {}
	for body_id in picks_by_body:
		var by: RefCounted = tool if body_id != tool_body else (_compound(r, reached) if not reached.is_empty() else null)
		var points := PackedVector3Array()
		# Picks without a click point are found on the body as cut for showing, cut once for all.
		var shown: RefCounted = null
		for pick in picks_by_body[body_id]:
			if pick.has("at"):
				points.append(pick.at)
				continue
			if shown == null and by != null:
				shown = r.kernel.trim(r.ctx.bodies[body_id].shape, by, PackedVector3Array(), {"tag": r.feature.id})
			points.append(_on_piece(shown, pick))
		points_by_body[body_id] = points
	var targets: Array = points_by_body.keys()
	if targets.is_empty():
		targets = reached.duplicate()
		if targets.is_empty():
			return "The trimming tool doesn't reach a surface body"
		if mutual:
			targets.append(tool_body)
	if targets.has(tool_body):
		if not mutual:
			return "The trimming tool can't trim itself"
		if reached.is_empty():
			return "The trimming tool doesn't reach another surface body"
	var made := {}
	var cut := false
	for body_id in targets:
		if not r.ctx.bodies[body_id].shape.is_surface():
			return "Trim cuts surface bodies (%s is solid)" % r.ctx.doc.body_name(body_id)
		var before: RefCounted = r.ctx.bodies[body_id].shape
		var by := tool if body_id != tool_body else _compound(r, reached)
		var shape := r.checked(r.kernel.trim(before, by, points_by_body.get(body_id, PackedVector3Array()), {"tag": r.feature.id}), "Trim")
		if shape == null:
			return r.error
		if points_by_body.is_empty():
			cut = cut or r.kernel.pieces(shape).size() > r.kernel.pieces(before).size()
		made[body_id] = shape
	# Every body is cut against the others as they were, then all change at once.
	for body_id in made:
		r.ctx.bodies[body_id].shape = made[body_id]
	if points_by_body.is_empty():
		# The surfaces stay cut so their pieces can be clicked, but nothing is trimmed yet.
		return "Click the pieces to remove" if cut else "The trimming tool doesn't cut a surface body"
	UTIL._warn(r)
	return ""


## A point on a picked piece that holds no click (picks made before clicks were kept): inside its
## face in shown, the body cut as the pieces were shown (a piece's centroid can lie on another
## piece), else that centroid.
static func _on_piece(shown: RefCounted, pick: Dictionary) -> Vector3:
	var centroid: Vector3 = (pick.get("sig", {}) as Dictionary).get("point", Vector3.ZERO)
	var index: int = shown.find_face(str(pick.get("name", ""))) if shown != null else -1
	if index < 0:
		return centroid
	# The middle of the face's biggest triangle lies inside the face.
	var face: RefCounted = shown.face_shape(index)
	var mesh: Dictionary = face.tessellate(maxf((face.bbox() as AABB).size.length() * 1e-3, 1e-7), 0.2)
	var points: PackedVector3Array = mesh.get("positions", PackedVector3Array())
	var corners: PackedInt32Array = mesh.get("indices", PackedInt32Array())
	var best := -1.0
	var inside := centroid
	for t in range(0, corners.size() - 2, 3):
		var a := points[corners[t]]
		var b := points[corners[t + 1]]
		var c := points[corners[t + 2]]
		var area := (b - a).cross(c - a).length()
		if area > best:
			best = area
			inside = (a + b + c) / 3.0
	return inside


## The bodies' shapes as one (a compound of several).
static func _compound(r: UTIL.Reader, ids: Array) -> RefCounted:
	var shapes := ids.map(func(id: String) -> RefCounted: return r.ctx.bodies[id].shape)
	return shapes[0] if shapes.size() == 1 else r.kernel.make_compound(shapes)


## A tool that cuts surfaces: a body, a face (a surface body's face stands for its whole body), a
## plane, or sketch curves and profiles pushed out both ways along their sketch's normal.
static func _cutting_tool(r: UTIL.Reader, key: String) -> RefCounted:
	var picks := r.refs(key)
	var kind := str((picks[0] as Dictionary).get("kind", "")) if not picks.is_empty() else ""
	if kind == "sketch_curve" or kind == "profile":
		var profile := SKETCH_SOLID.surface_profile(r, picks)
		if profile.is_empty():
			return null
		var size := UTIL.model_size(r.ctx)
		return r.checked(r.kernel.extrude(profile.shape, {
			"direction": (profile.plane as Transform3D).basis.z, "distance": size, "distance2": size, "surface": true, "tag": r.feature.id,
		}), "Trimming tool")
	if kind == "face" and not bool(r.opt("extend", false)):
		var body: Dictionary = r.ctx.bodies.get(str(picks[0].get("body", "")), {})
		if not body.is_empty() and body.shape.is_surface():
			return body.shape
	return r.tool_shape(key, UTIL.model_size(r.ctx))


static func _untrim(r: UTIL.Reader) -> String:
	var mode := str(r.opt("untrim_type", "all"))
	var grow := r.num("extend", 0.0, "non_negative")
	var groups := r.sub_shapes("loops", "edge") if mode == "loops" else r.sub_shapes("faces", "face")
	if not r.ok():
		return r.error
	for body_id in groups:
		var group: Dictionary = groups[body_id]
		if not group.shape.is_surface():
			return "Untrim works on surface bodies (%s is solid)" % r.ctx.doc.body_name(body_id)
		var faces: PackedInt32Array = group.indices if mode != "loops" else PackedInt32Array()
		var edges: PackedInt32Array = group.indices if mode == "loops" else PackedInt32Array()
		var error := UTIL.replace(r, body_id, r.kernel.untrim(group.shape, faces, edges, {"mode": mode, "extend": grow, "tag": r.feature.id}), "Untrim")
		if error != "":
			return error
	return ""


## Extend: a note says when natural extension fell back to tangent strips (on trimmed faces).
static func _extend(r: UTIL.Reader) -> String:
	var groups := r.sub_shapes("edges", "edge")
	var params := {"distance": r.num("distance", null, "positive"), "mode": str(r.opt("extend_type", "natural")),
		"chain": bool(r.opt("chain", false)), "tag": r.feature.id}
	if not r.ok():
		return r.error
	var notes := PackedStringArray()
	for body_id in groups:
		if not groups[body_id].shape.is_surface():
			return "Extend works on surface bodies (%s is solid)" % r.ctx.doc.body_name(body_id)
		var error := UTIL.replace(r, body_id, r.kernel.extend_surface(groups[body_id].shape, groups[body_id].indices, params), "Extend")
		if error != "":
			return error
		if r.kernel.get_last_warning() != "":
			notes.append(r.kernel.get_last_warning())
	if not notes.is_empty() and r.ctx.has("warnings"):
		var before := str(r.ctx.warnings.get(r.feature.id, ""))
		var note := "; ".join(notes)
		r.ctx.warnings[r.feature.id] = note if before == "" else before + "; " + note
	return ""


## Stitch: the picked bodies sewn together; closed results turn solid. Each piece that comes out
## is a body of its own, kept by the first picked body whose faces it holds, so a surface that
## meets nothing stays its own body (a warning says so). The kernel refuses when nothing meets
## (the bodies then stay as they were).
static func _stitch(r: UTIL.Reader) -> String:
	var ids := r.bodies("bodies")
	var tolerance := r.num("tolerance", 1e-5, "positive")
	if not r.ok():
		return r.error
	var shapes := []
	for body_id in ids:
		shapes.append(r.ctx.bodies[body_id].shape)
	var sewn := r.checked(r.kernel.stitch(shapes, {"tolerance": tolerance, "solid": bool(r.opt("solid", true)), "tag": r.feature.id}), "Stitch")
	if sewn == null:
		return r.error
	# Sewing keeps the faces' names, so each piece is found by the body its faces came from.
	var pieces: Array = r.kernel.pieces(sewn)
	var owned := {}
	for piece in pieces:
		var owner: String = ids[0]
		var names: PackedStringArray = piece.get_face_names()
		for k in ids.size():
			if _shares_name(shapes[k].get_face_names(), names):
				owner = ids[k]
				break
		if not owned.has(owner):
			owned[owner] = []
		(owned[owner] as Array).append(piece)
	for body_id in ids:
		if not owned.has(body_id):
			r.ctx.bodies.erase(body_id)
			continue
		var list: Array = owned[body_id]
		r.ctx.bodies[body_id].shape = list[0]
		for k in range(1, list.size()):
			var id := UTIL.derived_body_id(body_id, r.feature.id, k + 1, ids)
			r.ctx.bodies[id] = {"id": id, "shape": list[k], "feature": r.feature.id}
	UTIL._warn(r)
	if pieces.size() > 1 and r.ctx.has("warnings"):
		var before := str(r.ctx.warnings.get(r.feature.id, ""))
		var note := "%d pieces don't meet within the tolerance, so they stay separate bodies" % pieces.size()
		r.ctx.warnings[r.feature.id] = note if before == "" else before + "; " + note
	return ""


static func _shares_name(a: PackedStringArray, b: PackedStringArray) -> bool:
	for name in b:
		if a.has(name):
			return true
	return false


## Unstitch: each picked face becomes a surface body of its own; what is left of each body stays
## that body (the first picked face keeps it when nothing is left). Pieces are copies, so they
## no longer share edges.
static func _unstitch(r: UTIL.Reader) -> String:
	var groups := r.faces_or_bodies("objects")
	if not r.ok():
		return r.error
	for body_id in groups:
		var shape: RefCounted = groups[body_id].shape
		var picked: PackedInt32Array = groups[body_id].indices
		if picked.is_empty():
			for f in shape.face_count():
				picked.append(f)
		var rest := PackedInt32Array()
		for f in shape.face_count():
			if not picked.has(f):
				rest.append(f)
		var pieces := []
		if not rest.is_empty():
			pieces.append(rest)
		for f in picked:
			pieces.append(PackedInt32Array([f]))
		for k in pieces.size():
			var piece := r.checked(r.kernel.keep_faces(shape, pieces[k]), "Unstitch")
			piece = r.checked(r.kernel.transform_shape(piece, Transform3D.IDENTITY, r.feature.id), "Unstitch") if piece != null else null
			if piece == null:
				return r.error
			if k == 0:
				r.ctx.bodies[body_id].shape = piece
			else:
				var id := UTIL.derived_body_id(body_id, r.feature.id, k, groups.keys())
				r.ctx.bodies[id] = {"id": id, "shape": piece, "feature": r.feature.id}
	UTIL._warn(r)
	return ""


static func _merge(r: UTIL.Reader) -> String:
	var edge_picks := r.refs("edges").filter(func(p: Variant) -> bool: return p is Dictionary and p.get("kind", "") == "edge")
	var face_picks := r.refs("edges").filter(func(p: Variant) -> bool: return p is Dictionary and p.get("kind", "") == "face")
	var edges := r.sub_shapes_from(edge_picks, "edge") if not edge_picks.is_empty() else {}
	var faces := r.sub_shapes_from(face_picks, "face") if not face_picks.is_empty() else {}
	if edges.is_empty() and faces.is_empty():
		r.fail("Select the edges between the faces to merge")
	if not r.ok():
		return r.error
	var ids := edges.keys()
	for body_id in faces:
		if not ids.has(body_id):
			ids.append(body_id)
	for body_id in ids:
		var shape: RefCounted = edges.get(body_id, faces.get(body_id, {})).shape
		var edge_ids: PackedInt32Array = edges.get(body_id, {}).get("indices", PackedInt32Array())
		var face_ids: PackedInt32Array = faces.get(body_id, {}).get("indices", PackedInt32Array())
		var error := UTIL.replace(r, body_id, r.kernel.merge_faces(shape, edge_ids, face_ids, r.feature.id), "Merge")
		if error != "":
			return error
	return ""


static func _reverse(r: UTIL.Reader) -> String:
	var groups := r.faces_or_bodies("objects")
	if not r.ok():
		return r.error
	for body_id in groups:
		if not groups[body_id].shape.is_surface():
			return "Reverse Normal works on surface bodies (%s is solid)" % r.ctx.doc.body_name(body_id)
		var error := UTIL.replace(r, body_id, r.kernel.reverse_faces(groups[body_id].shape, groups[body_id].indices), "Reverse Normal")
		if error != "":
			return error
	return ""


## A sewing gap that suits the model (a millionth of its size, at least a nanometer).
static func _gap(r: UTIL.Reader) -> float:
	return maxf(UTIL.model_size(r.ctx) * 1e-6, 1e-9)
