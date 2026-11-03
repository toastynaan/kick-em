extends "res://tests/combat/combat_test_base.gd"
## Dropping strikes (Round 7 amendment: jump, vault and wall run are back;
## docs/Round 7 — Freeflow Combat.md: Movement, God path), with a Traversal
## double:
## - any strike in the air is the dropping strike: Traversal.begin_drop_strike()
##   once, active until the fighter lands, hitting with the button's move entry
##   (the punch's jab, the front kick's push);
## - a strike in the last 40% of a vault ends it in a dropping strike that
##   counts as the speed cap (a sprint strike: a front kick launches at
##   R7_SPRINT_LAUNCH_BASE + R7_SPRINT_LAUNCH_PER_MS (cap - 6)); one pressed
##   earlier, or in a mantle (Traversal refuses the drop), fires as a normal
##   strike once the fighter is on the ground;
## - a strike off a wall run counts as a full-speed sprint strike: a front kick
##   launches and on_strike_started(true) ends the run.

const TraversalDouble := preload("res://tests/combat/traversal_double.gd")
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
	if p.traversal != null:
		p.traversal.queue_free()
	p.traversal = tv
	await ticks(15)
	return [p, g, tv]

func run() -> void:
	print("a strike in the air: a dropping strike until landing, with the button's move")
	var r: Array = await _lane()
	var p: Fighter = r[0]
	var g: Fighter = r[1]
	var tv: Traversal = r[2]
	var started := record_moves(p)
	var ended := [0.0]
	p.combat.attack_ended.connect(func(_id: StringName) -> void: ended[0] = TimeDirector.now())
	tv.set(&"airborne", true)
	clear_events()
	tap(p, A.FRONT_KICK)
	check(Array(started) == [&"drop_strike"] and int(tv.get(&"drops")) == 1,
		"a drop strike, Traversal.begin_drop_strike() once")
	await wait_real(0.4)
	check(p.combat.is_attack_active(), "still active while in the air (0.4 s)")
	var info := last_hit(&"drop_strike")
	check(info != null and info.get_meta(&"drop_as", &"") == &"front_kick" and info.react == &"push"
		and is_equal_approx(info.push, float(Tuning.R7_MOVES[&"front_kick"]["push"])),
		"it hits with the front kick's entry (%s)" % (info.react if info else &"no hit"))
	tv.set(&"airborne", false)
	var t_land := TimeDirector.now()
	await wait_until(func() -> bool: return ended[0] > 0.0, 1.5)
	var dm := MoveLibrary.get_move(&"drop_strike")
	print("  landed: the drop strike ended %.3f s later (recovery %.3f s)" % [ended[0] - t_land, dm.recovery_s(false)])
	check(ended[0] - t_land < dm.recovery_s(false) + 0.05, "it ends on landing")
	await wait_real(Tuning.COMBO_DROP)

	print("the punch in the air hits with the jab")
	r = await _lane()
	p = r[0]
	g = r[1]
	tv = r[2]
	tv.set(&"airborne", true)
	clear_events()
	tap(p, A.LIGHT)
	await wait_until(func() -> bool: return last_hit(&"drop_strike") != null, 1.0)
	info = last_hit(&"drop_strike")
	check(info != null and info.get_meta(&"drop_as", &"") == &"jab" and info.react == &"snap", "a jab's snap")
	tv.set(&"airborne", false)
	await wait_real(Tuning.COMBO_DROP)

	print("vault: an early press is a normal strike after the landing, never a dropping strike")
	r = await _lane()
	p = r[0]
	g = r[1]
	tv = r[2]
	started = record_moves(p)
	tv.set(&"vaulting", true)
	tv.set(&"vault_progress", 0.3)
	clear_events()
	tap(p, A.FRONT_KICK)
	await ticks(3)
	check(started.is_empty() and int(tv.get(&"drops")) == 0, "at 30% of the vault the press waits")
	tv.set(&"vault_progress", Tuning.VAULT_ATTACK_FROM + 0.05)
	await ticks(3)
	check(started.is_empty() and int(tv.get(&"drops")) == 0, "it does not become a dropping strike later in the vault")
	tv.set(&"vaulting", false)
	await ticks(3)
	check(Array(started) == [&"front_kick"], "after the vault it is a normal front kick (%s)" % [started])
	await wait_real(Tuning.COMBO_DROP)

	print("vault: a press in the last 40% is a dropping strike at the speed cap")
	r = await _lane()
	p = r[0]
	g = r[1]
	tv = r[2]
	started = record_moves(p)
	tv.set(&"vaulting", true)
	tv.set(&"vault_progress", Tuning.VAULT_ATTACK_FROM + 0.05)
	tv.set(&"speed", 5.0)
	tv.set(&"cap", 8.0)
	clear_events()
	tap(p, A.FRONT_KICK)
	await ticks(2)
	check(Array(started) == [&"drop_strike"] and int(tv.get(&"drops")) == 1, "it is a dropping strike")
	tv.set(&"vaulting", false)
	tv.set(&"airborne", true)
	await wait_until(func() -> bool: return last_hit(&"drop_strike") != null, 1.0)
	tv.set(&"airborne", false)
	info = last_hit(&"drop_strike")
	var want := Tuning.R7_SPRINT_LAUNCH_BASE + Tuning.R7_SPRINT_LAUNCH_PER_MS * (8.0 - Tuning.SPEED_BONUS_FROM)
	print("  vault drop: sprint %s, react %s, launch %.2f m/s (want %.2f)" % [info.sprint if info else false,
		info.react if info else &"-", info.launch_velocity.length() if info else 0.0, want])
	check(info != null and info.sprint and info.react == &"launch" and absf(info.launch_velocity.length() - want) < 0.01,
		"it counts as the cap: the front kick launches at %.0f m/s" % want)
	await wait_real(Tuning.COMBO_DROP)

	print("mantle: Traversal refuses the drop, the press fires on the ground")
	r = await _lane()
	p = r[0]
	tv = r[2]
	var refuse := GDScript.new()
	refuse.source_code = "extends \"res://tests/combat/traversal_double.gd\"\nfunc begin_drop_strike() -> bool:\n\tdrops += 1\n\treturn false\n"
	refuse.reload()
	var tm: Traversal = refuse.new()
	p.add_child(tm)
	tm.setup(p)
	p.traversal = tm
	started = record_moves(p)
	tm.set(&"vaulting", true)
	tm.set(&"vault_progress", 0.8)
	tap(p, A.LIGHT)
	await ticks(3)
	check(started.is_empty(), "no strike while the mantle runs")
	tm.set(&"vaulting", false)
	await ticks(3)
	check(Array(started) == [&"jab"], "the press fires as a normal strike once on the ground (%s)" % [started])
	await wait_real(Tuning.COMBO_DROP)

	print("wall-run strike: full speed, ends the run")
	r = await _lane(1.4)
	p = r[0]
	g = r[1]
	tv = r[2]
	tv.set(&"wall_running", true)
	tv.set(&"speed", 6.5)  # real speed along the wall; a wall-run strike reads the cap
	tv.set(&"cap", 12.0)
	var ss: Array = []
	GameEvents.strike_started.connect(func(a: Node3D, _t: Node3D, _m: StringName, s: bool, _c: int) -> void:
		if a == p:
			ss.append(s))
	clear_events()
	tap(p, A.FRONT_KICK)
	await wait_until(func() -> bool: return last_hit(&"front_kick") != null, 1.5)
	info = last_hit(&"front_kick")
	var want12 := minf(Tuning.R7_SPRINT_LAUNCH_BASE + Tuning.R7_SPRINT_LAUNCH_PER_MS * (12.0 - Tuning.SPEED_BONUS_FROM),
		Tuning.LAUNCH_SPEED_MAX)
	if info != null:
		print("  wall-run front kick: react %s, launch %.2f m/s (want %.2f), tier %s" % [info.react,
			info.launch_velocity.length(), want12, HitInfo.tier_name(info.tier)])
	check(info != null and info.sprint and info.react == &"launch" and absf(info.launch_velocity.length() - want12) < 0.01,
		"a front kick off a wall run launches at the cap's sprint speed")
	var strikes: Array[bool] = tv.get(&"strikes")
	check(strikes == ([true] as Array[bool]) and not tv.is_wall_running(), "on_strike_started(true): the run ends")
	check(ss == [true], "strike_started(sprint = true)")
	await ticks(3)
	check(g.is_launched(), "the grunt is launched")
	done()
