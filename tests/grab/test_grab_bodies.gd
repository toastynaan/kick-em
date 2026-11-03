extends Node3D
## F9 acceptance: "Grabbing a flying, a downed and a dead body all succeed."
## Round 7: "Reacting, downed and dead bodies connect at once"; the hold is
## always the collar. Each through the player's Grab press (CombatController
## routing -> Carry):
## - flying: a grunt launched up in front of the player, grabbed in the air;
## - downed: a grunt knocked down and lying still, grabbed off the floor;
## - dead: a grunt killed and settled (frozen corpse), picked up (wake).
## Each must end held at once (no clinch, the held state on its ragdoll), by
## the collar (Chest), come with the holder, and be throwable (LIGHT). Logs the
## state at the press, the bone taken and the time to the hold.
## OWNER: agent G.

var _fail: Array[String] = []

func _ready() -> void:
	get_tree().create_timer(150.0, true, false, true).timeout.connect(func() -> void:
		print("FAIL timeout")
		get_tree().quit(1))
	Carry.force_enabled = true
	GrabTestUtil.make_floor(self)
	await get_tree().physics_frame
	await _case(&"flying")
	await _case(&"downed")
	await _case(&"dead")
	_finish()

func _case(kind: StringName) -> void:
	GrabTestUtil.reset_world()
	var p := GrabTestUtil.spawn(self, &"player", Vector3.ZERO, Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var e := GrabTestUtil.spawn(self, &"grunt", Vector3(0.0, 0.0, -1.1), Vector3.BACK)
	await GrabTestUtil.frames(self, 20)
	var ok_setup := true
	match kind:
		&"flying":
			e.launch(Vector3(0.0, 5.0, 0.4), e.get_center_of_mass(), Bones.CHEST)
			await GrabTestUtil.wait(self, 0.22)
			ok_setup = e.is_launched() and e.get_center_of_mass().y > 1.3
		&"downed":
			e.knockdown(Vector3.FORWARD, Bones.CHEST)
			ok_setup = await GrabTestUtil.wait_until(self, func() -> bool:
				return e.get_state() == RagdollController.State.GROUNDED, 3.0)
			await GrabTestUtil.wait(self, 0.2)
		&"dead":
			e.apply_damage(e.hp + 1.0, &"test")
			# Lie still long enough to settle and freeze (Tuning.DEAD_FREEZE_AFTER).
			await GrabTestUtil.wait(self, Tuning.DEAD_FREEZE_AFTER + 1.5)
			ok_setup = e.is_dead()
	# Walk up to the body: stand 0.6 m short of its nearest point, facing it.
	var target := e.get_center_of_mass()
	if kind != &"flying":
		var to := Vector3(target.x, 0.0, target.z) - Vector3(p.global_position.x, 0.0, p.global_position.z)
		p.teleport_to(Vector3(target.x, 0.0, target.z) - to.normalized() * 0.7, to)
		await GrabTestUtil.frames(self, 2)
	var st := GrabTestUtil.state_name(e)
	var com_y := e.get_center_of_mass().y
	var t0 := TimeDirector.now()
	GrabTestUtil.press(p, CombatController.Action.GRAB)
	GrabTestUtil.release(p, CombatController.Action.GRAB)
	await get_tree().physics_frame
	var held := await GrabTestUtil.wait_until(self, func() -> bool: return p.carry.is_holding_body(), 0.6)
	var t_hold := TimeDirector.now() - t0
	var bone := p.carry.get_held_bone()
	var motor_held := e.ragdoll.is_held() or e.ragdoll.is_gripped()
	# It comes with the holder: walk 1.5 m and measure the body.
	var c0 := e.get_center_of_mass()
	p.move_input = Vector3.RIGHT
	p.face_dir = Vector3.RIGHT
	await GrabTestUtil.wait(self, 0.6)
	p.move_input = Vector3.ZERO
	var moved := e.get_center_of_mass() - c0
	var still := p.carry.is_holding_body()
	await GrabTestUtil.tap(self, p, CombatController.Action.LIGHT, 0.05)
	await GrabTestUtil.frames(self, 2)
	var thrown := e.get_com_velocity().length()
	print("[%s] setup ok=%s state at press %s (COM %.2f m up): held=%s after %.3f s by %s (%s), motor holds=%s; carried %.2f m (still holding=%s); thrown at %.2f m/s" % [
		kind, ok_setup, st, com_y, held, t_hold, bone, p.carry.last_grab_result, motor_held, Vector2(moved.x, moved.z).length(),
		still, thrown])
	_check(ok_setup, "%s: setup" % kind)
	_check(held and motor_held, "%s body: the grab succeeds (held)" % kind)
	_check(t_hold < Tuning.frames(Tuning.GRAB_FRAMES + Carry.GRAB_ACTIVE_FRAMES) + 0.05 and p.carry.last_grab_result != &"clinch",
		"%s body: it connects at once (no clinch)" % kind)
	_check(bone == Bones.CHEST, "%s body: held by the collar" % kind)
	_check(Vector2(moved.x, moved.z).length() > 0.8 and still, "%s body: it comes with the holder" % kind)
	_check(thrown > 4.0, "%s body: it can be thrown" % kind)
	p.queue_free()
	e.queue_free()
	await GrabTestUtil.frames(self, 4)

func _check(ok: bool, what: String) -> void:
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		_fail.append(what)

func _finish() -> void:
	Carry.force_enabled = false
	if _fail.is_empty():
		print("PASS test_grab_bodies")
		get_tree().quit(0)
	else:
		print("FAIL test_grab_bodies: ", _fail)
		get_tree().quit(1)
