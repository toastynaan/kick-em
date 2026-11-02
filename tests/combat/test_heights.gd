extends "res://tests/combat/combat_test_base.gd"
## Upgrade 2 heights (U3): highs pass over a crouch, lows under a jump, a
## crouching guard stops lows and not mids, standing grabs whiff on a croucher,
## a jumping fighter takes an air counter; crouch / jump / rising / back moves;
## the player's guard covers only the front. Stances are faked (FakeFighter).

const L := CombatController.Action.LIGHT
const K := CombatController.Action.KICK
var _x := 0.0

func _lane(p_fake: bool, e_fake: bool, dist := 1.1) -> Array:
	_x += 8.0
	var p: Fighter = spawn_fake(&"player", Vector3(_x, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER) if p_fake \
		else spawn(&"player", Vector3(_x, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var e: Fighter = spawn_fake(&"grunt", Vector3(_x, 0, -dist), Vector3.BACK) if e_fake \
		else spawn(&"grunt", Vector3(_x, 0, -dist), Vector3.BACK)
	await ticks(12)
	return [p, e]

func _first_move(f: Fighter, action: int) -> StringName:
	var got := [&""]
	var cb := func(id: StringName) -> void:
		if got[0] == &"":
			got[0] = id
	f.combat.attack_started.connect(cb)
	tap(f, action)
	f.combat.attack_started.disconnect(cb)
	return got[0]

func run() -> void:
	print("highs pass over a crouch, lows under a jump")
	var pe: Array = await _lane(false, true)
	var e: Fighter = pe[1]
	e.fake_crouch = true
	var hp0 := e.hp
	tap(pe[0], L)
	await wait_real(0.5)
	check(is_equal_approx(e.hp, hp0), "jab (HIGH) whiffs on a crouching enemy")
	e.fake_crouch = false
	tap(pe[0], L)
	await wait_real(0.5)
	check(e.hp < hp0, "the same jab hits him standing")
	pe = await _lane(false, true)
	e = pe[1]
	e.fake_air = true
	hp0 = e.hp
	tap(pe[0], CombatController.Action.SWEEP)
	await wait_real(0.6)
	check(is_equal_approx(e.hp, hp0), "sweep (LOW) whiffs on a jumping enemy")

	print("guard heights")
	pe = await _lane(true, false, 1.3)
	var p: Fighter = pe[0]
	e = pe[1]
	p.combat.press(CombatController.Action.BLOCK)
	await ticks(3)
	p.combat.last_result = -1
	e.combat.start_enemy_attack(&"e_sweep", 0.35)
	await wait_until(func() -> bool: return p.combat.last_result != -1, 2.0)
	check(p.combat.last_result == HitInfo.Result.HIT, "a standing guard does not stop a low (e_sweep)")
	await wait_real(2.5)
	if p.is_down():
		p.ragdoll.force_recover()
	pe = await _lane(true, false, 1.3)
	p = pe[0]
	e = pe[1]
	p.fake_crouch = true
	p.combat.press(CombatController.Action.BLOCK)
	await ticks(3)
	p.combat.last_result = -1
	e.combat.start_enemy_attack(&"e_sweep", 0.35)
	await wait_until(func() -> bool: return p.combat.last_result != -1, 2.0)
	check(p.combat.last_result == HitInfo.Result.BLOCKED, "a crouching guard stops the low")
	await wait_real(0.8)
	p.combat.last_result = -1
	e.combat.start_enemy_attack(&"e_kick", 0.35)
	await wait_until(func() -> bool: return p.combat.last_result != -1, 2.0)
	check(p.combat.last_result == HitInfo.Result.HIT, "a mid (e_kick) hits a crouching guard")
	await wait_real(2.5)

	print("standing grabs whiff on a crouch")
	pe = await _lane(true, false, 1.0)
	p = pe[0]
	e = pe[1]
	p.fake_crouch = true
	clear_events()
	e.combat.start_enemy_attack(&"e_grab", 0.35)
	await wait_real(0.8)
	check(count_events(&"grab_started") == 0, "e_grab whiffed on the crouching player")

	print("air counter")
	pe = await _lane(true, false, 1.2)
	p = pe[0]
	e = pe[1]
	p.fake_air = true
	clear_events()
	e.combat.start_enemy_attack(&"e_hook", 0.35)
	await wait_until(func() -> bool: return count_events(&"hit_landed") > 0, 2.0)
	var info: HitInfo = last_event(&"hit_landed")[1] if count_events(&"hit_landed") > 0 else null
	check(info != null and info.air_counter and info.reaction == HitInfo.Reaction.LAUNCH,
		"a jumping player hit by a hook takes an air counter launch")
	if info:
		var want := 5.0 * Tuning.AIR_COUNTER_LAUNCH
		check(info.launch_velocity.length() >= want - 0.3, "x AIR_COUNTER_LAUNCH (%.2f m/s)" % info.launch_velocity.length())
	await wait_real(2.0)

	print("stance moves")
	_x += 8.0
	var f := spawn_fake(&"player", Vector3(_x, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	await ticks(10)
	var cases := [
		["crouch + P", "crouch", L, &"crouch_punch"], ["crouch + K", "crouch", K, &"leg_sweep"],
		["jump + K", "air", K, &"flying_kick"], ["jump + P", "air", L, &"hammer_fist"],
		["back + P", "back", L, &"backfist"], ["SWEEP action", "", CombatController.Action.SWEEP, &"leg_sweep"]]
	for c: Array in cases:
		f.fake_crouch = c[1] == "crouch"
		f.fake_air = c[1] == "air"
		f.fake_intent = &"back" if c[1] == "back" else &"neutral"
		var id: StringName = _first_move(f, c[2])
		check(id == c[3], "%s -> %s (%s)" % [c[0], c[3], id])
		f.fake_crouch = false
		f.fake_air = false
		f.fake_intent = &"neutral"
		await wait_real(1.0)
	f.fake_crouch = true
	await ticks(3)
	f.fake_crouch = false
	await ticks(2)
	var rid := _first_move(f, L)
	check(rid == &"rising_uppercut", "P right after releasing crouch -> rising_uppercut (%s)" % rid)
	await wait_real(1.0)
	var lvl_ok := true
	for id: StringName in MoveLibrary.PLAYER_MOVES + MoveLibrary.ENEMY_MOVES:
		var m := MoveLibrary.get_move(id)
		if m == null:
			lvl_ok = false
			print("  missing move ", id)
	check(lvl_ok, "every shared move id has MoveData")
	check(MoveLibrary.get_move(&"e_hook").hit_level == HitInfo.Level.HIGH and MoveLibrary.get_move(&"e_kick").hit_level == HitInfo.Level.MID
		and MoveLibrary.get_move(&"e_grab").hit_level == HitInfo.Level.HIGH and MoveLibrary.get_move(&"e_sweep").hit_level == HitInfo.Level.LOW,
		"enemy heights: e_hook HIGH, e_kick MID, e_grab HIGH, e_sweep LOW")

	print("the player's guard covers the front only")
	pe = await _lane(true, false, 1.2)
	p = pe[0]
	e = pe[1]
	p.combat.press(CombatController.Action.BLOCK)
	await ticks(3)
	p.combat.last_result = -1
	e.combat.start_enemy_attack(&"e_hook", 0.35)
	await wait_until(func() -> bool: return p.combat.last_result != -1, 2.0)
	check(p.combat.last_result == HitInfo.Result.BLOCKED, "front: blocked")
	await wait_real(1.0)
	p.snap_facing(Vector3.BACK)
	await ticks(3)
	p.combat.last_result = -1
	e.combat.start_enemy_attack(&"e_hook", 0.35)
	await wait_until(func() -> bool: return p.combat.last_result != -1, 2.0)
	check(p.combat.last_result == HitInfo.Result.HIT, "back turned: the hook lands")
	done()
