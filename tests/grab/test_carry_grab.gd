extends Node3D
## Round 5 (Feel Reference: Getting the grab), through CombatController's Grab
## routing into Carry:
## - nobody in reach: the 6-frame grab whiffs and recovers;
## - a neutral enemy is caught in a clinch for Tuning.GRAB_BREAK_FRAMES (10
##   frames), then the hold connects with Tuning.GRAB_CONNECT_HITSTOP;
## - the enemy's Grab inside the window breaks it: both pushed ~1.5 m apart; a
##   press after the window does nothing;
## - a staggered enemy is held at once (no window);
## - the stick picks the part: toward = collar (Chest), sideways = arm on that
##   side, away = leg;
## - sprinting (when Traversal sprints): 2.0 m reach, 60% of the speed kept on
##   contact, dropped to walk afterwards.
## OWNER: agent G.

var _fail: Array[String] = []
var _events: Array = []

func _ready() -> void:
	get_tree().create_timer(120.0, true, false, true).timeout.connect(func() -> void:
		print("FAIL timeout")
		get_tree().quit(1))
	Carry.force_enabled = true
	for sig: StringName in [&"grab_started", &"grab_broken", &"carry_changed", &"strike_started", &"attack_whiff"]:
		var s := sig
		GameEvents.connect(s, func(a = null, b = null, c = null, d = null, e = null) -> void:
			_events.append([s, a, b, c, d, e]))
	GrabTestUtil.make_floor(self)
	await get_tree().physics_frame
	await _whiff()
	await _neutral_clinch()
	await _break(5, true)
	await _break(13, false)
	await _staggered()
	await _parts()
	await _sprint()
	_finish()

func _pair(dist := 1.2, archetype := &"grunt") -> Array:
	GrabTestUtil.reset_world()
	_events.clear()
	var p := GrabTestUtil.spawn(self, &"player", Vector3.ZERO, Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var e := GrabTestUtil.spawn(self, archetype, Vector3(0.0, 0.0, -dist), Vector3.BACK)
	await GrabTestUtil.frames(self, 20)
	return [p, e]

func _clear(nodes: Array) -> void:
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
	print("[whiff] whiff after %.3f s (startup %d + active %d frames), free after %.3f s, held=%s" % [
		t_whiff, int(Tuning.GRAB_FRAMES), int(Carry.GRAB_ACTIVE_FRAMES), t_free, p.carry.held])
	_check(p.carry.last_grab_result == &"whiff", "nobody in reach: whiff")
	_check(absf(t_whiff - Tuning.frames(Tuning.GRAB_FRAMES + Carry.GRAB_ACTIVE_FRAMES)) < 0.03,
		"whiff at the end of the 6-frame startup + active frames")
	_check(t_free > t_whiff + Tuning.frames(Carry.GRAB_WHIFF_FRAMES) - 0.03, "whiff recovery")
	_check(not p.carry.is_holding() and _count(&"attack_whiff") == 1, "nothing held, attack_whiff emitted")
	await _clear(pr)

func _neutral_clinch() -> void:
	var pr: Array = await _pair(1.2)
	var p: Fighter = pr[0]
	var e: Fighter = pr[1]
	e.carry.set(&"_ai_break_at", INF)
	var t0 := TimeDirector.now()
	GrabTestUtil.press(p, CombatController.Action.GRAB)
	GrabTestUtil.release(p, CombatController.Action.GRAB)
	# Keep the AI fallback from breaking it: clear its scheduled press every frame.
	var ok := await GrabTestUtil.wait_until(self, func() -> bool:
		e.carry.set(&"_ai_break_at", INF)
		return e.carry.is_held(), 0.5)
	var t_contact := TimeDirector.now() - t0
	_check(ok and p.carry.held == e, "contact: the enemy is caught")
	_check(p.carry.last_grab_result == &"clinch", "a neutral enemy is clinched first (break window)")
	var clinch_start := TimeDirector.now()
	ok = await GrabTestUtil.wait_until(self, func() -> bool:
		e.carry.set(&"_ai_break_at", INF)
		return p.carry.is_holding_body(), 0.6)
	var clinch := TimeDirector.now() - clinch_start
	print("[neutral] contact after %.3f s, clinch %.3f s (window %.3f s), hold=%s motor=%s bone=%s frozen_after=%s" % [
		t_contact, clinch, Tuning.frames(Tuning.GRAB_BREAK_FRAMES), ok,
		"ragdoll" if p.carry.uses_ragdoll_motor() else "pin", p.carry.get_held_bone(), p.is_frozen()])
	_check(ok, "the hold connects after the window")
	_check(absf(clinch - Tuning.frames(Tuning.GRAB_BREAK_FRAMES)) < 0.03, "clinch lasts GRAB_BREAK_FRAMES")
	_check(p.is_frozen() and e.is_frozen(), "connect hitstop on both")
	_check(e.ragdoll.is_full_ragdoll(), "the held enemy is a ragdoll")
	_check(p.carry.get_held_bone() == Bones.CHEST, "neutral stick: the collar (Chest)")
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
	await GrabTestUtil.wait_until(self, func() -> bool:
		e.carry.set(&"_ai_break_at", INF)
		return e.carry.is_held(), 0.5)
	var caught := TimeDirector.now()
	var d0 := Vector2(p.global_position.x - e.global_position.x, p.global_position.z - e.global_position.z).length()
	while TimeDirector.now() - caught < Tuning.frames(at_frame) - 1e-4:
		e.carry.set(&"_ai_break_at", INF)
		await get_tree().physics_frame
	e.carry.on_grab_pressed(TimeDirector.now())
	var pressed_at := TimeDirector.now() - caught
	await GrabTestUtil.wait(self, 0.4)
	var d1 := Vector2(p.global_position.x - e.global_position.x, p.global_position.z - e.global_position.z).length()
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

func _staggered() -> void:
	var pr: Array = await _pair(1.2)
	var p: Fighter = pr[0]
	var e: Fighter = pr[1]
	e.stagger(Vector3.FORWARD, 0.75)
	await GrabTestUtil.frames(self, 3)
	var st := GrabTestUtil.state_name(e)
	GrabTestUtil.press(p, CombatController.Action.GRAB)
	GrabTestUtil.release(p, CombatController.Action.GRAB)
	var ok := await GrabTestUtil.wait_until(self, func() -> bool: return p.carry.is_holding_body(), 0.4)
	print("[staggered] enemy %s: result %s, holding=%s" % [st, p.carry.last_grab_result, ok])
	_check(ok and p.carry.last_grab_result == &"hold", "a staggered enemy is held at once (no break window)")
	p.carry.drop(&"release")
	await _clear(pr)

func _parts() -> void:
	var cases := [["toward", Vector3.FORWARD, [Bones.CHEST]],
		["right", Vector3.RIGHT, [Bones.L_LOWER_ARM, Bones.R_LOWER_ARM]],
		["left", Vector3.LEFT, [Bones.L_LOWER_ARM, Bones.R_LOWER_ARM]],
		["away", Vector3.BACK, [Bones.L_LOWER_LEG, Bones.R_LOWER_LEG]]]
	for c: Array in cases:
		var pr: Array = await _pair(1.1)
		var p: Fighter = pr[0]
		var e: Fighter = pr[1]
		# Off balance (always succeeds: no clinch to wait for), and not pushed away.
		if e.combat.has_method(&"apply_stumble"):
			e.combat.call(&"apply_stumble", 1.0)
		else:
			e.stagger(Vector3.BACK, 0.4)
		await GrabTestUtil.frames(self, 2)
		p.move_input = c[1]
		GrabTestUtil.press(p, CombatController.Action.GRAB)
		GrabTestUtil.release(p, CombatController.Action.GRAB)
		await get_tree().physics_frame
		p.move_input = Vector3.ZERO
		await GrabTestUtil.wait_until(self, func() -> bool: return p.carry.is_holding_body(), 0.4)
		var bone := p.carry.get_held_bone()
		var side_ok := true
		if c[0] == "right" or c[0] == "left":
			# The held forearm is the one on the grabber's stick side.
			var hp := e.rig.get_bone_global_position(bone)
			var other := Bones.L_LOWER_ARM if bone == Bones.R_LOWER_ARM else Bones.R_LOWER_ARM
			var op := e.rig.get_bone_global_position(other)
			side_ok = (hp.x - op.x) * (c[1] as Vector3).x >= -0.05
		print("[part] stick %s -> %s (%s) side ok=%s" % [c[0], bone, p.carry.get_held_part(), side_ok])
		_check((c[2] as Array).has(bone) and side_ok, "stick %s holds %s" % [c[0], c[2]])
		p.carry.drop(&"release")
		await _clear(pr)

## Sprint grab: only when Traversal (agent M) sprints.
func _sprint() -> void:
	var pr: Array = await _pair(9.0)
	var p: Fighter = pr[0]
	var e: Fighter = pr[1]
	if p.traversal == null:
		print("[sprint] SKIP: no Traversal")
		await _clear(pr)
		return
	p.move_input = Vector3.FORWARD
	p.face_dir = Vector3.FORWARD
	GrabTestUtil.press(p, CombatController.Action.DASH)
	var sprinting := await GrabTestUtil.wait_until(self, func() -> bool:
		return p.traversal.is_sprinting() and p.traversal.get_speed() > 7.0, 1.6)
	if not sprinting:
		print("[sprint] SKIP: Traversal does not sprint yet (speed %.2f)" % p.traversal.get_speed())
		GrabTestUtil.release(p, CombatController.Action.DASH)
		p.move_input = Vector3.ZERO
		await _clear(pr)
		return
	# Grab once the enemy is just inside the sprint reach.
	await GrabTestUtil.wait_until(self, func() -> bool:
		return absf(e.global_position.z - p.global_position.z) <= Tuning.GRAB_SPRINT_REACH + 0.35, 2.0)
	var gap := absf(e.global_position.z - p.global_position.z)
	var v0 := p.traversal.get_speed()
	GrabTestUtil.press(p, CombatController.Action.GRAB)
	GrabTestUtil.release(p, CombatController.Action.GRAB)
	GrabTestUtil.release(p, CombatController.Action.DASH)
	var caught := await GrabTestUtil.wait_until(self, func() -> bool:
		e.carry.set(&"_ai_break_at", INF)
		return e.carry.is_held(), 0.4)
	var e_contact := e.get_center_of_mass()
	await GrabTestUtil.frames(self, 3)
	var v_contact := p.traversal.get_speed()
	await GrabTestUtil.wait(self, 0.35)
	var dragged := e.get_center_of_mass().z - e_contact.z
	await GrabTestUtil.wait(self, 0.4)
	var v_after := p.traversal.get_speed()
	print("[sprint] gap %.2f m at %.2f m/s: caught=%s, speed on contact %.2f (%.0f%%), victim dragged %.2f m, speed after %.2f" % [
		gap, v0, caught, v_contact, 100.0 * v_contact / maxf(v0, 0.01), -dragged, v_after])
	_check(caught, "sprint grab reaches the enemy from up to GRAB_SPRINT_REACH")
	_check(absf(v_contact / maxf(v0, 0.01) - Tuning.GRAB_SPRINT_KEEP) < 0.12, "the grab keeps 60% of the speed on contact")
	_check(dragged < -0.3, "the victim is dragged backwards from the contact")
	_check(v_after <= Tuning.WALK_SPEED * Tuning.HOLD_WALK_MULT + 0.6 or not p.traversal.is_sprinting(),
		"a sprint grab drops you to walking speed afterwards")
	p.move_input = Vector3.ZERO
	p.carry.drop(&"release")
	await _clear(pr)

func _check(ok: bool, what: String) -> void:
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		_fail.append(what)

func _finish() -> void:
	Carry.force_enabled = false
	if _fail.is_empty():
		print("PASS test_carry_grab")
		get_tree().quit(0)
	else:
		print("FAIL test_carry_grab: ", _fail)
		get_tree().quit(1)
