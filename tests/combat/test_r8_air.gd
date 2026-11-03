extends "res://tests/combat/combat_test_base.gd"
## Round 8 acceptance check 7 (docs/Round 8 — Charge and Pressure.md: Air
## combo), through the real input path (Input.action_press -> PlayerController
## -> CombatController; H's Jump -> M's Traversal.start_air_follow; H's
## Fighter.air_hang):
## - a full-charge uppercut (E held until it fires itself) lifts a grunt
##   2.5 m +-0.15; get_air_follow_target() is that body inside
##   R8_AIR_FOLLOW_WINDOW;
## - Jump follows: the player leaps to the body's height (air_follow_started);
## - air strikes: 4 punches each hang the player and the body R8_AIR_HANG
##   (+-0.05 s), the 5th does not (both fall); air_hit counts 1..5, HitInfo.air,
##   get_air_hits(), never charged;
## - an air roundhouse launches the body at R8_AIR_KICK_LAUNCH (+-0.5 m/s) (a
##   level-3 grunt, so the uppercut does not break it open; on a broken one
##   x R8_BREAK_PUSH_MULT, cap LAUNCH_SPEED_MAX);
## - an air punch with the stick pulled back spikes it (react &"spike",
##   straight down at R7_SPIKE_SPEED).

const HANG_TOL := 0.05
const STILL := 1e-4   ## m per tick: still hanging (a hang holds the capsule exactly)

var _p: Fighter
var _x := 0.0

func _init() -> void:
	_timeout = 150.0

func run() -> void:
	_p = spawn_player(Vector3.ZERO)
	await ticks(20)

	print("a full-charge uppercut lifts 2.5 m")
	var g: Fighter = await _grunt()
	var up := await _uppercut(g)
	var follow_t := _p.combat.get_air_follow_target()
	var peak := 0.0
	while g.is_lifted() and not g.is_down():
		peak = maxf(peak, g.get_lift_height())
		await get_tree().physics_frame
	print("DATA full-charge uppercut: c %.2f, react %s, lift %.2f m planned, peak %.2f m (want %.2f); follow target %s" % [
		up.charge if up else -1.0, up.react if up else &"-", up.lift_height if up else 0.0, peak,
		Tuning.R8_MOVES[&"uppercut"]["charged"]["lift"].y, follow_t == g])
	check(up != null and up.charged and is_equal_approx(up.charge, 1.0) and up.react == &"lift", "the charged uppercut at c = 1 lifts")
	check(absf(peak - 2.5) <= 0.15, "it lifts 2.5 m +-0.15 (%.2f)" % peak)
	check(follow_t == g, "get_air_follow_target() is the lifted grunt")
	await _land_and_clear(g)

	print("Jump follows; 4 air punches hang, the 5th does not")
	g = await _grunt()
	up = await _uppercut(g)
	var jumped := await _follow(g)
	var follow_ok: bool = jumped["ok"]
	print("DATA launcher jump: started %s, the player's chest %.2f m from the body's chest height at the end of the leap (%.3f s)" % [
		follow_ok, jumped["dy"], jumped["t"]])
	check(follow_ok and absf(float(jumped["dy"])) <= 0.35, "Jump follows to the body's height")
	var hangs: Array = []
	var ids: Array = []
	for i in 5:
		var r: Dictionary = await _air_press(&"punch", g)
		hangs.append(r)
		ids.append(r["id"])
		if not r["hit"]:
			break
	var hits := events_of(&"air_hit").filter(func(e: Array) -> bool: return e[1] == _p)
	print("DATA air strikes %s; [body hang s, player hang s]: %s; air_hit counts %s; get_air_hits %d" % [ids,
		hangs.map(func(r: Dictionary) -> String: return "[%.3f, %.3f]" % [r["body"], r["player"]]),
		hits.map(func(e: Array) -> int: return e[3]), _p.combat.get_air_hits()])
	var all_air := hits_on(g).slice(1).all(func(h: HitInfo) -> bool: return h.air and not h.charged)
	check(hangs.size() == 5 and hangs.all(func(r: Dictionary) -> bool: return r["hit"]), "5 air strikes landed")
	if hangs.size() == 5:
		for i in 4:
			check(absf(float(hangs[i]["body"]) - Tuning.R8_AIR_HANG) <= HANG_TOL
				and absf(float(hangs[i]["player"]) - Tuning.R8_AIR_HANG) <= HANG_TOL,
				"air hit %d: the body and the player hang %.2f s from the hit (%.3f, %.3f)" % [i + 1, Tuning.R8_AIR_HANG,
				hangs[i]["body"], hangs[i]["player"]])
		var stop := float(hangs[4]["hitstop"]) + 2.0 / 120.0
		check(float(hangs[4]["body"]) <= stop and float(hangs[4]["player"]) <= stop,
			"the 5th does not hang: both fall once its hitstop (%.2f s) is over" % float(hangs[4]["hitstop"]))
	check(hits.size() == hangs.size() and hits.map(func(e: Array) -> int: return e[3]) == range(1, hits.size() + 1),
		"air_hit counts 1, 2, 3...")
	check(all_air, "every air strike is HitInfo.air and never charged")
	await _land_and_clear(g)
	await wait_until(func() -> bool: return _p.combat.get_air_hits() == 0, 2.0)
	check(_p.combat.get_air_hits() == 0, "get_air_hits() is 0 once the player has landed")

	print("an air roundhouse launches at R8_AIR_KICK_LAUNCH")
	var info: HitInfo = null
	for lv in [3, 1]:
		g = await _grunt()
		g.level = lv  # level 3 (capacity 8): the uppercut does not break it open
		await _uppercut(g)
		await _follow(g)
		var rk: Dictionary = await _air_press(&"roundhouse", g, true)
		info = rk["info"]
		var want := minf(Tuning.R8_AIR_KICK_LAUNCH * (Tuning.R8_BREAK_PUSH_MULT if info != null and info.broken_bonus else 1.0),
			Tuning.LAUNCH_SPEED_MAX)
		print("DATA air roundhouse on a level-%d grunt (broken %s): react %s, HitInfo %.2f m/s at %.1f deg, the body flies at %.2f m/s (want %.1f)" % [
			lv, info.broken_bonus if info else false, info.react if info else &"-", info.launch_velocity.length() if info else 0.0,
			rad_to_deg(atan2(info.launch_velocity.y, Vector2(info.launch_velocity.x, info.launch_velocity.z).length())) if info else 0.0,
			rk["speed"], want])
		if lv == 3:
			check(info != null and info.air and info.react == &"launch" and not info.broken_bonus
				and absf(float(rk["speed"]) - Tuning.R8_AIR_KICK_LAUNCH) <= 0.5,
				"the air roundhouse launches the body at %.0f m/s" % Tuning.R8_AIR_KICK_LAUNCH)
		else:
			check(info != null and info.broken_bonus and absf(float(rk["speed"]) - want) <= 0.5,
				"on a body broken open by the uppercut: x%.1f (cap %.0f m/s)" % [Tuning.R8_BREAK_PUSH_MULT, Tuning.LAUNCH_SPEED_MAX])
		await _land_and_clear(g)

	print("an air punch with the stick pulled back spikes")
	g = await _grunt()
	await _uppercut(g)
	await _follow(g)
	Input.action_press(&"move_back")
	var rs: Dictionary = await _air_press(&"punch", g, true)
	Input.action_release(&"move_back")
	info = rs["info"]
	print("DATA air spike: react %s, HitInfo velocity %s (%.2f m/s), the body's velocity %s" % [info.react if info else &"-",
		info.launch_velocity if info else Vector3.ZERO, info.launch_velocity.length() if info else 0.0, rs["vel"]])
	check(info != null and info.air and info.react == &"spike" and (rs["vel"] as Vector3).y < -0.8 * Tuning.R7_SPIKE_SPEED,
		"the stick pulled back: a spike straight down")
	release_inputs()
	done()

## A grunt dummy 1.0 m in front of the player on fresh ground.
func _grunt() -> Fighter:
	release_inputs()
	await wait_until(func() -> bool: return not _p.combat.is_attacking() and _p.can_act() and not _p.is_airborne(), 3.0)
	_x += 20.0
	_p.teleport_to(Vector3(_x, 0, 0), Vector3.FORWARD)
	var g := spawn(&"grunt", Vector3(_x, 0, -1.0), Vector3.BACK)
	await ticks(15)
	clear_events()
	return g

## Hold E until the uppercut fires itself at full; its HitInfo once it lands.
func _uppercut(g: Fighter) -> HitInfo:
	Input.action_press(&"uppercut")
	await wait_until(func() -> bool: return not hits_on(g).is_empty(), 2.5)
	Input.action_release(&"uppercut")
	return hits_on(g)[0] if not hits_on(g).is_empty() else null

## Jump once the uppercut's active frames are over; {ok, dy (chest heights at
## the leap's end), t (s the leap took)}.
func _follow(g: Fighter) -> Dictionary:
	await wait_until(func() -> bool: return not _p.combat.is_attack_active() and not _p.is_frozen(), 1.0)
	var tgt := _p.combat.get_air_follow_target()
	var t0 := TimeDirector.now()
	await tap_input(&"jump", 1.0 / 60.0)
	var started := await wait_until(func() -> bool: return not events_of(&"air_follow_started").is_empty(), 0.3)
	await wait_until(func() -> bool: return not _p.traversal.is_air_following(), 1.0)
	var dy := (_p.global_position.y + 1.3) - (g.global_position.y + 1.3 * g.get_height_scale())
	return {"ok": started and tgt == g, "dy": dy, "t": TimeDirector.now() - t0}

## Press `btn` in the air (a tap), wait for its hit on `g`; then how long the
## body and the player stay still after it ({hit, id, body, player}), or the
## launch ({info, speed, vel}).
func _air_press(btn: StringName, g: Fighter, launch := false) -> Dictionary:
	var n := hits_on(g).size()
	var ids := [&""]
	var cb := func(id: StringName) -> void: ids[0] = id
	_p.combat.attack_started.connect(cb)
	await tap_input(btn, 1.0 / 60.0)
	var hit := await wait_until(func() -> bool: return hits_on(g).size() > n, 0.6)
	_p.combat.attack_started.disconnect(cb)
	var info: HitInfo = hits_on(g)[-1] if hit else null
	if launch:
		await wait_until(func() -> bool: return not g.is_frozen(), 0.5)
		var speed := 0.0
		var vel := Vector3.ZERO
		for i in 4:
			await get_tree().physics_frame
			var v := g.get_com_velocity()
			if v.length() > speed:
				speed = v.length()
				vel = v
		return {"info": info, "speed": speed, "vel": vel, "hit": hit}
	# How long each stays still from the hit (its hitstop included): the first
	# tick it moves ends the hang one tick earlier.
	var t_hit := first_time(&"hit_landed")
	for e in events:
		if e[0] == &"hit_landed" and (e[1] as HitInfo) == info:
			t_hit = float(e[6])
	var body := -1.0
	var player := -1.0
	var by := g.global_position.y
	var py := _p.global_position.y
	while TimeDirector.now() - t_hit < 1.0 and (body < 0.0 or player < 0.0):
		await get_tree().physics_frame
		if body < 0.0 and (absf(g.global_position.y - by) > STILL or not g.is_lifted()):
			body = TimeDirector.now() - t_hit - 1.0 / 120.0
		if player < 0.0 and absf(_p.global_position.y - py) > STILL:
			player = TimeDirector.now() - t_hit - 1.0 / 120.0
		by = g.global_position.y
		py = _p.global_position.y
	return {"hit": hit, "id": ids[0], "body": maxf(body, 0.0), "player": maxf(player, 0.0), "info": info,
		"hitstop": info.hitstop if info else 0.0}

func _land_and_clear(g: Fighter) -> void:
	release_inputs()
	await wait_until(func() -> bool: return not _p.is_airborne() and not _p.combat.is_attacking(), 3.0)
	await wait_real(0.3)
	g.queue_free()
	await ticks(2)
