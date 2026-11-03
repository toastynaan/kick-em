extends "res://tests/combat/combat_test_base.gd"
## Contact frame and hitstop (Round 7: docs/Round 7 — Freeflow Combat.md: Hit
## feel):
## - hit_landed fires on the contact physics frame with the Round 7 fields
##   (react, weight, push, stun) filled, and the victim's reaction has already
##   started that frame (its react state);
## - hitstop per move (R7_MOVES "hitstop") freezes the attacker and the victim
##   only, while a third fighter keeps moving; the player's own freeze never
##   passes Tuning.R7_PLAYER_HITSTOP_MAX;
## - a launched victim is held (no motion) through its freeze, then flies;
## - combat emits no screen_shake for hits (the camera listens to hit_landed).

var _shakes := 0
var _landed_info: HitInfo
var _state_at_land: StringName = &""
var _landed_t := 0.0

func _init() -> void:
	_timeout = 60.0

func run() -> void:
	GameEvents.screen_shake.connect(func(_t: float) -> void: _shakes += 1)
	GameEvents.hit_landed.connect(func(info: HitInfo) -> void:
		if _landed_info == null:
			_landed_t = TimeDirector.now()
			_landed_info = info
			_state_at_land = (info.victim as Fighter).get_react_state())
	var walker := spawn(&"grunt", Vector3(6, 0, 0), Vector3.FORWARD)
	for spec: Array in [[&"jab", 1.0], [&"roundhouse", 1.2], [&"heavy_roundhouse", 1.2]]:
		var id: StringName = spec[0]
		var p := spawn_fake(&"player", Vector3(0, 0, 20.0 * float(["jab", "roundhouse", "heavy_roundhouse"].find(String(id)))),
			Vector3.FORWARD, Fighter.TEAM_PLAYER)
		var g := spawn(&"grunt", p.global_position + Vector3(0, 0, -float(spec[1])), Vector3.BACK)
		await ticks(15)
		_landed_info = null
		walker.move_input = Vector3.FORWARD
		var stop := float(Tuning.R7_MOVES[id]["hitstop"])
		print("%s: contact frame, hitstop %.2f s" % [id, stop])
		p.combat.play_move(id, g)
		await wait_until(func() -> bool: return _landed_info != null, 1.5)
		var info := _landed_info
		check(info != null and info.react != &"" and info.weight > 0.0 and is_equal_approx(info.hitstop, stop),
			"hit_landed carries react %s, weight %.2f, hitstop %.2f" % [info.react if info else &"-", info.weight if info else 0.0,
			info.hitstop if info else 0.0])
		if info != null and info.react in [&"snap", &"spin", &"push", &"fold", &"buckle", &"lift"]:
			check(_state_at_land == info.react, "the %s had started on the contact frame (state %s)" % [info.react, _state_at_land])
		var t0 := _landed_t
		var w0 := walker.global_position
		var p_frozen := 0.0
		var g_frozen := 0.0
		var held_speed := 0.0
		while TimeDirector.now() - t0 < stop + 0.12:
			await get_tree().physics_frame
			if p.is_frozen():
				p_frozen = TimeDirector.now() - t0
			if g.is_frozen():
				g_frozen = TimeDirector.now() - t0
				held_speed = maxf(held_speed, g.get_com_velocity().length())
		var walked := walker.global_position.distance_to(w0)
		var p_want := minf(stop, Tuning.R7_PLAYER_HITSTOP_MAX)
		print("  attacker frozen %.3f s (want %.3f), victim %.3f s (want %.3f), third fighter moved %.2f m" % [
			p_frozen, p_want, g_frozen, stop, walked])
		check(absf(g_frozen - stop) <= 0.02, "the victim freezes the move's hitstop")
		check(absf(p_frozen - p_want) <= 0.02 and p_frozen <= Tuning.R7_PLAYER_HITSTOP_MAX + 0.01,
			"the attacker freezes it too, never past R7_PLAYER_HITSTOP_MAX")
		check(walked > 0.1, "a third fighter keeps moving during the hitstop (%.2f m)" % walked)
		if info != null and info.react == &"launch":
			print("  launched body: speed while held %.2f m/s, then %.2f m/s" % [held_speed, g.get_com_velocity().length()])
			check(held_speed < 0.5, "the launched body is held through its freeze")
			check(g.get_com_velocity().length() > 5.0, "then it flies")
		walker.move_input = Vector3.ZERO
		walker.global_position = Vector3(6, 0, 0)
		walker.reset_physics_interpolation()
		await wait_real(0.3)
	check(_shakes == 0, "no screen_shake from combat for hits (%d)" % _shakes)
	done()
