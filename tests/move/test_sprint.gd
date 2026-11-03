extends "res://tests/move/move_test_base.gd"
## The sprint (Round 7: Defence > Sprint: still held after Tuning.DASH_HOLD_SPRINT,
## the dodge flows into the existing sprint ramp; sprinting adds no power).
## Checks, with measured numbers:
## - holding Dash in a straight line reaches the cap 1.2 +- 0.1 s after the
##   press (sprint_charge and the settled speed), never under 6 m/s after 150 ms;
## - releasing bleeds to walk over 0.25 s;
## - a 90-degree turn inside 0.2 s at full speed drops speed 30%; a gentle
##   curve costs nothing;
## - a strike thrown from a sprint ends it (walking speed at its end) and a
##   held Dash builds again from 6 m/s;
## - the upgraded caps (10, 12) build over the same 1.2 s;
## - in slow motion the player sprints the same distance per real second;
## - footsteps carry the floor surface and sprint_charge;
## - holding a body never sprints (Dash is the drive then); a prop in hand
##   keeps the dodge and the sprint, never slowed;
## - ground cracks at speed (Round 7 amendment): every footstep at 10 m/s cracks
##   the floor (level 1, never a crater), none at 8 m/s; the floor-decal budget
##   (Tuning.FLOOR_DECAL_MAX) holds over a long run.

func run() -> void:
	var p := spawn_player(Vector3(0.0, 0.0, 60.0))
	await ticks(30)
	check(p.traversal != null, "the player has a Traversal")
	await _cap_time(p)
	await _release_bleed(p)
	await _turn_penalty(p)
	await _gentle_curve(p)
	await _sprint_strike(p)
	await _upgraded_caps(p)
	await _slow_motion_sprint(p)
	await _footsteps(p)
	await _no_sprint_holding(p)
	await _sprint_with_prop(p)
	await _speed_cracks(p)
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
		# Last upward crossing (the dodge opens above the cap).
		if v < cap * 0.99:
			below = true
		elif below:
			below = false
			t_settle = t
		if v < cap * 0.98:
			below98 = true
		elif below98:
			below98 = false
			t_98 = t
	print("  cap %.1f: 98%% at %.3f s, 99%% at %.3f s, sprint_charge 1 at %.3f s; dodge peak %.2f, min after 150 ms %.2f, speed at 2 s %.2f" % [
		cap, t_98, t_settle, t_charge, peak, min_after, hspeed(p)])
	check(count_events(&"dodged") == 1, "the press dodged first (one dodged event)")
	check(near(t_98, Tuning.SPRINT_RAMP_TIME, 0.2), "98%% of the cap at %.3f s" % t_98)
	check(near(t_charge, Tuning.SPRINT_RAMP_TIME, 0.1), "sprint_charge reaches 1 in %.3f s (1.2 +- 0.1)" % t_charge)
	check(near(t_settle, Tuning.SPRINT_RAMP_TIME, 0.1), "speed reaches the cap (99%%) in %.3f s (1.2 +- 0.1)" % t_settle)
	check(min_after >= Tuning.SPRINT_START_SPEED - 0.05, "never under 6 m/s after the 150 ms hold (min %.2f)" % min_after)
	check(near(hspeed(p), cap, 0.05), "holds the cap %.2f m/s" % hspeed(p))
	check(p.traversal.is_sprinting() and count_events(&"sprint_started") == 1, "is_sprinting and one sprint_started")
	await settle(p, 40)

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
	await place(p, Vector3(0.0, 0.0, 60.0))
	await sprint_to_cap(p, Vector3.FORWARD)
	await ticks(12)
	var before := hspeed(p)
	var n0 := p.traversal.turn_penalties
	var yaw0 := yaw_of(p.velocity)
	p.move_input = Vector3.RIGHT  # a hard 90-degree cut
	var after := INF
	var t_turn := -1.0
	var t0 := TimeDirector.now()
	for i in 30:
		await get_tree().physics_frame
		after = minf(after, hspeed(p))
		if t_turn < 0.0 and absf(rad_to_deg(angle_difference(yaw0, yaw_of(p.velocity)))) >= 89.0:
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
	await place(p, Vector3(0.0, 0.0, 60.0))
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

## A strike thrown from a sprint ends the sprint: walking speed by its end,
## and the held Dash builds the sprint again from the start.
func _sprint_strike(p: Fighter) -> void:
	await settle(p, 20)
	await place(p, Vector3(0.0, 0.0, 60.0))
	await sprint_to_cap(p, Vector3.FORWARD)
	await ticks(10)
	var v0 := hspeed(p)
	p.combat.press(CombatController.Action.LIGHT)
	await ticks(1)
	p.combat.release(CombatController.Action.LIGHT)
	var seen := await wait_until(func() -> bool: return p.combat.is_attacking(), 10)
	var sprint_in := false
	var end := 0.0
	while p.combat.is_attacking():
		sprint_in = sprint_in or p.traversal.is_sprinting()
		end = hspeed(p)
		await get_tree().physics_frame
	var free := hspeed(p)
	await ticks(3)
	var rebuilt := p.traversal.is_sprinting()
	print("  sprint jab (no target) at %.2f m/s: sprinting during it %s, speed at its end %.2f, first free tick %.2f, sprinting again %s" % [
		v0, sprint_in, end, free, rebuilt])
	check(seen and not sprint_in and end <= Tuning.WALK_SPEED + 0.05,
		"a strike from a sprint ends it (%.2f m/s at the strike's end)" % end)
	check(free <= Tuning.SPRINT_START_SPEED + 0.05 and rebuilt, "the held Dash builds the sprint again from the start (%.2f)" % free)
	await settle(p, 30)

## The upgraded caps (10, 12) build over the same 1.2 s.
func _upgraded_caps(p: Fighter) -> void:
	for cap: float in [10.0, 12.0]:
		await settle(p, 20)
		Tuning.debug_speed_cap = cap
		await place(p, Vector3(0.0, 0.0, 60.0))
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

## Slow motion: the player sprints the same distance per real second.
func _slow_motion_sprint(p: Fighter) -> void:
	await settle(p, 20)
	await place(p, Vector3(0.0, 0.0, 70.0))
	await sprint_to_cap(p, Vector3.FORWARD)
	await ticks(5)
	var z0 := p.global_position.z
	await ticks(120)
	var d_normal := z0 - p.global_position.z
	var ok := false
	if TimeDirector.has_method(&"request_slowmo"):
		ok = bool(TimeDirector.call(&"request_slowmo", 0.3, 3.0, TimeDirector.PRIO_DODGE))
	else:
		ok = TimeDirector.request(&"finisher")
	await ticks(20)
	var scale := Engine.time_scale
	z0 = p.global_position.z
	await ticks(120)
	var d_slow := z0 - p.global_position.z
	TimeDirector.reset()
	await ticks(30)
	print("  sprint per real second: %.3f m normal, %.3f m in slow motion (time scale %.2f, granted %s)" % [d_normal, d_slow, scale, ok])
	check(ok and scale < 0.7 and absf(d_slow - d_normal) <= d_normal * 0.05,
		"in slow motion the sprint covers the same distance per real second (%.2f vs %.2f m)" % [d_slow, d_normal])
	dash_up(p)
	await settle(p, 30)

func _footsteps(p: Fighter) -> void:
	await settle(p, 20)
	var plate := make_box(Vector3(0.0, -0.49, 30.0), Vector3(6.0, 1.0, 20.0), "MetalPlate")
	plate.set_meta(&"surface", &"metal")
	await place(p, Vector3(0.0, 0.05, 38.0))
	p.move_input = Vector3.FORWARD
	dash_down(p)
	await wait_until(func() -> bool: return p.traversal.is_sprinting(), 60)
	clear_events()  # the dodge is a hop: footsteps from the first stride of the sprint
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

## Holding a body, Dash never sprints (it is Carry's: the drive).
func _no_sprint_holding(p: Fighter) -> void:
	await settle(p, 20)
	await place(p, Vector3(0.0, 0.0, 80.0))
	var d := install_carry_double(p, 0.7)
	p.move_input = Vector3.FORWARD
	p.traversal.on_dash_pressed()  # even if Dash reached Traversal
	var top := 0.0
	for i in 120:
		await get_tree().physics_frame
		top = maxf(top, hspeed(p))
	var sprinting := p.traversal.is_sprinting() or p.traversal.is_dodging()
	p.traversal.on_dash_released()
	print("  holding a body, Dash held 1 s: sprinting or dodging %s, top speed %.2f (walk x 0.7 = %.2f)" % [
		sprinting, top, Tuning.WALK_SPEED * 0.7])
	check(not sprinting and top <= Tuning.WALK_SPEED * 0.7 + 0.05, "holding a body never sprints or dodges")
	remove_carry_double(p, d)
	await settle(p, 20)

## A prop in hand: Dash is still the dodge and the sprint, at full speed.
func _sprint_with_prop(p: Fighter) -> void:
	await settle(p, 20)
	await place(p, Vector3(10.0, 0.0, 80.0))
	var d := install_carry_double(p, 0.7, true)
	clear_events()
	var ok := await sprint_to_cap(p, Vector3.FORWARD)
	var v := hspeed(p)
	dash_up(p)
	print("  a prop in hand, Dash held: dodged %d, sprint reached the cap %s (%.2f m/s)" % [count_events(&"dodged"), ok, v])
	check(count_events(&"dodged") == 1 and ok and near(v, p.traversal.get_speed_cap(), 0.05),
		"a prop in hand keeps the dodge and the sprint (%.2f m/s)" % v)
	remove_carry_double(p, d)
	await settle(p, 20)

## Ground cracks at speed: footsteps at R7_SPEED_CRACK_FROM (10 m/s) crack the
## floor, none at the 8 m/s base cap; level 1 only; the decal budget holds.
func _speed_cracks(p: Fighter) -> void:
	var rows := []
	for cap: float in [8.0, 10.0]:
		await settle(p, 20)
		WorldDamage.reset()
		Tuning.debug_speed_cap = cap
		await place(p, Vector3(-60.0, 0.0, 150.0))
		var n0 := p.traversal.speed_cracks
		p.move_input = Vector3.FORWARD
		dash_down(p)
		await wait_until(func() -> bool: return p.traversal.sprint_charge >= 0.999, 240)
		clear_events()
		await ticks(int(6.0 * 120.0))  # 6 s at the cap: 48 / 60 m
		var steps := count_events(&"footstep")
		var cracks := p.traversal.speed_cracks - n0
		var counts := WorldDamage.get_floor_counts()
		var marks: Array = BloodFX.call(&"floor_mark_levels") if BloodFX.has_method(&"floor_mark_levels") else [-1, -1, -1]
		dash_up(p)
		rows.append([cap, steps, cracks, counts, marks])
		print("  sprint 6 s at %.0f m/s: %d footsteps, %d cracked the floor; WorldDamage cells %s; live floor marks by level %s (budget %d)" % [
			cap, steps, cracks, counts, marks, Tuning.FLOOR_DECAL_MAX])
	Tuning.debug_speed_cap = 8.0
	var slow: Array = rows[0]
	var fast: Array = rows[1]
	var fast_counts: Dictionary = fast[3]
	var marks_fast: Array = fast[4]
	check(int(slow[2]) == 0 and int((slow[3] as Dictionary)["cracks"]) == 0, "no ground cracks at 8 m/s")
	check(int(fast[2]) >= int(fast[1]) - 1 and int(fast[2]) >= 20, "at 10 m/s every footstep cracks the floor (%d of %d)" % [fast[2], fast[1]])
	check(int(fast_counts["craters"]) == 0 and int(fast_counts["rubble"]) == 0 and int(fast_counts["cracks"]) >= 20,
		"footstep cracks are level 1, never a crater (%s)" % fast_counts)
	check(int(marks_fast[0]) >= 0 and int(marks_fast[0]) + int(marks_fast[1]) + int(marks_fast[2]) <= Tuning.FLOOR_DECAL_MAX,
		"the floor-decal budget holds (%s live marks, budget %d)" % [marks_fast, Tuning.FLOOR_DECAL_MAX])
	WorldDamage.reset()
	await settle(p, 20)
