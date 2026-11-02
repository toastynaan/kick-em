extends Node
## Duelist reactions against a scripted player dummy (real combat and defence).
## Round 5 defence model (H's Defence on): the Duelist READS a player strike
## by tapping Block in Tuning.PARRY_WINDOW (H's parry: GameEvents.parried, the
## player is staggered), then COUNTERS once the player can be attacked: with
## Focus, AIBrain.DUELIST_TELEPORT_SHARE of the time B's start_counter
## (teleport behind him, orange tell, back kick), else a quick hook. With
## Defence off (debug) the Upgrade 2 perfect dodge is the read. Checks:
## 0. Anti-mash: repeats of the same player move raise the read chance.
## 1. With the read chance forced to 1, every jab within reach is read.
## 2. After a read it counters: with Focus (teleport share forced to 1) the
##    teleport counter at once; without Focus a parry (or perfect dodge +
##    sidestep) and a quick hook within COUNTER_LIMIT s, swung only once
##    visible and once the parried player can act again (never in hitstun).
## 3. Whiff punish: a jab at air within 3 m draws a quick e_kick.
## OWNER: agent C (AI tests).

const Util := preload("res://tests/ai/ai_test_util.gd")
## s after the read in which the counter must start (the parried player's
## stagger ~0.8 s plus the freeze comes first).
const COUNTER_LIMIT := 1.8

var failures := 0
var player: Fighter
var duelist: Fighter
var brain: AIBrain
var reads: Array = []      ## [time, kind (&"parry" | &"dodge" | &"teleport"), duelist position]
var launches: Array = []   ## [time, move, vanished, position]
var whiffs: Array[float] = []

func _ready() -> void:
	_run.call_deferred()

func check(ok: bool, what: String) -> void:
	print("[ai] %s: %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		failures += 1

func _defence_on() -> bool:
	return duelist.defence != null and duelist.defence.is_enabled()

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
		if d == duelist: reads.append([Util.game_now(), &"dodge", duelist.get_ground_position()]))
	GameEvents.parried.connect(func(d: Node3D, _a: Node3D) -> void:
		if d == duelist: reads.append([Util.game_now(), &"parry", duelist.get_ground_position()]))
	GameEvents.attack_whiff.connect(func(a: Node3D, _m: StringName) -> void:
		if a == player: whiffs.append(Util.game_now()))
	brain.attack_launched.connect(func(m: StringName) -> void:
		var vanished := duelist.combat.has_method(&"is_vanished") and duelist.combat.is_vanished()
		launches.append([Util.game_now(), m, vanished, duelist.get_ground_position()]))

	if not player.has_method(&"_physics_process"):
		print("[ai] BLOCKED: fighter.gd is the contract stub")
		_finish()
		return
	print("[ai] info: Round 5 Defence %s" % ("ON (parry, then hook or teleport counter)" if _defence_on() else "off (Upgrade 2 perfect dodge)"))

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

	# Phase 1: no tokens (the Duelist only reacts), read chance 100 %, parry only.
	AttackDirector.camera_busy = true
	brain.dodge_chance_override = 1.0
	brain.teleport_share_override = 0.0
	await _wait(1.5)
	var presses := 0
	var before_all := reads.size()
	for i in 8:
		await _face_and_wait(1.3)
		if _dist() > AIBrain.DODGE_RANGE or not duelist.can_act():
			continue
		presses += 1
		await _jab()
	var got := reads.size() - before_all
	check(presses >= 5 and got >= presses - 1,
		"reads forced-chance jabs (%d reads %s / %d jabs)" % [got, str(_kinds(before_all)), presses])

	# Phase 2: the counter after a read, with Focus (teleport counter when the
	# Defence is on: start_counter; before it, perfect dodge + start_counter)
	# and without (parry or dodge + sidestep, then a hook once visible).
	var with_tp := duelist.combat.has_method(&"start_counter")
	brain.teleport_share_override = 1.0
	var info := await _counter_attempts(2.0)
	check(info[0], "with Focus: counters within %.1f s of a read (%s)" % [COUNTER_LIMIT, info[1]])
	if _defence_on():
		check(info[4] == &"parry", "with Focus: the read is a parry (%s)" % info[4])
	check(not with_tp or info[2] == &"counter", "with Focus: the counter is the teleport (start_counter): %s" % info[2])
	brain.teleport_share_override = 0.0
	info = await _counter_attempts(0.0)
	check(info[0], "without Focus: counters with a hook within %.1f s of a read, only once visible (%s)" % [COUNTER_LIMIT, info[1]])
	if _defence_on():
		check(info[4] == &"parry", "without Focus: the read is a parry (%s)" % info[4])
	else:
		check(info[3] >= 1.0, "without Focus: the dodge is a visible sidestep >= 1 m (%.2f m)" % info[3])

	# Phase 3: whiff punish. No reads; the Duelist stands just out of jab
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
		await _wait_duelist_idle()
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

func _kinds(from: int) -> Dictionary:
	var out := {}
	for i in range(from, reads.size()):
		out[reads[i][1]] = out.get(reads[i][1], 0) + 1
	return out

func _wait_duelist_idle() -> void:
	var tw := Util.game_now()
	while (duelist.combat.is_attacking() or not duelist.can_act() or player.is_down() or player.is_in_hitstun()) \
			and Util.game_now() - tw < 4.0:
		_keep_player()
		await get_tree().physics_frame

## Jab at the Duelist until it reads and counters. Returns [countered (and
## visible for a hook), description, counter move, distance moved before the
## counter, read kind].
func _counter_attempts(focus: float) -> Array:
	var open_on_read := func() -> void:
		AttackDirector.camera_busy = false
	var result := [false, "no read", &"", 0.0, &""]
	# The teleport counter needs a turn at the moment of the read: tokens stay
	# open for those attempts (the Duelist may also swing on its own between).
	var keep_open := focus >= Tuning.TELEPORT_COST
	for attempt in 8:
		AttackDirector.camera_busy = true
		await _wait_duelist_idle()
		AttackDirector.camera_busy = not keep_open
		duelist.focus = focus
		duelist.hp = duelist.max_hp
		# Inside the jab's reach, so H's Defence counts it as aimed at him.
		_place_near(1.6)
		await _face_and_wait(0.3)
		var before := reads.size()
		var launches_before := launches.size()
		# The read opens the tokens for the counter.
		var t_start := Util.game_now()
		await _jab_until_read(before, open_on_read)
		if reads.size() == before:
			print("[ai] info: no read (dist %.2f, duelist can_act %s attacking %s, player down %s hitstun %s): %s" % [
				_dist(), duelist.can_act(), duelist.combat.is_attacking(), player.is_down(), player.is_in_hitstun(), brain.get_debug_text()])
			continue
		var t_read: float = reads[before][0]
		var kind: StringName = reads[before][1]
		var start_pos: Vector3 = reads[before][2]
		var stepped := 0.0
		result[1] = "read (%s) but no counter within %.1f s" % [kind, COUNTER_LIMIT]
		result[4] = kind
		var t0 := Util.game_now()
		while Util.game_now() - t0 < COUNTER_LIMIT + 0.2:
			_keep_player()
			if Util.game_now() - t_read < 0.8 and not duelist.combat.is_attacking():
				stepped = maxf(stepped, Util.flat_dist(duelist.get_ground_position(), start_pos))
			await get_tree().physics_frame
		for k in range(launches_before, launches.size()):
			var l: Array = launches[k]
			if l[0] >= t_start and l[0] - t_read < COUNTER_LIMIT and l[1] in [&"e_hook", &"counter"]:
				var visible_ok: bool = l[1] == &"counter" or not l[2]
				result = [visible_ok, "%s %.2f s after the %s, visible %s" % [l[1], l[0] - t_read, kind, not l[2]],
					l[1], stepped, kind]
				break
		if result[0]:
			break
	AttackDirector.camera_busy = true
	return result

## One jab; the tokens open as soon as a read is logged.
func _jab_until_read(before: int, open: Callable) -> void:
	var to := duelist.get_ground_position() - player.get_ground_position()
	to.y = 0.0
	if player.has_method(&"snap_facing"):
		player.snap_facing(to)
	player.combat.press(CombatController.Action.LIGHT)
	await get_tree().physics_frame
	player.combat.release(CombatController.Action.LIGHT)
	var t0 := Util.game_now()
	while Util.game_now() - t0 < 0.4:
		if reads.size() > before:
			open.call()
		await get_tree().physics_frame
	if reads.size() > before:
		open.call()

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
	if player.hp < player.max_hp * 0.5:
		player.heal_fraction(1.0)

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
