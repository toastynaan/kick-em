extends "res://tests/input/input_test_base.gd"
## Player time (Round 5 F0, agent H; Round 7: Focus mode is gone, so the slow
## motion comes from TimeDirector.request_slowmo): in a 0.25x slow motion the
## player covers the same distance per real second as at normal speed, within
## 5%, while an enemy walks at the world's slowed rate. Also within 5%: a
## knockback slide and a sprint (when Traversal drives the player).

const SLOW := 0.25
const SLOW_TIME := 1.6  ## real s of slow motion per measurement

func run() -> void:
	var p := spawn_player(Vector3.ZERO)
	var g := spawn_dummy(&"grunt", Vector3(30, 0, 0), Vector3.FORWARD)
	await ticks(40)

	# --- Walk. --------------------------------------------------------------------
	var normal := await _run(p, g, false)
	var slow := await _run(p, g, true)
	print("  walk: %.3f m per real s normal, %.3f in slow motion (time %.2fx); enemy %.3f vs %.3f"
		% [normal["run"], slow["run"], slow["scale"], normal["enemy"], slow["enemy"]])
	check(near(slow["scale"], SLOW, 0.02), "the slow motion ran (world at %.2fx)" % slow["scale"])
	check(near(slow["run"], normal["run"], 0.05), "F0: distance per real second in slow motion %.3f vs %.3f m (%.1f%%)"
		% [slow["run"], normal["run"], 100.0 * (slow["run"] / maxf(normal["run"], 1e-4) - 1.0)])
	check(near(slow["enemy"], normal["enemy"] * SLOW, 0.08),
		"the enemy walks at the world's rate (%.2f vs %.2f m per real s)" % [slow["enemy"], normal["enemy"]])

	# --- Sprint (Traversal). --------------------------------------------------------
	var sn := await _sprint(p, false)
	if sn.is_empty():
		print("  NOTE Traversal does not drive the player's sprint; sprint skipped")
	else:
		var sf := await _sprint(p, true)
		print("  sprint: %.3f m per real s normal, %.3f in slow motion" % [sn["run"], sf["run"]])
		check(near(sf["run"], sn["run"], 0.05), "sprint distance per real second in slow motion %.3f vs %.3f m" % [sf["run"], sn["run"]])

	# --- Knockback. ----------------------------------------------------------------------
	var kn := await _slide(p, false)
	var kf := await _slide(p, true)
	print("  knockback slide: %.3f m normal, %.3f m in slow motion" % [kn, kf])
	check(near(kf, kn, 0.05), "knockback slide %.3f vs %.3f m" % [kf, kn])
	done()

func _slow_on() -> void:
	TimeDirector.reset()
	TimeDirector.request_slowmo(SLOW, SLOW_TIME, TimeDirector.PRIO_DODGE)
	await ticks(1)

func _slow_off() -> void:
	TimeDirector.reset()
	await wait_until(func() -> bool: return Engine.time_scale > 0.99, 240)

## Walk for 1 real second (after 0.25 s to reach speed). Returns the player's
## and the enemy's metres per real second and the time scale seen.
func _run(p: Fighter, g: Fighter, slowed: bool) -> Dictionary:
	await _home(p)
	g.move_input = Vector3.FORWARD
	press(&"move_right")
	await ticks(30)
	if slowed:
		await _slow_on()
	var a := p.global_position
	var ga := g.global_position
	var t0 := TimeDirector.now()
	var scale := Engine.time_scale
	await ticks(120)
	var dt := TimeDirector.now() - t0
	var b := p.global_position
	var gb := g.global_position
	release(&"move_right")
	g.move_input = Vector3.ZERO
	await _slow_off()
	return {"run": Vector2(b.x - a.x, b.z - a.z).length() / dt,
		"enemy": Vector2(gb.x - ga.x, gb.z - ga.z).length() / dt, "scale": scale}

## Sprint for 1 real second at full speed. {} when Traversal does not drive it.
func _sprint(p: Fighter, slowed: bool) -> Dictionary:
	await _home(p)
	press(&"move_right")
	press(&"dash")
	await ticks(180)  # past the ramp
	if not p.is_traversal_driving() or p.traversal == null or not p.traversal.is_sprinting():
		release(&"dash")
		release(&"move_right")
		await ticks(60)
		return {}
	if slowed:
		await _slow_on()
	await ticks(6)
	var a := p.global_position
	var t0 := TimeDirector.now()
	await ticks(120)
	var dt := TimeDirector.now() - t0
	var b := p.global_position
	release(&"dash")
	release(&"move_right")
	await _slow_off()
	await ticks(60)
	return {"run": Vector2(b.x - a.x, b.z - a.z).length() / dt}

## A 5 m/s knockback for 0.2 s of player time: 1 m.
func _slide(p: Fighter, slowed: bool) -> float:
	await _home(p)
	if slowed:
		await _slow_on()
	var k0 := p.global_position
	p.knockback(Vector3(5.0, 0.0, 0.0), 0.2)
	await ticks(60)
	var d := Vector2(p.global_position.x - k0.x, p.global_position.z - k0.z).length()
	await _slow_off()
	return d

## Back to the start, standing still.
func _home(p: Fighter) -> void:
	await wait_until(func() -> bool: return p.can_act(), 240)
	p.teleport_to(Vector3(0, 0, 0), Vector3.FORWARD)
	await ticks(20)
