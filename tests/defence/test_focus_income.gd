extends "res://tests/defence/defence_test_base.gd"
## F6 Focus income (Feel Reference: Focus). Acceptance (agent H): Focus gained
## during Focus mode is 0. Also the income table: parry +0.34, a stagger or
## knockdown hit +0.1, a launch +0.25, a wall break by a body the player
## launched +0.5; a flinch, a stumble, a kill and time give nothing; enemies'
## hits on the player give nothing.

func run() -> void:
	var p := spawn_player(Vector3.ZERO)
	await ticks(30)
	var g := spawn_attacker(p, &"grunt", Vector3(0, 0, -1.0))
	var g2 := spawn_dummy(&"grunt", Vector3(4, 0, -1.0), Vector3.BACK)
	await ticks(20)

	print("income outside Focus mode")
	var gains := await _income_round(p, g, g2)
	for k: StringName in gains:
		print("  %s: +%.3f" % [k, gains[k]])
	check(absf(gains[&"parry"] - 0.34) < 1e-3, "parry +%.2f (want 0.34)" % gains[&"parry"])
	check(absf(gains[&"stagger"] - 0.1) < 1e-3, "stagger hit +%.2f (want 0.1)" % gains[&"stagger"])
	check(absf(gains[&"knockdown"] - 0.1) < 1e-3, "knockdown hit +%.2f (want 0.1)" % gains[&"knockdown"])
	check(absf(gains[&"launch"] - 0.25) < 1e-3, "launch +%.2f (want 0.25)" % gains[&"launch"])
	check(absf(gains[&"wall_break"] - 0.5) < 1e-3, "wall break by a body the player launched +%.2f (want 0.5)" % gains[&"wall_break"])
	check(absf(gains[&"flinch"]) < 1e-4 and absf(gains[&"stumble"]) < 1e-4, "flinch and stumble hits: nothing")
	check(absf(gains[&"kill"]) < 1e-4, "a kill: nothing")
	check(absf(gains[&"enemy_hit"]) < 1e-4, "an enemy's hit on the player: nothing")
	check(absf(gains[&"time"]) < 1e-4, "3 s of time: nothing")

	print("income during Focus mode")
	p.focus = 2.0
	press(&"focus")
	await ticks(1)
	release(&"focus")
	await ticks(1)
	check(p.is_focusing(), "Focus mode on")
	var f_in := p.focus
	var during := await _income_round(p, g, g2, true)
	var total := 0.0
	for k: StringName in during:
		total += during[k]
	print("  gained during Focus mode: %.4f (per source %s)" % [total, during])
	check(p.is_focusing(), "still in Focus mode after the events (%.2f s left)" % p.get_focus_time_left())
	check(absf(total) < 1e-4 and absf(p.focus - f_in) < 1e-4, "Focus gained during Focus mode: %.4f (want 0)" % total)
	done()

## Each income source once; returns the Focus each one gave. `quick` skips the
## slow ones so the round fits in Focus mode's 2 s.
func _income_round(p: Fighter, g: Fighter, g2: Fighter, quick := false) -> Dictionary:
	var out := {}
	p.focus = minf(p.focus, 1.0) if not quick else p.focus
	# Parry (real, through the input path).
	await _ready_up(p, g, quick)
	var f := p.focus
	g.combat.start_enemy_attack(&"e_jab", Tuning.frames(18))
	await wait_for_lead(g, 6 / 120.0)
	press(&"block")
	await ticks(1)
	release(&"block")
	await wait_until(func() -> bool: return count_events(&"parried") > 0, 60)
	out[&"parry"] = p.focus - f
	# Hits by tier (scripted HitInfos from the player).
	for tier: int in [HitInfo.Tier.FLINCH, HitInfo.Tier.STUMBLE, HitInfo.Tier.STAGGER, HitInfo.Tier.KNOCKDOWN, HitInfo.Tier.LAUNCH]:
		await _ready_up(p, g2, quick)
		f = p.focus
		g2.take_hit(scripted_hit(p, g2, tier, 6.0 if tier == HitInfo.Tier.LAUNCH else 0.0))
		await ticks(2)
		out[HitInfo.tier_name(tier)] = p.focus - f
	# Wall break: a body the player launched breaks a wall (ImpactResolver.get_launcher).
	# The launch tier's hitstop (110 ms) holds the body before it flies, and the
	# resolver tracks a flight only once it moves: wait for the flight to start.
	await wait_until(func() -> bool: return ImpactResolver.get_launcher(g2) != null, 60)
	var launcher: Node3D = ImpactResolver.get_launcher(g2) if ImpactResolver.has_method(&"get_launcher") else null
	check(launcher == p, "ImpactResolver.get_launcher(the launched grunt) is the player (%s)" % launcher)
	f = p.focus
	GameEvents.wall_broken_by.emit(g2, null, 3000.0)
	await ticks(1)
	out[&"wall_break"] = p.focus - f
	# An enemy's hit on the player.
	f = p.focus
	p.take_hit(scripted_hit(g, p, HitInfo.Tier.STAGGER))
	await ticks(2)
	out[&"enemy_hit"] = p.focus - f
	p.hp = p.max_hp
	# A kill (a flinch-tier hit that finishes a 1 HP grunt).
	if not quick:
		var victim := spawn_dummy(&"grunt", Vector3(-4, 0, -1.0), Vector3.BACK)
		await ticks(10)
		victim.hp = 1.0
		f = p.focus
		victim.take_hit(scripted_hit(p, victim, HitInfo.Tier.FLINCH))
		await ticks(2)
		out[&"kill"] = p.focus - f
		check(victim.is_dead(), "the 1 HP grunt died")
		f = p.focus
		await ticks(360)
		out[&"time"] = p.focus - f
	return out

func _ready_up(p: Fighter, e: Fighter, quick := false) -> void:
	if not quick:
		await wait_until(func() -> bool: return not e.is_down(), 900)
		await settle(e)
		await settle(p)
	elif e.ragdoll and e.ragdoll.is_simulating():
		e.ragdoll.force_recover()
	e.combat.cancel()
	e.hp = e.max_hp
	await ticks(2)
