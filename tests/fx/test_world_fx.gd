extends Node3D
## F10 / F11 effects (Feel Reference: Dismemberment step 5, On the world,
## Things stay). A severed limb's stump sprays for 1.5 s and the loose limb
## leaves a decal where it lands (a real rig's whole-arm cut too); gore OFF
## sprays nothing. A body hitting the floor hard puffs dust, and bleeds a
## decal only if wounded; bodies in water make ripple rings and a splash.
## Thrown props burst by kind with their own sounds. Decal counts for J's
## end-of-wave check add up. OWNER: agent F.

const U := preload("res://tests/fx/fx_test_util.gd")

var played: Array[StringName] = []

func _ready() -> void:
	var errlog := U.ErrorLogger.new()
	OS.add_logger(errlog)
	var fails: Array[String] = []
	var saved_gore := Tuning.gore
	Tuning.gore = Tuning.Gore.DISMEMBER
	BloodFX.reset()
	U.make_floor(self)
	var water := U.make_box(self, Vector3(8, -0.45, 0), Vector3(4, 1, 4), Layers.WORLD)
	water.set_meta(&"surface", &"water")
	if not await U.wait_audio(get_tree()):
		fails.append("AudioFX never finished synthesising")
	AudioFX.sound_played.connect(func(id: StringName, _p: Vector3) -> void: played.append(id))
	var f := U.make_fighter(self, Vector3(0, 0, -1))
	f.add_to_group(&"fighters")
	await U.physics_frames(get_tree(), 2)
	var wfx: Node = BloodFX.get_world_fx()

	# --- Stump: 1.5 s of spray; the loose limb's landing decal --------------------------------
	var piece := RigidBody3D.new()
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(0.1, 0.5, 0.1)
	cs.shape = shape
	piece.add_child(cs)
	add_child(piece)
	piece.global_position = Vector3(1.5, 1.4, -1)
	piece.linear_velocity = Vector3(2.5, 1.5, 0)
	var d0: int = BloodFX.get_decal_counts()["blood_created"]
	GameEvents.limb_severed.emit(f, &"arm_r", piece)
	# Blood is world physics: it runs in world time (the sever's slow motion
	# stretches it in real time), so measure world seconds.
	var world := 0.0
	var stump_on := 0.0
	while world < 2.2:
		await get_tree().process_frame
		world += get_process_delta_time()
		if BloodFX.active_stumps() > 0:
			stump_on = world
	print("stump spray lasted %.2f world s (want %.1f)" % [stump_on, BloodFX.STUMP_TIME])
	if absf(stump_on - 1.5) > 0.05:
		fails.append("stump spray %.2f s" % stump_on)
	# Wait for the limb to settle (BloodFX pools it at rest, or after PIECE_TRACK_TIME).
	var waited := 0
	while not BloodFX._pieces.is_empty() and waited < 720:
		await get_tree().physics_frame
		waited += 1
	await U.drain(get_tree())
	var landed: Vector3 = BloodFX.piece_landings.back() if not BloodFX.piece_landings.is_empty() else Vector3(INF, 0, 0)
	var at_landing := 0
	var at_rest := 0
	for dcl: Decal in BloodFX.get_decals():
		if dcl.global_position.y > 0.05:
			continue
		var p := Vector2(dcl.global_position.x, dcl.global_position.z)
		if p.distance_to(Vector2(landed.x, landed.z)) < 0.6:
			at_landing += 1
		if p.distance_to(Vector2(piece.global_position.x, piece.global_position.z)) < 0.6:
			at_rest += 1
	print("loose limb: first touchdown %s -> %d decals there; at rest %s -> %d decals there (%d blood decals since the cut), sounds %s" % [
		landed, at_landing, piece.global_position, at_rest, BloodFX.get_decal_counts()["blood_created"] - d0, played])
	if at_landing == 0 or at_rest == 0:
		fails.append("no decal where the limb landed / came to rest")
	if not played.has(&"arm_break"):
		fails.append("no snap at the joint")

	# --- The real rig: a whole arm comes off -------------------------------------------------------
	var real: Node3D = FighterFactory.spawn_dummy(self, &"grunt", Transform3D(Basis(), Vector3(-3, 0.1, 1)))
	await U.physics_frames(get_tree(), 5)
	var rig = real.get(&"rig")
	if rig != null and rig.has_method(&"sever") and not (rig.call(&"get_mesh_parts") as Array).is_empty():
		var real_piece = rig.call(&"sever", &"arm_r")
		GameEvents.limb_severed.emit(real, &"arm_r", real_piece)
		await get_tree().create_timer(0.3).timeout
		var attach: Node3D = BloodFX._stump_attach[(BloodFX._stump_next + BloodFX.STUMP_POOL - 1) % BloodFX.STUMP_POOL]
		print("real rig arm_r: piece %s, stumps %d, stump rides %s" % [real_piece, BloodFX.active_stumps(), attach])
		if BloodFX.active_stumps() == 0:
			fails.append("no stump spray on the real rig")
	else:
		print("note: real HumanoidRig cannot sever yet; skipped")

	# --- Gore OFF: no stump --------------------------------------------------------------------
	Tuning.gore = Tuning.Gore.OFF
	await get_tree().create_timer(1.8).timeout
	GameEvents.limb_severed.emit(f, &"leg_l", null)
	if BloodFX.active_stumps() != 0:
		fails.append("stump with gore OFF")
	Tuning.gore = Tuning.Gore.DISMEMBER

	# --- Bodies hitting the floor: dust; blood only if wounded --------------------------------
	await U.drain(get_tree())
	var c0 := BloodFX.get_decal_counts()
	var dust0: int = BloodFX._dust_next
	f.hp = f.max_hp
	GameEvents.body_impact.emit(f, Vector3(0, 0, -2), Vector3.UP, 2500.0, &"concrete")
	await U.drain(get_tree())
	var fresh_decals: int = BloodFX.get_decal_counts()["blood_created"] - c0["blood_created"]
	var fresh_dust := BloodFX._dust_next != dust0
	f.hp = f.max_hp * 0.5
	f.com_velocity = Vector3(6, -3, 0)
	GameEvents.body_impact.emit(f, Vector3(1, 0, -2), Vector3.UP, 2500.0, &"concrete")
	await U.drain(get_tree())
	var hurt_decals: int = BloodFX.get_decal_counts()["blood_created"] - c0["blood_created"] - fresh_decals
	print("body hits the floor: unhurt -> dust %s, %d blood decals; wounded -> %d blood decals" % [fresh_dust,
		fresh_decals, hurt_decals])
	if not fresh_dust or fresh_decals != 0 or hurt_decals < 1:
		fails.append("body impact blood rule broken")

	# --- Water: ripples and a splash ------------------------------------------------------------
	var wc0: Dictionary = wfx.get(&"counts").duplicate()
	played.clear()
	var dust1: int = BloodFX._dust_next
	GameEvents.body_impact.emit(f, Vector3(8, 0.05, 0), Vector3.UP, 3500.0, &"water")
	await get_tree().process_frame
	var wc: Dictionary = wfx.get(&"counts")
	var ripples := int(wc.get(&"ripple", 0)) - int(wc0.get(&"ripple", 0))
	print("body in water: %d ripple rings (%d showing), splash %d, dust %s, sounds %s" % [ripples, wfx.call(&"active_ripples"),
		int(wc.get(&"splash", 0)) - int(wc0.get(&"splash", 0)), BloodFX._dust_next != dust1, played])
	if ripples != 3 or BloodFX._dust_next != dust1 or not played.has(&"splash"):
		fails.append("water impact wrong")
	await get_tree().create_timer(1.3).timeout
	if wfx.call(&"active_ripples") != 0:
		fails.append("ripples did not fade")

	# --- Props break by kind ------------------------------------------------------------------
	wc0 = wfx.get(&"counts").duplicate()
	var expect := {&"brick": &"break_brick", &"bottle": &"break_glass", &"chair_leg": &"break_wood",
		&"crate_small": &"break_wood", &"stick": &"break_wood"}
	for kind: StringName in expect:
		await U.physics_frames(get_tree(), 8)
		played.clear()
		GameEvents.prop_broken.emit(null, Vector3(0, 0.5, 2), kind)
		if not played.has(expect[kind]):
			fails.append("%s broke with %s" % [kind, played])
	wc = wfx.get(&"counts")
	print("prop bursts %d, glass bursts %d" % [int(wc.get(&"prop_burst", 0)) - int(wc0.get(&"prop_burst", 0)),
		int(wc.get(&"glass", 0)) - int(wc0.get(&"glass", 0))])
	if int(wc.get(&"prop_burst", 0)) - int(wc0.get(&"prop_burst", 0)) != 5 or int(wc.get(&"glass", 0)) - int(wc0.get(&"glass", 0)) != 1:
		fails.append("prop bursts wrong")

	# --- Holding: knees bleed a little; slams; throws (G) ---------------------------------------
	var held := U.hit(f, &"knee", f.global_position + Vector3(0, 1.2, 0.1), Vector3(0, 0, -1), 6.0, 0.0, &"strike",
			HitInfo.Tier.FLINCH)
	held.set_meta(&"blood", &"small")
	held.set_meta(&"held_strike", true)
	GameEvents.hit_landed.emit(held)
	var plain := U.hit(f, &"jab1", f.global_position + Vector3(0, 1.2, 0.1), Vector3(0, 0, -1), 4.0, 0.0, &"strike",
			HitInfo.Tier.FLINCH)
	await U.physics_frames(get_tree(), 4)
	var held_blood: bool = BloodFX.contact_log.back()["blood"]
	GameEvents.hit_landed.emit(plain)
	var plain_blood: bool = BloodFX.contact_log.back()["blood"]
	await U.physics_frames(get_tree(), 30)
	wc0 = wfx.get(&"counts").duplicate()
	played.clear()
	var fl0 := BloodFX.active_impact_flashes()
	GameEvents.body_slammed.emit(f, f, Vector3(-2, 0, 2))
	wc = wfx.get(&"counts")
	var slam_ring := int(wc.get(&"dust_ring", 0)) - int(wc0.get(&"dust_ring", 0))
	var slam_flash := BloodFX.active_impact_flashes() > fl0
	var slam_snd := played.duplicate()
	GameEvents.landing.emit(f, &"heavy", Vector3(-2, 0, 2), 12.0)  # the same slam reported as a landing
	var rings_after := int(wfx.get(&"counts").get(&"dust_ring", 0)) - int(wc0.get(&"dust_ring", 0))
	await U.physics_frames(get_tree(), 8)
	played.clear()
	AudioFX.stop_all()  # _newest_db finds the first player on the stream: only one may play
	GameEvents.thrown.emit(f, f, Vector3(0, 1, -6))
	var slow_db: float = _newest_db(&"throw")
	await U.physics_frames(get_tree(), 8)
	AudioFX.stop_all()
	GameEvents.thrown.emit(f, f, Vector3(0, 2, -16))
	var fast_db: float = _newest_db(&"throw")
	await U.physics_frames(get_tree(), 8)
	GameEvents.prop_thrown.emit(f, null, Vector3(0, 1, -10))
	print("held knee blood %s (a plain jab %s); body slam: flash %s, dust ring %d (%d after its heavy landing), sounds %s; throw whoosh %.1f dB at 6 m/s, %.1f dB at 16 m/s; prop throw %s" % [
		held_blood, plain_blood, slam_flash, slam_ring, rings_after, slam_snd, slow_db, fast_db, played])
	if not held_blood or plain_blood:
		fails.append("held strike blood rule broken")
	if not slam_flash or slam_ring != 1 or rings_after != 1 or not (slam_snd.has(&"body_slam") and slam_snd.has(&"land_heavy")):
		fails.append("body slam effects wrong")
	if fast_db <= slow_db + 2.0 or played.count(&"throw") != 3:
		fails.append("throw whooshes wrong")

	# --- Decal counts add up ---------------------------------------------------------------------
	await U.drain(get_tree())
	var dc := BloodFX.get_decal_counts()
	print("decal counts: %s" % [dc])
	if dc["live"] + dc["fading"] + dc["evicted"] + dc["released"] != dc["created"]:
		fails.append("decal counts do not add up")
	if dc["blood"] > Tuning.BLOOD_DECAL_MAX:
		fails.append("more live blood decals than the cap")
	Tuning.gore = saved_gore
	U.finish(get_tree(), "test_world_fx", fails, errlog)

## volume_db of the newest playing 3D sound with `id`'s last stream.
func _newest_db(id: StringName) -> float:
	var want = AudioFX.last_stream.get(id)
	for p: AudioStreamPlayer3D in AudioFX._players:
		if p.playing and p.stream == want:
			return p.volume_db
	return -100.0
