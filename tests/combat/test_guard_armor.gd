extends "res://tests/combat/combat_test_base.gd"
## Round 2 defence: guard cones per archetype, tell armor, dodge feedback.

var _x := 0.0

## A player and an enemy 1.0-1.2 m apart on a fresh lane. guard: the enemy holds
## Block. back: the enemy faces away from the player.
func _pair(arch: StringName, guard: bool, back: bool, dist := 1.1) -> Array:
	_x += 7.0
	var p := spawn(&"player", Vector3(_x, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var e := spawn(arch, Vector3(_x, 0, -dist), Vector3.FORWARD if back else Vector3.BACK)
	await ticks(15)
	if guard:
		e.combat.press(CombatController.Action.BLOCK)
		await ticks(3)
	return [p, e]

## Player performs `action` (Heavy held `hold` s) and returns the defender's result.
func _strike(p: Fighter, e: Fighter, action: int, hold := 0.0) -> int:
	clear_events()
	e.combat.last_result = -1
	p.combat.press(action)
	if hold > 0.0:
		await wait_real(hold)
	p.combat.release(action)
	await wait_until(func() -> bool: return e.combat.last_result != -1, 2.0)
	return e.combat.last_result

func _name(r: int) -> String:
	return ["IGNORED", "HIT", "BLOCKED", "DODGED", "GRAB_BROKEN"][r] if r >= 0 else "none"

func _expect(arch: StringName, guard: bool, back: bool, action: int, want: int, what: String, hold := 0.0) -> void:
	var pe: Array = await _pair(arch, guard, back)
	var r: int = await _strike(pe[0], pe[1], action, hold)
	check(r == want, "%s: %s (got %s)" % [arch, what, _name(r)])

func run() -> void:
	const L := CombatController.Action.LIGHT
	const K := CombatController.Action.KICK
	const S := CombatController.Action.SWEEP
	const H := CombatController.Action.HEAVY
	const HIT := HitInfo.Result.HIT
	const BLK := HitInfo.Result.BLOCKED
	print("guard cones")
	await _expect(&"brawler", true, false, L, BLK, "guard blocks a front jab")
	await _expect(&"brawler", true, false, K, BLK, "guard blocks a front kick")
	await _expect(&"brawler", true, false, S, HIT, "sweep gets through the guard")
	await _expect(&"brawler", true, false, H, HIT, "full-charge power punch gets through", 1.05)
	await _expect(&"brawler", true, false, H, HIT, "tap power punch gets through (Brawler guard stops jabs and kicks only)")
	await _expect(&"brawler", true, true, L, HIT, "jab to the back gets through")
	await _expect(&"brawler", false, false, L, BLK, "innate block still stops front jabs")
	await _expect(&"brawler", false, true, L, HIT, "innate block does not cover the back")
	await _expect(&"grunt", true, false, K, BLK, "guard blocks a front kick")
	await _expect(&"grunt", true, true, K, HIT, "kick to the back gets through")
	await _expect(&"grunt", true, false, S, HIT, "sweep gets through")
	await _expect(&"shield", false, false, K, BLK, "front kick blocked")
	await _expect(&"shield", false, false, H, BLK, "tap power punch blocked")
	await _expect(&"shield", false, false, S, HIT, "sweep gets through")
	await _expect(&"shield", false, false, H, HIT, "full-charge power punch gets through", 1.05)
	await _expect(&"shield", false, true, L, HIT, "jab to the back gets through")

	print("player guard covers every side")
	_x += 7.0
	var pb := spawn(&"player", Vector3(_x, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var eb := spawn(&"grunt", Vector3(_x, 0, 1.2), Vector3.FORWARD)  # behind the player
	await ticks(15)
	pb.combat.press(CombatController.Action.BLOCK)
	await ticks(3)
	clear_events()
	eb.combat.start_enemy_attack(&"e_hook", 0.4)
	await wait_until(func() -> bool: return pb.combat.last_result != -1, 2.0)
	check(pb.combat.last_result == BLK, "e_hook from behind is blocked by the player's guard")
	pb.combat.release(CombatController.Action.BLOCK)

	print("tell armor")
	var pe: Array = await _pair(&"grunt", false, false, 1.2)
	var p: Fighter = pe[0]
	var e: Fighter = pe[1]
	var ended := [false]
	e.combat.attack_ended.connect(func(_id: StringName) -> void: ended[0] = true)
	clear_events()
	var hp0 := e.hp
	check(e.combat.start_enemy_attack(&"e_kick", 0.5), "grunt e_kick started")
	await wait_real(0.1)
	check(e.combat.get_armor_level() == 1, "e_kick armor 1 in startup")
	p.combat.press(L)
	p.combat.release(L)
	await wait_until(func() -> bool: return count_events(&"armor_absorbed") > 0, 1.0)
	check(count_events(&"armor_absorbed") == 1, "jab absorbed by tell armor")
	check(is_equal_approx(hp0 - e.hp, Tuning.DMG_JAB), "armored hit still deals damage (%.0f)" % (hp0 - e.hp))
	check(e.combat.is_attacking() and not ended[0], "the kick is not cancelled")
	check(e.get_state() == RagdollController.State.ANIMATED, "no flinch")
	await wait_until(func() -> bool: return not e.combat.is_attacking(), 2.0)

	pe = await _pair(&"grunt", false, false, 1.2)
	p = pe[0]
	e = pe[1]
	clear_events()
	var cancelled := [false]
	var went_active := [false]
	e.combat.attack_active.connect(func(_id: StringName) -> void: went_active[0] = true)
	e.combat.attack_ended.connect(func(_id: StringName) -> void: cancelled[0] = not went_active[0])
	check(e.combat.start_enemy_attack(&"e_hook", 0.5), "grunt e_hook started")
	await wait_real(0.1)
	check(e.combat.get_armor_level() == 0, "e_hook has no armor")
	p.combat.press(L)
	p.combat.release(L)
	await wait_real(0.3)
	check(count_events(&"armor_absorbed") == 0 and count_events(&"hit_landed") >= 1, "jab lands on an unarmored tell")
	check(cancelled[0], "the hook is cancelled before going active")

	pe = await _pair(&"brute", false, false, 1.2)
	p = pe[0]
	e = pe[1]
	clear_events()
	check(e.combat.start_enemy_attack(&"e_heavy", 0.6), "brute e_heavy started")
	await wait_real(0.05)
	check(e.combat.get_armor_level() == 2, "brute e_heavy armor 2 (1 + armor_bonus)")
	p.combat.press(H)
	p.combat.release(H)
	await wait_until(func() -> bool: return count_events(&"armor_absorbed") > 0 or count_events(&"hit_landed") > 0, 1.0)
	check(count_events(&"armor_absorbed") == 1, "armor 2 absorbs a stagger (tap power punch)")
	check(e.combat.is_attacking(), "brute keeps swinging")
	await wait_until(func() -> bool: return not e.combat.is_attacking(), 2.0)

	pe = await _pair(&"duelist", false, false, 1.3)
	p = pe[0]
	e = pe[1]
	clear_events()
	check(e.combat.start_enemy_attack(&"e_kick", 0.55), "duelist e_kick started")
	await wait_real(0.05)
	p.combat.press(K)
	p.combat.release(K)
	await wait_until(func() -> bool: return count_events(&"hit_landed") > 0 or count_events(&"armor_absorbed") > 0, 1.0)
	check(count_events(&"armor_absorbed") == 0 and count_events(&"hit_landed") == 1, "launch goes through armor 2")
	check(not e.combat.is_attacking(), "launched duelist's kick is cancelled")

	print("dodge feedback")
	pe = await _pair(&"grunt", false, false, 1.2)
	p = pe[0]
	e = pe[1]
	var fb: Array = []
	GameEvents.dodge_feedback.connect(func(d: Node3D, r: StringName) -> void: fb.append([d, r]))
	e.combat.start_enemy_attack(&"e_hook", 0.5)
	await wait_until(func() -> bool: return e.combat.time_to_active() <= 0.25, 2.0)
	p.combat.press(CombatController.Action.BLOCK)
	p.combat.release(CombatController.Action.BLOCK)
	await wait_until(func() -> bool: return not e.combat.is_attacking(), 2.0)
	check(fb.size() == 1 and fb[0][0] == p and fb[0][1] == &"early", "early press -> dodge_feedback early (%s)" % [fb])
	fb.clear()
	await wait_real(1.0)
	e.combat.start_enemy_attack(&"e_hook", 0.4)
	await wait_until(func() -> bool: return e.combat.is_attack_active(), 2.0)
	await ticks(2)
	p.combat.press(CombatController.Action.BLOCK)
	p.combat.release(CombatController.Action.BLOCK)
	check(fb.size() == 1 and fb[0][1] == &"late", "press during active frames -> dodge_feedback late (%s)" % [fb])
	fb.clear()
	await wait_real(1.0)
	var g2: Fighter = (await _pair(&"grunt", false, false))[1]
	g2.combat.press(CombatController.Action.BLOCK)
	g2.combat.release(CombatController.Action.BLOCK)
	check(fb.is_empty(), "non-eligible fighters get no feedback")
	done()
