extends "res://tests/combat/combat_test_base.gd"
## Sparta kick launches (LAUNCHED); a dash-in kick launches at least 50%
## faster / further than a standing kick (spec M4, speed is power).

func _kick_once(p: Fighter, g: Fighter, dash: bool) -> Dictionary:
	clear_events()
	var out := {"speed": 0.0, "launched": false, "dist": 0.0}
	if dash:
		p.move_input = p.get_forward()
		p.combat.press(CombatController.Action.DASH)
		await wait_real(0.12)
		p.move_input = Vector3.ZERO
	p.combat.press(CombatController.Action.KICK)
	var ok := await wait_until(func() -> bool: return count_events(&"hit_landed") > 0, 1.5)
	if not ok:
		return out
	var info: HitInfo = last_event(&"hit_landed")[1]
	out["speed"] = info.launch_velocity.length()
	out["reaction"] = info.reaction
	var start := g.get_ground_position()
	await ticks(3)
	out["launched"] = g.is_launched()
	await wait_game(0.6)  # game time: big launches get slow motion
	var d := g.get_ground_position() - start
	d.y = 0.0
	out["dist"] = d.length()
	return out

func run() -> void:
	var p1 := spawn(&"player", Vector3.ZERO, Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var g1 := spawn(&"grunt", Vector3(0, 0, -1.3), Vector3.BACK)
	var p2 := spawn(&"player", Vector3(30, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var g2 := spawn(&"grunt", Vector3(30, 0, -3.6), Vector3.BACK)
	await ticks(20)
	print("kick: standing")
	var a: Dictionary = await _kick_once(p1, g1, false)
	print("  standing: ", a)
	check(a["speed"] > 0.0, "standing kick connected")
	check(absf(a["speed"] - Tuning.KICK_LAUNCH) < 0.3, "standing kick launch %.2f m/s ~ %.1f" % [a["speed"], Tuning.KICK_LAUNCH])
	check(a.get("reaction", -1) == HitInfo.Reaction.LAUNCH, "kick reaction is LAUNCH")
	if rig_is_real(g1):
		check(a["launched"], "victim state LAUNCHED after kick")
	else:
		print("  SKIP launched-state check (stub rig)")
	await wait_real(0.3)
	print("kick: dash-in")
	var b: Dictionary = await _kick_once(p2, g2, true)
	print("  dash-in: ", b)
	check(b["speed"] > 0.0, "dash kick connected")
	check(b["speed"] >= a["speed"] * 1.5, "dash kick %.2f m/s >= 1.5 x standing %.2f" % [b["speed"], a["speed"]])
	if rig_is_real(g2) and a["dist"] > 0.3:
		check(b["launched"], "dash-kick victim LAUNCHED")
		print("  distance after 0.6 s game time: standing %.2f m, dash %.2f m" % [a["dist"], b["dist"]])
		check(b["dist"] >= a["dist"] * 1.3, "dash kick travels further (%.2f vs %.2f m)" % [b["dist"], a["dist"]])
	done()
