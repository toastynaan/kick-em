extends Node
## Crowd attack rate (Upgrade 2 risk: target one tell every 1-1.5 s of open
## play) and Focus clocks. Four Grunts already fighting round an open,
## invulnerable player:
## A. 30 s at 1x: mean gap between tells within [RATE_MIN, RATE_MAX] s, and
##    no two different attackers' active frames closer than SWING_SPACING.
## B. 15 s (real) of Focus (world at 0.3x): attacks keep coming, no token is
##    lost to a timeout, tells last ~3.3x longer in real time, spacing holds.
## OWNER: agent C (AI tests).

const Util := preload("res://tests/ai/ai_test_util.gd")
const RATE_MIN := 0.9
const RATE_MAX := 1.6

var failures := 0
var player: Fighter
var enemies: Array[Fighter] = []
var tells: Array = []      ## [real time, attacker, duration]
var actives: Array = []    ## [real time, world time, attacker]
var grants := {}           ## enemy -> granted while not yet attacked
var wasted := 0            ## tokens released without an attack (not hit, not down)

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
	Util.build_walls(self, 12.0)
	player = FighterFactory.spawn_dummy(self, &"player", Transform3D(Basis(), Vector3(0, 0.05, 0)), Fighter.TEAM_PLAYER)
	Util.ensure_wired(player)
	AttackDirector.set_player(player)
	if not player.has_method(&"_physics_process"):
		print("[ai] BLOCKED: fighter.gd is a stub")
		_finish()
		return
	for pos in [Vector3(-4, 0.05, -3), Vector3(4, 0.05, -3), Vector3(-3, 0.05, 4), Vector3(3, 0.05, 4)]:
		var e := FighterFactory.spawn_enemy(self, &"grunt", Transform3D(Basis(), pos))
		enemies.append(e)
		e.combat.attack_started.connect(func(_m: StringName) -> void: grants.erase(e))
	GameEvents.attack_tell.connect(func(a: Node3D, _k: StringName, d: float) -> void:
		if a in enemies: tells.append([Util.game_now(), a, d]))
	GameEvents.attack_active.connect(func(a: Node3D, _m: StringName) -> void:
		if a in enemies: actives.append([Util.game_now(), AttackDirector.world_now(), a]))
	AttackDirector.token_granted.connect(func(e: Fighter) -> void: grants[e] = true)
	AttackDirector.token_released.connect(func(e: Fighter) -> void:
		if grants.has(e):
			grants.erase(e)
			if not e.is_down() and not e.is_in_hitstun():
				wasted += 1)

	# Settle: everyone takes a ring position first.
	await _run_for(4.0)
	# --- A: 1x.
	tells.clear()
	actives.clear()
	var _t0 := Util.game_now()
	await _run_for(30.0)
	var n := tells.size()
	var gap := 30.0 / maxf(n, 1)
	print("[ai] info: %d tells in 30 s of open play -> one every %.2f s" % [n, gap])
	check(gap >= RATE_MIN and gap <= RATE_MAX, "crowd rate: one tell every %.2f s (target %.1f-%.1f)" % [gap, RATE_MIN, RATE_MAX])
	check(_min_gap(1) >= Tuning.SWING_SPACING - 0.02, "1x: active frames of different attackers >= %.2f s apart (closest %.3f)" % [Tuning.SWING_SPACING, _min_gap(1)])

	# --- B: Focus, world at 0.3x for 15 s of real time.
	tells.clear()
	actives.clear()
	wasted = 0
	Engine.time_scale = Tuning.FOCUS_SCALE
	await _run_for(15.0)
	Engine.time_scale = 1.0
	var tells_b := tells.duplicate()
	var real_tell := _real_tell_time()
	print("[ai] info: Focus: %d tells in 15 s real (4.5 s world); tell to active %.2f s real; tokens wasted %d" % [tells_b.size(), real_tell, wasted])
	check(tells_b.size() >= 2, "Focus: attacks keep coming (%d tells)" % tells_b.size())
	check(wasted <= 1, "Focus: no token lost to a timeout (%d released unused)" % wasted)
	check(real_tell < 0.0 or real_tell > 0.35 / Tuning.FOCUS_SCALE * 0.8,
		"Focus: a tell lasts ~1/%.1f longer in real time (%.2f s)" % [Tuning.FOCUS_SCALE, real_tell])
	check(_min_gap(0) >= Tuning.SWING_SPACING - 0.02, "Focus: active frames >= %.2f s apart in real time (closest %.3f)" % [Tuning.SWING_SPACING, _min_gap(0)])
	# And straight after Focus.
	actives.clear()
	await _run_for(8.0)
	check(_min_gap(0) >= Tuning.SWING_SPACING - 0.02, "after Focus: spacing holds (closest %.3f)" % _min_gap(0))
	_finish()

## Closest gap between active frames of different attackers (index 0: real
## time, 1: world time).
func _min_gap(idx: int) -> float:
	var best := INF
	for i in range(1, actives.size()):
		if actives[i][2] != actives[i - 1][2]:
			best = minf(best, actives[i][idx] - actives[i - 1][idx])
	return best

## Mean real seconds from a tell to that attacker's next active frame.
func _real_tell_time() -> float:
	var total := 0.0
	var n := 0
	for t: Array in tells:
		for a: Array in actives:
			if a[2] == t[1] and a[0] >= t[0]:
				total += a[0] - t[0]
				n += 1
				break
	return total / n if n > 0 else -1.0

func _run_for(seconds: float) -> void:
	var t0 := Util.game_now()
	while Util.game_now() - t0 < seconds:
		if "invuln_until" in player:
			player.set(&"invuln_until", TimeDirector.now() + 5.0)
		if player.global_position.length() > 0.3:
			player.global_position = Vector3(0, player.global_position.y, 0)
			player.reset_physics_interpolation()
		await get_tree().physics_frame

func _finish() -> void:
	Engine.time_scale = 1.0
	AttackDirector.reset()
	print("[ai] test_crowd_rate: %s (%d failures)" % ["PASS" if failures == 0 else "FAIL", failures])
	get_tree().quit(0 if failures == 0 else 1)
