extends "res://tests/input/input_test_base.gd"
## Fighter.sever_limb (Round 5, agent H; A cuts the rig, B calls it on a
## severing launch and adds Tuning.LIMB_LOST_DAMAGE): a whole arm or leg comes
## off an enemy, GameEvents.limb_severed carries the loose limb, the lost
## bones' hurtboxes switch off; at most MAX_SEVERS per
## body; the player never loses a limb; nothing comes off with gore below
## DISMEMBER; a corpse is no longer dismembered by impact energy.

func run() -> void:
	var p := spawn_player(Vector3.ZERO)
	var g := spawn_dummy(&"grunt", Vector3(0, 0, -2.0), Vector3.BACK)
	await ticks(30)
	clear_events()
	var got := []
	GameEvents.limb_severed.connect(func(f: Node3D, cut: StringName, piece: Node3D) -> void: got.append([f, cut, piece]))

	check(not p.sever_limb(&"arm_l") and p.get_lost_limbs().is_empty(), "the player never loses a limb")
	var old_gore := Tuning.gore
	Tuning.gore = Tuning.Gore.BLOOD
	check(not g.sever_limb(&"arm_l"), "gore BLOOD: nothing comes off")
	Tuning.gore = old_gore

	check(g.sever_limb(&"arm_r"), "an enemy's right arm comes off")
	check(got.size() == 1 and got[0][0] == g and got[0][1] == &"arm_r", "limb_severed(grunt, arm_r)")
	check(got.size() == 1 and got[0][2] is RigidBody3D, "with the loose limb")
	var lost := g.get_lost_limbs()
	check(g.has_lost_arm() and not g.has_lost_leg() and lost.size() == 1 and lost[0] == &"arm_r", "lost: %s" % [lost])
	var arm_boxes_on := 0
	for hb in g.hurtboxes:
		if is_instance_valid(hb) and (hb.bone == Bones.R_UPPER_ARM or hb.bone == Bones.R_LOWER_ARM):
			if hb.monitorable:
				arm_boxes_on += 1
	check(arm_boxes_on == 0, "the lost arm's hurtboxes are off")
	check(not g.sever_limb(&"arm_r") and not g.sever_limb(&"forearm_r"), "the same limb never comes off twice")
	check(g.sever_limb(&"leg_l"), "a leg comes off")
	check(g.has_lost_leg() and got.size() == 2, "lost a leg")
	check(not g.sever_limb(&"arm_l"), "at most %d limbs per body" % Fighter.MAX_SEVERS)
	check(not g.is_dead(), "losing limbs does not kill by itself (B adds the damage)")

	# A corpse is no longer dismembered by impact energy (Round 5: severing comes from P only).
	var g2 := spawn_dummy(&"grunt", Vector3(4, 0, -2.0), Vector3.BACK)
	await ticks(20)
	got.clear()
	var big := HitInfo.new()
	big.energy = 9000.0
	big.is_finisher = true
	big.hit_position = g2.get_center_of_mass()
	g2.apply_damage(500.0, &"impact", big)
	g2.apply_damage(200.0, &"impact", big)
	await ticks(2)
	check(g2.is_dead() and got.is_empty(), "a big impact kill takes no limb")
	done()
