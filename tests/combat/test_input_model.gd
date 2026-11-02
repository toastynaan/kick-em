extends "res://tests/combat/combat_test_base.gd"
## Input model (Upgrade 2, Round 5 numbers): tap vs hold at
## Tuning.HOLD_THRESHOLD, charge levels at Tuning.CHARGE_LEVELS (0.3 / 0.6 /
## 1.0 s of real time, also in slow motion) with Tuning.CHARGE_MULT on P and
## damage, auto-release, charging adds its hold time on top of the startup, a
## hit cancels the charge, block drops it, a Dash keeps it, walking while
## charging at Tuning.CHARGE_WALK_MULT, the buffer and the string reset, Heavy
## is its own button (a tapped cross).

const L := CombatController.Action.LIGHT
const K := CombatController.Action.KICK
var _x := 0.0

func _lane(dist := 1.0, enemy := true) -> Array:
	_x += 8.0
	var p := spawn_fake(&"player", Vector3(_x, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER, true)
	var e: Fighter = spawn(&"grunt", Vector3(_x, 0, -dist), Vector3.BACK) if enemy else null
	await ticks(12)
	return [p, e]

func _hit_on(e: Fighter) -> HitInfo:
	for i in range(events.size() - 1, -1, -1):
		var ev: Array = events[i]
		if ev[0] == &"hit_landed" and (ev[1] as HitInfo).victim == e:
			return ev[1]
	return null

func _started(f: Fighter) -> Array:
	var starts: Array = []
	f.combat.attack_started.connect(func(id: StringName) -> void: starts.append([id, TimeDirector.now()]))
	return starts

## Press, hold `secs`, release, and return the HitInfo that landed on `e`.
func _press_for(p: Fighter, e: Fighter, action: int, secs: float) -> HitInfo:
	clear_events()
	await hold_press(p, action, secs)
	await wait_until(func() -> bool: return _hit_on(e) != null, 2.5)
	return _hit_on(e)

func run() -> void:
	var th := Tuning.HOLD_THRESHOLD
	print("tap vs hold at the threshold (%.2f s)" % th)
	var pe: Array = await _lane()
	var info: HitInfo = await _press_for(pe[0], pe[1], L, th - 0.03)
	check(info != null and info.charge_level == 0 and count_events(&"charge_started") == 0,
		"released %.2f s after the press: a normal jab" % (th - 0.03))
	check(info != null and is_equal_approx(info.damage, Power.strike_damage(&"jab", 0)), "tap damage %.1f" % (info.damage if info else -1.0))
	pe = await _lane()
	info = await _press_for(pe[0], pe[1], L, th + 0.03)
	check(count_events(&"charge_started") == 1, "held %.2f s: it charges" % (th + 0.03))
	check(info != null and info.charge_level == 0, "released before level 1 (%.1f s): fires at level 0 (%d)" % [
		Tuning.CHARGE_LEVELS[0], info.charge_level if info else -1])

	print("charge levels (P = base x CHARGE_MULT, damage x CHARGE_MULT)")
	var want_lvl := [1, 2, 3]
	var holds := [Tuning.CHARGE_LEVELS[0] + 0.05, Tuning.CHARGE_LEVELS[1] + 0.05, Tuning.CHARGE_LEVELS[2] + 0.05]
	for i in 3:
		pe = await _lane()
		info = await _press_for(pe[0], pe[1], L, holds[i])
		var lv: int = want_lvl[i]
		check(info != null and info.charge_level == lv, "held %.2f s -> level %d (%d)" % [holds[i], lv, info.charge_level if info else -1])
		if info == null:
			continue
		check(is_equal_approx(info.damage, Power.strike_damage(&"jab", lv)),
			"level %d damage x%.1f (%.1f)" % [lv, Tuning.CHARGE_MULT[lv], info.damage])
		check(is_equal_approx(info.power, Tuning.CHARGE_MULT[lv]) and info.tier == Power.tier_of(info.power),
			"level %d jab: P %.2f, %s" % [lv, info.power, HitInfo.tier_name(info.tier)])
		var lvls: Array = []
		for ev in events:
			if ev[0] == &"charge_level_changed":
				lvls.append(ev[2])
		check(lvls == range(1, lv + 1), "charge_level_changed 1..%d (%s)" % [lv, lvls])

	print("auto-release")
	pe = await _lane()
	var p: Fighter = pe[0]
	clear_events()
	p.combat.press(L)
	var t0 := TimeDirector.now()
	await wait_until(func() -> bool: return count_events(&"charge_released") > 0, 3.0)
	var t_rel := TimeDirector.now() - t0
	check(absf(t_rel - Tuning.CHARGE_AUTO_RELEASE) < 0.05, "released by itself after %.2f s" % t_rel)
	var cr := last_event(&"charge_released")
	check(not cr.is_empty() and cr[3] == 3, "auto-release fires level 3")
	p.combat.release(L)
	await wait_real(0.6)

	print("charge levels count in real time, also in slow motion")
	pe = await _lane()
	p = pe[0]
	clear_events()
	TimeDirector.begin_focus()
	await wait_real(0.1)
	var ts := Engine.time_scale
	p.combat.press(L)
	await wait_real(Tuning.CHARGE_LEVELS[1] + 0.05)
	var lvl_slow := p.combat.get_charge_level()
	p.combat.release(L)
	TimeDirector.end_focus()
	print("  world at x%.2f: held %.2f real s -> level %d" % [ts, Tuning.CHARGE_LEVELS[1] + 0.05, lvl_slow])
	check(ts < 0.5 and lvl_slow == 2, "level 2 after %.2f s of real time in slow motion" % (Tuning.CHARGE_LEVELS[1] + 0.05))
	await wait_real(1.0)

	print("charging adds its hold time on top of the startup")
	pe = await _lane(1.4)
	p = pe[0]
	var act2 := [0.0]
	p.combat.attack_active.connect(func(_id: StringName) -> void: act2[0] = TimeDirector.now())
	p.combat.press(K)
	await wait_real(0.7)
	var t_rel2 := TimeDirector.now()
	p.combat.release(K)
	await wait_until(func() -> bool: return act2[0] > 0.0, 1.0)
	var kick_su := Tuning.frames(Tuning.STRIKE_FRAMES[&"kick"].x)
	print("  released after 0.70 s: active %.3f s later (kick startup %.3f s)" % [act2[0] - t_rel2, kick_su])
	check(absf(act2[0] - t_rel2 - kick_su) < 0.02, "the kick's full startup plays after the release")
	await wait_real(1.0)

	print("walking while charging")
	pe = await _lane(2.5)
	p = pe[0]
	p.combat.press(K)
	await wait_real(0.35)
	check(p.combat.is_charging() and is_equal_approx(p.combat.get_move_speed_mult(), Tuning.CHARGE_WALK_MULT),
		"level 1: walk x%.1f (%.2f)" % [Tuning.CHARGE_WALK_MULT, p.combat.get_move_speed_mult()])
	await wait_real(0.75)
	check(p.combat.get_charge_level() == 3 and is_equal_approx(p.combat.get_move_speed_mult(), Tuning.CHARGE_WALK_MULT),
		"level 3: walk x%.1f" % Tuning.CHARGE_WALK_MULT)
	p.combat.release(K)
	await wait_real(0.8)

	print("a hit cancels the charge (no armour)")
	pe = await _lane(1.2)
	p = pe[0]
	var e: Fighter = pe[1]
	clear_events()
	p.combat.press(L)
	await wait_real(0.2)
	check(p.combat.is_charging(), "charging")
	e.combat.start_enemy_attack(&"e_hook", 0.35)
	await wait_until(func() -> bool: return p.combat.last_result == HitInfo.Result.HIT, 2.0)
	var cr0 := last_event(&"charge_released")
	check(not p.combat.is_charging(), "the hook cancelled the charge")
	check(not cr0.is_empty() and cr0[3] == 0, "an interrupted charge reports charge_released at level 0 (glow off)")
	p.combat.release(L)
	await wait_real(0.8)

	print("block drops a charge; block cancels a basic wind-up")
	pe = await _lane()
	p = pe[0]
	p.combat.press(L)
	await wait_real(0.25)
	p.combat.press(CombatController.Action.BLOCK)
	check(not p.combat.is_charging() and p.combat.is_blocking(), "block dropped the charge")
	p.combat.release(L)
	p.combat.release(CombatController.Action.BLOCK)
	await wait_real(0.5)
	var ended := [false]
	p.combat.attack_ended.connect(func(_id: StringName) -> void: ended[0] = true)
	tap(p, L)
	await ticks(2)
	p.combat.press(CombatController.Action.BLOCK)
	check(ended[0] and not p.combat.is_attacking(), "block cancelled the jab's wind-up")
	p.combat.release(CombatController.Action.BLOCK)
	await wait_real(0.5)

	print("a Dash keeps the charge (Traversal moves; the charge holds)")
	pe = await _lane(3.5)
	p = pe[0]
	clear_events()
	p.combat.press(K)
	await wait_real(0.3)
	p.move_input = Vector3.FORWARD
	p.combat.press(CombatController.Action.DASH)
	await wait_real(0.1)
	p.combat.release(CombatController.Action.DASH)
	check(p.combat.is_charging() and count_events(&"charge_released") == 0, "still charging after the dash")
	p.move_input = Vector3.ZERO
	p.combat.release(K)
	await wait_real(1.0)

	print("a quick tap waits for the release")
	pe = await _lane(1.0)
	p = pe[0]
	var act := [0.0]
	p.combat.attack_active.connect(func(_id: StringName) -> void: act[0] = TimeDirector.now())
	t0 = TimeDirector.now()
	await hold_press(p, L, 0.12)
	await wait_until(func() -> bool: return act[0] > 0.0, 1.0)
	check(act[0] - t0 >= 0.115 and act[0] - t0 < 0.15, "5-frame jab went active %.3f s after the press (released at 0.12)" % (act[0] - t0))
	await wait_real(0.6)

	print("buffer: last BUFFER_FRAMES of recovery only")
	pe = await _lane(1.0, false)
	p = pe[0]
	var started := _started(p)
	tap(p, K)
	var kick := MoveLibrary.get_move(&"sparta_kick")
	await wait_real(Tuning.frames(kick.startup + kick.active + 4.0))
	tap(p, K)  # early in a whiffed kick's recovery: dropped
	await wait_real(Tuning.frames(kick.recovery))
	await wait_real(0.6)
	check(started.size() == 1, "early press in recovery dropped (%d moves)" % started.size())
	started.clear()
	tap(p, K)
	await wait_real(Tuning.frames(kick.startup + kick.active + kick.recovery - 6.0))
	tap(p, K)  # 6 frames before the end: buffered
	await wait_real(0.3)
	check(started.size() == 2 and started[1][0] == &"knee_strike", "buffered press fired the next string move (%s)" % [started])
	if started.size() == 2:
		var gap: float = started[1][1] - started[0][1]
		var full := Tuning.frames(kick.startup + kick.active + kick.recovery)
		check(gap >= full - 0.02 and gap < full + 0.04, "it fired the moment the kick ended (%.3f s, kick %.3f s)" % [gap, full])
	await wait_real(1.0)

	print("string reset after STRING_RESET")
	pe = await _lane(1.0, false)
	p = pe[0]
	started = _started(p)
	tap(p, L)
	var jab := MoveLibrary.get_move(&"jab1")
	await wait_real(Tuning.frames(jab.startup + jab.active + jab.recovery) + Tuning.STRING_RESET - 0.15)
	tap(p, L)
	await wait_real(0.5)
	check(started.size() == 2 and started[1][0] == &"jab2", "Light inside the reset window: the second jab")
	await wait_real(Tuning.STRING_RESET + 0.3)
	tap(p, L)
	await wait_real(0.2)
	check(started.size() == 3 and started[2][0] == &"jab1", "P after the reset: jab1 again (%s)" % [started])

	print("Heavy: its own button, a tapped cross")
	pe = await _lane()
	clear_events()
	tap(pe[0], CombatController.Action.HEAVY)
	await wait_until(func() -> bool: return _hit_on(pe[1]) != null, 1.0)
	info = _hit_on(pe[1])
	check(info != null and info.move_id == &"cross" and info.charge_level == 0 and is_equal_approx(info.power, 2.0),
		"a Heavy tap is a cross at P 2.0")
	print("scripted taps (no PlayerController) never charge")
	_x += 8.0
	var dummy := spawn(&"player", Vector3(_x, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var g := spawn(&"grunt", Vector3(_x, 0, -1.0), Vector3.BACK)
	await ticks(12)
	clear_events()
	dummy.combat.press(L)  # never released
	await wait_until(func() -> bool: return _hit_on(g) != null, 1.0)
	check(_hit_on(g) != null and _hit_on(g).charge_level == 0 and count_events(&"charge_started") == 0,
		"a scripted press is a tap")
	done()
