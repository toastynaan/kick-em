extends "res://tests/move/move_test_base.gd"
## Movement in D's real Yard (YardBuilder): the F7 / F7b checks again on the
## arena's own geometry, with measured numbers:
## - sprinting into the static 0.9 m low wall and the brick 0.9 m low wall
##   vaults them, keeping >= 90%; a 1.1 m crate vaults;
## - walking into the 1.8 m platform is blocked, sprinting into it mantles up;
## - sprint + Jump along the west facade (destructible panels) and the south
##   concrete wall starts a wall run; a kick-off from the west facade lands on
##   the platform 3 m out;
## - footsteps report the water and metal patches;
## - the four stairwells are climbed with step-ups to their 3 m landing (Round 7).

var yard: YardBuilder
var _pl: Fighter  ## the player, for the stairwell helpers
var _q := PhysicsShapeQueryParameters3D.new()
var _shape := CapsuleShape3D.new()

func _init() -> void:
	_timeout = 900.0

func run() -> void:
	# The base scene's floor box sits under the Yard; the Yard brings its own floor.
	for c in get_children():
		if c is StaticBody3D and c.name == "Floor":
			c.queue_free()
	yard = YardBuilder.new()
	yard.name = "Yard"
	add_child(yard)
	yard.build()
	await ticks(3)
	var feats := yard.get_parkour_features()
	var p := spawn_player(Vector3(0.0, 0.05, 6.0))
	await ticks(30)
	await _vault_lane(p, Vector3(0.0, 0.05, 5.0), Vector3.FORWARD, "static low wall (0, -7.5)")
	await _vault_lane(p, Vector3(1.0, 0.05, -0.8), Vector3.RIGHT, "brick low wall (6.5, 0)")
	await _vault_lane(p, Vector3(3.2, 0.05, 0.6), Vector3.FORWARD, "market lane x 3.2 (table, crate)", &"vault")
	await _platform(p, feats["platform"])
	await _facade_run(p)
	await _south_run(p)
	await _lane_run(p, Vector3(10.3, 0.05, 10.3), Vector3.FORWARD, Vector3.RIGHT, "east facade (brick panels)")
	await _lane_run(p, Vector3(-4.0, 0.05, -10.3), Vector3.RIGHT, Vector3.FORWARD, "garage facade")
	await _facade_cooldown_cap10(p)
	await _cracked_facade(p)
	await _platform_landings(p, feats["platform"])
	await _surfaces(p)
	_pl = p
	_shape.radius = Fighter.CAPSULE_RADIUS
	_shape.height = Fighter.CAPSULE_HEIGHT
	_q.shape = _shape
	_q.collision_mask = Layers.WORLD | Layers.DESTRUCTIBLE | Layers.CAPSULE
	await _stairwells()
	done()

func _vault_lane(p: Fighter, start: Vector3, dir: Vector3, label: String, want: StringName = &"vault") -> void:
	await settle(p, 10)
	p.global_position = start
	p.snap_facing(dir)
	await ticks(6)
	clear_events()
	p.move_input = dir
	dash_down(p)
	var m := {"v": 0.0}
	var started := await wait_until(func() -> bool:
		if not p.traversal.is_vaulting():
			m["v"] = minf(hspeed(p), p.traversal.get_speed_cap())  # run speed: a dodge's burst above the cap is not
		return p.traversal.is_vaulting(), 360)
	var v_in: float = m["v"]
	var kind := p.traversal.get_parkour_kind()
	var ev := last_event(&"parkour")
	await wait_until(func() -> bool: return not p.traversal.is_vaulting(), 120)
	var v_out := hspeed(p)
	dash_up(p)
	print("  Yard %s at %.2f m/s: %s (height %.2f), out %.2f (%.1f%%)" % [label, v_in, kind,
		float(ev[3]) if not ev.is_empty() else -1.0, v_out, v_out / maxf(v_in, 0.01) * 100.0])
	check(started and kind == want, "the Yard's %s: %s with no input" % [label, want])
	check(v_out >= v_in * Tuning.VAULT_KEEP - 0.05, "keeps %.1f%% (>= 90%%)" % (v_out / maxf(v_in, 0.01) * 100.0))
	await settle(p, 30)

func _platform(p: Fighter, plat: AABB) -> void:
	# Approach the platform's east face (x = -5) along z = 0, heading -X.
	var face_x := plat.end.x
	await settle(p, 10)
	p.global_position = Vector3(face_x + 3.0, 0.05, 0.0)
	p.snap_facing(Vector3.LEFT)
	await ticks(6)
	p.move_input = Vector3.LEFT
	await ticks(150)
	var x_walk := p.global_position.x
	print("  Yard platform, walking: stopped at x %.2f (face %.2f), y %.2f" % [x_walk, face_x, p.global_position.y])
	check(x_walk > face_x + 0.2 and p.global_position.y < 0.3, "walking into the Yard's 1.8 m platform is blocked")
	await settle(p, 10)
	p.global_position = Vector3(face_x + 9.5, 0.05, 0.0)
	p.snap_facing(Vector3.LEFT)
	await ticks(6)
	clear_events()
	p.move_input = Vector3.LEFT
	dash_down(p)
	var started := await wait_until(func() -> bool: return p.traversal.is_vaulting(), 360)
	var kind := p.traversal.get_parkour_kind()
	await wait_until(func() -> bool: return not p.traversal.is_vaulting(), 120)
	dash_up(p)
	await ticks(10)
	print("  Yard platform, sprinting: %s, on top y %.2f" % [kind, p.global_position.y])
	check(started and kind == &"mantle" and p.global_position.y > 1.7, "sprinting into the Yard's platform mantles up")
	await settle(p, 20)
	p.global_position = Vector3(0.0, 0.05, 6.0)
	await ticks(10)

## The west facade lane (x = -11, normal +X): run north from z = 10 along x = -10.3.
func _facade_run(p: Fighter) -> void:
	var lane := _lane(&"west_facade")
	check(not lane.is_empty(), "the Yard lists the west facade lane")
	var into := Vector3(-sin(deg_to_rad(20.0)), 0.0, -cos(deg_to_rad(20.0)))
	await settle(p, 10)
	p.global_position = Vector3(-10.3, 0.05, 10.3)
	p.snap_facing(Vector3.FORWARD)
	await ticks(6)
	clear_events()
	p.move_input = Vector3.FORWARD
	dash_down(p)
	# Straight along the facade until the sprint has built past 0.6, then in.
	await wait_until(func() -> bool:
		return p.traversal.sprint_charge >= Tuning.WALLRUN_MIN_CHARGE + 0.05 or p.global_position.z <= 4.6, 400)
	p.move_input = into
	await ticks(3)
	var charge := p.traversal.sprint_charge
	p.traversal.on_jump_pressed()
	await ticks(1)
	var ran := p.traversal.is_wall_running()
	var st := last_event(&"wall_run_started")
	var wall_name := (st[1] as Node).name if not st.is_empty() and st[1] != null else &"-"
	await wait_until(func() -> bool: return p.global_position.z <= 3.2 or not p.traversal.is_wall_running(), 120)
	var still := p.traversal.is_wall_running()
	p.move_input = Vector3.ZERO
	p.traversal.on_jump_pressed()
	await wait_until(func() -> bool: return not p.traversal.is_airborne() and not p.traversal.is_vaulting(), 240)
	await ticks(2)
	dash_up(p)
	var end := p.global_position
	var plat: AABB = yard.get_parkour_features()["platform"]
	var on_plat := end.y > 1.7 and end.x >= plat.position.x - 0.1 and end.x <= plat.end.x + 0.1 \
		and end.z >= plat.position.z - 0.1 and end.z <= plat.end.z + 0.1
	print("  Yard west facade (charge %.2f): wall run %s on %s, still running at z 3.2 %s; kick-off ends at (%.2f, %.2f, %.2f), on the platform %s" % [
		charge, ran, wall_name, still, end.x, end.y, end.z, on_plat])
	check(ran, "sprint + Jump along the Yard's west facade starts a wall run")
	check(still and on_plat, "a kick-off from the west facade lands on the 1.8 m platform")
	await settle(p, 20)

## The south concrete wall (z = 11, normal -Z): run east from x = -7 along z = 10.3.
func _south_run(p: Fighter) -> void:
	var into := Vector3(cos(deg_to_rad(20.0)), 0.0, sin(deg_to_rad(20.0)))
	await settle(p, 10)
	p.global_position = Vector3(-9.0, 0.05, 10.3)
	p.snap_facing(Vector3.RIGHT)
	await ticks(6)
	clear_events()
	p.move_input = Vector3.RIGHT
	dash_down(p)
	await wait_until(func() -> bool: return p.traversal.sprint_charge >= 0.999 or p.global_position.x > 0.0, 400)
	p.move_input = into
	await ticks(3)
	var charge := p.traversal.sprint_charge
	p.traversal.on_jump_pressed()
	await ticks(1)
	var ran := p.traversal.is_wall_running()
	await wait_until(func() -> bool: return not p.traversal.is_wall_running(), 200)
	var ended := last_event(&"wall_run_ended")
	await wait_until(func() -> bool: return not p.traversal.is_airborne(), 240)
	dash_up(p)
	print("  Yard south concrete wall (charge %.2f, x %.2f): wall run %s, ended %s" % [charge, p.global_position.x, ran,
		ended[1] if not ended.is_empty() else &"-"])
	check(ran, "sprint + Jump along the Yard's south concrete wall starts a wall run")
	await settle(p, 20)

## Sprint along a lane from `start` in `run_dir`, steer 20 degrees toward the
## wall (`into`), press Jump. Returns whether a wall run started and on what.
func _lane_attempt(p: Fighter, start: Vector3, run_dir: Vector3, into: Vector3) -> Array:
	await settle(p, 10)
	p.global_position = start
	p.snap_facing(run_dir)
	await ticks(6)
	clear_events()
	p.move_input = run_dir
	dash_down(p)
	await wait_until(func() -> bool: return p.traversal.sprint_charge >= Tuning.WALLRUN_MIN_CHARGE + 0.05, 400)
	var a := deg_to_rad(20.0)
	p.move_input = (run_dir * cos(a) + into * sin(a)).normalized()
	await ticks(3)
	var charge := p.traversal.sprint_charge
	p.traversal.on_jump_pressed()
	await ticks(1)
	var ran := p.traversal.is_wall_running()
	var st := last_event(&"wall_run_started")
	var wall: Node = st[1] if not st.is_empty() else null
	await wait_until(func() -> bool: return not p.traversal.is_wall_running(), 200)
	var ended := last_event(&"wall_run_ended")
	await wait_until(func() -> bool: return not p.traversal.is_airborne(), 240)
	dash_up(p)
	return [ran, wall, charge, ended[1] if not ended.is_empty() else &"-", count_events(&"jumped")]

func _lane_run(p: Fighter, start: Vector3, run_dir: Vector3, into: Vector3, label: String) -> void:
	var r := await _lane_attempt(p, start, run_dir, into)
	print("  Yard %s (charge %.2f): wall run %s on %s, ended %s" % [label, r[2], r[0],
		(r[1] as Node).name if r[1] != null else &"-", r[3]])
	check(r[0], "sprint + Jump along the Yard's %s starts a wall run" % label)
	await settle(p, 20)

## At the 10 m/s cap one run crosses several facade panels; Jump in the air
## by the facade afterwards (before touching the floor) starts no second run.
func _facade_cooldown_cap10(p: Fighter) -> void:
	Tuning.debug_speed_cap = 10.0
	await settle(p, 10)
	p.global_position = Vector3(-10.3, 0.05, 10.3)
	p.snap_facing(Vector3.FORWARD)
	await ticks(6)
	clear_events()
	p.move_input = Vector3.FORWARD
	dash_down(p)
	await wait_until(func() -> bool: return p.traversal.sprint_charge >= Tuning.WALLRUN_MIN_CHARGE + 0.05, 400)
	var a := deg_to_rad(20.0)
	p.move_input = Vector3(-sin(a), 0.0, -cos(a))
	await ticks(3)
	p.traversal.on_jump_pressed()
	await ticks(1)
	var st := last_event(&"wall_run_started")
	await wait_until(func() -> bool: return not p.traversal.is_wall_running(), 200)
	p.traversal.on_jump_pressed()
	await ticks(2)
	var runs := count_events(&"wall_run_started")
	await wait_until(func() -> bool: return not p.traversal.is_airborne() and not p.traversal.is_wall_running(), 300)
	dash_up(p)
	Tuning.debug_speed_cap = 8.0
	print("  Yard west facade at cap 10: first run on %s, ended at z %.2f; Jump before landing: runs %d" % [
		(st[1] as Node).name if not st.is_empty() else &"-", p.global_position.z, runs])
	check(not st.is_empty() and runs == 1, "the Yard's facade panels are one wall for the same-wall cooldown")
	await settle(p, 20)

## A cracked facade panel is not runnable: Jump there is a normal jump.
func _cracked_facade(p: Fighter) -> void:
	# The west facade panels around the run's take-off point (x -11.125, z 6 and 3).
	var panels: Array[Destructible] = []
	for d in yard.get_destructibles():
		if d.kind == &"panel" and absf(d.global_position.x + 11.125) < 0.2 \
				and (absf(d.global_position.z - 6.0) < 0.2 or absf(d.global_position.z - 3.0) < 0.2):
			panels.append(d)
	check(panels.size() == 2, "found the west facade panels at z 6 and 3 (%d)" % panels.size())
	if panels.is_empty():
		return
	for d in panels:
		d.force_crack(d.global_position + Vector3(0.13, 0.0, 0.0))
	await ticks(2)
	var panel := panels[0]
	var r := await _lane_attempt(p, Vector3(-10.3, 0.05, 10.3), Vector3.FORWARD, Vector3.LEFT)
	print("  Yard cracked west facade panel (%s, cracked %s, runnable %s): wall run %s on %s, jumped %d" % [
		panel.name, panel.is_cracked, WorldTags.is_runnable(panel), r[0], (r[1] as Node).name if r[1] != null else &"-", r[4]])
	check(panel.is_cracked and not WorldTags.is_runnable(panel), "the cracked Yard panel is not runnable")
	check(not r[0] and r[4] == 1, "no wall run on the cracked panels: Jump there is a normal jump")
	await settle(p, 20)

## Jumping off the Yard's platform lands Hard; a slam off it lands Heavy.
func _platform_landings(p: Fighter, plat: AABB) -> void:
	var levels := []
	for slam in [false, true]:
		await settle(p, 10)
		p.global_position = Vector3(plat.end.x - 0.6, plat.size.y + 0.05, 0.0)
		p.snap_facing(Vector3.RIGHT)
		await ticks(10)
		clear_events()
		p.move_input = Vector3.RIGHT * 0.5
		await ticks(8)
		p.traversal.on_jump_pressed()
		p.move_input = Vector3.ZERO
		if slam:
			await wait_until(func() -> bool: return p.velocity.y < 0.0, 120)
			p.traversal.begin_drop_strike()
		await wait_until(func() -> bool: return count_events(&"landing") > 0, 300)
		var land := last_event(&"landing")
		levels.append([land[1] if not land.is_empty() else &"-", float(land[3]) if not land.is_empty() else 0.0])
	print("  Yard platform landings: jump off %s at %.2f m/s, slam off %s at %.2f m/s, player down %s" % [
		levels[0][0], levels[0][1], levels[1][0], levels[1][1], p.is_down()])
	check(levels[0][0] == &"hard" and levels[1][0] == &"heavy", "off the Yard's platform: a jump lands Hard, a slam Heavy")
	check(not p.is_down(), "the player stays on the feet")
	await settle(p, 30)

## Walk across each patch along x, from 1 m before it to 0.1 m past it (K keeps
## clutter off the patches; the water lane stops short of the garden railing).
## Every footstep that lands inside a patch must report that patch's surface
## (the floor is read under the foot: a teleport never leaves it stale).
func _surfaces(p: Fighter) -> void:
	var water: Rect2 = yard.get_parkour_features()["water"]
	var metal: Rect2 = yard.get_parkour_features()["metal"]
	var rows := []
	var all_ok := true
	for item: Array in [[water, &"water"], [metal, &"metal"]]:
		var r: Rect2 = item[0]
		var want: StringName = item[1]
		await settle(p, 10)
		var z := r.get_center().y
		p.global_position = Vector3(r.position.x - 1.0, 0.05, z)
		p.snap_facing(Vector3.RIGHT)
		await ticks(10)
		clear_events()
		p.move_input = Vector3.RIGHT
		await wait_until(func() -> bool: return p.global_position.x >= r.end.x + 0.1, 400)
		p.move_input = Vector3.ZERO
		var inside := 0
		var right := 0
		var seen := {}
		for e in events_of(&"footstep"):
			var pos: Vector3 = e[1]
			seen[e[2]] = int(seen.get(e[2], 0)) + 1
			if r.has_point(Vector2(pos.x, pos.z)):
				inside += 1
				if e[2] == want:
					right += 1
		rows.append("%s: %d steps inside, %d report %s (all steps %s)" % [want, inside, right, want, seen])
		all_ok = all_ok and inside >= 2 and right == inside
	print("  Yard footsteps across the patches: %s" % "; ".join(rows))
	check(all_ok, "every footstep on the Yard's water and metal patches reports that surface")
	await settle(p, 10)

func _lane(lane_name: StringName) -> Dictionary:
	for l in yard.get_wall_run_lanes():
		if l["name"] == lane_name:
			return l
	return {}

func _start(pos: Vector3, facing: Vector3) -> void:
	await settle(_pl, 10)
	await place(_pl, pos, facing)
	await ticks(4)
	clear_events()

## The stairwells (YardBuilder._build_stairwells): a flight of 12 steps (0.25 m
## rise, 0.3 m run) to a 3 m landing. Each is walked up from a clear run-in in
## front of its first step, else (a partition right in front of it) stepping
## onto its first step from the side and then up the flight.
func _stairwells() -> void:
	var flights := [[Vector3(-12.6, 0.0, -16.85), Vector3.LEFT, 1.3], [Vector3(12.6, 0.0, -16.85), Vector3.RIGHT, 1.3],
		[Vector3(-16.9, 0.0, 5.0), Vector3.BACK, 1.2], [Vector3(16.9, 0.0, 5.0), Vector3.BACK, 1.2]]
	var climbed := 0
	var tried := 0
	for f: Array in flights:
		var bottom: Vector3 = f[0]
		var dir: Vector3 = f[1]
		var width: float = f[2]
		var side := dir.cross(Vector3.UP).normalized()
		# A straight run-in (the farthest clear one up to 1 m), else from the side.
		var start := Vector3.INF
		var first := Vector3.ZERO  # the first leg's direction (onto the flight)
		var how := ""
		var gap := 1.0
		while gap >= 0.34 and start == Vector3.INF:
			var at := bottom - dir * gap + Vector3.UP * 0.05
			if _capsule_clear(at) and _path_clear(at, bottom - dir * 0.31 + Vector3.UP * 0.05):
				start = at
				first = dir
				how = "straight, %.2f m before it" % gap
			gap -= 0.05
		for sgn: float in [1.0, -1.0]:
			# Beside the first step, the capsule over its near edge (a 0.3 m tread
			# is narrower than the capsule; past it the second riser is in the way).
			var at := bottom - dir * 0.05 + side * sgn * (width * 0.5 + 0.6) + Vector3.UP * 0.05
			if start == Vector3.INF and _capsule_clear(at) and _path_clear(at, at - side * sgn * 0.25):
				start = at
				first = -side * sgn
				how = "from the side"
		if start == Vector3.INF:
			print("  stairwell at (%.1f, %.1f): no way onto it, skipped" % [bottom.x, bottom.z])
			continue
		tried += 1
		await _start(start, first)
		var steps0 := count_events(&"parkour")
		_pl.move_input = first
		if first != dir:
			# Onto the first step from the side, to the flight's middle line.
			await wait_until(func() -> bool: return absf((_pl.global_position - bottom).dot(side)) < 0.1, 120)
		_pl.move_input = dir
		# Up to the landing (then stop: past it the parkour finds the floor above).
		var kinds := {}
		await wait_until(func() -> bool:
			var k := _pl.traversal.get_parkour_kind()
			if k != &"":
				kinds[k] = true
			return _pl.global_position.y >= 2.95, 180)
		_pl.move_input = Vector3.ZERO
		await ticks(10)
		var y := _pl.global_position.y
		print("  stairwell at (%.1f, %.1f) walking %s (%s): feet at y %.2f on the landing, %d parkour moves, kinds %s" % [
			bottom.x, bottom.z, dir, how, y, count_events(&"parkour") - steps0, kinds.keys()])
		if near(y, 3.0, 0.05) and kinds.keys() == [&"step"]:
			climbed += 1
	check(tried == 4 and climbed == tried, "the Yard's stairwells are climbed with step-ups (%d / %d)" % [climbed, tried])

## The player's capsule moves from `a` to `b` (feet) without touching anything.
func _path_clear(a: Vector3, b: Vector3) -> bool:
	_q.exclude = [_pl.get_rid()]
	_q.transform = Transform3D(Basis(), a + Vector3.UP * (Fighter.CAPSULE_HEIGHT * 0.5 + 0.02))
	_q.motion = b - a
	var r := get_world_3d().direct_space_state.cast_motion(_q)
	_q.motion = Vector3.ZERO
	return r.size() > 0 and r[0] >= 0.999

func _capsule_clear(feet: Vector3) -> bool:
	_q.exclude = [_pl.get_rid()]
	_q.transform = Transform3D(Basis(), feet + Vector3.UP * (Fighter.CAPSULE_HEIGHT * 0.5 + 0.02))
	return get_world_3d().direct_space_state.intersect_shape(_q, 1).is_empty()
