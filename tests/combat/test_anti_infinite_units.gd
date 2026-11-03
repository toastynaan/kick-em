extends "res://tests/combat/combat_test_base.gd"
## Anti-infinite, Round 7 (docs/Round 7 — Freeflow Combat.md: Hit feel): per
## victim, from anyone; the stun of a player strike shrinks from hit
## R7_COMBO_STUN_DECAY_FROM by R7_COMBO_STUN_DECAY per hit down to
## R7_COMBO_STUN_MIN; the hit that would be number R7_COMBO_ESCAPE_HITS breaks
## the victim away (damage, no stun, pushed apart, a short auto-guard); the
## damage keeps the combo scaling (combo_scale) by the victim's count, shared
## by two attackers; enemy hits on the player keep the Round 5 decay.
## Round 8: the strikes are taps (R8_MOVES "tap" stun and damage); pressure is
## off here (Tuning.debug_pressure_mult 0), or the chain would break the grunt
## open (no guard: no auto-guard to see). Pressure has its own test.

const AimBrain := preload("res://tests/combat/aim_brain.gd")

func _init() -> void:
	_timeout = 90.0

func run() -> void:
	var was_pm := Tuning.debug_pressure_mult
	Tuning.debug_pressure_mult = 0.0
	print("Round 7 stun decay per hit")
	var d: Array = []
	var want: Array = []
	for n in range(1, 13):
		d.append(snappedf(CombatController.r7_stun_decay(n), 0.001))
		var w := 1.0
		if n >= Tuning.R7_COMBO_STUN_DECAY_FROM:
			w = maxf(Tuning.R7_COMBO_STUN_MIN, 1.0 - Tuning.R7_COMBO_STUN_DECAY * float(n - Tuning.R7_COMBO_STUN_DECAY_FROM + 1))
		want.append(snappedf(w, 0.001))
	print("  hits 1-12: %s" % [d])
	check(d == want and is_equal_approx(float(d[Tuning.R7_COMBO_STUN_DECAY_FROM - 2]), 1.0)
		and float(d[Tuning.R7_COMBO_STUN_DECAY_FROM - 1]) < 1.0, "full stun to hit %d, then the decay" % (Tuning.R7_COMBO_STUN_DECAY_FROM - 1))

	print("a chain of player strikes: stun x decay on HitInfo.stun, the break-away at hit %d" % Tuning.R7_COMBO_ESCAPE_HITS)
	var p := spawn_fake(&"player", Vector3(0, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var g := spawn(&"grunt", Vector3(0, 0, -1.0), Vector3.BACK)
	g.max_hp = 1000.0
	g.hp = 1000.0
	await ticks(12)
	var esc := [false]
	GameEvents.combo_escaped.connect(func(v: Node3D, a: Node3D) -> void:
		if v == g and a == p: esc[0] = true)
	clear_events()
	var stuns: Array = []
	for k in Tuning.R7_COMBO_ESCAPE_HITS:
		await wait_until(func() -> bool: return not p.combat.is_attacking(), 2.0)
		var n0 := hits_on(g).size()
		place_in_front(p, g, 1.0)
		p.combat.play_move(&"gut_punch", g)
		await wait_until(func() -> bool: return hits_on(g).size() > n0, 1.5)
		var h: HitInfo = hits_on(g)[n0] if hits_on(g).size() > n0 else null
		stuns.append(snappedf(h.stun, 0.001) if h else -1.0)
		if esc[0]:
			break
	var base := float(Tuning.R8_MOVES[&"gut_punch"]["tap"]["stun"])
	print("  gut punch stuns: %s (base %.2f)" % [stuns, base])
	var ok := stuns.size() == Tuning.R7_COMBO_ESCAPE_HITS
	for i in mini(stuns.size(), Tuning.R7_COMBO_ESCAPE_HITS - 1):
		ok = ok and absf(float(stuns[i]) - base * CombatController.r7_stun_decay(i + 1)) < 0.002
	check(ok, "hits 1-%d at the decayed stun" % (Tuning.R7_COMBO_ESCAPE_HITS - 1))
	check(esc[0] and stuns.size() == Tuning.R7_COMBO_ESCAPE_HITS and float(stuns[-1]) == 0.0,
		"hit %d breaks the victim away with no stun" % Tuning.R7_COMBO_ESCAPE_HITS)
	var last: HitInfo = hits_on(g)[-1] if not hits_on(g).is_empty() else null
	check(last != null and last.has_meta(&"escaped") and last.damage > 0.0, "the break-away hit still deals damage")
	check(g.combat.hits_taken() == 0, "the victim count resets")
	await wait_until(func() -> bool: return not p.combat.is_attacking(), 2.0)
	place_in_front(p, g, 1.0)
	p.combat.play_move(&"jab", g)
	await wait_until(func() -> bool: return g.combat.last_result == HitInfo.Result.BLOCKED, 0.8)
	check(g.combat.last_result == HitInfo.Result.BLOCKED, "auto-guard: the next frontal jab is blocked")
	await wait_real(1.5)

	print("the victim count is shared by two attackers (damage scaling per victim)")
	var a1 := spawn_fake(&"player", Vector3(10, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var a2 := spawn_fake(&"player", Vector3(10.9, 0, -0.9), Vector3.LEFT, Fighter.TEAM_PLAYER)
	var g2 := spawn(&"grunt", Vector3(10, 0, -1.0), Vector3.BACK)
	await ticks(12)
	clear_events()
	for att: Fighter in [a1, a2, a1]:
		var n0 := hits_on(g2).size()
		await wait_until(func() -> bool: return not att.combat.is_attacking(), 1.5)
		att.combat.play_move(&"jab", g2)
		await wait_until(func() -> bool: return hits_on(g2).size() > n0, 1.0)
		await wait_real(0.1)
	var hs := hits_on(g2)
	check(hs.size() == 3 and g2.combat.hits_taken() == 3, "3 hits from two attackers: victim count %d" % g2.combat.hits_taken())
	if hs.size() == 3:
		check(is_equal_approx(hs[2].damage_scale, CombatController.combo_scale(3))
			and is_equal_approx(hs[2].damage, float(Tuning.R8_MOVES[&"jab"]["tap"]["dmg"]) * CombatController.combo_scale(3)),
			"the 3rd hit (first attacker again) is scaled as hit 3: x%.1f" % hs[2].damage_scale)
		check(hs[2].chain_index == 2 and hs[1].chain_index == 1, "the chain (HUD counter) stays per attacker")

	print("enemy hits on the player keep the Round 5 decay")
	var r5: Array = []
	for n in range(1, 8):
		r5.append(snappedf(CombatController.stun_decay(n), 0.001))
	check(is_equal_approx(CombatController.stun_decay(Tuning.COMBO_STUN_DECAY_FROM - 1), 1.0)
		and CombatController.stun_decay(Tuning.COMBO_STUN_DECAY_FROM) < 1.0, "Round 5 decay %s" % [r5])
	Tuning.debug_pressure_mult = was_pm
	done()
