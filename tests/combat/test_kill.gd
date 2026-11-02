extends "res://tests/combat/combat_test_base.gd"
## Killing blow and severing launches (Feel Reference: How a limb comes off):
## - a jab that takes the last HP kills: died, GameEvents.fighter_died, ragdoll
##   DEAD, no limb comes off, the corpse is no longer a strike target;
## - a strike at P 9 or more is a severing launch: the hit limb (or the arm
##   nearest the hit for head and torso hits) comes off, Tuning.LIMB_LOST_DAMAGE
##   is added, the body still launches and a full grunt survives it;
## - with gore below DISMEMBER it is a hard launch instead (no limb, no limb damage);
## - a lethal severing launch takes the limb and kills;
## - enemy hits never take the player's limbs.

const TraversalDouble := preload("res://tests/combat/traversal_double.gd")
const A := CombatController.Action
var _x := 0.0

func _init() -> void:
	_timeout = 60.0

func _landed_on(g: Fighter) -> HitInfo:
	for e: Array in events:
		if e[0] == &"hit_landed" and (e[1] as HitInfo).victim == g:
			return e[1]
	return null

## A kick at charge level 3 with +1.0 speed bonus: P 9.0 (a severing launch).
## pre_cut: limbs the grunt has already lost.
func _sever_kick(grunt_hp: float, pre_cut: Array = []) -> Array:
	_x += 14.0
	var p := spawn(&"player", Vector3(_x, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var g := spawn(&"grunt", Vector3(_x, 0, -1.6), Vector3.BACK)
	var tv: Traversal = TraversalDouble.new()
	p.add_child(tv)
	tv.setup(p)
	p.traversal = tv
	tv.set(&"speed", Tuning.SPEED_BONUS_FROM + 1.0 / Tuning.SPEED_BONUS_K)
	await ticks(15)
	for c: StringName in pre_cut:
		g.sever_limb(c)
	await ticks(5)
	g.hp = grunt_hp
	clear_events()
	p.combat.force_hold_charge = true
	await hold_press(p, A.KICK, 1.1)
	await wait_until(func() -> bool: return _landed_on(g) != null, 1.5)
	return [p, g, _landed_on(g)]

func run() -> void:
	var p := spawn(&"player", Vector3.ZERO, Vector3.FORWARD, Fighter.TEAM_PLAYER)
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
	check(Targeting.pick_strike_target(p, p.get_forward(), false) == null, "the corpse is not a strike target")

	print("severing launch on a full grunt")
	var r: Array = await _sever_kick(100.0)
	var info: HitInfo = r[2]
	var gs: Fighter = r[1]
	check(info != null, "the severing kick landed")
	if info != null:
		var ls := last_event(&"limb_severed")
		print("  P %.2f tier %s cut %s (hit bone %s) damage %.1f hp %.1f" % [info.power, HitInfo.tier_name(info.tier),
			info.sever_cut, info.hit_bone, info.damage, gs.hp])
		check(info.tier == HitInfo.Tier.SEVER and info.sever_cut != &"", "P %.2f: a severing launch with a cut" % info.power)
		var want_cut := Bones.limb_cut_for(info.hit_bone)
		if want_cut != &"":
			check(info.sever_cut == want_cut, "the hit limb comes off (%s)" % want_cut)
		else:
			check(info.sever_cut in [&"arm_l", &"arm_r"], "a head / torso hit takes the nearest arm (%s)" % info.sever_cut)
		check(count_events(&"limb_severed") == 1 and not ls.is_empty() and ls[2] == info.sever_cut, "limb_severed for that cut")
		var want := Power.strike_damage(&"kick", 3) + Power.launch_damage(info.power, gs.max_hp) + Tuning.LIMB_LOST_DAMAGE
		check(is_equal_approx(info.damage, want), "damage %.1f = strike + launch + limb (%.1f)" % [info.damage, want])
		check(not gs.is_dead(), "a full grunt survives the severing launch (hp %.1f)" % gs.hp)
		await ticks(30)
		check(gs.is_launched() or gs.is_down(), "and still flies")

	print("gore below DISMEMBER: a hard launch instead")
	var gore0 := Tuning.gore
	Tuning.gore = Tuning.Gore.BLOOD
	r = await _sever_kick(100.0)
	Tuning.gore = gore0
	var hi: HitInfo = r[2]
	if hi != null:
		print("  P %.2f tier %s damage %.1f" % [hi.power, HitInfo.tier_name(hi.tier), hi.damage])
		check(hi.tier == HitInfo.Tier.HARD_LAUNCH and hi.sever_cut == &"", "gore off: hard launch, no cut")
		check(count_events(&"limb_severed") == 0, "no limb comes off")
		check(is_equal_approx(hi.damage, Power.strike_damage(&"kick", 3) + Power.launch_damage(hi.power, 100.0)),
			"no limb damage")
	else:
		check(false, "the gore-off kick landed")

	print("no more than Fighter.MAX_SEVERS limbs: past it a hard launch, no limb damage")
	var r2: Array = await _sever_kick(100.0, [&"leg_l", &"leg_r"])
	var ci: HitInfo = r2[2]
	var g3: Fighter = r2[1]
	var lost := g3.get_lost_limbs().size()
	check(ci != null, "the kick landed on the legless grunt")
	if ci != null:
		print("  %d limbs lost before: P %.2f tier %s cut '%s' damage %.1f" % [lost, ci.power, HitInfo.tier_name(ci.tier),
			ci.sever_cut, ci.damage])
		check(lost >= Fighter.MAX_SEVERS and ci.tier == HitInfo.Tier.HARD_LAUNCH and ci.sever_cut == &"",
			"at %d lost limbs a P 9 hit is a hard launch, no cut" % Fighter.MAX_SEVERS)
		check(is_equal_approx(ci.damage, Power.strike_damage(&"kick", 3) + Power.launch_damage(ci.power, g3.max_hp)), "no limb damage")

	print("a lethal severing launch takes the limb and kills")
	r = await _sever_kick(20.0)
	var li: HitInfo = r[2]
	var gl: Fighter = r[1]
	check(li != null and gl.is_dead(), "the severing launch kills a 20 HP grunt")
	check(count_events(&"limb_severed") == 1, "and its limb came off")

	print("enemy hits never take the player's limbs")
	clear_events()
	var e := spawn(&"heavy", Vector3(-20, 0, -1.3), Vector3.BACK)
	var pp := spawn(&"player", Vector3(-20, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	e.snap_facing(pp.global_position - e.global_position)
	await ticks(15)
	e.combat.start_enemy_attack(&"e_charge", 0.3)
	await wait_until(func() -> bool: return _landed_on(pp) != null, 2.0)
	var ei := _landed_on(pp)
	check(ei != null and ei.tier <= HitInfo.Tier.KNOCKDOWN and ei.sever_cut == &"", "the heavy's charge: at most a knockdown, no cut")
	check(count_events(&"limb_severed") == 0, "the player stays whole")
	done()
