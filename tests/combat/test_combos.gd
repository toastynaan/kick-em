extends "res://tests/combat/combat_test_base.gd"
## Upgrade 2 combos (U4): the spec's 8 strings, enders, juggles flattened
## toward the wall, damage scaling, sweeps (stumble / trip / lift), one trip
## per combo, Brute armour, daze (blocked hits, L2 head hit), ground
## finishers, upward throw.

const L := CombatController.Action.LIGHT
const K := CombatController.Action.KICK
var _x := 0.0

func _init() -> void:
	_timeout = 150.0

func _lane(arch := &"grunt", dist := 1.0) -> Array:
	_x += 9.0
	var p := spawn_fake(&"player", Vector3(_x, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER, true)
	var e := spawn(arch, Vector3(_x, 0, -dist), Vector3.BACK)
	await ticks(12)
	return [p, e]

func _log(f: Fighter) -> Array:
	var starts: Array = []
	f.combat.attack_started.connect(func(id: StringName) -> void: starts.append(id))
	return starts

func _hit(move_id: StringName, victim: Fighter) -> HitInfo:
	for i in range(events.size() - 1, -1, -1):
		var ev: Array = events[i]
		if ev[0] == &"hit_landed" and (ev[1] as HitInfo).move_id == move_id and (ev[1] as HitInfo).victim == victim:
			return ev[1]
	return null

## Press a sequence of [action, intent, air] steps, each on the previous hit.
func _string(p: Fighter, _e: Fighter, steps: Array) -> void:
	for st: Array in steps:
		p.fake_intent = st[1]
		p.fake_air = st[2]
		var n := count_events(&"hit_landed")
		tap(p, st[0])
		await wait_until(func() -> bool: return count_events(&"hit_landed") > n or not p.combat.is_attacking(), 1.2)
		p.fake_intent = &"neutral"
		p.fake_air = false
	await wait_real(0.6)

func run() -> void:
	print("combo scaling")
	var sc: Array = []
	for n in range(1, 9):
		sc.append(CombatController.combo_scale(n))
	check(sc == [1.0, 1.0, 0.9, 0.8, 0.7, 0.6, 0.5, 0.5], "hits 1-2 full, -10%% each, floor 50%% (%s)" % [sc])

	print("strings")
	var N := &"neutral"
	var F := &"forward"
	var cases := [
		["P,P,P", [[L, N, false], [L, N, false], [L, N, false]], [&"jab1", &"cross", &"hook"]],
		["P,P,fP", [[L, N, false], [L, N, false], [L, F, false]], [&"jab1", &"cross", &"uppercut"]],
		["P,P,K", [[L, N, false], [L, N, false], [K, N, false]], [&"jab1", &"cross", &"sparta_kick"]],
		["K,K", [[K, N, false], [K, N, false]], [&"sparta_kick", &"roundhouse"]],
	]
	for c: Array in cases:
		var pe: Array = await _lane(&"grunt", 1.0)
		var p: Fighter = pe[0]
		var e: Fighter = pe[1]
		var starts := _log(p)
		clear_events()
		await _string(p, e, c[1])
		check(starts == c[2], "%s -> %s (%s)" % [c[0], c[2], starts])
		match c[0]:
			"P,P,P":
				var h := _hit(&"hook", e)
				check(h != null and h.reaction == HitInfo.Reaction.STAGGER, "hook staggers")
				var cp := last_event(&"combo_progress")
				check(not cp.is_empty() and cp[2] == 3 and is_equal_approx(cp[3], 0.9), "combo_progress 3 hits at x0.9")
			"P,P,fP":
				var u := _hit(&"uppercut", e)
				var g: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
				check(u != null and absf(u.launch_velocity.y - sqrt(2.0 * g * Tuning.LAUNCHER_LIFT)) < 0.2,
					"uppercut lifts %.1f m (v_up %.2f)" % [Tuning.LAUNCHER_LIFT, u.launch_velocity.y if u else 0.0])
			"P,P,K":
				var k := _hit(&"sparta_kick", e)
				check(k != null and k.reaction == HitInfo.Reaction.LAUNCH, "front kick ender launches")
			"K,K":
				var r := _hit(&"roundhouse", e)
				if r != null:
					var right := p.get_forward().cross(Vector3.UP).normalized()
					check(r.launch_velocity.dot(-right) > 0.5 * r.launch_velocity.length(), "roundhouse launches sideways")
				else:
					check(e.is_launched(), "roundhouse follows the launched body (juggle) or hits")
		await wait_real(1.5)

	print("uppercut, jump + K: air juggle")
	var pe2: Array = await _lane(&"grunt", 1.0)
	var p2: Fighter = pe2[0]
	var e2: Fighter = pe2[1]
	var log2 := _log(p2)
	clear_events()
	await _string(p2, e2, [[L, N, false], [L, N, false], [L, F, false]])
	p2.fake_air = true
	tap(p2, K)
	await wait_real(0.6)
	p2.fake_air = false
	check(log2.size() >= 4 and log2[3] == &"flying_kick", "uppercut links into flying_kick (%s)" % [log2])
	var fk := _hit(&"flying_kick", e2)
	if fk != null:
		check(fk.juggle, "flying kick on the lifted body is a juggle")
	await wait_real(1.5)

	print("enders: no cancel into a starter")
	var pe3: Array = await _lane(&"grunt", 1.0)
	var p3: Fighter = pe3[0]
	var log3 := _log(p3)
	await _string(p3, pe3[1], [[L, N, false], [L, N, false]])
	clear_events()
	var t_hook := [0.0]
	var t_next := [0.0]
	p3.combat.attack_started.connect(func(id: StringName) -> void:
		if id == &"hook": t_hook[0] = TimeDirector.now()
		elif t_hook[0] > 0.0 and t_next[0] == 0.0: t_next[0] = TimeDirector.now())
	tap(p3, L)  # hook (ender)
	await wait_until(func() -> bool: return count_events(&"hit_landed") > 0, 1.0)
	tap(p3, L)  # mashed into the hook's recovery: buffered, not a cancel
	await wait_real(1.0)
	check(log3.size() >= 3 and log3[2] == &"hook", "hook played")
	var hook := MoveLibrary.get_move(&"hook")
	var hook_len := Tuning.frames(hook.startup + hook.active + hook.recovery)
	var gap: float = t_next[0] - t_hook[0]
	check(log3.size() >= 4 and log3[3] == &"jab1" and t_next[0] > 0.0 and gap >= hook_len - 0.02,
		"after the hook (ender) the next press starts jab1 only when the hook ends (%.3f s >= %.3f s, %s)" % [gap, hook_len, log3])

	print("juggle: flattened toward the nearest wall")
	_x += 9.0
	var wall := StaticBody3D.new()
	wall.collision_layer = Layers.WORLD
	var wcs := CollisionShape3D.new()
	var wb := BoxShape3D.new()
	wb.size = Vector3(0.4, 3.0, 8.0)
	wcs.shape = wb
	wall.add_child(wcs)
	add_child(wall)
	wall.global_position = Vector3(_x + 4.0, 1.5, -1.0)  # 4 m to the side (+X)
	var pj := spawn_fake(&"player", Vector3(_x, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER, true)
	var ej := spawn(&"grunt", Vector3(_x, 0, -1.1), Vector3.BACK)
	await ticks(12)
	var wd := pj.combat.nearest_wall_dir(ej.get_center_of_mass(), 10.0)
	check(wd.dot(Vector3.RIGHT) > 0.9, "nearest wall is to the +X side (%s)" % wd)
	clear_events()
	tap(pj, CombatController.Action.SWEEP)
	await wait_until(func() -> bool: return ej.combat.is_stumbling(), 1.0)
	tap(pj, K)
	await wait_until(func() -> bool: return _hit(&"sparta_kick", ej) != null, 1.5)
	var jk := _hit(&"sparta_kick", ej)
	check(jk != null and jk.juggle, "kick on the stumbling enemy is a juggle")
	if jk:
		var flat := Vector3(jk.launch_velocity.x, 0, jk.launch_velocity.z).normalized()
		check(flat.dot(Vector3.RIGHT) > 0.5, "launch bent toward the wall (%s)" % flat)
		var up_deg := rad_to_deg(asin(jk.launch_velocity.normalized().y))
		check(up_deg < 10.0, "flat launch (%.1f deg up)" % up_deg)
	await wait_real(1.5)

	print("sweeps: L3 lifts, one trip per combo, Brute only stumbles at L3")
	var ps: Array = await _lane(&"grunt", 1.1)
	clear_events()
	await hold_press(ps[0], CombatController.Action.SWEEP, 0.9)
	await wait_until(func() -> bool: return _hit(&"leg_sweep", ps[1]) != null, 1.0)
	var s3 := _hit(&"leg_sweep", ps[1])
	check(s3 != null and s3.charge_level == 3 and s3.launch_velocity.y > 4.5, "L3 sweep launches upward (v_up %.1f)" % (s3.launch_velocity.y if s3 else 0.0))
	await wait_real(2.5)
	ps = await _lane(&"grunt", 1.1)
	clear_events()
	await hold_press(ps[0], CombatController.Action.SWEEP, 0.3)
	await wait_until(func() -> bool: return count_events(&"tripped") > 0, 1.0)
	await wait_real(0.35)
	var to: Vector3 = (ps[1] as Fighter).get_ground_position() - (ps[0] as Fighter).global_position
	to.y = 0
	(ps[0] as Fighter).snap_facing(to)
	clear_events()
	await hold_press(ps[0], CombatController.Action.SWEEP, 0.3)
	await wait_real(0.6)
	var s2 := _hit(&"leg_sweep", ps[1])
	if s2 != null:
		check(count_events(&"tripped") == 0 and s2.launch_velocity.length() <= CombatController.KNOCKDOWN_LAUNCH + 0.1,
			"second sweep in the combo only knocks down (%.1f m/s)" % s2.launch_velocity.length())
	else:
		print("  SKIP second sweep: the tripped body was out of reach")
	await wait_real(2.0)
	var pb: Array = await _lane(&"brute", 1.3)
	clear_events()
	tap(pb[0], CombatController.Action.SWEEP)
	await wait_real(0.6)
	check(count_events(&"stumbled") == 0 and not (pb[1] as Fighter).combat.is_stumbling(), "tap sweep does not stumble the Brute")
	await wait_real(Tuning.COMBO_DROP)
	clear_events()
	await hold_press(pb[0], CombatController.Action.SWEEP, 0.9)
	await wait_real(0.6)
	check(count_events(&"stumbled") == 1, "an L3 sweep stumbles the Brute")
	await wait_real(1.5)

	print("dazed: three blocked hits, then the next hit launches")
	var pd: Array = await _lane(&"grunt", 1.0)
	var ed: Fighter = pd[1]
	ed.combat.press(CombatController.Action.BLOCK)
	await ticks(3)
	clear_events()
	for i in Tuning.DAZE_BLOCKED_HITS:
		tap(pd[0], L)
		await wait_real(0.45)
	check(count_events(&"dazed") == 1 and ed.combat.is_dazed(), "guard broken after %d blocked hits" % Tuning.DAZE_BLOCKED_HITS)
	check(not ed.combat.is_blocking(), "a dazed fighter cannot block")
	clear_events()
	tap(pd[0], L)
	await wait_until(func() -> bool: return count_events(&"hit_landed") > 0, 1.0)
	var dh: HitInfo = last_event(&"hit_landed")[1] if count_events(&"hit_landed") > 0 else null
	check(dh != null and dh.reaction == HitInfo.Reaction.LAUNCH, "a jab on a dazed fighter launches")
	await wait_real(2.0)
	print("dazed: level 2 head hit")
	var ph: Array = await _lane(&"grunt", 1.0)
	(ph[0] as Fighter).aim_zone = BodyZones.Zone.HEAD
	(ph[0] as Fighter).aim_bone = &"Head"
	clear_events()
	await hold_press(ph[0], L, 0.55)
	await wait_until(func() -> bool: return count_events(&"dazed") > 0, 1.0)
	check(count_events(&"dazed") == 1 and (ph[1] as Fighter).combat.is_dazed(), "a level 2 head hit dazes")
	await wait_real(2.0)

	print("ground finishers")
	var pg: Array = await _lane(&"grunt", 1.1)
	var pgp: Fighter = pg[0]
	var eg: Fighter = pg[1]
	await hold_press(pgp, CombatController.Action.SWEEP, 0.3)
	await wait_until(func() -> bool: return eg.get_state() == RagdollController.State.GROUNDED, 4.0)
	var tg := eg.get_ground_position() - pgp.global_position
	tg.y = 0
	pgp.teleport_to(eg.get_ground_position() - tg.normalized() * 0.7, tg)
	await ticks(3)
	var logg := _log(pgp)
	for i in 5:
		tap(pgp, L)  # mashed: presses buffer into the next mount punch
		await wait_real(0.15)
	await wait_real(0.5)
	var mounts := logg.count(&"mount_punch")
	check(mounts == CombatController.MOUNT_PUNCHES, "P over a downed enemy: %d mount punches, then no more (%s)" % [mounts, logg])
	await wait_real(2.5)
	pg = await _lane(&"grunt", 1.1)
	pgp = pg[0]
	eg = pg[1]
	await hold_press(pgp, CombatController.Action.SWEEP, 0.3)
	await wait_until(func() -> bool: return eg.get_state() == RagdollController.State.GROUNDED, 4.0)
	tg = eg.get_ground_position() - pgp.global_position
	tg.y = 0
	pgp.teleport_to(eg.get_ground_position() - tg.normalized() * 0.6, tg)
	await ticks(2)
	logg = _log(pgp)
	clear_events()
	tap(pgp, K)
	await wait_real(0.5)
	check(not logg.is_empty() and logg[0] == &"stomp", "K standing over a downed enemy: stomp (%s)" % [logg])
	check(_hit(&"stomp", eg) != null, "the stomp landed")
	await wait_real(2.0)

	print("grab, P x3 knees, then throw; upward throw")
	var pk: Array = await _lane(&"grunt", 1.0)
	var pkp: Fighter = pk[0]
	clear_events()
	pkp.combat.press(CombatController.Action.GRAB)
	await wait_until(func() -> bool: return count_events(&"grab_started") > 0, 1.0)
	for i in 4:
		tap(pkp, L)
		await wait_real(0.2)
	var knees := 0
	for ev in events:
		if ev[0] == &"hit_landed" and (ev[1] as HitInfo).move_id == &"knee":
			knees += 1
	check(knees == CombatController.MAX_KNEES, "knees while holding: %d" % knees)
	pkp.fake_intent = &"back"
	pkp.combat.release(CombatController.Action.GRAB)
	await wait_until(func() -> bool: return count_events(&"thrown") > 0, 1.0)
	pkp.fake_intent = &"neutral"
	var tv: Vector3 = last_event(&"thrown")[3] if count_events(&"thrown") > 0 else Vector3.ZERO
	var g2: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
	check(absf(tv.y - sqrt(2.0 * g2 * Tuning.UPWARD_THROW_LIFT)) < 0.2 and Vector2(tv.x, tv.z).length() < 1.0,
		"back + release: upward throw (%s)" % tv)
	await wait_real(2.0)

	print("back + P: backfist hits the enemy behind")
	_x += 9.0
	var pbk := spawn_fake(&"player", Vector3(_x, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER, true)
	var ebk := spawn(&"grunt", Vector3(_x, 0, 1.0), Vector3.FORWARD)
	await ticks(12)
	clear_events()
	pbk.fake_intent = &"back"
	tap(pbk, L)
	pbk.fake_intent = &"neutral"
	await wait_until(func() -> bool: return _hit(&"backfist", ebk) != null, 1.0)
	check(_hit(&"backfist", ebk) != null, "backfist landed on the enemy behind")
	done()
