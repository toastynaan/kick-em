extends Node
## Helper for test_audio_exit (also passes when run alone): waits for the
## synthesised sounds, starts every one of them, and quits on the next frame,
## mid-playback. The parent test checks the output for leak warnings.
## OWNER: agent F.

func _ready() -> void:
	var t0 := Time.get_ticks_msec()
	while not AudioFX.is_ready() and Time.get_ticks_msec() - t0 < 20000:
		await get_tree().process_frame
	for id: StringName in AudioFX.get_ids():
		AudioFX.play(id, Vector3(1, 1, 1))
		AudioFX.play_ui(id)
	await get_tree().process_frame
	print("PROBE DONE ready=%s" % AudioFX.is_ready())
	get_tree().quit(0)
