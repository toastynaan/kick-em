extends "res://tests/input/input_test_base.gd"
## Round 8 reactions (agent H, docs/Round 8 — Charge and Pressure.md), through
## Fighter.react with the numbers B passes (Tuning.R8_MOVES):
## - flinch (jab, cross and leg kick taps): state &"flinch" while it lasts, the
##   stun (+-0.05 s) and push (+-20%), a physical hit on the struck bone only
##   (that chain goes Tuning.REACT_FLINCH physical, the bone is kicked along
##   the hit, everything else stays animated, never a ragdoll state); a wind-up
##   is interrupted and the enemy starts an attack again within 0.4 s; a
##   walking enemy walks on right after.
## - sweep: reports &"down" at once; the legs are thrown up (feet well off the
##   floor, before the hips are down) and the body ends on its back, with the
##   attacker standing 0.9 m in front; a plain knockdown keeps its feet low.
## - broken: state &"broken" for the break (+-0.05 s), no acting, the daze pose,
##   the wind-up stopped; a fold on top plays, then the daze comes back until
##   the break's end (the clock kept running); a flinch on top keeps the daze; a
##   lift on top lands into a knockdown and the daze comes back once the body is
##   up; once CombatController reports the break, its time is the status.
## - fold: a short fold (the tap's 0.3 s) is a quick half-keel back up by the
##   end of its stun; the charged fold is the full keel.
## - lift: info.lift_height 0.8 m and 2.5 m peak within 0.15 m, land into a
##   knockdown and come to rest on the floor.
## Prints every measured number.

const STUN_TOL := 0.05
const PUSH_TOL := 0.2
const LIFT_TOL := 0.15
const HIPS_UP := 0.6   ## m: the body counts as not yet down while its hips are above this
const SWEEP_ATTACKER_GAP := 0.9  ## m: the attacker's capsule in front of the swept body (a leg kick's range)
const DOUBLE := preload("res://tests/input/broken_double.gd")

var _reacts: Array = []  ## [victim, kind, attacker]

func run() -> void:
	_timeout = 400.0
	GameEvents.react_started.connect(func(f: Node3D, kind: StringName, attacker: Node3D) -> void:
		_reacts.append([f, kind, attacker]))
	var atk := spawn_dummy(&"grunt", Vector3(0, 0, 40), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var v := spawn_dummy(&"grunt", Vector3.ZERO, Vector3.BACK)
	await ticks(40)
	await _flinch_suite(v, atk)
	await _sweep_suite(v, atk)
	await _broken_suite(v, atk)
	await _fold_suite(v, atk)
	await _lift_suite(v, atk)
	done()

# --- Flinch ---------------------------------------------------------------------------------
func _flinch_suite(v: Fighter, atk: Fighter) -> void:
	var lane := 0
	for c: Array in [[&"jab", Bones.HEAD], [&"cross", Bones.CHEST], [&"leg_kick", Bones.L_LOWER_LEG]]:
		var move_id: StringName = c[0]
		var bone: StringName = c[1]
		var tap: Dictionary = Tuning.R8_MOVES[move_id]["tap"]
		check(tap["react"] == &"flinch", "%s tap is a flinch in Tuning.R8_MOVES" % move_id)
		var push: float = tap["push"]
		var stun: float = tap["stun"]
		await _place(v, Vector3(lane * 4.0, 0, 0))
		lane += 1
		_reacts.clear()
		var dir := Vector3.FORWARD
		var p0 := v.global_position
		var base := _bone_offset(v, bone, dir)
		var t0 := TimeDirector.now()
		v.react(&"flinch", dir, push, stun, _info(v, atk, move_id, &"flinch", push, stun, 0.0, bone))
		var pose := v.animator.get_current_move()
		var state_ok := true
		var no_act := true
		var animated := true
		var chain_min := 1.0
		var other_min := 1.0
		var kick := 0.0
		var t_end := -1.0
		var t_act := -1.0
		var other: StringName = Bones.R_LOWER_LEG if bone != Bones.R_LOWER_LEG and bone != Bones.L_LOWER_LEG else Bones.HEAD
		for i in 120:
			await get_tree().physics_frame
			var reacting := v.is_reacting()
			if reacting:
				state_ok = state_ok and v.get_react_state() == &"flinch"
				no_act = no_act and not v.can_act()
			animated = animated and v.get_state() == RagdollController.State.ANIMATED and not v.is_body_simulating()
			chain_min = minf(chain_min, v.ragdoll.get_bone_strength(bone))
			other_min = minf(other_min, v.ragdoll.get_bone_strength(other))
			kick = maxf(kick, _bone_offset(v, bone, dir) - base)
			if t_end < 0.0 and not reacting:
				t_end = TimeDirector.now()
			if t_act < 0.0 and v.can_act():
				t_act = TimeDirector.now()
			if t_end >= 0.0 and t_act >= 0.0 and i > 40:
				break
		var d := (v.global_position - p0).dot(dir)
		var want_strength := 1.0 - float(Tuning.REACT_FLINCH["physics"])
		print("  %-8s flinch on %-12s push %.2f m (want %.2f), stun %.3f s (want %.2f), acts after %.3f s, struck chain strength %.2f, %s strength %.2f, bone kicked %.3f m along the hit"
			% [move_id, bone, d, push, t_end - t0, stun, t_act - t0, chain_min, other, other_min, kick])
		check(state_ok and no_act, "%s: state &\"flinch\", no acting while it lasts" % move_id)
		check(absf((t_end - t0) - stun) <= STUN_TOL, "%s: flinch stun %.3f s (want %.2f)" % [move_id, t_end - t0, stun])
		check(absf((t_act - t0) - stun) <= STUN_TOL, "%s: acts again %.3f s after the hit" % [move_id, t_act - t0])
		check(absf(d - push) <= push * PUSH_TOL, "%s: push %.2f m (want %.2f)" % [move_id, d, push])
		check(chain_min <= want_strength + 0.05, "%s: the struck bone goes physical (strength %.2f)" % [move_id, chain_min])
		check(other_min >= 0.99, "%s: the rest of the body stays animated (%s %.2f)" % [move_id, other, other_min])
		check(kick >= 0.02, "%s: the struck bone is kicked along the hit (%.3f m)" % [move_id, kick])
		check(animated, "%s: never a ragdoll state (the fighter keeps control)" % move_id)
		check(pose == &"react_flinch", "%s: plays P's react_flinch over the stun (%s)" % [move_id, pose])
		check(_reacts.size() == 1 and _reacts[0][1] == &"flinch" and _reacts[0][2] == atk, "%s: react_started(victim, flinch, attacker)" % move_id)

	# A tap interrupts a wind-up; the enemy attacks again within 0.4 s.
	var tap: Dictionary = Tuning.R8_MOVES[&"jab"]["tap"]
	await _place(v, Vector3(-4, 0, 0))
	var started := v.combat.start_enemy_attack(&"e_jab", 0.6)
	await ticks(10)
	var winding := v.combat.is_attacking()
	var t0 := TimeDirector.now()
	v.react(&"flinch", Vector3.FORWARD, tap["push"], tap["stun"], _info(v, atk, &"jab", &"flinch", tap["push"], tap["stun"], 0.0, Bones.HEAD))
	await ticks(1)
	var cut := not v.combat.is_attacking()
	var again := -1.0
	for i in 120:
		if v.combat.start_enemy_attack(&"e_jab", 0.6):
			again = TimeDirector.now() - t0
			break
		await get_tree().physics_frame
	print("  wind-up interrupted: %s, attacks again %.3f s after the tap" % [cut, again])
	check(started and winding and cut, "a flinch stops the enemy's wind-up")
	check(again >= 0.0 and again <= 0.4, "the flinched enemy starts an attack within 0.4 s (%.3f s)" % again)
	await ticks(5)
	v.combat.cancel()

	# A walking enemy walks on right after the flinch.
	await _place(v, Vector3(-8, 0, 0))
	v.move_input = Vector3.BACK  # toward its facing (+Z)
	await ticks(60)
	var walk := _hspeed(v)
	t0 = TimeDirector.now()
	v.react(&"flinch", Vector3.FORWARD, tap["push"], tap["stun"], _info(v, atk, &"jab", &"flinch", tap["push"], tap["stun"], 0.0, Bones.HEAD))
	var back := -1.0
	for i in 120:
		await get_tree().physics_frame
		if not v.is_reacting() and v.velocity.dot(Vector3.BACK) >= walk * 0.8:
			back = TimeDirector.now() - t0
			break
	v.move_input = Vector3.ZERO
	print("  walking %.2f m/s: back to 80%% of it %.3f s after the flinch (stun %.2f)" % [walk, back, tap["stun"]])
	check(walk > 1.0 and back >= 0.0 and back <= float(tap["stun"]) + 0.15, "a flinched enemy walks on right after (%.3f s)" % back)
	await ticks(20)

# --- Sweep ---------------------------------------------------------------------------------
func _sweep_suite(v: Fighter, atk: Fighter) -> void:
	var sw := await _fall(v, atk, Vector3(12, 0, 0), true)
	var kd := await _fall(v, atk, Vector3(16, 0, 0), false)
	print("  sweep: down at once %s, feet up %.2f m (%.2f m while the hips are still above %.2f m), hips down at %.3f s, chest facing up %.2f, hips moved %.2f m back; plain knockdown: feet up %.2f m (%.2f m while the hips are up), chest up %.2f"
		% [sw["down_now"], sw["feet"], sw["early"], HIPS_UP, sw["t_hips"], sw["chest_up"], sw["back"], kd["feet"], kd["early"], kd["chest_up"]])
	check(sw["down_now"], "sweep reports &\"down\" at once (a knockdown)")
	check(sw["feet"] >= 0.5 and sw["feet"] >= kd["feet"] + 0.2, "sweep: the legs are taken out, feet %.2f m up (a plain knockdown %.2f m)" % [sw["feet"], kd["feet"]])
	check(sw["early"] >= 0.3 and sw["early"] >= kd["early"] + 0.15, "sweep: legs first, feet %.2f m up while the hips are still up (a plain knockdown %.2f m)" % [sw["early"], kd["early"]])
	check(sw["chest_up"] >= 0.5, "sweep: the body ends on its back (chest facing up %.2f)" % sw["chest_up"])
	check(sw["event"], "react_started(victim, sweep, attacker)")

## A sweep (or a plain knockdown along the hit) from a standstill facing the
## attacker: feet height peak (overall, and while the hips are still above
## HIPS_UP: legs first), when the hips get low, how much the
## chest faces up once lying, how far back the hips went.
func _fall(v: Fighter, atk: Fighter, at: Vector3, sweep: bool) -> Dictionary:
	await _place(v, at)
	# The attacker stands where the leg kick lands from (bones collide with capsules).
	var atk_home := atk.global_position
	atk.teleport_to(at + Vector3(0, 0, SWEEP_ATTACKER_GAP), Vector3.FORWARD)
	await ticks(2)
	_reacts.clear()
	var dir := Vector3.FORWARD
	var fwd := v.get_forward()
	var hips0 := v.rig.get_bone_global_position(Bones.HIPS)
	var t0 := TimeDirector.now()
	if sweep:
		v.react(&"sweep", dir, 0.3, 0.0, _info(v, atk, &"heavy_leg_kick", &"sweep", 0.3, 0.0, 0.0, Bones.L_LOWER_LEG))
	else:
		v.knockdown(dir, Bones.CHEST)
	var down_now := v.is_down() and v.get_react_state() == &"down"
	var feet := 0.0
	var early := 0.0
	var t_hips := -1.0
	var chest_up := -1.0
	var hips_end := hips0
	for i in 150:
		await get_tree().physics_frame
		var f := maxf(v.rig.get_bone_global_position(Bones.L_FOOT).y, v.rig.get_bone_global_position(Bones.R_FOOT).y)
		feet = maxf(feet, f)
		var hy := v.rig.get_bone_global_position(Bones.HIPS).y
		if hy > HIPS_UP:
			early = maxf(early, f)
		if t_hips < 0.0 and hy < 0.35:
			t_hips = TimeDirector.now() - t0
		chest_up = (-v.rig.get_bone_global_transform(Bones.CHEST).basis.z).y
		hips_end = v.rig.get_bone_global_position(Bones.HIPS)
	var ev: bool = sweep and _reacts.size() == 1 and _reacts[0][1] == &"sweep" and _reacts[0][2] == atk
	atk.teleport_to(atk_home, Vector3.FORWARD)
	await _recover(v)
	return {"down_now": down_now, "feet": feet, "early": early, "t_hips": t_hips if t_hips >= 0.0 else 99.0,
		"chest_up": chest_up, "back": (hips_end - hips0).dot(-fwd), "event": ev}

# --- Broken ---------------------------------------------------------------------------------
func _broken_suite(v: Fighter, atk: Fighter) -> void:
	var bt := Tuning.R8_BREAK_TIME
	var want_hold := _daze_id()
	# A plain break on a free body, with its wind-up running.
	await _place(v, Vector3(20, 0, 0))
	_reacts.clear()
	var started := v.combat.start_enemy_attack(&"e_jab", 0.6)
	await ticks(10)
	var t0 := TimeDirector.now()
	v.react(&"broken", Vector3.FORWARD, 0.0, bt, _info(v, atk, &"jab", &"broken", 0.0, bt, 0.0, Bones.HEAD))
	await ticks(1)
	var cut := started and not v.combat.is_attacking()
	var hold := v.animator.get_hold_id()
	var m := await _watch(v, &"broken", 400)
	print("  broken: %.3f s (want %.2f), acts after %.3f s, daze hold %s (want %s), wind-up stopped %s"
		% [m["end"] - t0, bt, m["act"] - t0, hold, want_hold, cut])
	check(m["state_ok"] and m["no_act"], "broken: state &\"broken\" and no acting all through")
	check(absf(m["end"] - t0 - bt) <= STUN_TOL, "broken lasts %.3f s (want %.2f)" % [m["end"] - t0, bt])
	check(absf(m["act"] - t0 - bt) <= STUN_TOL, "broken: acts again %.3f s after the break" % [m["act"] - t0])
	check(hold == want_hold, "broken: plays the daze (%s)" % hold)
	check(cut, "broken: the wind-up stops")
	check(_reacts.size() == 1 and _reacts[0][1] == &"broken", "react_started(victim, broken, attacker)")
	check(m["animated"], "broken: the body stays animated (no ragdoll state)")

	# A fold on top: it plays, then the daze comes back until the break's end.
	var fold: Dictionary = Tuning.R8_MOVES[&"gut_punch"]["charged"]
	var fold_stun: float = (fold["stun"] as Vector2).x
	await _place(v, Vector3(24, 0, 0))
	t0 = TimeDirector.now()
	v.react(&"broken", Vector3.FORWARD, 0.0, bt, _info(v, atk, &"jab", &"broken", 0.0, bt, 0.0, Bones.HEAD))
	await _until(t0 + 0.3)
	var t_fold := TimeDirector.now()
	v.react(&"fold", Vector3.FORWARD, 0.3, fold_stun, _info(v, atk, &"heavy_gut_punch", &"fold", 0.3, fold_stun, 0.0, Bones.CHEST))
	var seq := await _sequence(v, 400)
	print("  fold on a broken body: states %s, fold %.3f s (want %.2f), back to broken at %.3f s, break over at %.3f s (want %.2f)"
		% [seq["kinds"], seq["t"][1] - t_fold if seq["t"].size() > 1 else -1.0, fold_stun,
		seq["t"][1] - t0 if seq["t"].size() > 1 else -1.0, seq["end"] - t0, bt])
	check(seq["kinds"] == [&"fold", &"broken"], "fold on a broken body: fold, then broken again (%s)" % [seq["kinds"]])
	check(seq["t"].size() > 1 and absf(seq["t"][1] - t_fold - fold_stun) <= STUN_TOL, "the fold plays its full stun on top")
	check(absf(seq["end"] - t0 - bt) <= STUN_TOL, "the break's clock kept running under the fold (over at %.3f s)" % [seq["end"] - t0])

	# A flinch on top: the daze stays, the struck bone still goes physical.
	var tap: Dictionary = Tuning.R8_MOVES[&"jab"]["tap"]
	await _place(v, Vector3(28, 0, 0))
	t0 = TimeDirector.now()
	v.react(&"broken", Vector3.FORWARD, 0.0, bt, _info(v, atk, &"jab", &"broken", 0.0, bt, 0.0, Bones.HEAD))
	await _until(t0 + 0.3)
	var p0 := v.global_position
	v.react(&"flinch", Vector3.FORWARD, tap["push"], tap["stun"], _info(v, atk, &"jab", &"flinch", tap["push"], tap["stun"], 0.0, Bones.HEAD))
	var strength := 1.0
	var kept := true
	for i in 40:
		await get_tree().physics_frame
		strength = minf(strength, v.ragdoll.get_bone_strength(Bones.HEAD))
		kept = kept and v.get_react_state() == &"broken" and v.animator.get_hold_id() == want_hold
	var slid := (v.global_position - p0).dot(Vector3.FORWARD)
	var rest := await _watch(v, &"broken", 400)
	print("  flinch on a broken body: daze kept %s, head strength %.2f, slid %.2f m, break over at %.3f s"
		% [kept, strength, slid, rest["end"] - t0])
	check(kept, "a flinch on a broken body keeps the daze (state and pose)")
	check(strength <= 0.5 and absf(slid - float(tap["push"])) <= float(tap["push"]) * PUSH_TOL, "a flinch on a broken body still hits the bone and slides")
	check(absf(rest["end"] - t0 - bt) <= STUN_TOL, "the break still ends on time")

	# A lift on top: it lands into a knockdown; once up, the daze comes back.
	await _place(v, Vector3(32, 0, 0))
	var long_break := 4.0
	t0 = TimeDirector.now()
	v.react(&"broken", Vector3.FORWARD, 0.0, long_break, _info(v, atk, &"jab", &"broken", 0.0, long_break, 0.0, Bones.HEAD))
	await _until(t0 + 0.2)
	v.react(&"lift", Vector3.FORWARD, 0.0, 0.0, _info(v, atk, &"heavy_uppercut", &"lift", 0.0, 0.0, 1.0, Bones.HEAD))
	await ticks(2)
	var lifted := v.is_lifted()
	await wait_until(func() -> bool: return v.is_down(), 240)
	var downed := v.is_down() and v.get_react_state() == &"down"
	await _until(t0 + 2.0)
	v.ragdoll.force_recover()
	await ticks(3)
	var dazed_again := v.get_react_state() == &"broken" and not v.can_act()
	var r2 := await _watch(v, &"broken", 600)
	print("  lift on a broken body: lifted %s, down %s, dazed again once up %s, break over at %.3f s (want %.2f)"
		% [lifted, downed, dazed_again, r2["end"] - t0, long_break])
	check(lifted and downed, "a lift on a broken body plays (lands into a knockdown)")
	check(dazed_again, "back on its feet with the break still on: dazed again")
	check(absf(r2["end"] - t0 - long_break) <= STUN_TOL, "the break ends on its own clock (%.3f s)" % [r2["end"] - t0])

	# Once CombatController reports the break, its time is the status.
	var dbl = DOUBLE.use_on(v)
	await _place(v, Vector3(36, 0, 0))
	t0 = TimeDirector.now()
	dbl.broken_until = t0 + 1.0
	v.react(&"broken", Vector3.FORWARD, 0.0, bt, _info(v, atk, &"jab", &"broken", 0.0, bt, 0.0, Bones.HEAD))
	await _until(t0 + 0.3)
	v.react(&"fold", Vector3.FORWARD, 0.3, 0.6, _info(v, atk, &"heavy_gut_punch", &"fold", 0.3, 0.6, 0.0, Bones.CHEST))
	var seq2 := await _sequence(v, 400)
	var b_end: float = seq2["end"] - t0
	await _place(v, Vector3(40, 0, 0))
	t0 = TimeDirector.now()
	dbl.broken_until = t0 + 1.0
	v.react(&"broken", Vector3.FORWARD, 0.0, bt, _info(v, atk, &"jab", &"broken", 0.0, bt, 0.0, Bones.HEAD))
	var still_b := false
	await _until(t0 + 0.4)
	v.react(&"snap", Vector3.FORWARD, 0.2, 0.25, _info(v, atk, &"uppercut", &"snap", 0.2, 0.25, 0.0, Bones.HEAD))
	await wait_until(func() -> bool: return v.get_react_state() != &"snap", 120)
	still_b = dbl.is_broken() and v.get_react_state() == &"broken"
	var seq3 := await _watch(v, &"broken", 400)
	print("  B reports a 1.0 s break (react asked %.2f): fold on top %s, daze over at %.3f s; after a snap on top B still broken %s, over at %.3f s"
		% [bt, seq2["kinds"], b_end, still_b, seq3["end"] - t0])
	check(seq2["kinds"] == [&"fold", &"broken"] and absf(b_end - 1.0) <= STUN_TOL, "B's break time is the status (over at %.3f s)" % b_end)
	check(still_b and absf(seq3["end"] - t0 - 1.0) <= STUN_TOL, "a reaction ending on top never ends the break early")
	dbl.broken_until = -INF

## The daze pose the fighter should hold: P's react_broken, else the fallbacks.
func _daze_id() -> StringName:
	var ids: Array[StringName] = [&"react_broken"]
	for id: StringName in Fighter.REACT_POSE_FALLBACK[&"broken"]:
		ids.append(id)
	for id in ids:
		if PoseLibrary.HOLDS.has(id) or PoseLibrary.POSES.has(id):
			return id
	return &""

## Watch a reaction of `kind` to its end: whether the state held, no acting,
## animated all through, the real time it ended and when it could act.
func _watch(v: Fighter, kind: StringName, max_ticks: int) -> Dictionary:
	var state_ok := true
	var no_act := true
	var animated := true
	var t_end := -1.0
	var t_act := -1.0
	for i in max_ticks:
		var reacting := v.is_reacting()
		if reacting:
			state_ok = state_ok and v.get_react_state() == kind
			no_act = no_act and not v.can_act()
			animated = animated and v.get_state() == RagdollController.State.ANIMATED
		if t_end < 0.0 and not reacting:
			t_end = TimeDirector.now()
		if t_act < 0.0 and v.can_act():
			t_act = TimeDirector.now()
		if t_end >= 0.0 and t_act >= 0.0:
			break
		await get_tree().physics_frame
	return {"state_ok": state_ok, "no_act": no_act, "animated": animated, "end": t_end, "act": t_act}

## The reaction states in order until none is left: kinds and the time each began.
func _sequence(v: Fighter, max_ticks: int) -> Dictionary:
	var kinds: Array[StringName] = []
	var times: Array[float] = []
	var t_end := -1.0
	for i in max_ticks:
		var k := v.get_react_state()
		if k == &"":
			t_end = TimeDirector.now()
			break
		if kinds.is_empty() or kinds[-1] != k:
			kinds.append(k)
			times.append(TimeDirector.now())
		await get_tree().physics_frame
	return {"kinds": kinds, "t": times, "end": t_end}

# --- Fold ----------------------------------------------------------------------------------
func _fold_suite(v: Fighter, atk: Fighter) -> void:
	var tap: Dictionary = Tuning.R8_MOVES[&"gut_punch"]["tap"]
	var quick_stun: float = tap["stun"]
	var full_stun: float = (Tuning.R8_MOVES[&"gut_punch"]["charged"]["stun"] as Vector2).y
	await _place(v, Vector3(44, 0, 0))
	var stand := _aim(v)
	var q := await _fold(v, atk, Vector3(44, 0, 0), quick_stun, stand)
	var f := await _fold(v, atk, Vector3(48, 0, 0), full_stun, stand)
	var share: float = q["drop"] / maxf(f["drop"], 1e-3)
	print("  fold %.2f s: drop %.3f m (%.0f%% of the full keel), deepest at %.3f s, back up %.3f s after the hit; fold %.2f s: drop %.3f m, still down %.3f m at the end of its stun"
		% [quick_stun, q["drop"], share * 100.0, q["t_low"], q["t_up"], full_stun, f["drop"], f["late"]])
	check(f["drop"] >= 0.1, "the charged fold is the full keel (aim point drops %.3f m)" % f["drop"])
	check(share >= 0.3 and share <= 0.7, "the tap's fold is a half-keel (%.0f%% of the full one)" % (share * 100.0))
	check(q["t_low"] <= quick_stun * 0.7, "the half-keel comes quickly (deepest at %.3f s)" % q["t_low"])
	check(q["t_up"] >= 0.0 and q["t_up"] <= quick_stun + 0.1, "and straight back up (%.3f s after the hit)" % q["t_up"])
	check(f["late"] >= f["drop"] * 0.6, "the full keel holds through its stun")
	check(q["move"] == &"react_fold" and q["hold"] == &"", "the half-keel is P's react_fold played over the stun (move %s, hold %s)" % [q["move"], q["hold"]])
	check(f["hold"] == &"react_fold", "the full keel holds P's react_fold (%s)" % f["hold"])

## A fold of `stun` from a standstill: the deepest aim-point drop below
## `stand`, when it was, when the aim point is back within 3 cm of standing
## (after the deepest point), and the drop 0.1 s before the stun ends.
func _fold(v: Fighter, atk: Fighter, at: Vector3, stun: float, stand: float) -> Dictionary:
	await _place(v, at)
	var t0 := TimeDirector.now()
	v.react(&"fold", Vector3.FORWARD, 0.0, stun, _info(v, atk, &"gut_punch", &"fold", 0.0, stun, 0.0, Bones.CHEST))
	var move := v.animator.get_current_move()
	var hold := v.animator.get_hold_id()
	var drop := 0.0
	var t_low := 0.0
	var t_up := -1.0
	var late := 0.0
	for i in int((stun + 0.6) * 120.0):
		await get_tree().physics_frame
		var t := TimeDirector.now() - t0
		var d := stand - _aim(v)
		if d > drop:
			drop = d
			t_low = t
		if t_up < 0.0 and drop > 0.05 and d < 0.03:
			t_up = t
		if t <= stun - 0.1:
			late = d
	return {"drop": drop, "t_low": t_low, "t_up": t_up, "late": late, "move": move, "hold": hold}

func _aim(v: Fighter) -> float:
	return v.get_aim_point().y - v.global_position.y

# --- Lift ----------------------------------------------------------------------------------
func _lift_suite(v: Fighter, atk: Fighter) -> void:
	var lift: Vector2 = Tuning.R8_MOVES[&"uppercut"]["charged"]["lift"]
	var lane := 0
	for h: float in [lift.x, lift.y]:
		var r := await _lift(v, atk, Vector3(52 + lane * 4.0, 0, 0), h)
		lane += 1
		var g := 2.0 * Tuning.R7_LIFT_HEIGHT / (Tuning.R7_LIFT_PEAK_TIME * Tuning.R7_LIFT_PEAK_TIME)
		var want_air := 2.0 * sqrt(2.0 * h / g)
		print("  lift %.1f m: peak %.3f m at %.3f s, landed after %.3f s (want %.3f), down %s, grounded %s, lowest bone %.3f m, fastest bone after landing %.2f m/s"
			% [h, r["peak"], r["t_peak"], r["air"], want_air, r["down"], r["grounded"], r["lowest"], r["fastest"]])
		check(absf(r["peak"] - h) <= LIFT_TOL, "lift %.1f m peaks %.3f m" % [h, r["peak"]])
		check(r["state_ok"] and r["capsule"], "lift %.1f m: state &\"lift\" on the capsule arc all through" % h)
		check(absf(r["air"] - want_air) <= STUN_TOL, "lift %.1f m: air time %.3f s" % [h, r["air"]])
		check(r["down"], "lift %.1f m lands into a knockdown" % h)
		check(r["grounded"] and r["lowest"] >= -0.1 and r["fastest"] < 15.0, "lift %.1f m: the body comes to rest on the floor" % h)

func _lift(v: Fighter, atk: Fighter, at: Vector3, height: float) -> Dictionary:
	await _place(v, at)
	var p0 := v.global_position
	var t0 := TimeDirector.now()
	v.react(&"lift", Vector3.FORWARD, 0.3, 0.0, _info(v, atk, &"heavy_uppercut", &"lift", 0.3, 0.0, height, Bones.HEAD))
	var peak := 0.0
	var t_peak := 0.0
	var state_ok := true
	var capsule := true
	var t_land := -1.0
	for i in 400:
		await get_tree().physics_frame
		if v.is_lifted():
			var h := v.global_position.y - p0.y
			if h > peak:
				peak = h
				t_peak = TimeDirector.now() - t0
			state_ok = state_ok and v.get_react_state() == &"lift"
			capsule = capsule and v.get_state() == RagdollController.State.ANIMATED
		else:
			t_land = TimeDirector.now() - t0
			break
	await ticks(2)
	var down := v.is_down() and v.get_react_state() == &"down"
	var lowest := INF
	var fastest := 0.0
	var grounded := false
	for i in 360:
		await get_tree().physics_frame
		for b: StringName in [Bones.HIPS, Bones.HEAD, Bones.L_FOOT, Bones.R_FOOT, Bones.L_HAND, Bones.R_HAND]:
			lowest = minf(lowest, v.rig.get_bone_global_position(b).y)
		if i > 12:
			fastest = maxf(fastest, v.get_com_velocity().length())
		var st := v.get_state()
		if st == RagdollController.State.GROUNDED or st == RagdollController.State.GETUP:
			grounded = true
			break
	await _recover(v)
	return {"peak": peak, "t_peak": t_peak, "air": t_land, "state_ok": state_ok, "capsule": capsule, "down": down,
		"lowest": lowest, "fastest": fastest, "grounded": grounded}

# --- Helpers ---------------------------------------------------------------------------------
## The bone's offset from the capsule along `dir` (m).
func _bone_offset(v: Fighter, bone: StringName, dir: Vector3) -> float:
	return (v.rig.get_bone_global_position(bone) - v.global_position).dot(dir)

func _hspeed(f: Fighter) -> float:
	return Vector2(f.velocity.x, f.velocity.z).length()

## Step until TimeDirector.now() reaches `t`.
func _until(t: float) -> void:
	while TimeDirector.now() < t - 1e-6:
		await get_tree().physics_frame

func _info(v: Fighter, atk: Fighter, move_id: StringName, kind: StringName, push: float, stun: float, lift: float,
		bone: StringName) -> HitInfo:
	var info := HitInfo.new()
	info.attacker = atk
	info.victim = v
	info.move_id = move_id
	info.kind = &"strike"
	info.react = kind
	info.push = push
	info.stun = stun
	info.lift_height = lift
	info.hit_bone = bone
	info.hit_direction = Vector3.FORWARD
	info.hit_position = v.get_aim_point()
	return info

## Standing still at `at`, facing back along the hit (+Z), nothing running.
func _place(v: Fighter, at: Vector3) -> void:
	await _recover(v)
	v.clear_react()
	v.move_input = Vector3.ZERO
	v.teleport_to(at, Vector3.BACK)
	await ticks(15)

func _recover(v: Fighter) -> void:
	if v.ragdoll.is_simulating() or v.get_state() != RagdollController.State.ANIMATED:
		v.ragdoll.force_recover()
	v.combat.cancel()
	await ticks(3)
