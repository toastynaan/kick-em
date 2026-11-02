extends "res://tests/combat/combat_test_base.gd"
## F7 / F7b support (Feel Reference: Jump; Automatic parkour; Wall run), with a
## Traversal double:
## - any attack in the air is a dropping strike: Traversal.begin_drop_strike()
##   once, the button's class, active until the fighter lands;
## - an attack in the last 40% of a vault ends it in a dropping strike that
##   inherits the vault speed (full-sprint bonus); one pressed earlier is never
##   a dropping strike: it fires as a normal strike once the fighter has landed;
##   in a mantle (Traversal refuses the drop) the same;
## - a wall-run strike counts as full sprint: a tapped kick off a run is P 5.5
##   and launches, and on_strike_started(true) ends the run.

const TraversalDouble := preload("res://tests/combat/traversal_double.gd")
const A := CombatController.Action
var _x := 0.0

func _init() -> void:
	_timeout = 90.0

func _lane(dist := 1.1) -> Array:
	_x += 12.0
	var p := spawn_fake(&"player", Vector3(_x, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var g := spawn(&"grunt", Vector3(_x, 0, -dist), Vector3.BACK)
	var tv: Traversal = TraversalDouble.new()
	p.add_child(tv)
	tv.setup(p)
	p.traversal.queue_free()
	p.traversal = tv
	await ticks(15)
	return [p, g, tv]

func _landed_on(f: Fighter) -> HitInfo:
	for e: Array in events:
		if e[0] == &"hit_landed" and (e[1] as HitInfo).victim == f:
			return e[1]
	return null

func run() -> void:
	print("an attack in the air: a dropping strike until landing")
	var r: Array = await _lane()
	var p: Fighter = r[0]
	var g: Fighter = r[1]
	var tv: Traversal = r[2]
	var started: Array = []
	var ended := [0.0]
	p.combat.attack_started.connect(func(id: StringName) -> void: started.append(id))
	p.combat.attack_ended.connect(func(_id: StringName) -> void: ended[0] = TimeDirector.now())
	p.fake_air = true
	tv.set(&"airborne", true)
	clear_events()
	tap(p, A.KICK)
	check(started == [&"drop_strike"] and int(tv.get(&"drops")) == 1, "a drop strike, Traversal.begin_drop_strike() once")
	await wait_real(0.4)
	check(p.combat.is_attack_active(), "still active while in the air (0.4 s)")
	var info := _landed_on(g)
	check(info != null and is_equal_approx(info.power, Power.base_of(&"kick")), "the kick-class drop hits (P %.2f)" % (info.power if info else -1.0))
	p.fake_air = false
	tv.set(&"airborne", false)
	var t_land := TimeDirector.now()
	await wait_until(func() -> bool: return ended[0] > 0.0, 1.5)
	var dm := MoveLibrary.get_move(&"drop_strike")
	print("  landed: the drop strike ended %.3f s later (recovery %.3f s)" % [ended[0] - t_land, dm.recovery_s(true)])
	check(ended[0] - t_land < dm.recovery_s(false) + 0.05, "it ends on landing")
	await wait_real(Tuning.COMBO_DROP)

	print("vault: an early press is a normal strike after the landing, never a dropping strike")
	r = await _lane()
	p = r[0]
	g = r[1]
	tv = r[2]
	started = []
	p.combat.attack_started.connect(func(id: StringName) -> void: started.append(id))
	tv.set(&"vaulting", true)
	tv.set(&"vault_progress", 0.3)
	clear_events()
	p.combat.press(A.KICK)
	p.combat.release(A.KICK)
	await ticks(3)
	check(started.is_empty() and int(tv.get(&"drops")) == 0, "at 30% of the vault the press waits")
	tv.set(&"vault_progress", Tuning.VAULT_ATTACK_FROM + 0.05)
	await ticks(3)
	check(started.is_empty() and int(tv.get(&"drops")) == 0, "it does not become a dropping strike at %d%%" % int((Tuning.VAULT_ATTACK_FROM + 0.05) * 100))
	tv.set(&"vaulting", false)
	await ticks(3)
	check(started == [&"sparta_kick"], "after the vault it is a normal kick (%s)" % [started])
	await wait_real(Tuning.COMBO_DROP)

	print("vault: a press in the last 40% is a dropping strike at full sprint")
	r = await _lane()
	p = r[0]
	g = r[1]
	tv = r[2]
	started = []
	p.combat.attack_started.connect(func(id: StringName) -> void: started.append(id))
	tv.set(&"vaulting", true)
	tv.set(&"vault_progress", Tuning.VAULT_ATTACK_FROM + 0.05)
	tv.set(&"speed", 8.0)
	tv.set(&"sprinting", true)
	clear_events()
	p.combat.press(A.KICK)
	p.combat.release(A.KICK)
	await ticks(2)
	check(started == [&"drop_strike"] and int(tv.get(&"drops")) == 1, "at %d%% it is a dropping strike" % int((Tuning.VAULT_ATTACK_FROM + 0.05) * 100))
	tv.set(&"vaulting", false)
	tv.set(&"airborne", true)
	await wait_until(func() -> bool: return _landed_on(g) != null, 1.0)
	tv.set(&"airborne", false)
	info = _landed_on(g)
	check(info != null and info.sprint and is_equal_approx(info.speed_bonus, 3.0),
		"it inherits the vault speed: sprint, +3.0 (P %.2f)" % (info.power if info else -1.0))
	await wait_real(Tuning.COMBO_DROP)

	print("vault: a charge released in the last 40% is a dropping strike")
	r = await _lane()
	p = r[0]
	g = r[1]
	tv = r[2]
	started = []
	p.combat.attack_started.connect(func(id: StringName) -> void: started.append(id))
	p.combat.force_hold_charge = true
	p.combat.press(A.KICK)
	await wait_real(0.4)
	check(p.combat.is_charging(), "charging")
	tv.set(&"vaulting", true)
	tv.set(&"vault_progress", 0.75)
	p.combat.release(A.KICK)
	await ticks(1)
	check(p.combat.current_move_id() == &"drop_strike" and int(tv.get(&"drops")) == 1,
		"released at 75%% of the vault: a dropping strike (%s)" % p.combat.current_move_id())
	tv.set(&"vaulting", false)
	await wait_real(Tuning.COMBO_DROP)

	print("mantle: Traversal refuses the drop, the press fires on the ground")
	r = await _lane()
	p = r[0]
	tv = r[2]
	started = []
	p.combat.attack_started.connect(func(id: StringName) -> void: started.append(id))
	var refuse := GDScript.new()
	refuse.source_code = "extends \"res://tests/combat/traversal_double.gd\"\nfunc begin_drop_strike() -> bool:\n\tdrops += 1\n\treturn false\n"
	refuse.reload()
	var tm: Traversal = refuse.new()
	p.add_child(tm)
	tm.setup(p)
	p.traversal = tm
	tm.set(&"vaulting", true)
	tm.set(&"vault_progress", 0.8)
	tap(p, A.LIGHT)
	await ticks(3)
	check(started.is_empty(), "no strike while the mantle runs")
	tm.set(&"vaulting", false)
	await ticks(3)
	check(started == [&"jab1"], "the press fires as a normal strike once on the ground (%s)" % [started])
	await wait_real(Tuning.COMBO_DROP)

	print("wall-run strike: full sprint, ends the run")
	r = await _lane(1.4)
	p = r[0]
	g = r[1]
	tv = r[2]
	tv.set(&"wall_running", true)
	tv.set(&"speed", 6.5)  # real speed along the wall; a wall-run strike reads the cap
	var ss: Array = []
	GameEvents.strike_started.connect(func(a: Node3D, _t: Node3D, _m: StringName, s: bool, _c: int) -> void:
		if a == p:
			ss.append(s))
	clear_events()
	tap(p, A.KICK)
	await wait_until(func() -> bool: return _landed_on(g) != null, 1.5)
	info = _landed_on(g)
	if info != null:
		print("  wall-run kick: P %.2f (speed bonus %.2f) tier %s" % [info.power, info.speed_bonus, HitInfo.tier_name(info.tier)])
	check(info != null and info.power >= 5.0 and HitInfo.is_launch_tier(info.tier), "a tapped kick off a wall run: P >= 5, launches")
	var strikes: Array[bool] = tv.get(&"strikes")
	check(strikes == ([true] as Array[bool]) and not tv.is_wall_running(), "on_strike_started(true): the run ends")
	check(ss == [true], "strike_started(sprint = true)")
	await ticks(3)
	check(g.is_launched(), "the grunt is launched")
	done()
