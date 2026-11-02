extends "res://tests/combat/combat_test_base.gd"
## Round 5 guard on enemies and armor (Feel Reference: Holding Block; Enemy
## types): an enemy that guards (the AI presses Block) uses the player's rules:
## a front cone, 80% less damage, a stagger-tier hit pushes it back; a low sweep
## gets under a standing guard; a launch-tier strike (P 5 and up) breaks
## through any guard. The heavy ignores flinches (damage, no interruption);
## a stagger interrupts it. Legacy archetypes keep their innate blocks and
## tell armor (the Duelist's armor_bonus).

const A := CombatController.Action
const HIT := HitInfo.Result.HIT
const BLK := HitInfo.Result.BLOCKED
var _x := 0.0

func _init() -> void:
	_timeout = 90.0

## A player and an enemy on a fresh lane. guard: the enemy holds Block.
## back: the enemy faces away from the player.
func _pair(arch: StringName, guard: bool, back: bool, dist := 1.1) -> Array:
	_x += 8.0
	var p := spawn_fake(&"player", Vector3(_x, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER, true)
	var e := spawn(arch, Vector3(_x, 0, -dist), Vector3.FORWARD if back else Vector3.BACK)
	await ticks(15)
	if guard:
		e.combat.press(A.BLOCK)
		await ticks(3)
	return [p, e]

## The player strikes (held `hold` s); returns [result, info].
func _strike(p: Fighter, e: Fighter, action: int, hold := 0.0, intent := &"neutral") -> Array:
	clear_events()
	e.combat.last_result = -1
	p.fake_intent = intent
	if hold > 0.0:
		await hold_press(p, action, hold)
	else:
		tap(p, action)
	p.fake_intent = &"neutral"
	await wait_until(func() -> bool: return e.combat.last_result != -1, 2.0)
	return [e.combat.last_result, e.combat.last_received]

func _name(r: int) -> String:
	return ["IGNORED", "HIT", "BLOCKED", "DODGED", "GRAB_BROKEN"][r] if r >= 0 else "none"

func _expect(arch: StringName, guard: bool, back: bool, action: int, want: int, what: String, hold := 0.0,
		intent := &"neutral") -> Array:
	var pe: Array = await _pair(arch, guard, back)
	var r: Array = await _strike(pe[0], pe[1], action, hold, intent)
	check(r[0] == want, "%s: %s (got %s)" % [arch, what, _name(r[0])])
	return [pe[0], pe[1], r[1]]

func run() -> void:
	print("an enemy guard (Block held) uses the player's rules")
	var r: Array = await _expect(&"grunt", true, false, A.LIGHT, BLK, "guard blocks a front jab")
	var gi: HitInfo = r[2]
	check(gi != null and is_equal_approx(gi.damage, Power.strike_damage(&"jab", 0) * Tuning.GUARD_DAMAGE_MULT),
		"80%% less damage (%.2f)" % (gi.damage if gi else -1.0))
	r = await _expect(&"grunt", true, false, A.KICK, BLK, "guard blocks a front kick (P 2.5)")
	await wait_real(0.35)
	var pushed: float = -1.1 - (r[1] as Fighter).global_position.z  # spawned 1.1 m in front, pushed away
	check(absf(pushed - Tuning.GUARD_PUSH) < 0.15, "a stagger-tier kick pushes the guard back %.2f m (GUARD_PUSH %.1f)" % [
		pushed, Tuning.GUARD_PUSH])
	await _expect(&"grunt", true, false, A.KICK, HIT, "a low sweep gets under a standing guard", 0.0, &"back")
	await _expect(&"grunt", true, true, A.KICK, HIT, "a kick to the back gets through")
	r = await _expect(&"grunt", true, false, A.HEAVY, HIT, "a level-3 cross (P 6.4) breaks the guard", 1.05)
	check(r[2] != null and (r[2] as HitInfo).tier == HitInfo.Tier.LAUNCH, "and launches")

	print("the heavy ignores flinches; a stagger interrupts it")
	var pe: Array = await _pair(&"heavy", false, false, 1.2)
	var p: Fighter = pe[0]
	var e: Fighter = pe[1]
	var ended := [false]
	e.combat.attack_ended.connect(func(_id: StringName) -> void: ended[0] = true)
	clear_events()
	var hp0 := e.hp
	check(e.combat.start_enemy_attack(&"e_heavy", 0.6), "heavy e_heavy started")
	await wait_real(0.05)
	tap(p, A.LIGHT)
	await wait_until(func() -> bool: return count_events(&"armor_absorbed") > 0, 1.0)
	check(count_events(&"armor_absorbed") == 1 and count_events(&"hit_landed") == 1, "the jab lands (hit_landed) but is absorbed")
	check(is_equal_approx(hp0 - e.hp, Power.strike_damage(&"jab", 0)), "it still deals damage (%.0f)" % (hp0 - e.hp))
	check(e.combat.is_attacking() and not ended[0], "the smash is not interrupted")
	check(e.get_state() == RagdollController.State.ANIMATED, "no flinch")
	await wait_until(func() -> bool: return not e.combat.is_attacking(), 2.5)
	await wait_real(Tuning.COMBO_DROP)
	pe = await _pair(&"heavy", false, false, 1.2)
	p = pe[0]
	e = pe[1]
	var went_active := [false]
	var cancelled := [false]
	e.combat.attack_active.connect(func(_id: StringName) -> void: went_active[0] = true)
	e.combat.attack_ended.connect(func(_id: StringName) -> void: cancelled[0] = not went_active[0])
	clear_events()
	check(e.combat.start_enemy_attack(&"e_heavy", 0.7), "heavy e_heavy started")
	await wait_real(0.05)
	tap(p, A.HEAVY)
	await wait_until(func() -> bool: return count_events(&"hit_landed") > 0, 1.0)
	check(count_events(&"armor_absorbed") == 0, "a cross (P 2.0, stagger) is not absorbed")
	await wait_real(0.3)
	check(cancelled[0], "the stagger interrupts the heavy's smash")

	print("legacy archetypes: innate blocks, tell armor")
	await _expect(&"brawler", false, false, A.LIGHT, BLK, "innate block stops front jabs")
	await _expect(&"brawler", false, true, A.LIGHT, HIT, "innate block does not cover the back")
	await _expect(&"shield", false, false, A.KICK, BLK, "shield blocks a front kick")
	await _expect(&"shield", false, true, A.LIGHT, HIT, "jab to the shield's back gets through")
	pe = await _pair(&"duelist", false, false, 1.2)
	p = pe[0]
	e = pe[1]
	clear_events()
	check(e.combat.start_enemy_attack(&"e_kick", 0.55), "duelist e_kick started")
	await wait_real(0.05)
	check(e.combat.get_armor_level() == 1, "Duelist armor_bonus: armor 1 in its startup")
	tap(p, A.LIGHT)
	await wait_until(func() -> bool: return count_events(&"armor_absorbed") > 0, 1.0)
	check(count_events(&"armor_absorbed") == 1 and e.combat.is_attacking(), "a jab is absorbed, the kick goes on")

	print("the player's guard covers the front only")
	_x += 8.0
	var pb := spawn(&"player", Vector3(_x, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var eb := spawn(&"grunt", Vector3(_x, 0, 1.2), Vector3.FORWARD)  # behind the player
	await ticks(15)
	pb.combat.press(A.BLOCK)
	await wait_real(0.3)
	pb.combat.last_result = -1
	eb.combat.start_enemy_attack(&"e_hook", 0.4)
	await wait_until(func() -> bool: return pb.combat.last_result != -1, 2.0)
	check(pb.combat.last_result == HitInfo.Result.HIT, "e_hook from behind lands on a guarding player")
	pb.combat.release(A.BLOCK)
	done()
