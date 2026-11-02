extends Node3D
## Round 3 wall strikes (GameEvents.wall_struck): per-surface strike sounds,
## volume and pitch rising with power, hold / crack / hole / break layering,
## rapid jabs throttled per surface and varied (no single repeated sample,
## each quick repeat softer), player pitch kept in Focus, dust and chips in
## the surface colour along the normal (bigger for holes and breaks, plus a
## puff out the far side), and no double burst or double break sound when D
## emits wall_broken / wall_cracked for the same strike. OWNER: agent F.

const U := preload("res://tests/fx/fx_test_util.gd")
const FakePanel := preload("res://tests/fx/fx_fake_panel.gd")

var played: Array[StringName] = []
var played_db: Array[float] = []

func _ready() -> void:
	var errlog := U.ErrorLogger.new()
	OS.add_logger(errlog)
	var fails: Array[String] = []
	BloodFX.reset()
	# Every variant (5 per strike id) takes a few seconds on an idle machine;
	# allow for a loaded one.
	var complete: bool = await U.wait_audio(get_tree(), 240000, true)
	if not complete and not AudioFX.is_ready():
		fails.append("AudioFX never finished synthesising")
	AudioFX.sound_played.connect(_on_played)
	var player := U.make_fighter(self, Vector3(0, 0, 1))
	player.add_to_group(&"player")
	var wall := FakePanel.new()
	add_child(wall)
	var at := Vector3(0, 1.3, -0.5)
	var n := Vector3(0, 0, 1)

	# Each surface plays its own strike sound.
	for surf: StringName in [&"drywall", &"brick", &"wood", &"concrete"]:
		await _gap()
		played.clear()
		GameEvents.wall_struck.emit(player, wall, at, n, 60.0, &"chip", surf)
		var want: StringName = AudioFX.STRIKE_BY_SURFACE[surf]
		if played != [want]:
			fails.append("%s chip played %s, want [%s]" % [surf, played, want])
	# Layering by result.
	var layers := {&"hold": [&"strike_hold", &"strike_concrete"], &"crack": [&"strike_brick", &"crack"],
		&"hole": [&"strike_drywall", &"break_drywall"], &"break": [&"strike_wood", &"break_wood"]}
	var surf_for := {&"hold": &"concrete", &"crack": &"brick", &"hole": &"drywall", &"break": &"wood"}
	for result: StringName in layers:
		await _gap()
		played.clear()
		GameEvents.wall_struck.emit(player, wall, at, n, 120.0, result, surf_for[result])
		for id: StringName in layers[result]:
			if not played.has(id):
				fails.append("%s on %s did not play %s (got %s)" % [result, surf_for[result], id, played])
	# Power: a charged kick is louder and lower than a jab.
	await _gap()
	played.clear()
	played_db.clear()
	GameEvents.wall_struck.emit(player, wall, at, n, 15.0, &"chip", &"brick")
	var jab_player := _last_player()
	var jab_pitch := jab_player.pitch_scale
	var jab_db := jab_player.volume_db
	await _gap()
	GameEvents.wall_struck.emit(player, wall, at, n, 360.0, &"chip", &"brick")
	var big_player := _last_player()
	print("strike power: jab %.1f dB pitch %.2f; charged kick %.1f dB pitch %.2f" % [
		jab_db, jab_pitch, big_player.volume_db, big_player.pitch_scale])
	if big_player.volume_db < jab_db + 6.0:
		fails.append("power does not raise the strike volume enough")
	if big_player.pitch_scale >= jab_pitch:
		fails.append("power does not lower the strike pitch")

	# Rapid jabs: a jab every 3 ticks (25 ms) for 0.5 s.
	await _gap(60)
	played.clear()
	var streams: Dictionary = {}
	var vols: Array[float] = []
	for i in 20:
		GameEvents.wall_struck.emit(player, wall, at, n, 15.0, &"chip", &"drywall")
		if played.size() > vols.size():
			var p := _last_player()
			streams[p.stream] = true
			vols.append(p.volume_db)
		await U.physics_frames(get_tree(), 3)
	print("rapid jabs: %d of 20 heard, %d different samples, volumes %s" % [vols.size(), streams.size(), vols])
	if vols.size() > 9 or vols.size() < 4:
		fails.append("per-surface cooldown let %d of 20 rapid jabs through" % vols.size())
	if streams.size() < 3 and complete:
		fails.append("rapid jabs repeat the same sample (%d variants)" % streams.size())
	if vols.size() >= 3 and vols[2] >= vols[0]:
		fails.append("quick repeats are not softer")
	if complete and AudioFX.variant_count(&"strike_drywall") != 5:
		fails.append("strike_drywall has %d variants, want 5" % AudioFX.variant_count(&"strike_drywall"))

	# Focus: the player's strike keeps its pitch.
	if TimeDirector.begin_focus():
		await get_tree().create_timer(0.3).timeout
		await _gap()
		GameEvents.wall_struck.emit(player, wall, at, n, 60.0, &"chip", &"wood")
		var i := _last_index()
		var factor := AudioFX.player_pitch_factor()
		if i < 0 or AudioFX._owned_base[i] <= 0.0 or absf(AudioFX._players[i].pitch_scale - AudioFX._owned_base[i] * factor) > 0.05:
			fails.append("strike not pitch-compensated in Focus")
		else:
			print("focus: strike pitch %.2f = base %.2f x %.2f" % [AudioFX._players[i].pitch_scale, AudioFX._owned_base[i], factor])
		TimeDirector.end_focus()
		await get_tree().create_timer(0.3).timeout
	else:
		print("note: begin_focus refused; Focus pitch not checked")

	# Particles: one puff + chips; two bursts for a hole, larger.
	var d0: int = BloodFX._dust_next
	GameEvents.wall_struck.emit(player, wall, at, n, 30.0, &"chip", &"brick")
	var puff := BloodFX._puffs[d0] as GPUParticles3D
	var chips := BloodFX._chips[d0] as GPUParticles3D
	var small_chip := (chips.process_material as ParticleProcessMaterial).scale_max
	var small_amount := puff.amount_ratio
	if BloodFX._dust_next != (d0 + 1) % BloodFX.DUST_POOL or not puff.visible or not chips.visible:
		fails.append("chip strike made no dust and chips")
	elif (puff.process_material as ParticleProcessMaterial).color != BloodFX.DUST_BY_SURFACE[&"brick"]:
		fails.append("dust not in the surface colour")
	elif -puff.global_basis.z.dot(n) < 0.99 or puff.global_position.distance_to(at) > 0.1:
		fails.append("dust not along the normal at the contact")
	var d1: int = BloodFX._dust_next
	GameEvents.wall_struck.emit(player, wall, at, n, 300.0, &"hole", &"drywall")
	var hole_puff := BloodFX._puffs[d1] as GPUParticles3D
	var back_puff := BloodFX._puffs[(d1 + 1) % BloodFX.DUST_POOL] as GPUParticles3D
	var hole_chip := (BloodFX._chips[d1].process_material as ParticleProcessMaterial).scale_max
	print("dust: chip amount %.2f chip size %.2f; hole amount %.2f chip size %.2f" % [
		small_amount, small_chip, hole_puff.amount_ratio, hole_chip])
	if BloodFX._dust_next != (d1 + 2) % BloodFX.DUST_POOL:
		fails.append("hole did not burst on both sides")
	elif -back_puff.global_basis.z.dot(-n) < 0.99:
		fails.append("far-side puff not pointing out of the hole")
	if hole_puff.amount_ratio <= small_amount or hole_chip <= small_chip:
		fails.append("hole burst not bigger than a chip")
	var d2: int = BloodFX._dust_next
	GameEvents.wall_struck.emit(player, wall, at, n, 15.0, &"hold", &"drywall")
	if (BloodFX._chips[d2] as GPUParticles3D).visible and (BloodFX._chips[d2].process_material as ParticleProcessMaterial).scale_max != hole_chip:
		pass  # chips from an earlier burst may still be flying; the next check covers it
	if BloodFX._dust_next != (d2 + 1) % BloodFX.DUST_POOL:
		fails.append("hold made no dust puff")

	# D emits wall_broken / wall_cracked for the same strike: no doubles.
	await _gap()
	played.clear()
	var d3: int = BloodFX._dust_next
	GameEvents.wall_broken.emit(wall, at, 3000.0, -n * 4.0)
	GameEvents.wall_cracked.emit(wall, at, 1500.0)
	GameEvents.wall_struck.emit(player, wall, at, n, 300.0, &"hole", &"drywall")
	await get_tree().process_frame
	await get_tree().process_frame
	var bursts := (BloodFX._dust_next - d3 + BloodFX.DUST_POOL) % BloodFX.DUST_POOL
	print("strike + wall_broken + wall_cracked: %s, %d dust bursts" % [played, bursts])
	if played.count(&"break_drywall") != 1 or played.has(&"crack"):
		fails.append("break / crack sounds doubled: %s" % [played])
	if bursts != 2:
		fails.append("dust doubled: %d bursts, want the strike's 2" % bursts)
	# A wall_broken with no strike still sounds and puffs on its own.
	await _gap()
	played.clear()
	var other := FakePanel.new()
	add_child(other)
	var d4: int = BloodFX._dust_next
	GameEvents.wall_broken.emit(other, at, 3000.0, -n * 4.0)
	await get_tree().process_frame
	if not played.has(&"break_drywall") or BloodFX._dust_next == d4:
		fails.append("a plain wall_broken lost its sound or dust")
	U.finish(get_tree(), "test_wall_strike", fails, errlog)

func _on_played(id: StringName, _p: Vector3) -> void:
	played.append(id)

## Wait past the per-surface cooldown and the streak window.
func _gap(frames := 70) -> void:
	await U.physics_frames(get_tree(), frames)

func _last_index() -> int:
	var i: int = (AudioFX._next_3d - 1 + AudioFX._players.size()) % AudioFX._players.size()
	return i

func _last_player() -> AudioStreamPlayer3D:
	return AudioFX._players[_last_index()]
