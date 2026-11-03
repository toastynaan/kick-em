extends Node
## Round 8: taps barely stun (docs/Round 8 — Charge and Pressure.md: Moves
## "Flinch ... After it, the enemy is free to walk in and attack";
## Acceptance 3: the grunt can attack again within 0.4 s of the tap). The
## enemies have their real AIBrain and AttackDirector.
## A. A grunt winding up in range is tapped, at TAP_AT ticks into its wind-up:
##    H's Fighter.react(&"flinch") once it exists (else the double: the move
##    cancelled as Fighter.react does, then the FakeFighter's react state
##    &"flinch" for the jab tap's stun), then hit_landed with info.react
##    &"flinch" as B sends it. It keeps its token all through the flinch,
##    starts nothing and does not walk while flinching, and starts an attack
##    again within FLINCH_RESUME s of the tap.
## B. A holder still closing in is flinched: it keeps its token and its move,
##    walks on and swings.
## C. At p 0.7 (FakeCombat pressure double) the same tap ends its turn: the
##    token goes back, it backs off, and it starts nothing for HIGH_P_QUIET s.
## D. Real pipeline: the player's real jab taps (B's CombatController
##    press / release) on a real level-1 grunt winding up. When B's tap
##    reaction is a flinch, it attacks again within FLINCH_RESUME s of the hit
##    (REAL_TRIALS flinches). Reported, not failed, while B's tap flinch is
##    not in yet.
## Measured numbers are printed. OWNER: agent C (AI tests).

const Util := preload("res://tests/ai/ai_test_util.gd")
const FakeCombat := preload("res://tests/ai/fake_combat.gd")
const FLINCH_RESUME := 0.4       ## s from the tap to its next attack start (doc: Acceptance 3)
const TAP_AT: Array[int] = [2, 12, 30, 50]  ## ticks (120 Hz) into the wind-up
const HIGH_P_QUIET := 1.0
const REAL_TRIALS := 4

var failures := 0
var player: Fighter

func _ready() -> void:
	_run.call_deferred()

func check(ok: bool, what: String) -> void:
	print("[ai] %s: %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		failures += 1

func _run() -> void:
	AttackDirector.reset()
	AIBrain.test_seed = 77
	Tuning.difficulty = Tuning.Difficulty.NORMAL
	AttackDirector.camera_busy = false
	Util.build_floor(self)
	player = FighterFactory.spawn_dummy(self, &"player", Transform3D(Basis(), Vector3(0, 0.05, 0)), Fighter.TEAM_PLAYER)
	Util.ensure_wired(player)
	AttackDirector.set_player(player)
	await _wait(0.3)
	var h_flinch := Fighter.REACT_KINDS.has(&"flinch")
	print("[ai] info: H's Fighter.react(&\"flinch\") %s" % ("in: used" if h_flinch else "not in yet: the react-state double stands in"))
	await _part_windup(h_flinch)
	await _part_closing(h_flinch)
	await _part_high_pressure(h_flinch)
	await _part_real()
	_finish()

## The jab tap's flinch on `e`, as B delivers it: Fighter.react (it cancels the
## move), then hit_landed. Returns the stun used.
func _tap(e: Fighter, h_flinch: bool) -> float:
	var tap: Dictionary = Tuning.R8_MOVES[&"jab"]["tap"]
	var stun := float(tap["stun"])
	var dir := e.get_ground_position() - player.get_ground_position()
	dir.y = 0.0
	dir = dir.normalized()
	var info := HitInfo.new()
	info.attacker = player
	info.victim = e
	info.move_id = &"jab"
	info.react = &"flinch"
	info.tier = HitInfo.Tier.FLINCH
	info.hit_direction = dir
	info.stun = stun
	info.push = float(tap["push"])
	if h_flinch:
		e.react(&"flinch", dir, float(tap["push"]), stun, info)
	else:
		e.combat.on_reaction(HitInfo.Reaction.STAGGER, 0.0)  # what Fighter.react does first
		e.set(&"fake_react_state", &"flinch")
		e.set(&"fake_reacting", true)
	GameEvents.hit_landed.emit(info)
	return stun

## After a tap at `t_tap`: the double's flinch ends after `stun`; watch until
## the next attack start (or `limit` s).
func _after_tap(e: Fighter, t_tap: float, stun: float, h_flinch: bool, limit: float) -> Dictionary:
	var b := e.brain as AIBrain
	var out := {"resume": -1.0, "lost": 0, "busy_starts": 0, "busy_walk": 0, "busy": 0.0, "backing": false}
	var a0 := b.attacks_started
	var busy_until := -1.0
	while Util.game_now() - t_tap < limit:
		if not h_flinch and bool(e.get(&"fake_reacting")) and Util.game_now() - t_tap >= stun - 1e-4:
			e.set(&"fake_reacting", false)
		_keep_player()
		await get_tree().physics_frame
		# Flinching this tick: reacting, or unable to act without being in a move.
		var busy := e.is_reacting() or (not e.can_act() and not e.combat.is_attacking())
		if busy:
			busy_until = Util.game_now()
			if b.attacks_started > a0:
				out["busy_starts"] += 1
			if Vector2(e.move_input.x, e.move_input.z).length() > 0.01:
				out["busy_walk"] += 1
		if not AttackDirector.has_token(e) and b.attacks_started == a0:
			out["lost"] += 1
		out["backing"] = out["backing"] or b.is_backing_off()
		if b.attacks_started > a0:
			out["resume"] = Util.game_now() - t_tap
			break
	out["busy"] = maxf(busy_until - t_tap, 0.0)
	return out

# --- A. Tapped in its wind-up ------------------------------------------------------------------

func _part_windup(h_flinch: bool) -> void:
	var g := Util.spawn_pressure_enemy(self, &"grunt", Vector3(0, 0.05, -1.2), Vector3.BACK)
	var gb := g.brain as AIBrain
	await _wait(0.3)
	var keeps0 := AttackDirector.flinch_keeps
	var worst := 0.0
	for k in TAP_AT:
		var winding := await _until(func() -> bool: return g.combat.is_attacking() and not g.combat.is_attack_active() \
			and AttackDirector.has_token(g), 8.0)
		if not winding:
			check(false, "tap %d ticks in: a grunt winding up" % k)
			continue
		var move := g.combat.current_move_id()
		await _ticks(k)
		if not (g.combat.is_attacking() and not g.combat.is_attack_active()):
			print("[ai] info: tap %d ticks in: %s was past its wind-up (startup shorter): tapped later in recovery skipped" % [k, move])
			continue
		var t_tap := Util.game_now()
		var stun := _tap(g, h_flinch)
		var r := await _after_tap(g, t_tap, stun, h_flinch, 1.5)
		worst = maxf(worst, r.resume if r.resume >= 0.0 else INF)
		print("[ai] info: %s tapped %d ticks into its wind-up: flinch %.2f s, attacks again %.3f s after the tap, token lost %d ticks, starts / walking while flinching %d / %d" % [
			move, k, r.busy, r.resume, r.lost, r.busy_starts, r.busy_walk])
		check(r.lost == 0, "tap %d ticks in: keeps its token through the flinch (%d ticks without)" % [k, r.lost])
		check(r.busy_starts == 0 and r.busy_walk == 0, "tap %d ticks in: nothing while flinching (starts %d, walking %d ticks)" % [
			k, r.busy_starts, r.busy_walk])
		check(r.resume >= 0.0 and r.resume <= FLINCH_RESUME, "tap %d ticks in: attacks again %.3f s after the tap (<= %.1f s)" % [
			k, r.resume, FLINCH_RESUME])
	print("[ai] info: wind-up taps: slowest resume %.3f s; director kept %d flinched turns" % [worst, AttackDirector.flinch_keeps - keeps0])
	check(AttackDirector.flinch_keeps - keeps0 >= 1, "the director kept the turn of a wind-up the tap cut short (%d)" % (AttackDirector.flinch_keeps - keeps0))
	check(gb.flinch_shrugs >= 3, "the brain shrugged the flinches off with its token (%d)" % gb.flinch_shrugs)
	AttackDirector.unregister_enemy(g)
	g.queue_free()
	await _wait(0.2)

# --- B. Tapped while closing in ------------------------------------------------------------------

func _part_closing(h_flinch: bool) -> void:
	var g := Util.spawn_pressure_enemy(self, &"grunt", Vector3(0, 0.05, -3.2), Vector3.BACK)
	var gb := g.brain as AIBrain
	await _wait(0.2)
	var closing := await _until(func() -> bool:
		return AttackDirector.has_token(g) and gb._has_move and not g.combat.is_attacking() \
			and Util.flat_dist(g.get_ground_position(), player.get_ground_position()) > float(AIBrain.MOVE_RANGE.get(gb._move_id, 1.5)) + 0.5, 6.0)
	check(closing, "a holder closing in")
	if closing:
		var move := gb._move_id
		var t_tap := Util.game_now()
		var stun := _tap(g, h_flinch)
		var r := await _after_tap(g, t_tap, stun, h_flinch, 2.0)
		print("[ai] info: tapped while closing in with %s: flinch %.2f s, token lost %d ticks, attacks %.2f s after the tap (%s)" % [
			move, r.busy, r.lost, r.resume, gb.get_move_id() if gb.get_move_id() != &"" else g.combat.current_move_id()])
		check(r.lost == 0 and r.resume >= 0.0, "closing in: keeps its token through the flinch, walks on and swings (lost %d ticks, swings %.2f s after)" % [
			r.lost, r.resume])
	AttackDirector.unregister_enemy(g)
	g.queue_free()
	await _wait(0.2)

# --- C. High pressure: the tap ends the turn -------------------------------------------------------

func _part_high_pressure(h_flinch: bool) -> void:
	var g := Util.spawn_pressure_enemy(self, &"grunt", Vector3(0, 0.05, -1.2), Vector3.BACK)
	var gb := g.brain as AIBrain
	var fc := g.combat as FakeCombat
	await _wait(0.3)
	var winding := await _until(func() -> bool: return g.combat.is_attacking() and not g.combat.is_attack_active() \
		and AttackDirector.has_token(g), 8.0)
	check(winding, "p 0.7: a grunt winding up")
	if winding:
		fc.fake_pressure = 0.7
		await _ticks(6)
		check(g.combat.is_attacking() and not gb.is_backing_off(), "p 0.7 mid-swing: it keeps swinging (attacking %s, backing %s)" % [
			g.combat.is_attacking(), gb.is_backing_off()])
		var t_tap := Util.game_now()
		var stun := _tap(g, h_flinch)
		var r := await _after_tap(g, t_tap, stun, h_flinch, stun + HIGH_P_QUIET)
		print("[ai] info: tapped at p 0.7: flinch %.2f s, backed off %s, attacked again %.2f s after (none = -1)" % [r.busy, r.backing, r.resume])
		check(r.backing and r.resume < 0.0 and not AttackDirector.has_token(g),
			"p 0.7: after the flinch it gives its turn up and backs off (backing %s, token %s, no attack for %.1f s: %s)" % [
				r.backing, AttackDirector.has_token(g), stun + HIGH_P_QUIET, r.resume < 0.0])
	fc.fake_pressure = -1.0
	AttackDirector.unregister_enemy(g)
	g.queue_free()
	await _wait(0.2)

# --- D. The real tap (B's pipeline) ------------------------------------------------------------------

func _part_real() -> void:
	var g := FighterFactory.spawn_enemy(self, &"grunt", Transform3D(Basis.looking_at(Vector3.BACK, Vector3.UP), Vector3(0, 0.05, -1.3)))
	var gb := g.brain as AIBrain
	var hits: Array = []  # [time, react]
	var on_hit := func(i: HitInfo) -> void:
		if i.victim == g and i.attacker == player: hits.append([Util.game_now(), i.react])
	GameEvents.hit_landed.connect(on_hit)
	await _wait(0.5)
	var flinches := 0
	var other: Array[String] = []
	var resumes: Array[String] = []
	var worst := 0.0
	var tries := 0
	while flinches < REAL_TRIALS and tries < REAL_TRIALS * 4:
		tries += 1
		# One tap per wind-up, with the meter drained between (a level-1 grunt breaks on the 3rd).
		await _until(func() -> bool: return g.combat.get_pressure() <= 0.0 and not g.is_reacting(), 6.0)
		var winding := await _until(func() -> bool: return g.combat.is_attacking() and not g.combat.is_attack_active() \
			and AttackDirector.has_token(g), 8.0)
		if not winding:
			continue
		_face(player, g)
		hits.clear()
		var a0 := gb.attacks_started
		player.combat.press(CombatController.Action.LIGHT)
		await _ticks(2)
		player.combat.release(CombatController.Action.LIGHT)
		var landed := await _until(func() -> bool: return not hits.is_empty(), 0.6)
		if not landed:
			continue
		var t_hit: float = hits[0][0]
		var react: StringName = hits[0][1]
		if react != &"flinch":
			other.append(String(react))
			await _wait(0.6)
			continue
		flinches += 1
		var back := await _until(func() -> bool: return gb.attacks_started > a0, 1.5)
		var dt := Util.game_now() - t_hit if back else -1.0
		worst = maxf(worst, dt if dt >= 0.0 else INF)
		resumes.append("%.3f" % dt)
		await _wait(0.3)
	GameEvents.hit_landed.disconnect(on_hit)
	if flinches == 0:
		print("[ai] info: real taps: B's tap reaction is not a flinch yet (%s): real-pipeline resume not checked" % ", ".join(other))
	else:
		print("[ai] info: real jab taps on a winding-up level-%d grunt: %d flinches, attacks again after %s s (slowest %.3f); other reactions %s" % [
			g.level, flinches, ", ".join(resumes), worst, str(other)])
		check(worst <= FLINCH_RESUME, "real taps: the flinched grunt attacks again within %.1f s of the hit (slowest %.3f s)" % [FLINCH_RESUME, worst])
	AttackDirector.unregister_enemy(g)
	g.queue_free()

# --- Helpers ---------------------------------------------------------------------------------------

func _face(a: Fighter, b: Fighter) -> void:
	var to := b.get_ground_position() - a.get_ground_position()
	to.y = 0.0
	if to.length() > 0.01:
		a.snap_facing(to)
		a.face_dir = to.normalized()

func _until(cond: Callable, limit: float) -> bool:
	var t0 := Util.game_now()
	while Util.game_now() - t0 < limit:
		if cond.call():
			return true
		_keep_player()
		await get_tree().physics_frame
	return bool(cond.call())

func _keep_player() -> void:
	player.set(&"invuln_until", TimeDirector.now() + 5.0)
	if player.hp < player.max_hp * 0.5:
		player.heal_fraction(1.0)

func _ticks(n: int) -> void:
	for i in n:
		_keep_player()
		await get_tree().physics_frame

func _wait(s: float) -> void:
	var t0 := Util.game_now()
	while Util.game_now() - t0 < s:
		_keep_player()
		await get_tree().physics_frame

func _finish() -> void:
	AttackDirector.reset()
	AIBrain.test_seed = -1
	print("[ai] test_flinch: %s (%d failures)" % ["PASS" if failures == 0 else "FAIL", failures])
	get_tree().quit(0 if failures == 0 else 1)
