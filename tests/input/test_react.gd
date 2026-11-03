extends "res://tests/input/input_test_base.gd"
## Round 7 reactions (acceptance 3, agent H): Fighter.react with each player
## move's numbers from Tuning.R7_MOVES (what B passes for a non-heavy victim).
## - snap, spin, fold, buckle, push: the state is reported while it lasts, the
##   fighter cannot act, the slide covers the push (+-20%) and the stun lasts
##   its time (+-0.05 s); pushes from Tuning.R7_PUSH_STEP_FROM step the legs,
##   shorter ones keep the feet planted; a spin turns the body away.
## - lift: a capsule arc (never a ragdoll) to R7_LIFT_HEIGHT in
##   R7_LIFT_PEAK_TIME, loose arms, drift = push, lands into a knockdown
##   (state &"down"); a payoff lift height (1.5 m) is honoured.
## - repop: +R7_REPOP_HEIGHT from where the body is, at most R7_JUGGLE_MAX
##   per lift; the next one is a knockdown at once.
## - the stun stops during the victim's hitstop and runs in the fighter's own
##   time (an enemy's in game time, the player's in real time).
## - a reaction cancels the victim's attack, and it cannot start another.
## Prints every measured number.

const STUN_TOL := 0.05
const PUSH_TOL := 0.2
const STEPS_SPEED := 0.5   ## m/s of leg cycle that counts as stepping
const PLANTED_SPEED := 0.05

var _reacts: Array = []  ## [victim, kind, attacker]

func run() -> void:
	_timeout = 300.0
	GameEvents.react_started.connect(func(f: Node3D, kind: StringName, attacker: Node3D) -> void:
		_reacts.append([f, kind, attacker]))
	var atk := spawn_dummy(&"grunt", Vector3(0, 0, 30), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var v := spawn_dummy(&"grunt", Vector3.ZERO, Vector3.BACK)
	await ticks(40)

	# --- Timed reactions with each move's numbers. ---------------------------------------
	var lane := 0
	for move_id: StringName in [&"jab", &"cross", &"hook", &"heavy_jab", &"heavy_cross",
			&"gut_punch", &"leg_kick", &"front_kick", &"counter"]:
		var row: Dictionary = Tuning.R7_MOVES[move_id]
		var kind: StringName = row["react"]
		var push: float = row["push"]
		var stun: float = row["stun"]
		var m := await _timed(v, atk, Vector3(lane * 4.0, 0, 0), move_id, kind, push, stun)
		lane += 1
		print("  %-11s %-6s push %.2f m (want %.2f), stun %.3f s (want %.2f), can act after %.3f s, legs %.2f m/s, turn %.0f deg"
			% [move_id, kind, m["push"], push, m["stun"], stun, m["act"], m["legs"], m["turn"]])
		check(m["state_ok"], "%s: state &\"%s\" all through the reaction" % [move_id, kind])
		check(m["no_act"], "%s: cannot act while reacting" % move_id)
		check(absf(m["push"] - push) <= push * PUSH_TOL, "%s: push %.2f m within 20%% of %.2f" % [move_id, m["push"], push])
		check(absf(m["stun"] - stun) <= STUN_TOL, "%s: stun %.3f s within 0.05 of %.2f" % [move_id, m["stun"], stun])
		check(absf(m["act"] - stun) <= STUN_TOL, "%s: acts again %.3f s after the hit" % [move_id, m["act"]])
		check(m["event"], "%s: react_started(victim, %s, attacker)" % [move_id, kind])
		if push >= Tuning.R7_PUSH_STEP_FROM:
			check(m["legs"] >= STEPS_SPEED, "%s: a %.1f m push steps (legs %.2f m/s)" % [move_id, push, m["legs"]])
		else:
			check(m["legs"] <= PLANTED_SPEED, "%s: a %.1f m push keeps the feet planted (legs %.2f m/s)" % [move_id, push, m["legs"]])
		if kind == &"spin":
			check(absf(m["turn"] - Fighter.REACT_SPIN_TURN) <= 10.0, "%s: the body turns away %.0f deg (want %.0f)"
				% [move_id, m["turn"], Fighter.REACT_SPIN_TURN])
		check(not m["ragdoll"], "%s: the body stays animated (no ragdoll state)" % move_id)

	# --- Lift: the uppercut's arc. ----------------------------------------------------------
	var up: Dictionary = Tuning.R7_MOVES[&"uppercut"]
	var l1 := await _lift(v, atk, Vector3(-4, 0, 0), up["push"], 0.0)
	var arc := 2.0 * Tuning.R7_LIFT_PEAK_TIME
	print("  uppercut lift: peak %.3f m at %.3f s, landed after %.3f s, drift %.2f m, arm strength %.2f, down after landing: %s"
		% [l1["peak"], l1["t_peak"], l1["air"], l1["drift"], l1["arm"], l1["down"]])
	check(absf(l1["peak"] - Tuning.R7_LIFT_HEIGHT) <= 0.05, "lift peaks %.3f m (want %.1f)" % [l1["peak"], Tuning.R7_LIFT_HEIGHT])
	check(absf(l1["t_peak"] - Tuning.R7_LIFT_PEAK_TIME) <= 0.02, "lift peak at %.3f s (want %.2f)" % [l1["t_peak"], Tuning.R7_LIFT_PEAK_TIME])
	check(absf(l1["air"] - arc) <= STUN_TOL, "lift airtime %.3f s (want %.2f)" % [l1["air"], arc])
	check(absf(l1["drift"] - float(up["push"])) <= float(up["push"]) * PUSH_TOL, "lift drift %.2f m (want %.2f)" % [l1["drift"], up["push"]])
	check(l1["state_ok"] and l1["no_act"], "state &\"lift\" and no acting all through the arc")
	check(l1["capsule"], "the capsule flies the arc: animated, never a ragdoll state, while lifted")
	check(l1["arm"] <= 1.0 - Fighter.LIFT_ARM_LIMP + 0.05, "arms loose during the lift (strength %.2f)" % l1["arm"])
	check(l1["down"], "landing turns into a knockdown (state &\"down\")")
	check(l1["event"], "react_started(victim, lift, attacker)")
	await _recover(v)

	var l2 := await _lift(v, atk, Vector3(-8, 0, 0), 0.0, 1.5)
	print("  high lift (payoff 1.5 m): peak %.3f m at %.3f s" % [l2["peak"], l2["t_peak"]])
	check(absf(l2["peak"] - 1.5) <= 0.05, "info.lift_height 1.5: peak %.3f m" % l2["peak"])
	await _recover(v)

	# --- Re-pop: two per lift, the third is a knockdown. -----------------------------------------
	await _place(v, Vector3(-12, 0, 0))
	_reacts.clear()
	var y0 := v.global_position.y
	v.react(&"lift", Vector3.FORWARD, 0.0, 0.0, _info(v, atk, &"uppercut", &"lift", 0.0, 0.0, 0.0))
	var peaks: Array[float] = []
	for k in 2:
		var pk := await _peak(v, y0)
		peaks.append(pk)
		v.react(&"repop", Vector3.FORWARD, 0.0, 0.0, _info(v, atk, &"jab", &"repop", 0.0, 0.0, 0.0))
	var pk3 := await _peak(v, y0)
	peaks.append(pk3)
	var still_lifted := v.is_lifted() and v.get_react_state() == &"lift" and v.get_repops() == Tuning.R7_JUGGLE_MAX
	v.react(&"repop", Vector3.FORWARD, 0.0, 0.0, _info(v, atk, &"jab", &"repop", 0.0, 0.0, 0.0))
	await ticks(2)
	var capped := v.is_down() and v.get_react_state() == &"down" and not v.is_lifted()
	var kinds: Array = _reacts.map(func(e: Array) -> StringName: return e[1])
	print("  re-pops: peaks %s m (want 1.0, 1.5, 2.0), react_started %s" % [peaks.map(func(x: float) -> String: return "%.3f" % x), kinds])
	check(absf(peaks[0] - 1.0) <= 0.05 and absf(peaks[1] - 1.5) <= 0.05 and absf(peaks[2] - 2.0) <= 0.05,
		"each re-pop adds %.1f m from where the body is" % Tuning.R7_REPOP_HEIGHT)
	check(still_lifted, "after %d re-pops the body is still lifted" % Tuning.R7_JUGGLE_MAX)
	check(capped, "re-pop %d: no re-pop, the body falls into a knockdown" % (Tuning.R7_JUGGLE_MAX + 1))
	check(kinds == [&"lift", &"repop", &"repop"], "react_started: lift, repop, repop (the capped hit is a knockdown)")
	await _recover(v)

	# --- The stun stops during the victim's hitstop. -----------------------------------------------
	var jab: Dictionary = Tuning.R7_MOVES[&"jab"]
	var stop := 0.12
	var hs := await _timed(v, atk, Vector3(-16, 0, 0), &"jab", &"snap", jab["push"], jab["stun"], stop)
	print("  jab with a %.2f s hitstop: stun %.3f s real (want %.2f), push %.2f m, moved during the freeze %.4f m"
		% [stop, hs["stun"], float(jab["stun"]) + stop, hs["push"], hs["frozen_move"]])
	check(absf(hs["stun"] - (float(jab["stun"]) + stop)) <= STUN_TOL, "the stun pauses during the hitstop")
	check(hs["frozen_move"] < 1e-3, "no slide during the hitstop")
	check(absf(hs["push"] - float(jab["push"])) <= float(jab["push"]) * PUSH_TOL, "the push is kept, not lost, after the hitstop")

	# --- Own time: an enemy's stun in game time, the player's in real time. -------------------------
	var p := spawn_player(Vector3(-20, 0, 0))
	await ticks(20)
	TimeDirector.set_process(false)
	Engine.time_scale = 0.5
	var slow_e := await _timed(v, atk, Vector3(-24, 0, 0), &"cross", &"snap", 0.6, 0.5)
	var slow_p := await _timed(p, atk, Vector3(-20, 0, 0), &"cross", &"snap", 0.6, 0.5)
	Engine.time_scale = 1.0
	TimeDirector.set_process(true)
	print("  at 0.5x world time: enemy stun %.3f real s (want 1.00), player stun %.3f real s (want 0.50), pushes %.2f / %.2f m"
		% [slow_e["stun"], slow_p["stun"], slow_e["push"], slow_p["push"]])
	check(absf(slow_e["stun"] - 1.0) <= STUN_TOL * 2.0, "an enemy's stun runs in game time")
	check(absf(slow_p["stun"] - 0.5) <= STUN_TOL, "the player's stun runs in player (real) time")
	check(absf(slow_e["push"] - 0.6) <= 0.6 * PUSH_TOL and absf(slow_p["push"] - 0.6) <= 0.6 * PUSH_TOL, "pushes keep their length in slow motion")
	p.queue_free()
	await ticks(5)

	# --- The aim point follows the upper body (a fold or buckle lowers it). ------------------------
	await _place(v, Vector3(-32, 0, 0))
	var stand_aim := v.get_aim_point().y - v.global_position.y
	var old_aim := v.get_height() * 0.72
	var low := {}
	for kind: StringName in [&"fold", &"buckle"]:
		await _place(v, Vector3(-32, 0, 0))
		v.react(kind, Vector3.FORWARD, 0.0, 1.0, _info(v, atk, &"gut_punch", kind, 0.0, 1.0, 0.0))
		await ticks(40)
		low[kind] = v.get_aim_point().y - v.global_position.y
	print("  aim point height: standing %.2f m (0.72 x height %.2f), fold %.2f m, buckle %.2f m"
		% [stand_aim, old_aim, low[&"fold"], low[&"buckle"]])
	check(absf(stand_aim - old_aim) <= 0.15, "standing, the aim point is at chest height (%.2f m)" % stand_aim)
	check(low[&"fold"] < stand_aim - 0.1 and low[&"buckle"] < stand_aim - 0.1, "a fold and a buckle lower the aim point")

	# --- A reaction cancels the victim's attack; it cannot start another. ---------------------------
	await _place(v, Vector3(-28, 0, 0))
	var started := v.combat.start_enemy_attack(&"e_jab", 0.6)
	await ticks(5)
	var was := v.combat.is_attacking()
	v.react(&"snap", Vector3.FORWARD, 0.4, 0.45, _info(v, atk, &"jab", &"snap", 0.4, 0.45, 0.0))
	await ticks(1)
	var cancelled := not v.combat.is_attacking()
	var again := v.combat.start_enemy_attack(&"e_jab", 0.6)
	check(started and was and cancelled, "a snap cancels the victim's attack in its wind-up")
	check(not again and v.is_in_hitstun(), "a reacting enemy cannot start an attack (in hitstun)")
	await wait_until(func() -> bool: return v.can_act(), 240)
	check(v.combat.start_enemy_attack(&"e_jab", 0.6), "after the stun it attacks again")
	done()

## One timed reaction from a standstill: measured push along the hit, stun
## (react -> not reacting), time to can_act, the fastest leg cycle, the
## largest turn, and whether the state held. `hitstop` freezes the victim right
## after the hit.
func _timed(v: Fighter, atk: Fighter, at: Vector3, move_id: StringName, kind: StringName, push: float,
		stun: float, hitstop := 0.0) -> Dictionary:
	await _place(v, at)
	_reacts.clear()
	var dir := Vector3.FORWARD
	var p0 := v.global_position
	var yaw0 := v.rotation.y
	var t0 := TimeDirector.now()
	v.react(kind, dir, push, stun, _info(v, atk, move_id, kind, push, stun, 0.0))
	if hitstop > 0.0:
		TimeDirector.hitstop([v], hitstop)
	var state_ok := true
	var no_act := true
	var ragdoll := false
	var legs := 0.0
	var turn := 0.0
	var frozen_move := 0.0
	var t_end := -1.0
	var t_act := -1.0
	for i in 600:
		await get_tree().physics_frame
		var reacting := v.is_reacting()
		if reacting:
			state_ok = state_ok and v.get_react_state() == kind
			no_act = no_act and not v.can_act()
			legs = maxf(legs, v.animator.get_locomotion_speed())
			turn = maxf(turn, rad_to_deg(absf(angle_difference(yaw0, v.rotation.y))))
		ragdoll = ragdoll or v.get_state() != RagdollController.State.ANIMATED
		if v.is_frozen():
			frozen_move = maxf(frozen_move, Vector2(v.global_position.x - p0.x, v.global_position.z - p0.z).length())
		if t_end < 0.0 and not reacting:
			t_end = TimeDirector.now()
		if t_act < 0.0 and v.can_act():
			t_act = TimeDirector.now()
		if t_end >= 0.0 and t_act >= 0.0:
			break
	await ticks(10)
	var d := (v.global_position - p0).dot(dir)
	var ev := false
	for e: Array in _reacts:
		ev = ev or (e[0] == v and e[1] == kind and e[2] == atk)
	return {"push": d, "stun": t_end - t0, "act": t_act - t0, "state_ok": state_ok, "no_act": no_act,
		"legs": legs, "turn": turn, "ragdoll": ragdoll, "frozen_move": frozen_move, "event": ev and _reacts.size() == 1}

## One lift from a standstill: peak, time to the peak, time to land (state
## &"down"), drift along the hit, the weakest arm strength, and the checks.
func _lift(v: Fighter, atk: Fighter, at: Vector3, push: float, height: float) -> Dictionary:
	await _place(v, at)
	_reacts.clear()
	var dir := Vector3.FORWARD
	var p0 := v.global_position
	var t0 := TimeDirector.now()
	v.react(&"lift", dir, push, 0.0, _info(v, atk, &"uppercut", &"lift", push, 0.0, height))
	var peak := 0.0
	var t_peak := 0.0
	var arm := 1.0
	var state_ok := true
	var no_act := true
	var capsule := true
	var t_land := -1.0
	var drift := 0.0
	for i in 400:
		await get_tree().physics_frame
		if v.is_lifted():
			var h := v.global_position.y - p0.y
			if h > peak:
				peak = h
				t_peak = TimeDirector.now() - t0
			arm = minf(arm, minf(v.ragdoll.get_bone_strength(Bones.L_UPPER_ARM), v.ragdoll.get_bone_strength(Bones.R_UPPER_ARM)))
			state_ok = state_ok and v.get_react_state() == &"lift"
			no_act = no_act and not v.can_act()
			capsule = capsule and v.get_state() == RagdollController.State.ANIMATED and not v.is_body_simulating()
			drift = (v.global_position - p0).dot(dir)
		elif t_land < 0.0:
			t_land = TimeDirector.now() - t0
			break
	await ticks(2)
	var down := v.is_down() and v.get_react_state() == &"down"
	var ev: bool = _reacts.size() == 1 and _reacts[0][0] == v and _reacts[0][1] == &"lift" and _reacts[0][2] == atk
	return {"peak": peak, "t_peak": t_peak, "air": t_land, "drift": drift, "arm": arm, "state_ok": state_ok,
		"no_act": no_act, "capsule": capsule, "down": down, "event": ev}

## Height of the next peak of a lifted body above `y0` (waits for it).
func _peak(v: Fighter, y0: float) -> float:
	var best := v.global_position.y - y0
	for i in 200:
		await get_tree().physics_frame
		if not v.is_lifted():
			break
		var h := v.global_position.y - y0
		if h < best - 1e-4:
			break
		best = maxf(best, h)
	return best

func _info(v: Fighter, atk: Fighter, move_id: StringName, kind: StringName, push: float, stun: float, lift: float) -> HitInfo:
	var info := HitInfo.new()
	info.attacker = atk
	info.victim = v
	info.move_id = move_id
	info.kind = &"strike"
	info.react = kind
	info.push = push
	info.stun = stun
	info.lift_height = lift
	info.hit_bone = Bones.CHEST
	info.hit_direction = Vector3.FORWARD
	info.hit_position = v.get_aim_point()
	return info

## Standing still at `at`, facing back along the hit (+Z), nothing running.
func _place(v: Fighter, at: Vector3) -> void:
	await _recover(v)
	v.clear_react()
	v.teleport_to(at, Vector3.BACK)
	await ticks(15)

func _recover(v: Fighter) -> void:
	if v.ragdoll.is_simulating() or v.get_state() != RagdollController.State.ANIMATED:
		v.ragdoll.force_recover()
	v.combat.cancel()
	await ticks(3)
