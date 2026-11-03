extends Node3D
## Round 7 (Grab, drive and throw: "Grab (C)"), through the real input path
## (Input.action_press(&"grab") -> PlayerController -> InputInterpreter ->
## CombatController -> Carry) where the button or the stick matters:
## - nobody in reach: the 6-frame grab whiffs and recovers;
## - a neutral enemy is caught in a clinch for Tuning.GRAB_BREAK_FRAMES (10
##   frames), then the hold connects with Tuning.GRAB_CONNECT_HITSTOP, always
##   by the collar (Chest);
## - the enemy's Grab inside the window breaks it: both pushed ~1.5 m apart; a
##   press after the window does nothing;
## - a reacting (staggered) enemy is held at once (no window);
## - glide: a grunt 2.8 m away is glided to at about R7_GLIDE_SPEED
##   (glide_started) and caught; one beyond R7_GRAB_GLIDE is not picked (whiff);
## - the stick picks the target (freeflow pick): stick right takes the grunt
##   on the right, stick left the one on the left; the hold is still the collar;
## - a downed grunt is picked up at once by the collar and held upright in front.
## OWNER: agent G.

var _fail: Array[String] = []
var _events: Array = []

func _ready() -> void:
	get_tree().create_timer(120.0, true, false, true).timeout.connect(func() -> void:
		print("FAIL timeout")
		get_tree().quit(1))
	Carry.force_enabled = true
	for sig: StringName in [&"grab_started", &"grab_broken", &"carry_changed", &"strike_started", &"attack_whiff", &"glide_started"]:
		var s := sig
		GameEvents.connect(s, func(a = null, b = null, c = null, d = null, e = null) -> void:
			_events.append([s, a, b, c, d, e]))
	GrabTestUtil.make_floor(self)
	await get_tree().physics_frame
	await _whiff()
	await _neutral_clinch()
	await _break(5, true)
	await _break(13, false)
	await _reacting()
	await _glide(2.8, true)
	await _glide(3.6, false)
	await _stick_pick(Vector3.RIGHT, &"move_right")
	await _stick_pick(Vector3.LEFT, &"move_left")
	await _downed()
	_finish()

## The real player at the origin facing -Z, a camera rig looking -Z, and a
## grunt `dist` m ahead facing it.
func _pair(dist := 1.2, archetype := &"grunt") -> Array:
	GrabTestUtil.reset_world()
	GrabTestUtil.release_all_input()
	_events.clear()
	var p := GrabTestUtil.spawn_player(self, Vector3.ZERO, Vector3.FORWARD)
	var cam := GrabTestUtil.make_camera(self, p, Vector3.FORWARD)
	var e := GrabTestUtil.spawn(self, archetype, Vector3(0.0, 0.0, -dist), Vector3.BACK)
	await GrabTestUtil.frames(self, 20)
	return [p, e, cam]

func _clear(nodes: Array) -> void:
	GrabTestUtil.release_all_input()
	for n in nodes:
		if is_instance_valid(n):
			n.queue_free()
	await GrabTestUtil.frames(self, 4)

func _count(sig: StringName) -> int:
	return _events.filter(func(ev: Array) -> bool: return ev[0] == sig).size()

func _whiff() -> void:
	var pr: Array = await _pair(5.0)
	var p: Fighter = pr[0]
	var t0 := TimeDirector.now()
	GrabTestUtil.press(p, CombatController.Action.GRAB)
	GrabTestUtil.release(p, CombatController.Action.GRAB)
	_check(p.carry.is_busy(), "the grab starts (busy) with nobody in reach")
	await GrabTestUtil.wait_until(self, func() -> bool: return p.carry.last_grab_result == &"whiff", 1.0)
	var t_whiff := TimeDirector.now() - t0
	await GrabTestUtil.wait_until(self, func() -> bool: return not p.carry.is_busy(), 1.0)
	var t_free := TimeDirector.now() - t0
	print("[whiff] whiff after %.3f s (startup %d + active %d frames), free after %.3f s, glide=%d held=%s" % [
		t_whiff, int(Tuning.GRAB_FRAMES), int(Carry.GRAB_ACTIVE_FRAMES), t_free, _count(&"glide_started"), p.carry.held])
	_check(p.carry.last_grab_result == &"whiff", "nobody in reach: whiff")
	_check(_count(&"glide_started") == 0, "a grunt 5 m away (beyond R7_GRAB_GLIDE) is not glided to")
	_check(absf(t_whiff - Tuning.frames(Tuning.GRAB_FRAMES + Carry.GRAB_ACTIVE_FRAMES)) < 0.03,
		"whiff at the end of the 6-frame startup + active frames")
	_check(t_free > t_whiff + Tuning.frames(Carry.GRAB_WHIFF_FRAMES) - 0.03, "whiff recovery")
	_check(not p.carry.is_holding() and _count(&"attack_whiff") == 1, "nothing held, attack_whiff emitted")
	await _clear(pr)

func _neutral_clinch() -> void:
	var pr: Array = await _pair(1.2)
	var p: Fighter = pr[0]
	var e: Fighter = pr[1]
	var t0 := TimeDirector.now()
	await GrabTestUtil.key_tap(self, &"grab")
	var ok := await GrabTestUtil.wait_until(self, func() -> bool: return e.carry.is_held(), 0.5)
	var t_contact := TimeDirector.now() - t0
	_check(ok and p.carry.held == e, "real input: C catches the enemy")
	_check(p.carry.last_grab_result == &"clinch", "a neutral enemy is clinched first (break window)")
	var clinch_start := TimeDirector.now()
	ok = await GrabTestUtil.wait_until(self, func() -> bool: return p.carry.is_holding_body(), 0.6)
	var clinch := TimeDirector.now() - clinch_start
	print("[neutral] contact after %.3f s, clinch %.3f s (window %.3f s), hold=%s motor=%s bone=%s part=%s frozen_after=%s" % [
		t_contact, clinch, Tuning.frames(Tuning.GRAB_BREAK_FRAMES), ok,
		"ragdoll" if p.carry.uses_ragdoll_motor() else "pin", p.carry.get_held_bone(), p.carry.get_held_part(), p.is_frozen()])
	_check(ok, "the hold connects after the window")
	_check(absf(clinch - Tuning.frames(Tuning.GRAB_BREAK_FRAMES)) < 0.03, "clinch lasts GRAB_BREAK_FRAMES")
	_check(p.is_frozen() and e.is_frozen(), "connect hitstop on both")
	_check(e.ragdoll.is_full_ragdoll(), "the held enemy is a ragdoll held by the motor")
	_check(p.carry.get_held_bone() == Bones.CHEST and p.carry.get_held_part() == &"collar", "the hold is the collar (Chest)")
	_check(_count(&"grab_started") == 1 and _count(&"strike_started") == 1, "grab_started and strike_started once")
	await GrabTestUtil.frames(self, 30)
	_check(p.carry.is_holding_body() and e.carry.get_holder() == p, "still holding")
	p.carry.drop(&"release")
	await _clear(pr)

## The enemy presses Grab `at_frame` frames after the catch.
func _break(at_frame: int, expect_break: bool) -> void:
	var pr: Array = await _pair(1.2)
	var p: Fighter = pr[0]
	var e: Fighter = pr[1]
	GrabTestUtil.press(p, CombatController.Action.GRAB)
	GrabTestUtil.release(p, CombatController.Action.GRAB)
	await GrabTestUtil.wait_until(self, func() -> bool: return e.carry.is_held(), 0.5)
	var caught := TimeDirector.now()
	var d0 := GrabTestUtil.flat_dist(p.global_position, e.global_position)
	while TimeDirector.now() - caught < Tuning.frames(at_frame) - 1e-4:
		await get_tree().physics_frame
	e.carry.on_grab_pressed(TimeDirector.now())
	var pressed_at := TimeDirector.now() - caught
	await GrabTestUtil.wait(self, 0.4)
	var d1 := GrabTestUtil.flat_dist(p.global_position, e.global_position)
	var broken := _count(&"grab_broken") == 1
	print("[break] enemy Grab %.3f s (%d frames) after the catch: broken=%s, gap %.2f -> %.2f m (+%.2f), holding=%s" % [
		pressed_at, at_frame, broken, d0, d1, d1 - d0, p.carry.is_holding()])
	if expect_break:
		_check(broken and not p.carry.is_holding() and not e.carry.is_held(), "Grab inside the window breaks the grab")
		_check(d1 - d0 > Tuning.GRAB_BREAK_PUSH * 0.75 and d1 - d0 < Tuning.GRAB_BREAK_PUSH * 1.35,
			"both pushed about GRAB_BREAK_PUSH apart")
	else:
		_check(not broken and p.carry.is_holding_body(), "Grab after the window does nothing")
		p.carry.drop(&"release")
	await _clear(pr)

func _reacting() -> void:
	var pr: Array = await _pair(1.2)
	var p: Fighter = pr[0]
	var e: Fighter = pr[1]
	e.react(&"fold", Vector3.FORWARD, 0.0, 1.0)
	await GrabTestUtil.frames(self, 3)
	var st := "%s react=%s reacting=%s" % [GrabTestUtil.state_name(e), e.get_react_state(), e.is_reacting()]
	await GrabTestUtil.key_tap(self, &"grab")
	var ok := await GrabTestUtil.wait_until(self, func() -> bool: return p.carry.is_holding_body(), 0.4)
	print("[reacting] enemy %s: result %s, holding=%s" % [st, p.carry.last_grab_result, ok])
	_check(ok and p.carry.last_grab_result == &"hold", "a reacting enemy is held at once (no break window)")
	p.carry.drop(&"release")
	await _clear(pr)

## A grunt `dist` m ahead: glided to (and caught) when within R7_GRAB_GLIDE.
func _glide(dist: float, expect: bool) -> void:
	var pr: Array = await _pair(dist)
	var p: Fighter = pr[0]
	var e: Fighter = pr[1]
	var t0 := TimeDirector.now()
	var peak := {"v": 0.0, "gliding": 0}
	await GrabTestUtil.key_tap(self, &"grab", 1)
	var ok := await GrabTestUtil.wait_until(self, func() -> bool:
		peak["v"] = maxf(peak["v"], GrabTestUtil.hspeed(p))
		if p.carry.is_gliding():
			peak["gliding"] += 1
		return e.carry.is_held() or p.carry.last_grab_result == &"whiff", 1.0)
	var t := TimeDirector.now() - t0
	var gap := GrabTestUtil.flat_dist(p.global_position, e.global_position)
	print("[glide %.1f m] glide_started=%d gliding ticks %d, peak speed %.2f m/s (R7_GLIDE_SPEED %.1f), caught=%s after %.3f s, gap %.2f m, result %s" % [
		dist, _count(&"glide_started"), int(peak["gliding"]), float(peak["v"]), Tuning.R7_GLIDE_SPEED,
		e.carry.is_held(), t, gap, p.carry.last_grab_result])
	if expect:
		_check(_count(&"glide_started") == 1, "glide %.1f m: glide_started" % dist)
		_check(float(peak["v"]) > Tuning.R7_GLIDE_SPEED * 0.85 and float(peak["v"]) < Tuning.R7_GLIDE_SPEED * 1.1,
			"glide %.1f m: the glide runs at about R7_GLIDE_SPEED" % dist)
		_check(ok and e.carry.is_held(), "glide %.1f m: the grunt is caught" % dist)
	else:
		_check(_count(&"glide_started") == 0 and not e.carry.is_held(), "%.1f m (beyond R7_GRAB_GLIDE): no glide, no catch" % dist)
	if p.carry.is_holding():
		p.carry.drop(&"release")
	await _clear(pr)

## Two grunts 2.4 m ahead, 35 degrees either side: the stick picks one.
func _stick_pick(side: Vector3, action: StringName) -> void:
	var pr: Array = await _pair(6.0)
	var p: Fighter = pr[0]
	var far: Fighter = pr[1]
	var a := deg_to_rad(35.0)
	var right := GrabTestUtil.spawn(self, &"grunt", Vector3(sin(a), 0.0, -cos(a)) * 2.4, Vector3(-sin(a), 0.0, cos(a)))
	var left := GrabTestUtil.spawn(self, &"grunt", Vector3(-sin(a), 0.0, -cos(a)) * 2.4, Vector3(sin(a), 0.0, cos(a)))
	await GrabTestUtil.frames(self, 10)
	GrabTestUtil.key_down(action)
	await GrabTestUtil.frames(self, 2)
	await GrabTestUtil.key_tap(self, &"grab", 1)
	GrabTestUtil.key_up(action)
	var want := right if side == Vector3.RIGHT else left
	var ok := await GrabTestUtil.wait_until(self, func() -> bool: return p.carry.is_holding_body(), 0.8)
	var got: Node3D = p.carry.held
	print("[stick %s] held %s (want %s), bone %s" % [action, got.name if got else "-", want.name, p.carry.get_held_bone()])
	_check(ok and got == want, "stick %s picks the grunt on that side" % action)
	_check(p.carry.get_held_bone() == Bones.CHEST, "stick %s: still the collar (no stick-chosen parts)" % action)
	if p.carry.is_holding():
		p.carry.drop(&"release")
	await _clear(pr + [right, left, far])

func _downed() -> void:
	var pr: Array = await _pair(1.5)
	var p: Fighter = pr[0]
	var e: Fighter = pr[1]
	e.knockdown(Vector3.FORWARD, Bones.CHEST)
	await GrabTestUtil.wait_until(self, func() -> bool: return e.get_state() == RagdollController.State.GROUNDED, 3.0)
	await GrabTestUtil.wait(self, 0.3)
	var st := GrabTestUtil.state_name(e)
	await GrabTestUtil.key_tap(self, &"grab")
	var ok := await GrabTestUtil.wait_until(self, func() -> bool: return p.carry.is_holding_body(), 0.6)
	await GrabTestUtil.wait(self, 0.6)
	var hips := e.rig.get_physical_bone(Bones.HIPS)
	var chest := e.rig.get_physical_bone(Bones.CHEST)
	var hp: Vector3 = PhysicsServer3D.body_get_state(hips.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM).origin
	var cp: Vector3 = PhysicsServer3D.body_get_state(chest.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM).origin
	var tilt := rad_to_deg((cp - hp).normalized().angle_to(Vector3.UP))
	var ahead := (cp - p.global_position).dot(p.get_forward())
	print("[downed] state %s: result %s holding=%s bone %s, torso tilt %.0f deg, chest %.2f m ahead at %.2f m high" % [
		st, p.carry.last_grab_result, ok, p.carry.get_held_bone(), tilt, ahead, cp.y])
	_check(ok and p.carry.last_grab_result == &"hold", "a downed grunt is picked up at once")
	_check(p.carry.get_held_bone() == Bones.CHEST, "picked up by the collar")
	_check(tilt < 35.0 and ahead > 0.25 and cp.y > 0.9, "held upright in front")
	p.carry.drop(&"release")
	await _clear(pr)

func _check(ok: bool, what: String) -> void:
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		_fail.append(what)

func _finish() -> void:
	Carry.force_enabled = false
	GrabTestUtil.release_all_input()
	if _fail.is_empty():
		print("PASS test_carry_grab")
		get_tree().quit(0)
	else:
		print("FAIL test_carry_grab: ", _fail)
		get_tree().quit(1)
