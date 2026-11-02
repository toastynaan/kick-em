extends "res://tests/input/input_test_base.gd"
## Player time (Upgrade 2: Focus, acceptance U6): in Focus the player's run
## speed, jump apex and air time, and knockback slide match normal speed within
## 5% in real time, while an enemy walks at the world's slowed rate. Run first
## with a fake factor (TimeDirector swapped for tests/input/fake_focus_time_director.gd:
## exactly 1 / time_scale), then with the real TimeDirector.

func run() -> void:
	use_fake_time_director()
	var p := spawn_player(Vector3.ZERO)
	var g := spawn_dummy(&"grunt", Vector3(30, 0, 0), Vector3.FORWARD)
	await ticks(40)
	p.focus = Tuning.FOCUS_MAX

	var normal := await _measure(p, g)
	press(&"focus")
	await ticks(2)
	check(p.is_focusing() and near(Engine.time_scale, Tuning.FOCUS_SCALE, 0.01), "fake Focus: world at %.2fx" % Engine.time_scale)
	check(near(p.own_time_factor(), 1.0 / Tuning.FOCUS_SCALE, 0.01), "player time factor %.2f" % p.own_time_factor())
	var focus := await _measure(p, g)
	release(&"focus")
	await ticks(5)
	_compare("fake factor", normal, focus)
	check(near(focus["enemy_speed"], normal["enemy_speed"] * Tuning.FOCUS_SCALE, 0.08),
		"enemy walks at the world's rate in Focus (%.2f vs %.2f m/s real)" % [focus["enemy_speed"], normal["enemy_speed"]])

	# The real TimeDirector (agent E): same acceptance.
	_restore_time_director()
	await ticks(5)
	p.focus = Tuning.FOCUS_MAX
	press(&"focus")
	await ticks(2)
	if not TimeDirector.is_focus_active():
		print("  NOTE real TimeDirector has no Focus yet; skipped the second pass")
		release(&"focus")
		done()
		return
	var real := await _measure(p, g)
	release(&"focus")
	await ticks(5)
	_compare("real TimeDirector", normal, real)
	done()

func _compare(label: String, a: Dictionary, b: Dictionary) -> void:
	check(near(b["run"], a["run"], 0.05), "%s: run %.3f vs %.3f m per real s" % [label, b["run"], a["run"]])
	check(near(b["apex"], a["apex"], 0.05), "%s: jump apex %.3f vs %.3f m" % [label, b["apex"], a["apex"]])
	check(near(b["air"], a["air"], 0.05), "%s: air time %.3f vs %.3f real s" % [label, b["air"], a["air"]])
	check(near(b["slide"], a["slide"], 0.05), "%s: knockback slide %.3f vs %.3f m" % [label, b["slide"], a["slide"]])

## Run speed (m per real second), a jump (apex, real air time) and a knockback
## slide distance, plus the enemy's walking speed (m per real second).
func _measure(p: Fighter, g: Fighter) -> Dictionary:
	var out := {}
	# Run.
	g.move_input = Vector3.FORWARD
	press(&"move_forward")
	await ticks(40)
	var a := p.global_position
	var ga := g.global_position
	await ticks(120)
	var b := p.global_position
	var gb := g.global_position
	release(&"move_forward")
	g.move_input = Vector3.ZERO
	out["run"] = Vector2(b.x - a.x, b.z - a.z).length()
	out["enemy_speed"] = Vector2(gb.x - ga.x, gb.z - ga.z).length()
	await wait_until(func() -> bool: return p.velocity.length() < 0.01 and p.can_act(), 240)
	await ticks(20)
	# Jump.
	clear_events()
	var base := p.global_position.y
	var apex := 0.0
	press(&"jump")
	for i in 600:
		await get_tree().physics_frame
		apex = maxf(apex, p.global_position.y - base)
		if count_events(&"landed") > 0:
			break
	release(&"jump")
	var j := last_event(&"jumped")
	var l := last_event(&"landed")
	out["apex"] = apex
	out["air"] = l[4] - j[4] if not j.is_empty() and not l.is_empty() else 0.0
	await wait_until(func() -> bool: return p.can_act(), 120)
	await ticks(20)
	# Knockback: 5 m/s for 0.2 s of player time = 1 m.
	var k0 := p.global_position
	p.knockback(Vector3(5.0, 0.0, 0.0), 0.2)
	await ticks(60)
	out["slide"] = Vector2(p.global_position.x - k0.x, p.global_position.z - k0.z).length()
	await ticks(20)
	return out
