extends Node
## AttackDirector rules with forceable fighters (independent of combat):
## token cap (Normal and Easy), no grants while the player is down / held /
## in hitstun / camera busy, token return on attack end / hit / launch /
## grab / death, the swing-spacing rule, rings (holders + next in line NEAR).
## OWNER: agent C (AI tests).

const Util := preload("res://tests/ai/ai_test_util.gd")

var failures := 0
var player: Fighter
var enemies: Array[Fighter] = []

func _ready() -> void:
	_run.call_deferred()

func check(ok: bool, what: String) -> void:
	print("[ai] %s: %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		failures += 1

func _run() -> void:
	AttackDirector.reset()
	Util.build_floor(self)
	player = Util.spawn_fake(self, &"player", Fighter.TEAM_PLAYER, Vector3(0, 0.05, 0))
	AttackDirector.set_player(player)
	for i in 5:
		var a := TAU * i / 5.0
		var e := Util.spawn_fake(self, &"grunt", Fighter.TEAM_ENEMY, Vector3(cos(a) * 3.0, 0.05, sin(a) * 3.0))
		AttackDirector.register_enemy(e)
		enemies.append(e)
	await get_tree().physics_frame

	await _test_cap(Tuning.Difficulty.NORMAL)
	await _test_cap(Tuning.Difficulty.EASY)
	Tuning.difficulty = Tuning.Difficulty.NORMAL
	await _test_returns()
	await _test_player_gates()
	await _test_spacing()
	await _test_rings()
	await _test_pacing()

	AttackDirector.reset()
	print("[ai] test_director: %s (%d failures)" % ["PASS" if failures == 0 else "FAIL", failures])
	get_tree().quit(0 if failures == 0 else 1)

func _release_all() -> void:
	for e in enemies:
		AttackDirector.release_token(e)

## Every enemy asks every frame for 2 s; the holder count never exceeds the cap.
func _test_cap(diff: int) -> void:
	_release_all()
	Tuning.difficulty = diff
	var cap: int = Tuning.TOKENS[diff]
	var max_seen := 0
	var t0 := AttackDirector.now()
	while AttackDirector.now() - t0 < 2.5:
		for e in enemies:
			AttackDirector.request_token(e)
		max_seen = maxi(max_seen, AttackDirector.get_token_holders().size())
		await get_tree().physics_frame
	check(max_seen == cap, "difficulty %d: max %d holders with 5 askers (cap %d)" % [diff, max_seen, cap])
	_release_all()

## Urgent requests skip the crowd pacing (tested on its own in _test_pacing).
func _grant(e: Fighter) -> bool:
	var t0 := AttackDirector.now()
	while AttackDirector.now() - t0 < 1.0:
		if AttackDirector.request_token(e, true):
			return true
		await get_tree().physics_frame
	return false

func _test_returns() -> void:
	_release_all()
	var e := enemies[0]
	check(await _grant(e), "token granted to a lone asker")
	e.combat.attack_ended.emit(&"e_hook")
	check(not AttackDirector.has_token(e), "token returned on combat.attack_ended")

	check(await _grant(e), "token granted again")
	var info := HitInfo.new()
	info.attacker = player
	info.victim = e
	GameEvents.hit_landed.emit(info)
	check(not AttackDirector.has_token(e), "token returned when the holder is hit")

	check(await _grant(e), "token granted again (launch)")
	GameEvents.fighter_launched.emit(e, Vector3(5, 1, 0))
	check(not AttackDirector.has_token(e), "token returned when the holder is launched")

	check(await _grant(e), "token granted again (grab)")
	GameEvents.grab_started.emit(player, e)
	check(not AttackDirector.has_token(e), "token returned when the holder is grabbed")

	check(await _grant(e), "token granted again (down)")
	(e as Util.FakeFighter).fake_down = true
	await get_tree().physics_frame
	await get_tree().physics_frame
	check(not AttackDirector.has_token(e), "token returned when the holder goes down")
	(e as Util.FakeFighter).fake_down = false

	# Death: use a spare enemy so the others stay registered.
	var spare := Util.spawn_fake(self, &"grunt", Fighter.TEAM_ENEMY, Vector3(0, 0.05, -5))
	AttackDirector.register_enemy(spare)
	check(await _grant(spare), "token granted to the spare enemy")
	spare.hp = 0.0
	GameEvents.fighter_died.emit(spare, null)
	check(not AttackDirector.has_token(spare) and not spare in AttackDirector.get_enemies(),
		"token returned and enemy unregistered on death")
	spare.queue_free()
	await get_tree().physics_frame

## Rule 3: no grants while the player is down, held, in hitstun, or the
## camera is busy. A holder that has not swung loses its token while the
## player is down or held; in the short states it keeps it but may not swing.
func _test_player_gates() -> void:
	_release_all()
	var fp := player as Util.FakeFighter
	var gates := {
		"player down": [func(on: bool) -> void: fp.fake_down = on, true],
		"player held by a grab": [func(on: bool) -> void: player.combat.held_by = enemies[4] if on else null, true],
		"player in hitstun": [func(on: bool) -> void: fp.fake_hitstun = on, false],
		"camera busy (follow-cam)": [func(on: bool) -> void: AttackDirector.camera_busy = on, false],
	}
	for gate_name: String in gates:
		var setter: Callable = gates[gate_name][0]
		var revokes: bool = gates[gate_name][1]
		check(await _grant(enemies[1]), "pre-grant before '%s'" % gate_name)
		setter.call(true)
		var granted := 0
		var swings := 0
		var t0 := AttackDirector.now()
		while AttackDirector.now() - t0 < 0.6:
			for e in enemies:
				if e != enemies[1] and AttackDirector.request_token(e, true):
					granted += 1
			if AttackDirector.request_swing(enemies[1], 0.4) >= 0.0:
				swings += 1
			await get_tree().physics_frame
		check(granted == 0 and swings == 0, "no new tokens and no swings while %s (granted %d, swings %d)" % [gate_name, granted, swings])
		if revokes:
			check(not AttackDirector.has_token(enemies[1]), "%s: an approaching holder loses its token" % gate_name)
		else:
			check(AttackDirector.has_token(enemies[1]), "%s: an approaching holder keeps its token but waits" % gate_name)
		setter.call(false)
		_release_all()
		check(await _grant(enemies[2]), "tokens resume after '%s' clears" % gate_name)
		_release_all()

## Rule 6: two holders' first active frames are >= SWING_SPACING apart.
func _test_spacing() -> void:
	_release_all()
	var a := enemies[0]
	var b := enemies[1]
	check(await _grant(a), "spacing: first holder")
	check(await _grant(b), "spacing: second holder (staggered grant)")
	var tell_a := AttackDirector.request_swing(a, 0.4)
	var active_a := AttackDirector.get_scheduled_active(a)
	check(tell_a >= Tuning.TELL_MIN and tell_a <= Tuning.TELL_MAX, "first swing gets tell %.3f" % tell_a)
	AttackDirector.notify_attack_started(a, tell_a)
	# The second holder asks for the same tell every frame until allowed.
	var tell_b := -1.0
	var waited := 0
	var t0 := AttackDirector.now()
	while tell_b < 0.0 and AttackDirector.now() - t0 < 1.0:
		tell_b = AttackDirector.request_swing(b, 0.4)
		if tell_b < 0.0:
			waited += 1
			await get_tree().physics_frame
	var active_b := AttackDirector.get_scheduled_active(b)
	check(tell_b >= Tuning.TELL_MIN and tell_b <= Tuning.TELL_MAX,
		"second swing allowed with tell %.3f after %d frames" % [tell_b, waited])
	check(absf(active_b - active_a) >= Tuning.SWING_SPACING - 0.0001,
		"active frames %.3f s apart (>= %.2f)" % [absf(active_b - active_a), Tuning.SWING_SPACING])
	# A tell outside the range is never returned.
	check(AttackDirector.request_swing(b, 5.0) <= Tuning.TELL_MAX, "tell clamped to TELL_MAX")
	_release_all()
	# Grants themselves are staggered by GRANT_GAP.
	var times: Array[float] = []
	t0 = AttackDirector.now()
	while times.size() < 2 and AttackDirector.now() - t0 < 2.0:
		for e in [enemies[2], enemies[3]]:
			if not AttackDirector.has_token(e) and AttackDirector.request_token(e, true):
				times.append(AttackDirector.now())
		await get_tree().physics_frame
	check(times.size() == 2 and times[1] - times[0] >= AttackDirector.GRANT_GAP - 0.0001,
		"grants staggered by >= %.2f s (%s)" % [AttackDirector.GRANT_GAP, str(times)])
	_release_all()

## Rule 2: holders and the next in line (one per free token, at least one)
## are NEAR, everyone else FAR.
func _test_rings() -> void:
	_release_all()
	await get_tree().physics_frame
	var near := 0
	for e in enemies:
		if AttackDirector.get_ring(e) == AttackDirector.Ring.NEAR:
			near += 1
	var want := AttackDirector.get_token_count() + 1
	check(near == want, "no holders: %d NEAR (one in line per free token + a standby), got %d" % [want, near])
	await _grant(enemies[3])
	await get_tree().physics_frame
	near = 0
	for e in enemies:
		if AttackDirector.get_ring(e) == AttackDirector.Ring.NEAR:
			near += 1
	var want1 := 1 + (AttackDirector.get_token_count() - 1) + 1
	check(AttackDirector.get_ring(enemies[3]) == AttackDirector.Ring.NEAR and near == want1,
		"1 holder: holder NEAR + %d in line (%d NEAR)" % [want1 - 1, near])
	var next := AttackDirector.get_next_in_line()
	check(next != null and next != enemies[3], "next in line is a non-holder")
	check(AttackDirector.get_ring(player) == AttackDirector.Ring.NONE, "unregistered fighter has ring NONE")
	_release_all()

## Crowd pacing: after a grant the next normal grant waits ATTACK_INTERVAL x
## CROWD_PACE; urgent requests skip it.
func _test_pacing() -> void:
	_release_all()
	await _wait(2.0)  # let any earlier pacing lapse
	check(AttackDirector.request_token(enemies[0]), "pacing: first normal request granted")
	var t0 := AttackDirector.now()
	var second := -1.0
	while AttackDirector.now() - t0 < 3.0 and second < 0.0:
		if AttackDirector.request_token(enemies[1]):
			second = AttackDirector.now() - t0
		await get_tree().physics_frame
	var pace: float = AttackDirector.CROWD_PACE[Tuning.difficulty]
	check(second >= Tuning.ATTACK_INTERVAL.x * pace - 0.02 and second <= Tuning.ATTACK_INTERVAL.y * pace + 0.1,
		"pacing: second normal grant after %.2f s (%.1f-%.1f)" % [second, Tuning.ATTACK_INTERVAL.x * pace, Tuning.ATTACK_INTERVAL.y * pace])
	_release_all()
	await _wait(Tuning.ATTACK_INTERVAL.y * pace + 0.1)
	check(AttackDirector.request_token(enemies[2]), "pacing: normal grant once the pace has passed")
	await _wait(0.3)
	check(not AttackDirector.request_token(enemies[3]) and AttackDirector.request_token(enemies[3], true),
		"pacing: a normal request waits, an urgent one goes through")
	_release_all()

func _wait(seconds: float) -> void:
	var t0 := AttackDirector.now()
	while AttackDirector.now() - t0 < seconds:
		await get_tree().physics_frame
