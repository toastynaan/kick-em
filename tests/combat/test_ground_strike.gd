extends "res://tests/combat/combat_test_base.gd"
## Round 5 ground strikes (Feel Reference: Hitting bodies that are down):
## attacking near a body on the ground is a stomp (Kick) or a knee drop
## (Light / Heavy): a small push into the nearest bone, ground-class damage
## (Tuning.STRIKE_DAMAGE ground x charge), hit_landed with ground_strike = true,
## never a launch; the first one of a knockdown keeps the body down a little
## longer; it finishes an enemy that is fleeing (lost a limb), including one
## crawling away on its own animation (Targeting.is_crawling) through the real
## input path. A standing enemy closer than the body is struck instead; a flying
## body is never stomped. An enemy's swing at a knocked-down player locks onto
## the body (the token holder's free swing) and lands as damage and a nudge.

const A := CombatController.Action
var _x := 0.0

func _init() -> void:
	_timeout = 90.0

func _landed_on(f: Fighter) -> HitInfo:
	for e: Array in events:
		if e[0] == &"hit_landed" and (e[1] as HitInfo).victim == f:
			return e[1]
	return null

## A player next to a grunt knocked flat (Fighter.knockdown), the body 1.0 m ahead.
func _downed() -> Array:
	_x += 12.0
	var p := spawn(&"player", Vector3(_x, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var g := spawn(&"grunt", Vector3(_x, 0, -1.2), Vector3.BACK)
	await ticks(20)
	g.knockdown(Vector3.FORWARD, &"Chest")
	g.ragdoll.set_getup_after(3.0)
	await wait_until(func() -> bool: return g.get_state() == RagdollController.State.GROUNDED, 4.0)
	var to := g.get_center_of_mass() - p.global_position
	to.y = 0.0
	p.teleport_to(g.get_center_of_mass() - to.normalized() * 1.0, to)
	await ticks(3)
	return [p, g]

func run() -> void:
	for row: Array in [[A.KICK, &"ground_stomp"], [A.LIGHT, &"knee_drop"], [A.HEAVY, &"knee_drop"]]:
		print("%s next to a downed grunt" % A.keys()[row[0]])
		var pg: Array = await _downed()
		var p: Fighter = pg[0]
		var g: Fighter = pg[1]
		var started: Array = []
		p.combat.attack_started.connect(func(id: StringName) -> void: started.append(id))
		clear_events()
		var hp0 := g.hp
		var delay0: float = g.ragdoll.get_getup_delay_left() if g.ragdoll.has_method(&"get_getup_delay_left") else 0.0
		tap(p, row[0])
		await wait_until(func() -> bool: return _landed_on(g) != null, 1.5)
		var info := _landed_on(g)
		check(not started.is_empty() and started[0] == row[1], "%s (%s)" % [row[1], started])
		check(info != null and info.ground_strike, "hit_landed with ground_strike")
		if info == null:
			continue
		print("  P %.2f tier %s damage %.1f bone %s" % [info.power, HitInfo.tier_name(info.tier), info.damage, info.hit_bone])
		check(info.tier == HitInfo.Tier.FLINCH and info.launch_velocity == Vector3.ZERO and info.has_meta(&"nudge"),
			"a small push into the body, never a launch")
		check(is_equal_approx(hp0 - g.hp, Power.strike_damage(&"ground", 0)), "ground damage %.0f" % (hp0 - g.hp))
		await ticks(10)
		check(g.get_state() == RagdollController.State.GROUNDED, "the body stays on the ground")
		check(g.get_com_velocity().length() < 3.0, "it is not thrown around (%.2f m/s)" % g.get_com_velocity().length())
		check(g.combat.getup_extended, "the first ground strike of a knockdown keeps it down")
		await wait_real(0.6)

	print("a charged stomp: more damage, still no launch")
	var pc: Array = await _downed()
	var pp: Fighter = pc[0]
	var gg: Fighter = pc[1]
	pp.combat.force_hold_charge = true
	clear_events()
	await hold_press(pp, A.KICK, Tuning.CHARGE_LEVELS[2] + 0.05)
	await wait_until(func() -> bool: return _landed_on(gg) != null, 1.5)
	var ci := _landed_on(gg)
	check(ci != null and is_equal_approx(ci.damage, Power.strike_damage(&"ground", 3) * CombatController.combo_scale(ci.combo_index)) \
		and ci.tier == HitInfo.Tier.FLINCH, "level-3 stomp: %.1f damage, no launch" % (ci.damage if ci else -1.0))

	print("a ground strike finishes a fleeing enemy")
	var pf: Array = await _downed()
	var p2: Fighter = pf[0]
	var g2: Fighter = pf[1]
	var flee := Node.new()
	var scr := GDScript.new()
	scr.source_code = "extends Node\nfunc is_fleeing() -> bool:\n\treturn true\n"
	scr.reload()
	flee.set_script(scr)
	g2.add_child(flee)
	g2.brain = flee
	g2.hp = 60.0
	check(g2.is_fleeing(), "the grunt is fleeing")
	clear_events()
	tap(p2, A.KICK)
	await wait_until(func() -> bool: return g2.is_dead(), 1.5)
	check(g2.is_dead(), "finished (60 HP left before the stomp)")

	print("a crawling enemy (lost a leg, still animated) is finished by a ground strike")
	_x += 12.0
	var pk := spawn(&"player", Vector3(_x, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var gk := spawn(&"grunt", Vector3(_x, 0, -1.1), Vector3.BACK)
	await ticks(15)
	var crawl := Node.new()
	var cs := GDScript.new()
	cs.source_code = "extends Node\nfunc is_fleeing() -> bool:\n\treturn true\nfunc is_crawling() -> bool:\n\treturn true\n"
	cs.reload()
	crawl.set_script(cs)
	gk.add_child(crawl)
	gk.brain = crawl
	gk.hp = 55.0
	check(Targeting.is_crawling(gk) and not gk.is_down(), "an animated crawler (COM %.2f m up)" % (gk.get_center_of_mass().y - gk.get_ground_position().y))
	var stk: Array = []
	pk.combat.attack_started.connect(func(id: StringName) -> void: stk.append(id))
	clear_events()
	tap(pk, A.LIGHT)
	await wait_until(func() -> bool: return gk.is_dead(), 1.5)
	check(stk == [&"knee_drop"], "Light next to the crawler is a knee drop (%s)" % [stk])
	var ki := _landed_on(gk)
	check(ki != null and ki.ground_strike and gk.is_dead(), "the ground strike finishes him (55 HP left before it)")

	print("a fleeing limper (lost an arm, standing) is finished by any strike")
	_x += 12.0
	var pl2 := spawn(&"player", Vector3(_x, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var gl := spawn(&"grunt", Vector3(_x, 0, -1.1), Vector3.BACK)
	await ticks(15)
	var limp := Node.new()
	var ls := GDScript.new()
	ls.source_code = "extends Node\nfunc is_fleeing() -> bool:\n\treturn true\nfunc is_crawling() -> bool:\n\treturn false\n"
	ls.reload()
	limp.set_script(ls)
	gl.add_child(limp)
	gl.brain = limp
	gl.hp = 40.0
	var stl: Array = []
	pl2.combat.attack_started.connect(func(id: StringName) -> void: stl.append(id))
	tap(pl2, A.LIGHT)
	await wait_until(func() -> bool: return gl.is_dead(), 1.5)
	check(stl == [&"jab1"] and gl.is_dead(), "a jab on the limper finishes him (40 HP left before it; %s)" % [stl])

	print("an enemy's free swing at the knocked-down player lands")
	_x += 12.0
	var pd := spawn(&"player", Vector3(_x, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var ed := spawn(&"grunt", Vector3(_x, 0, -1.4), Vector3.BACK)
	await ticks(15)
	AttackDirector.set_player(pd)
	pd.knockdown(Vector3.FORWARD, &"Chest")
	# The token holder swings at once (the player gets up after PLAYER_GETUP_AFTER).
	await wait_real(0.12)
	var pdc := pd.get_center_of_mass()
	ed.global_position = Vector3(pdc.x, 0.0, pdc.z) + Vector3(0, 0, -1.0)
	ed.snap_facing(Vector3.BACK)
	ed.reset_physics_interpolation()
	await ticks(3)
	check(AttackDirector.is_player_knocked_down(), "AttackDirector: the player is knocked down")
	clear_events()
	var hpd := pd.hp
	check(ed.combat.start_enemy_attack(&"e_jab", 0.3), "the token holder swings")
	check(ed.combat.get_attack_target() == pd, "the swing locks onto the downed player")
	await wait_until(func() -> bool: return _landed_on(pd) != null, 1.5)
	var fi := _landed_on(pd)
	print("  free swing: result %d, player state %d, invulnerable %s, whiffs %d, active %d" % [pd.combat.last_result,
		pd.get_state(), pd.is_invulnerable(), count_events(&"attack_whiff"), count_events(&"attack_active")])
	check(fi != null and pd.hp < hpd, "the free swing lands (%.1f damage)" % (hpd - pd.hp))
	check(fi != null and fi.tier == HitInfo.Tier.FLINCH and fi.has_meta(&"nudge"), "damage and a nudge, not a second knockdown")

	print("a standing enemy closer than the body is struck instead")
	var ps: Array = await _downed()
	var p3: Fighter = ps[0]
	var g3: Fighter = ps[1]
	var stand := spawn(&"grunt", p3.global_position + p3.get_forward() * 0.9, -p3.get_forward())
	await ticks(10)
	var st3: Array = []
	p3.combat.attack_started.connect(func(id: StringName) -> void: st3.append(id))
	tap(p3, A.LIGHT)
	await ticks(2)
	check(st3 == [&"jab1"] and p3.combat.get_attack_target() == stand, "a jab at the standing enemy (%s)" % [st3])
	await wait_real(0.6)

	print("a flying body is struck, never stomped")
	_x += 12.0
	var p4 := spawn(&"player", Vector3(_x, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var g4 := spawn(&"grunt", Vector3(_x, 0, -1.0), Vector3.BACK)
	await ticks(20)
	g4.launch(Vector3(0, 5.0, 0), g4.get_center_of_mass(), &"Chest")
	await wait_real(0.15)
	var st4: Array = []
	p4.combat.attack_started.connect(func(id: StringName) -> void: st4.append(id))
	tap(p4, A.KICK)
	await ticks(2)
	check(st4 == [&"sparta_kick"], "a kick, not a stomp, at a body in the air (%s)" % [st4])
	done()
