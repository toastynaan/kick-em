extends "res://tests/move/move_test_base.gd"
## F7 automatic parkour (Feel Reference: Automatic parkour). Checks, with
## measured numbers:
## - sprinting into a 0.9 m wall vaults it with no input, keeping >= 90% speed;
## - a 0.3 m step is stepped over at 100% speed, no animation;
## - walking into the 1.8 m platform is blocked; sprinting into it mantles up
##   (keeps 70%);
## - over 2.2 m at full speed: one wall kick-off, turning <= 120 deg, keeping 80%;
## - an enemy in the probe is never vaulted;
## - an attack in the last 40% of a vault gives a dropping strike that keeps the
##   vault speed and counts as full sprint; before that it does not;
## - mantle from the air: a jump whose hands reach within 0.5 m of a ledge
##   mantles up.

## Simulated seconds (the timeout counts fixed-fps time).
func _init() -> void:
	_timeout = 900.0

func run() -> void:
	var p := spawn_player(Vector3(0.0, 0.0, 0.0))
	await ticks(30)
	await _vault_low_wall(p)
	await _step(p)
	await _platform(p)
	await _kickoff(p)
	await _no_enemy_vault(p)
	await _vault_attack(p)
	await _vault_attack_b(p)
	await _air_mantle(p)
	done()

## Lane at x: run toward -Z from z_start; obstacle face at z_face.
func _run_at(p: Fighter, x: float, z_start: float, sprint: bool) -> void:
	await settle(p, 10)
	p.global_position = Vector3(x, 0.02, z_start)
	p.rotation.y = 0.0
	await ticks(10)
	p.move_input = Vector3.FORWARD
	if sprint:
		dash_down(p)

func _vault_low_wall(p: Fighter) -> void:
	make_wall_across(0.0, 0.9, 0.3, 4.0, 0.0)
	await _run_at(p, 0.0, 16.0, true)
	await wait_until(func() -> bool: return p.traversal.sprint_charge >= 0.999 or p.global_position.z < 4.0, 400)
	clear_events()
	var m := {"v": 0.0}
	var started := await wait_until(func() -> bool:
		if not p.traversal.is_vaulting():
			m["v"] = hspeed(p)
		return p.traversal.is_vaulting(), 240)
	var v_in: float = m["v"]
	var kind := p.traversal.get_parkour_kind()
	var t0 := TimeDirector.now()
	await wait_until(func() -> bool: return not p.traversal.is_vaulting(), 120)
	var dur := TimeDirector.now() - t0
	var v_out := hspeed(p)
	var ev := last_event(&"parkour")
	print("  0.9 m wall at %.2f m/s: %s (event %s, height %.2f) in %.3f s, out at %.2f (%.1f%%), z %.2f" % [
		v_in, kind, ev[1] if not ev.is_empty() else &"-", float(ev[3]) if not ev.is_empty() else 0.0, dur,
		v_out, v_out / maxf(v_in, 0.01) * 100.0, p.global_position.z])
	check(started and kind == &"vault", "sprinting into a 0.9 m wall vaults it with no input")
	check(v_out >= v_in * Tuning.VAULT_KEEP - 0.02, "the vault keeps %.1f%% of speed (>= 90%%)" % (v_out / maxf(v_in, 0.01) * 100.0))
	check(dur >= Tuning.VAULT_TIME.x - 0.02 and dur <= Tuning.VAULT_TIME.y + 0.02, "vault time %.3f s (0.25-0.35)" % dur)
	check(p.global_position.z < -0.3 and not p.traversal.is_airborne(), "lands beyond the wall, running")
	check(not ev.is_empty() and near(float(ev[3]), 0.9, 0.03), "parkour event logs the height")
	await settle(p, 20)
	# Walking into the low wall also vaults (over 3 m/s), keeping 90% of walking speed.
	await _run_at(p, 0.0, 6.0, false)
	await wait_until(func() -> bool: return p.traversal.is_vaulting(), 240)
	var wk := p.traversal.get_parkour_kind()
	await wait_until(func() -> bool: return not p.traversal.is_vaulting(), 120)
	print("  walking into the 0.9 m wall: %s, z %.2f" % [wk, p.global_position.z])
	check(wk == &"vault" and p.global_position.z < -0.3, "walking into a 0.9 m wall vaults it too")
	await settle(p, 20)

func _step(p: Fighter) -> void:
	make_box(Vector3(10.0, 0.15, -1.0), Vector3(4.0, 0.3, 2.0), "Step")
	await _run_at(p, 10.0, 10.0, true)
	var m := {"v": 0.0}
	await wait_until(func() -> bool:
		if p.traversal.get_parkour_kind() != &"step":
			m["v"] = hspeed(p)
		return p.traversal.get_parkour_kind() == &"step" or p.global_position.z < -2.5, 300)
	var v_in: float = m["v"]
	var kind := p.traversal.get_parkour_kind()
	await wait_until(func() -> bool: return p.traversal.get_parkour_kind() != &"step", 60)
	await ticks(2)
	print("  0.3 m step at %.2f m/s: %s, on top %.2f m, speed out %.2f" % [v_in, kind, p.global_position.y, hspeed(p)])
	check(kind == &"step", "a 0.3 m step is stepped over")
	check(p.global_position.y > 0.25, "the capsule is on the step (y %.2f)" % p.global_position.y)
	check(hspeed(p) >= v_in * 0.98, "stepping keeps 100%% speed (%.2f of %.2f)" % [hspeed(p), v_in])
	await settle(p, 20)

func _platform(p: Fighter) -> void:
	# The 1.8 m platform: deep (4 m) so a mantle ends on top.
	make_box(Vector3(20.0, 0.9, -2.0), Vector3(4.0, 1.8, 4.0), "Platform")
	await _run_at(p, 20.0, 6.0, false)
	await ticks(150)
	var walk_z := p.global_position.z
	print("  walking into the 1.8 m platform: stopped at z %.2f (face at 0.0), y %.2f, parkour %s" % [
		walk_z, p.global_position.y, last_event(&"parkour")])
	check(walk_z > 0.2 and p.global_position.y < 0.1, "walking into the 1.8 m platform is blocked")
	await settle(p, 20)
	await _run_at(p, 20.0, 14.0, true)
	var m := {"v": 0.0}
	var started := await wait_until(func() -> bool:
		if not p.traversal.is_vaulting():
			m["v"] = hspeed(p)
		return p.traversal.is_vaulting(), 300)
	var v_in: float = m["v"]
	var kind := p.traversal.get_parkour_kind()
	var t0 := TimeDirector.now()
	await wait_until(func() -> bool: return not p.traversal.is_vaulting(), 120)
	var dur := TimeDirector.now() - t0
	var v_out := hspeed(p)
	print("  sprinting into the 1.8 m platform at %.2f: %s in %.3f s, on top y %.2f, out %.2f (%.1f%%)" % [
		v_in, kind, dur, p.global_position.y, v_out, v_out / maxf(v_in, 0.01) * 100.0])
	check(started and kind == &"mantle", "sprinting into the 1.8 m platform mantles")
	check(p.global_position.y > 1.7, "the mantle ends on top of the platform")
	check(near(dur, Tuning.MANTLE_TIME, 0.02), "mantle time %.3f s (0.45)" % dur)
	check(near(v_out, v_in * Tuning.MANTLE_KEEP, 0.15), "the mantle keeps %.1f%% (70%%)" % (v_out / maxf(v_in, 0.01) * 100.0))
	await settle(p, 20)

func _kickoff(p: Fighter) -> void:
	make_box(Vector3(30.0, 2.0, -0.5), Vector3(6.0, 4.0, 1.0), "TallWall")
	await _run_at(p, 30.3, 16.0, true)
	await wait_until(func() -> bool: return p.traversal.sprint_charge >= 0.999, 400)
	var m := {"v": 0.0}
	var started := await wait_until(func() -> bool:
		if not p.traversal.is_vaulting():
			m["v"] = hspeed(p)
		return p.traversal.is_vaulting(), 300)
	var v_in: float = m["v"]
	var kind := p.traversal.get_parkour_kind()
	await wait_until(func() -> bool: return not p.traversal.is_vaulting(), 120)
	var v := p.velocity
	var turn := rad_to_deg(absf(angle_difference(atan2(0.0, 1.0), atan2(-v.x, -v.z))))
	var v_out := Vector2(v.x, v.z).length()
	print("  full speed into a 4 m wall at %.2f: %s, turned %.1f deg, out %.2f (%.1f%%), vy %.2f" % [
		v_in, kind, turn, v_out, v_out / maxf(v_in, 0.01) * 100.0, v.y])
	check(started and kind == &"kickoff", "a wall over 2.2 m at full speed gives a wall kick-off")
	check(turn <= Tuning.KICKOFF_TURN + 0.5 and turn >= 60.0, "the kick-off turns %.1f deg (<= 120)" % turn)
	check(near(v_out, v_in * Tuning.KICKOFF_KEEP, 0.15), "the kick-off keeps %.1f%% (80%%)" % (v_out / maxf(v_in, 0.01) * 100.0))
	await wait_until(func() -> bool: return not p.traversal.is_airborne(), 240)
	check(not p.is_down(), "the kick-off lands on the feet")
	await settle(p, 20)
	# Not at full speed (a fresh dash: its opening burst runs at the cap but
	# is not earned speed): the tall wall is just a wall.
	await _run_at(p, 30.3, 3.0, true)
	clear_events()
	var m2 := {"earned": 0.0}
	for i in 90:
		m2["earned"] = maxf(float(m2["earned"]), p.traversal.speed_toward(Vector3.FORWARD))
		await get_tree().physics_frame
	print("  part speed into the 4 m wall (earned up to %.2f, full speed from %.2f): parkour events %d, z %.2f" % [
		m2["earned"], p.traversal.get_speed_cap() * 0.9, count_events(&"parkour"), p.global_position.z])
	check(count_events(&"parkour") == 0 and p.global_position.z > 0.0, "below full speed a tall wall blocks")
	await settle(p, 20)

func _no_enemy_vault(p: Fighter) -> void:
	# A crouching-height obstacle with a grunt right in front of it: never vault the grunt.
	var g := spawn_enemy(&"grunt", Vector3(40.0, 0.0, 0.0))
	await ticks(10)
	clear_events()
	await _run_at(p, 40.0, 12.0, true)
	await wait_until(func() -> bool: return p.global_position.z < 1.2 or p.traversal.is_vaulting(), 300)
	await ticks(30)
	print("  sprint at a grunt: parkour events %d" % count_events(&"parkour"))
	check(count_events(&"parkour") == 0, "an enemy in the probe is a target, not an obstacle")
	await settle(p, 20)
	g.queue_free()
	await ticks(2)

func _vault_attack(p: Fighter) -> void:
	make_wall_across(0.0, 0.9, 0.3, 4.0, 50.0)
	# Early in the vault: no dropping strike.
	await _run_at(p, 50.0, 14.0, true)
	await wait_until(func() -> bool: return p.traversal.is_vaulting(), 300)
	await wait_until(func() -> bool: return p.traversal.get_vault_progress() >= 0.3, 60)
	var early := p.traversal.begin_drop_strike()
	await wait_until(func() -> bool: return not p.traversal.is_vaulting(), 120)
	check(not early, "an attack in the first 60% of a vault is not a dropping strike")
	await settle(p, 20)
	# Late in the vault: a dropping strike that keeps the vault speed.
	await _run_at(p, 50.0, 14.0, true)
	var m := {"v": 0.0}
	await wait_until(func() -> bool:
		if not p.traversal.is_vaulting():
			m["v"] = hspeed(p)
		return p.traversal.is_vaulting(), 300)
	var v_in: float = m["v"]
	await wait_until(func() -> bool: return p.traversal.get_vault_progress() >= Tuning.VAULT_ATTACK_FROM, 60)
	var prog := p.traversal.get_vault_progress()
	var cap_speed := p.traversal.speed_toward(Vector3.FORWARD)
	var ok := p.traversal.begin_drop_strike()
	var dropping := p.traversal.is_drop_striking()
	var st := p.traversal.speed_toward(Vector3.FORWARD)
	p.traversal.on_strike_started(true)
	# Over a thin wall the drop waits until the body has cleared the far side.
	await wait_until(func() -> bool: return not p.traversal.is_vaulting(), 60)
	var h_after := hspeed(p)
	var clear_z := p.global_position.z
	await wait_until(func() -> bool: return not p.traversal.is_airborne(), 120)
	var land := last_event(&"landing")
	print("  attack at %.0f%% of a vault at %.2f m/s: drop strike %s, plunges at z %.2f (wall's far face -0.30) with horizontal %.2f (%.1f%%), speed_toward %.2f / %.2f (cap %.1f), lands %s on y %.2f" % [
		prog * 100.0, v_in, ok, clear_z, h_after, h_after / maxf(v_in, 0.01) * 100.0, cap_speed, st, p.traversal.get_speed_cap(),
		land[1] if not land.is_empty() else &"-", p.global_position.y])
	check(ok and dropping, "an attack in the last 40% of a vault gives a dropping strike")
	check(h_after >= v_in * Tuning.VAULT_KEEP - 0.05, "the dropping strike inherits the vault speed (%.2f)" % h_after)
	check(not land.is_empty() and p.global_position.y < 0.1, "the dropping strike lands on the floor beyond the wall, not on its top")
	check(near(st, p.traversal.get_speed_cap(), 0.01), "a sprint vault's dropping strike counts as full sprint (%.2f)" % st)
	await settle(p, 20)

## With B's real attack press: a punch in the vault's last 40% is B's dropping
## strike; a punch before that is not (B: a normal strike once landed).
func _vault_attack_b(p: Fighter) -> void:
	for late in [true, false]:
		await _run_at(p, 50.0, 14.0, true)
		await wait_until(func() -> bool: return p.traversal.is_vaulting(), 300)
		var at := Tuning.VAULT_ATTACK_FROM + 0.05 if late else 0.3
		await wait_until(func() -> bool: return p.traversal.get_vault_progress() >= at, 60)
		var prog := p.traversal.get_vault_progress()
		p.combat.press(CombatController.Action.LIGHT)
		p.combat.release(CombatController.Action.LIGHT)
		await ticks(2)
		var move := p.combat.current_move_id()
		var dropping := p.traversal.is_drop_striking()
		# An early press waits for the floor and then fires as a normal strike.
		var m := {"after": &""}
		await wait_until(func() -> bool:
			if not p.traversal.is_vaulting() and not p.traversal.is_airborne() and p.combat.current_move_id() != &"":
				m["after"] = p.combat.current_move_id()
			return m["after"] != &"" or (not p.combat.is_attacking() and not p.traversal.is_vaulting()
				and not p.traversal.is_airborne() and late), 240)
		await wait_until(func() -> bool: return not p.combat.is_attacking() and not p.traversal.is_airborne() \
			and not p.traversal.is_vaulting(), 300)
		print("  B: punch pressed at %.0f%% of a vault: dropping strike %s (move %s), strike after landing %s" % [
			prog * 100.0, dropping, move, m["after"]])
		if late:
			check(dropping and move == &"drop_strike", "with B's strikes, an attack in a vault's last 40% is a dropping strike")
		else:
			check(not dropping and move != &"drop_strike", "an attack early in a vault is not a dropping strike")
			check(m["after"] != &"" and m["after"] != &"drop_strike",
				"...it fires as a normal strike once on the ground (%s)" % m["after"])
		await settle(p, 20)

func _air_mantle(p: Fighter) -> void:
	# A 2.4 m ledge (too tall to mantle running): a running jump at it reaches
	# within 0.5 m with the hands and mantles up from the air.
	make_box(Vector3(60.0, 1.2, -2.0), Vector3(4.0, 2.4, 4.0), "Ledge")
	await _run_at(p, 60.0, 4.0, false)
	await wait_until(func() -> bool: return p.global_position.z < 1.6, 200)
	clear_events()
	p.traversal.on_jump_pressed()
	var mantled := await wait_until(func() -> bool: return p.traversal.get_parkour_kind() == &"air_mantle", 120)
	await wait_until(func() -> bool: return not p.traversal.is_vaulting() and not p.traversal.is_airborne(), 120)
	print("  running jump at a 2.4 m ledge: air mantle %s, y %.2f" % [mantled, p.global_position.y])
	check(mantled and p.global_position.y > 2.3, "hands within 0.5 m of a ledge top during a jump: mantle up")
	await settle(p, 20)
