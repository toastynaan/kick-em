extends "res://tests/combat/combat_test_base.gd"
## Round 7 acceptance check 3, B's part (docs/Round 7 — Freeflow Combat.md:
## Reactions, Payoffs): every move on a neutral victim deals its own
## R7_MOVES reaction, and every R7_PAYOFFS entry, struck on a victim in that
## state, produces its result: the HitInfo (react, push, stun, lift height,
## payoff flag, victim state, damage x dmg_mult, launch speed and angle along
## the hit direction, tier, weight, hitstop) and the call CombatController
## makes (Fighter.react for the on-feet states, Fighter.knockdown, Fighter.launch
## setting the flight). Heavy enemies: push x R7_HEAVY_PUSH_MULT, stun x
## R7_HEAVY_STUN_MULT, lift x R7_HEAVY_LIFT_MULT, launch x HEAVY_LAUNCH_MULT.
## The victim's state is set by the test (FakeFighter.fake_react); agent H's
## Fighter.react then applies the reaction for real.

const T := HitInfo.Tier
var _x := 0.0
var _p: Fighter
var _trials := 0
var _payoffs := 0

func _init() -> void:
	_timeout = 150.0

func run() -> void:
	_p = spawn_fake(&"player", Vector3.ZERO, Vector3.FORWARD, Fighter.TEAM_PLAYER)
	_p.combat.sever_on_kill_chance = 0.0
	await ticks(10)
	print("every move on a neutral grunt: its own reaction")
	for id: StringName in MoveLibrary.PLAYER_MOVES:
		await _trial(id, &"", &"grunt")
	print("every payoff")
	for id: StringName in Tuning.R7_PAYOFFS:
		for state: StringName in Tuning.R7_PAYOFFS[id]:
			await _trial(id, state, &"grunt")
	print("a state with no payoff entry keeps the move's own reaction")
	await _trial(&"leg_kick", &"fold", &"grunt")
	await _trial(&"front_kick", &"snap", &"grunt")
	print("heavy enemies")
	await _trial(&"front_kick", &"", &"heavy")
	await _trial(&"gut_punch", &"", &"heavy")
	await _trial(&"uppercut", &"fold", &"heavy")
	await _trial(&"roundhouse", &"lift", &"heavy")
	print("DATA %d trials, %d payoffs of %d in the table" % [_trials, _payoffs, _count_payoffs()])
	check(_payoffs == _count_payoffs(), "every R7_PAYOFFS entry was struck (%d)" % _payoffs)
	done()

func _count_payoffs() -> int:
	var n := 0
	for id: StringName in Tuning.R7_PAYOFFS:
		n += (Tuning.R7_PAYOFFS[id] as Dictionary).size()
	return n

## Strike a fresh `arch` victim in react state `state` with `id`; check the
## result against R7_MOVES / R7_PAYOFFS.
func _trial(id: StringName, state: StringName, arch: StringName) -> void:
	_trials += 1
	_x += 6.0
	# A fresh chain each trial: the last move over and its chain dropped.
	await wait_until(func() -> bool: return not _p.combat.is_attacking() and _p.combat.get_chain_count() == 0, 2.0)
	_p.teleport_to(Vector3(_x, 0, 0), Vector3.FORWARD)
	var v: Fighter = spawn_fake(arch, Vector3(_x, 0, -1.0), Vector3.BACK)
	await ticks(12)
	v.set(&"fake_react", state)
	clear_events()
	var started := _p.combat.play_move(id, v)
	var landed := await wait_until(func() -> bool: return not hits_on(v).is_empty(), 1.5)
	var info: HitInfo = hits_on(v)[0] if landed else null
	var e: Dictionary = MoveLibrary.get_move(id).r7_entry()
	var pay: Dictionary = (Tuning.R7_PAYOFFS.get(id, {}) as Dictionary).get(state, {})
	if not pay.is_empty() and info != null and info.payoff and arch == &"grunt":
		_payoffs += 1
	var heavy := v.is_heavy()
	var want_react: StringName = pay.get("react", e["react"])
	var want_push := float(pay.get("push", e["push"])) * (Tuning.R7_HEAVY_PUSH_MULT if heavy else 1.0)
	var want_stun := float(pay.get("stun", e["stun"])) * (Tuning.R7_HEAVY_STUN_MULT if heavy else 1.0)
	var want_lift := 0.0
	if want_react == &"lift":
		want_lift = float(pay.get("lift", Tuning.R7_LIFT_HEIGHT))
	elif want_react == &"repop":
		want_lift = Tuning.R7_REPOP_HEIGHT
	want_lift *= Tuning.R7_HEAVY_LIFT_MULT if heavy else 1.0
	var want_dmg := float(e["dmg"]) * float(pay.get("dmg_mult", 1.0))
	var label := "%s on %s%s" % [id, state if state != &"" else &"neutral", " (heavy)" if heavy else ""]
	if info == null:
		check(false, "%s: landed (started %s)" % [label, started])
		v.queue_free()
		return
	var line := "%s -> %s push %.2f stun %.2f lift %.2f dmg %.1f" % [label, info.react, info.push, info.stun,
		info.lift_height, info.damage]
	var want_tier: int = CombatController.REACT_TIER[want_react] if not pay.is_empty() \
		else CombatController._tier_named(e["tier"])
	var bad: Array[String] = []
	for c: Array in [[info.react == want_react, "react"], [info.payoff == not pay.is_empty(), "payoff"],
			[info.victim_state == state, "victim_state"], [is_equal_approx(info.push, want_push), "push"],
			[is_equal_approx(info.stun, want_stun), "stun"], [is_equal_approx(info.lift_height, want_lift), "lift"],
			[is_equal_approx(info.damage, want_dmg), "damage"], [is_equal_approx(info.weight, float(e["weight"])), "weight"],
			[is_equal_approx(info.hitstop, float(e["hitstop"])), "hitstop"], [info.chain_index == 1, "chain_index"],
			[info.counter == (id == &"counter"), "counter"], [info.tier == want_tier, "tier"]]:
		if not c[0]:
			bad.append(c[1])
	var ok := bad.is_empty()
	# The call: react / knockdown / launch.
	var rec: Array = v.call(&"last_react")
	match want_react:
		&"knockdown":
			ok = ok and not rec.is_empty() and rec[0] == &"knockdown"
		&"launch":
			var lv := info.launch_velocity
			var spd := float(pay.get("launch_speed", e.get("launch_speed", 0.0))) * (Tuning.HEAVY_LAUNCH_MULT if heavy else 1.0)
			var want_ang := float(pay.get("launch_angle", e.get("launch_angle", 0.0)))
			var ang := rad_to_deg(atan2(lv.y, Vector2(lv.x, lv.z).length()))
			var flat := Vector3(lv.x, 0.0, lv.z).normalized()
			line += " launch %.2f m/s at %.1f deg" % [lv.length(), ang]
			ok = ok and absf(lv.length() - spd) < 0.01 and absf(ang - want_ang) < 0.1 \
				and flat.dot(info.hit_direction) > 0.999 and not rec.is_empty() and rec[0] == &"launch" \
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
