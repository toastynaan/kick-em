extends "res://tests/combat/combat_test_base.gd"
## Round 5 reactions by tier (Feel Reference: Partial ragdoll reactions):
## flinch (the hit chain only, act again after Tuning.REACT_FLINCH.act),
## stumble (Tuning.REACT_STUMBLE.act), stagger (upper body, legs animated, never
## tips into a launch, act after Tuning.REACT_STAGGER.act), knockdown (ground
## time in Tuning.REACT_KNOCKDOWN.ground, the player Tuning.PLAYER_GETUP_AFTER),
## launch (ground time in Tuning.REACT_LAUNCH.ground). The hit chain comes from
## the hurtbox / aimed bone; the push follows the strike direction (a hook turns
## the head across, a roundhouse sends the body to the attacker's left).

const TraversalDouble := preload("res://tests/combat/traversal_double.gd")
const DefenceDouble := preload("res://tests/combat/defence_double.gd")
const A := CombatController.Action
const T := HitInfo.Tier
const RS := RagdollController.State
var _x := 0.0

func _init() -> void:
	_timeout = 120.0

func _pair(dist := 1.1, speed := 0.0, counter := 0.0) -> Array:
	_x += 14.0
	var p := spawn_fake(&"player", Vector3(_x, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER, true)
	var g := spawn(&"grunt", Vector3(_x, 0, -dist), Vector3.BACK)
	var tv: Traversal = TraversalDouble.new()
	p.add_child(tv)
	tv.setup(p)
	p.traversal.queue_free()
	p.traversal = tv
	tv.set(&"speed", speed)
	tv.set(&"sprinting", speed > 6.0)
	var dd: Defence = DefenceDouble.new()
	p.add_child(dd)
	dd.setup(p)
	p.defence.queue_free()
	p.defence = dd
	dd.set(&"bonus", counter)
	await ticks(15)
	return [p, g]

func _landed_on(f: Fighter) -> HitInfo:
	for e: Array in events:
		if e[0] == &"hit_landed" and (e[1] as HitInfo).victim == f:
			return e[1]
	return null

## Real s from the hit until the victim can act again (standing).
func _act_again(g: Fighter, limit := 3.0) -> float:
	var t0 := TimeDirector.now()
	await wait_until(func() -> bool: return g.can_act(), limit)
	return TimeDirector.now() - t0

func _strike(p: Fighter, g: Fighter, action: int, intent := &"neutral") -> HitInfo:
	clear_events()
	p.fake_intent = intent
	tap(p, action)
	p.fake_intent = &"neutral"
	await wait_until(func() -> bool: return _landed_on(g) != null, 1.5)
	return _landed_on(g)

func run() -> void:
	print("flinch: the hit chain only")
	var r: Array = await _pair()
	var p: Fighter = r[0]
	var g: Fighter = r[1]
	p.aim_target = g
	p.aim_zone = BodyZones.Zone.HEAD
	p.aim_bone = &"Head"
	var info := await _strike(p, g, A.LIGHT)
	check(info != null and info.tier == T.FLINCH and info.hit_bone == &"Head", "a head jab: flinch on the Head chain")
	await ticks(1)
	check(g.get_state() == RS.FLINCH, "victim in FLINCH")
	if g.ragdoll.has_method(&"get_bone_strength"):
		var head := g.ragdoll.get_bone_strength(&"Head")
		var leg := g.ragdoll.get_bone_strength(&"LeftUpperLeg")
		print("  muscle strength after the head jab: Head %.2f, LeftUpperLeg %.2f" % [head, leg])
		check(head < 0.99 and leg > 0.99, "only the head chain goes physical")
	var act := await _act_again(g)
	var want: float = Tuning.REACT_FLINCH["act"] + Power.hitstop_for(T.FLINCH)
	print("  flinch: acts again after %.3f s (want %.3f incl. hitstop)" % [act, want])
	check(absf(act - want) < 0.05, "flinch act-again time")
	p.aim_target = null

	print("stumble: a tapped sweep")
	r = await _pair()
	p = r[0]
	g = r[1]
	info = await _strike(p, g, A.KICK, &"back")
	check(info != null and info.tier == T.STUMBLE, "tapped sweep: stumble")
	check(g.combat.is_stumbling() and not g.is_down(), "stumbling on its feet")
	act = await _act_again(g)
	want = Tuning.REACT_STUMBLE["act"] + Power.hitstop_for(T.STUMBLE)
	print("  stumble: acts again after %.3f s (want %.3f)" % [act, want])
	check(absf(act - want) < 0.06, "stumble act-again time")

	print("stagger: the upper body, legs animated, never a launch")
	r = await _pair()
	p = r[0]
	g = r[1]
	info = await _strike(p, g, A.HEAVY)
	check(info != null and info.tier == T.STAGGER, "standing cross: stagger")
	await ticks(2)
	check(g.get_state() == RS.STAGGER, "victim in STAGGER")
	var downed := false
	var t0 := TimeDirector.now()
	var ga := g.get_ground_position()
	while TimeDirector.now() - t0 < 1.4:
		await get_tree().physics_frame
		downed = downed or g.is_down()
	var push := g.get_ground_position().distance_to(ga)
	print("  stagger: pushed %.2f m (doc 0.6-1.0), went down: %s" % [push, downed])
	check(not downed, "a stagger never turns into a launch by itself")
	check(push >= 0.4 and push <= 1.3, "pushed back about 0.6-1.0 m (%.2f)" % push)
	r = await _pair()
	p = r[0]
	g = r[1]
	await _strike(p, g, A.HEAVY)
	act = await _act_again(g)
	want = Tuning.REACT_STAGGER["act"] + Power.hitstop_for(T.STAGGER)
	print("  stagger: acts again after %.3f s (want %.3f)" % [act, want])
	check(absf(act - want) < 0.1, "stagger act-again time")

	print("knockdown: a jab after a parry")
	r = await _pair(1.1, 0.0, Tuning.COUNTER_BONUS_PARRY)
	p = r[0]
	g = r[1]
	info = await _strike(p, g, A.LIGHT)
	check(info != null and info.tier == T.KNOCKDOWN, "P 3.5: knockdown")
	await ticks(3)
	check(g.is_down(), "the grunt goes down")
	var ground: Vector2 = Tuning.REACT_KNOCKDOWN["ground"]
	if g.ragdoll.has_method(&"get_getup_after"):
		var gt: float = g.ragdoll.get_getup_after()
		print("  knockdown ground time %.2f s (range %.1f-%.1f)" % [gt, ground.x, ground.y])
		check(gt >= ground.x - 1e-3 and gt <= ground.y + 1e-3, "ground time in Tuning.REACT_KNOCKDOWN")
	check(await wait_until(func() -> bool: return g.get_state() == RS.ANIMATED, 6.0), "it gets up")

	print("launch: a sprint cross")
	r = await _pair(2.6, 8.0)
	p = r[0]
	g = r[1]
	info = await _strike(p, g, A.HEAVY)
	check(info != null and info.tier == T.LAUNCH, "P 5: launch")
	await ticks(3)
	if g.ragdoll.has_method(&"get_getup_after"):
		var lt: float = g.ragdoll.get_getup_after()
		var lr: Vector2 = Tuning.REACT_LAUNCH["ground"]
		print("  launch ground time %.2f s (range %.1f-%.1f)" % [lt, lr.x, lr.y])
		check(lt >= lr.x - 1e-3 and lt <= lr.y + 1e-3, "ground time in Tuning.REACT_LAUNCH")

	print("the player knocked down gets up after PLAYER_GETUP_AFTER")
	_x += 14.0
	var pp := spawn(&"player", Vector3(_x, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var hv := spawn(&"heavy", Vector3(_x, 0, -1.4), Vector3.BACK)
	await ticks(15)
	clear_events()
	hv.combat.start_enemy_attack(&"e_charge", 0.3)
	await wait_until(func() -> bool: return pp.is_down(), 2.5)
	await ticks(2)
	if pp.ragdoll.has_method(&"get_getup_after"):
		check(is_equal_approx(pp.ragdoll.get_getup_after(), Tuning.PLAYER_GETUP_AFTER),
			"the player's ground time %.2f s" % pp.ragdoll.get_getup_after())

	print("the push follows the strike direction")
	r = await _pair()
	p = r[0]
	g = r[1]
	var right := p.get_forward().cross(Vector3.UP).normalized()
	await _strike(p, g, A.HEAVY)  # cross (2nd Heavy is the hook)
	await wait_real(0.15)
	info = await _strike(p, g, A.HEAVY)
	if info != null:
		var sd: Vector3 = info.get_meta(&"strike_dir", Vector3.ZERO)
		print("  hook strike direction %s (attacker right %s)" % [sd.snapped(Vector3.ONE * 0.01), right.snapped(Vector3.ONE * 0.01)])
		check(info.move_id == &"hook" and sd.dot(right) > 0.5, "a hook pushes the head across, to the attacker's right")
	r = await _pair(2.6, 12.0)  # a roundhouse at full speed launches
	p = r[0]
	g = r[1]
	right = p.get_forward().cross(Vector3.UP).normalized()
	p.combat._string_pos = 2  # third hit: Kick is the roundhouse
	p.combat._string_tap = true
	p.combat._last_move_id = &"knee_strike"
	p.combat._last_move_end = TimeDirector.now()
	info = await _strike(p, g, A.KICK)
	if info != null:
		var lv := Vector3(info.launch_velocity.x, 0.0, info.launch_velocity.z).normalized()
		print("  roundhouse: P %.2f launch direction %s" % [info.power, lv.snapped(Vector3.ONE * 0.01)])
		check(info.move_id == &"roundhouse" and HitInfo.is_launch_tier(info.tier) and lv.dot(-right) > 0.5,
			"a roundhouse launch goes to the attacker's left")
	done()
