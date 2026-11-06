extends "res://tests/combat/combat_test_base.gd"
## Round 8 acceptance check 2 (docs/Round 8 — Charge and Pressure.md: Moves):
## every row of the moves table, tapped and charged at c = 0 and c = 1, on a
## fresh grunt, with agent H's real reactions, measured on the body:
## - the reaction (react_started kind, knockdown / sweep down, ragdoll launch);
## - push +-20% (the body's slide along the hit, across the facing for the hook);
## - stun +-0.05 s (own time from the end of the hitstop to the reaction's end);
## - lift +-0.15 m (the feet's peak above the floor);
## - launch speed +-0.5 m/s (the body's speed once its hitstop lets it go;
##   the hook's charged launch goes sideways).
## Also: the HitInfo Round 8 fields (charged, charge, pressure, tier) and the
## full charged gut punch breaking the grunt's pressure outright;
## Tuning.debug_launch_step 0.5 makes the front kick launch at c = 0.5.

const PUSH_TOL := 0.2    ## share
const STUN_TOL := 0.05   ## s
const LIFT_TOL := 0.15   ## m
const SPEED_TOL := 0.5   ## m/s

var _x := 0.0
var _rows := 0

func _init() -> void:
	_timeout = 240.0

func run() -> void:
	for id: StringName in Tuning.R8_MOVES:
		await _trial(id, -1.0)
		await _trial(id, 0.0)
		await _trial(id, 1.0)
	print("debug_launch_step 0.5: the front kick launches from c = 0.5")
	Tuning.debug_launch_step = 0.5
	await _trial(&"front_kick", 0.45)
	await _trial(&"front_kick", 0.5)
	Tuning.debug_launch_step = 1.0
	print("DATA %d trials" % _rows)
	done()

## What the table says strike `id` does (c < 0: the tap): {react, push, stun,
## lift, speed, angle, sideways}.
func _want(id: StringName, c: float) -> Dictionary:
	var row: Dictionary = Tuning.R8_MOVES[id]
	if c < 0.0:
		var t: Dictionary = row["tap"]
		var tw := {"react": t["react"], "push": float(t["push"]), "stun": float(t["stun"]), "lift": 0.0,
			"speed": 0.0, "angle": 0.0, "sideways": false}
		if id == &"roundhouse":
			# Tuning.ROUNDHOUSE_STAGGER: on an unbroken guard the tap staggers (a push on its feet).
			tw["react"] = &"push"
			tw["stun"] = float(Tuning.ROUNDHOUSE_STAGGER["stun"])
		return tw
	var ch: Dictionary = row["charged"]
	var l := func(k: String) -> float: return lerpf((ch[k] as Vector2).x, (ch[k] as Vector2).y, c) if ch.has(k) else 0.0
	var w := {"react": ch["react"], "push": l.call("push"), "stun": l.call("stun"), "lift": l.call("lift"),
		"speed": 0.0, "angle": 0.0, "sideways": bool(ch.get("sideways", false))}
	if ch.has("launch_from") and c >= minf(float(ch["launch_from"]), Tuning.debug_launch_step) - 1e-4:
		w["react"] = &"launch"
		w["speed"] = l.call("launch_speed")
		w["angle"] = float(ch["launch_angle"])
	elif c >= 1.0 and ch.has("full_react"):
		w["react"] = ch["full_react"]
	return w

func _trial(id: StringName, c: float) -> void:
	_rows += 1
	_x += 8.0  # 26 lanes stay on the 500 m floor
	var label := "%s %s" % [id, "tap" if c < 0.0 else "charged c=%.2f" % c]
	var p := spawn_fake(&"player", Vector3(_x, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	p.combat.sever_on_kill_chance = 0.0
	var v: Fighter = spawn_fake(&"grunt", Vector3(_x, 0, -1.0), Vector3.BACK)
	await ticks(15)
	var w := _want(id, c)
	clear_events()
	var at := [Vector3.INF]
	var on_hit := func(i: HitInfo) -> void:
		if i.victim == v and at[0] == Vector3.INF:
			at[0] = v.global_position
	GameEvents.hit_landed.connect(on_hit)
	var started := p.combat.play_move(id, v) if c < 0.0 else p.combat.play_charged(id, c, v)
	var landed := await wait_until(func() -> bool: return not hits_on(v).is_empty(), 1.5)
	GameEvents.hit_landed.disconnect(on_hit)
	if not landed:
		check(false, "%s: landed (started %s)" % [label, started])
		p.queue_free()
		v.queue_free()
		return
	var info: HitInfo = hits_on(v)[0]
	var p0: Vector3 = at[0]
	var hit_dir := info.hit_direction
	var lateral := hit_dir.cross(Vector3.UP).normalized()  # the left hook sweeps to the attacker's right
	var dir: Vector3 = lateral if w["sideways"] else hit_dir
	await wait_until(func() -> bool: return not v.is_frozen(), 0.5)
	var t_go := TimeDirector.now()
	var kind: StringName = &""
	for e in events_of(&"react_started"):
		if e[1] == v:
			kind = e[2]
			break
	# Launch: the body's speed once the hitstop let it go.
	var speed := 0.0
	var vel := Vector3.ZERO
	var speeds: Array = []
	if w["react"] == &"launch":
		for i in 4:
			await get_tree().physics_frame
			var cv := v.get_com_velocity()
			speeds.append("%.2f" % cv.length())
			if cv.length() > speed:
				speed = cv.length()
				vel = cv
	# On-feet reactions: the slide, the stun, the lift's peak.
	var peak := 0.0
	var stun := 0.0
	var kind_now := v.get_react_state()
	var follows := kind_now != &"" and kind_now != &"down"
	if follows:
		while TimeDirector.now() - t_go < 4.0 and v.get_react_state() == kind_now:
			peak = maxf(peak, v.get_lift_height())
			await get_tree().physics_frame
		stun = TimeDirector.now() - t_go - 0.5 / 120.0
	var moved := v.global_position - p0
	moved.y = 0.0
	# The slide goes along the strike (a hook turns the head across: MoveData.push_dir)
	# or across the facing for a sideways move.
	var push := moved.dot(dir) if w["sideways"] else moved.length()
	var downed := v.is_down()
	var line := "%s -> react %s (%s), state %s" % [label, info.react, kind, kind_now]
	var bad: Array[String] = []
	if info.react != w["react"]:
		bad.append("react %s (want %s)" % [info.react, w["react"]])
	if info.charged != (c >= 0.0) or (c >= 0.0 and not is_equal_approx(info.charge, c)):
		bad.append("charged %s c %.2f" % [info.charged, info.charge])
	var want_p := 0.0
	if c < 0.0:
		want_p = float(Tuning.R8_MOVES[id]["tap"]["pressure"])
	else:
		var pv: Vector2 = Tuning.R8_MOVES[id]["charged"]["pressure"]
		want_p = lerpf(pv.x, pv.y, c)
	if absf(info.pressure - want_p) > 1e-3 and not (id == &"gut_punch" and c >= 1.0):
		bad.append("pressure %.2f (want %.2f)" % [info.pressure, want_p])
	match w["react"]:
		&"launch":
			var flat := Vector3(vel.x, 0.0, vel.z).normalized()
			line += ", flies at %.2f m/s (want %.2f; HitInfo %.2f; ticks %s) %s" % [speed, w["speed"], info.launch_velocity.length(),
				speeds, "sideways" if w["sideways"] else "straight"]
			if not v.is_launched() and not v.is_down():
				bad.append("not launched")
			if absf(speed - float(w["speed"])) > SPEED_TOL:
				bad.append("speed %.2f" % speed)
			if flat.dot(dir) < 0.9:
				bad.append("direction %s (want %s)" % [flat, dir])
		&"knockdown", &"sweep":
			var rec: Array = []
			for r: Array in v.get(&"reacts"):
				if r[0] == w["react"] or r[0] == &"knockdown":
					rec = r
					break
			line += ", down %s, call %s" % [downed, rec[0] if not rec.is_empty() else &"-"]
			if not downed:
				bad.append("not down")
			if w["react"] == &"sweep" and kind != &"sweep":
				bad.append("no sweep reaction")
			if w["sideways"] and (rec.is_empty() or (rec[1] as Vector3).normalized().dot(lateral) < 0.9):
				bad.append("knockdown not sideways (%s)" % [rec[1] if not rec.is_empty() else null])
		&"lift":
			line += ", peak %.2f m (want %.2f)" % [peak, w["lift"]]
			if kind != &"lift" or absf(peak - float(w["lift"])) > LIFT_TOL:
				bad.append("lift %.2f" % peak)
		_:
			line += ", push %.2f m (want %.2f), stun %.3f s (want %.2f)" % [push, w["push"], stun, w["stun"]]
			if kind != w["react"]:
				bad.append("reaction %s" % kind)
			if absf(push - float(w["push"])) > float(w["push"]) * PUSH_TOL + 0.01:
				bad.append("push %.2f" % push)
			if absf(stun - float(w["stun"])) > STUN_TOL:
				bad.append("stun %.3f" % stun)
	if id == &"gut_punch" and c >= 1.0:
		var broke := events_of(&"pressure_broken").any(func(e: Array) -> bool: return e[1] == v)
		line += ", pressure broken %s" % broke
		if not broke:
			bad.append("pressure not broken")
	print("  ", line, "" if bad.is_empty() else "  WRONG: %s" % ", ".join(bad))
	check(bad.is_empty(), label)
	p.queue_free()
	v.queue_free()
	await ticks(2)
