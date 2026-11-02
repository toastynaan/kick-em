extends Node3D
## Round 5 (Feel Reference: Holding; F9 acceptance "a held enemy's leg bones
## keep moving while you run, per logged angular velocity"):
## - the held body is a partial ragdoll pinned to the hand: while the holder
##   runs (sprint + slalom) the legs keep swinging (mean leg angular speed per
##   0.1 s window, logged) and the body stays with the hand;
## - moving while holding: walk x0.7, sprint cap x0.8, vault limit 1.0 m
##   (measured through Traversal when it drives the player);
## - the body comes along through a jump;
## - HOLD_MAX: the victim struggles out with a shove, both stumble;
## - a hit on the holder drops the body; Grab releases it (a collar-held body
##   lands on its feet and stumbles).
## OWNER: agent G.

const LEG_SPIN_MIN := 0.6       ## rad/s mean leg angular speed every 0.1 s window while running
const BODY_FOLLOW := 1.3        ## m: the body's chest stays this close to the hand

var _fail: Array[String] = []
var _events: Array = []

func _ready() -> void:
	get_tree().create_timer(150.0, true, false, true).timeout.connect(func() -> void:
		print("FAIL timeout")
		get_tree().quit(1))
	Carry.force_enabled = true
	GameEvents.charge_released.connect(func(f: Node3D, id: StringName, level: int) -> void:
		_events.append([&"charge_released", f, id, level]))
	for sig: StringName in [&"grab_broken", &"carry_changed"]:
		var s := sig
		GameEvents.connect(s, func(a = null, b = null, c = null) -> void:
			_events.append([s, a, b, c]))
	GrabTestUtil.make_floor(self)
	await get_tree().physics_frame
	await _run_legs()
	await _focus_run()
	await _multipliers()
	await _jump()
	await _vault(0.9, true)
	await _vault(1.15, false)
	await _struggle()
	await _hit_drops()
	await _release()
	await _release_part(&"arm")
	await _release_part(&"leg")
	_finish()

func _pair(dist := 1.0) -> Array:
	GrabTestUtil.reset_world()
	_events.clear()
	var p := GrabTestUtil.spawn(self, &"player", Vector3.ZERO, Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var e := GrabTestUtil.spawn(self, &"grunt", Vector3(0.0, 0.0, -dist), Vector3.BACK)
	await GrabTestUtil.frames(self, 20)
	return [p, e]

func _hold(p: Fighter, e: Fighter) -> bool:
	var ok := p.carry.grab_now(e, &"", true)
	await GrabTestUtil.wait(self, 0.25)
	return ok and p.carry.is_holding_body()

func _clear(nodes: Array) -> void:
	for n in nodes:
		if is_instance_valid(n):
			n.queue_free()
	await GrabTestUtil.frames(self, 4)

func _count(sig: StringName) -> int:
	return _events.filter(func(ev: Array) -> bool: return ev[0] == sig).size()

func _sprint(p: Fighter, on: bool) -> void:
	if on:
		GrabTestUtil.press(p, CombatController.Action.DASH)
	else:
		GrabTestUtil.release(p, CombatController.Action.DASH)

## Run with the body: 1.0 s straight sprint, then a slalom (the stick swings
## +-50 degrees every 0.35 s). Logs the legs' mean angular speed per 0.1 s.
func _run_legs() -> void:
	var pr: Array = await _pair()
	var p: Fighter = pr[0]
	var e: Fighter = pr[1]
	_check(await _hold(p, e), "holding the grunt by the collar")
	var motor := "ragdoll motor" if p.carry.uses_ragdoll_motor() else "fallback pin"
	_sprint(p, true)
	var windows: Array[float] = []
	var straight: Array[float] = []
	var follow_max := 0.0
	var speed_max := 0.0
	var acc := 0.0
	var n := 0
	var t := 0.0
	var dt := 1.0 / float(Engine.physics_ticks_per_second)
	while t < 2.1 and p.carry.is_holding_body():
		var dir := Vector3.FORWARD
		if t >= 1.0:
			var k := 1.0 if int((t - 1.0) / 0.35) % 2 == 0 else -1.0
			dir = Vector3.FORWARD.rotated(Vector3.UP, deg_to_rad(50.0) * k)
		p.move_input = dir
		p.face_dir = dir
		await get_tree().physics_frame
		t += dt
		acc += GrabTestUtil.leg_spin(e)
		n += 1
		if p.traversal != null:
			speed_max = maxf(speed_max, p.traversal.get_speed())
		follow_max = maxf(follow_max, e.rig.get_bone_global_position(Bones.CHEST).distance_to(p.carry.get_hand().global_position))
		if n >= 12:
			(straight if t < 1.0 else windows).append(acc / n)
			acc = 0.0
			n = 0
	p.move_input = Vector3.ZERO
	_sprint(p, false)
	var min_w: float = windows.min() if not windows.is_empty() else 0.0
	var min_s: float = straight.slice(2).min() if straight.size() > 2 else 0.0
	print("[legs] %s, top speed %.2f m/s; straight run leg spin per 0.1 s: %s" % [motor, speed_max,
		", ".join(straight.map(func(x: float) -> String: return "%.2f" % x))])
	print("[legs] slalom run leg spin per 0.1 s: %s" % ", ".join(windows.map(func(x: float) -> String: return "%.2f" % x)))
	print("[legs] min window straight %.2f rad/s (after 0.2 s), slalom %.2f rad/s; chest-to-hand max %.2f m" % [min_s, min_w, follow_max])
	_check(not windows.is_empty() and min_w > LEG_SPIN_MIN, "the held legs keep moving while running (every window > %.1f rad/s)" % LEG_SPIN_MIN)
	_check(min_s > LEG_SPIN_MIN * 0.5, "they keep moving on a straight run too")
	_check(follow_max < BODY_FOLLOW, "the body stays with the hand")
	p.carry.drop(&"release")
	await _clear(pr)

## Focus mode (the world at 0.3x, the player at real speed): the body still
## comes with the hand while sprinting (the motor and the assist work in world
## time), and the legs still swing.
func _focus_run() -> void:
	var pr: Array = await _pair()
	var p: Fighter = pr[0]
	var e: Fighter = pr[1]
	await _hold(p, e)
	if not TimeDirector.begin_focus():
		print("[focus] SKIP: Focus refused")
		p.carry.drop(&"release")
		await _clear(pr)
		return
	p.move_input = Vector3.FORWARD
	p.face_dir = Vector3.FORWARD
	_sprint(p, true)
	var z0 := p.global_position.z
	var follow_max := 0.0
	var spin := 0.0
	var n := 0
	for i in 120:   # 1.0 s of real time at --fixed-fps 120
		await get_tree().physics_frame
		if i >= 24:
			follow_max = maxf(follow_max, e.rig.get_bone_global_position(Bones.CHEST).distance_to(p.carry.get_hand().global_position))
			spin += GrabTestUtil.leg_spin(e)
			n += 1
	var dist := absf(p.global_position.z - z0)
	_sprint(p, false)
	p.move_input = Vector3.ZERO
	var scale := Engine.time_scale
	TimeDirector.end_focus()
	print("[focus] world x%.2f: player ran %.2f m in 1 s real, still holding=%s, chest-to-hand max %.2f m, legs %.2f rad/s (world time)" % [
		scale, dist, p.carry.is_holding_body(), follow_max, spin / maxf(n, 1)])
	_check(p.carry.is_holding_body() and follow_max < BODY_FOLLOW, "in Focus the body still comes with the hand")
	p.carry.drop(&"release")
	await GrabTestUtil.wait(self, 0.3)
	await _clear(pr)

func _multipliers() -> void:
	var pr: Array = await _pair()
	var p: Fighter = pr[0]
	var e: Fighter = pr[1]
	_check(is_equal_approx(p.carry.get_move_speed_mult(), 1.0) and is_equal_approx(p.carry.get_sprint_cap_mult(), 1.0)
		and is_equal_approx(p.carry.get_vault_max_height(), Tuning.VAULT_MAX), "empty-handed: no change")
	await _hold(p, e)
	print("[mult] holding: walk x%.2f, sprint cap x%.2f, vault %.2f m" % [p.carry.get_move_speed_mult(),
		p.carry.get_sprint_cap_mult(), p.carry.get_vault_max_height()])
	_check(is_equal_approx(p.carry.get_move_speed_mult(), Tuning.HOLD_WALK_MULT), "walk at 70%")
	_check(is_equal_approx(p.carry.get_sprint_cap_mult(), Tuning.HOLD_SPRINT_MULT), "sprint up to 80% of the cap")
	_check(is_equal_approx(p.carry.get_vault_max_height(), Tuning.VAULT_MAX_HOLDING), "vault limit 1.0 m")
	if p.traversal != null:
		# Measured through Traversal: walk speed and sprint top speed with the body.
		p.move_input = Vector3.FORWARD
		p.face_dir = Vector3.FORWARD
		await GrabTestUtil.wait(self, 0.7)
		var walk := p.traversal.get_speed()
		_sprint(p, true)
		await GrabTestUtil.wait(self, 1.5)
		var sprint := p.traversal.get_speed()
		_sprint(p, false)
		p.move_input = Vector3.ZERO
		var cap := p.traversal.get_speed_cap()
		print("[mult] measured: walk %.2f m/s (%.0f%% of %.1f), sprint %.2f m/s, cap now %.2f (%.0f%% of %.1f)" % [
			walk, 100.0 * walk / Tuning.WALK_SPEED, Tuning.WALK_SPEED, sprint, cap, 100.0 * cap / Tuning.debug_speed_cap,
			Tuning.debug_speed_cap])
		_check(absf(walk - Tuning.WALK_SPEED * Tuning.HOLD_WALK_MULT) < 0.35, "walking with a body: 70% speed")
		_check(sprint <= Tuning.debug_speed_cap * Tuning.HOLD_SPRINT_MULT + 0.2, "sprinting with a body: at most 80% of the cap")
	p.carry.drop(&"release")
	await _clear(pr)

func _jump() -> void:
	var pr: Array = await _pair()
	var p: Fighter = pr[0]
	var e: Fighter = pr[1]
	await _hold(p, e)
	var y0 := e.get_center_of_mass().y
	var feet0 := p.global_position.y
	var jumped := false
	if p.traversal != null:
		jumped = p.traversal.on_jump_pressed()
	if not jumped:
		jumped = p.jump()
	var top := y0
	var ptop := feet0
	for i in 90:
		await get_tree().physics_frame
		top = maxf(top, e.get_center_of_mass().y)
		ptop = maxf(ptop, p.global_position.y)
	print("[jump] jumped=%s player rose %.2f m, held body rose %.2f m, still holding=%s" % [jumped, ptop - feet0, top - y0,
		p.carry.is_holding_body()])
	_check(jumped and ptop - feet0 > 0.8, "jump at full height while holding")
	_check(top - y0 > (ptop - feet0) * 0.6 and p.carry.is_holding_body(), "the body comes with you through the jump")
	p.carry.drop(&"release")
	await _clear(pr)

## Sprint with a body at a box `h` m high (Traversal's automatic parkour):
## 0.9 m is vaulted with the body in hand; 1.15 m is over the 1.0 m limit
## while holding and stops you.
func _vault(h: float, expect: bool) -> void:
	var pr: Array = await _pair()
	var p: Fighter = pr[0]
	var e: Fighter = pr[1]
	if p.traversal == null:
		print("[vault] SKIP: no Traversal")
		await _clear(pr)
		return
	var box := GrabTestUtil.make_wall(self, Vector3(0.0, h * 0.5, -6.0), Vector3(4.0, h, 0.5))
	var kinds: Array = []
	var on_parkour := func(f: Node3D, kind: StringName, _pos: Vector3, _h: float) -> void:
		if f == p:
			kinds.append(kind)
	GameEvents.parkour.connect(on_parkour)
	await _hold(p, e)
	p.move_input = Vector3.FORWARD
	p.face_dir = Vector3.FORWARD
	_sprint(p, true)
	await GrabTestUtil.wait(self, 2.0)
	_sprint(p, false)
	p.move_input = Vector3.ZERO
	GameEvents.parkour.disconnect(on_parkour)
	var past := p.global_position.z < -6.3
	var holding := p.carry.is_holding_body()
	print("[vault] %.2f m box with a body: parkour %s, player z %.2f (box at -6.0), past it=%s, still holding=%s" % [h, kinds,
		p.global_position.z, past, holding])
	if expect:
		_check(kinds.has(&"vault") and past and holding, "the body comes with you through a %.1f m vault" % h)
	else:
		_check(not past and not kinds.has(&"vault") and not kinds.has(&"mantle"),
			"a %.2f m box is over the 1.0 m vault limit while holding" % h)
	p.carry.drop(&"release")
	await _clear(pr + [box])

func _struggle() -> void:
	var pr: Array = await _pair()
	var p: Fighter = pr[0]
	var e: Fighter = pr[1]
	var t0 := TimeDirector.now()
	await _hold(p, e)
	await GrabTestUtil.wait_until(self, func() -> bool: return not p.carry.is_holding(), Tuning.HOLD_MAX + 1.0)
	var held_for := TimeDirector.now() - t0
	await GrabTestUtil.frames(self, 2)
	var p_off := p.combat.is_stumbling() or p.get_state() != RagdollController.State.ANIMATED or p.is_in_hitstun()
	var e_free := not e.carry.is_held()
	var e_state := GrabTestUtil.state_name(e)
	var e_off := e.combat.is_stumbling() or e.get_state() != RagdollController.State.ANIMATED or e.is_in_hitstun()
	print("[struggle] held %.2f s (HOLD_MAX %.1f): reason %s, holder off balance=%s, victim free=%s state %s off balance=%s" % [
		held_for, Tuning.HOLD_MAX, p.carry.last_drop_reason, p_off, e_free, e_state, e_off])
	_check(absf(held_for - Tuning.HOLD_MAX) < 0.15 and p.carry.last_drop_reason == &"struggle",
		"the victim struggles out after HOLD_MAX")
	_check(p_off and e_free and e_off and _count(&"grab_broken") == 1, "both stumble")
	await _clear(pr)

func _hit_drops() -> void:
	var pr: Array = await _pair()
	var p: Fighter = pr[0]
	var e: Fighter = pr[1]
	var other := GrabTestUtil.spawn(self, &"grunt", Vector3(1.0, 0.0, 0.5), Vector3.LEFT)
	await GrabTestUtil.frames(self, 5)
	await _hold(p, e)
	# Charging a throw when the hit lands: the charge ends without a throw.
	GrabTestUtil.press(p, CombatController.Action.HEAVY)
	await GrabTestUtil.wait(self, Tuning.CHARGE_LEVELS[0] + 0.05)
	var was_charging := p.carry.is_charging()
	var info := HitInfo.new()
	info.attacker = other
	info.victim = p
	info.move_id = &"e_jab"
	info.kind = &"strike"
	info.tier = HitInfo.Tier.FLINCH
	info.reaction = HitInfo.Reaction.FLINCH
	info.damage = 10.0
	info.hit_direction = Vector3.LEFT
	info.hit_position = p.get_aim_point()
	info.unblockable = true
	var r := p.take_hit(info)
	await GrabTestUtil.frames(self, 3)
	GrabTestUtil.release(p, CombatController.Action.HEAVY)
	var rel := _events.filter(func(ev: Array) -> bool: return ev[0] == &"charge_released" and ev[1] == p)
	print("[hit] holder hit while charging (%s, result %d): holding=%s reason=%s victim held=%s, charge_released %s, still charging=%s, thrown=%s" % [
		was_charging, r, p.carry.is_holding(), p.carry.last_drop_reason, e.carry.is_held(),
		rel.map(func(ev: Array) -> String: return "L%d" % ev[3]), p.carry.is_charging(), p.carry.last_throw_velocity])
	_check(not p.carry.is_holding() and p.carry.last_drop_reason == &"hit" and not e.carry.is_held(),
		"a hit on the holder drops the body")
	_check(was_charging and rel.size() == 1 and int(rel[0][3]) == 0 and not p.carry.is_charging()
		and p.carry.last_throw_velocity == Vector3.ZERO, "the cut charge ends with charge_released at level 0, no throw")
	await _clear(pr + [other])

func _release() -> void:
	var pr: Array = await _pair()
	var p: Fighter = pr[0]
	var e: Fighter = pr[1]
	await _hold(p, e)
	GrabTestUtil.press(p, CombatController.Action.GRAB)
	GrabTestUtil.release(p, CombatController.Action.GRAB)
	await GrabTestUtil.frames(self, 3)
	var st := GrabTestUtil.state_name(e)
	var stumbling := e.combat.is_stumbling() or e.is_in_hitstun()
	print("[release] Grab while holding: holding=%s victim %s stumbling=%s" % [p.carry.is_holding(), st, stumbling])
	_check(not p.carry.is_holding() and not e.carry.is_held(), "Grab releases the body")
	_check(e.get_state() != RagdollController.State.LAUNCHED or stumbling, "a collar-held body lands and stumbles")
	await GrabTestUtil.wait(self, 2.5)
	print("[release] 2.5 s later the victim is %s" % GrabTestUtil.state_name(e))
	_check(e.get_state() == RagdollController.State.ANIMATED, "the released victim is back on its feet")
	await _clear(pr)

## Grab releases an arm-held body (it hangs upright: it lands and stumbles) and
## a leg-held one (upside down: it keeps falling and gets up later).
func _release_part(part: StringName) -> void:
	var pr: Array = await _pair()
	var p: Fighter = pr[0]
	var e: Fighter = pr[1]
	p.carry.grab_now(e, part, true)
	# The arm-held body hangs with its torso upright; the leg-held one is
	# tipped upside down after a second.
	await GrabTestUtil.wait(self, 0.6 if part == &"arm" else 1.2)
	var held_part := p.carry.get_held_part()
	var hp: Vector3 = (PhysicsServer3D.body_get_state(e.rig.get_physical_bone(Bones.HIPS).get_rid(),
		PhysicsServer3D.BODY_STATE_TRANSFORM) as Transform3D).origin
	var cp: Vector3 = (PhysicsServer3D.body_get_state(e.rig.get_physical_bone(Bones.CHEST).get_rid(),
		PhysicsServer3D.BODY_STATE_TRANSFORM) as Transform3D).origin
	var tilt := rad_to_deg((cp - hp).normalized().angle_to(Vector3.UP))
	GrabTestUtil.press(p, CombatController.Action.GRAB)
	GrabTestUtil.release(p, CombatController.Action.GRAB)
	await GrabTestUtil.frames(self, 3)
	var st := GrabTestUtil.state_name(e)
	var stumbling := e.combat.is_stumbling() or e.is_in_hitstun()
	print("[release %s] held by the %s (torso tilt %.0f deg, pelvis %.2f m), Grab: victim %s stumbling=%s" % [part,
		held_part, tilt, hp.y, st, stumbling])
	if part == &"arm":
		_check(held_part == &"arm" and tilt < Carry.STAND_TILT and e.get_state() != RagdollController.State.LAUNCHED
			and stumbling, "an arm-held live body, upright, lands on its feet and stumbles")
	else:
		_check(held_part == &"leg" and tilt > Carry.STAND_TILT and e.ragdoll.is_full_ragdoll() and not stumbling,
			"a leg-held body (tipped over) keeps falling")
		var up := await GrabTestUtil.wait_until(self, func() -> bool:
			return e.get_state() == RagdollController.State.ANIMATED, 4.0)
		_check(up, "and gets up")
	await _clear(pr)

func _check(ok: bool, what: String) -> void:
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		_fail.append(what)

func _finish() -> void:
	Carry.force_enabled = false
	if _fail.is_empty():
		print("PASS test_carry_hold")
		get_tree().quit(0)
	else:
		print("FAIL test_carry_hold: ", _fail)
		get_tree().quit(1)
