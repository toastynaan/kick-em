extends Node
## F10 enemies who lose a limb (Feel Reference: Enemies who lose a limb):
## A. Lost a leg: after the severing knockdown he gets up and crawls away from
##    the player at Tuning.CRAWL_SPEED, never takes a token or attacks, emits
##    GameEvents.fleeing_changed, uses P's &"crawl" locomotion; a ground
##    strike finishes him (B's real ground strike when it picks him, else a
##    ground-strike hit through take_hit; the path is printed).
## B. Lost an arm above Tuning.LIMB_LOST_FLEE_HP: keeps fighting one-handed at
##    Tuning.ARM_LOST_DAMAGE_MULT damage (no grabs, no moves of the lost hand);
##    at or below it he limps away. A stick enemy who loses his stick arm drops
##    the stick. OWNER: agent C (AI tests).

const Util := preload("res://tests/ai/ai_test_util.gd")
const CRAWL_WATCH := 6.0     ## s of crawling measured
const LIMP_WATCH := 4.0

var failures := 0
var player: Fighter
var fleeing_events: Array = []   ## [fighter, fleeing]
var pin_player := true           ## keep the player dummy at the origin

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
	GameEvents.fleeing_changed.connect(func(f: Node3D, on: bool) -> void: fleeing_events.append([f, on]))
	await _wait(0.2)
	await _part_leg()
	await _part_arm()
	await _part_stick_arm()
	_finish()

# --- A. Lost a leg: crawl away, a ground strike finishes him -------------------------

func _part_leg() -> void:
	var e := FighterFactory.spawn_enemy(self, &"grunt", Transform3D(Basis.from_euler(Vector3(0, PI, 0)), Vector3(0, 0.05, -3.0)))
	var b := e.brain as AIBrain
	await _wait(1.0)
	var cut_ok := e.sever_limb(&"leg_l")
	e.knockdown(Vector3.FORWARD, &"LeftUpperLeg")  # the severing launch lands him on the floor
	check(cut_ok and b.has_lost_leg(), "leg severed (Fighter.sever_limb -> GameEvents.limb_severed)")
	check(e.is_fleeing() and b.is_crawling(), "lost a leg: fleeing, crawling")
	check(_events_for(e) == [true], "GameEvents.fleeing_changed(true) once (%s)" % str(_events_for(e)))
	if e.animator.has_method(&"get_locomotion_style"):
		check(e.animator.get_locomotion_style() == &"crawl", "P's locomotion style is crawl (%s)" % e.animator.get_locomotion_style())
	# Back up from the knockdown.
	var t0 := Util.game_now()
	while e.is_down() and Util.game_now() - t0 < 6.0:
		_keep_player()
		await get_tree().physics_frame
	check(not e.is_down(), "he gets up after the severing knockdown (%.1f s)" % (Util.game_now() - t0))
	var attacks0 := b.attacks_started
	var start_d := _dist(e)
	var tokens := 0
	var speeds: Array[float] = []
	var prev := e.get_ground_position()
	var max_speed := 0.0
	t0 = Util.game_now()
	var window_t := t0
	while Util.game_now() - t0 < CRAWL_WATCH:
		_keep_player()
		await get_tree().physics_frame
		if AttackDirector.has_token(e):
			tokens += 1
		if Util.game_now() - window_t >= 0.5:
			var p := e.get_ground_position()
			var v := Util.flat_dist(p, prev) / (Util.game_now() - window_t)
			if v > 0.1:
				speeds.append(v)
			max_speed = maxf(max_speed, v)
			prev = p
			window_t = Util.game_now()
	var end_d := _dist(e)
	var mean := 0.0
	for v in speeds:
		mean += v
	mean = mean / speeds.size() if not speeds.is_empty() else 0.0
	print("[ai] info: crawl %.1f m -> %.1f m from the player in %.0f s, mean %.2f m/s, max %.2f m/s" % [start_d, end_d, CRAWL_WATCH, mean, max_speed])
	check(end_d > start_d + 2.0 or end_d >= AIBrain.FLEE_REST_DIST - 0.3, "crawls away from the player (%.1f -> %.1f m)" % [start_d, end_d])
	check(mean > Tuning.CRAWL_SPEED * 0.6 and max_speed <= Tuning.CRAWL_SPEED + 0.15,
		"at the crawl speed (mean %.2f, max %.2f m/s, Tuning.CRAWL_SPEED %.1f)" % [mean, max_speed, Tuning.CRAWL_SPEED])
	check(tokens == 0 and b.attacks_started == attacks0, "never takes a token or attacks while crawling (%d ticks with a token, %d attacks)" % [tokens, b.attacks_started - attacks0])
	check(not AttackDirector.request_token(e, true) and AttackDirector.get_last_denial(e) == "fleeing", "the director refuses him (%s)" % AttackDirector.get_last_denial(e))
	# A ground strike finishes him.
	var path := "none"
	var ground_hits := [0]
	var on_hit := func(i: HitInfo) -> void:
		if i.victim == e and i.ground_strike: ground_hits[0] += 1
	GameEvents.hit_landed.connect(on_hit)
	pin_player = false
	for attempt in 4:
		if e.is_dead():
			break
		var at := e.get_ground_position()
		var away := (player.get_ground_position() - at)
		away.y = 0.0
		away = away.normalized() if away.length() > 0.1 else Vector3.BACK
		player.global_position = at + away * 1.0 + Vector3(0, 0.05, 0)
		player.reset_physics_interpolation()
		player.snap_facing(-away)
		player.face_dir = -away
		await _wait(0.1)
		player.combat.press(CombatController.Action.LIGHT)
		await get_tree().physics_frame
		player.combat.release(CombatController.Action.LIGHT)
		await _wait(0.6)
	if e.is_dead():
		path = "B's ground strike (player Light next to the crawler)"
	else:
		var info := HitInfo.new()
		info.attacker = player
		info.victim = e
		info.move_id = &"stomp"
		info.kind = &"strike"
		info.ground_strike = true
		info.tier = HitInfo.Tier.FLINCH
		info.damage = Power.strike_damage(&"ground", 0)
		info.hit_direction = Vector3.FORWARD
		info.hit_position = e.get_center_of_mass()
		info.hit_bone = &"Chest"
		e.take_hit(info)
		await get_tree().physics_frame
		if e.is_dead():
			path = "ground-strike HitInfo through take_hit (B's ground strike did not pick the crawler)"
	GameEvents.hit_landed.disconnect(on_hit)
	pin_player = true
	print("[ai] info: finisher path: %s (ground-strike hits %d)" % [path, ground_hits[0]])
	check(e.is_dead(), "a ground strike finishes the crawler (%s)" % path)
	await _wait(0.5)
	player.global_position = Vector3(0, 0.05, 0)
	player.reset_physics_interpolation()

# --- B. Lost an arm: one-handed above 40 HP, limps away at 40 or below ----------------

func _part_arm() -> void:
	var e := FighterFactory.spawn_enemy(self, &"grunt", Transform3D(Basis.from_euler(Vector3(0, PI, 0)), Vector3(2, 0.05, -3.5)))
	var b := e.brain as AIBrain
	await _wait(0.8)
	e.sever_limb(&"arm_r")
	await get_tree().physics_frame
	check(b.has_lost_arm(&"right") and not e.is_fleeing() and e.hp > Tuning.LIMB_LOST_FLEE_HP,
		"lost an arm at %.0f HP (> %.0f): keeps fighting" % [e.hp, Tuning.LIMB_LOST_FLEE_HP])
	check(is_equal_approx(b.get_damage_mult(), Tuning.ARM_LOST_DAMAGE_MULT), "one-handed at x%.1f damage (get_damage_mult)" % b.get_damage_mult())
	var picks := {}
	var strings := 0
	for i in 200:
		var m: StringName = b._pick_move(1.4, player)
		picks[m] = picks.get(m, 0) + 1
		strings += 0 if b._string_rest.is_empty() else 1
	check(not picks.has(&"e_grab") and not picks.has(&"e_hook") and picks.has(&"e_jab") and strings == 0,
		"no grab, no right-hand cross, left jabs and kicks only (%s, strings %d)" % [str(picks), strings])
	# Let him attack for a while: still in the rotation.
	var attacks0 := b.attacks_started
	var t0 := Util.game_now()
	while Util.game_now() - t0 < 6.0 and b.attacks_started == attacks0:
		_keep_player()
		await get_tree().physics_frame
	check(b.attacks_started > attacks0, "the one-armed grunt still attacks (%d in %.1f s)" % [b.attacks_started - attacks0, Util.game_now() - t0])
	# Down to 40 HP: he limps away.
	await _settle(e)
	e.apply_damage(e.hp - Tuning.LIMB_LOST_FLEE_HP, &"test")
	await get_tree().physics_frame
	check(e.is_fleeing() and b.get_flee_style() == &"limp", "at %.0f HP (<= %.0f) he limps away" % [e.hp, Tuning.LIMB_LOST_FLEE_HP])
	if e.animator.has_method(&"get_locomotion_style"):
		check(e.animator.get_locomotion_style() == &"limp", "P's locomotion style is limp (%s)" % e.animator.get_locomotion_style())
	await _wait(0.6)
	var d0 := _dist(e)
	var prev := e.get_ground_position()
	var max_speed := 0.0
	var tokens := 0
	t0 = Util.game_now()
	var window_t := t0
	while Util.game_now() - t0 < LIMP_WATCH:
		_keep_player()
		await get_tree().physics_frame
		if AttackDirector.has_token(e):
			tokens += 1
		if Util.game_now() - window_t >= 0.5:
			var p := e.get_ground_position()
			max_speed = maxf(max_speed, Util.flat_dist(p, prev) / (Util.game_now() - window_t))
			prev = p
			window_t = Util.game_now()
	print("[ai] info: limp %.1f -> %.1f m from the player in %.0f s, max %.2f m/s" % [d0, _dist(e), LIMP_WATCH, max_speed])
	check(_dist(e) > d0 + 1.0 or _dist(e) >= AIBrain.FLEE_REST_DIST - 0.3, "limps away (%.1f -> %.1f m)" % [d0, _dist(e)])
	check(max_speed <= AIBrain.LIMP_SPEED + 0.2 and max_speed > AIBrain.LIMP_SPEED * 0.5,
		"at a limp (max %.2f m/s, LIMP_SPEED %.1f)" % [max_speed, AIBrain.LIMP_SPEED])
	check(tokens == 0, "no token while limping away (%d ticks)" % tokens)
	e.queue_free()
	await _wait(0.2)

# --- C. A stick enemy who loses his stick arm drops it -------------------------------

func _part_stick_arm() -> void:
	var e := FighterFactory.spawn_enemy(self, &"stick", Transform3D(Basis.from_euler(Vector3(0, PI, 0)), Vector3(-2, 0.05, -3.5)))
	var b := e.brain as AIBrain
	await _wait(0.5)
	check(b.has_stick(), "stick enemy armed")
	e.sever_limb(&"arm_r")
	await get_tree().physics_frame
	check(not b.has_stick() and b.dropped_stick != null and is_instance_valid(b.dropped_stick),
		"losing the stick arm drops the stick as a prop")
	e.queue_free()
	await _wait(0.2)

# --- Helpers ---------------------------------------------------------------------------

func _events_for(f: Node3D) -> Array:
	var out := []
	for ev: Array in fleeing_events:
		if ev[0] == f:
			out.append(ev[1])
	return out

func _keep_player() -> void:
	if "invuln_until" in player:
		player.set(&"invuln_until", TimeDirector.now() + 5.0)
	if player.hp < player.max_hp * 0.5:
		player.heal_fraction(1.0)
	if pin_player and player.get_ground_position().length() > 0.5 and not player.is_down():
		player.global_position = Vector3(0, 0.05, 0)
		player.reset_physics_interpolation()

func _settle(f: Fighter) -> void:
	var t0 := Util.game_now()
	while (not f.can_act() or f.is_down()) and Util.game_now() - t0 < 4.0:
		_keep_player()
		await get_tree().physics_frame

func _dist(f: Fighter) -> float:
	return Util.flat_dist(f.get_ground_position(), player.get_ground_position())

func _wait(s: float) -> void:
	var t0 := Util.game_now()
	while Util.game_now() - t0 < s:
		_keep_player()
		await get_tree().physics_frame

func _finish() -> void:
	AttackDirector.reset()
	print("[ai] test_limb_loss: %s (%d failures)" % ["PASS" if failures == 0 else "FAIL", failures])
	get_tree().quit(0 if failures == 0 else 1)
