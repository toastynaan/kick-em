extends "res://tests/combat/combat_test_base.gd"
## Perfect dodge (spec: Perfect dodge rules 1 and 3):
## - block pressed 0.1 s before an enemy attack's first active frame -> DODGED, no damage
## - pressed 0.25 s before -> no dodge, lockout
## - held block without a precise press -> BLOCKED, 80% damage cut

func _tap_block(f: Fighter) -> void:
	f.combat.press(CombatController.Action.BLOCK)
	await ticks(1)
	f.combat.release(CombatController.Action.BLOCK)

func run() -> void:
	var p := spawn(&"player", Vector3.ZERO, Vector3.FORWARD, Fighter.TEAM_PLAYER)
	var e := spawn(&"grunt", Vector3(0, 0, -1.2), Vector3.BACK)
	await ticks(20)
	var dmg: float = Tuning.DMG_ENEMY[&"e_hook"]

	print("dodge: press 0.10 s before active")
	var hp0 := p.hp
	var focus0 := p.focus
	check(e.combat.start_enemy_attack(&"e_hook", 0.5), "enemy attack started")
	await wait_until(func() -> bool: return e.combat.time_to_active() <= 0.1, 2.0)
	print("  pressed at time_to_active=%.3f" % e.combat.time_to_active())
	await _tap_block(p)
	await wait_until(func() -> bool: return count_events(&"perfect_dodge") > 0, 1.0)
	check(p.combat.is_vanished() and p.is_invulnerable(), "vanished and invulnerable")
	var parts := p.rig.get_mesh_parts()
	if not parts.is_empty():
		check(not parts[0].visible, "body hidden during the vanish")
	await wait_until(func() -> bool: return not e.combat.is_attacking(), 3.0)
	check(count_events(&"perfect_dodge") == 1, "perfect_dodge emitted")
	var pd := last_event(&"perfect_dodge")
	check(not pd.is_empty() and pd[1] == p and pd[2] == e, "perfect_dodge(defender=player, attacker=enemy)")
	check(p.combat.last_result == HitInfo.Result.DODGED, "result DODGED")
	check(is_equal_approx(p.hp, hp0), "no damage on dodge (hp %.0f)" % p.hp)
	check(is_equal_approx(p.focus, focus0 + Tuning.FOCUS_PERFECT_DODGE), "focus +0.5 (%.2f)" % p.focus)
	check(not p.combat.is_vanished(), "player visible again after the vanish")
	if not parts.is_empty():
		check(parts[0].visible, "body shown again")

	await wait_real(1.2)
	print("dodge: press 0.25 s before active (too early)")
	clear_events()
	hp0 = p.hp
	check(e.combat.start_enemy_attack(&"e_hook", 0.5), "enemy attack started")
	await wait_until(func() -> bool: return e.combat.time_to_active() <= 0.25, 2.0)
	print("  pressed at time_to_active=%.3f" % e.combat.time_to_active())
	await _tap_block(p)
	await wait_until(func() -> bool: return e.combat.is_attack_active(), 2.0)
	await ticks(1)
	check(p.combat.is_dodge_locked_out(), "early press locks out perfect dodge")
	await wait_until(func() -> bool: return not e.combat.is_attacking(), 3.0)
	check(count_events(&"perfect_dodge") == 0, "no perfect dodge")
	check(is_equal_approx(hp0 - p.hp, dmg), "early press gets hit for full damage (%.0f)" % (hp0 - p.hp))

	await wait_real(1.2)
	print("dodge: press with no attack coming never locks")
	await _tap_block(p)
	await wait_real(0.5)
	check(not p.combat.is_dodge_locked_out(), "no lockout without an attack")

	await wait_real(0.8)
	print("block: held block")
	clear_events()
	hp0 = p.hp
	p.combat.press(CombatController.Action.BLOCK)
	await wait_real(0.6)
	check(p.combat.is_blocking(), "player is blocking")
	check(e.combat.start_enemy_attack(&"e_hook", 0.5), "enemy attack started")
	await wait_until(func() -> bool: return not e.combat.is_attacking(), 3.0)
	check(count_events(&"perfect_dodge") == 0, "held block is not a dodge")
	check(count_events(&"hit_blocked") == 1, "hit_blocked emitted")
	check(p.combat.last_result == HitInfo.Result.BLOCKED, "result BLOCKED")
	check(absf((hp0 - p.hp) - dmg * Tuning.BLOCK_DAMAGE_MULT) < 0.01,
		"block cut damage 80%% (%.1f of %.0f)" % [hp0 - p.hp, dmg])
	p.combat.release(CombatController.Action.BLOCK)

	await wait_real(0.8)
	print("dodge: only the player and perfect_dodge fighters may dodge")
	clear_events()
	var e_hp := e.hp
	p.combat.press(CombatController.Action.LIGHT)
	await wait_until(func() -> bool: return p.combat.time_to_active() <= 0.05, 1.0)
	e.combat.press(CombatController.Action.BLOCK)
	e.combat.release(CombatController.Action.BLOCK)
	await wait_real(0.5)
	check(not e.combat.can_perfect_dodge(), "grunt is not dodge-eligible")
	check(count_events(&"perfect_dodge") == 0, "a grunt's timed Block press is no perfect dodge")
	check(not TimeDirector.is_slowmo(), "and no slow motion")

	var du := spawn(&"duelist", Vector3(6, 0, -1.2), Vector3.BACK)
	var p2 := spawn(&"player", Vector3(6, 0, 0), Vector3.FORWARD, Fighter.TEAM_PLAYER)
	await ticks(20)
	clear_events()
	e_hp = du.hp
	p2.combat.press(CombatController.Action.LIGHT)
	await wait_until(func() -> bool: return p2.combat.time_to_active() <= 0.05, 1.0)
	du.combat.press(CombatController.Action.BLOCK)
	du.combat.release(CombatController.Action.BLOCK)
	await wait_real(0.5)
	check(du.combat.can_perfect_dodge(), "duelist is dodge-eligible")
	check(count_events(&"perfect_dodge") == 1 and last_event(&"perfect_dodge")[1] == du, "duelist perfect-dodged the jab")
	check(is_equal_approx(du.hp, e_hp), "duelist took no damage")
	check(is_equal_approx(du.focus, float(du.config["focus"]) + Tuning.FOCUS_PERFECT_DODGE),
		"duelist focus %.1f (+0.5 from config focus)" % du.focus)
	done()
