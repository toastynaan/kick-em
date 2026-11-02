extends "res://tests/combat/combat_test_base.gd"
## Round 5 guard on the player (Feel Reference: Holding Block): a held guard
## takes Tuning.GUARD_DAMAGE_MULT of the damage; a stagger-tier or heavier hit
## pushes it back Tuning.GUARD_PUSH m, a light one does not; the heavy's
## shoulder charge is unblockable (a knockdown); grabs beat a guard;
## invulnerability ignores hits; heavies launch at Tuning.HEAVY_LAUNCH_MULT.

const TraversalDouble := preload("res://tests/combat/traversal_double.gd")
const A := CombatController.Action
var _x := 0.0

func _init() -> void:
	_timeout = 60.0

func _landed_on(f: Fighter) -> HitInfo:
	for e: Array in events:
		if (e[0] == &"hit_landed" or e[0] == &"hit_blocked") and (e[1] as HitInfo).victim == f:
			return e[1]
	return null

## A guarding player (Block held past its parry window) and an enemy 1.2 m in front.
func _guarding(arch: StringName) -> Array:
	_x += 10.0
	var p := spawn(&"player", Vector3(_x, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var e := spawn(arch, Vector3(_x, 0, -1.3), Vector3.BACK)
	await ticks(15)
	p.combat.press(A.BLOCK)
	await wait_real(Tuning.PARRY_WINDOW + Tuning.PARRY_LOCKOUT + 0.05)
	return [p, e]

func _guard_case(arch: StringName, move: StringName) -> Dictionary:
	var pe: Array = await _guarding(arch)
	var p: Fighter = pe[0]
	var e: Fighter = pe[1]
	clear_events()
	var hp0 := p.hp
	var z0 := p.global_position.z
	e.combat.start_enemy_attack(move, 0.3)
	await wait_until(func() -> bool: return _landed_on(p) != null, 2.0)
	await wait_real(0.35)
	var out := {"info": _landed_on(p), "dmg": hp0 - p.hp, "push": p.global_position.z - z0, "p": p}
	p.combat.release(A.BLOCK)
	return out

func run() -> void:
	print("guard: a light hit (e_jab), 80% less damage, no push")
	var r: Dictionary = await _guard_case(&"grunt", &"e_jab")
	var info: HitInfo = r["info"]
	print("  e_jab on a guard: result %s, damage %.2f, pushed %.2f m" % [info.result if info else -1, r["dmg"], r["push"]])
	check(info != null and info.result == HitInfo.Result.BLOCKED, "the jab is guarded")
	check(is_equal_approx(r["dmg"], Tuning.DMG_ENEMY[&"e_jab"] * Tuning.GUARD_DAMAGE_MULT), "80%% less damage (%.1f)" % r["dmg"])
	check(absf(r["push"]) < 0.15, "a light hit does not push the guard")

	print("guard: a heavy hit (e_heavy, stagger tier) pushes back 0.5 m")
	r = await _guard_case(&"heavy", &"e_heavy")
	info = r["info"]
	print("  e_heavy on a guard: result %s, damage %.2f, pushed %.2f m" % [info.result if info else -1, r["dmg"], r["push"]])
	check(info != null and info.result == HitInfo.Result.BLOCKED, "the smash is guarded")
	check(is_equal_approx(r["dmg"], Tuning.DMG_ENEMY[&"e_heavy"] * Tuning.GUARD_DAMAGE_MULT), "80%% less damage (%.1f)" % r["dmg"])
	check(absf(r["push"] - Tuning.GUARD_PUSH) < 0.15, "pushed back %.2f m (GUARD_PUSH %.1f)" % [r["push"], Tuning.GUARD_PUSH])

	print("guard: the heavy's shoulder charge goes through it")
	r = await _guard_case(&"heavy", &"e_charge")
	info = r["info"]
	check(info != null and info.result == HitInfo.Result.HIT and info.tier == HitInfo.Tier.KNOCKDOWN,
		"e_charge: unblockable, a knockdown (%s)" % [info])
	await ticks(5)
	check((r["p"] as Fighter).is_down(), "the player is knocked down")

	print("grab beats a guarding player")
	var pe: Array = await _guarding(&"grunt")
	var p3: Fighter = pe[0]
	var e3: Fighter = pe[1]
	clear_events()
	var grabbed := [false]
	var c1 := func(_a: Node3D, _b: Node3D) -> void: grabbed[0] = true
	GameEvents.grab_started.connect(c1)
	GameEvents.carry_changed.connect(c1)
	check(e3.combat.start_enemy_attack(&"e_grab", 0.4), "enemy grab started")
	var ok := await wait_until(func() -> bool: return grabbed[0], 2.0)
	check(ok and p3.combat.last_result != HitInfo.Result.BLOCKED, "the grab catches the guard")
	p3.combat.release(A.BLOCK)
	await wait_real(1.5)

	print("invulnerable ignores hits")
	_x += 10.0
	var p4 := spawn(&"player", Vector3(_x, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var e4 := spawn(&"grunt", Vector3(_x, 0, -1.0), Vector3.BACK)
	await ticks(20)
	e4.invuln_until = TimeDirector.now() + 2.0
	var hp0 := e4.hp
	tap(p4, A.LIGHT)
	await wait_real(0.4)
	check(is_equal_approx(e4.hp, hp0) and e4.combat.last_result == HitInfo.Result.IGNORED, "hit IGNORED while invulnerable")

	print("a heavy launches at 80%")
	_x += 10.0
	var p5 := spawn(&"player", Vector3(_x, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var hv := spawn(&"heavy", Vector3(_x, 0, -2.6), Vector3.BACK)
	var tv: Traversal = TraversalDouble.new()
	p5.add_child(tv)
	tv.setup(p5)
	p5.traversal = tv
	tv.set(&"speed", 8.0)
	tv.set(&"sprinting", true)
	await ticks(20)
	clear_events()
	tap(p5, A.HEAVY)
	await wait_until(func() -> bool: return _landed_on(hv) != null, 1.5)
	info = _landed_on(hv)
	check(info != null and info.tier == HitInfo.Tier.LAUNCH, "a sprint cross (P 5) launches the heavy")
	if info != null:
		var want := Power.launch_speed(info.power) * Tuning.HEAVY_LAUNCH_MULT
		print("  heavy launch %.2f m/s (v(P) %.2f x %.1f)" % [info.launch_velocity.length(), Power.launch_speed(info.power), Tuning.HEAVY_LAUNCH_MULT])
		check(absf(info.launch_velocity.length() - want) < 0.01, "at 80%% of v(P): %.2f m/s" % want)
	done()
