extends "res://tests/combat/combat_test_base.gd"
## Real-input checks (no doubles): the real player (PlayerController, M's
## Traversal, H's Defence) driven through Input actions.
## - A standing jab tap (90 ms) at 1.6 m and at 2.4 m is P 1.0, a flinch, not a
##   sprint strike: the speed is sampled at the press, before the lunge moves
##   the player (reviewer HIGH 1).
## - A jab at full sprint (Dash held toward the grunt) is P 4.0, a knockdown.
## - Sweep = pull back + Kick: move_back and kick pressed together with a grunt
##   1.2 m in front sweeps it (the sweep picks along the facing; HIGH 2).
## - The heavy's shoulder charge started from 5 m targets the player, so a Dash
##   in the window teleports away and the charge misses (HIGH 3).

const A := CombatController.Action
var _x := 0.0

func _init() -> void:
	_timeout = 120.0

func _release_all() -> void:
	for a in InputMap.get_actions():
		if not String(a).begins_with("ui_"):
			Input.action_release(a)

func _landed_on(f: Fighter) -> HitInfo:
	for e: Array in events:
		if e[0] == &"hit_landed" and (e[1] as HitInfo).victim == f:
			return e[1]
	return null

func _player(at: Vector3) -> Fighter:
	var p := FighterFactory.spawn_player(self, Transform3D(Basis(), at))
	AttackDirector.set_player(p)
	return p

## Press `action` for `secs` of real time, then release.
func _tap_input(action: StringName, secs := 0.09) -> void:
	Input.action_press(action)
	await wait_real(secs)
	Input.action_release(action)

func run() -> void:
	for dist: float in [1.6, 2.4]:
		print("a standing jab tap at %.1f m" % dist)
		_x += 14.0
		var p := _player(Vector3(_x, 0, 0))
		var g := spawn(&"grunt", Vector3(_x, 0, -dist), Vector3.BACK)
		await ticks(40)
		clear_events()
		await _tap_input(&"punch")
		await wait_until(func() -> bool: return _landed_on(g) != null, 1.5)
		var info := _landed_on(g)
		if info != null:
			print("  P %.2f (speed %.2f) tier %s sprint %s" % [info.power, info.speed_bonus, HitInfo.tier_name(info.tier), info.sprint])
		check(info != null and is_equal_approx(info.power, 1.0) and info.tier == HitInfo.Tier.FLINCH and not info.sprint,
			"a standing jab at %.1f m: P 1.0, flinch, not a sprint strike" % dist)
		_release_all()
		await wait_real(0.5)

	print("a jab at full sprint (Dash held)")
	_x += 14.0
	var ps := _player(Vector3(_x, 0, 0))
	var gs := spawn(&"grunt", Vector3(_x, 0, -16.0), Vector3.BACK)
	await ticks(40)
	clear_events()
	Input.action_press(&"move_forward")
	Input.action_press(&"dash")
	var pressed := false
	var t0 := TimeDirector.now()
	while TimeDirector.now() - t0 < 4.0 and _landed_on(gs) == null:
		await get_tree().physics_frame
		var to := gs.get_ground_position() - ps.global_position
		to.y = 0.0
		if not pressed and to.length() < 2.4:
			print("  sprint_charge %.2f, %.2f m/s at the press" % [ps.traversal.sprint_charge, ps.traversal.get_speed()])
			Input.action_press(&"punch")
			pressed = true
			await wait_real(0.09)
			Input.action_release(&"punch")
	_release_all()
	var si := _landed_on(gs)
	if si != null:
		print("  P %.2f (speed %.2f) tier %s sprint %s" % [si.power, si.speed_bonus, HitInfo.tier_name(si.tier), si.sprint])
	check(si != null and is_equal_approx(si.power, 4.0) and si.tier == HitInfo.Tier.KNOCKDOWN and si.sprint,
		"a full-sprint jab: P 4.0, knockdown")
	await wait_real(0.8)

	print("pull back + Kick sweeps the grunt in front")
	_x += 14.0
	var pw := _player(Vector3(_x, 0, 0))
	var gw := spawn(&"grunt", Vector3(_x, 0, -1.2), Vector3.BACK)
	await ticks(40)
	var started: Array = []
	pw.combat.attack_started.connect(func(id: StringName) -> void: started.append(id))
	clear_events()
	Input.action_press(&"move_back")
	Input.action_press(&"kick")
	await wait_real(0.09)
	Input.action_release(&"kick")
	await wait_until(func() -> bool: return _landed_on(gw) != null, 1.5)
	Input.action_release(&"move_back")
	var wi := _landed_on(gw)
	print("  started %s, hit %s" % [started, wi])
	check(not started.is_empty() and started[0] == &"leg_sweep", "S + E is the sweep")
	check(wi != null and wi.move_id == &"leg_sweep" and wi.tier == HitInfo.Tier.STUMBLE, "it hits the grunt in front (a stumble)")
	check(pw.get_forward().dot(Vector3.FORWARD) > 0.9, "the player did not turn round to the back stick")
	_release_all()
	await wait_real(0.8)

	print("the heavy's shoulder charge from 5 m can be teleported")
	_x += 14.0
	var pc := _player(Vector3(_x, 0, 0))
	var hv := spawn(&"heavy", Vector3(_x, 0, -5.0), Vector3.BACK)
	await ticks(40)
	pc.focus = Tuning.TELEPORT_COST
	var tele := [false]
	GameEvents.teleported.connect(func(f: Node3D, _a: Vector3, _b: Vector3, k: StringName) -> void:
		if f == pc and k == &"counter":
			tele[0] = true)
	clear_events()
	var hp0 := pc.hp
	check(hv.combat.start_enemy_attack(&"e_charge", 0.5), "the heavy charges from 5 m")
	check(hv.combat.get_attack_target() == pc, "the charge targets the player")
	await wait_until(func() -> bool: return hv.combat.time_to_active() <= 0.08, 2.0)
	await _tap_input(&"dash", 0.05)
	await wait_until(func() -> bool: return not hv.combat.is_attacking(), 2.0)
	check(tele[0], "a Dash in the window teleported the player")
	check(_landed_on(pc) == null and is_equal_approx(pc.hp, hp0) and not pc.is_down(), "the charge missed")
	_release_all()
	done()
