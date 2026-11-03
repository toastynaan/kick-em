extends "res://tests/combat/combat_test_base.gd"
## Round 7 acceptance check 4 (docs/Round 7 — Freeflow Combat.md: Payoffs):
## uppercut -> roundhouse on a real grunt (agent H's lift): the uppercut lifts
## it, the roundhouse on the lifted body is the launch payoff, and the grunt
## flies at 15 m/s +-1 into the air (12 degrees up, along the hit); a brick
## wall in its path cracks or breaks per the wall table (the impact energy
## against the panel's break energy, Tuning.CRACK_FRACTION of it to crack).
## Also, with the real lift: the juggle re-pop caps at R7_JUGGLE_MAX, then the
## body falls into a knockdown.

const T := HitInfo.Tier

func _init() -> void:
	_timeout = 90.0

func run() -> void:
	var walls := []
	GameEvents.wall_cracked.connect(func(w: Node3D, _p: Vector3, e: float) -> void: walls.append([&"crack", w, e]))
	GameEvents.wall_broken.connect(func(w: Node3D, _p: Vector3, e: float, _v: Vector3) -> void: walls.append([&"break", w, e]))
	print("uppercut -> roundhouse")
	var p := spawn_fake(&"player", Vector3(0, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	p.combat.sever_on_kill_chance = 0.0
	var g := spawn(&"grunt", Vector3(0, 0, -1.0), Vector3.BACK)
	var wall := Destructible.new()
	wall.surface = &"brick"
	wall.name = "BrickWall"
	wall.transform = Transform3D(Basis(), Vector3(0, 1.5, -4.6))  # exterior face toward the player (+Z)
	add_child(wall)
	await ticks(20)
	clear_events()
	p.combat.play_move(&"uppercut", g)
	await wait_until(func() -> bool: return not hits_on(g).is_empty(), 1.0)
	var up: HitInfo = hits_on(g)[0] if not hits_on(g).is_empty() else null
	await wait_until(func() -> bool: return g.is_lifted() or g.is_down(), 0.5)
	var lifted := g.is_lifted() and g.get_react_state() == &"lift"
	print("  uppercut: react %s, state %s, lifted %s" % [up.react if up else &"-", g.get_react_state(), g.is_lifted()])
	check(up != null and up.react == &"lift" and lifted, "the uppercut lifts the grunt (react state lift)")
	await wait_until(func() -> bool: return not p.combat.is_attacking(), 1.0)
	var peak := 0.0
	p.combat.play_move(&"roundhouse", g)
	while p.combat.is_attacking() and hits_on(g).size() < 2:
		peak = maxf(peak, g.global_position.y)
		await get_tree().physics_frame
	var rh: HitInfo = hits_on(g)[1] if hits_on(g).size() >= 2 else null
	if rh == null:
		check(false, "the roundhouse landed on the lifted grunt")
		done()
		return
	var lv := rh.launch_velocity
	print("  roundhouse on %s: react %s payoff %s, launch %.2f m/s at %.1f deg (lifted %.2f m)" % [rh.victim_state, rh.react,
		rh.payoff, lv.length(), rad_to_deg(atan2(lv.y, Vector2(lv.x, lv.z).length())), peak])
	check(rh.victim_state == &"lift" and rh.react == &"launch" and rh.payoff and rh.tier == T.LAUNCH,
		"the roundhouse on the lifted body is the launch payoff")
	# The flight: the body's speed once its hitstop lets it go.
	await wait_until(func() -> bool: return not g.is_frozen(), 0.5)
	var speed := 0.0
	var vel := Vector3.ZERO
	for i in 4:
		await get_tree().physics_frame
		var v := g.get_com_velocity()
		if v.length() > speed:
			speed = v.length()
			vel = v
	var ang := rad_to_deg(atan2(vel.y, Vector2(vel.x, vel.z).length()))
	print("DATA uppercut -> roundhouse: the grunt flies at %.2f m/s, %.1f deg up, heading %s" % [speed, ang,
		Vector3(vel.x, 0, vel.z).normalized()])
	check(g.is_launched(), "the grunt is launched (ragdoll flight)")
	check(absf(speed - 15.0) <= 1.0, "it flies at 15 m/s +-1 (%.2f)" % speed)
	check(vel.y > 0.0 and Vector3(vel.x, 0, vel.z).normalized().dot(Vector3.FORWARD) > 0.95, "into the air, along the hit")
	await wait_until(func() -> bool: return not walls.is_empty(), 1.5)
	var mine := walls.filter(func(w: Array) -> bool: return w[1] == wall)
	if mine.is_empty():
		check(false, "the brick wall in its path was struck")
	else:
		var e: float = mine[0][2]
		var need := wall.last_impact_break_energy if wall.last_impact_break_energy > 0.0 else wall.original_break_energy
		var want := &"break" if e >= need else (&"crack" if e >= Tuning.CRACK_FRACTION * wall.original_break_energy else &"hold")
		print("DATA the brick wall: %s at %.0f J (break at %.0f J, crack at %.0f J)" % [mine[0][0], e, need,
			Tuning.CRACK_FRACTION * wall.original_break_energy])
		check(mine[0][0] == want, "the wall %ss per the wall table" % mine[0][0])

	print("the juggle re-pop caps at R7_JUGGLE_MAX (agent H's lift)")
	var p2 := spawn_fake(&"player", Vector3(20, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var g2 := spawn(&"grunt", Vector3(20, 0, -1.0), Vector3.BACK)
	await ticks(20)
	clear_events()
	p2.combat.play_move(&"uppercut", g2)
	await wait_until(func() -> bool: return g2.is_lifted(), 1.0)
	var reacts: Array[StringName] = []
	for i in Tuning.R7_JUGGLE_MAX + 1:
		await wait_until(func() -> bool: return not p2.combat.is_attacking(), 1.0)
		var n := hits_on(g2).size()
		p2.combat.play_move(&"jab", g2)
		await wait_until(func() -> bool: return hits_on(g2).size() > n, 1.0)
		await ticks(2)
		reacts.append(&"down" if g2.is_down() else g2.get_react_state())
	var kinds := hits_on(g2).map(func(h: HitInfo) -> StringName: return h.react)
	print("  hits %s; after each jab: %s" % [kinds, reacts])
	check(kinds.slice(1).all(func(k: StringName) -> bool: return k == &"repop"), "every jab on the lifted body is a re-pop")
	check(reacts.size() == Tuning.R7_JUGGLE_MAX + 1 and reacts[Tuning.R7_JUGGLE_MAX - 1] == &"lift"
		and reacts[Tuning.R7_JUGGLE_MAX] == &"down", "re-pops %d times, then the body falls into a knockdown" % Tuning.R7_JUGGLE_MAX)
	done()
