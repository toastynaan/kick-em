extends "res://tests/move/move_test_base.gd"
## F7b wall run (Feel Reference: Wall run). Checks, with measured numbers:
## - sprint + Jump next to a runnable wall starts a wall run; walk + Jump is a
##   normal jump; a sprint below sprint_charge 0.6 is a normal jump;
## - the run keeps 100% speed, rises 0.5 m over 0.3 s then holds, lasts at most
##   1.0 s (8 m at the base cap), and drops off keeping 90%;
## - the same wall cannot be run again before touching the floor;
## - Jump during the run kicks off at 45 degrees, keeping 100% speed, and reaches
##   the top of the 1.8 m platform;
## - a bot doing 200 sprint jabs along a wall starts 0 wall runs;
## - a tapped kick at the end of a wall run counts as full sprint (speed_toward
##   = cap), ends the run, drops to walking; with B's power score: P >= 5 and a launch;
## - a cracked Destructible panel cannot be run on (D's real panel), an intact one can.

const LANE_X := 0.3         ## runner's x beside the concrete wall (face at x = 1.0)
const INTO := 20.0          ## degrees into the wall for the approach

var _wall: StaticBody3D

## Simulated seconds (the timeout counts fixed-fps time).
func _init() -> void:
	_timeout = 900.0

func run() -> void:
	_wall = make_runnable_wall(1.2, 0.0, -12.0, 4.0, 0.4)
	# The 1.8 m platform out from the wall, where a kick-off from the run lands.
	make_box(Vector3(-5.75, 0.9, -10.5), Vector3(6.5, 1.8, 11.0), "Platform")
	var p := spawn_player(Vector3(LANE_X, 0.0, 16.0))
	await ticks(30)
	await _sprint_run(p)
	await _walk_jump(p)
	await _low_charge(p)
	await _same_wall(p)
	await _kickoff_platform(p)
	await _kick_off_end(p)
	await _cracked_panel(p)
	await _jab_bot(p)
	done()

func _into_dir() -> Vector3:
	var a := deg_to_rad(INTO)
	return Vector3(sin(a), 0.0, -cos(a))

## Sprint along the lane (to the cap unless `charge_to` is lower) and steer
## INTO degrees into the wall as the wall begins. Returns at z ~ -0.8.
func _approach(p: Fighter, sprint := true, z0 := 16.0, x := LANE_X) -> void:
	await settle(p, 10)
	p.global_position = Vector3(x, 0.02, z0)
	p.rotation.y = 0.0
	await ticks(8)
	p.move_input = Vector3.FORWARD
	if sprint:
		dash_down(p)
	await wait_until(func() -> bool: return p.global_position.z <= 0.2, 600)
	p.move_input = _into_dir()
	await wait_until(func() -> bool: return p.global_position.z <= -0.8, 60)

func _sprint_run(p: Fighter) -> void:
	await _approach(p)
	clear_events()
	var v0 := hspeed(p)
	var charge := p.traversal.sprint_charge
	var y0 := p.global_position.y
	var z0 := p.global_position.z
	var t0 := TimeDirector.now()
	p.traversal.on_jump_pressed()
	await ticks(1)
	var started := p.traversal.is_wall_running()
	var st := last_event(&"wall_run_started")
	var y_03 := -1.0
	var ymax := y0
	var vmin := INF
	var vmax := 0.0
	var steps := 0
	var cap_seen := p.traversal.speed_toward(Vector3.FORWARD)
	while p.traversal.is_wall_running():
		await get_tree().physics_frame
		var t := TimeDirector.now() - t0
		if y_03 < 0.0 and t >= Tuning.WALLRUN_RISE_TIME - 1e-4:
			y_03 = p.global_position.y
		ymax = maxf(ymax, p.global_position.y)
		if p.traversal.is_wall_running():
			vmin = minf(vmin, -p.velocity.z)
			vmax = maxf(vmax, -p.velocity.z)
		if t > 2.0:
			break
	var dur := TimeDirector.now() - t0
	var dist := z0 - p.global_position.z
	var ended := last_event(&"wall_run_ended")
	var v_drop := hspeed(p)
	steps = count_events(&"wall_run_step")
	print("  sprint (charge %.2f, %.2f m/s) + Jump by the wall: run %s side %s; rise %.3f m at 0.3 s, max %.3f; speed along %.2f..%.2f; %.3f s, %.2f m; ended %s; drop-off %.2f (%.1f%%); steps %d; speed_toward %.2f" % [
		charge, v0, started, st[2] if not st.is_empty() else "-", y_03 - y0, ymax - y0, vmin, vmax, dur, dist,
		ended[1] if not ended.is_empty() else &"-", v_drop, v_drop / maxf(v0, 0.01) * 100.0, steps, cap_seen])
	check(started, "sprint + Jump next to a runnable wall starts a wall run")
	check(not st.is_empty() and int(st[2]) == 1, "the wall is reported on the right (+1)")
	check(near(y_03 - y0, Tuning.WALLRUN_RISE, 0.03) and ymax - y0 <= Tuning.WALLRUN_RISE + 0.03,
		"rises %.3f m over 0.3 s and holds (max %.3f)" % [y_03 - y0, ymax - y0])
	check(vmin >= v0 * 0.98 and vmax <= v0 * 1.02, "keeps 100%% of sprint speed along the wall (%.2f..%.2f of %.2f)" % [vmin, vmax, v0])
	check(near(dur, Tuning.WALLRUN_TIME, 0.02) and near(dist, v0 * Tuning.WALLRUN_TIME, 0.3),
		"lasts %.3f s and %.2f m (1.0 s, 8 m at the base cap)" % [dur, dist])
	check(not ended.is_empty() and ended[1] == &"time", "ends on time")
	check(near(v_drop, v0 * Tuning.WALLRUN_DROP_KEEP, 0.1), "drops off keeping %.1f%% (90%%)" % (v_drop / maxf(v0, 0.01) * 100.0))
	check(steps >= 5, "wall_run_step on every step (%d)" % steps)
	check(near(cap_seen, p.traversal.get_speed_cap(), 0.01), "speed_toward during the run is the cap")
	await wait_until(func() -> bool: return not p.traversal.is_airborne(), 240)
	check(not p.is_down(), "lands on the feet after the drop-off")
	await settle(p, 20)

func _walk_jump(p: Fighter) -> void:
	await _approach(p, false, 4.0)
	clear_events()
	p.traversal.on_jump_pressed()
	await ticks(2)
	print("  walk (%.2f m/s) + Jump by the wall: wall run %s, jumped %d, airborne %s" % [
		hspeed(p), p.traversal.is_wall_running(), count_events(&"jumped"), p.traversal.is_airborne()])
	check(not p.traversal.is_wall_running() and count_events(&"wall_run_started") == 0 and count_events(&"jumped") == 1,
		"walk + Jump next to the wall is a normal jump")
	await wait_until(func() -> bool: return not p.traversal.is_airborne(), 240)
	await settle(p, 20)

func _low_charge(p: Fighter) -> void:
	# Sprint started just before the wall: sprint_charge under 0.6.
	await _approach(p, true, 2.2)
	clear_events()
	var charge := p.traversal.sprint_charge
	p.traversal.on_jump_pressed()
	await ticks(2)
	print("  sprint at charge %.2f + Jump: wall run %s" % [charge, p.traversal.is_wall_running()])
	check(charge < Tuning.WALLRUN_MIN_CHARGE and count_events(&"wall_run_started") == 0,
		"below sprint_charge 0.6 Jump is a normal jump (charge %.2f)" % charge)
	await wait_until(func() -> bool: return not p.traversal.is_airborne(), 240)
	await settle(p, 20)

func _same_wall(p: Fighter) -> void:
	await _approach(p)
	clear_events()
	p.traversal.on_jump_pressed()
	await ticks(1)
	# Steer away to end the run early, then try again before touching the floor.
	p.move_input = Vector3.LEFT
	await wait_until(func() -> bool: return not p.traversal.is_wall_running(), 60)
	var reason := last_event(&"wall_run_ended")
	p.move_input = _into_dir()
	await ticks(2)
	p.traversal.on_jump_pressed()
	await ticks(1)
	var again := p.traversal.is_wall_running()
	print("  stick away ends the run: %s; Jump again before landing: wall run %s" % [
		reason[1] if not reason.is_empty() else &"-", again])
	check(not reason.is_empty() and reason[1] == &"stick", "pointing the stick away from the wall ends the run")
	check(not again and count_events(&"wall_run_started") == 1, "the same wall cannot be run again before touching the floor")
	await wait_until(func() -> bool: return not p.traversal.is_airborne() and not p.traversal.is_wall_running(), 240)
	await settle(p, 20)
	await _approach(p)
	p.traversal.on_jump_pressed()
	await ticks(1)
	check(p.traversal.is_wall_running(), "after touching the floor the wall can be run again")
	await wait_until(func() -> bool: return not p.traversal.is_wall_running(), 240)
	await wait_until(func() -> bool: return not p.traversal.is_airborne(), 240)
	await settle(p, 20)

func _kickoff_platform(p: Fighter) -> void:
	await _approach(p)
	clear_events()
	p.traversal.on_jump_pressed()
	await ticks(1)
	await wait_until(func() -> bool: return p.global_position.z <= -4.0, 120)
	var v_run := -p.velocity.z
	var y_run := p.global_position.y
	p.move_input = Vector3.ZERO
	p.traversal.on_jump_pressed()
	await ticks(1)
	var v := p.velocity
	var ang := rad_to_deg(atan2(-v.x, -v.z))
	var hv := Vector2(v.x, v.z).length()
	var top := p.global_position.y
	var mantle := false
	while p.traversal.is_airborne() or p.traversal.is_vaulting():
		top = maxf(top, p.global_position.y)
		if p.traversal.get_parkour_kind() == &"air_mantle":
			mantle = true
		await get_tree().physics_frame
	await ticks(2)
	var end := p.global_position
	var ended := last_event(&"wall_run_ended")
	print("  kick-off from the run at %.2f m/s (feet %.2f m): %.1f deg off the wall, %.2f m/s kept, apex %.2f m, air mantle %s, ends at (%.2f, %.2f, %.2f)" % [
		v_run, y_run, ang, hv, top, mantle, end.x, end.y, end.z])
	check(not ended.is_empty() and ended[1] == &"jump", "Jump during the run kicks off")
	check(near(ang, Tuning.WALLRUN_KICK_ANGLE, 1.0), "kicks off at %.1f deg away from the wall (45)" % ang)
	check(near(hv, v_run, 0.05), "the kick-off keeps 100%% speed (%.2f of %.2f)" % [hv, v_run])
	check(near(top - y_run, Tuning.WALLRUN_KICK_HEIGHT, 0.05) or mantle, "adds %.2f m of height (1.6)" % (top - y_run))
	check(end.y >= 1.75 and end.x < -2.5, "the kick-off reaches the top of the 1.8 m platform")
	await settle(p, 20)

func _kick_off_end(p: Fighter) -> void:
	var g := spawn_enemy(&"grunt", Vector3(0.45, 0.0, -10.0), Vector3.BACK)
	await ticks(10)
	await _approach(p)
	clear_events()
	p.traversal.on_jump_pressed()
	await ticks(1)
	await wait_until(func() -> bool:
		return p.global_position.distance_to(g.global_position) <= 2.3 or not p.traversal.is_wall_running(), 160)
	var running := p.traversal.is_wall_running()
	var st := p.traversal.speed_toward(g.global_position - p.global_position)
	p.combat.press(CombatController.Action.KICK)
	p.combat.release(CombatController.Action.KICK)
	await ticks(1)
	var still := p.traversal.is_wall_running()
	var end_speed := 0.0
	while p.combat.is_attacking():
		end_speed = hspeed(p)
		await get_tree().physics_frame
	var ended := last_event(&"wall_run_ended")
	var hit: HitInfo = null
	for e in events_of(&"hit_landed"):
		var info := e[0] as HitInfo
		if info != null and info.attacker == p and info.victim == g:
			hit = info
	var launched := count_events(&"fighter_launched") > 0
	await wait_until(func() -> bool: return not p.traversal.is_airborne(), 240)
	print("  tapped kick at the end of a wall run (running %s): speed_toward %.2f (cap %.1f), run ended %s, speed at the end of the strike %.2f; hit %s P %.2f tier %s, launched %s" % [
		running, st, p.traversal.get_speed_cap(), ended[1] if not ended.is_empty() else &"-", end_speed,
		hit != null, hit.power if hit else 0.0, HitInfo.tier_name(hit.tier) if hit else &"-", launched])
	check(running and near(st, p.traversal.get_speed_cap(), 0.01), "the wall-run kick reads full sprint speed toward the target")
	check(not still and not ended.is_empty() and ended[1] == &"strike", "the strike ends the run")
	check(end_speed <= Tuning.WALK_SPEED + 0.05, "and drops the player to walking speed (%.2f)" % end_speed)
	if hit != null and hit.power > 0.0:
		check(hit.power >= 5.0 - 1e-4 and launched, "a tapped kick off a wall run logs P %.2f (>= 5) and launches" % hit.power)
	else:
		print("  PENDING (B): no power score on the hit yet (hit %s); P >= 5 + launch is checked once B's strikes land" % (hit != null))
	await settle(p, 120)
	g.queue_free()
	await ticks(2)

func _cracked_panel(p: Fighter) -> void:
	# D's real drywall panels: three along z 0..-9 at x 21 (face toward -X).
	var panels: Array[Destructible] = []
	for i in 3:
		var d := Destructible.new()
		d.surface = &"drywall"
		d.name = "RunPanel%d" % i
		d.transform = Transform3D(Basis.looking_at(Vector3(1, 0, 0), Vector3.UP), Vector3(21.125, 1.5, -1.5 - 3.0 * i))
		add_child(d)
		panels.append(d)
	await ticks(2)
	var intact_ok := WorldTags.is_runnable(panels[0])
	await _approach(p, true, 16.0, 20.3)
	clear_events()
	p.traversal.on_jump_pressed()
	await ticks(1)
	var ran := p.traversal.is_wall_running()
	await wait_until(func() -> bool: return not p.traversal.is_wall_running() and not p.traversal.is_airborne(), 300)
	await settle(p, 20)
	panels[0].force_crack(panels[0].global_position + Vector3(-0.13, 0.0, 0.0))
	await ticks(2)
	var cracked_runnable := WorldTags.is_runnable(panels[0])
	await _approach(p, true, 16.0, 20.3)
	clear_events()
	p.traversal.on_jump_pressed()
	await ticks(1)
	var ran_cracked := p.traversal.is_wall_running()
	print("  drywall panels: intact runnable %s, wall run %s; cracked runnable %s (is_cracked %s), wall run %s, jumped %d" % [
		intact_ok, ran, cracked_runnable, panels[0].is_cracked, ran_cracked, count_events(&"jumped")])
	check(intact_ok and ran, "an intact Destructible panel is runnable")
	check(panels[0].is_cracked and not cracked_runnable and not ran_cracked and count_events(&"jumped") == 1,
		"a cracked panel can't be run on (Jump is a normal jump)")
	await wait_until(func() -> bool: return not p.traversal.is_airborne(), 240)
	await settle(p, 20)

func _jab_bot(p: Fighter) -> void:
	clear_events()
	var jabs := 0
	var was := false
	var passes := 0
	var since := 0
	while jabs < 200:
		await settle(p, 4)
		p.global_position = Vector3(LANE_X, 0.02, 12.0)
		p.rotation.y = 0.0
		await ticks(3)
		passes += 1
		p.move_input = Vector3.FORWARD
		dash_down(p)
		since = 0
		while p.global_position.z > -11.0 and jabs < 200:
			if p.global_position.z < 1.0:
				p.move_input = _into_dir()
			since += 1
			if since >= 40 and not p.combat.is_attacking():
				p.combat.press(CombatController.Action.LIGHT)
				p.combat.release(CombatController.Action.LIGHT)
				since = 0
			await get_tree().physics_frame
			var now_att := p.combat.is_attacking()
			if now_att and not was:
				jabs += 1
			was = now_att
			if hspeed(p) < 0.5 and since > 200:
				break
	await settle(p, 10)
	print("  sprint-jab bot: %d jabs over %d passes along the wall; wall runs %d, jumps %d" % [
		jabs, passes, count_events(&"wall_run_started"), count_events(&"jumped")])
	check(jabs >= 200, "the bot threw 200 sprint jabs (%d)" % jabs)
	check(count_events(&"wall_run_started") == 0, "200 sprint jabs along a wall start 0 wall runs")
