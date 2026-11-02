extends "res://tests/move/move_test_base.gd"
## Moving while holding a body (Feel Reference: Holding; with G's real Carry):
## walk at Tuning.HOLD_WALK_MULT (70%), sprint up to Tuning.HOLD_SPRINT_MULT of
## the cap (80%), vault height limited to Tuning.VAULT_MAX_HOLDING (1.0 m): a
## 0.9 m wall still vaults, a 1.1 m crate is a wall. Measured numbers printed.

func _init() -> void:
	_timeout = 600.0

func run() -> void:
	make_wall_across(-6.0, 0.9, 0.3, 4.0, 20.0)     # 0.9 m wall at z -6 in lane x 20
	make_box(Vector3(40.0, 0.55, -6.55), Vector3(1.1, 1.1, 1.1), "Crate")  # 1.1 m crate in lane x 40
	var p := spawn_player(Vector3(0.0, 0.0, 10.0))
	await ticks(30)
	if p.carry == null or not p.carry.is_enabled():
		check(false, "G's Carry is enabled")
		done()
		return
	var g := await _grab(p, Vector3(0.0, 0.02, 10.0))
	if g == null:
		done()
		return
	# Walking with a body: 70%.
	p.move_input = Vector3.FORWARD
	await ticks(60)
	var walk := hspeed(p)
	print("  walking with a body: %.2f m/s (70%% of %.1f = %.2f), holding %s" % [walk, Tuning.WALK_SPEED,
		Tuning.WALK_SPEED * Tuning.HOLD_WALK_MULT, p.carry.is_holding()])
	check(p.carry.is_holding() and near(walk, Tuning.WALK_SPEED * Tuning.HOLD_WALK_MULT, 0.05),
		"walking while holding a body runs at 70%% (%.2f m/s)" % walk)
	# Sprinting with a body: capped at 80% of the cap.
	dash_down(p)
	var top_v := 0.0
	for i in 170:
		await get_tree().physics_frame
		top_v = maxf(top_v, p.traversal.speed_toward(p.velocity))
	var cap := Tuning.debug_speed_cap * Tuning.HOLD_SPRINT_MULT
	print("  sprinting with a body: top earned speed %.2f m/s, get_speed_cap %.2f (80%% of %.1f = %.2f), holding %s" % [
		top_v, p.traversal.get_speed_cap(), Tuning.debug_speed_cap, cap, p.carry.is_holding()])
	check(near(p.traversal.get_speed_cap(), cap, 0.01) and top_v <= cap + 0.05 and top_v >= cap - 0.3,
		"sprinting while holding a body tops out at 80%% of the cap (%.2f)" % top_v)
	dash_up(p)
	await _drop(p, g)
	# Jumping with a body (its own grab: a hold lasts 2.5 s): full height.
	g = await _grab(p, Vector3(0.0, 0.02, 30.0))
	if g != null:
		# Past the clinch (Carry's speed multiplier is 0 until the hold settles).
		await wait_until(func() -> bool: return p.carry.get_move_speed_mult() > 0.0, 120)
		await ticks(5)
		var y0 := p.global_position.y
		var top := y0
		var jumped := p.traversal.on_jump_pressed()
		await ticks(1)
		while p.traversal.is_airborne():
			top = maxf(top, p.global_position.y)
			await get_tree().physics_frame
		print("  jumping with a body: rose %.3f m (holding %s)" % [top - y0, p.carry.is_holding()])
		check(jumped and near(top - y0, Tuning.JUMP_HEIGHT, 0.03) and p.carry.is_holding(),
			"holding a body jumps at full height (%.2f m) and keeps it" % (top - y0))
	await _drop(p, g)
	# Vault limit: the 0.9 m wall vaults, the 1.1 m crate does not.
	g = await _grab(p, Vector3(20.0, 0.02, 0.0))
	if g != null:
		clear_events()
		p.move_input = Vector3.FORWARD
		dash_down(p)
		await wait_until(func() -> bool: return p.traversal.is_vaulting() or p.global_position.z < -7.0, 240)
		var kind := p.traversal.get_parkour_kind()
		await wait_until(func() -> bool: return not p.traversal.is_vaulting(), 120)
		print("  holding a body into the 0.9 m wall: %s, z %.2f" % [kind, p.global_position.z])
		check(kind == &"vault", "holding a body, a 0.9 m wall still vaults (limit 1.0 m)")
		dash_up(p)
		await _drop(p, g)
	await _slam(p)
	await _sprint_throw_charge(p)
	g = await _grab(p, Vector3(40.0, 0.02, 0.0))
	if g != null:
		clear_events()
		p.move_input = Vector3.FORWARD
		dash_down(p)
		await ticks(130)
		var z := p.global_position.z
		print("  holding a body into the 1.1 m crate: parkour events %d, stopped at z %.2f (crate face -6.0)" % [
			count_events(&"parkour"), z])
		check(count_events(&"parkour") == 0 and z > -6.0, "holding a body, a 1.1 m crate is a wall (limit 1.0 m)")
		dash_up(p)
		await _drop(p, g)
	done()

## G's body slam from a normal jump (1.2 m, far under the 2 m slam height):
## any slam lands heavy, with this module's one shockwave.
func _slam(p: Fighter) -> void:
	var g := await _grab(p, Vector3(60.0, 0.02, 0.0))
	if g == null:
		return
	var watcher := spawn_enemy(&"grunt", Vector3(61.8, 0.0, -0.5), Vector3.LEFT)
	await ticks(5)
	clear_events()
	p.traversal.on_jump_pressed()
	await wait_until(func() -> bool: return p.velocity.y < 1.0, 60)
	p.combat.press(CombatController.Action.LIGHT)
	await ticks(2)
	p.combat.release(CombatController.Action.LIGHT)
	var slamming := p.carry.has_method(&"is_slamming") and bool(p.carry.call(&"is_slamming"))
	await wait_until(func() -> bool: return count_events(&"landing") > 0, 240)
	await ticks(3)
	var land := last_event(&"landing")
	var mine := 0
	for e in events_of(&"shockwave"):
		if e[0] == p:
			mine += 1
	print("  body slam from a 1.2 m jump: carry slamming %s, lands %s at %.2f m/s, shockwaves %d" % [
		slamming, land[1] if not land.is_empty() else &"-", float(land[3]) if not land.is_empty() else 0.0, mine])
	check(slamming and not land.is_empty() and land[1] == &"heavy", "any body slam lands heavy, whatever the height")
	check(mine == 1, "one shockwave on the slam landing")
	await ticks(60)
	if p.carry.is_holding():
		p.carry.drop(&"release")
	await ticks(20)
	for f in [g, watcher]:
		if is_instance_valid(f):
			f.queue_free()
	await settle(p, 60)

## Charging a throw at a sprint while holding a body: the speed is kept but
## never above the carry sprint cap (80% of the cap).
func _sprint_throw_charge(p: Fighter) -> void:
	var g := await _grab(p, Vector3(80.0, 0.02, 20.0))
	if g == null:
		return
	p.move_input = Vector3.FORWARD
	dash_down(p)
	await ticks(170)
	var v0 := hspeed(p)
	p.combat.press(CombatController.Action.HEAVY)
	var charging := await wait_until(func() -> bool:
		return p.carry.has_method(&"is_charging") and bool(p.carry.call(&"is_charging")), 60)
	var hi := 0.0
	var lo := INF
	for i in 60:
		await get_tree().physics_frame
		hi = maxf(hi, hspeed(p))
		lo = minf(lo, hspeed(p))
	var cap := p.traversal.get_speed_cap()
	print("  charging a throw at a sprint with a body: charging %s, steering %s, speed %.2f..%.2f (before %.2f, carry cap %.2f)" % [
		charging, p.traversal.is_charge_steering(), lo, hi, v0, cap])
	check(charging and hi <= cap + 0.05 and lo >= v0 * 0.95 - 0.05,
		"a sprinting throw charge keeps its speed within the carry cap (%.2f..%.2f, cap %.2f)" % [lo, hi, cap])
	p.combat.release(CombatController.Action.HEAVY)
	dash_up(p)
	await ticks(60)
	if p.carry.is_holding():
		p.carry.drop(&"release")
	await ticks(20)
	if is_instance_valid(g):
		g.queue_free()
	await settle(p, 60)

## A grunt 1 m ahead, grabbed with G's Grab. Returns it once held (null on failure).
func _grab(p: Fighter, at: Vector3) -> Fighter:
	await settle(p, 10)
	p.global_position = at
	p.snap_facing(Vector3.FORWARD)
	var g := spawn_enemy(&"grunt", at + Vector3(0.0, 0.0, -1.0), Vector3.BACK)
	await ticks(20)
	p.combat.press(CombatController.Action.GRAB)
	await ticks(2)
	p.combat.release(CombatController.Action.GRAB)
	var held := await wait_until(func() -> bool:
		return p.carry.has_method(&"is_holding_body") and bool(p.carry.call(&"is_holding_body")), 120)
	print("  grab: holding a body %s (%s)" % [held, p.carry.get_debug_text()])
	check(held, "G's grab holds the grunt")
	if not held:
		g.queue_free()
		return null
	return g

func _drop(p: Fighter, g: Fighter) -> void:
	p.move_input = Vector3.ZERO
	p.carry.drop(&"release")
	await ticks(30)
	if is_instance_valid(g):
		g.queue_free()
	await settle(p, 20)
