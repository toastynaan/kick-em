extends "res://tests/combat/combat_test_base.gd"
## Round 3 fix: a limb-grab victim must never stay "held" when the grabber is
## launched, flinched or killed mid-grab. Real player + PlayerController,
## real Input actions (zone aim on the victim's arm), real enemy hits.

var _x := 0.0
var _pc: PlayerController
var _aim_target: Fighter

func _init() -> void:
	_timeout = 120.0

func _physics_process(_d: float) -> void:
	# Aim the player's zone ray at the victim's left forearm (as a mouse would).
	if _pc != null and is_instance_valid(_pc) and _aim_target != null and is_instance_valid(_aim_target):
		var o := _pc.fighter.global_position + Vector3(0, 2.2, 2.5)
		var arm := (_aim_target.rig.get_bone_global_position(&"LeftLowerArm")
			+ _aim_target.rig.get_bone_global_position(&"LeftHand")) * 0.5
		_pc.zone_aim.ray_override = [o, (arm - o).normalized()]

func _release_input() -> void:
	for a in InputMap.get_actions():
		if not String(a).begins_with("ui_"):
			Input.action_release(a)

## Player at the lane origin facing -Z, the victim grunt 1 m ahead, plus an
## attacker grunt at the player's side.
func _setup() -> Array:
	_x += 14.0
	var p := FighterFactory.spawn_player(self, Transform3D(Basis(), Vector3(_x, 0, 0)))
	var v := spawn(&"grunt", Vector3(_x, 0, -1.0), Vector3.BACK)
	var att := spawn(&"grunt", Vector3(_x - 1.1, 0, 0.2), Vector3.RIGHT)
	await ticks(30)
	_pc = p.get_node("PlayerController")
	_aim_target = v
	await ticks(12)
	Input.action_press(&"grab")
	var ok := await wait_until(func() -> bool: return v.combat.held_by == p, 1.0)
	check(ok, "grab on the arm connected (%s)" % ("LimbGrab" if p.combat._limb_grab != null else "socket"))
	await ticks(30)
	return [p, v, att]

## After the grabber lost the grab: held_by clears at once; the victim walks
## and attacks once it is on its feet.
func _victim_free(v: Fighter, label: String) -> void:
	await ticks(1)
	check(v.combat.held_by == null, "%s: victim no longer held (next tick)" % label)
	check(LimbGrab.get_grip_on(v) == null, "%s: no limb grip left on the victim" % label)
	var t0 := TimeDirector.now()
	await wait_until(func() -> bool: return v.get_state() == RagdollController.State.ANIMATED and v.can_act(), 6.0)
	var up := TimeDirector.now() - t0
	var t1 := TimeDirector.now()
	var p0 := v.global_position
	v.move_input = Vector3.RIGHT
	await wait_real(0.25)
	v.move_input = Vector3.ZERO
	var moved := v.global_position.distance_to(p0)
	var attacked := false
	while TimeDirector.now() - t1 < 0.5 and not attacked:
		attacked = v.combat.start_enemy_attack(&"e_hook", 0.35)
		if not attacked:
			await get_tree().physics_frame
	print("  %s: on its feet %.2f s after the grabber lost the grab" % [label, up])
	check(moved > 0.2, "%s: victim walks when told (%.2f m)" % [label, moved])
	check(attacked, "%s: victim can start_enemy_attack within 0.5 s of standing" % label)
	check(up < 4.0, "%s: back on its feet within 4 s (%.2f)" % [label, up])

func run() -> void:
	print("grabber launched by a real enemy hit mid-grab")
	var s: Array = await _setup()
	var p: Fighter = s[0]
	var v: Fighter = s[1]
	var att: Fighter = s[2]
	att.snap_facing(p.global_position - att.global_position)
	att.combat.start_enemy_attack(&"e_kick", 0.3)
	var ok := await wait_until(func() -> bool: return p.is_launched(), 2.0)
	check(ok, "grabber launched")
	_release_input()
	await _victim_free(v, "launched")
	await wait_real(1.0)

	print("grabber flinched mid-drag")
	s = await _setup()
	p = s[0]
	v = s[1]
	att = s[2]
	att.snap_facing(p.global_position - att.global_position)
	att.combat.start_enemy_attack(&"e_hook", 0.3)
	ok = await wait_until(func() -> bool: return p.combat.last_result == HitInfo.Result.HIT, 2.0)
	check(ok, "grabber hit by the hook")
	check(LimbGrab.get_grip_by(p) == null and p.combat._limb_grab == null, "the swing stopped at once")
	_release_input()
	await _victim_free(v, "flinched")
	await wait_real(1.0)

	print("grabber dies mid-grab")
	s = await _setup()
	p = s[0]
	v = s[1]
	att = s[2]
	p.hp = 5.0
	att.snap_facing(p.global_position - att.global_position)
	att.combat.start_enemy_attack(&"e_hook", 0.3)
	ok = await wait_until(func() -> bool: return p.is_dead(), 2.0)
	check(ok, "grabber died")
	_release_input()
	await _victim_free(v, "grabber dead")
	done()
