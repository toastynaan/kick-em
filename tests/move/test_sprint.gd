extends "res://tests/move/move_test_base.gd"
## F2 sprint that builds (Feel Reference: Movement spec > Sprint that builds;
## Charging is the risk; Sprint strikes). Checks, with measured numbers:
## - holding Dash in a straight line reaches the cap in 1.2 +- 0.1 s
##   (sprint_charge and the settled speed), never under 6 m/s after 150 ms;
## - a Dash tap is a 3 m short dash; releasing bleeds to walk over 0.25 s;
## - a 90-degree turn inside 0.2 s at full speed drops speed 30%; a gentle
##   curve costs nothing;
## - charging during a sprint keeps speed within 5% and turns <= 30 deg/s;
## - any sprint strike, hit or miss, leaves the player at walking speed;
## - footsteps carry the floor surface and sprint_charge.

func run() -> void:
	var p := spawn_player(Vector3(0.0, 0.0, 60.0))
	await ticks(30)
	check(p.traversal != null, "the player has a Traversal")
	await _cap_time(p)
	await _short_dash(p)
	await _release_bleed(p)
	await _turn_penalty(p)
	await _gentle_curve(p)
	await _charge_at_sprint(p)
	await _sprint_strike_miss(p)
	await _sprint_strike_hit(p)
	await _charge_hit_stumble(p)
	await _upgraded_caps(p)
	await _focus_sprint(p)
	await _footsteps(p)
	done()

func _cap_time(p: Fighter) -> void:
	clear_events()
	var cap := p.traversal.get_speed_cap()
	var t0 := TimeDirector.now()
	p.move_input = Vector3.FORWARD
	dash_down(p)
	var t_charge := -1.0
	var t_settle := -1.0
	var t_98 := -1.0
	var below := true
	var below98 := true
	var min_after := INF
	var peak := 0.0
	for i in 240:
		await get_tree().physics_frame
		var t := TimeDirector.now() - t0
		var v := hspeed(p)
		peak = maxf(peak, v)
		if t >= Tuning.DASH_HOLD_SPRINT + 1.0 / 120.0:
			min_after = minf(min_after, v)
		if t_charge < 0.0 and p.traversal.sprint_charge >= 0.999:
			t_charge = t
		# Last upward crossing (the short dash's opening burst runs above the cap).
		if v < cap * 0.99:
			below = true
		elif below:
			below = false
			t_settle = t
		if v < cap * Tuning.SPEED_CAP_SNAP:
			below98 = true
		elif below98:
			below98 = false
			t_98 = t
	print("  cap %.1f: 98%% (power counts the cap) at %.3f s, 99%% at %.3f s, sprint_charge 1 at %.3f s; burst peak %.2f, min after 150 ms %.2f, speed at 2 s %.2f" % [
		cap, t_98, t_settle, t_charge, peak, min_after, hspeed(p)])
	check(near(t_98, Tuning.SPRINT_RAMP_TIME, 0.2), "98%% of the cap at %.3f s" % t_98)
	check(near(t_charge, Tuning.SPRINT_RAMP_TIME, 0.1), "sprint_charge reaches 1 in %.3f s (1.2 +- 0.1)" % t_charge)
	check(near(t_settle, Tuning.SPRINT_RAMP_TIME, 0.1), "speed reaches the cap (99%%) in %.3f s (1.2 +- 0.1)" % t_settle)
	check(min_after >= Tuning.SPRINT_START_SPEED - 0.05, "never under 6 m/s after the 150 ms hold (min %.2f)" % min_after)
	check(near(hspeed(p), cap, 0.05), "holds the cap %.2f m/s" % hspeed(p))
	check(p.traversal.is_sprinting() and count_events(&"sprint_started") == 1, "is_sprinting and one sprint_started")
	await settle(p, 40)

func _short_dash(p: Fighter) -> void:
	await settle(p, 30)
	var x0 := p.global_position
	dash_down(p)
	await ticks(2)
	dash_up(p)
	await wait_until(func() -> bool: return hspeed(p) < 0.05, 120)
	var d := Vector2(p.global_position.x - x0.x, p.global_position.z - x0.z).length()
	print("  short dash (tap, stick neutral): %.2f m" % d)
	check(d >= Tuning.SHORT_DASH_DIST - 0.05 and d <= Tuning.SHORT_DASH_DIST + 0.45,
		"a Dash tap covers %.2f m (short dash %.1f m, then the feet plant)" % [d, Tuning.SHORT_DASH_DIST])
	check(not p.traversal.is_sprinting(), "a tap does not sprint")

func _release_bleed(p: Fighter) -> void:
	await settle(p, 20)
	await sprint_to_cap(p, Vector3.FORWARD)
	await ticks(10)
	var v0 := hspeed(p)
	var t0 := TimeDirector.now()
	dash_up(p)
	await ticks(1)
	var v1 := hspeed(p)
	var t_walk := -1.0
	for i in 90:
		await get_tree().physics_frame
		if t_walk < 0.0 and hspeed(p) <= Tuning.WALK_SPEED + 0.01:
			t_walk = TimeDirector.now() - t0
	print("  release at %.2f m/s: %.2f after 1 tick, walking (%.1f) after %.3f s" % [v0, v1, Tuning.WALK_SPEED, t_walk])
	check(v1 > v0 - 0.5, "the release does not snap (%.2f -> %.2f in one tick)" % [v0, v1])
	check(near(t_walk, Tuning.SPRINT_RELEASE_TIME, 0.03), "bleeds to walking speed in %.3f s (0.25)" % t_walk)
	await settle(p, 30)

func _turn_penalty(p: Fighter) -> void:
	await settle(p, 20)
	p.global_position = Vector3(0.0, 0.0, 60.0)
	await sprint_to_cap(p, Vector3.FORWARD)
	await ticks(12)
	var before := hspeed(p)
	var n0 := p.traversal.turn_penalties
	var yaw0 := _yaw(p.velocity)
	p.move_input = Vector3.RIGHT  # a hard 90-degree cut
	var after := INF
	var t_turn := -1.0
	var t0 := TimeDirector.now()
	for i in 30:
		await get_tree().physics_frame
		after = minf(after, hspeed(p))
		if t_turn < 0.0 and absf(rad_to_deg(angle_difference(yaw0, _yaw(p.velocity)))) >= 89.0:
			t_turn = TimeDirector.now() - t0
	var drop := 1.0 - after / before
	print("  90-degree cut at %.2f m/s: turned in %.3f s, lowest speed %.2f (drop %.1f%%), penalties %d" % [
		before, t_turn, after, drop * 100.0, p.traversal.turn_penalties - n0])
	check(t_turn > 0.0 and t_turn <= Tuning.TURN_PENALTY_WINDOW, "the 90-degree turn takes %.3f s (inside 0.2 s)" % t_turn)
	check(near(drop, Tuning.TURN_PENALTY, 0.02), "a 90-degree turn inside 0.2 s loses %.1f%% (30%%)" % (drop * 100.0))
	check(p.traversal.turn_penalties - n0 == 1, "one turn penalty for one cut")
	await settle(p, 30)

func _gentle_curve(p: Fighter) -> void:
	await settle(p, 20)
	p.global_position = Vector3(0.0, 0.0, 60.0)
	await sprint_to_cap(p, Vector3.FORWARD)
	await ticks(10)
	var n0 := p.traversal.turn_penalties
	var before := hspeed(p)
	var lo := INF
	# Curve at 120 deg/s for 1.2 s (144 degrees in all, 24 per 0.2 s).
	for i in 144:
		var a := deg_to_rad(120.0 * i / 120.0)
		p.move_input = Vector3(-sin(-a), 0.0, -cos(-a))
		await get_tree().physics_frame
		lo = minf(lo, hspeed(p))
	print("  gentle curve 120 deg/s at %.2f m/s: lowest %.2f, penalties %d" % [before, lo, p.traversal.turn_penalties - n0])
	check(p.traversal.turn_penalties == n0 and lo >= before * 0.99, "a gentle curve costs nothing (lowest %.2f of %.2f)" % [lo, before])
	await settle(p, 30)

func _charge_at_sprint(p: Fighter) -> void:
	await settle(p, 20)
	p.global_position = Vector3(0.0, 0.0, 60.0)
	await sprint_to_cap(p, Vector3.FORWARD)
	await ticks(10)
	var v0 := hspeed(p)
	p.combat.force_hold_charge = true
	p.combat.press(CombatController.Action.KICK)
	var charging := await wait_until(func() -> bool: return p.combat.is_charging(), 60)
	check(charging, "holding Kick at a sprint charges")
	var lo := INF
	var hi := 0.0
	for i in 30:
		await get_tree().physics_frame
		lo = minf(lo, hspeed(p))
		hi = maxf(hi, hspeed(p))
	# Steer hard right for 0.5 s: the heading may turn at most 30 deg/s.
	var yaw0 := _yaw(p.velocity)
	p.move_input = Vector3.RIGHT
	var t0 := TimeDirector.now()
	for i in 60:
		await get_tree().physics_frame
		lo = minf(lo, hspeed(p))
		hi = maxf(hi, hspeed(p))
	var turned := absf(rad_to_deg(angle_difference(yaw0, _yaw(p.velocity))))
	var rate := turned / (TimeDirector.now() - t0)
	# Releasing Dash cannot stop a sprinting charge.
	dash_up(p)
	await ticks(20)
	var still := hspeed(p)
	print("  charge at %.2f m/s: speed %.2f..%.2f (%.1f%% band), steer %.1f deg/s, after Dash release %.2f, charge_steering %s" % [
		v0, lo, hi, (hi - lo) / v0 * 100.0, rate, still, p.traversal.is_charge_steering()])
	check(lo >= v0 * 0.95 and hi <= v0 * 1.05, "charging at a sprint keeps speed within 5%% (%.2f..%.2f of %.2f)" % [lo, hi, v0])
	check(rate <= Tuning.CHARGE_SPRINT_STEER + 1.0 and rate >= Tuning.CHARGE_SPRINT_STEER * 0.8,
		"steering while charging %.1f deg/s (<= 30)" % rate)
	check(still >= v0 * 0.95, "releasing Dash does not stop a sprinting charge (%.2f)" % still)
	p.combat.release(CombatController.Action.KICK)
	var r := await _strike_speeds(p)
	var after: float = r["end"]
	print("  charged kick released: speed at the end of the strike %.2f" % after)
	check(after <= Tuning.WALK_SPEED + 0.05, "the charged sprint strike drops to walking speed (%.2f)" % after)
	p.combat.force_hold_charge = false
	await settle(p, 30)

func _sprint_strike_miss(p: Fighter) -> void:
	await settle(p, 20)
	p.global_position = Vector3(0.0, 0.0, 60.0)
	await sprint_to_cap(p, Vector3.FORWARD)
	await ticks(10)
	var v0 := hspeed(p)
	p.combat.press(CombatController.Action.LIGHT)
	p.combat.release(CombatController.Action.LIGHT)
	var r := await _strike_speeds(p)
	print("  sprint jab (miss) at %.2f m/s: speed after the commit %.2f..%.2f, at the end of the strike %.2f, first free tick %.2f" % [
		v0, r["lo"], r["hi"], r["end"], r["free"]])
	check(r["seen"] and r["end"] <= Tuning.WALK_SPEED + 0.05,
		"a missed sprint strike leaves the player at walking speed (%.2f at its end)" % r["end"])
	check(r["free"] <= Tuning.SPRINT_START_SPEED + 0.05, "the next sprint builds from the start again (%.2f)" % r["free"])
	await settle(p, 30)

## Speeds through a strike: from its commit (the speed sample) to its end, and
## the first tick after it.
func _strike_speeds(p: Fighter) -> Dictionary:
	var seen := await wait_until(func() -> bool: return p.combat.is_attacking(), 10)
	var lo := INF
	var hi := 0.0
	var end := 0.0
	var lunge_ticks := 0
	while p.combat.is_attacking():
		await get_tree().physics_frame
		if p.combat.is_attacking():
			end = hspeed(p)
			if p.combat.has_forced_velocity():
				lunge_ticks += 1
			else:
				lo = minf(lo, end)
				hi = maxf(hi, end)
	return {"seen": seen, "lo": lo, "hi": hi, "end": end, "free": hspeed(p), "lunge": lunge_ticks}

func _sprint_strike_hit(p: Fighter) -> void:
	await settle(p, 20)
	p.global_position = Vector3(0.0, 0.0, 60.0)
	var g := spawn_enemy(&"grunt", Vector3(0.0, 0.0, 44.0))
	await ticks(5)
	p.move_input = Vector3.FORWARD
	dash_down(p)
	await wait_until(func() -> bool:
		return p.global_position.distance_to(g.global_position) <= 2.2, 360)
	var v0 := hspeed(p)
	clear_events()
	p.combat.press(CombatController.Action.LIGHT)
	p.combat.release(CombatController.Action.LIGHT)
	var r := await _strike_speeds(p)
	var at_end: float = r["end"]
	var hits := 0
	for e in events_of(&"hit_landed"):
		var info := e[0] as HitInfo
		if info != null and info.attacker == p:
			hits += 1
	print("  sprint jab (hit) at %.2f m/s: hits %d, speed at the end of the strike %.2f, rams %d" % [
		v0, hits, at_end, count_events(&"rammed")])
	check(hits >= 1, "the sprint jab hits the grunt")
	check(at_end <= Tuning.WALK_SPEED + 0.05, "a sprint strike that hits leaves the player at walking speed (%.2f)" % at_end)
	check(count_events(&"rammed") == 0, "a sprint attack never rams its target")
	await settle(p, 30)
	g.queue_free()
	await ticks(2)

func _footsteps(p: Fighter) -> void:
	await settle(p, 20)
	var plate := make_box(Vector3(0.0, -0.49, 30.0), Vector3(6.0, 1.0, 20.0), "MetalPlate")
	plate.set_meta(&"surface", &"metal")
	p.global_position = Vector3(0.0, 0.05, 38.0)
	await ticks(5)
	clear_events()
	p.move_input = Vector3.FORWARD
	dash_down(p)
	await ticks(120)
	var steps := events_of(&"footstep")
	var metal := 0
	var max_charge := 0.0
	for s in steps:
		if s[2] == &"metal":
			metal += 1
		max_charge = maxf(max_charge, float(s[3]))
	print("  footsteps over 1 s of sprint: %d (%d on metal), max sprint_charge %.2f" % [steps.size(), metal, max_charge])
	check(steps.size() >= 5, "footsteps while sprinting (%d in 1 s)" % steps.size())
	check(metal >= 3, "footsteps carry the surface (metal %d)" % metal)
	check(max_charge > 0.5, "footsteps carry sprint_charge (%.2f)" % max_charge)
	await settle(p, 20)

## A hit during a sprinting charge knocks the player out of it, and they stumble.
func _charge_hit_stumble(p: Fighter) -> void:
	await settle(p, 20)
	p.global_position = Vector3(0.0, 0.0, 60.0)
	await sprint_to_cap(p, Vector3.FORWARD)
	await ticks(5)
	p.combat.force_hold_charge = true
	p.combat.press(CombatController.Action.KICK)
	await wait_until(func() -> bool: return p.combat.is_charging(), 60)
	var steering := p.traversal.is_charge_steering()
	var g := spawn_enemy(&"grunt", p.global_position + Vector3(1.2, 0.0, 0.0), Vector3.LEFT)
	await ticks(2)
	clear_events()
	var info := HitInfo.new()
	info.attacker = g
	info.move_id = &"e_jab"
	info.kind = &"strike"
	info.damage = 1.0
	info.tier = HitInfo.Tier.FLINCH
	info.reaction = HitInfo.Reaction.FLINCH
	info.hit_direction = Vector3.LEFT
	info.hit_position = p.get_aim_point()
	info.hit_bone = Bones.CHEST
	info.unblockable = true
	var res := p.take_hit(info)
	await ticks(3)
	var stumbled := false
	for e in events_of(&"stumbled"):
		if e[0] == p:
			stumbled = true
	print("  hit while charging at a sprint (steering %s): result %d, stumbled %s, still charging %s, charge steering %s" % [
		steering, res, stumbled, p.combat.is_charging(), p.traversal.is_charge_steering()])
	check(steering and res == HitInfo.Result.HIT and stumbled, "a hit during a sprinting charge makes the player stumble")
	check(not p.combat.is_charging() and not p.traversal.is_charge_steering(), "...and knocks them out of the charge")
	p.combat.release(CombatController.Action.KICK)
	p.combat.force_hold_charge = false
	await settle(p, 90)
	g.queue_free()
	await ticks(2)

## The upgraded caps (10, 12) build over the same 1.2 s.
func _upgraded_caps(p: Fighter) -> void:
	for cap: float in [10.0, 12.0]:
		await settle(p, 20)
		Tuning.debug_speed_cap = cap
		p.global_position = Vector3(0.0, 0.0, 60.0)
		await ticks(5)
		var t0 := TimeDirector.now()
		p.move_input = Vector3.FORWARD
		dash_down(p)
		var below := true
		var t_cap := -1.0
		var t_charge := -1.0
		for i in 240:
			await get_tree().physics_frame
			var v := hspeed(p)
			if v < cap * 0.99:
				below = true
			elif below:
				below = false
				t_cap = TimeDirector.now() - t0
			if t_charge < 0.0 and p.traversal.sprint_charge >= 0.999:
				t_charge = TimeDirector.now() - t0
		print("  cap %.0f: 99%% at %.3f s, sprint_charge 1 at %.3f s, speed %.2f" % [cap, t_cap, t_charge, hspeed(p)])
		check(near(t_cap, Tuning.SPRINT_RAMP_TIME, 0.1) and near(t_charge, Tuning.SPRINT_RAMP_TIME, 0.1),
			"an upgraded %.0f m/s cap is reached in %.3f s (1.2 +- 0.1)" % [cap, t_cap])
		dash_up(p)
	Tuning.debug_speed_cap = 8.0
	await settle(p, 30)

## Focus mode: the player sprints the same distance per real second.
func _focus_sprint(p: Fighter) -> void:
	await settle(p, 20)
	p.global_position = Vector3(0.0, 0.0, 70.0)
	await sprint_to_cap(p, Vector3.FORWARD)
	await ticks(5)
	var z0 := p.global_position.z
	await ticks(120)
	var d_normal := z0 - p.global_position.z
	var ok := TimeDirector.begin_focus()
	await ticks(2)
	var scale := Engine.time_scale
	z0 = p.global_position.z
	await ticks(120)
	var d_focus := z0 - p.global_position.z
	TimeDirector.end_focus()
	await ticks(30)
	print("  sprint per real second: %.3f m normal, %.3f m in Focus (time scale %.2f, focus %s)" % [d_normal, d_focus, scale, ok])
	check(ok and scale < 0.5 and absf(d_focus - d_normal) <= d_normal * 0.05,
		"in Focus mode the sprint covers the same distance per real second (%.2f vs %.2f m)" % [d_focus, d_normal])
	await settle(p, 30)

static func _yaw(v: Vector3) -> float:
	return atan2(-v.x, -v.z)
