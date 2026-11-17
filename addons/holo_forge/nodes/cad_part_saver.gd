@tool
extends ResourceFormatSaver
## Tells Forge parts where their scene is being written, at the moment the editor writes it.
##
## The editor tells a scene's nodes before it writes the scene (they do not learn where to) and
## after (too late: the file is written). Between the two it hands the packed scene and its path
## to every resource saver in turn, this one first. This one writes nothing itself: it lets the
## parts of that scene put their baked meshes and large stored meshes beside the path
## (CadPart.scene_is_being_written), and then declines, so the editor's own saver writes the
## scene, which now points at those files. One Save is enough, and a Save As writes beside the
## new scene only. The plugin registers it (plugin.gd) and never saves a scene itself.

const CAD_PART := preload("res://addons/holo_forge/nodes/cad_part.gd")
## What this saver answers when the engine's savers are asked about its own probe (is_registered).
const MARK := "holo_forge_part_saver"

var _probe := Resource.new()


## Only a scene, and only while parts wait for their scene to be written (so no other save is
## ever looked at).
func _recognize(resource: Resource) -> bool:
	return resource is PackedScene and CAD_PART.parts_wait_for_save()


func _recognize_path(_resource: Resource, _path: String) -> bool:
	return true


## None: this saver offers no file type of its own (MARK for its own probe only).
func _get_recognized_extensions(resource: Resource) -> PackedStringArray:
	return PackedStringArray([MARK]) if resource == _probe else PackedStringArray()


## True while the engine has this saver in its list. (The editor drops every scripted saver when
## its list of script classes changes; CadPart puts this one back before a scene is written.)
func is_registered() -> bool:
	return ResourceSaver.get_recognized_extensions(_probe).has(MARK)


## Never the one that writes the scene: the next saver (the editor's own) does.
func _save(resource: Resource, path: String, _flags: int) -> Error:
	CAD_PART.scene_is_being_written(resource as PackedScene, path)
	return ERR_SKIP
