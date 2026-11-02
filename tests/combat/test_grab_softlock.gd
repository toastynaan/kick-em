extends "res://tests/combat/combat_test_base.gd"
## Grab soft-locks (Round 3 fix, Round 5 path): a body the player holds (Carry)
## must never stay "held" when the holder is knocked down, flinched or killed
## mid-hold by a real enemy hit through CombatController's hit pipeline.
## Real player + PlayerController and real Input actions; the victim must be
## free at once, walk when told and start an attack once it is on its feet.

var _x := 0.0

func _init() -> void:
	_timeout = 120.0

func _release_input() -> void:
	for a in InputMap.get_actions():
		if not String(a).begins_with("ui_"):
			Input.action_release(a)

func _held(v: Fighter) -> bool:
	return v.carry != null and v.carry.is_held()

## Player at the lane origin facing -Z, the victim grunt 1 m ahead, plus an
## attacker grunt at the player's side. The player grabs the victim (Carry).
func _setup() -> Array:
	_x += 14.0
	var p := FighterFactory.spawn_player(self, Transform3D(Basis(), Vector3(_x, 0, 0)))
	var v := spawn(&"grunt", Vector3(_x, 0, -1.0), Vector3.BACK)
	var att := spawn(&"grunt", Vector3(_x - 1.1, 0, 0.2), Vector3.RIGHT)
	await ticks(40)
	Input.action_press(&"grab")
	await ticks(2)
	Input.action_release(&"grab")
	var ok := await wait_until(func() -> bool: return p.carry.is_holding() and _held(v), 1.5)
	check(ok, "the player holds the grunt (Carry)")
	await ticks(20)
	return [p, v, att]

## After the holder lost the hold: the victim is free at once, walks and
## attacks once it is on its feet.
func _victim_free(v: Fighter, label: String) -> void:
	await ticks(2)
	check(not _held(v), "%s: victim no longer held" % label)
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
	print("  %s: on its feet %.2f s after the holder lost the hold" % [label, up])
	check(moved > 0.2, "%s: victim walks when told (%.2f m)" % [label, moved])
	check(attacked, "%s: victim can start_enemy_attack within 0.5 s of standing" % label)
	check(up < 4.0, "%s: back on its feet within 4 s (%.2f)" % [label, up])

func run() -> void:
	# Round 5: enemies never launch the player; the heavy's charge knocks it down.
	print("holder knocked down by a real enemy hit mid-hold")
	var s: Array = await _setup()
	var p: Fighter = s[0]
	var v: Fighter = s[1]
	var att: Fighter = s[2]
	att.snap_facing(p.global_position - att.global_position)
	att.combat.start_enemy_attack(&"e_charge", 0.3)
	var ok := await wait_until(func() -> bool: return p.is_down(), 2.5)
	check(ok, "holder knocked down")
	check(not p.carry.is_holding(), "the hit dropped the body")
	_release_input()
	await _victim_free(v, "knocked down")
	await wait_real(1.0)

	print("holder flinched mid-hold")
	s = await _setup()
	p = s[0]
	v = s[1]
	att = s[2]
	att.snap_facing(p.global_position - att.global_position)
	att.combat.start_enemy_attack(&"e_hook", 0.3)
	ok = await wait_until(func() -> bool: return p.combat.last_result == HitInfo.Result.HIT, 2.0)
	check(ok, "holder hit by the hook")
	check(not p.carry.is_holding(), "the hit dropped the body")
	_release_input()
	await _victim_free(v, "flinched")
	await wait_real(1.0)

	print("holder dies mid-hold")
	s = await _setup()
	p = s[0]
	v = s[1]
	att = s[2]
	p.hp = 5.0
	att.snap_facing(p.global_position - att.global_position)
	att.combat.start_enemy_attack(&"e_hook", 0.3)
	ok = await wait_until(func() -> bool: return p.is_dead(), 2.0)
	check(ok, "holder died")
	_release_input()
	await _victim_free(v, "holder dead")
	done()
