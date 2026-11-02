extends "res://tests/combat/combat_test_base.gd"
## Round 5 offence and target picking (Feel Reference: Picking the target):
## - strike limbs follow PoseLibrary.STRIKE_BONES;
## - a press in blockstun comes out after it; a blocked hook is punished;
## - on a hit, Kick cancels the jab's recovery into the string's knee; no cancel on a whiff;
## - the target is the best-scored enemy in the 60-degree cone around the stick
##   (0.6 angle + 0.4 distance), not just the nearest; the striker turns to it
##   and lunges at most Tuning.LUNGE_MAX; with no target it strikes along the
##   stick; the lock-on target wins; the speed bonus is read toward the target.

const TraversalDouble := preload("res://tests/combat/traversal_double.gd")
const AimBrain := preload("res://tests/combat/aim_brain.gd")
const K := CombatController.Action.KICK
const L := CombatController.Action.LIGHT
const B := CombatController.Action.BLOCK
var _x := 0.0

func _init() -> void:
	_timeout = 90.0

func _pair(arch: StringName, dist: float) -> Array:
	_x += 12.0
	var p := spawn(&"player", Vector3(_x, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var e := spawn(arch, Vector3(_x, 0, -dist), Vector3.BACK)
	await ticks(15)
	return [p, e]

func _brain(p: Fighter) -> Node:
	var b: Node = AimBrain.new()
	b.name = "AimBrain"
	p.add_child(b)
	p.brain = b
	return b

func _started(f: Fighter) -> Array:
	var starts: Array = []
	f.combat.attack_started.connect(func(id: StringName) -> void: starts.append([id, TimeDirector.now()]))
	return starts

func _landed(move_id: StringName, victim: Fighter = null) -> HitInfo:
	for i in range(events.size() - 1, -1, -1):
		var ev: Array = events[i]
		if ev[0] == &"hit_landed" and (ev[1] as HitInfo).move_id == move_id \
				and (victim == null or (ev[1] as HitInfo).victim == victim):
			return ev[1]
	return null

func run() -> void:
	print("strike limbs follow PoseLibrary.STRIKE_BONES")
	for id: StringName in [&"jab1", &"jab2", &"cross", &"sparta_kick", &"elbow", &"e_hook", &"e_jab"]:
		var m := MoveLibrary.get_move(id)
		var src: Array = PoseLibrary.STRIKE_BONES.get(id, PoseLibrary.STRIKE_BONES.get(m.anim, []))
		if src.is_empty():
			continue
		check(m.limb == StringName(src[0]), "%s strikes with %s" % [id, src[0]])

	print("buffer: kick pressed in blockstun comes out")
	var pe: Array = await _pair(&"grunt", 1.2)
	var p: Fighter = pe[0]
	var e: Fighter = pe[1]
	var started := _started(p)
	p.combat.press(B)
	await wait_real(0.3)  # a held guard (the press's parry window has closed)
	clear_events()
	e.combat.start_enemy_attack(&"e_heavy", 0.4)
	await wait_until(func() -> bool: return count_events(&"hit_blocked") > 0, 2.0)
	var t_block := TimeDirector.now()
	check(count_events(&"hit_blocked") > 0 and p.combat.is_stunned(), "player guarded, in blockstun")
	p.combat.release(B)
	tap(p, K)
	await wait_until(func() -> bool: return not started.is_empty(), 1.0)
	check(not started.is_empty() and started[0][0] == &"sparta_kick", "buffered kick started after blockstun")
	if not started.is_empty():
		var dt: float = started[0][1] - t_block
		var stun := minf(Power.hitstop_for(HitInfo.Tier.FLINCH), Tuning.PLAYER_HITSTOP_MAX) \
			+ Tuning.frames(MoveLibrary.get_move(&"e_heavy").blockstun)
		check(dt >= stun - 0.02 and dt < stun + 0.1, "kick came out %.3f s after the block (blockstun+hitstop %.3f)" % [dt, stun])

	print("block punish: a blocked e_hook is punished by a kick")
	pe = await _pair(&"grunt", 1.2)
	p = pe[0]
	e = pe[1]
	var e_active := [0.0]
	e.combat.attack_active.connect(func(_id: StringName) -> void: e_active[0] = TimeDirector.now())
	p.combat.press(B)
	await wait_real(0.3)
	clear_events()
	e.combat.start_enemy_attack(&"e_hook", 0.4)
	await wait_until(func() -> bool: return count_events(&"hit_blocked") > 0, 2.0)
	p.combat.release(B)
	tap(p, K)
	var ok := await wait_until(func() -> bool: return _landed(&"sparta_kick", e) != null, 1.5)
	check(ok, "punishing kick landed")
	var hook := MoveLibrary.get_move(&"e_hook")
	var hook_left := Tuning.frames(hook.active + hook.recovery) + Power.hitstop_for(HitInfo.Tier.FLINCH)
	var t_hit := TimeDirector.now()
	check(ok and t_hit - e_active[0] < hook_left + 0.05,
		"kick hit %.3f s after the hook went active (hook busy for %.3f s)" % [t_hit - e_active[0], hook_left])

	print("cancel: jab hit -> Kick (the string's knee)")
	pe = await _pair(&"grunt", 1.0)
	p = pe[0]
	e = pe[1]
	started = _started(p)
	clear_events()
	tap(p, L)
	await wait_until(func() -> bool: return _landed(&"jab1", e) != null, 1.0)
	tap(p, K)
	ok = await wait_until(func() -> bool: return _landed(&"knee_strike", e) != null, 1.5)
	check(ok, "jab -> knee cancel landed")
	if started.size() >= 2:
		var jab := MoveLibrary.get_move(&"jab1")
		var full := Tuning.frames(jab.startup + jab.active) + jab.recovery_s(true)
		var gap: float = started[1][1] - started[0][1]
		check(started[1][0] == &"knee_strike" and gap < full,
			"knee started %.3f s after the jab (the jab alone lasts %.3f s)" % [gap, full])

	print("no cancel on a whiff")
	_x += 12.0
	var lone := spawn(&"player", Vector3(_x, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	await ticks(10)
	started = _started(lone)
	tap(lone, L)
	await wait_until(func() -> bool: return lone.combat.is_attack_active(), 1.0)
	tap(lone, K)
	await wait_until(func() -> bool: return started.size() >= 2, 1.5)
	if started.size() >= 2:
		var jab := MoveLibrary.get_move(&"jab1")
		var full := Tuning.frames(jab.startup + jab.active) + jab.recovery_s(false)
		var gap: float = started[1][1] - started[0][1]
		check(gap >= full - 0.02, "a whiffed jab is not cancelled (next after %.3f s >= %.3f)" % [gap, full])
	else:
		check(false, "the second press came out after the whiffed jab")

	print("target picking: the stick's cone beats the nearest enemy")
	_x += 14.0
	var pt := spawn(&"player", Vector3(_x, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var stick := Vector3(1, 0, -1).normalized()  # 45 degrees right of facing
	var ga := spawn(&"grunt", pt.global_position + stick * 2.0, -stick)
	var gb := spawn(&"grunt", pt.global_position + Vector3(0, 0, -1.5), Vector3.BACK)
	var br := _brain(pt)
	br.set(&"stick", stick)
	var tv: Traversal = TraversalDouble.new()
	pt.add_child(tv)
	tv.setup(pt)
	pt.traversal = tv
	await ticks(15)
	var sa := Targeting.strike_score(pt.get_ground_position(), stick, ga.get_ground_position(), Tuning.STRIKE_TARGET_RANGE)
	var sb := Targeting.strike_score(pt.get_ground_position(), stick, gb.get_ground_position(), Tuning.STRIKE_TARGET_RANGE)
	print("  scores: on the stick 2.0 m %.2f, 45 deg off 1.5 m %.2f" % [sa, sb])
	var p0 := pt.global_position
	tap(pt, L)
	await ticks(1)
	check(pt.combat.get_attack_target() == ga, "the strike targets the enemy on the stick")
	check(pt.get_forward().dot(stick) > 0.98, "turned to face it (dot %.3f)" % pt.get_forward().dot(stick))
	check((tv.get(&"last_dir") as Vector3).dot(stick) > 0.98, "speed bonus read toward the target")
	await wait_until(func() -> bool: return not pt.combat.is_attacking(), 1.0)
	var moved := Vector3(pt.global_position.x - p0.x, 0.0, pt.global_position.z - p0.z)
	print("  lunged %.2f m toward a target 2.0 m away (LUNGE_MAX %.1f)" % [moved.length(), Tuning.LUNGE_MAX])
	check(moved.length() <= Tuning.LUNGE_MAX + 0.05 and moved.length() > 0.5, "the lunge covers at most LUNGE_MAX")
	check(moved.normalized().dot(stick) > 0.95, "the lunge goes toward the target")
	check(_landed(&"jab1", ga) != null, "the jab landed on the stick's target")

	print("no target: strike along the stick")
	_x += 14.0
	var pn := spawn(&"player", Vector3(_x, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var bn := _brain(pn)
	bn.set(&"stick", Vector3.RIGHT)
	await ticks(10)
	var pn0 := pn.global_position
	tap(pn, L)
	await ticks(1)
	check(pn.combat.get_attack_target() == null, "no target in range")
	check(pn.get_forward().dot(Vector3.RIGHT) > 0.98, "turned along the stick (dot %.3f)" % pn.get_forward().dot(Vector3.RIGHT))
	await wait_until(func() -> bool: return not pn.combat.is_attacking(), 1.0)
	check(pn.global_position.distance_to(pn0) < 0.1, "no step without a target: it strikes where it stands (%.2f m)" % pn.global_position.distance_to(pn0))

	print("lock-on: the locked target wins over the stick")
	_x += 14.0
	var pl := spawn(&"player", Vector3(_x, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var front := spawn(&"grunt", Vector3(_x, 0, -1.5), Vector3.BACK)
	var behind := spawn(&"grunt", Vector3(_x, 0, 1.5), Vector3.FORWARD)
	var bl := _brain(pl)
	bl.set(&"stick", Vector3.FORWARD)
	bl.set(&"lock", behind)
	await ticks(10)
	tap(pl, L)
	await ticks(1)
	check(pl.combat.get_attack_target() == behind, "the locked enemy is the target")
	check(pl.get_forward().dot(Vector3.BACK) > 0.98, "turned to the locked enemy behind")
	await wait_until(func() -> bool: return not pl.combat.is_attacking(), 1.0)
	check(front.hp == front.max_hp, "the enemy in front of the stick was not struck")
	done()
