extends "res://tests/combat/combat_test_base.gd"
## Round 7 acceptance check 3, B's part (docs/Round 7 — Freeflow Combat.md:
## Reactions, Payoffs), rewritten for Round 8 (docs/Round 8 — Charge and
## Pressure.md: Moves, "the full Round 7 table stays"):
## - every move on a neutral victim deals its own entry: the eight strikes
##   tapped (R8_MOVES[id].tap) and charged at c = 0.5 (.charged lerped), the
##   Round 7 heavies, the counter and the dropping strike (R7_MOVES);
## - every R7_PAYOFFS entry, struck on a victim in that state, produces its
##   result: taps by their own id, charged strikes by their payoff_id, the
##   Round 7 heavy ids through play_move too. Checked: the HitInfo (react,
##   push, stun, lift height, payoff flag, victim state, damage x dmg_mult,
##   launch speed and angle along the hit (across it for the charged hook),
##   tier, weight, hitstop, charged and charge) and the call CombatController
##   makes (Fighter.react for the on-feet states, Fighter.knockdown,
##   Fighter.launch setting the flight);
## - payoff results do not scale with c (a folded body launched by a charged
##   front kick flies at the payoff's 13 m/s at c = 0 and c = 1); a non-launch
##   payoff never replaces a charged launch (a full charged cross on a folded
##   body launches);
## - heavy enemies: push x R7_HEAVY_PUSH_MULT, stun x R7_HEAVY_STUN_MULT, lift x
##   R7_HEAVY_LIFT_MULT, launch x HEAVY_LAUNCH_MULT.
## The victim's state is set by the test (FakeFighter.fake_react); agent H's
## Fighter.react then applies the reaction for real.

const T := HitInfo.Tier
var _x := 0.0
var _z := 0.0
var _p: Fighter
var _trials := 0
var _struck := {}  ## "payoff_id/state" -> true (grunt trials that hit a payoff)

func _init() -> void:
	_timeout = 240.0

func run() -> void:
	_p = spawn_fake(&"player", Vector3.ZERO, Vector3.FORWARD, Fighter.TEAM_PLAYER)
	_p.combat.sever_on_kill_chance = 0.0
	await ticks(10)
	print("every move on a neutral grunt: its own entry")
	for id: StringName in MoveLibrary.PLAYER_MOVES:
		await _trial(id, &"", &"grunt")
	for id: StringName in Tuning.R8_MOVES:
		await _trial(id, &"", &"grunt", 0.5)
	print("every payoff")
	for pid: StringName in Tuning.R7_PAYOFFS:
		for state: StringName in Tuning.R7_PAYOFFS[pid]:
			await _trial(pid, state, &"grunt")  # a tap by its id, or a Round 7 heavy through play_move
			for id: StringName in Tuning.R8_MOVES:
				if Tuning.R8_MOVES[id]["charged"].get("payoff_id", id) == pid:
					await _trial(id, state, &"grunt", 0.5)  # the charged strike by its payoff_id
	print("payoffs do not scale with c; a non-launch payoff never replaces a charged launch")
	var lo: HitInfo = await _trial(&"front_kick", &"fold", &"grunt", 0.0)
	var hi: HitInfo = await _trial(&"front_kick", &"fold", &"grunt", 1.0)
	check(lo != null and hi != null and lo.payoff and hi.payoff
		and is_equal_approx(lo.launch_velocity.length(), hi.launch_velocity.length()),
		"the charged front kick's fold payoff launches at %.1f m/s at c = 0 and c = 1" % (lo.launch_velocity.length() if lo else 0.0))
	await _trial(&"cross", &"fold", &"grunt", 1.0)
	print("a state with no payoff entry keeps the move's own reaction")
	await _trial(&"leg_kick", &"fold", &"grunt")
	await _trial(&"front_kick", &"snap", &"grunt")
	print("heavy enemies")
	await _trial(&"front_kick", &"", &"heavy")
	await _trial(&"gut_punch", &"", &"heavy")
	await _trial(&"uppercut", &"fold", &"heavy")
	await _trial(&"roundhouse", &"lift", &"heavy")
	await _trial(&"uppercut", &"", &"heavy", 1.0)
	print("DATA %d trials, %d payoffs of %d in the table" % [_trials, _struck.size(), _count_payoffs()])
	check(_struck.size() == _count_payoffs(), "every R7_PAYOFFS entry was struck (%d)" % _struck.size())
	done()

func _count_payoffs() -> int:
	var n := 0
	for id: StringName in Tuning.R7_PAYOFFS:
		n += (Tuning.R7_PAYOFFS[id] as Dictionary).size()
	return n

## What strike `id` deals before payoffs: a Round 8 tap (c < 0) or charged
## strike at c, else the move's R7_MOVES entry. Adds "base_react", "launched",
## "payoff_id", "lift", "sideways".
func _entry(id: StringName, c: float) -> Dictionary:
	if not Tuning.R8_MOVES.has(id):
		var e: Dictionary = MoveLibrary.get_move(id).r7_entry().duplicate()
		e["base_react"] = e["react"]
		e["launched"] = false
		e["payoff_id"] = id
		e["sideways"] = false
		return e
	if c < 0.0:
		var t: Dictionary = (Tuning.R8_MOVES[id]["tap"] as Dictionary).duplicate()
		t["base_react"] = t["react"]
		t["launched"] = false
		t["payoff_id"] = id
		t["sideways"] = false
		return t
	var ch: Dictionary = Tuning.R8_MOVES[id]["charged"]
	var out := {}
	for k: String in ch:
		out[k] = lerpf((ch[k] as Vector2).x, (ch[k] as Vector2).y, c) if ch[k] is Vector2 else ch[k]
	out["base_react"] = ch["react"]
	out["launched"] = ch.has("launch_from") and c >= minf(float(ch["launch_from"]), Tuning.debug_launch_step) - 1e-4
	if out["launched"]:
		out["react"] = &"launch"
	elif c >= 1.0 and ch.has("full_react"):
		out["react"] = ch["full_react"]
	out["payoff_id"] = ch.get("payoff_id", id)
	out["sideways"] = bool(ch.get("sideways", false))
	return out

## Strike a fresh `arch` victim in react state `state` with `id` (c < 0: its
## tap or Round 7 move; else charged at c); check the result against the
## tables. Returns the HitInfo (null when it did not land).
func _trial(id: StringName, state: StringName, arch: StringName, c := -1.0) -> HitInfo:
	_trials += 1
	_x += 6.0
	if _x > 220.0:
		_x = 6.0
		_z += 12.0
	# A fresh chain each trial: the last move over and its chain dropped.
	await wait_until(func() -> bool: return not _p.combat.is_attacking() and _p.combat.get_chain_count() == 0, 2.0)
	_p.teleport_to(Vector3(_x, 0, _z), Vector3.FORWARD)
	var v: Fighter = spawn_fake(arch, Vector3(_x, 0, _z - 1.0), Vector3.BACK)
	await ticks(12)
	v.set(&"fake_react", state)
	clear_events()
	var started := _p.combat.play_move(id, v) if c < 0.0 else _p.combat.play_charged(id, c, v)
	var landed := await wait_until(func() -> bool: return not hits_on(v).is_empty(), 1.5)
	var info: HitInfo = hits_on(v)[0] if landed else null
	var e := _entry(id, c)
	var pay: Dictionary = (Tuning.R7_PAYOFFS.get(e["payoff_id"], {}) as Dictionary).get(state, {})
	if bool(e["launched"]) and StringName(pay.get("react", &"")) != &"launch":
		pay = {}  # a charged launch outranks a non-launch payoff
	if not pay.is_empty() and info != null and info.payoff and arch == &"grunt":
		_struck["%s/%s" % [e["payoff_id"], state]] = true
	var heavy := v.is_heavy()
	var want_react: StringName = pay.get("react", e["react"])
	var want_push := float(pay.get("push", e["push"])) * (Tuning.R7_HEAVY_PUSH_MULT if heavy else 1.0)
	var want_stun := float(pay.get("stun", e["stun"])) * (Tuning.R7_HEAVY_STUN_MULT if heavy else 1.0)
	var want_lift := 0.0
	if want_react == &"lift":
		want_lift = float(pay.get("lift", e.get("lift", Tuning.R7_LIFT_HEIGHT)))
	elif want_react == &"repop":
		want_lift = Tuning.R7_REPOP_HEIGHT
	want_lift *= Tuning.R7_HEAVY_LIFT_MULT if heavy else 1.0
	var want_dmg := float(e["dmg"]) * float(pay.get("dmg_mult", 1.0))
	var label := "%s%s on %s%s" % [id, "" if c < 0.0 else " charged c=%.1f" % c, state if state != &"" else &"neutral",
		" (heavy)" if heavy else ""]
	if info == null:
		check(false, "%s: landed (started %s)" % [label, started])
		v.queue_free()
		return null
	var line := "%s -> %s push %.2f stun %.2f lift %.2f dmg %.1f" % [label, info.react, info.push, info.stun,
		info.lift_height, info.damage]
	var want_tier: int = CombatController.REACT_TIER[want_react] if (not pay.is_empty() or want_react != e["base_react"]) \
		else CombatController._tier_named(e["tier"])
	var bad: Array[String] = []
	for chk: Array in [[info.react == want_react, "react"], [info.payoff == not pay.is_empty(), "payoff"],
			[info.victim_state == state, "victim_state"], [is_equal_approx(info.push, want_push), "push"],
			[is_equal_approx(info.stun, want_stun), "stun"], [is_equal_approx(info.lift_height, want_lift), "lift"],
			[is_equal_approx(info.damage, want_dmg), "damage"], [is_equal_approx(info.weight, float(e["weight"])), "weight"],
			[is_equal_approx(info.hitstop, float(e["hitstop"])), "hitstop"], [info.chain_index == 1, "chain_index"],
			[info.counter == (id == &"counter"), "counter"], [info.tier == want_tier, "tier"],
			[info.charged == (c >= 0.0) and (c < 0.0 or is_equal_approx(info.charge, c)), "charged"]]:
		if not chk[0]:
			bad.append(chk[1])
	var ok := bad.is_empty()
	# The call: react / knockdown / launch (the first one: a pressure break adds &"broken" after it).
	var recs: Array = v.get(&"reacts")
	var rec: Array = recs[0] if not recs.is_empty() else []
	match want_react:
		&"knockdown":
			ok = ok and not rec.is_empty() and rec[0] == &"knockdown"
		&"launch":
			var lv := info.launch_velocity
			var spd := float(pay.get("launch_speed", e.get("launch_speed", 0.0))) * (Tuning.HEAVY_LAUNCH_MULT if heavy else 1.0)
			var want_ang := float(pay.get("launch_angle", e.get("launch_angle", 0.0)))
			var ang := rad_to_deg(atan2(lv.y, Vector2(lv.x, lv.z).length()))
			var flat := Vector3(lv.x, 0.0, lv.z).normalized()
			var dir := info.hit_direction.cross(Vector3.UP).normalized() if e["sideways"] else info.hit_direction
			line += " launch %.2f m/s at %.1f deg" % [lv.length(), ang]
			ok = ok and absf(lv.length() - spd) < 0.01 and absf(ang - want_ang) < 0.1 \
				and flat.dot(dir) > 0.999 and not rec.is_empty() and rec[0] == &"launch" \
				and absf((rec[1] as Vector3).length() - spd) < 0.6
		_:
			ok = ok and not rec.is_empty() and rec[0] == want_react and is_equal_approx(float(rec[2]), want_push) \
				and is_equal_approx(float(rec[3]), want_stun) and rec[4] == info
	if not rec.is_empty() and not ok and bad.is_empty():
		bad.append("call %s" % str(rec.slice(0, 4)))
	print("  ", line, "" if bad.is_empty() else "  wrong: %s" % ", ".join(bad))
	check(ok, "%s: %s%s" % [label, want_react, " (payoff)" if not pay.is_empty() else ""])
	await wait_real(0.3)
	v.queue_free()
	await ticks(2)
	return info
