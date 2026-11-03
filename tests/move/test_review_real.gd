extends "res://tests/move/move_test_base.gd"
## The spec-accuracy review fixes, through the real game path: the real
## player (PlayerController reading Input actions) with B's real strikes.
## Measured numbers printed for each:
## 1. a sprint vaults a 0.9 m wall and mantles the 1.8 m platform without
##    stopping; an attack in the last 40% of a vault is a dropping strike
##    (Round 7 has no charge button: the old "sprinting charge" is gone);
## 2. Round 7: the press dodges first; held, the dodge hands off to the sprint
##    ramp at its speed (6-6.3 m/s), never slowing after the hand-off, the cap at
##    1.2 s; a tap is the 2.5 m dodge (the dodge itself: test_dodge);
## 3. a grunt 0.45 / 0.7 / 1.0 m behind a 0.9 m wall never turns the vault
##    into a dead stop;
## 5. a wall run needs a sprint (Dash released 0.05 s before Jump: a jump);
## 6. a 180-degree reversal pays one turn penalty (30%);
## 7. a body in the chest / head probes (an enemy on a crate) is a target; an
##    overhang over a low wall stops a vault;
## J. a jab thrown from a full sprint is flagged as a sprint strike (HitInfo.sprint),
##    a standing one is not (Round 7: sprinting adds no power; B owns the hit).
## 4. at the 10 m/s cap a facade of separate panels is one wall: no second run
##    on its next panel before the floor (also checked in the real Yard: test_yard_moves).

const STEER20 := 0.364  ## move_right strength that, with move_forward, is ~20 degrees off -Z

var p: Fighter

func _init() -> void:
	_timeout = 900.0

func run() -> void:
	p = spawn_real_player(Vector3(0.0, 0.02, 30.0))
	await ticks(30)
	check(p.brain is PlayerController, "the real PlayerController drives the player")
	await _burst_shape()
	await _tap_distance()
	await _sprint_parkour()
	await _vault_attack_drop()
	await _enemy_behind_wall()
	await _wall_run_needs_sprint()
	await _panel_facade_cooldown()
	await _reversal()
	await _probe_targets()
	await _jab_power()
	done()

func _reset(pos: Vector3, facing := Vector3.FORWARD) -> void:
	release_all_input()
	await ticks(4)
	await settle(p, 20)
	p.global_position = pos
	p.snap_facing(facing)
	p.velocity = Vector3.ZERO
	await ticks(8)

# --- 2. the sprint's opening ---------------------------------------------------------
func _burst_shape() -> void:
	await _reset(Vector3(0.0, 0.02, 60.0))
	clear_events()
	var cap := p.traversal.get_speed_cap()
	hold(&"move_forward")
	hold(&"dash")
	var t0 := TimeDirector.now()
	var top := 0.0
	var at_hand := -1.0
	var dips := 0
	var prev := -1.0
	var t_cap := -1.0
	var started := false
	var samples := []
	for i in 180:
		await get_tree().physics_frame
		var t := TimeDirector.now() - t0
		var v := hspeed(p)
		top = maxf(top, v)
		if not started and p.traversal.is_sprinting():
			started = true
			at_hand = v
			samples.append("hand-off %.3f s %.2f" % [t, v])
		elif started:
			if v < prev - 1e-3:
				dips += 1
			if t_cap < 0.0 and v >= cap * 0.99:
				t_cap = t
		if i in [1, 6, 12, 18, 36, 72, 108, 144]:
			samples.append("%.3f s %.2f" % [t, v])
		prev = v
	let_go(&"dash")
	let_go(&"move_forward")
	print("  [2] held Dash: %s; top %.2f (cap %.1f); after the hand-off speed fell %d times; 99%% of the cap at %.3f s" % [
		", ".join(samples), top, cap, dips, t_cap])
	check(near(at_hand, Tuning.SPRINT_START_SPEED, 0.35) and count_events(&"dodged") == 1,
		"the press dodges, then hands off to the sprint ramp at %.2f m/s (6-6.3)" % at_hand)
	check(dips == 0, "after the hand-off the speed never drops in a straight line")
	check(near(t_cap, Tuning.SPRINT_RAMP_TIME, 0.1), "a held Dash reaches the cap in %.3f s (1.2 +- 0.1)" % t_cap)

func _tap_distance() -> void:
	await _reset(Vector3(0.0, 0.02, 60.0))
	var x0 := p.global_position
	var top := 0.0
	hold(&"dash")
	await ticks(6)  # 50 ms: a tap
	let_go(&"dash")
	for i in 120:
		await get_tree().physics_frame
		top = maxf(top, hspeed(p))
	var d := Vector2(p.global_position.x - x0.x, p.global_position.z - x0.z).length()
	print("  [2] Dash tap, stick neutral: %.3f m, top %.2f m/s, sprinting %s" % [d, top, p.traversal.is_sprinting()])
	check(near(d, Tuning.R7_DODGE_DIST, 0.2) and not p.traversal.is_sprinting(),
		"a Dash tap is the dodge: %.2f m (2.5 +- 0.2), no sprint" % d)

# --- 1. a sprint does not stop for parkour --------------------------------------
func _sprint_parkour() -> void:
	make_wall_across(0.0, 0.9, 0.3, 4.0, 20.0)
	make_box(Vector3(20.0, 0.9, -7.0), Vector3(4.0, 1.8, 6.0), "PlatformCharge")  # face at z -4
	await _reset(Vector3(20.0, 0.02, 14.0))
	hold(&"move_forward")
	hold(&"dash")
	await wait_until(func() -> bool: return p.traversal.sprint_charge >= 0.999, 300)
	await wait_until(func() -> bool: return p.global_position.z <= 4.0, 120)
	var v_in := hspeed(p)
	clear_events()
	var m := {"lo": INF, "kinds": []}
	await wait_until(func() -> bool:
		if not p.traversal.is_vaulting():
			m["lo"] = minf(float(m["lo"]), hspeed(p))
		var k := p.traversal.get_parkour_kind()
		if k != &"" and not (m["kinds"] as Array).has(k):
			(m["kinds"] as Array).append(k)
		return p.global_position.y > 1.7 and not p.traversal.is_vaulting(), 240)
	var v_out := hspeed(p)
	let_go(&"dash")
	let_go(&"move_forward")
	print("  [1] sprint at %.2f m/s: parkour %s, lowest speed off the curves %.2f, on the platform y %.2f, out %.2f" % [
		v_in, m["kinds"], m["lo"], p.global_position.y, v_out])
	check((m["kinds"] as Array).has(&"vault") and (m["kinds"] as Array).has(&"mantle"),
		"a sprint vaults the 0.9 m wall and mantles the 1.8 m platform")
	check(float(m["lo"]) >= v_in * Tuning.VAULT_KEEP * Tuning.MANTLE_KEEP - 0.05,
		"it never stops: lowest %.2f m/s (vault 90%% x mantle 70%% of %.2f = %.2f)" % [m["lo"], v_in,
		v_in * Tuning.VAULT_KEEP * Tuning.MANTLE_KEEP])
	await settle(p, 20)

func _vault_attack_drop() -> void:
	make_wall_across(0.0, 0.9, 0.3, 4.0, 30.0)
	await _reset(Vector3(30.0, 0.02, 14.0))
	hold(&"move_forward")
	hold(&"dash")
	await wait_until(func() -> bool: return p.traversal.sprint_charge >= 0.999, 300)
	await wait_until(func() -> bool: return p.traversal.is_vaulting(), 120)
	await wait_until(func() -> bool: return p.traversal.get_vault_progress() >= 0.7, 60)
	var prog := p.traversal.get_vault_progress()
	await tap(&"punch", 2)
	var move := p.combat.current_move_id()
	var dropping := p.traversal.is_drop_striking()
	let_go(&"dash")
	let_go(&"move_forward")
	await wait_until(func() -> bool: return not p.traversal.is_airborne() and not p.traversal.is_vaulting(), 240)
	print("  [1] punch at %.0f%% of the vault: B's move %s, dropping strike (movement) %s, lands at y %.2f" % [
		prog * 100.0, move, dropping, p.global_position.y])
	check(dropping, "an attack in the last 40% of a vault ends it in a dropping strike (the plunge)")
	await wait_until(func() -> bool: return not p.combat.is_attacking(), 240)

# --- 3. a grunt behind the wall -----------------------------------------------------
func _enemy_behind_wall() -> void:
	for d: float in [0.45, 0.7, 1.0]:
		var x := 40.0 + d * 20.0
		make_wall_across(0.0, 0.9, 0.3, 4.0, x)
		var g := spawn_enemy(&"grunt", Vector3(x, 0.0, -0.3 - d), Vector3.BACK)
		await _reset(Vector3(x, 0.02, 14.0))
		hold(&"move_forward")
		hold(&"dash")
		clear_events()
		var m := {"lo": INF, "v": 0.0}
		var vaulted := await wait_until(func() -> bool:
			if not p.traversal.is_vaulting():
				var v := hspeed(p)
				if p.global_position.z < 6.0:
					m["lo"] = minf(float(m["lo"]), v)
				m["v"] = v
			return p.traversal.is_vaulting(), 400)
		var v_in: float = m["v"]
		await wait_until(func() -> bool: return not p.traversal.is_vaulting(), 120)
		var kind := p.traversal.last_vault_landing
		var z_land := p.global_position.z
		var v_out := hspeed(p)
		await ticks(30)
		let_go(&"dash")
		let_go(&"move_forward")
		var stopped_at_face := not vaulted and p.global_position.z > 0.0
		print("  [3] grunt %.2f m behind a 0.9 m wall: vaulted %s (%s landing) at %.2f m/s, lowest before %.2f, lands z %.2f, out %.2f, rams %d, player down %s" % [
			d, vaulted, kind, v_in, m["lo"], z_land, v_out, count_events(&"rammed"), p.is_down()])
		check(vaulted and not stopped_at_face and z_land < -0.3,
			"a grunt %.2f m behind the wall: the vault still happens (%s)" % [d, kind])
		check(float(m["lo"]) >= Tuning.SPRINT_START_SPEED, "no dead stop at the face (lowest %.2f m/s)" % m["lo"])
		await settle(p, 60)
		g.queue_free()
		await ticks(2)

# --- 5. a wall run needs a sprint ------------------------------------------------------
func _wall_run_needs_sprint() -> void:
	make_runnable_wall(101.2, 0.0, -12.0, 4.0, 0.4)
	await _reset(Vector3(100.3, 0.02, 14.0))
	hold(&"move_forward")
	hold(&"dash")
	await wait_until(func() -> bool: return p.global_position.z <= 0.2 and p.traversal.sprint_charge >= 0.65, 400)
	hold(&"move_right", STEER20)
	await wait_until(func() -> bool: return p.global_position.z <= -0.8, 60)
	let_go(&"dash")
	await ticks(6)  # 0.05 s
	var charge := p.traversal.sprint_charge
	clear_events()
	await tap(&"jump")
	var ran := count_events(&"wall_run_started") > 0
	var jumped := count_events(&"jumped") > 0
	release_all_input()
	print("  [5] Dash released 0.05 s before Jump (sprint_charge %.2f, sprinting %s): wall run %s, jumped %s" % [
		charge, p.traversal.is_sprinting(), ran, jumped])
	check(charge >= Tuning.WALLRUN_MIN_CHARGE and not ran and jumped, "without a sprint, Jump by the wall is a jump")
	await wait_until(func() -> bool: return not p.traversal.is_airborne(), 240)
	# With the sprint held it runs (same approach).
	await _reset(Vector3(100.3, 0.02, 14.0))
	hold(&"move_forward")
	hold(&"dash")
	await wait_until(func() -> bool: return p.global_position.z <= 0.2 and p.traversal.sprint_charge >= 0.65, 400)
	hold(&"move_right", STEER20)
	await wait_until(func() -> bool: return p.global_position.z <= -0.8, 60)
	clear_events()
	await tap(&"jump")
	var ran2 := count_events(&"wall_run_started") > 0
	release_all_input()
	print("  [5] the same with Dash held: wall run %s" % ran2)
	check(ran2, "with the sprint held, Jump by the wall starts a wall run")
	await wait_until(func() -> bool: return not p.traversal.is_wall_running() and not p.traversal.is_airborne(), 300)

# --- 4. one facade, one run -----------------------------------------------------------------
func _panel_facade_cooldown() -> void:
	for i in 6:  # six separate 3 m panels in one plane (face at x 121)
		var b := make_box(Vector3(121.2, 2.0, -1.5 - 3.0 * i), Vector3(0.4, 4.0, 3.0), "Panel%d" % i)
		b.add_to_group(&"runnable")
	Tuning.debug_speed_cap = 10.0
	await _reset(Vector3(120.3, 0.02, 16.0))
	hold(&"move_forward")
	hold(&"dash")
	await wait_until(func() -> bool: return p.global_position.z <= 0.2, 400)
	hold(&"move_right", STEER20)
	await wait_until(func() -> bool: return p.global_position.z <= -0.8, 60)
	clear_events()
	var v0 := hspeed(p)
	await tap(&"jump")
	var first: Node = last_event(&"wall_run_started")[1] if count_events(&"wall_run_started") > 0 else null
	await wait_until(func() -> bool: return not p.traversal.is_wall_running(), 200)
	var ended := last_event(&"wall_run_ended")
	var z_end := p.global_position.z
	await tap(&"jump")  # still in the air, next to the next panel of the same facade
	await ticks(2)
	var runs := count_events(&"wall_run_started")
	release_all_input()
	await wait_until(func() -> bool: return not p.traversal.is_airborne() and not p.traversal.is_wall_running(), 300)
	Tuning.debug_speed_cap = 8.0
	print("  [4] cap 10, panel facade: run from %.2f m/s on %s, ended %s at z %.2f (panel %d); Jump again before landing: runs %d" % [
		v0, first.name if first else &"-", ended[1] if not ended.is_empty() else &"-", z_end, int(-z_end / 3.0), runs])
	check(first != null and runs == 1, "a facade of separate panels is one wall: no second run before touching the floor")
	await settle(p, 30)

# --- 6. one turn, one penalty -----------------------------------------------------------
func _reversal() -> void:
	await _reset(Vector3(-40.0, 0.02, 60.0))
	hold(&"move_forward")
	hold(&"dash")
	await wait_until(func() -> bool: return p.traversal.sprint_charge >= 0.999, 300)
	await ticks(10)
	var before := hspeed(p)
	var n0 := p.traversal.turn_penalties
	let_go(&"move_forward")
	hold(&"move_back")
	var lo := INF
	for i in 50:
		await get_tree().physics_frame
		lo = minf(lo, hspeed(p))
	release_all_input()
	var drop := 1.0 - lo / before
	print("  [6] 180-degree reversal at %.2f m/s: penalties %d, lowest %.2f (lost %.1f%%)" % [
		before, p.traversal.turn_penalties - n0, lo, drop * 100.0])
	check(p.traversal.turn_penalties - n0 == 1 and near(drop, Tuning.TURN_PENALTY, 0.02),
		"a 180-degree reversal pays one penalty (%.1f%%)" % (drop * 100.0))

# --- 7. the three probes -----------------------------------------------------------------
func _probe_targets() -> void:
	# An enemy standing on a 1.1 m crate: only the chest / head probes see him.
	make_box(Vector3(-60.0, 0.55, -0.55), Vector3(1.1, 1.1, 1.1), "CrateWithEnemy")
	var g := spawn_enemy(&"grunt", Vector3(-60.0, 1.15, -0.55), Vector3.BACK)
	await ticks(30)
	await _reset(Vector3(-60.0, 0.02, 12.0))
	clear_events()
	hold(&"move_forward")
	hold(&"dash")
	await wait_until(func() -> bool: return p.global_position.z < 0.8, 300)
	await ticks(40)
	release_all_input()
	var on_crate := g.global_position.y > 0.9
	print("  [7] sprint at a crate with a grunt on it (grunt still on top %s): parkour events %d" % [on_crate, count_events(&"parkour")])
	check(on_crate and count_events(&"parkour") == 0, "a body in the chest / head probes is a target: no vault")
	g.queue_free()
	# A beam over a 0.9 m wall (an overhang the head probe meets).
	make_wall_across(0.0, 0.9, 0.3, 4.0, -70.0)
	make_box(Vector3(-70.0, 1.7, -0.35), Vector3(4.0, 0.3, 0.5), "Beam")  # a window head set back 0.1 m over the sill
	await _reset(Vector3(-70.0, 0.02, 12.0))
	clear_events()
	hold(&"move_forward")
	hold(&"dash")
	await wait_until(func() -> bool: return p.global_position.z < 0.8, 300)
	await ticks(40)
	release_all_input()
	print("  [7] sprint at a 0.9 m wall under a beam at 1.55-1.85 m: parkour events %d, z %.2f" % [count_events(&"parkour"), p.global_position.z])
	check(count_events(&"parkour") == 0, "an overhang over a low wall: no vault")
	await settle(p, 20)

# --- J. a standing jab is a standing jab ------------------------------------------------
func _jab_power() -> void:
	for sprint in [false, true]:
		var z0 := 80.0 if not sprint else 95.0
		var g := spawn_enemy(&"grunt", Vector3(-80.0, 0.0, z0 - 1.6 if not sprint else z0 - 14.0), Vector3.BACK)
		await ticks(20)
		await _reset(Vector3(-80.0, 0.02, z0))
		clear_events()
		if sprint:
			hold(&"move_forward")
			hold(&"dash")
			await wait_until(func() -> bool:
				return p.global_position.z - g.global_position.z <= 2.2, 400)
		var charge := p.traversal.sprint_charge
		await tap(&"punch", 11)  # ~90 ms
		await wait_until(func() -> bool: return count_events(&"hit_landed") > 0, 60)
		release_all_input()
		var info: HitInfo = null
		for e in events_of(&"hit_landed"):
			var hi := e[0] as HitInfo
			if hi != null and hi.attacker == p and hi.victim == g:
				info = hi
		print("  [J] %s jab (sprint_charge %.2f): P %.2f, tier %s, sprint %s" % [
			"full-sprint" if sprint else "standing (1.6 m)", charge, info.power if info else -1.0,
			HitInfo.tier_name(info.tier) if info else &"-", info.sprint if info else false])
		if not sprint:
			check(info != null and not info.sprint, "a standing jab is not a sprint strike")
		else:
			check(info != null and info.sprint and charge >= 0.99, "a jab from a full sprint is flagged as a sprint strike")
		await wait_until(func() -> bool: return not p.combat.is_attacking(), 240)
		await ticks(60)
		g.queue_free()
		await ticks(2)
