extends SceneTree
## Holo Forge appearances: a box with a body appearance and one face appearance bakes to two
## surfaces with those materials, two face appearances and no body one bake to three (the default
## for the rest); automatic mapping is real size (a 0.1 m face at 0.05 m per repeat spans 2.0 in U),
## never mirrored and upright on walls (as planar and box are); cylindrical mapping on a cylinder of radius r spans 2*pi*r/scale around,
## and a half or quarter cylinder maps in one piece (no wrap in the middle of a face); box mapping
## is continuous on flat faces; a component's appearance reaches a body inside it and a face's
## overrides it (split-off bodies fall back to their source body); unknown ids bake with the
## default material; a decal bakes to a Decal node with the right size, place, facing and flip
## (a flipped decal bakes at its positive size with a mirrored basis, which survives packing),
## and rebakes keep one node per decal; CadPart still bakes a node per body and per component;
## and the library lists the texture-set folders with base colors (maps found by their naming)
## and makes the built-in finishes. No 8K texture is ever loaded.
## Texture Map Controls (without the editor): panel values and mappings convert both ways, only
## the fields that changed are written (origin and axis too, and the bake reads them); the gizmo
## frame's U and V are one texture repeat on the face; dragging the Scale U arrow by d lengthens
## the repeat by d along it; dragging the Rotation dot by an angle sets the rotation and turns the
## U arrow as much (flipped too); dragging the point slides the texture with it; picks find the
## appearance entry they read. A split-off body gets its own Physical Material key (and its own
## appearance), still falling back to its source body's and its component's.
## Review fixes: a face a later groove or Split Body splits ("f1:y+#0", "#1") keeps its appearance
## (bake, resolve, Texture Map picks) unless a piece gets its own; a decal placed with no "up" reads
## upright on every wall (the -X and -Z walls were upside down); a decal follows its face when a
## parametric edit moves it (a taller box) or splits it; cylindrical and spherical mapping are
## unmirrored on bores and inside hollow balls; tops tilted a fraction of a degree toward -Z keep
## the level top's texture direction (they turned half round); a default (+Y) spherical mapping on
## a sphere whose poles lie on Z smears no half turn of texture across one triangle.
##
## godot --headless --path . --script res://tests/holo_forge_appearance_test.gd

const CAD_PART := preload("res://addons/holo_forge/nodes/cad_part.gd")
const DOCUMENT := preload("res://addons/holo_forge/core/document.gd")
const REGEN := preload("res://addons/holo_forge/core/regen.gd")
const OPERATIONS := preload("res://addons/holo_forge/core/operations.gd")
const TESSELLATE := preload("res://addons/holo_forge/core/tessellate.gd")
const APPEARANCE := preload("res://addons/holo_forge/core/appearance.gd")
const MATERIAL_LIBRARY := preload("res://addons/holo_forge/core/material_library.gd")
const UNITS := preload("res://addons/holo_forge/core/units.gd")
const INSPECT := preload("res://addons/holo_forge/core/inspect.gd")
const PHYSICAL := preload("res://addons/holo_forge/core/physical_materials.gd")
const MASS_COMMAND := preload("res://addons/holo_forge/tools/mass_command.gd")
const TEXTURE_MAP := preload("res://addons/holo_forge/tools/texture_map_command.gd")
const SKETCH_DATA := preload("res://addons/holo_forge/core/sketch/sketch_data.gd")

const RED := "builtin:paint_red"
const CHROME := "builtin:metal_chrome"
const BLUE := "builtin:anodized_blue"
const RUBBER := "builtin:rubber_black"

var failures: Array[String] = []
var kernel: RefCounted


func _init() -> void:
	call_deferred("run")


func run() -> void:
	kernel = REGEN.make_kernel()
	_expect(kernel != null, "The native kernel should load.")
	if kernel != null:
		_check_library()
		await _check_body_and_face()
		await _check_two_faces()
		_check_automatic()
		_check_cylindrical()
		_check_partial_round()
		_check_box_mapping()
		_check_fallbacks()
		await _check_components()
		await _check_decals()
		await _check_decal_nodes()
		await _check_decal_flip()
		_check_texture_map_values()
		_check_texture_map_handles()
		_check_texture_map_targets()
		_check_split_bodies()
		await _check_split_faces()
		await _check_decal_upright()
		await _check_decal_follows_face()
		_check_round_facing()
		_check_tilted_tops()
		_check_sphere_poles()
		_check_sphere_primitive_poles()
	print("PASS holo_forge_appearance: body+face appearance bakes to 2 surfaces and 2 face appearances to 3, real-size automatic (2.0 U on 0.1 m at 0.05 m) and cylindrical (2*pi*r/scale) UVs, unmirrored and upright on walls, no wrap on partial cylinders, continuous box mapping, component and face precedence, default-material fallback, Decal nodes reused per decal, flipped decal = positive size + mirrored basis, per-body/per-component nodes, library sets and built-in finishes; Texture Map Controls values/origin/axis, repeat frame, scale arrow (+d), angle handle (rotation and U arrow turn), offset drag, pick targets; split bodies' own Physical Material and appearance with fallbacks; split faces keep their appearance (groove, Split Body); decals upright on every wall and following their face; bores and hollow balls unmirrored; slightly tilted tops not turned; no half-turn smear at off-pole sphere poles; the Sphere primitive has its poles on +Y." \
		if failures.is_empty() else "FAIL holo_forge_appearance")
	quit(0 if failures.is_empty() else 1)


# --- Library ---------------------------------------------------------------------------------

func _check_library() -> void:
	var all: Array[Dictionary] = MATERIAL_LIBRARY.sets(true)
	var by_id := {}
	for e in all:
		by_id[e.id] = e
	var library := all.filter(func(e: Dictionary) -> bool: return str(e.id).begins_with("library:"))
	var builtins := all.filter(func(e: Dictionary) -> bool: return str(e.id).begins_with("builtin:"))
	# (At least: more sets may be added to the folder later.)
	_expect(library.size() >= 16, "The library should list the 16 texture-set folders with a base color (got %d: %s)." % [library.size(), library.map(func(e: Dictionary) -> String: return e.id)])
	for skipped in ["library:ScratchesLight001", "library:StarterNaturePack_F1", "library:_previews"]:
		_expect(not by_id.has(skipped), "%s has no base color and should not be listed." % skipped)
	for e in library:
		var albedo := str(e.maps.albedo)
		var folder := "res://materials/material_library/" + str(e.id).trim_prefix("library:")
		_expect(albedo.begins_with(folder + "/") and FileAccess.file_exists(albedo), "%s: the albedo map should be a file in its folder (%s)." % [e.id, albedo])
		_expect(e.maps.has_all(["albedo", "normal", "roughness", "metallic", "ao", "gloss"]), "%s: maps should have every key." % e.id)
		_expect(str(e.name) != "" and not str(e.name).contains("_"), "%s: the name should be readable (%s)." % [e.id, e.name])
	var sand: Dictionary = by_id.get("library:GroundSand005", {})
	_expect(not sand.is_empty() and sand.maps.albedo.ends_with("GroundSand005_COL_4K.jpg") and sand.maps.normal.ends_with("GroundSand005_NRM_4K.jpg")
		and sand.maps.gloss.ends_with("GroundSand005_GLOSS_4K.jpg") and sand.maps.roughness == "" and sand.maps.ao.ends_with("GroundSand005_AO_4K.jpg")
		and sand.preview.ends_with("GroundSand005_Preview1.png") and sand.name == "Ground Sand 005",
		"A textures.com set should map COL/NRM/GLOSS/AO and its preview (%s)." % sand)
	var corroded: Dictionary = by_id.get("library:MetalCorrodedHeavy001", {})
	_expect(not corroded.is_empty() and corroded.maps.albedo.ends_with("_COL_4K_METALNESS.jpg") and corroded.maps.metallic.ends_with("_METALNESS_4K_METALNESS.jpg")
		and corroded.maps.roughness.ends_with("_ROUGHNESS_4K_METALNESS.jpg") and corroded.maps.normal.ends_with("_NRM_4K_METALNESS.jpg"),
		"A metalness-workflow set should map by its first tag, not the trailing METALNESS (%s)." % corroded)
	var zinc: Dictionary = by_id.get("library:Poliigon_MetalGalvanizedZinc_7184", {})
	_expect(not zinc.is_empty() and zinc.name == "Metal Galvanized Zinc" and zinc.maps.albedo.ends_with("_BaseColor.jpg") and zinc.maps.ao.ends_with("_AmbientOcclusion.jpg")
		and zinc.maps.metallic.ends_with("_Metallic.jpg") and zinc.maps.normal.ends_with("_Normal.png"),
		"A Poliigon set should map BaseColor/Normal/Metallic/AmbientOcclusion (%s)." % zinc)
	var slabs: Dictionary = by_id.get("library:concrete_slabs_03_4k", {})
	_expect(not slabs.is_empty() and slabs.name == "Concrete Slabs 03" and slabs.maps.albedo.ends_with("__basecolor_4k.png") and slabs.maps.normal.ends_with("__normal_gl_4k.png")
		and slabs.maps.ao.ends_with("__ambientocclusion_4k.png") and slabs.preview == "res://materials/material_library/_previews/Concrete Slabs 03.png",
		"A Poly Haven set should map basecolor/normal_gl/ambientocclusion and use the shared preview (%s)." % slabs)
	var wall: Dictionary = by_id.get("library:concrete_wall_03_4k", {})
	_expect(not wall.is_empty() and wall.maps.albedo.ends_with("_color_4k.png") and wall.maps.ao.ends_with("_ambient_occlusion_4k.png"),
		"Poly Haven's color and ambient_occlusion names should map too (%s)." % wall)

	_expect(builtins.size() >= 10, "There should be at least 10 built-in finishes (got %d)." % builtins.size())
	for e in builtins:
		var m := MATERIAL_LIBRARY.material(e.id)
		_expect(m is StandardMaterial3D and (m as StandardMaterial3D).albedo_texture == null, "%s should make a plain StandardMaterial3D." % e.id)
	var chrome := MATERIAL_LIBRARY.material(CHROME) as StandardMaterial3D
	_expect(chrome != null and chrome.metallic == 1.0 and chrome.roughness < 0.1, "Chrome should be a smooth metal.")
	_expect(MATERIAL_LIBRARY.material(CHROME) == chrome, "Materials should be cached and shared.")
	var glass := MATERIAL_LIBRARY.material("builtin:glass_clear") as StandardMaterial3D
	_expect(glass != null and glass.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA and glass.albedo_color.a < 0.5, "Clear glass should be transparent.")
	_expect(MATERIAL_LIBRARY.material("builtin:nope") == null and MATERIAL_LIBRARY.material("library:nope") == null, "Unknown ids should give no material.")
	# Any Godot Material can be an appearance.
	var path := "user://holo_forge_appearance_test.tres"
	var own := StandardMaterial3D.new()
	own.albedo_color = Color(0.2, 0.8, 0.3)
	ResourceSaver.save(own, path)
	var loaded := MATERIAL_LIBRARY.material(path) as StandardMaterial3D
	_expect(loaded != null and loaded.albedo_color.is_equal_approx(Color(0.2, 0.8, 0.3)), "A Material file should load as an appearance.")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


# --- Baking surfaces -------------------------------------------------------------------------

func _check_body_and_face() -> void:
	var doc: Resource = DOCUMENT.new()
	var box := _add_box(doc, Vector3(0.1, 0.02, 0.2), Vector3.ZERO)
	var body_id: String = box.options.body_id
	var shape: RefCounted = REGEN.rebuild(doc, kernel).bodies[body_id].shape
	var top := _face_name(shape, Vector3.UP)
	doc.appearances[APPEARANCE.body_target(body_id)] = {"material": RED}
	doc.appearances[APPEARANCE.face_target(body_id, top)] = {"material": CHROME, "mapping": {"type": "automatic", "scale": Vector2(0.05, 0.05)}}
	var part := await _bake(doc)
	var node: MeshInstance3D = part.body_nodes().get(body_id)
	var mesh: ArrayMesh = node.mesh if node != null else null
	_expect(mesh != null and mesh.get_surface_count() == 2, "A body appearance plus one face appearance should bake to 2 surfaces (got %s)." % (mesh.get_surface_count() if mesh != null else "no mesh"))
	if mesh != null and mesh.get_surface_count() == 2:
		_expect(mesh.surface_get_material(0) == MATERIAL_LIBRARY.material(RED) and mesh.surface_get_material(1) == MATERIAL_LIBRARY.material(CHROME),
			"The surfaces should carry the body's and the face's materials.")
		var face_surface := mesh.surface_get_arrays(1)
		var positions: PackedVector3Array = face_surface[Mesh.ARRAY_VERTEX]
		var top_only := positions.size() == 4
		for p in positions:
			top_only = top_only and absf(p.y - 0.02) < 1e-6
		_expect(top_only, "The face's surface should hold just the top face's 4 corners (%s)." % positions)
		var span := _uv_span(face_surface[Mesh.ARRAY_TEX_UV])
		_expect(absf(span.x - 2.0) < 1e-5 and absf(span.y - 4.0) < 1e-5,
			"Automatic mapping at 0.05 m per repeat should span 2.0 x 4.0 on the 0.1 x 0.2 m top face (got %s)." % span)
		var rest: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		_expect(rest.size() == 20, "The body surface should share vertices within each face: 5 faces x 4 (got %d)." % rest.size())
		_expect(mesh.surface_get_arrays(0)[Mesh.ARRAY_TANGENT] != null, "Baked surfaces should have tangents for normal maps.")
	part.free()


func _check_two_faces() -> void:
	var doc: Resource = DOCUMENT.new()
	var box := _add_box(doc, Vector3(0.1, 0.05, 0.1), Vector3.ZERO)
	var body_id: String = box.options.body_id
	var shape: RefCounted = REGEN.rebuild(doc, kernel).bodies[body_id].shape
	doc.appearances[APPEARANCE.face_target(body_id, _face_name(shape, Vector3.UP))] = {"material": CHROME}
	doc.appearances[APPEARANCE.face_target(body_id, _face_name(shape, Vector3.RIGHT))] = {"material": RUBBER}
	var part := await _bake(doc)
	var node: MeshInstance3D = part.body_nodes().get(body_id)
	var mesh: ArrayMesh = node.mesh if node != null else null
	_expect(mesh != null and mesh.get_surface_count() == 3, "Two face appearances and no body one should bake to 3 surfaces (got %s)." % (mesh.get_surface_count() if mesh != null else "no mesh"))
	if mesh != null and mesh.get_surface_count() == 3:
		var materials := [mesh.surface_get_material(0), mesh.surface_get_material(1), mesh.surface_get_material(2)]
		_expect(materials[0] == CAD_PART.default_material() and materials.has(MATERIAL_LIBRARY.material(CHROME)) and materials.has(MATERIAL_LIBRARY.material(RUBBER)),
			"The rest of the faces should keep the default material, the two faces theirs.")
		var counts := []
		for s in 3:
			counts.append((mesh.surface_get_arrays(s)[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3)
		_expect(counts == [8, 2, 2], "Triangles should split 8 / 2 / 2 between the surfaces (got %s)." % [counts])
	part.free()


# --- Mapping ---------------------------------------------------------------------------------

func _check_automatic() -> void:
	var shape: RefCounted = kernel.make_box(Vector3(0.1, 0.02, 0.2), Vector3.ZERO, "a")
	var tess := TESSELLATE.tessellate(shape)
	var top := _face_index(shape, Vector3.UP)
	var mapping := {"type": "automatic", "scale": Vector2(0.05, 0.05)}
	var uvs := APPEARANCE.uvs_for_face(shape, top, tess, _face_vertices(tess, top), mapping)
	var span := _uv_span(uvs)
	_expect(absf(span.x - 2.0) < 1e-5, "Automatic mapping on a 0.1 m wide flat face at 0.05 m should span 2.0 in U (got %s)." % span.x)
	for f in shape.face_count():
		var w := _winding(APPEARANCE.face_corner_uvs(shape, f, tess, _face_tris(tess, f), mapping))
		_expect(w > 0.0, "Automatic mapping should not mirror box face %d (winding %s)." % [f, w])
	# Walls read upright (v runs down the world) with automatic and planar, as with box mapping;
	# face_plane alone turns the -X and -Z walls upside down.
	var positions: PackedVector3Array = tess.positions
	for type in ["automatic", "planar", "box"]:
		for f in shape.face_count():
			if absf((shape.face_info(f).normal as Vector3).y) > 0.5:
				continue
			var vertices := _face_vertices(tess, f)
			var face_uvs := APPEARANCE.uvs_for_face(shape, f, tess, vertices, {"type": type})
			var upright := true
			for i in vertices.size():
				for j in vertices.size():
					if positions[vertices[i]].y > positions[vertices[j]].y + 1e-6:
						upright = upright and face_uvs[i].y < face_uvs[j].y
			_expect(upright, "%s mapping should keep the texture upright on wall %d (normal %s)." % [type, f, shape.face_info(f).normal])
	# Rotation and offset: a quarter turn swaps the spans, the offset moves the start.
	var turned := APPEARANCE.uvs_for_face(shape, top, tess, _face_vertices(tess, top), {"type": "automatic", "scale": Vector2(0.05, 0.05), "rotation": PI * 0.5, "offset": Vector2(3, 0)})
	var turned_span := _uv_span(turned)
	_expect(absf(turned_span.x - 4.0) < 1e-5 and absf(turned_span.y - 2.0) < 1e-5, "A quarter turn should swap U and V spans (got %s)." % turned_span)


func _check_cylindrical() -> void:
	var r := 0.05
	var scale := 0.05
	var shape: RefCounted = kernel.make_cylinder(r, 0.2, Vector3.ZERO, Vector3.UP, "c")
	var tess := TESSELLATE.tessellate(shape)
	var side := -1
	for f in shape.face_count():
		if shape.face_info(f).type == "cylinder":
			side = f
	var mapping := {"type": "cylindrical", "origin": Vector3.ZERO, "axis": Vector3.UP, "scale": Vector2(scale, scale)}
	var around := TAU * r / scale
	var span := _uv_span(APPEARANCE.uvs_for_face(shape, side, tess, _face_vertices(tess, side), mapping))
	_expect(absf(span.x - around) < around * 1e-5 and absf(span.y - 4.0) < 1e-5, "Cylindrical mapping should span 2*pi*r/scale = %s around and 4.0 up the side (got %s)." % [around, span])
	_expect(_winding(APPEARANCE.face_corner_uvs(shape, side, tess, _face_tris(tess, side), mapping)) > 0.0, "Cylindrical mapping should not be mirrored.")
	# The baked body: the side wraps exactly once; the caps are projected flat (2r across).
	var doc: Resource = DOCUMENT.new()
	doc.bodies["body1"] = {"name": "Body1", "visible": true, "component": ""}
	doc.appearances["body:body1"] = {"material": BLUE, "mapping": mapping}
	var built := APPEARANCE.build_mesh(doc, "body1", shape, tess, null)
	var mesh: ArrayMesh = built.mesh
	_expect(mesh.get_surface_count() == 1 and built.ids == PackedStringArray([BLUE]), "One body appearance should bake to one surface.")
	var arrays := mesh.surface_get_arrays(0)
	var side_uvs := PackedVector2Array()
	var cap_uvs := PackedVector2Array()
	for i in (arrays[Mesh.ARRAY_NORMAL] as PackedVector3Array).size():
		var n: Vector3 = arrays[Mesh.ARRAY_NORMAL][i]
		if absf(n.y) < 0.5:
			side_uvs.append(arrays[Mesh.ARRAY_TEX_UV][i])
		elif n.y > 0.5:
			cap_uvs.append(arrays[Mesh.ARRAY_TEX_UV][i])
	var baked := _uv_span(side_uvs)
	_expect(absf(baked.x - around) < around * 1e-5 and absf(baked.y - 4.0) < 1e-5, "The baked cylinder's side should wrap 2*pi*r/scale once around (got %s, want %s)." % [baked, around])
	var cap := _uv_span(cap_uvs)
	# (The cap's polygon need not reach the circle's extremes on both axes.)
	_expect(cap.distance_to(Vector2(2.0 * r / scale, 2.0 * r / scale)) < 0.01, "The top cap should be projected flat, 2r/scale across (got %s)." % cap)
	var extra: int = (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() - (tess.positions as PackedVector3Array).size()
	_expect(extra == 0, "The side's own seam should be the wrap, so no vertex is split (%d extra)." % extra)
	# Automatic on a curved face: the surface's own u,v at real size, unmirrored.
	var automatic := {"type": "automatic", "scale": Vector2(scale, scale)}
	var auto_span := _uv_span(APPEARANCE.uvs_for_face(shape, side, tess, _face_vertices(tess, side), automatic))
	_expect(absf(auto_span.x - around) < around * 1e-5 and absf(auto_span.y - 4.0) < 1e-5, "Automatic mapping on the cylinder should be real size too (got %s)." % auto_span)
	_expect(_winding(APPEARANCE.face_corner_uvs(shape, side, tess, _face_tris(tess, side), automatic)) > 0.0, "Automatic mapping should not mirror the cylinder.")
	# Spherical (about the sphere's own poles, on Z): half a turn of latitude, a full turn of
	# longitude, at the sphere's radius.
	var ball: RefCounted = kernel.make_sphere(r, Vector3.ZERO, "s")
	var ball_tess := TESSELLATE.tessellate(ball)
	doc.appearances["body:body1"] = {"material": BLUE, "mapping": {"type": "spherical", "axis": Vector3.BACK, "scale": Vector2(scale, scale)}}
	var ball_span := _uv_span(APPEARANCE.build_mesh(doc, "body1", ball, ball_tess, null).mesh.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV])
	_expect(absf(ball_span.x - around) < around * 1e-3 and absf(ball_span.y - PI * r / scale) < 1e-3, "Spherical mapping should span 2*pi*r and pi*r over scale (got %s)." % ball_span)


## Faces that don't go all the way round the axis need no wrap: a half cylinder lying across the
## frame's x direction, and a quarter of one (like a fillet), map in one piece at real size, baked
## and face by face.
func _check_partial_round() -> void:
	var r := 0.05
	var scale := 0.05
	var mapping := {"type": "cylindrical", "scale": Vector2(scale, scale)}
	var full: RefCounted = kernel.make_cylinder(r, 0.2, Vector3.ZERO, Vector3.UP, "c")
	var half: RefCounted = kernel.boolean(full, kernel.make_box(Vector3(0.2, 0.4, 0.2), Vector3(0, -0.1, -0.1), "b"), 2, "h")
	var wedge: RefCounted = kernel.transform_shape(kernel.make_box(Vector3(0.2, 0.4, 0.2), Vector3(0, -0.1, 0), "w"), Transform3D(Basis(Vector3.UP, PI * 0.25), Vector3.ZERO), "w")
	var quarter: RefCounted = kernel.boolean(full, wedge, 2, "q")
	for item in [["half", half, PI], ["quarter", quarter, PI * 0.5]]:
		var shape: RefCounted = item[1]
		var want: float = float(item[2]) * r / scale
		var tess := TESSELLATE.tessellate(shape)
		var doc: Resource = DOCUMENT.new()
		doc.bodies["body1"] = {"name": "Body1", "visible": true, "component": ""}
		doc.appearances["body:body1"] = {"material": BLUE, "mapping": mapping}
		var arrays := (APPEARANCE.build_mesh(doc, "body1", shape, tess, null).mesh as ArrayMesh).surface_get_arrays(0)
		var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
		var side := PackedVector2Array()
		for i in positions.size():
			var radial := Vector3(positions[i].x, 0.0, positions[i].z)
			if radial.length() > r * 0.5 and normals[i].dot(radial.normalized()) > 0.99:
				side.append(uvs[i])
		var span := _uv_span(side)
		_expect(absf(span.x - want) < want * 1e-3, "The %s cylinder's side should map in one piece, %s around (got %s)." % [item[0], want, span])
		var extra := positions.size() - (tess.positions as PackedVector3Array).size()
		_expect(extra == 0, "The %s cylinder needs no wrap, so no vertex should split (%d extra)." % [item[0], extra])
		for f in shape.face_count():
			if shape.face_info(f).type == "cylinder":
				var own := _uv_span(APPEARANCE.uvs_for_face(shape, f, tess, _face_vertices(tess, f), mapping))
				_expect(absf(own.x - want) < want * 1e-3, "The %s cylinder face alone should map in one piece too (got %s)." % [item[0], own])


## Ids that can't be made fall back to the default material; split-off bodies bake their source
## body's face appearances; scale is the texture's own repeat size, so a quarter turn keeps its
## aspect; a negative decal size flips the image.
func _check_fallbacks() -> void:
	var shape: RefCounted = kernel.make_box(Vector3(0.1, 0.02, 0.2), Vector3.ZERO, "a")
	var tess := TESSELLATE.tessellate(shape)
	var top := _face_index(shape, Vector3.UP)
	var fallback := StandardMaterial3D.new()
	var doc: Resource = DOCUMENT.new()
	doc.bodies["body1"] = {"name": "Body1", "visible": true, "component": ""}
	doc.appearances["body:body1"] = {"material": "library:NoSuchSet"}
	var built := APPEARANCE.build_mesh(doc, "body1", shape, tess, fallback)
	_expect(built.ids == PackedStringArray(["library:NoSuchSet"]) and (built.mesh as ArrayMesh).surface_get_material(0) == fallback,
		"An appearance that can't be made should bake with the default material (%s)." % [built.materials])
	doc.appearances.erase("body:body1")
	doc.appearances[APPEARANCE.face_target("body1", str(shape.get_face_names()[top]))] = {"material": CHROME}
	built = APPEARANCE.build_mesh(doc, "body1.f3.2", shape, tess, fallback)
	_expect(built.ids == PackedStringArray(["", CHROME]) and (built.face_surfaces as PackedInt32Array)[top] == 1,
		"A split-off body should bake its source body's face appearance (%s, %s)." % [built.ids, built.face_surfaces])
	# The 0.1 x 0.2 m top face turned a quarter at 0.05 x 0.1 m per repeat: 0.2 / 0.05 by 0.1 / 0.1.
	var turned := _uv_span(APPEARANCE.uvs_for_face(shape, top, tess, _face_vertices(tess, top), {"scale": Vector2(0.05, 0.1), "rotation": PI * 0.5}))
	_expect(turned.distance_to(Vector2(4.0, 1.0)) < 1e-4, "Rotation should turn the texture before scaling it, keeping its aspect (got %s)." % turned)
	var info := {"position": Vector3.ZERO, "normal": Vector3.UP, "up": Vector3.FORWARD, "size": Vector2(-0.08, 0.04)}
	var flipped := APPEARANCE.decal_transform(info)
	_expect(flipped.basis.x.distance_to(Vector3.LEFT) < 1e-6 and flipped.basis.y.distance_to(Vector3.UP) < 1e-6 and (-flipped.basis.z).distance_to(Vector3.FORWARD) < 1e-6
		and APPEARANCE.decal_size(info).is_equal_approx(Vector3(0.08, 0.04, 0.04)), "A negative width should flip the decal across, at its positive size (%s)." % flipped.basis)


func _check_box_mapping() -> void:
	# A box turned off every axis: each flat face projects onto one box side, seamlessly.
	var turn := Transform3D(Basis.from_euler(Vector3(0.35, 0.6, 0.2)), Vector3(0.01, 0.02, 0.03))
	var shape: RefCounted = kernel.transform_shape(kernel.make_box(Vector3(0.1, 0.06, 0.08), Vector3.ZERO, "b"), turn, "b")
	var tess := TESSELLATE.tessellate(shape)
	var indices: PackedInt32Array = tess.indices
	var mapping := {"type": "box", "scale": Vector2(0.02, 0.02)}
	for f in shape.face_count():
		var tris := _face_tris(tess, f)
		var corners := APPEARANCE.face_corner_uvs(shape, f, tess, tris, mapping)
		var seen := {}
		var continuous := true
		for k in tris.size():
			for j in 3:
				var v := indices[tris[k] * 3 + j]
				if seen.has(v):
					continuous = continuous and (seen[v] as Vector2).is_equal_approx(corners[k * 3 + j])
				seen[v] = corners[k * 3 + j]
		_expect(continuous, "Box mapping should give each vertex of flat face %d one UV." % f)
		_expect(absf(_winding(corners)) > 1e-3, "Box mapping should cover flat face %d (not collapse it)." % f)
	var doc: Resource = DOCUMENT.new()
	doc.bodies["body1"] = {"name": "Body1", "visible": true, "component": ""}
	doc.appearances["body:body1"] = {"material": RED, "mapping": mapping}
	var built := APPEARANCE.build_mesh(doc, "body1", shape, tess, null)
	var count := (built.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	_expect(count == (tess.positions as PackedVector3Array).size(), "Box mapping on flat faces should split no vertices (%d vs %d)." % [count, (tess.positions as PackedVector3Array).size()])


# --- Precedence, components, decals ----------------------------------------------------------

func _check_components() -> void:
	var doc: Resource = DOCUMENT.new()
	var outer: String = doc.new_component()
	doc.active_component = outer
	var inner: String = doc.new_component()
	doc.active_component = inner
	var boxed := _add_box(doc, Vector3(0.05, 0.05, 0.05), Vector3.ZERO)
	doc.active_component = ""
	var loose := _add_box(doc, Vector3(0.05, 0.05, 0.05), Vector3(0.2, 0, 0))
	var body_id: String = boxed.options.body_id
	var shape: RefCounted = REGEN.rebuild(doc, kernel).bodies[body_id].shape
	var top := _face_name(shape, Vector3.UP)
	doc.appearances[APPEARANCE.component_target(outer)] = {"material": BLUE, "mapping": {"type": "box"}}
	var r: Dictionary = APPEARANCE.resolve(doc, body_id, top)
	_expect(r.material == BLUE and r.source == "component" and r.mapping.type == "box" and r.mapping.scale == Vector2(0.1, 0.1),
		"An outer component's appearance should reach a body two components down, with mapping defaults filled in (%s)." % r)
	_expect(APPEARANCE.resolve(doc, loose.options.body_id, top).material == "", "A body outside the component should get nothing.")
	doc.appearances[APPEARANCE.component_target(inner)] = {"material": RUBBER}
	_expect(APPEARANCE.resolve(doc, body_id, top).material == RUBBER, "The nearest component should win.")
	doc.appearances[APPEARANCE.body_target(body_id)] = {"material": RED}
	_expect(APPEARANCE.resolve(doc, body_id, top).source == "body", "A body's appearance should beat its component's.")
	doc.appearances[APPEARANCE.face_target(body_id, top)] = {"material": CHROME}
	r = APPEARANCE.resolve(doc, body_id, top)
	_expect(r.material == CHROME and r.source == "face", "A face's appearance should beat the body's and the component's.")
	_expect(APPEARANCE.resolve(doc, body_id, "f999:x").material == RED, "Other faces should keep the body's.")
	var derived: Dictionary = APPEARANCE.resolve(doc, body_id + ".f9.2", top)
	_expect(derived.material == CHROME and APPEARANCE.resolve(doc, body_id + ".f9.2", "").material == RED,
		"A split-off body should fall back to its source body's face and body appearances.")
	doc.appearances.erase(APPEARANCE.body_target(body_id))
	doc.appearances.erase(APPEARANCE.component_target(inner))

	var part := await _bake(doc)
	var bodies: Dictionary = part.body_nodes()
	var components: Dictionary = part.component_nodes()
	_expect(bodies.size() == 2 and components.size() == 2, "Each body and each component should bake to its own node (%d bodies, %d components)." % [bodies.size(), components.size()])
	var node: MeshInstance3D = bodies.get(body_id)
	if node != null and components.has(inner) and components.has(outer):
		_expect(node.get_parent() == components[inner] and components[inner].get_parent() == components[outer], "The body should sit in its component, inside the outer one.")
		var mesh: ArrayMesh = node.mesh
		_expect(mesh.get_surface_count() == 2 and mesh.surface_get_material(0) == MATERIAL_LIBRARY.material(BLUE) and mesh.surface_get_material(1) == MATERIAL_LIBRARY.material(CHROME),
			"The baked body should show the component's appearance with the face's on top.")
	var plain: MeshInstance3D = bodies.get(loose.options.body_id)
	_expect(plain != null and plain.get_parent() == part and plain.mesh.get_surface_count() == 1 and plain.mesh.surface_get_material(0) == CAD_PART.default_material(),
		"A body with no appearance should bake as before: one surface with the default material, at the top level.")
	part.free()


func _check_decals() -> void:
	var doc: Resource = DOCUMENT.new()
	var box := _add_box(doc, Vector3(0.2, 0.02, 0.1), Vector3.ZERO)
	var body_id: String = box.options.body_id
	doc.decals.append({
		"id": "decal1", "name": "Logo", "image": "res://icon.svg", "body": body_id, "face": "", "position": Vector3(0.03, 0.02, -0.01),
		"normal": Vector3.UP, "up": Vector3.FORWARD, "size": Vector2(0.08, 0.04), "rotation": 0.0, "visible": true,
	})
	doc.decals.append({"id": "decal2", "name": "Hidden", "image": "res://icon.svg", "body": body_id, "position": Vector3.ZERO, "normal": Vector3.UP, "size": Vector2(0.01, 0.01), "visible": false})
	var part := await _bake(doc)
	var node: MeshInstance3D = part.body_nodes().get(body_id)
	var decals: Array[Node] = []
	if node != null:
		decals = node.find_children("*", "Decal", false, false)
	_expect(decals.size() == 1, "One visible decal should bake to one Decal node (got %d)." % decals.size())
	if decals.size() != 1:
		part.free()
		return
	var decal := decals[0] as Decal
	_expect(decal.name == "Logo", "The Decal should be named after the decal (%s)." % decal.name)
	_expect(decal.size.is_equal_approx(Vector3(0.08, 0.04, 0.04)), "The Decal's size should be (width, depth, height) = (0.08, 0.04, 0.04) (got %s)." % decal.size)
	_expect(decal.position.distance_to(Vector3(0.03, 0.02, -0.01)) < 1e-6, "The Decal should sit at the decal's position (%s)." % decal.position)
	_expect(decal.transform.basis.y.distance_to(Vector3.UP) < 1e-6 and (-decal.transform.basis.z).distance_to(Vector3.FORWARD) < 1e-6,
		"The Decal should project down onto the face (its +Y the normal) with the image's top toward 'up' (%s)." % decal.transform.basis)
	_expect(decal.texture_albedo != null, "The Decal should carry the image.")
	_expect(decal.owner == part.owner if part.owner != null else decal.owner == part, "The Decal should be owned like the other baked nodes.")
	doc.decals[0].rotation = PI * 0.5
	doc.decals[0].size = Vector2(0.06, 0.02)
	part.apply_result(REGEN.rebuild(doc, kernel))
	await process_frame
	var again: Array[Node] = node.find_children("*", "Decal", false, false)
	_expect(again.size() == 1 and again[0] == decal, "A rebake should reuse the Decal node.")
	_expect((-decal.transform.basis.z).distance_to(Vector3.LEFT) < 1e-6 and decal.size.is_equal_approx(Vector3(0.06, 0.03, 0.02)),
		"Turning the decal a quarter about the normal should turn its up from -Z to -X (%s, %s)." % [decal.transform.basis, decal.size])
	doc.decals[0].visible = false
	part.apply_result(REGEN.rebuild(doc, kernel))
	await process_frame
	_expect(node.find_children("*", "Decal", false, false).is_empty(), "Hiding the decal should remove its node.")
	part.free()


## Rebakes keep one Decal node per entry, also for entries without an id, and a decal named like
## the collision node never takes its name (which made every rebake add a StaticBody3D).
func _check_decal_nodes() -> void:
	var doc: Resource = DOCUMENT.new()
	var box := _add_box(doc, Vector3(0.1, 0.02, 0.1), Vector3.ZERO)
	var body_id: String = box.options.body_id
	for label in ["Collision", "Sticker", "Sticker"]:
		doc.decals.append({"name": label, "image": "res://icon.svg", "body": body_id, "position": Vector3(0, 0.02, 0), "normal": Vector3.UP, "size": Vector2(0.02, 0.02), "visible": true})
	var part := await _bake(doc)
	part.generate_collision = true
	var result := REGEN.rebuild(doc, kernel)
	for i in 3:
		part.apply_result(result)
		await process_frame
	var node: MeshInstance3D = part.body_nodes().get(body_id)
	var decals := -1
	var collisions: Array[Node] = []
	if node != null:
		decals = node.find_children("*", "Decal", false, false).size()
		collisions = node.find_children("*", "StaticBody3D", false, false)
	_expect(decals == 3 and collisions.size() == 1 and collisions[0].name == CAD_PART.COLLISION_NAME,
		"Rebakes should keep 3 Decal nodes and 1 collision body (got %d decals, %s)." % [decals, collisions])
	part.free()


## Flip (a negative width) bakes a Decal at its positive size whose basis is mirrored across the
## image: every corner lands on the unflipped decal's mirror corner. Godot would collapse a
## negative size to 0.001 instead. The mirrored basis survives packing the scene.
func _check_decal_flip() -> void:
	var doc: Resource = DOCUMENT.new()
	var box := _add_box(doc, Vector3(0.2, 0.02, 0.1), Vector3.ZERO)
	var body_id: String = box.options.body_id
	for spec in [["plain", 0.06], ["flipped", -0.06]]:
		doc.decals.append({
			"id": spec[0], "name": str(spec[0]).capitalize(), "image": "res://icon.svg", "body": body_id, "position": Vector3(0.1, 0.02, 0.05),
			"normal": Vector3.UP, "up": Vector3.FORWARD, "size": Vector2(spec[1], 0.03), "rotation": 0.3, "visible": true,
		})
	var part := await _bake(doc)
	var node: MeshInstance3D = part.body_nodes().get(body_id)
	var plain := node.get_node_or_null("Plain") as Decal if node != null else null
	var flipped := node.get_node_or_null("Flipped") as Decal if node != null else null
	_expect(plain != null and flipped != null, "Both decals should bake to Decal nodes.")
	if plain == null or flipped == null:
		part.free()
		return
	_expect(flipped.size.is_equal_approx(Vector3(0.06, 0.03, 0.03)) and flipped.size == plain.size,
		"A flipped decal should bake at its positive size, like the unflipped one (%s, %s)." % [flipped.size, plain.size])
	var a := plain.transform.basis
	var b := flipped.transform.basis
	_expect(a.determinant() > 0.0 and b.determinant() < 0.0, "Only the flipped decal's basis should be mirrored (determinants %s, %s)." % [a.determinant(), b.determinant()])
	_expect(b.x.distance_to(-a.x) < 1e-6 and b.y.distance_to(a.y) < 1e-6 and b.z.distance_to(a.z) < 1e-6,
		"Flip should mirror across the image only, keeping the projection (Y) and the image's up (-Z) (%s vs %s)." % [b, a])
	var half := flipped.size * 0.5
	var mirrored := true
	for c in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
		var local := Vector3(c.x * half.x, 0.0, c.y * half.z)
		mirrored = mirrored and (flipped.transform * local).distance_to(plain.transform * Vector3(-local.x, 0.0, local.z)) < 1e-6
	_expect(mirrored, "Each corner of the flipped image should land on the unflipped image's mirror corner.")
	var probe := Decal.new()
	probe.size = Vector3(-0.06, 0.03, 0.03)
	_expect(probe.size.x > 0.0 and probe.size.x < 0.01, "Godot collapses a negative Decal size (got %s), so the flip has to be in the basis." % probe.size)
	probe.free()
	var packed := PackedScene.new()
	_expect(packed.pack(part) == OK, "The baked part should pack.")
	var copy := packed.instantiate()
	var again: Decal = null
	for decal in copy.find_children("Flipped", "Decal", true, false):
		again = decal
	_expect(again != null and again.transform.basis.determinant() < 0.0 and again.size.is_equal_approx(flipped.size),
		"The mirrored basis and positive size should survive packing the scene.")
	copy.free()
	part.free()


# --- Texture Map Controls --------------------------------------------------------------------

## Panel values and mappings convert both ways; only changed fields are written (untouched keys
## stay unset); fields that don't evaluate keep their value; origin and axis reach the bake.
func _check_texture_map_values() -> void:
	var mapping := {"type": "planar", "scale": Vector2(0.05, -0.02), "rotation": deg_to_rad(30.0), "offset": Vector2(0.25, 0.0), "origin": Vector3(0.01, 0, 0), "axis": Vector3.BACK}
	var values := TEXTURE_MAP.values_from_mapping(mapping, "mm")
	_expect(values.type == "planar" and values.scale_u == "50" and values.scale_v == "20" and not values.flip_u and values.flip_v and values.rotation == "30"
		and values.offset_u == "0.25" and values.offset_v == "0" and values.origin == Vector3(0.01, 0, 0) and values.axis == "z",
		"A mapping should show as panel values in the document's units (%s)." % values)
	var back := TEXTURE_MAP.mapping_from_values(values, "mm")
	_expect(back.type == "planar" and (back.scale as Vector2).is_equal_approx(mapping.scale) and absf(float(back.rotation) - float(mapping.rotation)) < 1e-6
		and (back.offset as Vector2).is_equal_approx(mapping.offset) and back.origin == mapping.origin and back.axis == Vector3.BACK,
		"Panel values should give the mapping back (%s)." % back)
	var stored := {"type": "planar", "scale": Vector2(0.05, 0.05)}
	_expect(TEXTURE_MAP.changed_mapping(stored, TEXTURE_MAP.values_from_mapping(stored, "mm"), "mm") == stored, "Untouched fields should write nothing.")
	var typed := TEXTURE_MAP.values_from_mapping(stored, "mm")
	typed["scale_u"] = "70"
	typed["origin"] = Vector3(0, 0.02, 0.01)
	typed["axis"] = "custom"
	typed["axis_x"] = "1"
	typed["axis_z"] = "1"
	var written := TEXTURE_MAP.changed_mapping(stored, typed, "mm")
	_expect((written.scale as Vector2).is_equal_approx(Vector2(0.07, 0.05)) and written.origin == Vector3(0, 0.02, 0.01) and written.axis == Vector3(1, 0, 1)
		and written.type == "planar" and not written.has("offset") and not written.has("rotation"),
		"Only the changed scale, origin and axis should be written (%s)." % written)
	typed = TEXTURE_MAP.values_from_mapping(stored, "mm")
	typed["scale_v"] = "oops"
	typed["flip_v"] = true
	written = TEXTURE_MAP.changed_mapping(stored, typed, "mm")
	_expect((written.scale as Vector2).is_equal_approx(Vector2(0.05, -0.05)), "A field that doesn't evaluate should keep its value, and Flip V negate it (%s)." % written)
	_expect(TEXTURE_MAP.axis_from_values({"axis": "-y"}, "mm") == Vector3.DOWN and TEXTURE_MAP.axis_from_values({"axis": "auto"}, "mm") == Vector3.ZERO
		and TEXTURE_MAP.axis_choice(Vector3(0, 0, -2)) == "-z" and TEXTURE_MAP.axis_choice(Vector3(1, 1, 0)) == "custom", "Axis choices should map to directions.")
	# The bake reads them: moving a planar origin 10 mm along U shifts the top face's U by 0.2 at
	# 0.05 m per repeat; projecting along +Z collapses the top face's V and the gizmo frame.
	var shape: RefCounted = kernel.make_box(Vector3(0.1, 0.02, 0.2), Vector3.ZERO, "a")
	var tess := TESSELLATE.tessellate(shape)
	var top := _face_index(shape, Vector3.UP)
	var vertices := _face_vertices(tess, top)
	var plain := APPEARANCE.uvs_for_face(shape, top, tess, vertices, stored)
	var moved := APPEARANCE.uvs_for_face(shape, top, tess, vertices, TEXTURE_MAP.changed_mapping(stored, _with(TEXTURE_MAP.values_from_mapping(stored, "mm"), "origin", Vector3(0.01, 0, 0)), "mm"))
	var shifted := true
	for i in vertices.size():
		shifted = shifted and (moved[i] - plain[i]).distance_to(Vector2(-0.2, 0.0)) < 1e-5
	_expect(shifted, "A planar origin 10 mm along U should shift U by 0.2 repeats (%s vs %s)." % [moved, plain])
	var along_z := {"type": "planar", "scale": Vector2(0.05, 0.05), "axis": Vector3.BACK}
	_expect(_uv_span(APPEARANCE.uvs_for_face(shape, top, tess, vertices, along_z)).y < 1e-6 and TEXTURE_MAP.surface_frame(shape, top, tess, along_z, Vector3(0.05, 0.02, 0.1)).is_empty(),
		"A planar axis along the top face should collapse it (no frame to put handles on).")


## The gizmo frame and its handles on a box top and a cylinder side.
func _check_texture_map_handles() -> void:
	var shape: RefCounted = kernel.make_box(Vector3(0.1, 0.02, 0.2), Vector3.ZERO, "a")
	var tess := TESSELLATE.tessellate(shape)
	var top := _face_index(shape, Vector3.UP)
	var mapping := {"type": "planar", "scale": Vector2(0.05, 0.05)}
	var start := TEXTURE_MAP.start_point(shape, top, tess)
	var frame := TEXTURE_MAP.surface_frame(shape, top, tess, mapping, start)
	_expect(not frame.is_empty() and (frame.anchor as Vector3).distance_to(Vector3(0.05, 0.02, 0.1)) < 1e-6, "The gizmo should start in the middle of the top face (%s)." % frame)
	if frame.is_empty():
		return
	var u: Vector3 = frame.u
	var v: Vector3 = frame.v
	_expect(absf(u.length() - 0.05) < 1e-6 and absf(v.length() - 0.05) < 1e-6 and absf(u.dot(Vector3.UP)) < 1e-6 and absf(v.dot(Vector3.UP)) < 1e-6
		and (frame.normal as Vector3).distance_to(Vector3.UP) < 1e-6 and (frame.turn_axis as Vector3).distance_to(Vector3.UP) < 1e-6,
		"U and V should be one 50 mm repeat across the top face, turning about its normal (%s)." % frame)
	# U and V really are one repeat: between any two vertices the face's UVs step by their u, v
	# amounts, and an offset drag from one to the other puts the first one's texture under the second.
	var vertices := _face_vertices(tess, top)
	var positions: PackedVector3Array = tess.positions
	var uvs := APPEARANCE.uvs_for_face(shape, top, tess, vertices, mapping)
	var steps := true
	var follows := true
	for i in range(1, vertices.size()):
		var offset := TEXTURE_MAP.dragged_offset(frame, Vector2.ZERO, positions[vertices[0]], positions[vertices[i]])
		steps = steps and (uvs[i] - uvs[0]).distance_to(-offset) < 1e-5
		var slid := APPEARANCE.uvs_for_face(shape, top, tess, vertices, {"type": "planar", "scale": Vector2(0.05, 0.05), "offset": offset})
		follows = follows and slid[i].distance_to(uvs[0]) < 1e-5
	_expect(steps, "The face's UVs should step by exactly the frame's u, v amounts between vertices.")
	_expect(follows, "Dragging the point handle should slide the texture with it.")
	var by_key := {}
	for handle in TEXTURE_MAP.handles(frame, mapping, 0.001):
		by_key[handle.key] = handle
	_expect(by_key.has_all(["scale_u", "scale_v", "rotation", "anchor"]) and not by_key.has("origin"), "Planar mapping should get two arrows, a turn dot and a point (%s)." % [by_key.keys()])
	if not by_key.has_all(["scale_u", "rotation"]):
		return
	var arrow: Dictionary = by_key.scale_u
	_expect(arrow.type == "arrow" and (arrow.direction as Vector3).distance_to(u.normalized()) < 1e-6 and absf(float(arrow.base) - 0.05) < 1e-9 and absf(float(arrow.factor) - 1.0) < 1e-5,
		"The Scale U arrow should point along U from the current 50 mm, one to one (%s)." % arrow)
	# Drag it 20 mm out the way the view does (base + distance * factor), written as the workspace does.
	var d := 0.02
	var values := TEXTURE_MAP.values_from_mapping(mapping, "mm")
	values[arrow.key] = UNITS.format_value(maxf(float(arrow.base) + d * float(arrow.factor), float(arrow.min)), UNITS.KIND_LENGTH, "mm")
	var stretched := TEXTURE_MAP.changed_mapping(mapping, values, "mm")
	var after := TEXTURE_MAP.surface_frame(shape, top, tess, stretched, frame.anchor)
	_expect((stretched.scale as Vector2).is_equal_approx(Vector2(0.07, 0.05)) and not after.is_empty() and absf((after.u as Vector3).length() - 0.07) < 1e-6
		and (after.u as Vector3).normalized().distance_to(u.normalized()) < 1e-6, "Dragging the U arrow 20 mm should make one repeat 70 mm along it (%s)." % [stretched])
	var turn: Dictionary = by_key.rotation
	_expect(turn.type == "angle" and (turn.axis as Vector3).distance_to(Vector3.UP) < 1e-6 and float(turn.base) == 0.0 and absf((turn.start as Vector3).length() - 0.1) < 1e-6,
		"The turn dot should sit 100 px out, turning about the face normal from the current rotation (%s)." % turn)
	var alpha := 0.4
	values = TEXTURE_MAP.values_from_mapping(stretched, "mm")
	values[turn.key] = UNITS.format_value(float(turn.base) + alpha, UNITS.KIND_ANGLE, "mm")
	var turned := TEXTURE_MAP.changed_mapping(stretched, values, "mm")
	var turned_frame := TEXTURE_MAP.surface_frame(shape, top, tess, turned, frame.anchor)
	_expect(absf(float(turned.get("rotation", 0.0)) - alpha) < 1e-5, "Dragging the turn dot by 0.4 rad should set the rotation to it (%s)." % turned)
	_expect(not turned_frame.is_empty() and (turned_frame.u as Vector3).distance_to((after.u as Vector3).rotated(turn.axis, alpha)) < 1e-6
		and (turned_frame.v as Vector3).distance_to((after.v as Vector3).rotated(turn.axis, alpha)) < 1e-6, "The texture (its U arrow) should turn as far as the dot was dragged.")
	# Flipped U: the dot still turns the texture the way it is dragged.
	var flipped := {"type": "planar", "scale": Vector2(-0.05, 0.05)}
	var f0 := TEXTURE_MAP.surface_frame(shape, top, tess, flipped, frame.anchor)
	var f1 := TEXTURE_MAP.surface_frame(shape, top, tess, {"type": "planar", "scale": Vector2(-0.05, 0.05), "rotation": alpha}, frame.anchor)
	_expect(not f0.is_empty() and not f1.is_empty() and (f0.u as Vector3).distance_to(-u) < 1e-6 and (f1.u as Vector3).distance_to((f0.u as Vector3).rotated(f0.turn_axis, alpha)) < 1e-6,
		"With U flipped the turn dot should still turn the texture as it is dragged.")
	# A cylinder side: true to size around and down, with the projection's center as a handle.
	var r := 0.05
	var cylinder: RefCounted = kernel.make_cylinder(r, 0.2, Vector3.ZERO, Vector3.UP, "c")
	var cylinder_tess := TESSELLATE.tessellate(cylinder)
	var side := -1
	for f in cylinder.face_count():
		if cylinder.face_info(f).type == "cylinder":
			side = f
	var round_mapping := {"type": "cylindrical", "scale": Vector2(0.05, 0.05)}
	var at := TEXTURE_MAP.start_point(cylinder, side, cylinder_tess)
	var c := TEXTURE_MAP.surface_frame(cylinder, side, cylinder_tess, round_mapping, at)
	_expect(absf(at.y - 0.1) < 1e-6 and absf(Vector2(at.x, at.z).length() - r) < r * 0.01, "The gizmo should start halfway up the cylinder's side (%s)." % at)
	_expect(not c.is_empty() and absf((c.u as Vector3).length() - 0.05) < 0.05 * 0.01 and (c.v as Vector3).distance_to(Vector3(0, -0.05, 0)) < 1e-6
		and absf((c.u as Vector3).dot(Vector3.UP)) < 1e-6, "Cylindrical U should run 50 mm around and V 50 mm down the side (%s)." % c)
	var round_handles := {}
	for handle in TEXTURE_MAP.handles(c, round_mapping, 0.001):
		round_handles[handle.key] = handle
	_expect(round_handles.has("origin") and (round_handles.origin.position as Vector3) == Vector3.ZERO and (round_handles.origin.normal as Vector3).distance_to(Vector3.UP) < 1e-6,
		"A round projection should get a handle on its center, moving across its axis.")
	var fit := TEXTURE_MAP.fit_projection(cylinder, side, "cylindrical")
	_expect((fit.origin as Vector3).distance_to(Vector3.ZERO) < 1e-6 and absf((fit.axis as Vector3).normalized().dot(Vector3.UP)) > 1.0 - 1e-6,
		"Fit should put a cylindrical projection on the cylinder's own axis (%s)." % fit)


## Picks edit the entry they read: a face its own, else its body's or component's; a body its
## body-wide entry with the gizmo on its largest face that shows it.
func _check_texture_map_targets() -> void:
	var doc: Resource = DOCUMENT.new()
	var component: String = doc.new_component()
	doc.active_component = component
	var inside := _add_box(doc, Vector3(0.1, 0.02, 0.2), Vector3.ZERO)
	doc.active_component = ""
	var loose := _add_box(doc, Vector3(0.05, 0.05, 0.05), Vector3(0.3, 0, 0))
	var body_id: String = inside.options.body_id
	var result := REGEN.rebuild(doc, kernel)
	var shape: RefCounted = result.bodies[body_id].shape
	var top_name := _face_name(shape, Vector3.UP)
	var face_key := APPEARANCE.face_target(body_id, top_name)
	doc.appearances[APPEARANCE.component_target(component)] = {"material": RED, "mapping": {"type": "box"}}
	doc.appearances[face_key] = {"material": CHROME}
	var top_ref := {"kind": "face", "body": body_id, "name": top_name}
	var side_ref := {"kind": "face", "body": body_id, "name": _face_name(shape, Vector3.RIGHT)}
	var top_pick := TEXTURE_MAP.pick_target(doc, result, top_ref)
	_expect(top_pick.target == face_key and top_pick.face == _face_index(shape, Vector3.UP), "A face with its own appearance should edit it (%s)." % top_pick)
	_expect(TEXTURE_MAP.pick_target(doc, result, side_ref).target == APPEARANCE.component_target(component), "A face showing its component's appearance should edit the component's.")
	var body_pick := TEXTURE_MAP.pick_target(doc, result, {"kind": "body", "body": body_id})
	_expect(body_pick.target == APPEARANCE.component_target(component) and body_pick.face == _face_index(shape, Vector3.DOWN),
		"A body pick should edit its body-wide appearance on its largest face that shows it, the bottom (%s)." % body_pick)
	var bare := TEXTURE_MAP.pick_target(doc, result, {"kind": "body", "body": loose.options.body_id})
	_expect(bare.target == "" and bare.body == loose.options.body_id and int(bare.face) >= 0, "A body without an appearance should edit nothing (%s)." % bare)
	var found := TEXTURE_MAP.ref_for_target(doc, result, face_key)
	_expect(found.get("kind") == "face" and found.get("name") == top_name and TEXTURE_MAP.ref_for_target(doc, result, APPEARANCE.component_target(component)) == {"kind": "body", "body": body_id},
		"With nothing selected the command should find what reads an entry (%s)." % found)
	_expect(APPEARANCE.resolve(doc, body_id + ".f9.2", top_name).target == face_key and APPEARANCE.reaches(doc, body_id + ".f9.2", APPEARANCE.body_target(body_id))
		and not APPEARANCE.reaches(doc, loose.options.body_id, APPEARANCE.component_target(component)), "Split-off bodies should read and be reached by their source's entries.")


## A body Split Body cut off ("body1.f3.2") gets Physical Material and appearance keys of its own;
## without them it falls back to its source body's, then its component's.
func _check_split_bodies() -> void:
	var doc: Resource = DOCUMENT.new()
	var box := _add_box(doc, Vector3(0.1, 0.02, 0.2), Vector3.ZERO)
	var source: String = box.options.body_id
	var plane: Resource = doc.add_feature("plane", "Plane", {"distance": doc.make_input("30 mm", "length")}, {"method": "offset", "plane": [{"kind": "origin", "name": "yz"}]})
	doc.add_feature("split_body", "Split Body", {}, {"body": [{"kind": "body", "body": source}], "tool": [{"kind": "construct", "feature": plane.id}]})
	var result := REGEN.rebuild(doc, kernel)
	var piece := ""
	for id in result.bodies:
		if id != source:
			piece = id
	_expect(result.bodies.size() == 2 and piece.begins_with(source + "."), "Split Body should leave the box and a split-off piece (%s, %s)." % [result.bodies.keys(), result.errors])
	if piece == "":
		return
	var keys := MASS_COMMAND.targets(doc, [piece], false)
	_expect(keys.size() == 1 and keys[0] == "body:" + piece, "Physical Material should write the piece's own key (%s)." % [keys])
	doc.physical_materials[keys[0]] = "Aluminum"
	_expect(PHYSICAL.material_for(doc, piece) == "Aluminum" and PHYSICAL.material_for(doc, source) == PHYSICAL.DEFAULT, "Only the piece should be aluminum.")
	doc.physical_materials["body:" + source] = "Titanium"
	var props := INSPECT.mass_properties(doc, result, [source, piece])
	var piece_mass := float(result.bodies[piece].shape.volume()) * 2700.0
	var source_mass := float(result.bodies[source].shape.volume()) * 4500.0
	_expect(absf(float(props.bodies[piece].mass) - piece_mass) < piece_mass * 1e-6 and absf(float(props.bodies[source].mass) - source_mass) < source_mass * 1e-6,
		"Each half should weigh by its own material (%s)." % [props.bodies])
	doc.physical_materials.erase(keys[0])
	_expect(PHYSICAL.material_for(doc, piece) == "Titanium", "Without its own the piece should use its source body's.")
	var component: String = doc.new_component()
	doc.bodies[source]["component"] = component
	_expect(MASS_COMMAND.targets(doc, [piece], true).has("component:" + component), "Apply To Components should write the piece's component.")
	doc.physical_materials.erase("body:" + source)
	doc.physical_materials["component:" + component] = "Copper"
	_expect(PHYSICAL.material_for(doc, piece) == "Copper", "Then its component's.")
	# Appearances: the piece's own body entry beats its source's, which the source keeps.
	doc.appearances[APPEARANCE.body_target(source)] = {"material": RED}
	doc.appearances[APPEARANCE.body_target(piece)] = {"material": CHROME}
	var piece_shape: RefCounted = result.bodies[piece].shape
	var source_shape: RefCounted = result.bodies[source].shape
	_expect(APPEARANCE.build_mesh(doc, piece, piece_shape, TESSELLATE.tessellate(piece_shape), null).ids == PackedStringArray([CHROME])
		and APPEARANCE.build_mesh(doc, source, source_shape, TESSELLATE.tessellate(source_shape), null).ids == PackedStringArray([RED]),
		"The piece should show its own appearance and the source keep its.")
	_expect(TEXTURE_MAP.pick_target(doc, result, {"kind": "body", "body": piece}).target == APPEARANCE.body_target(piece), "Texture Map Controls should edit the piece's own entry.")
	doc.appearances.erase(APPEARANCE.body_target(piece))
	_expect(APPEARANCE.build_mesh(doc, piece, piece_shape, TESSELLATE.tessellate(piece_shape), null).ids == PackedStringArray([RED])
		and TEXTURE_MAP.pick_target(doc, result, {"kind": "body", "body": piece}).target == APPEARANCE.body_target(source),
		"Without its own the piece should show (and edit) its source body's.")


# --- Review fixes ----------------------------------------------------------------------------

## A face appearance follows the face through features that split it: a groove across the deck's
## painted top leaves two pieces ("f1:y+#0", "f1:y+#1") that both keep the paint (they fell back
## to the default), in the bake, resolve and Texture Map Controls, until a piece gets its own;
## Split Body through it leaves a painted piece on each body. A pocket only changes the face.
func _check_split_faces() -> void:
	_expect(APPEARANCE.face_name_chain("f1:y+#0#1") == PackedStringArray(["f1:y+#0#1", "f1:y+#0", "f1:y+"])
		and APPEARANCE.face_name_chain("f3:g(s2)") == PackedStringArray(["f3:g(s2)"]) and APPEARANCE.face_name_chain("a#b") == PackedStringArray(["a#b"])
		and APPEARANCE.face_name_chain("#1") == PackedStringArray(["#1"]) and APPEARANCE.face_name_chain("f1:x+#") == PackedStringArray(["f1:x+#"]),
		"Split face names should lead back to the faces they came from, through #<digits> only.")
	var doc: Resource = DOCUMENT.new()
	var deck := _add_box(doc, Vector3(0.3, 0.02, 0.1), Vector3.ZERO)
	var body_id: String = deck.options.body_id
	var top := APPEARANCE.face_target(body_id, "f1:y+")
	doc.appearances[top] = {"material": CHROME}
	_add_box_op(doc, Vector3(0.04, 0.01, 0.04), Vector3(-0.08, 0.012, 0.0), OPERATIONS.CUT)
	var pieces := _top_looks(doc, body_id, REGEN.rebuild(doc, kernel))
	_expect(pieces == {"f1:y+": CHROME}, "A pocket should keep the top's name and paint (%s)." % pieces)
	_add_box_op(doc, Vector3(0.02, 0.01, 0.2), Vector3(0.05, 0.012, 0.0), OPERATIONS.CUT)
	var result := REGEN.rebuild(doc, kernel)
	pieces = _top_looks(doc, body_id, result)
	_expect(pieces == {"f1:y+#0": CHROME, "f1:y+#1": CHROME}, "Both pieces of a top a groove splits should keep its paint (%s)." % pieces)
	var shape: RefCounted = result.bodies[body_id].shape
	for piece in ["f1:y+#0", "f1:y+#1"]:
		var r := APPEARANCE.resolve(doc, body_id, piece)
		_expect(r.material == CHROME and r.target == top and r.source == "face", "%s should read the top's entry (%s)." % [piece, r])
		var pick := TEXTURE_MAP.pick_target(doc, result, {"kind": "face", "body": body_id, "name": piece})
		_expect(pick.target == top and int(pick.face) == int(shape.find_face(piece)), "Texture Map Controls should edit the top's entry from %s (%s)." % [piece, pick])
	var found := TEXTURE_MAP.ref_for_target(doc, result, top)
	_expect(str(found.get("kind", "")) == "face" and ["f1:y+#0", "f1:y+#1"].has(str(found.get("name", ""))) and str(found.get("body", "")) == body_id,
		"With nothing selected the command should find a piece of the split face (%s)." % [found])
	var part := await _bake(doc)
	var node: MeshInstance3D = part.body_nodes().get(body_id)
	_expect(node != null and node.mesh.get_surface_count() == 2 and node.mesh.surface_get_material(1) == MATERIAL_LIBRARY.material(CHROME),
		"The baked deck should still show its chrome top.")
	part.free()
	doc.appearances[APPEARANCE.face_target(body_id, "f1:y+#1")] = {"material": RED}
	pieces = _top_looks(doc, body_id, result)
	_expect(pieces == {"f1:y+#0": CHROME, "f1:y+#1": RED}, "A piece's own entry should beat the one it inherits (%s)." % pieces)
	# Split Body 10 mm off the middle of the painted top.
	doc = DOCUMENT.new()
	var box := _add_box(doc, Vector3(0.1, 0.02, 0.2), Vector3.ZERO)
	var source: String = box.options.body_id
	doc.appearances[APPEARANCE.face_target(source, "f1:y+")] = {"material": CHROME}
	var plane: Resource = doc.add_feature("plane", "Plane", {"distance": doc.make_input("10 mm", "length")}, {"method": "offset", "plane": [{"kind": "origin", "name": "yz"}]})
	doc.add_feature("split_body", "Split Body", {}, {"body": [{"kind": "body", "body": source}], "tool": [{"kind": "construct", "feature": plane.id}]})
	var split := REGEN.rebuild(doc, kernel)
	var shown := {}
	for id in split.bodies:
		var looks := _top_looks(doc, str(id), split)
		for face_name in looks:
			shown["%s %s" % [id, face_name]] = looks[face_name]
	_expect(split.bodies.size() == 2 and shown.size() == 2 and shown.values() == [CHROME, CHROME],
		"Split Body should leave a chrome piece of the top on each body (%s)." % shown)


## A decal placed with no "up" (as Insert > Decal stores it) reads upright and unmirrored on every
## wall: the image's top (-Z) up the world, its right to the right of someone facing the wall. On
## walls facing -X or -Z it came out turned half round. On tops the image's top stays toward -Z,
## and on sloped faces it points up the slope. Baked Decal nodes on the -X and -Z walls agree.
func _check_decal_upright() -> void:
	var wrong := []
	for i in 24:
		var a := deg_to_rad(i * 15.0)
		var n := Vector3(cos(a), 0.0, sin(a))
		var t := APPEARANCE.decal_transform({"normal": n, "up": Vector3.ZERO, "rotation": 0.0, "size": Vector2(0.02, 0.01)})
		if (-t.basis.z).distance_to(Vector3.UP) > 1e-6 or t.basis.x.distance_to(Vector3.UP.cross(n)) > 1e-6 or t.basis.y.distance_to(n) > 1e-6:
			wrong.append(i * 15)
	_expect(wrong.is_empty(), "Decals should stand upright, unmirrored, on every wall (wrong at %s degrees from +X toward +Z)." % [wrong])
	var on_top := APPEARANCE.decal_transform({"normal": Vector3.UP})
	_expect((-on_top.basis.z).distance_to(Vector3.FORWARD) < 1e-6 and on_top.basis.x.distance_to(Vector3.RIGHT) < 1e-6, "On a top the image's top should stay toward -Z (%s)." % on_top.basis)
	for n in [Vector3(-0.8, 0.5, 0.33).normalized(), Vector3(0.3, 0.6, -0.74).normalized(), Vector3(0.75, 0.66, -0.001).normalized()]:
		var t := APPEARANCE.decal_transform({"normal": n})
		var uphill: Vector3 = (Vector3.UP - n * n.y).normalized()
		_expect((-t.basis.z).distance_to(uphill) < 1e-6 and t.basis.determinant() > 0.0, "On the slope %s the image's top should point up the slope (%s)." % [n, t.basis])
	# Baked, as Insert > Decal writes them: the face's normal at the point, no up.
	var doc: Resource = DOCUMENT.new()
	var box := _add_box(doc, Vector3(0.1, 0.05, 0.1), Vector3.ZERO)
	var body_id: String = box.options.body_id
	var shape: RefCounted = REGEN.rebuild(doc, kernel).bodies[body_id].shape
	for item in [["West", Vector3.LEFT], ["North", Vector3.FORWARD], ["East", Vector3.RIGHT], ["South", Vector3.BACK]]:
		var f := _face_index(shape, item[1])
		var at: Vector3 = shape.face_info(f).point
		doc.decals.append({"id": item[0], "name": item[0], "image": "res://icon.svg", "body": body_id, "face": str(shape.get_face_names()[f]), "position": at,
			"normal": shape.face_normal_at(f, at), "up": Vector3.ZERO, "size": Vector2(0.02, 0.01), "rotation": 0.0, "visible": true})
	var part := await _bake(doc)
	var node: MeshInstance3D = part.body_nodes().get(body_id)
	for item in [["West", Vector3.LEFT], ["North", Vector3.FORWARD], ["East", Vector3.RIGHT], ["South", Vector3.BACK]]:
		var decal := node.get_node_or_null(str(item[0])) as Decal if node != null else null
		_expect(decal != null and (-decal.transform.basis.z).distance_to(Vector3.UP) < 1e-5 and decal.transform.basis.x.distance_to(Vector3.UP.cross(item[1])) < 1e-5,
			"The baked decal on the %s wall should be upright and unmirrored (%s)." % [item[0], decal.transform.basis if decal != null else null])
	part.free()


## A decal follows its face: making the box taller carries the decal on its top up with it (it
## stayed at the old height, where its projection no longer reached the face); a groove that
## splits the top right under it moves it onto the nearest piece; with no face left it keeps its
## place. Without a kernel (a game) entries keep their stored place, and baking never changes them.
func _check_decal_follows_face() -> void:
	var doc: Resource = DOCUMENT.new()
	var box := _add_box(doc, Vector3(0.2, 0.02, 0.1), Vector3.ZERO)
	var body_id: String = box.options.body_id
	var stored := Vector3(0.03, 0.02, -0.01)
	doc.decals.append({"id": "logo", "name": "Logo", "image": "res://icon.svg", "body": body_id, "face": "f1:y+", "position": stored,
		"normal": Vector3.UP, "up": Vector3.ZERO, "size": Vector2(0.05, 0.05), "rotation": 0.0, "visible": true})
	doc.decals.append({"id": "stray", "name": "Stray", "image": "res://icon.svg", "body": body_id, "face": "f9:gone", "position": Vector3(3, 3, 3),
		"normal": Vector3.DOWN, "size": Vector2(0.01, 0.01), "visible": true})
	var part := await _bake(doc)
	var node: MeshInstance3D = part.body_nodes().get(body_id)
	var decal := node.get_node_or_null("Logo") as Decal if node != null else null
	_expect(decal != null and decal.position.distance_to(stored) < 1e-6, "The decal should bake where it was put.")
	if decal == null:
		part.free()
		return
	(box.inputs.height as Dictionary).expression = "0.06 m"
	part.apply_result(REGEN.rebuild(doc, kernel))
	await process_frame
	_expect(decal.position.distance_to(Vector3(0.03, 0.06, -0.01)) < 1e-6 and decal.transform.basis.y.distance_to(Vector3.UP) < 1e-6,
		"A taller box should carry the decal up with its top, to y = 0.06 (got %s)." % decal.position)
	_expect(absf(decal.position.y - 0.06) <= decal.size.y * 0.5, "The decal's projection should reach the moved top.")
	_expect(doc.decals[0].position == stored, "Baking should not change the decal entry (%s)." % doc.decals[0].position)
	var stray := node.get_node_or_null("Stray") as Decal
	_expect(stray != null and stray.position == Vector3(3, 3, 3), "A decal whose face can't be found should stay where it was.")
	var shape: RefCounted = REGEN.rebuild(doc, kernel).bodies[body_id].shape
	_expect(bool(APPEARANCE.placed_decal(doc.decals[1], shape, kernel).get("lost", false)), "A decal with no face near should be reported lost.")
	_expect(APPEARANCE.placed_decal(doc.decals[0], shape, null) == doc.decals[0], "Without a kernel an entry should keep its place.")
	# A groove across the top, x 25..45 mm, under the decal at x = 30 mm: the nearest piece's edge.
	_add_box_op(doc, Vector3(0.02, 0.01, 0.2), Vector3(0.035, 0.052, 0.0), OPERATIONS.CUT)
	var result := REGEN.rebuild(doc, kernel)
	var placed := APPEARANCE.placed_decal(doc.decals[0], result.bodies[body_id].shape, kernel)
	_expect(bool(placed.get("repaired", false)) and not placed.has("lost") and (placed.position as Vector3).distance_to(Vector3(0.025, 0.06, -0.01)) < 1e-6
		and (placed.normal as Vector3).distance_to(Vector3.UP) < 1e-6, "A groove splitting the top should move the decal onto the nearest piece (%s)." % placed)
	part.apply_result(result)
	await process_frame
	_expect(decal.position.distance_to(Vector3(0.025, 0.06, -0.01)) < 1e-6, "The baked decal should sit on that piece (%s)." % decal.position)
	part.free()


## Cylindrical and spherical mapping read unmirrored from the side each face faces: a tube's
## outside and its bore, a hollow ball's outside and its inside (the bore and the inside were
## mirrored), every triangle of them.
func _check_round_facing() -> void:
	var tube: RefCounted = kernel.boolean(kernel.make_cylinder(0.05, 0.1, Vector3.ZERO, Vector3.UP, "a"), kernel.make_cylinder(0.03, 0.1, Vector3.ZERO, Vector3.UP, "b"), 1, "t")
	var ball: RefCounted = kernel.boolean(kernel.make_sphere(0.05, Vector3.ZERO, "a"), kernel.make_sphere(0.03, Vector3.ZERO, "b"), 1, "h")
	for item in [["tube", tube, "cylinder", "cylindrical"], ["tube", tube, "cylinder", "spherical"], ["hollow ball", ball, "sphere", "spherical"]]:
		var shape: RefCounted = item[1]
		var tess := TESSELLATE.tessellate(shape)
		var radii := []
		for f in shape.face_count():
			var info: Dictionary = shape.face_info(f)
			if info.type != item[2]:
				continue
			radii.append(roundi(float(info.radius) * 1000.0))
			var corners := APPEARANCE.face_corner_uvs(shape, f, tess, _face_tris(tess, f), {"type": item[3], "scale": Vector2(0.05, 0.05)})
			var mirrored := 0
			for k in range(0, corners.size(), 3):
				# (Triangles round the axis take one angle: no area, only rounding.)
				if _winding(corners.slice(k, k + 3)) < -1e-6:
					mirrored += 1
			_expect(_winding(corners) > 0.0 and mirrored == 0, "%s mapping should not mirror the %s's r = %s face (winding %s, %d mirrored triangles)." % [item[3], item[0], info.radius, _winding(corners), mirrored])
		radii.sort()
		_expect(radii == [30, 50], "The %s should have an outer and an inner round face (%s mm)." % [item[0], radii])


## Tops tilted a hair either way keep the level top's texture direction (U along +X, V along +Z,
## as box mapping): tilting 0.05 degrees toward -Z turned automatic and planar mapping half round,
## and so did a planar axis tipped as much. Sloped walls still read upright: V runs down the slope.
func _check_tilted_tops() -> void:
	for tilt in [0.0, 0.05, -0.05, 0.5, -0.5, -2.0, 30.0, -30.0]:
		var shape: RefCounted = kernel.transform_shape(kernel.make_box(Vector3(0.2, 0.02, 0.2), Vector3(-0.1, -0.01, -0.1), "b"), Transform3D(Basis(Vector3.RIGHT, deg_to_rad(tilt)), Vector3.ZERO), "b")
		var tess := TESSELLATE.tessellate(shape)
		var top := -1
		for f in shape.face_count():
			if top < 0 or _face_normal(shape, f).y > _face_normal(shape, top).y:
				top = f
		for type in ["automatic", "planar", "box"]:
			var axes := _uv_axes(shape, top, tess, {"type": type, "scale": Vector2(0.05, 0.05)})
			_expect(axes[0].normalized().distance_to(Vector3.RIGHT) < 1e-4 and axes[1].normalized().z > 0.8,
				"%s mapping on a top tilted %s degrees should run U along +X and V along +Z (got %s)." % [type, tilt, axes])
	var level: RefCounted = kernel.make_box(Vector3(0.2, 0.02, 0.2), Vector3.ZERO, "l")
	var level_tess := TESSELLATE.tessellate(level)
	for tilt in [0.05, -0.05, -1.0]:
		var axis := Vector3.UP.rotated(Vector3.RIGHT, deg_to_rad(tilt))
		var axes := _uv_axes(level, _face_index(level, Vector3.UP), level_tess, {"type": "planar", "axis": axis, "scale": Vector2(0.05, 0.05)})
		_expect(axes[0].normalized().distance_to(Vector3.RIGHT) < 1e-4, "A planar axis tipped %s degrees should keep U along +X (got %s)." % [tilt, axes])
	# Walls of a box turned off every axis: V straight down each slope, unmirrored.
	var turned: RefCounted = kernel.transform_shape(kernel.make_box(Vector3(0.1, 0.06, 0.08), Vector3.ZERO, "w"), Transform3D(Basis.from_euler(Vector3(0.35, 0.6, 0.2)), Vector3.ZERO), "w")
	var turned_tess := TESSELLATE.tessellate(turned)
	var walls := 0
	for f in turned.face_count():
		var n := _face_normal(turned, f)
		if absf(n.y) >= maxf(absf(n.x), absf(n.z)):
			continue
		walls += 1
		var mapping := {"type": "automatic", "scale": Vector2(0.05, 0.05)}
		var axes := _uv_axes(turned, f, turned_tess, mapping)
		var downhill := -(Vector3.UP - n * n.y).normalized()
		_expect(axes[1].normalized().distance_to(downhill) < 1e-4 and _winding(APPEARANCE.face_corner_uvs(turned, f, turned_tess, _face_tris(turned_tess, f), mapping)) > 0.0,
			"Automatic mapping on the sloped wall %s should run V down the slope, unmirrored (got %s)." % [n, axes])
	_expect(walls == 4, "The turned box should have 4 walls (%d)." % walls)
	# A wall sloped about Z (normal about (0.75, 0.66, 0)) turned a hair either way about Y: the sign
	# of that hair used to decide whether the texture lay on its side one way or the other.
	for hair in [0.001, -0.001]:
		var basis := Basis(Vector3.UP, hair) * Basis(Vector3.BACK, deg_to_rad(41.35))
		var slope: RefCounted = kernel.transform_shape(kernel.make_box(Vector3(0.1, 0.06, 0.08), Vector3.ZERO, "s"), Transform3D(basis, Vector3.ZERO), "s")
		var slope_tess := TESSELLATE.tessellate(slope)
		var face := -1
		for f in slope.face_count():
			if face < 0 or _face_normal(slope, f).x > _face_normal(slope, face).x:
				face = f
		var n := _face_normal(slope, face)
		var axes := _uv_axes(slope, face, slope_tess, {"type": "automatic", "scale": Vector2(0.05, 0.05)})
		_expect(axes[1].normalized().distance_to(-(Vector3.UP - n * n.y).normalized()) < 1e-4,
			"Automatic mapping on the wall %s should run V down its slope (got %s)." % [n, axes])


## Spherical mapping about +Y (the default) on a sphere whose poles lie on Z (kernel.make_sphere):
## no vertex sits on the projection axis, and two triangles with an edge through it each took half
## a turn of texture (3.14 repeats at r = scale). Triangles round the axis now take one angle, and
## no triangle spans more than about a quarter turn. About the sphere's own poles nothing changes.
func _check_sphere_poles() -> void:
	var r := 0.05
	var scale := 0.05
	var ball: RefCounted = kernel.make_sphere(r, Vector3.ZERO, "s")
	var tess := TESSELLATE.tessellate(ball)
	var doc: Resource = DOCUMENT.new()
	doc.bodies["body1"] = {"name": "Body1", "visible": true, "component": ""}
	var turn := TAU * r / scale
	for item in [[Vector3.ZERO, 0.3], [Vector3.BACK, 0.05]]:
		var mapping := {"type": "spherical", "scale": Vector2(scale, scale)}
		if not (item[0] as Vector3).is_zero_approx():
			mapping["axis"] = item[0]
		doc.appearances["body:body1"] = {"material": BLUE, "mapping": mapping}
		var arrays := (APPEARANCE.build_mesh(doc, "body1", ball, tess, null).mesh as ArrayMesh).surface_get_arrays(0)
		var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var frame := SKETCH_DATA.face_plane(Vector3.ZERO, Vector3.UP if (item[0] as Vector3).is_zero_approx() else item[0])
		var widest := 0.0
		var around := 0
		var around_span := 0.0
		for k in range(0, indices.size(), 3):
			var lo := INF
			var hi := -INF
			var angles: Array[float] = []
			for j in 3:
				var p := positions[indices[k + j]]
				lo = minf(lo, uvs[indices[k + j]].x)
				hi = maxf(hi, uvs[indices[k + j]].x)
				var flat := Vector2(p.dot(frame.x), p.dot(frame.y))
				if flat.length() > 1e-6:
					angles.append(atan2(flat.y, flat.x))
			widest = maxf(widest, (hi - lo) / turn)
			# Corners spread so no half turn is free of them: round the axis, or an edge through it.
			if angles.size() == 3:
				angles.sort()
				var gap := maxf(angles[0] + TAU - angles[2], maxf(angles[1] - angles[0], angles[2] - angles[1]))
				if gap < PI + 1e-4:
					around += 1
					around_span = maxf(around_span, hi - lo)
		_expect(widest < float(item[1]), "Spherical mapping about %s should spread no triangle over more than %s of a turn (widest %s)." % [item[0], item[1], widest])
		if (item[0] as Vector3).is_zero_approx():
			_expect(around >= 2 and around_span < 1e-5, "The triangles round the +Y axis should each take one angle (%d of them, widest %s repeats)." % [around, around_span])


## The Sphere primitive is built with its poles on +Y (an exact quarter turn of the kernel's
## Z-pole sphere, so its face stays an analytic sphere named as before): spherical mapping about
## the default axis meets real pole vertices and spreads no triangle over a twentieth of a turn.
func _check_sphere_primitive_poles() -> void:
	var center := Vector3(0.1, 0.2, -0.3)
	var doc: Resource = DOCUMENT.new()
	var feature: Resource = doc.add_feature("sphere", "Sphere", {"diameter": doc.make_input("100 mm", "length")},
		{"operation": OPERATIONS.NEW_BODY, "position": center})
	feature.options.body_id = doc.new_body(feature.id)
	var body_id := str(feature.options.body_id)
	var result := REGEN.rebuild(doc, kernel)
	var shape: RefCounted = result.get("bodies", {}).get(body_id, {}).get("shape")
	_expect(shape != null, "The Sphere primitive should build (%s)." % [result.get("errors", {})])
	if shape == null:
		return
	var info: Dictionary = shape.face_info(0)
	_expect(str(info.get("type", "")) == "sphere" and (info.get("center", Vector3.INF) as Vector3).distance_to(center) < 1e-6
		and shape.get_face_names() == PackedStringArray([feature.id + ":surface"]) and absf(float(shape.volume()) - 4.0 / 3.0 * PI * 0.05 ** 3) < 1e-9,
		"The turned sphere should stay one analytic sphere face, named as before, with its volume (%s, %s)." % [info, shape.get_face_names()])
	var tess := TESSELLATE.tessellate(shape)
	var on_axis := 0
	for p in tess.positions:
		on_axis += 1 if Vector2(p.x - center.x, p.z - center.z).length() < 1e-6 else 0
	_expect(on_axis >= 2, "The sphere's poles should lie on the vertical axis through its center (%d vertices there)." % on_axis)
	doc.appearances["body:" + body_id] = {"material": BLUE, "mapping": {"type": "spherical", "origin": center, "scale": Vector2(0.05, 0.05)}}
	var arrays := (APPEARANCE.build_mesh(doc, body_id, shape, tess, null).mesh as ArrayMesh).surface_get_arrays(0)
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var widest := 0.0
	var lowest := INF
	var highest := -INF
	for k in range(0, indices.size(), 3):
		var lo := INF
		var hi := -INF
		for j in 3:
			lo = minf(lo, uvs[indices[k + j]].x)
			hi = maxf(hi, uvs[indices[k + j]].x)
		widest = maxf(widest, (hi - lo) / TAU)
		lowest = minf(lowest, lo)
		highest = maxf(highest, hi)
	_expect(widest < 0.05 and absf((highest - lowest) - TAU) < 1e-3,
		"Default spherical mapping on the primitive should spread no triangle over 0.05 turn and span one turn (widest %s, span %s)." % [widest, (highest - lowest) / TAU])


# --- Helpers ---------------------------------------------------------------------------------

## The faces of body_id facing straight up at y = 0.02 (a 20 mm deck's top), by name -> appearance
## id they bake with.
func _top_looks(doc: Resource, body_id: String, result: Dictionary) -> Dictionary:
	var shape: RefCounted = result.bodies[body_id].shape
	var built := APPEARANCE.build_mesh(doc, body_id, shape, TESSELLATE.tessellate(shape), null)
	var names: PackedStringArray = shape.get_face_names()
	var looks := {}
	for f in shape.face_count():
		var info: Dictionary = shape.face_info(f)
		if info.get("planar", false) and (info.normal as Vector3).distance_to(Vector3.UP) < 1e-6 and absf((info.point as Vector3).y - 0.02) < 1e-6:
			var s: int = (built.face_surfaces as PackedInt32Array)[f]
			looks[str(names[f])] = (built.ids as PackedStringArray)[s] if s >= 0 else "?"
	return looks


## A flat face's normal (face_info has none for faces a transform turned into general surfaces).
func _face_normal(shape: RefCounted, face: int) -> Vector3:
	return shape.face_normal_at(face, shape.face_info(face).point)


## The world vectors one texture repeat of U and V span on a face (measured on its first triangle).
func _uv_axes(shape: RefCounted, face: int, tess: Dictionary, mapping: Dictionary) -> Array[Vector3]:
	var tris := _face_tris(tess, face)
	var corners := APPEARANCE.face_corner_uvs(shape, face, tess, tris.slice(0, 1), mapping)
	var indices: PackedInt32Array = tess.indices
	var positions: PackedVector3Array = tess.positions
	var p0 := positions[indices[tris[0] * 3]]
	var e1 := positions[indices[tris[0] * 3 + 1]] - p0
	var e2 := positions[indices[tris[0] * 3 + 2]] - p0
	var d1 := corners[1] - corners[0]
	var d2 := corners[2] - corners[0]
	var det := d1.x * d2.y - d2.x * d1.y
	if absf(det) < 1e-20:
		return [Vector3.ZERO, Vector3.ZERO]
	return [(e1 * d2.y - e2 * d1.y) / det, (e2 * d1.x - e1 * d2.x) / det]


func _add_box_op(doc: Resource, size: Vector3, position: Vector3, operation: String) -> Resource:
	return doc.add_feature("box", "Box", {
		"length": doc.make_input("%f m" % size.x, "length"), "height": doc.make_input("%f m" % size.y, "length"),
		"width": doc.make_input("%f m" % size.z, "length"),
	}, {"operation": operation, "position": position})


## values with one key set (a copy).
func _with(values: Dictionary, key: String, value: Variant) -> Dictionary:
	var copy := values.duplicate(true)
	copy[key] = value
	return copy

func _bake(doc: Resource) -> Node3D:
	var part: Node3D = CAD_PART.new()
	part.name = "Part"
	part.document = doc
	root.add_child(part)
	part.apply_result(REGEN.rebuild(doc, kernel))
	await process_frame
	return part


func _add_box(doc: Resource, size: Vector3, position: Vector3) -> Resource:
	var feature: Resource = doc.add_feature("box", "Box", {
		"length": doc.make_input("%f m" % size.x, "length"), "height": doc.make_input("%f m" % size.y, "length"),
		"width": doc.make_input("%f m" % size.z, "length"),
	}, {"operation": OPERATIONS.NEW_BODY, "position": position})
	feature.options.body_id = doc.new_body(feature.id)
	return feature


func _face_index(shape: RefCounted, normal: Vector3) -> int:
	for f in shape.face_count():
		var info: Dictionary = shape.face_info(f)
		if info.get("planar", false) and (info.normal as Vector3).distance_to(normal) < 1e-6:
			return f
	return -1


func _face_name(shape: RefCounted, normal: Vector3) -> String:
	return str(shape.get_face_names()[_face_index(shape, normal)])


func _face_tris(tess: Dictionary, face: int) -> PackedInt32Array:
	var tris := PackedInt32Array()
	var face_ids: PackedInt32Array = tess.face_ids
	for t in face_ids.size():
		if face_ids[t] == face:
			tris.append(t)
	return tris


func _face_vertices(tess: Dictionary, face: int) -> PackedInt32Array:
	var indices: PackedInt32Array = tess.indices
	var result := PackedInt32Array()
	for t in _face_tris(tess, face):
		for c in 3:
			if not result.has(indices[t * 3 + c]):
				result.append(indices[t * 3 + c])
	return result


func _uv_span(uvs: PackedVector2Array) -> Vector2:
	if uvs.is_empty():
		return Vector2.ZERO
	var lo := uvs[0]
	var hi := uvs[0]
	for uv in uvs:
		lo = lo.min(uv)
		hi = hi.max(uv)
	return hi - lo


## Positive when the texture is not mirrored (front faces are clockwise, v points down).
func _winding(corners: PackedVector2Array) -> float:
	var total := 0.0
	for k in range(0, corners.size(), 3):
		total += (corners[k + 1] - corners[k]).cross(corners[k + 2] - corners[k])
	return total


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error(message)
		print("FAIL: ", message)
