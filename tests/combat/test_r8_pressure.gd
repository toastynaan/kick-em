extends "res://tests/combat/combat_test_base.gd"
## Round 8 acceptance check 5 (docs/Round 8 — Charge and Pressure.md: Pressure),
## with agent H's real reactions:
## - capacity Tuning.r8_pressure_cap(archetype, Fighter.level): a level-1 grunt
##   2.5 (levels 2 and 3: 5 and 8), the Duelist 16;
## - a level-1 grunt breaks on the 3rd jab (pressure_broken), not before;
##   Tuning.debug_pressure_mult 2 doubles a jab's pressure;
## - blocked hits add pressure (x R8_BLOCKED_PRESSURE_MULT) and the guard
##   breaks that way;
## - the break lasts R8_BREAK_TIME with no attack and no block (the AI still
##   holding Block), the react state &"broken", then pressure_recovered;
## - hits on a broken grunt: x R8_BREAK_DAMAGE_MULT damage, x R8_BREAK_PUSH_MULT
##   push, HitInfo.broken_bonus;
## - the meter drains after R8_PRESSURE_DECAY_DELAY idle at R8_PRESSURE_DECAY
##   of its capacity per s;
## - after a break it is empty and fills at R8_BREAK_IMMUNE_RATE for
##   R8_BREAK_IMMUNE, then at full rate;
## - the Duelist breaks on the 16th jab.

var _x := 0.0

func _init() -> void:
	_timeout = 180.0

func run() -> void:
	print("capacity")
	var r: Array = await _lane(&"grunt")
	var p: Fighter = r[0]
	var g: Fighter = r[1]
	var caps: Array[float] = []
	for lv in [1, 2, 3]:
		g.level = lv
		caps.append(g.combat.get_pressure_max())
	g.level = 1
	var d0 := spawn(&"duelist", Vector3(_x + 4.0, 0, -3), Vector3.BACK)
	await ticks(2)
	print("  grunt levels 1-3: %s, Duelist %.1f" % [caps, d0.combat.get_pressure_max()])
	check(caps == ([2.5, 5.0, 8.0] as Array[float]) and is_equal_approx(d0.combat.get_pressure_max(), 16.0),
		"grunt 2.5 / 5 / 8 by level, the Duelist 16")
	d0.queue_free()

	print("a level-1 grunt breaks on the 3rd jab")
	var seen: Array[float] = []
	var broke_at := -1
	for i in 3:
		await _jab(p, g)
		seen.append(g.combat.get_pressure())
		if broke_at < 0 and not events_of(&"pressure_broken").is_empty():
			broke_at = i + 1
	var be: Array = events_of(&"pressure_broken")[0] if not events_of(&"pressure_broken").is_empty() else []
	print("  pressure after each jab %s, broken on jab %d, fraction %.2f" % [seen, broke_at, g.combat.get_pressure_fraction()])
	check(broke_at == 3 and absf(seen[0] - 1.0) < 1e-3 and absf(seen[1] - 2.0) < 1e-3,
		"1, 2, then the 3rd jab breaks it (pressure_broken)")
	check(not be.is_empty() and be[1] == g and be[2] == p and g.combat.is_broken()
		and is_equal_approx(g.combat.get_pressure_fraction(), 1.0), "pressure_broken(grunt, player); is_broken, fraction 1")

	print("the break: no attack, no block, the daze; R8_BREAK_TIME")
	g.combat.press(A.BLOCK)  # the AI holding Block the whole time
	await wait_until(func() -> bool: return not g.is_frozen(), 0.5)
	var t0 := TimeDirector.now()
	var attacked := false
	var blocked := false
	var dazed := false
	while g.combat.is_broken() and TimeDirector.now() - t0 < 3.0:
		if g.combat.start_enemy_attack(&"e_jab", 0.6):
			attacked = true
			g.combat.cancel()
		blocked = blocked or g.combat.is_blocking()
		dazed = dazed or g.get_react_state() == &"broken"
		await get_tree().physics_frame
	var lasted := TimeDirector.now() - t0
	var rec_ev := not events_of(&"pressure_recovered").is_empty()
	await ticks(2)
	var can_after := g.combat.start_enemy_attack(&"e_jab", 0.6)
	g.combat.cancel()
	g.combat.release(A.BLOCK)
	print("DATA the break lasted %.3f s (want %.2f) after the hitstop; attacked %s, blocked %s, dazed %s; pressure_recovered %s, pressure %.2f, attacks again %s" % [
		lasted, Tuning.R8_BREAK_TIME, attacked, blocked, dazed, rec_ev, g.combat.get_pressure(), can_after])
	check(absf(lasted - Tuning.R8_BREAK_TIME) <= 1.5 / 120.0, "the break lasts %.1f s" % Tuning.R8_BREAK_TIME)
	check(not attacked and not blocked, "no attack and no block during the break")
	check(dazed, "the react state is &\"broken\" (H's daze)")
	check(rec_ev and is_equal_approx(g.combat.get_pressure(), 0.0) and can_after, "pressure_recovered, the meter empty, it attacks again")

	print("half-rate refill for R8_BREAK_IMMUNE after a break")
	await wait_until(func() -> bool: return not g.is_reacting() and not g.combat.is_attacking(), 1.0)
	var t_rec := first_time(&"pressure_recovered")
	await _jab(p, g)
	var t_into := first_time(&"hit_landed") - t_rec
	for e in events:
		if e[0] == &"hit_landed" and float(e[6]) > t_rec:
			t_into = float(e[6]) - t_rec
	var during := g.combat.get_pressure()
	var info_during: HitInfo = hits_on(g)[-1]
	var left := Tuning.R8_BREAK_IMMUNE - (TimeDirector.now() - t_rec)
	await wait_real(maxf(left, 0.0) + 0.1)
	await _jab(p, g)
	var after := hits_on(g)[-1].pressure
	print("  a jab %.2f s into the immunity adds %.2f (HitInfo.pressure %.2f); after it a jab adds %.2f" % [
		t_into, during, info_during.pressure, after])
	check(absf(during - Tuning.R8_BREAK_IMMUNE_RATE) < 1e-3 and absf(info_during.pressure - Tuning.R8_BREAK_IMMUNE_RATE) < 1e-3,
		"during the immunity a jab adds %.1f" % Tuning.R8_BREAK_IMMUNE_RATE)
	check(absf(after - 1.0) < 1e-3, "after it a jab adds 1.0 again")
	p.queue_free()
	g.queue_free()

	print("hits on a broken grunt: the bonus")
	r = await _lane(&"grunt")
	p = r[0]
	g = r[1]
	await _jab(p, g)
	var normal: HitInfo = hits_on(g)[-1]
	g.combat.set(&"_pressure", g.combat.get_pressure_max() - 0.5)
	await _jab(p, g)  # breaks it
	await wait_until(func() -> bool: return g.get_react_state() == &"broken" and not g.is_frozen(), 1.0)
	await _jab(p, g)
	var bonus: HitInfo = hits_on(g)[-1]
	var dmg_ratio := (bonus.damage / bonus.damage_scale) / (normal.damage / normal.damage_scale)
	print("DATA jab on a broken grunt: damage %.2f (unscaled x%.2f), push %.2f m (x%.2f), broken_bonus %s" % [bonus.damage,
		dmg_ratio, bonus.push, bonus.push / normal.push, bonus.broken_bonus])
	check(bonus.broken_bonus and not normal.broken_bonus and absf(dmg_ratio - Tuning.R8_BREAK_DAMAGE_MULT) < 1e-3
		and absf(bonus.push / normal.push - Tuning.R8_BREAK_PUSH_MULT) < 1e-3, "x%.1f damage and x%.1f push, broken_bonus" % [
		Tuning.R8_BREAK_DAMAGE_MULT, Tuning.R8_BREAK_PUSH_MULT])
	var launch_info := await _charged_on_broken(&"front_kick")
	if launch_info != null:
		var want := Tuning.R8_MOVES[&"front_kick"]["charged"]["launch_speed"].y * Tuning.R8_BREAK_PUSH_MULT
		print("  a full charged front kick on a broken grunt launches at %.2f m/s (want %.2f)" % [
			launch_info.launch_velocity.length(), minf(want, Tuning.LAUNCH_SPEED_MAX)])
		check(launch_info.broken_bonus and absf(launch_info.launch_velocity.length() - minf(want, Tuning.LAUNCH_SPEED_MAX)) < 0.01,
			"and x%.1f launch speed (cap LAUNCH_SPEED_MAX)" % Tuning.R8_BREAK_PUSH_MULT)
	p.queue_free()
	g.queue_free()

	print("the drain")
	r = await _lane(&"grunt")
	p = r[0]
	g = r[1]
	await _jab(p, g)
	await wait_until(func() -> bool: return not g.is_frozen(), 0.5)
	var t_hit := TimeDirector.now()
	var p_hit := g.combat.get_pressure()
	var drain_at := INF
	while TimeDirector.now() - t_hit < 2.2:
		if drain_at == INF and g.combat.get_pressure() < p_hit - 1e-4:
			drain_at = TimeDirector.now() - t_hit
		await get_tree().physics_frame
	var span := TimeDirector.now() - t_hit - drain_at
	var rate := (p_hit - g.combat.get_pressure()) / maxf(span, 1e-3) / g.combat.get_pressure_max()
	print("DATA the meter starts draining %.3f s after the last hit (want %.2f), at %.3f of capacity per s (want %.2f)" % [
		drain_at, Tuning.R8_PRESSURE_DECAY_DELAY, rate, Tuning.R8_PRESSURE_DECAY])
	check(absf(drain_at - Tuning.R8_PRESSURE_DECAY_DELAY) <= 1.5 / 120.0, "it drains after %.1f s idle" % Tuning.R8_PRESSURE_DECAY_DELAY)
	check(absf(rate - Tuning.R8_PRESSURE_DECAY) <= 0.02, "at R8_PRESSURE_DECAY of its capacity per s")
	print("debug_pressure_mult 2")
	Tuning.debug_pressure_mult = 2.0
	await _jab(p, g)
	var added := hits_on(g)[-1].pressure  # what it added (the meter is still draining around it)
	Tuning.debug_pressure_mult = 1.0
	check(absf(added - 2.0) < 1e-3, "a jab adds 2.0 (%.2f)" % added)
	p.queue_free()
	g.queue_free()

	print("blocked hits add pressure; the guard breaks that way")
	r = await _lane(&"grunt")
	p = r[0]
	g = r[1]
	g.combat.press(A.BLOCK)
	await ticks(4)
	var guard0 := g.combat.is_blocking()
	var bl: Array = []
	for i in 3:
		clear_events()
		await _jab(p, g)
		bl.append([events_of(&"hit_blocked").size(), g.combat.get_pressure(), g.combat.is_broken()])
	var binfo: HitInfo = events_of(&"hit_blocked")[0][1] if not events_of(&"hit_blocked").is_empty() else null
	print("  guarding %s; after each jab [blocked, pressure, broken]: %s; guard now %s" % [guard0, bl, g.combat.is_blocking()])
	check(guard0 and bl[0][0] == 1 and absf(float(bl[0][1]) - Tuning.R8_BLOCKED_PRESSURE_MULT) < 1e-3 and bl[1][0] == 1,
		"blocked jabs add %.1f each" % Tuning.R8_BLOCKED_PRESSURE_MULT)
	check(bool(bl[2][2]) and not g.combat.is_blocking(), "the 3rd blocked jab breaks it: the guard drops")
	g.combat.release(A.BLOCK)
	p.queue_free()
	g.queue_free()

	print("the Duelist breaks on the 16th jab")
	r = await _lane(&"duelist")
	p = r[0]
	var d: Fighter = r[1]
	var n := 0
	var broke := -1
	while n < 20 and broke < 0:
		await _jab(p, d)
		n += 1
		if not events_of(&"pressure_broken").is_empty():
			broke = n
	print("  the Duelist broke on jab %d (pressure %.1f of %.1f)" % [broke, d.combat.get_pressure(), d.combat.get_pressure_max()])
	check(broke == 16, "the Duelist needs 16")
	p.queue_free()
	d.queue_free()
	done()

## A fake player and an `arch` dummy 1.0 m ahead on fresh ground, events cleared.
func _lane(arch: StringName) -> Array:
	_x += 12.0
	var p := spawn_fake(&"player", Vector3(_x, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var v := spawn(arch, Vector3(_x, 0, -1.0), Vector3.BACK)
	await ticks(15)
	clear_events()
	return [p, v]

## A tapped jab at `v` once the player is free; waits for it to land (or be blocked).
func _jab(p: Fighter, v: Fighter) -> void:
	await wait_until(func() -> bool: return not p.combat.is_attacking(), 2.0)
	var n := hits_on(v).size() + events_of(&"hit_blocked").size()
	p.combat.play_move(&"jab", v)
	await wait_until(func() -> bool: return hits_on(v).size() + events_of(&"hit_blocked").size() > n, 1.5)
	await ticks(1)

## A full charged `id` on a freshly broken grunt; its HitInfo.
func _charged_on_broken(id: StringName) -> HitInfo:
	var r: Array = await _lane(&"grunt")
	var p: Fighter = r[0]
	var g: Fighter = r[1]
	g.combat.set(&"_pressure", g.combat.get_pressure_max() - 0.5)
	await _jab(p, g)
	await wait_until(func() -> bool: return g.get_react_state() == &"broken" and not g.is_frozen(), 1.0)
	await wait_until(func() -> bool: return not p.combat.is_attacking(), 1.0)
	var n := hits_on(g).size()
	p.combat.play_charged(id, 1.0, g)
	await wait_until(func() -> bool: return hits_on(g).size() > n, 1.5)
	var info: HitInfo = hits_on(g)[-1] if hits_on(g).size() > n else null
	await wait_real(0.3)
	p.queue_free()
	g.queue_free()
	return info
