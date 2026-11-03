extends "res://tests/combat/combat_test_base.gd"
## Round 2 cross-module APIs, Round 7 rules: CombatController.start_counter
## (the Duelist's teleport counter, free since the Focus meter went: on the
## player a knockdown, never a launch), pick_up_debris, ThrownChunk.launch_body
## and the player's debris kick (the front kick sends a chunk at an enemy).

var _x := 0.0
const PEAK_LIMIT := 20.0
## body -> [peak reported speed, peak speed from position change, last pos, last parent]
var _peaks := {}

## Sampled on SceneTree.physics_frame, before any _physics_process (and before
## ProjectileProbe's clamp), so a solver spike would show up here.
func _sample_peaks() -> void:
	for b: RigidBody3D in _peaks:
		if not is_instance_valid(b):
			continue
		var rec: Array = _peaks[b]
		rec[0] = maxf(rec[0], b.linear_velocity.length())
		var par := b.get_parent()
		var in_hand := par is BoneAttachment3D
		if par == rec[3] and not in_hand:
			rec[1] = maxf(rec[1], (b.global_position - (rec[2] as Vector3)).length() * Engine.physics_ticks_per_second)
		rec[2] = b.global_position
		rec[3] = par

func _track(b: RigidBody3D) -> void:
	_peaks[b] = [0.0, 0.0, b.global_position, b.get_parent()]

func _lane() -> float:
	_x += 10.0
	return _x

func _landed(move_id: StringName, victim: Fighter = null) -> HitInfo:
	for i in range(events.size() - 1, -1, -1):
		var ev: Array = events[i]
		if ev[0] == &"hit_landed" and (ev[1] as HitInfo).move_id == move_id \
				and (victim == null or (ev[1] as HitInfo).victim == victim):
			return ev[1]
	return null

func _chunk(pos: Vector3) -> RigidBody3D:
	var b := RigidBody3D.new()
	b.mass = 8.0
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.4, 0.3, 0.4)
	cs.shape = box
	b.add_child(cs)
	add_child(b)
	b.global_position = pos
	DebrisManager.register(b, false)
	return b

func run() -> void:
	get_tree().physics_frame.connect(_sample_peaks)
	print("AI teleport counter (the Duelist; free: no Focus meter)")
	var x := _lane()
	var p := spawn(&"player", Vector3(x, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var du := spawn(&"duelist", Vector3(x, 0, -3.0), Vector3.BACK)
	await ticks(15)
	clear_events()
	var hp0 := p.hp
	check(du.combat.start_counter(p, 0.4), "start_counter accepted")
	var behind := (du.get_ground_position() - p.get_ground_position()).dot(p.get_forward())
	check(behind < -0.5, "the duelist reappears behind the player (%.2f m)" % -behind)
	var tell := last_event(&"attack_tell")
	var want_tell := maxf(0.4, Tuning.frames(Tuning.ENEMY_STARTUP_MIN))  # never under the enemy startup minimum
	check(not tell.is_empty() and tell[2] == &"counter" and absf(tell[3] - want_tell) < 0.01,
		"blue counter tell %.2f s (%.2f)" % [want_tell, tell[3] if not tell.is_empty() else -1.0])
	var ok := await wait_until(func() -> bool: return _landed(&"back_kick", p) != null, 1.5)
	check(ok, "AI back_kick landed on the player")
	if ok:
		var info := _landed(&"back_kick", p)
		check(info.tier == HitInfo.Tier.KNOCKDOWN and info.launch_velocity == Vector3.ZERO and info.react == &"",
			"the counter knocks the player down (a Round 5 tier), no launch (%s)" % HitInfo.tier_name(info.tier))
		var want := Tuning.DMG_ENEMY[&"e_kick"] * float(du.config["damage_mult"])
		check(is_equal_approx(hp0 - p.hp, want), "damage %.1f = DMG_ENEMY e_kick x damage_mult" % (hp0 - p.hp))

	print("start_counter is refused mid-attack")
	x = _lane()
	var p4 := spawn(&"player", Vector3(x, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var du4 := spawn(&"duelist", Vector3(x, 0, -3.0), Vector3.BACK)
	await ticks(15)
	check(du4.combat.start_enemy_attack(&"e_hook", 0.5), "the Duelist starts a hook")
	check(not du4.combat.start_counter(p4, 0.4), "no teleport counter in the middle of its own attack")
	await wait_real(1.0)

	print("Thrower: pick up a real chunk and throw it")
	x = _lane()
	var p5 := spawn(&"player", Vector3(x, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var th := spawn(&"thrower", Vector3(x, 0, -7.0), Vector3.BACK)
	await ticks(15)
	var chunk := _chunk(Vector3(x + 0.6, 0.2, -7.0))
	await ticks(5)
	var n0 := DebrisManager.count()
	_track(chunk)
	check(th.combat.pick_up_debris(chunk), "pick_up_debris accepted")
	check(DebrisManager.count() == n0 - 1, "chunk released from DebrisManager")
	check(chunk.get_parent() == th.rig.get_attachment(&"RightHand"), "chunk rides the right hand")
	check(not th.combat.pick_up_debris(_chunk(Vector3(x - 0.6, 0.2, -7.0))), "one chunk at a time")
	clear_events()
	var hp5 := p5.hp
	check(th.combat.start_enemy_attack(&"e_throw_debris", 0.4), "throw started")
	ok = await wait_until(func() -> bool: return _landed(&"e_throw_debris", p5) != null, 3.0)
	check(ok, "the carried chunk hit the player")
	check(ok and chunk.get_parent() != th.rig.get_attachment(&"RightHand"), "it was the real chunk (left the hand)")
	check(is_equal_approx(hp5 - p5.hp, Tuning.DMG_ENEMY[&"e_throw_debris"]), "projectile damage %.0f" % (hp5 - p5.hp))
	var spawned := 0
	for c in get_children():
		if c is ThrownChunk:
			spawned += 1
	check(spawned == 0, "no box spawned when a chunk was carried")
	await wait_real(1.0)
	var pk: Array = _peaks[chunk]
	check(pk[0] <= PEAK_LIMIT and pk[1] <= PEAK_LIMIT,
		"picked-up chunk peak %.1f m/s (velocity), %.1f m/s (moved) from pickup to landing <= %.0f" % [pk[0], pk[1], PEAK_LIMIT])

	print("Thrower: carried chunk survives a fast windup and a throw from beside a wall")
	x = _lane()
	var _p5b := spawn(&"player", Vector3(x, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var th2 := spawn(&"thrower", Vector3(x, 0, -7.0), Vector3.BACK)
	var wall := StaticBody3D.new()
	wall.collision_layer = Layers.WORLD
	var wcs := CollisionShape3D.new()
	var wbox := BoxShape3D.new()
	wbox.size = Vector3(4.0, 3.0, 0.3)
	wcs.shape = wbox
	wall.add_child(wcs)
	add_child(wall)
	wall.global_position = Vector3(x, 1.5, -6.35)  # 0.65 m in front of the thrower
	await ticks(15)
	var big := _chunk(Vector3(x + 0.8, 0.3, -7.2))
	await wait_real(0.3)
	_track(big)
	check(th2.combat.pick_up_debris(big), "picked up a chunk next to a wall")
	await wait_real(0.3)
	th2.combat.start_enemy_attack(&"e_throw_debris", 0.35)
	await wait_real(2.0)
	pk = _peaks[big]
	check(pk[0] <= PEAK_LIMIT and pk[1] <= PEAK_LIMIT,
		"chunk thrown beside a wall: peak %.1f / %.1f m/s <= %.0f" % [pk[0], pk[1], PEAK_LIMIT])

	print("ThrownChunk.launch_body on any RigidBody")
	x = _lane()
	var p6 := spawn(&"player", Vector3(x, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var g6 := spawn(&"grunt", Vector3(x, 0, -6.0), Vector3.BACK)
	await ticks(15)
	var b6 := _chunk(Vector3(x, 1.2, -1.0))
	DebrisManager.release(b6)
	clear_events()
	var probe := ThrownChunk.launch_body(b6, ThrownChunk.ballistic_velocity(b6.global_position, g6.get_aim_point(), 14.0), p6, 33.0, &"debris_kick")
	check(probe != null, "probe attached")
	ok = await wait_until(func() -> bool: return _landed(&"debris_kick", g6) != null, 2.0)
	check(ok, "launched body hit the grunt")
	if ok:
		check(_landed(&"debris_kick", g6).kind == &"projectile" and _landed(&"debris_kick", g6).attacker == p6, "projectile from the player")
	await wait_real(0.3)
	check(DebrisManager.get_bodies().has(b6), "body returned to DebrisManager after the hit")

	print("debris kick")
	x = _lane()
	var p7 := spawn(&"player", Vector3(x, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var g7 := spawn(&"grunt", Vector3(x, 0, -7.0), Vector3.BACK)  # beyond the strike's pick: no glide
	await ticks(15)
	var b7 := _chunk(Vector3(x, 0.15, -0.8))
	await wait_real(0.5)
	_track(b7)
	clear_events()
	p7.combat.press(CombatController.Action.FRONT_KICK)
	p7.combat.release(CombatController.Action.FRONT_KICK)
	ok = await wait_until(func() -> bool: return b7.linear_velocity.length() > 8.0, 1.0)
	check(ok, "kick launched the chunk (%.1f m/s)" % b7.linear_velocity.length())
	ok = await wait_until(func() -> bool: return _landed(&"debris_kick", g7) != null, 2.0)
	check(ok, "kicked chunk hit the grunt 7 m away")
	await wait_real(1.0)
	pk = _peaks[b7]
	check(pk[0] <= PEAK_LIMIT and pk[1] <= PEAK_LIMIT,
		"debris-kicked chunk peak %.1f m/s (velocity), %.1f m/s (moved) <= %.0f" % [pk[0], pk[1], PEAK_LIMIT])

	done()
