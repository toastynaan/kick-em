extends "res://tests/combat/combat_test_base.gd"
## Round 7 hit rules on enemies (docs/Round 7 — Freeflow Combat.md: Hit feel),
## rewritten for Round 8 (docs/Round 8 — Charge and Pressure.md: Moves: taps
## never break a guard or tell armor, charged strikes always do):
## - enemy guard (the AI holding Block): it blocks every tap (chip damage, no
##   reaction, the blocked hit's pressure added); every charged strike (and the
##   Round 7 heavy jab) breaks the guard: the hit lands with its reaction
##   (HitInfo meta "guard_broken") and the guard drops;
## - enemy tell armor (the heavy archetype in a tell, a move's armor): a tap
##   deals its damage and a small snap and the attack goes on; charged strikes
##   break the armor (the attack is cancelled, the reaction plays);
## - a guard only covers the front.

var _x := 0.0

func _init() -> void:
	_timeout = 120.0

func run() -> void:
	print("enemy guard")
	var guard_specs: Array = []
	for id: StringName in Tuning.R8_MOVES:
		guard_specs.append([id, false, -1.0])   # the tap: blocked
		guard_specs.append([id, true, 0.0])     # charged (c = 0): breaks the guard
	guard_specs.append([&"heavy_jab", true, -1.0])  # a Round 7 heavy (play_move) still breaks it
	for spec: Array in guard_specs:
		var r: Array = await _lane(&"grunt", 1.0)
		var p: Fighter = r[0]
		var g: Fighter = r[1]
		g.combat.press(A.BLOCK)
		await ticks(4)
		var guarding := g.combat.is_blocking()
		var hp0 := g.hp
		clear_events()
		if float(spec[2]) >= 0.0:
			p.combat.play_charged(spec[0], spec[2], g)
		else:
			p.combat.play_move(spec[0], g)
		await wait_until(func() -> bool: return count_events(&"hit_blocked") + count_events(&"hit_landed") > 0, 1.5)
		await ticks(2)
		var blocked := count_events(&"hit_blocked") > 0
		var info: HitInfo = hits_on(g)[0] if not hits_on(g).is_empty() else null
		var label := "%s%s" % [spec[0], " charged" if float(spec[2]) >= 0.0 else ""]
		if spec[1]:
			check(guarding and not blocked and info != null and info.get_meta(&"guard_broken", false) and info.react != &""
				and not g.combat.is_blocking(), "%s breaks the guard: %s, the guard drops" % [label, info.react if info else &"-"])
		else:
			var tap: Dictionary = Tuning.R8_MOVES[spec[0]]["tap"]
			var chip := float(tap["dmg"]) * Tuning.GUARD_DAMAGE_MULT
			var bi: HitInfo = events_of(&"hit_blocked")[0][1] if blocked else null
			var want_p := float(tap["pressure"]) * Tuning.R8_BLOCKED_PRESSURE_MULT
			check(guarding and blocked and info == null and is_equal_approx(hp0 - g.hp, chip) and not g.is_reacting()
				and bi != null and is_equal_approx(bi.pressure, want_p) and is_equal_approx(g.combat.get_pressure(), want_p),
				"a guard blocks the %s tap (chip %.1f, pressure %.1f)" % [spec[0], hp0 - g.hp, g.combat.get_pressure()])
		g.combat.release(A.BLOCK)
		p.queue_free()
		g.queue_free()
	var rb: Array = await _lane(&"grunt", 1.0)
	(rb[1] as Fighter).snap_facing(Vector3.FORWARD)  # back turned
	(rb[1] as Fighter).combat.press(A.BLOCK)
	await ticks(4)
	clear_events()
	(rb[0] as Fighter).combat.play_move(&"jab", rb[1])
	await wait_until(func() -> bool: return count_events(&"hit_blocked") + count_events(&"hit_landed") > 0, 1.5)
	check(count_events(&"hit_landed") == 1 and count_events(&"hit_blocked") == 0, "a guard only covers the front")

	print("enemy tell armor (the heavy in its tell)")
	for spec: Array in [[&"jab", true, -1.0], [&"hook", true, -1.0], [&"leg_kick", true, -1.0], [&"heavy_jab", false, -1.0],
			[&"gut_punch", false, 0.0], [&"leg_kick", false, 0.0], [&"jab", false, 1.0]]:
		var r: Array = await _lane(&"heavy", 1.3)
		var p: Fighter = r[0]
		var h: Fighter = r[1]
		h.combat.start_enemy_attack(&"e_heavy", 0.7)
		await ticks(3)
		var hp0 := h.hp
		clear_events()
		if float(spec[2]) >= 0.0:
			p.combat.play_charged(spec[0], spec[2], h)
		else:
			p.combat.play_move(spec[0], h)
		await wait_until(func() -> bool: return not hits_on(h).is_empty(), 1.5)
		await ticks(2)
		var info: HitInfo = hits_on(h)[0] if not hits_on(h).is_empty() else null
		var dmg := hp0 - h.hp
		if spec[1]:
			check(info != null and info.get_meta(&"armored", false) and info.react == &"snap" and dmg > 0.0
				and h.combat.is_attacking() and h.combat.current_move_id() == &"e_heavy" and not h.is_reacting(),
				"the %s tap on the armored tell: %.1f damage, a small snap, it keeps attacking" % [spec[0], dmg])
			var reached := await wait_until(func() -> bool: return h.combat.is_attack_active(), 1.5)
			check(reached, "its attack still reaches its active frames")
		else:
			check(info != null and not info.get_meta(&"armored", false) and not h.combat.is_attacking()
				and (h.is_reacting() or h.is_down()), "%s%s breaks the armor: the attack is cancelled, %s" % [spec[0],
				" charged" if float(spec[2]) >= 0.0 else "", info.react if info else &"-"])
		p.queue_free()
		h.queue_free()
	done()

## A fake player and an enemy dummy `dist` m in front, on fresh ground.
func _lane(arch: StringName, dist: float) -> Array:
	_x += 15.0
	var p := spawn_fake(&"player", Vector3(_x, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var e := spawn(arch, Vector3(_x, 0, -dist), Vector3.BACK)
	await ticks(15)
	return [p, e]
