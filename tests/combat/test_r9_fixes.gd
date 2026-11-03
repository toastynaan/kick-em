extends "res://tests/combat/combat_test_base.gd"
## Round 9 (docs/Round 9 — Playtest Fixes.md), one light check per fix of
## agent B's (the guard-broken rule is checked in test_r8_pressure):
## - hook: a charged hook's knockdown (c 0.5) and launch (c 1) go along the
##   hit; Fighter.add_spin gets R9_HOOK_SPIN lerped by c (left hook: positive),
##   the knockdown hops R9_HOOK_HOP;
## - the punch string holds through a whiff and goes back to the jab
##   R9_STRING_RESET after the punch;
## - axe kick: a leg kick press at a lifted body plays the axe kick: a spike
##   straight down at R9_AXE's tap speed, its floor shockwave R9_AXE's tap blast;
## - downed bodies: a leg kick whose foot touches a lying body hits it (react
##   &"ground", R9_GROUND_HIT tap damage, the shove, the get-up delayed).

var _x := 0.0

func _init() -> void:
	_timeout = 90.0

func run() -> void:
	await _hook()
	await _string()
	await _axe()
	await _ground()
	done()

## A fake player and a fake grunt 1 m ahead on fresh ground, events cleared.
func _lane() -> Array:
	_x += 12.0
	var p := spawn_fake(&"player", Vector3(_x, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	p.combat.sever_on_kill_chance = 0.0
	var v := spawn_fake(&"grunt", Vector3(_x, 0, -1.0), Vector3.BACK)
	await ticks(15)
	clear_events()
	return [p, v]

func _hook() -> void:
	print("hook: forward and spinning")
	for c: float in [0.5, 1.0]:
		var r := await _lane()
		var p: Fighter = r[0]
		var v: Fighter = r[1]
		p.combat.play_charged(&"hook", c, v)
		await wait_until(func() -> bool: return not hits_on(v).is_empty(), 1.5)
		await ticks(2)
		var info: HitInfo = hits_on(v)[0] if not hits_on(v).is_empty() else null
		var spins: Array[float] = v.get(&"spins")
		var want_spin := lerpf(Tuning.R9_HOOK_SPIN.x, Tuning.R9_HOOK_SPIN.y, c)
		var along := 0.0
		if info != null and info.react == &"knockdown":
			for rec: Array in v.get(&"reacts"):
				if rec[0] == &"knockdown":
					along = (rec[1] as Vector3).normalized().dot(info.hit_direction)
		elif info != null:
			var lv := info.launch_velocity
			along = Vector3(lv.x, 0.0, lv.z).normalized().dot(info.hit_direction)
		var hop := float(info.get_meta(&"hop", 0.0)) if info != null else 0.0
		print("  c %.1f: react %s, along the hit %.3f, add_spin %s (want %.1f), hop %.1f" % [c,
			info.react if info else &"-", along, spins, want_spin, hop])
		var want_react := &"knockdown" if c < 1.0 else &"launch"
		check(info != null and info.react == want_react and along > 0.99 and spins.size() == 1
			and absf(spins[0] - want_spin) < 1e-3 and (hop == Tuning.R9_HOOK_HOP if c < 1.0 else hop == 0.0),
			"charged hook c %.1f: %s along the hit, add_spin(+%.0f)%s" % [c, want_react, want_spin,
				", hop %.1f m/s" % Tuning.R9_HOOK_HOP if c < 1.0 else ""])
		p.queue_free()
		v.queue_free()

func _string() -> void:
	print("the punch string holds; R9_STRING_RESET idle resets it")
	var r := await _lane()
	var p: Fighter = r[0]
	var v: Fighter = r[1]
	v.global_position += Vector3(0, 0, -20)  # nothing to hit: the jab whiffs
	await ticks(2)
	tap(p, A.LIGHT)
	await wait_until(func() -> bool: return p.combat.is_attacking(), 0.5)
	await wait_until(func() -> bool: return not p.combat.is_attacking(), 2.0)
	var t_end := TimeDirector.now()
	var idx := p.combat.get_string_index()
	await wait_until(func() -> bool: return p.combat.get_string_index() == 0, Tuning.R9_STRING_RESET + 1.0)
	var reset_after := TimeDirector.now() - t_end
	print("  after the whiffed jab: index %d; back to the jab %.3f s after it ended (want %.2f)" % [idx, reset_after,
		Tuning.R9_STRING_RESET])
	check(idx == 1 and absf(reset_after - Tuning.R9_STRING_RESET) <= 0.03,
		"a whiff keeps the string (the cross next); the jab again after R9_STRING_RESET idle")
	p.queue_free()
	v.queue_free()

func _axe() -> void:
	print("axe kick: the leg kick on a lifted body")
	var r := await _lane()
	var p: Fighter = r[0]
	var v: Fighter = r[1]
	var moves := record_moves(p)
	var waves: Array = []
	var on_wave := func(f: Node3D, _pos: Vector3, radius: float, _kd: float) -> void:
		if f == p:
			waves.append(radius)
	GameEvents.shockwave.connect(on_wave)
	p.combat.play_charged(&"uppercut", 1.0, v)
	await wait_until(func() -> bool: return v.is_lifted() and not p.combat.is_attacking(), 2.0)
	var lifted := v.is_lifted()
	tap(p, A.LEG_KICK)
	await wait_until(func() -> bool: return hits_on(v).size() >= 2, 1.5)
	var info: HitInfo = hits_on(v)[-1] if hits_on(v).size() >= 2 else null
	await wait_until(func() -> bool: return not waves.is_empty(), 2.0)
	GameEvents.shockwave.disconnect(on_wave)
	var speed: float = Tuning.R9_AXE["tap"]["speed"]
	var blast: float = Tuning.R9_AXE["tap"]["blast"]
	print("  lifted %s; moves %s; hit %s react %s, velocity %s; shockwave radii %s (want %.1f)" % [lifted, moves,
		info.move_id if info else &"-", info.react if info else &"-", info.launch_velocity if info else Vector3.ZERO,
		waves, blast])
	check(lifted and moves.has(MoveLibrary.AXE) and info != null and info.move_id == MoveLibrary.AXE
		and info.react == &"spike" and info.launch_velocity.y < -speed * 0.99,
		"a leg kick on the lifted body is the axe kick: a spike down at %.0f m/s" % speed)
	check(waves.size() == 1 and is_equal_approx(float(waves[0]), blast), "its floor shockwave has the axe's blast (%.1f m)" % blast)
	p.queue_free()
	v.queue_free()

func _ground() -> void:
	print("downed bodies: a leg kick whose foot touches a lying body hits it")
	var r := await _lane()
	var p: Fighter = r[0]
	var v: Fighter = r[1]
	# Where the leg kick's foot is in its active frames, in the kicker's frame (no one near).
	v.global_position += Vector3(0, 0, -20)
	await ticks(4)
	var feet: Array[Vector3] = []
	p.combat.play_move(&"leg_kick")
	while p.combat.is_attacking():
		if p.combat.is_attack_active():
			feet.append(p.rig.get_bone_global_position(&"RightFoot") - p.global_position)
		await get_tree().physics_frame
	var foot: Vector3 = feet[-1] if not feet.is_empty() else Vector3(0, 0.4, -0.9)
	var fwd := p.get_forward()
	var right := fwd.cross(Vector3.UP).normalized()
	var off_f := foot.dot(fwd)
	var off_r := foot.dot(right)
	# Knock the grunt down and wait until it lies still.
	v.global_position = p.global_position + fwd * 3.0
	v.reset_physics_interpolation()
	await ticks(4)
	v.knockdown(fwd, Bones.CHEST)
	await wait_until(func() -> bool: return v.get_state() == RagdollController.State.GROUNDED, 3.0)
	var at := v.rig.get_bone_global_position(Bones.SPINE)
	p.teleport_to(Vector3(at.x, 0.0, at.z) - fwd * off_f - right * off_r, fwd)
	await ticks(6)
	var shove := [Vector3.ZERO]
	var on_hit := func(i: HitInfo) -> void:
		if i.victim == v:
			shove[0] = v.get_com_velocity()
	GameEvents.hit_landed.connect(on_hit)
	clear_events()
	p.combat.play_move(&"leg_kick")
	await wait_until(func() -> bool: return not hits_on(v).is_empty() or not p.combat.is_attacking(), 1.5)
	GameEvents.hit_landed.disconnect(on_hit)
	var info: HitInfo = hits_on(v)[0] if not hits_on(v).is_empty() else null
	var delay := v.ragdoll.get_getup_delay_left()
	var dmg: float = (Tuning.R9_GROUND_HIT["dmg"] as Vector2).x
	var along := Vector3(shove[0].x, 0.0, shove[0].z).dot(info.hit_direction) if info else 0.0
	print("  foot at %.2f m ahead, %.2f m right; hit %s react %s bone %s damage %.2f (want %.1f); body speed along the strike %.2f m/s; get-up delay %.2f s" % [
		off_f, off_r, info != null, info.react if info else &"-", info.hit_bone if info else &"-",
		info.damage if info else 0.0, dmg, along, delay])
	check(info != null and info.react == &"ground" and info.ground_strike and absf(info.damage - dmg) < 1e-3
		and along > 1.5 and delay > CombatController.GROUND_HIT_HOLD - 0.1,
		"the lying body is hit: react &\"ground\", %.0f damage, shoved, the get-up delayed" % dmg)
	p.queue_free()
	v.queue_free()
