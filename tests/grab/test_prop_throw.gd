extends Node3D
## F9 acceptance: "A thrown brick staggers and shatters." (Feel Reference:
## Props: Grab picks a prop up when no body is in reach, with no slowdown even
## while sprinting; Heavy throws it; a prop hit is a stagger and 8 damage; only
## a brick to the head knocks down; it breaks on impact.)
## - a brick on the floor, nobody in reach: Grab takes it (prop_picked_up);
## - Heavy throws it at a grunt 5 m away: a stagger-tier hit for
##   Tuning.PROP_DAMAGE, and the brick shatters (GameEvents.prop_broken);
## - with the player's zone aim on the grunt's head, the brick knocks down;
## - sprinting past a brick: Grab picks it up with no loss of speed;
## - a body in reach wins over a prop.
## Props are agent D's ThrowableProp.
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
	for sig: StringName in [&"prop_picked_up", &"prop_thrown", &"prop_broken"]:
		var s := sig
		GameEvents.connect(s, func(a = null, b = null, c = null) -> void:
			_events.append([s, a, b, c]))
	GrabTestUtil.make_floor(self)
	await get_tree().physics_frame
	await _brick(false)
	await _brick(true)
	await _sprint_pickup()
	await _sprint_reach()
	await _body_first()
	_finish()

func _count(sig: StringName) -> int:
	return _events.filter(func(ev: Array) -> bool: return ev[0] == sig).size()

func _spawn_prop(kind: StringName, pos: Vector3) -> ThrowableProp:
	var p := ThrowableProp.spawn(self, kind, Transform3D(Basis(), pos))
	return p

func _brick(head: bool) -> void:
	GrabTestUtil.reset_world()
	_hits.clear()
	_events.clear()
	var p := GrabTestUtil.spawn(self, &"player", Vector3.ZERO, Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var g := GrabTestUtil.spawn(self, &"grunt", Vector3(0.0, 0.0, -5.0), Vector3.BACK)
	var brick := _spawn_prop(&"brick", Vector3(0.35, 0.05, -0.7))
	await GrabTestUtil.wait(self, 0.4)
	GrabTestUtil.press(p, CombatController.Action.GRAB)
	GrabTestUtil.release(p, CombatController.Action.GRAB)
	await GrabTestUtil.frames(self, 3)
	var picked := p.carry.is_holding_prop() and p.carry.held == brick and _count(&"prop_picked_up") == 1
	await GrabTestUtil.wait(self, 0.2)
	var in_hand := brick.global_position.distance_to(p.rig.get_bone_global_position(Bones.R_HAND))
	if head:
		# The player's zone aim on the grunt's head (ZoneAim rewrites these every
		# tick from the camera, so set them on the frame of the press).
		p.aim_target = g
		p.aim_zone = BodyZones.Zone.HEAD
		p.aim_bone = Bones.HEAD
	await GrabTestUtil.tap(self, p, CombatController.Action.HEAVY, 0.05)
	var v := p.carry.last_throw_velocity
	await GrabTestUtil.wait_until(self, func() -> bool: return _count(&"prop_broken") > 0, 1.5)
	await GrabTestUtil.frames(self, 2)
	var hit := _hits.filter(func(h: HitInfo) -> bool: return h.victim == g and String(h.move_id).begins_with("prop_"))
	var h: HitInfo = hit[0] if hit.size() > 0 else null
	var label := "brick at the head" if head else "brick"
	print("[%s] picked up=%s (%.2f m from the hand), thrown at %.1f m/s: hit %s on %s for %.0f dmg, grunt %s, shattered=%s" % [
		label, picked, in_hand, v.length(), HitInfo.tier_name(h.tier) if h else &"-", h.hit_bone if h else &"-",
		h.damage if h else 0.0, GrabTestUtil.state_name(g), _count(&"prop_broken") > 0])
	_check(picked and in_hand < 0.3, "%s: Grab picks it up into the hand" % label)
	_check(_count(&"prop_thrown") == 1 and v.length() > 10.0, "%s: Heavy throws it" % label)
	var want := HitInfo.Tier.KNOCKDOWN if head else HitInfo.Tier.STAGGER
	_check(h != null and h.tier == want and is_equal_approx(h.damage, Tuning.PROP_DAMAGE),
		"%s: %s for %.0f damage" % [label, HitInfo.tier_name(want), Tuning.PROP_DAMAGE])
	_check(_count(&"prop_broken") == 1 and (not is_instance_valid(brick) or brick.is_broken()), "%s: it shatters" % label)
	p.aim_target = null
	for n in [p, g, brick]:
		if is_instance_valid(n):
			n.queue_free()
	await GrabTestUtil.frames(self, 4)

func _sprint_pickup() -> void:
	GrabTestUtil.reset_world()
	_events.clear()
	var p := GrabTestUtil.spawn(self, &"player", Vector3(20.0, 0.0, 8.0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var brick := _spawn_prop(&"brick", Vector3(20.6, 0.05, -4.0))
	await GrabTestUtil.wait(self, 0.3)
	if p.traversal == null:
		print("[sprint] SKIP: no Traversal")
		p.queue_free()
		brick.queue_free()
		return
	p.move_input = Vector3.FORWARD
	p.face_dir = Vector3.FORWARD
	GrabTestUtil.press(p, CombatController.Action.DASH)
	await GrabTestUtil.wait_until(self, func() -> bool: return p.global_position.z - brick.global_position.z < 1.3, 3.0)
	var v0 := p.traversal.get_speed()
	GrabTestUtil.press(p, CombatController.Action.GRAB)
	GrabTestUtil.release(p, CombatController.Action.GRAB)
	await GrabTestUtil.wait(self, 0.3)
	var v1 := p.traversal.get_speed()
	var picked := p.carry.is_holding_prop()
	GrabTestUtil.release(p, CombatController.Action.DASH)
	p.move_input = Vector3.ZERO
	print("[sprint] picked up a brick at %.2f m/s: holding=%s, speed 0.3 s later %.2f m/s (%.0f%%)" % [v0, picked, v1,
		100.0 * v1 / maxf(v0, 0.01)])
	_check(picked, "a prop is picked up while sprinting")
	_check(v1 >= v0 * 0.95, "with no slowdown")
	p.carry.drop(&"release")
	for n in [p, brick]:
		if is_instance_valid(n):
			n.queue_free()
	await GrabTestUtil.frames(self, 4)

## Props are taken within Tuning.GRAB_RANGE (1.4 m) even at a sprint (bodies
## get the 2.0 m sprint reach, props do not): a brick 1.75 m to the side is
## not picked up.
func _sprint_reach() -> void:
	GrabTestUtil.reset_world()
	_events.clear()
	var p := GrabTestUtil.spawn(self, &"player", Vector3(-30.0, 0.0, 8.0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var brick := _spawn_prop(&"brick", Vector3(-30.0 + 1.75, 0.05, -4.0))
	await GrabTestUtil.wait(self, 0.3)
	if p.traversal == null:
		p.queue_free()
		brick.queue_free()
		return
	p.move_input = Vector3.FORWARD
	p.face_dir = Vector3.FORWARD
	GrabTestUtil.press(p, CombatController.Action.DASH)
	await GrabTestUtil.wait_until(self, func() -> bool: return p.global_position.z - brick.global_position.z < 0.1, 3.0)
	var d := Vector2(p.global_position.x - brick.global_position.x, p.global_position.z - brick.global_position.z).length()
	var sprinting := p.traversal.is_sprinting()
	GrabTestUtil.press(p, CombatController.Action.GRAB)
	GrabTestUtil.release(p, CombatController.Action.GRAB)
	await GrabTestUtil.wait(self, 0.3)
	GrabTestUtil.release(p, CombatController.Action.DASH)
	p.move_input = Vector3.ZERO
	print("[sprint reach] brick %.2f m away at a sprint (%s): picked up=%s" % [d, sprinting, p.carry.is_holding_prop()])
	_check(sprinting and d > Tuning.GRAB_RANGE and d < Tuning.GRAB_SPRINT_REACH and not p.carry.is_holding_prop(),
		"a prop beyond GRAB_RANGE is not taken, even at a sprint")
	if p.carry.is_holding_prop():
		p.carry.drop(&"release")
	for n in [p, brick]:
		if is_instance_valid(n):
			n.queue_free()
	await GrabTestUtil.frames(self, 4)

func _body_first() -> void:
	GrabTestUtil.reset_world()
	var p := GrabTestUtil.spawn(self, &"player", Vector3(-20.0, 0.0, 0.0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var g := GrabTestUtil.spawn(self, &"grunt", Vector3(-20.0, 0.0, -1.1), Vector3.BACK)
	var brick := _spawn_prop(&"brick", Vector3(-19.7, 0.05, -0.6))
	await GrabTestUtil.wait(self, 0.3)
	g.stagger(Vector3.BACK, 0.4)
	await GrabTestUtil.frames(self, 2)
	GrabTestUtil.press(p, CombatController.Action.GRAB)
	GrabTestUtil.release(p, CombatController.Action.GRAB)
	await GrabTestUtil.wait(self, 0.3)
	print("[priority] body and brick in reach: holding body=%s prop=%s" % [p.carry.is_holding_body(), p.carry.is_holding_prop()])
	_check(p.carry.is_holding_body() and not p.carry.is_holding_prop(), "a body in reach wins over a prop")
	p.carry.drop(&"release")
	for n in [p, g, brick]:
		if is_instance_valid(n):
			n.queue_free()
	await GrabTestUtil.frames(self, 4)

func _check(ok: bool, what: String) -> void:
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		_fail.append(what)

func _finish() -> void:
	Carry.force_enabled = false
	if _fail.is_empty():
		print("PASS test_prop_throw")
		get_tree().quit(0)
	else:
		print("FAIL test_prop_throw: ", _fail)
		get_tree().quit(1)
