@tool
extends RefCounted
## Every Holo Forge tool, by workspace and menu group, with the phase that implements it.
## Tools from later phases are listed (so the toolbar shows the whole kit) but disabled.
##
## A tool is {"id", "name", "workspace", "group", "phase", "shortcut", "icon", "command", "action",
## "folder", "form"}: "command" is a feature command script, "action" a workspace action name,
## "folder" the family of like tools its group's dropdown nests it under ("" for none, see
## _FOLDERS), "form" a Form environment tool id (ui/form_tools.gd; enabled once registered there).

const IMPLEMENTED_PHASE := 8
## The Form tool registry (pure static scripts, so the catalog stays loadable headless): a Form
## tool is enabled once one of its registry scripts declares its id.
const FORM_TOOLS := preload("res://addons/holo_forge/ui/form_tools.gd")
const PRIMITIVE := "res://addons/holo_forge/tools/primitive_command.gd"
const FEATURE := "res://addons/holo_forge/tools/feature_command.gd"
const MEASURE := "res://addons/holo_forge/tools/measure_command.gd"
const INTERFERENCE := "res://addons/holo_forge/tools/interference_command.gd"
const MASS := "res://addons/holo_forge/tools/mass_command.gd"
const ANALYSIS := "res://addons/holo_forge/tools/analysis_command.gd"
const FASTENER := "res://addons/holo_forge/tools/fastener_command.gd"
const IMAGE := "res://addons/holo_forge/tools/image_command.gd"
const TEXTURE_MAP := "res://addons/holo_forge/tools/texture_map_command.gd"

## Phase 3 tools by name: a feature_specs key (run by the feature command) or "action:<name>".
const PHASE3 := {
	"New Component": "action:new_component", "Create Base Feature": "action:create_base_feature",
	"Extrude": "extrude", "Revolve": "revolve", "Sweep": "sweep", "Loft": "loft", "Rib": "rib", "Web": "web",
	"Emboss": "emboss", "Hole": "hole", "Thread": "thread", "Torus": "torus", "Coil": "coil", "Pipe": "pipe",
	"Rectangular Pattern": "rect_pattern", "Circular Pattern": "circ_pattern", "Pattern on Path": "path_pattern",
	"Mirror": "mirror", "Thicken": "thicken", "Boundary Fill": "boundary_fill",
	"Press Pull": "press_pull", "Fillet": "fillet", "Chamfer": "chamfer", "Shell": "shell", "Draft": "draft",
	"Scale": "scale", "Combine": "combine", "Offset Face": "offset_face", "Replace Face": "replace_face",
	"Split Face": "split_face", "Split Body": "split_body", "Silhouette Split": "silhouette_split",
	"Move/Copy": "move", "Align": "align",
	"Offset Plane": "plane:offset", "Plane at Angle": "plane:angle", "Tangent Plane": "plane:tangent",
	"Midplane": "plane:midplane", "Perpendicular Plane": "plane:perpendicular",
	"Plane Through Two Edges": "plane:two_edges", "Plane Through Three Points": "plane:three_points",
	"Plane Tangent to Face at Point": "plane:tangent_at_point", "Plane Along Path": "plane:along_path",
	"Axis Through Cylinder/Cone/Torus": "axis:cylinder", "Axis Perpendicular at Point": "axis:perp_at_point",
	"Axis Through Two Planes": "axis:two_planes", "Axis Through Two Points": "axis:two_points",
	"Axis Through Edge": "axis:edge", "Axis Perpendicular to Face at Point": "axis:perp_face_point",
	"Point at Vertex": "point:vertex", "Point Through Two Edges": "point:two_edges",
	"Point Through Three Planes": "point:three_planes", "Point at Center of Circle/Sphere/Torus": "point:center",
	"Point at Edge and Plane": "point:edge_plane", "Point Along Path": "point:along_path",
}

## Phase 4 tools by name: [command script, tool type] or "action:<name>". Analysis, Canvas,
## Decal and Texture Map Controls types carry a prefix ("analysis:", "insert:", "appearance:") so
## they never match a feature type when a feature is edited; Insert Fastener's type is its
## feature's, so the timeline edits it.
const PHASE4 := {
	"Insert Derive": "action:insert_derive", "Derive": "action:insert_derive", "Insert Component": "action:insert_component",
	"Insert Fastener": [FASTENER, "fastener"], "Decal": [IMAGE, "insert:decal"], "Canvas": [IMAGE, "insert:canvas"],
	"Insert Mesh": "action:insert_mesh", "Insert SVG": "action:insert_svg", "Insert DXF": "action:insert_dxf",
	"Insert STEP/IGES": "action:insert_step",
	"Export STEP": "action:export_step", "Export IGES": "action:export_iges", "Export STL": "action:export_stl",
	"Export Components": "action:export_components", "Export Body Meshes": "action:export_body_meshes",
	"Save Board Model Version": "action:save_board_model",
	"Measure": [MEASURE, "inspect:measure"], "Interference": [INTERFERENCE, "inspect:interference"],
	"Center of Mass": [MASS, "inspect:center_of_mass"], "Physical Material": [MASS, "inspect:physical_material"],
	"Curvature Comb Analysis": [ANALYSIS, "analysis:curvature_comb"], "Zebra Analysis": [ANALYSIS, "analysis:zebra"],
	"Draft Analysis": [ANALYSIS, "analysis:draft"], "Curvature Map Analysis": [ANALYSIS, "analysis:curvature_map"],
	"Isocurve Analysis": [ANALYSIS, "analysis:isocurve"], "Environment Map": [ANALYSIS, "analysis:environment_map"],
	"Accessibility Analysis": [ANALYSIS, "analysis:accessibility"], "Minimum Radius Analysis": [ANALYSIS, "analysis:minimum_radius"],
	"Section Analysis": [ANALYSIS, "analysis:section"],
	"Display Component Colors": "action:toggle_component_colors", "Appearance": "action:appearance",
	"Manage Materials": "action:manage_materials", "Texture Map Controls": [TEXTURE_MAP, "appearance:texture_map"],
}

## Phase 5 (the Surface workspace) by name: a feature_specs key. Its own tools are "surface:"
## features; the rest are the solid features, which take surface bodies too. Its Press Pull
## extrudes a profile into a surface ("press_pull:surface", tools/feature_command.gd).
const PHASE5 := {
	"Extrude": "surface:extrude", "Revolve": "surface:revolve", "Sweep": "surface:sweep", "Loft": "surface:loft",
	"Coil": "surface:coil", "Patch": "surface:patch", "Ruled": "surface:ruled", "Offset": "surface:offset",
	"Thicken": "thicken", "Boundary Fill": "boundary_fill", "Rectangular Pattern": "rect_pattern",
	"Circular Pattern": "circ_pattern", "Pattern on Path": "path_pattern", "Mirror": "mirror",
	"Press Pull": "press_pull:surface", "Fillet": "fillet", "Chamfer": "chamfer", "Trim": "surface:trim",
	"Untrim": "surface:untrim", "Extend": "surface:extend", "Stitch": "surface:stitch", "Unstitch": "surface:unstitch",
	"Merge": "surface:merge", "Reverse Normal": "surface:reverse_normal", "Scale": "scale", "Replace Face": "replace_face",
	"Split Face": "split_face", "Split Body": "split_body", "Move/Copy": "move", "Align": "align",
}

## Phase 6 (the Form environment) by name: the Form tool id each toolbar entry runs. Stage 2
## registers the primitives, Edit Form, Display Mode, Crease / UnCrease, Freeze / Unfreeze and Clear
## Symmetry; the rest stay greyed until their registry entries land.
const PHASE6 := {
	"Box": "box", "Plane": "plane", "Cylinder": "cylinder", "Sphere": "sphere", "Torus": "torus", "Quadball": "quadball",
	"Pipe": "pipe", "Face": "face", "Extrude": "extrude", "Revolve": "revolve", "Sweep": "sweep", "Loft": "loft",
	"Edit Form": "edit_form", "Edit By Curve": "edit_by_curve", "Insert Edge": "insert_edge", "Subdivide": "subdivide",
	"Insert Point": "insert_point", "Merge Edge": "merge_edge", "Bridge": "bridge", "Fill Hole": "fill_hole",
	"Erase and Fill": "erase_and_fill", "Weld Vertices": "weld_vertices", "UnWeld Edges": "unweld_edges",
	"Crease": "crease", "UnCrease": "uncrease", "Bevel Edge": "bevel_edge", "Slide Edge": "slide_edge",
	"Smooth": "smooth", "Cylindrify": "cylindrify", "Pull": "pull", "Flatten": "flatten", "Straighten": "straighten",
	"Match": "match", "Interpolate": "interpolate", "Thicken": "thicken", "Freeze": "freeze", "Unfreeze": "unfreeze",
	"Mirror - Internal": "mirror_internal", "Circular - Internal": "circular_internal",
	"Mirror - Duplicate": "mirror_duplicate", "Circular - Duplicate": "circular_duplicate",
	"Clear Symmetry": "clear_symmetry", "Isolate Symmetry": "isolate_symmetry",
	"Display Mode": "display_mode", "Repair Body": "repair_body", "Make Uniform": "make_uniform", "Convert": "convert",
}

## Phase 7 (the Mesh workspace) by name: a "mesh:<method>" feature_specs key (run by the feature
## command) or "action:<name>".
const PHASE7 := {
	"Tessellate": "mesh:tessellate", "Create Mesh Section Sketch": "mesh:section_sketch", "Close Holes": "mesh:close_holes",
	"Stitch and Remove": "mesh:stitch_remove", "Wrap": "mesh:wrap", "Rebuild": "mesh:rebuild",
	"Generate Face Groups": "mesh:generate_groups", "Combine Face Groups": "mesh:combine_groups",
	"Create Face Group": "mesh:create_group", "Direct Edit": "action:mesh_direct_edit", "Remesh": "mesh:remesh",
	"Reduce": "mesh:reduce", "Plane Cut": "mesh:plane_cut", "Shell": "mesh:shell", "Combine": "mesh:combine",
	"Smooth": "mesh:smooth", "Reverse Normal": "mesh:reverse_normal", "Erase and Fill": "mesh:erase_fill",
	"Mesh Align": "mesh:align", "Texture Extrude": "mesh:texture_extrude", "Separate": "mesh:separate",
	"Move/Copy": "mesh:move", "Scale Mesh": "mesh:scale", "Convert Mesh: Faceted": "mesh:convert_faceted",
	"Convert Mesh: Prismatic": "mesh:convert_prismatic", "Convert Mesh: Organic": "mesh:convert_organic",
	"Insert Mesh": "action:insert_mesh_body", "Display Mesh Face Groups": "action:mesh_face_groups",
}

## Phase 8 (Assemble) by name: [command script, tool type] or "action:<name>". The tools make no
## timeline feature (tools/assemble_command.gd); their types carry the "assemble:" prefix so they
## never match a feature type. Place Component and Contact Settings run from the browser only
## (assemble:place, assemble:contact_settings); Motion Study opens its floating panel.
const ASSEMBLE_JOINT := "res://addons/holo_forge/tools/assemble_joint_command.gd"
const PHASE8 := {
	"Joint": [ASSEMBLE_JOINT, "assemble:joint"], "As-built Joint": [ASSEMBLE_JOINT, "assemble:as_built_joint"],
	"Joint Origin": ["res://addons/holo_forge/tools/assemble_origin_command.gd", "assemble:joint_origin"],
	"Rigid Group": ["res://addons/holo_forge/tools/assemble_rigid_group_command.gd", "assemble:rigid_group"],
	"Drive Joints": ["res://addons/holo_forge/tools/assemble_drive_command.gd", "assemble:drive"],
	"Motion Link": ["res://addons/holo_forge/tools/assemble_link_command.gd", "assemble:motion_link"],
	"Enable Contact Sets": "action:toggle_contact_sets", "Motion Study": "action:motion_study",
}

const WORKSPACES := ["Solid", "Surface", "Mesh", "Form", "Sheet Metal", "Plastic", "Utilities"]

const _SHARED_ASSEMBLE := [
	["New Component", 3], ["Joint", 8, {"shortcut": "J"}], ["As-built Joint", 8], ["Joint Origin", 8], ["Rigid Group", 8],
	["Drive Joints", 8], ["Motion Link", 8], ["Enable Contact Sets", 8], ["Motion Study", 8],
]
const _SHARED_CONSTRUCT := [
	["Offset Plane", 3], ["Plane at Angle", 3], ["Tangent Plane", 3], ["Midplane", 3], ["Perpendicular Plane", 3],
	["Plane Through Two Edges", 3], ["Plane Through Three Points", 3], ["Plane Tangent to Face at Point", 3], ["Plane Along Path", 3],
	["Axis Through Cylinder/Cone/Torus", 3], ["Axis Perpendicular at Point", 3], ["Axis Through Two Planes", 3],
	["Axis Through Two Points", 3], ["Axis Through Edge", 3], ["Axis Perpendicular to Face at Point", 3],
	["Point at Vertex", 3], ["Point Through Two Edges", 3], ["Point Through Three Planes", 3],
	["Point at Center of Circle/Sphere/Torus", 3], ["Point at Edge and Plane", 3], ["Point Along Path", 3],
]
const _SHARED_INSPECT := [
	["Measure", 4, {"shortcut": "I"}], ["Interference", 4], ["Curvature Comb Analysis", 4], ["Zebra Analysis", 4],
	["Draft Analysis", 4], ["Curvature Map Analysis", 4], ["Isocurve Analysis", 4], ["Environment Map", 4],
	["Accessibility Analysis", 4], ["Minimum Radius Analysis", 4], ["Section Analysis", 4], ["Center of Mass", 4],
	["Display Component Colors", 4],
]
const _SHARED_INSERT := [
	["Insert Derive", 4], ["Insert Component", 4], ["Insert Fastener", 4], ["Decal", 4], ["Canvas", 4],
	["Insert Mesh", 4], ["Insert SVG", 4], ["Insert DXF", 4], ["Insert STEP/IGES", 4],
]
const _SHARED_SELECT := [
	["Window Selection", 1, {"action": "select_mode_window"}], ["Freeform Selection", 1, {"action": "select_mode_freeform"}],
	["Paint Selection", 1, {"action": "select_mode_paint"}], ["Select All", 1, {"action": "select_all"}],
	["Invert Selection", 1, {"action": "invert_selection"}], ["Clear Selection", 1, {"action": "clear_selection"}],
	["Create Selection Set", 1, {"action": "create_selection_set"}],
]
## The Mesh workspace's Select group: the shared tools, then the two pick modes (face groups or
## triangles) and the helpers that change a triangle selection.
const _MESH_SELECT := _SHARED_SELECT + [
	["Select Face Groups", 7, {"action": "mesh_pick_groups"}], ["Select Triangles", 7, {"action": "mesh_pick_triangles"}],
	["Grow Selection", 7, {"action": "mesh_grow"}], ["Shrink Selection", 7, {"action": "mesh_shrink"}],
	["Select Connected", 7, {"action": "mesh_connected"}], ["Select Boundary", 7, {"action": "mesh_boundary"}],
]

## The contextual Sketch toolbar shown while a sketch is being edited.
const SKETCH_WORKSPACE := "Sketch"
const _SKETCH_GROUPS := {
	"Create": [
		["Line", 2, {"sketch": "line", "shortcut": "L"}], ["Centerline", 2, {"sketch": "centerline"}],
		["2-Point Rectangle", 2, {"sketch": "rect_2pt", "shortcut": "R"}], ["3-Point Rectangle", 2, {"sketch": "rect_3pt"}],
		["Center Rectangle", 2, {"sketch": "rect_center"}], ["Center Diameter Circle", 2, {"sketch": "circle_center", "shortcut": "C"}],
		["2-Point Circle", 2, {"sketch": "circle_2pt"}], ["3-Point Circle", 2, {"sketch": "circle_3pt"}],
		["2-Tangent Circle", 2, {"sketch": "circle_2tan"}], ["3-Tangent Circle", 2, {"sketch": "circle_3tan"}],
		["3-Point Arc", 2, {"sketch": "arc_3pt"}], ["Center Point Arc", 2, {"sketch": "arc_center"}], ["Tangent Arc", 2, {"sketch": "arc_tangent"}],
		["Circumscribed Polygon", 2, {"sketch": "polygon_circumscribed"}], ["Inscribed Polygon", 2, {"sketch": "polygon_inscribed"}],
		["Edge Polygon", 2, {"sketch": "polygon_edge"}], ["Ellipse", 2, {"sketch": "ellipse"}],
		["Center to Center Slot", 2, {"sketch": "slot_cc"}], ["Overall Slot", 2, {"sketch": "slot_overall"}],
		["Center Point Slot", 2, {"sketch": "slot_center"}], ["Three Point Arc Slot", 2, {"sketch": "slot_3pt_arc"}],
		["Center Point Arc Slot", 2, {"sketch": "slot_center_arc"}], ["Fit Point Spline", 2, {"sketch": "spline_fit"}],
		["Control Point Spline", 2, {"sketch": "spline_control"}], ["Conic Curve", 2, {"sketch": "conic"}], ["Point", 2, {"sketch": "point"}],
		["Text", 2, {"sketch": "text"}], ["Text on Path", 2, {"sketch": "text_on_path"}], ["Mirror", 2, {"sketch": "mirror"}],
		["Circular Pattern", 2, {"sketch": "circ_pattern"}], ["Rectangular Pattern", 2, {"sketch": "rect_pattern"}],
		["Project", 2, {"sketch": "project", "shortcut": "P"}], ["Intersect", 2, {"sketch": "intersect"}],
		["Include 3D Geometry", 2, {"sketch": "include3d"}], ["Project To Surface", 2, {"sketch": "project_surface"}],
		["Intersection Curve", 2, {"sketch": "intersection_curve"}], ["Isoparametric Curve", 2, {"sketch": "isocurve"}],
		["Spun Profile", 2, {"sketch": "spun_profile"}], ["Sketch Dimension", 2, {"sketch": "dimension", "shortcut": "D"}],
	],
	"Modify": [
		["Fillet", 2, {"sketch": "fillet"}], ["Chamfer (Equal Distance)", 2, {"sketch": "chamfer_equal"}],
		["Chamfer (Distance and Angle)", 2, {"sketch": "chamfer_angle"}], ["Chamfer (Two Distance)", 2, {"sketch": "chamfer_two"}],
		["Trim", 2, {"sketch": "trim", "shortcut": "T"}], ["Extend", 2, {"sketch": "extend"}], ["Break", 2, {"sketch": "break"}],
		["Offset", 2, {"sketch": "offset", "shortcut": "O"}], ["Blend Curve (G1)", 2, {"sketch": "blend_g1"}],
		["Blend Curve (G2)", 2, {"sketch": "blend_g2"}], ["Sketch Scale", 2, {"sketch": "sketch_scale"}],
		["Move/Copy", 2, {"sketch": "move_copy", "shortcut": "M"}], ["Explode Text", 2, {"action": "explode_text"}],
		["Construction", 2, {"action": "toggle_construction", "shortcut": "X"}], ["Fully Define", 2, {"action": "fully_define"}],
		["Delete", 1, {"action": "delete", "icon": "Remove"}],
		["Change Parameters", 1, {"action": "change_parameters", "icon": "EditorProperties"}],
	],
	"Constraints": [
		["Horizontal/Vertical", 2, {"sketch": "constraint:horizontal_vertical"}], ["Coincident", 2, {"sketch": "constraint:coincident"}],
		["Tangent", 2, {"sketch": "constraint:tangent"}], ["Equal", 2, {"sketch": "constraint:equal"}],
		["Parallel", 2, {"sketch": "constraint:parallel"}], ["Perpendicular", 2, {"sketch": "constraint:perpendicular"}],
		["Fix/UnFix", 2, {"sketch": "constraint:fix"}], ["Midpoint", 2, {"sketch": "constraint:midpoint"}],
		["Concentric", 2, {"sketch": "constraint:concentric"}], ["Collinear", 2, {"sketch": "constraint:collinear"}],
		["Symmetry", 2, {"sketch": "constraint:symmetric"}], ["Curvature", 2, {"sketch": "constraint:curvature"}],
	],
	"Inspect": [["Measure", 4, {"shortcut": "I"}], ["Curvature Comb Analysis", 4]],
	"Insert": [["Insert SVG", 4], ["Insert DXF", 4], ["Canvas", 4]],
	"Select": [
		["Window Selection", 1, {"action": "select_mode_window"}], ["Freeform Selection", 1, {"action": "select_mode_freeform"}],
		["Clear Selection", 1, {"action": "clear_selection"}],
	],
	"Finish": [["Finish Sketch", 2, {"action": "finish_sketch", "icon": "ImportCheck"}]],
}

const _GROUPS := {
	"Solid": {
		"Create": [
			["New Component", 3], ["Create Sketch", 2, {"action": "create_sketch", "icon": "Path2D"}], ["Extrude", 3, {"shortcut": "E"}], ["Revolve", 3], ["Sweep", 3],
			["Loft", 3], ["Rib", 3], ["Web", 3], ["Emboss", 3], ["Hole", 3, {"shortcut": "H"}], ["Thread", 3],
			["Box", 1, {"command": PRIMITIVE, "type": "box", "icon": "BoxMesh"}],
			["Cylinder", 1, {"command": PRIMITIVE, "type": "cylinder", "icon": "CylinderMesh"}],
			["Sphere", 1, {"command": PRIMITIVE, "type": "sphere", "icon": "SphereMesh"}],
			["Torus", 3], ["Coil", 3], ["Pipe", 3], ["Rectangular Pattern", 3], ["Circular Pattern", 3],
			["Pattern on Path", 3], ["Mirror", 3], ["Thicken", 3], ["Boundary Fill", 3], ["Create Base Feature", 3],
			["Create Form", 6, {"action": "create_form"}], ["Derive", 4, {"icon": "PackedScene"}],
		],
		"Modify": [
			["Press Pull", 3, {"shortcut": "Q"}], ["Fillet", 3, {"shortcut": "F"}], ["Chamfer", 3], ["Shell", 3], ["Draft", 3],
			["Scale", 3], ["Combine", 3], ["Offset Face", 3], ["Replace Face", 3], ["Split Face", 3], ["Split Body", 3],
			["Silhouette Split", 3], ["Move/Copy", 3, {"shortcut": "M"}], ["Align", 3],
			["Delete", 1, {"action": "delete", "icon": "Remove"}], ["Physical Material", 4], ["Appearance", 4, {"shortcut": "A"}],
			["Texture Map Controls", 4], ["Manage Materials", 4], ["Change Parameters", 1, {"action": "change_parameters", "icon": "EditorProperties"}],
			["Compute All", 1, {"action": "compute_all", "icon": "Reload"}],
		],
		"Assemble": _SHARED_ASSEMBLE, "Construct": _SHARED_CONSTRUCT, "Inspect": _SHARED_INSPECT,
		"Insert": _SHARED_INSERT, "Select": _SHARED_SELECT,
	},
	"Surface": {
		"Create": [
			["New Component", 3], ["Create Sketch", 2, {"action": "create_sketch", "icon": "Path2D"}], ["Extrude", 5, {"shortcut": "E"}],
			["Revolve", 5], ["Sweep", 5], ["Loft", 5], ["Coil", 5], ["Patch", 5], ["Ruled", 5], ["Offset", 5], ["Thicken", 5],
			["Boundary Fill", 5], ["Rectangular Pattern", 5], ["Circular Pattern", 5], ["Pattern on Path", 5], ["Mirror", 5],
		],
		"Modify": [
			["Press Pull", 5, {"shortcut": "Q"}], ["Fillet", 5, {"shortcut": "F"}], ["Chamfer", 5], ["Trim", 5], ["Untrim", 5],
			["Extend", 5], ["Stitch", 5], ["Unstitch", 5], ["Merge", 5], ["Reverse Normal", 5], ["Scale", 5], ["Replace Face", 5],
			["Split Face", 5], ["Split Body", 5], ["Move/Copy", 5, {"shortcut": "M"}], ["Align", 5],
			["Delete", 1, {"action": "delete", "icon": "Remove"}], ["Physical Material", 4], ["Appearance", 4, {"shortcut": "A"}],
			["Texture Map Controls", 4], ["Manage Materials", 4],
			["Change Parameters", 1, {"action": "change_parameters", "icon": "EditorProperties"}],
			["Compute All", 1, {"action": "compute_all", "icon": "Reload"}],
		],
		"Assemble": _SHARED_ASSEMBLE, "Construct": _SHARED_CONSTRUCT, "Inspect": _SHARED_INSPECT,
		"Insert": _SHARED_INSERT, "Select": _SHARED_SELECT,
	},
	"Mesh": {
		"Create": [["Insert Mesh", 7], ["Tessellate", 7], ["Create Mesh Section Sketch", 7]],
		"Prepare": [
			["Close Holes", 7], ["Stitch and Remove", 7], ["Wrap", 7], ["Rebuild", 7], ["Generate Face Groups", 7],
			["Combine Face Groups", 7], ["Create Face Group", 7],
		],
		"Modify": [
			["Direct Edit", 7], ["Remesh", 7], ["Reduce", 7], ["Plane Cut", 7], ["Shell", 7], ["Combine", 7], ["Smooth", 7],
			["Reverse Normal", 7], ["Erase and Fill", 7], ["Mesh Align", 7], ["Texture Extrude", 7], ["Separate", 7],
			["Move/Copy", 7], ["Scale Mesh", 7], ["Delete", 1, {"action": "delete", "icon": "Remove"}],
			["Convert Mesh: Faceted", 7], ["Convert Mesh: Prismatic", 7], ["Convert Mesh: Organic", 7],
		],
		"Assemble": _SHARED_ASSEMBLE, "Construct": _SHARED_CONSTRUCT, "Inspect": _SHARED_INSPECT,
		"Insert": _SHARED_INSERT, "Select": _MESH_SELECT,
	},
	"Form": {
		"Create": [
			["Create Sketch", 2, {"action": "create_sketch", "icon": "Path2D"}], ["Box", 6], ["Plane", 6], ["Cylinder", 6], ["Sphere", 6], ["Torus", 6], ["Quadball", 6], ["Pipe", 6],
			["Face", 6], ["Extrude", 6], ["Revolve", 6], ["Sweep", 6], ["Loft", 6],
		],
		"Modify": [
			["Edit Form", 6], ["Edit By Curve", 6], ["Insert Edge", 6], ["Subdivide", 6], ["Insert Point", 6],
			["Merge Edge", 6], ["Bridge", 6], ["Fill Hole", 6], ["Erase and Fill", 6], ["Weld Vertices", 6],
			["UnWeld Edges", 6], ["Crease", 6], ["UnCrease", 6], ["Bevel Edge", 6], ["Slide Edge", 6], ["Smooth", 6],
			["Cylindrify", 6], ["Pull", 6], ["Flatten", 6], ["Straighten", 6], ["Match", 6], ["Interpolate", 6],
			["Thicken", 6], ["Freeze", 6], ["Unfreeze", 6],
		],
		"Symmetry": [
			["Mirror - Internal", 6], ["Circular - Internal", 6], ["Mirror - Duplicate", 6], ["Circular - Duplicate", 6],
			["Clear Symmetry", 6], ["Isolate Symmetry", 6],
		],
		"Utilities": [["Display Mode", 6], ["Repair Body", 6], ["Make Uniform", 6], ["Convert", 6]],
		"Construct": _SHARED_CONSTRUCT, "Inspect": _SHARED_INSPECT, "Insert": _SHARED_INSERT,
		"Select": [
			["Window Selection", 1, {"action": "select_mode_window"}], ["Freeform Selection", 1, {"action": "select_mode_freeform"}],
			["Paint Selection", 1, {"action": "select_mode_paint"}], ["Select All", 1, {"action": "select_all"}],
			["Invert Selection", 1, {"action": "invert_selection"}], ["Clear Selection", 1, {"action": "clear_selection"}],
			["Create Selection Set", 1, {"action": "create_selection_set"}],
			["Select Loop", 6, {"action": "form_select_loop", "icon": "Loop"}],
			["Select Ring", 6, {"action": "form_select_ring", "icon": "RotateRight"}],
			["Grow Selection", 6, {"action": "form_select_grow", "icon": "ZoomMore"}],
			["Shrink Selection", 6, {"action": "form_select_shrink", "icon": "ZoomLess"}],
			["Select Range", 6, {"action": "form_select_range", "icon": "ExpandTree"}],
			["Feature Selection", 6, {"action": "form_select_feature", "icon": "Groups"}],
		],
		"Finish": [["Finish Form", 6, {"action": "finish_form"}]],
	},
	"Sheet Metal": {
		"Create": [
			["Create Sketch", 2, {"action": "create_sketch", "icon": "Path2D"}], ["Flange", 9], ["Bend", 9], ["Rip", 9], ["Unfold", 9], ["Refold", 9],
			["Create Flat Pattern", 9], ["Convert to Sheet Metal", 9], ["Extrude", 3], ["Hole", 3],
			["Rectangular Pattern", 3], ["Mirror", 3],
		],
		"Modify": [
			["Sheet Metal Rules", 9], ["Press Pull", 3], ["Fillet", 3], ["Chamfer", 3], ["Move/Copy", 3],
			["Delete", 1, {"action": "delete", "icon": "Remove"}],
			["Change Parameters", 1, {"action": "change_parameters", "icon": "EditorProperties"}],
		],
		"Assemble": _SHARED_ASSEMBLE, "Construct": _SHARED_CONSTRUCT, "Inspect": _SHARED_INSPECT,
		"Insert": _SHARED_INSERT, "Select": _SHARED_SELECT,
	},
	"Plastic": {
		"Create": [
			["Plastic Rules", 9], ["Boss", 9], ["Snap Fit", 9], ["Lip", 9], ["Groove", 9], ["Lip and Groove", 9],
			["Rest", 9], ["Rib", 3], ["Web", 3],
		],
		"Modify": [
			["Shell", 3], ["Draft", 3], ["Fillet", 3], ["Delete", 1, {"action": "delete", "icon": "Remove"}],
			["Change Parameters", 1, {"action": "change_parameters", "icon": "EditorProperties"}],
		],
		"Assemble": _SHARED_ASSEMBLE, "Construct": _SHARED_CONSTRUCT, "Inspect": _SHARED_INSPECT,
		"Insert": _SHARED_INSERT, "Select": _SHARED_SELECT,
	},
	"Utilities": {
		"Utility": [
			["Change Parameters", 1, {"action": "change_parameters", "icon": "EditorProperties"}],
			["Compute All", 1, {"action": "compute_all", "icon": "Reload"}],
			["Export .glb", 1, {"action": "export_glb", "icon": "Save"}], ["Export STEP", 4], ["Export IGES", 4], ["Export STL", 4],
			["Export Components", 4], ["Export Body Meshes", 4], ["Save Board Model Version", 4],
			["Physical Material", 4], ["Appearance", 4], ["Texture Map Controls", 4],
		],
		"Display": [["Display Component Colors", 4], ["Display Mesh Face Groups", 7, {"shortcut": "Shift+F"}], ["Dark Mode", 1, {"action": "theme"}]],
		"Inspect": _SHARED_INSPECT, "Select": _SHARED_SELECT,
	},
}

## Families of like tools that a group's dropdown shows as one submenu each, with their tools in
## the order given here: workspace -> group -> [[folder, [tool names]]]. "*" is for the shared
## Assemble, Construct, Inspect and Insert groups of every workspace but Sketch. A spec's own
## "folder" extra overrides these.
const _FOLDERS := {
	"*": {
		"Assemble": [["Motion", ["Drive Joints", "Motion Link", "Enable Contact Sets", "Motion Study"]]],
		"Construct": [
			["Plane", ["Offset Plane", "Plane at Angle", "Tangent Plane", "Midplane", "Perpendicular Plane",
				"Plane Through Two Edges", "Plane Through Three Points", "Plane Tangent to Face at Point", "Plane Along Path"]],
			["Axis", ["Axis Through Cylinder/Cone/Torus", "Axis Perpendicular at Point", "Axis Through Two Planes",
				"Axis Through Two Points", "Axis Through Edge", "Axis Perpendicular to Face at Point"]],
			["Point", ["Point at Vertex", "Point Through Two Edges", "Point Through Three Planes",
				"Point at Center of Circle/Sphere/Torus", "Point at Edge and Plane", "Point Along Path"]],
		],
		"Inspect": [["Analysis", ["Curvature Comb Analysis", "Zebra Analysis", "Draft Analysis", "Curvature Map Analysis",
			"Isocurve Analysis", "Accessibility Analysis", "Minimum Radius Analysis", "Environment Map"]]],
		"Insert": [["Import", ["Insert Mesh", "Insert SVG", "Insert DXF", "Insert STEP/IGES"]], ["Images", ["Decal", "Canvas"]]],
	},
	"Sketch": {
		"Create": [
			["Rectangle", ["2-Point Rectangle", "3-Point Rectangle", "Center Rectangle"]],
			["Circle", ["Center Diameter Circle", "2-Point Circle", "3-Point Circle", "2-Tangent Circle", "3-Tangent Circle"]],
			["Arc", ["3-Point Arc", "Center Point Arc", "Tangent Arc"]],
			["Polygon", ["Circumscribed Polygon", "Inscribed Polygon", "Edge Polygon"]],
			["Slot", ["Center to Center Slot", "Overall Slot", "Center Point Slot", "Three Point Arc Slot", "Center Point Arc Slot"]],
			["Spline", ["Fit Point Spline", "Control Point Spline"]],
			["Text", ["Text", "Text on Path"]],
			["Pattern", ["Circular Pattern", "Rectangular Pattern"]],
			["Project / Include", ["Project", "Intersect", "Include 3D Geometry", "Project To Surface", "Intersection Curve",
				"Isoparametric Curve", "Spun Profile"]],
		],
		"Modify": [
			["Chamfer", ["Chamfer (Equal Distance)", "Chamfer (Distance and Angle)", "Chamfer (Two Distance)"]],
			["Blend Curve", ["Blend Curve (G1)", "Blend Curve (G2)"]],
		],
	},
	"Solid": {
		"Create": [["Pattern", ["Rectangular Pattern", "Circular Pattern", "Pattern on Path"]]],
		"Modify": [
			["Split", ["Split Face", "Split Body", "Silhouette Split"]],
			["Materials", ["Physical Material", "Appearance", "Texture Map Controls", "Manage Materials"]],
		],
	},
	"Surface": {
		"Create": [["Pattern", ["Rectangular Pattern", "Circular Pattern", "Pattern on Path"]]],
		"Modify": [
			["Split", ["Split Face", "Split Body"]],
			["Materials", ["Physical Material", "Appearance", "Texture Map Controls", "Manage Materials"]],
		],
	},
	"Mesh": {
		"Prepare": [
			["Repair", ["Close Holes", "Stitch and Remove", "Wrap", "Rebuild"]],
			["Face Groups", ["Generate Face Groups", "Combine Face Groups", "Create Face Group"]],
		],
		"Modify": [["Convert Mesh", ["Convert Mesh: Faceted", "Convert Mesh: Prismatic", "Convert Mesh: Organic"]]],
	},
	"Form": {
		"Create": [["Primitives", ["Box", "Plane", "Cylinder", "Sphere", "Torus", "Quadball"]]],
		"Modify": [
			["Edges", ["Insert Edge", "Merge Edge", "Bridge", "Weld Vertices", "UnWeld Edges", "Crease", "UnCrease",
				"Bevel Edge", "Slide Edge"]],
			["Shape", ["Cylindrify", "Pull", "Flatten", "Straighten", "Match", "Interpolate"]],
			["Freeze", ["Freeze", "Unfreeze"]],
		],
	},
	"Sheet Metal": {"Create": [["Flat Pattern", ["Unfold", "Refold", "Create Flat Pattern"]]]},
	"Plastic": {"Create": [["Lips and Grooves", ["Lip", "Groove", "Lip and Groove"]], ["Ribs", ["Rib", "Web"]]]},
	"Utilities": {
		"Utility": [
			["Export", ["Export .glb", "Export STEP", "Export IGES", "Export STL", "Export Components", "Export Body Meshes"]],
			["Materials", ["Physical Material", "Appearance", "Texture Map Controls"]],
		],
	},
}

## The tools pinned to the bar as icons until the user changes them: workspace -> group -> [tool
## names]. A group not listed for a workspace (other than Sketch) takes _SHARED_PINS.
const _DEFAULT_PINS := {
	"Solid": {
		"Create": ["Create Sketch", "Extrude", "Revolve", "Sweep", "Loft", "Hole", "Box"],
		"Modify": ["Press Pull", "Fillet", "Chamfer", "Shell", "Combine", "Move/Copy"],
	},
	"Surface": {
		"Create": ["Create Sketch", "Extrude", "Revolve", "Sweep", "Loft", "Patch", "Offset"],
		"Modify": ["Trim", "Untrim", "Extend", "Stitch", "Unstitch", "Reverse Normal"],
	},
	"Mesh": {
		"Create": ["Insert Mesh", "Tessellate"], "Prepare": ["Close Holes", "Generate Face Groups"],
		"Modify": ["Remesh", "Reduce", "Plane Cut", "Smooth"],
	},
	"Form": {
		"Create": ["Box", "Sphere", "Extrude", "Revolve", "Loft"], "Modify": ["Edit Form", "Insert Edge", "Subdivide", "Crease"],
		"Symmetry": ["Mirror - Internal", "Clear Symmetry"], "Utilities": ["Repair Body", "Convert"],
		"Finish": ["Finish Form"],
	},
	"Sheet Metal": {
		"Create": ["Create Sketch", "Flange", "Bend", "Unfold", "Create Flat Pattern"],
		"Modify": ["Sheet Metal Rules", "Press Pull", "Fillet"],
	},
	"Plastic": {"Create": ["Plastic Rules", "Boss", "Snap Fit", "Rib"], "Modify": ["Shell", "Draft", "Fillet"]},
	"Utilities": {
		"Utility": ["Change Parameters", "Compute All", "Export .glb", "Export STEP", "Save Board Model Version"],
		"Display": ["Display Component Colors", "Dark Mode"],
	},
	"Sketch": {
		"Create": ["Line", "2-Point Rectangle", "Center Diameter Circle", "3-Point Arc", "Inscribed Polygon", "Fit Point Spline",
			"Project", "Sketch Dimension"],
		"Modify": ["Fillet", "Trim", "Extend", "Offset", "Move/Copy"],
		"Constraints": ["Horizontal/Vertical", "Coincident", "Tangent", "Equal", "Parallel", "Perpendicular", "Fix/UnFix",
			"Midpoint", "Concentric", "Collinear", "Symmetry", "Curvature"],
		"Inspect": ["Measure"], "Insert": ["Canvas"], "Select": ["Window Selection"], "Finish": ["Finish Sketch"],
	},
}
const _SHARED_PINS := {
	"Assemble": ["New Component", "Joint"], "Construct": ["Offset Plane", "Midplane", "Axis Through Cylinder/Cone/Torus"],
	"Inspect": ["Measure", "Section Analysis"], "Insert": ["Insert Mesh", "Canvas"], "Select": ["Window Selection"],
}

static var _cache: Array[Dictionary] = []
## The same tools by id, and tools_in() and default_pins() answers by "workspace|group".
static var _by_id := {}
static var _groups_cache := {}
static var _pins_cache := {}


## Every tool in every workspace.
static func all_tools() -> Array[Dictionary]:
	if not _cache.is_empty():
		return _cache
	for workspace in WORKSPACES + [SKETCH_WORKSPACE]:
		var groups: Dictionary = _SKETCH_GROUPS if workspace == SKETCH_WORKSPACE else _GROUPS[workspace]
		for group in groups:
			var folder_lists := _folder_lists(workspace, group)
			for spec in groups[group]:
				var extra: Dictionary = (spec[2] as Dictionary).duplicate() if spec.size() > 2 else {}
				if not extra.has("folder"):
					for folder in folder_lists:
						if (folder_lists[folder] as Array).has(spec[0]):
							extra["folder"] = folder
							break
				if int(spec[1]) == 3 and not extra.has("command") and not extra.has("action") and PHASE3.has(spec[0]):
					var target: String = PHASE3[spec[0]]
					if target.begins_with("action:"):
						extra["action"] = target.trim_prefix("action:")
					else:
						extra["command"] = FEATURE
						extra["type"] = target
				if int(spec[1]) == 5 and not extra.has("command") and not extra.has("action") and PHASE5.has(spec[0]):
					extra["command"] = FEATURE
					extra["type"] = PHASE5[spec[0]]
				if int(spec[1]) == 6 and not extra.has("command") and not extra.has("action") and PHASE6.has(spec[0]):
					extra["form"] = PHASE6[spec[0]]
				if int(spec[1]) == 7 and not extra.has("command") and not extra.has("action") and PHASE7.has(spec[0]):
					var target7: String = PHASE7[spec[0]]
					if target7.begins_with("action:"):
						extra["action"] = target7.trim_prefix("action:")
					else:
						extra["command"] = FEATURE
						extra["type"] = target7
				if int(spec[1]) == 8 and not extra.has("command") and not extra.has("action") and PHASE8.has(spec[0]):
					var target8: Variant = PHASE8[spec[0]]
					if target8 is String:
						extra["action"] = str(target8).trim_prefix("action:")
					else:
						extra["command"] = target8[0]
						extra["type"] = target8[1]
				if int(spec[1]) == 4 and not extra.has("command") and not extra.has("action") and PHASE4.has(spec[0]):
					var target4: Variant = PHASE4[spec[0]]
					if target4 is String:
						extra["action"] = str(target4).trim_prefix("action:")
					else:
						extra["command"] = target4[0]
						extra["type"] = target4[1]
				var tool := {
					"id": "%s.%s.%s" % [_slug(workspace), _slug(group), _slug(spec[0])],
					"name": spec[0], "workspace": workspace, "group": group, "phase": spec[1],
					"shortcut": str(extra.get("shortcut", "")), "icon": str(extra.get("icon", "")),
					"command": str(extra.get("command", "")), "type": str(extra.get("type", "")),
					"action": str(extra.get("action", "")), "sketch": str(extra.get("sketch", "")),
					"folder": str(extra.get("folder", "")), "form": str(extra.get("form", "")),
				}
				_cache.append(tool)
				_by_id[tool.id] = tool
	return _cache


static func groups(workspace: String) -> Array:
	if workspace == SKETCH_WORKSPACE:
		return _SKETCH_GROUPS.keys()
	return (_GROUPS.get(workspace, {}) as Dictionary).keys()


static func tools_in(workspace: String, group: String) -> Array[Dictionary]:
	var key := workspace + "|" + group
	if not _groups_cache.has(key):
		var found: Array[Dictionary] = []
		for tool in all_tools():
			if tool.workspace == workspace and tool.group == group:
				found.append(tool)
		_groups_cache[key] = found
	return (_groups_cache[key] as Array[Dictionary]).duplicate()


static func find(id: String) -> Dictionary:
	all_tools()
	return _by_id.get(id, {})


static func is_enabled(tool: Dictionary) -> bool:
	if int(tool.get("phase", 99)) > IMPLEMENTED_PHASE:
		return false
	var form := str(tool.get("form", ""))
	if form != "":
		return FORM_TOOLS.has_tool(form)
	return str(tool.get("command", "")) != "" or str(tool.get("action", "")) != "" or str(tool.get("sketch", "")) != ""


## The tool a shortcut key runs in a workspace (falls back to the Solid workspace's tool, then
## the Sketch toolbar's, so L still means Line outside a sketch).
static func for_shortcut(workspace: String, key: String) -> Dictionary:
	var solid := {}
	var sketch := {}
	for tool in all_tools():
		if tool.shortcut == key:
			if tool.workspace == workspace:
				return tool
			if solid.is_empty() and tool.workspace == "Solid":
				solid = tool
			if sketch.is_empty() and tool.workspace == SKETCH_WORKSPACE:
				sketch = tool
	return solid if not solid.is_empty() else sketch


## Tools whose names match a search, best first (start of a word beats inside a word).
static func search(text: String, workspace: String) -> Array[Dictionary]:
	var needle := text.strip_edges().to_lower()
	var scored: Array = []
	var seen := {}
	for tool in all_tools():
		var name_lower: String = str(tool.name).to_lower()
		var score := -1
		if needle == "":
			score = 1
		elif name_lower.begins_with(needle):
			score = 4
		elif (" " + name_lower).contains(" " + needle):
			score = 3
		elif name_lower.contains(needle):
			score = 2
		elif _is_subsequence(needle, name_lower):
			score = 1
		if score < 0:
			continue
		if tool.workspace == workspace:
			score += 10
		# One entry per tool name: the current workspace's version wins.
		var key := str(tool.name) + "|" + str(tool.group)
		if seen.has(key) and seen[key].score >= score:
			continue
		seen[key] = {"score": score, "tool": tool}
	for entry in seen.values():
		scored.append(entry)
	scored.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a.score != b.score:
			return a.score > b.score
		return str(a.tool.name) < str(b.tool.name))
	var result: Array[Dictionary] = []
	for entry in scored:
		result.append(entry.tool)
	return result


## A group's dropdown in order: {"tool": tool} for a tool on its own, {"folder": name, "tools":
## [tool, ...]} for a family of like tools (placed where its first tool is listed).
static func menu_entries(workspace: String, group: String) -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	var folders := {}
	for tool in tools_in(workspace, group):
		var folder: String = tool.get("folder", "")
		if folder == "":
			entries.append({"tool": tool})
		elif folders.has(folder):
			folders[folder].tools.append(tool)
		else:
			folders[folder] = {"folder": folder, "tools": [tool]}
			entries.append(folders[folder])
	var lists := _folder_lists(workspace, group)
	for folder in folders:
		var listed: Array = folders[folder].tools
		var ordered: Array[Dictionary] = []
		for name in lists.get(folder, []):
			for tool in listed:
				if tool.name == name:
					ordered.append(tool)
		for tool in listed:
			if not ordered.has(tool):
				ordered.append(tool)
		folders[folder].tools = ordered
	return entries


## The ids of the tools a group shows on the bar until the user pins others.
static func default_pins(workspace: String, group: String) -> Array[String]:
	var key := workspace + "|" + group
	if not _pins_cache.has(key):
		var table: Dictionary = _DEFAULT_PINS.get(workspace, {})
		var names: Array = table.get(group, [] if workspace == SKETCH_WORKSPACE else _SHARED_PINS.get(group, []))
		var ids: Array[String] = []
		for name in names:
			var id := "%s.%s.%s" % [_slug(workspace), _slug(group), _slug(name)]
			if not find(id).is_empty():
				ids.append(id)
		_pins_cache[key] = ids
	return (_pins_cache[key] as Array[String]).duplicate()


## A name as it appears in tool ids and icon file names ("Move/Copy" -> "move_copy").
static func slug(text: String) -> String:
	return _slug(text)


## folder -> [tool names] for a group (its workspace's own folders first, then the shared ones).
static func _folder_lists(workspace: String, group: String) -> Dictionary:
	var lists := {}
	var tables: Array = [_FOLDERS.get(workspace, {})]
	if workspace != SKETCH_WORKSPACE:
		tables.append(_FOLDERS["*"])
	for table in tables:
		for entry in (table as Dictionary).get(group, []):
			if not lists.has(entry[0]):
				lists[entry[0]] = entry[1]
	return lists


static func _is_subsequence(needle: String, haystack: String) -> bool:
	var i := 0
	for c in haystack:
		if i < needle.length() and c == needle[i]:
			i += 1
	return i == needle.length()


static func _slug(text: String) -> String:
	return text.to_lower().replace("/", "_").replace(" - ", "_").replace(":", "").replace(".", "").replace(" ", "_")
