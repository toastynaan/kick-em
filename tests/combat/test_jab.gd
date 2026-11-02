extends "res://tests/combat/combat_test_base.gd"
## Jab deals Tuning.DMG_JAB exactly once per attack (hit registry); Light
## pressed during a jab chains jab1 -> jab2 -> jab3.

func run() -> void:
	var p := spawn(&"player", Vector3.ZERO, Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var g := spawn(&"grunt", Vector3(0, 0, -1.0), Vector3.BACK)
	await ticks(20)
	print("jab: single hit")
	var hp0 := g.hp
	p.combat.press(CombatController.Action.LIGHT)
	p.combat.release(CombatController.Action.LIGHT)
	await wait_real(0.5)
	check(is_equal_approx(hp0 - g.hp, Tuning.DMG_JAB), "jab dealt %.1f (want %.1f)" % [hp0 - g.hp, Tuning.DMG_JAB])
	check(count_events(&"hit_landed") == 1, "one hit_landed for one jab (got %d)" % count_events(&"hit_landed"))
	check(not p.combat.is_attacking(), "jab finished")

	print("jab: P, P, P string (jab, cross, hook)")
	await wait_real(Tuning.COMBO_DROP + 0.2)
	clear_events()
	var started: Array[StringName] = []
	p.combat.attack_started.connect(func(id: StringName) -> void: started.append(id))
	hp0 = g.hp
	for i in 3:
		p.combat.press(CombatController.Action.LIGHT)
		p.combat.release(CombatController.Action.LIGHT)
		await wait_real(0.1)
	await wait_real(0.6)
	print("  started: ", started)
	check(started == ([&"jab1", &"cross", &"hook"] as Array[StringName]), "string jab1 -> cross -> hook")
	check(count_events(&"hit_landed") == 3, "three hits landed (got %d)" % count_events(&"hit_landed"))
	var want := Tuning.DMG_JAB + MoveLibrary.DMG[&"cross"] + MoveLibrary.DMG[&"hook"] * CombatController.combo_scale(3)
	check(is_equal_approx(hp0 - g.hp, want), "string dealt %.1f (want %.1f, 3rd hit scaled)" % [hp0 - g.hp, want])

	print("jab: whiff")
	clear_events()
	var far := spawn(&"player", Vector3(10, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	await ticks(5)
	far.combat.press(CombatController.Action.LIGHT)
	await wait_real(0.4)
	check(count_events(&"attack_whiff") == 1, "jab into air emits attack_whiff")
	done()
