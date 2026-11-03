extends "res://tests/input/input_test_base.gd"
## Round 8 tap reactions through the whole path (Round 8 acceptance 2 with B;
## rewritten from Round 7, whose taps were heavier): a real button tap
## (Input.action_press -> PlayerController -> CombatController's strike, glide
## and hit) on a fresh grunt gives the reaction of Tuning.R8_MOVES[move].tap,
## and Fighter.react plays it out: the reported state, the push (+-20%) and the
## stun (+-0.05 s, the victim's hitstop excluded). The jab and leg kick taps
## flinch, the gut punch tap is the quick fold, the front kick tap shoves, the
## uppercut tap snaps the head. Prints the measured numbers.

const STUN_TOL := 0.05
const PUSH_TOL := 0.2
## Button -> the move it fires as the first press on a fresh target.
const CASES := [[&"punch", &"jab"], [&"gut_punch", &"gut_punch"], [&"leg_kick", &"leg_kick"],
	[&"front_kick", &"front_kick"], [&"uppercut", &"uppercut"]]

var _reacts: Array = []  ## [victim, kind, attacker, real time]
var _hits: Array[HitInfo] = []

func run() -> void:
	_timeout = 200.0
	GameEvents.react_started.connect(func(f: Node3D, kind: StringName, attacker: Node3D) -> void:
		_reacts.append([f, kind, attacker, TimeDirector.now()]))
	GameEvents.hit_landed.connect(func(info: HitInfo) -> void: _hits.append(info))
	var p := spawn_player(Vector3.ZERO)
	await ticks(40)
	var lane := 0
	for c: Array in CASES:
		var button: StringName = c[0]
		var move_id: StringName = c[1]
		var row: Dictionary = Tuning.R8_MOVES[move_id]["tap"]
		var at := Vector3(lane * 8.0, 0, 0)
		lane += 1
		p.teleport_to(at, Vector3.FORWARD)
		var v := spawn_dummy(&"grunt", at + Vector3(0, 0, -1.0), Vector3.BACK)
		await ticks(30)
		_reacts.clear()
		_hits.clear()
		press(button)
		await ticks(1)
		release(button)
		var got := await wait_until(func() -> bool: return not _reacts.is_empty() and _reacts[0][0] == v, 120)
		if not got:
			check(false, "%s: the press hit and the grunt reacted (hits %d)" % [button, _hits.size()])
			v.queue_free()
			continue
		var info: HitInfo = null
		for h in _hits:
			if h.victim == v:
				info = h
		var kind: StringName = _reacts[0][1]
		var p0 := v.global_position
		var dir := Vector3(info.hit_direction.x, 0.0, info.hit_direction.z).normalized() if info else Vector3.FORWARD
		var t0: float = _reacts[0][3]
		var frozen := 0
		var state_ok := true
		var peak := 0.0
		var t_end := -1.0
		for i in 400:
			if v.is_frozen():
				frozen += 1
			if v.is_reacting():
				state_ok = state_ok and v.get_react_state() == kind
				peak = maxf(peak, v.global_position.y - p0.y)
			elif t_end < 0.0:
				t_end = TimeDirector.now()
				break
			await get_tree().physics_frame
		await ticks(10)
		var push := (v.global_position - p0).dot(dir)
		var stun := t_end - t0 - frozen / 120.0
		var want_react: StringName = row["react"]
		print("  %-10s -> %-10s react %-6s (want %s), info push %.2f stun %.2f, measured push %.2f m, stun %.3f s (+%.3f s hitstop), peak %.2f m"
			% [button, info.move_id if info else &"?", kind, want_react, info.push if info else -1.0, info.stun if info else -1.0,
			push, stun, frozen / 120.0, peak])
		check(info != null and info.move_id == move_id, "%s fires %s" % [button, move_id])
		check(kind == want_react and info != null and info.react == want_react, "%s: reaction %s" % [move_id, want_react])
		check(state_ok, "%s: state reported all through the reaction" % move_id)
		var want_push: float = row["push"]
		var want_stun: float = row["stun"]
		check(info != null and not info.charged, "%s: a tap, not a charge" % move_id)
		check(absf(push - want_push) <= want_push * PUSH_TOL, "%s: push %.2f m (want %.2f)" % [move_id, push, want_push])
		check(absf(stun - want_stun) <= STUN_TOL, "%s: stun %.3f s (want %.2f)" % [move_id, stun, want_stun])
		await wait_until(func() -> bool: return p.can_act() and not p.combat.is_attacking(), 240)
		v.queue_free()
		await ticks(5)
	done()
