extends Logger
## Counts engine and script errors (not warnings) so FX tests can fail on them.
## `errors` counts errors raised in or through FX code (scripts/fx, shaders,
## tests/fx); `other_errors` counts the rest (other modules), which tests only
## report. OWNER: agent F (fx tests).

const FX_PATHS := ["res://scripts/fx/", "res://shaders/", "res://tests/fx/"]

var errors := 0
var other_errors := 0
var last := ""
var last_other := ""
var _mutex := Mutex.new()

func _log_error(function: String, file: String, line: int, code: String, rationale: String,
		_editor_notify: bool, error_type: int, script_backtraces: Array[ScriptBacktrace]) -> void:
	if error_type == ERROR_TYPE_WARNING:
		return
	var text := "%s:%d %s() %s %s" % [file, line, function, code, rationale]
	var mine := _is_fx(file)
	var frames := ""
	for bt in script_backtraces:
		if bt == null:
			continue
		for i in bt.get_frame_count():
			var ff := bt.get_frame_file(i)
			frames += " <- %s:%d" % [ff, bt.get_frame_line(i)]
			# Only the innermost script frame decides who raised it.
			if i == 0 and _is_fx(ff):
				mine = true
	_mutex.lock()
	if mine:
		errors += 1
		last = text + frames
	else:
		other_errors += 1
		last_other = text + frames
	_mutex.unlock()

func _log_message(_message: String, _error: bool) -> void:
	pass

static func _is_fx(path: String) -> bool:
	for p in FX_PATHS:
		if path.begins_with(p):
			return true
	return false
