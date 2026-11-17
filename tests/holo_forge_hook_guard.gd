@tool
extends RefCounted
## Keeps an editor hook run (godot --editor -- --holo-forge-<name>-test) off the user's project.
##
## Why: an editor hook starts the user's editor on the user's project. That editor opens the
## scenes, scripts and shaders of the user's last session, and every scene save in it (a test's as
## much as the user's own Ctrl+S) also writes each loaded resource file the editor has marked as
## edited, whatever scene it belongs to. Measured in Godot 4.7.1: a loaded .tres that has
## sub-resources of its own is marked from the moment it is loaded, so any scene save writes it
## again (same bytes, new modified time); a .tres without sub-resources is left alone. The game's
## plugins, autoloads and scripts load such files when the editor starts, with no scene open. A
## hook must not write a file it does not own, so:
##   - a hook never lets the editor save a scene while one of the project's resource files is
##     loaded (loaded_user_resources); it saves its own scene alone instead (pack it, write it
##     with ResourceSaver, tell its nodes before and after, as tests/holo_forge_save_editor_test.gd
##     does);
##   - every hook run is watched, and fails when a file outside its own folders changed.
##
## What the plugin does with this for every hook (addons/holo_forge/plugin.gd):
##   begin()  when the plugin enters the tree, before the editor reads its layout:
##            - keeps the bytes of .godot/editor/editor_layout.cfg and project_metadata.cfg,
##            - takes the user's open scenes, scripts and shaders out of the layout the editor is
##              about to read, so none of them is opened in the hook's editor,
##            - notes the modified time and size of every file of the project outside the hook's
##              own folders.
##   end()    when the plugin leaves the tree (the hook has called quit): compares the files with
##            the notes, puts the two editor files back byte for byte, and returns what changed;
##            the plugin prints "FAIL Holo Forge HOOK GUARD: ..." and makes the run exit with 1.
## A hook can also ask while it runs (plugin.hook_guard):
##   loaded_user_resources()  the project's resource files the editor holds in memory (the only
##                            ones a scene save of the editor's could write).
##   changed_files()          what changed since begin(); a hook that saves fails on any before
##                            it prints PASS.
##
## Hooks that overlap (several teams) share one kept copy: the first one in keeps it, the last one
## out puts it back. A hook that was killed leaves its copy behind; the next start of the plugin
## (a hook's or the user's editor) puts it back, unless the user's editor has used the layout
## since (heal()).

const LAYOUT := "res://.godot/editor/editor_layout.cfg"
const METADATA := "res://.godot/editor/project_metadata.cfg"
## Where the kept copies and the running hooks' markers are (inside .godot: not project content).
const SESSION := "res://.godot/holo_forge_hook_session"
const KEPT := {LAYOUT: "editor_layout.cfg.kept", METADATA: "project_metadata.cfg.kept"}
## What makes the editor open the user's last session, by section of the layout.
const SESSION_KEYS := {
	"EditorNode": ["open_scenes", "current_scene"],
	"ScriptEditor": ["open_scripts", "selected_script", "open_help"],
	"ShaderEditor": ["open_shaders", "selected_shader"],
}
## Folders a hook may write in (its test folder, the editor's own caches, the library other teams
## rebuild while hooks run).
const OWN_FOLDERS := ["res://.godot/", "res://tests/holo_forge/", "res://addons/holo_forge/bin/"]
## Folders the Holo Forge teams edit by hand while hooks run: there only the kinds of file an
## editor save writes are watched (scenes and resources), not sources, notes or build output.
const TEAM_FOLDERS := ["res://addons/holo_forge/", "res://tests/", "res://docs/"]
const TEAM_WATCHED := ["tscn", "scn", "tres", "res", "material", "gdshader", "gdshaderinc", "theme", "anim", "mesh", "shape"]
## File kinds that are never a resource the editor would save (not asked about in
## loaded_user_resources).
const NOT_RESOURCES := ["tscn", "scn", "import", "uid", "md", "txt", "cfg", "godot", "py", "sh", "ps1", "cpp", "h", "hpp", "dll", "lib", "log", "zip", "blend", "blend1"]

var _stamps := {}
var _marker := ""
## This hook's marker, held open for as long as the hook runs (see _alive).
var _marker_held: FileAccess
var _begun := false
var _ended := false
var _changed := PackedStringArray()


## Starts guarding this hook run (see the top). Call before the editor reads its layout.
func begin() -> void:
	if _begun:
		return
	_begun = true
	heal()
	var dir := ProjectSettings.globalize_path(SESSION)
	DirAccess.make_dir_recursive_absolute(dir)
	if _others_running().is_empty() and not _has_kept():
		for path in KEPT:
			_keep(path)
	_marker = SESSION.path_join("hook_%d" % OS.get_process_id())
	var mark := FileAccess.open(_marker, FileAccess.WRITE)
	if mark != null:
		mark.store_string(" ".join(OS.get_cmdline_user_args()))
		mark.close()
	_marker_held = FileAccess.open(_marker, FileAccess.READ)
	_close_user_session()
	_stamps = stamps()


## Ends guarding: what changed (see changed_files) and the two editor files back as they were.
## Safe to call more than once.
func end() -> PackedStringArray:
	if not _begun or _ended:
		return _changed
	_changed = changed_files()
	_ended = true
	if _marker != "":
		_marker_held = null
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_marker))
	if _others_running().is_empty():
		_put_back()
	return _changed


## Puts back what a hook that never ended (killed, crashed) left behind. Does nothing while a hook
## still runs. The kept layout is put back only when the layout on disk is still a hook's (no
## scene open outside res://tests/): after the user's own editor has written it, it is the user's
## and stays; the kept copy is dropped either way.
func heal() -> void:
	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(SESSION)):
		return
	if not _others_running().is_empty():
		return
	_put_back()


## Every watched file of the project: path -> [modified time, size]. Everything outside
## OWN_FOLDERS, and inside TEAM_FOLDERS only the TEAM_WATCHED kinds.
func stamps(folder := "res://", into := {}) -> Dictionary:
	var dir := DirAccess.open(folder)
	if dir == null:
		return into
	dir.include_hidden = true
	var team := _inside(folder.path_join("x"), TEAM_FOLDERS)
	for file in dir.get_files():
		var path := folder.path_join(file)
		if _inside(path, OWN_FOLDERS) or (team and not TEAM_WATCHED.has(file.get_extension().to_lower())):
			continue
		var stream := FileAccess.open(path, FileAccess.READ)
		into[path] = [FileAccess.get_modified_time(path), stream.get_length() if stream != null else -1]
	for sub in dir.get_directories():
		if sub == ".git" or _inside(folder.path_join(sub) + "/", OWN_FOLDERS):
			continue
		stamps(folder.path_join(sub), into)
	return into


## The watched files that are not as they were at begin(), each with what happened to it:
## "(new)", "(deleted)", "(rewritten: size a -> b)" or "(rewritten: same size, new modified
## time)". This run did it, or something else did while it ran; either way the hook fails.
func changed_files() -> PackedStringArray:
	if _ended:
		return _changed
	var changed := PackedStringArray()
	var now := stamps()
	for path in now:
		if not _stamps.has(path):
			changed.append("%s (new)" % path)
		elif _stamps[path] != now[path]:
			if _stamps[path][1] != now[path][1]:
				changed.append("%s (rewritten: size %d -> %d)" % [path, _stamps[path][1], now[path][1]])
			else:
				changed.append("%s (rewritten: same size, new modified time)" % path)
	for path in _stamps:
		if not now.has(path):
			changed.append("%s (deleted)" % path)
	changed.sort()
	return changed


## The project's resource files (outside OWN_FOLDERS, res://addons/holo_forge/ and res://tests/)
## that the editor holds in memory now. A scene save writes, besides the scene, exactly the
## loaded resource files the editor has marked as edited (scenes excepted); whether one is marked
## cannot be asked, so a hook lets the editor save only while none is loaded at all. (Imported
## files, scenes and scripts are not counted: the editor's save cannot write the first two, and
## writes a script only from the script editor, see loaded_user_scripts.)
func loaded_user_resources() -> PackedStringArray:
	var loaded := PackedStringArray()
	for path in stamps():
		var kind := str(path).get_extension().to_lower()
		if str(path).begins_with("res://addons/holo_forge/") or str(path).begins_with("res://tests/") or NOT_RESOURCES.has(kind) or kind == "gd":
			continue
		if FileAccess.file_exists(str(path) + ".import"):
			continue
		if ResourceLoader.has_cached(path):
			loaded.append(path)
	loaded.sort()
	return loaded


## The user's scripts the editor holds in memory now (a save writes a script only when the script
## editor has it open and changed; begin() keeps the user's scripts out of the script editor).
func loaded_user_scripts() -> PackedStringArray:
	var loaded := PackedStringArray()
	for path in stamps():
		if str(path).get_extension().to_lower() == "gd" and not str(path).begins_with("res://addons/") and not str(path).begins_with("res://tests/") and ResourceLoader.has_cached(path):
			loaded.append(path)
	return loaded


# --- inside ---------------------------------------------------------------------------------------

static func _inside(path: String, folders: Array) -> bool:
	for folder in folders:
		if path.begins_with(folder):
			return true
	return false


func _kept_path(path: String) -> String:
	return SESSION.path_join(str(KEPT[path]))


func _has_kept() -> bool:
	for path in KEPT:
		if FileAccess.file_exists(_kept_path(path)) or FileAccess.file_exists(_kept_path(path) + ".absent"):
			return true
	return false


## Keeps a file's bytes (or that it was not there).
func _keep(path: String) -> void:
	var kept := _kept_path(path)
	if not FileAccess.file_exists(path):
		var none := FileAccess.open(kept + ".absent", FileAccess.WRITE)
		if none != null:
			none.close()
		return
	var out := FileAccess.open(kept + ".tmp", FileAccess.WRITE)
	if out == null:
		return
	out.store_buffer(FileAccess.get_file_as_bytes(path))
	out.close()
	DirAccess.rename_absolute(ProjectSettings.globalize_path(kept + ".tmp"), ProjectSettings.globalize_path(kept))


## The markers of hook processes that still run, this one excepted (markers of ended processes
## are removed).
func _others_running() -> PackedStringArray:
	var running := PackedStringArray()
	var dir := DirAccess.open(SESSION)
	if dir == null:
		return running
	for file in dir.get_files():
		if file.begins_with("hook_") and SESSION.path_join(file) != _marker and _alive(file):
			running.append(file)
	return running


## True when the hook process a marker belongs to still runs; the marker of one that ended is
## removed. A running hook holds its marker open: on Windows a file another process holds open
## cannot be deleted, so the marker of an ended hook goes and that of a running one stays.
## (OS.is_process_running only knows this process's own children.) Elsewhere the process is asked.
func _alive(file: String) -> bool:
	var path := ProjectSettings.globalize_path(SESSION.path_join(file))
	if OS.get_name() == "Windows":
		return DirAccess.remove_absolute(path) != OK
	var pid := int(file.trim_prefix("hook_"))
	if pid > 0 and OS.execute("kill", ["-0", str(pid)]) == 0:
		return true
	DirAccess.remove_absolute(path)
	return false


## The kept files back byte for byte, and the session folder gone. The layout (and with it the
## list of recent scenes) is put back only over a hook's layout (see heal).
func _put_back() -> void:
	if _layout_is_a_hooks():
		_reset_project_metadata()
		for path in KEPT:
			var kept := _kept_path(path)
			if FileAccess.file_exists(kept):
				var bytes := FileAccess.get_file_as_bytes(kept)
				if not FileAccess.file_exists(path) or FileAccess.get_file_as_bytes(path) != bytes:
					var out := FileAccess.open(path, FileAccess.WRITE)
					if out != null:
						out.store_buffer(bytes)
						out.close()
			elif FileAccess.file_exists(kept + ".absent") and FileAccess.file_exists(path):
				DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	var dir := DirAccess.open(SESSION)
	if dir != null:
		for file in dir.get_files():
			DirAccess.remove_absolute(ProjectSettings.globalize_path(SESSION.path_join(file)))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SESSION))


## The editor keeps the project metadata (recent scenes and the like) in memory and writes all of
## it whenever one value is set, also while it closes, after the plugins have left: so the values
## in memory are put back to the kept ones first (through the editor's settings), and what the
## editor writes later is the kept content again.
func _reset_project_metadata() -> void:
	var kept := ConfigFile.new()
	var now := ConfigFile.new()
	var editor: Object = Engine.get_singleton("EditorInterface") if Engine.is_editor_hint() else null
	if editor == null or not FileAccess.file_exists(_kept_path(METADATA)) or kept.load(_kept_path(METADATA)) != OK or now.load(METADATA) != OK:
		return
	var settings: Object = editor.get_editor_settings()
	for section in now.get_sections():
		for key in now.get_section_keys(section):
			if not kept.has_section_key(section, key):
				settings.set_project_metadata(section, key, null)
	for section in kept.get_sections():
		for key in kept.get_section_keys(section):
			var value: Variant = kept.get_value(section, key)
			if not now.has_section_key(section, key) or var_to_str(now.get_value(section, key)) != var_to_str(value):
				settings.set_project_metadata(section, key, value)


## True when the layout on disk lists no open scene outside res://tests/ (what a hook's editor
## leaves; the user's has the user's scenes).
func _layout_is_a_hooks() -> bool:
	var layout := ConfigFile.new()
	if layout.load(LAYOUT) != OK:
		return true
	for scene in layout.get_value("EditorNode", "open_scenes", PackedStringArray()):
		if not str(scene).begins_with("res://tests/"):
			return false
	return true


## Takes the user's open scenes, scripts and shaders out of the layout the editor is about to read
## (the docks and everything else stay), so the hook's editor opens none of them.
func _close_user_session() -> void:
	var layout := ConfigFile.new()
	if layout.load(LAYOUT) != OK:
		return
	var touched := false
	for section in SESSION_KEYS:
		for key in SESSION_KEYS[section]:
			if layout.has_section_key(section, key):
				layout.erase_section_key(section, key)
				touched = true
	if touched:
		layout.save(LAYOUT)
