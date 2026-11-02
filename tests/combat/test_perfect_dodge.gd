extends "res://tests/combat/combat_test_base.gd"
## Round 5 defence integration (replaces the Upgrade 2 perfect dodge; Defence
## is agent H's): on the first active frame of every attack aimed at a fighter
## CombatController asks Defence.intercepts() first.
## - a Block press just before the first active frame parries: no damage, the
##   attacker is staggered (its attack is over: no whiff);
## - a jab right after the parry is P 3.5 (+2.5 counter bonus), a knockdown, and
##   the bonus is used up by that hit;
## - a held guard without a timed press is a guard: 80% less damage;
## - intercepts() is asked once per attack with (attacker, move); an intercept
##   without a parry makes the attack whiff (attack_whiff, whiff recovery).

const DefenceDouble := preload("res://tests/combat/defence_double.gd")
const A := CombatController.Action
var _x := 0.0

func _init() -> void:
	_timeout = 60.0

func _pair(dist := 1.2) -> Array:
	_x += 10.0
	var p := spawn(&"player", Vector3(_x, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var e := spawn(&"grunt", Vector3(_x, 0, -dist), Vector3.BACK)
	await ticks(20)
	return [p, e]

func _landed_on(f: Fighter) -> HitInfo:
	for e: Array in events:
		if e[0] == &"hit_landed" and (e[1] as HitInfo).victim == f:
			return e[1]
	return null

func run() -> void:
	print("a timed Block press parries")
	var pe: Array = await _pair()
	var p: Fighter = pe[0]
	var e: Fighter = pe[1]
	check(p.defence != null and p.defence.is_enabled(), "Defence is on")
	var parried := [false]
	GameEvents.parried.connect(func(d: Node3D, a: Node3D) -> void:
		if d == p and a == e:
			parried[0] = true)
	clear_events()
	var hp0 := p.hp
	e.combat.start_enemy_attack(&"e_hook", 0.5)
	await wait_until(func() -> bool: return e.combat.time_to_active() <= 0.08, 2.0)
	p.combat.press(A.BLOCK)
	p.combat.release(A.BLOCK)
	await wait_real(0.3)
	check(parried[0], "parried")
	check(is_equal_approx(p.hp, hp0), "no damage")
	check(count_events(&"attack_whiff") == 0 and not e.combat.is_attacking(), "the attacker's hook is over (staggered, no whiff)")
	check(e.is_in_hitstun(), "the attacker is staggered")
	print("a jab right after the parry")
	clear_events()
	tap(p, A.LIGHT)
	await wait_until(func() -> bool: return _landed_on(e) != null, 1.0)
	var info := _landed_on(e)
	if info != null:
		print("  jab after a parry: P %.2f (counter %.2f) tier %s" % [info.power, info.counter_bonus, HitInfo.tier_name(info.tier)])
	check(info != null and is_equal_approx(info.power, 3.5) and info.tier == HitInfo.Tier.KNOCKDOWN, "P 3.5, a knockdown")
	check(is_zero_approx(p.defence.counter_bonus()), "the counter bonus was used up by the hit")
	await wait_real(2.5)

	print("a held guard without a timed press: 80% less damage")
	pe = await _pair()
	p = pe[0]
	e = pe[1]
	p.combat.press(A.BLOCK)
	await wait_real(Tuning.PARRY_WINDOW + Tuning.PARRY_LOCKOUT + 0.05)
	clear_events()
	hp0 = p.hp
	e.combat.start_enemy_attack(&"e_hook", 0.4)
	await wait_until(func() -> bool: return count_events(&"hit_blocked") > 0 or count_events(&"hit_landed") > 0, 2.0)
	check(count_events(&"hit_blocked") == 1, "BLOCKED")
	check(is_equal_approx(hp0 - p.hp, Tuning.DMG_ENEMY[&"e_hook"] * Tuning.GUARD_DAMAGE_MULT), "80%% less damage (%.1f)" % (hp0 - p.hp))
	p.combat.release(A.BLOCK)

	print("intercepts() is asked once per attack; an intercept makes it whiff")
	pe = await _pair()
	p = pe[0]
	e = pe[1]
	p.defence.queue_free()
	var dd: Defence = DefenceDouble.new()
	p.add_child(dd)
	dd.setup(p)
	p.defence = dd
	dd.set(&"intercept", true)
	clear_events()
	hp0 = p.hp
	var t0 := TimeDirector.now()
	var ended := [0.0]
	e.combat.attack_ended.connect(func(_id: StringName) -> void: ended[0] = TimeDirector.now())
	e.combat.start_enemy_attack(&"e_jab", 0.4)
	await wait_until(func() -> bool: return ended[0] > 0.0, 2.0)
	var asked: Array = dd.get(&"intercepted")
	check(asked.size() == 1 and asked[0][0] == e and asked[0][1] == &"e_jab", "asked once with (attacker, e_jab) (%d)" % asked.size())
	check(is_equal_approx(p.hp, hp0) and count_events(&"attack_whiff") == 1, "the intercepted jab whiffed")
	var m := MoveLibrary.get_move(&"e_jab")
	var whole := maxf(0.4, Tuning.frames(AttackDirector.enemy_startup_frames(&"e_jab"))) + m.active_s() + m.recovery_s(false)
	check(absf(ended[0] - t0 - whole) < 0.03, "with its whiff recovery (%.3f s, want %.3f)" % [ended[0] - t0, whole])
	print("the player's strikes ask the enemy's Defence too")
	var ed: Defence = DefenceDouble.new()
	e.add_child(ed)
	ed.setup(e)
	e.defence.queue_free()
	e.defence = ed
	await wait_real(0.3)
	tap(p, A.LIGHT)
	await wait_until(func() -> bool: return not p.combat.is_attacking(), 1.0)
	var asked2: Array = ed.get(&"intercepted")
	check(asked2.size() == 1 and asked2[0][0] == p and asked2[0][1] == &"jab1", "the grunt's Defence was asked about the jab")
	done()
