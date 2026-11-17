@tool
extends RefCounted
## Form modify, symmetry and utility tools wired in Stage 3 (team M2): Edit By Curve, Insert Edge,
## Subdivide, Insert Point, Merge Edge, Bridge, Fill Hole, Erase and Fill, Weld Vertices, UnWeld
## Edges, Bevel Edge, Slide Edge, Smooth, Cylindrify, Pull, Flatten, Straighten, Match,
## Interpolate, Thicken, Mirror / Circular - Internal and - Duplicate, Isolate Symmetry, Repair
## Body, Make Uniform and Convert. A tool is enabled once its id is in TOOLS (see ui/form_tools.gd
## for the spec format and the run_<id> / handle_mouse_<id> / draw_<id> functions the registry
## dispatches to). Never preload catalog.gd, forge_workspace.gd, form_editor.gd or form_tools.gd
## here (form_tools.gd preloads this file).
##
## Picks beyond a tool's first slot live in the panel as "selection" fields, so the panel's own
## slot buttons choose where the next click goes:
## - a field with "cage": true holds form cage items ({"kind", "body", "index", "pair"}, like the
##   editor's selection) of its "kinds" (Bridge's Side Two, Merge Edge's Edge Group Two);
## - any other selection field holds model references (core/references.gd) of its "filter" kinds,
##   picked with the workspace's reference picker (planes, axes, sketch curves, model edges and
##   faces), or body ids when its filter is the String "body".
## In run_<id> these arrive in values[key] as Arrays. Headless callers may also give geometry
## directly: a plane as {"origin", "normal"}, an axis or line as {"origin", "direction"}, a point
## as a Vector3.

const CAGE := preload("res://addons/holo_forge/core/form/cage.gd")
const FORM_OPS := preload("res://addons/holo_forge/core/form/form_ops.gd")
const FORM_FIT := preload("res://addons/holo_forge/core/form/form_fit.gd")
const FORM := preload("res://addons/holo_forge/core/features/form.gd")
const UTIL := preload("res://addons/holo_forge/core/features/util.gd")
const REFERENCES := preload("res://addons/holo_forge/core/references.gd")
const MESH_IMPORT := preload("res://addons/holo_forge/core/import/mesh_import.gd")
const UNITS := preload("res://addons/holo_forge/core/units.gd")
const MANIPULATOR := preload("res://addons/holo_forge/core/manipulator_math.gd")

## Screen distance (pixels) at which a click takes a control point or a snap.
const GRAB_PX := 9.0
const SNAP_PX := 6.0

const _MODE_SIMPLE_EXACT := [["simple", "Simple"], ["exact", "Exact"]]
const _CONTROL_SURFACE := [["control", "Control Points"], ["surface", "Surface Points"]]
## Typed scale factors (the same range as Edit Form's, form_tools.gd SCALE_RANGE).
const _SCALE_RANGE := [0.01, 1000.0]
const _CANDIDATES := [["0", "Best match"], ["1", "Second"], ["2", "Third"], ["3", "Fourth"], ["4", "Fifth"], ["5", "Sixth"]]

const TOOLS := {
	"edit_by_curve": {
		"title": "Edit By Curve", "uses_selection": true, "preview": true, "interact": true,
		"picks": [{"key": "edges", "label": "Edge chain", "kinds": ["edge"], "count": -1, "required": true}],
		"fields": [
			{"key": "degree", "label": "Degree", "type": "expression", "kind": "number", "range": [1, 7, true]},
			{"key": "distribution", "label": "Distribution", "type": "enum", "options": [["edge_length", "Edge Length"], ["uniform", "Uniform"]]},
			{"key": "planar", "label": "Planar", "type": "bool"},
			{"key": "fit", "label": "Curve Fit", "type": "enum", "options": _CONTROL_SURFACE},
			{"key": "hint", "type": "info", "text": "Drag the curve's square points (Shift adds to the picked points); the fields below move the picked points."},
			{"key": "x_distance", "label": "X Distance", "type": "expression", "kind": "length"},
			{"key": "y_distance", "label": "Y Distance", "type": "expression", "kind": "length"},
			{"key": "z_distance", "label": "Z Distance", "type": "expression", "kind": "length"},
			{"key": "x_angle", "label": "X Angle", "type": "expression", "kind": "angle"},
			{"key": "y_angle", "label": "Y Angle", "type": "expression", "kind": "angle"},
			{"key": "z_angle", "label": "Z Angle", "type": "expression", "kind": "angle"},
			{"key": "x_scale", "label": "X Scale", "type": "expression", "kind": "number", "range": _SCALE_RANGE},
			{"key": "y_scale", "label": "Y Scale", "type": "expression", "kind": "number", "range": _SCALE_RANGE},
			{"key": "z_scale", "label": "Z Scale", "type": "expression", "kind": "number", "range": _SCALE_RANGE},
			{"key": "xy_scale", "label": "XY Plane Scale", "type": "expression", "kind": "number", "range": _SCALE_RANGE},
			{"key": "yz_scale", "label": "YZ Plane Scale", "type": "expression", "kind": "number", "range": _SCALE_RANGE},
			{"key": "zx_scale", "label": "ZX Plane Scale", "type": "expression", "kind": "number", "range": _SCALE_RANGE},
			{"key": "reset_curve", "label": "Reset Curve", "type": "button", "tooltip": "Put the curve's points back where they started"},
		],
		"defaults": {"degree": "3", "distribution": "edge_length", "planar": false, "fit": "control", "x_distance": "0", "y_distance": "0",
			"z_distance": "0", "x_angle": "0 deg", "y_angle": "0 deg", "z_angle": "0 deg", "x_scale": "1", "y_scale": "1", "z_scale": "1",
			"xy_scale": "1", "yz_scale": "1", "zx_scale": "1", "curve_offsets": [], "curve_selected": []},
	},
	"insert_edge": {
		"title": "Insert Edge", "uses_selection": true, "preview": true, "handles": true,
		"picks": [{"key": "edges", "label": "Edges", "kinds": ["edge"], "count": -1, "required": true}],
		"fields": [
			{"key": "mode", "label": "Insertion Mode", "type": "enum", "options": _MODE_SIMPLE_EXACT},
			{"key": "location", "label": "Insert Location", "type": "expression", "kind": "number"},
			{"key": "side", "label": "Insert Side", "type": "enum", "options": [["single", "Single"], ["both", "Both"]]},
			{"key": "result", "type": "info", "text": "Drag the green knob along the rail, or type -1..1 (negative: the other side)."},
		],
		"defaults": {"mode": "simple", "location": "0.5", "side": "single"},
	},
	"subdivide": {
		"title": "Subdivide", "uses_selection": true, "preview": true,
		"picks": [{"key": "faces", "label": "Faces", "kinds": ["face"], "count": -1, "required": true}],
		"fields": [
			{"key": "mode", "label": "Insert Mode", "type": "enum", "options": _MODE_SIMPLE_EXACT},
			{"key": "specify", "label": "Specify", "type": "bool"},
			{"key": "u_faces", "label": "Length Faces", "type": "expression", "kind": "number", "visible_if": {"specify": [true]}, "range": [1, 16, true]},
			{"key": "v_faces", "label": "Width Faces", "type": "expression", "kind": "number", "visible_if": {"specify": [true]}, "range": [1, 16, true]},
			{"key": "result", "type": "info", "text": "Exact on every face of a body is one exact smoothing step."},
		],
		"defaults": {"mode": "simple", "specify": false, "u_faces": "2", "v_faces": "2"},
	},
	"insert_point": {
		"title": "Insert Point", "preview": true, "interact": true, "repeat": true,
		"picks": [],
		"fields": [
			{"key": "mode", "label": "Insertion Mode", "type": "enum", "options": _MODE_SIMPLE_EXACT},
			{"key": "result", "type": "info", "text": "Click on cage edges (midpoints and ends snap). Points on one face are joined; Enter, a double-click or OK applies."},
		],
		"defaults": {"mode": "simple", "points": [], "points_body": ""},
	},
	"merge_edge": {
		"title": "Merge Edge", "uses_selection": true, "preview": true, "interact": true,
		"picks": [{"key": "edges", "label": "Edge Group One", "kinds": ["edge"], "count": -1, "required": true}],
		"fields": [
			{"key": "edges2", "label": "Edge Group Two", "type": "selection", "cage": true, "kinds": ["edge"]},
			{"key": "keep_creases", "label": "Maintain Crease Edges", "type": "bool"},
		],
		"defaults": {"edges2": [], "keep_creases": true},
	},
	"bridge": {
		"title": "Bridge", "uses_selection": true, "preview": true, "interact": true,
		"picks": [{"key": "side1", "label": "Side One", "kinds": ["face", "edge"], "count": -1, "required": true}],
		"fields": [
			{"key": "side2", "label": "Side Two", "type": "selection", "cage": true, "kinds": ["face", "edge"]},
			{"key": "segments", "label": "Faces", "type": "expression", "kind": "number", "range": [1, 64, true]},
			{"key": "twist", "label": "Twist", "type": "expression", "kind": "number", "range": [-64, 64, true]},
			{"key": "follow", "label": "Follow Curve", "type": "selection", "filter": ["sketch_curve", "edge"]},
			{"key": "flip1", "label": "Flip Direction 1", "type": "bool"},
			{"key": "flip2", "label": "Flip Direction 2", "type": "bool"},
			{"key": "keep_creases", "label": "Maintain Crease Edges", "type": "bool"},
		],
		"defaults": {"side2": [], "segments": "1", "twist": "0", "follow": [], "flip1": false, "flip2": false, "keep_creases": true},
	},
	"fill_hole": {
		"title": "Fill Hole", "uses_selection": true, "preview": true,
		"picks": [{"key": "edge", "label": "Hole edge", "kinds": ["edge"], "count": 1, "required": true}],
		"fields": [
			{"key": "mode", "label": "Fill Mode", "type": "enum", "options": [["reduced", "Reduced Star"], ["star", "Fill Star"], ["collapse", "Collapse"]]},
			{"key": "keep_creases", "label": "Keep Creases", "type": "bool"},
		],
		"defaults": {"mode": "reduced", "keep_creases": true},
	},
	"erase_and_fill": {
		"title": "Erase and Fill", "uses_selection": true, "preview": true,
		"picks": [{"key": "faces", "label": "Faces", "kinds": ["face"], "count": -1, "required": true}],
		"fields": [
			{"key": "mode", "label": "Fill Mode", "type": "enum", "options": [["reduced", "Reduced Star"], ["star", "Fill Star"]]},
			{"key": "feature", "label": "Feature (Alt+H)", "type": "button", "tooltip": "Grow the picked faces to the band or hole they belong to"},
		],
		"defaults": {"mode": "reduced"},
	},
	"weld_vertices": {
		"title": "Weld Vertices", "uses_selection": true, "preview": true, "interact": true, "repeat": true, "select_through": true,
		"picks": [{"key": "vertices", "label": "Vertices", "kinds": ["vertex"], "count": -1, "required": true}],
		"fields": [
			{"key": "mode", "label": "Weld Mode", "type": "enum", "options": [["vertex", "Vertex to Vertex"], ["midpoint", "Vertex to Midpoint"], ["tolerance", "Weld to Tolerance"]]},
			{"key": "tolerance", "label": "Weld Tolerance", "type": "expression", "kind": "length", "visible_if": {"mode": ["tolerance"]}},
			{"key": "keep_creases", "label": "Maintain Crease Edges", "type": "bool"},
			{"key": "result", "type": "info", "text": "Click the vertex that moves, then the one it welds to."},
		],
		"defaults": {"mode": "vertex", "tolerance": "0", "keep_creases": true},
	},
	"unweld_edges": {
		"title": "UnWeld Edges", "uses_selection": true, "preview": true,
		"picks": [{"key": "edges", "label": "Edges", "kinds": ["edge"], "count": -1, "required": true}],
		"fields": [{"key": "result", "type": "info", "text": "Double-click an edge to take its whole loop."}],
		"defaults": {},
	},
	"bevel_edge": {
		"title": "Bevel Edge", "uses_selection": true, "preview": true,
		"picks": [{"key": "edges", "label": "Edges", "kinds": ["edge"], "count": -1, "required": true}],
		"fields": [
			{"key": "distance_mode", "label": "Distance Mode", "type": "enum", "options": [["ratio", "Ratio"], ["width", "Width"]]},
			{"key": "ratio", "label": "Ratio", "type": "expression", "kind": "number", "visible_if": {"distance_mode": ["ratio"]}, "range": [0.01, 0.99, false]},
			{"key": "width", "label": "Width", "type": "expression", "kind": "length", "visible_if": {"distance_mode": ["width"]}},
			{"key": "segments", "label": "Segments", "type": "expression", "kind": "number", "range": [1, 16, true]},
			{"key": "spacing", "label": "Spacing", "type": "enum", "options": [["uniform", "Uniform"], ["parametric", "Parametric"]]},
			{"key": "crown", "label": "Crown", "type": "expression", "kind": "number", "range": [0, 2, false]},
		],
		"defaults": {"distance_mode": "ratio", "ratio": "0.25", "width": "0", "segments": "1", "spacing": "uniform", "crown": "1"},
	},
	"slide_edge": {
		"title": "Slide Edge", "uses_selection": true, "preview": true, "handles": true,
		"picks": [{"key": "edges", "label": "Edges", "kinds": ["edge"], "count": -1, "required": true}],
		"fields": [{"key": "slide", "label": "Slide", "type": "expression", "kind": "number", "range": [-1, 1, false]}],
		"defaults": {"slide": "0"},
	},
	"smooth": {
		"title": "Smooth", "uses_selection": true, "preview": true, "handles": true,
		"picks": [{"key": "faces", "label": "Faces", "kinds": ["face"], "count": -1, "required": true}],
		"fields": [{"key": "amount", "label": "Amount", "type": "expression", "kind": "number", "range": [0, 1, false]}],
		"defaults": {"amount": "0.5"},
	},
	"cylindrify": {
		"title": "Cylindrify", "uses_selection": true, "preview": true,
		"picks": [{"key": "faces", "label": "Faces", "kinds": ["face"], "count": -1, "required": true}],
		"fields": [{"key": "auto_feature", "label": "Auto Feature Selection", "type": "bool"}],
		"defaults": {"auto_feature": true},
	},
	"pull": {
		"title": "Pull", "uses_selection": true, "preview": true, "native": true, "interact": true,
		"picks": [{"key": "vertices", "label": "Vertices", "kinds": ["vertex", "edge", "face", "body"], "count": -1, "required": true}],
		"fields": [
			{"key": "target", "label": "Target", "type": "enum", "options": [["auto", "Auto"], ["select", "Select"]]},
			{"key": "target_bodies", "label": "Target Bodies", "type": "selection", "filter": "body", "visible_if": {"target": ["select"]}},
			{"key": "type", "label": "Pull Type", "type": "enum", "options": _CONTROL_SURFACE},
			{"key": "result", "type": "info", "text": "Auto pulls onto every model body."},
		],
		"defaults": {"target": "auto", "target_bodies": [], "type": "control"},
	},
	"flatten": {
		"title": "Flatten", "uses_selection": true, "preview": true, "interact": true,
		"picks": [{"key": "vertices", "label": "Vertices", "kinds": ["vertex", "edge", "face", "body"], "count": -1, "required": true}],
		"fields": [
			{"key": "direction", "label": "Direction", "type": "enum", "options": [["fit", "Fit"], ["plane", "Select Plane"], ["parallel", "Select Parallel Plane"]]},
			{"key": "plane", "label": "Plane", "type": "selection", "filter": ["plane", "face"], "single": true, "visible_if": {"direction": ["plane", "parallel"]}},
			{"key": "type", "label": "Flatten Type", "type": "enum", "options": _CONTROL_SURFACE},
		],
		"defaults": {"direction": "fit", "plane": [], "type": "control"},
	},
	"straighten": {
		"title": "Straighten", "uses_selection": true, "preview": true, "interact": true,
		"picks": [{"key": "vertices", "label": "Vertices", "kinds": ["vertex", "edge"], "count": -1, "required": true}],
		"fields": [
			{"key": "direction", "label": "Direction", "type": "enum", "options": [["fit", "Fit"], ["line", "Select Line"], ["parallel", "Select Parallel Line"], ["two_points", "Two Points"]]},
			{"key": "line", "label": "Line", "type": "selection", "filter": ["axis", "edge"], "single": true, "visible_if": {"direction": ["line", "parallel"]}},
			{"key": "points", "label": "Points", "type": "selection", "filter": ["point"], "visible_if": {"direction": ["two_points"]}},
			{"key": "type", "label": "Straighten Type", "type": "enum", "options": _CONTROL_SURFACE},
			{"key": "range", "label": "Range", "type": "button", "tooltip": "Add the vertices between the first and the last picked one"},
		],
		"defaults": {"direction": "fit", "line": [], "points": [], "type": "control"},
	},
	"match": {
		"title": "Match", "uses_selection": true, "preview": true, "native": true, "interact": true,
		"picks": [{"key": "edges", "label": "Form edges", "kinds": ["edge"], "count": -1, "required": true}],
		"fields": [
			{"key": "target", "label": "Match Edges", "type": "selection", "filter": ["sketch_curve", "edge"]},
			{"key": "continuity", "label": "Continuity", "type": "enum", "options": [["g0", "G0"], ["g1", "G1"], ["g2", "G2"]]},
			{"key": "spacing", "label": "Spacing", "type": "enum", "options": [["uniform", "Uniform"], ["curvature", "Curvature"]]},
			{"key": "falloff", "label": "Falloff Rows", "type": "expression", "kind": "number", "range": [0, 3, true]},
			{"key": "associative", "label": "Associative", "type": "bool"},
			{"key": "alternate", "label": "Alternate Alignment", "type": "button", "tooltip": "Run the match the other way along the curve"},
			{"key": "result", "type": "info", "text": "G1 and G2 need model edges with a face beside them."},
		],
		"defaults": {"target": [], "continuity": "g0", "spacing": "uniform", "falloff": "1", "associative": false, "reverse": false},
	},
	"interpolate": {
		"title": "Interpolate", "uses_selection": true, "preview": true, "native": true,
		"picks": [{"key": "elements", "label": "Bodies or vertices", "kinds": ["vertex", "body"], "count": -1, "required": false}],
		"fields": [
			{"key": "mode", "label": "Mode", "type": "enum", "options": [["through", "Through Cage Points"], ["onto", "Cage Onto Surface"]]},
			{"key": "result", "type": "info", "text": "Nothing picked: every body of the form."},
		],
		"defaults": {"mode": "through"},
	},
	"thicken": {
		"title": "Thicken", "uses_selection": true, "preview": true, "interact": true,
		"picks": [{"key": "elements", "label": "Body or faces", "kinds": ["body", "face"], "count": -1, "required": true}],
		"fields": [
			{"key": "thickness", "label": "Thickness", "type": "expression", "kind": "length"},
			{"key": "type", "label": "Type", "type": "enum", "options": [["sharp", "Sharp"], ["soft", "Soft"], ["none", "No Edge"]]},
			{"key": "direction", "label": "Direction", "type": "enum", "options": [["normal", "Normal"], ["axis", "Axis"]]},
			{"key": "axis", "label": "Axis", "type": "selection", "filter": ["axis", "edge"], "single": true, "visible_if": {"direction": ["axis"]}},
			{"key": "flip", "label": "Flip", "type": "bool"},
		],
		"defaults": {"thickness": "0", "type": "sharp", "direction": "normal", "axis": [], "flip": false},
	},
	"mirror_internal": {
		"title": "Mirror - Internal", "uses_selection": true, "preview": true, "interact": true,
		"picks": [{"key": "faces", "label": "Face 1 and Face 2", "kinds": ["face"], "count": 2, "required": true}],
		"fields": [
			{"key": "candidate", "label": "Possible Symmetries", "type": "enum", "options": _CANDIDATES},
			{"key": "candidates", "type": "info", "text": "Click a face on each side of the symmetry."},
			{"key": "tolerance", "label": "Tolerance", "type": "expression", "kind": "length"},
			{"key": "snap", "label": "Snap Exactly", "type": "bool"},
		],
		"defaults": {"candidate": "0", "tolerance": "0", "snap": true},
	},
	"circular_internal": {
		"title": "Circular - Internal", "uses_selection": true, "preview": true, "interact": true,
		"picks": [{"key": "faces", "label": "Face", "kinds": ["face"], "count": 2, "required": true}],
		"fields": [
			{"key": "candidate", "label": "Possible Symmetries", "type": "enum", "options": _CANDIDATES},
			{"key": "candidates", "type": "info", "text": "Click a face of the body."},
			{"key": "tolerance", "label": "Tolerance", "type": "expression", "kind": "length"},
			{"key": "snap", "label": "Snap Exactly", "type": "bool"},
		],
		"defaults": {"candidate": "0", "tolerance": "0", "snap": true},
	},
	"mirror_duplicate": {
		"title": "Mirror - Duplicate", "uses_selection": true, "preview": true, "interact": true,
		"picks": [{"key": "bodies", "label": "Body", "kinds": ["body"], "count": -1, "required": true}],
		"fields": [
			{"key": "plane", "label": "Mirror Plane", "type": "selection", "filter": ["plane", "face"], "single": true},
			{"key": "weld", "label": "Weld", "type": "bool"},
			{"key": "tolerance", "label": "Weld Tolerance", "type": "expression", "kind": "length", "visible_if": {"weld": [true]}},
		],
		"defaults": {"plane": [], "weld": true, "tolerance": "0"},
	},
	"circular_duplicate": {
		"title": "Circular - Duplicate", "uses_selection": true, "preview": true, "interact": true,
		"picks": [{"key": "bodies", "label": "Body", "kinds": ["body"], "count": -1, "required": true}],
		"fields": [
			{"key": "axis", "label": "Axis", "type": "selection", "filter": ["axis", "edge"], "single": true},
			{"key": "quantity", "label": "Quantity", "type": "expression", "kind": "number", "range": [2, 64, true]},
			{"key": "spacing", "label": "Angular Spacing", "type": "enum", "options": [["full", "Full"], ["angle", "Angle"]]},
			{"key": "angle", "label": "Total Angle", "type": "expression", "kind": "angle", "visible_if": {"spacing": ["angle"]}},
			{"key": "weld", "label": "Weld", "type": "bool"},
			{"key": "tolerance", "label": "Weld Tolerance", "type": "expression", "kind": "length", "visible_if": {"weld": [true]}},
		],
		"defaults": {"axis": [], "quantity": "4", "spacing": "full", "angle": "180 deg", "weld": true, "tolerance": "0"},
	},
	"isolate_symmetry": {
		"title": "Isolate Symmetry", "uses_selection": true, "preview": true,
		"picks": [{"key": "elements", "label": "Cage", "kinds": ["face", "edge", "vertex"], "count": -1, "required": true}],
		"fields": [{"key": "mode", "label": "Mode", "type": "enum", "options": [["isolate", "Isolate"], ["restore", "Restore"]]}],
		"defaults": {"mode": "isolate"},
	},
	"repair_body": {
		"title": "Repair Body", "uses_selection": true, "preview": true, "interact": true,
		"picks": [{"key": "bodies", "label": "Body", "kinds": ["body"], "count": -1, "required": false}],
		"fields": [
			{"key": "mode", "label": "Mode", "type": "enum", "options": [["fix", "Fix"], ["report", "Report"]]},
			{"key": "tolerance", "label": "Weld Tolerance", "type": "expression", "kind": "length"},
			{"key": "merge_triangles", "label": "Merge Triangles into Quads", "type": "bool"},
			{"key": "result", "type": "info", "text": "Nothing picked: every body of the form."},
		],
		"defaults": {"mode": "fix", "tolerance": "0", "merge_triangles": false},
	},
	"make_uniform": {
		"title": "Make Uniform", "uses_selection": true, "preview": true,
		"picks": [{"key": "bodies", "label": "Body", "kinds": ["body"], "count": -1, "required": false}],
		"fields": [
			{"key": "quads_only", "label": "Quads Only", "type": "bool"},
			{"key": "even", "label": "Even Spacing", "type": "bool"},
			{"key": "iterations", "label": "Iterations", "type": "expression", "kind": "number", "visible_if": {"even": [true]}, "range": [1, 20, true]},
			{"key": "result", "type": "info", "text": "Nothing picked: every body of the form."},
		],
		"defaults": {"quads_only": true, "even": false, "iterations": "5"},
	},
	"convert": {
		"title": "Convert", "uses_selection": true, "preview": false, "native": true, "interact": true,
		"picks": [{"key": "bodies", "label": "Form bodies", "kinds": ["body"], "count": -1, "required": false}],
		"fields": [
			{"key": "direction", "label": "Direction", "type": "enum", "options": [["form_brep", "Form to BRep"], ["mesh_form", "Mesh to Form"], ["face_form", "Face to Form"]]},
			{"key": "mesh_body", "label": "Mesh Body", "type": "selection", "filter": "body", "single": true, "visible_if": {"direction": ["mesh_form"]}},
			{"key": "merge", "label": "Merge Triangles to Quads", "type": "bool", "visible_if": {"direction": ["mesh_form"]}},
			{"key": "weld_tolerance", "label": "Weld Tolerance", "type": "expression", "kind": "length", "visible_if": {"direction": ["mesh_form"]}},
			{"key": "faces", "label": "Faces", "type": "selection", "filter": ["face"], "visible_if": {"direction": ["face_form"]}},
			{"key": "grid_u", "label": "Grid U", "type": "expression", "kind": "number", "visible_if": {"direction": ["face_form"]}},
			{"key": "grid_v", "label": "Grid V", "type": "expression", "kind": "number", "visible_if": {"direction": ["face_form"]}},
			{"key": "fit", "label": "Fit", "type": "bool", "visible_if": {"direction": ["face_form"]}},
			{"key": "result", "type": "info", "text": "Form to BRep fixes the picked bodies as exact geometry (no cage)."},
		],
		"defaults": {"direction": "form_brep", "mesh_body": [], "merge": true, "weld_tolerance": "0", "faces": [], "grid_u": "0", "grid_v": "0", "fit": true},
	},
}


# --- Shared helpers --------------------------------------------------------------------------------

static func failure(message: String) -> Dictionary:
	return {"ok": false, "error": message, "warnings": PackedStringArray(), "cages": {}, "new_bodies": [], "removed_bodies": [],
		"breps": {}, "display": {}, "selection": [], "info": {}}


## Cage selection items grouped by body: {body id: {"vertices", "edges" (pairs), "faces", "body"}}.
static func by_body(items: Array) -> Dictionary:
	var out := {}
	for item in items:
		if not item is Dictionary or not (item as Dictionary).has("body"):
			continue
		var body := str(item.body)
		if not out.has(body):
			out[body] = {"vertices": PackedInt32Array(), "edges": PackedInt32Array(), "faces": PackedInt32Array(), "body": false}
		var sel: Dictionary = out[body]
		match str(item.get("kind", "")):
			"vertex":
				var v: PackedInt32Array = sel.vertices
				v.append(int(item.index))
				sel.vertices = v
			"edge":
				var pair: Vector2i = item.get("pair", Vector2i(-1, -1))
				var e: PackedInt32Array = sel.edges
				e.append(mini(pair.x, pair.y))
				e.append(maxi(pair.x, pair.y))
				sel.edges = e
			"face":
				var f: PackedInt32Array = sel.faces
				f.append(int(item.index))
				sel.faces = f
			"body":
				sel.body = true
	return out


## The bodies a pick list names; every cage body when it names none.
static func picked_bodies(items: Array, cages: Dictionary) -> Array:
	var bodies := []
	for item in items:
		if item is Dictionary and cages.has(str(item.get("body", ""))) and not bodies.has(str(item.body)):
			bodies.append(str(item.body))
	return bodies if not bodies.is_empty() else cages.keys()


## Editor selection items for a form_ops selection of one body.
static func items_of(body: String, sel: Dictionary) -> Array:
	var out := []
	for v in FORM_OPS._list(sel, "vertices"):
		out.append({"kind": "vertex", "body": body, "index": v, "pair": Vector2i(-1, -1)})
	var pairs := FORM_OPS._list(sel, "edges")
	for i in pairs.size() / 2:
		out.append({"kind": "edge", "body": body, "index": -1, "pair": Vector2i(pairs[2 * i], pairs[2 * i + 1])})
	for f in FORM_OPS._list(sel, "faces"):
		out.append({"kind": "face", "body": body, "index": f, "pair": Vector2i(-1, -1)})
	return out


## values[key] as an Array (selection fields).
static func list_value(values: Dictionary, key: String) -> Array:
	var v: Variant = values.get(key, [])
	if v is Array:
		return v
	if v == null:
		return []
	return [v]


## A rebuild-like context for core/references.gd from a tool context.
static func refs_ctx(ctx: Dictionary) -> Dictionary:
	var result: Dictionary = ctx.get("result", {})
	return {"kernel": ctx.get("kernel"), "doc": ctx.get("doc"), "bodies": result.get("bodies", {}), "sketches": result.get("sketches", {}),
		"construction": result.get("construction", {}), "values": result.get("values", {})}


static func _units(ctx: Dictionary) -> String:
	var doc: Resource = ctx.get("doc")
	return str(doc.units) if doc != null else "mm"


static func _length(ctx: Dictionary, meters: float) -> String:
	return UNITS.format_value(meters, UNITS.KIND_LENGTH, _units(ctx))


## Text for an info field of the tool's panel: the registry hands it back in the result's
## info.panel, which the editor shows (also when the tool can't run).
static func _info(ctx: Dictionary, key: String, text: String) -> void:
	var panel: Variant = ctx.get("panel")
	if not panel is Dictionary:
		panel = {}
		ctx["panel"] = panel
	(panel as Dictionary)[key] = text


## A length field's value, or auto when it is 0 (or missing); with an editor the field then shows
## the automatic value once (deferred, so the preview isn't re-entered).
static func _auto_length(ctx: Dictionary, values: Dictionary, key: String, auto: float) -> float:
	var v := float(values.get(key, 0.0))
	if v > 0.0:
		return v
	var editor: Object = ctx.get("editor")
	if editor != null and is_instance_valid(editor) and auto > 0.0:
		var state: Dictionary = editor.tool_state
		var flag := "auto_" + key
		if not state.has(flag):
			state[flag] = true
			var tool_id := str(editor.tool)
			var text := _length(ctx, auto)
			(func() -> void:
				if is_instance_valid(editor) and str(editor.tool) == tool_id:
					editor.set_tool_values({key: text})).call_deferred()
	return auto


## The body's mean edge length, 0 for an empty cage.
static func _mean_edge(cage: Dictionary) -> float:
	return CAGE.mean_edge_length(cage) if CAGE.face_count(cage) > 0 else 0.0


## Runs op(cage, sel, body) for every body the items touch. Bodies where nothing changes are left
## out; the tool fails with "Nothing to change" when no body changes. Selections come back as
## editor items; the last body's info wins (info.bodies counts the changed ones).
static func _each_body(ctx: Dictionary, items: Array, op: Callable, empty_message: String) -> Dictionary:
	var cages: Dictionary = ctx.get("cages", {})
	var groups := by_body(items)
	if groups.is_empty():
		return failure(empty_message)
	var out := {"ok": true, "cages": {}, "warnings": PackedStringArray(), "info": {}, "selection": []}
	var nothing := false
	for body in groups:
		if not cages.has(body):
			continue
		var r: Dictionary = op.call(cages[body], groups[body], str(body))
		if not bool(r.get("ok", false)):
			if str(r.get("error", "")) == FORM_OPS.NOTHING:
				nothing = true
				continue
			return failure(str(r.get("error", "")))
		out.cages[body] = r.cage
		var warnings: PackedStringArray = out.warnings
		warnings.append_array(r.get("warnings", PackedStringArray()))
		out.warnings = warnings
		out.info = (r.get("info", {}) as Dictionary).duplicate()
		(out.selection as Array).append_array(items_of(str(body), r.get("selection", {})))
	if (out.cages as Dictionary).is_empty():
		return failure(FORM_OPS.NOTHING if nothing else empty_message)
	out.info["bodies"] = (out.cages as Dictionary).size()
	return out


## Two bodies' cages as one (the second appended to the first): {"cage", "voff", "foff"}; the same
## cage with zero offsets when they are one body.
static func _join(cages: Dictionary, base: String, other: String) -> Dictionary:
	if base == other:
		return {"cage": cages[base], "voff": 0, "foff": 0}
	var a: Dictionary = cages[base]
	var r := CAGE.append(a, cages[other])
	return {"cage": r.cage, "voff": int(r.offset), "foff": CAGE.face_count(a)}


static func _shift(list: PackedInt32Array, by: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	for x in list:
		out.append(x + by)
	return out


## A plane from a selection value: {"origin", "normal"} or {"error"}.
static func _plane_of(ctx: Dictionary, values: Dictionary, key: String) -> Dictionary:
	var list := list_value(values, key)
	if list.is_empty():
		return {"error": "Pick a plane or a flat face."}
	var ref: Variant = list[0]
	if ref is Dictionary and (ref as Dictionary).has("normal") and not (ref as Dictionary).has("kind"):
		return ref
	if not ref is Dictionary:
		return {"error": "Pick a plane or a flat face."}
	return REFERENCES.plane(ref, refs_ctx(ctx))


## An axis or line from a selection value: {"origin", "direction"} or {"error"}.
static func _axis_of(ctx: Dictionary, values: Dictionary, key: String) -> Dictionary:
	var list := list_value(values, key)
	if list.is_empty():
		return {"error": "Pick an axis, a straight line or edge."}
	var ref: Variant = list[0]
	if ref is Dictionary and (ref as Dictionary).has("direction") and not (ref as Dictionary).has("kind"):
		return ref
	if not ref is Dictionary:
		return {"error": "Pick an axis, a straight line or edge."}
	return REFERENCES.axis(ref, refs_ctx(ctx))


## A point from a selection value (a Vector3, or a point reference).
static func _point_of(ctx: Dictionary, ref: Variant) -> Dictionary:
	if ref is Vector3:
		return {"point": ref}
	if ref is Dictionary:
		return REFERENCES.point(ref, refs_ctx(ctx))
	return {"error": "Pick a point."}


static func _deviation_text(ctx: Dictionary, info: Dictionary) -> String:
	if not info.has("max_deviation"):
		return ""
	return "Max deviation %s (%.2f%% of an edge)" % [_length(ctx, float(info.max_deviation)), 100.0 * float(info.get("relative_deviation", 0.0))]


## The tool's spec field by key ({} when none).
static func _field(id: String, key: String) -> Dictionary:
	var spec: Dictionary = TOOLS.get(id, {})
	for f in spec.get("fields", []):
		if str((f as Dictionary).get("key", "")) == key:
			return f
	return {}


# --- Modify ----------------------------------------------------------------------------------------

static func run_insert_edge(ctx: Dictionary, picks: Dictionary, values: Dictionary) -> Dictionary:
	var opts := {"location": float(values.get("location", 0.5)), "side": str(values.get("side", "single")), "mode": str(values.get("mode", "simple"))}
	var r := _each_body(ctx, picks.get("edges", []), func(cage: Dictionary, sel: Dictionary, _body: String) -> Dictionary:
		return FORM_FIT.insert_edge(cage, sel, opts), "Pick edges to insert next to.")
	if r.ok:
		_info(ctx, "result", _deviation_text(ctx, r.info) if opts.mode == "exact" else "New edges: %d" % (r.selection as Array).size())
	return r


static func run_subdivide(ctx: Dictionary, picks: Dictionary, values: Dictionary) -> Dictionary:
	var opts := {"mode": str(values.get("mode", "simple")), "u_faces": 2, "v_faces": 2}
	if bool(values.get("specify", false)):
		opts.u_faces = clampi(roundi(float(values.get("u_faces", 2))), 1, 16)
		opts.v_faces = clampi(roundi(float(values.get("v_faces", 2))), 1, 16)
		if opts.u_faces == 1 and opts.v_faces == 1:
			# 1 x 1 splits nothing: no empty undo step.
			return failure(FORM_OPS.NOTHING)
	var r := _each_body(ctx, picks.get("faces", []), func(cage: Dictionary, sel: Dictionary, _body: String) -> Dictionary:
		return FORM_FIT.subdivide(cage, sel, opts), "Pick faces to subdivide.")
	if r.ok and opts.mode == "exact":
		_info(ctx, "result", "Exact smoothing step: the surface is unchanged" if bool(r.info.get("catmull_clark", false)) else _deviation_text(ctx, r.info))
	return r


## Insert Point: values.points (the clicks, in order: {"edge": Vector2i(a, b), "t"} or {"vertex": v})
## on values.points_body.
static func run_insert_point(ctx: Dictionary, _picks: Dictionary, values: Dictionary) -> Dictionary:
	var points := list_value(values, "points")
	var body := str(values.get("points_body", ""))
	var cages: Dictionary = ctx.get("cages", {})
	if points.is_empty() or not cages.has(body):
		return failure("Click points on cage edges.")
	var opts := {"points": points, "mode": str(values.get("mode", "simple"))}
	var r := FORM_FIT.insert_point(cages[body], {}, opts)
	if not r.ok:
		return failure(r.error)
	if opts.mode == "exact":
		_info(ctx, "result", _deviation_text(ctx, r.info))
	return {"ok": true, "cages": {body: r.cage}, "warnings": r.warnings, "info": r.info, "selection": items_of(body, r.selection)}


## Merge Edge: group one (picks.edges) moves onto group two (values.edges2) and welds to it; group
## one's body joins group two's.
static func run_merge_edge(ctx: Dictionary, picks: Dictionary, values: Dictionary) -> Dictionary:
	var cages: Dictionary = ctx.get("cages", {})
	var g1 := by_body(picks.get("edges", []))
	var g2 := by_body(list_value(values, "edges2"))
	if g1.is_empty():
		return failure("Pick the open edges of group one.")
	if g2.is_empty():
		return failure("Pick Edge Group Two in the panel, then its edges.")
	if g1.size() != 1 or g2.size() != 1:
		return failure("Each group must be on one body.")
	var b1 := str(g1.keys()[0])
	var b2 := str(g2.keys()[0])
	if not cages.has(b1) or not cages.has(b2):
		return failure("Pick edges of the open form.")
	var joined := _join(cages, b2, b1)
	var sel := {"edges": _shift(g1[b1].edges, int(joined.voff)), "edges2": g2[b2].edges}
	var r := FORM_OPS.merge_edge(joined.cage, sel, {"keep_creases": bool(values.get("keep_creases", true))})
	if not r.ok:
		return failure(r.error)
	var out := {"ok": true, "cages": {b2: r.cage}, "warnings": r.warnings, "info": r.info}
	if b1 != b2:
		out["removed_bodies"] = [b1]
	return out


## Bridge: side one (picks.side1) and side two (values.side2), faces or open edges, on one body or
## two (the second joins the first).
static func run_bridge(ctx: Dictionary, picks: Dictionary, values: Dictionary) -> Dictionary:
	var cages: Dictionary = ctx.get("cages", {})
	var g1 := by_body(picks.get("side1", []))
	var g2 := by_body(list_value(values, "side2"))
	if g1.is_empty():
		return failure("Pick side one: faces or open edges.")
	if g2.is_empty():
		return failure("Pick Side Two in the panel, then its faces or open edges.")
	if g1.size() != 1 or g2.size() != 1:
		return failure("Each side must be on one body.")
	var b1 := str(g1.keys()[0])
	var b2 := str(g2.keys()[0])
	if not cages.has(b1) or not cages.has(b2):
		return failure("Pick sides on the open form.")
	var joined := _join(cages, b1, b2)
	var s1: Dictionary = g1[b1]
	var s2: Dictionary = g2[b2]
	var sel := {"faces": s1.faces, "edges": s1.edges, "faces2": _shift(s2.faces, int(joined.foff)), "edges2": _shift(s2.edges, int(joined.voff))}
	var opts := {"segments": clampi(roundi(float(values.get("segments", 1))), 1, 64), "twist": roundi(float(values.get("twist", 0))),
		"flip1": bool(values.get("flip1", false)), "flip2": bool(values.get("flip2", false)), "keep_creases": bool(values.get("keep_creases", true))}
	var r := FORM_OPS.bridge(joined.cage, sel, opts)
	if not r.ok:
		return failure(r.error)
	var cage: Dictionary = r.cage
	var warnings: PackedStringArray = r.warnings
	var follow := list_value(values, "follow")
	if not follow.is_empty() and int(opts.segments) > 1:
		var line := FORM_FIT.target_polyline(follow, refs_ctx(ctx))
		if str(line.get("error", "")) != "":
			return failure("Follow Curve: %s" % line.error)
		var topo := CAGE.topology(joined.cage)
		var l1 := FORM_OPS._side_loop(topo, sel.faces, sel.edges)
		var l2 := FORM_OPS._side_loop(topo, sel.faces2, sel.edges2)
		var a: PackedInt32Array = l1.get("loop", PackedInt32Array())
		var b: PackedInt32Array = l2.get("loop", PackedInt32Array())
		var dense := a if a.size() >= b.size() else b
		var fr := follow_curve(cage, (r.info as Dictionary).get("new_vertices", PackedInt32Array()), maxi(a.size(), b.size()),
			int(opts.segments), CAGE._centroid((joined.cage as Dictionary).positions, dense), CAGE._centroid((joined.cage as Dictionary).positions, a if dense == b else b), line.points)
		if fr.has("error"):
			warnings.append(str(fr.error))
		else:
			cage = fr.cage
	var out := {"ok": true, "cages": {b1: cage}, "warnings": warnings, "info": r.info, "selection": items_of(b1, r.selection)}
	if b1 != b2:
		out["removed_bodies"] = [b2]
	return out


## Bridge's Follow Curve: the bridge's inner rings (new_vertices: seg - 1 rings of ring_size
## vertices each, from the denser side; dense_centre / other_centre are the two sides' centres)
## move so their centres lie on the curve, at equal steps from the curve's end nearer the dense
## side. Each ring keeps its shape around its centre, turned by the rotation from the bridge's own
## direction there to the curve's (a rotation-minimizing step from ring to ring).
static func follow_curve(c: Dictionary, new_vertices: PackedInt32Array, ring_size: int, seg: int, dense_centre: Vector3, other_centre: Vector3, curve: PackedFloat64Array) -> Dictionary:
	if seg < 2 or ring_size < 2 or curve.size() < 6 or new_vertices.size() < (seg - 1) * ring_size:
		return {"error": "Follow Curve needs a bridge with more than one face along it"}
	var n := curve.size() / 3
	var start := Vector3(curve[0], curve[1], curve[2])
	var end := Vector3(curve[3 * (n - 1)], curve[3 * (n - 1) + 1], curve[3 * (n - 1) + 2])
	var line := curve
	if start.distance_to(dense_centre) + end.distance_to(other_centre) > end.distance_to(dense_centre) + start.distance_to(other_centre):
		line = PackedFloat64Array()
		for i in range(n - 1, -1, -1):
			line.append_array(PackedFloat64Array([curve[3 * i], curve[3 * i + 1], curve[3 * i + 2]]))
	var samples := FORM_FIT.resample(line, 2 * seg + 1, false)
	var p: PackedFloat64Array = c.positions
	var centres: Array = [dense_centre]
	var rings: Array = []
	for r in seg - 1:
		var ring := new_vertices.slice(r * ring_size, (r + 1) * ring_size)
		rings.append(ring)
		centres.append(CAGE._centroid(p, ring))
	centres.append(other_centre)
	var out := CAGE.copy(c)
	var np: PackedFloat64Array = (out.positions as PackedFloat64Array).duplicate()
	for r in seg - 1:
		var ring: PackedInt32Array = rings[r]
		var centre: Vector3 = centres[r + 1]
		var own := ((centres[r + 2] as Vector3) - (centres[r] as Vector3)).normalized()
		var j := 2 * (r + 1)
		var q := Vector3(samples[3 * j], samples[3 * j + 1], samples[3 * j + 2])
		var ahead := Vector3(samples[3 * (j + 1)], samples[3 * (j + 1) + 1], samples[3 * (j + 1) + 2])
		var behind := Vector3(samples[3 * (j - 1)], samples[3 * (j - 1) + 1], samples[3 * (j - 1) + 2])
		var along := (ahead - behind).normalized()
		var turn := Basis.IDENTITY
		var axis := own.cross(along)
		if axis.length() > 1e-9 and own.length() > 0.5 and along.length() > 0.5:
			turn = Basis(axis.normalized(), own.angle_to(along))
		for v in ring:
			var w := q + turn * (CAGE.position(c, v) - centre)
			np[3 * v] = w.x
			np[3 * v + 1] = w.y
			np[3 * v + 2] = w.z
	out.positions = np
	return {"cage": out}


static func run_fill_hole(ctx: Dictionary, picks: Dictionary, values: Dictionary) -> Dictionary:
	var opts := {"mode": str(values.get("mode", "reduced")), "keep_creases": bool(values.get("keep_creases", true))}
	return _each_body(ctx, picks.get("edge", []), func(cage: Dictionary, sel: Dictionary, _body: String) -> Dictionary:
		return FORM_OPS.fill_hole(cage, sel, opts), "Pick an open boundary edge of the hole.")


static func run_erase_and_fill(ctx: Dictionary, picks: Dictionary, values: Dictionary) -> Dictionary:
	var opts := {"mode": str(values.get("mode", "reduced"))}
	return _each_body(ctx, picks.get("faces", []), func(cage: Dictionary, sel: Dictionary, _body: String) -> Dictionary:
		return FORM_OPS.erase_and_fill(cage, sel, opts), "Pick faces to erase.")


## Weld Vertices: two vertices (the first moves onto the second, or both to the middle; on one body
## or two, which become one) or Weld to Tolerance (the picked vertices, or every vertex of the
## form's bodies when none is picked).
static func run_weld_vertices(ctx: Dictionary, picks: Dictionary, values: Dictionary) -> Dictionary:
	var cages: Dictionary = ctx.get("cages", {})
	var mode := str(values.get("mode", "vertex"))
	var items: Array = picks.get("vertices", [])
	var keep := bool(values.get("keep_creases", true))
	if mode == "tolerance":
		var bodies := picked_bodies(items, cages)
		var groups := by_body(items)
		var out := {"ok": true, "cages": {}, "warnings": PackedStringArray(), "info": {"welded": 0}}
		for body in bodies:
			var cage: Dictionary = cages[body]
			var tol := _auto_length(ctx, values, "tolerance", 0.01 * _mean_edge(cage))
			var sel: Dictionary = groups.get(body, {})
			var r := FORM_OPS.weld_vertices(cage, sel, {"mode": "tolerance", "tolerance": tol, "keep_creases": keep})
			if r.ok:
				out.cages[body] = r.cage
				out.info.welded = int(out.info.welded) + int(r.info.get("welded", 0))
				out.warnings.append_array(r.warnings)
		if (out.cages as Dictionary).is_empty():
			return failure("No vertices lie within the weld tolerance.")
		_info(ctx, "result", "Welds: %d" % int(out.info.welded))
		return out
	if items.size() < 2:
		return failure("Pick two vertices: the one that moves, then the one it welds to.")
	var first: Dictionary = items[items.size() - 2]
	var second: Dictionary = items[items.size() - 1]
	if str(first.get("kind", "")) != "vertex" or str(second.get("kind", "")) != "vertex":
		return failure("Pick two vertices.")
	var b1 := str(first.body)
	var b2 := str(second.body)
	if not cages.has(b1) or not cages.has(b2):
		return failure("Pick vertices of the open form.")
	var joined := _join(cages, b2, b1)
	var v1 := int(first.index) + int(joined.voff)
	var v2 := int(second.index)
	var r := FORM_OPS.weld_vertices(joined.cage, {"vertices": PackedInt32Array([v1, v2])}, {"mode": mode, "keep_creases": keep})
	if not r.ok:
		var why := str(r.error)
		if why.contains("three faces") or why.contains("non-manifold") or why.contains("manifold"):
			why = "Welding these vertices would make an edge with three faces"
		return failure(why)
	var out := {"ok": true, "cages": {b2: r.cage}, "warnings": r.warnings, "info": r.info}
	if b1 != b2:
		out["removed_bodies"] = [b1]
	return out


static func run_unweld_edges(ctx: Dictionary, picks: Dictionary, _values: Dictionary) -> Dictionary:
	var r := _each_body(ctx, picks.get("edges", []), func(cage: Dictionary, sel: Dictionary, _body: String) -> Dictionary:
		return FORM_OPS.unweld(cage, sel, {}), "Pick edges to cut along.")
	if r.ok:
		for body in r.cages:
			var parts := CAGE.topology(r.cages[body]).component_count()
			_info(ctx, "result", "%d separate pieces (each becomes a body when the form is finished)" % parts if parts > 1 else "The cut leaves one piece")
	return r


static func run_bevel_edge(ctx: Dictionary, picks: Dictionary, values: Dictionary) -> Dictionary:
	var opts := {"mode": str(values.get("distance_mode", "ratio")), "ratio": float(values.get("ratio", 0.25)), "width": float(values.get("width", 0.0)),
		"segments": clampi(roundi(float(values.get("segments", 1))), 1, 16), "spacing": str(values.get("spacing", "uniform")),
		"crown": clampf(float(values.get("crown", 1.0)), 0.0, 2.0)}
	return _each_body(ctx, picks.get("edges", []), func(cage: Dictionary, sel: Dictionary, _body: String) -> Dictionary:
		return FORM_OPS.bevel_edge(cage, sel, opts), "Pick edges to bevel.")


static func run_slide_edge(ctx: Dictionary, picks: Dictionary, values: Dictionary) -> Dictionary:
	var s := clampf(float(values.get("slide", 0.0)), -1.0, 1.0)
	if s == 0.0:
		return failure(FORM_OPS.NOTHING)
	var r := _each_body(ctx, picks.get("edges", []), func(cage: Dictionary, sel: Dictionary, _body: String) -> Dictionary:
		return FORM_OPS.slide_edge(cage, sel, {"slide": s}), "Pick edges to slide.")
	if r.ok and absf(s) >= 1.0 - 1e-9:
		# All the way puts each slid vertex on its neighbour along the rail: those edges and the
		# faces between them collapse.
		var notes: PackedStringArray = r.warnings
		notes.append("Slide %s puts the edges onto their neighbours: the faces between them collapse (no area)." % String.num(s))
		r.warnings = notes
	return r


static func run_smooth(ctx: Dictionary, picks: Dictionary, values: Dictionary) -> Dictionary:
	var amount := clampf(float(values.get("amount", 0.5)), 0.0, 1.0)
	if amount == 0.0:
		return failure(FORM_OPS.NOTHING)
	return _each_body(ctx, picks.get("faces", []), func(cage: Dictionary, sel: Dictionary, _body: String) -> Dictionary:
		return FORM_OPS.smooth(cage, sel, {"amount": amount}), "Pick faces to smooth.")


static func run_cylindrify(ctx: Dictionary, picks: Dictionary, values: Dictionary) -> Dictionary:
	var opts := {"auto_feature": bool(values.get("auto_feature", true))}
	return _each_body(ctx, picks.get("faces", []), func(cage: Dictionary, sel: Dictionary, _body: String) -> Dictionary:
		return FORM_OPS.cylindrify(cage, sel, opts), "Pick faces of a band to make round.")


## Pull: onto every model body (Auto) or the picked ones (values.target_bodies: body ids).
static func run_pull(ctx: Dictionary, picks: Dictionary, values: Dictionary) -> Dictionary:
	var result: Dictionary = ctx.get("result", {})
	var bodies: Dictionary = result.get("bodies", {})
	var shapes := []
	if str(values.get("target", "auto")) == "select":
		for id in list_value(values, "target_bodies"):
			var key := str(id.get("body", "")) if id is Dictionary else str(id)
			var body: Dictionary = bodies.get(key, {})
			if body.get("shape") != null:
				shapes.append(body.shape)
		if shapes.is_empty():
			return failure("Pick the bodies to pull to (Target Bodies).")
	else:
		var cages: Dictionary = ctx.get("cages", {})
		for id in bodies:
			if cages.has(id):
				continue
			var shape: Variant = (bodies[id] as Dictionary).get("shape")
			if shape != null:
				shapes.append(shape)
	if shapes.is_empty():
		return failure("There is no body to pull to")
	var opts := {"shapes": shapes, "type": str(values.get("type", "control"))}
	var r := _each_body(ctx, picks.get("vertices", []), func(cage: Dictionary, sel: Dictionary, _body: String) -> Dictionary:
		return FORM_FIT.pull(cage, sel, opts), "Pick cage vertices to pull.")
	if r.ok:
		_info(ctx, "result", "Moved %d vertices up to %s" % [(r.info.get("moved", PackedInt32Array()) as PackedInt32Array).size(), _length(ctx, float(r.info.get("max_distance", 0.0)))])
	return r


static func run_flatten(ctx: Dictionary, picks: Dictionary, values: Dictionary) -> Dictionary:
	var opts := {"direction": str(values.get("direction", "fit")), "type": str(values.get("type", "control"))}
	if opts.direction != "fit":
		var plane := _plane_of(ctx, values, "plane")
		if plane.has("error"):
			return failure(str(plane.error))
		opts["plane"] = plane
	if opts.type == "surface" and not FORM_FIT.available():
		return failure("Flattening surface points needs the Holo Forge kernel.")
	return _each_body(ctx, picks.get("vertices", []), func(cage: Dictionary, sel: Dictionary, _body: String) -> Dictionary:
		return FORM_FIT.flatten(cage, sel, opts), "Pick vertices to flatten.")


static func run_straighten(ctx: Dictionary, picks: Dictionary, values: Dictionary) -> Dictionary:
	var opts := {"direction": str(values.get("direction", "fit")), "type": str(values.get("type", "control"))}
	match opts.direction:
		"line", "parallel":
			var line := _axis_of(ctx, values, "line")
			if line.has("error"):
				return failure(str(line.error))
			opts["line"] = line
		"two_points":
			var refs := list_value(values, "points")
			if refs.size() < 2:
				return failure("Pick two points for the line.")
			var pts := []
			for ref in refs.slice(0, 2):
				var q := _point_of(ctx, ref)
				if q.has("error"):
					return failure(str(q.error))
				pts.append(q.point)
			opts["points"] = pts
	if opts.type == "surface" and not FORM_FIT.available():
		return failure("Straightening surface points needs the Holo Forge kernel.")
	return _each_body(ctx, picks.get("vertices", []), func(cage: Dictionary, sel: Dictionary, _body: String) -> Dictionary:
		return FORM_FIT.straighten(cage, sel, opts), "Pick at least two vertices to straighten.")


## Match: picks.edges (one body's open boundary chain) onto values.target (sketch curves or model
## edges; headless callers may give values.target_points, a PackedFloat64Array polyline).
static func run_match(ctx: Dictionary, picks: Dictionary, values: Dictionary) -> Dictionary:
	var cages: Dictionary = ctx.get("cages", {})
	var groups := by_body(picks.get("edges", []))
	if groups.is_empty():
		return failure("Pick the form's open boundary edges to match.")
	if groups.size() != 1:
		return failure("Pick edges of one body.")
	var body := str(groups.keys()[0])
	if not cages.has(body):
		return failure("Pick edges of the open form.")
	var refs := list_value(values, "target")
	var opts := {"continuity": str(values.get("continuity", "g0")), "spacing": str(values.get("spacing", "uniform")),
		"falloff": clampi(roundi(float(values.get("falloff", 1))), 0, 3), "reverse": bool(values.get("reverse", false))}
	if values.has("target_points") and refs.is_empty():
		opts["points"] = PackedFloat64Array(values.target_points)
		opts["closed"] = bool(values.get("target_closed", false))
	else:
		var line := FORM_FIT.target_polyline(refs, refs_ctx(ctx))
		if str(line.get("error", "")) != "":
			return failure(str(line.error))
		opts["points"] = line.points
		opts["closed"] = line.closed
		if line.has("normal_at"):
			opts["normal_at"] = line.normal_at
	if bool(values.get("associative", false)):
		if refs.is_empty():
			return failure("Associative needs picked curves or edges.")
		var why := _associative_problem(ctx, refs)
		if why != "":
			return failure(why)
		opts["link"] = {"target": refs[0], "targets": refs.duplicate(true), "continuity": opts.continuity, "spacing": opts.spacing,
			"falloff": opts.falloff, "reverse": opts.reverse}
	var r := FORM_FIT.match_chain(cages[body], groups[body], opts)
	if not r.ok:
		return failure(r.error)
	_info(ctx, "result", "Matched %d vertices (%s off)" % [(r.info.get("moved", PackedInt32Array()) as PackedInt32Array).size(), _length(ctx, float(r.info.get("residual", 0.0)))])
	return {"ok": true, "cages": {body: r.cage}, "warnings": r.warnings, "info": r.info}


## Why associative targets can't be linked ("" when they can): each must come from a feature before
## the form in the timeline.
static func _associative_problem(ctx: Dictionary, refs: Array) -> String:
	var doc: Resource = ctx.get("doc")
	var feature: Resource = ctx.get("feature")
	if doc == null or feature == null:
		return ""
	var at: int = doc.feature_index(feature.id)
	var bodies: Dictionary = (ctx.get("result", {}) as Dictionary).get("bodies", {})
	for ref in refs:
		if not ref is Dictionary:
			continue
		var source := ""
		match str(ref.get("kind", "")):
			"sketch_curve":
				source = str(ref.get("sketch", ""))
			"edge", "face":
				source = str((bodies.get(str(ref.get("body", "")), {}) as Dictionary).get("feature", ""))
		if source == "" or source == str(feature.id) or doc.feature_index(source) < 0 or doc.feature_index(source) >= at:
			return "Associative targets must come before the form in the timeline"
	return ""


static func run_interpolate(ctx: Dictionary, picks: Dictionary, values: Dictionary) -> Dictionary:
	var cages: Dictionary = ctx.get("cages", {})
	var items: Array = picks.get("elements", [])
	if items.is_empty():
		items = []
		for body in cages:
			items.append({"kind": "body", "body": body, "index": -1, "pair": Vector2i(-1, -1)})
	var opts := {"mode": str(values.get("mode", "through"))}
	var r := _each_body(ctx, items, func(cage: Dictionary, sel: Dictionary, _body: String) -> Dictionary:
		return FORM_FIT.interpolate(cage, sel, opts), "The form has no bodies yet.")
	if r.ok and opts.mode == "through":
		_info(ctx, "result", "The surface passes the cage points within %s" % _length(ctx, float(r.info.get("residual", 0.0))))
	return r


static func run_thicken(ctx: Dictionary, picks: Dictionary, values: Dictionary) -> Dictionary:
	var opts := {"type": str(values.get("type", "sharp")), "direction": str(values.get("direction", "normal")), "flip": bool(values.get("flip", false))}
	if opts.direction == "axis":
		var axis := _axis_of(ctx, values, "axis")
		if axis.has("error"):
			return failure(str(axis.error))
		opts["axis"] = axis.direction
	return _each_body(ctx, picks.get("elements", []), func(cage: Dictionary, sel: Dictionary, _body: String) -> Dictionary:
		var o := opts.duplicate()
		o["thickness"] = _auto_length(ctx, values, "thickness", maxf(0.001, 0.05 * CAGE.diagonal(cage)))
		return FORM_OPS.thicken(cage, sel, o), "Pick a body (or faces of it) to thicken.")


# --- Symmetry --------------------------------------------------------------------------------------

## True when cage already has a mirror through this plane.
static func _has_mirror(cage: Dictionary, origin: PackedFloat64Array, normal: PackedFloat64Array, tol: float) -> bool:
	for e in cage.get("symmetry", []):
		if str(e.get("type", "")) != "mirror":
			continue
		var n := FORM_OPS.unit_d(FORM_OPS._d3(e.normal))
		var dot := absf(n[0] * normal[0] + n[1] * normal[1] + n[2] * normal[2])
		var o := FORM_OPS._d3(e.origin)
		var off := absf((origin[0] - o[0]) * n[0] + (origin[1] - o[1]) * n[1] + (origin[2] - o[2]) * n[2])
		if dot > 1.0 - 1e-6 and off <= tol:
			return true
	return false


static func run_mirror_internal(ctx: Dictionary, picks: Dictionary, values: Dictionary) -> Dictionary:
	return _internal(ctx, picks, values, false)


static func run_circular_internal(ctx: Dictionary, picks: Dictionary, values: Dictionary) -> Dictionary:
	return _internal(ctx, picks, values, true)


static func _internal(ctx: Dictionary, picks: Dictionary, values: Dictionary, circular: bool) -> Dictionary:
	var cages: Dictionary = ctx.get("cages", {})
	if cages.is_empty():
		return failure("The form has no bodies yet.")
	var items: Array = picks.get("faces", [])
	var groups := by_body(items)
	var bodies := picked_bodies(items, cages)
	var out := {"ok": true, "cages": {}, "warnings": PackedStringArray(), "info": {}}
	var labels := PackedStringArray()
	var last_error := ""
	for body in bodies:
		var cage: Dictionary = cages[body]
		var hint: PackedInt32Array = (groups.get(body, {}) as Dictionary).get("faces", PackedInt32Array())
		var tol := _auto_length(ctx, values, "tolerance", FORM_OPS.default_tolerance(cage))
		var cands := FORM_OPS.detect_circular(cage, hint, tol) if circular else FORM_OPS.detect_mirror(cage, hint, tol)
		if not circular:
			cands = cands.filter(func(cand: Dictionary) -> bool: return not _has_mirror(cage, FORM_OPS._d3(cand.origin), FORM_OPS.unit_d(FORM_OPS._d3(cand.normal)), tol))
		for i in cands.size():
			var cand: Dictionary = cands[i]
			labels.append("%d: %s" % [i + 1, ("%d around %s" % [int(cand.count), str(cand.label)]) if circular else str(cand.label)])
		if cands.is_empty():
			last_error = "No circular symmetry found within the tolerance; pick a face" if circular else "No mirror symmetry found within the tolerance; pick a face on each side"
			continue
		var pick := clampi(int(str(values.get("candidate", "0"))), 0, cands.size() - 1)
		var cand: Dictionary = cands[pick]
		var opts := {"origin": cand.origin, "tolerance": tol, "snap": bool(values.get("snap", true))}
		var r: Dictionary
		if circular:
			opts["axis"] = cand.axis
			opts["count"] = int(cand.count)
			r = FORM_OPS.add_circular(cage, {}, opts)
		else:
			opts["normal"] = cand.normal
			r = FORM_OPS.add_mirror(cage, {}, opts)
		if not r.ok:
			last_error = str(r.error)
			continue
		out.cages[body] = r.cage
		out.warnings.append_array(r.warnings)
		out.info = {"candidates": cands.size(), "label": str(cand.label), "count": int(cand.get("count", 0))}
	_info(ctx, "candidates", "\n".join(labels) if not labels.is_empty() else "No symmetry found yet.")
	if (out.cages as Dictionary).is_empty():
		return failure(last_error if last_error != "" else "Pick a face of a body.")
	# Its picks are required: without a face on each side, OK would apply whichever plane ranked
	# first (a thickness mid-plane, say), which then mirrors every later edit. The candidates
	# still show.
	if not circular and items.size() < 2:
		return failure("Pick a face on each side of the symmetry (2 faces), then OK.")
	return out


static func run_mirror_duplicate(ctx: Dictionary, picks: Dictionary, values: Dictionary) -> Dictionary:
	var cages: Dictionary = ctx.get("cages", {})
	var items: Array = picks.get("bodies", [])
	if by_body(items).is_empty():
		return failure("Pick the body to mirror.")
	var plane := _plane_of(ctx, values, "plane")
	if plane.has("error"):
		return failure("Pick a mirror plane." if list_value(values, "plane").is_empty() else str(plane.error))
	var out := {"ok": true, "cages": {}, "warnings": PackedStringArray(), "info": {}}
	for body in by_body(items):
		if not cages.has(body):
			continue
		var cage: Dictionary = cages[body]
		var opts := {"origin": plane.origin, "normal": plane.normal, "weld": bool(values.get("weld", true)),
			"tolerance": _auto_length(ctx, values, "tolerance", 0.01 * _mean_edge(cage))}
		var r := FORM_OPS.mirror_duplicate(cage, {}, opts)
		if not r.ok:
			return failure(r.error)
		out.cages[body] = r.cage
		out.warnings.append_array(r.warnings)
		out.info = r.info
	return out


static func run_circular_duplicate(ctx: Dictionary, picks: Dictionary, values: Dictionary) -> Dictionary:
	var cages: Dictionary = ctx.get("cages", {})
	var items: Array = picks.get("bodies", [])
	if by_body(items).is_empty():
		return failure("Pick the body to repeat.")
	var axis := _axis_of(ctx, values, "axis")
	if axis.has("error"):
		return failure(str(axis.error))
	var out := {"ok": true, "cages": {}, "warnings": PackedStringArray(), "info": {}}
	for body in by_body(items):
		if not cages.has(body):
			continue
		var cage: Dictionary = cages[body]
		var opts := {"origin": axis.origin, "axis": axis.direction, "count": clampi(roundi(float(values.get("quantity", 4))), 2, 64),
			"spacing": str(values.get("spacing", "full")), "angle": float(values.get("angle", PI)), "weld": bool(values.get("weld", true)),
			"tolerance": _auto_length(ctx, values, "tolerance", 0.01 * _mean_edge(cage))}
		var r := FORM_OPS.circular_duplicate(cage, {}, opts)
		if not r.ok:
			return failure(r.error)
		out.cages[body] = r.cage
		out.warnings.append_array(r.warnings)
	return out


static func run_isolate_symmetry(ctx: Dictionary, picks: Dictionary, values: Dictionary) -> Dictionary:
	var opts := {"mode": str(values.get("mode", "isolate"))}
	return _each_body(ctx, picks.get("elements", []), func(cage: Dictionary, sel: Dictionary, _body: String) -> Dictionary:
		return FORM_OPS.isolate_symmetry(cage, sel, opts), "Pick cage faces, edges or vertices.")


# --- Utilities -------------------------------------------------------------------------------------

## Repair Body: the picked bodies (all when none). info.markers per body go to the editor's tool
## state for drawing ({body id: markers}).
static func run_repair_body(ctx: Dictionary, picks: Dictionary, values: Dictionary) -> Dictionary:
	var cages: Dictionary = ctx.get("cages", {})
	if cages.is_empty():
		return failure("The form has no bodies yet.")
	var report := str(values.get("mode", "fix")) == "report"
	var out := {"ok": true, "cages": {}, "warnings": PackedStringArray(), "info": {}}
	var markers := {}
	var totals := {}
	for body in picked_bodies(picks.get("bodies", []), cages):
		var cage: Dictionary = cages[body]
		var opts := {"mode": "report" if report else "fix", "merge_triangles": bool(values.get("merge_triangles", false)),
			"tolerance": _auto_length(ctx, values, "tolerance", 1e-6 * CAGE.diagonal(cage))}
		var r := FORM_FIT.repair(cage, {}, opts)
		if not r.ok:
			return failure(r.error)
		markers[body] = (r.info as Dictionary).get("markers", [])
		for key in r.info:
			if key != "markers" and (r.info[key] is int or r.info[key] is float):
				totals[key] = int(totals.get(key, 0)) + int(r.info[key])
		out.warnings.append_array(r.warnings)
		if not report and (CAGE.content_hash(r.cage) != CAGE.content_hash(cage) or _extras(r.cage) != _extras(cage)):
			out.cages[body] = r.cage
	out.info = totals
	out.info["markers"] = markers
	var editor: Object = ctx.get("editor")
	if editor != null and is_instance_valid(editor):
		editor.tool_state["repair_markers"] = markers
	var parts := PackedStringArray()
	for key in ["degenerate", "duplicate", "welded", "t_junctions", "non_manifold", "flipped", "unused", "self_intersections", "triangles_merged"]:
		if int(totals.get(key, 0)) > 0:
			parts.append("%s %d" % [str(key).replace("_", " "), int(totals[key])])
	var kinds := {}
	for body in markers:
		for mk in markers[body]:
			if str(mk.get("severity", "")) == "warning":
				var label := str(mk.get("label", "")).split(" (")[0].to_lower()
				kinds[label] = int(kinds.get(label, 0)) + 1
	var notes := PackedStringArray()
	for label in kinds:
		notes.append("%d %s%s" % [kinds[label], label, "" if int(kinds[label]) == 1 else "s"])
	var text := ("Fixes: " + ", ".join(parts)) if not parts.is_empty() else "Nothing to fix"
	if not notes.is_empty():
		text += ". Marked: " + ", ".join(notes)
	_info(ctx, "result", text)
	if report:
		return failure(FORM_OPS.NOTHING)
	if (out.cages as Dictionary).is_empty():
		return failure(FORM_OPS.NOTHING)
	return out


## The parts of a cage beyond its surface that Repair may change (frozen, isolated, symmetry).
static func _extras(c: Dictionary) -> String:
	return str([c.get("frozen"), c.get("sym_isolated"), c.get("symmetry"), c.get("links")])


static func run_make_uniform(ctx: Dictionary, picks: Dictionary, values: Dictionary) -> Dictionary:
	var cages: Dictionary = ctx.get("cages", {})
	var items: Array = picks.get("bodies", [])
	if items.is_empty():
		for body in cages:
			items.append({"kind": "body", "body": body, "index": -1, "pair": Vector2i(-1, -1)})
	var opts := {"quads_only": bool(values.get("quads_only", true)), "even": bool(values.get("even", false)),
		"iterations": clampi(roundi(float(values.get("iterations", 5))), 1, 20)}
	var r := _each_body(ctx, items, func(cage: Dictionary, sel: Dictionary, _body: String) -> Dictionary:
		return FORM_FIT.make_uniform(cage, sel, opts), "The form has no bodies yet.")
	if r.ok:
		_info(ctx, "result", _deviation_text(ctx, r.info) if opts.even else "Every face is a quad")
	return r


## Convert: Form to BRep (the picked cage bodies become fixed B-rep bodies of the form), Mesh to Form
## (a body made by Insert Mesh becomes a new cage body; the mesh stays) or Face to Form (four-sided
## model faces become grid cage bodies).
static func run_convert(ctx: Dictionary, picks: Dictionary, values: Dictionary) -> Dictionary:
	match str(values.get("direction", "form_brep")):
		"mesh_form":
			return _mesh_to_form(ctx, values)
		"face_form":
			return _face_to_form(ctx, values)
	var cages: Dictionary = ctx.get("cages", {})
	var feature: Resource = ctx.get("feature")
	var bodies := by_body(picks.get("bodies", []))
	if bodies.is_empty():
		return failure("Pick the form bodies to convert.")
	var quality := str(feature.options.get("quality", "standard")) if feature != null else "standard"
	var fid := str(feature.id) if feature != null else "form"
	var breps := {}
	var notes := {}
	var warnings := PackedStringArray()
	for body in bodies:
		if not cages.has(body):
			continue
		var r := FORM_FIT.to_breps(cages[body], FORM.isolation(quality), fid + "/" + str(body))
		if str(r.get("error", "")) != "":
			return failure("%s: %s" % [str(body), r.error])
		var bytes: Array = r.bytes
		var doc: Resource = ctx.get("doc")
		var name: String = doc.body_name(str(body)) if doc != null and doc.has_method("body_name") else str(body)
		# Every conversion warning (flat, folded or self-intersecting cages, degenerate faces,
		# pinches, seams), as Finish shows them; they are kept with the B-rep (options.brep_notes)
		# so each rebuild shows them again: once converted, the cage is gone.
		var body_notes := FORM.conversion_notes(r.report as Dictionary) + FORM.flat_crease_notes(cages[body])
		for k in bytes.size():
			var out_id := str(body) if k == 0 else UTIL.derived_body_id(str(body), fid, k + 1)
			breps[out_id] = bytes[k]
			notes[out_id] = body_notes
		for note in body_notes:
			warnings.append("%s %s" % [name, note] if note.begins_with("converted by") else "%s: %s" % [name, note])
	if breps.is_empty():
		return failure("Pick the form bodies to convert.")
	return {"ok": true, "breps": breps, "brep_notes": notes, "warnings": warnings, "info": {"converted": breps.size()}}


## read_polygons() of a mesh_import feature's file when it is there, else its kept triangles; both
## in meters at the feature's placement.
static func mesh_polygons(feature: Resource, ctx: Dictionary) -> Dictionary:
	var options: Dictionary = feature.options
	var units := str(options.get("units", "mm"))
	var path := str(options.get("path", ""))
	var points := PackedVector3Array()
	var faces: Array = []
	var polys := MESH_IMPORT.read_polygons(path, "m") if path != "" and FileAccess.file_exists(path) else {"error": "missing"}
	if str(polys.get("error", "")) == "":
		points = polys.points
		faces = polys.faces
	else:
		points = options.get("positions", PackedVector3Array())
		var indices: PackedInt32Array = options.get("indices", PackedInt32Array())
		# Kept triangles are in Godot's clockwise winding: back to counter-clockwise.
		for t in range(0, indices.size() - 2, 3):
			faces.append(PackedInt32Array([indices[t], indices[t + 2], indices[t + 1]]))
	if points.is_empty() or faces.is_empty():
		return {"error": "The mesh holds no faces"}
	var scale := MESH_IMPORT.unit_scale(units)
	var box := AABB(points[0] * scale, Vector3.ZERO)
	for q in points:
		box = box.expand(q * scale)
	var INSERT: Script = load("res://addons/holo_forge/core/features/insert.gd")
	var rctx := refs_ctx(ctx)
	var xform: Transform3D = options.get("transform", Transform3D.IDENTITY)
	if rctx.get("kernel") != null:
		var reader: RefCounted = UTIL.Reader.new(feature, rctx)
		xform = INSERT.placement(reader, box)
	xform = xform * Transform3D(Basis.from_scale(Vector3.ONE * scale), Vector3.ZERO)
	var out := PackedFloat64Array()
	for q in points:
		var w := xform * q
		out.append_array(PackedFloat64Array([w.x, w.y, w.z]))
	return {"points": out, "faces": faces, "error": ""}


static func _mesh_to_form(ctx: Dictionary, values: Dictionary) -> Dictionary:
	var doc: Resource = ctx.get("doc")
	var list := list_value(values, "mesh_body")
	if list.is_empty() or doc == null:
		return failure("Pick a body made by Insert Mesh.")
	var body_id := str(list[0].get("body", "")) if list[0] is Dictionary else str(list[0])
	var info: Dictionary = doc.bodies.get(body_id, {})
	var feature: Resource = doc.find_feature(str(info.get("feature", ""))) if not info.is_empty() else null
	if feature == null or feature.type != "mesh_import":
		return failure("Pick a body made by Insert Mesh.")
	var polys := mesh_polygons(feature, ctx)
	if str(polys.get("error", "")) != "":
		return failure(str(polys.error))
	var tol := float(values.get("weld_tolerance", 0.0))
	var r := FORM_FIT.mesh_to_cage(polys.points, polys.faces, {"merge": bool(values.get("merge", true)), "tolerance": tol})
	if str(r.get("error", "")) != "":
		return failure(str(r.error))
	var cage: Dictionary = r.cage
	_info(ctx, "result", "%d vertices, %d faces" % [CAGE.vertex_count(cage), CAGE.face_count(cage)])
	return {"ok": true, "new_bodies": [cage], "info": r.info}


static func _face_to_form(ctx: Dictionary, values: Dictionary) -> Dictionary:
	var refs := list_value(values, "faces")
	if refs.is_empty():
		return failure("Pick four-sided model faces.")
	var rctx := refs_ctx(ctx)
	var cages := []
	var nu := maxi(0, roundi(float(values.get("grid_u", 0))))
	var nv := maxi(0, roundi(float(values.get("grid_v", 0))))
	var worst := 0.0
	for ref in refs:
		var shape: RefCounted
		var index := -1
		if ref is Dictionary and (ref as Dictionary).has("shape"):
			shape = ref.shape
			index = int(ref.get("index", 0))
		else:
			var found := REFERENCES.face(ref, rctx)
			if found.has("error"):
				return failure(str(found.error))
			shape = found.shape
			index = int(found.index)
		var r := FORM_FIT.face_to_cage(shape, index, nu, nv, bool(values.get("fit", true)))
		if str(r.get("error", "")) != "":
			return failure(str(r.error))
		cages.append(r.cage)
		worst = maxf(worst, float(r.residual))
	var joined: Dictionary = cages[0]
	for k in range(1, cages.size()):
		joined = CAGE.append(joined, cages[k]).cage
	if cages.size() > 1:
		var w := FORM_OPS.weld_vertices(joined, {}, {"mode": "tolerance", "tolerance": 1e-6 * maxf(CAGE.diagonal(joined), 1e-9)})
		if w.ok:
			joined = w.cage
	var parts := FORM_OPS.split_components(joined)
	_info(ctx, "result", "%d bod%s; the surface passes the samples within %s" % [parts.size(), "y" if parts.size() == 1 else "ies", _length(ctx, worst)])
	return {"ok": true, "new_bodies": parts, "info": {"residual": worst, "bodies": parts.size()}}


# --- Edit By Curve ---------------------------------------------------------------------------------

## The numeric transform of the Edit By Curve panel (about the picked control points' centroid):
## 12 doubles, or empty when the fields are neutral.
static func curve_xf(values: Dictionary) -> PackedFloat64Array:
	var t := Vector3(float(values.get("x_distance", 0.0)), float(values.get("y_distance", 0.0)), float(values.get("z_distance", 0.0)))
	var a := Vector3(float(values.get("x_angle", 0.0)), float(values.get("y_angle", 0.0)), float(values.get("z_angle", 0.0)))
	var s := Vector3(float(values.get("x_scale", 1.0)), float(values.get("y_scale", 1.0)), float(values.get("z_scale", 1.0)))
	s.x *= float(values.get("xy_scale", 1.0)) * float(values.get("zx_scale", 1.0))
	s.y *= float(values.get("xy_scale", 1.0)) * float(values.get("yz_scale", 1.0))
	s.z *= float(values.get("yz_scale", 1.0)) * float(values.get("zx_scale", 1.0))
	if t == Vector3.ZERO and a == Vector3.ZERO and s == Vector3.ONE:
		return PackedFloat64Array()
	var basis := Basis.from_euler(a, EULER_ORDER_XYZ) * Basis.from_scale(s)
	return FORM_OPS.xf_from(basis, t)


static func _curve_opts(values: Dictionary) -> Dictionary:
	return {"degree": clampi(roundi(float(values.get("degree", 3))), 1, 7), "distribution": str(values.get("distribution", "edge_length")),
		"planar": bool(values.get("planar", false)), "fit": str(values.get("fit", "control")), "offsets": list_value(values, "curve_offsets"),
		"selected": PackedInt32Array(list_value(values, "curve_selected")), "xf": curve_xf(values)}


static func run_edit_by_curve(ctx: Dictionary, picks: Dictionary, values: Dictionary) -> Dictionary:
	if _curve_switch(ctx, picks):
		return failure(FORM_OPS.NOTHING)
	var out := _edit_by_curve(ctx, picks, values)
	_curve_remember(ctx, picks, out)
	return out


static func _edit_by_curve(ctx: Dictionary, picks: Dictionary, values: Dictionary) -> Dictionary:
	var groups := by_body(picks.get("edges", []))
	if groups.is_empty():
		return failure("Pick an open chain of edges")
	if groups.size() != 1:
		return failure("Pick a chain of edges on one body.")
	var body := str(groups.keys()[0])
	var cages: Dictionary = ctx.get("cages", {})
	if not cages.has(body):
		return failure("Pick edges of the open form.")
	var opts := _curve_opts(values)
	if opts.fit == "surface" and not FORM_FIT.available():
		return failure("Surface Points needs the Holo Forge kernel.")
	var r := FORM_FIT.edit_by_curve(cages[body], groups[body], opts)
	if not r.ok:
		return failure(r.error)
	return {"ok": true, "cages": {body: r.cage}, "warnings": r.warnings, "info": r.info, "selection": items_of(body, groups[body])}


const _CURVE_NEUTRAL := {"curve_offsets": [], "curve_selected": [], "x_distance": "0", "y_distance": "0", "z_distance": "0",
	"x_angle": "0 deg", "y_angle": "0 deg", "z_angle": "0 deg", "x_scale": "1", "y_scale": "1", "z_scale": "1", "xy_scale": "1",
	"yz_scale": "1", "zx_scale": "1"}


static func _chain_key(items: Array) -> String:
	var keys := PackedStringArray()
	for item in items:
		if item is Dictionary:
			var pair: Vector2i = item.get("pair", Vector2i(-1, -1))
			keys.append("%s:%d-%d" % [str(item.get("body", "")), mini(pair.x, pair.y), maxi(pair.x, pair.y)])
	keys.sort()
	return ",".join(keys)


## Edit By Curve keeps the last edit of the picked chain. When the chain changes while the tool is
## open (the edge selection cleared or another chain picked), that edit becomes its own undo step
## and the curve starts fresh for the new chain. True when an edit is being committed (the caller
## shows nothing until the reset values arrive).
static func _curve_switch(ctx: Dictionary, picks: Dictionary) -> bool:
	var editor: Object = ctx.get("editor")
	if editor == null or not is_instance_valid(editor):
		return false
	var st: Dictionary = editor.tool_state
	var key := _chain_key(picks.get("edges", []))
	var last_key := str(st.get("curve_key", key))
	st["curve_key"] = key
	if last_key == key or not st.has("curve_last"):
		return false
	var last: Dictionary = st.curve_last
	st.erase("curve_last")
	var body := str(last.get("body", ""))
	if CAGE.content_hash(editor.cage_of(body)) != int(last.get("source", 0)):
		return false
	var r: Dictionary = last.result
	var fid := str(editor.feature_id)
	var ws: Object = editor.workspace
	(func() -> void:
		if not is_instance_valid(editor) or str(editor.tool) != "edit_by_curve":
			return
		ws.change("Form: Edit By Curve", func() -> void: editor.apply_result(fid, r, []))
		editor.set_tool_values(_CURVE_NEUTRAL.duplicate(true))).call_deferred()
	return true


static func _curve_remember(ctx: Dictionary, picks: Dictionary, out: Dictionary) -> void:
	var editor: Object = ctx.get("editor")
	if editor == null or not is_instance_valid(editor):
		return
	var st: Dictionary = editor.tool_state
	st["curve_key"] = _chain_key(picks.get("edges", []))
	if not bool(out.get("ok", false)) or (out.get("cages", {}) as Dictionary).is_empty():
		st.erase("curve_last")
		return
	var body := str((out.cages as Dictionary).keys()[0])
	st["curve_last"] = {"body": body, "source": CAGE.content_hash(editor.cage_of(body)), "result": {"ok": true, "cages": out.cages.duplicate()}}


# --- Buttons ------------------------------------------------------------------------------------------

## The editor hands each panel button it doesn't handle itself to button_<tool id>.
static func button_erase_and_fill(editor: Object, key: String) -> void:
	button(editor, key)


static func button_straighten(editor: Object, key: String) -> void:
	button(editor, key)


static func button_match(editor: Object, key: String) -> void:
	button(editor, key)


static func button_edit_by_curve(editor: Object, key: String) -> void:
	button(editor, key)


## Button actions (also callable directly): Erase and Fill's Feature, Straighten's Range, Match's
## Alternate Alignment, Edit By Curve's Reset Curve.
static func button(editor: Object, key: String) -> void:
	match key:
		"feature":
			editor.select_helper("feature")
		"range":
			editor.select_helper("range")
		"alternate":
			editor.set_tool_values({"reverse": not bool(editor.tool_values.get("reverse", false))})
		"reset_curve":
			editor.set_tool_values(_CURVE_NEUTRAL.duplicate(true))


# --- View interaction -------------------------------------------------------------------------------

## The first pick slot's key and whether it is still empty.
static func _first_slot_empty(editor: Object) -> bool:
	var picks: Array = (TOOLS.get(str(editor.tool), {}) as Dictionary).get("picks", [])
	if picks.is_empty():
		return false
	return (editor.tool_picks.get(str(picks[0].key), []) as Array).is_empty()


static func _first_slot_kinds(editor: Object) -> Array:
	var picks: Array = (TOOLS.get(str(editor.tool), {}) as Dictionary).get("picks", [])
	return (picks[0] as Dictionary).get("kinds", []) if not picks.is_empty() else []


## A press for the panel's active selection slot (Side Two, a plane, target bodies...): true when the
## slot took it. Clicks on cage elements the first slot takes go to the editor's selection while the
## first slot is empty, or when the active slot holds model references.
static func slot_mouse(editor: Object, event: InputEvent) -> bool:
	var button := event as InputEventMouseButton
	if button == null or not button.pressed or button.button_index != MOUSE_BUTTON_LEFT:
		return false
	var ws: Object = editor.workspace
	var panel: Object = ws.panel
	var key := str(panel.active_selection_key)
	if key == "":
		return false
	var field := _field(str(editor.tool), key)
	if field.is_empty() or str(field.get("type", "")) != "selection":
		return false
	var condition: Dictionary = field.get("visible_if", {})
	for other in condition:
		if not (condition[other] as Array).has(editor.tool_values.get(other)):
			return false
	if bool(field.get("cage", false)):
		if _first_slot_empty(editor):
			return false
		var pick: Dictionary = editor.pick_at(button.position, field.get("kinds", []))
		if pick.is_empty():
			return true
		panel.add_selection({"kind": str(pick.kind), "body": str(pick.body), "index": int(pick.get("index", -1)), "pair": pick.get("pair", Vector2i(-1, -1))})
		return true
	var kinds := _first_slot_kinds(editor)
	if not kinds.is_empty() and not editor.pick_at(button.position, kinds).is_empty():
		return false
	var filter: Variant = field.get("filter", [])
	var wanted: Array = [filter] if filter is String else (filter as Array)
	var picker: Object = ws.get("picker")
	if picker == null:
		return false
	var saved: Callable = picker.kinds_provider
	picker.kinds_provider = func() -> Array: return wanted
	var ref: Dictionary = picker.pick(button.position)
	picker.kinds_provider = saved
	if ref.is_empty():
		return false
	ref.erase("key")
	if filter is String:
		if not ref.has("body"):
			return false
		panel.add_selection(str(ref.body))
	else:
		panel.add_selection(ref)
	return true


## Cage items held by the tool's cage selection fields (drawn like partners).
static func _draw_slots(editor: Object, overlay: Control) -> void:
	for f in (TOOLS.get(str(editor.tool), {}) as Dictionary).get("fields", []):
		if str(f.get("type", "")) != "selection" or not bool(f.get("cage", false)):
			continue
		for item in list_value(editor.tool_values, str(f.key)):
			if item is Dictionary:
				editor._draw_item(overlay, item, editor.theme_colors.form_preview)
				if str(item.get("kind", "")) == "face":
					var cage: Dictionary = editor.cage_of(str(item.body))
					if cage.is_empty() or int(item.index) >= CAGE.face_count(cage):
						continue
					var verts := CAGE.face_vertices(cage, int(item.index))
					var ring := PackedVector2Array()
					for v in verts:
						ring.append(editor.viewport.project(CAGE.position(cage, v)))
					ring.append(ring[0])
					overlay.draw_polyline(ring, editor.theme_colors.form_preview, 2.0, true)


# Tools whose only view interaction is their panel slots.
static func handle_mouse_merge_edge(editor: Object, event: InputEvent) -> bool:
	return slot_mouse(editor, event)


static func draw_merge_edge(editor: Object, overlay: Control) -> void:
	_draw_slots(editor, overlay)


static func handle_mouse_bridge(editor: Object, event: InputEvent) -> bool:
	return slot_mouse(editor, event)


## Bridge: Side Two highlighted, and an arrow along each side's loop at its first vertex.
static func draw_bridge(editor: Object, overlay: Control) -> void:
	_draw_slots(editor, overlay)
	var sides := [editor.tool_picks.get("side1", []), list_value(editor.tool_values, "side2")]
	for items in sides:
		var groups := by_body(items)
		if groups.size() != 1:
			continue
		var body := str(groups.keys()[0])
		var cage: Dictionary = editor.cage_of(body)
		if cage.is_empty():
			continue
		var topo := CAGE.topology(cage)
		var s: Dictionary = groups[body]
		var side := FORM_OPS._side_loop(topo, s.faces, s.edges)
		if side.has("error"):
			continue
		var loop: PackedInt32Array = side.loop
		if loop.size() < 2:
			continue
		var a: Vector2 = editor.viewport.project(CAGE.position(cage, loop[0]))
		var b: Vector2 = editor.viewport.project(CAGE.position(cage, loop[1]))
		if not (a.is_finite() and b.is_finite()) or a.distance_to(b) < 2.0:
			continue
		var dir := (b - a).normalized()
		var tip := a + dir * minf(a.distance_to(b) * 0.6, 28.0)
		var side_v := Vector2(-dir.y, dir.x)
		var color: Color = editor.theme_colors.form_preview
		overlay.draw_line(a, tip, color, 2.0, true)
		overlay.draw_colored_polygon(PackedVector2Array([tip + dir * 8.0, tip + side_v * 4.5, tip - side_v * 4.5]), color)


static func handle_mouse_pull(editor: Object, event: InputEvent) -> bool:
	return slot_mouse(editor, event)


static func handle_mouse_flatten(editor: Object, event: InputEvent) -> bool:
	return slot_mouse(editor, event)


static func handle_mouse_straighten(editor: Object, event: InputEvent) -> bool:
	return slot_mouse(editor, event)


static func handle_mouse_match(editor: Object, event: InputEvent) -> bool:
	return slot_mouse(editor, event)


static func handle_mouse_thicken(editor: Object, event: InputEvent) -> bool:
	return slot_mouse(editor, event)


static func handle_mouse_mirror_duplicate(editor: Object, event: InputEvent) -> bool:
	return slot_mouse(editor, event)


static func handle_mouse_circular_duplicate(editor: Object, event: InputEvent) -> bool:
	return slot_mouse(editor, event)


static func handle_mouse_convert(editor: Object, event: InputEvent) -> bool:
	return slot_mouse(editor, event)


## Mirror / Circular - Internal: a click on a face adds it to the two hint faces (the oldest drops).
static func handle_mouse_mirror_internal(editor: Object, event: InputEvent) -> bool:
	return _face_toggle(editor, event)


static func handle_mouse_circular_internal(editor: Object, event: InputEvent) -> bool:
	return _face_toggle(editor, event)


static func _face_toggle(editor: Object, event: InputEvent) -> bool:
	var button := event as InputEventMouseButton
	if button == null or not button.pressed or button.button_index != MOUSE_BUTTON_LEFT:
		return false
	var pick: Dictionary = editor.pick_at(button.position, ["face"])
	if pick.is_empty():
		return false
	var item := {"kind": "face", "body": str(pick.body), "index": int(pick.index), "pair": Vector2i(-1, -1)}
	var kept := []
	for s in editor.selection:
		if str(s.kind) == "face" and str(s.body) == item.body and int(s.index) != item.index:
			kept.append(s)
	kept.append(item)
	while kept.size() > 2:
		kept.pop_front()
	editor.selection.clear()
	for s in kept:
		editor.selection.append(s)
	editor._selection_changed()
	return true


## Weld Vertices: in the two-vertex modes each click adds a vertex (any body); the second applies.
static func handle_mouse_weld_vertices(editor: Object, event: InputEvent) -> bool:
	if str(editor.tool_values.get("mode", "vertex")) == "tolerance":
		return false
	var button := event as InputEventMouseButton
	if button == null or not button.pressed or button.button_index != MOUSE_BUTTON_LEFT:
		return false
	var pick: Dictionary = editor.pick_at(button.position, ["vertex"])
	if pick.is_empty():
		return false
	var item := {"kind": "vertex", "body": str(pick.body), "index": int(pick.index), "pair": Vector2i(-1, -1)}
	var kept := []
	for s in editor.selection:
		if str(s.kind) == "vertex" and not (str(s.body) == item.body and int(s.index) == item.index):
			kept.append(s)
	kept.append(item)
	while kept.size() > 2:
		kept.pop_front()
	editor.selection.clear()
	for s in kept:
		editor.selection.append(s)
	editor._selection_changed()
	if kept.size() == 2:
		var tool_id := str(editor.tool)
		(func() -> void:
			if is_instance_valid(editor) and str(editor.tool) == tool_id:
				editor.tool_ok()).call_deferred()
	else:
		editor.workspace.flash("Weld Vertices: now click the vertex it welds to.")
	return true


## Repair Body: its markers (circles with a short label), error and warning colours.
static func draw_repair_body(editor: Object, overlay: Control) -> void:
	var markers: Dictionary = editor.tool_state.get("repair_markers", {})
	var c: Dictionary = editor.theme_colors
	var font := overlay.get_theme_default_font()
	for body in markers:
		# Markers behind the cage are drawn faint, without their labels (as hidden crease lines).
		var probe := PackedVector3Array()
		for m in markers[body]:
			probe.append(m.position)
		var seen: PackedByteArray = editor.cage_point_visibility(str(body), probe)
		var i := -1
		for m in markers[body]:
			i += 1
			var severity := str(m.get("severity", "info"))
			if severity == "info":
				continue
			var at: Vector2 = editor.viewport.project(m.position)
			if not at.is_finite():
				continue
			var color: Color = c.form_error if severity == "error" else c.form_warning
			if not seen.is_empty() and i < seen.size() and seen[i] == 0:
				overlay.draw_arc(at, 5.0, 0.0, TAU, 20, Color(color, color.a * 0.3), 1.5, true)
				continue
			overlay.draw_arc(at, 5.0, 0.0, TAU, 20, color, 2.0, true)
			var text := str(m.get("label", ""))
			var size := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 11)
			var box := Rect2(at + Vector2(8, -size.y * 0.5 - 2), size + Vector2(6, 4))
			overlay.draw_rect(box, c.get("note_back", Color(0, 0, 0, 0.6)), true)
			overlay.draw_string(font, box.position + Vector2(3, size.y - 1), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, c.get("note_text", Color.WHITE))


static func handle_mouse_repair_body(_editor: Object, _event: InputEvent) -> bool:
	return false


# --- Sliders (Insert Edge location, Slide Edge, Smooth amount) ---------------------------------------

## The tool's slider handles: [{"key", "origin", "direction" (the value 1 is at origin +
## direction), "min", "max"}].
static func sliders(editor: Object) -> Array:
	var id := str(editor.tool)
	var out := []
	match id:
		"insert_edge", "slide_edge":
			var groups := by_body(editor.tool_picks.get("edges", []))
			if groups.size() != 1:
				return out
			var body := str(groups.keys()[0])
			var cage: Dictionary = editor.cage_of(body)
			if cage.is_empty():
				return out
			var topo := CAGE.topology(cage)
			var si := FORM_OPS.side_items(topo, groups[body].edges, false)
			if (si.items as Array).is_empty():
				return out
			var item: Dictionary = si.items[0]
			var ev: Vector2i = item.edge
			var f: int = item.side
			var verts := topo.face_verts(f)
			var n := verts.size()
			var i := verts.find(ev.x)
			var rail_from := ev.x
			var rail_to := verts[(i - 1 + n) % n] if verts[(i + 1) % n] == ev.y else verts[(i + 1) % n]
			var o := CAGE.position(cage, rail_from)
			var d := CAGE.position(cage, rail_to) - o
			if id == "insert_edge":
				out.append({"key": "location", "origin": o, "direction": d, "min": 0.02, "max": 0.98})
			else:
				out.append({"key": "slide", "origin": o, "direction": d, "min": 0.0, "max": 1.0})
		"smooth":
			var groups := by_body(editor.tool_picks.get("faces", []))
			if groups.size() != 1:
				return out
			var body := str(groups.keys()[0])
			var cage: Dictionary = editor.cage_of(body)
			if cage.is_empty():
				return out
			var topo := CAGE.topology(cage)
			var centre := Vector3.ZERO
			var normal := Vector3.ZERO
			var count := 0
			for f in groups[body].faces:
				if f >= topo.nF:
					continue
				for v in topo.face_verts(f):
					centre += CAGE.position(cage, v)
					count += 1
				normal += topo.face_area_vector(cage, f)
			if count == 0 or normal.length() == 0.0:
				return out
			out.append({"key": "amount", "origin": centre / count, "direction": normal.normalized() * 2.0 * CAGE.mean_edge_length(cage), "min": 0.0, "max": 1.0})
	return out


## The sliders as editor handles (drawn and dragged by the editor; see form_tools.gd).
static func _slider_handles(editor: Object) -> Array:
	var out := []
	for s in sliders(editor):
		var handle: Dictionary = (s as Dictionary).duplicate()
		handle["type"] = "slider"
		out.append(handle)
	return out


static func handles_insert_edge(editor: Object, _values: Dictionary) -> Array:
	return _slider_handles(editor)


static func handles_slide_edge(editor: Object, _values: Dictionary) -> Array:
	return _slider_handles(editor)


static func handles_smooth(editor: Object, _values: Dictionary) -> Array:
	return _slider_handles(editor)


# --- Insert Point clicks ---------------------------------------------------------------------------

## The cage point under a screen position: {"body", "point": {"edge": Vector2i, "t"} or {"vertex"},
## "at": Vector3 (as drawn)} or {}. Within SNAP_PX of an edge's middle t is 0.5; of an end, the
## vertex.
static func edge_point(editor: Object, screen: Vector2) -> Dictionary:
	var pick: Dictionary = editor.pick_at(screen, ["edge", "vertex"])
	if pick.is_empty():
		return {}
	var body := str(pick.body)
	var viewport: Object = editor.viewport
	if str(pick.kind) == "vertex":
		return {"body": body, "point": {"vertex": int(pick.index)}, "at": pick.get("point", Vector3.ZERO)}
	var pair: Vector2i = pick.pair
	var line: PackedVector3Array = editor._edge_polyline(body, -1, pair)
	if line.size() < 2:
		return {}
	var cage: Dictionary = editor.cage_of(body)
	# The polyline runs from one end to the other; t counts from pair.x.
	var pa := CAGE.position(cage, pair.x)
	var pb := CAGE.position(cage, pair.y)
	var tess: Dictionary = editor.tess_of(body)
	var limits: PackedVector3Array = tess.get("vertices", PackedVector3Array())
	if limits.size() > maxi(pair.x, pair.y) and editor.display_mode(body) == "smooth":
		pa = limits[pair.x]
		pb = limits[pair.y]
	if line[0].distance_to(pb) < line[0].distance_to(pa):
		line.reverse()
	var lengths := PackedFloat64Array([0.0])
	for i in line.size() - 1:
		lengths.append(lengths[i] + line[i].distance_to(line[i + 1]))
	var total := lengths[lengths.size() - 1]
	if total <= 0.0:
		return {}
	var best := INF
	var best_s := 0.0
	var best_p := line[0]
	for i in line.size() - 1:
		var a: Vector2 = viewport.project(line[i])
		var b: Vector2 = viewport.project(line[i + 1])
		if not (a.is_finite() and b.is_finite()):
			continue
		var q := Geometry2D.get_closest_point_to_segment(screen, a, b)
		var dd := q.distance_to(screen)
		if dd < best:
			best = dd
			var f := (q - a).length() / maxf((b - a).length(), 1e-9)
			best_s = (lengths[i] + f * (lengths[i + 1] - lengths[i])) / total
			best_p = line[i].lerp(line[i + 1], f)
	var ends := [[0.0, pair.x], [1.0, pair.y]]
	for e in ends:
		var at: Vector2 = viewport.project(_along(line, lengths, float(e[0])))
		if at.is_finite() and at.distance_to(screen) <= SNAP_PX:
			return {"body": body, "point": {"vertex": int(e[1])}, "at": _along(line, lengths, float(e[0]))}
	var mid: Vector2 = viewport.project(_along(line, lengths, 0.5))
	if mid.is_finite() and mid.distance_to(screen) <= SNAP_PX:
		return {"body": body, "point": {"edge": pair, "t": 0.5}, "at": _along(line, lengths, 0.5), "snap": true}
	return {"body": body, "point": {"edge": pair, "t": clampf(best_s, 0.01, 0.99)}, "at": best_p}


static func _along(line: PackedVector3Array, lengths: PackedFloat64Array, s: float) -> Vector3:
	var total := lengths[lengths.size() - 1]
	var target := s * total
	for i in line.size() - 1:
		if lengths[i + 1] >= target:
			var span := lengths[i + 1] - lengths[i]
			return line[i].lerp(line[i + 1], (target - lengths[i]) / span if span > 0.0 else 0.0)
	return line[line.size() - 1]


## The faces a cage point touches (an edge's faces, or every face of a vertex).
static func _point_faces(topo: CAGE.Topo, pt: Dictionary) -> PackedInt32Array:
	if pt.has("vertex"):
		return topo.vertex_all_faces(int(pt.vertex))
	var ev: Vector2i = pt.edge
	var e := topo.edge_index(ev.x, ev.y)
	return topo.edge_faces(e) if e >= 0 else PackedInt32Array()


## Where a placed point is drawn.
static func _point_world(editor: Object, body: String, pt: Dictionary) -> Vector3:
	var cage: Dictionary = editor.cage_of(body)
	if cage.is_empty():
		return Vector3.INF
	if pt.has("vertex"):
		return CAGE.position(cage, int(pt.vertex))
	var ev: Vector2i = pt.edge
	return CAGE.position(cage, ev.x).lerp(CAGE.position(cage, ev.y), float(pt.get("t", 0.5)))


static func handle_mouse_insert_point(editor: Object, event: InputEvent) -> bool:
	var motion := event as InputEventMouseMotion
	if motion != null:
		editor.tool_state["hover_point"] = edge_point(editor, motion.position)
		return false
	var button := event as InputEventMouseButton
	if button == null or button.button_index != MOUSE_BUTTON_LEFT:
		return false
	if not button.pressed:
		return true
	var values: Dictionary = editor.tool_values
	var points := list_value(values, "points").duplicate(true)
	if button.double_click:
		if not points.is_empty():
			var tool_id := str(editor.tool)
			(func() -> void:
				if is_instance_valid(editor) and str(editor.tool) == tool_id:
					editor.tool_ok()).call_deferred()
		return true
	var hit := edge_point(editor, button.position)
	if hit.is_empty():
		return true
	var body := str(values.get("points_body", ""))
	if body != "" and body != str(hit.body):
		points = []
	if not points.is_empty():
		var topo := CAGE.topology(editor.cage_of(str(hit.body)))
		var shared := false
		for f in _point_faces(topo, points.back()):
			if _point_faces(topo, hit.point).has(f):
				shared = true
				break
		if not shared:
			editor.workspace.flash("Points must share a face")
			points.pop_back()
	points.append(hit.point)
	editor.set_tool_values({"points": points, "points_body": str(hit.body)})
	return true


static func draw_insert_point(editor: Object, overlay: Control) -> void:
	var c: Dictionary = editor.theme_colors
	var viewport: Object = editor.viewport
	var body := str(editor.tool_values.get("points_body", ""))
	var screen := PackedVector2Array()
	for pt in list_value(editor.tool_values, "points"):
		screen.append(viewport.project(_point_world(editor, body, pt)))
	for i in screen.size() - 1:
		if screen[i].is_finite() and screen[i + 1].is_finite():
			overlay.draw_dashed_line(screen[i], screen[i + 1], c.form_preview, 2.0, 6.0)
	for q in screen:
		if q.is_finite():
			overlay.draw_circle(q, 4.0, c.form_preview)
	var hover: Dictionary = editor.tool_state.get("hover_point", {})
	if not hover.is_empty():
		var at: Vector2 = viewport.project(hover.at)
		if at.is_finite():
			overlay.draw_circle(at, 3.0 if not bool(hover.get("snap", false)) else 3.0, c.form_preview)
			if bool(hover.get("snap", false)):
				overlay.draw_arc(at, 6.0, 0.0, TAU, 20, c.form_preview, 1.5, true)


# --- Edit By Curve: the curve and its control points -----------------------------------------------

## The tool's curve on the stored cage: {"body", "control", "edited", "plane"} or {}.
static func _curve_state(editor: Object) -> Dictionary:
	var groups := by_body(editor.tool_picks.get("edges", []))
	if groups.size() != 1:
		return {}
	var body := str(groups.keys()[0])
	var cage: Dictionary = editor.cage_of(body)
	if cage.is_empty():
		return {}
	var values: Dictionary = editor.evaluated_values()
	var opts := _curve_opts(values)
	if str(opts.fit) == "surface":
		# The curve runs through the limit points (as drawn on the surface).
		var limits: PackedVector3Array = (editor.tess_of(body) as Dictionary).get("vertices", PackedVector3Array())
		if limits.size() == CAGE.vertex_count(cage):
			var lp := PackedFloat64Array()
			for q in limits:
				lp.append_array(PackedFloat64Array([q.x, q.y, q.z]))
			opts["points"] = lp
	var curve := FORM_FIT.chain_curve(cage, groups[body].edges, opts)
	if curve.has("error"):
		return {}
	var edited := FORM_FIT.edited_control(curve.control, opts.offsets, opts.selected, opts.xf, curve.plane)
	return {"body": body, "control": curve.control, "edited": edited, "plane": curve.plane}


static func draw_edit_by_curve(editor: Object, overlay: Control) -> void:
	var state := _curve_state(editor)
	if state.is_empty():
		return
	var c: Dictionary = editor.theme_colors
	var viewport: Object = editor.viewport
	var edited: PackedFloat64Array = state.edited
	var line := PackedVector2Array()
	for i in 49:
		var q: Vector2 = viewport.project(FORM_FIT.bezier_point(edited, float(i) / 48.0))
		if q.is_finite():
			line.append(q)
	if line.size() > 1:
		overlay.draw_polyline(line, c.form_preview, 2.0, true)
	var hull := PackedVector2Array()
	var selected := PackedInt32Array(list_value(editor.tool_values, "curve_selected"))
	for k in edited.size() / 3:
		var at: Vector2 = viewport.project(Vector3(edited[3 * k], edited[3 * k + 1], edited[3 * k + 2]))
		hull.append(at)
		if not at.is_finite():
			continue
		var rect := Rect2(at - Vector2(4, 4), Vector2(8, 8))
		if selected.has(k):
			overlay.draw_rect(rect, c.handle, true)
		else:
			overlay.draw_rect(rect, c.handle_fill, true)
		overlay.draw_rect(rect, c.form_preview, false, 1.5)
	for i in hull.size() - 1:
		if hull[i].is_finite() and hull[i + 1].is_finite():
			overlay.draw_dashed_line(hull[i], hull[i + 1], Color(c.form_preview, 0.45), 1.0, 4.0)


## Control-point clicks and drags: a click picks a point (Shift adds or takes away), a drag moves
## the picked points in the view plane.
static func handle_mouse_edit_by_curve(editor: Object, event: InputEvent) -> bool:
	var button := event as InputEventMouseButton
	var motion := event as InputEventMouseMotion
	var tool_state: Dictionary = editor.tool_state
	var viewport: Object = editor.viewport
	if button != null and button.button_index == MOUSE_BUTTON_LEFT:
		if not button.pressed:
			if tool_state.has("curve_drag"):
				tool_state.erase("curve_drag")
				return true
			return false
		var state := _curve_state(editor)
		if state.is_empty():
			return false
		var edited: PackedFloat64Array = state.edited
		var hit := -1
		for k in edited.size() / 3:
			var at: Vector2 = viewport.project(Vector3(edited[3 * k], edited[3 * k + 1], edited[3 * k + 2]))
			if at.is_finite() and at.distance_to(button.position) <= GRAB_PX:
				hit = k
				break
		if hit < 0:
			return false
		var selected := PackedInt32Array(list_value(editor.tool_values, "curve_selected"))
		if button.shift_pressed:
			if selected.has(hit):
				selected.remove_at(selected.find(hit))
			else:
				selected.append(hit)
		elif not selected.has(hit):
			selected = PackedInt32Array([hit])
		var offsets := list_value(editor.tool_values, "curve_offsets").duplicate()
		var n := edited.size() / 3
		while offsets.size() < n:
			offsets.append(Vector3.ZERO)
		var origin := Vector3(edited[3 * hit], edited[3 * hit + 1], edited[3 * hit + 2])
		tool_state["curve_drag"] = {"origin": origin, "start": viewport.plane_hit(button.position, origin, -viewport.camera().global_transform.basis.z),
			"offsets": offsets, "selected": selected}
		editor.set_tool_values({"curve_selected": Array(selected)})
		return true
	if motion != null and tool_state.has("curve_drag"):
		var drag: Dictionary = tool_state.curve_drag
		var normal: Vector3 = -viewport.camera().global_transform.basis.z
		var now: Variant = viewport.plane_hit(motion.position, drag.origin, normal)
		if now == null or drag.start == null:
			return true
		var d: Vector3 = (now as Vector3) - (drag.start as Vector3)
		var offsets: Array = (drag.offsets as Array).duplicate()
		for k in drag.selected:
			if k < offsets.size():
				offsets[k] = (offsets[k] as Vector3) + d
		editor.set_tool_values({"curve_offsets": offsets})
		return true
	return false
