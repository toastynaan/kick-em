extends "res://tests/input/input_test_base.gd"
## Round 7 key map through the real input path (Input.action_press ->
## PlayerController -> InputInterpreter -> combat.press / release), agent H:
## - every button reaches CombatController as its action (a recording double
##   stands in for B's combat, so only the map is checked), press and release;
## - the pad's kick layer: LT + X / A / B = leg kick / front kick / roundhouse
##   (A is Jump without the layer, never a jump with it), a layered press's
##   release maps to the same action whatever LT does in between, LT itself,
##   Jump and the removed buttons never reach combat;
## - player-time stamps, Cmd-held presses dropped with their release, a
##   disabled controller lets go of held buttons;
## - get_aim_dir() is the camera-relative stick (zero when neutral), and a
##   strike press turns the body to the freeflow pick first (auto_face);
## - with the real CombatController a punch tap starts an attack.

const A := CombatController.Action
const REC := preload("res://tests/input/press_recorder.gd")

func run() -> void:
	var p := spawn_player(Vector3.ZERO)
	await ticks(30)
	var pc := p.brain as PlayerController
	check(pc != null and pc.interpreter != null, "player has a PlayerController with an InputInterpreter")
	if pc == null:
		done()
		return
	var interp := pc.interpreter
	var real_combat := p.combat

	# --- Integration first: a punch tap starts an attack on B's real combat. ---------
	var starts: Array[StringName] = []
	real_combat.attack_started.connect(func(id: StringName) -> void: starts.append(id))
	press(&"punch")
	await ticks(1)
	release(&"punch")
	await ticks(3)
	check(starts.size() >= 1, "punch tap starts an attack on the real CombatController (%s)" % [starts])
	await wait_until(func() -> bool: return p.can_act() and not p.combat.is_attacking(), 240)
	await ticks(10)

	var rec = REC.use_on(p)
	await ticks(2)

	# --- One button, one action (keyboard / mouse bindings). -------------------------
	var map := {&"punch": A.LIGHT, &"leg_kick": A.LEG_KICK, &"gut_punch": A.GUT_PUNCH,
		&"uppercut": A.UPPERCUT, &"front_kick": A.FRONT_KICK, &"roundhouse": A.ROUNDHOUSE,
		&"grab": A.GRAB, &"counter": A.COUNTER, &"dash": A.DASH}
	for action: StringName in map:
		rec.calls.clear()
		press(action)
		await ticks(1)
		release(action)
		await ticks(2)
		var want := [[map[action], true], [map[action], false]]
		check(rec.pairs() == want, "%s -> %s press + release (got %s)" % [action, A.keys()[map[action]], _names(rec.pairs())])

	# --- Pad kick layer (LT). -------------------------------------------------------------
	for raw: StringName in Controls.KICK_LAYER:
		var kick: StringName = Controls.KICK_LAYER[raw]
		rec.calls.clear()
		press(&"kick_layer")
		await ticks(1)
		press(raw)
		await ticks(1)
		release(raw)
		await ticks(1)
		release(&"kick_layer")
		await ticks(2)
		var want2 := [[map[kick], true], [map[kick], false]]
		check(rec.pairs() == want2, "LT + %s -> %s (got %s)" % [raw, kick, _names(rec.pairs())])

	# LT and the button on the same tick: the layer already applies.
	rec.calls.clear()
	press(&"kick_layer")
	press(&"punch")
	await ticks(1)
	release(&"punch")
	release(&"kick_layer")
	await ticks(2)
	check(rec.pairs() == [[A.LEG_KICK, true], [A.LEG_KICK, false]], "LT + X on one tick -> leg kick (got %s)" % _names(rec.pairs()))

	# A layered press keeps its action for its release, even after LT is let go;
	# LT + A is the front kick and never a jump.
	rec.calls.clear()
	press(&"kick_layer")
	await ticks(1)
	press(&"jump")
	var airborne := false
	for i in 4:
		await get_tree().physics_frame
		airborne = airborne or p.is_airborne() or not p.is_on_floor()
	release(&"kick_layer")
	await ticks(2)
	release(&"jump")
	for i in 30:
		await get_tree().physics_frame
		airborne = airborne or p.is_airborne() or not p.is_on_floor()
	check(rec.pairs() == [[A.FRONT_KICK, true], [A.FRONT_KICK, false]],
		"LT + A, LT let go first: the release is still the front kick's (got %s)" % _names(rec.pairs()))
	check(not airborne, "LT + A does not jump")
	# A (jump) alone is not a combat button.
	rec.calls.clear()
	press(&"jump")
	await ticks(1)
	release(&"jump")
	await wait_until(func() -> bool: return p.is_on_floor() and not p.is_airborne() and p.can_act(), 240)
	await ticks(10)
	check(rec.calls.is_empty(), "Jump alone reaches no combat action (got %s)" % _names(rec.pairs()))

	# An unlayered press keeps its action too, even if LT goes down while it is held.
	rec.calls.clear()
	press(&"punch")
	await ticks(1)
	press(&"kick_layer")
	await ticks(2)
	release(&"punch")
	await ticks(1)
	release(&"kick_layer")
	await ticks(2)
	check(rec.pairs() == [[A.LIGHT, true], [A.LIGHT, false]],
		"X held, then LT: the release is still the punch's (got %s)" % _names(rec.pairs()))

	# LT alone and the removed buttons never reach combat.
	rec.calls.clear()
	press(&"kick_layer")
	await ticks(2)
	release(&"kick_layer")
	await ticks(1)
	for legacy: StringName in Controls.LEGACY_ACTIONS:
		if InputMap.has_action(legacy):
			press(legacy)
	await ticks(2)
	for legacy: StringName in Controls.LEGACY_ACTIONS:
		if InputMap.has_action(legacy):
			release(legacy)
	await ticks(2)
	check(rec.calls.is_empty(), "LT alone, heavy, kick, crouch, block, focus and lock-on reach nothing (got %s)" % _names(rec.pairs()))
	var cap_h := (p.capsule.shape as CapsuleShape3D).height
	check(p.is_on_floor() and not p.is_airborne() and is_equal_approx(cap_h, p.get_height()) and is_equal_approx(Engine.time_scale, 1.0),
		"no crouch (capsule %.2f m), no Focus slow motion" % cap_h)

	# --- Player-time stamps and hold time. --------------------------------------------------
	var t0 := interp.now()
	press(&"punch")
	await ticks(36)
	release(&"punch")
	await ticks(1)
	check(interp.last_press_time(&"punch") >= t0, "punch press stamped in player time")
	var hold := interp.last_hold(&"punch")
	check(near(hold, 0.3, 0.05), "a 36-tick hold reads 0.3 s (%.3f)" % hold)
	await ticks(2)

	# --- Cmd held: the press is dropped, and so is its release. ------------------------------
	rec.calls.clear()
	var dropped0 := interp.dropped_presses
	var rel0 := interp.last_release_time(&"grab")
	_key(KEY_META, true)
	await ticks(2)
	check(InputInterpreter.is_meta_held(), "Cmd (meta) reads as held")
	press(&"grab")
	await ticks(3)
	check(interp.dropped_presses == dropped0 + 1, "Cmd + grab press dropped (dropped=%d)" % interp.dropped_presses)
	check(not interp.is_held(&"grab"), "dropped grab is not held")
	_key(KEY_META, false)
	await ticks(2)
	check(not interp.is_held(&"grab"), "letting go of Cmd while C is down does not revive the press")
	release(&"grab")
	await ticks(2)
	check(interp.last_release_time(&"grab") == rel0, "the dropped press's release was dropped too")
	var dropped1 := interp.dropped_presses
	_key(KEY_C, true, true)
	await ticks(3)
	check(interp.dropped_presses == dropped1 + 1, "a C event with meta_pressed is dropped")
	_key(KEY_C, false)
	await ticks(3)
	check(rec.calls.is_empty(), "nothing reached combat while Cmd was held (got %s)" % _names(rec.pairs()))
	press(&"grab")
	await ticks(1)
	release(&"grab")
	await ticks(2)
	check(rec.pairs() == [[A.GRAB, true], [A.GRAB, false]], "without Cmd the grab gets through (got %s)" % _names(rec.pairs()))

	# --- Disabling the controller lets go of held buttons (layered ones too). ----------------
	rec.calls.clear()
	press(&"kick_layer")
	await ticks(1)
	press(&"gut_punch")
	await ticks(3)
	pc.enabled = false
	await ticks(3)
	check(rec.pairs() == [[A.ROUNDHOUSE, true], [A.ROUNDHOUSE, false]],
		"disabled controller released the held LT + B as the roundhouse (got %s)" % _names(rec.pairs()))
	release(&"gut_punch")
	release(&"kick_layer")
	await ticks(2)
	pc.enabled = true
	await ticks(2)
	check(not interp.is_held(&"gut_punch") and rec.calls.size() == 2, "re-enabled: nothing stuck, no stray release")

	# --- Freeflow aim: the camera-relative stick, zero when neutral. --------------------------
	check(pc.get_aim_dir() == Vector3.ZERO, "get_aim_dir() is zero with the stick neutral")
	press(&"move_right")
	await ticks(2)
	var aim := pc.get_aim_dir()
	var want_aim := pc.get_stick_world()
	check(aim.distance_to(want_aim) < 1e-4 and aim.length() > 0.9 and absf(aim.dot(pc.get_camera_forward())) < 0.05,
		"get_aim_dir() with D held is the stick, across the camera (%s)" % [aim])
	release(&"move_right")
	await ticks(10)

	# --- auto_face: a strike press turns to the freeflow pick before combat sees it. ---------
	p.teleport_to(Vector3.ZERO, Vector3.FORWARD)
	var right := spawn_dummy(&"grunt", Vector3(3.0, 0, -0.5), Vector3.LEFT)
	var ahead := spawn_dummy(&"grunt", Vector3(0.0, 0, -4.0), Vector3.BACK)
	await ticks(10)
	var cam_fwd := pc.get_camera_forward()
	var want_neutral := Targeting.pick_freeflow_target(p, Vector3.ZERO, null, cam_fwd)
	rec.calls.clear()
	press(&"punch")
	await ticks(1)
	release(&"punch")
	await ticks(2)
	var f0: Vector3 = rec.calls[0][3] if not rec.calls.is_empty() else Vector3.ZERO
	var to_n := (want_neutral.global_position - p.global_position) if want_neutral else Vector3.FORWARD
	to_n.y = 0.0
	check(want_neutral == ahead and f0.dot(to_n.normalized()) > 0.99,
		"neutral stick: the punch faces the enemy along the camera (%s)" % [want_neutral.name if want_neutral else "none"])
	p.teleport_to(Vector3.ZERO, Vector3.FORWARD)
	await ticks(2)
	rec.calls.clear()
	press(&"move_right")
	press(&"front_kick")
	await ticks(1)
	release(&"front_kick")
	release(&"move_right")
	await ticks(2)
	var stick_pick := Targeting.pick_freeflow_target(p, Vector3.RIGHT, null, cam_fwd)
	var f1: Vector3 = rec.calls[0][3] if not rec.calls.is_empty() else Vector3.ZERO
	var to_r := right.global_position - p.global_position
	to_r.y = 0.0
	check(stick_pick == right and f1.dot(to_r.normalized()) > 0.99,
		"stick right: the front kick faces the enemy on the right (facing %s)" % [f1])
	right.queue_free()
	ahead.queue_free()
	done()

func _names(pairs: Array) -> String:
	var out: PackedStringArray = []
	for e: Array in pairs:
		out.append("%s%s" % ["+" if e[1] else "-", A.keys()[e[0]]])
	return "[" + ", ".join(out) + "]"

func _key(code: Key, down: bool, meta := false) -> void:
	var e := InputEventKey.new()
	e.keycode = code
	e.physical_keycode = code
	e.pressed = down
	e.meta_pressed = meta or (code == KEY_META and down)
	Input.parse_input_event(e)
