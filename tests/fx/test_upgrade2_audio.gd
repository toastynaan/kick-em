extends Node3D
## Upgrade 2 AudioFX (Round 5 rules): the impact follows the tier, not the
## move; the charge hum (seamless loop, pitch rising with c (Round 8), stopped
## by the release, which whooshes and suppresses the move's own whoosh;
## auto-stop without a release), jump / land / crouch, arm break, wall slam,
## stumble and trip, and slow-motion pitch: the player's own sounds stay at
## normal pitch while the world slows. Round 7 removed Focus mode and its
## stings: focus_started / focus_ended play nothing. OWNER: agent F.

const U := preload("res://tests/fx/fx_test_util.gd")

var played: Array[StringName] = []

func _ready() -> void:
	var errlog := U.ErrorLogger.new()
	OS.add_logger(errlog)
	var fails: Array[String] = []
	if not await U.wait_audio(get_tree()):
		fails.append("AudioFX never finished synthesising")
	AudioFX.sound_played.connect(func(id: StringName, _p: Vector3) -> void: played.append(id))
	var player := U.make_fighter(self, Vector3(0, 0, 2))
	player.add_to_group(&"player")
	player.add_to_group(&"fighters")
	var enemy := U.make_fighter(self, Vector3(0, 0, -1))
	enemy.add_to_group(&"fighters")

	# Round 5: the impact follows the hit tier, whatever the move (the Upgrade 2
	# per-move variants gave way to "impact sounds layered by tier").
	for tier in [HitInfo.Tier.FLINCH, HitInfo.Tier.STAGGER, HitInfo.Tier.LAUNCH, HitInfo.Tier.SEVER]:
		for move: StringName in [&"jab1", &"cross", &"sparta_kick"]:
			await U.physics_frames(get_tree(), 6)
			played.clear()
			var h := U.hit(enemy, move, Vector3(0, 1.3, -0.8), Vector3(0, 0, -1), 60.0, 2000.0, &"strike", tier)
			h.attacker = player
			GameEvents.hit_landed.emit(h)
			if played.is_empty() or played[0] != AudioFX.TIER_SOUND[tier]:
				fails.append("%s at %s played %s, want %s" % [move, HitInfo.tier_name(tier), played,
					AudioFX.TIER_SOUND[tier]])
	await U.physics_frames(get_tree(), 6)
	played.clear()
	GameEvents.hit_landed.emit(U.hit(enemy, &"grab", Vector3(0, 1.3, -0.8), Vector3(0, 0, -1), 0.0, 0.0, &"grab",
			HitInfo.Tier.FLINCH))
	if not played.is_empty():
		fails.append("a grab hit played %s (grab_started covers it)" % [played])

	# Charge hum: loop; Round 8: the pitch follows c, a tick per step, the release
	# whooshes at once and covers the move's own whoosh.
	var hum_stream: AudioStreamWAV = AudioFX.generate(&"charge_hum", 0)
	@warning_ignore("integer_division")
	if hum_stream.loop_mode != AudioStreamWAV.LOOP_FORWARD or hum_stream.loop_end != hum_stream.data.size() / 2:
		fails.append("charge_hum is not a full forward loop")
	played.clear()
	GameEvents.charge_started.emit(player, &"power_punch")
	if AudioFX.active_hums() != 1:
		fails.append("charge_started gave %d hums" % AudioFX.active_hums())
	var p0 := AudioFX.hum_pitch_for(0.0)
	for lvl in [1, 2, 3]:
		await U.physics_frames(get_tree(), 8)
		GameEvents.charge_level_changed.emit(player, lvl)
	await U.physics_frames(get_tree(), 4)
	var c3 := AudioFX.hum_charge(player)
	var pitch3 := AudioFX.hum_pitch(player)
	print("hum after 3 steps: c %.2f, pitch %.2f (want ~%.2f, start %.2f); step ticks %d" % [c3, pitch3,
		AudioFX.hum_pitch_for(c3), p0, played.count(&"charge_tick")])
	if c3 < 0.1 or absf(pitch3 - AudioFX.hum_pitch_for(c3)) > 0.06 or pitch3 <= p0 * 1.05:
		fails.append("hum pitch did not rise with c")
	if played.count(&"charge_tick") != 3:
		fails.append("step ticks: %d, want 3" % played.count(&"charge_tick"))
	played.clear()
	GameEvents.charge_released.emit(player, &"power_punch", 3)
	GameEvents.attack_active.emit(player, &"power_punch")
	await get_tree().process_frame
	if AudioFX.active_hums() != 0:
		fails.append("release did not stop the hum")
	if not played.has(&"charge_release"):
		fails.append("no release whoosh")
	if played.has(&"whoosh"):
		fails.append("move whoosh doubled the release whoosh")
	await get_tree().create_timer(0.5).timeout
	played.clear()
	GameEvents.attack_active.emit(player, &"power_punch")
	if not played.has(&"whoosh"):
		fails.append("whoosh stayed suppressed after the release gap")
	# A hum with no release stops on its own.
	GameEvents.charge_started.emit(enemy, &"e_heavy")
	for i in int((AudioFX.HUM_MAX_TIME + 0.3) * 120.0):
		await get_tree().process_frame
	if AudioFX.active_hums() != 0:
		fails.append("orphan hum never stopped")

	# Movement, arm break, wall slam, stumble, trip.
	for spec in [[&"jump", func() -> void: GameEvents.jumped.emit(player)],
			[&"land", func() -> void: GameEvents.landed.emit(player)],
			[&"crouch", func() -> void: GameEvents.crouch_changed.emit(player, true)],
			[&"arm_break", func() -> void: GameEvents.arm_broken.emit(enemy, BodyZones.Zone.ARM_L)],
			[&"wall_slam", func() -> void: GameEvents.wall_slam.emit(player, enemy, null)],
			[&"land", func() -> void: GameEvents.stumbled.emit(enemy, 0.6)],
			[&"thud", func() -> void: GameEvents.tripped.emit(enemy)]]:
		await U.physics_frames(get_tree(), 6)
		played.clear()
		(spec[1] as Callable).call()
		await get_tree().process_frame  # `landed` waits a frame for Traversal's `landing` (Round 5)
		if not played.has(spec[0]):
			fails.append("%s did not play (got %s)" % [spec[0], played])

	# Round 7: no Focus stings.
	await U.physics_frames(get_tree(), 6)
	played.clear()
	GameEvents.focus_started.emit(player)
	GameEvents.focus_ended.emit(player)
	print("focus_started / focus_ended (Focus removed) played %s" % [played])
	if not played.is_empty():
		fails.append("removed Focus stings still play: %s" % [played])

	# Slow motion: the player's sounds keep their pitch.
	if U.slow_world(0.3):
		await get_tree().create_timer(0.3).timeout
		var factor := AudioFX.player_pitch_factor()
		AudioFX.play(&"whoosh", Vector3.ZERO, 0.0, 1.0, player)
		var own := _last_owned()
		AudioFX.play(&"thud", Vector3.ZERO, 0.0, 1.0, enemy)
		await get_tree().process_frame
		print("slow motion: time scale %.2f, pitch factor %.2f, player sound pitch %.2f (base %.2f)" % [
			Engine.time_scale, factor, own[1], own[0]])
		if factor < 2.5:
			fails.append("player pitch factor %.2f in slow motion" % factor)
		if own[0] <= 0.0 or absf(own[1] - own[0] * factor) > 0.05:
			fails.append("player sound not pitch-compensated")
		U.normal_time()
		await get_tree().create_timer(0.5).timeout
		if absf(AudioFX.player_pitch_factor() - 1.0) > 0.01:
			fails.append("pitch factor stuck after slow motion")
	else:
		print("note: TimeDirector refused slow motion; pitch not checked")
	U.finish(get_tree(), "test_upgrade2_audio", fails, errlog)

## [base pitch, current pitch_scale] of the most recent player-owned 3D sound.
func _last_owned() -> Array:
	for i in AudioFX._players.size():
		if AudioFX._owned_base[i] > 0.0 and AudioFX._players[i].stream != null \
				and AudioFX._players[i].playing:
			return [AudioFX._owned_base[i], AudioFX._players[i].pitch_scale]
	return [0.0, 0.0]
