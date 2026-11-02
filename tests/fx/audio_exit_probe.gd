extends Node
## Helper for test_audio_exit (also passes when run alone): waits for the
## synthesised sounds, starts every one of them, and quits on the next frame,
## mid-playback. The parent test checks the output for leak warnings.
## OWNER: agent F.

func _ready() -> void:
	var t0 := Time.get_ticks_msec()
	while not AudioFX.is_ready() and Time.get_ticks_msec() - t0 < 5000:
		await get_tree().process_frame
	# On a loaded machine the background synth may not be done: build a few
	# short sounds here so AudioFX's own players still play mid-quit.
	var ids: Array[StringName] = AudioFX.get_ids()
	if not AudioFX.is_ready():
		ids = [&"ui", &"punch", &"clank", &"miss"]
		for id in ids:
			var wav := AudioFX.generate(id, 0)
			AudioFX._mutex.lock()
			(AudioFX._streams[id] as Array).append(wav)
			AudioFX._mutex.unlock()
	var started := 0
	for id: StringName in ids:
		AudioFX.play(id, Vector3(1, 1, 1))
		AudioFX.play_ui(id)
		started += 2
	await get_tree().process_frame
	print("PROBE DONE playing=%s started=%d" % [AudioFX._used, started])
	get_tree().quit(0)
