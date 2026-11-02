extends "res://tests/combat/combat_test_base.gd"
## F4 contact frame (Feel Reference: Wind-up, contact, recovery):
## - hit_landed fires on the contact physics frame with P and tier filled, and
##   the victim's reaction has already started that frame;
## - hitstop freezes the attacker and the victim only, by tier
##   (Power.hitstop_for), while a third fighter keeps moving; the player's own
##   freeze never passes Tuning.PLAYER_HITSTOP_MAX (60 ms);
## - a launched victim is held (no motion) through its freeze, then flies;
## - Block and Dash pressed during the player's freeze fire when it ends;
## - combat emits no screen_shake for hits (the camera listens to hit_landed).

const DefenceDouble := preload("res://tests/combat/defence_double.gd")
const A := CombatController.Action

var _shakes := 0
var _landed_frame := -1
var _landed_info: HitInfo
var _state_at_land := -1
var _landed_t := 0.0

func _init() -> void:
	_timeout = 60.0

func run() -> void:
	GameEvents.screen_shake.connect(func(_t: float) -> void: _shakes += 1)
	var p := spawn(&"player", Vector3.ZERO, Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var g := spawn(&"grunt", Vector3(0, 0, -1.2), Vector3.BACK)
	var walker := spawn(&"grunt", Vector3(6, 0, 0), Vector3.FORWARD)
	if p.defence != null:
		p.defence.queue_free()
	var dd: Defence = DefenceDouble.new()
	p.add_child(dd)
	dd.setup(p)
	p.defence = dd
	await ticks(15)
	GameEvents.hit_landed.connect(func(info: HitInfo) -> void:
		if _landed_frame < 0:
			_landed_frame = Engine.get_physics_frames()
			_landed_t = TimeDirector.now()
			_landed_info = info
			_state_at_land = (info.victim as Fighter).get_state())

	print("jab: contact frame, freezes by tier")
	walker.move_input = Vector3.FORWARD
	var frozen := {"p": 0, "g": 0, "walker_moved": 0.0}
	var w0 := walker.global_position
	tap(p, A.LIGHT)
	await wait_until(func() -> bool: return _landed_frame >= 0, 1.0)
	check(_landed_info != null and _landed_info.power > 0.0 and _landed_info.tier == HitInfo.Tier.FLINCH,
		"hit_landed carries P %.2f and tier %s" % [_landed_info.power if _landed_info else 0.0,
			HitInfo.tier_name(_landed_info.tier) if _landed_info else &"?"])
	check(_state_at_land == RagdollController.State.FLINCH, "the flinch had started on the contact frame (state %d)" % _state_at_land)
	var t0 := _landed_t
	w0 = walker.global_position
	var p_frozen := 0.0
	var g_frozen := 0.0
	while TimeDirector.now() - t0 < 0.3:
		await get_tree().physics_frame
		if p.is_frozen():
			p_frozen = TimeDirector.now() - t0
		if g.is_frozen():
			g_frozen = TimeDirector.now() - t0
	var walked := walker.global_position.distance_to(w0)
	print("  jab: attacker frozen %.3f s, victim %.3f s (tier hitstop %.3f), third fighter moved %.2f m" % [
		p_frozen, g_frozen, Power.hitstop_for(HitInfo.Tier.FLINCH), walked])
	check(absf(g_frozen - Power.hitstop_for(HitInfo.Tier.FLINCH)) <= 0.02, "victim freezes the flinch hitstop")
	check(p_frozen <= Tuning.PLAYER_HITSTOP_MAX + 0.01, "attacker freeze %.3f s <= 60 ms" % p_frozen)
	check(walked > 0.3, "a third fighter keeps moving during the hitstop (%.2f m)" % walked)
	walker.move_input = Vector3.ZERO
	frozen.clear()

	print("level-3 kick: the victim's 150 ms freeze, the player's capped at 60 ms; Block and Dash buffered")
	await wait_real(1.2)
	_x_reset(g, p)
	await ticks(10)
	_landed_frame = -1
	p.combat.force_hold_charge = true
	p.combat.press(A.KICK)
	await wait_real(1.05)
	p.combat.release(A.KICK)
	await wait_until(func() -> bool: return _landed_frame >= 0, 1.5)
	check(_landed_info != null and _landed_info.tier == HitInfo.Tier.HARD_LAUNCH, "level-3 kick: hard launch")
	var land_t := _landed_t
	# Block and Dash pressed during the player's freeze.
	check(p.is_frozen(), "the player is frozen right after the contact frame")
	p.combat.press(A.BLOCK)
	p.combat.press(A.DASH)
	var bp: Array[float] = dd.get(&"block_presses")
	var dp: Array[float] = dd.get(&"dash_presses")
	check(bp.is_empty() and dp.is_empty(), "nothing reaches Defence during the freeze")
	var p_frozen2 := 0.0
	var g_frozen2 := 0.0
	var held_speed := 0.0
	while TimeDirector.now() - land_t < 0.3:
		await get_tree().physics_frame
		if p.is_frozen():
			p_frozen2 = TimeDirector.now() - land_t
		if g.is_frozen():
			g_frozen2 = TimeDirector.now() - land_t
			held_speed = maxf(held_speed, g.get_com_velocity().length())
	print("  kick: attacker frozen %.3f s, victim %.3f s (tier hitstop %.3f), victim speed while held %.2f m/s" % [
		p_frozen2, g_frozen2, Power.hitstop_for(HitInfo.Tier.HARD_LAUNCH), held_speed])
	check(p_frozen2 <= Tuning.PLAYER_HITSTOP_MAX + 0.01, "player freeze %.3f s never passes 60 ms" % p_frozen2)
	check(absf(g_frozen2 - Power.hitstop_for(HitInfo.Tier.HARD_LAUNCH)) <= 0.02, "victim freezes the hard-launch hitstop")
	check(held_speed < 0.5, "the launched body is held through its freeze")
	check(g.get_com_velocity().length() > 5.0, "then it flies (%.2f m/s)" % g.get_com_velocity().length())
	print("  Block fired at +%.3f s, Dash at +%.3f s (the player's freeze ended at +%.3f s)" % [
		(bp[0] - land_t) if not bp.is_empty() else -1.0, (dp[0] - land_t) if not dp.is_empty() else -1.0, p_frozen2])
	check(bp.size() == 1 and bp[0] - land_t >= p_frozen2 - 0.01, "the Block press fired once, after the freeze")
	check(dp.size() == 1 and dp[0] - land_t >= p_frozen2 - 0.01, "the Dash press fired once, after the freeze")
	check(await wait_until(func() -> bool: return p.combat.is_blocking(), 1.0),
		"Block still held: the player guards once the kick recovers")
	p.combat.release(A.BLOCK)
	p.combat.release(A.DASH)
	check(_shakes == 0, "no screen_shake from combat for hits (%d)" % _shakes)
	done()

## Put the grunt back in front of the player for the next strike.
func _x_reset(g: Fighter, p: Fighter) -> void:
	var at := p.global_position + p.get_forward() * 1.3
	if g.is_down():
		return
	g.global_position = at
	g.reset_physics_interpolation()
