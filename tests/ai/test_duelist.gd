extends Node
## Round 7 Duelist (docs/Round 7 — Freeflow Combat.md: Enemies): against a
## scripted player dummy (real combat), the Duelist
## 0. reads the player's strikes with its read chance, raised per repeat of the
##    same move (anti-mash; every press of the punch button is one move);
## 1. guards what he reads: Block held (the AI guard), B's guard stops the
##    tapped punches, and he never parries (no GameEvents.parried with him as
##    defender) and never teleports (no &"counter" tell, no jump in position,
##    combat.start_counter never used);
## 2. answers a broken guard with a quick hook (e_hook): a guard breaker (Round
##    8: a charged gut punch, held CHARGE_HOLD s, through the real press and
##    release; else a guard-breaking hit through Fighter.take_hit) gets through
##    his raised guard, and once he can act again an e_hook starts within
##    ANSWER_LIMIT s; he never starts it while reacting or in hitstun;
## 3. punishes a whiffed strike and a whiffed Counter with an e_kick within 1 s.
## Round 8: every hit fills his pressure meter (blocked ones too), and under
## pressure he backs off instead of answering; each step starts with his
## meter drained (_wait_idle), as a fresh Duelist.
## OWNER: agent C (AI tests).

const Util := preload("res://tests/ai/ai_test_util.gd")
## s from the moment the Duelist can act again after a broken guard to his hook.
const ANSWER_LIMIT := 1.0
## m: a jump of the Duelist's position in one tick larger than this is a teleport.
const TELEPORT_JUMP := 0.6
## s the gut punch is held: past Tuning.R8_TAP_MAX, a charged strike (Round 8:
## only charged strikes break a guard), far from full (no outright pressure break).
const CHARGE_HOLD := 0.35

var failures := 0
var player: Fighter
var duelist: Fighter
var brain: AIBrain
var parries := 0
var counter_tells := 0
var teleport_jumps := 0
var blocked := 0
var launches: Array = []        ## [time, move, reacting or stunned at the start]
var acts_at: Array[float] = []   ## times the Duelist could act again after not being able to
var _last_pos := Vector3.INF
var _could_act := true

func _ready() -> void:
	_run.call_deferred()

func check(ok: bool, what: String) -> void:
	print("[ai] %s: %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		failures += 1

func _run() -> void:
	AttackDirector.reset()
	Tuning.difficulty = Tuning.Difficulty.NORMAL
	Util.build_floor(self)
	player = FighterFactory.spawn_dummy(self, &"player", Transform3D(Basis(), Vector3(0, 0.05, 0)), Fighter.TEAM_PLAYER)
	Util.ensure_wired(player)
	AttackDirector.set_player(player)
	duelist = FighterFactory.spawn_enemy(self, &"duelist", Transform3D(Basis.from_euler(Vector3(0, PI, 0)), Vector3(0, 0.05, -1.6)))
	brain = duelist.brain as AIBrain
	if GameEvents.has_signal(&"parried"):
		GameEvents.connect(&"parried", func(d: Node3D, _a: Node3D) -> void:
			if d == duelist: parries += 1)
	GameEvents.attack_tell.connect(func(a: Node3D, kind: StringName, _d: float) -> void:
		if a == duelist and kind == &"counter": counter_tells += 1)
	GameEvents.hit_blocked.connect(func(i: HitInfo) -> void:
		if i.victim == duelist: blocked += 1)
	brain.attack_launched.connect(func(m: StringName) -> void:
		launches.append([Util.game_now(), m, duelist.is_reacting() or duelist.is_lifted() or duelist.is_in_hitstun()]))
	if not player.has_method(&"_physics_process"):
		print("[ai] BLOCKED: fighter.gd is the contract stub")
		_finish()
		return
	set_physics_process(true)

	# Phase 0: anti-mash read chance.
	var base := brain.get_read_chance(0)
	check(base > 0.0 and absf(brain.get_read_chance(1) - (base + AIBrain.MASH_BONUS)) < 0.001
		and absf(brain.get_read_chance(10) - AIBrain.MASH_CAP) < 0.001,
		"anti-mash: read chance %.2f, %.2f after 1 repeat, capped at %.2f" % [base, brain.get_read_chance(1), brain.get_read_chance(10)])
	await _wait(0.5)
	brain._player_moves.clear()
	for m: StringName in [&"jab", &"cross", &"hook", &"heavy_jab"]:
		player.combat.attack_incoming.emit(m, 0.4)
	var punch_entries := 0
	for e: Array in brain._player_moves:
		if e[1] == "punch":
			punch_entries += 1
	check(punch_entries == 4, "jab, cross, hook and heavy jab count as one move, the punch button (%d of 4)" % punch_entries)

	# Phase 1: no tokens (he only reacts), read chance 100 %: tapped jabs.
	AttackDirector.camera_busy = true
	brain.read_chance_override = 1.0
	await _wait(1.0)
	var jabs := 0
	var reads0 := brain.guard_reads
	var blocked0 := blocked
	var guard_seen := 0
	for i in 10:
		await _wait_idle()
		_place_near(1.4)
		await _face_and_wait(0.2)
		jabs += 1
		var r0 := brain.guard_reads
		await _press(CombatController.Action.LIGHT)
		var up := false
		var t0 := Util.game_now()
		while Util.game_now() - t0 < 0.45:
			up = up or duelist.combat.is_blocking()
			await get_tree().physics_frame
		if brain.guard_reads > r0 and up:
			guard_seen += 1
	var reads := brain.guard_reads - reads0
	print("[ai] info: %d jabs: %d reads, %d with the guard up, %d blocked by B's guard" % [jabs, reads, guard_seen, blocked - blocked0])
	check(reads >= jabs - 1, "reads every jab aimed at him with the chance forced to 1 (%d / %d)" % [reads, jabs])
	check(guard_seen >= jabs - 1, "every read raises his guard (Block held) at once (%d / %d)" % [guard_seen, jabs])
	check(blocked - blocked0 >= 1, "his guard blocks tapped jabs (B: hit_blocked, %d)" % (blocked - blocked0))

	# Phase 2: a guard breaker through the raised guard; he answers with a hook.
	var answered := 0
	var breaks := 0
	var delays: Array[String] = []
	var paths := {}
	for attempt in 6:
		AttackDirector.camera_busy = true
		await _wait_idle()
		duelist.hp = duelist.max_hp
		_place_near(1.3)
		await _face_and_wait(0.25)
		var b0 := brain.guard_breaks
		var path := await _break_guard()
		if brain.guard_breaks == b0:
			print("[ai] info: attempt %d: the guard did not break (%s): %s" % [attempt, path, brain.get_debug_text()])
			continue
		breaks += 1
		paths[path] = int(paths.get(path, 0)) + 1
		var t_break := Util.game_now()
		var l0 := launches.size()
		var acts0 := acts_at.size()
		AttackDirector.camera_busy = false
		# His hook: the first launch after the break, once he can act again.
		var t_act := -1.0
		while Util.game_now() - t_break < 4.0 and launches.size() == l0:
			_keep_player()
			if t_act < 0.0 and acts_at.size() > acts0:
				t_act = acts_at[acts0]
			await get_tree().physics_frame
		AttackDirector.camera_busy = true
		if t_act < 0.0 and acts_at.size() > acts0:
			t_act = acts_at[acts0]
		if launches.size() == l0:
			print("[ai] info: attempt %d: no attack within 4 s of the break: %s" % [attempt, brain.get_debug_text()])
			continue
		var l: Array = launches[l0]
		if t_act < 0.0:
			t_act = t_break  # never lost the ability to act (no stun)
		var delay: float = l[0] - t_act
		delays.append("%s %.2f s after he could act (%.2f s after the break)" % [l[1], delay, l[0] - t_break])
		if l[1] == &"e_hook" and not l[2] and delay <= ANSWER_LIMIT:
			answered += 1
		if breaks >= 3:
			break
	print("[ai] info: guard breaks %d (%s), answers: %s" % [breaks, str(paths), "; ".join(delays)])
	check(breaks >= 3, "guard breakers get through his raised guard (%d breaks)" % breaks)
	check(breaks > 0 and answered == breaks,
		"every broken guard is answered with an e_hook within %.1f s of acting again, never while reacting (%d / %d)" % [
			ANSWER_LIMIT, answered, breaks])
	check(brain.guard_answers >= answered, "brain counts its answers (%d)" % brain.guard_answers)

	# Phase 3: whiff punish and whiffed-Counter punish.
	brain.read_chance_override = 0.0
	for kind: StringName in [&"whiff", &"counter_whiff"]:
		var punished := false
		for attempt in 4:
			AttackDirector.camera_busy = true
			await _wait_idle()
			_place_near(2.3)
			await _face_and_wait(0.3)
			var t0 := Util.game_now()
			var l0 := launches.size()
			AttackDirector.camera_busy = false
			if kind == &"whiff":
				GameEvents.attack_whiff.emit(player, &"jab")
			else:
				GameEvents.counter_whiffed.emit(player)
			while Util.game_now() - t0 < 1.2:
				_keep_player()
				await get_tree().physics_frame
			for k in range(l0, launches.size()):
				if launches[k][1] == &"e_kick" and float(launches[k][0]) - t0 < 1.0:
					punished = true
			if punished:
				break
		AttackDirector.camera_busy = true
		check(punished, "punishes a %s within 3 m with an e_kick within 1 s" % ("whiffed strike" if kind == &"whiff" else "whiffed Counter"))

	# Never a parry, never a teleport, never a start while reacting.
	var bad_starts := launches.filter(func(l: Array) -> bool: return l[2]).size()
	check(parries == 0, "never parries (GameEvents.parried with him as defender: %d)" % parries)
	check(counter_tells == 0 and teleport_jumps == 0,
		"never teleports (counter tells %d, position jumps > %.1f m in a tick %d)" % [counter_tells, TELEPORT_JUMP, teleport_jumps])
	check(bad_starts == 0, "never starts an attack while reacting or in hitstun (%d of %d)" % [bad_starts, launches.size()])
	_finish()

func _physics_process(_delta: float) -> void:
	if duelist == null or not is_instance_valid(duelist):
		return
	var p := duelist.get_ground_position()
	if _last_pos != Vector3.INF and Util.flat_dist(p, _last_pos) > TELEPORT_JUMP and not get_meta(&"placing", false):
		teleport_jumps += 1
	_last_pos = p
	set_meta(&"placing", false)
	var can := duelist.can_act() or (duelist.combat.is_attacking() and not duelist.is_reacting())
	if can and not _could_act:
		acts_at.append(Util.game_now())
	_could_act = can

## Break his guard: the gut punch through the real input path (B's guard
## break) when B handles it; else a guard-breaking hit through take_hit after
## a read (his guard up). Returns the path used.
func _break_guard() -> String:
	var b0 := brain.guard_breaks
	await _press(CombatController.Action.GUT_PUNCH, CHARGE_HOLD)
	var t0 := Util.game_now()
	while Util.game_now() - t0 < 0.8 and brain.guard_breaks == b0:
		await get_tree().physics_frame
	if brain.guard_breaks > b0:
		return "real charged gut punch"
	# Fallback: the read (as B's attack_incoming would send it), then a hit B's
	# guard cannot stop.
	await _wait_idle()
	_place_near(1.3)
	brain._on_player_attack_incoming(&"gut_punch", Tuning.frames(10.0))
	await get_tree().physics_frame
	await get_tree().physics_frame
	var up := duelist.combat.is_blocking()
	var info := HitInfo.new()
	info.attacker = player
	info.victim = duelist
	info.kind = &"strike"
	info.move_id = &"gut_punch"
	info.damage = 8.0
	info.unblockable = true
	info.tier = HitInfo.Tier.STAGGER
	info.reaction = HitInfo.Reaction.STAGGER
	info.react = &"fold"
	info.stun = 1.1
	info.push = 0.3
	info.hit_direction = (duelist.get_ground_position() - player.get_ground_position()).normalized()
	info.hit_position = duelist.get_aim_point()
	duelist.take_hit(info)
	return "guard-break hit (guard up %s)" % up

## Press `action` and release it after one tick (a tap) or `hold` s (charged).
func _press(action: int, hold := 0.0) -> void:
	_face(player, duelist)
	player.combat.press(action)
	await get_tree().physics_frame
	var t0 := Util.game_now()
	while Util.game_now() - t0 < hold:
		_face(player, duelist)
		_keep_player()
		await get_tree().physics_frame
	player.combat.release(action)

## Both idle and the Duelist's pressure meter drained (Round 8: under
## pressure he backs off, broken he does nothing).
func _wait_idle() -> void:
	var tw := Util.game_now()
	while (duelist.combat.is_attacking() or not duelist.can_act() or duelist.is_down() or player.is_down()
			or player.is_in_hitstun() or not player.can_act() or duelist.combat.get_pressure() > 0.0
			or duelist.combat.is_broken()) and Util.game_now() - tw < 8.0:
		_keep_player()
		await get_tree().physics_frame
	brain._guard_until = 0.0

## Put the Duelist `dist` m in front of the player, facing it.
func _place_near(dist := 1.4) -> void:
	var f := player.get_forward()
	set_meta(&"placing", true)
	duelist.global_position = player.global_position + f * dist
	duelist.face_dir = -f
	duelist.snap_facing(-f)
	duelist.reset_physics_interpolation()
	_last_pos = Vector3.INF

func _keep_player() -> void:
	if "invuln_until" in player:
		player.set(&"invuln_until", TimeDirector.now() + 5.0)
	if player.hp < player.max_hp * 0.5:
		player.heal_fraction(1.0)

func _face(a: Fighter, b: Fighter) -> void:
	var to := b.get_ground_position() - a.get_ground_position()
	to.y = 0.0
	if to.length() > 0.01:
		a.snap_facing(to)
		a.face_dir = to.normalized()

func _wait(s: float) -> void:
	var t0 := Util.game_now()
	while Util.game_now() - t0 < s:
		_keep_player()
		await get_tree().physics_frame

## Keep the player facing the Duelist (and healthy) for `s` seconds.
func _face_and_wait(s: float) -> void:
	var t0 := Util.game_now()
	while Util.game_now() - t0 < s:
		_face(player, duelist)
		_keep_player()
		await get_tree().physics_frame

func _finish() -> void:
	AttackDirector.reset()
	print("[ai] test_duelist: %s (%d failures)" % ["PASS" if failures == 0 else "FAIL", failures])
	get_tree().quit(0 if failures == 0 else 1)
