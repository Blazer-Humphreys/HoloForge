@tool
extends RefCounted
## The command panel of every Phase 3 feature (and Insert Fastener, and the edit panels of
## Import, Insert Mesh and Derive): its fields, starting values and which fields show
## for which choices. feature_command.gd turns a spec into a working command; regen's handlers
## read the same keys (expression fields become inputs, everything else options).
##
## Spec: {"type", "title", "fields": [field...], "op": "" | default operation (adds Operation and
## Bodies), "ops": the operations offered, "op_visible_if": when the Operation shows (hidden, the
## feature owns no body), "method": construction method}. Field: {"key", "label", "type", "kind",
## "options", "filter" (selection: kinds the viewport may pick; a String "body" stores body ids),
## "filter_by" ({option key: {value: kinds}}), "single", "gather" (kinds a single slot still takes
## several of), "at_click" (face picks keep where the click hit), "default", "unset" (what a feature
## saved before the field existed builds with, when that isn't the default), "read_as" ({stored
## value no longer offered: the choice an edit reads it as}), "visible_if", "parse" ("int_list"
## for text fields kept as arrays)}. A default of "$size" is a size that fits the view.
##
## Mesh tools ("mesh:<method>", _add_mesh_specs; core/features/mesh.gd): their selection filters
## take the mesh kinds "mesh_body" (stored as {"kind": "body", "body"}), "mesh_group" ({"kind":
## "mesh_group", "body", "group"}), "mesh_triangles" ({"kind": "mesh_triangles", "body",
## "triangles", "digest"}; "separate": one pick per click, "limit": how many) and "mesh_boundary"
## (an open edge loop: {"kind": "mesh_boundary", "body", "loop", "edges", "digest"}). Their
## expression fields may hold "range": [low, high] (see ranged()) and defaults that follow the
## picked body: "$D/150" (D: the body's diagonal), "$T/2" (T: its triangle count), "$detail*2"
## (another field), "$m:0.0001" (meters). A spec's "metrics": "union" measures D over every picked
## body together; "voxel": {"field", "op", ...} names the cell size field that is raised until its
## grid fits (tools/feature_command.gd). The last row of every mesh panel is the "stat" info row.

const HOLE := preload("res://addons/holo_forge/core/features/hole.gd")
const INSERT := preload("res://addons/holo_forge/core/features/insert.gd")

const _LEN := "length"
const _ANG := "angle"
const _NUM := "number"

const MESH_UNITS := [["mm", "Millimeters"], ["cm", "Centimeters"], ["m", "Meters"], ["in", "Inches"], ["ft", "Feet"], ["um", "Microns"]]
const OBJECT_KINDS := {"object_type": {"bodies": ["body"], "features": ["feature"], "faces": ["face"], "components": ["component"]}}
const OBJECT_TYPES := [["bodies", "Bodies"], ["features", "Features"], ["faces", "Faces"], ["components", "Components"]]

static var _specs := {}


static func expr(key: String, label: String, kind: String, default: String, visible_if := {}) -> Dictionary:
	return {"key": key, "label": label, "type": "expression", "kind": kind, "default": default, "visible_if": visible_if}


static func pick(key: String, label: String, filter: Array, single := false, visible_if := {}) -> Dictionary:
	return {"key": key, "label": label, "type": "selection", "filter": filter, "single": single, "default": [], "visible_if": visible_if}


static func choice(key: String, label: String, options: Array, default: String, visible_if := {}) -> Dictionary:
	return {"key": key, "label": label, "type": "enum", "options": options, "default": default, "visible_if": visible_if}


static func flag(key: String, label: String, default := false, visible_if := {}) -> Dictionary:
	return {"key": key, "label": label, "type": "bool", "default": default, "visible_if": visible_if}


static func text(key: String, label: String, default: String, visible_if := {}, parse := "") -> Dictionary:
	return {"key": key, "label": label, "type": "text", "default": default, "visible_if": visible_if, "parse": parse}


## An expression field with the range its value must lie in: low and high are numbers (meters for a
## length, degrees for an angle, plain for a number) or formulas of D (the picked body's
## diagonal), T (its triangle count) or another field's key: "D/10", "D*1e-5", "-gap", "T-1",
## "thickness/10". extra: "whole" (a whole number), "zero_ok" (0 is taken too, whatever the range),
## "not_zero" (0 is refused), "gt" / "lt" (the value must be above low / below high, not equal),
## "optional" (the field may stay empty, and is no input while it is: the kernel keeps its own
## default, which it may raise to fit), "used" (the key of the op's report that holds the value
## the kernel used, shown beside the empty field).
static func ranged(field: Dictionary, low: Variant, high: Variant, extra := {}) -> Dictionary:
	return field.merged({"range": [low, high]}).merged(extra)


## A read-only row (type "info"): a note, or the mesh tools' "stat" row.
static func note(key: String, note_text: String, visible_if := {}) -> Dictionary:
	return {"key": key, "label": "", "type": "info", "text": note_text, "visible_if": visible_if}


## The spec for a tool key ("extrude", "plane:offset", ...), or {}.
static func get_spec(key: String) -> Dictionary:
	if _specs.is_empty():
		_build()
	return _specs.get(key, {})


static func keys() -> Array:
	if _specs.is_empty():
		_build()
	return _specs.keys()


static func _add(key: String, title: String, fields: Array, op := "", extra := {}) -> void:
	var spec := {"type": key.get_slice(":", 0), "title": title, "fields": fields, "op": op}
	spec.merge(extra)
	if key.contains(":"):
		spec["method"] = key.get_slice(":", 1)
	_specs[key] = spec


## The Surface workspace's own tools ("surface:<method>", core/features/surface.gd). Their
## Create tools make new bodies (or components) only: surfaces don't join or cut solids.
static func _add_surface_specs(profile_kinds: Array, sides: Array) -> void:
	var new_only := {"ops": ["new_body", "new_component"]}
	var curves: Array = profile_kinds + ["sketch_curve", "edge"]
	_add("surface:extrude", "Surface Extrude", [
		pick("profiles", "Profiles or Curves", curves),
		pick("direction", "Direction (empty: the sketch's normal)", ["axis", "plane"], true),
		choice("start", "Start", [["profile", "Profile Plane"], ["offset", "Offset"], ["object", "Object"]], "profile"),
		expr("start_offset", "Offset", _LEN, "0", {"start": ["offset"]}),
		pick("start_object", "Start Object", ["plane", "face", "point"], true, {"start": ["object"]}),
		choice("side", "Direction", sides, "one"),
		choice("extent", "Extent", [["distance", "Distance"], ["to", "To Object"], ["all", "All"]], "distance"),
		expr("distance", "Distance", _LEN, "$size", {"extent": ["distance"]}),
		flag("whole_length", "Whole Length", false, {"side": ["symmetric"]}),
		expr("distance2", "Distance 2", _LEN, "$size", {"side": ["two"], "extent": ["distance", "to"]}),
		pick("to_object", "To Object", ["plane", "face", "body", "point"], true, {"extent": ["to"]}),
		flag("flip", "Flip"),
		# Loops narrow (holes widen); open curves lean to the left of the way they were drawn, as
		# seen looking back from the far end (a negative angle leans them right).
		expr("taper", "Taper Angle (open curves lean left, from the far end)", _ANG, "0"),
	], "new_body", {"arrow": "distance"}.merged(new_only))
	_add("surface:revolve", "Surface Revolve", [
		pick("profiles", "Profiles or Curves", curves),
		pick("axis", "Axis", ["axis"], true),
		choice("extent", "Extent", [["full", "Full"], ["angle", "Angle"], ["two_sides", "Two Sides"], ["symmetric", "Symmetric"], ["to", "To"]], "full"),
		expr("angle", "Angle", _ANG, "90", {"extent": ["angle", "two_sides", "symmetric"]}),
		expr("angle2", "Angle 2", _ANG, "90", {"extent": ["two_sides"]}),
		pick("to_object", "To Plane", ["plane", "face"], true, {"extent": ["to"]}),
		flag("flip", "Flip"),
	], "new_body", new_only)
	_add("surface:sweep", "Surface Sweep", [
		pick("profiles", "Profiles or Curves", curves),
		pick("path", "Path", ["path"]),
		pick("guide", "Guide Rail", ["path"]),
		choice("orientation", "Orientation", [["perpendicular", "Perpendicular"], ["parallel", "Parallel"]], "perpendicular"),
		expr("twist", "Twist Angle", _ANG, "0"),
		expr("scale", "End Scale", _NUM, "1"),
	], "new_body", new_only)
	_add("surface:loft", "Surface Loft", [
		pick("sections", "Profiles or Curves", ["profile", "face", "point", "sketch_curve", "edge"]),
		pick("centerline", "Centerline", ["path"]),
		pick("rails", "Rails (one exactly, several as a centerline)", ["path"]),
		flag("closed", "Closed"),
		flag("ruled", "Straight Sections (Ruled)"),
	], "new_body", new_only)
	var coil: Array = (get_spec("coil").fields as Array).duplicate(true)
	_add("surface:coil", "Surface Coil", coil, "new_body", new_only)
	# Stitched into the surface its edges came from, a patch makes no body of its own. Its filling
	# reaches tangency, not curvature, so G2 isn't offered (a document that stored it is refused;
	# edited, it reads as G1, the nearest it can build). The build reads a continuity stored as a
	# number by its digit, as an edit does.
	var continuities := [["g0", "G0 (Connected)"], ["g1", "G1 (Tangent)"]]
	var read_continuity := {"g2": "g1", "0": "g0", "1": "g1", "2": "g1"}
	_add("surface:patch", "Patch", [
		pick("boundary", "Boundary (edges, curves or a profile)", ["edge", "sketch_curve", "profile"]),
		choice("continuity", "Continuity", continuities, "g0").merged({"read_as": read_continuity}),
		pick("other_edges", "Edges With Another Continuity", ["edge"]),
		choice("other_continuity", "Their Continuity", continuities, "g1").merged({"read_as": read_continuity}),
		pick("points", "Interior Points", ["point"]),
		pick("rails", "Interior Rails", ["sketch_curve", "edge"]),
		flag("stitch", "Stitch Into the Surface"),
	], "new_body", {"op_visible_if": {"stitch": [false]}}.merged(new_only))
	_add("surface:ruled", "Ruled", [
		pick("edges", "Edges", ["edge"]),
		choice("ruled_type", "Ruled Type", [["tangent", "Tangent"], ["normal", "Normal"], ["direction", "Direction"]], "tangent"),
		pick("direction", "Direction", ["axis", "plane"], true, {"ruled_type": ["direction"]}),
		expr("distance", "Distance", _LEN, "$size/2"),
		expr("angle", "Angle", _ANG, "0"),
		flag("flip", "Flip"),
		flag("alternate", "Alternate Face"),
		choice("corner_type", "Corner Type", [["rounded", "Rounded"], ["mitered", "Mitered"]], "rounded").merged({"unset": "mitered"}),
	], "new_body", new_only)
	_add("surface:offset", "Offset Surface", [
		pick("faces", "Faces or Bodies", ["face", "body"]),
		expr("distance", "Distance (negative: the other way)", _LEN, "$size/5"),
	], "new_body", new_only)
	# One tool, but sketch curves gather (an outline of several curves cuts as one); the clicks on
	# the pieces keep where they hit ("at_click"), since a piece's middle can lie on another one.
	_add("surface:trim", "Trim", [
		pick("tool", "Trimming Tool", ["body", "face", "plane", "sketch_curve", "profile"], true).merged({"gather": ["sketch_curve"]}),
		pick("remove", "Pieces to Remove (click them)", ["face"]).merged({"at_click": true}),
		flag("extend", "Extend a Flat Tool Face", false),
	])
	var outer := {"untrim_type": ["all", "outer", "loops"]}
	_add("surface:untrim", "Untrim", [
		choice("untrim_type", "Loop Type", [["all", "All Loops"], ["inner", "Internal Loops"], ["outer", "External Loop"], ["loops", "Selected Loops"]], "all"),
		pick("faces", "Faces", ["face"], false, {"untrim_type": ["all", "inner", "outer"]}),
		pick("loops", "Loop Edges", ["edge"], false, {"untrim_type": ["loops"]}),
		expr("extend", "Extend Unbounded Sides", _LEN, "0", outer),
	])
	_add("surface:extend", "Extend", [
		pick("edges", "Edges", ["edge"]),
		flag("chain", "Chain Selection", true).merged({"unset": false}),
		expr("distance", "Distance", _LEN, "$size/5"),
		choice("extend_type", "Extend Type", [["natural", "Natural"], ["tangent", "Tangent"], ["perpendicular", "Perpendicular"]], "natural"),
	])
	_add("surface:stitch", "Stitch", [
		pick("bodies", "Surfaces", ["body"]),
		expr("tolerance", "Stitch Tolerance", _LEN, "0.01"),
		flag("solid", "Make a Solid When Closed", true),
	])
	_add("surface:unstitch", "Unstitch", [pick("objects", "Faces or Bodies", ["face", "body"])])
	_add("surface:merge", "Merge", [pick("edges", "Edges (or Faces) to Merge Across", ["edge", "face"])])
	_add("surface:reverse_normal", "Reverse Normal", [pick("objects", "Surface Bodies or Faces", ["body", "face"])])


## The Mesh workspace's tools ("mesh:<method>", core/features/mesh.gd). They own their bodies (no
## Operation row): most replace the picked mesh bodies in place; Tessellate, Separate, Plane Cut
## (Split Body), Combine (New Body) and Convert Mesh add bodies (options.outputs). Lengths, angles
## and numbers are inputs (expressions); everything else is an option. A tool's Method choice is
## stored as "algorithm": options.method is the tool itself.
static func _add_mesh_specs() -> void:
	var bodies := pick("bodies", "Mesh Bodies", ["mesh_body"])
	# (Pinned: the result row stays in sight when a short panel scrolls its other rows.)
	var stat := note("stat", "").merged({"pinned": true})
	var fills := [["minimal", "Minimal"], ["smooth", "Smooth"], ["flat", "Flat"]]
	var results := choice("result", "Result", [["new_body", "New Body (the mesh body is hidden)"], ["replace", "Replace the Mesh Body"]], "new_body")
	var custom := {"quality": ["custom"]}

	# --- Create ---
	_add("mesh:tessellate", "Tessellate", [
		pick("bodies", "Solid or Surface Bodies", ["body"]),
		choice("quality", "Refinement", [["low", "Low"], ["medium", "Medium"], ["high", "High"], ["very_high", "Very High"], ["custom", "Custom"]], "medium"),
		ranged(expr("linear", "Surface Deviation", _LEN, "$m:0.0001", custom), 1e-6, "D/10"),
		ranged(expr("angular", "Normal Deviation", _ANG, "15", custom), 1, 45),
		flag("relative", "Relative to Size", false, custom),
		flag("keep_original", "Keep Original Body", true),
		note("note", "For a maximum edge length, Remesh the result."),
		stat,
	])
	_add("mesh:section_sketch", "Create Mesh Section Sketch", [
		pick("body", "Mesh Body", ["mesh_body"], true),
		pick("plane", "Plane (or a flat face group)", ["plane", "mesh_group"], true),
		ranged(expr("tolerance", "Simplify Tolerance", _LEN, "$D/2000"), 0, "D/20"),
		flag("fit", "Fit Lines and Arcs"),
		stat,
	], "", {"label": "MeshSection"})

	# --- Prepare ---
	_add("mesh:close_holes", "Close Holes", [
		bodies,
		pick("loops", "Holes (none picked: every hole)", ["mesh_boundary"]),
		choice("fill", "Fill Type", fills, "smooth"),
		ranged(expr("max_edges", "Largest Hole (edges, 0 = any)", _NUM, "0"), 0, 100000, {"whole": true}),
		# (A Flat fill without it is the Minimal one moved into the hole's plane.)
		flag("refine", "Match Edge Size", true, {"fill": ["smooth", "flat"]}),
		stat,
	])
	_add("mesh:stitch_remove", "Stitch and Remove", [
		bodies,
		ranged(expr("tolerance", "Stitch Tolerance", _LEN, "$D*1e-5"), 0, "D/100"),
		flag("remove_small", "Remove Small Pieces", true),
		ranged(expr("min_size", "Smallest Piece to Keep (% of the largest piece's area)", _NUM, "1", {"remove_small": [true]}), 0, 50),
		flag("remove_inner", "Remove Pieces Inside Others"),
		flag("fix_non_manifold", "Fix Non-Manifold Edges", true),
		stat,
	])
	_add("mesh:wrap", "Wrap", [
		bodies,
		ranged(expr("detail", "Detail (cell size)", _LEN, "$D/150"), "D/400", "D/10"),
		ranged(expr("gap", "Close Gaps Up To", _LEN, "$detail*2"), "detail", "D/4"),
		ranged(expr("offset", "Offset", _LEN, "0"), "-gap", "D/10"),
		note("note", "Several bodies are wrapped into one. Edges come out rounded to about the Detail."),
		stat,
	], "", {"metrics": "union", "voxel": {"field": "detail", "op": "wrap", "margin": ["gap", "offset"], "cells": 2.0}})
	_add("mesh:rebuild", "Rebuild", [
		bodies,
		ranged(expr("detail", "Detail (cell size)", _LEN, "$D/250"), "D/600", "D/10"),
		choice("algorithm", "Method", [["union", "Union"], ["exact_surface", "Exact Surface"]], "union"),
		stat,
	], "", {"voxel": {"field": "detail", "op": "rebuild", "margin": [], "cells": 2.0}})
	_add("mesh:generate_groups", "Generate Face Groups", [
		bodies,
		choice("algorithm", "Method", [["fast", "Fast (by angle)"], ["accurate", "Accurate (flat and round areas)"]], "accurate"),
		ranged(expr("angle", "Angle Threshold", _ANG, "20", {"algorithm": ["fast"]}), 1, 90),
		ranged(expr("tolerance", "Fit Tolerance", _LEN, "$D/2000", {"algorithm": ["accurate"]}), "D*1e-6", "D/20"),
		ranged(expr("min_size", "Smallest Group (triangles)", _NUM, "10"), 1, 100000, {"whole": true}),
		stat,
	])
	_add("mesh:combine_groups", "Combine Face Groups", [
		pick("groups", "Face Groups (two or more of one body)", ["mesh_group"]),
		stat,
	])
	_add("mesh:create_group", "Create Face Group", [
		pick("selection", "Triangles (of one body)", ["mesh_triangles"]),
		stat,
	])

	# --- Modify ---
	var uniform := {"mode": ["uniform"]}
	var adaptive := {"mode": ["adaptive"]}
	_add("mesh:remesh", "Remesh", [
		bodies,
		pick("selection", "Triangles (none: the whole body)", ["mesh_triangles"]),
		choice("mode", "Type", [["uniform", "Uniform"], ["adaptive", "Adaptive"]], "uniform"),
		ranged(expr("density", "Density (0 coarser, 1 finer)", _NUM, "0.5", uniform), 0.01, 1),
		ranged(expr("edge_length", "Edge Length (overrides Density when not 0)", _LEN, "0", uniform), "D/2000", "D/5", {"zero_ok": true}),
		# Left empty, the kernel picks it (D/1000, raised until the result fits its triangle limit).
		ranged(expr("min_edge", "Minimum Edge", _LEN, "", adaptive), 0, "max_edge", {"gt": true, "lt": true, "optional": true, "used": "min_edge"}),
		ranged(expr("max_edge", "Maximum Edge", _LEN, "$D/50", adaptive), "min_edge", "D/5", {"gt": true}),
		ranged(expr("approx_error", "Shape Error", _LEN, "$D/2000", adaptive), "D*1e-6", "D/20"),
		ranged(expr("iterations", "Passes", _NUM, "10"), 1, 50, {"whole": true}),
		flag("keep_sharp", "Keep Sharp Edges", true),
		ranged(expr("sharp_angle", "Sharp Edge Angle", _ANG, "45", {"keep_sharp": [true]}), 10, 170),
		flag("keep_boundary", "Keep Open Edges", true),
		flag("keep_groups", "Keep Face Group Borders", true),
		stat,
	])
	_add("mesh:reduce", "Reduce", [
		bodies,
		pick("selection", "Triangles (none: the whole body)", ["mesh_triangles"]),
		choice("target", "Reduce By", [["proportion", "Proportion"], ["face_count", "Triangle Count"], ["tolerance", "Deviation"]], "proportion"),
		# Both count the whole body, also when only a selection may change.
		ranged(expr("proportion", "Keep (% of the whole body's triangles)", _NUM, "50", {"target": ["proportion"]}), 1, 99),
		ranged(expr("face_count", "Triangle Count (of the whole body)", _NUM, "$T/2", {"target": ["face_count"]}), 4, "T-1", {"whole": true}),
		ranged(expr("tolerance", "Maximum Deviation", _LEN, "$D/2000", {"target": ["tolerance"]}), "D*1e-6", "D/10"),
		choice("algorithm", "Method", [["adaptive", "Adaptive (keeps the shape best)"], ["fast", "Fast (for big bodies)"]], "adaptive"),
		flag("keep_boundary", "Keep Open Edges", true),
		flag("keep_groups", "Keep Face Group Borders", true),
		flag("keep_sharp", "Keep Sharp Edges"),
		ranged(expr("sharp_angle", "Sharp Edge Angle", _ANG, "45", {"keep_sharp": [true]}), 10, 170),
		stat,
	])
	_add("mesh:plane_cut", "Plane Cut", [
		bodies,
		pick("plane", "Cut Plane (or a flat face group)", ["plane", "mesh_group"], true),
		choice("type", "Cut Type", [["trim", "Trim"], ["split_body", "Split Body"], ["split_faces", "Split Faces"]], "trim"),
		ranged(expr("offset", "Offset", _LEN, "0"), "-D", "D"),
		flag("flip", "Keep Other Side"),
		choice("fill", "Fill", [["none", "None"], ["uniform", "Uniform"], ["minimal", "Minimal"]], "uniform", {"type": ["trim", "split_body"]}),
		stat,
	], "", {"arrow": "offset", "arrow_signed": true})
	_add("mesh:shell", "Shell", [
		bodies,
		ranged(expr("thickness", "Thickness", _LEN, "$D/50"), "D/2000", "D/4"),
		choice("direction", "Direction", [["inside", "Inside"], ["outside", "Outside"], ["both", "Both"]], "inside"),
		choice("algorithm", "Method", [["fast", "Fast"], ["accurate", "Accurate"]], "accurate"),
		ranged(expr("detail", "Detail (cell size)", _LEN, "$thickness/4", {"algorithm": ["accurate"]}), "thickness/10", "thickness/2"),
		stat,
	], "", {"label": "MeshShell", "voxel": {"field": "detail", "op": "shell", "margin": ["thickness"], "cells": 2.0}})
	_add("mesh:combine", "Combine", [
		pick("target", "Target Mesh Body", ["mesh_body"], true),
		pick("tools", "Tool Bodies (solids are tessellated)", ["mesh_body", "body"]),
		choice("operation", "Operation", [["join", "Join"], ["cut", "Cut"], ["intersect", "Intersect"], ["merge", "Merge (no boolean)"]], "join"),
		flag("keep_tools", "Keep Tools"),
		flag("new_body", "New Body"),
		stat,
	], "", {"label": "MeshCombine"})
	_add("mesh:smooth", "Smooth", [
		bodies,
		pick("selection", "Triangles (none: the whole body)", ["mesh_triangles"]),
		ranged(expr("strength", "Smoothness", _NUM, "0.5"), 0, 1),
		ranged(expr("iterations", "Passes", _NUM, "5"), 1, 50, {"whole": true}),
		flag("keep_volume", "Keep Volume", true),
		flag("keep_sharp", "Keep Sharp Edges"),
		ranged(expr("sharp_angle", "Sharp Edge Angle", _ANG, "45", {"keep_sharp": [true]}), 10, 170),
		flag("keep_boundary", "Keep Open Edges", true),
		stat,
	])
	_add("mesh:reverse_normal", "Reverse Normal", [
		choice("mode", "Reverse", [["auto", "Automatic (fix inside-out parts)"], ["whole", "Whole Body"], ["selection", "Selection"]], "auto"),
		pick("bodies", "Mesh Bodies", ["mesh_body"], false, {"mode": ["whole", "auto"]}),
		pick("selection", "Face Groups or Triangles", ["mesh_group", "mesh_triangles"], false, {"mode": ["selection"]}),
		stat,
	], "", {"label": "MeshReverseNormal"})
	_add("mesh:erase_fill", "Erase and Fill", [
		pick("selection", "Triangles or Face Groups (of one body)", ["mesh_triangles", "mesh_group"]),
		choice("fill", "Fill Type", fills, "smooth"),
		stat,
	])
	_add("mesh:align", "Mesh Align", [
		pick("source", "Flat Face Group to Align", ["mesh_group"], true),
		pick("points", "Or Three Points on the Mesh", ["mesh_triangles"]).merged({"separate": true, "limit": 3}),
		pick("to", "Align To (plane or flat face)", ["plane"], true),
		flag("flip", "Flip"),
		expr("offset", "Offset", _LEN, "0"),
		stat,
	])
	_add("mesh:texture_extrude", "Texture Extrude", [
		pick("selection", "Face Groups or Triangles (of one body)", ["mesh_group", "mesh_triangles"]),
		text("image", "Image", ""), {"key": "browse", "label": "Choose File...", "type": "button", "tooltip": "A PNG or JPG: bright areas rise by the Depth"},
		ranged(expr("depth", "Depth", _LEN, "$D/200"), "-D/10", "D/10", {"not_zero": true}),
		choice("mapping", "Mapping", [["planar", "Planar"], ["box", "Box"], ["cylindrical", "Cylindrical"]], "box"),
		ranged(expr("tile", "Tile Size", _LEN, "$D/5"), "D/1000", "D*10"),
		ranged(expr("angle", "Rotation", _ANG, "0"), -360, 360),
		flag("invert", "Invert"),
		ranged(expr("detail", "Detail (edge length)", _LEN, "$tile/128"), "tile/512", "tile/8"),
		stat,
	])
	_add("mesh:separate", "Separate", [
		bodies,
		choice("by", "Separate By", [["components", "Connected Pieces"], ["groups", "Face Groups"]], "components"),
		stat,
	])
	# Move/Copy: the Solid tool's fields on mesh bodies (the same option keys, so the build is shared).
	var move: Array = (get_spec("move").fields as Array).duplicate(true)
	move[0] = pick("objects", "Mesh Bodies", ["mesh_body"])
	_add("mesh:move", "Move/Copy", move + [stat], "", {"label": "MeshMove"})
	var one := {"uniform": [true]}
	var each := {"uniform": [false]}
	_add("mesh:scale", "Scale Mesh", [
		bodies,
		pick("point", "Point (empty: the body's middle)", ["point"], true),
		flag("uniform", "Uniform", true),
		ranged(expr("scale", "Scale Factor", _NUM, "1", one), 0.001, 1000),
		ranged(expr("sx", "X Scale", _NUM, "1", each), 0.001, 1000),
		ranged(expr("sy", "Y Scale", _NUM, "1", each), 0.001, 1000),
		ranged(expr("sz", "Z Scale", _NUM, "1", each), 0.001, 1000),
		stat,
	])

	# --- Convert Mesh ---
	_add("mesh:convert_faceted", "Convert Mesh: Faceted", [
		bodies,
		flag("merge_flat", "Merge Flat Face Groups", true),
		ranged(expr("flat_tolerance", "Flat Tolerance", _LEN, "$D*1e-6", {"merge_flat": [true]}), 0, "D/100"),
		results,
		stat,
	], "", {"label": "ConvertFaceted"})
	_add("mesh:convert_prismatic", "Convert Mesh: Prismatic", [
		bodies,
		ranged(expr("tolerance", "Fit Tolerance", _LEN, "$D/1000"), "D*1e-6", "D/20"),
		flag("allow_spheres", "Allow Spheres", true),
		results,
		note("note", "For machined parts: each flat or round area needs its own face group (Generate Face Groups)."),
		stat,
	], "", {"label": "ConvertPrismatic"})
	_add("mesh:convert_organic", "Convert Mesh: Organic (experimental)", [
		pick("body", "Closed Mesh Body", ["mesh_body"], true),
		ranged(expr("faces", "Target Cage Faces", _NUM, "500"), 24, 5000, {"whole": true}),
		choice("output", "Output", [["brep", "Solid Body"], ["form_body", "Form Body"]], "brep"),
		ranged(expr("tolerance", "Allowed Deviation", _LEN, "$D/500"), 0, "D/10", {"gt": true}),
		results,
		note("note", "Experimental: for smooth sculpted shapes. It may refuse; Reduce a big body first."),
		stat,
	], "", {"label": "ConvertOrganic"})


static func _build() -> void:
	var profile_kinds := ["profile", "face"]
	var sides := [["one", "One Side"], ["two", "Two Sides"], ["symmetric", "Symmetric"]]
	_add("extrude", "Extrude", [
		pick("profiles", "Profiles", profile_kinds + ["sketch_curve"]),
		choice("start", "Start", [["profile", "Profile Plane"], ["offset", "Offset"], ["object", "Object"]], "profile"),
		expr("start_offset", "Offset", _LEN, "0", {"start": ["offset"]}),
		pick("start_object", "Start Object", ["plane", "face", "point"], true, {"start": ["object"]}),
		choice("side", "Direction", sides, "one"),
		choice("extent", "Extent", [["distance", "Distance"], ["to", "To Object"], ["all", "All"]], "distance"),
		expr("distance", "Distance", _LEN, "$size", {"extent": ["distance"]}),
		flag("whole_length", "Whole Length", false, {"side": ["symmetric"]}),
		expr("distance2", "Distance 2", _LEN, "$size", {"side": ["two"], "extent": ["distance", "to"]}),
		pick("to_object", "To Object", ["plane", "face", "body", "point"], true, {"extent": ["to"]}),
		flag("flip", "Flip"),
		expr("taper", "Taper Angle", _ANG, "0"),
		flag("thin", "Thin Extrude"),
		choice("thin_side", "Thin Side", [["inside", "Side 1 (inside)"], ["outside", "Side 2 (outside)"], ["center", "Center"]], "inside", {"thin": [true]}),
		expr("thickness", "Thickness", _LEN, "1", {"thin": [true]}),
	# The automatic operation (auto) is the default, and what a Press Pull on a profile makes: it joins
	# the body the profile sits on, cuts it when pulled back past zero, or makes a new body when it
	# touches none. The Operation list shows which of those it does; a choice picked there by hand
	# stays (tools/command.gd operation_fields). The arrow goes both ways (a negative distance runs
	# the other way).
	], "auto", {"arrow": "distance", "arrow_signed": true, "ops": ["auto", "new_body", "join", "cut", "intersect", "new_component"]})
	_add("revolve", "Revolve", [
		pick("profiles", "Profiles", profile_kinds),
		pick("axis", "Axis", ["axis"], true),
		choice("extent", "Extent", [["full", "Full"], ["angle", "Angle"], ["two_sides", "Two Sides"], ["symmetric", "Symmetric"], ["to", "To"]], "full"),
		expr("angle", "Angle", _ANG, "90", {"extent": ["angle", "two_sides", "symmetric"]}),
		expr("angle2", "Angle 2", _ANG, "90", {"extent": ["two_sides"]}),
		pick("to_object", "To Plane", ["plane", "face"], true, {"extent": ["to"]}),
		flag("flip", "Flip"),
	], "new_body")
	_add("sweep", "Sweep", [
		pick("profiles", "Profile", profile_kinds),
		pick("path", "Path", ["path"]),
		pick("guide", "Guide Rail", ["path"]),
		choice("orientation", "Orientation", [["perpendicular", "Perpendicular"], ["parallel", "Parallel"]], "perpendicular"),
		expr("twist", "Twist Angle", _ANG, "0"),
		expr("scale", "End Scale", _NUM, "1"),
	], "new_body")
	_add("loft", "Loft", [
		pick("sections", "Profiles", ["profile", "face", "point", "sketch_curve"]),
		pick("centerline", "Centerline", ["path"]),
		pick("rails", "Rails (one exactly, several as a centerline)", ["path"]),
		flag("closed", "Closed"),
		flag("ruled", "Straight Sections (Ruled)"),
	], "new_body")
	_add("rib", "Rib", [
		pick("curves", "Curve", ["sketch_curve"]),
		expr("thickness", "Thickness", _LEN, "2"),
		choice("thickness_side", "Thickness", [["symmetric", "Symmetric"], ["one", "One Side"]], "symmetric"),
		flag("flip", "Flip"),
		pick("targets", "Body", ["body"]),
	])
	_add("web", "Web", [
		pick("curves", "Curves", ["sketch_curve"]),
		expr("thickness", "Thickness", _LEN, "2"),
		expr("depth", "Depth", _LEN, "$size"),
		choice("depth_side", "Depth", [["one", "One Side"], ["symmetric", "Symmetric"]], "one"),
		flag("flip", "Flip"),
	], "join")
	_add("emboss", "Emboss", [
		pick("profiles", "Profiles", ["profile"]),
		pick("face", "Face", ["face"], true),
		choice("effect", "Effect", [["emboss", "Emboss"], ["deboss", "Deboss"]], "emboss"),
		expr("depth", "Depth", _LEN, "1"),
	])
	var standards := []
	for standard in HOLE.standards():
		standards.append([standard, standard])
	var tapped := {"tap_type": ["tapped", "taper_tapped"]}
	_add("hole", "Hole", [
		pick("points", "Positions", ["point"]),
		pick("face", "Start Face", ["face"], true),
		choice("hole_type", "Hole Type", [["simple", "Simple"], ["counterbore", "Counterbore"], ["countersink", "Countersink"]], "simple"),
		choice("tap_type", "Hole Tap Type", [["simple", "Simple"], ["clearance", "Clearance"], ["tapped", "Tapped"], ["taper_tapped", "Taper Tapped"]], "simple"),
		choice("standard", "Standard", standards, "ISO Metric", {"tap_type": ["clearance", "tapped", "taper_tapped"]}),
		text("size", "Size", "M6", {"tap_type": ["clearance", "tapped", "taper_tapped"]}),
		choice("fit", "Fit", [["close", "Close"], ["normal", "Normal"], ["loose", "Loose"]], "normal", {"tap_type": ["clearance"]}),
		flag("modeled", "Modeled Thread", false, tapped),
		expr("diameter", "Diameter", _LEN, "6", {"tap_type": ["simple"]}),
		choice("extent", "Extent", [["distance", "Distance"], ["to", "To"], ["all", "All"]], "distance"),
		expr("depth", "Depth", _LEN, "10", {"extent": ["distance"]}),
		pick("to_object", "To Object", ["plane", "face", "point"], true, {"extent": ["to"]}),
		expr("cb_diameter", "Counterbore Diameter", _LEN, "11", {"hole_type": ["counterbore"]}),
		expr("cb_depth", "Counterbore Depth", _LEN, "6", {"hole_type": ["counterbore"]}),
		expr("cs_diameter", "Countersink Diameter", _LEN, "13", {"hole_type": ["countersink"]}),
		expr("cs_angle", "Countersink Angle", _ANG, "90", {"hole_type": ["countersink"]}),
		choice("drill_point", "Drill Point", [["flat", "Flat"], ["angled", "Angled"]], "flat"),
		expr("drill_angle", "Drill Point Angle", _ANG, "118", {"drill_point": ["angled"]}),
		flag("flip", "Flip"),
	])
	_add("thread", "Thread", [
		pick("faces", "Faces", ["face"]),
		choice("standard", "Standard", standards, "ISO Metric"),
		text("size", "Size (empty: closest)", ""),
		flag("modeled", "Modeled"),
		flag("full_length", "Full Length", true),
		expr("length", "Length", _LEN, "10", {"full_length": [false]}),
		expr("offset", "Offset", _LEN, "0", {"full_length": [false]}),
		flag("left", "Left Hand"),
		flag("flip", "Start at the Other End"),
	])
	_add("torus", "Torus", [
		expr("diameter", "Diameter", _LEN, "$size"),
		expr("section", "Torus Diameter", _LEN, "$size/4"),
		{"key": "position", "label": "Center", "type": "point", "default": "$position"},
	], "new_body")
	var coil_turns := {"coil_type": ["revolution_height", "revolution_pitch", "spiral"]}
	_add("coil", "Coil", [
		choice("coil_type", "Type", [["revolution_height", "Revolution and Height"], ["revolution_pitch", "Revolution and Pitch"], ["height_pitch", "Height and Pitch"], ["spiral", "Spiral"]], "revolution_height"),
		expr("diameter", "Diameter", _LEN, "$size"),
		expr("turns", "Revolutions", _NUM, "5", coil_turns),
		expr("height", "Height", _LEN, "$size", {"coil_type": ["revolution_height", "height_pitch"]}),
		expr("pitch", "Pitch", _LEN, "$size/5", {"coil_type": ["revolution_pitch", "height_pitch", "spiral"]}),
		expr("taper", "Angle", _ANG, "0", {"coil_type": ["revolution_height", "revolution_pitch", "height_pitch"]}),
		choice("section", "Section", [["circle", "Circular"], ["square", "Square"], ["triangle_out", "Triangular (External)"], ["triangle_in", "Triangular (Internal)"]], "circle"),
		choice("section_position", "Section Position", [["inside", "Inside"], ["on", "On Center"], ["outside", "Outside"]], "on"),
		expr("section_size", "Section Size", _LEN, "$size/10"),
		flag("left", "Left Hand"),
		{"key": "position", "label": "Base Center", "type": "point", "default": "$position"},
	], "new_body")
	_add("pipe", "Pipe", [
		pick("path", "Path", ["path"]),
		choice("section", "Section", [["circle", "Circular"], ["square", "Square"], ["triangle_out", "Triangular"]], "circle"),
		expr("diameter", "Section Size", _LEN, "$size/5"),
		flag("hollow", "Hollow"),
		expr("thickness", "Section Thickness", _LEN, "1", {"hollow": [true]}),
	], "new_body")

	var objects := [choice("object_type", "Object Type", OBJECT_TYPES, "bodies"),
		{"key": "objects", "label": "Objects", "type": "selection", "filter": ["body"], "filter_by": OBJECT_KINDS, "default": []}]
	var suppress := text("suppressed", "Suppress Copies", "", {}, "int_list")
	var spacing := choice("distance_type", "Distance Type", [["extent", "Extent"], ["spacing", "Spacing"]], "extent")
	_add("rect_pattern", "Rectangular Pattern", objects + [
		pick("direction1", "Direction 1", ["axis"], true),
		expr("quantity1", "Quantity", _NUM, "3"),
		expr("distance1", "Distance", _LEN, "$size"),
		flag("symmetric1", "Symmetric"), flag("flip1", "Flip"),
		pick("direction2", "Direction 2", ["axis"], true),
		expr("quantity2", "Quantity 2", _NUM, "1"),
		expr("distance2", "Distance 2", _LEN, "$size"),
		flag("symmetric2", "Symmetric 2"), flag("flip2", "Flip 2"),
		spacing, suppress,
	])
	_add("circ_pattern", "Circular Pattern", objects + [
		pick("axis", "Axis", ["axis"], true),
		expr("quantity", "Quantity", _NUM, "6"),
		expr("angle", "Total Angle", _ANG, "360"),
		flag("symmetric", "Symmetric"),
		suppress,
	])
	_add("path_pattern", "Pattern on Path", objects + [
		pick("path", "Path", ["path"]),
		expr("quantity", "Quantity", _NUM, "3"),
		expr("distance", "Distance", _LEN, "$size"),
		spacing,
		choice("orientation", "Orientation", [["identical", "Identical"], ["path", "Path Direction"]], "identical"),
		flag("flip", "Start at the Other End"),
		suppress,
	])
	_add("mirror", "Mirror", objects + [
		pick("plane", "Mirror Plane", ["plane"], true),
		choice("operation", "Operation", [["new_body", "New Body"], ["join", "Join"]], "new_body", {"object_type": ["bodies", "components"]}),
	])
	_add("thicken", "Thicken", [
		pick("faces", "Faces or Surface Bodies", ["face", "body"]),
		expr("thickness", "Thickness", _LEN, "2"),
		choice("direction", "Direction", [["one", "One Side"], ["symmetric", "Symmetric"]], "one"),
		choice("thicken_type", "Thicken Type", [["sharp", "Sharp"], ["rounded", "Rounded"]], "sharp"),
		flag("flip", "Flip"),
	], "new_body")
	_add("boundary_fill", "Boundary Fill", [
		pick("tools", "Tools", ["body", "face", "plane"]),
		pick("cells", "Cells (points inside; none keeps all)", ["point"]),
	], "new_body")

	_add("fillet", "Fillet", [
		pick("edges", "Edges", ["edge", "face", "body"]),
		choice("radius_type", "Radius Type", [["constant", "Constant"], ["variable", "Variable"], ["chord", "Chord Length"]], "constant"),
		expr("radius", "Radius", _LEN, "1"),
		expr("radius2", "End Radius", _LEN, "2", {"radius_type": ["variable"]}),
		choice("rule", "Rule (for bodies)", [["all", "All Edges"], ["rounds", "Rounds (outside)"], ["fillets", "Fillets (inside)"]], "all"),
	], "", {"arrow": ""})
	_add("chamfer", "Chamfer", [
		pick("edges", "Edges", ["edge", "face", "body"]),
		choice("chamfer_type", "Chamfer Type", [["equal", "Equal Distance"], ["two", "Two Distances"], ["angle", "Distance and Angle"]], "equal"),
		expr("distance", "Distance", _LEN, "1"),
		expr("distance2", "Distance 2", _LEN, "2", {"chamfer_type": ["two"]}),
		expr("angle", "Angle", _ANG, "45", {"chamfer_type": ["angle"]}),
		choice("rule", "Rule (for bodies)", [["all", "All Edges"], ["rounds", "Outside Edges"], ["fillets", "Inside Edges"]], "all"),
	])
	_add("shell", "Shell", [
		pick("faces", "Faces / Body", ["face", "body"]),
		expr("thickness", "Inside Thickness", _LEN, "1"),
		choice("direction", "Direction", [["inside", "Inside"], ["outside", "Outside"], ["both", "Both"]], "inside"),
	])
	_add("draft", "Draft", [
		pick("plane", "Pull Direction (Fixed Plane)", ["plane"], true),
		pick("faces", "Faces", ["face"]),
		expr("angle", "Angle", _ANG, "5"),
		choice("side", "Draft Side", [["one", "One Side"], ["symmetric", "Symmetric (split at the plane)"]], "one"),
		flag("flip", "Flip Pull Direction"),
	])
	_add("scale", "Scale", [
		pick("bodies", "Entities", ["body", "component"]),
		pick("point", "Point", ["point"], true),
		choice("scale_type", "Scale Type", [["uniform", "Uniform"], ["non_uniform", "Non-uniform"]], "uniform"),
		expr("scale", "Scale Factor", _NUM, "1", {"scale_type": ["uniform"]}),
		expr("scale_x", "X Scale", _NUM, "1", {"scale_type": ["non_uniform"]}),
		expr("scale_y", "Y Scale", _NUM, "1", {"scale_type": ["non_uniform"]}),
		expr("scale_z", "Z Scale", _NUM, "1", {"scale_type": ["non_uniform"]}),
	])
	_add("combine", "Combine", [
		pick("target", "Target Body", ["body"], true),
		pick("tools", "Tool Bodies", ["body"]),
		choice("operation", "Operation", [["join", "Join"], ["cut", "Cut"], ["intersect", "Intersect"]], "join"),
		flag("keep_tools", "Keep Tools"),
	])
	_add("offset_face", "Offset Face", [pick("faces", "Faces", ["face"]), expr("distance", "Distance", _LEN, "1")], "", {"arrow": "distance"})
	_add("replace_face", "Replace Face", [pick("faces", "Source Faces", ["face"]), pick("target", "Target (plane, face or surface body)", ["plane", "face", "body"], true)])
	_add("split_face", "Split Face", [pick("faces", "Faces to Split", ["face"]), pick("tool", "Splitting Tool", ["plane", "face", "body"], true), flag("extend", "Extend Splitting Tool", true)])
	_add("split_body", "Split Body", [pick("body", "Body to Split", ["body"], true), pick("tool", "Splitting Tool", ["plane", "face", "body"], true), flag("extend", "Extend Splitting Tool", true)])
	_add("silhouette_split", "Silhouette Split", [pick("body", "Body", ["body"], true), pick("direction", "View Direction", ["axis", "plane"], true)])
	var free := {"move_type": ["free"]}
	_add("move", "Move/Copy", [
		pick("objects", "Objects", ["body", "component"]),
		choice("move_type", "Move Type", [["free", "Free Move"], ["translate", "Translate"], ["rotate", "Rotate"], ["point_to_point", "Point to Point"]], "free"),
		expr("x", "X Distance", _LEN, "0", free), expr("y", "Y Distance", _LEN, "0", free), expr("z", "Z Distance", _LEN, "0", free),
		expr("rx", "X Angle", _ANG, "0", free), expr("ry", "Y Angle", _ANG, "0", free), expr("rz", "Z Angle", _ANG, "0", free),
		pick("axis", "Axis", ["axis"], true, {"move_type": ["translate", "rotate"]}),
		expr("distance", "Distance", _LEN, "$size", {"move_type": ["translate"]}),
		expr("angle", "Angle", _ANG, "90", {"move_type": ["rotate"]}),
		pick("from_point", "From Point", ["point"], true, {"move_type": ["point_to_point"]}),
		pick("to_point", "To Point", ["point"], true, {"move_type": ["point_to_point"]}),
		flag("copy", "Create Copy"),
	])
	_add("align", "Align", [
		pick("from", "From (on the body to move)", ["face", "point"], true),
		pick("to", "To", ["face", "plane", "point"], true),
		pick("objects", "Also Move", ["body", "component"]),
		flag("flip", "Flip"), flag("copy", "Create Copy"),
	])
	_add("remove", "Remove", [pick("bodies", "Bodies", ["body"]), pick("faces", "Faces", ["face"])])

	_add_surface_specs(profile_kinds, sides)
	_add_mesh_specs()

	# Insert Fastener (tools/fastener_command.gd turns the pick and direction into position/axis).
	var fastener_kinds := []
	for kind in INSERT.fastener_kinds():
		var entry: Dictionary = INSERT.fastener_table()[kind]
		fastener_kinds.append([kind, "%s (%s)" % [entry.get("label", kind), entry.get("standard", "")]])
	var fastener_sizes := []
	for size in INSERT.fastener_sizes("hex_bolt"):
		fastener_sizes.append([size, size])
	_add("fastener", "Fastener", [
		choice("kind", "Type", fastener_kinds, "hex_bolt"),
		choice("size", "Size", fastener_sizes, "M6"),
		expr("length", "Length", _LEN, "$size", {"kind": INSERT.BOLTS}),
		pick("place", "Place On (hole edge, point or face)", ["point", "face"], true),
		{"key": "position", "label": "Position", "type": "point", "default": "$position"},
		choice("direction", "Direction", [["auto", "From the Pick"], ["down", "-Y (Down)"], ["up", "+Y (Up)"],
			["+x", "+X"], ["-x", "-X"], ["+z", "+Z"], ["-z", "-Z"]], "auto"),
		flag("flip", "Flip"),
		expr("angle", "Rotation", _ANG, "0"),
	], "new_body")

	# Insert features, edited from the timeline (tools/insert_command.gd; the Insert menu adds
	# them). "source" shows what was read; Derive adds a row per source body.
	var source := [text("path", "File", ""), {"key": "browse", "label": "Choose File...", "type": "button"},
		{"key": "source", "label": "Source", "type": "info", "text": ""}]
	var placement := [
		expr("x", "X Offset", _LEN, "0"), expr("y", "Y Offset", _LEN, "0"), expr("z", "Z Offset", _LEN, "0"),
		expr("rx", "X Angle", _ANG, "0"), expr("ry", "Y Angle", _ANG, "0"), expr("rz", "Z Angle", _ANG, "0"),
	]
	_add("import", "Import", source + [
		flag("linked", "Linked (read the file on every rebuild)"),
		flag("split", "One Body per Solid"),
	] + placement, "new_body")
	# Body Type: a mesh body (the Mesh workspace's) or a faceted solid. A feature saved before the
	# choice existed is a solid.
	_add("mesh_import", "Insert Mesh", source + [
		choice("kind", "Body Type", [["mesh", "Mesh Body"], ["solid", "Solid (faceted)"]], "solid").merged({"unset": "solid"}),
		choice("units", "One File Unit Is", MESH_UNITS, "mm"),
		flag("z_up", "The File Is Z-Up"),
		flag("linked", "Linked (read the file on every rebuild)"),
		flag("split", "One Body per Piece"),
	] + placement, "new_body")
	_add("derive", "Derive", source + placement)

	# Construction: one spec per method.
	var plane := ["plane"]
	_add("plane:offset", "Offset Plane", [pick("plane", "Plane", plane, true), expr("distance", "Distance", _LEN, "$size")], "", {"arrow": "distance"})
	_add("plane:angle", "Plane at Angle", [pick("axis", "Line", ["axis"], true), expr("angle", "Angle", _ANG, "45")])
	_add("plane:tangent", "Tangent Plane", [pick("face", "Round Face", ["face"], true), pick("plane", "Reference Plane", plane, true), expr("angle", "Angle", _ANG, "0")])
	_add("plane:midplane", "Midplane", [pick("plane", "First Plane", plane, true), pick("plane2", "Second Plane", plane, true)])
	_add("plane:perpendicular", "Perpendicular Plane", [pick("axis", "Line", ["axis"], true), pick("point", "Through Point", ["point"], true)])
	_add("plane:two_edges", "Plane Through Two Edges", [pick("axis", "First Line", ["axis"], true), pick("axis2", "Second Line", ["axis"], true)])
	_add("plane:three_points", "Plane Through Three Points", [pick("points", "Three Points", ["point"])])
	_add("plane:tangent_at_point", "Plane Tangent to Face at Point", [pick("face", "Face", ["face"], true), pick("point", "Point", ["point"], true)])
	_add("plane:along_path", "Plane Along Path", [pick("path", "Path", ["path"]), expr("distance", "Distance (0 to 1)", _NUM, "0.5")])
	_add("axis:cylinder", "Axis Through Cylinder/Cone/Torus", [pick("face", "Round Face", ["face"], true)])
	_add("axis:perp_at_point", "Axis Perpendicular at Point", [pick("face", "Flat Face", ["face"], true), pick("point", "Point", ["point"], true)])
	_add("axis:two_planes", "Axis Through Two Planes", [pick("plane", "First Plane", plane, true), pick("plane2", "Second Plane", plane, true)])
	_add("axis:two_points", "Axis Through Two Points", [pick("point", "First Point", ["point"], true), pick("point2", "Second Point", ["point"], true)])
	_add("axis:edge", "Axis Through Edge", [pick("axis", "Edge or Line", ["axis"], true)])
	_add("axis:perp_face_point", "Axis Perpendicular to Face at Point", [pick("face", "Face", ["face"], true), pick("point", "Point", ["point"], true)])
	_add("point:vertex", "Point at Vertex", [pick("point", "Vertex", ["point"], true)])
	_add("point:two_edges", "Point Through Two Edges", [pick("axis", "First Edge", ["axis"], true), pick("axis2", "Second Edge", ["axis"], true)])
	_add("point:three_planes", "Point Through Three Planes", [pick("plane", "First Plane", plane, true), pick("plane2", "Second Plane", plane, true), pick("plane3", "Third Plane", plane, true)])
	_add("point:center", "Point at Center of Circle/Sphere/Torus", [pick("center", "Circle Edge or Round Face", ["edge", "face"], true)])
	_add("point:edge_plane", "Point at Edge and Plane", [pick("axis", "Edge or Line", ["axis"], true), pick("plane", "Plane", plane, true)])
	_add("point:along_path", "Point Along Path", [pick("path", "Path", ["path"]), expr("distance", "Distance (0 to 1)", _NUM, "0.5")])
