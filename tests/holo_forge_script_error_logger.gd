extends Logger
## Collects every GDScript runtime error ("SCRIPT ERROR") while a hook runs. A script error ends
## only the function it happens in, and the code that awaited it goes on, so without this a check
## section could break half way and still be reported as done. OS.add_logger() it at the start and
## OS.remove_logger() it at the end; read take() from the main thread (errors arrive from any).

var _lock := Mutex.new()
var _errors := PackedStringArray()


func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
	if error_type != ERROR_TYPE_SCRIPT:
		return
	_lock.lock()
	_errors.append("%s (%s:%d in %s)" % [rationale if rationale != "" else code, file, line, function])
	_lock.unlock()


func _log_message(_message: String, _error: bool) -> void:
	pass


## The errors since the last take(), cleared.
func take() -> PackedStringArray:
	_lock.lock()
	var out := _errors.duplicate()
	_errors.clear()
	_lock.unlock()
	return out
