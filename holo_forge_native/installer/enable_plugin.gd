extends SceneTree
## Used by the Holo Forge Windows installer (holo_forge_setup.iss): turns the Holo Forge plugin on in
## the project's Project Settings > Plugins, the way the editor does, by saving project.godot
## through Godot itself.
##
##     godot --headless --path <project> --script <this file>
##
## Prints "HOLO_FORGE_ENABLED" (it was turned on) or "HOLO_FORGE_ALREADY_ENABLED", and quits with 0;
## quits with 1 when project.godot couldn't be saved.

const PLUGIN := "res://addons/holo_forge/plugin.cfg"
const SETTING := "editor_plugins/enabled"


func _init() -> void:
	var enabled := PackedStringArray(ProjectSettings.get_setting(SETTING, PackedStringArray()))
	if enabled.has(PLUGIN):
		print("HOLO_FORGE_ALREADY_ENABLED")
		quit(0)
		return
	enabled.append(PLUGIN)
	ProjectSettings.set_setting(SETTING, enabled)
	var err := ProjectSettings.save()
	print("HOLO_FORGE_ENABLED" if err == OK else "HOLO_FORGE_ENABLE_FAILED %s" % error_string(err))
	quit(0 if err == OK else 1)
