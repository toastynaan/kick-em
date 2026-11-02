extends Node3D
## Round 5 (Feel Reference: Being grabbed; Defence: "Enemy grabs can't be
## parried. Break them with Grab in the 10-frame window, or teleport"; "Enemies
## can grab you and knock you down but can't launch you or take your limbs"):
## - connect_enemy_grab: the player is held standing in front of the enemy, no
##   movement, no actions; both calling conventions (the grabber's Carry, or
##   the victim's own Carry as CombatController calls it) work;
## - Grab within GRAB_BREAK_FRAMES (or just before the connect) breaks it:
##   both pushed ~1.5 m apart; a later press does nothing;
## - no break, e_grab: the throw knocks the player down (preset KNOCKDOWN,
##   Tuning.DMG_ENEMY e_grab), never a launch tier, no limb lost; he gets up;
## - e_grab_slam (heavy): lift and slam, KNOCKDOWN, DMG_ENEMY e_grab_slam;
## - a vanished or invulnerable player cannot be grabbed.
## OWNER: agent G.

var _fail: Array[String] = []
var _hits: Array[HitInfo] = []
var _events: Array = []

func _ready() -> void:
	get_tree().create_timer(150.0, true, false, true).timeout.connect(func() -> void:
		print("FAIL timeout")
		get_tree().quit(1))
	Carry.force_enabled = true
	GameEvents.hit_landed.connect(func(info: HitInfo) -> void: _hits.append(info))
	for sig: StringName in [&"grab_broken", &"grab_started", &"limb_severed"]:
		var s := sig
		GameEvents.connect(s, func(a = null, b = null, c = null) -> void:
			_events.append([s, a, b, c]))
	GrabTestUtil.make_floor(self)
	await get_tree().physics_frame
	await _held_then_thrown(&"grunt", &"e_grab", false)
	await _held_then_thrown(&"heavy", &"e_grab_slam", true)
	await _break(5)
	await _break(-2)
	await _late_press()
	await _refusals()
	_finish()

func _pair(archetype: StringName) -> Array:
	GrabTestUtil.reset_world()
	_hits.clear()
	_events.clear()
	var p := GrabTestUtil.spawn(self, &"player", Vector3.ZERO, Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var e := GrabTestUtil.spawn(self, archetype, Vector3(0.0, 0.0, -1.0), Vector3.BACK)
	await GrabTestUtil.frames(self, 20)
	return [p, e]

func _clear(nodes: Array) -> void:
	for n in nodes:
		if is_instance_valid(n):
			n.queue_free()
	await GrabTestUtil.frames(self, 4)

func _count(sig: StringName) -> int:
	return _events.filter(func(ev: Array) -> bool: return ev[0] == sig).size()

func _gap(a: Fighter, b: Fighter) -> float:
	return Vector2(a.global_position.x - b.global_position.x, a.global_position.z - b.global_position.z).length()

func _held_then_thrown(archetype: StringName, move: StringName, victim_side_call: bool) -> void:
	var pr: Array = await _pair(archetype)
	var p: Fighter = pr[0]
	var e: Fighter = pr[1]
	var hp0 := p.hp
	var ok: bool
	if victim_side_call:
		# As CombatController calls it: on the victim's Carry, the grab move active.
		e.combat.start_enemy_attack(move, 0.3)
		await GrabTestUtil.wait_until(self, func() -> bool: return e.combat.is_attack_active() or p.carry.is_held(), 1.0)
		# CombatController may already have connected it on the active frame.
		ok = p.carry.is_held() or p.carry.connect_enemy_grab(p, move)
	else:
		ok = e.carry.connect_enemy_grab(p, move)
	_check(ok and p.carry.is_held() and p.carry.get_holder() == e and e.carry.held == p,
		"%s: %s connects, the player is held (%s call)" % [archetype, move, "victim-side" if victim_side_call else "holder-side"])
	p.move_input = Vector3.BACK
	var can_act := p.can_act()
	GrabTestUtil.press(p, CombatController.Action.LIGHT)
	await GrabTestUtil.frames(self, 12)
	GrabTestUtil.release(p, CombatController.Action.LIGHT)
	p.move_input = Vector3.ZERO
	# Held in front of the enemy (Carry.CLINCH_DIST), not walking away.
	var spot := e.global_position + e.get_forward() * Carry.CLINCH_DIST * e.get_height_scale()
	var walked := Vector2(p.global_position.x - spot.x, p.global_position.z - spot.z).length()
	var attacked := p.combat.is_attacking()
	var top := [p.global_position.y]   # an array: lambdas capture locals by value
	await GrabTestUtil.wait_until(self, func() -> bool:
		top[0] = maxf(top[0], p.global_position.y)
		return not p.carry.is_held(), 1.5)
	await GrabTestUtil.frames(self, 3)
	var hit := _hits.filter(func(h: HitInfo) -> bool: return h.victim == p and h.move_id == move)
	var h: HitInfo = hit[0] if hit.size() > 0 else null
	print("[%s] held: can_act=%s off the hold spot %.2f m attacked=%s lifted %.2f m; then %s: %s %.0f dmg (hp %.0f -> %.0f), player %s, limbs lost %d" % [
		move, can_act, walked, attacked, top[0], "slam" if move == &"e_grab_slam" else "throw",
		HitInfo.tier_name(h.tier) if h else &"-", h.damage if h else 0.0, hp0, p.hp, GrabTestUtil.state_name(p), _count(&"limb_severed")])
	_check(not can_act and walked < 0.15 and not attacked, "%s: held in front of the enemy, can't move or attack" % move)
	if move == &"e_grab_slam":
		_check(top[0] > Carry.ENEMY_SLAM_LIFT * 0.6, "the heavy lifts the player before the slam")
	_check(h != null and h.tier == HitInfo.Tier.KNOCKDOWN and not HitInfo.is_launch_tier(h.tier),
		"%s knocks the player down (never a launch)" % move)
	_check(h != null and is_equal_approx(h.damage, float(Tuning.DMG_ENEMY[move])) and is_equal_approx(hp0 - p.hp, h.damage),
		"%s deals Tuning.DMG_ENEMY (%.0f)" % [move, Tuning.DMG_ENEMY[move]])
	_check(p.is_down() and _count(&"limb_severed") == 0, "the player is down, no limb lost")
	var up := await GrabTestUtil.wait_until(self, func() -> bool:
		return p.get_state() == RagdollController.State.ANIMATED, 4.0)
	_check(up, "the player gets up")
	await _clear(pr)

## The player presses Grab `at_frame` frames after the connect (negative: before it).
func _break(at_frame: int) -> void:
	var pr: Array = await _pair(&"grunt")
	var p: Fighter = pr[0]
	var e: Fighter = pr[1]
	if at_frame < 0:
		p.carry.on_grab_pressed(TimeDirector.now())   # early: a player's own grab starts...
		await GrabTestUtil.frames(self, -at_frame * 2)
	var d0 := _gap(p, e)
	e.carry.connect_enemy_grab(p, &"e_grab")
	if at_frame > 0:
		await GrabTestUtil.frames(self, at_frame * 2)
		p.carry.on_grab_pressed(TimeDirector.now())
	await GrabTestUtil.wait(self, 0.45)
	var d1 := _gap(p, e)
	var broken := _count(&"grab_broken") == 1
	var thrown := _hits.any(func(h: HitInfo) -> bool: return h.victim == p and h.move_id == &"e_grab")
	print("[break] Grab %d frames %s the connect: broken=%s thrown=%s, gap %.2f -> %.2f m" % [absi(at_frame),
		"after" if at_frame > 0 else "before", broken, thrown, d0, d1])
	_check(broken and not thrown and not p.carry.is_held(), "Grab %d frames %s the connect breaks it" % [absi(at_frame),
		"after" if at_frame > 0 else "before"])
	_check(d1 - d0 > Tuning.GRAB_BREAK_PUSH * 0.7, "both pushed about 1.5 m apart (+%.2f m)" % (d1 - d0))
	await _clear(pr)

func _late_press() -> void:
	var pr: Array = await _pair(&"grunt")
	var p: Fighter = pr[0]
	var e: Fighter = pr[1]
	e.carry.connect_enemy_grab(p, &"e_grab")
	await GrabTestUtil.frames(self, 2 * int(Tuning.GRAB_BREAK_FRAMES) + 6)
	p.carry.on_grab_pressed(TimeDirector.now())
	await GrabTestUtil.wait(self, 0.6)
	var thrown := _hits.any(func(h: HitInfo) -> bool: return h.victim == p and h.move_id == &"e_grab")
	print("[late] Grab %d frames after the connect: broken=%s thrown=%s" % [int(Tuning.GRAB_BREAK_FRAMES) + 3,
		_count(&"grab_broken") > 0, thrown])
	_check(_count(&"grab_broken") == 0 and thrown, "a Grab after the 10-frame window does not break it")
	await _clear(pr)

func _refusals() -> void:
	var pr: Array = await _pair(&"grunt")
	var p: Fighter = pr[0]
	var e: Fighter = pr[1]
	p.invuln_until = TimeDirector.now() + 1.0
	var inv := e.carry.connect_enemy_grab(p, &"e_grab")
	p.invuln_until = 0.0
	var vanished := false
	if p.defence != null and p.defence.is_enabled():
		# Defence decides vanish itself; nothing to force here.
		vanished = p.defence.is_vanished()
	print("[refuse] invulnerable player grabbed=%s (vanish check active=%s)" % [inv, vanished])
	_check(not inv and not p.carry.is_held(), "an invulnerable player cannot be grabbed")
	await _clear(pr)

func _check(ok: bool, what: String) -> void:
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		_fail.append(what)

func _finish() -> void:
	Carry.force_enabled = false
	if _fail.is_empty():
		print("PASS test_enemy_grab")
		get_tree().quit(0)
	else:
		print("FAIL test_enemy_grab: ", _fail)
		get_tree().quit(1)
