extends "res://tests/combat/combat_test_base.gd"
## Round 5 grab routing (grabs, holds and throws are agent G's Carry):
## - Grab press / release go to Carry; attack presses while holding go to
##   Carry (knees, throws) and never start a CombatController strike;
## - enemy grab moves (e_grab, e_grab_slam) show the grab tell and connect
##   through the victim's Carry on their active frames, through a guard;
## - a standing grab whiffs on a crouching player;
## - Defence.intercepts() is asked first on the grab's first active frame,
##   and an intercepted grab misses.

const DefenceDouble := preload("res://tests/combat/defence_double.gd")
const A := CombatController.Action
var _x := 0.0

func _init() -> void:
	_timeout = 90.0

func _lane(dist := 1.0, fake := false) -> Array:
	_x += 10.0
	var p: Fighter = spawn_fake(&"player", Vector3(_x, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER) if fake \
		else spawn(&"player", Vector3(_x, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var e := spawn(&"grunt", Vector3(_x, 0, -dist), Vector3.BACK)
	await ticks(20)
	return [p, e]

func _held(f: Fighter) -> bool:
	return f.carry != null and f.carry.is_held()

func run() -> void:
	print("Grab press routes to Carry; attacks while holding go to Carry")
	var pe: Array = await _lane()
	var p: Fighter = pe[0]
	var e: Fighter = pe[1]
	check(p.carry != null and p.carry.is_enabled(), "Carry is on")
	p.combat.press(A.GRAB)
	p.combat.release(A.GRAB)
	var ok := await wait_until(func() -> bool: return p.carry.is_holding() and _held(e), 1.5)
	check(ok, "the grab connected through Carry")
	var started: Array = []
	p.combat.attack_started.connect(func(id: StringName) -> void: started.append(id))
	clear_events()
	var hp0 := e.hp
	tap(p, A.LIGHT)
	await wait_real(0.5)
	check(started.is_empty() and not p.combat.is_attacking(), "Light while holding starts no strike (%s)" % [started])
	check(e.hp < hp0 or count_events(&"hit_landed") > 0, "Carry turned it into a knee on the held body")
	await wait_real(Tuning.HOLD_MAX + 0.5)

	print("enemy grabs connect through Carry, through a guard")
	for move: StringName in [&"e_grab", &"e_grab_slam"]:
		pe = await _lane(1.1)
		p = pe[0]
		e = pe[1]
		p.combat.press(A.BLOCK)
		await wait_real(0.3)
		clear_events()
		check(e.combat.start_enemy_attack(move, 0.35), "%s started" % move)
		var tell := last_event(&"attack_tell")
		check(not tell.is_empty() and tell[2] == &"grab", "%s: the grab tell" % move)
		ok = await wait_until(func() -> bool: return _held(p), 2.0)
		check(ok, "%s: the guarding player is caught" % move)
		check(count_events(&"attack_whiff") == 0, "%s: no whiff" % move)
		p.combat.release(A.BLOCK)
		await wait_real(3.0)

	print("a standing grab whiffs on a crouching player")
	pe = await _lane(1.0, true)
	p = pe[0]
	e = pe[1]
	p.fake_crouch = true
	clear_events()
	e.combat.start_enemy_attack(&"e_grab", 0.35)
	await wait_until(func() -> bool: return not e.combat.is_attacking(), 2.5)
	check(not _held(p) and count_events(&"attack_whiff") == 1, "e_grab whiffed on the crouch")

	print("Defence is asked first; an intercepted grab misses")
	pe = await _lane(1.0)
	p = pe[0]
	e = pe[1]
	if p.defence != null:
		p.defence.queue_free()
	var dd: Defence = DefenceDouble.new()
	p.add_child(dd)
	dd.setup(p)
	p.defence = dd
	dd.set(&"intercept", true)
	clear_events()
	e.combat.start_enemy_attack(&"e_grab", 0.35)
	await wait_until(func() -> bool: return not e.combat.is_attacking(), 2.5)
	var asked: Array = dd.get(&"intercepted")
	check(asked.size() == 1 and asked[0][0] == e and asked[0][1] == &"e_grab", "intercepts(attacker, e_grab) once (%d)" % asked.size())
	check(not _held(p) and count_events(&"attack_whiff") == 1, "the intercepted grab missed")
	done()
