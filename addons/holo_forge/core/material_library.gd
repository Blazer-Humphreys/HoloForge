@tool
extends RefCounted
## The appearance library: plain built-in finishes plus the project's texture sets.
##
## Appearance ids (what doc.appearances stores in "material"):
##   "builtin:<slug>"     a plain finish made here (no textures)
##   "library:<folder>"   a texture set in res://materials/material_library/<folder>/
##   "res://....tres"     any Godot Material resource (dragged in)
## Materials are made on first use and cached; texture sets load their maps only then, so
## listing the library never touches the (large) textures.

const LIBRARY_DIR := "res://materials/material_library"
const IMAGE_EXTENSIONS := ["png", "jpg", "jpeg", "webp", "tga", "bmp", "exr", "hdr"]
const MAP_KEYS := ["albedo", "normal", "roughness", "metallic", "ao", "gloss"]
## First matching token in a file name (split on "_") decides its map. The same rules as
## tools/import_habitat_paint_layers.gd: COL/NRM/GLOSS/ROUGHNESS/METALNESS/AO (textures.com),
## BaseColor/Normal/Roughness/Metallic/AmbientOcclusion (Poliigon), basecolor/color/diff,
## normal_gl, roughness, metallic, ambient_occlusion (Poly Haven).
const MAP_TOKENS := {
	"col": "albedo", "color": "albedo", "colour": "albedo", "basecolor": "albedo", "diff": "albedo",
	"diffuse": "albedo", "albedo": "albedo",
	"nrm": "normal", "normal": "normal", "nor": "normal",
	"roughness": "roughness", "rough": "roughness",
	"metallic": "metallic", "metalness": "metallic",
	"ao": "ao", "ambientocclusion": "ao", "ambient": "ao", "occlusion": "ao",
	"gloss": "gloss", "glossiness": "gloss",
	"preview": "preview", "preview1": "preview",
	# Maps a StandardMaterial3D appearance doesn't use.
	"disp": "", "displacement": "", "height": "", "bump": "", "overlay": "", "spec": "", "specular": "",
}

## slug -> [name, albedo Color, metallic, roughness, extra]; extra keys: "clearcoat", "glass".
const BUILTINS := {
	"plastic_glossy_white": ["Plastic Glossy White", Color(0.9, 0.9, 0.89), 0.0, 0.12, {}],
	"plastic_matte_black": ["Plastic Matte Black", Color(0.035, 0.035, 0.038), 0.0, 0.78, {}],
	"paint_red": ["Paint Red", Color(0.62, 0.04, 0.04), 0.0, 0.32, {"clearcoat": 0.06}],
	"paint_blue": ["Paint Blue", Color(0.04, 0.13, 0.55), 0.0, 0.32, {"clearcoat": 0.06}],
	"metal_steel_satin": ["Metal Steel Satin", Color(0.56, 0.57, 0.58), 1.0, 0.34, {}],
	"metal_aluminum_brushed": ["Metal Aluminum Brushed", Color(0.91, 0.92, 0.92), 1.0, 0.42, {}],
	"metal_chrome": ["Metal Chrome", Color(0.55, 0.56, 0.57), 1.0, 0.04, {}],
	"anodized_blue": ["Anodized Blue", Color(0.12, 0.3, 0.72), 1.0, 0.3, {}],
	"rubber_black": ["Rubber Black", Color(0.025, 0.025, 0.025), 0.0, 0.92, {}],
	"glass_clear": ["Glass Clear", Color(0.86, 0.92, 0.96, 0.18), 0.0, 0.03, {"glass": true}],
	"carbon_dark": ["Carbon Dark", Color(0.05, 0.05, 0.055), 0.25, 0.28, {"clearcoat": 0.04}],
}

static var _materials := {}
static var _sets: Array[Dictionary] = []
static var _scanned := false


## Every library entry: [{"id", "name", "preview": res:// path or "", "maps": {"albedo", "normal",
## "roughness", "metallic", "ao", "gloss": res:// path or ""}}], built-in finishes first, then
## the texture sets (folders without a base color map are left out). refresh rescans the folder.
static func sets(refresh := false) -> Array[Dictionary]:
	if refresh or not _scanned:
		_scan()
	var result: Array[Dictionary] = []
	for slug in BUILTINS:
		var maps := {}
		for key in MAP_KEYS:
			maps[key] = ""
		result.append({"id": "builtin:" + slug, "name": BUILTINS[slug][0], "preview": "", "maps": maps})
	for item in _sets:
		result.append(item.duplicate(true))
	return result


## One library entry by id (as in sets()), or {} for ids that aren't builtin or library sets.
static func entry(id: String) -> Dictionary:
	for e in sets():
		if e.id == id:
			return e
	return {}


## A readable name for any appearance id (library entries, or a Material file's name).
static func name_of(id: String) -> String:
	if id == "":
		return "Default"
	var e := entry(id)
	if not e.is_empty():
		return str(e.name)
	return id.get_file().get_basename().capitalize() if id.begins_with("res://") or id.begins_with("uid://") else id


## The Material for an appearance id, or null when it can't be made (unknown id, missing file).
## Built-in and library materials are cached, so every body with the same id shares one.
static func material(id: String) -> Material:
	if id == "":
		return null
	if id.begins_with("res://") or id.begins_with("uid://") or id.begins_with("user://"):
		# Godot caches loaded resources itself; a dragged-in Material is used as it is.
		var loaded: Resource = load(id) if ResourceLoader.exists(id) else null
		return loaded as Material
	if _materials.has(id):
		return _materials[id]
	var made: Material = null
	if id.begins_with("builtin:"):
		made = _builtin(id.trim_prefix("builtin:"))
	elif id.begins_with("library:"):
		var e := entry(id)
		if not e.is_empty():
			made = _textured(e)
	if made != null:
		made.resource_name = name_of(id)
		_materials[id] = made
	return made


## Drops cached materials (after the library folder changes).
static func clear_cache() -> void:
	_materials.clear()
	_scanned = false


static func _builtin(slug: String) -> StandardMaterial3D:
	if not BUILTINS.has(slug):
		return null
	var spec: Array = BUILTINS[slug]
	var m := StandardMaterial3D.new()
	m.albedo_color = spec[1]
	m.metallic = spec[2]
	m.roughness = spec[3]
	var extra: Dictionary = spec[4]
	if extra.has("clearcoat"):
		m.clearcoat_enabled = true
		m.clearcoat = 1.0
		m.clearcoat_roughness = float(extra.clearcoat)
	if extra.get("glass", false):
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX
		m.metallic_specular = 0.9
		# Both sides, so the far wall of a glass body shows through the near one.
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


static func _textured(e: Dictionary) -> StandardMaterial3D:
	var maps: Dictionary = e.maps
	var m := StandardMaterial3D.new()
	m.albedo_texture = _texture(maps.albedo)
	var normal := _texture(maps.normal)
	if normal != null:
		m.normal_enabled = true
		m.normal_texture = normal
	var roughness := _texture(maps.roughness)
	if roughness != null:
		# The texture is multiplied by the value.
		m.roughness = 1.0
		m.roughness_texture = roughness
	else:
		# A gloss map is roughness inverted, which StandardMaterial3D can't do: use a middle value.
		m.roughness = 0.5 if maps.gloss != "" else 0.8
	var metallic := _texture(maps.metallic)
	if metallic != null:
		m.metallic = 1.0
		m.metallic_texture = metallic
	var ao := _texture(maps.ao)
	if ao != null:
		m.ao_enabled = true
		m.ao_texture = ao
	return m


static func _texture(path: String) -> Texture2D:
	if path == "" or not ResourceLoader.exists(path):
		return null
	return load(path) as Texture2D


## An image file as a texture (decals, canvases): imported textures load as they are; a plain
## image file Godot hasn't imported (user://, a folder outside the project) is read directly.
static func load_texture(path: String) -> Texture2D:
	if path == "":
		return null
	if ResourceLoader.exists(path):
		var loaded: Resource = load(path)
		if loaded is Texture2D:
			return loaded
		if loaded is Image:
			return ImageTexture.create_from_image(loaded)
	if FileAccess.file_exists(path):
		var image := Image.load_from_file(path)
		if image != null and not image.is_empty():
			return ImageTexture.create_from_image(image)
	return null


static func _scan() -> void:
	_sets.clear()
	_scanned = true
	var folders := DirAccess.get_directories_at(LIBRARY_DIR)
	folders.sort()
	for folder in folders:
		if folder.begins_with("_") or folder.begins_with("."):
			continue
		var found := scan_folder(LIBRARY_DIR.path_join(folder))
		if found.maps.albedo == "":
			continue
		var name := readable_name(folder)
		var preview: String = found.preview
		if preview == "":
			# Poly Haven sets keep their previews in the shared _previews folder.
			var shared := LIBRARY_DIR.path_join("_previews").path_join(name + ".png")
			preview = shared if _file_exists(shared) else ""
		_sets.append({"id": "library:" + folder, "name": name, "preview": preview, "maps": found.maps})


## The maps in one texture-set folder: {"maps": {key: res:// path or ""}, "preview": path or ""}.
static func scan_folder(folder: String) -> Dictionary:
	var maps := {}
	for key in MAP_KEYS:
		maps[key] = ""
	var preview := ""
	var files := PackedStringArray()
	for file in DirAccess.get_files_at(folder):
		# Exported games only list the .import stubs; the textures still load by their own name.
		var base := file.trim_suffix(".import").trim_suffix(".remap")
		if IMAGE_EXTENSIONS.has(base.get_extension().to_lower()) and not files.has(base):
			files.append(base)
	files.sort()
	for file in files:
		var kind := map_kind(file)
		var path := folder.path_join(file)
		if kind == "preview":
			preview = path if preview == "" else preview
		elif kind != "" and maps[kind] == "":
			maps[kind] = path
		elif kind == "normal" and _is_directx(str(maps.normal)) and not _is_directx(path):
			# Prefer the OpenGL normal map (Godot's convention) when both are there.
			maps.normal = path
	return {"maps": maps, "preview": preview}


## Which map a texture file is ("albedo", "normal", ..., "preview"), or "" for unused files.
static func map_kind(file: String) -> String:
	for token in file.get_basename().to_lower().split("_", false):
		if MAP_TOKENS.has(token):
			return MAP_TOKENS[token]
	return ""


## "concrete_slabs_03_4k" -> "Concrete Slabs 03", "Poliigon_MetalGalvanizedZinc_7184" ->
## "Metal Galvanized Zinc", "GroundDirtRocky020" -> "Ground Dirt Rocky 020".
static func readable_name(folder: String) -> String:
	var text := folder.trim_prefix("Poliigon_")
	var parts := text.split("_", false)
	# Resolution tags (4k, 8K) and Poliigon's trailing catalogue numbers say nothing to a reader.
	while parts.size() > 1:
		var last := parts[parts.size() - 1].to_lower()
		var resolution := last.ends_with("k") and last.trim_suffix("k").is_valid_int()
		var catalogue := folder.begins_with("Poliigon_") and last.is_valid_int()
		if not resolution and not catalogue:
			break
		parts.remove_at(parts.size() - 1)
	return "_".join(parts).capitalize()


static func _is_directx(path: String) -> bool:
	return path.get_file().to_lower().split("_", false).has("dx")


static func _file_exists(path: String) -> bool:
	return FileAccess.file_exists(path) or FileAccess.file_exists(path + ".import")
