extends "res://tests/combat/combat_test_base.gd"
## Round 5 jab: a standing jab is P 1.0, a flinch, Tuning.STRIKE_DAMAGE jab
## damage, dealt exactly once per attack (hit registry). Light, Light, Light
## is jab, jab (other hand), elbow: the elbow is the third hit of a tap string
## (+1 finisher: P 2.5, a stagger), the hits before it get no bonus. A jab into
## the air whiffs.

func run() -> void:
	var p := spawn(&"player", Vector3.ZERO, Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var g := spawn(&"grunt", Vector3(0, 0, -1.0), Vector3.BACK)
	await ticks(20)
	print("jab: single hit")
	var hp0 := g.hp
	tap(p, CombatController.Action.LIGHT)
	await wait_real(0.5)
	var want1 := Power.strike_damage(&"jab", 0)
	check(is_equal_approx(hp0 - g.hp, want1), "jab dealt %.1f (want %.1f)" % [hp0 - g.hp, want1])
	check(count_events(&"hit_landed") == 1, "one hit_landed for one jab (got %d)" % count_events(&"hit_landed"))
	var info: HitInfo = last_event(&"hit_landed")[1] if count_events(&"hit_landed") > 0 else null
	if info != null:
		print("  jab P %.2f tier %s" % [info.power, HitInfo.tier_name(info.tier)])
		check(is_equal_approx(info.power, 1.0) and info.tier == HitInfo.Tier.FLINCH, "standing jab: P 1.0, flinch")
	check(not p.combat.is_attacking(), "jab finished")

	print("jab: Light, Light, Light (jab, jab, elbow)")
	await wait_real(Tuning.COMBO_DROP + 0.3)
	clear_events()
	var started: Array[StringName] = []
	p.combat.attack_started.connect(func(id: StringName) -> void: started.append(id))
	hp0 = g.hp
	for i in 3:
		tap(p, CombatController.Action.LIGHT)
		await wait_real(0.1)
	await wait_real(0.8)
	print("  started: ", started)
	check(started == ([&"jab1", &"jab2", &"elbow"] as Array[StringName]), "string jab1 -> jab2 -> elbow")
	var hits: Array[HitInfo] = []
	for e in events:
		if e[0] == &"hit_landed":
			hits.append(e[1])
	check(hits.size() == 3, "three hits landed (got %d)" % hits.size())
	if hits.size() == 3:
		for h in hits:
			print("  %s P %.2f (finisher %.1f) tier %s dmg %.2f" % [h.move_id, h.power, h.finisher_bonus,
				HitInfo.tier_name(h.tier), h.damage])
		check(is_equal_approx(hits[0].power, 1.0) and is_equal_approx(hits[1].power, 1.0), "jab, jab: P 1.0 each, no bonus")
		check(is_equal_approx(hits[2].finisher_bonus, Tuning.FINISHER_BONUS), "the third tap hit gets the finisher bonus")
		check(is_equal_approx(hits[2].power, 2.5) and hits[2].tier == HitInfo.Tier.STAGGER, "elbow finisher: P 2.5, stagger")
	var want := Power.strike_damage(&"jab", 0) * 2.0 + Power.strike_damage(&"elbow", 0) * CombatController.combo_scale(3)
	check(is_equal_approx(hp0 - g.hp, want), "string dealt %.2f (want %.2f, 3rd hit scaled)" % [hp0 - g.hp, want])

	print("jab: whiff")
	clear_events()
	var far := spawn(&"player", Vector3(10, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	await ticks(5)
	far.combat.press(CombatController.Action.LIGHT)
	await wait_real(0.4)
	check(count_events(&"attack_whiff") == 1, "jab into air emits attack_whiff")
	done()
