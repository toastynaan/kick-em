extends Node
## Round 7 reaction states (docs/Round 7 — Freeflow Combat.md: Reactions,
## Enemies): enemies do nothing while reacting, and nothing breaks when an
## enemy is pushed 3 m, lifted 1 m, or held and driven into a wall.
## A. Director (forced states on a FakeFighter): a reacting or lifted enemy
##    gets no token ("enemy busy"), a holder that starts reacting loses its
##    token, and it leaves the line (NEAR) to another enemy.
## B. Real reactions (H's Fighter.react) on a grunt with its AIBrain taking
##    turns at an open, invulnerable player: snap, spin, fold, buckle, push
##    (3 m) and lift (1 m, then the knockdown). While it reacts (or is down
##    after the lift) it starts no attack, holds no token (after one tick),
##    asks for none and does not walk. After a push it re-approaches (closes
##    REAPPROACH_DIST of the gap) and attacks again; after every reaction it
##    attacks again within RESUME_LIMIT s of being able to act.
## C. Held and driven (G's Carry; the brain forced to want every grab break):
##    the player grabs the grunt and drives it through a drywall panel into a
##    concrete wall; while held it never breaks free, starts nothing, holds no
##    token; afterwards it gets up and attacks again.
## Measured numbers are printed. OWNER: agent C (AI tests).

const Util := preload("res://tests/ai/ai_test_util.gd")
## s after the enemy can act again in which it must start an attack again.
const RESUME_LIMIT := 6.0
## s after a push ends in which it must have closed REAPPROACH_DIST of the gap.
const REAPPROACH_LIMIT := 4.0
const REAPPROACH_DIST := 1.5

var failures := 0
var player: Fighter
var launched: Array = []   ## [time, enemy, move]

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
	await _wait(0.3)
	await _part_director()
	await _part_reactions()
	await _part_drive()
	_finish()

# --- A. Director ---------------------------------------------------------------

func _part_director() -> void:
	AttackDirector.camera_busy = false
	var a := Util.spawn_fake_enemy(self, &"grunt", Vector3(0, 0.05, -3.5), Vector3.BACK)
	var b := Util.spawn_fake_enemy(self, &"grunt", Vector3(3.5, 0.05, 0), Vector3.LEFT)
	# Brains off: the director alone decides here.
	for f: Fighter in [a, b]:
		f.brain.process_mode = Node.PROCESS_MODE_DISABLED
		(f.brain as AIBrain).mode = AIBrain.Mode.FIGHT
	await _wait(0.6)
	for state: StringName in [&"fake_reacting", &"fake_lifted"]:
		a.set(state, true)
		var denied := not AttackDirector.request_token(a, true)
		var why := AttackDirector.get_last_denial(a)
		a.set(state, false)
		check(denied and why == "enemy busy", "%s: no token (%s)" % [state, why])
		check(await _grant(a), "%s cleared: token granted" % state)
		a.set(state, true)
		await _ticks(2)
		check(not AttackDirector.has_token(a), "%s: a holder that starts reacting loses its token" % state)
		a.set(state, false)
	# The line: the reacting one steps out, the other moves up.
	await _ticks(2)
	var line_before := AttackDirector._line.duplicate()
	a.set(&"fake_reacting", true)
	b.set(&"fake_reacting", false)
	await _ticks(2)
	var a_in := a in AttackDirector._line
	var b_in := b in AttackDirector._line
	print("[ai] info: line before %s, while a reacts %s" % [line_before.map(func(e: Fighter) -> String: return e.name),
		AttackDirector._line.map(func(e: Fighter) -> String: return e.name)])
	check(not a_in and b_in, "a reacting enemy leaves the line, the other is in it (a %s, b %s)" % [a_in, b_in])
	a.set(&"fake_reacting", false)
	for f: Fighter in [a, b]:
		AttackDirector.unregister_enemy(f)
		f.queue_free()
	await _wait(0.2)

func _grant(e: Fighter) -> bool:
	var t0 := Util.game_now()
	while Util.game_now() - t0 < 1.5:
		if AttackDirector.request_token(e, true):
			return true
		await get_tree().physics_frame
	return false

# --- B. Real reactions -------------------------------------------------------------

func _part_reactions() -> void:
	AttackDirector.camera_busy = false
	var g := FighterFactory.spawn_enemy(self, &"grunt", Transform3D(Basis.from_euler(Vector3(0, PI, 0)), Vector3(0, 0.05, -3.0)))
	var gb := g.brain as AIBrain
	gb.attack_launched.connect(func(m: StringName) -> void: launched.append([Util.game_now(), g, m]))
	await _wait(1.0)
	if not g.has_method(&"react"):
		check(false, "Fighter.react exists")
		return
	var probe_ok := false
	# [kind, push m, stun s] from the Round 7 move table (lift: the arc decides).
	var cases := [[&"snap", Tuning.R7_MOVES[&"cross"]["push"], Tuning.R7_MOVES[&"cross"]["stun"]],
		[&"spin", Tuning.R7_MOVES[&"hook"]["push"], Tuning.R7_MOVES[&"hook"]["stun"]],
		[&"fold", Tuning.R7_MOVES[&"gut_punch"]["push"], Tuning.R7_MOVES[&"gut_punch"]["stun"]],
		[&"buckle", Tuning.R7_MOVES[&"leg_kick"]["push"], Tuning.R7_MOVES[&"leg_kick"]["stun"]],
		[&"push", 3.0, Tuning.R7_MOVES[&"front_kick"]["stun"]],
		[&"lift", Tuning.R7_MOVES[&"uppercut"]["push"], 0.0]]
	for c: Array in cases:
		var kind: StringName = c[0]
		var push: float = c[1]
		var stun: float = c[2]
		_keep_player()
		# Mid-turn when possible: holding a token, closing in (or swinging).
		var t_wait := Util.game_now()
		while Util.game_now() - t_wait < 6.0 and not (AttackDirector.has_token(g) and not g.combat.is_attacking()) :
			_keep_player()
			await get_tree().physics_frame
		var had_token := AttackDirector.has_token(g)
		# Close enough for every case to land in the open.
		if Util.flat_dist(g.get_ground_position(), player.get_ground_position()) > 3.5:
			g.global_position = Vector3(0, 0.05, -2.0)
			g.reset_physics_interpolation()
			await get_tree().physics_frame
		var p0 := g.get_ground_position()
		var dir := (p0 - player.get_ground_position())
		dir.y = 0.0
		dir = dir.normalized()
		var foot0 := g.global_position.y
		var info := HitInfo.new()
		info.attacker = player
		info.victim = g
		g.react(kind, dir, push, stun, info)
		probe_ok = probe_ok or g.is_reacting()
		var r := await _track_reaction(g, kind)
		var moved := Util.flat_dist(g.get_ground_position(), p0)
		var rows := "%s: reacted %.2f s (token before %s), moved %.2f m, peak %.2f m; during it: %d starts, %d token ticks, %d requests, %d walking ticks; attacks again %.2f s after it could act, from %.1f m (%.1f m when free)" % [
			kind, r.busy, had_token, r.moved, r.peak - foot0, r.starts, r.token_ticks, r.requests, r.walk_ticks, r.resume,
			r.attack_dist, r.free_dist]
		print("[ai] info: " + rows)
		check(r.busy > 0.1, "%s: Fighter.react put it in the state (%.2f s)" % [kind, r.busy])
		check(r.starts == 0 and r.token_ticks == 0 and r.requests == 0 and r.walk_ticks == 0,
			"%s: does nothing while reacting (starts %d, token ticks %d, requests %d, walking ticks %d)" % [
				kind, r.starts, r.token_ticks, r.requests, r.walk_ticks])
		check(r.resume >= 0.0 and r.resume <= RESUME_LIMIT, "%s: attacks again %.2f s after it can act (<= %.0f)" % [kind, r.resume, RESUME_LIMIT])
		if kind == &"push":
			check(r.moved >= 3.0 * 0.8, "push: slid %.2f m (3 m asked)" % r.moved)
			check(r.reapproach >= 0.0 and r.reapproach <= REAPPROACH_LIMIT,
				"push: re-approaches: %.1f m closer %.2f s after the push ended (<= %.0f s; %.1f m away when free)" % [
					REAPPROACH_DIST, r.reapproach, REAPPROACH_LIMIT, r.free_dist])
		if kind == &"lift":
			check(r.peak - foot0 >= Tuning.R7_LIFT_HEIGHT * 0.8, "lift: popped %.2f m up (1 m asked)" % (r.peak - foot0))
			check(r.downed, "lift: lands into a knockdown and gets up")
		print("[ai] info: %s: max stuck %.2f s" % [kind, gb.max_stuck_time])
	check(gb.max_stuck_time <= 1.0, "never stuck through the reactions (longest %.2f s)" % gb.max_stuck_time)
	AttackDirector.unregister_enemy(g)
	g.queue_free()
	await _wait(0.2)

## Watch `e` from now: the reaction (and a knockdown after a lift), what the
## brain does meanwhile, then how long until it attacks again.
func _track_reaction(e: Fighter, kind: StringName) -> Dictionary:
	var b := e.brain as AIBrain
	var out := {"busy": 0.0, "starts": 0, "token_ticks": 0, "requests": 0, "walk_ticks": 0, "peak": e.global_position.y,
		"moved": 0.0, "resume": -1.0, "reapproach": -1.0, "downed": false, "free_dist": 0.0, "attack_dist": -1.0}
	var p0 := e.get_ground_position()
	var t0 := Util.game_now()
	var a0 := b.attacks_started
	var req0: float = AttackDirector._last_request.get(e, -INF)
	var ticks := 0
	# The reaction (lift: the arc, then the knockdown and the get-up).
	while Util.game_now() - t0 < 8.0:
		var busy := e.is_reacting() or e.is_lifted() or (kind == &"lift" and e.is_down())
		if not busy and ticks > 0:
			break
		ticks += 1
		out["downed"] = out["downed"] or e.is_down()
		out["peak"] = maxf(out["peak"], e.global_position.y)
		if ticks > 1:
			if AttackDirector.has_token(e):
				out["token_ticks"] += 1
			if float(AttackDirector._last_request.get(e, -INF)) != req0:
				out["requests"] += 1
				req0 = AttackDirector._last_request.get(e, -INF)
			if Vector2(e.move_input.x, e.move_input.z).length() > 0.01:
				out["walk_ticks"] += 1
		_keep_player()
		await get_tree().physics_frame
	out["starts"] = b.attacks_started - a0
	out["busy"] = Util.game_now() - t0
	out["moved"] = Util.flat_dist(e.get_ground_position(), p0)
	# Then: wait until it can act (a get-up pause), and for its next attack.
	var t_free := Util.game_now()
	var d_free := Util.flat_dist(e.get_ground_position(), player.get_ground_position())
	out["free_dist"] = d_free
	var a1 := b.attacks_started
	while Util.game_now() - t_free < RESUME_LIMIT + 2.0:
		var d := Util.flat_dist(e.get_ground_position(), player.get_ground_position())
		if out["reapproach"] < 0.0 and d <= d_free - REAPPROACH_DIST:
			out["reapproach"] = Util.game_now() - t_free
		if b.attacks_started > a1:
			out["resume"] = Util.game_now() - t_free
			out["attack_dist"] = d
			break
		_keep_player()
		await get_tree().physics_frame
	return out

# --- C. Held and driven -------------------------------------------------------------

func _part_drive() -> void:
	AttackDirector.camera_busy = false
	# A drywall panel 6 m east of the grab spot, a concrete wall 6 m behind it.
	var spot := Vector3(-30, 0.05, 0)
	var panel := Destructible.new()
	panel.surface = &"drywall"
	panel.name = "Panel_drywall"
	panel.transform = Transform3D(Basis.looking_at(Vector3.RIGHT, Vector3.UP), Vector3(spot.x + 6.0, 1.5, 0))
	add_child(panel)
	var wall := StaticBody3D.new()
	wall.name = "ConcreteWall"
	wall.collision_layer = Layers.WORLD
	wall.collision_mask = 0
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.5, 4.0, 8.0)
	cs.shape = box
	wall.add_child(cs)
	wall.position = Vector3(spot.x + 12.0, 2.0, 0)
	add_child(wall)
	player.global_position = spot
	player.reset_physics_interpolation()
	player.snap_facing(Vector3.RIGHT)
	var g := FighterFactory.spawn_enemy(self, &"grunt", Transform3D(Basis.looking_at(Vector3.LEFT, Vector3.UP), spot + Vector3(1.0, 0, 0)))
	var gb := g.brain as AIBrain
	gb.grab_break_override = 1.0  # it would break every neutral grab it could
	var broken := [0]
	var impacts: Array = []
	var on_broken := func(_h: Node3D, v: Node3D, _p: bool) -> void:
		if v == g or _h == g: broken[0] += 1
	GameEvents.grab_broken.connect(on_broken)
	var on_impact := func(_h: Node3D, v: Node3D, _t: Node3D, _pos: Vector3, speed: float, result: StringName) -> void:
		if v == g: impacts.append("%s %.1f m/s" % [result, speed])
	GameEvents.drive_impact.connect(on_impact)
	await _wait(0.6)
	_keep_player()
	if not player.carry.is_enabled() or not player.carry.grab_now(g, &"", true):
		check(false, "the player holds the grunt (Carry.grab_now: enabled %s)" % player.carry.is_enabled())
		GameEvents.grab_broken.disconnect(on_broken)
		GameEvents.drive_impact.disconnect(on_impact)
		return
	var a0 := gb.attacks_started
	var held_ticks := 0
	var token_ticks := 0
	var drove := false
	var max_speed := 0.0
	await _ticks(3)
	player.snap_facing(Vector3.RIGHT)
	player.combat.press(CombatController.Action.DASH)
	var t0 := Util.game_now()
	while Util.game_now() - t0 < 4.0:
		var held := g.carry != null and g.carry.is_held()
		if held:
			held_ticks += 1
			if held_ticks > 1 and AttackDirector.has_token(g):
				token_ticks += 1
		drove = drove or player.carry.is_driving()
		max_speed = maxf(max_speed, Vector2(player.velocity.x, player.velocity.z).length())
		if not held and held_ticks > 0 and not player.carry.is_driving():
			break
		_keep_player()
		await get_tree().physics_frame
	player.combat.release(CombatController.Action.DASH)
	if player.carry.is_holding():
		player.carry.drop(&"release")
	var starts_held := gb.attacks_started - a0
	print("[ai] info: held %.2f s, drove %s (max %.1f m/s), drive impacts %s, panel broken %s, grabs broken %d, grunt at %s" % [
		held_ticks / float(Engine.physics_ticks_per_second), drove, max_speed, str(impacts), panel.is_broken, broken[0],
		g.get_ground_position().snapped(Vector3.ONE * 0.1)])
	check(drove, "the player drives the held grunt (Carry.is_driving)")
	check(broken[0] == 0, "no grab break while held and driven, though it wants every break (%d)" % broken[0])
	check(starts_held == 0 and token_ticks == 0, "while held: no attack (%d), no token (%d ticks)" % [starts_held, token_ticks])
	# Afterwards: up again and attacking.
	var t1 := Util.game_now()
	var a1 := gb.attacks_started
	var back := -1.0
	while Util.game_now() - t1 < RESUME_LIMIT + 4.0:
		if gb.attacks_started > a1:
			back = Util.game_now() - t1
			break
		_keep_player()
		await get_tree().physics_frame
	print("[ai] info: after the drive: attacks again %.2f s after the hold ended (state %s, at %s), max stuck %.2f s" % [
		back, g.get_react_state(), g.get_ground_position().snapped(Vector3.ONE * 0.1), gb.max_stuck_time])
	check(back >= 0.0, "after being driven into the wall it gets up and attacks again (%.2f s)" % back)
	gb.grab_break_override = -1.0
	GameEvents.grab_broken.disconnect(on_broken)
	GameEvents.drive_impact.disconnect(on_impact)

# --- Helpers -------------------------------------------------------------------------

func _keep_player() -> void:
	if "invuln_until" in player:
		player.set(&"invuln_until", TimeDirector.now() + 5.0)
	if player.hp < player.max_hp * 0.5:
		player.heal_fraction(1.0)

func _ticks(n: int) -> void:
	for i in n:
		await get_tree().physics_frame

func _wait(s: float) -> void:
	var t0 := Util.game_now()
	while Util.game_now() - t0 < s:
		_keep_player()
		await get_tree().physics_frame

func _finish() -> void:
	AttackDirector.reset()
	print("[ai] test_react: %s (%d failures)" % ["PASS" if failures == 0 else "FAIL", failures])
	get_tree().quit(0 if failures == 0 else 1)
