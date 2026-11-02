extends "res://tests/combat/combat_test_base.gd"
## Round 5 combo graph (ComboGraph header): three buttons, strings of at most
## three hits, knees and elbows from strings. Each string is pressed hit by
## hit through real strikes on a grunt; the move ids, P and tier are checked.
## The third hit of a TAP string gets the finisher bonus (+1 P), whether or not
## the hits before it landed; a charged hit ends the string; after Tuning.STRING_RESET
## a press starts a new string; after the third hit the next press is a new
## string. Stance variants: back + Kick and crouch + Kick sweep, back + Light
## is the backfist, any attack in the air is a dropping strike (class by button).
## Combo damage scaling by hit number is unchanged.

const L := CombatController.Action.LIGHT
const H := CombatController.Action.HEAVY
const K := CombatController.Action.KICK
const N := &"neutral"
const B := &"back"
var _x := 0.0

func _init() -> void:
	_timeout = 150.0

func _lane(arch := &"grunt", dist := 1.0) -> Array:
	_x += 10.0
	var p := spawn_fake(&"player", Vector3(_x, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER, true)
	var e := spawn(arch, Vector3(_x, 0, -dist), Vector3.BACK)
	await ticks(12)
	return [p, e]

func _log(f: Fighter) -> Array:
	var starts: Array = []
	f.combat.attack_started.connect(func(id: StringName) -> void: starts.append(id))
	return starts

func _hits_on(victim: Fighter) -> Array[HitInfo]:
	var out: Array[HitInfo] = []
	for ev: Array in events:
		if ev[0] == &"hit_landed" and (ev[1] as HitInfo).victim == victim:
			out.append(ev[1])
	return out

## Press [action, intent, crouch, air, hold s] steps, each once the previous hit landed.
func _string(p: Fighter, steps: Array) -> void:
	for st: Array in steps:
		p.fake_intent = st[1]
		p.fake_crouch = st[2]
		p.fake_air = st[3]
		var n := count_events(&"hit_landed")
		var hold: float = st[4]
		if hold > 0.0:
			await hold_press(p, st[0], hold)
		else:
			tap(p, st[0])
		await wait_until(func() -> bool: return count_events(&"hit_landed") > n or not p.combat.is_attacking(), 1.5)
		p.fake_intent = N
		p.fake_crouch = false
		p.fake_air = false
	await wait_real(0.5)

func _st(action: int, intent := N, crouch := false, air := false, hold := 0.0) -> Array:
	return [action, intent, crouch, air, hold]

func run() -> void:
	print("combo scaling")
	var sc: Array = []
	for n in range(1, 9):
		sc.append(CombatController.combo_scale(n))
	check(sc == [1.0, 1.0, 0.9, 0.8, 0.7, 0.6, 0.5, 0.5], "hits 1-2 full, -10%% each, floor 50%% (%s)" % [sc])

	print("strings (tapped)")
	# [name, steps, move ids, P of each hit, tier of the last hit]
	var cases := [
		["L,L,L", [_st(L), _st(L), _st(L)], [&"jab1", &"jab2", &"elbow"], [1.0, 1.0, 2.5], HitInfo.Tier.STAGGER],
		["L,H (one-two)", [_st(L), _st(H)], [&"jab1", &"cross"], [1.0, 2.0], HitInfo.Tier.STAGGER],
		["L,L,K", [_st(L), _st(L), _st(K)], [&"jab1", &"jab2", &"roundhouse"], [1.0, 1.0, 3.5], HitInfo.Tier.KNOCKDOWN],
		["K,K,K", [_st(K), _st(K), _st(K)], [&"sparta_kick", &"knee_strike", &"roundhouse"], [2.5, 1.5, 3.5], HitInfo.Tier.KNOCKDOWN],
		["H,H,H", [_st(H), _st(H), _st(H)], [&"cross", &"hook", &"uppercut"], [2.0, 2.0, 3.0], HitInfo.Tier.STAGGER],
		["L,K", [_st(L), _st(K)], [&"jab1", &"knee_strike"], [1.0, 1.5], HitInfo.Tier.FLINCH],
		["back + K", [_st(K, B)], [&"leg_sweep"], [1.5], HitInfo.Tier.STUMBLE],
		["crouch + K", [_st(K, N, true)], [&"leg_sweep"], [1.5], HitInfo.Tier.STUMBLE],
		["back + L", [_st(L, B)], [&"backfist"], [2.0], HitInfo.Tier.STAGGER],
		["L,L, back + K (sweep as the third hit)", [_st(L), _st(L), _st(K, B)], [&"jab1", &"jab2", &"leg_sweep"], [1.0, 1.0, 2.5], HitInfo.Tier.STUMBLE],
		["L,L, hold L (charged: no finisher)", [_st(L), _st(L), _st(L, N, false, false, 0.4)], [&"jab1", &"jab2", &"elbow"], [1.0, 1.0, 2.4], HitInfo.Tier.STAGGER],
	]
	for c: Array in cases:
		var pe: Array = await _lane(&"grunt", 1.0)
		var p: Fighter = pe[0]
		var e: Fighter = pe[1]
		var starts := _log(p)
		clear_events()
		await _string(p, c[1])
		var hits := _hits_on(e)
		var ps: Array = []
		for h in hits:
			ps.append(snappedf(h.power, 0.01))
		print("  %-38s moves %s P %s" % [c[0], starts, ps])
		check(starts == c[2], "%s -> %s" % [c[0], c[2]])
		check(ps == c[3], "%s: P %s (want %s)" % [c[0], ps, c[3]])
		if not hits.is_empty():
			check(hits[-1].tier == c[4], "%s: last hit %s (want %s)" % [c[0], HitInfo.tier_name(hits[-1].tier),
				HitInfo.tier_name(c[4])])

	print("air: any attack is a dropping strike (class by button)")
	for row: Array in [[L, &"jab"], [H, &"cross"], [K, &"kick"]]:
		var pe: Array = await _lane(&"grunt", 1.0)
		var p: Fighter = pe[0]
		var starts := _log(p)
		p.fake_air = true
		tap(p, row[0])
		await ticks(3)
		check(starts == [&"drop_strike"], "air %s -> drop_strike (%s)" % [row[1], starts])
		var dbg: Dictionary = p.combat.get_strike_debug()
		check(dbg.get("class", &"") == row[1], "drop strike class %s (%s)" % [row[1], dbg.get("class", &"")])
		p.fake_air = false

	print("the third hit of a tap string gets the finisher even if an earlier one missed")
	var pw: Array = await _lane(&"grunt", 1.0)
	var pf: Fighter = pw[0]
	var ef: Fighter = pw[1]
	clear_events()
	# First jab into the air (the grunt steps out of reach), then two hits.
	ef.global_position = Vector3(_x, 0, -8.0)
	ef.reset_physics_interpolation()
	await ticks(2)
	tap(pf, L)
	await wait_until(func() -> bool: return pf.combat.is_in_recovery() or not pf.combat.is_attacking(), 1.0)
	ef.global_position = pf.global_position + pf.get_forward() * 1.0
	ef.reset_physics_interpolation()
	await ticks(1)
	await _string(pf, [_st(L), _st(L)])
	var fh := _hits_on(ef)
	check(fh.size() == 2 and is_equal_approx(fh[-1].finisher_bonus, Tuning.FINISHER_BONUS) and is_equal_approx(fh[-1].power, 2.5),
		"whiff, hit, hit: the third hit (elbow) gets +1 (%s)" % [fh.map(func(h: HitInfo) -> float: return h.finisher_bonus)])

	print("string reset and string end")
	var pr: Array = await _lane(&"grunt", 1.0)
	var p2: Fighter = pr[0]
	var starts2 := _log(p2)
	await _string(p2, [_st(L)])
	await wait_real(Tuning.STRING_RESET + 0.4)
	await _string(p2, [_st(L)])
	check(starts2 == [&"jab1", &"jab1"], "a press after STRING_RESET starts a new string (%s)" % [starts2])
	await wait_real(Tuning.COMBO_DROP + 0.4)
	starts2.clear()
	await _string(p2, [_st(L), _st(L), _st(L), _st(L)])
	check(starts2.size() == 4 and starts2[3] == &"jab1", "after the third hit the next press is a new string (%s)" % [starts2])
	done()
