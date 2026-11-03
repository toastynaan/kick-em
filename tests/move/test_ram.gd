extends "res://tests/move/move_test_base.gd"
## F8 Battering Ram (Feel Reference: Running into enemies). Checks, with
## measured numbers:
## - base level, heavy: the runner is knocked down (the heavy only flinches)
##   and can act again within 1.1 s;
## - base level, grunt: both stumble, the runner drops to walking speed;
## - level 3 (Round 7 amendment): a line of 3 grunts are all launched, ahead and
##   up at the runner's speed x R7_RAM_LAUNCH_SHARE, R7_RAM_LAUNCH_ANGLE up
##   (speed and angle printed), the runner keeps 95% per ram; the launches go
##   through the hit pipeline with the player as the attacker (pursuit window);
## - every collision adds a 50 ms hitstop on both;
## - levels 0-2 never launch (tiers <= knockdown, bodies drop in place); level 3
##   launches normal enemies and knocks heavies down;
## - 200 sprint attacks at base level never knock the player down;
## - below 85% of the cap a touch is not a ram.

const LANE_Z0 := 14.0

## Simulated seconds (the timeout counts fixed-fps time).
func _init() -> void:
	_timeout = 900.0

func run() -> void:
	var p := spawn_player(Vector3(0.0, 0.0, LANE_Z0))
	await ticks(30)
	await _base_heavy(p)
	await _base_grunt(p)
	await _slow_touch(p)
	await _level3_line(p)
	await _no_launch_any_level(p)  # levels 0-2 (and heavies at 3) never launch; a level-3 grunt does
	await _sprint_attacks(p, 200)
	done()

## Sprint from LANE_Z0 at x toward -Z until the first rammed event (or timeout).
func _ram_run(p: Fighter, x := 0.0, max_ticks := 600) -> bool:
	await settle(p, 10)
	p.global_position = Vector3(x, 0.02, LANE_Z0)
	p.rotation.y = 0.0
	await ticks(6)
	p.move_input = Vector3.FORWARD
	dash_down(p)
	return await wait_until(func() -> bool: return count_events(&"rammed") > 0, max_ticks)

func _victim_info(p: Fighter, v: Fighter) -> HitInfo:
	for e in events_of(&"hit_landed"):
		var info := e[0] as HitInfo
		if info != null and info.attacker == p and info.victim == v:
			return info
	return null

func _base_heavy(p: Fighter) -> void:
	Tuning.debug_ram_level = 0
	var h := spawn_enemy(&"heavy", Vector3(0.0, 0.0, -2.0))
	await ticks(10)
	clear_events()
	var rammed := await _ram_run(p)
	var t0 := TimeDirector.now()
	var ev := last_event(&"rammed")
	var frozen := p.is_frozen() and h.is_frozen()
	await ticks(1)
	var down := p.is_down()
	var info := _victim_info(p, h)
	var marks := {}
	var acted := await wait_until(func() -> bool:
		var st := p.get_state()
		if not marks.has(st):
			marks[st] = TimeDirector.now() - t0
		return p.can_act() and not p.is_down(), 360)
	var t_act := TimeDirector.now() - t0
	var parts := []
	for st in marks:
		parts.append("%s %.3f" % [RagdollController.State.keys()[st], marks[st]])
	print("  player knockdown timeline from the ram (s): %s, can act %.3f" % [", ".join(parts), t_act])
	print("  base level vs heavy (%.0f kg): rammed %s, victim %s, self %s; both frozen %s; runner down %s; can act after %.3f s; heavy tier %s" % [
		h.get_total_mass(), rammed, ev[2] if not ev.is_empty() else &"-", ev[3] if not ev.is_empty() else &"-",
		frozen, down, t_act, HitInfo.tier_name(info.tier) if info else &"-"])
	check(rammed and not ev.is_empty() and ev[3] == &"knockdown" and down, "at base level running into a heavy knocks you down")
	check(info != null and info.tier == HitInfo.Tier.FLINCH, "the heavy only flinches")
	check(frozen, "the collision freezes both (50 ms hitstop)")
	check(acted and t_act <= 1.1 + 1e-3, "you can act again within 1.1 s (%.3f s)" % t_act)
	dash_up(p)
	await settle(p, 60)
	h.queue_free()
	await ticks(2)

func _base_grunt(p: Fighter) -> void:
	Tuning.debug_ram_level = 0
	var g := spawn_enemy(&"grunt", Vector3(0.0, 0.0, -2.0))
	await ticks(10)
	clear_events()
	var rammed := await _ram_run(p)
	var ev := last_event(&"rammed")
	var info := _victim_info(p, g)
	await ticks(1)
	var p_state := p.get_state()
	var p_speed := hspeed(p)
	await ticks(10)
	print("  base level vs grunt: rammed %s, victim %s, self %s; grunt tier %s; runner state %s, speed %.2f, down %s" % [
		rammed, ev[2] if not ev.is_empty() else &"-", ev[3] if not ev.is_empty() else &"-",
		HitInfo.tier_name(info.tier) if info else &"-", RagdollController.State.keys()[p_state], p_speed, p.is_down()])
	check(rammed and not ev.is_empty() and ev[2] == &"stumble" and ev[3] == &"stumble", "at base level running into a grunt: both stumble")
	check(info != null and info.tier == HitInfo.Tier.STUMBLE, "the grunt takes a stumble-tier hit")
	check(not p.is_down() and not g.is_down(), "neither falls")
	check(p_speed <= Tuning.WALK_SPEED + 0.05, "the runner drops to walking speed (%.2f)" % p_speed)
	dash_up(p)
	await settle(p, 90)
	g.queue_free()
	await ticks(2)

func _slow_touch(p: Fighter) -> void:
	# A heavy 1.6 m ahead of a fresh sprint: contact ~0.15 s in, the opening
	# burst runs at up to 10 m/s but the earned sprint speed is ~6.3 (< 85% of 8).
	Tuning.debug_ram_level = 0
	var g := spawn_enemy(&"heavy", Vector3(0.0, 0.0, LANE_Z0 - 1.6))
	await ticks(10)
	await settle(p, 5)
	p.global_position = Vector3(0.0, 0.02, LANE_Z0)
	p.rotation.y = 0.0
	await ticks(4)
	clear_events()
	p.move_input = Vector3.FORWARD
	dash_down(p)
	var touched := await wait_until(func() -> bool:
		return p.global_position.distance_to(g.global_position) <= 0.7, 60)
	var v := hspeed(p)
	var earned := p.traversal.speed_toward(Vector3.FORWARD)
	await ticks(30)
	print("  touching a heavy %.2f s into a sprint (moving %.2f, earned %.2f; 85%% of %.1f = %.2f): touched %s, rams %d, down %s" % [
		0.15, v, earned, p.traversal.get_speed_cap(), p.traversal.get_speed_cap() * Tuning.RAM_SPEED_SHARE, touched,
		count_events(&"rammed"), p.is_down()])
	check(touched and count_events(&"rammed") == 0 and not p.is_down(), "under 85% of the cap a touch is not a ram")
	dash_up(p)
	await settle(p, 30)
	g.queue_free()
	await ticks(2)

func _level3_line(p: Fighter) -> void:
	Tuning.debug_ram_level = 3
	# Spaced and staggered so a launched body does not bowl the next one (it
	# flies to the side the grunt stood on).
	var line: Array[Fighter] = []
	for spot: Vector2 in [Vector2(0.25, -2.0), Vector2(-0.25, -10.0), Vector2(0.25, -18.0)]:
		line.append(spawn_enemy(&"grunt", Vector3(spot.x, 0.0, spot.y)))
	await ticks(10)
	await settle(p, 10)
	p.global_position = Vector3(0.0, 0.02, LANE_Z0)
	p.rotation.y = 0.0
	await ticks(6)
	clear_events()
	var v_before: Array[float] = []
	var v_after_each: Array[float] = []
	p.move_input = Vector3.FORWARD
	dash_down(p)
	var prev := 0.0
	for i in 600:
		var n := count_events(&"rammed")
		await get_tree().physics_frame
		if count_events(&"rammed") > n:
			v_before.append(prev)
			v_after_each.append(hspeed(p))
		prev = hspeed(p)
		if count_events(&"rammed") >= 3 or p.global_position.z < -22.0:
			break
	var v_after := hspeed(p)
	await ticks(20)
	var tiers := []
	var flying := 0
	var rows := []
	var ok_speed := true
	for g in line:
		var info := _victim_info(p, g)
		tiers.append(HitInfo.tier_name(info.tier) if info else &"-")
		if g.is_launched() or g.is_down():
			flying += 1
		var lv: Vector3 = info.launch_velocity if info else Vector3.ZERO
		var flat := Vector2(lv.x, lv.z).length()
		var ang := rad_to_deg(atan2(lv.y, flat))
		rows.append("%.2f m/s at %.1f deg" % [lv.length(), ang])
		if info == null or not near(ang, Tuning.R7_RAM_LAUNCH_ANGLE, 0.5):
			ok_speed = false
	# Each launch speed against the runner's speed at that ram.
	var ratios := []
	for i in mini(v_before.size(), line.size()):
		var info := _victim_info(p, line[i])
		var r := (info.launch_velocity.length() / maxf(v_before[i], 0.01)) if info else 0.0
		ratios.append("%.2f" % r)
		if not near(r, Tuning.R7_RAM_LAUNCH_SHARE, 0.1):
			ok_speed = false
	var keeps := []
	var ok_keep := v_before.size() == 3
	for i in mini(v_before.size(), v_after_each.size()):
		var k := v_after_each[i] / maxf(v_before[i], 0.01)
		keeps.append("%.2f->%.2f (%.0f%%)" % [v_before[i], v_after_each[i], k * 100.0])
		ok_keep = ok_keep and near(k, 0.95, 0.02)
	print("  level 3 through a line of 3 grunts: rams %d, tiers %s, launched %d, launches %s (x runner speed %s; want x%.1f, %.0f deg up), runner per ram %s, %.2f m/s after, down %s" % [
		count_events(&"rammed"), tiers, flying, rows, ratios, Tuning.R7_RAM_LAUNCH_SHARE, Tuning.R7_RAM_LAUNCH_ANGLE,
		keeps, v_after, p.is_down()])
	check(count_events(&"rammed") == 3 and tiers == [&"launch", &"launch", &"launch"] and flying == 3,
		"at level 3 a line of 3 grunts are all launched")
	check(ok_speed and ratios.size() == 3, "each flies at the runner's speed x %.1f, %.0f degrees up" % [Tuning.R7_RAM_LAUNCH_SHARE, Tuning.R7_RAM_LAUNCH_ANGLE])
	var launched_ev := 0
	for e in events_of(&"fighter_launched"):
		if line.has(e[0]):
			launched_ev += 1
	check(launched_ev >= 3, "the launches go through the hit pipeline (HitInfo attacker = the player) and Fighter.launch (fighter_launched x %d)" % launched_ev)
	check(not p.is_down() and ok_keep, "the runner keeps 95%% of its speed per ram (%s)" % ", ".join(keeps))
	dash_up(p)
	await settle(p, 30)
	for g in line:
		g.queue_free()
	await ticks(2)
	Tuning.debug_ram_level = 0

func _no_launch_any_level(p: Fighter) -> void:
	var worst_tier := 0
	var worst_speed := 0.0
	var launches := 0
	var rows := []
	var l3_grunt_launched := false
	for lvl in 4:
		for arch: StringName in [&"grunt", &"heavy"]:
			Tuning.debug_ram_level = lvl
			var e := spawn_enemy(arch, Vector3(0.0, 0.0, -2.0))
			await ticks(10)
			clear_events()
			await _ram_run(p)
			var peak := 0.0
			for i in 60:
				await get_tree().physics_frame
				var cv := e.get_com_velocity()
				peak = maxf(peak, Vector2(cv.x, cv.z).length())
			var info := _victim_info(p, e)
			var t := info.tier if info else 0
			rows.append("L%d %s:%s %.1f" % [lvl, arch, HitInfo.tier_name(t), peak])
			if lvl == 3 and arch == &"grunt":
				# The amendment: level 3 launches normal enemies (checked above and here).
				l3_grunt_launched = info != null and info.tier == HitInfo.Tier.LAUNCH and peak > 5.0
				dash_up(p)
				await settle(p, 90)
				e.queue_free()
				await ticks(2)
				continue
			worst_tier = maxi(worst_tier, t)
			worst_speed = maxf(worst_speed, peak)
			for le in events_of(&"fighter_launched"):
				if le[0] == e and (le[1] as Vector3).length() > 3.0:
					launches += 1
			if info != null and (HitInfo.is_launch_tier(info.tier) or info.launch_velocity.length() > 0.0):
				launches += 1
			dash_up(p)
			await settle(p, 90)
			e.queue_free()
			await ticks(2)
	Tuning.debug_ram_level = 0
	print("  every level x grunt/heavy (tier, victim peak horizontal COM m/s): %s" % ", ".join(rows))
	check(launches == 0 and worst_tier <= HitInfo.Tier.KNOCKDOWN, "levels 0-2 and heavies at level 3: no launch (worst tier %s)" % HitInfo.tier_name(worst_tier))
	# The slowest launch (6 m/s at 30 degrees) moves 5.2 m/s sideways.
	check(worst_speed < 4.5, "those rammed bodies never fly: peak horizontal %.2f m/s (a launch is >= 5.2)" % worst_speed)
	check(l3_grunt_launched, "level 3 launches a grunt (the amendment)")

func _sprint_attacks(p: Fighter, n: int) -> void:
	Tuning.debug_ram_level = 0
	var cnt := {"downs": 0}
	var rams_seen := 0
	var attacks := 0
	var watch := func(_old: int, new_state: int) -> void:
		if new_state == RagdollController.State.LAUNCHED or new_state == RagdollController.State.GROUNDED:
			cnt["downs"] += 1
	p.ragdoll.state_changed.connect(watch)
	clear_events()
	for i in n:
		var arch: StringName = &"heavy" if i % 2 == 0 else &"grunt"
		var e := spawn_enemy(arch, Vector3(0.0, 0.0, 2.0))
		await settle(p, 3)
		p.global_position = Vector3(0.0, 0.02, 12.5)
		p.rotation.y = 0.0
		await ticks(3)
		p.move_input = Vector3.FORWARD
		dash_down(p)
		var reached := await wait_until(func() -> bool:
			return p.global_position.z - e.global_position.z <= 2.0, 300)
		var act := CombatController.Action.LIGHT if i % 3 != 2 else CombatController.Action.KICK
		p.combat.press(act)
		p.combat.release(act)
		if reached and await wait_until(func() -> bool: return p.combat.is_attacking(), 6):
			attacks += 1
		await wait_until(func() -> bool: return not p.combat.is_attacking(), 240)
		await ticks(20)
		if p.is_down():
			await wait_until(func() -> bool: return not p.is_down(), 600)
		dash_up(p)
		e.queue_free()
		await ticks(1)
	p.ragdoll.state_changed.disconnect(watch)
	var downs: int = cnt["downs"]
	rams_seen = count_events(&"rammed")
	print("  %d sprint attacks at base level (heavy / grunt alternating): attacks started %d, rams %d, player knocked down %d" % [
		n, attacks, rams_seen, downs])
	check(attacks == n, "every sprint attack started (%d / %d)" % [attacks, n])
	check(downs == 0 and rams_seen == 0, "over %d sprint attacks at base level the player is knocked down 0 times" % n)
