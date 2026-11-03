extends "res://tests/combat/combat_test_base.gd"
## Killing blows (Round 7: docs/Round 7 — Freeflow Combat.md: Payoffs, Hit feel,
## Freeflow targeting):
## - a jab that takes the last HP kills: died, GameEvents.fighter_died, ragdoll
##   DEAD, no limb comes off, the corpse is no longer a freeflow target;
## - a killing LAUNCH severs a limb with chance R7_SEVER_ON_KILL (the existing
##   severing code: the hit limb, or the arm nearest the hit), tier sever; a
##   launch that does not kill takes no limb; with gore below DISMEMBER, or at
##   Fighter.MAX_SEVERS lost limbs, no limb comes off;
## - any hit on a fleeing or crawling enemy kills it;
## - enemy hits never take the player's limbs.

var _x := 0.0

func _init() -> void:
	_timeout = 90.0

## A heavy hook on a folded grunt is the launch payoff (9 m/s). chance: the
## attacker's sever_on_kill_chance. pre_cut: limbs the grunt has already lost.
func _launch_kill(grunt_hp: float, chance: float, pre_cut: Array = []) -> Array:
	_x += 14.0
	var p := spawn_fake(&"player", Vector3(_x, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	p.combat.sever_on_kill_chance = chance
	var g := spawn_fake(&"grunt", Vector3(_x, 0, -1.1), Vector3.BACK)
	await ticks(15)
	for c: StringName in pre_cut:
		g.sever_limb(c)
	await ticks(5)
	g.hp = grunt_hp
	g.set(&"fake_react", &"fold")
	clear_events()
	p.combat.play_move(&"heavy_hook", g)
	await wait_until(func() -> bool: return not hits_on(g).is_empty(), 1.5)
	return [p, g, hits_on(g)[0] if not hits_on(g).is_empty() else null]

func run() -> void:
	var p := spawn_fake(&"player", Vector3.ZERO, Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var g := spawn(&"grunt", Vector3(0, 0, -1.0), Vector3.BACK)
	await ticks(20)
	print("kill: a jab finishes a 3 HP grunt")
	var died_fired := [false]
	g.died.connect(func(_f: Fighter) -> void: died_fired[0] = true)
	g.hp = 3.0
	tap(p, A.LIGHT)
	await wait_real(0.5)
	check(g.is_dead() and g.hp == 0.0, "grunt HP 0")
	check(died_fired[0], "died signal")
	check(count_events(&"fighter_died") == 1 and last_event(&"fighter_died")[1] == g, "GameEvents.fighter_died")
	check(count_events(&"limb_severed") == 0, "a jab kill does not dismember")
	if rig_is_real(g):
		check(g.get_state() == RagdollController.State.DEAD, "ragdoll DEAD (state %d)" % g.get_state())
	check(not Targeting.is_freeflow_target(p, g), "the corpse is not a freeflow target")

	print("a killing launch severs a limb (sever_on_kill_chance 1)")
	var r: Array = await _launch_kill(5.0, 1.0)
	var info: HitInfo = r[2]
	var gs: Fighter = r[1]
	if info != null:
		var ls := last_event(&"limb_severed")
		print("  react %s tier %s cut %s (hit bone %s) damage %.1f, dead %s" % [info.react, HitInfo.tier_name(info.tier),
			info.sever_cut, info.hit_bone, info.damage, gs.is_dead()])
		check(info.react == &"launch" and info.tier == HitInfo.Tier.SEVER and info.sever_cut != &"" and info.is_finisher,
			"a killing launch: tier sever, a cut")
		var want_cut := Bones.limb_cut_for(info.hit_bone)
		if want_cut != &"":
			check(info.sever_cut == want_cut, "the hit limb comes off (%s)" % want_cut)
		else:
			check(info.sever_cut in [&"arm_l", &"arm_r"], "a head / torso hit takes the nearest arm (%s)" % info.sever_cut)
		check(count_events(&"limb_severed") == 1 and not ls.is_empty() and ls[2] == info.sever_cut, "limb_severed for that cut")
		check(gs.is_dead(), "and it kills")
	else:
		check(false, "the launch landed")

	print("the chance: sever_on_kill_chance 0, and Tuning.R7_SEVER_ON_KILL by default")
	r = await _launch_kill(5.0, 0.0)
	info = r[2]
	check(info != null and info.sever_cut == &"" and info.tier == HitInfo.Tier.LAUNCH and count_events(&"limb_severed") == 0,
		"chance 0: a killing launch keeps every limb")
	var fresh := CombatController.new()
	check(is_equal_approx(fresh.sever_on_kill_chance, Tuning.R7_SEVER_ON_KILL), "the default chance is R7_SEVER_ON_KILL (%.2f)" % Tuning.R7_SEVER_ON_KILL)
	fresh.free()

	print("a launch that does not kill takes no limb")
	r = await _launch_kill(100.0, 1.0)
	info = r[2]
	check(info != null and info.sever_cut == &"" and not (r[1] as Fighter).is_dead() and count_events(&"limb_severed") == 0,
		"a full grunt is launched whole")

	print("gore below DISMEMBER: no limb")
	var gore0 := Tuning.gore
	Tuning.gore = Tuning.Gore.BLOOD
	r = await _launch_kill(5.0, 1.0)
	Tuning.gore = gore0
	info = r[2]
	check(info != null and info.sever_cut == &"" and count_events(&"limb_severed") == 0, "gore off: no cut")

	print("no more than Fighter.MAX_SEVERS limbs")
	r = await _launch_kill(5.0, 1.0, [&"leg_l", &"leg_r"])
	info = r[2]
	var lost := (r[1] as Fighter).get_lost_limbs().size()
	check(info != null and lost >= Fighter.MAX_SEVERS and info.sever_cut == &"",
		"at %d lost limbs no more come off (%d)" % [Fighter.MAX_SEVERS, lost])

	print("any hit finishes a fleeing or crawling enemy")
	for how: String in ["fleeing", "crawling"]:
		_x += 14.0
		var pf := spawn_fake(&"player", Vector3(_x, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
		var gf := spawn(&"grunt", Vector3(_x, 0, -1.0), Vector3.BACK)
		var brain := Node.new()
		brain.set_script(_brain_script(how))
		gf.add_child(brain)
		gf.brain = brain
		await ticks(15)
		clear_events()
		pf.combat.play_move(&"jab", gf)
		await wait_until(func() -> bool: return not hits_on(gf).is_empty(), 1.0)
		var fi: HitInfo = hits_on(gf)[0] if not hits_on(gf).is_empty() else null
		check(fi != null and gf.is_dead(), "a jab kills a %s enemy (damage %.0f)" % [how, fi.damage if fi else 0.0])

	print("enemy hits never take the player's limbs")
	clear_events()
	var e := spawn(&"heavy", Vector3(-20, 0, -1.3), Vector3.BACK)
	var pp := spawn(&"player", Vector3(-20, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	e.snap_facing(pp.global_position - e.global_position)
	await ticks(15)
	e.combat.start_enemy_attack(&"e_charge", 0.3)
	await wait_until(func() -> bool: return not hits_on(pp).is_empty(), 2.0)
	var ei: HitInfo = hits_on(pp)[0] if not hits_on(pp).is_empty() else null
	check(ei != null and ei.tier <= HitInfo.Tier.KNOCKDOWN and ei.sever_cut == &"", "the heavy's charge: at most a knockdown, no cut")
	check(count_events(&"limb_severed") == 0, "the player stays whole")
	done()

## A brain that answers is_fleeing() or is_crawling() (C's).
func _brain_script(how: String) -> GDScript:
	var s := GDScript.new()
	s.source_code = "extends Node\nfunc is_fleeing() -> bool:\n\treturn %s\nfunc is_crawling() -> bool:\n\treturn %s\n" % [
		"true" if how == "fleeing" else "false", "true" if how == "crawling" else "false"]
	s.reload()
	return s
