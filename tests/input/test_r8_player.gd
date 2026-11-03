extends "res://tests/input/input_test_base.gd"
## Round 8 PlayerController through the real input path (agent H, docs/Round 8
## — Charge and Pressure.md). A recording double stands in for B's combat
## (press_recorder.gd: get_air_follow_target(), is_charging() and the charge
## target are scripted), so only PlayerController's part is checked; Traversal
## is M's real one.
## - Jump (a Space key event) with combat.get_air_follow_target() set calls
##   traversal.start_air_follow(target): the launcher jump starts
##   (air_follow_started(player, body)) and the player climbs past a normal
##   jump's height toward the lifted body.
## - Pressed while Traversal cannot start the leap yet (here: the body is out
##   of Tuning.R8_AIR_FOLLOW_RANGE; in play, the uppercut's active frames and
##   hitstop), the press waits: no normal jump, and the leap starts on the
##   first tick Traversal accepts.
## - With no follow target, or a body that is no longer lifted, Jump is the
##   normal jump (Tuning.JUMP_HEIGHT apex).
## - A held strike button stays held: one press reaches combat, no release
##   until the real key-up (B charges it), and it is not pressed again.
## - While combat.is_charging(), the body turns to the charge target, not the
##   stick; with no target, or once the charge is over, the stick turns it.

const A := CombatController.Action
const REC := preload("res://tests/input/press_recorder.gd")

var _follows: Array = []  ## [fighter, target, Traversal.is_air_following() at the event]

func run() -> void:
	_timeout = 120.0
	GameEvents.air_follow_started.connect(func(f: Node3D, t: Node3D) -> void:
		_follows.append([f, t, (f as Fighter).traversal.is_air_following()]))
	var p := spawn_player(Vector3.ZERO)
	await ticks(30)
	var pc := p.brain as PlayerController
	var rec = REC.use_on(p)
	await ticks(10)
	await _follow_suite(p, rec)
	await _hold_suite(p, pc, rec)
	await _facing_suite(p, rec)
	done()

# --- Launcher jump ---------------------------------------------------------------------------
func _follow_suite(p: Fighter, rec) -> void:
	var lift: float = (Tuning.R8_MOVES[&"uppercut"]["charged"]["lift"] as Vector2).y
	var v := spawn_dummy(&"grunt", Vector3(0, 0, -2.0), Vector3.BACK)
	await ticks(30)
	var y0 := p.global_position.y
	v.react(&"lift", Vector3.FORWARD, 0.0, 0.0, _lift_info(v, p, lift))
	await ticks(18)  # the uppercut's hit was a moment ago
	rec.follow_target = v
	_follows.clear()
	_space(true)
	await ticks(1)
	_space(false)
	var top := 0.0
	for i in 48:
		await get_tree().physics_frame
		top = maxf(top, p.global_position.y - y0)
	var body := v.global_position.y - y0
	var ok_event: bool = _follows.size() == 1 and _follows[0][0] == p and _follows[0][1] == v
	var following: bool = ok_event and _follows[0][2]
	print("  Jump with a follow target: air_follow_started %s, following %s, climbed %.2f m in 0.4 s (body at %.2f m, a normal jump %.2f m)"
		% [ok_event, following, top, body, Tuning.JUMP_HEIGHT])
	check(ok_event and following, "Jump with combat.get_air_follow_target() set starts traversal.start_air_follow(target)")
	check(top > Tuning.JUMP_HEIGHT + 0.3, "the launcher jump climbs past a normal jump toward the body (%.2f m)" % top)
	rec.follow_target = null
	await wait_until(func() -> bool: return not p.is_airborne() and not p.traversal.is_air_following(), 480)
	await wait_until(func() -> bool: return not v.is_lifted(), 480)
	await _recover(v)

	# Traversal refuses at the press (out of range): the press waits, no normal jump.
	var far := p.global_position + Vector3(0, 0, -(Tuning.R8_AIR_FOLLOW_RANGE + 1.5))
	v.teleport_to(far, Vector3.BACK)
	await ticks(10)
	v.react(&"lift", Vector3.FORWARD, 0.0, 0.0, _lift_info(v, p, lift))
	await ticks(6)
	rec.follow_target = v
	_follows.clear()
	y0 = p.global_position.y
	_space(true)
	await ticks(1)
	_space(false)
	var rose := 0.0
	for i in 8:
		await get_tree().physics_frame
		rose = maxf(rose, p.global_position.y - y0)
	var waited := _follows.is_empty() and rose < 0.01
	var t_move := TimeDirector.now()
	v.teleport_to(Vector3(p.global_position.x, v.global_position.y, p.global_position.z - 2.0), Vector3.BACK)
	await wait_until(func() -> bool: return not _follows.is_empty(), 30)
	var lag := (TimeDirector.now() - t_move) if not _follows.is_empty() else -1.0
	print("  Jump while Traversal refuses: waited on the floor %s (rose %.3f m); in range: leap %.3f s later"
		% [waited, rose, lag])
	check(waited, "a refused launcher jump waits: no normal jump")
	check(lag >= 0.0 and lag <= 3.0 / 120.0 + 1e-4, "the waiting press leaps on the first tick Traversal accepts (%.3f s)" % lag)
	rec.follow_target = null
	await wait_until(func() -> bool: return not p.is_airborne() and not p.traversal.is_air_following(), 480)
	await wait_until(func() -> bool: return not v.is_lifted(), 480)
	await _recover(v)
	v.teleport_to(Vector3(0, 0, -2.0), Vector3.BACK)
	await ticks(30)

	# No follow target: the normal jump.
	_follows.clear()
	var apex := await _jump_apex(p)
	print("  Jump with no follow target: apex %.3f m (Tuning %.2f), launcher jumps %d" % [apex, Tuning.JUMP_HEIGHT, _follows.size()])
	check(_follows.is_empty() and near(apex, Tuning.JUMP_HEIGHT, 0.05), "no follow target: the normal jump")

	# A follow target that is no longer lifted (standing): the normal jump.
	await _recover(v)
	rec.follow_target = v
	_follows.clear()
	var apex2 := await _jump_apex(p)
	rec.follow_target = null
	print("  Jump with a body that is not lifted: apex %.3f m, launcher jumps %d" % [apex2, _follows.size()])
	check(_follows.is_empty() and near(apex2, Tuning.JUMP_HEIGHT, 0.05), "a body that is not lifted: the normal jump")
	v.queue_free()
	await ticks(10)

## A normal-jump press (Space): the apex above the take-off.
func _jump_apex(p: Fighter) -> float:
	var y0 := p.global_position.y
	_space(true)
	await ticks(1)
	_space(false)
	var apex := 0.0
	for i in 240:
		await get_tree().physics_frame
		apex = maxf(apex, p.global_position.y - y0)
		if apex > 0.05 and not p.is_airborne():
			break
	await wait_until(func() -> bool: return p.can_act() and not p.is_airborne(), 240)
	await ticks(20)
	return apex

# --- A held strike button stays held -----------------------------------------------------------
func _hold_suite(p: Fighter, pc: PlayerController, rec) -> void:
	rec.calls.clear()
	press(&"punch")
	await ticks(30)  # past R8_TAP_MAX: B would be charging now
	rec.charging = true
	await ticks(42)  # 0.6 s held
	var during: Array = rec.pairs()
	var held := pc.interpreter.is_held(&"punch")
	var held_time := pc.interpreter.held_time(&"punch")
	release(&"punch")
	await ticks(2)
	rec.charging = false
	var after: Array = rec.pairs()
	print("  punch held %.2f s: during %s, after the key-up %s" % [held_time, _names(during), _names(after)])
	check(during == [[A.LIGHT, true]], "a held strike reaches combat as one press, no release while held")
	check(held and held_time >= 0.59, "the interpreter keeps it held (%.2f s)" % held_time)
	check(after == [[A.LIGHT, true], [A.LIGHT, false]], "the release reaches combat once, at the key-up")
	await ticks(10)

# --- Facing while charging --------------------------------------------------------------------------
func _facing_suite(p: Fighter, rec) -> void:
	var t := spawn_dummy(&"grunt", p.global_position + Vector3(3.0, 0, 0), Vector3.LEFT)
	await ticks(20)
	p.snap_facing(Vector3.BACK)
	rec.charging = true
	rec.charge_target = t
	press(&"move_forward")  # the stick points away from the target (no camera: -Z)
	var walked := p.global_position
	await ticks(60)
	var to_t := t.global_position - p.global_position
	to_t.y = 0.0
	var face_t := p.get_forward().dot(to_t.normalized())
	var moved := (p.global_position - walked).dot(Vector3.FORWARD)
	rec.charge_target = null
	await ticks(60)
	var face_stick_no_target := p.get_forward().dot(Vector3.FORWARD)
	p.snap_facing(Vector3.BACK)
	rec.charge_target = t
	await ticks(30)
	rec.charging = false
	await ticks(60)
	var face_stick_after := p.get_forward().dot(Vector3.FORWARD)
	release(&"move_forward")
	rec.charge_target = null
	print("  charging with the stick forward: faces the target %.2f (walked %.2f m along the stick); no target: faces the stick %.2f; charge over: faces the stick %.2f"
		% [face_t, moved, face_stick_no_target, face_stick_after])
	check(face_t > 0.95, "while charging the body tracks the charge target, not the stick")
	check(moved > 0.3, "the stick still walks while charging")
	check(face_stick_no_target > 0.95, "charging with no target: the stick turns the body")
	check(face_stick_after > 0.95, "after the charge the stick turns the body again")
	t.queue_free()
	await ticks(5)

func _recover(v: Fighter) -> void:
	if v.ragdoll.is_simulating() or v.get_state() != RagdollController.State.ANIMATED:
		v.ragdoll.force_recover()
	v.clear_react()
	await ticks(10)

func _lift_info(v: Fighter, atk: Fighter, lift: float) -> HitInfo:
	var info := HitInfo.new()
	info.attacker = atk
	info.victim = v
	info.move_id = &"heavy_uppercut"
	info.kind = &"strike"
	info.react = &"lift"
	info.lift_height = lift
	info.hit_bone = Bones.HEAD
	info.hit_direction = Vector3.FORWARD
	info.hit_position = v.get_aim_point()
	info.charged = true
	info.charge = 1.0
	return info

func _names(pairs: Array) -> Array:
	return pairs.map(func(e: Array) -> String: return "%s %s" % [A.keys()[e[0]], "press" if e[1] else "release"])

## The Space key (Controls binds it to `jump` by physical keycode).
func _space(down: bool) -> void:
	var e := InputEventKey.new()
	e.keycode = KEY_SPACE
	e.physical_keycode = KEY_SPACE
	e.pressed = down
	Input.parse_input_event(e)
