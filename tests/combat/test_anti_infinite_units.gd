extends "res://tests/combat/combat_test_base.gd"
## Anti-infinite unit checks: stun decay per hit, the victim count shared by
## two attackers (damage scaling per victim), the juggle relaunch cap, a short
## string still at full stun, and the break-away hit itself.

const L := CombatController.Action.LIGHT

func _init() -> void:
	_timeout = 90.0

func run() -> void:
	print("stun decay per hit")
	var d: Array = []
	for n in range(1, 10):
		d.append(snappedf(CombatController.stun_decay(n), 0.001))
	var want := [1.0, 1.0, 1.0, 0.85, 0.7, 0.55, 0.4, 0.4, 0.4]
	var same := true
	for i in want.size():
		same = same and absf(float(d[i]) - float(want[i])) < 0.001
	check(same, "decay per hit %s" % [d])

	print("the victim count is shared by two attackers")
	var a1 := spawn(&"player", Vector3(0, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var a2 := spawn(&"player", Vector3(0.9, 0, -0.9), Vector3.LEFT, Fighter.TEAM_PLAYER)
	var g := spawn(&"grunt", Vector3(0, 0, -1.0), Vector3.BACK)
	await ticks(12)
	var hits: Array = []
	GameEvents.hit_landed.connect(func(i: HitInfo) -> void:
		if i.victim == g: hits.append(i))
	for att: Fighter in [a1, a2, a1]:
		var n0 := hits.size()
		att.combat.press(L)
		await wait_until(func() -> bool: return hits.size() > n0, 1.0)
		await wait_real(0.15)
	check(hits.size() == 3 and g.combat.hits_taken() == 3, "3 hits from two attackers: victim count %d" % g.combat.hits_taken())
	if hits.size() == 3:
		check(is_equal_approx((hits[2] as HitInfo).damage_scale, CombatController.combo_scale(3)),
			"the 3rd hit (first attacker again) is scaled as hit 3: x%.1f" % (hits[2] as HitInfo).damage_scale)
		check(a1.combat.get_combo_count() == 2 and a2.combat.get_combo_count() == 1, "the HUD combo counter stays per attacker")
	await wait_real(1.5)

	print("a short string plays at full stun")
	var p := spawn(&"player", Vector3(8, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var g2 := spawn(&"grunt", Vector3(8, 0, -1.0), Vector3.BACK)
	await ticks(12)
	var stuns: Array = []
	GameEvents.hit_landed.connect(func(i: HitInfo) -> void:
		if i.victim == g2: stuns.append([i.move_id, g2.combat._stun_left]))
	for k in 4:
		var n0 := stuns.size()
		p.combat.press(L)
		await wait_until(func() -> bool: return stuns.size() > n0, 1.0)
		await wait_real(0.12)
	print("  stun after each hit: ", stuns)
	var base := {&"jab1": MoveLibrary.get_move(&"jab1").hitstun, &"cross": MoveLibrary.get_move(&"cross").hitstun,
		&"hook": CombatController.STAGGER_TIME * CombatController.STAGGER_STRENGTH}
	var full := stuns.size() >= 3
	for i in mini(3, stuns.size()):
		full = full and absf(float(stuns[i][1]) - float(base[stuns[i][0]])) < 0.02
	check(full, "hits 1-3 (jab, cross, hook) at full stun")
	if stuns.size() >= 4:
		check(absf(float(stuns[3][1]) - float(base[stuns[3][0]]) * CombatController.stun_decay(4)) < 0.02,
			"hit 4 at x%.2f stun" % CombatController.stun_decay(4))
	await wait_real(1.5)

	print("juggle relaunch cap")
	var pj := spawn(&"player", Vector3(16, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var gj := spawn(&"grunt", Vector3(16, 0, -1.0), Vector3.BACK)
	await ticks(12)
	gj.launch(Vector3(0, 6, 0), gj.get_center_of_mass(), &"Chest")
	await wait_real(0.15)
	pj.combat._move = MoveLibrary.get_move(&"jab1")
	pj.combat._move_charge = 0
	var info := pj.combat._build_hit(gj, &"Chest", gj.get_center_of_mass())
	check(info.juggle and info.reaction == HitInfo.Reaction.LAUNCH, "a hit on the flying body is a juggle relaunch")
	gj.combat.juggle_relaunches = Tuning.JUGGLE_MAX_RELAUNCH
	info = pj.combat._build_hit(gj, &"Chest", gj.get_center_of_mass())
	check(info.juggle and info.reaction == HitInfo.Reaction.NONE and info.get_meta(&"juggle_capped", false),
		"after %d relaunches: damage only, the body falls" % Tuning.JUGGLE_MAX_RELAUNCH)
	gj.combat.juggle_relaunches = 0
	var r0 := gj.combat.juggle_relaunches
	var real := HitInfo.new()
	real.attacker = pj
	real.move_id = &"jab1"
	real.kind = &"strike"
	real.reaction = HitInfo.Reaction.LAUNCH
	real.juggle = true
	real.launch_velocity = Vector3(0, 3, -3)
	real.damage = 1.0
	real.hit_direction = Vector3.FORWARD
	gj.take_hit(real)
	check(gj.combat.juggle_relaunches == r0 + 1, "a juggle relaunch is counted on the victim")
	var up := await wait_until(func() -> bool: return not gj.is_down(), 8.0)
	await ticks(2)
	check(up and gj.combat.juggle_relaunches == 0, "the count resets when the body gets up (up=%s)" % up)

	print("the break-away hit")
	var pb := spawn(&"player", Vector3(24, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var gb := spawn(&"grunt", Vector3(24, 0, -1.0), Vector3.BACK)
	await ticks(12)
	clear_events()
	var esc := [false]
	GameEvents.combo_escaped.connect(func(v: Node3D, a: Node3D) -> void:
		if v == gb and a == pb: esc[0] = true)
	gb.combat._taken = Tuning.COMBO_ESCAPE_HITS - 1
	gb.combat._taken_last = TimeDirector.now()
	var hp0 := gb.hp
	var z0 := gb.global_position.z
	pb.combat.press(L)
	await wait_until(func() -> bool: return esc[0], 1.0)
	check(esc[0], "hit %d breaks the victim away (combo_escaped)" % Tuning.COMBO_ESCAPE_HITS)
	check(gb.hp < hp0 and not gb.combat.is_stunned(), "it deals damage and no stun")
	check(gb.combat.hits_taken() == 0, "the victim count resets")
	await wait_real(0.3)
	check(gb.global_position.z < z0 - Tuning.COMBO_ESCAPE_PUSH * 0.5, "pushed back %.2f m" % (z0 - gb.global_position.z))
	pb.combat.press(L)
	await wait_until(func() -> bool: return gb.combat.last_result == HitInfo.Result.BLOCKED, 0.5)
	check(gb.combat.last_result == HitInfo.Result.BLOCKED and not gb.combat.is_stunned(), "auto-guard: the next frontal jab is blocked without stun")
	done()
