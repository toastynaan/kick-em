extends Node
## AttackDirector rules with forceable fighters (independent of combat):
## token cap (Normal and Easy, never above Tuning.TOKEN_MAX), no grants while
## the player is down / held / in hitstun / camera busy, the free swing at a
## knocked-down player (Tuning.DOWNED_FREE_SWINGS, the rest wait), token
## return on attack end / hit / launch / grab / death / fleeing (a holder hit
## mid-attack through its armor keeps it), the swing-spacing rule (first
## active frames >= Tuning.TOKEN_ACTIVE_GAP apart, a string's follow-up
## reserved, startups never stretched), wave startups, rings (holders + next
## in line NEAR). OWNER: agent C (AI tests).

const Util := preload("res://tests/ai/ai_test_util.gd")
const FakeCombat := preload("res://tests/ai/fake_combat.gd")
const FakeBrain := preload("res://tests/ai/fake_brain.gd")

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
	await _test_player_down()
	await _test_spacing()
	await _test_rings()
	await _test_pacing()
	await _test_fleeing_and_armor()
	_test_waves()

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
	var cap: int = mini(Tuning.TOKENS[diff], Tuning.TOKEN_MAX)
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

## Rule 3: no grants while the player is held, in hitstun, or the camera is
## busy. A holder that has not swung loses its token while the player is
## held; in the short states it keeps it but may not swing. (Down: below.)
func _test_player_gates() -> void:
	_release_all()
	var fp := player as Util.FakeFighter
	var gates := {
		"player held by a grab": [func(on: bool) -> void: _force_hold(enemies[4], player, on), true],
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

## Feel Reference (Enemies have to be readable first): while the player is
## knocked down, holders keep their token and get DOWNED_FREE_SWINGS free
## swings; nobody else gets a token; a used-up holder gives the token back.
func _test_player_down() -> void:
	_release_all()
	var fp := player as Util.FakeFighter
	check(await _grant(enemies[1]), "pre-grant before 'player down'")
	fp.fake_down = true
	await get_tree().physics_frame
	await get_tree().physics_frame
	check(AttackDirector.has_token(enemies[1]), "player down: an approaching holder keeps its token for its free swing")
	var granted := 0
	var t0 := AttackDirector.now()
	while AttackDirector.now() - t0 < 0.5:
		for e in enemies:
			if e != enemies[1] and AttackDirector.request_token(e, true):
				granted += 1
		await get_tree().physics_frame
	check(granted == 0, "player down: no new tokens, the rest wait (granted %d)" % granted)
	check(AttackDirector.free_swings_left(enemies[1]) == Tuning.DOWNED_FREE_SWINGS,
		"player down: %d free swing(s) left" % AttackDirector.free_swings_left(enemies[1]))
	var swings := 0
	for i in Tuning.DOWNED_FREE_SWINGS + 2:
		var s := AttackDirector.request_swing(enemies[1], 0.3)
		if s >= 0.0:
			swings += 1
			AttackDirector.notify_attack_started(enemies[1], s)
			enemies[1].combat.attack_ended.emit(&"e_kick")
			await get_tree().physics_frame
			AttackDirector.request_token(enemies[1], true)
	check(swings == Tuning.DOWNED_FREE_SWINGS, "player down: exactly %d free swing(s) taken (%d)" % [Tuning.DOWNED_FREE_SWINGS, swings])
	check(not AttackDirector.has_token(enemies[1]), "player down: no token once the free swing is used")
	fp.fake_down = false
	await get_tree().physics_frame
	_release_all()
	check(await _grant(enemies[2]), "tokens resume after the player gets up")
	check(AttackDirector.free_swings_left(enemies[1]) == Tuning.DOWNED_FREE_SWINGS, "free swings reset after the get-up")
	_release_all()

## Rule 6: two holders' first active frames are >= TOKEN_ACTIVE_GAP apart;
## a swing's startup is never stretched to make room (the enemy waits).
func _test_spacing() -> void:
	_release_all()
	var a := enemies[0]
	var b := enemies[1]
	var startup := Tuning.frames(Tuning.ENEMY_STARTUP[&"e_jab"])
	check(await _grant(a), "spacing: first holder")
	check(await _grant(b), "spacing: second holder (staggered grant)")
	# Real attacks (B's combat on the fake fighters), started the way AIBrain does.
	var actives := {}
	var on_active := func(f: Node3D, _m: StringName) -> void:
		if (f == a or f == b) and not actives.has(f):
			actives[f] = AttackDirector.world_now()
	GameEvents.attack_active.connect(on_active)
	var s_a := AttackDirector.request_swing(a, startup)
	var active_a := AttackDirector.get_scheduled_active(a)
	check(absf(s_a - startup) < 1e-6, "first swing keeps its startup exactly (%.3f s)" % s_a)
	a.combat.start_enemy_attack(&"e_jab", s_a)
	AttackDirector.notify_attack_started(a, a.combat.time_to_active())
	# The second holder asks for the same startup every frame until allowed.
	var s_b := -1.0
	var waited := 0
	var t0 := AttackDirector.now()
	while s_b < 0.0 and AttackDirector.now() - t0 < 1.0:
		s_b = AttackDirector.request_swing(b, startup)
		if s_b < 0.0:
			waited += 1
			await get_tree().physics_frame
	var active_b := AttackDirector.get_scheduled_active(b)
	check(absf(s_b - startup) < 1e-6, "second swing allowed with the same startup %.3f after waiting %d frames" % [s_b, waited])
	check(absf(active_b - active_a) >= Tuning.TOKEN_ACTIVE_GAP - 0.0001,
		"scheduled first active frames %.0f frames apart (>= %.0f)" % [absf(active_b - active_a) * 60.0, Tuning.TOKEN_ACTIVE_GAP * 60.0])
	if s_b >= 0.0:
		b.combat.start_enemy_attack(&"e_jab", s_b)
		AttackDirector.notify_attack_started(b, b.combat.time_to_active())
	t0 = AttackDirector.now()
	while actives.size() < 2 and AttackDirector.now() - t0 < 1.5:
		await get_tree().physics_frame
	GameEvents.attack_active.disconnect(on_active)
	var real_gap: float = absf(float(actives.get(b, INF)) - float(actives.get(a, -INF))) * 60.0
	check(actives.size() == 2 and real_gap >= Tuning.TOKEN_ACTIVE_GAP * 60.0 - 0.01,
		"real first active frames %.1f frames apart (>= %.0f)" % [real_gap, Tuning.TOKEN_ACTIVE_GAP * 60.0])
	while a.combat.is_attacking() or b.combat.is_attacking():
		await get_tree().physics_frame
	_release_all()
	# A string reserves its follow-up: another holder may not land on it.
	check(await _grant(a), "string: holder a")
	check(await _grant(b), "string: holder b")
	var follow := 0.6
	check(AttackDirector.request_swing(a, startup, [follow]) >= 0.0, "string: jab + cross reserved")
	AttackDirector.notify_attack_started(a, startup)
	var cross_at: float = AttackDirector.get_reserved_actives(a)[0]
	var clash := AttackDirector.request_swing(b, cross_at - AttackDirector.world_now())
	check(clash < 0.0, "string: a swing landing on the reserved cross is refused")
	AttackDirector.hold_for_followup(a)
	a.combat.attack_ended.emit(&"e_jab")
	check(AttackDirector.has_token(a), "string: the holder keeps its token between the jab and the cross")
	check(absf(AttackDirector.get_scheduled_active(a) - cross_at) < 1e-6, "string: the cross's reservation is now the holder's next active frame")
	a.combat.attack_ended.emit(&"e_hook")
	check(not AttackDirector.has_token(a), "string: token returned after the last hit")
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

## A fleeing enemy (lost a limb) gets no token and loses a held one; a holder
## hit while its attack carries on (a heavy's armor) keeps its token.
func _test_fleeing_and_armor() -> void:
	_release_all()
	await _wait(1.5)
	var e := enemies[3]
	var fb: Node = FakeBrain.new()
	e.add_child(fb)
	var old_brain := e.brain
	e.brain = fb
	check(await _grant(e), "fleeing: token granted before")
	fb.fleeing = true
	GameEvents.fleeing_changed.emit(e, true)
	check(not AttackDirector.has_token(e), "fleeing: token returned when it starts fleeing")
	check(not AttackDirector.request_token(e, true) and AttackDirector.get_last_denial(e) == "fleeing",
		"fleeing: no token while fleeing (%s)" % AttackDirector.get_last_denial(e))
	check(AttackDirector.get_ring(e) == AttackDirector.Ring.FAR, "fleeing: never in line (FAR)")
	fb.fleeing = false
	e.brain = old_brain
	fb.queue_free()
	_release_all()
	await _wait(0.4)
	# Armor: the holder is still attacking after the hit.
	var h := enemies[4]
	var fc: FakeCombat = FakeCombat.new()
	fc.name = "FakeCombat"
	fc.setup(h)
	h.add_child(fc)
	var real_combat := h.combat
	h.combat = fc
	check(await _grant(h), "armor: token granted")
	fc.fake_attacking = true
	AttackDirector.notify_attack_started(h, 0.3)
	var info := HitInfo.new()
	info.attacker = player
	info.victim = h
	info.tier = HitInfo.Tier.FLINCH
	GameEvents.hit_landed.emit(info)
	check(AttackDirector.has_token(h), "armor: a holder hit mid-attack (ignore_flinch) keeps its token")
	fc.fake_attacking = false
	h.combat = real_combat
	fc.queue_free()
	_release_all()

## Enemy startup per wave (Tuning.ENEMY_STARTUP; early never under 18 frames;
## from wave 5, 2 frames faster per wave down to 12).
func _test_waves() -> void:
	var early_min := INF
	for w in range(0, Tuning.ENEMY_STARTUP_SHRINK_FROM):
		AttackDirector.set_wave(w)
		for m: StringName in Tuning.ENEMY_STARTUP:
			early_min = minf(early_min, AttackDirector.enemy_startup_frames(m))
	check(early_min >= Tuning.ENEMY_STARTUP_EARLY_MIN, "waves 1-4: no enemy startup under %.0f frames (min %.0f)" % [Tuning.ENEMY_STARTUP_EARLY_MIN, early_min])
	AttackDirector.set_wave(1)
	var jab1 := AttackDirector.enemy_startup_frames(&"e_jab")
	var heavy1 := AttackDirector.enemy_startup_frames(&"e_heavy")
	check(jab1 == 18.0 and AttackDirector.enemy_startup_frames(&"e_hook") == 22.0 and heavy1 == 30.0,
		"wave 1: jab 18, cross 22, smash 30 frames (got %.0f, %.0f, %.0f)" % [jab1, AttackDirector.enemy_startup_frames(&"e_hook"), heavy1])
	var row := []
	for w in [5, 6, 7, 8, 12]:
		AttackDirector.set_wave(w)
		row.append("w%d jab %.0f smash %.0f" % [w, AttackDirector.enemy_startup_frames(&"e_jab"), AttackDirector.enemy_startup_frames(&"e_heavy")])
	AttackDirector.set_wave(5)
	var j5 := AttackDirector.enemy_startup_frames(&"e_jab")
	AttackDirector.set_wave(6)
	var j6 := AttackDirector.enemy_startup_frames(&"e_jab")
	AttackDirector.set_wave(12)
	var j12 := AttackDirector.enemy_startup_frames(&"e_jab")
	var h12 := AttackDirector.enemy_startup_frames(&"e_heavy")
	AttackDirector.set_wave(30)
	var h30 := AttackDirector.enemy_startup_frames(&"e_heavy")
	check(j5 == 16.0 and j6 == 14.0 and j12 == 12.0 and h12 == 14.0 and h30 == 12.0,
		"from wave 5: 2 frames faster per wave, floor 12 (%s; wave 30 smash %.0f)" % [", ".join(row), h30])
	GameEvents.wave_started.emit(4, 8)
	check(AttackDirector.wave_index == 5, "GameEvents.wave_started(index 4) sets wave 5 (got %d)" % AttackDirector.wave_index)
	AttackDirector.set_wave(0)

## G's Carry: a hold needs both sides (the victim's holder and the holder's
## `held`), or Carry clears it on the next tick.
func _force_hold(holder: Fighter, victim: Fighter, on: bool) -> void:
	holder.carry.held = victim if on else null
	victim.carry.set(&"_holder", holder if on else null)

func _wait(seconds: float) -> void:
	var t0 := AttackDirector.now()
	while AttackDirector.now() - t0 < seconds:
		await get_tree().physics_frame
