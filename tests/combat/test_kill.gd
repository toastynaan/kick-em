extends "res://tests/combat/combat_test_base.gd"
## Killing blow: HP to 0 -> died, GameEvents.fighter_died, ragdoll DEAD.
## Dismemberment only on a killing blow at >= Tuning.SEVER_ENERGY or a finisher,
## including impact damage on a body already at 0 HP.

func run() -> void:
	var p := spawn(&"player", Vector3.ZERO, Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var g := spawn(&"grunt", Vector3(0, 0, -1.0), Vector3.BACK)
	await ticks(20)
	print("kill: jab finishes a 10 HP grunt")
	var died_fired := [false]
	g.died.connect(func(_f: Fighter) -> void: died_fired[0] = true)
	g.hp = 10.0
	p.combat.press(CombatController.Action.LIGHT)
	await wait_real(0.5)
	check(g.is_dead() and g.hp == 0.0, "grunt HP 0")
	check(died_fired[0], "died signal")
	check(count_events(&"fighter_died") == 1 and last_event(&"fighter_died")[1] == g, "GameEvents.fighter_died")
	check(count_events(&"limb_severed") == 0, "a jab kill does not dismember")
	if rig_is_real(g):
		check(g.get_state() == RagdollController.State.DEAD, "ragdoll DEAD (state %d)" % g.get_state())
	else:
		print("  SKIP ragdoll DEAD check (stub rig)")
	check(not g.combat.can_be_grabbed(), "corpse cannot be grabbed")
	check(Targeting.opponents_of(p).is_empty(), "corpse is not a target")

	print("kill: high-energy killing blow dismembers")
	clear_events()
	var g2 := spawn(&"grunt", Vector3(6, 0, -1.0), Vector3.BACK)
	await ticks(10)
	g2.hp = 5.0
	var info := HitInfo.new()
	info.attacker = p
	info.move_id = &"sparta_kick"
	info.kind = &"strike"
	info.damage = 60.0
	info.reaction = HitInfo.Reaction.LAUNCH
	info.launch_velocity = Vector3(0, 2, -13)
	info.hit_direction = Vector3.FORWARD
	info.hit_bone = &"Head"
	info.hit_position = g2.global_position + Vector3.UP * 1.65
	info.energy = 6000.0
	info.unblockable = true
	g2.take_hit(info)
	check(g2.is_dead(), "killed")
	if rig_is_real(g2):
		check(count_events(&"limb_severed") == 1, "limb severed")
		var ls := last_event(&"limb_severed")
		check(not ls.is_empty() and ls[2] == &"head", "nearest cut to a head hit is the head (%s)" % [ls[2] if not ls.is_empty() else "-"])
	else:
		print("  SKIP sever checks (stub rig)")

	print("kill: impact on a dead body")
	clear_events()
	var imp := HitInfo.new()
	imp.energy = 7000.0
	imp.kind = &"impact"
	imp.hit_position = g2.get_center_of_mass()
	g2.apply_damage(200.0, &"impact", imp)
	if rig_is_real(g2):
		check(count_events(&"limb_severed") == 1, "impact on a corpse can sever another limb")
	var low := HitInfo.new()
	low.energy = 1000.0
	clear_events()
	g2.apply_damage(30.0, &"impact", low)
	check(count_events(&"limb_severed") == 0, "low-energy impact never severs")

	print("kill: living player is never dismembered")
	clear_events()
	var big := HitInfo.new()
	big.energy = 9000.0
	big.is_finisher = true
	p.apply_damage(50.0, &"impact", big)
	check(not p.is_dead() and count_events(&"limb_severed") == 0, "player alive and whole")
	done()
