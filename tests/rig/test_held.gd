extends Node3D
## Held bodies (Feel Reference F9, Prototype 1 0-6 s), agent A. A hand node
## runs a course (6 m/s out and back, two hops) carried by a holder capsule;
## the held body is pinned to it by the velocity motor, never collides with
## the holder, and its legs keep swinging (G's F9 check "a held enemy's leg
## bones keep moving while you run" depends on this: leg angular velocity is
## logged). Covers a standing live enemy (torso grab), a flying body, a downed
## body (leg grab) and a settled corpse; after end_held the live body lands
## and gets up, the corpse settles and refreezes.

var _ok := true
var hand: Node3D
var holder: LabDummy
var probe: SpeedProbe

## Reads the held body's bone speeds after every controller has run and before
## the physics step: the speeds the cap enforces.
class SpeedProbe extends Node:
	var rc: RagdollController
	var pre_max := 0.0
	func _init() -> void:
		process_physics_priority = 100
	func _physics_process(_delta: float) -> void:
		if rc and rc.is_held():
			pre_max = maxf(pre_max, RigTestUtil.max_bone_speed(rc))

func _check(what: String, cond: bool, info := "") -> void:
	print("  %-56s %s %s" % [what, "ok" if cond else "FAILED", info])
	_ok = _ok and cond

func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame

## The run (a player carrying a body): from standing to 6 m/s in 0.25 s along
## +X, a 0.3 s turn at 1.85 s, back at 6 m/s; a 1.2 m hop on each leg
## (take-off and landing are instant, like a jump). The hand is at the
## carry height (1.75 m: a grunt held by the collar has its feet clear of the
## floor); the holder trails it by 0.45 m.
const CARRY_Y := 1.75
func _speed_at(t: float) -> float:
	if t < 0.25:
		return 6.0 * t / 0.25
	if t < 1.85:
		return 6.0
	if t < 2.15:
		return 6.0 - 12.0 * (t - 1.85) / 0.3
	return -6.0

func _hand_at(t: float, origin: Vector3) -> Transform3D:
	var x := 0.0
	var step := 1.0 / 120.0
	var u := 0.0
	while u < t:
		x += _speed_at(u) * step
		u += step
	var hop := 0.0
	var ph := fmod(t, 2.0)
	if ph > 0.8 and ph < 1.4:
		var k := (ph - 0.8) / 0.6
		hop = 4.0 * 1.2 * k * (1.0 - k)   # 1.2 m hop
	var dir := 1.0 if _speed_at(t) >= 0.0 else -1.0
	var basis := Basis.looking_at(Vector3(dir, 0, 0), Vector3.UP)
	return Transform3D(basis, origin + Vector3(x, CARRY_Y + hop, 0))

## Run the course carrying `d`; returns stats.
func _run(d: LabDummy, origin: Vector3, seconds: float) -> Dictionary:
	var rc := d.ragdoll
	var legs: Array[RID] = []
	for b in [Bones.L_UPPER_LEG, Bones.L_LOWER_LEG, Bones.R_UPPER_LEG, Bones.R_LOWER_LEG]:
		legs.append(d.rig.get_physical_bone(b).get_rid())
	var hips := d.rig.get_physical_bone(Bones.HIPS).get_rid()
	var out := {"leg_w_mean": 0.0, "leg_rel_mean": 0.0, "pin_mean": 0.0, "pin_max": 0.0, "speed_max": 0.0,
		"states": {}, "nan": false}
	probe.rc = rc
	probe.pre_max = 0.0
	var n := int(seconds * 120.0)
	for f in n:
		var xf := _hand_at(f / 120.0, origin)
		hand.global_transform = xf
		holder.global_position = xf.origin - xf.basis.z * -0.45 - Vector3(0, CARRY_Y, 0)
		holder.global_position.y = maxf(holder.global_position.y, 0.0)
		await get_tree().physics_frame
		var hw: Vector3 = PhysicsServer3D.body_get_state(hips, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY)
		var w := 0.0
		var rel := 0.0
		for r in legs:
			var lw: Vector3 = PhysicsServer3D.body_get_state(r, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY)
			w += lw.length()
			rel += (lw - hw).length()
		out["leg_w_mean"] += w / legs.size() / n
		out["leg_rel_mean"] += rel / legs.size() / n
		var pin: Vector3 = rc._xf[rc._held_i] * rc._held_local if rc.is_held() else hand.global_position
		var e := pin.distance_to(hand.global_position)
		if f >= 30:   # after the catch
			out["pin_mean"] += e / (n - 30)
			out["pin_max"] = maxf(out["pin_max"], e)
		out["speed_max"] = maxf(out["speed_max"], RigTestUtil.max_bone_speed(rc))
		out["states"][rc.state] = true
		out["nan"] = out["nan"] or RigTestUtil.has_nan(rc)
	out["capped_max"] = probe.pre_max
	return out

func _held_line(name: String, st: Dictionary) -> String:
	return "%s: legs |w| %.2f rad/s (vs pelvis %.2f), pin error mean %.3f max %.3f m, fastest bone %.1f m/s capped, %.1f inside a step" % [
		name, st["leg_w_mean"], st["leg_rel_mean"], st["pin_mean"], st["pin_max"], st["capped_max"], st["speed_max"]]

## Bones capped at 18 m/s (the cap applies each tick; joint impulses inside one
## physics step may add a little on top).
func _capped(st: Dictionary) -> bool:
	return st["capped_max"] <= Tuning.LAUNCH_SPEED_MAX + 0.01 and st["speed_max"] < 22.0

## The held body and the holder never collide (exceptions both ways).
func _excepted(d: LabDummy) -> bool:
	var ok := true
	for pb in d.rig.get_physical_bones():
		ok = ok and pb.get_collision_exceptions().has(holder)
	return ok

func _ready() -> void:
	get_tree().create_timer(150.0).timeout.connect(func() -> void:
		print("HELD FAIL (timeout)")
		get_tree().quit(1))
	RigTestUtil.make_floor(self, 400.0)
	hand = Node3D.new()
	hand.name = "Hand"
	add_child(hand)
	probe = SpeedProbe.new()
	add_child(probe)
	holder = RigTestUtil.make_dummy(self, &"player", Vector3(0, 0, -20), null, true)
	var v := RigTestUtil.make_dummy(self, &"grunt", Vector3(0, 0, 0), null, false)
	await _frames(8)
	var rc := v.ragdoll

	# --- A live enemy, grabbed by the chest while standing ------------------------------
	hand.global_transform = _hand_at(0.0, Vector3.ZERO)
	v.global_position = Vector3(hand.global_position.x, 0, hand.global_position.z)
	await _frames(4)
	rc.begin_held(Bones.CHEST, hand, holder)
	_check("standing enemy: held, full ragdoll, collisions with the holder off", rc.is_held()
		and rc.state == RagdollController.State.LAUNCHED and rc.is_full_ragdoll() and _excepted(v))
	var s := rc.get_bone_strength(Bones.L_LOWER_LEG)
	var t := rc.get_bone_strength(Bones.CHEST)
	_check("held: legs low tone, torso a little firmer", s < 0.1 and t > s, "legs %.2f, chest %.2f" % [s, t])
	var st := await _run(v, Vector3.ZERO, 4.0)
	print("  ", _held_line("live", st))
	_check("live held: legs keep swinging while running", st["leg_w_mean"] > 1.0 and st["leg_rel_mean"] > 0.6)
	_check("live held: stays pinned to the hand, bones <= 18 m/s", st["pin_mean"] < 0.06 and st["pin_max"] < 0.3
		and _capped(st) and not st["nan"])
	_check("live held: never lands or gets up while held", st["states"].keys() == [RagdollController.State.LAUNCHED])
	rc.end_held()
	_check("end_held: exceptions removed", not rc.is_held() and not _excepted(v))
	var n := 0
	while rc.state != RagdollController.State.ANIMATED and n < 900:
		await get_tree().physics_frame
		n += 1
	_check("let go: lands and gets up", rc.state == RagdollController.State.ANIMATED, "%.2f s" % (n / 120.0))

	# --- A flying body -----------------------------------------------------------------------
	await _frames(20)
	rc.launch(Vector3(0, 4, 3), v.global_position + Vector3.UP, Bones.CHEST)
	await _frames(15)
	hand.global_transform = Transform3D(Basis(), rc.get_center_of_mass() + Vector3(0, 0.25, 0))
	rc.begin_held(Bones.CHEST, hand, holder)
	var o := Vector3(hand.global_position.x, 0, hand.global_position.z)
	st = await _run(v, o, 2.0)
	print("  ", _held_line("flying", st))
	_check("flying body: caught into the held state", rc.is_held() and st["pin_mean"] < 0.06 and st["leg_w_mean"] > 1.0 and _capped(st))
	rc.end_held()
	n = 0
	while rc.state != RagdollController.State.ANIMATED and n < 900:
		await get_tree().physics_frame
		n += 1

	# --- A downed body, grabbed by the leg ---------------------------------------------------------
	rc.set_getup_after(5.0)
	rc.launch(Vector3(0, 2, 3), v.global_position + Vector3.UP, Bones.CHEST)
	n = 0
	while rc.state != RagdollController.State.GROUNDED and n < 900:
		await get_tree().physics_frame
		n += 1
	var ankle := v.rig.get_bone_global_position(Bones.L_FOOT)
	hand.global_transform = Transform3D(Basis(), ankle + Vector3(0, 0.05, 0))
	rc.begin_held(Bones.L_LOWER_LEG, hand, holder)
	_check("downed body: held (leg grab)", rc.is_held() and rc.state == RagdollController.State.LAUNCHED)
	# Lift and carry by the leg.
	for f in 60:
		hand.global_position = hand.global_position.move_toward(Vector3(ankle.x, CARRY_Y, ankle.z), 2.5 / 120.0)
		await get_tree().physics_frame
	o = Vector3(ankle.x, 0, ankle.z)
	st = await _run(v, o, 2.0)
	# Then the hand stops, lifted to 2.4 m so the arms clear the floor: the body
	# hangs head-down from it (mean over the last 0.5 s of 1.5 s).
	var below := 0.0
	var inverted := 0.0
	for f in 180:
		hand.global_position = hand.global_position.move_toward(Vector3(hand.global_position.x, 2.4, hand.global_position.z), 2.0 / 120.0)
		await get_tree().physics_frame
		if f >= 120:
			var head_y := v.rig.get_bone_global_position(Bones.HEAD).y
			below += (hand.global_position.y - head_y) / 60.0
			inverted += (v.rig.get_bone_global_position(Bones.HIPS).y - head_y) / 60.0
	print("  ", _held_line("leg grab", st))
	# A live body curls a little (its low-tone muscles pull toward the "held"
	# pose, hips flexed), so: head down, well below the hand and the hips.
	_check("leg grab: swings while carried, hangs head-down from the hand", below > 1.0 and inverted > 0.25
		and st["pin_mean"] < 0.06 and _capped(st) and not st["nan"],
		"head %.2f m below the hand, %.2f m below the hips" % [below, inverted])
	rc.end_held()
	n = 0
	while rc.state != RagdollController.State.ANIMATED and n < 1200:
		await get_tree().physics_frame
		n += 1
	_check("leg grab let go: gets up", rc.state == RagdollController.State.ANIMATED)

	# --- A dead body ------------------------------------------------------------------------------
	rc.kill(Vector3(0, 0.5, 1.0))
	n = 0
	while not rc.is_settled() and n < 1500:
		await get_tree().physics_frame
		n += 1
	_check("corpse settled before the grab", rc.is_settled())
	var chest := v.rig.get_bone_global_position(Bones.CHEST)
	hand.global_transform = Transform3D(Basis(), chest + Vector3(0, 0.2, 0))
	rc.begin_held(Bones.CHEST, hand, holder)
	_check("dead body: woken and held", rc.is_held() and not rc.is_settled() and rc.state == RagdollController.State.DEAD
		and rc.get_bone_strength(Bones.L_UPPER_LEG) == 0.0)
	for f in 60:
		hand.global_position = hand.global_position.move_toward(Vector3(chest.x, CARRY_Y, chest.z), 3.0 / 120.0)
		await get_tree().physics_frame
	o = Vector3(chest.x, 0, chest.z)
	st = await _run(v, o, 3.0)
	print("  ", _held_line("dead", st))
	_check("dead body: carried, legs dangle", st["pin_mean"] < 0.06 and st["leg_w_mean"] > 1.0 and not st["nan"] and _capped(st)
		and st["states"].keys() == [RagdollController.State.DEAD])
	rc.end_held()
	n = 0
	while not rc.is_settled() and n < 1500:
		await get_tree().physics_frame
		n += 1
	_check("dead body let go: settles and refreezes", rc.is_settled(), "%.2f s" % (n / 120.0))

	# --- Slow motion: the player carries a body at real speed (world at 0.3x) ---------------
	# Round 7 removed Focus mode; any non-KO slow motion keeps the player in real time.
	holder.add_to_group(&"player")
	var w := RigTestUtil.make_dummy(self, &"grunt", Vector3(40, 0, 0), null, false)
	await _frames(8)
	hand.global_transform = _hand_at(0.0, Vector3(40, 0, 0))
	w.ragdoll.begin_held(Bones.CHEST, hand, holder)
	TimeDirector.request_slowmo(0.3, 4.0, TimeDirector.PRIO_DODGE)
	await _frames(2)
	var k := TimeDirector.player_time_factor()
	st = await _run(w, Vector3(40, 0, 0), 3.0)
	TimeDirector.reset()
	print("  ", _held_line("slow x%.2f" % k, st))
	_check("slow motion: a body the player carries keeps up at real speed", k > 3.0 and st["pin_mean"] < 0.08
		and st["capped_max"] > Tuning.LAUNCH_SPEED_MAX and st["capped_max"] <= RagdollController.HELD_SPEED_CAP * k + 0.01
		and not st["nan"], "caps x%.2f" % k)
	w.ragdoll.end_held()
	holder.remove_from_group(&"player")
	print("HELD ", "PASS" if _ok else "FAIL")
	get_tree().quit(0 if _ok else 1)
