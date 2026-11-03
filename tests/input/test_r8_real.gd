extends "res://tests/input/input_test_base.gd"
## Round 8 through B's real strikes and real input (agent H, with B's
## CombatController and M's Traversal; Input.action_press / key events ->
## PlayerController -> InputInterpreter):
## - Punch taps on a level-1 grunt flinch it and break its pressure; the break
##   shows as state &"broken" (no acting) while combat.is_broken(); a gut punch
##   tap on the dazed grunt plays the quick fold and the daze comes back; B's
##   break is never ended early and the daze ends with it.
## - A fully charged leg kick sweeps: down at once, the legs thrown up.
## - E held to a full charge and let go: the uppercut lifts a grunt
##   Tuning.R8_MOVES uppercut lift.y (+-0.15 m). Space pressed during its active frames or hitstop
##   is kept: the launcher jump starts as soon as the active frames end and
##   reaches the body's height. Then 4 air punches each hang the player and the
##   body Tuning.R8_AIR_HANG (+-0.03 s, from the hit), the 5th does not hang.
## Prints every measured number.

const TICK := 1.0 / 120.0
const HANG_TOL := 0.03
const FULL_HOLD := 1.1  ## s a strike button is held: past debug_charge_full (c = 1), before the auto-fire

var _reacts: Array = []   ## [victim, kind, real time]
var _hits: Array[HitInfo] = []
var _air: Array = []      ## [count, real time]
var _follow_t := -1.0

func run() -> void:
	_timeout = 200.0
	Tuning.debug_charge_full = 1.0
	Tuning.debug_air_hits = 4
	GameEvents.react_started.connect(func(f: Node3D, kind: StringName, _a: Node3D) -> void:
		_reacts.append([f, kind, TimeDirector.now()]))
	GameEvents.hit_landed.connect(func(info: HitInfo) -> void: _hits.append(info))
	GameEvents.air_hit.connect(func(_a: Node3D, _v: Node3D, count: int) -> void: _air.append([count, TimeDirector.now()]))
	GameEvents.air_follow_started.connect(func(_f: Node3D, _t: Node3D) -> void: _follow_t = TimeDirector.now())
	var p := spawn_player(Vector3.ZERO)
	await ticks(40)
	await _break_suite(p)
	await _sweep_suite(p)
	await _air_suite(p)
	done()

# --- Pressure break and the daze ----------------------------------------------------------------
func _break_suite(p: Fighter) -> void:
	var v := await _victim(p, Vector3(0, 0, 0))
	_reacts.clear()
	var taps := 0
	var kinds: Array[StringName] = []
	while not v.combat.is_broken() and taps < 6:
		await _tap(p, &"punch")
		taps += 1
		await wait_until(func() -> bool: return v.combat.is_broken() or (p.can_act() and not p.combat.is_attacking()), 240)
	for e: Array in _reacts:
		if e[0] == v:
			kinds.append(e[1])
	var broke := v.combat.is_broken()
	var t_break := TimeDirector.now() - (Tuning.R8_BREAK_TIME - v.combat.get_broken_time_left())
	var state_ok := true
	var no_act := true
	await wait_until(func() -> bool: return v.get_react_state() == &"broken", 120)
	var dazed := v.get_react_state() == &"broken"
	# A gut punch tap on the dazed grunt: the quick fold, then the daze again.
	await _until(t_break + 0.5)
	await wait_until(func() -> bool: return p.can_act() and not p.combat.is_attacking(), 120)
	_reacts.clear()
	await _tap(p, &"gut_punch")
	var seq: Array[StringName] = []
	var b_end := -1.0
	var d_end := -1.0
	for i in 400:
		var k := v.get_react_state()
		if k != &"" and (seq.is_empty() or seq[-1] != k):
			seq.append(k)
		if k != &"":
			no_act = no_act and not v.can_act()
		if b_end < 0.0 and not v.combat.is_broken():
			b_end = TimeDirector.now()
		if d_end < 0.0 and not seq.is_empty() and k == &"":
			d_end = TimeDirector.now()
		if b_end >= 0.0 and d_end >= 0.0:
			break
		state_ok = state_ok and (not v.combat.is_broken() or k != &"")
		await get_tree().physics_frame
	print("  %d punch taps: reactions %s, broken %s, dazed %s; gut punch tap on top: states %s; B's break over %.3f s after it began (want %.2f), the daze %.3f s"
		% [taps, kinds, broke, dazed, seq, b_end - t_break, Tuning.R8_BREAK_TIME, d_end - t_break])
	check(not kinds.is_empty() and kinds[0] == &"flinch", "a punch tap flinches the grunt (%s)" % [kinds])
	check(broke and dazed, "pressure breaks it: state &\"broken\"")
	var fi := seq.find(&"fold")
	check(fi >= 0 and fi + 1 < seq.size() and seq[fi + 1] == &"broken", "a gut punch tap on top: the fold, then the daze again (%s)" % [seq])
	check(b_end - t_break >= Tuning.R8_BREAK_TIME - 0.05 and b_end - t_break <= Tuning.R8_BREAK_TIME + 0.25,
		"B's break is not ended early by the fold on top (%.3f s; B's clock pauses in hitstop)" % [b_end - t_break])
	check(state_ok and no_act and absf(d_end - b_end) <= 2.0 * TICK + 1e-4, "dazed and unable to act while B says broken; the daze ends with it")
	v.queue_free()
	await ticks(10)

# --- Charged sweep -------------------------------------------------------------------------------
func _sweep_suite(p: Fighter) -> void:
	var v := await _victim(p, Vector3(8, 0, 0))
	_reacts.clear()
	_hits.clear()
	await _hold(p, &"leg_kick", FULL_HOLD)
	var got := await wait_until(func() -> bool: return _reacted(v, &"sweep") >= 0.0, 180)
	var down := v.is_down() and v.get_react_state() == &"down"
	var feet := 0.0
	for i in 72:
		feet = maxf(feet, maxf(v.rig.get_bone_global_position(Bones.L_FOOT).y, v.rig.get_bone_global_position(Bones.R_FOOT).y))
		await get_tree().physics_frame
	var info := _hit_on(v)
	print("  attacker %.2f m from the swept body" % (p.global_position - v.get_ground_position()).length())
	print("  charged leg kick: hit %s (charged %s, c %.2f, react %s), down %s, feet up %.2f m"
		% [info.move_id if info else &"?", info.charged if info else false, info.charge if info else -1.0,
		info.react if info else &"?", down, feet])
	check(got and info != null and info.charged and info.react == &"sweep", "a full leg kick charge sweeps")
	check(down and feet >= 0.4, "the sweep: down at once, the legs thrown up (%.2f m)" % feet)
	v.queue_free()
	await ticks(10)

# --- Charged uppercut, launcher jump, air combo ---------------------------------------------------
func _air_suite(p: Fighter) -> void:
	var v := await _victim(p, Vector3(16, 0, 0))
	var y_floor := v.global_position.y
	var want_lift: float = (Tuning.R8_MOVES[&"uppercut"]["charged"]["lift"] as Vector2).y
	_reacts.clear()
	_hits.clear()
	_air.clear()
	_follow_t = -1.0
	# The E key held to full charge, then let go (key events, as a player would).
	_key(KEY_E, true)
	await ticks(int(round(FULL_HOLD * 120.0)))
	_key(KEY_E, false)
	await wait_until(func() -> bool: return _reacted(v, &"lift") >= 0.0, 180)
	# Space on the hit: the uppercut's active frames or hitstop.
	var in_active := p.combat.is_attack_active() or p.is_frozen()
	_key(KEY_SPACE, true)
	var last_active := TimeDirector.now() if p.combat.is_attack_active() else -1.0
	var peak := 0.0
	for i in 90:
		await get_tree().physics_frame
		if i == 1:
			_key(KEY_SPACE, false)
		if p.combat.is_attack_active():
			last_active = TimeDirector.now()
		peak = maxf(peak, v.global_position.y - y_floor)
		if _follow_t >= 0.0 and not p.traversal.is_air_following():
			break
	var gap := (p.global_position.y - v.global_position.y)
	var start_lag := _follow_t - last_active if _follow_t >= 0.0 and last_active >= 0.0 else -1.0
	await wait_until(func() -> bool: return v.velocity.y <= 0.0 or not v.is_lifted(), 60)
	peak = maxf(peak, v.global_position.y - y_floor)
	var info := _hit_on(v)
	print("  charged uppercut: c %.2f, lift %.2f m (info %.2f, want %.2f); Space during active/hitstop %s, leap %.3f s after the last active frame, ends %.2f m from the body's height"
		% [info.charge if info else -1.0, peak, info.lift_height if info else -1.0, want_lift, in_active, start_lag, gap])
	check(info != null and info.charged and absf(peak - want_lift) <= 0.15, "a full uppercut charge lifts %.2f m (want %.2f)" % [peak, want_lift])
	check(in_active, "Space was pressed during the uppercut's active frames or hitstop")
	check(_follow_t >= 0.0 and start_lag >= 0.0 and start_lag <= 3.0 * TICK + 1e-4, "the kept press leaps as soon as the active frames end (%.3f s)" % start_lag)
	check(absf(gap) <= 0.35, "the launcher jump reaches the body's height (%.2f m off)" % gap)

	# Air punches: 4 hang both, the 5th does not.
	var holds_b: Array[float] = []
	var holds_p: Array[float] = []
	for k in 5:
		var n0 := _air.size()
		await _tap(p, &"punch")
		var hit := await wait_until(func() -> bool: return _air.size() > n0, 60)
		if not hit:
			break
		var yb := v.global_position.y
		var yp := p.global_position.y
		var nb := -1
		var np := -1
		for i in 70:
			await get_tree().physics_frame
			if nb < 0 and absf(v.global_position.y - yb) > 1e-4:
				nb = i
			if np < 0 and absf(p.global_position.y - yp) > 1e-4:
				np = i
			if nb >= 0 and np >= 0:
				break
		holds_b.append(maxf(nb, 0) * TICK if nb >= 0 else 70 * TICK)
		holds_p.append(maxf(np, 0) * TICK if np >= 0 else 70 * TICK)
	var fmt := func(a: Array[float]) -> Array: return a.map(func(x: float) -> String: return "%.3f" % x)
	print("  air punches: %d hits, body held %s s, player held %s s (want %.2f for the first %d)"
		% [_air.size(), fmt.call(holds_b), fmt.call(holds_p), Tuning.R8_AIR_HANG, Tuning.debug_air_hits])
	check(holds_b.size() == 5, "5 air punches land (%d)" % holds_b.size())
	if holds_b.size() == 5:
		for k in 4:
			check(absf(holds_b[k] - Tuning.R8_AIR_HANG) <= HANG_TOL and absf(holds_p[k] - Tuning.R8_AIR_HANG) <= HANG_TOL,
				"air hit %d hangs the body %.3f s and the player %.3f s" % [k + 1, holds_b[k], holds_p[k]])
		check(holds_b[4] < Tuning.R8_AIR_HANG - 0.1 and holds_p[4] < Tuning.R8_AIR_HANG - 0.1,
			"air hit 5 does not hang (body %.3f s, player %.3f s)" % [holds_b[4], holds_p[4]])
	await wait_until(func() -> bool: return not v.is_lifted() and not p.is_airborne(), 600)
	v.queue_free()
	await ticks(10)

# --- Helpers ---------------------------------------------------------------------------------
## A fresh grunt 1.2 m in front of the player, who stands at `at` facing it.
func _victim(p: Fighter, at: Vector3) -> Fighter:
	await wait_until(func() -> bool: return p.can_act() and not p.combat.is_attacking() and not p.is_airborne(), 600)
	p.teleport_to(at, Vector3.FORWARD)
	var v := spawn_dummy(&"grunt", at + Vector3(0, 0, -1.2), Vector3.BACK)
	await ticks(30)
	return v

func _tap(_p: Fighter, action: StringName) -> void:
	press(action)
	await ticks(1)
	release(action)
	await ticks(1)

func _hold(_p: Fighter, action: StringName, seconds: float) -> void:
	press(action)
	await ticks(int(round(seconds * 120.0)))
	release(action)

## Real time of the first react_started(v, kind) since the last clear (-1 if none).
func _reacted(v: Fighter, kind: StringName) -> float:
	for e: Array in _reacts:
		if e[0] == v and e[1] == kind:
			return e[2]
	return -1.0

func _hit_on(v: Fighter) -> HitInfo:
	for i in range(_hits.size() - 1, -1, -1):
		if _hits[i].victim == v:
			return _hits[i]
	return null

func _until(t: float) -> void:
	while TimeDirector.now() < t - 1e-6:
		await get_tree().physics_frame

## A key event (Controls binds by physical keycode: Space = jump, E = uppercut).
func _key(key: Key, down: bool) -> void:
	var e := InputEventKey.new()
	e.keycode = key
	e.physical_keycode = key
	e.pressed = down
	Input.parse_input_event(e)
