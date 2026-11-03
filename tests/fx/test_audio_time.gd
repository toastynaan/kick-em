extends Node3D
## F0 (Feel Reference: Time, in code > Audio): is AudioServer.playback_speed_scale
## global in Godot 4.8, and do the player's own sounds keep real time in slow
## motion? Three raw players play a 4 s stream while the world runs at 0.3x
## (a TimeDirector slow-motion row; Round 7 removed Focus): one on the World bus, one on the Player bus with no
## compensation, one on the Player bus with AudioFX.player_pitch_factor().
## Wall-clock playback progress shows the scale is global (the bus does not
## matter) and that the compensation restores real time. Also checks AudioFX
## routes player-owned sounds to the Player bus with that pitch, world sounds
## to the World bus (muffled by the slow-motion low-pass), and that a KO (the
## player slows too) is not compensated. OWNER: agent F.

const U := preload("res://tests/fx/fx_test_util.gd")
const MEASURE_MS := 1500

func _ready() -> void:
	var errlog := U.ErrorLogger.new()
	OS.add_logger(errlog)
	var fails: Array[String] = []
	if not await U.wait_audio(get_tree()):
		fails.append("AudioFX never finished synthesising")
	var player := U.make_fighter(self, Vector3(0, 0, 2))
	player.add_to_group(&"player")
	var enemy := U.make_fighter(self, Vector3(0, 0, -1))
	print("buses: World %d, Player %d (Master %d)" % [AudioServer.get_bus_index(AudioFX.WORLD_BUS),
		AudioServer.get_bus_index(AudioFX.PLAYER_BUS), AudioServer.get_bus_index(&"Master")])
	if AudioServer.get_bus_index(AudioFX.WORLD_BUS) < 0 or AudioServer.get_bus_index(AudioFX.PLAYER_BUS) < 0:
		fails.append("World / Player buses missing")

	# A 4 s stream (quiet noise so nothing is optimised away).
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = 44100
	var bytes := PackedByteArray()
	bytes.resize(44100 * 4 * 2)
	for i in 44100 * 4:
		bytes.encode_s16(i * 2, (i * 7919) % 41 - 20)
	wav.data = bytes
	var raw: Array[AudioStreamPlayer] = []
	for spec in [[AudioFX.WORLD_BUS, false], [AudioFX.PLAYER_BUS, false], [AudioFX.PLAYER_BUS, true]]:
		var p := AudioStreamPlayer.new()
		p.bus = spec[0]
		p.stream = wav
		p.volume_db = -60.0
		p.set_meta(&"comp", spec[1])
		add_child(p)
		raw.append(p)

	# Calibrate: how fast the (headless dummy) driver mixes at normal speed.
	var drive := await _measure([raw[0]])
	var driver_rate: float = drive[0] if drive[0] > 0.01 else 1.0
	raw[0].stop()
	print("driver mix rate at 1.0x: %.3f stream s per wall-clock s" % driver_rate)
	if not U.slow_world(0.3):
		fails.append("TimeDirector refused a 0.3x slow motion")
	await U.physics_frames(get_tree(), 4)
	var scale := AudioServer.playback_speed_scale
	var factor := AudioFX.player_pitch_factor()
	print("slow motion: Engine.time_scale %.2f, playback_speed_scale %.2f, player_time_factor %.2f, AudioFX pitch factor %.2f" % [
		Engine.time_scale, scale, TimeDirector.player_time_factor(), factor])
	for p in raw:
		if p.get_meta(&"comp"):
			p.pitch_scale = factor
	var rate: Array[float] = []
	for r in await _measure(raw):
		rate.append(r / driver_rate)
	print("stream seconds per real second (driver-calibrated): World bus %.3f, Player bus (no comp) %.3f, Player bus x%.2f %.3f" % [
		rate[0], rate[1], factor, rate[2]])
	if rate[0] < 0.01 and rate[2] < 0.01:
		print("note: the audio driver does not mix here; the playback rates were not measured")
	else:
		# The dummy driver's own pace drifts between runs, so the ratios between
		# the three channels (mixed together) are the exact measurement.
		var bus_ratio := rate[1] / maxf(rate[0], 0.001)
		var comp_ratio := rate[2] / maxf(rate[0], 0.001)
		print("F0 result: Player bus / World bus %.3f (1 = the scale is GLOBAL); compensated / world %.3f (want 1 / %.2f = %.3f): the player's sound runs at %.0f%% of real time" % [
			bus_ratio, comp_ratio, scale, 1.0 / scale, comp_ratio * scale * 100.0])
		if absf(bus_ratio - 1.0) > 0.03:
			fails.append("the Player bus alone changed the rate (%.3f): playback_speed_scale is not global?" % bus_ratio)
		if absf(comp_ratio * scale - 1.0) > 0.05:
			fails.append("compensated player sound at %.0f%% of real time" % (comp_ratio * scale * 100.0))
		if absf(rate[0] - scale) > 0.25 * scale:
			fails.append("world sound rate %.3f, want about %.2f" % [rate[0], scale])
	if absf(factor - 1.0 / scale) > 0.02:
		fails.append("pitch factor %.2f, want 1 / %.2f" % [factor, scale])

	# AudioFX routing: the player's own sound vs a world sound.
	AudioFX.play(&"whoosh", Vector3.ZERO, 0.0, 1.0, player)
	var own := _newest(&"whoosh")
	AudioFX.play(&"thud", Vector3.ZERO, 0.0, 1.0, enemy)
	var world := _newest(&"thud")
	print("AudioFX: player whoosh bus %s pitch %.2f; enemy thud bus %s pitch %.2f; world low-pass %.0f Hz" % [
		own.bus if own else &"-", own.pitch_scale if own else 0.0, world.bus if world else &"-",
		world.pitch_scale if world else 0.0, AudioFX.get_world_lowpass()])
	if own == null or own.bus != AudioFX.PLAYER_BUS or own.pitch_scale < factor * 0.9:
		fails.append("player sound not on the Player bus at the compensated pitch")
	if world == null or world.bus != AudioFX.WORLD_BUS or world.pitch_scale > 1.1:
		fails.append("world sound not on the World bus at world pitch")
	var want_lp := maxf(AudioFX.SLOW_LP_OPEN * pow(scale, AudioFX.SLOW_LP_EXP), AudioFX.SLOW_LP_MIN)
	if absf(AudioFX.get_world_lowpass() - want_lp) > 50.0:
		fails.append("world low-pass %.0f Hz, want %.0f" % [AudioFX.get_world_lowpass(), want_lp])
	U.normal_time()

	# A KO: the player slows with the world, so nothing is compensated.
	if TimeDirector.has_method(&"request") and TimeDirector.request(&"last_kill"):
		await U.physics_frames(get_tree(), 4)
		print("KO: time scale %.2f, player_time_factor %.2f, AudioFX pitch factor %.2f" % [
			Engine.time_scale, TimeDirector.player_time_factor(), AudioFX.player_pitch_factor()])
		if absf(AudioFX.player_pitch_factor() - 1.0) > 0.02:
			fails.append("player sounds compensated during a KO")
	TimeDirector.reset()
	await U.physics_frames(get_tree(), 4)
	if AudioFX.get_world_lowpass() != 0.0:
		fails.append("world low-pass still on at normal speed")
	for p in raw:
		p.stop()
	U.finish(get_tree(), "test_audio_time", fails, errlog)

## Play `players`, skip the mix start-up latency, then return each one's stream
## seconds advanced per wall-clock second over MEASURE_MS.
func _measure(players: Array[AudioStreamPlayer]) -> Array[float]:
	for p in players:
		p.play()
	var t_settle := Time.get_ticks_usec()
	while Time.get_ticks_usec() - t_settle < 300000:
		await get_tree().process_frame
	var t0 := Time.get_ticks_usec()
	var start: Array[float] = []
	for p in players:
		start.append(p.get_playback_position())
	while Time.get_ticks_usec() - t0 < MEASURE_MS * 1000:
		await get_tree().process_frame
	var real := (Time.get_ticks_usec() - t0) / 1000000.0
	var out: Array[float] = []
	for i in players.size():
		out.append((players[i].get_playback_position() - start[i]) / real)
	return out

func _newest(id: StringName) -> AudioStreamPlayer3D:
	var want = AudioFX.last_stream.get(id)
	for p: AudioStreamPlayer3D in AudioFX._players:
		if p.playing and p.stream == want:
			return p
	return null
