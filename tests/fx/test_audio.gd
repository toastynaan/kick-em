extends Node
## Every AudioFX sound id synthesises a non-empty 16-bit mono 44.1 kHz
## AudioStreamWAV, shorter than 3 s, with no sample at int16 full scale
## (clipping). Also checks play()/play_ui() run without errors.

const MAX_SECONDS := 3.0

func _ready() -> void:
	var fails := 0
	var t0 := Time.get_ticks_msec()
	var total_samples := 0
	for id: StringName in AudioFX.get_ids():
		for v in 2:
			var wav: AudioStreamWAV = AudioFX.generate(id, v)
			if wav == null:
				print("FAIL %s v%d: null stream" % [id, v])
				fails += 1
				continue
			var data := wav.data
			var n := data.size() / 2
			total_samples += n
			var seconds := float(n) / wav.mix_rate
			var peak := 0
			var clipped := 0
			var sum_sq := 0.0
			for i in n:
				var s := data.decode_s16(i * 2)
				peak = maxi(peak, absi(s))
				if absi(s) >= 32767:
					clipped += 1
				sum_sq += float(s) * s
			var rms_db := linear_to_db(sqrt(sum_sq / maxf(n, 1)) / 32767.0)
			var ok := n > 0 and seconds < MAX_SECONDS and clipped == 0 and peak > 1000 \
					and wav.format == AudioStreamWAV.FORMAT_16_BITS and not wav.stereo \
					and wav.mix_rate == 44100
			if not ok:
				fails += 1
			if v == 0 or not ok:
				print("%s %-12s v%d  %.3f s  peak %d  rms %.1f dB  clipped %d" % [
					"ok  " if ok else "FAIL", id, v, seconds, peak, rms_db, clipped])
	print("synth time %d ms for %d samples" % [Time.get_ticks_msec() - t0, total_samples])
	if AudioFX.generate(&"no_such_sound") != null:
		print("FAIL unknown id returned a stream")
		fails += 1
	# Wait for the background generator, then exercise the players.
	var t0w := Time.get_ticks_msec()
	while not AudioFX.is_ready() and Time.get_ticks_msec() - t0w < 20000:
		await get_tree().process_frame
	if not AudioFX.is_ready():
		print("FAIL background synthesis not ready after 20 s")
		fails += 1
	for id: StringName in AudioFX.get_ids():
		AudioFX.play(id, Vector3(1, 1, 1), 0.0, 1.0)
		AudioFX.play_ui(id)
	for i in 10:
		await get_tree().process_frame
	# Stopped playbacks leave the AudioServer on its next mix; wait so none leak at quit.
	AudioFX.stop_all()
	for i in 10:
		await get_tree().process_frame
	if fails == 0:
		print("PASS test_audio")
		get_tree().quit(0)
	else:
		print("FAIL test_audio (%d)" % fails)
		get_tree().quit(1)
