extends Node
## Duelist reactions against a scripted player dummy (needs agent B's combat):
## 1. Perfect dodge: with dodge chance forced to 1, the Duelist presses block
##    just before the player's jab goes active and B's dodge logic fires
##    GameEvents.perfect_dodge(defender = duelist).
## 2. Counter (BT3 vanish exchange): after a dodge it either teleports
##    behind the player with combat.start_counter (when B has it and it has
##    Focus) or sidesteps >= 1 m and hooks; it only attacks once visible.
## 3. Whiff punish: a jab at air within 3 m draws a quick e_kick.
## 0. Anti-mash: repeats of the same player move raise the dodge chance.
## OWNER: agent C (AI tests).

const Util := preload("res://tests/ai/ai_test_util.gd")

var failures := 0
var player: Fighter
var duelist: Fighter
var brain: AIBrain
var dodges: Array[float] = []
var launches: Array = []   ## [time, move]
var whiffs: Array[float] = []
var dodge_pos := Vector3.ZERO  ## Duelist position when its last dodge fired

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
	duelist = FighterFactory.spawn_enemy(self, &"duelist", Transform3D(Basis.from_euler(Vector3(0, PI, 0)), Vector3(0, 0.05, -2.0)))
	brain = duelist.brain as AIBrain
	GameEvents.perfect_dodge.connect(func(d: Node3D, _a: Node3D) -> void:
		if d == duelist:
			dodges.append(Util.game_now())
			dodge_pos = duelist.get_ground_position())
	GameEvents.attack_whiff.connect(func(a: Node3D, _m: StringName) -> void:
		if a == player: whiffs.append(Util.game_now()))
	brain.attack_launched.connect(func(m: StringName) -> void:
		var vanished := duelist.combat.has_method(&"is_vanished") and duelist.combat.is_vanished()
		launches.append([Util.game_now(), m, vanished, duelist.get_ground_position()]))

	if not player.has_method(&"_physics_process"):
		print("[ai] BLOCKED: fighter.gd is the contract stub")
		_finish()
		return

	# Phase 0: anti-mash chance.
	var base := brain.get_dodge_chance(0)
	check(absf(brain.get_dodge_chance(1) - (base + AIBrain.MASH_BONUS)) < 0.001
		and absf(brain.get_dodge_chance(10) - AIBrain.MASH_CAP) < 0.001,
		"anti-mash: %.2f, %.2f after 1 repeat, capped at %.2f" % [base, brain.get_dodge_chance(1), brain.get_dodge_chance(10)])
	await _wait(0.5)
	for i in 3:
		player.combat.attack_incoming.emit(&"jab%d" % (i + 1), 0.4)
	var jab_entries := 0
	for m: Array in brain._player_moves:
		if m[1] == "jab":
			jab_entries += 1
	check(jab_entries == 3, "jab1-3 count as repeats of one move (%d)" % jab_entries)

	# Phase 1: no tokens (the Duelist only reacts), dodge chance 100 %.
	AttackDirector.camera_busy = true
	brain.dodge_chance_override = 1.0
	await _wait(1.5)
	var presses := 0
	for i in 8:
		await _face_and_wait(1.3)
		if _dist() > AIBrain.DODGE_RANGE or not duelist.can_act():
			continue
		presses += 1
		await _jab()
	check(presses >= 5 and dodges.size() >= presses - 1,
		"perfect-dodges forced-chance jabs (%d dodges / %d jabs)" % [dodges.size(), presses])

	# Phase 2: the counter after a dodge, with Focus (teleport behind the
	# player via start_counter when B has it) and without (sidestep + hook).
	var with_tp := duelist.combat.has_method(&"start_counter")
	var info := await _counter_attempts(2.0)
	check(info[0], "with Focus: counters within 1.3 s of a dodge, only once visible (%s)" % info[1])
	check(not with_tp or info[2] == &"counter", "with Focus: the counter is the teleport (start_counter): %s" % info[2])
	info = await _counter_attempts(0.0)
	check(info[0], "without Focus: counters within 1.3 s of a dodge, only once visible (%s)" % info[1])
	check(info[3] >= 1.0, "without Focus: the dodge is a visible sidestep >= 1 m (%.2f m)" % info[3])

	# Phase 3: whiff punish. No dodging; the Duelist stands just out of jab
	# reach, tokens stay off until the whiff (then it may punish at once).
	brain.dodge_chance_override = 0.0
	AttackDirector.camera_busy = true
	var open_on_whiff := func(a: Node3D, _m: StringName) -> void:
		if a == player:
			AttackDirector.camera_busy = false
	GameEvents.attack_whiff.connect(open_on_whiff)
	await _wait(0.8)
	var punished := false
	var tries := 0
	var seen_whiffs := 0
	for attempt in 8:
		AttackDirector.camera_busy = true
		var tw := Util.game_now()
		while (duelist.combat.is_attacking() or not duelist.can_act() or player.is_down()) \
				and Util.game_now() - tw < 4.0:
			await get_tree().physics_frame
		_place_near(2.3)
		await _face_and_wait(0.3)
		tries += 1
		var before := whiffs.size()
		await _jab()
		if whiffs.size() == before:
			continue
		seen_whiffs += 1
		var t_whiff: float = whiffs[-1]
		while Util.game_now() - t_whiff < 1.2:
			_keep_player()
			await get_tree().physics_frame
		for l in launches:
			if l[0] >= t_whiff - 0.02 and l[0] - t_whiff < 1.0 and l[1] == &"e_kick":
				punished = true
		if punished:
			break
	GameEvents.attack_whiff.disconnect(open_on_whiff)
	AttackDirector.camera_busy = true
	check(punished, "punishes a whiffed jab with an e_kick within 1 s (%d jabs, %d whiffs)" % [tries, seen_whiffs])
	_finish()

## Jab at the Duelist until it dodges and counters. Returns [countered and
## visible, description, counter move, distance moved before the counter].
func _counter_attempts(focus: float) -> Array:
	var open_on_dodge := func(d: Node3D, _a: Node3D) -> void:
		if d == duelist:
			AttackDirector.camera_busy = false
	GameEvents.perfect_dodge.connect(open_on_dodge)
	var result := [false, "no dodge", &"", 0.0]
	for attempt in 8:
		AttackDirector.camera_busy = true
		var tw := Util.game_now()
		while (duelist.combat.is_attacking() or not duelist.can_act() or player.is_down()) \
				and Util.game_now() - tw < 4.0:
			await get_tree().physics_frame
		duelist.focus = focus
		await _face_and_wait(0.3)
		if _dist() > AIBrain.DODGE_RANGE - 0.3:
			_place_near()
			await _face_and_wait(0.3)
		var before := dodges.size()
		await _jab()
		if dodges.size() == before:
			continue
		var t_dodge: float = dodges[-1]
		var start_pos := dodge_pos
		var stepped := 0.0
		var t0 := Util.game_now()
		while Util.game_now() - t0 < 1.5:
			_keep_player()
			# The sidestep runs in the dodge's slow motion: watch it for 0.8 s.
			if Util.game_now() - t_dodge < 0.8 and not duelist.combat.is_attacking():
				stepped = maxf(stepped, Util.flat_dist(duelist.get_ground_position(), start_pos))
			await get_tree().physics_frame
		for l in launches:
			if l[0] > t_dodge and l[0] - t_dodge < 1.3 and l[1] in [&"e_hook", &"counter"]:
				result = [not l[2], "%s %.2f s after the dodge, visible %s" % [l[1], l[0] - t_dodge, not l[2]],
					l[1], stepped]
				break
		if result[0]:
			break
	GameEvents.perfect_dodge.disconnect(open_on_dodge)
	AttackDirector.camera_busy = true
	return result

## Put the Duelist `dist` m in front of the player, facing it.
func _place_near(dist := 2.0) -> void:
	var f := player.get_forward()
	duelist.global_position = player.global_position + f * dist
	duelist.face_dir = -f
	if duelist.has_method(&"snap_facing"):
		duelist.snap_facing(-f)
	duelist.reset_physics_interpolation()

func _keep_player() -> void:
	if "invuln_until" in player:
		player.set(&"invuln_until", TimeDirector.now() + 5.0)

func _dist() -> float:
	return Util.flat_dist(player.get_ground_position(), duelist.get_ground_position())

func _wait(s: float) -> void:
	var t0 := Util.game_now()
	while Util.game_now() - t0 < s:
		await get_tree().physics_frame

## Keep the player facing the Duelist (and healthy) for `s` seconds.
func _face_and_wait(s: float) -> void:
	var t0 := Util.game_now()
	while Util.game_now() - t0 < s:
		var to := duelist.get_ground_position() - player.get_ground_position()
		to.y = 0.0
		if to.length() > 0.05:
			player.face_dir = to.normalized()
		if player.hp < player.max_hp * 0.5:
			player.heal_fraction(1.0)
		await get_tree().physics_frame

func _jab() -> void:
	var to := duelist.get_ground_position() - player.get_ground_position()
	to.y = 0.0
	if player.has_method(&"snap_facing"):
		player.snap_facing(to)
	player.combat.press(CombatController.Action.LIGHT)
	await get_tree().physics_frame
	player.combat.release(CombatController.Action.LIGHT)
	await _wait(0.4)

func _finish() -> void:
	AttackDirector.reset()
	print("[ai] test_dodge: %s (%d failures)" % ["PASS" if failures == 0 else "FAIL", failures])
	get_tree().quit(0 if failures == 0 else 1)
