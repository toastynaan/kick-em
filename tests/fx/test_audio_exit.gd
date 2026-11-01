extends Node
## Quitting while sounds play must not leak AudioStreamWAV / playbacks
## ("N ObjectDB instances were leaked at exit"). Runs audio_exit_probe.tscn in
## a child Godot (same copy, --fixed-fps 120 like tests/run_all.sh) three
## times and checks its output. OWNER: agent F.

const RUNS := 3

func _ready() -> void:
	var fails: Array[String] = []
	var root := ProjectSettings.globalize_path("res://")
	for i in RUNS:
		var out: Array = []
		var code := OS.execute(OS.get_executable_path(), ["--headless", "--path", root, "--fixed-fps", "120",
				"res://tests/fx/audio_exit_probe.tscn"], out, true)
		var text := "\n".join(out)
		var leaked := text.contains("leaked")
		var done := text.contains("PROBE DONE ready=true")
		print("run %d: exit %d, probe done %s, leaked %s" % [i + 1, code, done, leaked])
		if code != 0 or not done:
			fails.append("probe run %d failed (exit %d)" % [i + 1, code])
		if leaked:
			fails.append("run %d leaked at exit: %s" % [i + 1, text.substr(text.find("WARNING"), 120)])
	for f in fails:
		print("FAIL ", f)
	print("PASS test_audio_exit" if fails.is_empty() else "FAIL test_audio_exit")
	get_tree().quit(0 if fails.is_empty() else 1)
