extends "res://tests/input/input_test_base.gd"
## Round 8 air combo hangs (agent H, docs/Round 8 — Charge and Pressure.md: Air combo):
## - Fighter.air_hang(Tuning.R8_AIR_HANG) on a body lifted 2.5 m (a full
##   charged uppercut) holds it still, no fall and no drift, for 0.35 s
##   (+-1 tick), 4 times in a row; each hang comes with B's floating re-pop,
##   past Tuning.R7_JUGGLE_MAX, and the body is never knocked down during the
##   air combo; after each hang the arc goes on, and after the last the body
##   falls and lands into a knockdown. Its velocity reads zero while it hangs
##   (Traversal's launcher jump reads it).
## - air_hang does nothing to a body that is not lifted.
## - The player's hang (Fighter.hang) begun during an attack (B's landed air
##   strike): he holds still in the air for R8_AIR_HANG while the strike runs
##   and a second strike starts, then falls and lands.
## Prints every measured number.

const TICK := 1.0 / 120.0

func run() -> void:
	_timeout = 120.0
	var atk := spawn_dummy(&"grunt", Vector3(0, 0, 30), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var v := spawn_dummy(&"grunt", Vector3.ZERO, Vector3.BACK)
	await ticks(40)
	await _body_suite(v, atk)
	await _player_suite()
	done()

func _body_suite(v: Fighter, atk: Fighter) -> void:
	var hang := Tuning.R8_AIR_HANG
	var lift: float = (Tuning.R8_MOVES[&"uppercut"]["charged"]["lift"] as Vector2).y
	# Not lifted: no effect.
	v.air_hang(hang)
	await ticks(1)
	check(v.get_air_hang_left() == 0.0 and v.get_react_state() == &"", "air_hang on a standing body does nothing")
	var y_floor := v.global_position.y
	v.react(&"lift", Vector3.FORWARD, 1.0, 0.0, _info(v, atk, &"heavy_uppercut", &"lift", 1.0, 0.0, lift))
	await ticks(1)
	check(v.global_position.y > y_floor + 0.01, "a later lift starts rising at once (no stale hang)")
	await wait_until(func() -> bool: return v.velocity.y <= 0.0, 240)
	var peak := v.global_position.y - y_floor
	var holds: Array[float] = []
	var still := true
	var vel_zero := true
	for k in 4:
		v.air_hang(hang)
		v.react(&"repop", Vector3.FORWARD, 0.2, 0.0, _info(v, atk, &"jab", &"repop", 0.2, 0.0, 0.0))  # B's floating punch
		var p0 := v.global_position
		var n := 0
		for i in 120:
			await get_tree().physics_frame
			if (v.global_position - p0).length() > 1e-5:
				break
			n += 1
			vel_zero = vel_zero and v.velocity.length() < 1e-4
		holds.append(n * TICK)
		still = still and v.is_lifted()
		await ticks(4)  # the next air strike's startup
	var repops := v.get_repops()
	var lifted := v.is_lifted()
	var top := [0.0]  # lambdas capture locals by value: an array carries the peak out
	var landed := await wait_until(func() -> bool:
		top[0] = maxf(top[0], v.global_position.y - y_floor)
		return not v.is_lifted(), 600)
	await ticks(2)
	var down := v.is_down() and v.get_react_state() == &"down"
	print("  lift %.1f m: peak %.3f m; 4 hangs held %s s (want %.2f), re-pops %d (cap %d), still lifted %s, then up to %.2f m, landed down %s"
		% [lift, peak, holds.map(func(x: float) -> String: return "%.3f" % x), hang, repops, Tuning.R7_JUGGLE_MAX, lifted, top[0], down])
	for k in 4:
		check(absf(holds[k] - hang) <= TICK + 1e-4, "hang %d holds the body %.3f s (want %.2f)" % [k + 1, holds[k], hang])
	check(still and lifted and repops == 4, "4 re-pops past the cap of %d during the air combo: never knocked down" % Tuning.R7_JUGGLE_MAX)
	check(vel_zero, "the hanging body's velocity reads zero")
	check(landed and down, "after the last hang the body falls and lands into a knockdown")
	await _recover(v)

	# The drift stops while it hangs and goes on after.
	v.clear_react()
	v.teleport_to(Vector3(6, 0, 0), Vector3.BACK)
	await ticks(15)
	v.react(&"lift", Vector3.FORWARD, 2.0, 0.0, _info(v, atk, &"heavy_uppercut", &"lift", 2.0, 0.0, lift))
	await ticks(20)
	var x0 := v.global_position
	v.air_hang(hang)
	await ticks(20)
	var held := (v.global_position - x0).length()
	await ticks(40)
	var moved := Vector2(v.global_position.x - x0.x, v.global_position.z - x0.z).length()
	print("  drift during a hang %.4f m, after it %.3f m" % [held, moved])
	check(held < 1e-4 and moved > 0.1, "the drift holds during the hang and goes on after")
	await wait_until(func() -> bool: return not v.is_lifted(), 600)
	await _recover(v)

func _player_suite() -> void:
	var hang := Tuning.R8_AIR_HANG
	var p := spawn_player(Vector3(12, 0, 0))
	await ticks(40)
	var starts: Array[float] = []
	p.combat.attack_started.connect(func(_id: StringName) -> void: starts.append(TimeDirector.now()))
	var y_floor := p.global_position.y
	_space(true)
	await ticks(1)
	_space(false)
	await wait_until(func() -> bool: return p.is_airborne() and p.velocity.y <= 1.0, 240)
	var struck := p.combat.play_move(&"jab")  # what B's landed air strike would be running
	var attacking := p.combat.is_attacking()
	var t0 := TimeDirector.now()
	p.hang(hang)
	var y0 := p.global_position.y
	var n := 0
	var second := false
	for i in 120:
		await get_tree().physics_frame
		if absf(p.global_position.y - y0) > 1e-5:
			break
		n += 1
		if i == 18:
			p.combat.cancel()  # the next air strike starts while he still hangs
			press(&"punch")
		if i == 19:
			release(&"punch")
		if i > 19:
			second = second or p.combat.is_attacking()
	var held := n * TICK
	var fell := await wait_until(func() -> bool: return p.global_position.y < y0 - 0.1, 120)
	var landed := await wait_until(func() -> bool: return not p.is_airborne() and absf(p.global_position.y - y_floor) < 0.02, 240)
	var strikes_in_hang := starts.filter(func(t: float) -> bool: return t >= t0 and t < t0 + held).size()
	print("  player: hang at %.2f m during a strike (%s, attacking %s) held %.3f s (want %.2f), second strike in the hang %s (%d starts), fell %s, landed %s"
		% [y0 - y_floor, struck, attacking, held, hang, second, strikes_in_hang, fell, landed])
	check(struck and attacking, "the player is mid-strike in the air when the hang starts")
	check(absf(held - hang) <= TICK * 2.0 + 1e-4, "the player holds still in the air %.3f s (want %.2f)" % [held, hang])
	check(second and strikes_in_hang >= 1, "a second strike starts while he hangs, and the hang goes on")
	check(fell and landed, "then he falls and lands")
	p.queue_free()
	await ticks(5)

func _info(v: Fighter, atk: Fighter, move_id: StringName, kind: StringName, push: float, stun: float, lift: float) -> HitInfo:
	var info := HitInfo.new()
	info.attacker = atk
	info.victim = v
	info.move_id = move_id
	info.kind = &"strike"
	info.react = kind
	info.push = push
	info.stun = stun
	info.lift_height = lift
	info.hit_bone = Bones.CHEST
	info.hit_direction = Vector3.FORWARD
	info.hit_position = v.get_aim_point()
	info.air = true
	return info

func _recover(v: Fighter) -> void:
	if v.ragdoll.is_simulating() or v.get_state() != RagdollController.State.ANIMATED:
		v.ragdoll.force_recover()
	v.combat.cancel()
	await ticks(3)

## The Space key (Controls binds it to `jump` by physical keycode).
func _space(down: bool) -> void:
	var e := InputEventKey.new()
	e.keycode = KEY_SPACE
	e.physical_keycode = KEY_SPACE
	e.pressed = down
	Input.parse_input_event(e)
