extends "res://tests/combat/combat_test_base.gd"
## Round 7 hit rules on enemies (docs/Round 7 — Freeflow Combat.md: Hit feel):
## - enemy guard (the AI holding Block): it blocks tapped punches (chip damage,
##   no reaction); heavies, the gut punch, the uppercut and every kick break the
##   guard: the hit lands with its reaction (HitInfo meta "guard_broken") and the
##   guard drops;
## - enemy tell armor (the heavy archetype in a tell, a move's armor): a tapped
##   punch deals its damage and a small snap and the attack goes on; heavies,
##   specials and kicks break the armor (the attack is cancelled, the reaction
##   plays);
## - a guard only covers the front.

var _x := 0.0

func _init() -> void:
	_timeout = 120.0

func run() -> void:
	print("enemy guard")
	for spec: Array in [[&"jab", false], [&"cross", false], [&"hook", false], [&"heavy_jab", true],
			[&"gut_punch", true], [&"uppercut", true], [&"leg_kick", true], [&"front_kick", true], [&"roundhouse", true]]:
		var r: Array = await _lane(&"grunt", 1.0)
		var p: Fighter = r[0]
		var g: Fighter = r[1]
		g.combat.press(A.BLOCK)
		await ticks(4)
		var guarding := g.combat.is_blocking()
		var hp0 := g.hp
		clear_events()
		p.combat.play_move(spec[0], g)
		await wait_until(func() -> bool: return count_events(&"hit_blocked") + count_events(&"hit_landed") > 0, 1.5)
		await ticks(2)
		var blocked := count_events(&"hit_blocked") > 0
		var info: HitInfo = hits_on(g)[0] if not hits_on(g).is_empty() else null
		var chip := float(Tuning.R7_MOVES[spec[0]]["dmg"]) * Tuning.GUARD_DAMAGE_MULT
		if spec[1]:
			check(guarding and not blocked and info != null and info.get_meta(&"guard_broken", false) and info.react != &""
				and not g.combat.is_blocking(), "%s breaks the guard: %s, the guard drops" % [spec[0], info.react if info else &"-"])
		else:
			check(guarding and blocked and info == null and is_equal_approx(hp0 - g.hp, chip) and not g.is_reacting(),
				"a guard blocks the tapped %s (chip %.1f)" % [spec[0], hp0 - g.hp])
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
	for spec: Array in [[&"jab", true], [&"hook", true], [&"heavy_jab", false], [&"gut_punch", false], [&"leg_kick", false]]:
		var r: Array = await _lane(&"heavy", 1.3)
		var p: Fighter = r[0]
		var h: Fighter = r[1]
		h.combat.start_enemy_attack(&"e_heavy", 0.7)
		await ticks(3)
		var hp0 := h.hp
		clear_events()
		p.combat.play_move(spec[0], h)
		await wait_until(func() -> bool: return not hits_on(h).is_empty(), 1.5)
		await ticks(2)
		var info: HitInfo = hits_on(h)[0] if not hits_on(h).is_empty() else null
		var dmg := hp0 - h.hp
		if spec[1]:
			check(info != null and info.get_meta(&"armored", false) and info.react == &"snap" and dmg > 0.0
				and h.combat.is_attacking() and h.combat.current_move_id() == &"e_heavy" and not h.is_reacting(),
				"the tapped %s on the armored tell: %.1f damage, a small snap, it keeps attacking" % [spec[0], dmg])
			var reached := await wait_until(func() -> bool: return h.combat.is_attack_active(), 1.5)
			check(reached, "its attack still reaches its active frames")
		else:
			check(info != null and not info.get_meta(&"armored", false) and not h.combat.is_attacking()
				and (h.is_reacting() or h.is_down()), "%s breaks the armor: the attack is cancelled, %s" % [spec[0],
				info.react if info else &"-"])
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
